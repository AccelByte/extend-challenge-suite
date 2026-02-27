#!/bin/bash
# E2E Test: M5 ExpiresAt Set at Initialization (Before Events)
# Tests that expiresAt is populated immediately after initialize-player, before any stat events
# Location: tests/e2e/test-m5-rotation-expiry-on-init.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: ExpiresAt Set at Initialization (Before Events)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

DAILY_GOAL="daily-challenges-goal-01"      # daily rotation goal
WEEKLY_GOAL="weekly-challenges-goal-01"    # weekly rotation goal
NON_ROTATION_CHALLENGE="daily-challenges"  # M4 non-rotation challenge

#============================================================================
# Step 1: Initialize player (NO events sent)
#============================================================================
print_step 1 "Initialize player (no stat events sent yet)"

initialize_player > /dev/null 2>&1 || true

#============================================================================
# Step 2: GET challenges immediately - check rotation goal expiry
#============================================================================
print_step 2 "Verify rotation goals have expiresAt immediately after init"

CHALLENGES=$(get_user_progress)

# Check daily rotation goal
DAILY_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$DAILY_GOAL")
DAILY_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$DAILY_GOAL")

assert_not_empty "$DAILY_EXPIRES_AT" "Daily rotation goal expiresAt should be set after init (before events)"
assert_gt "$DAILY_EXPIRES_IN" "0" "Daily rotation goal expiresInSeconds should be > 0 after init"

echo "  Daily goal expiresAt: $DAILY_EXPIRES_AT"
echo "  Daily goal expiresInSeconds: $DAILY_EXPIRES_IN"

# Check weekly rotation goal
WEEKLY_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$WEEKLY_GOAL")
WEEKLY_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$WEEKLY_GOAL")

assert_not_empty "$WEEKLY_EXPIRES_AT" "Weekly rotation goal expiresAt should be set after init (before events)"
assert_gt "$WEEKLY_EXPIRES_IN" "0" "Weekly rotation goal expiresInSeconds should be > 0 after init"

echo "  Weekly goal expiresAt: $WEEKLY_EXPIRES_AT"
echo "  Weekly goal expiresInSeconds: $WEEKLY_EXPIRES_IN"

#============================================================================
# Step 3: Verify non-rotation goal does NOT have expiry
#============================================================================
print_step 3 "Verify non-rotation goal has no expiry after init"

# Find a non-rotation goal from the daily-challenges (M4) challenge
NON_ROTATION_GOAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$NON_ROTATION_CHALLENGE\") | .goals[0].goalId // \"\"" 2>/dev/null)

if [ -z "$NON_ROTATION_GOAL" ] || [ "$NON_ROTATION_GOAL" = "null" ]; then
    echo -e "${YELLOW}⚠${NC} No non-rotation challenge found, skipping non-rotation check"
else
    NON_ROT_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$NON_ROTATION_GOAL")
    assert_equals "0" "$NON_ROT_EXPIRES_IN" "Non-rotation goal expiresInSeconds should be 0"
    echo "  Non-rotation goal ($NON_ROTATION_GOAL) expiresInSeconds: $NON_ROT_EXPIRES_IN"
fi

#============================================================================
# Step 4: Verify rotation goal statuses are not_started (no events yet)
#============================================================================
print_step 4 "Verify rotation goal statuses are not_started (no events sent)"

DAILY_STATUS=$(get_goal_status "$CHALLENGES" "$DAILY_GOAL")
WEEKLY_STATUS=$(get_goal_status "$CHALLENGES" "$WEEKLY_GOAL")

assert_equals "not_started" "$DAILY_STATUS" "Daily goal should be not_started (no events)"
assert_equals "not_started" "$WEEKLY_STATUS" "Weekly goal should be not_started (no events)"

print_success "M5 ExpiresAt Set at Initialization (Before Events)"
