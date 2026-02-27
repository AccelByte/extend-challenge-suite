#!/bin/bash
# E2E Test: M5 Rotation Status Endpoint
# Tests GET /v1/challenges/{id}/rotation
# Location: tests/e2e/test-m5-rotation-status.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M5: Rotation Status Endpoint"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

#============================================================================
# Step 1: Get rotation status for rotation-daily (daily rotation)
#============================================================================
print_step 1 "Get rotation status for rotation-daily challenge"

RESULT=$(get_rotation_status "rotation-daily")

ENABLED=$(echo "$RESULT" | jq -r '.rotation.enabled // false')
SCHEDULE=$(echo "$RESULT" | jq -r '.rotation.schedule // ""')
TYPE=$(echo "$RESULT" | jq -r '.rotation.type // ""')

assert_equals "true" "$ENABLED" "Rotation should be enabled for rotation-daily"
assert_equals "daily" "$SCHEDULE" "Schedule should be daily"
assert_equals "global" "$TYPE" "Type should be global"

#============================================================================
# Step 2: Verify currentPeriod fields
#============================================================================
print_step 2 "Verify currentPeriod has valid fields"

START_TIME=$(echo "$RESULT" | jq -r '.rotation.currentPeriod.startTime // ""')
END_TIME=$(echo "$RESULT" | jq -r '.rotation.currentPeriod.endTime // ""')
EXPIRES_IN=$(echo "$RESULT" | jq -r '.rotation.currentPeriod.expiresInSeconds // 0')

assert_not_empty "$START_TIME" "currentPeriod.startTime should be non-empty"
assert_not_empty "$END_TIME" "currentPeriod.endTime should be non-empty"
assert_gt "$EXPIRES_IN" "0" "currentPeriod.expiresInSeconds should be > 0"

# Verify startTime is today's date (UTC midnight)
TODAY_DATE=$(date -u +%Y-%m-%d)
assert_contains "$START_TIME" "$TODAY_DATE" "startTime should contain today's date"

#============================================================================
# Step 3: Get rotation status for weekly-challenges (weekly rotation)
#============================================================================
print_step 3 "Get rotation status for weekly-challenges"

RESULT=$(get_rotation_status "weekly-challenges")

ENABLED=$(echo "$RESULT" | jq -r '.rotation.enabled // false')
SCHEDULE=$(echo "$RESULT" | jq -r '.rotation.schedule // ""')

assert_equals "true" "$ENABLED" "Rotation should be enabled for weekly-challenges"
assert_equals "weekly" "$SCHEDULE" "Schedule should be weekly"

EXPIRES_IN=$(echo "$RESULT" | jq -r '.rotation.currentPeriod.expiresInSeconds // 0')
assert_gt "$EXPIRES_IN" "0" "Weekly currentPeriod.expiresInSeconds should be > 0"

#============================================================================
# Step 4: Get rotation status for non-rotation challenge
#============================================================================
print_step 4 "Get rotation status for non-rotation challenge"

# Use a non-rotation challenge (daily-challenges is the M4 one without rotation)
RESULT=$(get_rotation_status "daily-challenges" 2>&1 || true)

# Should either return enabled=false or an error/empty rotation
ENABLED=$(echo "$RESULT" | jq -r '.rotation.enabled // false' 2>/dev/null || echo "false")
assert_equals "false" "$ENABLED" "Rotation should be disabled for non-rotation challenge"

print_success "M5 Rotation Status Endpoint"
