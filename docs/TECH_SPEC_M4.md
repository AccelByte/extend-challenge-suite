# Technical Specification: Milestone 4 - Batch & Random Goal Selection

**Document Version:** 4.0 (Implementation Complete)
**Date:** 2025-11-25
**Status:** ✅ IMPLEMENTATION COMPLETE
**Dependencies:** M3 Complete

**Related Documents:**
- [MILESTONES.md](./MILESTONES.md) - M4 overview
- [TECH_SPEC_M3.md](./TECH_SPEC_M3.md) - M3 assignment foundation
- [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md) - Database schema reference

---

## Design Decisions Summary

All planning questions have been resolved. Here are the final decisions:

### ✅ Q1: Random Selection Algorithm
- **Algorithm:** Smart Random with Auto-Filters (Option B)
- **Mandatory filters:** Exclude completed/claimed goals, exclude unmet prerequisites
- **Insufficient goals:** Return partial results (select all available)
- **Randomness:** Use crypto/rand from Go standard library

### ✅ Q2: Filter Options
- **API parameter:** `exclude_active` only (Minimal approach)
- **No tag/category filtering** (out of scope)
- **No "prefer incomplete"** (simple random is sufficient)

### ✅ Q3: Replace Behavior
- **API parameter:** `replace_existing` (User-controlled)
- **Progress preservation:** Deactivated goals KEEP their progress
- **Completed/unclaimed:** Can be deactivated, claim still available

### ✅ Q4: Validation Rules
- **Count validation:** Enforce count > 0
- **Available goals:** Return partial results if fewer available
- **Challenge exists:** Validate before processing
- **Max active goals:** No limit in M4 (deferred to M5)

**Implementation Impact:**
- ✅ No database schema changes needed
- ✅ No configuration changes needed
- ✅ Builds on M3 foundation (uses existing `is_active` column)
- ✅ New repository method: `BatchUpsertGoalActive` (performance optimization)

---

## Table of Contents

