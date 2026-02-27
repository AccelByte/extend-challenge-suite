#!/bin/bash
# E2E Test: M5 Cross-Challenge Isolation (Rotation vs Absolute)
# Tests that absolute (non-rotating) goal progress is preserved when rotation goals reset
# Location: tests/e2e/test-m5-rotation-absolute-coexist.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Cross-Challenge Isolation (Rotation vs Absolute)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

ROTATION_CHALLENGE="rotation-daily"
ROTATION_GOAL="daily-challenges-goal-01"    # kills >= 10, relative, daily rotation, resetProgress=true
ABSOLUTE_CHALLENGE="challenge-001"
ABSOLUTE_GOAL="challenge-001-goal-01"       # login_count >= 1, absolute, no rotation

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for both rotation and absolute challenges"

initialize_player > /dev/null 2>&1 || true

#============================================================================
# Step 2: Complete the rotation goal (kills)
#============================================================================
print_step 2 "Complete the rotation goal (10 kills)"

# Send kills=50, inc=10 -> baseline=40, displayed=10/10 -> completed
trigger_stat_with_inc "kills" "50" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
ROT_STATUS=$(get_goal_status "$CHALLENGES" "$ROTATION_GOAL")
ROT_PROGRESS=$(get_goal_progress "$CHALLENGES" "$ROTATION_GOAL")

assert_gte "$ROT_PROGRESS" "10" "Rotation goal progress should be >= 10"
assert_equals "completed" "$ROT_STATUS" "Rotation goal should be completed"

#============================================================================
# Step 3: Complete the absolute goal (login)
#============================================================================
print_step 3 "Complete the absolute goal (1 login)"

run_cli trigger-event login > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
ABS_STATUS=$(get_goal_status "$CHALLENGES" "$ABSOLUTE_GOAL")
ABS_PROGRESS=$(get_goal_progress "$CHALLENGES" "$ABSOLUTE_GOAL")

assert_gte "$ABS_PROGRESS" "1" "Absolute goal progress should be >= 1"
assert_equals "completed" "$ABS_STATUS" "Absolute goal should be completed"

#============================================================================
# Step 4: Verify rotation goal has expiresAt, absolute does not
#============================================================================
print_step 4 "Verify expiry fields differ between rotation and absolute goals"

ROT_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$ROTATION_GOAL")
ROT_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$ROTATION_GOAL")
ABS_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$ABSOLUTE_GOAL")

assert_not_empty "$ROT_EXPIRES_AT" "Rotation goal should have expiresAt"
assert_gt "$ROT_EXPIRES_IN" "0" "Rotation goal expiresInSeconds should be > 0"
assert_equals "0" "$ABS_EXPIRES_IN" "Absolute goal expiresInSeconds should be 0"

echo "  Rotation goal: expiresAt=$ROT_EXPIRES_AT, expiresInSeconds=$ROT_EXPIRES_IN"
echo "  Absolute goal: expiresInSeconds=$ABS_EXPIRES_IN (no rotation)"

#============================================================================
# Step 5: Backdate ONLY the rotation goal by 2 days
#============================================================================
print_step 5 "Backdate rotation goal to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$ROTATION_GOAL" "2 days"

#============================================================================
# Step 6: Verify rotation goal reset, absolute goal preserved
#============================================================================
print_step 6 "Verify rotation goal reset while absolute goal preserved"

CHALLENGES=$(get_user_progress)

# Rotation goal should be reset
ROT_STATUS=$(get_goal_status "$CHALLENGES" "$ROTATION_GOAL")
ROT_PROGRESS=$(get_goal_progress "$CHALLENGES" "$ROTATION_GOAL")

assert_equals "not_started" "$ROT_STATUS" "Rotation goal should be not_started after rotation"
assert_equals "0" "$ROT_PROGRESS" "Rotation goal progress should be 0 after rotation"

# Absolute goal should be untouched
ABS_STATUS=$(get_goal_status "$CHALLENGES" "$ABSOLUTE_GOAL")
ABS_PROGRESS=$(get_goal_progress "$CHALLENGES" "$ABSOLUTE_GOAL")

assert_equals "completed" "$ABS_STATUS" "Absolute goal should still be completed"
assert_gte "$ABS_PROGRESS" "1" "Absolute goal progress should still be >= 1"

echo "  Rotation goal: status=$ROT_STATUS, progress=$ROT_PROGRESS (reset)"
echo "  Absolute goal: status=$ABS_STATUS, progress=$ABS_PROGRESS (preserved)"

#============================================================================
# Step 7: Verify absolute goal in DB is still completed
#============================================================================
print_step 7 "Verify absolute goal DB status unchanged"

DB_ABS_STATUS=$(query_db_field "$USER_ID" "$ABSOLUTE_GOAL" "status")
assert_equals "completed" "$DB_ABS_STATUS" "DB status for absolute goal should still be completed"

print_success "M5 Cross-Challenge Isolation (Rotation vs Absolute)"
