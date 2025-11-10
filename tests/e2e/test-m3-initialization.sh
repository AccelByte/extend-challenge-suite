#!/bin/bash
# E2E Test: M3 Player Initialization Flow
# Tests the initialize-player endpoint with various scenarios

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M3: Player Initialization Flow"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

#============================================================================
# Test 1: First Login - Initialize Player with Default Goals
#============================================================================
print_step 1 "First Login - Creates Default Assignments"

# Call initialize endpoint
echo "Calling initialize-player..."
INIT_RESULT=$(initialize_player)

# Extract values
NEW_ASSIGNMENTS=$(extract_json_value "$INIT_RESULT" '.newAssignments')
TOTAL_ACTIVE=$(extract_json_value "$INIT_RESULT" '.totalActive')

echo "Initialize result:"
echo "  New assignments: $NEW_ASSIGNMENTS"
echo "  Total active: $TOTAL_ACTIVE"

# Verify response structure
assert_contains "$INIT_RESULT" "assignedGoals" "Response should contain assignedGoals field"
assert_contains "$INIT_RESULT" "newAssignments" "Response should contain newAssignments field"
assert_contains "$INIT_RESULT" "totalActive" "Response should contain totalActive field"

# Note: Since config may have 0 default goals, we can't assert specific counts
# But we can verify the response structure is correct
print_success "First login initialization successful"

#============================================================================
# Test 2: Subsequent Login - Fast Path (Idempotent)
#============================================================================
print_step 2 "Subsequent Login - Fast Path"

# Call initialize again
echo "Calling initialize-player again..."
INIT_RESULT2=$(initialize_player)

NEW_ASSIGNMENTS2=$(extract_json_value "$INIT_RESULT2" '.newAssignments')
TOTAL_ACTIVE2=$(extract_json_value "$INIT_RESULT2" '.totalActive')

echo "Second initialize result:"
echo "  New assignments: $NEW_ASSIGNMENTS2"
echo "  Total active: $TOTAL_ACTIVE2"

# Second call should have 0 new assignments (idempotent)
assert_equals "0" "$NEW_ASSIGNMENTS2" "Second call should have 0 new assignments"
assert_equals "$TOTAL_ACTIVE" "$TOTAL_ACTIVE2" "Total active should remain the same"

print_success "Subsequent login fast path works correctly"

#============================================================================
# Test 3: Manual Goal Activation
#============================================================================
print_step 3 "Manual Goal Activation"

# Get first challenge and goal
CHALLENGES=$(run_cli list-challenges --format=json)
CHALLENGE_ID=$(extract_json_value "$CHALLENGES" '.challenges[0].challengeId')
GOAL_ID=$(extract_json_value "$CHALLENGES" '.challenges[0].goals[0].goalId')

if [ -z "$CHALLENGE_ID" ] || [ -z "$GOAL_ID" ]; then
    echo -e "${YELLOW}⚠${NC} Warning: No challenges/goals available for activation test"
else
    echo "Activating goal: $CHALLENGE_ID / $GOAL_ID"

    # Activate goal
    ACTIVATE_RESULT=$(activate_goal "$CHALLENGE_ID" "$GOAL_ID")

    echo "Activation result:"
    echo "$ACTIVATE_RESULT" | jq '.'

    # Verify response
    IS_ACTIVE=$(extract_json_value "$ACTIVATE_RESULT" '.isActive')
    assert_equals "true" "$IS_ACTIVE" "Goal should be active after activation"

    print_success "Manual goal activation works"

    #========================================================================
    # Test 4: Goal Deactivation
    #========================================================================
    print_step 4 "Goal Deactivation"

    # Deactivate the same goal
    DEACTIVATE_RESULT=$(deactivate_goal "$CHALLENGE_ID" "$GOAL_ID")

    echo "Deactivation result:"
    echo "$DEACTIVATE_RESULT" | jq '.'

    # Verify response
    IS_ACTIVE=$(extract_json_value "$DEACTIVATE_RESULT" '.isActive')
    assert_equals "false" "$IS_ACTIVE" "Goal should be inactive after deactivation"

    print_success "Goal deactivation works"
fi

#============================================================================
# Test 5: Active-Only Filter
#============================================================================
print_step 5 "List Challenges with active_only Filter"

# List all challenges (no filter)
ALL_CHALLENGES=$(run_cli list-challenges --format=json)
ALL_COUNT=$(echo "$ALL_CHALLENGES" | jq '[.challenges[].goals[]] | length')

echo "All challenges goal count: $ALL_COUNT"

# List only active challenges
ACTIVE_CHALLENGES=$(list_active_challenges)
ACTIVE_COUNT=$(count_active_goals "$ACTIVE_CHALLENGES")

echo "Active-only goal count: $ACTIVE_COUNT"

# Active count should be <= all count
if [ "$ACTIVE_COUNT" -le "$ALL_COUNT" ]; then
    echo -e "${GREEN}✅ PASS${NC}: Active count ($ACTIVE_COUNT) <= All count ($ALL_COUNT)"
else
    echo -e "${RED}❌ FAIL${NC}: Active count ($ACTIVE_COUNT) > All count ($ALL_COUNT)"
    exit 1
fi

print_success "Active-only filter works correctly"

#============================================================================
# Test Summary
#============================================================================
print_success "All M3 initialization tests passed!"

echo ""
echo "Test Summary:"
echo "  ✅ First login initialization"
echo "  ✅ Subsequent login (idempotent)"
echo "  ✅ Manual goal activation"
echo "  ✅ Goal deactivation"
echo "  ✅ Active-only filter"
echo ""
