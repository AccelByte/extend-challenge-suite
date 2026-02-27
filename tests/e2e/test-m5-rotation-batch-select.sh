#!/bin/bash
# E2E Test: M5 Batch Select Sets Rotation Expiry (M4+M5 Integration)
# Tests that M4 batch-select correctly populates expires_at for rotation goals
# Location: tests/e2e/test-m5-rotation-batch-select.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Batch Select Sets Rotation Expiry (M4+M5 Integration)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_01="daily-challenges-goal-01"  # kills >= 10, daily rotation
GOAL_02="daily-challenges-goal-02"  # wins >= 3, daily rotation

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player"

initialize_player > /dev/null 2>&1 || true

#============================================================================
# Step 2: Batch-select two rotation goals
#============================================================================
print_step 2 "Batch-select two rotation goals"

RESULT=$(batch_select_goals "$CHALLENGE_ID" "$GOAL_01,$GOAL_02" "false")

SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length')
assert_gte "$SELECTED_COUNT" "2" "Should select at least 2 goals"

echo "  Selected goals: $SELECTED_COUNT"

#============================================================================
# Step 3: Verify both goals have expiresAt and expiresInSeconds
#============================================================================
print_step 3 "Verify both goals have rotation expiry fields populated"

CHALLENGES=$(get_user_progress)

EXPIRES_AT_01=$(get_goal_expires_at "$CHALLENGES" "$GOAL_01")
EXPIRES_IN_01=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_01")
EXPIRES_AT_02=$(get_goal_expires_at "$CHALLENGES" "$GOAL_02")
EXPIRES_IN_02=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_02")

assert_not_empty "$EXPIRES_AT_01" "Goal 01 expiresAt should be non-empty"
assert_gt "$EXPIRES_IN_01" "0" "Goal 01 expiresInSeconds should be > 0"
assert_lte "$EXPIRES_IN_01" "86400" "Goal 01 expiresInSeconds should be <= 86400 (daily)"

assert_not_empty "$EXPIRES_AT_02" "Goal 02 expiresAt should be non-empty"
assert_gt "$EXPIRES_IN_02" "0" "Goal 02 expiresInSeconds should be > 0"
assert_lte "$EXPIRES_IN_02" "86400" "Goal 02 expiresInSeconds should be <= 86400 (daily)"

echo "  Goal 01: expiresAt=$EXPIRES_AT_01, expiresInSeconds=$EXPIRES_IN_01"
echo "  Goal 02: expiresAt=$EXPIRES_AT_02, expiresInSeconds=$EXPIRES_IN_02"

#============================================================================
# Step 4: Assert both share same expiresAt (same daily schedule)
#============================================================================
print_step 4 "Verify both goals share same daily rotation boundary"

assert_equals "$EXPIRES_AT_01" "$EXPIRES_AT_02" "Both daily goals should share same expiresAt"

echo "  Goal 01 expiresAt: $EXPIRES_AT_01"
echo "  Goal 02 expiresAt: $EXPIRES_AT_02"
echo "  Match: YES (same daily boundary)"

#============================================================================
# Step 5: Verify both goals are active and not_started
#============================================================================
print_step 5 "Verify both goals are active and not_started"

STATUS_01=$(get_goal_status "$CHALLENGES" "$GOAL_01")
STATUS_02=$(get_goal_status "$CHALLENGES" "$GOAL_02")
ACTIVE_01=$(get_goal_active_status "$CHALLENGES" "$GOAL_01")
ACTIVE_02=$(get_goal_active_status "$CHALLENGES" "$GOAL_02")

assert_equals "not_started" "$STATUS_01" "Goal 01 should be not_started"
assert_equals "not_started" "$STATUS_02" "Goal 02 should be not_started"
assert_equals "true" "$ACTIVE_01" "Goal 01 should be active"
assert_equals "true" "$ACTIVE_02" "Goal 02 should be active"

#============================================================================
# Step 6: Trigger stat event and verify relative progress works
#============================================================================
print_step 6 "Trigger stat event and verify relative progress for batch-selected goal"

# Send kills=80, inc=5 -> baseline=75, displayed=5/10 for goal-01
trigger_stat_with_inc "kills" "80" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS_01=$(get_goal_progress "$CHALLENGES" "$GOAL_01")
STATUS_01=$(get_goal_status "$CHALLENGES" "$GOAL_01")

assert_equals "5" "$PROGRESS_01" "Goal 01 progress should be 5 (80 - baseline 75)"
assert_equals "in_progress" "$STATUS_01" "Goal 01 should be in_progress"

#============================================================================
# Step 7: Verify DB expires_at is populated
#============================================================================
print_step 7 "Verify DB expires_at is populated for batch-selected goals"

DB_EXPIRES_01=$(query_db_field "$USER_ID" "$GOAL_01" "expires_at")
DB_EXPIRES_02=$(query_db_field "$USER_ID" "$GOAL_02" "expires_at")

assert_not_empty "$DB_EXPIRES_01" "DB expires_at for goal 01 should be populated"
assert_not_empty "$DB_EXPIRES_02" "DB expires_at for goal 02 should be populated"

echo "  DB goal 01 expires_at: $DB_EXPIRES_01"
echo "  DB goal 02 expires_at: $DB_EXPIRES_02"

print_success "M5 Batch Select Sets Rotation Expiry (M4+M5 Integration)"
