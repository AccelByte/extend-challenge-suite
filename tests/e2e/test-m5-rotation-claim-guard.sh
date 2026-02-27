#!/bin/bash
# E2E Test: M5 Claim-After-Rotation Guard
# Tests that claiming a completed goal AFTER rotation boundary returns an error (not success)
# Location: tests/e2e/test-m5-rotation-claim-guard.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Claim Guard - Reject Stale Claims"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, relative mode, daily rotation, allowReselection=true

#============================================================================
# Step 1: Initialize player
#============================================================================
print_step 1 "Initialize player for rotation goals"

initialize_player > /dev/null 2>&1 || true

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Goal should start as not_started"

#============================================================================
# Step 2: Complete the goal (kills=100, inc=10 -> baseline=90, displayed=10/10)
#============================================================================
print_step 2 "Send stat update to complete goal (kills=100, inc=10)"

trigger_stat_with_inc "kills" "100" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "completed" "$STATUS" "Goal should be completed after reaching target"

#============================================================================
# Step 3: Backdate updated_at by 2 days to simulate rotation
#============================================================================
print_step 3 "Backdate updated_at by 2 days to simulate rotation boundary"

backdate_updated_at "$USER_ID" "$GOAL_ID" "2 days"

#============================================================================
# Step 4: Attempt claim on rotated goal (should fail)
#============================================================================
print_step 4 "Attempt claim on rotated goal - should be rejected"

# Capture claim output including errors (don't exit on failure)
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json 2>&1 || true)

# The claim should NOT succeed - check for error indicators
# The service should reject the claim because the goal has rotated
if echo "$CLAIM_RESULT" | grep -qi '"status".*:.*"success"'; then
    echo -e "${RED}❌ FAIL${NC}: Claim succeeded but should have been rejected after rotation"
    echo "  Claim result: $CLAIM_RESULT"
    exit 1
fi
echo -e "${GREEN}✅ PASS${NC}: Claim was rejected (did not return success)"

#============================================================================
# Step 5: Verify API shows goal as not_started (rotation display)
#============================================================================
print_step 5 "Verify API shows goal as not_started after rotation"

CHALLENGES=$(get_user_progress)
STATUS=$(get_goal_status "$CHALLENGES" "$GOAL_ID")
assert_equals "not_started" "$STATUS" "Goal should show not_started after rotation (allowReselection=true)"

PROGRESS=$(get_goal_progress "$CHALLENGES" "$GOAL_ID")
assert_equals "0" "$PROGRESS" "Progress should be 0 after rotation reset"

#============================================================================
# Step 6: Verify DB status is NOT "claimed" (claim was rejected)
#============================================================================
print_step 6 "Verify DB status is not claimed (claim was rejected)"

DB_STATUS=$(query_db_field "$USER_ID" "$GOAL_ID" "status")

# The DB status should be "completed" (original status) since the claim was rejected,
# or could be reset by the rotation display logic. Either way, NOT "claimed".
assert_not_equals "claimed" "$DB_STATUS" "DB status should not be 'claimed' - claim was rejected after rotation"

print_success "M5 Rotation Claim Guard - Reject Stale Claims"
