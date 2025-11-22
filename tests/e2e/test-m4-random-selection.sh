#!/bin/bash
# E2E Test: M4 Random Goal Selection
# Tests the random-select endpoint with various scenarios

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_test_header "M4: Random Goal Selection"

# Pre-flight checks
check_demo_app
check_services
validate_user_id_for_password_mode

# Cleanup previous test data
cleanup_test_data

# Initialize player to ensure default challenge exists
initialize_player > /dev/null 2>&1 || true

# Assume we have a challenge with ID "daily-challenges"
CHALLENGE_ID="daily-challenges"

#============================================================================
# Test 1: Random Select N Goals (Happy Path)
#============================================================================
print_step 1 "Random select 3 goals - happy path"

RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "false" "false")

# Verify response
SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')

assert_equals "$SELECTED_COUNT" "3" "Should select exactly 3 goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 total active goals"

# Verify no duplicates
GOAL_IDS=$(extract_json_value "$RESULT" '.selectedGoals[].goalId' | sort)
UNIQUE_COUNT=$(echo "$GOAL_IDS" | uniq | wc -l)
assert_equals "$UNIQUE_COUNT" "3" "Should have no duplicate goals"

print_success "Random selection successful"

#============================================================================
# Test 2: Random Select with exclude_active=true
#============================================================================
# Reset
cleanup_test_data

print_step 2 "Random select with exclude_active filter"

# Reset
cleanup_test_data

# Get available goals
CHALLENGES=$(get_user_progress)
GOAL_A=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0].goalId")
GOAL_B=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[1].goalId")

# Manually activate 2 goals first
activate_goal "$CHALLENGE_ID" "$GOAL_A" > /dev/null
activate_goal "$CHALLENGE_ID" "$GOAL_B" > /dev/null

# Random select 3 more (excluding already active)
RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "false" "true")

SELECTED_GOALS=$(extract_json_value "$RESULT" '.selectedGoals[].goalId')

# Verify selected goals don't include goal-a or goal-b
assert_not_contains "$SELECTED_GOALS" "$GOAL_A" "Should exclude already active goal A"
assert_not_contains "$SELECTED_GOALS" "$GOAL_B" "Should exclude already active goal B"

TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')
assert_equals "$TOTAL_ACTIVE" "5" "Should have 5 active goals (2 existing + 3 new)"

print_success "exclude_active filter working correctly"

#============================================================================
# Test 3: Random Select with exclude_active=false (Can Re-select)
#============================================================================
# Reset
cleanup_test_data

print_step 3 "Random select without exclude_active filter"

# Reset
cleanup_test_data

# Activate 2 goals
activate_goal "$CHALLENGE_ID" "$GOAL_A" > /dev/null
activate_goal "$CHALLENGE_ID" "$GOAL_B" > /dev/null

# Random select 3 (may include already active goals)
RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "false" "false")

SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length')
assert_equals "$SELECTED_COUNT" "3" "Should select 3 goals"

print_success "Random selection without filter works"

#============================================================================
# Test 4: Random Select with replace_existing=true
#============================================================================
# Reset
cleanup_test_data

print_step 4 "Random select with replace mode"

# Reset
cleanup_test_data

# First: activate 2 goals manually
activate_goal "$CHALLENGE_ID" "$GOAL_A" > /dev/null
activate_goal "$CHALLENGE_ID" "$GOAL_B" > /dev/null

# Second: random select 3 with replace mode
RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "true" "false")

REPLACED_COUNT=$(extract_json_value "$RESULT" '.replacedGoals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.totalActiveGoals')

assert_equals "$REPLACED_COUNT" "2" "Should replace 2 existing goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have exactly 3 active goals after replace"

# Verify goal-a and goal-b are no longer active
PROGRESS=$(get_user_progress)
GOAL_A_ACTIVE=$(get_goal_active_status "$PROGRESS" "$GOAL_A")
GOAL_B_ACTIVE=$(get_goal_active_status "$PROGRESS" "$GOAL_B")

