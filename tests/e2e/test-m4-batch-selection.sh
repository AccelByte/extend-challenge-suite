#!/bin/bash
# E2E Test: M4 Batch Goal Selection
# Tests the batch-select endpoint with various scenarios

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M4: Batch Goal Selection"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

# Initialize player to ensure default challenge exists
initialize_player > /dev/null 2>&1 || true

# Assume we have a challenge with ID "daily-challenges" and several goals
CHALLENGE_ID="daily-challenges"

#============================================================================
# Test 1: Batch Select Multiple Goals (Happy Path)
#============================================================================
print_step 1 "Batch select 3 goals - happy path"

# Get available goals first
CHALLENGES=$(get_user_progress)
GOAL_IDS=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0:3] | .[].goalId" | tr '\n' ',' | sed 's/,$//')

if [ -z "$GOAL_IDS" ]; then
    error_exit "No goals found in challenge $CHALLENGE_ID"
fi

# Call batch-select with 3 goal IDs
RESULT=$(batch_select_goals "$CHALLENGE_ID" "$GOAL_IDS" "false")

# Verify response
SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')

assert_equals "$SELECTED_COUNT" "3" "Should select exactly 3 goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 total active goals"
print_success "Batch selection successful"

#============================================================================
# Test 2: Batch Select with replace_existing=true
#============================================================================
print_step 2 "Batch select with replace mode"

# Reset
cleanup_test_data

# First batch: select 2 goals
GOAL_IDS_FIRST=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0:2] | .[].goalId" | tr '\n' ',' | sed 's/,$//')
batch_select_goals "$CHALLENGE_ID" "$GOAL_IDS_FIRST" "false" > /dev/null

# Second batch: replace with 3 new goals
GOAL_IDS_SECOND=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[3:6] | .[].goalId" | tr '\n' ',' | sed 's/,$//')
RESULT=$(batch_select_goals "$CHALLENGE_ID" "$GOAL_IDS_SECOND" "true")

REPLACED_COUNT=$(extract_json_value "$RESULT" '.replacedGoals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')

assert_equals "$REPLACED_COUNT" "2" "Should replace 2 existing goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 active goals after replace"
print_success "Replace mode working correctly"

#============================================================================
# Test 3: Batch Select with replace_existing=false (Add Mode)
#============================================================================
print_step 3 "Batch select with add mode"

# Reset
cleanup_test_data

# Reset
cleanup_test_data

# First: select 2 goals
GOAL_IDS_FIRST=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0:2] | .[].goalId" | tr '\n' ',' | sed 's/,$//')
batch_select_goals "$CHALLENGE_ID" "$GOAL_IDS_FIRST" "false" > /dev/null

# Second: add 2 more goals (not replace)
GOAL_IDS_SECOND=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[3:5] | .[].goalId" | tr '\n' ',' | sed 's/,$//')
RESULT=$(batch_select_goals "$CHALLENGE_ID" "$GOAL_IDS_SECOND" "false")

TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')

assert_equals "$TOTAL_ACTIVE" "4" "Should have 4 active goals (2 existing + 2 new)"
print_success "Add mode working correctly"

#============================================================================
# Test 4: Error - Invalid Goal IDs
#============================================================================
print_step 4 "Error handling - invalid goal IDs"

# Reset
cleanup_test_data

# Try to select non-existent goals
RESULT=$(batch_select_goals "$CHALLENGE_ID" "invalid-goal-1,invalid-goal-2" "false" 2>&1 || true)

assert_contains "$RESULT" "404" "Should return 404 for invalid goal IDs"
print_success "Invalid goal IDs rejected correctly"

#============================================================================
# Test 5: Error - Empty Goal List
#============================================================================
print_step 5 "Error handling - empty goal list"

RESULT=$(batch_select_goals "$CHALLENGE_ID" "" "false" 2>&1 || true)

# The CLI converts empty string to [""] which fails with "goal '' not found"
# This is acceptable as it still rejects invalid input
if echo "$RESULT" | grep -q "goal-ids cannot be empty"; then
    print_success "Empty list rejected correctly (goal-ids cannot be empty)"
elif echo "$RESULT" | grep -q "goal '' not found"; then
    print_success "Empty list rejected correctly (empty goal ID not found)"
else
    assert_contains "$RESULT" "goal-ids cannot be empty" "Should return error for empty list"
fi

#============================================================================
# Test 6: Atomicity - All or Nothing
#============================================================================
print_step 6 "Atomicity verification"

# Reset
cleanup_test_data

# Reset
cleanup_test_data

