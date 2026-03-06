#!/bin/bash
# E2E Test: M5 Completed Goal Preserved When resetProgress=false
# Tests that a completed goal stays completed across rotation when resetProgress=false
# Location: tests/e2e/test-m5-rotation-completed-preserved.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Completed Goal Preserved (resetProgress=false)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="weekly-challenges"
GOAL_ID="weekly-wins-no-reset"  # wins >= 5, relative mode, weekly rotation, resetProgress=false, allowReselection=false

#============================================================================
# Step 1: Initialize player and complete the goal
#============================================================================
print_step 1 "Initialize and complete the weekly-wins-no-reset goal"

initialize_player > /dev/null 2>&1 || true

# Send wins=100, inc=5 -> baseline=95, displayed=5/5 -> completed
trigger_stat_with_inc "wins" "100" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "5" "Progress should be >= 5 (target reached)"
assert_equals "completed" "$STATUS" "Status should be completed after reaching target"

#============================================================================
# Step 2: Verify DB status is completed
#============================================================================
print_step 2 "Verify DB shows completed status before rotation"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
assert_equals "completed" "$DB_STATUS" "DB status should be 'completed' before rotation"

#============================================================================
# Step 3: Backdate updated_at by 8 days to cross weekly rotation boundary
#============================================================================
print_step 3 "Backdate updated_at by 8 days to simulate weekly rotation"

backdate_updated_at "$USER_ID" "$GOAL_ID" "8 days"

#============================================================================
# Step 4: GET challenges - completed status should be preserved
#============================================================================
print_step 4 "Verify completed status preserved after rotation (resetProgress=false)"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "completed" "$STATUS" "Status should still be 'completed' (resetProgress=false preserves completed)"
assert_gte "$PROGRESS" "5" "Progress should still be >= 5 (not reset)"

#============================================================================
# Step 5: Verify DB status is still completed
#============================================================================
print_step 5 "Verify DB status unchanged after rotation display"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
assert_equals "completed" "$DB_STATUS" "DB status should still be 'completed' after rotation"

#============================================================================
# Step 6: Verify expiresAt is still present
#============================================================================
print_step 6 "Verify expiresAt still present for completed preserved goal"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$EXPIRES_AT" "expiresAt should still be present on preserved completed goal"

echo "  Status: $STATUS (preserved across rotation)"
echo "  expiresAt: $EXPIRES_AT"
echo "  expiresInSeconds: $EXPIRES_IN"

print_success "M5 Completed Goal Preserved (resetProgress=false)"
