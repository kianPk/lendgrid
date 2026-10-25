// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {SimplePriceOracle} from "../src/Oracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract LendingPoolTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    SimplePriceOracle oracle;
    LendingPool pool;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new SimplePriceOracle(admin);

        vm.startPrank(admin);
        oracle.setPrice(address(weth), 3000e8); // $3000
        oracle.setPrice(address(usdc), 1e8); // $1
        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            admin,
            7500, // 75% LTV
            8000, // 80% liq threshold
            500 // 5% bonus
        );
        vm.stopPrank();

        // Seed borrow liquidity
        usdc.mint(admin, 10_000_000e6);
        vm.startPrank(admin);
        usdc.approve(address(pool), type(uint256).max);
        pool.seedLiquidity(5_000_000e6);
        vm.stopPrank();

        weth.mint(alice, 100e18);
        usdc.mint(bob, 1_000_000e6);
    }

    function test_depositBorrowRepay() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 10e18);
        pool.deposit(10e18); // $30,000 collateral

        uint256 borrowAmt = 15_000e6; // $15k < 75% of 30k
        pool.borrow(borrowAmt);
        assertEq(usdc.balanceOf(alice), borrowAmt);
        assertGt(pool.healthFactor(alice), 1e18);

        usdc.approve(address(pool), borrowAmt);
        pool.repay(borrowAmt);
        assertEq(pool.debtBalance(alice), 0);
        vm.stopPrank();
    }

    function test_cannotBorrowOverLTV() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 1e18);
        pool.deposit(1e18); // $3000 → max borrow $2250
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(2300e6);
        vm.stopPrank();
    }

    function test_liquidation() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 1e18);
        pool.deposit(1e18);
        pool.borrow(2200e6); // near max
        vm.stopPrank();

        // Crash ETH to $2000 → HF under 1
        vm.prank(admin);
        oracle.setPrice(address(weth), 2000e8);

        assertLt(pool.healthFactor(alice), 1e18);

        vm.startPrank(bob);
        usdc.approve(address(pool), 1000e6);
        uint256 bobWethBefore = weth.balanceOf(bob);
        pool.liquidate(alice, 1000e6);
        vm.stopPrank();

        assertGt(weth.balanceOf(bob), bobWethBefore);
        assertLt(pool.debtBalance(alice), 2200e6);
    }

    function test_withdrawKeepsHealthy() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 10e18);
        pool.deposit(10e18);
        pool.borrow(5_000e6);
        pool.withdraw(1e18);
        assertGt(pool.healthFactor(alice), 1e18);
        vm.stopPrank();
    }

    function test_fixedBorrowRatePerSecond() public {
        // ~10% APR equivalent: 1000 bps / year as WAD per second
        uint256 rateWad = (1000 * 1e18) / (uint256(10_000) * 365 days);
        vm.prank(admin);
        pool.setBorrowRateBpsPerSecond(rateWad);

        vm.startPrank(alice);
        weth.approve(address(pool), 10e18);
        pool.deposit(10e18);
        pool.borrow(10_000e6);
        vm.stopPrank();

        uint256 debtBefore = pool.debtBalance(alice);
        vm.warp(block.timestamp + 365 days);
        pool.accrue();

        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(alice, 10_000e6);
        pool.repay(1);
        vm.stopPrank();

        uint256 debtAfter = pool.debtBalance(alice);
        assertGt(debtAfter + 1, debtBefore);
        assertApproxEqAbs(debtAfter + 1, debtBefore + (debtBefore * 1000) / 10_000, 100e6);
    }

    function test_interestAccruesOverTime() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 10e18);
        pool.deposit(10e18);
        pool.borrow(10_000e6);
        vm.stopPrank();

        uint256 debtBefore = pool.debtBalance(alice);
        vm.warp(block.timestamp + 30 days);
        pool.accrue();
        // touch position to sync user index
        vm.startPrank(alice);
        usdc.approve(address(pool), 1);
        usdc.mint(alice, 1);
        pool.repay(1);
        vm.stopPrank();

        assertGt(pool.debtBalance(alice) + 1, debtBefore);
        assertGt(pool.borrowAprBps(), 0);
        assertGt(pool.utilizationBps(), 0);
    }
}
