// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {TestHelper} from "./TestHelper.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {IFlashLoanCallback} from "../contracts/interfaces/IFlashLoanCallback.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract FlashLoanTest is TestHelper {
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    address user = address(0x1);
    
    function setUp() public {
        token0 = new MockToken("Token0", "TK0");
        token1 = new MockToken("Token1", "TK1");
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        deployFactory();
        
        pool = createPool(address(token0), address(token1), 3000);
        
        pool.initializeState(79228162514264337593543950336); // 1:1 price
        
        // Add liquidity
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        
        pool.mint(address(this), -887220, 887220, 100 ether, "");
    }
    
    function testFlashLoan_Success() public {
        FlashBorrower borrower = new FlashBorrower(address(pool), address(token0), address(token1));
        
        uint256 amount0 = 10 ether;
        uint256 amount1 = 5 ether;
        
        // Mint tokens to borrower for fee payment
        uint256 fee0 = (amount0 * 5) / 10000; // 0.05%
        uint256 fee1 = (amount1 * 5) / 10000;
        token0.mint(address(borrower), fee0);
        token1.mint(address(borrower), fee1);
        
        uint128 protocolFees0Before = pool.protocolFees0();
        uint128 protocolFees1Before = pool.protocolFees1();
        
        borrower.executeFlashLoan(amount0, amount1);
        
        uint128 protocolFees0After = pool.protocolFees0();
        uint128 protocolFees1After = pool.protocolFees1();
        
        assertEq(protocolFees0After - protocolFees0Before, fee0, "Protocol fee0 should increase");
        assertEq(protocolFees1After - protocolFees1Before, fee1, "Protocol fee1 should increase");
    }
    
    function testFlashLoan_SingleToken() public {
        FlashBorrower borrower = new FlashBorrower(address(pool), address(token0), address(token1));
        
        uint256 amount0 = 10 ether;
        uint256 fee0 = (amount0 * 5) / 10000;
        token0.mint(address(borrower), fee0);
        
        borrower.executeFlashLoan(amount0, 0);
        
        assertTrue(true, "Flash loan with single token should succeed");
    }
    
    function testFlashLoan_InsufficientRepayment() public {
        MaliciousBorrower borrower = new MaliciousBorrower(address(pool), address(token0), address(token1));
        
        uint256 amount0 = 10 ether;
        
        vm.expectRevert("Insufficient repayment 0");
        borrower.executeFlashLoan(amount0, 0);
    }
    
    function testFlashLoan_CallbackFailure() public {
        FailingBorrower borrower = new FailingBorrower(address(pool));
        
        vm.expectRevert("Callback failed");
        borrower.executeFlashLoan(1 ether, 0);
    }
    
    function testFlashLoan_Reentrancy() public {
        ReentrantBorrower borrower = new ReentrantBorrower(address(pool), address(token0), address(token1));
        
        uint256 amount0 = 1 ether;
        uint256 fee0 = (amount0 * 5) / 10000;
        token0.mint(address(borrower), fee0 * 2); // Extra for reentrancy attempt
        
        vm.expectRevert(); // Should revert due to reentrancy guard
        borrower.executeFlashLoan(amount0, 0);
    }
    
    function testFlashLoan_ZeroAmount() public {
        FlashBorrower borrower = new FlashBorrower(address(pool), address(token0), address(token1));
        
        vm.expectRevert("Zero amount");
        borrower.executeFlashLoan(0, 0);
    }
    
    function testFlashLoan_FeeAccrual() public {
        FlashBorrower borrower = new FlashBorrower(address(pool), address(token0), address(token1));
        
        uint256 amount0 = 10 ether;
        uint256 amount1 = 5 ether;
        uint256 fee0 = (amount0 * 5) / 10000;
        uint256 fee1 = (amount1 * 5) / 10000;
        
        // Mint enough tokens for both flash loans
        token0.mint(address(borrower), fee0 * 2);
        token1.mint(address(borrower), fee1 * 2);
        
        // Execute first flash loan
        borrower.executeFlashLoan(amount0, amount1);
        
        // Execute second flash loan
        borrower.executeFlashLoan(amount0, amount1);
        
        uint128 totalFees0 = pool.protocolFees0();
        uint128 totalFees1 = pool.protocolFees1();
        
        assertEq(totalFees0, fee0 * 2, "Protocol fees should accumulate");
        assertEq(totalFees1, fee1 * 2, "Protocol fees should accumulate");
    }
}

// Helper contract that properly repays flash loan
contract FlashBorrower is IFlashLoanCallback {
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    constructor(address _pool, address _token0, address _token1) {
        pool = ConcentratedPool(_pool);
        token0 = MockToken(_token0);
        token1 = MockToken(_token1);
    }
    
    function executeFlashLoan(uint256 amount0, uint256 amount1) external {
        pool.flash(address(this), amount0, amount1, "");
    }
    
    function flashLoanCallback(
        address /* _token0 */,
        address /* _token1 */,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(msg.sender == address(pool), "Only pool");
        
        // Transfer borrowed amount + fees back to pool
        if (amount0 > 0) {
            token0.transfer(address(pool), amount0 + fee0);
        }
        if (amount1 > 0) {
            token1.transfer(address(pool), amount1 + fee1);
        }
    }
}

// Malicious borrower that doesn't repay
contract MaliciousBorrower is IFlashLoanCallback {
    ConcentratedPool pool;
    
    constructor(address _pool, address /* _token0 */, address /* _token1 */) {
        pool = ConcentratedPool(_pool);
    }
    
    function executeFlashLoan(uint256 amount0, uint256 amount1) external {
        pool.flash(address(this), amount0, amount1, "");
    }
    
    function flashLoanCallback(
        address /* token0 */,
        address /* token1 */,
        uint256 /* amount0 */,
        uint256 /* amount1 */,
        uint256 /* fee0 */,
        uint256 /* fee1 */,
        bytes calldata /* data */
    ) external pure override {
        // Don't repay - malicious
    }
}

// Borrower that reverts in callback
contract FailingBorrower is IFlashLoanCallback {
    ConcentratedPool pool;
    
    constructor(address _pool) {
        pool = ConcentratedPool(_pool);
    }
    
    function executeFlashLoan(uint256 amount0, uint256 amount1) external {
        pool.flash(address(this), amount0, amount1, "");
    }
    
    function flashLoanCallback(
        address /* token0 */,
        address /* token1 */,
        uint256 /* amount0 */,
        uint256 /* amount1 */,
        uint256 /* fee0 */,
        uint256 /* fee1 */,
        bytes calldata /* data */
    ) external pure override {
        revert("Callback failed");
    }
}

// Borrower that attempts reentrancy
contract ReentrantBorrower is IFlashLoanCallback {
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    bool reentered;
    
    constructor(address _pool, address _token0, address _token1) {
        pool = ConcentratedPool(_pool);
        token0 = MockToken(_token0);
        token1 = MockToken(_token1);
    }
    
    function executeFlashLoan(uint256 amount0, uint256 amount1) external {
        pool.flash(address(this), amount0, amount1, "");
    }
    
    function flashLoanCallback(
        address /* _token0 */,
        address /* _token1 */,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata /* data */
    ) external override {
        require(msg.sender == address(pool), "Only pool");
        
        if (!reentered) {
            reentered = true;
            // Attempt reentrancy
            pool.flash(address(this), 1 ether, 0, "");
        }
        
        // Transfer repayment
        if (amount0 > 0) {
            token0.transfer(address(pool), amount0 + fee0);
        }
        if (amount1 > 0) {
            token1.transfer(address(pool), amount1 + fee1);
        }
    }
}
