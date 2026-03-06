#!/bin/bash
# E2E Test: M5 Relative Progress & Baseline
# Tests that relative progress mode correctly computes displayed_progress = stat_value - baseline
# Location: tests/e2e/test-m5-rotation-basic.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Basic - Relative Progress & Baseline"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation

#============================================================================
# Step 1: Initialize player - rotation goals become active
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Rotation goal should start as not_started"

ACTIVE=$(get_goal_active_status "$CHALLENGES" "$GOAL_ID")
assert_equals "true" "$ACTIVE" "Rotation goal should be active (defaultAssigned=true)"

#============================================================================
# Step 2: Send kills=100, inc=5 -> baseline initializes to 95, displayed=5/10
#============================================================================
print_step 2 "Send stat update with inc=5 to initialize baseline"

trigger_stat_with_inc "kills" "100" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

assert_equals "5" "$PROGRESS" "Progress should be 5 (100 - baseline 95)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress"

#============================================================================
# Step 3: Verify expiresAt and expiresInSeconds are populated
#============================================================================
print_step 3 "Verify rotation expiry fields"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$EXPIRES_AT" "expiresAt should be non-empty for rotation goals"
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0"

#============================================================================
# Step 4: Send kills=105, inc=5 -> displayed=10/10, should complete
#============================================================================
print_step 4 "Send stat update to reach target (10 kills)"

trigger_stat_with_inc "kills" "105" "5" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")

assert_gte "$PROGRESS" "10" "Progress should be >= 10 (105 - baseline 95)"
assert_equals "completed" "$STATUS" "Status should be completed after reaching target"

print_success "M5 Rotation Basic - Relative Progress & Baseline"
