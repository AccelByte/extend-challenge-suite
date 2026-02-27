#!/bin/bash
# E2E Test: M5 Login Event with Rotation
# Tests login events with rotation (NULL progress / accumulation path in SQL)
# Location: tests/e2e/test-m5-rotation-login.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Login - Login Events with Daily Rotation"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-login-rotation"  # login_count >= 1, relative mode, daily rotation

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Login rotation goal should start as not_started"

#============================================================================
# Step 2: Trigger login event
#============================================================================
print_step 2 "Trigger login event to complete daily login goal"

run_cli trigger-event login > /dev/null 2>&1
wait_for_flush 3

#============================================================================
# Step 3: Verify goal is completed (target=1, single login)
#============================================================================
print_step 3 "Verify login rotation goal is completed"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "completed" "$STATUS" "Login goal should be completed after one login event"
assert_gte "$PROGRESS" "1" "Progress should be >= 1"

#============================================================================
# Step 4: Verify DB has baseline_value set (login-based baseline)
#============================================================================
print_step 4 "Verify DB state after login event processing"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
assert_equals "completed" "$DB_STATUS" "DB status should be 'completed'"

DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")
# Login events should set a baseline_value for relative mode
assert_not_empty "$DB_BASELINE" "baseline_value should be set for login-based relative goal"

#============================================================================
# Step 5: Backdate updated_at by 2 days to simulate rotation
#============================================================================
print_step 5 "Backdate updated_at by 2 days to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 6: Verify goal shows not_started after rotation
#============================================================================
print_step 6 "Verify login goal resets after rotation"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "not_started" "$STATUS" "Login goal should be not_started after rotation"
assert_equals "0" "$PROGRESS" "Progress should be 0 after rotation reset"

#============================================================================
# Step 7: Trigger another login event in new period
#============================================================================
print_step 7 "Trigger another login event in new rotation period"

run_cli trigger-event login > /dev/null 2>&1
wait_for_flush 3

#============================================================================
# Step 8: Verify goal completes again in new period
#============================================================================
print_step 8 "Verify login goal completes again in new period"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "completed" "$STATUS" "Login goal should be completed again in new period"
assert_gte "$PROGRESS" "1" "Progress should be >= 1 in new period"

#============================================================================
# Step 9: Verify DB baseline updated to new value
#============================================================================
print_step 9 "Verify DB baseline updated for new period"

DB_BASELINE_NEW=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")
assert_not_empty "$DB_BASELINE_NEW" "baseline_value should be set after second login event"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
assert_equals "completed" "$DB_STATUS" "DB status should be 'completed' after re-completion"

print_success "M5 Rotation Login - Login Events with Daily Rotation"
