# M5 Technical Specification: Time-Based Rotation

**Status:** Draft - Performance questions resolved, ready for implementation
**Created:** 2025-11-25
**Dependencies:** M3 (Goal Activation Control), M4 (Batch & Random Selection)

---

## Table of Contents

1. [Overview](#overview)
2. [Key Design Challenge: Daily Goals with Cumulative Stats](#key-design-challenge-daily-goals-with-cumulative-stats)
3. [Database Schema Changes](#database-schema-changes)
4. [Configuration Schema](#configuration-schema)
5. [Rotation Types](#rotation-types)
6. [API Changes](#api-changes)
7. [Rotation Detection (Truly Lazy)](#rotation-detection-truly-lazy)
8. [Event Processing Changes](#event-processing-changes)
9. [Implementation Phases](#implementation-phases)
10. [Design Decisions](#design-decisions)
11. [Performance Benchmark Results](#performance-benchmark-results) ✅ RESOLVED
12. [Resolved Questions](#resolved-questions)

---

## Overview

M5 adds **time-based expiry** to goal assignments, enabling:
- **Daily challenges**: Goals that reset every 24 hours
- **Weekly challenges**: Goals that reset every Monday
- **Seasonal events**: Time-limited goals with fixed start/end dates

> **Note:** Per-user timers (independent countdown per user) are deferred to M6. M5 implements **global rotation only** (all users share the same schedule boundaries).

### Core Concepts

| Concept | Description |
|---------|-------------|
| **Rotation** | The process of expiring old goals and making new ones available |
| **Global Rotation** | All users share the same expiry time (e.g., Monday midnight UTC) |
| **Per-User Rotation** | *(M6)* Each user has independent timer (e.g., 24h after activation) |
| **Baseline** | The stat value at goal activation, used for relative progress tracking |
| **ProgressMode** | How progress is tracked: `absolute` (lifetime) or `relative` (since baseline). Replaces the legacy `GoalType` system — see [GoalType to ProgressMode Migration](#goaltype-to-progressmode-migration) |

---

## Key Design Challenge: Daily Goals with Cumulative Stats

### The Problem

**Scenario:** Daily goal "Play 10 matches"
- User's stat `matches_played` is **cumulative** (never resets): 150 → 155 → 160...
- AGS Statistics Service tracks absolute values
- We **cannot and should not** reset the stat

**Current M1-M4 Behavior:**
```
Day 1 Start: stat = 150, goal target = 10
Day 1 Event: stat = 155 → progress = 155 → COMPLETED (155 >= 10) ❌ Wrong!

What we want:
Day 1 Start: stat = 150, baseline = 150, goal target = 10
Day 1 Event: stat = 155 → progress = 5 (155-150) → IN_PROGRESS (5/10) ✅
Day 1 Event: stat = 160 → progress = 10 (160-150) → COMPLETED (10/10) ✅
Day 2 Rotation: baseline = 160, progress reset
Day 2 Event: stat = 163 → progress = 3 (163-160) → IN_PROGRESS (3/10) ✅
```

### Solution: Baseline Snapshot + Progress Mode

Introduce two progress tracking modes:

| Mode | Use Case | Progress Calculation | Example |
|------|----------|---------------------|---------|
| `absolute` | Lifetime achievements | `progress = stat_value` | "Reach level 50" |
| `relative` | Daily/weekly goals | `progress = stat_value - baseline` | "Play 10 matches today" |

> **Important:** M5 introduces `ProgressMode` as a replacement for the legacy `GoalType` system (`absolute`/`increment`/`daily`). See [GoalType to ProgressMode Migration](#goaltype-to-progressmode-migration) for the migration plan.

### How It Works

#### 1. Goal Activation (Initialize/Select)

```
User activates "Play 10 matches" goal (relative mode)
├── Store baseline_value = NULL (set from first event — see Q6)
├── Set progress = 0
└── Goal is now tracking relative progress
```

> **Note:** Baseline is NOT fetched from AGS at activation time. Instead, it is derived
> from the first stat event via SQL CASE: `baseline = progress - inc_value`.
> See [Q6: Baseline Initialization](#q6-baseline-initialization--ags-api-call--resolved).

#### 2. Event Processing

```
Stat event arrives: matches_played = 155
├── Look up goal config: progress_mode = "relative"
├── Update progress = 155 (store absolute value)
├── Calculate displayed_progress = 155 - 150 = 5
└── Check completion: 5 >= 10? No → still in_progress
```

#### 3. Rotation (Daily Reset)

```
Rotation triggers at midnight
├── Current state: progress = 160, baseline = 150
├── Update baseline = 160 (snapshot current progress)
├── Reset status = "not_started"
└── Next event: progress = 163 → displayed = 163 - 160 = 3
```

### Alternative Approaches Considered

#### Option A: Reset Stats in AGS ❌
- Requires modifying player's actual statistics
- Breaks other game systems that depend on cumulative stats
- Against AGS design philosophy

#### Option B: Delta-Based Event Processing ❌
- Track `old_value` and `new_value` from events
- Increment progress by delta each time
- Problem: Events can arrive out of order, duplicates possible
- Complex idempotency handling

#### Option C: Baseline Snapshot ✅ (Chosen)
- Store stat value at activation as baseline
- Progress = current_stat - baseline
- Clean, simple, idempotent
- No AGS modifications needed

---

## Database Schema Changes

> **Note:** The `baseline_value` column is not yet in the production migration. Update the existing migration script (`extend-challenge-service/migrations/001_create_user_goal_progress.up.sql`) to include the new column. No new migration file is required since M5 is not yet deployed to production.

### New Columns in `user_goal_progress`

```sql
-- Update existing migration script:
-- extend-challenge-service/migrations/001_create_user_goal_progress.up.sql
-- Add baseline_value column to the CREATE TABLE statement
baseline_value INT NULL

-- baseline_value: Stat value when goal was activated (for relative progress)
-- NULL means absolute mode or not yet initialized
```

### Full Schema (Post-M5)

```sql
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    namespace VARCHAR(100) NOT NULL,

    -- Progress tracking
    progress INT NOT NULL DEFAULT 0,
    baseline_value INT NULL,              -- NEW: For relative progress mode
    status VARCHAR(20) NOT NULL DEFAULT 'not_started',

    -- Assignment control (M3)
    is_active BOOLEAN NOT NULL DEFAULT true,
    assigned_at TIMESTAMP NULL,
    expires_at TIMESTAMP NULL,            -- Used by M5 rotation

    -- Timestamps
    completed_at TIMESTAMP NULL,
    claimed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, goal_id)
);

-- Existing indexes remain unchanged
```

### Column Semantics

| Column | Purpose | Set By | When Updated |
|--------|---------|--------|--------------|
| `progress` | Absolute stat value | Event handler | On each stat event |
| `baseline_value` | Stat value at activation | Event handler (SQL CASE) | On first event, on rotation |
| `expires_at` | When goal expires | Initialize/Select API | On activation |
| `is_active` | Goal assignment status | User API, Rotation | On toggle, on expiry |

---

## Configuration Schema

### Goal-Level Configuration

```json
{
  "id": "daily-10-matches",
  "name": "Play 10 Matches",
  "description": "Complete 10 matches today",
  "requirement": {
    "stat_code": "matches_played",
    "operator": ">=",
    "target_value": 10,
    "progress_mode": "relative"    // NEW: "absolute" (default) or "relative"
  },
  "reward": {
    "type": "WALLET",
    "reward_id": "GOLD",
    "quantity": 100
  },
  "rotation": {                    // NEW: Optional rotation config
    "enabled": true,
    "type": "global",              // M5: "global" only (per_user deferred to M6)
    "schedule": "daily",           // Predefined: "daily", "weekly", "monthly"
    "on_expiry": {
      "reset_progress": true,      // Reset progress to 0 (and update baseline)
      "allow_reselection": true    // Allow re-attempting claimed goals after rotation
    }
  }
}
```

> **Validation rule:** `rotation.enabled=true` requires `progress_mode="relative"`. Absolute goals cannot rotate because rotation depends on baseline-relative progress tracking.

### Challenge-Level Configuration (Alternative)

```json
{
  "id": "daily-challenges",
  "name": "Daily Challenges",
  "rotation": {                    // Applied to all goals in challenge
    "enabled": true,
    "type": "global",
    "schedule": "daily",           // Predefined: "daily", "weekly", "monthly"
    "on_expiry": {
      "reset_progress": true,
      "allow_reselection": true    // Allow re-attempting claimed goals after rotation
    }
  },
  "goals": [
    {
      "id": "daily-login",
      "requirement": {
        "stat_code": "login_count",
        "operator": ">=",
        "target_value": 1,
        "progress_mode": "relative"
      }
    },
    {
      "id": "daily-10-matches",
      "requirement": {
        "stat_code": "matches_played",
        "operator": ">=",
        "target_value": 10,
        "progress_mode": "relative"
      }
    }
  ]
}
```

### Progress Mode Rules

| progress_mode | baseline_value | Progress Calculation | Completion Check |
|---------------|----------------|---------------------|------------------|
| `absolute` | NULL | `progress` | `progress >= target` |
| `relative` | Set on activation | `progress - baseline_value` | `(progress - baseline_value) >= target` |

### Rotation Type Rules

| rotation.type | expires_at Calculation | Example | Status |
|---------------|------------------------|---------|--------|
| `global` | Next schedule boundary | "Monday 00:00 UTC for everyone" | **M5** |
| `per_user` | `NOW() + duration` | "24h from when YOU activate" | **Deferred to M6** |

> **M6 Note:** Per-user rotation (`"type": "per_user"`) requires per-user timer tracking in both the SQL CASE event path and the API path. The current SQL CASE only handles global rotation boundaries. See [Decision 8](#8-per-user-rotation-deferred-to-m6--decided).

### Predefined Schedules

| Schedule | Boundary | Duration |
|----------|----------|----------|
| `daily` | Midnight UTC | 24h |
| `weekly` | Monday 00:00 UTC | 7d |
| `monthly` | 1st of month 00:00 UTC | ~30d |
| `custom` | Cron expression | Variable |

### GoalType to ProgressMode Migration

M5 introduces `ProgressMode` to replace the legacy `GoalType` system. This is a prerequisite for rotation because the old types conflate "how to track progress" with "how often to reset."

#### Current GoalType System (M1-M4)

| GoalType | `Daily` Flag | Behavior | Code Path |
|----------|------|----------|-----------|
| `absolute` | n/a | `progress = stat_value` | `processAbsoluteGoal()` → `UpdateProgress()` → COPY flush |
| `increment` | `false` | `progress += 1` per event | `processIncrementGoal()` → `IncrementProgress()` → UNNEST flush |
| `increment` | `true` | `progress += 1` once/day | `processIncrementGoal()` → `IncrementProgress(daily=true)` → UNNEST flush |
| `daily` | n/a | `completed_at = NOW()` | `processDailyGoal()` → `UpdateProgress()` → COPY flush |

**Key files affected:**
- `extend-challenge-common/pkg/domain/models.go` — `GoalType` enum (lines 39-78), `Goal.Type` + `Goal.Daily` fields
- `extend-challenge-event-handler/pkg/processor/event_processor.go` — 3-way switch on `GoalType` (lines 118-146)
- `extend-challenge-event-handler/pkg/buffered/buffered_repository.go` — Dual buffers: `buffer` (absolute/daily) + `bufferIncrement` (increment)
- Config loader, validator, cache, tests (~34 files total)

#### New ProgressMode System (M5)

| ProgressMode | Behavior | Replaces |
|-------------|----------|----------|
| `absolute` | `progress = stat_value` (blind write) | `GoalType.absolute` |
| `relative` | `progress = stat_value`, completion = `(progress - baseline) >= target` | `GoalType.increment` + `GoalType.daily` |

**Migration mapping:**

| Old Config | New Config | Rationale |
|------------|------------|-----------|
| `type: "absolute"` | `progress_mode: "absolute"` | Direct mapping |
| `type: "increment", daily: false` | `progress_mode: "relative"` | Counter logic replaced by `inc_value` extraction |
| `type: "increment", daily: true` | `progress_mode: "relative"` + `rotation.schedule: "daily"` | Daily dedup now handled by rotation |
| `type: "daily"` | `progress_mode: "relative"` + `rotation.schedule: "daily"` | Binary daily check becomes relative with target=1 |

**Before (M4 config):**
```json
{
  "id": "daily-login",
  "type": "daily",
  "event_source": "login",
  "requirement": { "stat_code": "login_count", "operator": ">=", "target_value": 1 }
}
```

**After (M5 config):**
```json
{
  "id": "daily-login",
  "event_source": "login",
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 1,
    "progress_mode": "relative"
  },
  "rotation": { "enabled": true, "type": "global", "schedule": "daily",
                 "on_expiry": { "reset_progress": true, "allow_reselection": true } }
}
```

**Removed fields:** `type` (GoalType), `daily` (bool)
**Added fields:** `requirement.progress_mode`, `rotation` block

---

## Rotation Types

### Global Rotation

All users share the **same expiry time** based on server schedule. This is the only rotation type supported in M5.

```
Weekly rotation (Monday 00:00 UTC):
- User A joins Monday → expires next Monday (7 days)
- User B joins Friday → expires next Monday (3 days)
```

**Use Cases:**
- Weekly challenges (everyone competes in same window)
- Seasonal events (fixed start/end dates)
- Synchronized leaderboards
- Daily challenges (midnight UTC reset for all users)

### Per-User Rotation (Deferred to M6)

> **M6:** Per-user rotation (independent timer per user starting from activation) is deferred. It requires:
> - Per-user `rotation_boundary` computation in the SQL CASE event path (currently only global boundaries are computed)
> - Per-user expiry tracking in the API path
> - Additional SQL CASE branches for `expires_at`-based rotation detection
>
> **Use cases (M6):** "Complete within 24 hours of starting", tutorial challenges, personal daily quests.

---

## API Changes

### 1. Update Initialize Endpoint

**Endpoint:** `POST /v1/challenges/initialize`

**Changes:**
- **Detect rotation lazily** for existing goals (returning players)
- Set `expires_at` based on rotation config (baseline is NOT set here — derived from first event, see Q6)

**Implementation:**
```go
func InitializePlayer(ctx context.Context, userID string) (*InitializeResponse, error) {
    now := time.Now()
    defaultGoals := config.GetGoalsWithDefaultAssigned()

    // Get existing progress for this user
    existingRows, _ := h.repo.GetUserGoalProgress(ctx, userID)
    existingMap := make(map[string]*UserGoalProgress)
    for _, row := range existingRows {
        existingMap[row.GoalID] = row
    }

    var rowsToUpdate []*UserGoalProgress
    var rowsToInsert []*UserGoalProgress

    for _, goal := range defaultGoals {
        if existing, ok := existingMap[goal.ID]; ok {
            // ========================================
            // EXISTING GOAL: Check for lazy rotation
            // ========================================
            if ApplyRotationReset(existing, goal, now) {
                rowsToUpdate = append(rowsToUpdate, existing)
            }
        } else {
            // ========================================
            // NEW GOAL: Create fresh row
            // ========================================
            row := &UserGoalProgress{
                UserID:     userID,
                GoalID:     goal.ID,
                ChallengeID: goal.ChallengeID,
                Namespace:  h.namespace,
                IsActive:   true,
                Status:     "not_started",
                AssignedAt: &now,
                UpdatedAt:  now,
            }

            // Set expiry based on rotation config (global only in M5)
            if goal.Rotation.Enabled {
                exp := CalculateNextRotationBoundary(goal.Rotation.Schedule, now)
                row.ExpiresAt = &exp
            }

            // Baseline is NOT set here — it is derived from the first stat event
            // via SQL CASE: baseline = progress - inc_value (see Q6)
            // row.BaselineValue stays nil until first event arrives

            rowsToInsert = append(rowsToInsert, row)
        }
    }

    // Batch insert new rows
    if len(rowsToInsert) > 0 {
        h.repo.BatchInsertProgress(ctx, rowsToInsert) // New method: Phase 6
    }

    // Batch update rotated rows
    if len(rowsToUpdate) > 0 {
        h.repo.BatchUpdateProgress(ctx, rowsToUpdate) // New method: Phase 6
    }

    return &InitializeResponse{...}
}
```

**Scenarios:**

| Player Type | Behavior |
|-------------|----------|
| New player | Create all default goal rows with initial baseline/expiry |
| Returning player (same day) | No changes, return current state |
| Returning player (after rotation) | Detect rotation, reset affected goals |

### 2. Update Selection Endpoints (M4)

**Endpoints:**
- `POST /v1/challenges/{challenge_id}/goals/batch-select`
- `POST /v1/challenges/{challenge_id}/goals/random-select`

**Changes:**
- Set `baseline_value` for relative progress goals
- Set `expires_at` based on rotation config

### 3. Update GET Challenges Response

**Changes:**
- **Detect rotation lazily** before building response
- Return `displayed_progress` (calculated) instead of raw `progress`
- Include `expires_at` and `expires_in_seconds` for rotation goals
- If rotation occurred, show reset state (progress=0, status=not_started)

**Implementation with Lazy Rotation Detection:**

```go
func (h *ChallengesHandler) GetChallenges(ctx context.Context, userID string) (*ChallengesResponse, error) {
    now := time.Now()

    // Get user's goal progress from DB
    rows, err := h.repo.GetUserGoalProgress(ctx, userID)
    if err != nil {
        return nil, err
    }

    // Build response with in-memory rotation detection (read-only — Q5)
    // No DB writes — GET is read-only. The event handler's SQL CASE rotation
    // persists the rotation reset on the next event.
    response := &ChallengesResponse{}

    for _, row := range rows {
        goal := h.cache.GetGoalByID(row.GoalID)
        if goal == nil {
            continue
        }

        // In-memory rotation detection: check if rotation occurred since last update
        rotated := HasRotationOccurred(row, goal, now)

        // Compute displayed progress and status (no mutation of row)
        var displayedProgress int
        var displayStatus string

        if rotated && goal.Requirement.ProgressMode == "relative" && goal.Rotation.OnExpiry.ResetProgress {
            // Rotated + relative + reset_progress=true: show reset state
            displayedProgress = 0
            displayStatus = "not_started"
        } else if rotated && goal.Rotation.OnExpiry.AllowReselection && row.Status == "claimed" {
            // Rotated + claimed + allow_reselection: show reset state for re-attempt
            displayedProgress = 0
            displayStatus = "not_started"
        } else {
            displayedProgress = calculateDisplayedProgress(row, goal)
            displayStatus = row.Status
        }

        // Calculate expiry info (global rotation only in M5)
        var expiresAt *time.Time
        var expiresInSeconds *int
        if goal.Rotation.Enabled {
            // Global rotation: calculate next boundary
            exp := CalculateNextRotationBoundary(goal.Rotation.Schedule, now)
            expiresAt = &exp
            if expiresAt != nil {
                secs := int(expiresAt.Sub(now).Seconds())
                expiresInSeconds = &secs
            }
        }

        // Build goal response
        goalResp := GoalResponse{
            ID:               goal.ID,
            Name:             goal.Name,
            Progress:         displayedProgress,
            Target:           goal.Requirement.TargetValue,
            Status:           displayStatus,
            IsActive:         row.IsActive,
            ExpiresAt:        expiresAt,
            ExpiresInSeconds: expiresInSeconds,
        }
        // ... add to response
    }

    return response, nil
}
```

**Response Schema:**
```json
{
  "challenges": [
    {
      "id": "daily-challenges",
      "name": "Daily Challenges",
      "goals": [
        {
          "id": "daily-10-matches",
          "name": "Play 10 Matches",
          "progress": 5,              // Calculated: progress - baseline
          "target": 10,
          "status": "in_progress",
          "is_active": true,
          "expires_at": "2025-11-26T00:00:00Z",
          "expires_in_seconds": 43200
        }
      ]
    }
  ]
}
```

**Edge Case: User queries after rotation but before any event:**
- `ApplyRotationReset()` sets status="not_started", baseline=nil
- `calculateDisplayedProgress()` returns 0 (since baseline is nil)
- User sees fresh daily challenge with progress=0 ✓

### 4. New Rotation Status Endpoint

**Endpoint:** `GET /v1/challenges/{challenge_id}/rotation`

> **Note:** In M5, `type` is always `"global"`. Per-user rotation is deferred to M6.

**Response:**
```json
{
  "challenge_id": "daily-challenges",
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "current_period": {
      "start_time": "2025-11-25T00:00:00Z",
      "end_time": "2025-11-26T00:00:00Z",
      "expires_in_seconds": 43200
    },
    "next_period": {
      "start_time": "2025-11-26T00:00:00Z"
    }
  }
}
```

---

## Rotation Detection (Truly Lazy)

### Architecture

With truly lazy rotation, there is **no background scheduler** for rotating user progress. Rotation is detected on-demand via two distinct paths:

1. **API path** (REST handlers): In-memory, read-only detection using Go utilities. No DB writes — just display the rotated state to the client. (See [Q5](#q5-get-challenges--read-only-vs-writeback--resolved))
2. **Event path** (gRPC handler): SQL CASE expressions in the batch UPDATE. Zero application-level reads. The rotation logic lives entirely in the UPDATE's SET clause. (See [Q3](#q3-event-handler--blind-write--read-before-write--resolved))

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                   API Path: In-Memory Rotation (Read-Only)                    │
│                                                                               │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐             │
│  │ POST /initialize │   │ GET /challenges │   │ POST /claim     │             │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘             │
│           │                     │                     │                       │
│           └──────────────────┬──┴─────────────────────┘                       │
│                              ▼                                                │
│                 ┌────────────────────────┐                                    │
│                 │ HasRotationOccurred()  │  Compare row.UpdatedAt             │
│                 │ for each user goal     │  vs last rotation boundary         │
│                 └───────────┬────────────┘                                    │
│                             │                                                 │
│              ┌──────────────┴──────────────┐                                  │
│              ▼                             ▼                                  │
│    ┌─────────────────┐          ┌─────────────────────┐                       │
│    │ No rotation     │          │ Rotation detected   │                       │
│    │ Return as-is    │          │ Display reset state: │                       │
│    └─────────────────┘          │ progress=0, status=  │                       │
│                                 │ not_started (in mem) │                       │
│                                 └─────────────────────┘                       │
│                                                                               │
│  No DB writes — GET is read-only (Q5). DB catches up on next event.           │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│                   Event Path: SQL CASE Rotation (Zero Reads)                  │
│                                                                               │
│  ┌───────────────────────┐                                                    │
│  │ OnStatItemUpdated()   │  Receives AGS stat events                          │
│  └───────────┬───────────┘                                                    │
│              ▼                                                                │
│  ┌──────────────────────────────┐                                             │
│  │ Enrich from config cache:    │  Look up goal config (in-memory)            │
│  │  progress_mode, target_value │                                             │
│  │  rotation_boundary (computed)│  = CalculateLastRotationBoundary()          │
│  │  new_expires_at (computed)   │  = CalculateNextRotationBoundary()          │
│  └───────────┬──────────────────┘                                             │
│              ▼                                                                │
│  ┌──────────────────────────────┐                                             │
│  │ Buffer + COPY to temp table  │  Enhanced temp table with M5 columns        │
│  └───────────┬──────────────────┘                                             │
│              ▼                                                                │
│  ┌──────────────────────────────┐                                             │
│  │ SQL CASE UPDATE              │  All rotation logic in SET clause:           │
│  │  - Detect: updated_at <      │    rotation_boundary                        │
│  │  - Reset baseline: progress  │    - inc_value                              │
│  │  - Init baseline: NULL case  │                                             │
│  │  - Compute status            │                                             │
│  │  - Skip claimed (WHERE)      │                                             │
│  └──────────────────────────────┘                                             │
│                                                                               │
│  Zero app-level reads. Blind-write preserved. 1.2x overhead (Q3).             │
└──────────────────────────────────────────────────────────────────────────────┘

                              ┌─────────────┐
                              │ PostgreSQL  │  No bulk updates at rotation time!
                              └─────────────┘  Per-user updates only via events.
```

### Core Rotation Detection Logic

These Go utilities serve a **dual role**:
1. **API handlers**: In-memory display — detect rotation and show reset state without DB writes
2. **Event enrichment**: Compute `rotation_boundary` and `new_expires_at` values for the enhanced temp table

> **Read-only vs mutating functions:**
> - `HasRotationOccurred()` — **read-only**. Used by GET handlers (`/challenges`, `/challenges/{id}`) to detect if a rotation boundary has passed. Returns a boolean; does not write to the database.
> - `ApplyRotationReset()` — **mutating**. Used by Initialize/Select handlers and event processing to actually reset progress and write new `baseline_value`, `expires_at`, etc. to the database.

```go
// rotation.go - Shared rotation utilities (global rotation only in M5)

// CalculateLastRotationBoundary returns the start of the current rotation period
func CalculateLastRotationBoundary(schedule string, now time.Time) time.Time {
    now = now.UTC()
    switch schedule {
    case "daily":
        return now.Truncate(24 * time.Hour)
    case "weekly":
        // Last Monday 00:00 UTC
        daysFromMonday := (int(now.Weekday()) + 6) % 7
        return now.Truncate(24 * time.Hour).AddDate(0, 0, -daysFromMonday)
    case "monthly":
        return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
    }
    return time.Time{}
}

// CalculateNextRotationBoundary returns when the current period ends
func CalculateNextRotationBoundary(schedule string, now time.Time) time.Time {
    last := CalculateLastRotationBoundary(schedule, now)
    switch schedule {
    case "daily":
        return last.Add(24 * time.Hour)
    case "weekly":
        return last.AddDate(0, 0, 7)
    case "monthly":
        return last.AddDate(0, 1, 0)
    }
    return time.Time{}
}

// CalculateNextExpiresAt returns the next expiry time based on rotation config
// M5: Global rotation only. Per-user rotation deferred to M6.
func CalculateNextExpiresAt(goal *Goal, now time.Time) *time.Time {
    if !goal.Rotation.Enabled {
        return nil
    }

    // Global: next schedule boundary
    next := CalculateNextRotationBoundary(goal.Rotation.Schedule, now)
    return &next
}

// HasRotationOccurred checks if the goal has rotated since the row was last updated
// M5: Global rotation only — compare updated_at with last schedule boundary
func HasRotationOccurred(row *UserGoalProgress, goal *Goal, now time.Time) bool {
    if !goal.Rotation.Enabled {
        return false
    }

    // Global: compare updated_at with last rotation boundary
    lastRotation := CalculateLastRotationBoundary(goal.Rotation.Schedule, now)
    return row.UpdatedAt.Before(lastRotation)
}

// ApplyRotationReset resets a row for the new rotation period (global rotation)
// Respects on_expiry config and preserves completed/claimed goals
// Returns true if reset was applied
func ApplyRotationReset(row *UserGoalProgress, goal *Goal, now time.Time) bool {
    if !HasRotationOccurred(row, goal, now) {
        return false
    }

    // ========================================
    // HANDLE CLAIMED GOALS
    // ========================================
    // Claimed goals are permanent UNLESS allow_reselection=true.
    // When allow_reselection is enabled, claimed goals reset on rotation
    // so the user can re-attempt and re-claim in the new period.
    // Completed goals ARE always reset on rotation (new period = new attempt).
    if row.Status == "claimed" {
        if !goal.Rotation.OnExpiry.AllowReselection {
            return false  // Claimed goals excluded unless reselectable
        }
        // Fall through to reset logic below
    }

    // ========================================
    // RESPECT on_expiry.reset_progress CONFIG
    // ========================================
    if goal.Rotation.OnExpiry.ResetProgress {
        // Reset baseline (will be set from event.Inc on first event)
        row.BaselineValue = nil
        row.Status = "not_started"
        row.CompletedAt = nil
        row.ClaimedAt = nil  // Clear claimed_at for reselection
    }
    // If reset_progress=false, keep current progress/status (just update expiry)

    // ========================================
    // SET NEW EXPIRY (global rotation)
    // ========================================
    row.ExpiresAt = CalculateNextExpiresAt(goal, now)
    row.UpdatedAt = now

    return true
}
```

### Rotation Behavior Summary

| Status Before Rotation | `reset_progress=true` | `reset_progress=false` |
|------------------------|----------------------|------------------------|
| `not_started` | Reset to `not_started` | Keep `not_started` |
| `in_progress` | Reset to `not_started`, baseline=nil | Keep progress |
| `completed` | **Reset** (new period = new attempt) | **Keep completed** |
| `claimed` | **Reset** if `allow_reselection=true`, else **Skipped** | **Skipped** |

**Key Design Decision:** Completed goals are reset on rotation **only when `reset_progress=true`**. When `reset_progress=false`, completed goals keep their status. Claimed goals are permanent **unless** `allow_reselection=true` and a rotation boundary has passed, in which case they reset to `not_started` for a fresh attempt in the new period. See [Reselection of Claimed Goals](#reselection-of-claimed-goals) for full design.

### Why No Background Scheduler?

| Aspect | Background Scheduler | Truly Lazy |
|--------|---------------------|------------|
| Rotation cost | O(users × goals) | O(1) |
| 100K users × 100 goals | 10M row updates | 0 row updates |
| Latency at rotation | Minutes of DB load | Zero |
| First user access | Instant | +1 row update |
| Complexity | Scheduler, locks, retries | Detection logic only |
| Redis dependency | Required (distributed lock) | Not required |

### Optional: Scheduled Tasks (Non-Rotation)

A background scheduler may still be useful for tasks that truly need scheduled execution:
- Sending rotation notifications (push notifications, webhooks)
- Pre-warming caches
- Analytics/reporting snapshots
- Cleanup of old data

These do NOT require updating user_goal_progress rows.

### Reselection of Claimed Goals

The `on_expiry.allow_reselection` config field controls whether claimed goals can be re-attempted after a rotation boundary passes. This is essential for **repeatable daily/weekly goals** where users should be able to complete, claim, and then re-do the same goal in each new period.

**Behavior:**
- When `allow_reselection=true`: Claimed goals reset to `not_started` on rotation, clearing `claimed_at` and `completed_at`. The user gets a fresh attempt in the new period.
- When `allow_reselection=false` (default): Claimed goals are permanent and excluded from all rotation logic.

**Note:** `allow_reselection` only takes effect when `reset_progress=true`. The combination `reset_progress=false` + `allow_reselection=true` doesn't make sense — you wouldn't keep old progress for a re-attempted goal — so `allow_reselection` is ignored when `reset_progress=false`.

**Audit trail:** The `claimed_at` column is set to `NULL` when a claimed goal resets for reselection. Historical claim data should be captured via application-level logging or an audit table if needed for analytics.

**Implementation touchpoints:**
1. **Temp table**: `allow_reselection BOOLEAN` column (see [Enhanced Temp Table Schema](#enhanced-temp-table-schema))
2. **WHERE clause**: Conditional exclusion — claimed rows pass through when `allow_reselection=true`
3. **SQL CASE branches**: Status, baseline, completed_at, claimed_at, and expires_at all handle the `claimed + stale + allow_reselection` case
4. **ApplyRotationReset()**: Conditional claimed check (see [Core Rotation Detection Logic](#core-rotation-detection-logic))
5. **GET handler**: In-memory display of reset state for claimed+reselectable goals

---

## Event Processing Changes

### SQL CASE Rotation (Zero App-Level Reads)

> **Resolved by Q3:** All rotation detection, baseline initialization, and status computation are pushed into SQL CASE expressions within the batch UPDATE statement. This preserves the blind-write architecture (zero application-level reads) with only 1.2x overhead. See [Q3 details](#q3-event-handler--blind-write--read-before-write--resolved).

The event processor:
1. **Enriches each buffered event** with metadata from the in-memory config cache
2. **COPY events into an enhanced temp table** with M5 metadata columns
3. **Executes a single UPDATE with CASE expressions** that handle rotation, baseline init, and completion

### Inc Field Extraction from AGS Events

M5 requires the `inc_value` (increment delta) from each event for baseline computation (`baseline = progress - inc_value`). The AGS proto provides this field but it is not currently extracted.

**Proto field:** `StatItem.Inc` (float64) — defined in `extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/social/statistic/v1/statistic.pb.go:451`

| Event Type | Current Extraction | M5 Extraction |
|------------|-------------------|---------------|
| **Statistic update** | `msg.Payload.LatestValue` → `statValue` | `msg.Payload.LatestValue` → `statValue` + `msg.Payload.Inc` → `incValue` |
| **Login event** | Synthetic `statValue=1` | Synthetic `statValue=1` + synthetic `incValue=1` |

**Current code** (`pkg/service/statisticHandler.go:135`):
```go
statValue := int(msg.Payload.LatestValue)
```

**M5 code:**
```go
statValue := int(msg.Payload.LatestValue)
incValue := int(msg.Payload.Inc)  // NEW: extract increment for baseline computation
```

For login events, `incValue=1` is always synthetic (login events don't carry stat increments).

**ProcessEvent signature change:**

M5 changes `ProcessEvent` to accept a `StatUpdate` struct instead of a bare `int` value:

```go
// StatUpdate carries both the absolute value and the increment delta.
// For login events: Value=nil, Inc=1 (no absolute stat value available).
// For stat events:  Value=&latestValue, Inc=incValue.
type StatUpdate struct {
    Value *int // nil for login events (no absolute stat value)
    Inc   int  // increment delta; always >= 1
}
```

- **statisticHandler**: creates `StatUpdate{Value: &statValue, Inc: incValue}`
- **loginHandler**: creates `StatUpdate{Value: nil, Inc: 1}` (synthetic increment, no absolute value)

### Unified COPY Path

M1-M4 uses two separate flush paths with separate buffers. M5 unifies these into a single COPY+UPDATE path.

**Current dual-path architecture (M1-M4):**

| Path | Buffer | Goals | SQL Method |
|------|--------|-------|------------|
| Absolute/Daily | `buffer` (map[string]*UserGoalProgress) | `GoalTypeAbsolute`, `GoalTypeDaily` | `BatchUpsertProgressWithCOPY()` |
| Increment | `bufferIncrement` (map[string]int) + `bufferIncrementDaily` (map[string]time.Time) | `GoalTypeIncrement` | `BatchIncrementProgress()` (UNNEST) |

**New unified path (M5):**

| Path | Buffer | Goals | SQL Method |
|------|--------|-------|------------|
| Unified COPY | Single buffer with `progress`, `inc_value`, `progress_mode` | All goals | `BatchUpsertProgressWithCOPY()` (enhanced) |

**Unified buffer entry type:**

```go
// BufferedEvent is the single buffer entry type that replaces the 3 separate
// buffer maps (buffer, bufferIncrement, bufferIncrementDaily).
type BufferedEvent struct {
    UserID       string
    GoalID       string
    ChallengeID  string
    Namespace    string
    Progress     *int      // nil for login events (no absolute stat value)
    IncValue     int       // increment delta; always >= 1
    ProgressMode string    // "absolute" or "relative"
}
```

The unified buffer is `map[string]*BufferedEvent` keyed by `userID:goalID`.

**Key changes:**
- Single buffer replaces 3 separate maps (`buffer`, `bufferIncrement`, `bufferIncrementDaily`)
- `Progress` is nullable (`*int`) — `nil` for login events where only `IncValue` is known
- SQL CASE handles accumulation: when `progress IS NULL`, use `ugp.progress + temp.inc_value`
- Login events: buffered as `{Progress: nil, IncValue: 1}` — SQL does the accumulation
- The `IncrementProgress()` method and UNNEST flush path are removed

#### Enhanced Temp Table Schema

```sql
CREATE TEMP TABLE temp_event_progress (
    user_id            VARCHAR(100) NOT NULL,
    goal_id            VARCHAR(100) NOT NULL,
    challenge_id       VARCHAR(100) NOT NULL,
    namespace          VARCHAR(100) NOT NULL,
    progress           INT          NULL,        -- Absolute stat value from event (NULL for login/increment events)
    progress_mode      VARCHAR(20)  NOT NULL,    -- "absolute" or "relative" (from config)
    inc_value          INT          NOT NULL DEFAULT 0,    -- Delta from this event (extracted from AGS Inc field)
    target_value       INT          NOT NULL DEFAULT 0,    -- Completion target (from config)
    rotation_boundary  TIMESTAMP    NULL,        -- Last rotation boundary (computed, global only)
    new_expires_at     TIMESTAMP    NULL,        -- Next expiry timestamp (computed)
    allow_reselection  BOOLEAN      NOT NULL DEFAULT false, -- Allow claimed goals to reset on rotation
    reset_progress     BOOLEAN      NOT NULL DEFAULT true,  -- Reset progress on rotation
    updated_at         TIMESTAMP    NOT NULL DEFAULT NOW()
) ON COMMIT DROP
```

#### Event Enrichment (Go Code)

```go
// During buffer flush, enrich each event with config metadata before COPY
func (b *BufferedRepository) enrichEvent(event *BufferedEvent, goal *Goal, now time.Time) *EnrichedEvent {
    enriched := &EnrichedEvent{
        UserID:           event.UserID,
        GoalID:           event.GoalID,
        ChallengeID:      event.ChallengeID,
        Namespace:        event.Namespace,
        Progress:         event.Progress,      // may be nil for login events
        ProgressMode:     goal.Requirement.ProgressMode,
        IncValue:         event.IncValue,      // from AGS Inc field or synthetic 1
        TargetValue:      goal.Requirement.TargetValue,
        AllowReselection: goal.Rotation.OnExpiry.AllowReselection,
        ResetProgress:    goal.Rotation.OnExpiry.ResetProgress,
    }

    // Compute rotation boundary for relative goals with rotation enabled (global only)
    // Defense-in-depth: rotation.enabled=true requires progress_mode="relative" (validated at config load)
    if goal.Requirement.ProgressMode == "relative" && goal.Rotation.Enabled {
        boundary := CalculateLastRotationBoundary(goal.Rotation.Schedule, now)
        enriched.RotationBoundary = &boundary

        nextExpiry := CalculateNextRotationBoundary(goal.Rotation.Schedule, now)
        enriched.NewExpiresAt = &nextExpiry
    }

    return enriched
}
```

#### SQL CASE UPDATE Statement

All rotation logic lives in the UPDATE's SET clause. This is designed for M5 implementation; core patterns (rotation detection, baseline init, status computation, `reset_progress`, and `allow_reselection`) are validated by `tests/benchmarks/bench_3_sql_rotation_test.go`. NULL progress (login events where `progress IS NULL` and accumulation uses `ugp.progress + temp.inc_value`) is not yet covered by benchmarks — those paths will be tested in Phase 7 integration tests.

```sql
UPDATE user_goal_progress AS ugp
SET
    -- Progress: set from event, or accumulate for login/increment events
    progress = CASE
        WHEN temp.progress IS NOT NULL THEN temp.progress
        ELSE ugp.progress + temp.inc_value
    END,

    -- Baseline: rotation detection via SQL CASE
    baseline_value = CASE
        -- Absolute mode: baseline stays NULL
        WHEN temp.progress_mode = 'absolute'
            THEN ugp.baseline_value

        -- Relative + claimed + reselectable + stale: reset baseline for new period
        WHEN temp.progress_mode = 'relative'
             AND ugp.status = 'claimed'
             AND temp.allow_reselection = true
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
            THEN COALESCE(temp.progress, ugp.progress + temp.inc_value) - temp.inc_value

        -- Relative + rotated + reset_progress=true: reset baseline
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND ugp.status != 'claimed'
             AND temp.reset_progress = true
            THEN COALESCE(temp.progress, ugp.progress + temp.inc_value) - temp.inc_value

        -- Relative + rotated + reset_progress=false: keep existing baseline
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND ugp.status != 'claimed'
             AND temp.reset_progress = false
            THEN ugp.baseline_value

        -- Relative + first event (no baseline yet): initialize
        WHEN temp.progress_mode = 'relative'
             AND ugp.baseline_value IS NULL
            THEN COALESCE(temp.progress, ugp.progress + temp.inc_value) - temp.inc_value

        -- Relative + not rotated: keep existing baseline
        ELSE ugp.baseline_value
    END,

    -- Status: compute based on new progress vs baseline
    status = CASE
        -- Claimed + allow_reselection + stale: reset for new period
        WHEN ugp.status = 'claimed'
             AND temp.allow_reselection = true
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
            THEN 'not_started'

        -- Claimed + not reselectable (or not stale): preserve
        WHEN ugp.status = 'claimed'
            THEN 'claimed'

        -- Completed + NOT stale: preserve
        WHEN ugp.status = 'completed'
             AND NOT (temp.progress_mode = 'relative'
                      AND temp.rotation_boundary IS NOT NULL
                      AND ugp.updated_at < temp.rotation_boundary)
            THEN 'completed'

        -- Completed + stale + reset_progress=false: preserve completed
        WHEN ugp.status = 'completed'
             AND temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = false
            THEN 'completed'

        -- Absolute mode: simple threshold
        WHEN temp.progress_mode = 'absolute'
             AND COALESCE(temp.progress, ugp.progress + temp.inc_value) >= temp.target_value
            THEN 'completed'

        -- Relative + rotated + reset_progress=true: check inc_value against target
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = true
             AND temp.inc_value >= temp.target_value
            THEN 'completed'

        -- Relative + rotated + reset_progress=false: check against existing baseline
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = false
             AND ugp.baseline_value IS NOT NULL
             AND (COALESCE(temp.progress, ugp.progress + temp.inc_value) - ugp.baseline_value) >= temp.target_value
            THEN 'completed'

        -- Relative + not rotated: check against existing baseline
        WHEN temp.progress_mode = 'relative'
             AND NOT (temp.rotation_boundary IS NOT NULL AND ugp.updated_at < temp.rotation_boundary)
             AND ugp.baseline_value IS NOT NULL
             AND (COALESCE(temp.progress, ugp.progress + temp.inc_value) - ugp.baseline_value) >= temp.target_value
            THEN 'completed'

        -- Default: in_progress
        ELSE 'in_progress'
    END,

    -- Completed timestamp (reset on rotation, set on new completion)
    completed_at = CASE
        -- Claimed + reselectable + stale: clear for new period
        WHEN ugp.status = 'claimed'
             AND temp.allow_reselection = true
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
            THEN NULL
        WHEN ugp.status = 'claimed' THEN ugp.completed_at
        -- Completed + stale + reset_progress=false: preserve
        WHEN ugp.status = 'completed'
             AND temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = false
            THEN ugp.completed_at
        WHEN ugp.status = 'completed'
             AND NOT (temp.progress_mode = 'relative'
                      AND temp.rotation_boundary IS NOT NULL
                      AND ugp.updated_at < temp.rotation_boundary)
            THEN ugp.completed_at
        WHEN temp.progress_mode = 'absolute'
             AND COALESCE(temp.progress, ugp.progress + temp.inc_value) >= temp.target_value
             AND ugp.completed_at IS NULL
            THEN NOW()
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = true
             AND temp.inc_value >= temp.target_value
            THEN NOW()
        WHEN temp.progress_mode = 'relative'
             AND NOT (temp.rotation_boundary IS NOT NULL AND ugp.updated_at < temp.rotation_boundary)
             AND ugp.baseline_value IS NOT NULL
             AND (COALESCE(temp.progress, ugp.progress + temp.inc_value) - ugp.baseline_value) >= temp.target_value
             AND ugp.completed_at IS NULL
            THEN NOW()
        -- Rotated + reset_progress=true but not completed: clear old completed_at
        WHEN temp.progress_mode = 'relative'
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
             AND temp.reset_progress = true
            THEN NULL
        ELSE ugp.completed_at
    END,

    -- Expires: update on rotation
    -- Note: No special branch needed for claimed+reselectable — the generic
    -- rotation branch below covers all stale rows regardless of status.
    expires_at = CASE
        WHEN temp.new_expires_at IS NOT NULL
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
            THEN temp.new_expires_at
        WHEN temp.new_expires_at IS NOT NULL AND ugp.expires_at IS NULL
            THEN temp.new_expires_at
        ELSE ugp.expires_at
    END,

    -- Claimed_at: clear for reselectable goals on rotation
    claimed_at = CASE
        WHEN ugp.status = 'claimed'
             AND temp.allow_reselection = true
             AND temp.rotation_boundary IS NOT NULL
             AND ugp.updated_at < temp.rotation_boundary
            THEN NULL
        ELSE ugp.claimed_at
    END,

    updated_at = NOW()

FROM temp_event_progress AS temp
WHERE ugp.user_id    = temp.user_id
  AND ugp.goal_id    = temp.goal_id
  AND ugp.is_active  = true
  AND NOT (ugp.status = 'claimed' AND temp.allow_reselection = false)
```

**Benchmark implementation:** `tests/benchmarks/bench_3_sql_rotation_test.go` — covers core stat event patterns with non-NULL progress, `reset_progress=true/false`, and `allow_reselection=true/false`. NULL progress (login event accumulation) paths are deferred to Phase 7 integration tests.

### Event Flow with SQL CASE Rotation

**Scenario 1: In-Progress Goal (reset_progress=true)**
```
Day 1 (before rotation):
  stat=155, baseline=150, progress=155, displayed=5, status=in_progress

Midnight: Rotation boundary passes (no DB updates!)

Day 2 Event: stat=163, inc=3
  1. Event enriched: rotation_boundary=midnight, progress_mode=relative
  2. SQL CASE detects ugp.updated_at < rotation_boundary
     → baseline = 163 - 3 = 160 (reset from first event in new period)
     → status = in_progress (inc=3 < target=10)
     → expires_at = next midnight
  3. Result: progress=163, baseline=160, displayed=3, status=in_progress
```

**Scenario 2: Completed Goal (reset_progress=true)**
```
Day 1 (before rotation):
  stat=160, baseline=150, progress=160, displayed=10, status=completed ✓

Midnight: Rotation boundary passes (no DB updates!)

Day 2 Event: stat=163, inc=3
  1. SQL CASE detects: completed + stale (updated_at < rotation_boundary) + reset_progress=true
     → completed is NOT preserved for stale rows — new period = new attempt
     → baseline = 163 - 3 = 160 (reset)
     → status = in_progress (inc=3 < target=10)
     → completed_at = NULL (cleared)
  2. Result: goal resets for new day. User must re-complete.

Note: When reset_progress=false, completed goals keep their status across rotation
boundaries — the completed_at and baseline are preserved, only expires_at updates.
Claimed goals are permanent unless allow_reselection=true.
```

**Scenario 3: Claimed Goal with allow_reselection=true**
```
Day 1: User completes and claims daily goal
  → status=claimed, claimed_at=Day1 18:00, completed_at=Day1 17:30

Midnight: Rotation boundary passes (no DB updates!)

Day 2 Event: stat=173, inc=3
  1. Event enriched: rotation_boundary=midnight, allow_reselection=true
  2. WHERE clause passes: NOT (status='claimed' AND allow_reselection=false) → true
  3. SQL CASE detects claimed + stale + allow_reselection:
     → status = 'not_started' (reset for new period)
     → baseline = 173 - 3 = 170 (fresh baseline)
     → completed_at = NULL (cleared)
     → claimed_at = NULL (cleared)
     → expires_at = next midnight (new period)
  4. Result: Goal is available for a fresh attempt. User can re-complete and re-claim.

Day 2 Later: stat=180, inc=7
  → displayed_progress = 180 - 170 = 10 → COMPLETED (10/10)
  → User claims again → status=claimed, claimed_at=Day2

Without allow_reselection (default):
  → WHERE clause blocks: NOT (status='claimed' AND false=false) → false
  → Row is excluded from UPDATE entirely. Stays claimed forever.
```

---

## Implementation Phases

### Phase 0.5: GoalType → ProgressMode Migration + Inc Extraction (3-4 days)

**Prerequisite for all other M5 phases.** This phase replaces the legacy `GoalType` system with `ProgressMode` and adds `Inc` field extraction from AGS events.

- [x] Add `ProgressMode` field to `Requirement` struct in `extend-challenge-common/pkg/domain/models.go`
- [x] Remove `GoalType` enum, `Goal.Type` field, and `Goal.Daily` field
- [x] Update config JSON schema: replace `type`/`daily` with `requirement.progress_mode`
- [x] Update config loader and validator to parse `progress_mode`
- [x] Update `challenges.json` config files (convert all goals)
- [x] Refactor `EventProcessor.ProcessEvent()`: replace 3-way `GoalType` switch with `ProgressMode` switch
- [x] Remove `processIncrementGoal()` and `processDailyGoal()` — unified into single path
- [x] Extract `Inc` field from AGS statistic events (`msg.Payload.Inc` → `incValue`)
- [x] Synthesize `incValue=1` for login events
- [x] Update `ProcessEvent()` signature to pass both `statValue` and `incValue`
- [x] Update all unit tests (~34 files affected)
- [x] Run linter: `golangci-lint run ./...`

### Phase 1: Database Schema (0.5 day)

> **Rationale:** The `baseline_value` column must exist before the Unified COPY Path can reference it in SQL CASE expressions.

- [x] Add `baseline_value INT NULL` column to existing migration (`extend-challenge-service/migrations/001_create_user_goal_progress.up.sql`)
- [x] Update `UserGoalProgress` struct in domain models with `BaselineValue` field
- [x] No new migration file needed (update existing)

### Phase 2: Unified COPY Path (1.5 days)

Replace the dual-buffer architecture with a single unified buffer and COPY flush.

- [x] Replace 3 buffer maps (`buffer`, `bufferIncrement`, `bufferIncrementDaily`) with single unified buffer
- [x] Remove `IncrementProgress()` method from `BufferedRepository`
- [x] Remove `BatchIncrementProgress()` (UNNEST path) from `GoalRepository`
- [x] Update `UpdateProgress()` to accept `incValue` alongside progress
- [x] Update `BatchUpsertProgressWithCOPY()` to include `inc_value` and `progress_mode` columns
- [x] Handle NULL progress in COPY (login events: progress=NULL, inc_value=1)
- [x] Remove `startDailyBufferCleanup()` goroutine (no longer needed)
- [x] Update unit tests for new buffer structure
- [x] Run linter: `golangci-lint run ./...`

### Phase 3: Config Schema (0.5 day)

- [x] Add `rotation` config block to Goal struct
- [x] Add rotation config validation (schedule values, on_expiry fields)
- [x] Validate `rotation.enabled=true` requires `progress_mode="relative"` (reject absolute goals with rotation)
- [x] Update config cache to include rotation metadata
- [x] Update `challenges.json` with rotation config for daily/weekly goals

### Phase 4: Rotation Detection Utilities (1 day)

- [ ] Implement `CalculateLastRotationBoundary()` (global only)
- [ ] Implement `CalculateNextRotationBoundary()` (global only)
- [ ] Implement `CalculateNextExpiresAt()` (global only)
- [ ] Implement `HasRotationOccurred()` (global only)
- [ ] Implement `ApplyRotationReset()`
- [ ] Add to shared package (`extend-challenge-common`)
- [ ] Unit tests for boundary calculation utilities in isolation (daily, weekly, monthly schedules)

### Phase 5: SQL CASE Rotation (1.5 days)

Port the SQL CASE rotation logic from benchmarks to production code.

- [ ] Extend temp table with M5 metadata columns (`progress_mode`, `inc_value`, `target_value`, `rotation_boundary`, `new_expires_at`, `allow_reselection`)
- [ ] Implement event enrichment from config cache (compute rotation boundary + next expiry)
- [ ] Implement SQL CASE UPDATE statement (port from `bench_3_sql_rotation_test.go`)
- [ ] Add `allow_reselection` support: temp table column, WHERE clause, CASE branches for claimed+stale reset
- [ ] Handle NULL progress in SQL CASE (`COALESCE(temp.progress, ugp.progress + temp.inc_value)`)
- [ ] Adapt verify tests from `tests/benchmarks/verify_test.go` to production code
- [ ] Unit tests for event enrichment logic

### Phase 6: API Handler Updates (2 days)

- [ ] Add lazy rotation detection to POST /initialize (returning players)
- [ ] Add lazy rotation detection to GET /challenges
- [ ] Add lazy rotation detection to GET /challenges/{id}
- [ ] Add lazy rotation detection to POST /claim (reject if goal rotated since completion; allow if `allow_reselection=true`)
- [ ] Implement `calculateDisplayedProgress()` utility (returns `progress - baseline` for relative, raw `progress` for absolute)
- [ ] Update response with `expires_at` and `expires_in_seconds`
- [ ] Add rotation status endpoint (`GET /v1/challenges/{id}/rotation`)
- [ ] Batch update for rotated rows in Initialize endpoint (`BatchInsertProgress` for new, `BatchUpdateProgress` for rotated)
- [ ] Update optimized HTTP handler for GET /challenges (feature parity with gRPC handler)

### Phase 7: Testing + Benchmark Updates (1.5 days)

- [ ] Integration tests for rotation boundary calculations in full event + API flow
- [ ] Unit tests for lazy rotation detection
- [ ] Unit tests for baseline initialization
- [ ] Integration tests for full rotation flow
- [ ] E2E tests: daily challenge completion across rotation
- [x] Add `allow_reselection` branches to benchmark SQL in `bench_3_sql_rotation_test.go`
- [x] Add verify tests for `allow_reselection` scenarios
- [ ] Run full linter and coverage check: target ≥ 80%

### Phase 8: Documentation Updates (1.5 days)

Update existing documentation to reflect all M5 changes. No new document files — bring existing specs in sync with ProgressMode, rotation config, unified buffer, SQL CASE rotation, and new API fields.

> **Two audiences:** Game-developer-facing docs (how to use — prioritized first) and internal/operational docs (how it works).

#### 8A: Game-Developer-Facing Docs

**`docs/TECH_SPEC_CONFIGURATION.md`** (~18 GoalType refs to replace):
- [ ] Replace "Goal Types" section with "Progress Modes" (`absolute`/`relative`), remove `type` and `daily` fields from schema
- [ ] Add `rotation` config block schema: `enabled`, `type`, `schedule`, `on_expiry.reset_progress`, `on_expiry.allow_reselection`
- [ ] Add complete config examples: daily rotating goal, weekly rotating goal, monthly rotating goal, non-rotating absolute goal
- [ ] Add "GoalType to ProgressMode Migration" section with before/after config for each old type
- [ ] Update config validation rules for `progress_mode` enum and `rotation` block constraints

**`docs/TECH_SPEC_API.md`**:
- [ ] Add `expires_at` and `expires_in_seconds` fields to all goal response schema examples
- [ ] Document rotation status endpoint: `GET /v1/challenges/{challenge_id}/rotation`
- [ ] Update Initialize endpoint: document lazy rotation detection for returning players
- [ ] Update GET /challenges: document in-memory rotation display (read-only, no DB writes)
- [ ] Finalize Client Integration Requirements section (M5 placeholders already at lines 93-104)
- [ ] Add "Rotation Behavior for Clients" section: `expires_at` handling, UI countdown, polling strategy

**`docs/TECH_SPEC_EVENT_PROCESSING.md`** (~26 GoalType refs to replace):
- [ ] Replace "Goal Type Routing" section with "Progress Mode Handling" (2-way switch replaces 3-way)
- [ ] Document unified COPY path replacing dual buffer architecture (3 buffer maps → 1 `BufferedEvent` map)
- [ ] Document SQL CASE rotation logic in batch UPDATE (summary from TECH_SPEC_M5.md §Event Processing Changes)
- [ ] Document `Inc` field extraction from AGS events (`msg.Payload.Inc`) and synthetic `incValue=1` for logins
- [ ] Document baseline initialization via SQL CASE (`baseline = progress - inc_value`)
- [ ] Remove references to `IncrementProgress()`, `BatchIncrementProgress()`, UNNEST flush path, `bufferIncrement`/`bufferIncrementDaily`

#### 8B: Internal/Operational Docs

**`docs/TECH_SPEC_DATABASE.md`** (~3 GoalType refs):
- [ ] Add `baseline_value INT NULL` column to schema and Column Descriptions table
- [ ] Update full CREATE TABLE listing to match post-M5 schema
- [ ] Add note on SQL CASE patterns used in event processing (reference TECH_SPEC_M5.md)

**`docs/TECH_SPEC_TESTING.md`** (~19 GoalType refs):
- [ ] Update test fixtures and examples to use `progress_mode` instead of GoalType
- [ ] Add rotation test scenarios (daily rotation, baseline reset, allow_reselection)

**`docs/TECH_SPEC_OBSERVABILITY.md`** (~2 GoalType refs):
- [ ] Update metric labels and log field references from GoalType to ProgressMode

**`docs/STATUS.md`**:
- [ ] Update current phase to M5, add M4 completion summary

**`docs/MILESTONES.md`**:
- [ ] Update M4 status to Complete, M5 status to current state

**`docs/INDEX.md`**:
- [ ] Add TECH_SPEC_M5.md entry, update version header

**`README.md`** (project root):
- [ ] Update feature list: replace "3 Goal Types" with "2 Progress Modes", add rotation features
- [ ] Update current release label to M5

**`CLAUDE.md`** (project root):
- [ ] Update Core Data Model schema example with `baseline_value` column
- [ ] Update GoalType references to ProgressMode in project description

#### 8C: Verification

- [ ] Grep all docs for stale references: `GoalType`, `type: "increment"`, `type: "daily"`, `daily: true/false`
- [ ] Cross-check config JSON examples across docs for consistency
- [ ] Update TECH_SPEC_M5.md status from "Draft" to "Complete"
- [ ] Verify all cross-document links resolve

**Total: ~13.5-14.5 days**

> **Note:** No background scheduler phase needed! Rotation is handled lazily in all API endpoints and event handlers.

---

## Design Decisions

Decisions made during M5 planning:

### ~~1. Baseline Initialization Strategy~~ ❌ SUPERSEDED

**Original Decision:** Initialize baseline in `/initialize` endpoint via AGS API call

**Superseded by:** [Q6: Baseline Initialization](#q6-baseline-initialization--ags-api-call--resolved)

**Reason:** Benchmark results showed that baseline can be derived from the first stat event via SQL CASE (`baseline = progress - inc_value`). No AGS API call is needed. This eliminates 50-200ms latency per stat code and removes an external failure mode. The SQL handles both first-event initialization and rotation-triggered baseline reset in the same CASE expression. Verified by `TestSQLRotation_FirstEventInitializesBaseline`.

### 2. ~~Redis for Distributed Lock~~ ❌ SUPERSEDED

**Original Decision:** Use Redis for distributed lock during rotation

**Superseded by:** Decision #6 (Truly Lazy Rotation)

**Reason:** With lazy rotation, there is no background scheduler that needs coordination across instances. Each request independently detects and handles rotation for its own user's goals. No distributed lock needed.

### 3. ~~Scheduler Location~~ ❌ SUPERSEDED

**Original Decision:** Rotation scheduler runs in Challenge Service

**Superseded by:** Decision #6 (Truly Lazy Rotation)

**Reason:** No background scheduler is needed for rotation. Rotation is detected lazily in API handlers and event processors. This eliminates:
- Scheduler goroutine complexity
- Distributed lock requirements
- Bulk UPDATE operations at rotation time

### 4. Timezone Handling ✅ DECIDED

**Decision:** UTC only (for now)

**Rationale:**
- Simplicity and consistency
- Most games use server time anyway
- Can add timezone support in future if needed

### 5. Mid-Rotation Config Changes ✅ DECIDED

**Decision:** Config changes apply at next rotation only

**Rationale:**
- Prevents inconsistency during active rotation
- Players complete current rotation with original rules
- New config takes effect when rotation triggers

### 6. Truly Lazy Rotation ✅ DECIDED

**Decision:** Zero database updates during rotation. Detect rotation lazily in API handlers and event processors.

**Problem with Bulk Updates:**
With 100K users × 100 goals = 10 million rows to update at rotation time. Even setting `baseline_value = NULL` requires updating every row, which is not scalable.

**Solution: Compute Rotation State On-Demand**

Instead of updating rows during rotation:
1. **Rotation config lives in challenge/goal definition**
2. **Detect rotation lazily** when user accesses their goals
3. **Reset individual rows** only when that user triggers an event or API call

**Key Behaviors:**

| Behavior | Implementation |
|----------|----------------|
| **Global Rotation** | Compare `row.UpdatedAt` with schedule boundary (daily/weekly/monthly) |
| **Per-User Rotation** | *(M6)* Check if stored `row.ExpiresAt < now` |
| **Preserve Claimed (unless `allow_reselection=true`)** | Claimed goals are permanent unless `allow_reselection=true`, in which case they reset on rotation. Completed goals always reset. |
| **Respect Config** | Honor `on_expiry.reset_progress` setting |
| **Baseline from SQL CASE** | SQL CASE initializes baseline from first event: `baseline = progress - inc_value` (see Q6) |

**See:** [Core Rotation Detection Logic](#core-rotation-detection-logic) for full implementation.

**Rotation Behavior Summary:**

| Status | `reset_progress=true` | `reset_progress=false` |
|--------|----------------------|------------------------|
| `not_started` | Reset | Keep |
| `in_progress` | Reset to `not_started` | Keep progress |
| `completed` | **Reset** (new period) | **Keep completed** |
| `claimed` | **Reset** if `allow_reselection=true`, else **Skipped** | **Skipped** |

**Performance Comparison:**

| Approach | Rotation Cost | Per-User Cost | Scales To |
|----------|---------------|---------------|-----------|
| Bulk UPDATE | O(n) - 10M rows | O(1) | ~100K users |
| Truly Lazy | O(1) - zero DB | O(1) per user | Unlimited |

**Trade-offs:**
- ✅ Rotation is instant (zero database operations)
- ✅ Scales to any number of users
- ✅ No scheduler needed for rotation itself
- ⚠️ API handlers and event processors need rotation detection logic
- ⚠️ First access after rotation has slight overhead (one row update)
- ✅ **Compatible with stateless buffered write architecture** — SQL-side CASE rotation adds only 1.2x overhead ([benchmark results](#performance-benchmark-results))

### 7. GoalType Replaced by ProgressMode ✅ DECIDED

**Decision:** Replace the legacy `GoalType` (`absolute`/`increment`/`daily`) with `ProgressMode` (`absolute`/`relative`) as Phase 0.5 of M5.

**Rationale:**
- `GoalType` conflates progress tracking mode with event processing behavior
- `increment` type with `daily` flag overlaps conceptually with rotation (daily reset)
- `daily` type is just a special case of relative progress with target=1
- The 3-way switch in `EventProcessor` and dual flush paths in `BufferedRepository` add unnecessary complexity
- `ProgressMode` cleanly separates "how to calculate progress" from "when to reset"

**Impact:** ~34 files across all three packages. Migration mapping:
- `absolute` → `absolute` (direct)
- `increment` → `relative` (counter logic replaced by `inc_value`)
- `daily` → `relative` + rotation config (binary check becomes relative with target=1)

### 8. Per-User Rotation Deferred to M6 ✅ DECIDED

**Decision:** M5 implements **global rotation only**. Per-user rotation (independent countdown timers) is deferred to M6.

**Rationale:**
- The SQL CASE event path only handles global rotation boundaries (`CalculateLastRotationBoundary` based on schedule)
- Per-user rotation requires per-user `rotation_boundary` computation from stored `expires_at`, which is not implemented in the SQL CASE
- Adding per-user branches to the SQL CASE adds complexity without M5 use cases requiring it
- Global rotation covers the most common use cases: daily challenges, weekly challenges, seasonal events

**M6 Requirements:**
- SQL CASE branches for `expires_at`-based rotation detection
- API path support for per-user expiry display
- Config validation for `"type": "per_user"` with duration field

### 9. Batch SQL Paths Unified ✅ DECIDED

**Decision:** Unify the dual flush paths (COPY for absolute/daily, UNNEST for increment) into a single COPY+UPDATE path.

**Rationale:**
- Two separate flush paths with separate buffers add complexity
- The increment path (UNNEST) was designed for a different accumulation model that is superseded by `ProgressMode`
- A single COPY path with enhanced temp table columns (`progress_mode`, `inc_value`) handles all goal types
- NULL progress for login/increment events is handled by SQL CASE: `COALESCE(temp.progress, ugp.progress + temp.inc_value)`
- Removes ~200 lines of buffer management code (`bufferIncrement`, `bufferIncrementDaily`, `flushIncrementBuffer`, `startDailyBufferCleanup`)

### 10. Inc Field Extracted from AGS Events ✅ DECIDED

**Decision:** Extract the `Inc` field from AGS statistic events (`msg.Payload.Inc`) for use in baseline computation.

**Rationale:**
- The SQL CASE rotation logic requires `inc_value` to compute baseline: `baseline = progress - inc_value`
- The field is available in the AGS proto (`StatItem.Inc float64` at `statistic.pb.go:451`)
- Currently only `LatestValue` is extracted — `Inc` is ignored
- For login events, `inc_value=1` is synthetic (login events don't carry stat increments)

---

## Performance Benchmark Results

> **STATUS: ✅ RESOLVED** — Benchmarks run 2026-02-25 against 100K rows (10K users × 10 goals) on PostgreSQL 15. Source: `tests/benchmarks/`. All questions Q3-Q5 are now answered with hard data.
>
> **Note:** Benchmarks validate core SQL CASE patterns (rotation detection, baseline init, status computation, `reset_progress`, and `allow_reselection`). NULL progress (login event accumulation) paths are deferred to Phase 7 integration tests.

### Benchmark Summary

Five approaches were benchmarked at batch sizes of 100, 500, and 1,000 rows:

| Benchmark | Size 100 | Size 500 | Size 1,000 | vs Baseline |
|-----------|----------|----------|------------|-------------|
| **1. Blind UPSERT (baseline, M1-M4)** | **3.6ms** | **6.5ms** | **9.7ms** | **1.0x** |
| **3. SQL-Side Rotation (recommended)** | **4.8ms** | **8.3ms** | **12.0ms** | **1.2x** |
| 4. Batch Read + Write | 4.6ms | 8.6ms | 13.6ms | 1.4x |
| 2. Per-Event Read (naive M5) | 24.6ms | 111ms | 217ms | 22x |

**GET /v1/challenges** (single user, 10 goals):

| Variant | Latency | Difference |
|---------|---------|------------|
| Pure Read (current M1-M4) | 248μs | — |
| Read + Compute rotation in-memory | 247μs | ~0μs |
| Read + Sync Writeback | 249μs | ~1μs |

### Q3: Event Handler — Blind Write → Read-Before-Write ✅ RESOLVED

**Answer: Use SQL-side CASE rotation (option a). Only 1.2x overhead.**

The SQL CASE approach encodes all rotation detection, baseline initialization, and status computation directly in the UPDATE statement's SET clause. The enhanced temp table carries metadata columns (`progress_mode`, `inc_value`, `target_value`, `rotation_boundary`, `new_expires_at`) that the event processor already knows from the in-memory config cache.

**Benchmark data (1,000 rows):**

| Approach | Latency | DB Reads | DB Writes | Overhead |
|----------|---------|----------|-----------|----------|
| Blind UPSERT (current) | 9.7ms | 0 | 1 | — |
| SQL-side rotation | 12.0ms | 0 | 1 | +2.3ms (1.2x) |
| Batch read + write | 13.6ms | 1 | 1 | +3.9ms (1.4x) |
| Per-event read | 217ms | 1,000 | 1 | +207ms (22x) |

**Rotation percentage does not matter:**

| Scenario (1,000 rows) | Latency | vs Baseline |
|------------------------|---------|-------------|
| 100% rotated | 11.8ms | 1.22x |
| 0% rotated | 11.4ms | 1.17x |
| 40% rotated (realistic daily) | 12.0ms | 1.23x |

The SQL CASE overhead is constant regardless of how many rows actually rotate. This is because PostgreSQL evaluates CASE expressions for all rows uniformly — there's no branching penalty.

**Decision: Option (a) — Push rotation logic into SQL.** The blind-write architecture is preserved. Zero application-level reads. The 1,000,000x DB load reduction is maintained.

**Key SQL pattern** (simplified — omits `allow_reselection` for clarity):
```sql
UPDATE bench_user_goal_progress AS ugp
SET
    progress = temp.progress,
    baseline_value = CASE
        WHEN temp.progress_mode = 'absolute' THEN ugp.baseline_value
        WHEN temp.progress_mode = 'relative'
             AND ugp.updated_at < temp.rotation_boundary
             AND ugp.status != 'claimed'
            THEN temp.progress - temp.inc_value
        WHEN temp.progress_mode = 'relative'
             AND ugp.baseline_value IS NULL
            THEN temp.progress - temp.inc_value
        ELSE ugp.baseline_value
    END,
    status = CASE
        WHEN ugp.status = 'claimed' THEN 'claimed'
        -- ... (rotation-aware completion checks)
    END,
    updated_at = NOW()
FROM temp_bench_rotation AS temp
WHERE ugp.user_id = temp.user_id AND ugp.goal_id = temp.goal_id
  AND ugp.is_active = true
  AND ugp.status != 'claimed'
```

Full implementation: `tests/benchmarks/bench_3_sql_rotation_test.go`

### Q4: Buffer Deduplication Across Rotation Boundaries ✅ RESOLVED

**Answer: Accept the edge case (option c). The SQL CASE makes it a non-issue.**

Since rotation detection now lives entirely in SQL (Q3 decision), the buffer never needs to know about rotation boundaries. The buffer continues to deduplicate by keeping only the latest `(user_id, goal_id)` entry — exactly as M1-M4.

**Why the cross-boundary scenario is safe:**
```
11:59 PM: event arrives, progress=163, inc=3 → buffered as {progress:163, inc:3}
12:01 AM: event arrives, progress=165, inc=2 → overwrites to {progress:165, inc:2}

On flush, SQL detects: updated_at < midnight → rotation needed
SQL computes: baseline = 165 - 2 = 163 ✅ correct
```

The `inc_value` from the *latest* event in the buffer is always the correct increment for that event, and SQL uses it to derive the new baseline. The only scenario where this could produce a slightly different baseline than processing events individually is if two events within the same 1-second flush window straddle midnight — the baseline would be derived from the latest event's `inc` rather than the first post-midnight event. At daily/weekly granularity with 1-second flush intervals, this is acceptable.

**Decision: Option (c) — Accept the edge case.** No buffer changes needed.

### Q5: GET /challenges — Read-Only vs Writeback ✅ RESOLVED

**Answer: Keep GET read-only, compute rotation in-memory (option a). Zero overhead.**

**Benchmark data (single user, 10 goals):**

| Variant | Latency | Memory |
|---------|---------|--------|
| Pure Read | 248μs | 5,200 B / 127 allocs |
| Read + Compute (no write) | 247μs | 5,200 B / 127 allocs |
| Read + Sync Writeback | 249μs | 5,200 B / 127 allocs |

Computing rotation state in-memory adds **zero measurable overhead** — the computation is trivial (compare `updated_at` against rotation boundary, subtract baseline from progress). Even the writeback variant adds only ~1μs because it updates at most 4-5 rows for a single user.

However, the writeback is unnecessary. The event handler's SQL CASE rotation (Q3) will persist the rotation reset on the next event. The GET endpoint just needs to *display* the rotated state correctly.

**Decision: Option (a) — GET stays read-only.** The handler:
1. Reads user's goals (existing SELECT)
2. For each relative goal where `updated_at < rotation_boundary`: display `progress=0`, `status=not_started`
3. Returns immediately — no DB writes

The DB catches up lazily when the next event arrives and triggers the SQL CASE rotation.

### Q6: Baseline Initialization — AGS API Call ✅ RESOLVED

**Answer: Set baseline from first event only (option a).**

The SQL CASE rotation logic already handles this:
```sql
WHEN temp.progress_mode = 'relative' AND ugp.baseline_value IS NULL
    THEN temp.progress - temp.inc_value  -- Initialize baseline from first event
```

When the first stat event arrives with `progress=153, inc=3`, the SQL computes `baseline = 153 - 3 = 150`. No AGS API call needed.

**Trade-off:** The user sees no progress until the first event fires. This is acceptable because:
- Daily/weekly goals reset frequently — the first event typically arrives within minutes
- The alternative (AGS API call) adds 50-200ms latency per stat code and introduces external failure modes
- Correctness verified by `TestSQLRotation_FirstEventInitializesBaseline` in `tests/benchmarks/verify_test.go`

**Decision: Option (a) — Derive baseline from first event.** No `/initialize` changes needed.

### Correctness Verification

Ten tests in `tests/benchmarks/verify_test.go` validate the SQL CASE approach:

| Test | Validates |
|------|-----------|
| `RotatedRowGetsNewBaseline` | Stale relative row gets baseline = progress - inc |
| `CompletedGoalRotated`   | Completed+stale goals reset baseline and status |
| `ClaimedGoalUntouched` | Claimed goals completely skipped by WHERE clause |
| `AbsoluteBaselineStaysNull` | Absolute mode never sets baseline_value |
| `FirstEventInitializesBaseline` | NULL baseline initialized from first event |
| `CrossApproachComparison` | SQL CASE matches app-side rotation logic |
| `CompletedGoalPreservedWhenResetProgressFalse` | `reset_progress=false` preserves completed status across rotation |
| `ClaimedGoalResetWithAllowReselection` | `allow_reselection=true` resets claimed goals on rotation |
| `InProgressPreservedWhenResetProgressFalse` | `reset_progress=false` preserves in-progress across rotation |
| `CompletedGoalRotatedExplicitResetProgress` | Explicit `reset_progress=true` resets completed goals |

### How to Reproduce

```bash
# Start postgres
docker-compose up -d postgres

# Run correctness tests
cd tests/benchmarks && go test -run=Test -v

# Run all benchmarks (5 iterations for benchstat)
cd tests/benchmarks && go test -bench=. -benchtime=5s -count=5 -benchmem

# Compare with benchstat
go test -bench=. -benchtime=5s -count=5 > results.txt
go run golang.org/x/perf/cmd/benchstat@latest results.txt
```

---

## Resolved Questions

### 1. Handling Multiple Stat Codes per Goal (Future)

If a goal tracks multiple stats (M6+), how do we handle baselines?
- Store multiple baselines?
- Track each stat separately?

**Current thinking:** Out of scope for M5. M5 only supports single stat per goal.

### ~~2. Rotation Failure Recovery~~ ✅ RESOLVED

~~What happens if rotation scheduler crashes mid-execution?~~

**Resolved by:** Decision #6 (Truly Lazy Rotation)

**Why this is no longer a concern:**
- No background scheduler exists that can crash
- Rotation is detected per-request, per-user
- If a request fails, the next request detects rotation again
- Inherently idempotent - no partial state to recover from

### ~~3. Event Handler: Blind Write → Read-Before-Write~~ ✅ RESOLVED

**Resolved by:** Benchmark results (2026-02-25). SQL-side CASE rotation adds only 1.2x overhead (12ms vs 9.7ms for 1,000 rows). Blind-write architecture preserved. See [Performance Benchmark Results](#performance-benchmark-results).

### ~~4. Buffer Deduplication Across Rotation Boundaries~~ ✅ RESOLVED

**Resolved by:** Q3 decision makes this moot. SQL handles rotation detection at write time, so the buffer doesn't need rotation awareness. Edge case at boundary crossing is acceptable (1s window, daily/weekly granularity). See [Q4 details](#q4-buffer-deduplication-across-rotation-boundaries--resolved).

### ~~5. GET /challenges Becomes a Write Endpoint~~ ✅ RESOLVED

**Resolved by:** Benchmark shows zero overhead for in-memory rotation computation (248μs vs 247μs). GET stays read-only. DB catches up lazily via event handler. See [Q5 details](#q5-get-challenges--read-only-vs-writeback--resolved).

### ~~6. Baseline Initialization Requires AGS API Call~~ ✅ RESOLVED

**Resolved by:** SQL CASE initializes baseline from first event (`baseline = progress - inc`). No AGS API call needed. Verified by `TestSQLRotation_FirstEventInitializesBaseline`. See [Q6 details](#q6-baseline-initialization--ags-api-call--resolved).

### 7. Per-User Rotation Scope ✅ RESOLVED

**Decision:** Per-user rotation deferred to M6. M5 implements global rotation only.

**Rationale:** The SQL CASE event path only handles global rotation boundaries. Per-user rotation requires per-user `rotation_boundary` computation from stored `expires_at`, which adds complexity without M5 use cases requiring it. See [Decision 8](#8-per-user-rotation-deferred-to-m6--decided).

### 8. GoalType Migration Strategy ✅ RESOLVED

**Decision:** Replace `GoalType` with `ProgressMode` as Phase 0.5 of M5 (prerequisite for all other phases).

**Rationale:** The legacy `GoalType` system (`absolute`/`increment`/`daily`) conflates progress tracking with event processing behavior. `ProgressMode` (`absolute`/`relative`) cleanly separates these concerns and eliminates the dual-buffer/dual-flush architecture. See [Decision 7](#7-goaltype-replaced-by-progressmode--decided) and [GoalType to ProgressMode Migration](#goaltype-to-progressmode-migration).

---

## References

- [MILESTONES.md](./MILESTONES.md) - M5 overview
- [TECH_SPEC_API.md](./TECH_SPEC_API.md) - API design and **Client Integration Requirements**
- [TECH_SPEC_M3.md](./TECH_SPEC_M3.md) - Goal activation control
- [TECH_SPEC_M4.md](./TECH_SPEC_M4.md) - Batch and random selection
- [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md) - Database schema

---

**Document Status:** Draft — Performance questions resolved, ready for implementation
**Last Updated:** 2026-02-25
