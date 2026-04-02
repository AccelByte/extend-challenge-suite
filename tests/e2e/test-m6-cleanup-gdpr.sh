#!/bin/bash
# E2E Test: M6 GDPR User Data Deletion
# Tests that DeleteUserData correctly removes all data for a specific user
# while leaving other users' data intact.
# Location: tests/e2e/test-m6-cleanup-gdpr.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M6: GDPR User Data Deletion"

# Pre-flight checks
check_services

# Test-specific users
USER_A="test-user-m6-gdpr-A"
USER_B="test-user-m6-gdpr-B"

#============================================================================
# Step 1: Clean test data
#============================================================================
print_step 1 "Clean test data for $USER_A and $USER_B"

docker compose exec -T postgres \
    psql -U postgres -d challenge_db \
    -c "DELETE FROM user_goal_progress WHERE user_id IN ('$USER_A', '$USER_B');" \
    > /dev/null 2>&1
echo -e "${GREEN}done${NC}"

#============================================================================
# Step 2: Seed rows for both users
#============================================================================
print_step 2 "Seed 4 rows for user-A, 2 rows for user-B"

# User A: 4 rows (mix of types)
insert_permanent_row "$USER_A" "gdpr-goal-01" "ch-gdpr" "completed"
insert_permanent_row "$USER_A" "gdpr-goal-02" "ch-gdpr" "in_progress"
insert_permanent_row "$USER_A" "gdpr-goal-03" "ch-gdpr" "claimed"
insert_expired_row "$USER_A" "gdpr-goal-04" "ch-gdpr" "not_started" 5

# User B: 2 rows
insert_permanent_row "$USER_B" "gdpr-goal-01" "ch-gdpr" "completed"
insert_permanent_row "$USER_B" "gdpr-goal-02" "ch-gdpr" "in_progress"

COUNT_A=$(count_user_rows "$USER_A")
COUNT_B=$(count_user_rows "$USER_B")
assert_equals "4" "$COUNT_A" "User-A should have 4 rows"
assert_equals "2" "$COUNT_B" "User-B should have 2 rows"
echo -e "${GREEN}done${NC}: user-A=$COUNT_A, user-B=$COUNT_B"

#============================================================================
# Step 3: Delete user-A data — assert 4 deleted
#============================================================================
print_step 3 "Delete all data for user-A"

DELETED=$(delete_user_data "$USER_A")
assert_equals "4" "$DELETED" "Should delete 4 rows for user-A"
echo -e "${GREEN}done${NC}: $DELETED rows deleted"

#============================================================================
# Step 4: Verify user-A has 0 rows
#============================================================================
print_step 4 "Verify user-A has no remaining data"

COUNT_A=$(count_user_rows "$USER_A")
assert_equals "0" "$COUNT_A" "User-A should have 0 rows after deletion"
echo -e "${GREEN}done${NC}: user-A has $COUNT_A rows"

#============================================================================
# Step 5: Verify user-B still has 2 rows
#============================================================================
print_step 5 "Verify user-B data is intact"

COUNT_B=$(count_user_rows "$USER_B")
assert_equals "2" "$COUNT_B" "User-B should still have 2 rows"
echo -e "${GREEN}done${NC}: user-B has $COUNT_B rows"

#============================================================================
# Step 6: Delete user-A again — assert 0 (idempotent)
#============================================================================
print_step 6 "Delete user-A again (idempotency check)"

DELETED=$(delete_user_data "$USER_A")
assert_equals "0" "$DELETED" "Second delete should return 0 rows"
echo -e "${GREEN}done${NC}: idempotent ($DELETED rows deleted)"

#============================================================================
# Step 7: HTTP endpoint — seed rows, delete via REST, verify JSON response
#============================================================================
print_step 7 "Test GDPR deletion via HTTP endpoint"

USER_HTTP="test-user-m6-gdpr-HTTP"

# Seed 3 rows for HTTP test user
docker compose exec -T postgres \
    psql -U postgres -d challenge_db \
    -c "DELETE FROM user_goal_progress WHERE user_id = '$USER_HTTP';" \
    > /dev/null 2>&1
insert_permanent_row "$USER_HTTP" "gdpr-http-01" "ch-gdpr" "completed"
insert_permanent_row "$USER_HTTP" "gdpr-http-02" "ch-gdpr" "in_progress"
insert_permanent_row "$USER_HTTP" "gdpr-http-03" "ch-gdpr" "not_started"

COUNT_HTTP=$(count_user_rows "$USER_HTTP")
assert_equals "3" "$COUNT_HTTP" "HTTP user should have 3 rows before deletion"

# Call HTTP GDPR endpoint
RESPONSE=$(delete_user_data_http "$USER_HTTP")
ROWS_DELETED=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('rowsDeleted',0))" 2>/dev/null || echo "PARSE_ERROR")
assert_equals "3" "$ROWS_DELETED" "HTTP response rowsDeleted should be 3"

# Verify rows are gone
COUNT_HTTP=$(count_user_rows "$USER_HTTP")
assert_equals "0" "$COUNT_HTTP" "HTTP user should have 0 rows after deletion"

echo -e "${GREEN}done${NC}: HTTP GDPR endpoint returned rowsDeleted=$ROWS_DELETED"

#============================================================================
# Step 8: HTTP endpoint — idempotent re-delete returns 0
#============================================================================
print_step 8 "HTTP GDPR idempotency check"

RESPONSE=$(delete_user_data_http "$USER_HTTP")
ROWS_DELETED=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('rowsDeleted',0))" 2>/dev/null || echo "PARSE_ERROR")
assert_equals "0" "$ROWS_DELETED" "Re-delete should return rowsDeleted=0"

echo -e "${GREEN}done${NC}: idempotent ($ROWS_DELETED rows)"

#============================================================================
# Step 9: Clean up
#============================================================================
print_step 9 "Clean up test data"

docker compose exec -T postgres \
    psql -U postgres -d challenge_db \
    -c "DELETE FROM user_goal_progress WHERE user_id IN ('$USER_A', '$USER_B', '$USER_HTTP');" \
    > /dev/null 2>&1
echo -e "${GREEN}done${NC}"

print_success "M6 GDPR User Data Deletion"
