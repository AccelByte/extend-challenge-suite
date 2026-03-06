#!/bin/bash
# E2E Test: M5 Daily Rotation with Reset
# Tests display-only rotation detection and event-driven rotation reset
# Location: tests/e2e/test-m5-rotation-reset.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Reset - Daily Rotation with Progress Reset"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation, resetProgress=true

#============================================================================
# Step 1: Complete the daily-kills goal
#============================================================================
print_step 1 "Complete the daily-kills goal"

initialize_player > /dev/null 2>&1 || true

# Send kills=50, inc=10 -> baseline=40, displayed=10/10 -> completed
trigger_stat_with_inc "kills" "50" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "10" "Progress should be >= 10"
assert_equals "completed" "$STATUS" "Status should be completed"

#============================================================================
# Step 2: Backdate updated_at by 2 days to simulate rotation boundary crossed
#============================================================================
print_step 2 "Backdate updated_at to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 3: GET challenges - verify display-only rotation reset
#============================================================================
print_step 3 "Verify display-only rotation (progress=0, status=not_started)"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "0" "$PROGRESS" "Progress should be 0 after display-only rotation"
assert_equals "not_started" "$STATUS" "Status should be not_started after rotation"

#============================================================================
# Step 4: Send stat event to trigger SQL CASE rotation reset
#============================================================================
print_step 4 "Trigger event to cause SQL CASE rotation reset"

# Send kills=55, inc=5 -> new baseline=50, displayed=5
trigger_stat_with_inc "kills" "55" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "5" "$PROGRESS" "Progress should be 5 (55 - new baseline 50)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress after rotation reset"

#============================================================================
# Step 5: Verify DB baseline was reset
#============================================================================
print_step 5 "Verify DB baseline_value was reset"

DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")
assert_equals "50" "$DB_BASELINE" "DB baseline_value should be 50 after rotation reset"

print_success "M5 Rotation Reset - Daily Rotation with Progress Reset"
