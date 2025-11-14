# Technical Specification: Database Design

**Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Overview](#overview)
2. [Database Schema](#database-schema)
3. [Indexes](#indexes)
4. [Queries](#queries)
5. [Migrations](#migrations)
6. [Connection Pooling](#connection-pooling)

---

## Overview

### Database System
- **Technology**: PostgreSQL 15+
- **Justification**: Required by AccelByte Extend templates, provides ACID compliance for reward claims

### Design Principles
- **Lazy Initialization**: Create user progress rows on-demand (no pre-population)
- **Typed Columns**: Use proper types, avoid JSONB for structured data
- **Single Namespace**: Namespace column for debugging only (each deployment operates in one namespace)
- **Status-Based Locking**: Prevent claimed rewards from being overwritten

---

## Database Schema

### Table: `user_goal_progress`

Stores user progress for each goal across all challenges.

```sql
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    namespace VARCHAR(100) NOT NULL,
    progress INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'not_started',
    completed_at TIMESTAMP NULL,
    claimed_at TIMESTAMP NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    assigned_at TIMESTAMP NULL,
    expires_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, goal_id),

    CONSTRAINT check_status CHECK (status IN ('not_started', 'in_progress', 'completed', 'claimed')),
    CONSTRAINT check_progress_non_negative CHECK (progress >= 0),
    CONSTRAINT check_claimed_implies_completed CHECK (claimed_at IS NULL OR completed_at IS NOT NULL)
);
```

### Column Descriptions

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| `user_id` | VARCHAR(100) | NOT NULL | AGS user identifier (from JWT) |
| `goal_id` | VARCHAR(100) | NOT NULL | Goal identifier from config file |
| `challenge_id` | VARCHAR(100) | NOT NULL | Parent challenge identifier |
| `namespace` | VARCHAR(100) | NOT NULL | AGS namespace (for debugging/portability) |
| `progress` | INT | NOT NULL | Current progress value (e.g., 7 kills out of 10) |
| `status` | VARCHAR(20) | NOT NULL | `not_started`, `in_progress`, `completed`, `claimed` |
| `completed_at` | TIMESTAMP | NULL | Timestamp when goal was completed |
| `claimed_at` | TIMESTAMP | NULL | Timestamp when reward was claimed |
| `is_active` | BOOLEAN | NOT NULL | M3: Whether goal is assigned to user (controls event processing) |
| `assigned_at` | TIMESTAMP | NULL | M3: When goal was assigned to user |
| `expires_at` | TIMESTAMP | NULL | M5: When assignment expires (NULL = permanent, schema added in M3) |
| `created_at` | TIMESTAMP | NOT NULL | Row creation time |
| `updated_at` | TIMESTAMP | NOT NULL | Last update time |

### Primary Key

```sql
PRIMARY KEY (user_id, goal_id)
```

**Rationale:**
- Ensures one progress record per user per goal
- Composite key allows efficient lookups by user or user+goal pair
- Goal IDs are globally unique across all challenges

### Constraints

#### Check Constraints

```sql
-- Status can only be one of 4 values
CONSTRAINT check_status CHECK (status IN ('not_started', 'in_progress', 'completed', 'claimed'))

-- Progress cannot be negative
CONSTRAINT check_progress_non_negative CHECK (progress >= 0)

-- Cannot have claimed_at without completed_at
CONSTRAINT check_claimed_implies_completed CHECK (claimed_at IS NULL OR completed_at IS NOT NULL)
```

### Status State Machine

```
not_started → in_progress → completed → claimed
     │                          ▲
     └──────────────────────────┘
       (if progress reaches target on first event)
```

**State Transitions:**
- `not_started` → `in_progress`: First event with progress < target
- `not_started` → `completed`: First event with progress >= target
- `in_progress` → `completed`: Subsequent event with progress >= target
- `completed` → `claimed`: User claims reward via API

**Immutable States:**
- Once `claimed`, status cannot change (enforced by UPSERT WHERE clause)

---

## Indexes

### Performance Indexes

```sql
-- User + Challenge lookups (GET /v1/challenges)
CREATE INDEX idx_user_goal_progress_user_challenge
ON user_goal_progress(user_id, challenge_id);

-- Active goal filtering (M3: GET /v1/challenges?active_only=true)
CREATE INDEX idx_user_goal_progress_user_active
ON user_goal_progress(user_id, is_active)
WHERE is_active = true;

-- M3 Phase 9: Fast path optimization for InitializePlayer
-- Used by GetUserGoalCount() to quickly check if user is initialized
CREATE INDEX idx_user_goal_count ON user_goal_progress(user_id);

-- M3 Phase 9: Composite index for fast goal lookups
-- Used by GetGoalsByIDs for faster querying with IN clause
CREATE INDEX idx_user_goal_lookup ON user_goal_progress(user_id, goal_id);

-- M3 Phase 9: Partial index for active-only queries
-- Used by GetActiveGoals() for fast path returning users
CREATE INDEX idx_user_goal_active_only
ON user_goal_progress(user_id)
WHERE is_active = true;
```

### Index Usage Analysis

#### Base Indexes (M1)

**Query Pattern:**
```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND challenge_id = $2;
```

**Index Used:** `idx_user_goal_progress_user_challenge`
**Usage:** GET /v1/challenges endpoint - retrieving all goals for a specific challenge
**Cardinality:** High (unique per user-challenge pair)
**Performance:** < 10ms for 1000 rows

**Note:** The primary key `(user_id, goal_id)` handles:
- Single goal lookups: `WHERE user_id = $1 AND goal_id = $2`
- All user goals via prefix scan: `WHERE user_id = $1`
- No additional indexes needed for these queries

#### M3 Active Goal Index

**Query Pattern:**
```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND is_active = true;
```

**Index Used:** `idx_user_goal_progress_user_active` (partial index)
**Usage:** GET /v1/challenges?active_only=true endpoint
**Performance:** < 5ms for filtering active goals

#### M3 Phase 9 Optimization Indexes

**1. User Goal Count Index**
```sql
-- Query: SELECT COUNT(*) FROM user_goal_progress WHERE user_id = $1;
```
**Index Used:** `idx_user_goal_count`
**Usage:** Fast-path check in InitializePlayer to determine if user is already initialized
**Performance:** < 1ms for existence check
**Impact:** Reduced initialization latency from 5.32s to 16.84ms (316x improvement)

**2. User Goal Lookup Index**
```sql
-- Query: SELECT * FROM user_goal_progress WHERE user_id = $1 AND goal_id IN ($2, $3, ...);
```
**Index Used:** `idx_user_goal_lookup`
**Usage:** Batch goal lookups with IN clause in GetGoalsByIDs
**Performance:** < 5ms for batch lookups
**Impact:** Optimizes bulk operations during initialization

**3. User Active-Only Index**
```sql
-- Query: SELECT * FROM user_goal_progress WHERE user_id = $1 AND is_active = true;
```
**Index Used:** `idx_user_goal_active_only` (partial index, overlaps with `idx_user_goal_progress_user_active`)
**Usage:** Fast-path GetActiveGoals for returning users
**Performance:** < 2ms for active goal filtering
**Impact:** Improves cache hit path for initialization endpoint

**Note on Index Redundancy:** `idx_user_goal_active_only` and `idx_user_goal_progress_user_active` have overlapping functionality. The former is a simple user_id index with WHERE clause, while the latter is a composite (user_id, is_active) index. Both are partial indexes. In practice, PostgreSQL will choose the most efficient based on query structure

---

## Queries

### GoalRepository Interface Overview

The repository provides four main methods for updating progress, each optimized for specific goal types and usage patterns:

#### UpsertProgress - For Absolute-Type Goals

```go
// UpsertProgress updates or inserts progress for absolute-type goals.
// Use this for goals where the stat value represents the absolute progress
// (e.g., "kill 100 enemies" where stat value is total kills).
// The progress value from the event replaces the current progress in the database.
//
// Do NOT use for increment-type or daily-type goals - use IncrementProgress instead.
//
// Example: User has 50 kills → event reports 52 kills → progress becomes 52
UpsertProgress(ctx context.Context, progress *UserGoalProgress) error
```

#### BatchUpsertProgress - Batch Version for Absolute Goals

```go
// BatchUpsertProgress updates or inserts progress for multiple absolute-type goals.
// This is the batch version of UpsertProgress, used during periodic flush.
// Executes all upserts in a single database query for performance (1,000,000x reduction).
//
// Use this in BufferedRepository flush for absolute-type goals.
//
// Performance: 1,000 updates in ~20ms (vs 1,000ms for individual UpsertProgress calls)
BatchUpsertProgress(ctx context.Context, updates []*UserGoalProgress) error
```

#### IncrementProgress - For Increment-Type Goals

```go
// IncrementProgress atomically increments progress by delta.
// Use this for increment-type goals (both regular and daily increments).
// The delta is ADDED to the current progress in the database (atomic DB operation).
//
// For regular increments (daily=false): Accumulates all event deltas
//   Example: progress=5 → IncrementProgress(delta=3) → progress=8
//
// For daily increments (daily=true): Only increments once per day
//   Example: Day 1 progress=3 → IncrementProgress(delta=1) → progress=4
//            Same day → IncrementProgress(delta=1) → progress=4 (no change)
//            Next day → IncrementProgress(delta=1) → progress=5
//
// Do NOT use for absolute-type goals - use UpsertProgress instead.
//
// Parameters:
// - delta: Amount to increment (typically 1, or accumulated count from buffer)
// - targetValue: Goal threshold (from config) for completion status check
// - isDailyIncrement: If true, uses date-based logic to increment once per day
IncrementProgress(ctx context.Context, userID, goalID, challengeID, namespace string,
    delta, targetValue int, isDailyIncrement bool) error
```

#### BatchIncrementProgress - Batch Version for Increment Goals

```go
// BatchIncrementProgress atomically increments progress for multiple goals.
// This is the batch version of IncrementProgress, used during periodic flush.
// Executes all increments in a single database query for performance.
//
// Use this in BufferedRepository flush for increment-type goals.
//
// Performance: 1,000 increments in ~20ms (vs 1,000ms for individual calls)
BatchIncrementProgress(ctx context.Context, increments []ProgressIncrement) error

// ProgressIncrement represents a single increment operation
type ProgressIncrement struct {
    UserID            string
    GoalID            string
    ChallengeID       string
    Namespace         string
    Delta             int    // Amount to increment by
    TargetValue       int    // For completion check
    IsDailyIncrement  bool   // If true, only increment once per day
}
```

**Method Selection Guide:**

| Goal Type | Single Update | Batch Update (Flush) |
|-----------|--------------|---------------------|
| `absolute` | `UpsertProgress` | `BatchUpsertProgress` |
| `increment` (daily=false) | `IncrementProgress` | `BatchIncrementProgress` |
| `increment` (daily=true) | `IncrementProgress` | `BatchIncrementProgress` |

---

### 1. UPSERT Progress

```sql
INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    updated_at
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, NOW()
)
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    progress = EXCLUDED.progress,
    status = EXCLUDED.status,
    completed_at = EXCLUDED.completed_at,
    updated_at = NOW()
WHERE user_goal_progress.status != 'claimed'
  AND (user_goal_progress.expires_at IS NULL OR user_goal_progress.expires_at > NOW());
```

**Parameters:**
- `$1`: user_id (from event)
- `$2`: goal_id (from cache)
- `$3`: challenge_id (from cache)
- `$4`: namespace (from config)
- `$5`: progress (from event payload)
- `$6`: status (`in_progress` or `completed`)
- `$7`: completed_at (NULL or NOW())

**Critical Features:**
- `WHERE user_goal_progress.status != 'claimed'` prevents overwriting claimed rewards
- `WHERE is_active = true` only updates assigned goals (M3)
- `WHERE expires_at IS NULL OR expires_at > NOW()` only updates non-expired assignments (M5 prep)
- If goal already claimed, unassigned, or expired, UPSERT becomes a no-op
- **Single query** maintains M1/M2 performance (no separate assignment table lookup)

**Performance:** < 5ms (uses primary key for conflict detection)

### 2. Batch UPSERT Progress

```sql
INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    updated_at
) VALUES
    ($1, $2, $3, $4, $5, $6, $7, NOW()),
    ($8, $9, $10, $11, $12, $13, $14, NOW()),
    ($15, $16, $17, $18, $19, $20, $21, NOW())
    -- ... continue for all rows
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    progress = EXCLUDED.progress,
    status = EXCLUDED.status,
    completed_at = EXCLUDED.completed_at,
    updated_at = NOW()
WHERE user_goal_progress.status != 'claimed'
  AND user_goal_progress.is_active = true
  AND (user_goal_progress.expires_at IS NULL OR user_goal_progress.expires_at > NOW());
```

**Usage:** BufferedRepository flush operation (event processing)

**Parameters:** 7 parameters per row (user_id, goal_id, challenge_id, namespace, progress, status, completed_at)

**Critical Features:**
- Multi-row INSERT with single `ON CONFLICT` clause applies to all rows
- `WHERE status != 'claimed'` prevents overwriting claimed rewards for all rows
- `WHERE is_active = true` only updates assigned goals (M3)
- `WHERE expires_at IS NULL OR expires_at > NOW()` only updates non-expired assignments (M5 prep)
- Single round trip to database regardless of batch size
- PostgreSQL processes all conflicts atomically in one transaction
- **Single query** maintains M1/M2 performance (no separate assignment table lookup)

**Performance Characteristics:**

| Batch Size | Query Time (p95) | Round Trips | Throughput |
|------------|------------------|-------------|------------|
| 100 rows | ~10ms | 1 | 10,000 updates/sec |
| 1,000 rows | ~20ms | 1 | 50,000 updates/sec |
| 10,000 rows | ~200ms | 1 | 50,000 updates/sec |

**Implementation Notes:**

1. **Dynamic Query Building**: Build VALUES clause dynamically based on batch size
   ```go
   func (r *PostgresGoalRepository) BatchUpsertProgress(updates []*UserGoalProgress) error {
       if len(updates) == 0 {
           return nil
       }

       // Build dynamic query with correct number of placeholders
       valueStrings := make([]string, 0, len(updates))
       valueArgs := make([]interface{}, 0, len(updates)*7)

       for i, update := range updates {
           valueStrings = append(valueStrings, fmt.Sprintf(
               "($%d, $%d, $%d, $%d, $%d, $%d, $%d, NOW())",
               i*7+1, i*7+2, i*7+3, i*7+4, i*7+5, i*7+6, i*7+7,
           ))
           valueArgs = append(valueArgs,
               update.UserID,
               update.GoalID,
               update.ChallengeID,
               update.Namespace,
               update.Progress,
               update.Status,
               update.CompletedAt,
           )
       }

       query := fmt.Sprintf(`
           INSERT INTO user_goal_progress (
               user_id, goal_id, challenge_id, namespace,
               progress, status, completed_at, updated_at
           ) VALUES %s
           ON CONFLICT (user_id, goal_id) DO UPDATE SET
               progress = EXCLUDED.progress,
               status = EXCLUDED.status,
               completed_at = EXCLUDED.completed_at,
               updated_at = NOW()
           WHERE user_goal_progress.status != 'claimed'
       `, strings.Join(valueStrings, ","))

       _, err := r.db.ExecContext(context.Background(), query, valueArgs...)
       return err
   }
   ```

2. **Batch Size Limits**:
   - PostgreSQL parameter limit: 65,535 parameters
   - With 7 parameters per row: max ~9,000 rows per batch
   - Recommended batch size: 1,000 rows (stays well under limit, ~20ms processing)
   - For larger batches, split into multiple calls

3. **Error Handling**:
   - If batch fails, entire batch fails (atomic operation)
   - No partial success - all or nothing
   - Retry logic should re-attempt entire batch

4. **Comparison vs Single UPSERT**:
   ```
   Single UPSERT (1000 updates):
   - Queries: 1,000 queries
   - Time: ~1,000ms (1ms per query × 1,000)
   - Network overhead: 1,000 round trips

   Batch UPSERT (1000 updates):
   - Queries: 1 query
   - Time: ~20ms
   - Network overhead: 1 round trip

   Improvement: 50x faster, 1,000x fewer round trips
   ```

**Index Usage:** Primary key (user_id, goal_id) for conflict detection - extremely efficient for batch operations

**Transaction Safety:** Entire batch executes in single transaction - either all succeed or all fail

### 3. Increment Progress (Atomic Counter)

**New in Phase 5.2**: For increment-type goals that count occurrences (e.g., login count, daily login streak).

#### 3a. Regular Increment (daily = false)

Counts every occurrence without date restrictions.

```sql
INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    updated_at
) VALUES (
    $1, $2, $3, $4, $5,
    CASE WHEN $5 >= $6 THEN 'completed' ELSE 'in_progress' END,
    CASE WHEN $5 >= $6 THEN NOW() ELSE NULL END,
    NOW()
)
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    progress = user_goal_progress.progress + $5,
    status = CASE
        WHEN user_goal_progress.progress + $5 >= $6 THEN 'completed'
        ELSE 'in_progress'
    END,
    completed_at = CASE
        WHEN user_goal_progress.progress + $5 >= $6 AND user_goal_progress.completed_at IS NULL
            THEN NOW()
        ELSE user_goal_progress.completed_at
    END,
    updated_at = NOW()
WHERE user_goal_progress.status != 'claimed'
  AND user_goal_progress.is_active = true
  AND (user_goal_progress.expires_at IS NULL OR user_goal_progress.expires_at > NOW());
```

**Parameters:**
- `$1`: user_id (from event)
- `$2`: goal_id (from cache)
- `$3`: challenge_id (from cache)
- `$4`: namespace (from config)
- `$5`: delta (increment amount, typically 1 or accumulated count)
- `$6`: target_value (from goal config, for status determination)

**Assignment Check (M3):**
- `WHERE is_active = true` only updates assigned goals
- `WHERE expires_at IS NULL OR expires_at > NOW()` only updates non-expired assignments (M5 prep)
- **Single query** maintains M1/M2 performance (no separate assignment table lookup)

#### 3b. Daily Increment (daily = true)

Only increments once per day. Uses `updated_at` to track last increment date.

```sql
INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    updated_at
) VALUES (
    $1, $2, $3, $4, 1,  -- Initial progress = 1
    CASE WHEN 1 >= $6 THEN 'completed' ELSE 'in_progress' END,
    CASE WHEN 1 >= $6 THEN NOW() ELSE NULL END,
    NOW()
)
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    progress = CASE
        -- Same day: don't increment
        WHEN DATE(user_goal_progress.updated_at) = CURRENT_DATE
            THEN user_goal_progress.progress
        -- New day: increment by delta
        ELSE user_goal_progress.progress + $5
    END,
    status = CASE
        -- Calculate new progress first, then check threshold
        WHEN DATE(user_goal_progress.updated_at) = CURRENT_DATE THEN
            -- Same day, progress unchanged
            CASE WHEN user_goal_progress.progress >= $6 THEN 'completed' ELSE 'in_progress' END
        ELSE
            -- New day, check incremented progress
            CASE WHEN user_goal_progress.progress + $5 >= $6 THEN 'completed' ELSE 'in_progress' END
    END,
    completed_at = CASE
        WHEN DATE(user_goal_progress.updated_at) = CURRENT_DATE THEN
            user_goal_progress.completed_at  -- Same day, keep existing
        WHEN user_goal_progress.progress + $5 >= $6 AND user_goal_progress.completed_at IS NULL THEN
            NOW()  -- New day and just completed
        ELSE
            user_goal_progress.completed_at  -- Keep existing
    END,
    updated_at = NOW()  -- Always update timestamp
WHERE user_goal_progress.status != 'claimed'
  AND user_goal_progress.is_active = true
  AND (user_goal_progress.expires_at IS NULL OR user_goal_progress.expires_at > NOW());
```

**Parameters:**
- `$1`: user_id (from event)
- `$2`: goal_id (from cache)
- `$3`: challenge_id (from cache)
- `$4`: namespace (from config)
- `$5`: delta (typically 1 for daily increment)
- `$6`: target_value (from goal config, for status determination)

**Key Differences:**
- Regular: `progress = progress + delta` (always increments)
- Daily: `progress = CASE WHEN date_changed THEN progress + delta ELSE progress END` (conditional increment)
- Assignment: `WHERE is_active = true` only updates assigned goals (M3)
- Expiry: `WHERE expires_at IS NULL OR expires_at > NOW()` only updates non-expired assignments (M5 prep)

**Date Consistency with Go Code (Decision Q3, Phase 5.2.2c):**

The SQL `DATE(updated_at) = CURRENT_DATE` check must match Go's date truncation logic to prevent duplicates:

- **SQL**: `DATE(user_goal_progress.updated_at) = CURRENT_DATE` truncates to midnight UTC
- **Go**: `dateutil.GetCurrentDateUTC()` from `extend-challenge-common/pkg/common/dateutil.go` also truncates to midnight UTC
- **Consistency guaranteed**: Both use UTC timezone and 24-hour truncation

**Integration Test Required (Decision Q3b, Phase 5.2.2c):**

An integration test must verify that Go's `dateutil.TruncateToDateUTC()` produces the same date value as PostgreSQL's `DATE()` function:

```go
// Test: Date consistency between Go and PostgreSQL
func TestDateConsistencyGoAndSQL(t *testing.T) {
    now := time.Now().UTC()

    // Go date calculation
    goDate := dateutil.TruncateToDateUTC(now)

    // SQL date calculation
    var sqlDate time.Time
    err := db.QueryRow("SELECT DATE($1)::TIMESTAMP", now).Scan(&sqlDate)
    require.NoError(t, err)

    // Must match
    assert.Equal(t, goDate, sqlDate,
        "Go dateutil and SQL DATE() must produce identical results")
}
```

This test ensures that client-side date checking in BufferedRepository matches server-side SQL date checking in daily increment queries.

**See Also:**
- `TECH_SPEC_EVENT_PROCESSING.md` - Shared date utility implementation and client-side buffering logic
- `extend-challenge-common/pkg/common/dateutil.go` - Date utility function implementation

**Key Features:**
- **Atomic Increment**: `progress = user_goal_progress.progress + $5` executes atomically at DB level
- **No Read-Modify-Write**: No need to query current value first
- **Status Auto-Update**: CASE statement updates status when threshold reached
- **Completion Timestamp**: Sets `completed_at` once when threshold reached (idempotent)
- **Claimed Protection**: WHERE clause prevents updating claimed goals

**GoalRepository Interface Signature:**
```go
// IncrementProgress atomically increments progress by delta.
// The targetValue parameter is used in the SQL query's CASE statement to determine
// when to mark the goal as completed. The caller (EventProcessor) extracts this
// value from the in-memory goal config cache before calling this method.
// The repository does not have access to goal config to keep separation of concerns.
// If isDailyIncrement is true, only increments if updated_at date < current date.
//
// Delta Behavior:
// - Positive delta: Increments progress (typical use case)
// - Negative delta: Decrements progress (use case: penalties, event corrections)
// - Zero delta: No-op (but still updates updated_at timestamp)
//
// Overflow Behavior:
// - Progress can exceed targetValue (not capped at target)
// - Example: target=5, progress=4, delta=100 → progress becomes 104, status='completed'
// - This allows for tracking exact occurrence counts even after goal completion
//
// Returns error only on database failure. Does NOT error if:
// - Goal already claimed (WHERE clause makes it a no-op)
// - Delta causes negative progress (DB constraint will catch this)
IncrementProgress(ctx context.Context, userId, goalId, challengeId, namespace string,
    delta, targetValue int, isDailyIncrement bool) error
```

**Usage Example (Regular Increment):**
```go
// User logs in (regular increment, counts every login)
goal := cache.GetGoalByID(goalId)
err := repo.IncrementProgress(ctx, userId, goalId, challengeId, namespace,
    1, goal.Requirement.TargetValue, false)

// First login:  INSERT with progress=1, status='in_progress'
// Second login: UPDATE progress=1+1=2, status='in_progress'
// Third login:  UPDATE progress=2+1=3, status='in_progress'
// ...
// 100th login:  UPDATE progress=99+1=100, status='completed', completed_at=NOW()
```

**Usage Example (Daily Increment):**
```go
// User logs in (daily increment, counts unique days)
goal := cache.GetGoalByID(goalId)
err := repo.IncrementProgress(ctx, userId, goalId, challengeId, namespace,
    1, goal.Requirement.TargetValue, true)

// Day 1, Login #1: INSERT with progress=1, status='in_progress', updated_at=Day1
// Day 1, Login #2: UPDATE progress=1 (same day, no increment), updated_at=Day1
// Day 2, Login #1: UPDATE progress=1+1=2, updated_at=Day2
// Day 3, Login #1: UPDATE progress=2+1=3, updated_at=Day3
// ...
// Day 7, Login #1: UPDATE progress=6+1=7, status='completed', updated_at=Day7
```

**Buffering Integration:**
```go
// Regular increment: BufferedRepository accumulates deltas
// 3 login events in buffer → single query with delta=3
goal := cache.GetGoalByID(goalId)
err := repo.IncrementProgress(ctx, userId, goalId, challengeId, namespace,
    3, goal.Requirement.TargetValue, false)

// Daily increment: BufferedRepository uses client-side date checking
// 3 login events same day in buffer → only first one processed
// See TECH_SPEC_EVENT_PROCESSING.md for buffering strategy details
goal := cache.GetGoalByID(goalId)
err := repo.IncrementProgress(ctx, userId, goalId, challengeId, namespace,
    1, goal.Requirement.TargetValue, true)
```

**Performance:**
- < 5ms (uses primary key for conflict detection)
- Same as regular UPSERT (no performance penalty for CASE logic)

**Comparison to Read-Modify-Write:**
```
❌ Read-Modify-Write (2 queries):
  1. SELECT progress FROM ... WHERE user_id=$1 AND goal_id=$2
  2. UPDATE ... SET progress=$progress+1 WHERE ...
  Total: ~10ms + 2 network round trips + race condition risk

✅ Atomic Increment (1 query):
  1. INSERT ... ON CONFLICT DO UPDATE SET progress=progress+$delta
  Total: ~5ms + 1 network round trip + race-free
```

**Thread Safety:** Atomic at database level - no application-level locking needed

#### 3c. Batch Increment Progress

**New in Phase 5.2**: For efficient buffered flush of increment-type goals.

Similar to BatchUpsertProgress, this method processes multiple increments in a single query for maximum performance during periodic flush operations.

```sql
INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    updated_at
)
SELECT * FROM UNNEST(
    $1::VARCHAR(100)[],  -- user_ids
    $2::VARCHAR(100)[],  -- goal_ids
    $3::VARCHAR(100)[],  -- challenge_ids
    $4::VARCHAR(100)[],  -- namespaces
    $5::INT[],           -- deltas (initial progress for INSERT)
    $6::INT[],           -- target_values
    $7::BOOLEAN[]        -- is_daily_increment flags
) AS t(user_id, goal_id, challenge_id, namespace, delta, target_value, is_daily)
-- Determine initial status and completed_at for INSERT
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN t.delta >= t.target_value THEN 'completed' ELSE 'in_progress' END as status,
        CASE WHEN t.delta >= t.target_value THEN NOW() ELSE NULL END as completed_at
) AS initial
ON CONFLICT (user_id, goal_id) DO UPDATE SET
    progress = CASE
        -- Daily increment: check if same day
        WHEN (SELECT is_daily FROM UNNEST($7::BOOLEAN[], $2::VARCHAR(100)[]) AS u(is_daily, gid)
              WHERE u.gid = user_goal_progress.goal_id LIMIT 1) = true
             AND DATE(user_goal_progress.updated_at) = CURRENT_DATE
            THEN user_goal_progress.progress  -- Same day, no increment
        ELSE
            user_goal_progress.progress + (
                SELECT delta FROM UNNEST($5::INT[], $2::VARCHAR(100)[]) AS u(delta, gid)
                WHERE u.gid = user_goal_progress.goal_id LIMIT 1
            )  -- Different day or regular increment
    END,
    status = CASE
        -- Calculate based on new progress value
        WHEN (SELECT is_daily FROM UNNEST($7::BOOLEAN[], $2::VARCHAR(100)[]) AS u(is_daily, gid)
              WHERE u.gid = user_goal_progress.goal_id LIMIT 1) = true
             AND DATE(user_goal_progress.updated_at) = CURRENT_DATE THEN
            -- Same day: status based on current progress
            CASE WHEN user_goal_progress.progress >= (
                SELECT target_value FROM UNNEST($6::INT[], $2::VARCHAR(100)[]) AS u(target_value, gid)
                WHERE u.gid = user_goal_progress.goal_id LIMIT 1
            ) THEN 'completed' ELSE 'in_progress' END
        ELSE
            -- New day or regular: status based on incremented progress
            CASE WHEN user_goal_progress.progress + (
                SELECT delta FROM UNNEST($5::INT[], $2::VARCHAR(100)[]) AS u(delta, gid)
                WHERE u.gid = user_goal_progress.goal_id LIMIT 1
            ) >= (
                SELECT target_value FROM UNNEST($6::INT[], $2::VARCHAR(100)[]) AS u(target_value, gid)
                WHERE u.gid = user_goal_progress.goal_id LIMIT 1
            ) THEN 'completed' ELSE 'in_progress' END
    END,
    completed_at = CASE
        WHEN (SELECT is_daily FROM UNNEST($7::BOOLEAN[], $2::VARCHAR(100)[]) AS u(is_daily, gid)
              WHERE u.gid = user_goal_progress.goal_id LIMIT 1) = true
             AND DATE(user_goal_progress.updated_at) = CURRENT_DATE THEN
            user_goal_progress.completed_at  -- Same day, keep existing
        WHEN user_goal_progress.progress + (
            SELECT delta FROM UNNEST($5::INT[], $2::VARCHAR(100)[]) AS u(delta, gid)
            WHERE u.gid = user_goal_progress.goal_id LIMIT 1
        ) >= (
            SELECT target_value FROM UNNEST($6::INT[], $2::VARCHAR(100)[]) AS u(target_value, gid)
            WHERE u.gid = user_goal_progress.goal_id LIMIT 1
        ) AND user_goal_progress.completed_at IS NULL THEN
            NOW()  -- Just completed
        ELSE
            user_goal_progress.completed_at  -- Keep existing
    END,
    updated_at = NOW()
WHERE user_goal_progress.status != 'claimed'
  AND user_goal_progress.is_active = true
  AND (user_goal_progress.expires_at IS NULL OR user_goal_progress.expires_at > NOW());
```

**Parameters:**
- `$1`: Array of user_ids
- `$2`: Array of goal_ids
- `$3`: Array of challenge_ids
- `$4`: Array of namespaces
- `$5`: Array of deltas (increment amounts)
- `$6`: Array of target_values (for completion checks)
- `$7`: Array of is_daily_increment flags

**Implementation Notes:**

```go
func (r *PostgresGoalRepository) BatchIncrementProgress(ctx context.Context, increments []ProgressIncrement) error {
    if len(increments) == 0 {
        return nil
    }

    // Build arrays for UNNEST
    userIDs := make([]string, len(increments))
    goalIDs := make([]string, len(increments))
    challengeIDs := make([]string, len(increments))
    namespaces := make([]string, len(increments))
    deltas := make([]int, len(increments))
    targetValues := make([]int, len(increments))
    isDailyFlags := make([]bool, len(increments))

    for i, inc := range increments {
        userIDs[i] = inc.UserID
        goalIDs[i] = inc.GoalID
        challengeIDs[i] = inc.ChallengeID
        namespaces[i] = inc.Namespace
        deltas[i] = inc.Delta
        targetValues[i] = inc.TargetValue
        isDailyFlags[i] = inc.IsDailyIncrement
    }

    query := `[SQL query from above]`

    _, err := r.db.ExecContext(ctx, query,
        pq.Array(userIDs),
        pq.Array(goalIDs),
        pq.Array(challengeIDs),
        pq.Array(namespaces),
        pq.Array(deltas),
        pq.Array(targetValues),
        pq.Array(isDailyFlags),
    )
    return err
}
```

**Performance Characteristics:**

| Batch Size | Query Time (p95) | Comparison to Individual Calls |
|------------|------------------|-------------------------------|
| 100 increments | ~10ms | 100× faster (vs 1,000ms) |
| 1,000 increments | ~20ms | 50× faster (vs 1,000ms) |
| 10,000 increments | ~200ms | 50× faster (vs 10,000ms) |

**Key Features:**
- **Single Query**: All increments execute in one database round trip
- **Atomic Increments**: Each increment uses `progress = progress + delta` logic
- **Daily Logic**: Respects daily increment constraints (date checking)
- **Status Updates**: Automatically updates status when threshold reached
- **Claimed Protection**: WHERE clause prevents updating claimed goals
- **Assignment Check**: Only updates assigned goals (is_active check, M3)
- **Expiry Check**: Only updates non-expired assignments (expires_at check, M5 prep)
- **Transaction Safety**: All increments succeed or fail together
- **Single query** maintains M1/M2 performance (no separate assignment table lookup)

**Usage in BufferedRepository:**

```go
// During flush, collect all buffered increments
var increments []ProgressIncrement

for key, delta := range r.incrementBuffer {
    goal := r.cache.GetGoalByID(key.goalID)
    increments = append(increments, ProgressIncrement{
        UserID:            key.userID,
        GoalID:            key.goalID,
        ChallengeID:       goal.ChallengeID,
        Namespace:         r.namespace,
        Delta:             delta,
        TargetValue:       goal.Requirement.TargetValue,
        IsDailyIncrement:  goal.Daily,  // From config
    })
}

// Single batch call for all increments
if len(increments) > 0 {
    err := r.repo.BatchIncrementProgress(ctx, increments)
    // Handle error...
}
```

**Comparison to N Individual Calls:**

```
❌ Individual IncrementProgress (1,000 goals):
  - Queries: 1,000 queries
  - Time: ~1,000ms (1ms per query × 1,000)
  - Network overhead: 1,000 round trips

✅ BatchIncrementProgress (1,000 goals):
  - Queries: 1 query
  - Time: ~20ms
  - Network overhead: 1 round trip

Improvement: 50× faster, 1,000× fewer round trips
```

**Batch Size Limits:**
- PostgreSQL array size limit: No practical limit for this use case
- Recommended batch size: 1,000 increments (optimal performance)
- For larger batches, split into multiple calls of 1,000 each

### 4. Transaction Strategy for Buffered Flush

**Decision (BRAINSTORM.md Q12):** Use **separate transactions** for absolute and increment buffer flushes.

#### Independent Transaction Approach

BufferedRepository flush uses two independent database transactions:

1. **Transaction 1: Absolute/Daily Goals** → `BatchUpsertProgress()`
2. **Transaction 2: Increment Goals** → `BatchIncrementProgress()`

Each transaction succeeds or fails independently.

**Benefits:**
- **Simpler implementation** - No cross-buffer transaction coordination
- **Independent failure recovery** - Absolute buffer success doesn't depend on increment buffer success
- **Fault isolation** - Database error in one query type doesn't block the other
- **Eventual consistency acceptable** - Both buffers retry on next flush (1 sec interval)

**Trade-off Accepted:**
- One buffer type might succeed while the other fails and retries
- Example: Absolute goals flush successfully, increment goals fail → increment buffer retries in 1 sec
- Acceptable for M1: Event-driven system with 1-sec automatic retry

**Implementation Pattern:**

```go
func (r *BufferedRepository) Flush() error {
    var flushErrors []error

    // TRANSACTION 1: Flush absolute goals (independent)
    if len(r.bufferAbsolute) > 0 {
        err := r.repo.BatchUpsertProgress(ctx, absoluteUpdates)
        if err != nil {
            flushErrors = append(flushErrors, fmt.Errorf("absolute flush: %w", err))
            // Keep in buffer, retry next flush
        } else {
            // Clear absolute buffer only on success
        }
    }

    // TRANSACTION 2: Flush increment goals (independent)
    if len(r.bufferIncrement) > 0 {
        err := r.repo.BatchIncrementProgress(ctx, incrementUpdates)
        if err != nil {
            flushErrors = append(flushErrors, fmt.Errorf("increment flush: %w", err))
            // Keep in buffer, retry next flush
        } else {
            // Clear increment buffer only on success
        }
    }

    // Return combined errors (partial success allowed)
    if len(flushErrors) > 0 {
        return fmt.Errorf("flush partial failure: %v", flushErrors)
    }
    return nil
}
```

**Partial Success Behavior:**
- If absolute flush succeeds but increment flush fails → absolute buffer cleared, increment buffer retries
- If increment flush succeeds but absolute flush fails → increment buffer cleared, absolute buffer retries
- Both buffers can succeed independently

**Consistency Implications:**
- User might see absolute progress updated but increment progress delayed by 1 sec (max)
- Both buffers will eventually flush (automatic retry every 1 sec)
- Acceptable for event-driven progress tracking where strict ordering is not critical

**Alternative Considered (Rejected for M1):**
- Single transaction for both buffers (all-or-nothing)
- Rejected: More complex, either buffer type failure blocks the other
- May revisit in M2+ if strict consistency becomes a requirement

**See Also:**
- BRAINSTORM.md Q12 - Full decision rationale
- TECH_SPEC_EVENT_PROCESSING.md - Flush implementation details

---

### 5. Get User Progress for Challenge

```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND challenge_id = $2;
```

**Usage:** GET /v1/challenges endpoint
**Index Used:** `idx_user_goal_progress_user_challenge`
**Performance:** < 10ms for 1000 goals per challenge

### 6. Get Progress for Specific Goal

```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND goal_id = $2;
```

**Usage:** POST /v1/challenges/{id}/goals/{id}/claim
**Index Used:** Primary key
**Performance:** < 5ms

### 5. Get Progress with Row Lock (Claim Flow)

```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND goal_id = $2
FOR UPDATE;
```

**Usage:** Claim flow transaction (prevents double claims)
**Index Used:** Primary key
**Performance:** < 5ms
**Locks:** Row-level exclusive lock until transaction commits

### 6. Mark as Claimed

```sql
UPDATE user_goal_progress
SET status = 'claimed',
    claimed_at = NOW(),
    updated_at = NOW()
WHERE user_id = $1 AND goal_id = $2
AND status = 'completed'
AND claimed_at IS NULL;
```

**Usage:** Claim flow after reward grant succeeds
**Index Used:** Primary key
**Performance:** < 5ms
**Idempotency:** Returns 0 rows if already claimed (handled by business logic)

### 7. Get All User Progress (All Challenges)

```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1;
```

**Usage:** GET /v1/challenges (all challenges)
**Index Used:** Primary key (prefix scan on user_id)
**Performance:** < 20ms for 10,000 goals

---

## Migrations

### Migration Tool

**Tool:** [golang-migrate](https://github.com/golang-migrate/migrate)

**Installation:**
```bash
# macOS
brew install golang-migrate

# Linux
curl -L https://github.com/golang-migrate/migrate/releases/download/v4.16.2/migrate.linux-amd64.tar.gz | tar xvz
sudo mv migrate /usr/local/bin/
```

### Migration Files

#### File Structure

```
extend-challenge-service/
└── migrations/
    ├── 001_create_user_goal_progress.up.sql
    └── 001_create_user_goal_progress.down.sql
```

#### 001_create_user_goal_progress.up.sql

```sql
-- Create user_goal_progress table
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    namespace VARCHAR(100) NOT NULL,
    progress INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'not_started',
    completed_at TIMESTAMP NULL,
    claimed_at TIMESTAMP NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    assigned_at TIMESTAMP NULL,
    expires_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, goal_id),

    CONSTRAINT check_status CHECK (status IN ('not_started', 'in_progress', 'completed', 'claimed')),
    CONSTRAINT check_progress_non_negative CHECK (progress >= 0),
    CONSTRAINT check_claimed_implies_completed CHECK (claimed_at IS NULL OR completed_at IS NOT NULL)
);

-- Create performance indexes
CREATE INDEX idx_user_goal_progress_user_challenge ON user_goal_progress(user_id, challenge_id);
CREATE INDEX idx_user_goal_progress_user_active ON user_goal_progress(user_id, is_active) WHERE is_active = true;

-- M3 Phase 9: Fast path optimization for InitializePlayer
-- Used by GetUserGoalCount() to quickly check if user is initialized
CREATE INDEX idx_user_goal_count ON user_goal_progress(user_id);

-- M3 Phase 9: Composite index for fast goal lookups
-- Used by GetGoalsByIDs for faster querying with IN clause
CREATE INDEX idx_user_goal_lookup ON user_goal_progress(user_id, goal_id);

-- M3 Phase 9: Partial index for active-only queries
-- Used by GetActiveGoals() for fast path returning users
CREATE INDEX idx_user_goal_active_only
ON user_goal_progress(user_id)
WHERE is_active = true;

-- Add comments for documentation
COMMENT ON TABLE user_goal_progress IS 'Tracks user progress for challenge goals';
COMMENT ON COLUMN user_goal_progress.namespace IS 'For debugging only - each deployment operates in single namespace';
COMMENT ON COLUMN user_goal_progress.is_active IS 'M3: Whether goal is assigned to user (controls event processing)';
COMMENT ON COLUMN user_goal_progress.assigned_at IS 'M3: When goal was assigned to user';
COMMENT ON COLUMN user_goal_progress.expires_at IS 'M5: When assignment expires (NULL for permanent)';
```

#### 001_create_user_goal_progress.down.sql

```sql
-- Drop indexes
DROP INDEX IF EXISTS idx_user_goal_active_only;
DROP INDEX IF EXISTS idx_user_goal_lookup;
DROP INDEX IF EXISTS idx_user_goal_count;
DROP INDEX IF EXISTS idx_user_goal_progress_user_active;
DROP INDEX IF EXISTS idx_user_goal_progress_user_challenge;

-- Drop table
DROP TABLE IF EXISTS user_goal_progress;
```

### Migration Commands

```bash
# Set database URL
export DATABASE_URL="postgres://user:password@localhost:5432/challenge_db?sslmode=disable"

# Apply all migrations
migrate -path migrations -database "${DATABASE_URL}" up

# Rollback 1 migration
migrate -path migrations -database "${DATABASE_URL}" down 1

# Check migration version
migrate -path migrations -database "${DATABASE_URL}" version

# Force version (use with caution)
migrate -path migrations -database "${DATABASE_URL}" force 1
```

### Migration in Code

```go
import (
    "github.com/golang-migrate/migrate/v4"
    _ "github.com/golang-migrate/migrate/v4/database/postgres"
    _ "github.com/golang-migrate/migrate/v4/source/file"
)

func runMigrations(dbURL string) error {
    m, err := migrate.New(
        "file://migrations",
        dbURL,
    )
    if err != nil {
        return err
    }

    if err := m.Up(); err != nil && err != migrate.ErrNoChange {
        return err
    }

    return nil
}
```

---

## Shared Database Initialization (Phase 6 Decision Q10)

### Overview

Both REST API service (`extend-challenge-service`) and Event Handler service (`extend-challenge-event-handler`) need to connect to the same PostgreSQL database. To avoid code duplication and ensure consistent configuration, a shared database initialization package is provided in `extend-challenge-common`.

### Package Location

**Path:** `extend-challenge-common/pkg/db/postgres.go`

### Initialization Function

```go
package db

import (
    "database/sql"
    "fmt"
    "os"
    "strconv"
    "time"

    _ "github.com/lib/pq"
)

// Config holds database configuration
type Config struct {
    Host            string
    Port            int
    Database        string
    User            string
    Password        string
    SSLMode         string
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    ConnMaxIdleTime time.Duration
}

// NewConfigFromEnv creates database config from environment variables
func NewConfigFromEnv() *Config {
    return &Config{
        Host:            getEnv("DB_HOST", "localhost"),
        Port:            getEnvAsInt("DB_PORT", 5432),
        Database:        getEnv("DB_NAME", "challenge_service"),
        User:            getEnv("DB_USER", "postgres"),
        Password:        getEnv("DB_PASSWORD", ""),
        SSLMode:         getEnv("DB_SSLMODE", "disable"),
        MaxOpenConns:    getEnvAsInt("DB_MAX_OPEN_CONNS", 25),
        MaxIdleConns:    getEnvAsInt("DB_MAX_IDLE_CONNS", 5),
        ConnMaxLifetime: time.Duration(getEnvAsInt("DB_CONN_MAX_LIFETIME", 300)) * time.Second,
        ConnMaxIdleTime: time.Duration(getEnvAsInt("DB_CONN_MAX_IDLE_TIME", 300)) * time.Second,
    }
}

// Connect establishes a database connection with the provided configuration
func Connect(cfg *Config) (*sql.DB, error) {
    dsn := fmt.Sprintf(
        "host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
        cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.Database, cfg.SSLMode,
    )

    db, err := sql.Open("postgres", dsn)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }

    // Configure connection pool
    db.SetMaxOpenConns(cfg.MaxOpenConns)
    db.SetMaxIdleConns(cfg.MaxIdleConns)
    db.SetConnMaxLifetime(cfg.ConnMaxLifetime)
    db.SetConnMaxIdleTime(cfg.ConnMaxIdleTime)

    // Verify connection
    if err := db.Ping(); err != nil {
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }

    return db, nil
}

// Health checks database connectivity (for /healthz endpoint)
func Health(db *sql.DB) error {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()

    if err := db.PingContext(ctx); err != nil {
        return fmt.Errorf("database unhealthy: %w", err)
    }

    return nil
}

// Helper functions
func getEnv(key, defaultValue string) string {
    if value := os.Getenv(key); value != "" {
        return value
    }
    return defaultValue
}

func getEnvAsInt(key string, defaultValue int) int {
    if value := os.Getenv(key); value != "" {
        if intValue, err := strconv.Atoi(value); err == nil {
            return intValue
        }
    }
    return defaultValue
}
```

### Usage in Services

**REST API Service (`extend-challenge-service/main.go`):**

```go
import (
    "extend-challenge-common/pkg/db"
    "extend-challenge-common/pkg/repository"
)

func main() {
    // Initialize database connection
    dbConfig := db.NewConfigFromEnv()
    database, err := db.Connect(dbConfig)
    if err != nil {
        log.Fatalf("Failed to connect to database: %v", err)
    }
    defer database.Close()

    // Create repository
    repo := repository.NewPostgresGoalRepository(database)

    // Use in service layer
    challengeService := service.NewChallengeService(repo, cache, rewardClient)
}
```

**Event Handler Service (`extend-challenge-event-handler/main.go`):**

```go
import (
    "extend-challenge-common/pkg/db"
    "extend-challenge-common/pkg/repository"
    "extend-challenge-event-handler/pkg/buffered"
)

func main() {
    // Initialize database connection (same code as REST API)
    dbConfig := db.NewConfigFromEnv()
    database, err := db.Connect(dbConfig)
    if err != nil {
        log.Fatalf("Failed to connect to database: %v", err)
    }
    defer database.Close()

    // Create repository
    repo := repository.NewPostgresGoalRepository(database)

    // Wrap with buffered repository
    bufferedRepo := buffered.NewBufferedRepository(repo, flushInterval, bufferSize)

    // Use in event processor
    eventProcessor := processor.NewEventProcessor(bufferedRepo, cache, namespace)
}
```

### Health Check Implementation

**Health check endpoint in REST API service:**

```go
func (s *ChallengeServiceServer) HealthCheck(
    ctx context.Context,
    req *pb.HealthCheckRequest,
) (*pb.HealthCheckResponse, error) {
    // Check database connectivity
    if err := db.Health(s.database); err != nil {
        return &pb.HealthCheckResponse{
            Status: "unhealthy",
        }, status.Error(codes.Unavailable, "database unhealthy")
    }

    return &pb.HealthCheckResponse{
        Status: "healthy",
    }, nil
}
```

### Environment Variables

Both services use the same environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `localhost` | PostgreSQL host |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_NAME` | `challenge_service` | Database name |
| `DB_USER` | `postgres` | Database user |
| `DB_PASSWORD` | `` | Database password |
| `DB_SSLMODE` | `disable` | SSL mode (disable, require, verify-ca, verify-full) |
| `DB_MAX_OPEN_CONNS` | `25` | Maximum open connections (Decision Q10b) |
| `DB_MAX_IDLE_CONNS` | `5` | Maximum idle connections (Decision Q10b) |
| `DB_CONN_MAX_LIFETIME` | `300` | Connection max lifetime (seconds) |
| `DB_CONN_MAX_IDLE_TIME` | `300` | Connection max idle time (seconds) |

### Benefits

- ✅ **DRY**: No code duplication between services
- ✅ **Consistency**: Both services use identical connection settings
- ✅ **Testability**: Easy to mock `Connect()` function in tests
- ✅ **Health Checks**: Shared health check logic for both services
- ✅ **Configuration**: Centralized environment variable handling

---

## Connection Pooling

### Configuration (Applies to both services via shared package)

```go
import (
    "database/sql"
    "time"
)

func configureDB(db *sql.DB) {
    // Maximum open connections (includes idle + in-use)
    db.SetMaxOpenConns(50)

    // Maximum idle connections in pool
    db.SetMaxIdleConns(10)

    // Maximum lifetime of connection
    db.SetConnMaxLifetime(30 * time.Minute)

    // Maximum idle time for connection
    db.SetConnMaxIdleTime(5 * time.Minute)
}
```

### Sizing Recommendations

| Environment | Max Open | Max Idle | Rationale |
|-------------|----------|----------|-----------|
| Local Dev | 10 | 2 | Single developer, low load |
| Test | 20 | 5 | Integration tests, moderate load |
| Production | 50 | 10 | 3 replicas × 50 = 150 total connections to DB |

**PostgreSQL Limit:** Configure `max_connections = 200` in `postgresql.conf` to accommodate:
- 150 from app replicas
- 50 for admin/monitoring connections

### Health Check Query

```go
func (r *PostgresGoalRepository) Ping(ctx context.Context) error {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    return r.db.PingContext(ctx)
}
```

**Usage:** Called by service layer health checks

---

## Data Lifecycle

### Row Creation
- **Trigger**: First event for user-goal pair OR first API request
- **Strategy**: Lazy initialization (no pre-population of all possible user-goal combinations)
- **Rationale**: 1M users × 1000 goals = 1B rows (unnecessary if user never engages with goal)

### Row Updates
- **Frequency**: On every stat update event (mitigated by buffering)
- **Deduplication**: Buffered repository reduces updates to 1/sec per user-goal pair
- **Concurrency**: Per-user mutex prevents race conditions

### Row Deletion
- **M1 Scope**: No automatic deletion
- **Orphaned Rows**: If goal removed from config, row remains in DB (ignored by API)
- **Manual Cleanup**: Game developers can run DELETE queries if needed

### Future: GDPR Data Deletion
```sql
-- Delete all data for user
DELETE FROM user_goal_progress WHERE user_id = $1;
```

---

## Performance Benchmarks

### Expected Row Counts

| Deployment Size | Users | Goals | Total Rows (Max) | Storage |
|-----------------|-------|-------|-----------------|---------|
| Small | 10K | 100 | 1M | ~100 MB |
| Medium | 100K | 500 | 50M | ~5 GB |
| Large | 1M | 1000 | 1B | ~100 GB |

**Actual Row Count:** Much lower due to lazy initialization (only active users)

### Query Performance Targets

| Query | Target (p95) | Index Used |
|-------|-------------|-----------|
| UPSERT Progress | < 5ms | Primary key |
| Batch UPSERT Progress (1000 rows) | < 20ms | Primary key |
| Get User Progress | < 10ms | User+Challenge index |
| Get Goal for Claim | < 5ms | Primary key |
| Mark as Claimed | < 5ms | Primary key |

### Load Testing Results

**TODO, not done yet**

---

## Troubleshooting

### Common Issues

#### Issue 1: Claimed Rewards Being Overwritten

**Symptom:** User claims reward, but status resets to `completed`

**Cause:** UPSERT query missing `WHERE status != 'claimed'` clause

**Fix:**
```sql
-- WRONG (no WHERE clause)
ON CONFLICT (user_id, goal_id) DO UPDATE SET status = EXCLUDED.status;

-- CORRECT (with WHERE clause)
ON CONFLICT (user_id, goal_id) DO UPDATE SET status = EXCLUDED.status
WHERE user_goal_progress.status != 'claimed';
```

#### Issue 2: Deadlocks on Concurrent Claims

**Symptom:** `ERROR: deadlock detected` in logs

**Cause:** Two transactions trying to claim same goal simultaneously

**Fix:** Use `SELECT ... FOR UPDATE` in claim flow:
```sql
SELECT * FROM user_goal_progress
WHERE user_id = $1 AND goal_id = $2
FOR UPDATE;
```

#### Issue 3: Slow Queries

**Symptom:** Queries taking > 100ms

**Diagnosis:**
```sql
-- Explain query plan
EXPLAIN ANALYZE
SELECT * FROM user_goal_progress WHERE user_id = 'abc123';

-- Check index usage
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE tablename = 'user_goal_progress';
```

**Fix:** Ensure indexes are created and used.

---

## References

- **PostgreSQL Docs**: https://www.postgresql.org/docs/15/
- **golang-migrate**: https://github.com/golang-migrate/migrate
- **Connection Pooling Best Practices**: https://www.alexedwards.net/blog/configuring-sqldb

---

**Document Status:** Complete - Ready for implementation
