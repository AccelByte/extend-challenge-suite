#!/bin/bash
# E2E Test Runner
# Runs all E2E tests and provides summary report
# Location: tests/e2e/run-all-tests.sh

set +e  # Don't exit on error - we want to run all tests

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILED_TEST_NAMES

# Banner
echo ""
echo "========================================"
echo "  Challenge Service E2E Test Suite"
echo "========================================"
echo ""

# Overall start time
SUITE_START=$(date +%s)

# Test list
TESTS=(
    # Happy path tests
    "test-login-flow.sh"
    "test-stat-flow.sh"
    "test-daily-goal.sh"
    "test-prerequisites.sh"
    "test-mixed-goals.sh"
    "test-buffering-performance.sh"
    # M3 feature tests
    "test-m3-initialization.sh"
    "test-inactive-goal-filtering.sh"
    # Error scenario tests
    "test-error-scenarios.sh"
    "test-reward-failures.sh"
    "test-multi-user.sh"
)

# Run each test
for test_script in "${TESTS[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Running test $TOTAL_TESTS/${#TESTS[@]}: $test_script${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Start time for this test
    TEST_START=$(date +%s)

    # Run the test
    "$SCRIPT_DIR/$test_script"
    TEST_EXIT_CODE=$?

    # End time
    TEST_END=$(date +%s)
    TEST_ELAPSED=$((TEST_END - TEST_START))

    # Check result
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo ""
        echo -e "${GREEN}✅ PASS${NC}: $test_script (${TEST_ELAPSED}s)"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_script")
        echo ""
        echo -e "${RED}❌ FAIL${NC}: $test_script (${TEST_ELAPSED}s, exit code: $TEST_EXIT_CODE)"
    fi

    # Small delay between tests
    sleep 1
done

# Overall end time
SUITE_END=$(date +%s)
SUITE_ELAPSED=$((SUITE_END - SUITE_START))

# Print summary
echo ""
echo ""
echo "========================================"
echo "  Test Suite Summary"
echo "========================================"
echo ""
echo "Total tests:    $TOTAL_TESTS"
echo -e "${GREEN}Passed:         $PASSED_TESTS${NC}"

if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failed:         $FAILED_TESTS${NC}"
    echo ""
    echo "Failed tests:"
    for failed_test in "${FAILED_TEST_NAMES[@]}"; do
        echo -e "  ${RED}✗${NC} $failed_test"
    done
else
    echo -e "${GREEN}Failed:         0${NC}"
fi

echo ""
echo "Total time:     ${SUITE_ELAPSED}s"
echo ""

# Final result
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅ ALL TESTS PASSED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ❌ SOME TESTS FAILED${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 1
fi
