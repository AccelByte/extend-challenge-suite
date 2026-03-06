#!/bin/bash
# E2E Test: M5 ExpiresAt/ExpiresInSeconds Fields
# Verifies rotation goals have expiry fields populated and non-rotation goals don't
# Location: tests/e2e/test-m5-rotation-expiry-fields.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Expiry Fields (expiresAt / expiresInSeconds)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

ROTATION_CHALLENGE="rotation-daily"
ROTATION_GOAL="daily-challenges-goal-01"
NON_ROTATION_CHALLENGE="daily-challenges"

#============================================================================
# Step 1: Initialize player and get challenges
#============================================================================
print_step 1 "Initialize player and fetch challenges"

initialize_player > /dev/null 2>&1 || true

# Trigger a stat event to ensure rotation goals have DB rows
trigger_stat_with_inc "kills" "1" "1" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)

#============================================================================
# Step 2: Verify rotation goal has expiry fields
#============================================================================
print_step 2 "Verify rotation goal has expiry fields"

EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$ROTATION_GOAL")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$ROTATION_GOAL")

assert_not_empty "$EXPIRES_AT" "Rotation goal expiresAt should be non-empty"
assert_gt "$EXPIRES_IN" "0" "Rotation goal expiresInSeconds should be > 0"

# Verify expiresAt is a valid RFC3339 timestamp
assert_contains "$EXPIRES_AT" "T" "expiresAt should contain 'T' (RFC3339 format)"

echo "  expiresAt: $EXPIRES_AT"
echo "  expiresInSeconds: $EXPIRES_IN"

#============================================================================
# Step 3: Verify non-rotation goal does NOT have expiry fields
#============================================================================
print_step 3 "Verify non-rotation goal does not have expiry fields"

# Find a non-rotation goal from the daily-challenges (M4) challenge
NON_ROTATION_GOAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$NON_ROTATION_CHALLENGE\") | .goals[0].goalId // \"\"" 2>/dev/null)

if [ -z "$NON_ROTATION_GOAL" ] || [ "$NON_ROTATION_GOAL" = "null" ]; then
    echo -e "${YELLOW}⚠${NC} No non-rotation challenge found, skipping non-rotation check"
else
    NON_ROT_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$NON_ROTATION_GOAL")
    NON_ROT_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$NON_ROTATION_GOAL")

    # Non-rotation goals should have empty expiresAt and 0 expiresInSeconds
    if [ -z "$NON_ROT_EXPIRES_AT" ] || [ "$NON_ROT_EXPIRES_AT" = "" ] || [ "$NON_ROT_EXPIRES_AT" = "null" ]; then
        echo -e "${GREEN}✅ PASS${NC}: Non-rotation goal expiresAt is empty"
    else
        # If expiresAt is present but empty string, that's also OK
        assert_equals "" "$NON_ROT_EXPIRES_AT" "Non-rotation goal expiresAt should be empty"
    fi

    assert_equals "0" "$NON_ROT_EXPIRES_IN" "Non-rotation goal expiresInSeconds should be 0"
fi

#============================================================================
# Step 4: Verify second rotation goal also has expiry
#============================================================================
print_step 4 "Verify second rotation goal also has expiry fields"

GOAL_02="daily-challenges-goal-02"

# Trigger wins too to ensure goal-02 has a DB row
trigger_stat_with_inc "wins" "1" "1" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
EXPIRES_AT_02=$(get_goal_expires_at "$CHALLENGES" "$GOAL_02")
EXPIRES_IN_02=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_02")

assert_not_empty "$EXPIRES_AT_02" "Second rotation goal expiresAt should be non-empty"
assert_gt "$EXPIRES_IN_02" "0" "Second rotation goal expiresInSeconds should be > 0"

print_success "M5 Rotation Expiry Fields"
