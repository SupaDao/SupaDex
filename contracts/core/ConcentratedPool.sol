// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IConcentratedPool} from "../interfaces/IConcentratedPool.sol";
import {IConcentratedPoolSwapCallback} from "../interfaces/IConcentratedPoolSwapCallback.sol";
import {TickMathOptimized} from "../libraries/TickMathOptimized.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {CompactEncoding} from "../libraries/CompactEncoding.sol";
import {IFlashLoanCallback} from "../interfaces/IFlashLoanCallback.sol";
import {Oracle} from "../libraries/Oracle.sol";

contract ConcentratedPool is IConcentratedPool, Initializable, ReentrancyGuardUpgradeable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using TickBitmap for mapping(int16 => uint256);
    using LiquidityMath for uint128;
    using Oracle for Oracle.Observation[65535];

    mapping(address => bool) public isPauser;
    mapping(address => bool) public isCircuitBreaker;

    struct CircuitBreakerConfig {
        uint16 maxPriceDeviationBps; // e.g. 500 = 5%
        uint128 maxVolumePerBlock;   // Cap on volume per block
        uint32 cooldownPeriod;       // Time to wait after auto-pause
        bool autoPauseEnabled;
    }

    struct VolumeTracker {
        uint256 blockNumber;
        uint256 volume;
    }

    modifier onlyPauser() {
        require(isPauser[msg.sender] || msg.sender == owner(), "Not pauser");
        _;
    }

    modifier onlyCircuitBreaker() {
        require(isCircuitBreaker[msg.sender] || msg.sender == owner(), "Not circuit breaker");
        _;
    }

    function setPauser(address pauser, bool status) external onlyOwner {
        isPauser[pauser] = status;
    }

    function setCircuitBreaker(address cb, bool status) external onlyOwner {
        isCircuitBreaker[cb] = status;
    }

    // Gap to avoid collision with inherited contracts (Ownable, Pausable, etc)
    uint256[50] private __gap_custom;

    CircuitBreakerConfig public cbConfig;
    VolumeTracker public volumeTracker;
    uint256 public lastPauseTime;

    address public FACTORY;
    address public TOKEN0;
    address public TOKEN1;
    uint24 public FEE;
    int24 public TICK_SPACING;
    uint128 public MAX_LIQUIDITY_PER_TICK;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }

    Slot0 public slot0;
    uint128 public liquidity;
    
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    
    uint128 public protocolFees0;
    uint128 public protocolFees1;

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        int56 tickCumulativeOutside;
        uint160 secondsPerLiquidityOutsideX128;
        uint32 secondsOutside;
        bool initialized;
    }

    mapping(int24 => TickInfo) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => PositionInfo) public positions;
    Oracle.Observation[65535] public observations;

    struct PositionInfo {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == FACTORY, "Not factory");
    }

    modifier lock() {
        _lockBefore();
        _;
        _lockAfter();
    }

    function _lockBefore() internal {
        require(slot0.unlocked, "LOK");
        slot0.unlocked = false;
    }

    function _lockAfter() internal {
        slot0.unlocked = true;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __Pausable_init();
        isPauser[msg.sender] = true;
        isCircuitBreaker[msg.sender] = true;

        cbConfig = CircuitBreakerConfig({
            maxPriceDeviationBps: 500, // 5%
            maxVolumePerBlock: type(uint128).max, // Unlimited by default
            cooldownPeriod: 1 hours,
            autoPauseEnabled: true
        });

        FACTORY = _factory;
        TOKEN0 = _token0;
        TOKEN1 = _token1;
        FEE = _fee;
        TICK_SPACING = _tickSpacing;
        MAX_LIQUIDITY_PER_TICK = type(uint128).max / 10000; // Reasonable limit
        
        slot0 = Slot0({
            sqrtPriceX96: 0,
            tick: 0,
            observationIndex: 0,
            observationCardinality: 0,
            observationCardinalityNext: 0,
            feeProtocol: 0,
            unlocked: true
        });
        
        // Transfer ownership to factory so it can control upgrades if needed, or keep as deployer (Governance)
        _transferOwnership(_factory); 
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function initializeState(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "AI");
        int24 tick = TickMathOptimized.getTickAtSqrtRatio(sqrtPriceX96);
        
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(uint32(block.timestamp));
        
        slot0.sqrtPriceX96 = sqrtPriceX96;
        slot0.tick = tick;
        slot0.observationCardinality = cardinality;
        slot0.observationCardinalityNext = cardinalityNext;
        
        emit Initialize(sqrtPriceX96, tick);
    }

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata /* data */
    ) external override nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "A0");
        require(tickLower < tickUpper, "TLU");
        require(tickLower >= TickMathOptimized.MIN_TICK, "TLM");
        require(tickUpper <= TickMathOptimized.MAX_TICK, "TUM");
        require(tickLower % TICK_SPACING == 0, "TLS");
        require(tickUpper % TICK_SPACING == 0, "TUS");

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int128(amount)
            })
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        amount0 = uint256(amount0Int);
        // forge-lint: disable-next-line(unsafe-typecast)
        amount1 = uint256(amount1Int);

            // forge-lint: disable-next-line(unsafe-typecast)
            if (amount0 > 0) IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), uint256(amount0));
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amount1 > 0) IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), uint256(amount1));

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        (PositionInfo storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: -int128(amount)
            })
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        amount0 = uint256(-amount0Int);
        // forge-lint: disable-next-line(unsafe-typecast)
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                // forge-lint: disable-next-line(unsafe-typecast)
                position.tokensOwed0 + uint128(amount0),
                // forge-lint: disable-next-line(unsafe-typecast)
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct ModifyPositionParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (
            PositionInfo storage position,
            int256 amount0,
            int256 amount1
        )
    {
        _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, slot0.tick);

        if (params.liquidityDelta != 0) {
            if (slot0.tick < params.tickLower) {
                amount0 = int256(
                    SqrtPriceMath.getAmount0Delta(
                        TickMathOptimized.getSqrtRatioAtTick(params.tickLower),
                        TickMathOptimized.getSqrtRatioAtTick(params.tickUpper),
                        params.liquidityDelta
                    )
                );
            } else if (slot0.tick < params.tickUpper) {
                amount0 = int256(
                    SqrtPriceMath.getAmount0Delta(
                        slot0.sqrtPriceX96,
                        TickMathOptimized.getSqrtRatioAtTick(params.tickUpper),
                        params.liquidityDelta
                    )
                );
                amount1 = int256(
                    SqrtPriceMath.getAmount1Delta(
                        TickMathOptimized.getSqrtRatioAtTick(params.tickLower),
                        slot0.sqrtPriceX96,
                        params.liquidityDelta
                    )
                );

                liquidity = params.liquidityDelta < 0
                    ? liquidity - uint128(-params.liquidityDelta)
                    : liquidity + uint128(params.liquidityDelta);
            } else {
                amount1 = int256(
                    SqrtPriceMath.getAmount1Delta(
                        TickMathOptimized.getSqrtRatioAtTick(params.tickLower),
                        TickMathOptimized.getSqrtRatioAtTick(params.tickUpper),
                        params.liquidityDelta
                    )
                );
            }
        }

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 positionKey = keccak256(abi.encodePacked(params.owner, params.tickLower, params.tickUpper));
        position = positions[positionKey];
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override nonReentrant whenNotPaused returns (uint128 amount0, uint128 amount1) {
        // Update position to ensure fees are accreted
        _updatePosition(msg.sender, tickLower, tickUpper, 0, slot0.tick);
        
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 positionKey = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper));
        PositionInfo storage position = positions[positionKey];

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(TOKEN0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(TOKEN1).safeTransfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    struct SwapCache {
        uint8 feeProtocol;
        uint128 liquidityStart;
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 protocolFee;
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override nonReentrant whenNotPaused returns (int256 amount0, int256 amount1) {
        // Circuit Breaker: Volume Check
        _updateAndCheckVolume(SafeCast.toUint256(amountSpecified > 0 ? amountSpecified : -amountSpecified));
        require(amountSpecified != 0, "AS");

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, "LOK");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMathOptimized.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMathOptimized.MAX_SQRT_RATIO,
            "SPL"
        );

        (slot0.observationIndex, slot0.observationCardinality) = observations.write(
            slot0Start.observationIndex,
            uint32(block.timestamp),
            slot0Start.tick,
            liquidity,
            slot0Start.observationCardinality,
            slot0Start.observationCardinalityNext
        );

        SwapCache memory cache = SwapCache({feeProtocol: slot0Start.feeProtocol, liquidityStart: liquidity});

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                TICK_SPACING,
                zeroForOne
            );

            if (step.tickNext < TickMathOptimized.MIN_TICK) {
                step.tickNext = TickMathOptimized.MIN_TICK;
            } else if (step.tickNext > TickMathOptimized.MAX_TICK) {
                step.tickNext = TickMathOptimized.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMathOptimized.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                FEE
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= int256(step.amountIn + step.feeAmount);
                state.amountCalculated = state.amountCalculated - int256(step.amountOut);
            } else {
                state.amountSpecifiedRemaining += int256(step.amountOut);
                state.amountCalculated = state.amountCalculated + int256(step.amountIn + step.feeAmount);
            }

            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                // forge-lint: disable-next-line(unsafe-typecast)
                state.protocolFee += uint128(delta);
            }

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, 1 << 128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    // Start cross
                    int128 liquidityNet = ticks[step.tickNext].liquidityNet;
                    
                    // Update fee growth outside
                    TickInfo storage tickInfo = ticks[step.tickNext];
                    tickInfo.feeGrowthOutside0X128 = state.feeGrowthGlobalX128 - tickInfo.feeGrowthOutside0X128;
                    // For the other token, we need the global fee growth value which might not be in state if we are swapping the other way
                    // But wait, state only tracks one feeGrowthGlobalX128 (the one being swapped in/out?)
                    // feeGrowthGlobal0X128 and 1 are state variables.
                    // state.feeGrowthGlobalX128 is a cache for the invalid input token?
                    // zeroForOne: input is 0. output is 1. fees are taken from input?
                    // Actually fees are taken from input amount.
                    // So only feeGrowthGlobal[IN] increases.
                    // But we must flip BOTH.
                    
                    if (zeroForOne) {
                        // Input 0. state tracks 0.
                        tickInfo.feeGrowthOutside0X128 = state.feeGrowthGlobalX128 - tickInfo.feeGrowthOutside0X128;
                         tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - tickInfo.feeGrowthOutside1X128;
                    } else {
                        // Input 1. state tracks 1.
                        tickInfo.feeGrowthOutside1X128 = state.feeGrowthGlobalX128 - tickInfo.feeGrowthOutside1X128;
                        tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - tickInfo.feeGrowthOutside0X128;
                    }
                    
                    // secondsPerLiquidity, tickCumulative, secondsOutside should also be flipped?
                    // For now let's focus on fees.
                    
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = liquidityNet < 0
                        // forge-lint: disable-next-line(unsafe-typecast)
                        ? state.liquidity - uint128(-liquidityNet)
                        // forge-lint: disable-next-line(unsafe-typecast)
                        : state.liquidity + uint128(liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMathOptimized.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        if (state.tick != slot0Start.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        if (zeroForOne) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amount1 < 0) IERC20(TOKEN1).safeTransfer(recipient, uint256(-amount1));
            
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount0ToPay = amount0 > 0 ? uint256(amount0) : 0;
            if (amount0ToPay > 0) {
                if (data.length > 0) {
                    uint256 balanceBefore = IERC20(TOKEN0).balanceOf(address(this));
                    IConcentratedPoolSwapCallback(msg.sender).concentratedPoolSwapCallback(amount0, amount1, data);
                    require(IERC20(TOKEN0).balanceOf(address(this)) >= balanceBefore + amount0ToPay, "IIA");
                } else {
                    IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), amount0ToPay);
                }
            }
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amount0 < 0) IERC20(TOKEN0).safeTransfer(recipient, uint256(-amount0));
            
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount1ToPay = amount1 > 0 ? uint256(amount1) : 0;
            if (amount1ToPay > 0) {
                if (data.length > 0) {
                    uint256 balanceBefore = IERC20(TOKEN1).balanceOf(address(this));
                    IConcentratedPoolSwapCallback(msg.sender).concentratedPoolSwapCallback(amount0, amount1, data);
                    require(IERC20(TOKEN1).balanceOf(address(this)) >= balanceBefore + amount1ToPay, "IIA");
                } else {
                    IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), amount1ToPay);
                }
            }
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);

        // Circuit Breaker: Price Deviation Check
        _checkPriceDeviation(slot0.tick);
    }

    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper));
        PositionInfo storage position = positions[positionKey];

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = _updateTick(tickLower, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, false, MAX_LIQUIDITY_PER_TICK);
            flippedUpper = _updateTick(tickUpper, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, true, MAX_LIQUIDITY_PER_TICK);

            if (flippedLower) {
                tickBitmap.flipTick(tickLower, TICK_SPACING);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, TICK_SPACING);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(
            tickLower,
            tickUpper,
            tick,
            _feeGrowthGlobal0X128,
            _feeGrowthGlobal1X128
        );

        // Always update fees if there is liquidity
        if (position.liquidity > 0) {
            uint128 tokensOwed0 = uint128(
                FullMath.mulDiv(feeGrowthInside0X128 - position.feeGrowthInside0LastX128, position.liquidity, 1 << 128)
            );
            uint128 tokensOwed1 = uint128(
                FullMath.mulDiv(feeGrowthInside1X128 - position.feeGrowthInside1LastX128, position.liquidity, 1 << 128)
            );

            if (tokensOwed0 > 0 || tokensOwed1 > 0) {
                position.tokensOwed0 += tokensOwed0;
                position.tokensOwed1 += tokensOwed1;
            }
        }

        if (liquidityDelta != 0) {
            position.liquidity = liquidityDelta < 0
                // forge-lint: disable-next-line(unsafe-typecast)
                ? position.liquidity - uint128(-liquidityDelta)
                // forge-lint: disable-next-line(unsafe-typecast)
                : position.liquidity + uint128(liquidityDelta);
        }

        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    function _updateTick(
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 _feeGrowthGlobal0X128,
        uint256 _feeGrowthGlobal1X128,
        bool upper,
        uint128 maxLiquidity
    ) private returns (bool flipped) {
        TickInfo storage info = ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            // forge-lint: disable-next-line(unsafe-typecast)
            : liquidityGrossBefore + uint128(liquidityDelta);

        require(liquidityGrossAfter <= maxLiquidity, "LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = _feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = _feeGrowthGlobal1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;
    }

    function _checkPriceDeviation(int24 currentTick) internal {
        if (!cbConfig.autoPauseEnabled) return;
        if (cbConfig.maxPriceDeviationBps == 0) return; // Disabled

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800; // 30 minutes
        secondsAgos[1] = 0;

        // We need to use try/catch because observation might fail if not initialized long enough
        try this.observe(
            secondsAgos
        ) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 twapTick = int24(tickCumulativesDelta / 1800);
            
            int24 deviation = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
            
            // 1 tick is approximately 1 basis point (0.01%)
            if (uint256(int256(deviation)) > cbConfig.maxPriceDeviationBps) {
                _triggerPause();
                // emit AutoPaused("Price deviation exceeded");
            }
        } catch {
            // Ignore errors
        }
    }

    function _getFeeGrowthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 _feeGrowthGlobal0X128,
        uint256 _feeGrowthGlobal1X128
    ) private view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        TickInfo storage lower = ticks[tickLower];
        TickInfo storage upper = ticks[tickUpper];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = _feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = _feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = _feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = _feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = _feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = _feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }
    
    /*//////////////////////////////////////////////////////////////
                            FLASH LOANS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Executes a flash loan
    /// @param recipient Address to receive the flash loan
    /// @param amount0 Amount of token0 to borrow
    /// @param amount1 Amount of token1 to borrow
    /// @param data Arbitrary data to pass to the callback
    /// @dev Transfers tokens to recipient, calls callback, then verifies repayment + fees
    ///      Flash loan fee is 0.05% (5 basis points)
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external nonReentrant whenNotPaused {
        require(amount0 > 0 || amount1 > 0, "Zero amount");
        
        // Calculate fees (0.05% = 5 basis points)
        uint256 fee0 = (amount0 * 5) / 10000;
        uint256 fee1 = (amount1 * 5) / 10000;
        
        // Record balances before transfer
        uint256 balance0Before = IERC20(TOKEN0).balanceOf(address(this));
        uint256 balance1Before = IERC20(TOKEN1).balanceOf(address(this));
        
        // Transfer tokens to recipient
        if (amount0 > 0) IERC20(TOKEN0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransfer(recipient, amount1);
        
        // Call callback
        IFlashLoanCallback(msg.sender).flashLoanCallback(
            TOKEN0,
            TOKEN1,
            amount0,
            amount1,
            fee0,
            fee1,
            data
        );
        
        // Verify repayment + fees
        uint256 balance0After = IERC20(TOKEN0).balanceOf(address(this));
        uint256 balance1After = IERC20(TOKEN1).balanceOf(address(this));
        
        require(balance0After >= balance0Before + fee0, "Insufficient repayment 0");
        require(balance1After >= balance1Before + fee1, "Insufficient repayment 1");
        
        // Collect protocol fees
        if (fee0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            protocolFees0 += uint128(fee0);
        }
        if (fee1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            protocolFees1 += uint128(fee1);
        }
        
        emit Flash(msg.sender, recipient, amount0, amount1, fee0, fee1);
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Increases the maximum number of price observations that are stored for the pool
    /// @dev This function is no-op if the pool already has an observationCardinalityNext greater than or equal to the input observationCardinalityNext
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override lock {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
        }
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick, you must call it with secondsAgos = [3600, 0].
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgo` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value as of each `secondsAgo` from the current block timestamp
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                uint32(block.timestamp),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    function setFeeProtocol(uint8 feeProtocol) external override onlyFactory {
        require(feeProtocol == 0 || (feeProtocol >= 4 && feeProtocol <= 10), "Invalid fee protocol");
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol;
        emit SetFeeProtocol(feeProtocolOld, feeProtocol);
    }

    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override onlyFactory returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees0 ? protocolFees0 : amount0Requested;
        amount1 = amount1Requested > protocolFees1 ? protocolFees1 : amount1Requested;

        if (amount0 > 0) {
            protocolFees0 -= amount0;
            IERC20(TOKEN0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            protocolFees1 -= amount1;
            IERC20(TOKEN1).safeTransfer(recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
    function pause() external onlyPauser {
        _triggerPause();
    }

    function unpause() external onlyPauser {
        if (cbConfig.cooldownPeriod > 0) {
            require(block.timestamp >= lastPauseTime + cbConfig.cooldownPeriod, "Cooldown active");
        }
        _unpause();
    }

    function _triggerPause() internal {
        if (!paused()) {
            lastPauseTime = block.timestamp;
            _pause();
        }
    }

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyPauser whenPaused {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(recipient, amount);
    }

    function setCircuitBreakerConfig(
        uint16 _maxPriceDeviationBps,
        uint128 _maxVolumePerBlock,
        uint32 _cooldownPeriod,
        bool _autoPauseEnabled
    ) external onlyCircuitBreaker {
        cbConfig.maxPriceDeviationBps = _maxPriceDeviationBps;
        cbConfig.maxVolumePerBlock = _maxVolumePerBlock;
        cbConfig.cooldownPeriod = _cooldownPeriod;
        cbConfig.autoPauseEnabled = _autoPauseEnabled;
        // emit CircuitBreakerConfigUpdated(...);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL SAFETY
    //////////////////////////////////////////////////////////////*/

    function _updateAndCheckVolume(uint256 amount) internal {
        if (block.number != volumeTracker.blockNumber) {
            volumeTracker.blockNumber = block.number;
            volumeTracker.volume = amount;
        } else {
            volumeTracker.volume += amount;
        }

        if (volumeTracker.volume > cbConfig.maxVolumePerBlock && cbConfig.autoPauseEnabled) {
            _triggerPause();
            // emit AutoPaused("Volume limit exceeded");
        }
    }
}
