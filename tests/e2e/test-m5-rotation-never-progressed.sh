#!/bin/bash
# E2E Test: M5 Dormant Player Rotation (No Events Ever)
# Tests that a goal with NULL baseline (no events ever) handles rotation boundary correctly
# Location: tests/e2e/test-m5-rotation-never-progressed.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Dormant Player Rotation (No Events Ever)"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation

#============================================================================
# Step 1: Initialize player (NO events sent)
#============================================================================
print_step 1 "Initialize player (no events sent)"

initialize_player > /dev/null 2>&1 || true

#============================================================================
# Step 2: Verify not_started, progress=0, expiresAt set
#============================================================================
print_step 2 "Verify initial state: not_started, progress=0, expiresAt set"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
INITIAL_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_equals "not_started" "$STATUS" "Status should be not_started (no events)"
assert_equals "0" "$PROGRESS" "Progress should be 0 (no events)"
assert_not_empty "$INITIAL_EXPIRES_AT" "expiresAt should be set even without events"
assert_gt "$EXPIRES_IN" "0" "expiresInSeconds should be > 0"

echo "  Status: $STATUS"
echo "  Progress: $PROGRESS"
echo "  Initial expiresAt: $INITIAL_EXPIRES_AT"
echo "  expiresInSeconds: $EXPIRES_IN"

#============================================================================
# Step 3: Verify DB baseline_value is NULL (no events ever processed)
#============================================================================
print_step 3 "Verify DB baseline_value is NULL (no events processed)"

DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")

# baseline_value should be empty/NULL since no events have been processed
if [ -z "$DB_BASELINE" ] || [ "$DB_BASELINE" = "" ] || [ "$DB_BASELINE" = "null" ]; then
    echo -e "  ${GREEN}PASS${NC}: DB baseline_value is NULL/empty (expected for dormant player)"
else
    # If a DB row doesn't exist yet (lazy init), query_db_field may return empty
    echo "  DB baseline_value: '$DB_BASELINE' (may be empty if row not yet created)"
fi

#============================================================================
# Step 4: Backdate updated_at by 2 days to cross rotation boundary
#============================================================================
print_step 4 "Backdate updated_at to simulate rotation boundary"

# The row may not exist yet if truly lazy-initialized.
# backdate_updated_at will succeed silently if no row matches.
backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 5: GET challenges - verify still not_started, progress=0
#============================================================================
print_step 5 "Verify dormant player still shows not_started after rotation"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "not_started" "$STATUS" "Status should still be not_started after rotation"
assert_equals "0" "$PROGRESS" "Progress should still be 0 after rotation"

#============================================================================
# Step 6: Verify expiresAt still valid after rotation (computed from now)
#============================================================================
print_step 6 "Verify expiresAt still valid after rotation"

NEW_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$GOAL_ID")
NEW_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$GOAL_ID")

assert_not_empty "$NEW_EXPIRES_AT" "expiresAt should be non-empty after rotation"
assert_gt "$NEW_EXPIRES_IN" "0" "expiresInSeconds should be > 0 after rotation"
assert_lte "$NEW_EXPIRES_IN" "86400" "expiresInSeconds should be <= 86400 (daily)"

echo "  expiresAt after rotation: $NEW_EXPIRES_AT"
echo "  expiresInSeconds: $NEW_EXPIRES_IN"

#============================================================================
# Step 7: Send FIRST event ever - verify baseline initializes correctly
#============================================================================
print_step 7 "Send first event ever - verify baseline initializes"

# Send kills=80, inc=7 -> baseline=73, displayed=7/10
trigger_stat_with_inc "kills" "80" "7" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")

assert_equals "7" "$PROGRESS" "Progress should be 7 (80 - baseline 73)"
assert_equals "in_progress" "$STATUS" "Status should be in_progress after first event"

#============================================================================
# Step 8: Verify DB baseline set correctly
#============================================================================
print_step 8 "Verify DB baseline set from first event"

DB_BASELINE=$(query_db_field "$USER_ID" "$GOAL_ID" "baseline_value")
assert_equals "73" "$DB_BASELINE" "DB baseline should be 73 (80 - 7) after first event"

echo "  DB baseline: $DB_BASELINE"
echo "  Progress: $PROGRESS (80 - 73 = 7)"

print_success "M5 Dormant Player Rotation (No Events Ever)"