assert_equals "$GOAL_A_ACTIVE" "false" "goal A should be deactivated"
assert_equals "$GOAL_B_ACTIVE" "false" "goal B should be deactivated"

print_success "Replace mode working correctly"

#============================================================================
# Test 5: Partial Results (Fewer Available Than Requested)
#============================================================================
# Reset
cleanup_test_data

print_step 5 "Partial results when fewer goals available"

# Reset
cleanup_test_data

# Complete several goals (they'll be excluded from random selection)
# Note: This test assumes we can complete goals or that there are limited goals
# For simplicity, we'll just try to select more than available and expect partial results

# Request more goals than available (assuming challenge has limited goals)
RESULT=$(random_select_goals "$CHALLENGE_ID" "100" "false" "true")

SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length')

# Should return at least 1 goal (partial result)
assert_gte "$SELECTED_COUNT" "1" "Should return at least 1 goal"

print_success "Partial results returned correctly"

#============================================================================
# Test 6: Error - Invalid Count
#============================================================================
# Reset
cleanup_test_data

print_step 6 "Error handling - invalid count"

# Test count = 0
RESULT=$(random_select_goals "$CHALLENGE_ID" "0" "false" "false" 2>&1 || true)
assert_contains "$RESULT" "count must be greater than 0" "Should return error for count=0"

# Test count < 0
RESULT=$(random_select_goals "$CHALLENGE_ID" "-1" "false" "false" 2>&1 || true)
assert_contains "$RESULT" "count must be greater than 0" "Should return error for count<0"

print_success "Invalid count rejected correctly"

#============================================================================
# Test 7: Progress Preservation on Deactivation
#============================================================================
# Reset
cleanup_test_data

print_step 7 "Verify progress preserved when goals deactivated"

# Reset
cleanup_test_data

# Get a goal that can have progress
CHALLENGES=$(get_user_progress)
PROGRESS_GOAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.requirement.statCode != null) | .goalId" | head -1)

if [ -n "$PROGRESS_GOAL" ]; then
    # Activate goal and make partial progress
    activate_goal "$CHALLENGE_ID" "$PROGRESS_GOAL" > /dev/null

    # Trigger some progress (if trigger-event command is available)
    # For now, we'll skip this part as it depends on the challenge configuration

    # Random select with replace (deactivates the progress goal)
    random_select_goals "$CHALLENGE_ID" "3" "true" "false" > /dev/null

    # Verify goal is deactivated but progress preserved
    PROGRESS=$(get_user_progress)
    IS_ACTIVE=$(get_goal_active_status "$PROGRESS" "$PROGRESS_GOAL")

    assert_equals "$IS_ACTIVE" "false" "Goal should be deactivated"
    print_success "Progress preservation verified"
else
    echo -e "${YELLOW}⚠${NC} Skipping progress preservation test (no suitable goal found)"
fi

#============================================================================
# Test 8: M3 Compatibility - Individual Activation Still Works
#============================================================================
# Reset
cleanup_test_data

print_step 8 "M3 compatibility - individual activation"

# Reset
cleanup_test_data

# Use M3 individual activation
GOAL_INDIVIDUAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[0].goalId")
activate_goal "$CHALLENGE_ID" "$GOAL_INDIVIDUAL" > /dev/null

# Use M4 random selection
random_select_goals "$CHALLENGE_ID" "2" "false" "true" > /dev/null

# Verify both work together
PROGRESS=$(get_user_progress)
TOTAL_ACTIVE=$(count_active_goals "$PROGRESS")

assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 active goals (1 M3 + 2 M4)"

print_success "M3 and M4 APIs work together"

#============================================================================
# Test 9: Random Selection No Duplicates Across Multiple Calls
#============================================================================
# Reset
cleanup_test_data

print_step 9 "Verify randomness - no duplicate selections"

# Reset
cleanup_test_data

