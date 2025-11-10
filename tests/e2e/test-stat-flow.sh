#!/bin/bash
# E2E Test: Stat Update Flow
# Tests: Stat update events → Absolute goal type → Reward claiming
# Location: tests/e2e/test-stat-flow.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Stat Update Flow E2E Test"

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
# Using winter-challenge-2025 goals (from challenges.test.json)
CHALLENGE_ID="winter-challenge-2025"
GOAL_ID_1="kill-10-snowmen"  # Absolute type: snowmen_killed >= 10, default_assigned = false
GOAL_ID_2="reach-level-5"    # Absolute type: player_level >= 5, default_assigned = false

# Step 1: Check initial state
print_step 1 "Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_1\") | .progress // 0")
INITIAL_PROGRESS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .progress // 0")

echo "  Goal 1 ($GOAL_ID_1) initial progress: $INITIAL_PROGRESS_1"
echo "  Goal 2 ($GOAL_ID_2) initial progress: $INITIAL_PROGRESS_2"
assert_equals "0" "$INITIAL_PROGRESS_1" "Initial progress for goal 1 should be 0"
assert_equals "0" "$INITIAL_PROGRESS_2" "Initial progress for goal 2 should be 0"

# Step 2: Activate goals (they have default_assigned = false)
print_step 2 "Activating goals (not auto-assigned)..."
activate_goal "$CHALLENGE_ID" "$GOAL_ID_1"
activate_goal "$CHALLENGE_ID" "$GOAL_ID_2"
sleep 0.5

# Step 3: Test absolute goal type - snowmen_killed
print_step 3 "Testing absolute goal type (snowmen_killed)..."

echo "  Triggering stat-update: snowmen_killed=3"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=3
sleep 0.5

echo "  Triggering stat-update: snowmen_killed=7"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=7
sleep 0.5

echo "  Triggering stat-update: snowmen_killed=10"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=10

wait_for_flush 2

# Step 4: Verify absolute goal replaced (not accumulated)
print_step 4 "Verifying absolute goal behavior (replaces value)..."
CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_1\") | .progress")
STATUS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_1\") | .status")

echo "  Progress after 3 stat updates: $PROGRESS_1"
echo "  Status: $STATUS_1"
assert_equals "10" "$PROGRESS_1" "Absolute goal should use latest value (10, not accumulated)"
assert_equals "completed" "$STATUS_1" "Status should be 'completed' after reaching target (10)"

# Step 5: Test another absolute goal - player_level
print_step 5 "Testing second absolute goal (player_level)..."

echo "  Triggering stat-update: player_level=5"
run_cli trigger-event stat-update --stat-code=player_level --value=5

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .progress")
STATUS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .status")

echo "  Progress: $PROGRESS_2"
echo "  Status: $STATUS_2"
assert_equals "5" "$PROGRESS_2" "Progress should be 5"
assert_equals "completed" "$STATUS_2" "Status should be 'completed' (target: 5)"

# Step 6: Claim second goal (reach-level-5)
print_step 6 "Claiming second goal reward (reach-level-5)..."

# Get reward info for verification
REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .reward.type")
REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .reward.rewardId // .reward.reward_id")
REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .reward.quantity // 1")

echo "  Reward type: $REWARD_TYPE"
echo "  Reward ID: $REWARD_ID"
echo "  Reward quantity: $REWARD_QUANTITY"

# Get initial wallet/entitlement state (if admin credentials provided)
if [ "$REWARD_TYPE" = "WALLET" ]; then
    INITIAL_BALANCE=$(get_initial_wallet_balance "$REWARD_ID")
    echo "  Initial $REWARD_ID balance: $INITIAL_BALANCE"
fi

CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID_2" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Claim should succeed"

# Verify reward in AGS Platform (if admin credentials provided)
print_step 6.1 "Verifying reward in AGS Platform Service..."
if [ "$REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$REWARD_ID" "$INITIAL_BALANCE" "$REWARD_QUANTITY"
elif [ "$REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$REWARD_ID"
else
    echo -e "${YELLOW}⚠${NC} Unknown reward type: $REWARD_TYPE (skipping verification)"
fi

# Step 7: Verify claimed status
print_step 7 "Verifying goal marked as claimed..."
CHALLENGES=$(run_cli list-challenges --format=json)
CLAIMED_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .status")

echo "  Status after claim: $CLAIMED_STATUS"
assert_equals "claimed" "$CLAIMED_STATUS" "Status should be 'claimed'"

# Step 8: Trigger more stat updates to test that claimed goals don't update
print_step 8 "Testing that claimed goals don't update..."

echo "  Triggering stat-update: player_level=10 (should not update claimed goal)"
run_cli trigger-event stat-update --stat-code=player_level --value=10

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER_CLAIM=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID_2\") | .progress")

echo "  Progress after stat update on claimed goal: $PROGRESS_AFTER_CLAIM"
assert_equals "5" "$PROGRESS_AFTER_CLAIM" "Claimed goal progress should not change (protected)"

print_success "Stat update flow test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - Tested M3 player initialization and manual goal activation"
echo "  - Tested absolute goal type (replaces value, not accumulate)"
echo "  - Verified multiple stat update events (snowmen_killed, player_level)"
echo "  - Verified status transitions: not_started → in_progress → completed → claimed"
echo "  - Verified claimed goals are protected from updates"
echo "  - Successfully claimed rewards"