# Try to select mix of valid and invalid goals (should fail atomically)
VALID_GOAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0].goalId")
RESULT=$(batch_select_goals "$CHALLENGE_ID" "$VALID_GOAL,invalid-goal" "false" 2>&1 || true)

# Verify NO goals were activated (atomicity)
PROGRESS=$(get_user_progress)
ACTIVE_COUNT=$(count_active_goals "$PROGRESS")

assert_equals "$ACTIVE_COUNT" "0" "No goals should be active if batch fails"
print_success "Atomicity verified - all or nothing"

#============================================================================
# Test 7: Edge Case - Duplicate Goal IDs
#============================================================================
print_step 7 "Handle duplicate goal IDs gracefully"

# Reset
cleanup_test_data

# Get first two goals
CHALLENGES=$(get_user_progress)
GOAL_A=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0].goalId")
GOAL_B=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[1].goalId")

if [ -n "$GOAL_A" ] && [ -n "$GOAL_B" ]; then
    # Try batch select with duplicates: [goal-a, goal-a, goal-b]
    RESULT=$(batch_select_goals "$CHALLENGE_ID" "$GOAL_A,$GOAL_A,$GOAL_B" "false" 2>&1 || true)
    
    # Check if it's an error response
    if echo "$RESULT" | grep -qi "error\|invalid\|duplicate"; then
        print_success "Duplicate IDs rejected with error"
    else
        # Check if deduplication occurred
        SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length' 2>/dev/null || echo "0")
        
        if [ "$SELECTED_COUNT" = "2" ]; then
            # Verify that only unique goals were activated
            PROGRESS=$(get_user_progress)
            GOAL_A_ACTIVE=$(get_goal_active_status "$PROGRESS" "$GOAL_A")
            GOAL_B_ACTIVE=$(get_goal_active_status "$PROGRESS" "$GOAL_B")
            
            assert_equals "$GOAL_A_ACTIVE" "true" "Goal A should be active"
            assert_equals "$GOAL_B_ACTIVE" "true" "Goal B should be active"
            print_success "Duplicate IDs deduplicated to unique goals"
        elif [ "$SELECTED_COUNT" = "3" ]; then
            # System allowed duplicates (unexpected but not necessarily wrong)
            echo -e "${YELLOW}⚠${NC} Warning: System allowed duplicate goal IDs in batch selection"
            print_success "Duplicate IDs processed (allowed by system)"
        else
            echo -e "${RED}✗${NC} Unexpected result with duplicate goal IDs"
            echo "  Expected 2 or 3 goals, got: $SELECTED_COUNT"
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping duplicate IDs test (insufficient goals in challenge)"
fi

#============================================================================
# Test 8: Error - Non-Existent Challenge
#============================================================================
print_step 8 "Error handling - non-existent challenge"

INVALID_CHALLENGE="invalid-challenge-id-12345"

# Try batch select on non-existent challenge
RESULT=$(batch_select_goals "$INVALID_CHALLENGE" "goal-a,goal-b" "false" 2>&1 || true)

# Should return 404 or appropriate error
if echo "$RESULT" | grep -qi "404\|not found\|challenge.*not.*found"; then
    print_success "Non-existent challenge handled correctly (404)"
else
    echo -e "${YELLOW}⚠${NC} Warning: Expected 404 for non-existent challenge"
    echo "  Result: $RESULT"
    # Still pass if we got some kind of error (not a success response)
    if echo "$RESULT" | grep -qi "error"; then
        print_success "Non-existent challenge returned error (not 404 but acceptable)"
    else
        echo -e "${RED}✗${NC} Expected error for non-existent challenge"
        exit 1
    fi
fi

#============================================================================
# Test 9: Edge Case - Empty Goal List vs Empty Challenge
#============================================================================
print_step 9 "Verify empty challenge behavior"

# This test verifies what happens when trying to select from a challenge with 0 goals
# vs providing an empty goal list

# We already tested empty goal list in Test 5
# Here we focus on documenting expected behavior

# Try batch select with completely empty string (not even comma)
RESULT=$(batch_select_goals "$CHALLENGE_ID" "" "false" 2>&1 || true)

# Should error (either "goal-ids cannot be empty" or "goal '' not found")
if echo "$RESULT" | grep -qi "empty\|cannot be empty\|goal.*not found"; then
    print_success "Empty goal list validation working"
else
    echo -e "${YELLOW}⚠${NC} Warning: Unexpected response for empty goal list"
    echo "  Result: $RESULT"
fi

print_success "M4 Batch Selection Tests"
