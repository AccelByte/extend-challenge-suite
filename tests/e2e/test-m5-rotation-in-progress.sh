#!/bin/bash
# E2E Test: M5 Partial Progress Reset on Rotation
# Tests that in_progress goals are reset to not_started when rotation boundary crosses
# Location: tests/e2e/test-m5-rotation-in-progress.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Partial Progress Reset on Rotation"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation, resetProgress=true

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Goal should start as not_started"

#============================================================================
# Step 2: Send partial progress (5/10 kills) - should be in_progress
#============================================================================
print_step 2 "Send partial progress (5/10 kills)"

# Send kills=95, inc=5 -> baseline=90, displayed=5/10
trigger_stat_with_inc "kills" "95" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "5" "$PROGRESS" "Progress should be 5 (95 - baseline 90)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress (5/10)"

#============================================================================
# Step 3: Verify DB shows in_progress with baseline set
#============================================================================
print_step 3 "Verify DB state: in_progress with baseline"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")

assert_equals "in_progress" "$DB_STATUS" "DB status should be in_progress"
assert_equals "90" "$DB_BASELINE" "DB baseline should be 90 (95 - 5)"

#============================================================================
# Step 4: Backdate updated_at by 2 days to simulate rotation boundary
#============================================================================
print_step 4 "Backdate updated_at to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 5: GET challenges - verify display-only reset (in_progress -> not_started)
#============================================================================
print_step 5 "Verify display-only rotation reset (in_progress -> not_started)"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "0" "$PROGRESS" "Progress should be 0 after rotation"
assert_equals "not_started" "$STATUS" "Status should be not_started after rotation"

#============================================================================
# Step 6: Verify expiresAt/expiresInSeconds are valid
#============================================================================
print_step 6 "Verify rotation expiry fields after reset"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$EXPIRES_AT" "expiresAt should be non-empty after rotation"
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0"
assert_lte "$EXPIRES_IN" "86400" "expiresInSeconds should be <= 86400 (daily)"

echo "  expiresAt: $EXPIRES_AT"
echo "  expiresInSeconds: $EXPIRES_IN"

#============================================================================
# Step 7: Send new event - verify fresh progress with new baseline
#============================================================================
print_step 7 "Send new event after rotation - verify fresh baseline"

# Send kills=102, inc=7 -> new baseline=95, displayed=7/10
trigger_stat_with_inc "kills" "102" "7" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "7" "$PROGRESS" "Progress should be 7 (102 - new baseline 95)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress after new event"

#============================================================================
# Step 8: Verify DB baseline was reset
#============================================================================
print_step 8 "Verify DB baseline was reset after rotation"

DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")
assert_equals "95" "$DB_BASELINE" "DB baseline should be 95 (102 - 7) after rotation reset"

print_success "M5 Partial Progress Reset on Rotation"
