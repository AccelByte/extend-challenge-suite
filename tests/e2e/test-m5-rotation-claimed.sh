#!/bin/bash
# E2E Test: M5 Claimed Goal Protection
# Tests allowReselection=false (permanent claim) and allowReselection=true (resets on rotation)
# Location: tests/e2e/test-m5-rotation-claimed.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Claimed - Goal Protection & Reselection"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

DAILY_CHALLENGE="rotation-daily"

#============================================================================
# Part A: Permanent claim (allowReselection=false)
# Goal: daily-wins-no-reselect (wins >= 3, daily, resetProgress=true, allowReselection=false)
#============================================================================
print_step 1 "Part A: Complete and claim daily-wins-no-reselect (allowReselection=false)"

PERM_GOAL="daily-wins-no-reselect"

initialize_player > /dev/null 2>&1 || true

# Complete the goal: wins=30, inc=3 -> baseline=27, displayed=3/3 -> completed
trigger_stat_with_inc "wins" "30" "3" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$PERM_GOAL")
assert_equals "completed" "$STATUS" "daily-wins-no-reselect should be completed"

# Claim the reward
print_step 2 "Claim daily-wins-no-reselect reward"

CLAIM_RESULT=$(run_cli claim-reward "$DAILY_CHALLENGE" "$PERM_GOAL" --format=json 2>&1 || true)

# Verify claimed status
CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$PERM_GOAL")
assert_equals "claimed" "$STATUS" "daily-wins-no-reselect should be claimed"

# Backdate to simulate rotation
print_step 3 "Backdate and verify permanent claim survives rotation"

backdate_updated_at "$USER_ID" "$PERM_GOAL" "2 days"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$PERM_GOAL")
assert_equals "claimed" "$STATUS" "daily-wins-no-reselect should STILL be claimed (allowReselection=false)"

#============================================================================
# Part B: Reselectable claim (allowReselection=true)
# Goal: daily-challenges-goal-02 (wins >= 3, daily, resetProgress=true, allowReselection=true)
#============================================================================
print_step 4 "Part B: Complete and claim daily-challenges-goal-02 (allowReselection=true)"

RESELECT_GOAL="daily-challenges-goal-02"

# Complete the goal: wins=35, inc=5 -> should complete
trigger_stat_with_inc "wins" "35" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$RESELECT_GOAL")
assert_equals "completed" "$STATUS" "daily-challenges-goal-02 should be completed"

# Claim the reward
print_step 5 "Claim daily-challenges-goal-02 reward"

CLAIM_RESULT=$(run_cli claim-reward "$DAILY_CHALLENGE" "$RESELECT_GOAL" --format=json 2>&1 || true)

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$RESELECT_GOAL")
assert_equals "claimed" "$STATUS" "daily-challenges-goal-02 should be claimed"

# Backdate to simulate rotation
print_step 6 "Backdate and verify reselectable goal resets on rotation"

backdate_updated_at "$USER_ID" "$RESELECT_GOAL" "2 days"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$RESELECT_GOAL")
assert_equals "not_started" "$STATUS" "daily-challenges-goal-02 should be not_started after rotation (allowReselection=true)"

print_success "M5 Rotation Claimed - Goal Protection & Reselection"