1. [Overview](#overview)
2. [Objectives](#objectives)
3. [Open Questions](#open-questions)
4. [API Design](#api-design)
5. [Business Logic](#business-logic)
6. [Implementation Plan](#implementation-plan)
7. [Testing Strategy](#testing-strategy)
8. [Success Criteria](#success-criteria)

---

## Overview

### What is M4?

Milestone 4 (M4) introduces **two new goal selection patterns** while keeping M3's individual activation API. This gives game developers maximum flexibility in how they present goal selection to players.

**Key Simplification:** No explicit "pools" needed. **All goals in a challenge act as an implicit pool**. Game developers can choose which selection pattern(s) to expose in their UI.

### Three Selection Patterns

**Pattern 1: Individual Manual Selection (M3 - Existing)**
- Player activates goals one at a time: `PUT /goals/{goal_id}/active`
- Best for: Careful, deliberate goal selection
- Example UI: Checkbox next to each goal

**Pattern 2: Batch Manual Selection (M4 - New)**
- Player selects multiple goals at once: `POST /goals/batch-select`
- Best for: Quick selection from a list
- Example UI: Multi-select dialog with "Select" button

**Pattern 3: Random Selection (M4 - New)**
- System randomly picks goals: `POST /goals/random-select`
- Best for: "Surprise me" / quick start flows
- Example UI: "Random 3 Goals" button

### Key Concepts

**Batch Manual Selection:**
- Player provides list of goal IDs to activate
- Atomic operation (all or nothing)
- Can replace existing active goals or add to them

**Random Selection:**
- **Challenge as Pool**: All goals in a challenge form the selection pool
- **Random Activation**: System randomly picks N goals and activates them
- **Replace Mode**: Option to deactivate existing active goals before selecting new ones
- **Smart Filters**: Exclude completed goals, goals with unmet prerequisites, or already-active goals

**Example Use Cases:**
- **Pattern 1 (Individual)**: Player browses goals, clicks checkbox on each they want
- **Pattern 2 (Batch)**: Player selects 3 goals from list, clicks "Activate Selected"
- **Pattern 3 (Random)**: Player clicks "Surprise Me" button, gets 3 random goals

### What Changes from M3?

| Aspect | M3 Behavior | M4 Behavior |
|--------|-------------|-------------|
| **Goal Activation** | Individual only | Individual + Batch + Random |
| **Selection Method** | Player picks one at a time | Player can pick multiple at once OR get random |
| **API** | Single goal endpoint | Single + Batch + Random endpoints |
| **UX Options** | Checkbox per goal | Checkbox + Multi-select + "Surprise Me" |
| **Atomicity** | Single goal per request | Multiple goals per request (batch/random) |

### Benefits

1. **Developer Flexibility**: Three patterns to choose from based on game design
2. **Gameplay Variety**: Random selection keeps gameplay fresh and unpredictable
3. **Reduced Choice Paralysis**: Batch/random avoids picking from 100+ goals one by one
4. **Quick Start**: One-click random selection gets players into the game faster
5. **Foundation for M5**: Random selection logic reusable for rotation auto-assignment
6. **Simple Implementation**: No complex pool configuration needed
7. **Backward Compatible**: M3 individual activation still works
8. **Performance Optimized**: New `BatchUpsertGoalActive` method reduces DB queries by 5-10x (10ms vs 20-50ms)

---

## Objectives

### Primary Goals

1. ✅ **Design batch manual selection API** - Activate multiple goals at once
2. ✅ **Design random selection API** - System randomly activates N goals from a challenge
3. ✅ **Define random selection algorithm** - Smart Random with Auto-Filters (Q1 resolved)
4. ✅ **Define insufficient goals behavior** - Return partial results (Q1 resolved)
5. ✅ **Define randomness source** - Use crypto/rand from Go stdlib (Q1 resolved)
6. ✅ **Design filter options** - Minimal (just `exclude_active` parameter) (Q2 resolved)
7. ✅ **Define replace behavior** - User-controlled via `replace_existing` parameter (Q3 resolved)
8. ✅ **Progress preservation** - Deactivated goals keep progress (Q3 resolved)
9. ✅ **Determine validation rules** - All checks implemented (count, available, challenge exists) (Q4 resolved)
10. ✅ **Max active goals limit** - No enforcement in M4 (deferred to M5) (Q4 resolved)
7. ✅ **No configuration changes needed** - Use existing challenge structure
8. ✅ **No database changes needed** - Use M3 `is_active` column
9. ✅ **Backward compatible** - M3 individual activation API still works

### Success Criteria

M4 is complete when:
- ✅ Players can manually activate multiple goals at once via batch API
- ✅ Players can randomly activate N goals from a challenge via random API
- ✅ Both APIs support "replace all" mode (deactivate existing first)
- ✅ Random selection can filter out completed/claimed goals
- ✅ Random selection can filter out already-active goals
- ✅ Batch selection validates all goals exist before activating any
- ✅ Validation prevents selecting more goals than available (random)
- ✅ M3 manual activation API still works (unchanged)
- ✅ All three patterns work together seamlessly
- ✅ All tests pass with ≥80% coverage
- ✅ E2E tests pass (15 scenarios across batch and random selection)
- ✅ Load tests validate improved performance with batch operations (< 30ms p95, ~10ms for DB operations)
- ✅ Linter reports 0 issues

---

## Open Questions

### ✅ Q1: Random Selection Algorithm (RESOLVED)

**Question:** How should random selection choose goals?

**DECISION:** **Option B (Smart Random with Auto-Filters)**

**Auto-Applied Filters (always applied):**
1. Exclude goals with `status = 'claimed'` (already got reward)
2. Exclude goals with `status = 'completed'` (completed but not claimed yet)
3. Exclude goals with unmet prerequisites (if prerequisite system exists)

**Optional Filters (via API params):**
1. `exclude_active: boolean` - Exclude goals already active (`is_active = true`)
2. `replace_existing: boolean` - Deactivate all active goals before selection

**Implementation:**
```go
func RandomSelectGoals(
    userID string,
    challenge *Challenge,
    count int,
    excludeActive bool,
) ([]string, error) {
    // Get all goals from challenge
    allGoals := challenge.Goals

    // Get user's current state from DB
    userProgress := repo.GetUserProgress(userID, challenge.ID)

    // Auto-filter: exclude completed/claimed
    available := []Goal{}
    for _, goal := range allGoals {
        progress := userProgress[goal.ID]

        // Skip if completed or claimed
        if progress != nil &amp;&amp; (progress.Status == "completed" || progress.Status == "claimed") {
            continue
        }

        // Skip if already active (if requested)
        if excludeActive &amp;&amp; progress != nil &amp;&amp; progress.IsActive {
            continue
        }

        // Skip if has unmet prerequisites
        if hasUnmetPrerequisites(goal, userProgress) {
            continue
        }

        available = append(available, goal)
    }

    // Validate sufficient goals
    if len(available) &lt; count {
        // DECISION: Return partial results (select all available)
        count = len(available)
        if count == 0 {
            return nil, fmt.Errorf("no goals available for selection")
        }
    }

    // DECISION: Use crypto/rand for seeded randomness (standard Go lib)
    selected := randomSample(available, count)

    return extractGoalIDs(selected), nil
}
```

**Follow-up Decisions:**
1. ✅ **Insufficient goals behavior:** Return partial results (select all available goals if fewer than requested)
   - Example: Request 5 goals, only 3 available → select all 3
   - Return error only if 0 goals available
2. ✅ **Randomness:** Use `crypto/rand` from standard Go library for seeded randomness
   - Ensures fairness and unpredictability
   - Industry standard for non-cryptographic random selection

**Rationale:**
- Partial results improve UX (player doesn't need to know exact count available)
- Better than hard error that requires client retry with lower count
- crypto/rand provides quality randomness without external dependencies

---

### ✅ Q2: Filter Options (RESOLVED)

**Question:** Which filters should be configurable via API parameters?

**DECISION:** **Option A (Minimal - Just `exclude_active`)**

**Mandatory Filters (always applied, not configurable):**
1. ✅ Exclude `status = 'claimed'` goals
2. ✅ Exclude `status = 'completed'` goals (player should claim first)
3. ✅ Exclude goals with unmet prerequisites

**Optional Filters (API parameters):**

**API Signature:**
```json
POST /v1/challenges/{id}/goals/random-select
Body: {
  "count": 3,
  "exclude_active": true  // Don't select already-active goals
}
```

**Rationale:**
- ✅ Simple API (only one optional filter parameter)
- ✅ Covers main use case (replace vs add behavior)
- ✅ Mandatory filters already provide good UX
- ✅ Easier to understand and document
- ✅ Less potential for confusion

**Follow-up Decisions:**
- ✅ **Tag/category filtering:** Not needed (out of scope for M4)
- ✅ **Prefer incomplete goals:** Not needed (simple random is sufficient)

---

### ✅ Q3: Replace Behavior (RESOLVED)

**Question:** How should random selection handle existing active goals?
answer: option C

**Scenario:** Player has 3 goals active, calls random selection for 3 new goals.

**Options:**

**Option A: Always Replace (Deactivate All First)**
```json
POST /v1/challenges/{id}/goals/random-select
Body: { "count": 3 }  // Always deactivates existing
```
- ✅ Pros: Simple, predictable
- ⚠️ Cons: Deactivates all goals (but progress is preserved)
- ❌ Cons: No way to "add more" goals

**Option B: Never Replace (Add Only)**
```json
POST /v1/challenges/{id}/goals/random-select
Body: { "count": 3 }  // Always keeps existing, adds new
```
- ✅ Pros: Never loses progress
- ❌ Cons: Can accumulate too many active goals
- ❌ Cons: No way to "refresh" selection

**Option C: User-Controlled via Parameter (Recommended)**
```json
POST /v1/challenges/{id}/goals/random-select
Body: {
  "count": 3,
  "replace_existing": true  // true = deactivate first, false = add to existing
}
```
- ✅ Pros: User choice
- ✅ Pros: Supports both use cases
- ❌ Cons: Slightly more complex API

**DECISION:** **Option C (User-Controlled via `replace_existing` parameter)**

**Behavior:**
- `replace_existing: true` → Deactivate all active goals in challenge, then select new ones
- `replace_existing: false` → Keep existing active goals, add N more (subject to max limit)

**Edge Case Handling:**
```
# Scenario 1: Replace mode
Player has [A, B, C] active
POST random-select { count: 3, replace_existing: true }
→ Deactivate [A, B, C]
→ Select [D, E, F] randomly
→ Result: [D, E, F] active

# Scenario 2: Add mode
Player has [A, B, C] active
POST random-select { count: 3, replace_existing: false, exclude_active: true }
→ Keep [A, B, C]
→ Select 3 from remaining goals (excluding A, B, C)
→ Result: [A, B, C, D, E, F] active

# Scenario 3: Add mode with insufficient goals
Player has [A, B, C] active
Challenge has only 4 total goals [A, B, C, D]
POST random-select { count: 3, replace_existing: false, exclude_active: true }
→ Error: "Only 1 goal available (excluding active), requested 3"
```

**Follow-up Decisions:**

1. ✅ **Deactivated goals and progress:** Deactivated goals **KEEP their progress** (not reset to 0)
   - **Current M3 behavior:** `UpsertGoalActive` only modifies `is_active`, `assigned_at`, and `updated_at`
   - **Progress field unchanged:** If goal has 7/10 progress, it stays at 7 when deactivated
   - **Status unchanged:** Goal status (not_started/in_progress/completed/claimed) preserved
   - **Rationale:** Good UX - players can "pause" goals without losing work
   - **Implementation:** No changes needed (M3 already works this way)
   
   Example:
   ```
   Player has goal "Kill 10 Snowmen" with progress 7/10
   → Deactivate goal (via replace_existing: true)
   → Progress remains at 7/10 (just is_active = false)
   → Goal won't receive event updates while inactive
   → Player reactivates later → still has 7/10 progress
   ```

2. ✅ **Completed but unclaimed goals in replace mode:** Can be deactivated (progress preserved)
   - **Status = 'completed':** Goal finished but reward not claimed yet
   - **Replace mode behavior:** Will deactivate (set is_active = false)
   - **Progress preserved:** Player can still claim reward later via explicit claim API
   - **Auto-filter:** Smart Random excludes completed goals from new selection (see Q1)
   - **Rationale:** Player has full control over when to claim rewards
   
   Example:
   ```
   Player has goals: [A: completed/unclaimed, B: in_progress 5/10, C: active]
   POST random-select { count: 3, replace_existing: true }
   → Deactivate [A, B, C] (all keep their progress/status)
   → Select [D, E, F] randomly (smart filter excludes A from selection)
   → Result: [D, E, F] active
   → Player can still claim A's reward anytime via POST /claim
   ```

---

### ✅ Q4: Validation Rules (RESOLVED)

**Question:** What validation should be enforced on random selection requests?

**DECISION:** Implement all validation checks below

**Validation Checks:**

1. **Count Validation**
   ```go
   if count <= 0 {
       return ErrInvalidCount
   }
   if count > len(allGoals) {
       return ErrCountExceedsTotal
   }
   ```

2. **Sufficient Goals Available**
   ```go
   if len(availableGoals) < count {
       return fmt.Errorf("only %d goals available, requested %d", len(availableGoals), count)
   }
   ```

3. **Challenge Exists**
   ```go
   challenge := cache.GetChallengeByID(challengeID)
   if challenge == nil {
       return ErrChallengeNotFound
   }
   ```

4. **Max Active Goals Limit**
   - **M4 Decision:** No enforcement (rely on client behavior)
   - **Rationale:** Keep M4 simple, add complexity only when needed
   - **Future (M5):** Add optional `max_active_goals` config field if needed

**Error Responses:**

```json
// No goals available (only error case)
{
  "error": "insufficient_goals",
  "message": "No goals available for selection",
  "available_count": 0,
  "requested_count": 3,
  "suggestion": "Complete or claim existing goals, or adjust filters"
}

// Note: If available_count &gt; 0 but less than requested, API returns partial results (not an error)

// Invalid count
{
  "error": "invalid_count",
  "message": "Count must be > 0",
  "requested_count": 0
}

// Challenge not found
{
  "error": "challenge_not_found",
  "message": "Challenge 'invalid-id' not found",
  "challenge_id": "invalid-id"
}
```

**Follow-up Decisions (from Q1):**
- ✅ Auto-adjust count if insufficient goals: **YES** - return partial results (select all available)
- 🔍 Max active goals per challenge: Deferred to future milestone (M5)

---

## API Design

### New Endpoint 1: Batch Manual Selection

```http
POST /v1/challenges/{challenge_id}/goals/batch-select
Authorization: Bearer <JWT>

Request Body:
{
  "goal_ids": [                 // Required: list of goal IDs to activate
    "daily-login",
    "daily-10-kills",
    "daily-3-matches"
  ],
  "replace_existing": false     // Optional: deactivate existing first (default: false)
}

Success Response (200 OK):
{
  "selected_goals": [
    {
      "goal_id": "daily-login",
      "name": "Daily Login",
      "status": "activated",
      "progress": 0,
      "target": 1,
      "is_active": true
    },
    {
      "goal_id": "daily-10-kills",
      "name": "Get 10 Kills",
      "status": "activated",
      "progress": 0,
      "target": 10,
      "is_active": true
    },
    {
      "goal_id": "daily-3-matches",
      "name": "Play 3 Matches",
      "status": "activated",
      "progress": 0,
      "target": 3,
      "is_active": true
    }
  ],
  "challenge_id": "daily-challenges",
  "total_active_goals": 3,
  "replaced_goals": []
}

Error Responses:
- 400 Bad Request: Invalid goal IDs, empty list
- 404 Not Found: Challenge or goal doesn't exist
- 401 Unauthorized: Missing/invalid JWT
- 500 Internal Server Error: Database/service error
```

**Use Case:**
- Player selects 3 goals from UI (checkboxes/multi-select)
- Clicks "Activate Selected" button
- All 3 goals activated atomically (all or nothing)

---

### New Endpoint 2: Random Goal Selection

```http
POST /v1/challenges/{challenge_id}/goals/random-select
Authorization: Bearer <JWT>

Request Body:
{
  "count": 3,                    // Required: number of goals to select
  "replace_existing": false,     // Optional: deactivate existing first (default: false)
  "exclude_active": true         // Optional: exclude already-active goals (default: false)
}

Success Response (200 OK):
{
  "selected_goals": [
    {
      "goal_id": "daily-login",
      "name": "Daily Login",
      "description": "Login to the game",
      "requirement": {
        "stat_code": "login_count",
        "target_value": 1
      },
      "reward": {
        "type": "WALLET",
        "reward_id": "GEMS",
        "quantity": 50
      },
      "status": "activated",         // Just activated
      "progress": 0,                 // No progress yet
      "is_active": true
    },
    {
      "goal_id": "daily-10-kills",
      "name": "Get 10 Kills",
      "requirement": {
        "stat_code": "enemy_kills",
        "target_value": 10
      },
      "reward": {
        "type": "ITEM",
        "reward_id": "bronze_sword",
        "quantity": 1
      },
      "status": "activated",
      "progress": 0,
      "is_active": true
    }
  ],
  "challenge_id": "daily-challenges",
  "total_active_goals": 2,          // Total active after this operation
  "replaced_goals": []              // Goals deactivated (if replace_existing=true)
}

Error Responses:
- 400 Bad Request: Invalid count (count &lt;= 0), no goals available (0 available after filtering)
- 404 Not Found: Challenge doesn't exist
- 401 Unauthorized: Missing/invalid JWT
- 500 Internal Server Error: Database/service error

**Note:** If fewer goals are available than requested (but &gt; 0), the API returns partial results with all available goals instead of an error
```

### Existing M3 Endpoints (Unchanged)

```http
# Manual activation (still works)
PUT /v1/challenges/{challenge_id}/goals/{goal_id}/active
Body: { "is_active": true }

# List all challenges with progress
GET /v1/challenges

# Get specific challenge with progress
GET /v1/challenges/{challenge_id}

# Claim reward
POST /v1/challenges/{challenge_id}/goals/{goal_id}/claim
```

---

## Business Logic

### Random Selection Flow

```go
// Service layer
func (s *ChallengeService) RandomSelectGoals(
    ctx context.Context,
    userID string,
    challengeID string,
    count int,
    replaceExisting bool,
    excludeActive bool,
) (*RandomSelectionResult, error) {
    // 1. Validate challenge exists
    challenge := s.cache.GetChallengeByID(challengeID)
    if challenge == nil {
        return nil, ErrChallengeNotFound
    }

    // 2. Get user's current progress
    userProgress, err := s.repo.GetUserChallengeProgress(ctx, userID, challengeID)
    if err != nil {
        return nil, fmt.Errorf("get user progress: %w", err)
    }

    // 3. Filter available goals
    available := s.filterAvailableGoals(challenge.Goals, userProgress, excludeActive)

    // 4. Handle insufficient goals (return partial results)
    if len(available) < count {
        if len(available) == 0 {
            return nil, &amp;InsufficientGoalsError{
                Available: 0,
                Requested: count,
                Message:   "no goals available for selection",
            }
        }
        // Use all available goals (partial result)
        count = len(available)
    }

    // 5. Random sample using crypto/rand
    selected := randomSample(available, count)

    // 6. Database transaction
    tx, err := s.repo.BeginTx(ctx)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()

    // 7. Deactivate existing (if replace mode)
    replacedGoals := []string{}
    if replaceExisting {
        activeGoals := getActiveGoalIDs(userProgress)
        err = tx.DeactivateGoals(ctx, userID, activeGoals)
        if err != nil {
            return nil, fmt.Errorf("deactivate goals: %w", err)
        }
        replacedGoals = activeGoals
    }

    // 8. Activate selected goals (BATCH operation for performance)
    // Build batch of goals to activate
    now := time.Now()
    goalBatch := make([]*UserGoalProgress, len(selected))
    for i, goalID := range selected {
        goalBatch[i] = &UserGoalProgress{
            UserID:      userID,
            GoalID:      goalID,
            ChallengeID: challengeID,
            Namespace:   challenge.Namespace,
            IsActive:    true,
            AssignedAt:  &now,
            ExpiresAt:   nil,  // M4: no rotation yet
            Progress:    0,
            Status:      "not_started",
        }
    }

    // Single batch operation instead of N queries
    err = tx.BatchUpsertGoalActive(ctx, goalBatch)
    if err != nil {
        return nil, fmt.Errorf("batch activate goals: %w", err)
    }

    // 9. Commit transaction
    if err = tx.Commit(); err != nil {
        return nil, err
    }

    // 10. Build response
    selectedGoalDetails := s.buildGoalDetails(challenge, selected)
    totalActive := len(selected)
    if !replaceExisting {
        totalActive += len(getActiveGoalIDs(userProgress))
    }

    return &RandomSelectionResult{
        SelectedGoals:   selectedGoalDetails,
        ChallengeID:     challengeID,
        TotalActiveGoals: totalActive,
        ReplacedGoals:   replacedGoals,
    }, nil
}

// Filter available goals
func (s *ChallengeService) filterAvailableGoals(
    allGoals []Goal,
    userProgress map[string]*UserGoalProgress,
    excludeActive bool,
) []string {
    available := []string{}

    for _, goal := range allGoals {
        progress := userProgress[goal.ID]

        // Skip completed goals
        if progress != nil && (progress.Status == "completed" || progress.Status == "claimed") {
            continue
        }

        // Skip active goals (if requested)
        if excludeActive && progress != nil && progress.IsActive {
            continue
        }

        // Skip goals with unmet prerequisites
        if s.hasUnmetPrerequisites(goal, userProgress) {
            continue
        }

        available = append(available, goal.ID)
    }

    return available
}

// Random sample (Fisher-Yates shuffle)
func randomSample(goals []string, count int) []string {
    // Copy to avoid modifying input
    pool := make([]string, len(goals))
    copy(pool, goals)

    // Fisher-Yates shuffle
    for i := 0; i < count; i++ {
        j := i + rand.Intn(len(pool)-i)  // crypto/rand for fairness
        pool[i], pool[j] = pool[j], pool[i]
    }

    return pool[:count]
}
```

---

## Database Operations

### New Repository Method Required

To achieve optimal performance for batch goal activation, a new repository method is needed:

```go
// extend-challenge-common/pkg/repository/goal_repository.go

type GoalRepository interface {
    // ... existing methods (GetProgress, UpsertProgress, etc.) ...

    // M4: Batch version of UpsertGoalActive for efficient random/batch selection
    // Activates multiple goals in a single database operation.
    //
    // Behavior:
    //   - If row exists: sets is_active=true, assigned_at=NOW(), updated_at=NOW()
    //   - If row doesn't exist: creates new row with is_active=true, status='not_started'
    //
    // Performance: ~10ms for 10 goals (vs ~20-50ms with individual UpsertGoalActive loop)
    //
    // Implementation Strategy:
    //   1. Batch UPDATE for existing rows: SET is_active=true WHERE goal_id IN (...)
    //   2. Batch INSERT for missing rows: INSERT ... ON CONFLICT DO NOTHING
    //
    // Used by:
    //   - POST /goals/random-select (M4)
    //   - POST /goals/batch-select (M4)
    //
    // NOTE: This method is defined in GoalRepository (not TxRepository) following
    // the existing pattern where all batch operations are in the base interface.
    // TxRepository inherits this method via embedding.
    BatchUpsertGoalActive(ctx context.Context, progresses []*domain.UserGoalProgress) error
}

// TxRepository embeds GoalRepository and adds transaction-specific methods.
// It automatically inherits BatchUpsertGoalActive from GoalRepository.
type TxRepository interface {
    GoalRepository  // Inherits all methods including BatchUpsertGoalActive

    // Transaction-specific methods only
    GetProgressForUpdate(ctx context.Context, userID, goalID string) (*domain.UserGoalProgress, error)
    Commit() error
    Rollback() error
}
```

### Implementation Notes

**Why not reuse existing batch methods?**

| Method | Why Not Suitable for M4 |
|--------|------------------------|
| `BatchUpsertProgress` | N+1 queries (10 goals = 10-20 queries), missing M3 fields |
| `BatchUpsertProgressWithCOPY` | UPDATE-only (no INSERT), optimized for event processing, doesn't set `is_active`/`assigned_at` |
| `BulkInsert` | INSERT-only with `ON CONFLICT DO NOTHING`, doesn't update existing rows |
| `UpsertGoalActive` (loop) | Correct semantics but N+1 queries (20-50ms for 10 goals) |

**Performance comparison:**

| Approach | Queries | Time (10 goals) | Recommended? |
|----------|---------|-----------------|--------------|
| Loop `UpsertGoalActive` | 10-20 | 20-50ms | ⚠️ OK for MVP |
| `BatchUpsertGoalActive` | 2 | 10ms | ✅ Production |

**SQL Implementation (Postgres):**

**Design Note:** This implementation uses UNNEST to map each goal to its specific `is_active` value, enabling both activation (`is_active = true`) and deactivation (`is_active = false`) through the same method. This flexibility is required for M4's replace mode, where existing goals are deactivated before selecting new ones.

```sql
-- Step 1: Update existing rows using UNNEST to map each goal to its is_active value
UPDATE user_goal_progress
SET is_active = data.is_active,
    assigned_at = NOW(),
    updated_at = NOW()
FROM (
    SELECT UNNEST($2::text[]) AS goal_id, UNNEST($3::boolean[]) AS is_active
) AS data
WHERE user_goal_progress.user_id = $1
  AND user_goal_progress.goal_id = data.goal_id;

-- Step 2: Insert missing rows with actual is_active values
-- ON CONFLICT DO UPDATE handles race conditions where row created between Step 1 and Step 2
INSERT INTO user_goal_progress (
    user_id, goal_id, challenge_id, namespace,
    progress, status, is_active, assigned_at,
    created_at, updated_at, expires_at
) VALUES
    ($1, $2, $3, $4, 0, 'not_started', $5, NOW(), NOW(), NOW(), $6),
    ($7, $8, $9, $10, 0, 'not_started', $11, NOW(), NOW(), NOW(), $12),
    -- ... (one row per goal)
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    is_active = EXCLUDED.is_active,
    assigned_at = NOW(),
    updated_at = NOW();
```

**Parameters:**
- `$1`: user_id (string)
- `$2`: array of goal_ids (string[])
- `$3`: array of is_active values (boolean[])
- Step 2 per-row: user_id, goal_id, challenge_id, namespace, is_active, expires_at

**Total: 2 queries instead of 10-20 queries**

---

## Implementation Plan

### Estimated Timeline: 3-4 days

**Day 1: Repository Layer (4-6 hours)**
- Add `BatchUpsertGoalActive` interface method to `GoalRepository`
- Implement in `PostgresGoalRepository` (2 SQL queries)
- `PostgresTxRepository` automatically inherits via embedding
- Unit tests for batch upsert (≥80% coverage)
  - Test UPDATE existing rows
  - Test INSERT missing rows
  - Test mixed existing + new rows
  - Test sets `is_active=true`, `assigned_at=NOW()`
- Integration test with real database

**Day 2: Service Logic (6-8 hours)**
- Implement random selection algorithm (filter → shuffle → sample)
- Add random selection service method
- Add database transaction handling using `BatchUpsertGoalActive`
- Unit tests for selection logic (≥80% coverage)

**Day 3: API Endpoint & Testing (8-10 hours)**

*Backend Service:*
- Implement `POST /goals/random-select` endpoint
- Implement `POST /goals/batch-select` endpoint
- Add request validation
- Add authentication check
- Add error handling
- API tests (valid/invalid inputs)
- Integration tests (DB + API)

*Demo App (for E2E testing):*
- Add `BatchSelectGoals()` and `RandomSelectGoals()` to APIClient (30 mins)
- Add request/response models (15 mins)
- Create `batch-select` CLI command (30 mins)
- Create `random-select` CLI command (30 mins)
- Register commands in main.go (5 mins)
- Manual testing of CLI commands (30 mins)

*E2E Tests:*
- Update `helpers.sh` with `batch_select_goals()` and `random_select_goals()` functions (30 mins)
- Create `test-m4-batch-selection.sh` (6 scenarios) (1 hour)
- Create `test-m4-random-selection.sh` (9 scenarios) (1.5 hours)
- Update `run-all-tests.sh` to include M4 tests (10 mins)
- Run and debug E2E tests (1 hour)

*Performance & Quality:*
- Performance testing (verify ~10ms p95 for batch operation)
- Linter verification
- Documentation updates

**Total: ~20-26 hours (3-4 days, including demo app updates)**

---

## Testing Strategy

### Unit Tests (Target: ≥80% coverage)

1. **Random Selection Algorithm**
   ```go
   func TestFilterAvailableGoals(t *testing.T) {
       // Test excludes completed goals
       // Test excludes active goals when excludeActive=true
       // Test excludes goals with unmet prerequisites
       // Test returns all available when no filters
   }

   func TestRandomSample(t *testing.T) {
       // Test correct count returned
       // Test no duplicates
       // Test all elements from pool
       // Test empty pool
   }
   ```

2. **Service Layer**
   ```go
   func TestRandomSelectGoals_Success(t *testing.T) {
       // Mock dependencies
       // Verify correct goals selected
       // Verify DB calls made
       // Verify transaction committed
   }

   func TestRandomSelectGoals_InsufficientGoals(t *testing.T) {
       // Request more than available
       // Verify error returned
       // Verify no DB changes
   }

   func TestRandomSelectGoals_ReplaceMode(t *testing.T) {
       // Verify existing goals deactivated
       // Verify new goals activated
   }
   ```

3. **API Tests**
   ```go
   func TestRandomSelectEndpoint_ValidRequest(t *testing.T) {
       // Happy path
       // Verify 200 OK
       // Verify response format
   }

   func TestRandomSelectEndpoint_InvalidCount(t *testing.T) {
       // count = 0
       // count = -1
       // Verify 400 Bad Request
   }
   ```

### Integration Tests

```go
func TestRandomSelect_E2E(t *testing.T) {
    // Setup: Create challenge with 10 goals
    // Setup: User has 3 completed, 2 active

    // Test 1: Random select 3 (exclude active)
    resp := POST("/v1/challenges/daily/goals/random-select", {
        count: 3,
        exclude_active: true
    })
    assert.Equal(t, 3, len(resp.SelectedGoals))
    assert.NoDuplicates(t, resp.SelectedGoals)

    // Verify DB state
    progress := repo.GetUserProgress(userID, "daily")
    assert.Equal(t, 5, countActiveGoals(progress))  // 2 existing + 3 new

    // Test 2: Replace mode
    resp2 := POST("/v1/challenges/daily/goals/random-select", {
        count: 5,
        replace_existing: true
    })
    assert.Equal(t, 5, len(resp2.SelectedGoals))
    assert.Equal(t, 5, countActiveGoals(repo.GetUserProgress(userID, "daily")))
}
```

### Performance Validation

**Objective:** Validate random selection achieves ~10ms p95 with batch operations

**Test Scenario:**
- Load: 100 RPS for `POST /goals/random-select`
- Challenge: 50 goals
- User state: 10 completed, 5 active
- Request: `count=5, exclude_active=true`

**Expected Performance (with `BatchUpsertGoalActive`):**
- DB operation time: ~10ms for batch activation (2 queries)
- Total API latency p95: < 30ms (includes filtering, transaction overhead)
- Total API latency p99: < 50ms
- Success rate: 100%
- No DB connection exhaustion

**Performance Breakdown:**
| Operation | Time |
|-----------|------|
| GetUserChallengeProgress (1 query) | 3-5ms |
| In-memory filtering + random sampling | < 1ms |
| DeactivateGoals (1 query, if replace mode) | 5-10ms |
| **BatchUpsertGoalActive (2 queries)** | **~10ms** ✅ |
| Transaction commit | 2-5ms |
| **Total** | **20-30ms** ✅ |

**k6 Test Script:**
```javascript
import http from 'k6/http';

export let options = {
  vus: 50,
  duration: '60s',
  thresholds: {
    http_req_duration: ['p(95)<30', 'p(99)<50'],  // Improved with BatchUpsertGoalActive
  },
};

export default function () {
  const payload = JSON.stringify({
    count: 5,
    exclude_active: true,
  });

  http.post('http://localhost:8080/v1/challenges/daily/goals/random-select', payload, {
    headers: { 'Authorization': `Bearer ${__ENV.JWT}` },
  });
}
```

### Demo App Updates Required

**Objective:** Update the demo app CLI to support M4 endpoints for E2E testing

The E2E test infrastructure uses the demo app CLI to make API calls to the backend service. For M4, the demo app must be extended with new commands to support batch and random selection.

**Architecture Context:**
- E2E tests call helper functions in `tests/e2e/helpers.sh`
- Helpers invoke demo app CLI commands via `run_cli` (e.g., `challenge-demo batch-select`)
- Demo app CLI commands use `internal/api/client.go` to make HTTP requests to backend service
- Backend service is at `http://localhost:8000/challenge`

**Required Changes:**

#### 1. New API Client Methods (`extend-challenge-demo-app/internal/api/client.go`)

Add two new methods to the `APIClient` interface and `HTTPAPIClient` implementation:

```go
// APIClient interface - add to existing interface
type APIClient interface {
    // ... existing M1/M3 methods ...

    // M4 endpoints
    BatchSelectGoals(ctx context.Context, challengeID string, req *BatchSelectRequest) (*BatchSelectResponse, error)
    RandomSelectGoals(ctx context.Context, challengeID string, req *RandomSelectRequest) (*RandomSelectResponse, error)
}

// HTTPAPIClient implementation
func (c *HTTPAPIClient) BatchSelectGoals(ctx context.Context, challengeID string, req *BatchSelectRequest) (*BatchSelectResponse, error) {
    path := fmt.Sprintf("/v1/challenges/%s/goals/batch-select", challengeID)
    resp, err := c.doRequest(ctx, "POST", path, req)
    if err != nil {
        return nil, fmt.Errorf("batch select goals: %w", err)
    }
    defer resp.Body.Close()

    if err := c.checkStatusCode(resp); err != nil {
        return nil, err
    }

    var result BatchSelectResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    return &result, nil
}

func (c *HTTPAPIClient) RandomSelectGoals(ctx context.Context, challengeID string, req *RandomSelectRequest) (*RandomSelectResponse, error) {
    path := fmt.Sprintf("/v1/challenges/%s/goals/random-select", challengeID)
    resp, err := c.doRequest(ctx, "POST", path, req)
    if err != nil {
        return nil, fmt.Errorf("random select goals: %w", err)
    }
    defer resp.Body.Close()

    if err := c.checkStatusCode(resp); err != nil {
        return nil, err
    }

    var result RandomSelectResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    return &result, nil
}
```

#### 2. New Request/Response Models (`extend-challenge-demo-app/internal/api/models.go`)

Add models for M4 API requests and responses:

```go
// M4: Batch Selection
type BatchSelectRequest struct {
    GoalIDs         []string `json:"goal_ids"`
    ReplaceExisting bool     `json:"replace_existing"`
}

type BatchSelectResponse struct {
    SelectedGoals    []GoalProgress `json:"selected_goals"`
    ChallengeID      string         `json:"challenge_id"`
    TotalActiveGoals int            `json:"total_active_goals"`
    ReplacedGoals    []string       `json:"replaced_goals"`
}

// M4: Random Selection
type RandomSelectRequest struct {
    Count           int  `json:"count"`
    ReplaceExisting bool `json:"replace_existing"`
    ExcludeActive   bool `json:"exclude_active"`
}

type RandomSelectResponse struct {
    SelectedGoals    []GoalProgress `json:"selected_goals"`
    ChallengeID      string         `json:"challenge_id"`
    TotalActiveGoals int            `json:"total_active_goals"`
    ReplacedGoals    []string       `json:"replaced_goals"`
}
```

#### 3. New CLI Commands (`extend-challenge-demo-app/internal/cli/commands/`)

Create `batch_select.go`:

```go
package commands

import (
    "context"
    "fmt"
    "strings"

    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/app"
    "github.com/spf13/cobra"
)

func NewBatchSelectCommand() *cobra.Command {
    var (
        challengeID     string
        goalIDs         string
        replaceExisting bool
    )

    cmd := &cobra.Command{
        Use:   "batch-select",
        Short: "Batch select multiple goals",
        Long:  "Activate multiple goals at once (M4 feature)",
        RunE: func(cmd *cobra.Command, args []string) error {
            container := app.GetContainerFromContext(cmd)
            
            // Parse goal IDs
            goalIDList := strings.Split(goalIDs, ",")
            if len(goalIDList) == 0 {
                return fmt.Errorf("goal-ids cannot be empty")
            }

            req := &api.BatchSelectRequest{
                GoalIDs:         goalIDList,
                ReplaceExisting: replaceExisting,
            }

            result, err := container.APIClient.BatchSelectGoals(context.Background(), challengeID, req)
            if err != nil {
                return err
            }

            return container.Formatter.FormatOutput(result)
        },
    }

    cmd.Flags().StringVar(&challengeID, "challenge-id", "", "Challenge ID (required)")
    cmd.Flags().StringVar(&goalIDs, "goal-ids", "", "Comma-separated goal IDs (required)")
    cmd.Flags().BoolVar(&replaceExisting, "replace-existing", false, "Deactivate existing goals first")
    cmd.MarkFlagRequired("challenge-id")
    cmd.MarkFlagRequired("goal-ids")

    return cmd
}
```

Create `random_select.go`:

```go
package commands

import (
    "context"

    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/app"
    "github.com/spf13/cobra"
)

func NewRandomSelectCommand() *cobra.Command {
    var (
        challengeID     string
        count           int
        replaceExisting bool
        excludeActive   bool
    )

    cmd := &cobra.Command{
        Use:   "random-select",
        Short: "Randomly select N goals",
        Long:  "Randomly activate N goals from a challenge (M4 feature)",
        RunE: func(cmd *cobra.Command, args []string) error {
            container := app.GetContainerFromContext(cmd)

            req := &api.RandomSelectRequest{
                Count:           count,
                ReplaceExisting: replaceExisting,
                ExcludeActive:   excludeActive,
            }

            result, err := container.APIClient.RandomSelectGoals(context.Background(), challengeID, req)
            if err != nil {
                return err
            }

            return container.Formatter.FormatOutput(result)
        },
    }

    cmd.Flags().StringVar(&challengeID, "challenge-id", "", "Challenge ID (required)")
    cmd.Flags().IntVar(&count, "count", 3, "Number of goals to select")
    cmd.Flags().BoolVar(&replaceExisting, "replace-existing", false, "Deactivate existing goals first")
    cmd.Flags().BoolVar(&excludeActive, "exclude-active", false, "Exclude already-active goals")
    cmd.MarkFlagRequired("challenge-id")

    return cmd
}
```

#### 4. Register Commands (`extend-challenge-demo-app/cmd/challenge-demo/main.go`)

Add command registration in `main()`:

```go
// M4: Add goal selection commands
rootCmd.AddCommand(commands.NewBatchSelectCommand())
rootCmd.AddCommand(commands.NewRandomSelectCommand())
```

#### 5. Update E2E Test Helpers (`tests/e2e/helpers.sh`)

The helper functions reference demo app CLI commands:

```bash
# Batch select goals
# Usage: batch_select_goals "goal1,goal2,goal3" "replace_existing_bool"
batch_select_goals() {
    local goal_ids="$1"
    local replace_existing="${2:-false}"
    local challenge_id="${CHALLENGE_ID:-daily-challenges}"
    
    run_cli batch-select \
        --challenge-id="$challenge_id" \
        --goal-ids="$goal_ids" \
        --replace-existing="$replace_existing" \
        --format=json
}

# Random select goals
# Usage: random_select_goals "count" "replace_existing_bool" "exclude_active_bool"
random_select_goals() {
    local count="$1"
    local replace_existing="${2:-false}"
    local exclude_active="${3:-false}"
    local challenge_id="${CHALLENGE_ID:-daily-challenges}"
    
    run_cli random-select \
        --challenge-id="$challenge_id" \
        --count="$count" \
        --replace-existing="$replace_existing" \
        --exclude-active="$exclude_active" \
        --format=json
}
```

**Implementation Checklist:**

- ✅ Add `BatchSelectGoals()` method to APIClient interface
- ✅ Add `RandomSelectGoals()` method to APIClient interface
- ✅ Implement both methods in HTTPAPIClient
- ✅ Add BatchSelectRequest/Response models
- ✅ Add RandomSelectRequest/Response models
- ✅ Create `batch_select.go` CLI command
- ✅ Create `random_select.go` CLI command
- ✅ Register commands in main.go
- ✅ Update helpers.sh with batch_select_goals() function
- ✅ Update helpers.sh with random_select_goals() function
- ✅ Test commands manually before running E2E tests

**Estimated Effort:** 2-3 hours (straightforward additions following existing M3 pattern)

---

### E2E Tests (Bash Scripts in tests/e2e/)

**Objective:** Validate M4 features work end-to-end with real API calls and database state

**Prerequisites:** Demo app must be updated with M4 CLI commands (see section above)

**New Test Files to Create:**

#### 1. `test-m4-batch-selection.sh`

Test batch manual selection endpoint with various scenarios.

**Test Scenarios:**

```bash
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

#============================================================================
# Test 1: Batch Select Multiple Goals (Happy Path)
#============================================================================
print_step 1 "Batch select 3 goals - happy path"

# Call batch-select with 3 goal IDs
RESULT=$(batch_select_goals "daily-login,daily-10-kills,daily-3-matches" "false")

# Verify response
SELECTED_COUNT=$(extract_json_value "$RESULT" '.selected_goals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')

assert_equals "$SELECTED_COUNT" "3" "Should select exactly 3 goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 total active goals"
print_success "Batch selection successful"

#============================================================================
# Test 2: Batch Select with replace_existing=true
#============================================================================
print_step 2 "Batch select with replace mode"

# First batch: select 2 goals
batch_select_goals "goal-a,goal-b" "false"

# Second batch: replace with 3 new goals
RESULT=$(batch_select_goals "goal-c,goal-d,goal-e" "true")

REPLACED_COUNT=$(extract_json_value "$RESULT" '.replaced_goals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')

assert_equals "$REPLACED_COUNT" "2" "Should replace 2 existing goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 active goals after replace"
print_success "Replace mode working correctly"

#============================================================================
# Test 3: Batch Select with replace_existing=false (Add Mode)
#============================================================================
print_step 3 "Batch select with add mode"

# Reset
cleanup_test_data

# First: select 2 goals
batch_select_goals "goal-a,goal-b" "false"

# Second: add 2 more goals (not replace)
RESULT=$(batch_select_goals "goal-c,goal-d" "false")

TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')

assert_equals "$TOTAL_ACTIVE" "4" "Should have 4 active goals (2 existing + 2 new)"
print_success "Add mode working correctly"

#============================================================================
# Test 4: Error - Invalid Goal IDs
#============================================================================
print_step 4 "Error handling - invalid goal IDs"

# Try to select non-existent goals
RESULT=$(batch_select_goals "invalid-goal-1,invalid-goal-2" "false" 2>&1 || true)

assert_contains "$RESULT" "404" "Should return 404 for invalid goal IDs"
print_success "Invalid goal IDs rejected correctly"

#============================================================================
# Test 5: Error - Empty Goal List
#============================================================================
print_step 5 "Error handling - empty goal list"

RESULT=$(batch_select_goals "" "false" 2>&1 || true)

assert_contains "$RESULT" "400" "Should return 400 for empty list"
print_success "Empty list rejected correctly"

#============================================================================
# Test 6: Atomicity - All or Nothing
#============================================================================
print_step 6 "Atomicity verification"

# Reset
cleanup_test_data

# Try to select mix of valid and invalid goals (should fail atomically)
RESULT=$(batch_select_goals "valid-goal,invalid-goal" "false" 2>&1 || true)

# Verify NO goals were activated (atomicity)
PROGRESS=$(get_user_progress)
ACTIVE_COUNT=$(extract_json_value "$PROGRESS" '[.challenges[].goals[] | select(.is_active == true)] | length')

assert_equals "$ACTIVE_COUNT" "0" "No goals should be active if batch fails"
print_success "Atomicity verified - all or nothing"

print_test_summary "M4 Batch Selection Tests"
```

**Required Helper Function in `helpers.sh`:**

```bash
# Batch select goals
# Usage: batch_select_goals "goal1,goal2,goal3" "replace_existing_bool"
batch_select_goals() {
    local goal_ids="$1"
    local replace_existing="${2:-false}"
    local challenge_id="${CHALLENGE_ID:-daily-challenges}"
    
    # Convert comma-separated to JSON array
    local goal_array=$(echo "$goal_ids" | awk -F',' '{printf "["; for(i=1; i<=NF; i++) {printf "\"%s\"", $i; if(i<NF) printf ","}; printf "]"}')
    
    local payload=$(cat <<EOF
{
  "goal_ids": $goal_array,
  "replace_existing": $replace_existing
}
EOF
)
    
    curl -s -X POST \
        "$DEMO_APP_URL/v1/challenges/$challenge_id/goals/batch-select" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload"
}
```

---

#### 2. `test-m4-random-selection.sh`

Test random selection endpoint with comprehensive scenarios.

**Test Scenarios:**

```bash
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

#============================================================================
# Test 1: Random Select N Goals (Happy Path)
#============================================================================
print_step 1 "Random select 3 goals - happy path"

RESULT=$(random_select_goals "3" "false" "false")

# Verify response
SELECTED_COUNT=$(extract_json_value "$RESULT" '.selected_goals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')

assert_equals "$SELECTED_COUNT" "3" "Should select exactly 3 goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 total active goals"

# Verify no duplicates
GOAL_IDS=$(extract_json_value "$RESULT" '.selected_goals[].goal_id')
UNIQUE_COUNT=$(echo "$GOAL_IDS" | sort | uniq | wc -l)
assert_equals "$UNIQUE_COUNT" "3" "Should have no duplicate goals"

print_success "Random selection successful"

#============================================================================
# Test 2: Random Select with exclude_active=true
#============================================================================
print_step 2 "Random select with exclude_active filter"

# Reset
cleanup_test_data

# Manually activate 2 goals first
activate_goal "goal-a"
activate_goal "goal-b"

# Random select 3 more (excluding already active)
RESULT=$(random_select_goals "3" "false" "true")

SELECTED_GOALS=$(extract_json_value "$RESULT" '.selected_goals[].goal_id')

# Verify selected goals don't include goal-a or goal-b
assert_not_contains "$SELECTED_GOALS" "goal-a" "Should exclude already active goal-a"
assert_not_contains "$SELECTED_GOALS" "goal-b" "Should exclude already active goal-b"

TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')
assert_equals "$TOTAL_ACTIVE" "5" "Should have 5 active goals (2 existing + 3 new)"

print_success "exclude_active filter working correctly"

#============================================================================
# Test 3: Random Select with exclude_active=false (Can Re-select)
#============================================================================
print_step 3 "Random select without exclude_active filter"

# Reset
cleanup_test_data

# Activate 2 goals
activate_goal "goal-a"
activate_goal "goal-b"

# Random select 3 (may include already active goals)
RESULT=$(random_select_goals "3" "false" "false")

SELECTED_COUNT=$(extract_json_value "$RESULT" '.selected_goals | length')
assert_equals "$SELECTED_COUNT" "3" "Should select 3 goals"

print_success "Random selection without filter works"

#============================================================================
# Test 4: Random Select with replace_existing=true
#============================================================================
print_step 4 "Random select with replace mode"

# Reset
cleanup_test_data

# First: activate 2 goals manually
activate_goal "goal-a"
activate_goal "goal-b"

# Second: random select 3 with replace mode
RESULT=$(random_select_goals "3" "true" "false")

REPLACED_COUNT=$(extract_json_value "$RESULT" '.replaced_goals | length')
TOTAL_ACTIVE=$(extract_json_value "$RESULT" '.total_active_goals')

assert_equals "$REPLACED_COUNT" "2" "Should replace 2 existing goals"
assert_equals "$TOTAL_ACTIVE" "3" "Should have exactly 3 active goals after replace"

# Verify goal-a and goal-b are no longer active
PROGRESS=$(get_user_progress)
GOAL_A_ACTIVE=$(extract_json_value "$PROGRESS" '.challenges[].goals[] | select(.goal_id == "goal-a") | .is_active')
GOAL_B_ACTIVE=$(extract_json_value "$PROGRESS" '.challenges[].goals[] | select(.goal_id == "goal-b") | .is_active')

assert_equals "$GOAL_A_ACTIVE" "false" "goal-a should be deactivated"
assert_equals "$GOAL_B_ACTIVE" "false" "goal-b should be deactivated"

print_success "Replace mode working correctly"

#============================================================================
# Test 5: Partial Results (Fewer Available Than Requested)
#============================================================================
print_step 5 "Partial results when fewer goals available"

# Reset
cleanup_test_data

# Assume challenge has 10 total goals
# Complete 5 goals (they'll be excluded from random selection)
for i in {1..5}; do
    activate_goal "goal-$i"
    complete_goal "goal-$i"
done

# Try to select 10 goals (but only 5 available after filters)
RESULT=$(random_select_goals "10" "false" "true")

SELECTED_COUNT=$(extract_json_value "$RESULT" '.selected_goals | length')

# Should return partial results (all 5 available)
assert_greater_or_equal "$SELECTED_COUNT" "1" "Should return at least 1 goal"
assert_less_or_equal "$SELECTED_COUNT" "5" "Should return at most 5 goals (available count)"

print_success "Partial results returned correctly"

#============================================================================
# Test 6: Error - Zero Goals Available
#============================================================================
print_step 6 "Error handling - zero goals available"

# Reset
cleanup_test_data

# Complete ALL goals in challenge (assume 10 goals)
for i in {1..10}; do
    activate_goal "goal-$i"
    complete_goal "goal-$i"
done

# Try to random select (should fail - no goals available)
RESULT=$(random_select_goals "3" "false" "true" 2>&1 || true)

assert_contains "$RESULT" "400" "Should return 400 when no goals available"
assert_contains "$RESULT" "insufficient_goals" "Error message should mention insufficient goals"

print_success "Zero available goals handled correctly"

#============================================================================
# Test 7: Error - Invalid Count
#============================================================================
print_step 7 "Error handling - invalid count"

# Test count = 0
RESULT=$(random_select_goals "0" "false" "false" 2>&1 || true)
assert_contains "$RESULT" "400" "Should return 400 for count=0"

# Test count < 0
RESULT=$(random_select_goals "-1" "false" "false" 2>&1 || true)
assert_contains "$RESULT" "400" "Should return 400 for count<0"

print_success "Invalid count rejected correctly"

#============================================================================
# Test 8: Progress Preservation on Deactivation
#============================================================================
print_step 8 "Verify progress preserved when goals deactivated"

# Reset
cleanup_test_data

# Activate goal and make partial progress
activate_goal "daily-10-kills"
update_stat "enemy_kills" "7"  # 7/10 progress

# Verify progress
PROGRESS_BEFORE=$(get_goal_progress "daily-10-kills")
assert_equals "$PROGRESS_BEFORE" "7" "Should have 7 progress"

# Random select with replace (deactivates daily-10-kills)
random_select_goals "3" "true" "false"

# Verify daily-10-kills is deactivated but progress preserved
PROGRESS_AFTER=$(get_goal_progress "daily-10-kills")
IS_ACTIVE=$(get_goal_active_status "daily-10-kills")

assert_equals "$PROGRESS_AFTER" "7" "Progress should be preserved (still 7)"
assert_equals "$IS_ACTIVE" "false" "Goal should be deactivated"

print_success "Progress preservation verified"

#============================================================================
# Test 9: M3 Compatibility - Individual Activation Still Works
#============================================================================
print_step 9 "M3 compatibility - individual activation"

# Reset
cleanup_test_data

# Use M3 individual activation
activate_goal "daily-login"

# Use M4 random selection
random_select_goals "2" "false" "true"

# Verify both work together
PROGRESS=$(get_user_progress)
TOTAL_ACTIVE=$(extract_json_value "$PROGRESS" '[.challenges[].goals[] | select(.is_active == true)] | length')

assert_equals "$TOTAL_ACTIVE" "3" "Should have 3 active goals (1 M3 + 2 M4)"

print_success "M3 and M4 APIs work together"

print_test_summary "M4 Random Selection Tests"
```

**Required Helper Functions in `helpers.sh`:**

```bash
# Random select goals
# Usage: random_select_goals "count" "replace_existing_bool" "exclude_active_bool"
random_select_goals() {
    local count="$1"
    local replace_existing="${2:-false}"
    local exclude_active="${3:-false}"
    local challenge_id="${CHALLENGE_ID:-daily-challenges}"
    
    local payload=$(cat <<EOF
{
  "count": $count,
  "replace_existing": $replace_existing,
  "exclude_active": $exclude_active
}
EOF
)
    
    curl -s -X POST \
        "$DEMO_APP_URL/v1/challenges/$challenge_id/goals/random-select" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

# Get specific goal progress value
get_goal_progress() {
    local goal_id="$1"
    local progress=$(get_user_progress)
    echo "$progress" | jq -r ".challenges[].goals[] | select(.goal_id == \"$goal_id\") | .progress"
}

# Get specific goal active status
get_goal_active_status() {
    local goal_id="$1"
    local progress=$(get_user_progress)
    echo "$progress" | jq -r ".challenges[].goals[] | select(.goal_id == \"$goal_id\") | .is_active"
}

# Complete a goal (set progress to target)
complete_goal() {
    local goal_id="$1"
    # Implementation depends on goal requirements
    # For stat-based goals, update stat to target value
    # This is a simplified version - actual implementation may vary
    echo "Completing goal $goal_id (helper function - implement based on goal type)"
}

# Assert greater or equal
assert_greater_or_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    
    if [ "$actual" -ge "$expected" ]; then
        echo "✓ $message (actual: $actual >= expected: $expected)"
    else
        echo "✗ FAILED: $message (actual: $actual < expected: $expected)"
        exit 1
    fi
}

# Assert less or equal
assert_less_or_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    
    if [ "$actual" -le "$expected" ]; then
        echo "✓ $message (actual: $actual <= expected: $expected)"
    else
        echo "✗ FAILED: $message (actual: $actual > expected: $expected)"
        exit 1
    fi
}

# Assert not contains
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    
    if ! echo "$haystack" | grep -q "$needle"; then
        echo "✓ $message"
    else
        echo "✗ FAILED: $message (found '$needle' in output)"
        exit 1
    fi
}
```

---

#### 3. Update `run-all-tests.sh`

Add M4 tests to the test suite:

```bash
# Add to run-all-tests.sh after M3 tests:

echo "========================================="
echo "Running M4 Tests..."
echo "========================================="

# M4 Batch Selection
./test-m4-batch-selection.sh || { echo "M4 batch selection tests failed"; exit 1; }

# M4 Random Selection
./test-m4-random-selection.sh || { echo "M4 random selection tests failed"; exit 1; }

echo ""
echo "✅ All M4 tests passed!"
```

---

### E2E Test Coverage Summary

**Batch Selection (`test-m4-batch-selection.sh`):**
- ✅ Happy path - select multiple goals
- ✅ Replace mode - deactivate existing before selection
- ✅ Add mode - keep existing, add more
- ✅ Error handling - invalid goal IDs
- ✅ Error handling - empty list
- ✅ Atomicity - all or nothing on failure

**Random Selection (`test-m4-random-selection.sh`):**
- ✅ Happy path - random select N goals
- ✅ `exclude_active=true` - filter out active goals
- ✅ `exclude_active=false` - can re-select active goals
- ✅ `replace_existing=true` - deactivate all first
- ✅ Partial results - fewer available than requested
- ✅ Error handling - zero goals available
- ✅ Error handling - invalid count (≤ 0)
- ✅ Progress preservation - deactivated goals keep progress
- ✅ M3 compatibility - individual + batch/random work together

**Total: 15 comprehensive E2E test scenarios**

---

## Success Criteria

### Functional Requirements

- ✅ Players can randomly activate N goals from a challenge via API
- ✅ Random selection excludes completed/claimed goals (mandatory)
- ✅ Random selection excludes goals with unmet prerequisites (mandatory)
- ✅ Optional filter: `exclude_active` to skip already-active goals
- ✅ Replace mode: `replace_existing` to deactivate all before selection
- ✅ Validation: Prevent selecting more goals than available
- ✅ Validation: Reject invalid counts (≤ 0, > total)
- ✅ M3 manual activation API still works (unchanged)
- ✅ Transaction ensures atomicity (all or nothing)

### Technical Requirements

- ✅ All tests pass with ≥80% coverage
- ✅ E2E tests pass (15 scenarios across batch and random selection)
- ✅ Linter reports 0 issues
- ✅ Random selection p95 latency < 50ms
- ✅ No database schema changes needed
- ✅ No configuration schema changes needed
- ✅ Uses crypto/rand for fair randomness

### Documentation Requirements

- ✅ TECH_SPEC_M4.md complete with all design decisions
- ✅ API documentation updated with new endpoint
- ✅ All open questions resolved

---

## Document Status

**Status:** ✅ **IMPLEMENTATION COMPLETE**
**Date:** 2025-11-25
**Version:** 4.0 (Implementation Complete)

**Completed:**
1. ✅ All design questions resolved (Q1-Q4)
2. ✅ Simplified design finalized (no pools, batch + random selection)
3. ✅ Repository layer (`BatchUpsertGoalActive`) implemented
4. ✅ Service logic (random selection algorithm) implemented
5. ✅ API endpoints implemented and tested
6. ✅ Demo app CLI commands added (batch-select, random-select)
7. ✅ E2E tests passing (15 scenarios)
8. ✅ Load tests validated performance targets
9. ✅ Linter reports 0 issues

**Questions Summary:**
- ✅ **Q1:** Random selection algorithm - **RESOLVED**
  - Algorithm: Smart Random with Auto-Filters
  - Insufficient goals: Return partial results (select all available)
  - Randomness: Use crypto/rand from Go stdlib
- ✅ **Q2:** Filter options - **RESOLVED**
  - API parameter: `exclude_active` only (Minimal approach)
  - No tag/category filtering needed
  - No "prefer incomplete" prioritization needed
- ✅ **Q3:** Replace behavior - **RESOLVED**
  - API parameter: `replace_existing` (User-controlled)
  - Progress preservation: Deactivated goals KEEP progress
  - Completed/unclaimed goals: Can be deactivated, claim still available
- ✅ **Q4:** Validation rules - **RESOLVED**
  - Count validation: Enforce count > 0
  - Available goals: Return partial results (from Q1)
  - Challenge exists: Validate before processing
  - Max active goals: No limit in M4 (deferred to M5) (Count, sufficient goals, challenge exists - DEFINED)

---

**End of Document**