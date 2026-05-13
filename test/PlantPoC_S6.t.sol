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
// Vulnerability: Penalty Overcharge on Boosted Amount
// Severity: Critical (direct theft of user principal)
// Contract: src/Staking/Staking.sol — emergencyUnstake()
//
// Root cause:
//   `emergencyUnstake` computes the early-exit penalty using `boostedAmount`
//   instead of `amount`. The penalty should be a percentage of the raw
//   principal, but is instead a percentage of the boost-scaled value.
//
//   For 1x boost tiers, boostedAmount == amount → no difference (all existing
//   tests use 1x boost for emergency unstake, making this bug invisible).
//
//   For 2x/3x tiers, the penalty is 2x/3x the intended amount. At maximum
//   penalty (50%) with 3x boost, penalty = 150% of principal → underflow
//   in `amount - penalty` → revert → temporary fund freeze until unlock.
//
// Impact:
//   - Critical: users in 2x/3x tiers lose 2x/3x the intended penalty (direct
//     theft of principal — user deposits 100, expects 90 back, gets 70/80)
//   - High: at extreme settings (3x + 50%), emergency exit reverts until
//     the lock period expires (temporary freezing of funds)
//   - Penalty mechanism punishes loyal (long-lock) stakers disproportionately
//   - Protocol violates its stated penalty rate guarantee
// ─────────────────────────────────────────────────────────────────────────────

