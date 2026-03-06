#!/bin/bash
# E2E Test: M5 Monthly Rotation Schedule
# Tests that the monthly rotation schedule works end-to-end
# Location: tests/e2e/test-m5-rotation-monthly.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Monthly Rotation Schedule"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="monthly-challenges"
GOAL_ID="monthly-kills-goal"  # kills >= 500, relative mode, monthly rotation, resetProgress=true

#============================================================================
# Step 1: Initialize player - monthly rotation goal becomes active
#============================================================================
print_step 1 "Initialize player for monthly rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Monthly rotation goal should start as not_started"

ACTIVE=$(get_goal_active_status "$CHALLENGES" "$GOAL_ID")
assert_equals "true" "$ACTIVE" "Monthly rotation goal should be active (defaultAssigned=true)"

#============================================================================
# Step 2: Send kills=600, inc=500 -> baseline=100, displayed=500/500 -> completed
#============================================================================
print_step 2 "Send stat update to complete monthly goal (kills=600, inc=500)"

trigger_stat_with_inc "kills" "600" "500" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "500" "Progress should be >= 500 (600 - baseline 100)"
assert_equals "completed" "$STATUS" "Status should be completed after reaching target"

#============================================================================
# Step 3: Verify expiresAt and expiresInSeconds for monthly schedule
#============================================================================
print_step 3 "Verify monthly rotation expiry fields"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$EXPIRES_AT" "expiresAt should be non-empty for monthly rotation goal"
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0"

# Monthly expiry should be <= ~31 days (2678400 seconds)
assert_lte "$EXPIRES_IN" "2678400" "expiresInSeconds should be <= 2678400 (31 days)"

echo "  expiresAt: $EXPIRES_AT"
echo "  expiresInSeconds: $EXPIRES_IN"

#============================================================================
# Step 4: Backdate updated_at by 32 days to cross monthly boundary
#============================================================================
print_step 4 "Backdate updated_at by 32 days to simulate monthly rotation"

backdate_updated_at "$USER_ID" "$GOAL_ID" "32 days"

#============================================================================
# Step 5: Verify display-only rotation reset
#============================================================================
print_step 5 "Verify display-only rotation (progress=0, status=not_started)"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "0" "$PROGRESS" "Progress should be 0 after monthly rotation"
assert_equals "not_started" "$STATUS" "Status should be not_started after monthly rotation"

#============================================================================
# Step 6: Send new event in new period and verify progress
#============================================================================
print_step 6 "Send stat update in new monthly period"

# Send kills=610, inc=10 -> new baseline, displayed=10/500
trigger_stat_with_inc "kills" "610" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

assert_equals "10" "$PROGRESS" "Progress should be 10 in new monthly period"
assert_equals "in_progress" "$STATUS" "Status should be in_progress after new event"

#============================================================================
# Step 7: Verify updated expiresInSeconds is positive
#============================================================================
print_step 7 "Verify expiresInSeconds is still positive after new event"

EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0 after new event"

print_success "M5 Monthly Rotation Schedule"
