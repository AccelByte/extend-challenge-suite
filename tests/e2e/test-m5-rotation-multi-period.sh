#!/bin/bash
# E2E Test: M5 Multiple Missed Rotation Periods
# Tests that missing multiple rotation periods behaves identically to missing one
# Location: tests/e2e/test-m5-rotation-multi-period.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Multi-Period - Multiple Missed Periods"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Goal should start as not_started"

#============================================================================
# Step 2: Complete the goal (kills=300, inc=10 -> baseline=290, displayed=10/10)
#============================================================================
print_step 2 "Send stat update to complete goal (kills=300, inc=10)"

trigger_stat_with_inc "kills" "300" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "completed" "$STATUS" "Goal should be completed"

#============================================================================
# Step 3: Backdate by 7 days (7 missed daily periods)
#============================================================================
print_step 3 "Backdate updated_at by 7 days (7 missed daily rotation periods)"

backdate_updated_at "$USER_ID" "$GOAL_ID" "7 days"

#============================================================================
# Step 4: Verify goal shows not_started with progress=0 (same as 1-period miss)
#============================================================================
print_step 4 "Verify goal resets identically to single-period miss"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "not_started" "$STATUS" "Goal should be not_started after 7 missed periods"
assert_equals "0" "$PROGRESS" "Progress should be 0 after 7 missed periods (no accumulated debt)"

#============================================================================
# Step 5: Send partial progress in new period (kills=310, inc=5)
#============================================================================
print_step 5 "Send partial stat update in new period (kills=310, inc=5)"

trigger_stat_with_inc "kills" "310" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "5" "$PROGRESS" "Progress should be 5 (fresh tracking in new period)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress"

#============================================================================
# Step 6: Verify expiresAt is set to NEXT daily boundary (not an old one)
#============================================================================
print_step 6 "Verify expiresAt points to next daily boundary"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$EXPIRES_AT" "expiresAt should be set for rotation goal"
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0 (future expiry)"

# expiresInSeconds should be <= 86400 (one day in seconds) for a daily rotation
assert_lte "$EXPIRES_IN" "86400" "expiresInSeconds should be <= 86400 (one day)"

#============================================================================
# Step 7: Complete goal in new period and verify it works normally
#============================================================================
print_step 7 "Complete goal in new period to verify normal function"

trigger_stat_with_inc "kills" "315" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "10" "Progress should be >= 10 (target reached)"
assert_equals "completed" "$STATUS" "Goal should be completed in new period"

print_success "M5 Rotation Multi-Period - Multiple Missed Periods"
