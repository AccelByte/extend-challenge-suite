#!/bin/bash
# E2E Test: M5 Full Rotation Cycle
# Tests the complete repeatable daily challenge story: complete -> claim -> rotate -> complete again -> claim again
# Location: tests/e2e/test-m5-rotation-full-cycle.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Full Cycle - Complete->Claim->Rotate->Repeat"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-02"  # wins >= 3, relative mode, daily rotation, allowReselection=true

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Goal should start as not_started"

#============================================================================
# Step 2: Complete the goal (wins=50, inc=3 -> baseline=47, displayed=3/3)
#============================================================================
print_step 2 "Send stat update to complete goal (wins=50, inc=3)"

trigger_stat_with_inc "wins" "50" "3" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "3" "Progress should be >= 3 (target reached)"
assert_equals "completed" "$STATUS" "Goal should be completed"

#============================================================================
# Step 3: Claim reward (first claim)
#============================================================================
print_step 3 "Claim reward for first completion"

CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json 2>&1 || true)

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "claimed" "$STATUS" "Goal should be claimed after first claim"

#============================================================================
# Step 4: Backdate updated_at by 2 days to simulate rotation
#============================================================================
print_step 4 "Backdate updated_at by 2 days to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 5: Verify goal resets after rotation (allowReselection=true)
#============================================================================
print_step 5 "Verify goal shows not_started after rotation"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "not_started" "$STATUS" "Goal should be not_started after rotation (allowReselection=true)"
assert_equals "0" "$PROGRESS" "Progress should be 0 after rotation reset"

#============================================================================
# Step 6: Complete goal again in new period (wins=55, inc=3 -> new baseline=52)
#============================================================================
print_step 6 "Send stat update to complete goal again in new period"

trigger_stat_with_inc "wins" "55" "3" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "3" "Progress should be >= 3 in new period"
assert_equals "completed" "$STATUS" "Goal should be completed again in new period"

#============================================================================
# Step 7: Claim reward again (second claim)
#============================================================================
print_step 7 "Claim reward for second completion"

CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json 2>&1 || true)

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "claimed" "$STATUS" "Goal should be claimed after second claim"

#============================================================================
# Step 8: Verify DB state shows claimed (second claim persisted)
#============================================================================
print_step 8 "Verify DB shows claimed status (second claim persisted)"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")
assert_equals "claimed" "$DB_STATUS" "DB status should be 'claimed' after second successful claim"

DB_CLAIMED_AT=$(query_db_field "$USER_ID" "$GOAL_ID" "claimed_at")
assert_not_empty "$DB_CLAIMED_AT" "claimed_at should be set in DB after second claim"

print_success "M5 Rotation Full Cycle - Complete->Claim->Rotate->Repeat"
