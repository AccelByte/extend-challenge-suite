#!/bin/bash
# E2E Test: Inactive Goal Filtering
# Tests: Only active goals receive progress updates from events
# Location: tests/e2e/test-inactive-goal-filtering.sh
#
# This test verifies the critical M3 Phase 6 requirement:
# "Only active goals (is_active=true) can receive progress updates"

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "Inactive Goal Filtering E2E Test"

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
GOAL_ID="kill-10-snowmen"  # Absolute type: snowmen_killed >= 10, default_assigned = false

#============================================================================
# Test 1: Verify inactive goal does NOT receive updates
#============================================================================
print_step 1 "Verify inactive goal doesn't receive progress updates..."

# Check initial state (goal should be inactive and have no progress row)
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress // 0")
INITIAL_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status // \"not_started\"")
IS_ACTIVE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .isActive // false")

echo "  Initial progress: $INITIAL_PROGRESS"
echo "  Initial status: $INITIAL_STATUS"
echo "  Is active: $IS_ACTIVE"
assert_equals "0" "$INITIAL_PROGRESS" "Initial progress should be 0"
assert_equals "false" "$IS_ACTIVE" "Goal should be inactive initially (default_assigned=false)"

# Trigger event while goal is inactive
echo "  Triggering stat-update event while goal is INACTIVE..."
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=5
sleep 0.5

wait_for_flush 2

# Verify progress did NOT update (inactive goal protection)
CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER_INACTIVE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress // 0")
STATUS_AFTER_INACTIVE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status // \"not_started\"")

echo "  Progress after event (inactive): $PROGRESS_AFTER_INACTIVE"
echo "  Status after event (inactive): $STATUS_AFTER_INACTIVE"
assert_equals "0" "$PROGRESS_AFTER_INACTIVE" "Progress should remain 0 (inactive goal should not receive updates)"
assert_equals "not_started" "$STATUS_AFTER_INACTIVE" "Status should remain 'not_started' (no progress row created)"

print_success "Inactive goal correctly ignored event"

#============================================================================
# Test 2: Activate goal and verify it NOW receives updates
#============================================================================
print_step 2 "Activate goal and verify it receives progress updates..."

# Activate the goal
echo "  Activating goal..."
ACTIVATE_RESULT=$(activate_goal "$CHALLENGE_ID" "$GOAL_ID")
IS_ACTIVE_AFTER=$(extract_json_value "$ACTIVATE_RESULT" '.isActive')

echo "  Is active after activation: $IS_ACTIVE_AFTER"
assert_equals "true" "$IS_ACTIVE_AFTER" "Goal should be active after activation"

sleep 0.5

# Trigger same event now that goal is active
echo "  Triggering stat-update event while goal is ACTIVE..."
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=5
sleep 0.5

wait_for_flush 2

# Verify progress DID update this time
CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER_ACTIVE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS_AFTER_ACTIVE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after event (active): $PROGRESS_AFTER_ACTIVE"
echo "  Status after event (active): $STATUS_AFTER_ACTIVE"
assert_equals "5" "$PROGRESS_AFTER_ACTIVE" "Progress should be 5 (active goal received update)"
assert_equals "in_progress" "$STATUS_AFTER_ACTIVE" "Status should be 'in_progress' (progress row created and updated)"

print_success "Active goal correctly received event"

#============================================================================
# Test 3: Continue progress toward completion
#============================================================================
print_step 3 "Continue progress updates..."

# Trigger more events to reach completion threshold
echo "  Triggering stat-update: snowmen_killed=10"
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=10
sleep 0.5

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AT_10=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS_AT_10=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress at 10: $PROGRESS_AT_10"
echo "  Status at 10: $STATUS_AT_10"
assert_equals "10" "$PROGRESS_AT_10" "Progress should be 10 (reached target)"
assert_equals "completed" "$STATUS_AT_10" "Status should be 'completed' (target reached)"

print_success "Goal completed successfully"

#============================================================================
# Test 4: Deactivate goal and verify it stops receiving updates
#============================================================================
print_step 4 "Deactivate goal and verify it stops receiving updates..."

