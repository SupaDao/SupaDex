// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IConcentratedPool {
    event Initialize(uint160 sqrtPriceX96, int24 tick);
    event Mint(address sender, address owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Collect(address owner, address recipient, int24 tickLower, int24 tickUpper, uint128 amount0, uint128 amount1);
    event Burn(address owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    event Flash(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );
    event SetFeeProtocol(uint8 feeProtocolOld, uint8 feeProtocolNew);
    event CollectProtocol(address indexed sender, address indexed recipient, uint128 amount0, uint128 amount1);

    function initializeState(uint160 sqrtPriceX96) external;

    function pause() external;
    function unpause() external;
    function emergencyWithdraw(address token, uint256 amount, address recipient) external;
    function setCircuitBreakerConfig(
        uint16 _maxPriceDeviationBps,
        uint128 _maxVolumePerBlock,
        uint32 _cooldownPeriod,
        bool _autoPauseEnabled
    ) external;

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function liquidity() external view returns (uint128);
    
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    function setFeeProtocol(uint8 feeProtocol) external;

    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    function TOKEN0() external view returns (address);
    function TOKEN1() external view returns (address);
}
