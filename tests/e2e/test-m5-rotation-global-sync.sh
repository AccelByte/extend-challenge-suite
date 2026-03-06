#!/bin/bash
# E2E Test: M5 Global Rotation Sync (Two Users Same Boundary)
# Tests that two independent users share the same global rotation boundary
# Location: tests/e2e/test-m5-rotation-global-sync.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Global Rotation Sync (Two Users Same Boundary)"

# Pre-flight checks
check_demo_app
check_services

CHALLENGE_ID="rotation-daily"
GOAL_ID="daily-challenges-goal-01"  # kills >= 10, daily, global rotation

# Save original USER_ID
ORIGINAL_USER_ID="$USER_ID"
USER_A="test-user-rotation-sync-A"
USER_B="test-user-rotation-sync-B"

#============================================================================
# Step 1: Cleanup both test users
#============================================================================
print_step 1 "Cleanup both test users"

docker compose exec -T postgres psql -U postgres -d challenge_db -c \
    "DELETE FROM user_goal_progress WHERE user_id = '$USER_A';" > /dev/null 2>&1 || true
docker compose exec -T postgres psql -U postgres -d challenge_db -c \
    "DELETE FROM user_goal_progress WHERE user_id = '$USER_B';" > /dev/null 2>&1 || true

echo "  Cleaned up users: $USER_A, $USER_B"

#============================================================================
# Step 2: Initialize and complete goal for User A
#============================================================================
print_step 2 "Initialize and complete goal for User A"

USER_ID="$USER_A"
initialize_player > /dev/null 2>&1 || true

# Send kills=200, inc=10 -> baseline=190, displayed=10/10 -> completed
trigger_stat_with_inc "kills" "200" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES_A=$(get_user_progress)
STATUS_A=$(get_goal_status "$CHALLENGES_A" "$GOAL_ID")
assert_equals "completed" "$STATUS_A" "User A goal should be completed"

EXPIRES_AT_A=$(get_goal_expires_at "$CHALLENGES_A" "$GOAL_ID")
assert_not_empty "$EXPIRES_AT_A" "User A expiresAt should be non-empty"

echo "  User A: status=$STATUS_A, expiresAt=$EXPIRES_AT_A"

#============================================================================
# Step 3: Initialize and complete goal for User B
#============================================================================
print_step 3 "Initialize and complete goal for User B"

USER_ID="$USER_B"
initialize_player > /dev/null 2>&1 || true

# Send kills=300, inc=10 -> baseline=290, displayed=10/10 -> completed
trigger_stat_with_inc "kills" "300" "10" > /dev/null 2>&1
wait_for_flush 3

CHALLENGES_B=$(get_user_progress)
STATUS_B=$(get_goal_status "$CHALLENGES_B" "$GOAL_ID")
assert_equals "completed" "$STATUS_B" "User B goal should be completed"

EXPIRES_AT_B=$(get_goal_expires_at "$CHALLENGES_B" "$GOAL_ID")
assert_not_empty "$EXPIRES_AT_B" "User B expiresAt should be non-empty"

echo "  User B: status=$STATUS_B, expiresAt=$EXPIRES_AT_B"

#============================================================================
# Step 4: Assert both users share same global rotation boundary
#============================================================================
print_step 4 "Verify both users share same expiresAt (global boundary)"

assert_equals "$EXPIRES_AT_A" "$EXPIRES_AT_B" "User A and B should share same global expiresAt"

echo "  User A expiresAt: $EXPIRES_AT_A"
echo "  User B expiresAt: $EXPIRES_AT_B"
echo "  Match: YES (same global boundary)"

#============================================================================
# Step 5: Backdate both users by 2 days to cross rotation boundary
#============================================================================
print_step 5 "Backdate both users to simulate rotation boundary"

backdate_updated_at "$USER_A" "$GOAL_ID" "2 days"
backdate_updated_at "$USER_B" "$GOAL_ID" "2 days"

#============================================================================
# Step 6: Verify both users show reset status
#============================================================================
print_step 6 "Verify both users show not_started after rotation"

USER_ID="$USER_A"
CHALLENGES_A=$(get_user_progress)
STATUS_A=$(get_goal_status "$CHALLENGES_A" "$GOAL_ID")
PROGRESS_A=$(get_goal_progress "$CHALLENGES_A" "$GOAL_ID")

assert_equals "not_started" "$STATUS_A" "User A should be not_started after rotation"
assert_equals "0" "$PROGRESS_A" "User A progress should be 0 after rotation"

USER_ID="$USER_B"
CHALLENGES_B=$(get_user_progress)
STATUS_B=$(get_goal_status "$CHALLENGES_B" "$GOAL_ID")
PROGRESS_B=$(get_goal_progress "$CHALLENGES_B" "$GOAL_ID")

assert_equals "not_started" "$STATUS_B" "User B should be not_started after rotation"
assert_equals "0" "$PROGRESS_B" "User B progress should be 0 after rotation"

#============================================================================
# Step 7: Assert both users get same NEW expiresAt (next boundary)
#============================================================================
print_step 7 "Verify both users get same new expiresAt after rotation"

NEW_EXPIRES_AT_A=$(get_goal_expires_at "$CHALLENGES_A" "$GOAL_ID")
NEW_EXPIRES_AT_B=$(get_goal_expires_at "$CHALLENGES_B" "$GOAL_ID")

assert_not_empty "$NEW_EXPIRES_AT_A" "User A new expiresAt should be non-empty"
assert_not_empty "$NEW_EXPIRES_AT_B" "User B new expiresAt should be non-empty"
assert_equals "$NEW_EXPIRES_AT_A" "$NEW_EXPIRES_AT_B" "Both users should get same new global expiresAt"

echo "  New expiresAt A: $NEW_EXPIRES_AT_A"
echo "  New expiresAt B: $NEW_EXPIRES_AT_B"
echo "  Match: YES (same next global boundary)"

#============================================================================
# Step 8: Cleanup both users and restore original USER_ID
#============================================================================
print_step 8 "Cleanup test users"

docker compose exec -T postgres psql -U postgres -d challenge_db -c \
    "DELETE FROM user_goal_progress WHERE user_id = '$USER_A';" > /dev/null 2>&1 || true
docker compose exec -T postgres psql -U postgres -d challenge_db -c \
    "DELETE FROM user_goal_progress WHERE user_id = '$USER_B';" > /dev/null 2>&1 || true

USER_ID="$ORIGINAL_USER_ID"

echo "  Cleaned up users and restored USER_ID=$USER_ID"

print_success "M5 Global Rotation Sync (Two Users Same Boundary)"
