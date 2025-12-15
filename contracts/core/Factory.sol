// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ConcentratedPool} from "./ConcentratedPool.sol";
import {BatchAuction} from "./BatchAuction.sol";

contract Factory is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
    mapping(address => mapping(address => address)) public getAuction;

    event Debug(string message, uint256 val); // Temporary debug
    event PoolCreated(address indexed token0, address indexed token1, uint24 fee, int24 tickSpacing, address pool);
    event AuctionCreated(address indexed token0, address indexed token1, address auction);
    event ImplementationSet(bytes32 indexed contractType, address indexed implementation);

    address public concentratedPoolImplementation;
    address public batchAuctionImplementation;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        _transferOwnership(_owner);
    }

    function setImplementation(bytes32 contractType, address implementation) external onlyOwner {
        require(implementation != address(0), "ZI");
        if (contractType == keccak256("ConcentratedPool")) {
            concentratedPoolImplementation = implementation;
        } else if (contractType == keccak256("BatchAuction")) {
            batchAuctionImplementation = implementation;
        } else {
            revert("Invalid type");
        }
        emit ImplementationSet(contractType, implementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool) {
        require(tokenA != tokenB, "IA");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZA");
        require(getPool[token0][token1][fee] == address(0), "PE");

        // forge-lint: disable-next-line(unsafe-typecast)
        int24 tickSpacing = int24(fee) / 50; // Simplified tick spacing logic: 500 fee -> 10 tick spacing
        
        // forge-lint: disable-next-line(asm-keccak256)
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, fee));
        
        require(concentratedPoolImplementation != address(0), "No Impl");
        
        bytes memory initData = abi.encodeWithSelector(
            ConcentratedPool.initialize.selector, 
            address(this), 
            token0, 
            token1, 
            fee, 
            tickSpacing
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(concentratedPoolImplementation, initData);
        pool = address(proxy);
        
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
        
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    function createAuction(
        address tokenA,
        address tokenB
    ) external returns (address auction) {
        require(tokenA != tokenB, "IA");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZA");
        require(getAuction[token0][token1] == address(0), "AE");

        // forge-lint: disable-next-line(asm-keccak256)
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, "AUCTION"));
        
        require(batchAuctionImplementation != address(0), "No Impl");

        bytes memory initData = abi.encodeWithSelector(
            BatchAuction.initialize.selector,
            token0,
            token1,
            10, // batchDuration: 10 blocks
            1e15, // minOrderSize: 0.001 tokens
            1000, // maxPriceDeviationBps: 10%
            30 // feeBps: 0.3%
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(batchAuctionImplementation, initData);
        auction = address(proxy);
        
        getAuction[token0][token1] = auction;
        getAuction[token1][token0] = auction;
        
        emit AuctionCreated(token0, token1, auction);
    }
}
