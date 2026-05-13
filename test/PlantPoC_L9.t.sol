// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "./helpers/BaseTest.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {Lending} from "src/Lending/Lending.sol";
import {LendingMath} from "src/Lending/LendingMath.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {ILendingPool} from "src/interfaces/ILendingPool.sol";

/// @title L-PLANT-9 PoC: Reserve Subtraction Freezes User Liquidity
/// @notice `_availableLiquidity` was "fixed" to subtract accrued reserves from
///   the pool balance. This makes reserves unavailable for borrowing or
///   withdrawal, progressively freezing user funds as reserves accrue.
contract PlantPoC_L9 is BaseTest {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Lending internal lending;
    PriceOracle internal oracle;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        weth = deployMockToken("WETH", 18);

        vm.startPrank(owner);
        oracle = new PriceOracle();
        lending = new Lending(IPriceOracle(address(oracle)), 5_000);

        ILendingPool.InterestRateParams memory irParams = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 1e26,
            slope1RayPerYear: 4e26,
            slope2RayPerYear: 3e27,
            optimalUtilizationBps: 8_000
        });

        // 30% reserve factor — aggressive but within allowed range
        lending.listReserve(address(usdc), irParams, 8_000, 8_500, 500, 3_000, true, true);
        lending.listReserve(address(weth), irParams, 7_500, 8_000, 500, 1_000, true, true);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        vm.stopPrank();

        mintAndApprove(usdc, alice, address(lending), 1_000_000e6);
        mintAndApprove(usdc, bob, address(lending), 1_000_000e6);
        mintAndApprove(weth, bob, address(lending), 1_000 ether);
        mintAndApprove(weth, charlie, address(lending), 1_000 ether);
    }

    function _refreshOracle() internal {
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: After interest accrual, borrowing is restricted
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L9_reservesReduceBorrowableLiquidity() public {
        // Alice supplies 100k USDC
        vm.prank(alice);
        lending.supply(address(usdc), 100_000e6, alice);

        // Bob supplies ETH collateral
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);

        // Bob borrows 60k USDC (60% utilization)
        vm.prank(bob);
        lending.borrow(address(usdc), 60_000e6, bob);

        // Before interest: pool has 40k USDC, 0 reserves
        uint256 balanceBefore = usdc.balanceOf(address(lending));
        assertEq(balanceBefore, 40_000e6, "40k USDC available before interest");

        // Accrue 180 days of interest
        advanceSeconds(180 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        uint256 balanceAfter = usdc.balanceOf(address(lending));

        emit log_named_uint("Pool balance (USDC)", balanceAfter);
        emit log_named_uint("Accrued reserves (USDC)", reserve.accruedReserves);

        // Balance hasn't changed (no deposits/withdrawals), but reserves accrued
        assertEq(balanceAfter, balanceBefore, "balance unchanged");
        assertGt(reserve.accruedReserves, 0, "reserves accrued");

        // BUG: available liquidity = balance - reserves < balance
        // Charlie tries to borrow using the "full" available liquidity
        vm.prank(charlie);
        lending.supply(address(weth), 100 ether, charlie);

        // Charlie should be able to borrow up to ~40k (pool balance)
        // But with the bug, available = 40k - reserves < 40k
        // Try to borrow exactly the pool balance
        uint256 maxBorrow = balanceAfter;
        vm.prank(charlie);
        vm.expectRevert(); // InsufficientLiquidity — reserves reduced available
        lending.borrow(address(usdc), maxBorrow, charlie);

        // Charlie can only borrow balance - reserves
        uint256 reducedMax = balanceAfter - reserve.accruedReserves;
        vm.prank(charlie);
        lending.borrow(address(usdc), reducedMax, charlie);

        emit log_named_uint("Max borrow without bug", maxBorrow);
        emit log_named_uint("Max borrow with bug", reducedMax);
        emit log_named_uint("Frozen liquidity (USDC)", maxBorrow - reducedMax);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: Supplier can't withdraw full balance
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L9_supplierWithdrawalPartiallyBlocked() public {
        vm.prank(alice);
        lending.supply(address(usdc), 100_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 50_000e6, bob);

        // 1 year of interest accrual
        advanceSeconds(365 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        uint256 poolBalance = usdc.balanceOf(address(lending));

        emit log_named_uint("Pool balance", poolBalance);
        emit log_named_uint("Accrued reserves", reserve.accruedReserves);

        // Alice's supply balance (with interest)
        (uint256 aliceSupply,) = lending.getUserReserveData(alice, address(usdc));
        emit log_named_uint("Alice supply balance", aliceSupply);

        // How much can Alice actually withdraw?
        // Without bug: min(aliceSupply, poolBalance) = poolBalance (50k)
        // With bug: min(aliceSupply, poolBalance - reserves) = poolBalance - reserves
        uint256 availableWithBug = poolBalance > reserve.accruedReserves
            ? poolBalance - reserve.accruedReserves
            : 0;

        emit log_named_uint("Available to withdraw (with bug)", availableWithBug);
        emit log_named_uint("Frozen from Alice (USDC)", poolBalance - availableWithBug);

        // Alice tries to withdraw full pool balance — should work without bug
        // With bug: reverts because reserves reduce available liquidity
        if (reserve.accruedReserves > 0 && poolBalance > availableWithBug) {
            vm.prank(alice);
            vm.expectRevert(); // InsufficientLiquidity
            lending.withdraw(address(usdc), poolBalance, alice);

            // Alice can only get the reduced amount
            vm.prank(alice);
            lending.withdraw(address(usdc), availableWithBug, alice);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Reserve accumulation progressively freezes more funds
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L9_progressiveFreezing() public {
        vm.prank(alice);
        lending.supply(address(usdc), 100_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 100 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 70_000e6, bob);

        uint256 poolBalance = usdc.balanceOf(address(lending)); // 30k

        // Check frozen amount at 3 time points
        uint256 prevFrozen;
        for (uint256 i = 1; i <= 3; i++) {
            advanceSeconds(120 days);
            lending.accrueInterest(address(usdc));
            _refreshOracle();

            ILendingPool.Reserve memory r = lending.getReserveData(address(usdc));
            uint256 frozen = r.accruedReserves < poolBalance ? r.accruedReserves : poolBalance;

            emit log_named_uint(
                string.concat("Period ", vm.toString(i), " frozen (USDC)"),
                frozen
            );

            // Frozen amount grows with each period
            assertGe(frozen, prevFrozen, "frozen amount must grow");
            prevFrozen = frozen;
        }

        // After ~1 year at 70% util with 30% reserve factor,
        // significant portion of idle liquidity is frozen
        assertGt(prevFrozen, 1_000e6, "material amount frozen (>$1000)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: Pool still operational for normal operations
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L9_poolRemainsOperational() public {
        vm.prank(alice);
        lending.supply(address(usdc), 100_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 50_000e6, bob);

        advanceSeconds(90 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        // Small operations still work
        vm.prank(alice);
        lending.withdraw(address(usdc), 1_000e6, alice);

        mintAndApprove(usdc, charlie, address(lending), 100_000e6);
        vm.prank(charlie);
        lending.supply(address(usdc), 10_000e6, charlie);

        // Repay still works
        mintAndApprove(usdc, bob, address(lending), 100_000e6);
        vm.prank(bob);
        lending.repay(address(usdc), 10_000e6, bob);

        advanceSeconds(30 days);
        lending.accrueInterest(address(usdc));
    }
}
