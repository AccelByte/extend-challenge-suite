#!/bin/bash
# E2E Test: Mixed Goal Types
# Tests: Absolute + Increment + Daily goal types working together
# Location: tests/e2e/test-mixed-goals.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Mixed Goal Types E2E Test"

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
# Using winter-challenge-2025 (absolute goals) and daily-quests (daily goals)
CHALLENGE_ID_1="winter-challenge-2025"
CHALLENGE_ID_2="daily-quests"
ABSOLUTE_GOAL_1="kill-10-snowmen"      # Absolute type: snowmen_killed >= 10
ABSOLUTE_GOAL_2="reach-level-5"        # Absolute type: player_level >= 5
DAILY_GOAL="login-today"               # Daily type: daily_login >= 1

# Step 1: Activate goals (none have default_assigned = true except complete-tutorial)
print_step 1 "Activating test goals..."
activate_goal "$CHALLENGE_ID_1" "$ABSOLUTE_GOAL_1"
activate_goal "$CHALLENGE_ID_1" "$ABSOLUTE_GOAL_2"
activate_goal "$CHALLENGE_ID_2" "$DAILY_GOAL"
sleep 0.5

# Step 2: Check initial state
print_step 2 "Checking initial state for all goal types..."
CHALLENGES=$(run_cli list-challenges --format=json)

ABSOLUTE_PROGRESS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .progress // 0")
ABSOLUTE_PROGRESS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_2\") | .progress // 0")
DAILY_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .progress // 0")

echo "  Absolute goal 1 (kill-10-snowmen) progress: $ABSOLUTE_PROGRESS_1"
echo "  Absolute goal 2 (reach-level-5) progress: $ABSOLUTE_PROGRESS_2"
echo "  Daily goal (login-today) progress: $DAILY_PROGRESS"

assert_equals "0" "$ABSOLUTE_PROGRESS_1" "Absolute goal 1 should start at 0"
assert_equals "0" "$ABSOLUTE_PROGRESS_2" "Absolute goal 2 should start at 0"
assert_equals "0" "$DAILY_PROGRESS" "Daily goal should start at 0"

# Step 3: Trigger events for all goal types
print_step 3 "Triggering events for all goal types..."

echo "  Triggering stat-update: snowmen_killed=10 (absolute goal 1)"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=10
sleep 0.3

echo "  Triggering stat-update: player_level=5 (absolute goal 2)"
run_cli trigger-event stat-update --stat-code=player_level --value=5
sleep 0.3

echo "  Triggering login event (daily goal)"
run_cli trigger-event login
sleep 0.3

wait_for_flush 2

# Step 4: Verify all goal types updated correctly
print_step 4 "Verifying all goal types updated correctly..."
CHALLENGES=$(run_cli list-challenges --format=json)

ABSOLUTE_PROGRESS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .progress")
ABSOLUTE_STATUS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .status")

ABSOLUTE_PROGRESS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_2\") | .progress")
ABSOLUTE_STATUS_2=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_2\") | .status")

DAILY_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .progress")
DAILY_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .status")

echo "  Absolute goal 1 (kill-10-snowmen): progress=$ABSOLUTE_PROGRESS_1, status=$ABSOLUTE_STATUS_1"
echo "  Absolute goal 2 (reach-level-5): progress=$ABSOLUTE_PROGRESS_2, status=$ABSOLUTE_STATUS_2"
echo "  Daily goal (login-today): progress=$DAILY_PROGRESS, status=$DAILY_STATUS"

assert_equals "10" "$ABSOLUTE_PROGRESS_1" "Absolute goal 1 progress should be 10"
assert_equals "completed" "$ABSOLUTE_STATUS_1" "Absolute goal 1 should be completed (target: 10)"

assert_equals "5" "$ABSOLUTE_PROGRESS_2" "Absolute goal 2 progress should be 5"
assert_equals "completed" "$ABSOLUTE_STATUS_2" "Absolute goal 2 should be completed (target: 5)"

assert_equals "1" "$DAILY_PROGRESS" "Daily goal progress should be 1"
assert_equals "completed" "$DAILY_STATUS" "Daily goal should be completed (daily goals complete on first event)"

# Step 5: Trigger more events to further test different behaviors
print_step 5 "Triggering more events to test goal type behaviors..."

echo "  Triggering stat-update: snowmen_killed=20 (should replace to 20, not add)"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=20
sleep 0.3

echo "  Triggering login event (daily should stay same - same day idempotency)"
run_cli trigger-event login

wait_for_flush 2

# Step 6: Verify different update behaviors
print_step 6 "Verifying different update behaviors..."
CHALLENGES=$(run_cli list-challenges --format=json)

ABSOLUTE_PROGRESS_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .progress")
DAILY_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .progress")

echo "  Absolute goal 1 progress: $ABSOLUTE_PROGRESS_1 (should be 20, replaced)"
echo "  Daily goal progress: $DAILY_PROGRESS (should still be 1, same day)"

