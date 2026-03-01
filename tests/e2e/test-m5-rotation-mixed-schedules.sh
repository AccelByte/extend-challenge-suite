#!/bin/bash
# E2E Test: M5 Mixed Daily+Weekly Expiry in Same Response
# Tests that daily and weekly goals show correct, different expiry values in the same GET response
# Location: tests/e2e/test-m5-rotation-mixed-schedules.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Mixed Daily+Weekly Expiry in Same Response"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

DAILY_GOAL="daily-challenges-goal-01"      # daily rotation, kills >= 10
WEEKLY_GOAL="weekly-challenges-goal-01"    # weekly rotation, kills >= 100

#============================================================================
# Step 1: Initialize player and create DB rows for both goals
#============================================================================
print_step 1 "Initialize player and trigger events for both daily and weekly goals"

initialize_player > /dev/null 2>&1 || true

# Send kills=1, inc=1 to create DB rows for goals that track kills
trigger_stat_with_inc "kills" "1" "1" > /dev/null 2>&1
wait_for_flush 3

#============================================================================
# Step 2: Get challenges and extract expiry values for both schedules
#============================================================================
print_step 2 "Fetch challenges and compare daily vs weekly expiry"

CHALLENGES=$(get_user_progress)

DAILY_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$DAILY_GOAL")
DAILY_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$DAILY_GOAL")
WEEKLY_EXPIRES_AT=$(get_goal_expires_at "$CHALLENGES" "$WEEKLY_GOAL")
WEEKLY_EXPIRES_IN=$(get_goal_expires_in_seconds "$CHALLENGES" "$WEEKLY_GOAL")

echo "  Daily goal:  expiresAt=$DAILY_EXPIRES_AT, expiresInSeconds=$DAILY_EXPIRES_IN"
echo "  Weekly goal: expiresAt=$WEEKLY_EXPIRES_AT, expiresInSeconds=$WEEKLY_EXPIRES_IN"

#============================================================================
# Step 3: Verify both have non-empty expiry values
#============================================================================
print_step 3 "Verify both goals have expiry fields populated"

assert_not_empty "$DAILY_EXPIRES_AT" "Daily goal expiresAt should be non-empty"
assert_not_empty "$WEEKLY_EXPIRES_AT" "Weekly goal expiresAt should be non-empty"
assert_gt "$DAILY_EXPIRES_IN" "0" "Daily goal expiresInSeconds should be > 0"
assert_gt "$WEEKLY_EXPIRES_IN" "0" "Weekly goal expiresInSeconds should be > 0"

#============================================================================
# Step 4: Verify daily expiry is <= 86400 seconds (24 hours)
#============================================================================
print_step 4 "Verify daily expiry is within 24 hours"

assert_lte "$DAILY_EXPIRES_IN" "86400" "Daily expiresInSeconds should be <= 86400 (24 hours)"

#============================================================================
# Step 5: Verify weekly expiry is <= 604800 seconds (7 days)
#============================================================================
print_step 5 "Verify weekly expiry is within 7 days"

assert_lte "$WEEKLY_EXPIRES_IN" "604800" "Weekly expiresInSeconds should be <= 604800 (7 days)"

#============================================================================
# Step 6: Verify weekly expiry >= daily expiry (weekly further out)
#============================================================================
print_step 6 "Verify weekly expiry is >= daily expiry"

# Weekly boundary is always further out than daily (except at exact midnight Monday UTC,
# which is vanishingly unlikely during test execution)
assert_gte "$WEEKLY_EXPIRES_IN" "$DAILY_EXPIRES_IN" "Weekly expiresInSeconds should be >= daily expiresInSeconds"

#============================================================================
# Step 7: Verify the expiresAt timestamps differ (except on Sundays where both end Monday midnight)
#============================================================================
print_step 7 "Verify expiresAt timestamps are different between schedules"

DAY_OF_WEEK=$(date -u +%u)  # 7 = Sunday
if [ "$DAY_OF_WEEK" -eq 7 ]; then
  echo "  (Skipping: today is Sunday — daily and weekly boundaries both end Monday midnight)"
  echo -e "${GREEN}✅ PASS${NC}: Skipped on Sunday (daily/weekly boundaries coincide)"
else
  assert_not_equals "$DAILY_EXPIRES_AT" "$WEEKLY_EXPIRES_AT" "Daily and weekly expiresAt should be different timestamps"
fi

print_success "M5 Mixed Daily+Weekly Expiry in Same Response"