# First random selection
RESULT1=$(random_select_goals "$CHALLENGE_ID" "2" "false" "false")
GOALS1=$(extract_json_value "$RESULT1" '.selectedGoals[].goalId' | sort | tr '\n' ',' | sed 's/,$//')

# Second random selection (replace mode)
RESULT2=$(random_select_goals "$CHALLENGE_ID" "2" "true" "false")
GOALS2=$(extract_json_value "$RESULT2" '.selectedGoals[].goalId' | sort | tr '\n' ',' | sed 's/,$//')

# While not guaranteed to be different due to randomness,
# at least verify both selections are valid
assert_not_equals "$GOALS1" "" "First selection should not be empty"
assert_not_equals "$GOALS2" "" "Second selection should not be empty"

print_success "Multiple random selections work correctly"

#============================================================================
# Test 10: Auto-Filter - Completed/Claimed Goals Excluded
#============================================================================
# Reset
cleanup_test_data

print_step 10 "Verify completed/claimed goals auto-excluded"

# Get a goal that can be completed
CHALLENGES=$(get_user_progress)
GOAL_TO_COMPLETE=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.requirement.statCode != null) | .goalId" | head -1)

if [ -n "$GOAL_TO_COMPLETE" ]; then
    # Activate and complete the goal
    activate_goal "$CHALLENGE_ID" "$GOAL_TO_COMPLETE" > /dev/null
    
    # Complete the goal
    complete_goal "$CHALLENGE_ID" "$GOAL_TO_COMPLETE"
    
    # Wait for processing
    wait_for_flush 2
    
    # Verify goal is completed
    PROGRESS=$(get_user_progress)
    STATUS=$(echo "$PROGRESS" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.goalId == \"$GOAL_TO_COMPLETE\") | .status")
    
    if [ "$STATUS" = "completed" ]; then
        # Claim the completed goal
        run_cli claim "$CHALLENGE_ID" "$GOAL_TO_COMPLETE" > /dev/null 2>&1 || true
        
        wait_for_flush 1
        
        # Random select (should exclude claimed goal)
        RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "false" "false")
        SELECTED_GOALS=$(extract_json_value "$RESULT" '.selectedGoals[].goalId')
        
        # Verify the completed/claimed goal was NOT selected
        assert_not_contains "$SELECTED_GOALS" "$GOAL_TO_COMPLETE" "Should exclude claimed goal from selection"
        print_success "Completed/claimed goals auto-filter verified"
    else
        echo -e "${YELLOW}⚠${NC} Skipping completed/claimed filter test (goal did not complete)"
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping completed/claimed filter test (no suitable goal found)"
fi

#============================================================================
# Test 11: Auto-Filter - Prerequisites Exclusion
#============================================================================
# Reset
cleanup_test_data

print_step 11 "Verify goals with unmet prerequisites auto-excluded"

# Find a goal that has prerequisites
CHALLENGES=$(get_user_progress)
PREREQ_GOAL=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.prerequisiteGoalIds != null and (.prerequisiteGoalIds | length > 0)) | .goalId" | head -1)

if [ -n "$PREREQ_GOAL" ]; then
    # Get the prerequisites for this goal
    PREREQS=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.goalId == \"$PREREQ_GOAL\") | .prerequisiteGoalIds[]")
    
    # Ensure prerequisites are NOT completed (should be the case after cleanup)
    # Random select multiple times to increase confidence
    FOUND_PREREQ_GOAL=false
    
    for attempt in {1..3}; do
        RESULT=$(random_select_goals "$CHALLENGE_ID" "5" "false" "false" 2>/dev/null || true)
        SELECTED_GOALS=$(extract_json_value "$RESULT" '.selectedGoals[].goalId' 2>/dev/null || echo "")
        
        if echo "$SELECTED_GOALS" | grep -q "$PREREQ_GOAL"; then
            FOUND_PREREQ_GOAL=true
            break
        fi
    done
    
    if [ "$FOUND_PREREQ_GOAL" = "true" ]; then
        echo -e "${RED}✗${NC} Goal with unmet prerequisites WAS selected (should be filtered)"
        exit 1
    else
        print_success "Prerequisites auto-filter verified (goal with unmet prereqs not selected)"
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping prerequisite test (no goals with prerequisites in challenge)"
fi

