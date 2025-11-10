#!/bin/bash
# E2E Test: Prerequisite Validation
# Tests: Prerequisite checking → Claim order enforcement → Unlocking dependent goals
# Location: tests/e2e/test-prerequisites.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Prerequisites E2E Test"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

# M3: Initialize player goals
print_step 0 "Initializing player with default goals (M3)..."
INIT_RESULT=$(initialize_player)
NEW_ASSIGNMENTS=$(extract_json_value "$INIT_RESULT" '.newAssignments')
TOTAL_ACTIVE=$(extract_json_value "$INIT_RESULT" '.totalActive')
echo "  New assignments: $NEW_ASSIGNMENTS"
echo "  Total active goals: $TOTAL_ACTIVE"

# Test configuration
CHALLENGE_ID="winter-challenge-2025"
PREREQ_GOAL="complete-tutorial"    # Prerequisite for kill-10-snowmen
DEPENDENT_GOAL="kill-10-snowmen"   # Requires complete-tutorial
CHAIN_GOAL="reach-level-5"         # Requires kill-10-snowmen

# M3: Activate goals (none have default_assigned = true except complete-tutorial)
echo "Activating test goals..."
activate_goal "$CHALLENGE_ID" "$PREREQ_GOAL"
activate_goal "$CHALLENGE_ID" "$DEPENDENT_GOAL"
activate_goal "$CHALLENGE_ID" "$CHAIN_GOAL"
sleep 0.5

# Step 1: Complete the dependent goal WITHOUT completing prerequisite
print_step 1 "Completing dependent goal without prerequisite..."
echo "  Completing $DEPENDENT_GOAL (requires $PREREQ_GOAL to be claimed)"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=10

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
DEPENDENT_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$DEPENDENT_GOAL\") | .status")

echo "  Dependent goal status: $DEPENDENT_STATUS"
assert_equals "completed" "$DEPENDENT_STATUS" "Goal should be completed (progress met)"

# Step 2: Try to claim dependent goal (should fail - prerequisite not met)
print_step 2 "Attempting to claim dependent goal (should fail)..."
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$DEPENDENT_GOAL" --format=json 2>&1 || true)

echo "  Claim result: $CLAIM_RESULT"
if echo "$CLAIM_RESULT" | grep -qi "prerequisite\|locked\|GOAL_LOCKED"; then
    echo -e "${GREEN}✅ PASS${NC}: Claim correctly rejected (prerequisite not met)"
else
    error_exit "Claim should have failed with prerequisite/locked error, got: $CLAIM_RESULT"
fi

# Step 3: Complete and claim the prerequisite goal
print_step 3 "Completing and claiming prerequisite goal..."
echo "  Completing $PREREQ_GOAL"
run_cli trigger-event stat-update --stat-code=tutorial_completed --value=1

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PREREQ_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$PREREQ_GOAL\") | .status")

echo "  Prerequisite goal status: $PREREQ_STATUS"
assert_equals "completed" "$PREREQ_STATUS" "Prerequisite goal should be completed"

# Get reward info for verification
PREREQ_REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$PREREQ_GOAL\") | .reward.type")
PREREQ_REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$PREREQ_GOAL\") | .reward.rewardId // .reward.reward_id")
PREREQ_REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$PREREQ_GOAL\") | .reward.quantity // 1")

echo "  Prerequisite reward: $PREREQ_REWARD_TYPE / $PREREQ_REWARD_ID / $PREREQ_REWARD_QUANTITY"

# Get initial balance for prerequisite reward
if [ "$PREREQ_REWARD_TYPE" = "WALLET" ]; then
    PREREQ_INITIAL_BALANCE=$(get_initial_wallet_balance "$PREREQ_REWARD_ID")
    echo "  Initial $PREREQ_REWARD_ID balance: $PREREQ_INITIAL_BALANCE"
fi

echo "  Claiming $PREREQ_GOAL"
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$PREREQ_GOAL" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Prerequisite claim should succeed"

