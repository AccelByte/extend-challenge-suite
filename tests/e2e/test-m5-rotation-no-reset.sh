#!/bin/bash
# E2E Test: M5 Weekly No-Reset
# Tests that resetProgress=false preserves progress across rotation
# Location: tests/e2e/test-m5-rotation-no-reset.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation No-Reset - Weekly Progress Preservation"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="weekly-challenges"
GOAL_ID="weekly-wins-no-reset"  # wins >= 5, relative mode, weekly rotation, resetProgress=false

#============================================================================
# Step 1: Initialize and send wins=20, inc=3 -> displayed=3/5
#============================================================================
print_step 1 "Initialize and send stat update"

initialize_player > /dev/null 2>&1 || true

trigger_stat_with_inc "wins" "20" "3" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

assert_equals "3" "$PROGRESS" "Progress should be 3 (20 - baseline 17)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress"

#============================================================================
# Step 2: Backdate updated_at by 8 days to cross weekly rotation boundary
#============================================================================
print_step 2 "Backdate updated_at to simulate weekly rotation"

backdate_updated_at "$USER_ID" "$GOAL_ID" "8 days"

#============================================================================
# Step 3: GET challenges - progress should be preserved (no reset)
#============================================================================
print_step 3 "Verify progress preserved after rotation (no reset)"

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "3" "$PROGRESS" "Progress should still be 3 (resetProgress=false preserves progress)"

#============================================================================
# Step 4: Send more wins to continue accumulating progress
#============================================================================
print_step 4 "Send more wins to continue progress"

# Send wins=23, inc=3 -> progress should add to existing
trigger_stat_with_inc "wins" "23" "3" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

# Progress should now be 6 (23 - baseline 17 = 6, or continued from 3 + new 3)
assert_gte "$PROGRESS" "5" "Progress should be >= 5 after additional wins"
assert_equals "completed" "$STATUS" "Status should be completed after reaching target of 5"

print_success "M5 Rotation No-Reset - Weekly Progress Preservation"