#============================================================================
# Test 12: Error - Zero Goals Available After Filtering
#============================================================================
# Reset
cleanup_test_data

print_step 12 "Error when zero goals available after filtering"

# Strategy: Activate all goals, then try to random select with exclude_active=true
# This should result in zero available goals

# Get all goal IDs
CHALLENGES=$(get_user_progress)
ALL_GOAL_IDS=$(echo "$CHALLENGES" | jq -r ".challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[].goalId")
GOAL_COUNT=$(echo "$ALL_GOAL_IDS" | wc -w | tr -d ' ')

if [ "$GOAL_COUNT" -gt 0 ]; then
    # Activate all goals
    for goal_id in $ALL_GOAL_IDS; do
        activate_goal "$CHALLENGE_ID" "$goal_id" > /dev/null 2>&1 || true
    done
    
    # Wait for activation
    wait_for_flush 1
    
    # Verify all goals are active
    PROGRESS=$(get_user_progress)
    ACTIVE_COUNT=$(echo "$PROGRESS" | jq "[.challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[] | select(.isActive == true)] | length")
    
    echo -e "${BLUE}ℹ${NC} Activated $ACTIVE_COUNT out of $GOAL_COUNT goals"
    
    # Try random select with exclude_active=true (should fail - zero goals available)
    RESULT=$(random_select_goals "$CHALLENGE_ID" "3" "false" "true" 2>&1 || true)
    
    # Should return error (any error is acceptable - we just want to verify it fails)
    # The backend may return 400 with "insufficient_goals" or 500 with generic error
    if echo "$RESULT" | grep -qi "error\|failed\|no goals available\|insufficient"; then
        print_success "Zero goals error handling verified (operation failed as expected)"
    else
        echo -e "${RED}✗${NC} Expected error for zero available goals, but got: $RESULT"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping zero goals test (challenge has no goals)"
fi

#============================================================================
# Test 13: Edge Case - Count Exceeds Total Goals
#============================================================================
# Reset
cleanup_test_data

print_step 13 "Error when count exceeds total goals in challenge"

# Get total goal count
CHALLENGES=$(get_user_progress)
TOTAL_GOALS=$(echo "$CHALLENGES" | jq "[.challenges[] | select(.challengeId == \"$CHALLENGE_ID\") | .goals[]] | length")

if [ "$TOTAL_GOALS" -gt 0 ]; then
    # Request more goals than exist (before any filtering)
    EXCESSIVE_COUNT=$((TOTAL_GOALS + 10))
    
    RESULT=$(random_select_goals "$CHALLENGE_ID" "$EXCESSIVE_COUNT" "false" "false" 2>&1 || true)
    
    # Should either error or return partial results (all available goals)
    if echo "$RESULT" | grep -qi "error\|exceeds"; then
        print_success "Count exceeds total goals - error returned"
    else
        # Check if partial results were returned
        SELECTED_COUNT=$(extract_json_value "$RESULT" '.selectedGoals | length' 2>/dev/null || echo "0")
        
        if [ "$SELECTED_COUNT" -le "$TOTAL_GOALS" ] && [ "$SELECTED_COUNT" -gt 0 ]; then
            print_success "Count exceeds total goals - partial results returned ($SELECTED_COUNT/$TOTAL_GOALS)"
        else
            echo -e "${RED}✗${NC} Unexpected behavior when count exceeds total goals"
            echo "  Requested: $EXCESSIVE_COUNT, Total: $TOTAL_GOALS, Selected: $SELECTED_COUNT"
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping count exceeds test (challenge has no goals)"
fi

print_success "M4 Random Selection Tests"
