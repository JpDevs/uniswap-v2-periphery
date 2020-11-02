pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

import '../libraries/SafeMath.sol';
import '../interfaces/IERC20.sol';
import '../libraries/UniswapV2Library.sol';
import '../libraries/UniswapV2OracleLibrary.sol';
import './ICourt.sol';

// sliding window oracle that uses observations collected over a window to provide moving price averages in the past
// `windowSize` with a precision of `windowSize / granularity`
// note this is a singleton oracle and only needs to be deployed once per desired parameters, which
// differs from the simple oracle which must be deployed once per pair.
contract IncentivisedSlidingWindowOracle {
    using FixedPoint for *;
    using SafeMath for uint256;

    uint256 public constant ONE_HUNDRED_PERCENT = 1e18;

    struct Observation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }

    address public immutable factory;
    // the desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint public immutable windowSize;
    // the number of observations stored for each pair, i.e. how many price observations are stored for the window.
    // as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    // averages are computed over intervals with sizes in the range:
    //   [windowSize - (windowSize / granularity) * 2, windowSize]
    // e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
    //   the period:
    //   [now - [22 hours, 24 hours (whenever it was called between these times ago)], now]
    uint8 public immutable granularity;
    // this is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint public immutable periodSize;

    IERC20 public immutable incentiveToken;
    uint256 public immutable percentIncentivePerCall;
    address public incentivisedPair;
    ICourt public court;
    address public courtFeeToken;
    address public courtStableToken;
    uint256[3] public courtStableValueFees;

    // mapping from pair address to a list of price observations of that pair
    mapping(address => Observation[]) public pairObservations;

    constructor(
        address factory_,
        uint windowSize_,
        uint8 granularity_,
        IERC20 incentiveToken_,
        uint256 percentIncentivePerCall_,
        address incentivisedPair_,
        ICourt court_,
        address courtFeeToken_,
        address courtStableToken_,
        uint256[3] memory courtStableValueFees_
    ) public {
        require(granularity_ > 1, 'SlidingWindowOracle: GRANULARITY');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'SlidingWindowOracle: WINDOW_NOT_EVENLY_DIVISIBLE'
        );

        factory = factory_;
        windowSize = windowSize_;
        granularity = granularity_;
        incentiveToken = incentiveToken_;
        percentIncentivePerCall = percentIncentivePerCall_;
        incentivisedPair = incentivisedPair_;
        court = court_;
        courtFeeToken = courtFeeToken_;
        courtStableToken = courtStableToken_;
        courtStableValueFees = courtStableValueFees_;
    }

    function incentiveTokenBalance() public view returns (uint256) {
        return incentiveToken.balanceOf(address(this));
    }

    function updateIncentiveAmount() public view returns (uint256) {
        return incentiveTokenBalance().mul(percentIncentivePerCall) / ONE_HUNDRED_PERCENT;
    }

    // returns the index of the observation corresponding to the given timestamp
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationInWindow(address pair) private view returns (Observation storage firstObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = pairObservations[pair][firstObservationIndex];
    }

    function canUpdate(address tokenA, address tokenB) external view returns (bool) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        uint8 observationIndex = observationIndexOf(block.timestamp);

        if (pairObservations[pair].length > 0) {
            Observation storage observation = pairObservations[pair][observationIndex];
            uint timeElapsed = block.timestamp - observation.timestamp;
            return timeElapsed > periodSize;
        } else {
            return true;
        }
    }

    // update the cumulative price for the observation at the current timestamp. each observation is updated at most
    // once per epoch period.
    function update(address tokenA, address tokenB) external {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // populate the array with empty observations (first call only)
        for (uint i = pairObservations[pair].length; i < granularity; i++) {
            pairObservations[pair].push();
        }

        // get the observation for the current period
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = pairObservations[pair][observationIndex];

        // we only want to commit updates once per period (i.e. windowSize / granularity)
        uint timeElapsed = block.timestamp - observation.timestamp;
        require(timeElapsed > periodSize, 'SlidingWindowOracle: ALREADY_UPDATED_THIS_PERIOD');

        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
        observation.timestamp = block.timestamp;
        observation.price0Cumulative = price0Cumulative;
        observation.price1Cumulative = price1Cumulative;

        if (pair == incentivisedPair) {
            incentiveToken.transfer(msg.sender, updateIncentiveAmount());
        }
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    function consult(address tokenIn, uint amountIn, address tokenOut) public view returns (uint amountOut) {
        address pair = UniswapV2Library.pairFor(factory, tokenIn, tokenOut);
        Observation storage firstObservation = getFirstObservationInWindow(pair);

        uint timeElapsed = block.timestamp - firstObservation.timestamp;
        require(timeElapsed <= windowSize, 'SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION'); // Not enough recorded observations
        // should never happen.
        require(timeElapsed >= windowSize - periodSize * 2, 'SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED');

        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
        (address token0,) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }

    // given the cumulative prices of the start and end of a period, and the length of the period, compute the average
    // price in terms of how much amount out is received for the amount in
    function computeAmountOut(
        uint priceCumulativeStart, uint priceCumulativeEnd,
        uint timeElapsed, uint amountIn
    ) private pure returns (uint amountOut) {
        // overflow is desired.
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    /**
    * @notice Convert the court fees from their stable value to the fee token value and update the court config with them
    *   This function can be called any number of times during a court term, the closer to the start of the following term
    *   the more accurate the configured fees will be.
    */
    function updateCourtFees() external {
        uint64 currentTerm = court.ensureCurrentTerm();

        // We use the latest possible term to ensure that if the config has been updated by an account other
        // than this oracle, the config fetched will be the updated one. However, this does mean that a config update
        // that is scheduled for a future term will be scheduled for the next term instead.
        uint64 latestPossibleTerm = uint64(-1);
        (address feeToken,,
        uint64[5] memory roundStateDurations,
        uint16[2] memory pcts,
        uint64[4] memory roundParams,
        uint256[2] memory appealCollateralParams,
        uint256[3] memory jurorsParams
        ) = court.getConfig(latestPossibleTerm);

        uint256[3] memory convertedFees;
        convertedFees[0] = consult(courtStableToken, courtStableValueFees[0], courtFeeToken);
        convertedFees[1] = consult(courtStableToken, courtStableValueFees[1], courtFeeToken);
        convertedFees[2] = consult(courtStableToken, courtStableValueFees[2], courtFeeToken);

        court.setConfig(currentTerm + 1, feeToken, convertedFees, roundStateDurations, pcts, roundParams,
            appealCollateralParams, jurorsParams);
    }
}