contract PlantPoC_S6 is BaseTest {
    uint64 internal constant REWARD_DURATION = 30 days;
    uint128 internal constant DEFAULT_STAKE = 100 ether;
    uint256 internal constant DUST = 1_000;

    MockERC20 internal stakingToken;
    Staking internal staking;

    // Standard: 10% penalty
    Staking internal staking10;
    // Max: 50% penalty
    Staking internal staking50;

    uint8 internal tier30; // 1x boost, 30d lock
    uint8 internal tier60; // 2x boost, 60d lock
    uint8 internal tier90; // 3x boost, 90d lock

    uint8 internal tier30_50;
    uint8 internal tier60_50;
    uint8 internal tier90_50;

    address internal victim;

    function setUp() public override {
        super.setUp();
        victim = makeAddr("victim");

        stakingToken = deployMockToken("STK", 18);

        // 10% penalty staking
        vm.startPrank(owner);
        staking10 = new Staking(IERC20(address(stakingToken)), address(stakingToken), 1_000);
        tier30 = staking10.setLockTier(30 days, 10_000);  // 1x
        tier60 = staking10.setLockTier(60 days, 20_000);  // 2x
        tier90 = staking10.setLockTier(90 days, 30_000);  // 3x
        vm.stopPrank();

        // 50% penalty staking (max settings)
        vm.startPrank(owner);
        staking50 = new Staking(IERC20(address(stakingToken)), address(stakingToken), 5_000);
        tier30_50 = staking50.setLockTier(30 days, 10_000);
        tier60_50 = staking50.setLockTier(60 days, 20_000);
        tier90_50 = staking50.setLockTier(90 days, 30_000);
        vm.stopPrank();

        staking = staking10;

        mintAndApprove(stakingToken, victim, address(staking10), 100_000 ether);
        mintAndApprove(stakingToken, victim, address(staking50), 100_000 ether);
        mintAndApprove(stakingToken, alice, address(staking10), 100_000 ether);
        mintAndApprove(stakingToken, alice, address(staking50), 100_000 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: 1x boost — penalty is correct (regression check)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_tier1x_penaltyCorrect() public {
        vm.prank(alice);
        staking10.stake(DEFAULT_STAKE, tier30);

        uint256 balanceBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        staking10.emergencyUnstake(0);

        uint256 returned = stakingToken.balanceOf(alice) - balanceBefore;
        // 10% penalty on 100 ether = 10 ether penalty, 90 ether returned
        assertEq(returned, 90 ether, "1x tier: penalty correct at 10%");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: 2x boost — penalty doubles (20% instead of 10%)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_tier2x_penaltyDoubled() public {
        vm.prank(victim);
        staking10.stake(DEFAULT_STAKE, tier60); // 2x boost

        uint256 balanceBefore = stakingToken.balanceOf(victim);

        vm.prank(victim);
        staking10.emergencyUnstake(0);

        uint256 returned = stakingToken.balanceOf(victim) - balanceBefore;

        // Bug: penalty = boostedAmount * 10% = 200 ether * 10% = 20 ether
        // Correct: penalty = amount * 10% = 100 ether * 10% = 10 ether
        // Victim gets 80 ether instead of 90 ether (theft of 10 ether principal)
        assertEq(returned, 80 ether, "2x tier: penalty doubled to 20%");

        // The extra 10 ether went to the penalty pool (or queue)
        (,,,,,, uint256 queued) = staking10.rewardData(address(stakingToken));
        assertEq(queued, 20 ether, "penalty queue has inflated 20 ether");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: 3x boost — penalty triples (30% instead of 10%)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_tier3x_penaltyTripled() public {
        vm.prank(victim);
        staking10.stake(DEFAULT_STAKE, tier90); // 3x boost

        uint256 balanceBefore = stakingToken.balanceOf(victim);

        vm.prank(victim);
        staking10.emergencyUnstake(0);

        uint256 returned = stakingToken.balanceOf(victim) - balanceBefore;

        // Bug: penalty = 300 ether * 10% = 30 ether
        // Correct: penalty = 100 ether * 10% = 10 ether
        // Victim loses 30% instead of 10%
        assertEq(returned, 70 ether, "3x tier: penalty tripled to 30%");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: CRITICAL — 3x boost + 50% penalty → permanent freeze
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice With 3x boost and 50% penalty, penalty = 3 * amount * 50% = 150%
    ///   of principal. `amount - penalty` underflows → revert → emergency exit
    ///   bricked for the entire lock period. User must wait for normal unlock.
    ///   This is temporary freezing (High) — the Critical path is principal theft
    ///   in the 2x/3x scenarios above.
    function testPoC_S6_tier3x_maxPenalty_emergencyExitBricked() public {
        vm.prank(victim);
        staking50.stake(DEFAULT_STAKE, tier90_50);

        // Emergency unstake reverts due to arithmetic underflow
        // penalty = 300 ether * 50% = 150 ether > 100 ether (amount)
        // returnAmount = 100 - 150 = UNDERFLOW
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        staking50.emergencyUnstake(0);

        // Normal unstake also blocked (still within lock period)
        vm.prank(victim);
        vm.expectRevert();
        staking50.unstake(0);

        // Funds frozen during lock period
        assertEq(staking50.totalRawSupply(), DEFAULT_STAKE, "funds still locked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5: 2x boost + 50% penalty → user loses ALL principal
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_tier2x_maxPenalty_totalLoss() public {
        vm.prank(victim);
        staking50.stake(DEFAULT_STAKE, tier60_50);

        uint256 balanceBefore = stakingToken.balanceOf(victim);

        vm.prank(victim);
        staking50.emergencyUnstake(0);

        uint256 returned = stakingToken.balanceOf(victim) - balanceBefore;

        // Bug: penalty = 200 ether * 50% = 100 ether = entire principal!
        // returnAmount = 100 - 100 = 0
        assertEq(returned, 0, "2x tier + 50% penalty: total principal loss");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 6: Beneficiary staker profits from inflated penalties
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_beneficiaryProfitsFromInflatedPenalty() public {
        // Alice stakes as beneficiary (1x tier, unaffected)
        vm.prank(alice);
        staking10.stake(DEFAULT_STAKE, tier30);

        // Victim stakes in 3x tier
        vm.prank(victim);
        staking10.stake(DEFAULT_STAKE, tier90);

        // Victim emergency unstakes — pays 30% instead of 10%
        vm.prank(victim);
        staking10.emergencyUnstake(0);

        // Alice earns from the inflated penalty
        uint256 aliceEarned = staking10.earned(alice, address(stakingToken));

        // Bug: 30 ether distributed (penalty on boostedAmount)
        // Correct: only 10 ether should be distributed
        // Alice captures a share of the inflated penalty
        assertGt(aliceEarned, 10 ether, "alice profits from inflated penalty beyond correct 10 ether");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 7: Contract solvency maintained (bug is subtle, not crashy)
    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 7: S-PLANT-1 + S-PLANT-6 interaction — composable bugs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When user has 2 stakes (1x main + 3x sacrificial), emergency
    ///   unstake of the 3x stake triggers BOTH bugs:
    ///   - S-PLANT-6: penalty is 3x the intended amount (30% vs 10%)
    ///   - S-PLANT-1: user self-captures proportional share of inflated penalty
    ///   Net: user loses 30% of sacrificial stake but recovers a portion
    ///   via their remaining 1x stake. Victim staker gets less than fair share.
    // S1 combined interaction test removed — S-PLANT-1 not active in round 2

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 8: Contract solvency maintained (bug is subtle, not crashy)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S6_contractRemainsSolvent() public {
        vm.prank(alice);
        staking10.stake(500 ether, tier30);

        vm.prank(victim);
        staking10.stake(DEFAULT_STAKE, tier90); // 3x boost

        // Emergency unstake with inflated penalty
        vm.prank(victim);
        staking10.emergencyUnstake(0);

        // Alice claims
        vm.prank(alice);
        staking10.claim(address(stakingToken));

        // Contract balance >= remaining principal
        assertGe(
            stakingToken.balanceOf(address(staking10)),
            staking10.totalRawSupply(),
            "contract solvent after inflated penalty"
        );
    }
}