# Deactivate the goal
echo "  Deactivating goal..."
DEACTIVATE_RESULT=$(deactivate_goal "$CHALLENGE_ID" "$GOAL_ID")
IS_ACTIVE_AFTER_DEACTIVATE=$(extract_json_value "$DEACTIVATE_RESULT" '.isActive')

echo "  Is active after deactivation: $IS_ACTIVE_AFTER_DEACTIVATE"
assert_equals "false" "$IS_ACTIVE_AFTER_DEACTIVATE" "Goal should be inactive after deactivation"

sleep 0.5

# Trigger event while goal is deactivated (but has existing progress)
echo "  Triggering stat-update event while goal is DEACTIVATED..."
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=20
sleep 0.5

wait_for_flush 2

# Verify progress did NOT update (deactivated goal protection)
CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER_DEACTIVATE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS_AFTER_DEACTIVATE=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after event (deactivated): $PROGRESS_AFTER_DEACTIVATE"
echo "  Status after event (deactivated): $STATUS_AFTER_DEACTIVATE"
assert_equals "10" "$PROGRESS_AFTER_DEACTIVATE" "Progress should remain 10 (deactivated goal should not receive updates)"
assert_equals "completed" "$STATUS_AFTER_DEACTIVATE" "Status should remain 'completed' (no changes)"

print_success "Deactivated goal correctly ignored event"

#============================================================================
# Test 5: Verify claimed goals cannot be reactivated
#============================================================================
print_step 5 "Verify claimed goals cannot be reactivated..."

# First, complete the prerequisite goal (complete-tutorial)
echo "  Completing prerequisite goal (complete-tutorial)..."
activate_goal "$CHALLENGE_ID" "complete-tutorial"
sleep 0.5
run_cli trigger-event stat-update --stat-code=tutorial_completed --value=1
sleep 0.5
wait_for_flush 2

# Reactivate our test goal and claim it
echo "  Reactivating goal to claim it..."
activate_goal "$CHALLENGE_ID" "$GOAL_ID"
sleep 0.5

# Claim reward
echo "  Claiming reward..."
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')

echo "  Claim status: $CLAIM_STATUS"
assert_equals "success" "$CLAIM_STATUS" "Claim should succeed"

sleep 0.5

# Verify status is claimed
CHALLENGES=$(run_cli list-challenges --format=json)
CLAIMED_STATUS=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Status after claim: $CLAIMED_STATUS"
assert_equals "claimed" "$CLAIMED_STATUS" "Status should be 'claimed'"

# Try to trigger event on claimed goal (should not update regardless of active state)
echo "  Triggering event on claimed goal..."
run_cli trigger-event stat-update --stat-code=snowmen_killed --value=30
sleep 0.5

wait_for_flush 2

CHALLENGES=$(run_cli list-challenges --format=json)
PROGRESS_AFTER_CLAIMED=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .progress")
STATUS_FINAL=$(extract_json_value "$CHALLENGES" ".challenges[] | select(.challengeId==\"$CHALLENGE_ID\") | .goals[] | select(.goalId==\"$GOAL_ID\") | .status")

echo "  Progress after event (claimed): $PROGRESS_AFTER_CLAIMED"
echo "  Status final: $STATUS_FINAL"
assert_equals "10" "$PROGRESS_AFTER_CLAIMED" "Progress should remain 10 (claimed protection overrides active state)"
assert_equals "claimed" "$STATUS_FINAL" "Status should remain 'claimed'"

print_success "Claimed goal correctly protected from updates"

print_success "Inactive goal filtering test completed successfully"

# Summary
echo ""
echo "Summary:"
echo "  - ✅ Inactive goals (is_active=false) do NOT receive progress updates"
echo "  - ✅ Activating a goal (is_active=true) enables progress updates"
echo "  - ✅ Active goals receive progress updates correctly"
echo "  - ✅ Deactivating a goal stops progress updates immediately"
echo "  - ✅ Claimed goals are protected from updates (regardless of active state)"
echo ""
echo "Test Coverage:"
echo "  - Inactive → Event → No update (Test 1)"
echo "  - Inactive → Activate → Event → Update (Test 2)"
echo "  - Active → Event → Update → Completion (Test 3)"
echo "  - Active → Deactivate → Event → No update (Test 4)"
echo "  - Claimed → Event → No update (Test 5)"
