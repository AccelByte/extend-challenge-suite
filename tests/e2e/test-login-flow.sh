#!/bin/bash
# E2E Test: Login Flow
# Tests: Login events → Progress tracking → Reward claiming
# Location: tests/e2e/test-login-flow.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Login Flow E2E Test"

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
GOAL_ID="complete-tutorial"  # This goal has default_assigned = true, requires tutorial_completed stat

# Note: If goal wasn't auto-assigned (already initialized before), manually activate it
if [ "$NEW_ASSIGNMENTS" = "0" ]; then
    echo "  Goal not auto-assigned (player already initialized), activating manually..."
    activate_goal "$CHALLENGE_ID" "$GOAL_ID"
    sleep 0.5
fi

# Step 1: Check initial state
print_step 1 "Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress // 0")
INITIAL_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status // \"not_started\"")

echo "  Initial progress: $INITIAL_PROGRESS"
echo "  Initial status: $INITIAL_STATUS"
assert_equals "0" "$INITIAL_PROGRESS" "Initial progress should be 0"

# Step 2: Complete the tutorial goal (absolute type, requires tutorial_completed >= 1)
print_step 2 "Completing tutorial goal..."
echo "  Triggering stat-update: tutorial_completed=1"
run_cli trigger-event stat-update --stat-code=tutorial_completed --value=1
sleep 0.5

# Step 3: Wait for buffer flush
wait_for_flush 2

# Step 3: Verify goal completed
print_step 3 "Verifying tutorial goal completed..."
CHALLENGES=$(run_cli list-challenges --format=json)
NEW_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Current progress: $NEW_PROGRESS"
echo "  Current status: $STATUS"
assert_equals "1" "$NEW_PROGRESS" "Progress should be 1"
assert_equals "completed" "$STATUS" "Status should be 'completed'"

# Step 4: Claim reward
print_step 4 "Claiming tutorial reward..."

# Get reward info
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

# Claim reward
echo "  Claiming tutorial reward..."
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Claim should succeed for completed goal"

# Verify reward in AGS Platform (if admin credentials provided)
print_step 4.1 "Verifying reward in AGS Platform Service..."
if [ "$REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$REWARD_ID" "$INITIAL_BALANCE" "$REWARD_QUANTITY"
elif [ "$REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$REWARD_ID"
else
    echo -e "${YELLOW}⚠${NC} Unknown reward type: $REWARD_TYPE (skipping verification)"
fi

# Verify claimed status
CHALLENGES=$(run_cli list-challenges --format=json)
CLAIMED_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Status after claim: $CLAIMED_STATUS"
assert_equals "claimed" "$CLAIMED_STATUS" "Status should be 'claimed' after claiming reward"

# Try to claim again (should fail - idempotency test)
print_step 5 "Testing claim idempotency..."
CLAIM_AGAIN_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json 2>&1 || true)

echo "  Second claim result: $CLAIM_AGAIN_RESULT"

if echo "$CLAIM_AGAIN_RESULT" | grep -qi "already\|claimed\|CLAIMED"; then
    echo -e "${GREEN}✅ PASS${NC}: Second claim correctly rejected (idempotency works)"
else
    error_exit "Second claim should have failed with 'already claimed' error. Got: $CLAIM_AGAIN_RESULT"
fi

print_success "Login flow test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - Tested M3 player initialization (default goal assignment)"
echo "  - Tested absolute goal type (complete-tutorial): Completes when tutorial_completed >= 1"
echo "  - Status transitions verified: not_started → completed → claimed"
echo "  - Reward claiming verified with AGS Platform Service integration"
echo "  - Idempotency verified (second claim rejected)"
