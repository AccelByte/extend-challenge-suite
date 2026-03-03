#!/bin/bash
# E2E Test: M6 Cleanup Prometheus Metrics
# Tests that all 4 cleanup Prometheus metrics are registered and have proper metadata.
# Location: tests/e2e/test-m6-cleanup-metrics.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M6: Cleanup Prometheus Metrics"

# Pre-flight checks
check_services

#============================================================================
# Step 1: Verify all 4 cleanup metrics are present
#============================================================================
print_step 1 "Verify cleanup metrics are registered"

METRICS=$(curl -s http://localhost:8080/metrics 2>/dev/null)

# Check each metric name
assert_contains "$METRICS" "challenge_cleanup_rows_deleted_total" "rows_deleted_total metric should exist"
assert_contains "$METRICS" "challenge_cleanup_cycles_total" "cycles_total metric should exist"
assert_contains "$METRICS" "challenge_cleanup_errors_total" "errors_total metric should exist"
assert_contains "$METRICS" "challenge_cleanup_duration_seconds" "duration_seconds metric should exist"

echo -e "${GREEN}done${NC}: all 4 cleanup metrics present"

#============================================================================
# Step 2: Verify HELP and TYPE metadata lines
#============================================================================
print_step 2 "Verify metric HELP and TYPE metadata"

assert_contains "$METRICS" "# HELP challenge_cleanup_rows_deleted_total" "rows_deleted HELP should exist"
assert_contains "$METRICS" "# TYPE challenge_cleanup_rows_deleted_total counter" "rows_deleted should be counter type"

assert_contains "$METRICS" "# HELP challenge_cleanup_cycles_total" "cycles HELP should exist"
assert_contains "$METRICS" "# TYPE challenge_cleanup_cycles_total counter" "cycles should be counter type"

assert_contains "$METRICS" "# HELP challenge_cleanup_errors_total" "errors HELP should exist"
assert_contains "$METRICS" "# TYPE challenge_cleanup_errors_total counter" "errors should be counter type"

assert_contains "$METRICS" "# HELP challenge_cleanup_duration_seconds" "duration HELP should exist"
assert_contains "$METRICS" "# TYPE challenge_cleanup_duration_seconds histogram" "duration should be histogram type"

echo -e "${GREEN}done${NC}: all HELP and TYPE metadata verified"

print_success "M6 Cleanup Prometheus Metrics"
