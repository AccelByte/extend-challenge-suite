#!/bin/bash
# E2E Test: M6 Expired Row Cleanup
# Tests that the cleanup mechanism correctly deletes expired rows while preserving
# permanent and recent rows, and verifies the partial index and metrics.
# Location: tests/e2e/test-m6-cleanup-expired.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M6: Expired Row Cleanup"

# Pre-flight checks
check_services

# Test-specific user (unique to avoid collisions)
M6_USER="test-user-m6-cleanup"

#============================================================================
# Step 1: Clean test data
#============================================================================
print_step 1 "Clean test data for $M6_USER"

docker compose exec -T postgres \
    psql -U postgres -d challenge_db \
    -c "DELETE FROM user_goal_progress WHERE user_id = '$M6_USER';" \
    > /dev/null 2>&1
echo -e "${GREEN}done${NC}"

#============================================================================
# Step 2: Verify partial index exists (migration 003)
#============================================================================
print_step 2 "Verify cleanup partial index exists"

verify_cleanup_index
assert_equals "0" "$?" "idx_user_goal_progress_expires_at should exist"
echo -e "${GREEN}done${NC}: partial index verified"

#============================================================================
# Step 3: Seed mixed rows
#============================================================================
print_step 3 "Seed mixed rows: 4 expired, 2 permanent, 1 recent"

# 4 expired rows (10-30 days ago, various statuses)
insert_expired_row "$M6_USER" "m6-expired-01" "ch-cleanup" "completed" 10
insert_expired_row "$M6_USER" "m6-expired-02" "ch-cleanup" "in_progress" 15
insert_expired_row "$M6_USER" "m6-expired-03" "ch-cleanup" "claimed" 20
insert_expired_row "$M6_USER" "m6-expired-04" "ch-cleanup" "not_started" 30

# 2 permanent rows (NULL expires_at)
insert_permanent_row "$M6_USER" "m6-permanent-01" "ch-cleanup" "completed"
insert_permanent_row "$M6_USER" "m6-permanent-02" "ch-cleanup" "in_progress"

# 1 recent expired row (3 days ago — within 7d retention)
insert_expired_row "$M6_USER" "m6-recent-01" "ch-cleanup" "completed" 3

TOTAL=$(count_user_rows "$M6_USER")
assert_equals "7" "$TOTAL" "Should have 7 rows after seeding"
echo -e "${GREEN}done${NC}: $TOTAL rows seeded"

#============================================================================
# Step 4: Run cleanup query (retention=7d) — expect 4 deleted
#============================================================================
print_step 4 "Run cleanup query (retention_days=7, batch_size=1000)"

DELETED=$(run_cleanup_query 7 1000)
assert_equals "4" "$DELETED" "Should delete 4 expired rows (10d, 15d, 20d, 30d > 7d retention)"
echo -e "${GREEN}done${NC}: $DELETED rows deleted"

#============================================================================
# Step 5: Verify 3 rows remain (2 permanent + 1 recent)
#============================================================================
print_step 5 "Verify remaining rows"

REMAINING=$(count_user_rows "$M6_USER")
assert_equals "3" "$REMAINING" "Should have 3 rows remaining (2 permanent + 1 recent)"
echo -e "${GREEN}done${NC}: $REMAINING rows remain"

#============================================================================
# Step 6: Run cleanup again — assert 0 deleted (idempotent)
#============================================================================
print_step 6 "Run cleanup again (idempotency check)"

DELETED=$(run_cleanup_query 7 1000)
assert_equals "0" "$DELETED" "Second cleanup should delete 0 rows"
echo -e "${GREEN}done${NC}: idempotent ($DELETED rows deleted)"

#============================================================================
# Step 7: Verify Prometheus cleanup metrics registered
#============================================================================
print_step 7 "Verify Prometheus cleanup metrics"

check_cleanup_metrics
assert_equals "0" "$?" "All 4 cleanup metrics should be registered"
echo -e "${GREEN}done${NC}: all metrics present"

#============================================================================
# Step 8: Clean up
#============================================================================
print_step 8 "Clean up test data"

docker compose exec -T postgres \
    psql -U postgres -d challenge_db \
    -c "DELETE FROM user_goal_progress WHERE user_id = '$M6_USER';" \
    > /dev/null 2>&1
echo -e "${GREEN}done${NC}"

print_success "M6 Expired Row Cleanup"