# Verify prerequisite reward in AGS Platform
print_step 3.1 "Verifying prerequisite reward in AGS Platform..."
if [ "$PREREQ_REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$PREREQ_REWARD_ID" "$PREREQ_INITIAL_BALANCE" "$PREREQ_REWARD_QUANTITY"
elif [ "$PREREQ_REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$PREREQ_REWARD_ID"
fi

# Step 4: Verify prerequisite is claimed
CHALLENGES=$(run_cli list-challenges --format=json)
PREREQ_CLAIMED=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$PREREQ_GOAL\") | .status")

echo "  Prerequisite status after claim: $PREREQ_CLAIMED"
assert_equals "claimed" "$PREREQ_CLAIMED" "Prerequisite should be claimed"

# Step 5: Now try to claim dependent goal again (should succeed)
print_step 4 "Claiming dependent goal now (should succeed)..."

# Get reward info for dependent goal
CHALLENGES=$(run_cli list-challenges --format=json)
DEPENDENT_REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$DEPENDENT_GOAL\") | .reward.type")
DEPENDENT_REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$DEPENDENT_GOAL\") | .reward.rewardId // .reward.reward_id")
DEPENDENT_REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$DEPENDENT_GOAL\") | .reward.quantity // 1")

echo "  Dependent reward: $DEPENDENT_REWARD_TYPE / $DEPENDENT_REWARD_ID / $DEPENDENT_REWARD_QUANTITY"

# Get initial balance for dependent reward
if [ "$DEPENDENT_REWARD_TYPE" = "WALLET" ]; then
    DEPENDENT_INITIAL_BALANCE=$(get_initial_wallet_balance "$DEPENDENT_REWARD_ID")
    echo "  Initial $DEPENDENT_REWARD_ID balance: $DEPENDENT_INITIAL_BALANCE"
fi

CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$DEPENDENT_GOAL" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Dependent goal claim should now succeed"

# Verify dependent reward in AGS Platform
print_step 4.1 "Verifying dependent reward in AGS Platform..."
if [ "$DEPENDENT_REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$DEPENDENT_REWARD_ID" "$DEPENDENT_INITIAL_BALANCE" "$DEPENDENT_REWARD_QUANTITY"
elif [ "$DEPENDENT_REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$DEPENDENT_REWARD_ID"
fi

# Step 6: Verify dependent goal is claimed
CHALLENGES=$(run_cli list-challenges --format=json)
DEPENDENT_CLAIMED=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$DEPENDENT_GOAL\") | .status")

echo "  Dependent goal status: $DEPENDENT_CLAIMED"
assert_equals "claimed" "$DEPENDENT_CLAIMED" "Dependent goal should be claimed"

# Step 7: Test prerequisite chain (reach-level-5 requires kill-10-snowmen)
print_step 5 "Testing prerequisite chain..."
echo "  Completing $CHAIN_GOAL (requires $DEPENDENT_GOAL to be claimed)"
run_cli trigger-event stat-update --stat-code=player_level --value=5

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
CHAIN_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$CHAIN_GOAL\") | .status")

echo "  Chain goal status: $CHAIN_STATUS"
assert_equals "completed" "$CHAIN_STATUS" "Chain goal should be completed"

# Get reward info for chain goal
CHAIN_REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$CHAIN_GOAL\") | .reward.type")
CHAIN_REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$CHAIN_GOAL\") | .reward.rewardId // .reward.reward_id")
CHAIN_REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$CHAIN_GOAL\") | .reward.quantity // 1")

echo "  Chain reward: $CHAIN_REWARD_TYPE / $CHAIN_REWARD_ID / $CHAIN_REWARD_QUANTITY"

# Get initial balance for chain reward
if [ "$CHAIN_REWARD_TYPE" = "WALLET" ]; then
    CHAIN_INITIAL_BALANCE=$(get_initial_wallet_balance "$CHAIN_REWARD_ID")
    echo "  Initial $CHAIN_REWARD_ID balance: $CHAIN_INITIAL_BALANCE"
fi

echo "  Claiming $CHAIN_GOAL (should succeed, prerequisite already claimed)"
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$CHAIN_GOAL" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Chain goal claim should succeed"

# Verify chain reward in AGS Platform
print_step 5.1 "Verifying chain reward in AGS Platform..."
if [ "$CHAIN_REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$CHAIN_REWARD_ID" "$CHAIN_INITIAL_BALANCE" "$CHAIN_REWARD_QUANTITY"
elif [ "$CHAIN_REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$CHAIN_REWARD_ID"
fi

print_success "Prerequisites test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - Verified prerequisite enforcement (claim blocked when prerequisite not met)"
echo "  - Verified claim allowed after prerequisite claimed"
echo "  - Verified prerequisite chain works correctly"
echo "  - Goal claim order enforced:"
echo "    1. $PREREQ_GOAL (claimed first)"
echo "    2. $DEPENDENT_GOAL (claimed second, after prerequisite)"
echo "    3. $CHAIN_GOAL (claimed third, chain prerequisite)"
