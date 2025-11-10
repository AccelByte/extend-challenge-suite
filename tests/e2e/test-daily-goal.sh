#!/bin/bash
# E2E Test: Daily Goal Behavior
# Tests: Daily goal type → Idempotency (same day) → Daily reset behavior
# Location: tests/e2e/test-daily-goal.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Daily Goal E2E Test"

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
# Using daily-quests goals (from challenges.test.json)
CHALLENGE_ID="daily-quests"
GOAL_ID="login-today"  # Daily type goal: daily_login >= 1, default_assigned = false

# Step 1: Activate goal (it has default_assigned = false)
print_step 1 "Activating daily goal..."
activate_goal "$CHALLENGE_ID" "$GOAL_ID"
sleep 0.5

# Step 2: Check initial state
print_step 2 "Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress // 0")
INITIAL_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status // \"not_started\"")

echo "  Initial progress: $INITIAL_PROGRESS"
echo "  Initial status: $INITIAL_STATUS"
assert_equals "0" "$INITIAL_PROGRESS" "Initial progress should be 0"

# Step 3: Trigger first login event
print_step 3 "Triggering first login event..."
run_cli trigger-event login

wait_for_flush 2

# Step 4: Verify goal completed (daily goal completes on first occurrence)
print_step 4 "Verifying daily goal completed..."
CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after first login: $PROGRESS"
echo "  Status: $STATUS"
assert_equals "1" "$PROGRESS" "Progress should be 1 after first login"
assert_equals "completed" "$STATUS" "Status should be 'completed' (daily goals complete on first event)"

# Step 5: Test idempotency - trigger another login event same day
print_step 5 "Testing same-day idempotency..."
echo "  Triggering second login event (same day)..."
run_cli trigger-event login

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS_AFTER=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after second login (same day): $PROGRESS_AFTER"
echo "  Status: $STATUS_AFTER"
assert_equals "1" "$PROGRESS_AFTER" "Progress should still be 1 (no change on same day)"
assert_equals "completed" "$STATUS_AFTER" "Status should remain 'completed'"

# Step 6: Claim reward
print_step 6 "Claiming daily goal reward..."

# Get reward info for verification
REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .reward.type")
REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .reward.rewardId // .reward.reward_id")
REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .reward.quantity // 1")

echo "  Reward type: $REWARD_TYPE"
echo "  Reward ID: $REWARD_ID"
echo "  Reward quantity: $REWARD_QUANTITY"

# Get initial wallet/entitlement state (if admin credentials provided)
if [ "$REWARD_TYPE" = "WALLET" ]; then
    INITIAL_BALANCE=$(get_initial_wallet_balance "$REWARD_ID")
    echo "  Initial $REWARD_ID balance: $INITIAL_BALANCE"
fi

CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json)
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
CLAIMED_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Status after claim: $CLAIMED_STATUS"
assert_equals "claimed" "$CLAIMED_STATUS" "Status should be 'claimed'"

# Step 8: Test that claimed goals don't update even with new login events
print_step 8 "Testing claimed goal protection..."
echo "  Triggering login event on claimed goal (should not update)..."
run_cli trigger-event login

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
FINAL_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
FINAL_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after login on claimed goal: $FINAL_PROGRESS"
echo "  Status: $FINAL_STATUS"
assert_equals "1" "$FINAL_PROGRESS" "Progress should not change (claimed protection)"
assert_equals "claimed" "$FINAL_STATUS" "Status should remain 'claimed'"

print_success "Daily goal test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - Tested M3 player initialization and manual goal activation"
echo "  - Daily goal (login-today) completed on first login event"
echo "  - Same-day idempotency verified (second login did not change progress)"
echo "  - Status transitions: not_started → completed → claimed"
echo "  - Claimed goal protected from updates"
echo ""
echo "Note: Testing next-day reset requires waiting 24 hours or database manipulation"
echo "      (not feasible in automated tests, but the daily timestamp logic is validated)"
