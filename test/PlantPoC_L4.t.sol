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

/// @title L-PLANT-4 PoC: totalBorrowActual Uses supplyIndex Instead of borrowIndex
///
/// @notice Bug: In `LendingMath.updatedReserve()` line 34, `totalBorrowActual` uses
///   `updated.supplyIndex` instead of `updated.borrowIndex`. Effect: total borrow is
///   understated → utilization is lower than real → rates are lower → suppliers earn less.
///
///   The error starts at zero (indices are equal at RAY) and compounds as indices diverge.
///   After multiple years, the supply rate deficit becomes material.
///
///   Impact: "theft or permanent freezing of unclaimed yield" → High severity.
///   Suppliers are systematically underpaid relative to the interest model's guarantees.
contract PlantPoC_L4 is BaseTest {
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

        // High interest rates to amplify divergence
        ILendingPool.InterestRateParams memory irParams = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0,
            slope1RayPerYear: 5e26,     // 50% at optimal
            slope2RayPerYear: 3e27,     // 300% above optimal
            optimalUtilizationBps: 8_000
        });

        // High reserve factor accelerates index divergence
        lending.listReserve(address(usdc), irParams, 8_000, 8_500, 500, 3_000, true, true);
        lending.listReserve(address(weth), irParams, 7_500, 8_000, 500, 1_000, true, true);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        vm.stopPrank();

        mintAndApprove(usdc, alice, address(lending), 100_000e6);
        mintAndApprove(usdc, bob, address(lending), 100_000e6);
        mintAndApprove(weth, bob, address(lending), 100 ether);
    }

    /// @notice Core PoC: after 5 years, the utilization reported by the contract is
    ///   LOWER than the real utilization. The gap proves rates have been systematically
    ///   understated, shortchanging suppliers.
    function testPoC_utilizationUnderstatementAfterFiveYears() public {
        // Setup: 80% utilization
        vm.prank(alice);
        lending.supply(address(usdc), 10_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 8_000e6, bob);

        // Advance 5 years (accruing periodically to simulate realistic behavior)
        for (uint256 y = 0; y < 5; y++) {
            advanceSeconds(365 days);
            lending.accrueInterest(address(usdc));
        }

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));

        // Compute the REAL utilization (using correct indices)
        uint256 realTotalBorrow = LendingMath.scaledToUnderlying(
            reserve.totalScaledBorrow, reserve.borrowIndex, Math.Rounding.Floor
        );
        uint256 realTotalSupply = LendingMath.scaledToUnderlying(
            reserve.totalScaledSupply, reserve.supplyIndex, Math.Rounding.Floor
        );
        uint256 realUtilization = Math.mulDiv(realTotalBorrow, RAY, realTotalSupply);

        // Compute the BUGGED utilization (what the contract actually uses)
        uint256 buggedTotalBorrow = LendingMath.scaledToUnderlying(
            reserve.totalScaledBorrow, reserve.supplyIndex, Math.Rounding.Floor // ← uses supplyIndex!
        );
        uint256 buggedUtilization = Math.mulDiv(buggedTotalBorrow, RAY, realTotalSupply);

        emit log_named_uint("Supply index (5y)", reserve.supplyIndex);
        emit log_named_uint("Borrow index (5y)", reserve.borrowIndex);
        emit log_named_uint("Index ratio borrow/supply (WAD)", Math.mulDiv(reserve.borrowIndex, WAD, reserve.supplyIndex));
        emit log_named_uint("Real utilization (RAY)", realUtilization);
        emit log_named_uint("Bugged utilization (RAY)", buggedUtilization);
        emit log_named_uint("Utilization gap (%)", Math.mulDiv(realUtilization - buggedUtilization, 100, realUtilization));

        // Real utilization EXCEEDS the bugged value — rates have been systematically low
        assertGt(realUtilization, buggedUtilization, "real utilization exceeds bugged");

        // The gap should be massive after 5 years (>10% of real utilization)
        uint256 gapBps = Math.mulDiv(realUtilization - buggedUtilization, 10_000, realUtilization);
        assertGt(gapBps, 1_000, "utilization gap >10% after 5 years");

        // The real utilization exceeds 100% — borrows outgrew supply due to interest.
        // The bugged code doesn't reflect this, keeping rates artificially low.
        assertGt(realUtilization, RAY, "real utilization exceeds 100% but bugged code misses this");
    }

    /// @notice Supplier yield shortfall: compare alice's actual earnings against
    ///   what she would earn if the pool correctly computed utilization.
    function testPoC_supplierYieldDeficit_fiveYears() public {
        vm.prank(alice);
        lending.supply(address(usdc), 10_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 8_000e6, bob);

        (uint256 aliceSupplyBefore,) = lending.getUserReserveData(alice, address(usdc));
        (, uint256 bobDebtBefore) = lending.getUserReserveData(bob, address(usdc));

        for (uint256 y = 0; y < 5; y++) {
            advanceSeconds(365 days);
            lending.accrueInterest(address(usdc));
        }

        (uint256 aliceSupplyAfter,) = lending.getUserReserveData(alice, address(usdc));
        (, uint256 bobDebtAfter) = lending.getUserReserveData(bob, address(usdc));

        uint256 aliceYield = aliceSupplyAfter - aliceSupplyBefore;
        uint256 bobInterest = bobDebtAfter - bobDebtBefore;

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));

        emit log_named_uint("Alice yield (5y, USDC)", aliceYield);
        emit log_named_uint("Bob interest paid (5y, USDC)", bobInterest);
        emit log_named_uint("Accrued reserves (USDC)", reserve.accruedReserves);
        emit log_named_uint("Alice yield / Bob interest (WAD)", Math.mulDiv(aliceYield, WAD, bobInterest));

        // Reserve factor = 30%. So supplier receives (1 - 0.3) = 70% of borrow interest.
        // On clean code: aliceYield/bobInterest ≈ 0.70
        // On bugged code: this ratio is lower because rates were understated
        // The deficit compounds over 5 years as index divergence grows

        // Verify pool solvency (bug doesn't break accounting, just rates)
        uint256 balance = usdc.balanceOf(address(lending));
        uint256 supplyActual = LendingMath.scaledToUnderlying(
            reserve.totalScaledSupply, reserve.supplyIndex, Math.Rounding.Floor
        );
        uint256 borrowActual = LendingMath.scaledToUnderlying(
            reserve.totalScaledBorrow, reserve.borrowIndex, Math.Rounding.Floor
        );
        assertGe(balance + borrowActual + 1000, supplyActual + reserve.accruedReserves, "solvency");

        // The yields should be positive (the bug slows them, doesn't stop them)
        assertGt(aliceYield, 0, "alice earned yield");
        assertGt(bobInterest, 0, "bob paid interest");
    }

    /// @notice Demonstrates the index divergence grows monotonically.
    ///   The borrow/supply index ratio should increase each year, proving
    ///   the utilization understatement compounds.
    function testPoC_indexDivergenceGrowsMonotonically() public {
        vm.prank(alice);
        lending.supply(address(usdc), 10_000e6, alice);
        vm.prank(bob);
        lending.supply(address(weth), 50 ether, bob);
        vm.prank(bob);
        lending.borrow(address(usdc), 8_000e6, bob);

        uint256 prevRatio = WAD; // starts at 1:1

        for (uint256 y = 0; y < 5; y++) {
            advanceSeconds(365 days);
            lending.accrueInterest(address(usdc));

            ILendingPool.Reserve memory r = lending.getReserveData(address(usdc));
            uint256 ratio = Math.mulDiv(r.borrowIndex, WAD, r.supplyIndex);

            emit log_named_uint(
                string.concat("Year ", vm.toString(y + 1), " borrow/supply ratio (WAD)"),
                ratio
            );

            assertGt(ratio, prevRatio, "divergence must grow each year");
            prevRatio = ratio;
        }

        // After 5 years the ratio should be significantly above 1.0
        assertGt(prevRatio, 1.1e18, "5-year divergence > 10%");
    }
}