assert_equals "20" "$ABSOLUTE_PROGRESS_1" "Absolute goal should replace value (not accumulate)"
assert_equals "1" "$DAILY_PROGRESS" "Daily goal should not change on same day"

# Step 7: Claim all completed goals
print_step 7 "Claiming all completed goals..."

# First complete and claim the prerequisite (complete-tutorial)
echo "  Completing prerequisite (complete-tutorial)..."
run_cli trigger-event stat-update --stat-code=tutorial_completed --value=1
wait_for_flush 2

echo "  Claiming prerequisite (complete-tutorial)..."
run_cli claim-reward "$CHALLENGE_ID_1" "complete-tutorial" --format=json > /dev/null 2>&1

sleep 0.5

# Get reward info for absolute goal 1
ABSOLUTE_REWARD_TYPE_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .reward.type")
ABSOLUTE_REWARD_ID_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .reward.rewardId // .reward.reward_id")
ABSOLUTE_REWARD_QUANTITY_1=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_1\") | .goals[] | select(.goalId==\"$ABSOLUTE_GOAL_1\") | .reward.quantity // 1")

echo "  Absolute goal 1 reward: $ABSOLUTE_REWARD_TYPE_1 / $ABSOLUTE_REWARD_ID_1 / $ABSOLUTE_REWARD_QUANTITY_1"

# Get initial balance for absolute goal 1
if [ "$ABSOLUTE_REWARD_TYPE_1" = "WALLET" ]; then
    ABSOLUTE_INITIAL_BALANCE_1=$(get_initial_wallet_balance "$ABSOLUTE_REWARD_ID_1")
    echo "  Initial $ABSOLUTE_REWARD_ID_1 balance: $ABSOLUTE_INITIAL_BALANCE_1"
fi

echo "  Claiming absolute goal 1 ($ABSOLUTE_GOAL_1)"
CLAIM_1=$(run_cli claim-reward "$CHALLENGE_ID_1" "$ABSOLUTE_GOAL_1" --format=json)
assert_equals "success" "$(extract_json_value "$CLAIM_1" '.status')" "Absolute goal 1 claim should succeed"

# Verify absolute goal 1 reward in AGS Platform
print_step 7.1 "Verifying absolute goal 1 reward in AGS Platform..."
if [ "$ABSOLUTE_REWARD_TYPE_1" = "WALLET" ]; then
    verify_wallet_increased "$ABSOLUTE_REWARD_ID_1" "$ABSOLUTE_INITIAL_BALANCE_1" "$ABSOLUTE_REWARD_QUANTITY_1"
elif [ "$ABSOLUTE_REWARD_TYPE_1" = "ITEM" ]; then
    verify_entitlement_granted "$ABSOLUTE_REWARD_ID_1"
fi

# Get reward info for daily goal
DAILY_REWARD_TYPE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .reward.type")
DAILY_REWARD_ID=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .reward.rewardId // .reward.reward_id")
DAILY_REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID_2\") | .goals[] | select(.goalId==\"$DAILY_GOAL\") | .reward.quantity // 1")

echo "  Daily goal reward: $DAILY_REWARD_TYPE / $DAILY_REWARD_ID / $DAILY_REWARD_QUANTITY"

# Get initial balance for daily goal
if [ "$DAILY_REWARD_TYPE" = "WALLET" ]; then
    DAILY_INITIAL_BALANCE=$(get_initial_wallet_balance "$DAILY_REWARD_ID")
    echo "  Initial $DAILY_REWARD_ID balance: $DAILY_INITIAL_BALANCE"
fi

echo "  Claiming daily goal ($DAILY_GOAL)"
CLAIM_2=$(run_cli claim-reward "$CHALLENGE_ID_2" "$DAILY_GOAL" --format=json)
assert_equals "success" "$(extract_json_value "$CLAIM_2" '.status')" "Daily goal claim should succeed"

# Verify daily goal reward in AGS Platform
print_step 7.2 "Verifying daily goal reward in AGS Platform..."
if [ "$DAILY_REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$DAILY_REWARD_ID" "$DAILY_INITIAL_BALANCE" "$DAILY_REWARD_QUANTITY"
elif [ "$DAILY_REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$DAILY_REWARD_ID"
fi

# Step 8: Verify absolute goal 2 is claimable
print_step 8 "Claiming absolute goal 2..."
CLAIM_3=$(run_cli claim-reward "$CHALLENGE_ID_1" "$ABSOLUTE_GOAL_2" --format=json)
assert_equals "success" "$(extract_json_value "$CLAIM_3" '.status')" "Absolute goal 2 claim should succeed"

print_success "Mixed goal types test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - Tested M3 player initialization and manual goal activation"
echo "  - Tested multiple goal types together: 2 absolute + 1 daily"
echo "  - Verified different update behaviors:"
echo "    • Absolute (kill-10-snowmen): Replaces value (10 → 20)"
echo "    • Absolute (reach-level-5): Completes at 5"
echo "    • Daily (login-today): Once per day (1, no change on same day)"
echo "  - Successfully claimed all completed goals"
echo "  - Verified reward distribution via AGS Platform Service"
