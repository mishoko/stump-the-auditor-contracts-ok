// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "./helpers/BaseTest.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {Staking} from "src/Staking/Staking.sol";
import {IStaking} from "src/interfaces/IStaking.sol";

/// @title S-PLANT-10 PoC: Penalty Value Dilution via Wrong Denominator
/// @notice `_distributeOrQueuePenalty` uses `totalBoostedSupply` instead of
///   `eligibleBoostedSupply` as the accumulator denominator. The paid-marker
///   still prevents the penalized user from self-claiming, but the penalty
///   value is DILUTED across a larger supply base. The penalized user's
///   proportional share of the penalty is effectively LOST — permanently
///   locked in the accumulator gap that nobody can claim.
contract PlantPoC_S10 is BaseTest {
    uint64 internal constant REWARD_DURATION = 30 days;
    uint128 internal constant DEFAULT_STAKE = 100 ether;
    uint256 internal constant DUST = 1_000;
    uint256 internal constant ACCUMULATOR_PRECISION = 1e36;

    MockERC20 internal stakingToken;
    Staking internal staking;
    uint8 internal tier30;

    address internal penalizedUser;
    address internal eligibleUser;

    function setUp() public override {
        super.setUp();
        penalizedUser = makeAddr("penalizedUser");
        eligibleUser = makeAddr("eligibleUser");

        stakingToken = deployMockToken("STK", 18);

        vm.startPrank(owner);
        staking = new Staking(IERC20(address(stakingToken)), address(stakingToken), 1_000);
        tier30 = staking.setLockTier(30 days, 10_000);
        vm.stopPrank();

        mintAndApprove(stakingToken, penalizedUser, address(staking), 10_000 ether);
        mintAndApprove(stakingToken, eligibleUser, address(staking), 10_000 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: Eligible staker receives LESS than the full penalty
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S10_eligibleStakerShortchanged() public {
        // Both stake equal amounts
        vm.prank(eligibleUser);
        staking.stake(500 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(500 ether, tier30);
        // Also give penalized user a second stake so they have remaining boost
        vm.prank(penalizedUser);
        staking.stake(100 ether, tier30);

        // Emergency unstake the second stake (penalty = 10 ether)
        vm.prank(penalizedUser);
        staking.emergencyUnstake(1);

        uint256 penalty = 10 ether; // 10% of 100 ether

        // Eligible staker should get ALL 10 ether (penalized user excluded)
        // Bug: penalty distributed over totalBoostedSupply (1000) not eligible (500)
        // Eligible gets: 500/1000 * 10 = 5 ether (HALF of what they deserve)
        // Penalized user's paid marker prevents them from claiming their 5 ether share
        // That 5 ether is PERMANENTLY LOST

        uint256 eligibleEarned = staking.earned(eligibleUser, address(stakingToken));
        uint256 penalizedEarned = staking.earned(penalizedUser, address(stakingToken));

        emit log_named_uint("Penalty amount", penalty);
        emit log_named_uint("Eligible earned", eligibleEarned);
        emit log_named_uint("Penalized earned (should be 0)", penalizedEarned);
        emit log_named_uint("Value LOST (penalty - eligible - penalized)", penalty - eligibleEarned - penalizedEarned);

        // Eligible staker got only ~5 ether instead of 10 ether
        assertApproxEqAbs(eligibleEarned, 5 ether, DUST, "eligible gets only half");

        // Penalized user correctly gets 0 (paid marker works)
        assertEq(penalizedEarned, 0, "penalized user blocked by paid marker");

        // 5 ether is permanently lost — nobody can claim it
        uint256 totalClaimable = eligibleEarned + penalizedEarned;
        assertLt(totalClaimable, penalty, "total claimable < penalty: value leaked");

        uint256 leaked = penalty - totalClaimable;
        assertApproxEqAbs(leaked, 5 ether, DUST, "~5 ether permanently frozen");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: Larger penalized position = more value lost
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S10_largerPositionMoreLoss() public {
        // Eligible: small stake. Penalized: dominant position.
        vm.prank(eligibleUser);
        staking.stake(100 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(900 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(100 ether, tier30); // sacrificial

        vm.prank(penalizedUser);
        staking.emergencyUnstake(1); // penalty = 10 ether

        uint256 penalty = 10 ether;
        uint256 eligibleEarned = staking.earned(eligibleUser, address(stakingToken));
        uint256 penalizedEarned = staking.earned(penalizedUser, address(stakingToken));

        // totalBoostedSupply = 1000 (eligible=100 + penalized=900)
        // Eligible gets: 100/1000 * 10 = 1 ether (instead of full 10)
        // Lost: 900/1000 * 10 = 9 ether — 90% of penalty GONE

        assertApproxEqAbs(eligibleEarned, 1 ether, DUST, "eligible gets only 10%");
        assertEq(penalizedEarned, 0, "penalized blocked");

        uint256 leaked = penalty - eligibleEarned;
        emit log_named_uint("Leaked (90% of penalty)", leaked);
        assertApproxEqAbs(leaked, 9 ether, DUST, "90% of penalty permanently frozen");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Repeated penalties compound the leak
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S10_repeatedPenaltiesCompoundLeak() public {
        vm.prank(eligibleUser);
        staking.stake(100 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(900 ether, tier30);

        uint256 totalLeaked;

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(penalizedUser);
            staking.stake(50 ether, tier30);

            uint256 stakeIdx = staking.getUserStakes(penalizedUser).length - 1;
            uint256 earnedBefore = staking.earned(eligibleUser, address(stakingToken));

            vm.prank(penalizedUser);
            staking.emergencyUnstake(stakeIdx);

            uint256 earnedAfter = staking.earned(eligibleUser, address(stakingToken));
            uint256 penaltyRound = 5 ether; // 10% of 50
            uint256 captured = earnedAfter - earnedBefore;
            totalLeaked += penaltyRound - captured;
        }

        emit log_named_uint("Total leaked over 5 rounds", totalLeaked);
        // Each round loses ~90% of penalty. 5 rounds x 5 ether x 90% ~ 22.5 ether
        assertGt(totalLeaked, 20 ether, "massive cumulative leak");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: Contract stays solvent (bug is silent)
    // ─────────────────────────────────────────────────────────────────────────

    function testPoC_S10_contractRemainsSolvent() public {
        vm.prank(eligibleUser);
        staking.stake(500 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(500 ether, tier30);
        vm.prank(penalizedUser);
        staking.stake(100 ether, tier30);

        vm.prank(penalizedUser);
        staking.emergencyUnstake(1);

        // Claims work — no revert
        vm.prank(eligibleUser);
        staking.claim(address(stakingToken));

        // Contract balance covers all principal
        assertGe(
            stakingToken.balanceOf(address(staking)),
            staking.totalRawSupply(),
            "solvent"
        );
    }
}
