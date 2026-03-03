# M6 Technical Specification: Expired Row Cleanup

**Status:** Complete (Phases 1-6), Phase 7 (Load Testing) deferred
**Created:** 2026-03-02
**Dependencies:** M5 (Time-Based Rotation)

---

## Table of Contents

1. [Overview](#overview)
2. [Motivation: Load Test Evidence](#motivation-load-test-evidence)
3. [Database Changes](#database-changes)
4. [Configuration](#configuration)
5. [Cleanup Algorithm](#cleanup-algorithm)
6. [GDPR User Deletion](#gdpr-user-deletion)
7. [Partition Compatibility](#partition-compatibility)
8. [Implementation Phases](#implementation-phases)
9. [Testing Strategy](#testing-strategy)
10. [Performance Targets](#performance-targets)
11. [Design Decisions](#design-decisions)

---

## Overview

M6 adds a **background cleanup goroutine** inside `extend-challenge-service` that periodically deletes expired rows from the `user_goal_progress` table. Without cleanup, rotating goals accumulate rows indefinitely, degrading database performance over time.

### Core Concepts

| Concept | Description |
|---------|-------------|
| **Expired Row** | A row where `expires_at IS NOT NULL AND expires_at < NOW() - retention_period` |
| **Retention Period** | Grace period (default 7 days) before expired rows are deleted |
| **Batch DELETE** | Rows are deleted in small batches (1,000/batch) to avoid long locks |
| **Cleanup Cycle** | One full pass of batched deletes until no more rows match |
| **Idempotent DELETE** | Multiple replicas can run cleanup concurrently without conflicts |

### What M6 Does NOT Include

- **Per-user rotation** (deferred to M7)
- **Historical progress archival** (backlog item)
- **External cron jobs** — cleanup runs as a goroutine inside the service

---

## Motivation: Load Test Evidence

Load testing on the M5-Rotation branch proved that accumulated rows cause severe performance degradation:

### Three-Way Performance Comparison

| Metric | Clean DB (565K rows) | Dirty DB (1.1M rows) | Degradation |
|--------|---------------------|---------------------|-------------|
| `SELECT` max query time | **55ms** | **4,163ms** | 75x higher latency |
| `UPDATE` max query time | **42ms** | **4,118ms** | 98x higher latency |
| `INSERT` max query time | **23ms** | **4,049ms** | 176x higher latency |
| `claim` endpoint p95 | **34.2ms** | **1,469ms** | 43x higher latency |
| `batch_select` endpoint p95 | **49.6ms** | **848ms** | 17x higher latency |
| `set_active` endpoint p95 | **48.9ms** | **1,116ms** | 23x higher latency |
| Dead tuples | **717** | **196,816** | 274x more |

> **Source:** Load test results from `tests/loadtest/results/smoke_post_optimization_20260302_112944/ANALYSIS.md` (dirty) and `tests/loadtest/results/smoke_clean_post_optimization_20260302_114513/ANALYSIS.md` (clean).

### Root Cause

The `user_goal_progress` table grows without bound because:
1. **Rotating goals create new rows** on every rotation boundary
2. **Expired rows are never deleted** — they remain with `expires_at < NOW()`
3. **Dead tuples accumulate** from UPSERTs on expired rows, increasing VACUUM pressure
4. **Index bloat** slows all queries even when queries filter by `user_id`

### Why Cleanup Solves This

Deleting expired rows after a 7-day grace period:
- Keeps table size proportional to **active** goals only
- Eliminates dead tuple accumulation from expired row updates
- Reduces index size and improves scan performance
- Prevents the 75-176x query time degradation observed under load

---

## Database Changes

### New Partial Index

```sql
-- Migration: 003_add_expired_cleanup_index.up.sql
CREATE INDEX IF NOT EXISTS idx_user_goal_progress_expires_at
ON user_goal_progress(expires_at)
WHERE expires_at IS NOT NULL;
```

| Property | Value |
|----------|-------|
| **Migration file** | `003_add_expired_cleanup_index.up.sql` |
| **Index type** | B-tree partial index |
| **Condition** | `WHERE expires_at IS NOT NULL` |
| **Size impact** | Small — only rotating goals have non-NULL `expires_at` |
| **Creation method** | Regular `CREATE INDEX` — `golang-migrate` wraps migrations in a transaction, which forbids `CONCURRENTLY`. The partial index only covers rotating goals, so the table lock is brief and acceptable. |

> **Why 003?** Migration `002_add_baseline_value.up.sql` already exists for the M5 `baseline_value` column.

### Down Migration

```sql
-- Migration: 003_add_expired_cleanup_index.down.sql
DROP INDEX IF EXISTS idx_user_goal_progress_expires_at;
```

### New Repository Methods

Add to `GoalRepository` interface in `extend-challenge-common/pkg/repository/goal_repository.go`:

```go
// M6: Expired row cleanup

// DeleteExpiredRows deletes up to batchSize rows where expires_at < cutoff.
// Returns the number of rows deleted in this batch (up to batchSize).
// Caller loops until returned count < batchSize to drain all expired rows.
// Uses CTE with primary key for partition-safe batched deletes with LIMIT.
DeleteExpiredRows(ctx context.Context, cutoff time.Time, batchSize int) (int64, error)

// M6: GDPR user data deletion

// DeleteUserData deletes all rows for a specific user.
// Partition-optimal: includes user_id which is the partition key.
DeleteUserData(ctx context.Context, userID string) (int64, error)
```

---

## Configuration

### Environment Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `CLEANUP_ENABLED` | bool | `true` | Enable/disable the cleanup goroutine |
| `CLEANUP_INTERVAL_MINUTES` | int | `60` | Minutes between cleanup cycles (default: 1 hour) |
| `CLEANUP_RETENTION_DAYS` | int | `7` | Days after expiry before rows are deleted |
| `CLEANUP_BATCH_SIZE` | int | `1000` | Rows deleted per batch |

### Helper Function: `GetEnvBool`

The existing `extend-challenge-service/pkg/common/utils.go` has `GetEnv` (string) and `GetEnvInt` (int) but no boolean helper. M6 adds:

```go
// GetEnvBool returns the boolean value of an environment variable,
// or the fallback if not set or unparseable.
// Truthy values: "true", "1", "yes" (case-insensitive).
func GetEnvBool(key string, fallback bool) bool {
    str := GetEnv(key, "")
    if str == "" {
        return fallback
    }

    switch strings.ToLower(str) {
    case "true", "1", "yes":
        return true
    case "false", "0", "no":
        return false
    default:
        return fallback
    }
}
```

### Configuration Struct

**Package:** `extend-challenge-service/pkg/cleanup/config.go`

The cleanup config, goroutine, and Prometheus metrics all live in `extend-challenge-service/pkg/cleanup/` because they are service-specific concerns (goroutine lifecycle, env var loading, metrics registration). The repository methods (`DeleteExpiredRows`, `DeleteUserData`) live in `extend-challenge-common` as part of the `GoalRepository` interface.

```go
// CleanupConfig holds configuration for the expired row cleanup goroutine.
type CleanupConfig struct {
    Enabled       bool
    Interval      time.Duration
    RetentionDays int
    BatchSize     int
}

func NewCleanupConfigFromEnv() CleanupConfig {
    return CleanupConfig{
        Enabled:       common.GetEnvBool("CLEANUP_ENABLED", true),
        Interval:      time.Duration(common.GetEnvInt("CLEANUP_INTERVAL_MINUTES", 60)) * time.Minute,
        RetentionDays: common.GetEnvInt("CLEANUP_RETENTION_DAYS", 7),
        BatchSize:     common.GetEnvInt("CLEANUP_BATCH_SIZE", 1000),
    }
}
```

---

## Cleanup Algorithm

### Deletion Rule

```sql
DELETE FROM user_goal_progress
WHERE expires_at IS NOT NULL
  AND expires_at < NOW() - INTERVAL '7 days';
```

**All rows matching the rule are deleted regardless of status.** No config-based or status-based filtering is needed because:
- `claimed` rows with expiry: player already got their reward, safe to delete
- `completed` rows with expiry: unclaimed after 7 days, forfeit
- `in_progress` / `not_started` rows with expiry: goal expired, no longer relevant
- Rows with `expires_at IS NULL` (permanent goals): never matched, never deleted

### Batched DELETE Query

```sql
-- Delete one batch of expired rows using CTE + USING join
WITH expired AS (
    SELECT user_id, goal_id
    FROM user_goal_progress
    WHERE expires_at IS NOT NULL
      AND expires_at < $1  -- cutoff = NOW() - retention_period
    LIMIT $2               -- batch_size (default: 1000)
)
DELETE FROM user_goal_progress
USING expired
WHERE user_goal_progress.user_id = expired.user_id
  AND user_goal_progress.goal_id = expired.goal_id;
```

| Property | Value | Rationale |
|----------|-------|-----------|
| **CTE + USING join** | `(user_id, goal_id)` | Partition-safe — works with hash partitioning on `user_id` |
| **LIMIT** | 1,000 rows/batch | Keeps lock duration short (~5-10ms per batch) |
| **Pause between batches** | 50ms | Prevents sustained I/O pressure on concurrent queries |

### `DeleteExpiredRows` Implementation

**Package:** `extend-challenge-common/pkg/repository/postgres_goal_repository.go`

```go
// DeleteExpiredRows deletes up to batchSize rows where expires_at < cutoff.
// Returns the number of rows deleted in this batch (up to batchSize).
func (r *PostgresGoalRepository) DeleteExpiredRows(ctx context.Context, cutoff time.Time, batchSize int) (int64, error) {
    query := `
        WITH expired AS (
            SELECT user_id, goal_id
            FROM user_goal_progress
            WHERE expires_at IS NOT NULL
              AND expires_at < $1
            LIMIT $2
        )
        DELETE FROM user_goal_progress
        USING expired
        WHERE user_goal_progress.user_id = expired.user_id
          AND user_goal_progress.goal_id = expired.goal_id`

    result, err := r.db.ExecContext(ctx, query, cutoff, batchSize)
    if err != nil {
        return 0, fmt.Errorf("delete expired rows: %w", err)
    }

    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return 0, fmt.Errorf("rows affected: %w", err)
    }

    return rowsAffected, nil
}
```

### Cleanup Goroutine

**Package:** `extend-challenge-service/pkg/cleanup/cleanup.go`

```go
// Cleaner is the minimal interface needed by the cleanup goroutine.
// PostgresGoalRepository satisfies this implicitly — no need for the full GoalRepository.
type Cleaner interface {
    DeleteExpiredRows(ctx context.Context, cutoff time.Time, batchSize int) (int64, error)
}

func StartCleanupGoroutine(ctx context.Context, repo Cleaner, cfg CleanupConfig, logger *slog.Logger) {
    if !cfg.Enabled {
        logger.Info("cleanup goroutine disabled")
        return
    }

    logger.Info("cleanup goroutine started",
        "interval", cfg.Interval,
        "retention_days", cfg.RetentionDays,
        "batch_size", cfg.BatchSize,
    )

    ticker := time.NewTicker(cfg.Interval)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            runCleanupCycle(ctx, repo, cfg, logger)
        case <-ctx.Done():
            logger.Info("cleanup goroutine stopped")
            return
        }
    }
}

func runCleanupCycle(ctx context.Context, repo Cleaner, cfg CleanupConfig, logger *slog.Logger) {
    cutoff := time.Now().Add(-time.Duration(cfg.RetentionDays) * 24 * time.Hour)
    totalDeleted := int64(0)
    batchCount := 0
    start := time.Now()

    for {
        deleted, err := repo.DeleteExpiredRows(ctx, cutoff, cfg.BatchSize)
        if err != nil {
            logger.Error("cleanup batch failed",
                "error", err,
                "batch", batchCount,
                "total_deleted", totalDeleted,
            )
            // Prometheus: increment error counter
            cleanupErrors.Inc()
            // Note: On error, we abandon the current cycle and wait for the next
            // ticker interval. For transient errors (e.g., connection blips), this
            // means waiting up to 1 hour. A short retry (e.g., 3 attempts with 30s
            // backoff) could be added if this proves too conservative in practice.
            return
        }

        totalDeleted += deleted
        batchCount++

        if deleted < int64(cfg.BatchSize) {
            break // No more rows to delete
        }

        // Pause between batches to avoid I/O starvation
        time.Sleep(50 * time.Millisecond)
    }

    duration := time.Since(start)
    logger.Info("cleanup cycle complete",
        "total_deleted", totalDeleted,
        "batches", batchCount,
        "duration_ms", duration.Milliseconds(),
        "cutoff", cutoff.Format(time.RFC3339),
    )

    // Prometheus metrics
    cleanupRowsDeleted.Add(float64(totalDeleted))
    cleanupDuration.Observe(duration.Seconds())
    cleanupCyclesTotal.Inc()
}
```

### Integration Point

The cleanup goroutine is started in `extend-challenge-service/main.go`. Key variables and insertion point:

| Reference | Variable | Type | Line |
|-----------|----------|------|------|
| Repository | `goalRepo` | `*PostgresGoalRepository` (satisfies `Cleaner`) | 233 |
| Logger | `slogLogger` | `*slog.Logger` | 196 |
| Context | `ctx` | from `context.WithCancel(context.Background())` | 80 |
| Prometheus registry | `prometheusRegistry` | `*prometheus.Registry` | 330 |
| Insert point | After `MustRegister(...)` block | Before metrics HTTP goroutine | 335→337 |

```go
// In main.go, after prometheusRegistry.MustRegister(...) block (line 335),
// before the metrics HTTP goroutine (line 337):
cleanupCfg := cleanup.NewCleanupConfigFromEnv()
prometheusRegistry.MustRegister(cleanup.Collectors()...)
go cleanup.StartCleanupGoroutine(ctx, goalRepo, cleanupCfg, slogLogger)
```

---

## GDPR User Deletion

M6 adds a `DeleteUserData` method to the `GoalRepository` interface for GDPR compliance:

```go
// DeleteUserData deletes all rows for a specific user.
func (r *PostgresGoalRepository) DeleteUserData(ctx context.Context, userID string) (int64, error) {
    result, err := r.db.ExecContext(ctx,
        "DELETE FROM user_goal_progress WHERE user_id = $1",
        userID,
    )
    if err != nil {
        return 0, fmt.Errorf("delete user data: %w", err)
    }

    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return 0, fmt.Errorf("rows affected: %w", err)
    }

    return rowsAffected, nil
}
```

| Property | Value |
|----------|-------|
| **Query** | `DELETE FROM user_goal_progress WHERE user_id = $1` |
| **Partition-optimal** | Yes — `user_id` is the partition key |
| **Performance** | Single-partition scan, ~1ms for typical user |
| **Exposure** | Not exposed via REST API in M6 (admin tool or future GDPR endpoint) |

---

## Partition Compatibility

The cleanup DELETE query is compatible with the planned hash partitioning strategy (see [TECH_SPEC_DATABASE_PARTITIONING.md](./TECH_SPEC_DATABASE_PARTITIONING.md)).

### How Cleanup Works With Hash Partitions

```
user_goal_progress (partitioned by HASH(user_id))
├── partition_p0  → local idx_expires_at (WHERE expires_at IS NOT NULL)
├── partition_p1  → local idx_expires_at (WHERE expires_at IS NOT NULL)
├── ...
└── partition_p15 → local idx_expires_at (WHERE expires_at IS NOT NULL)
```

The cleanup query uses the composite primary key `(user_id, goal_id)` in the DELETE, which is partition-safe: the CTE scans `expires_at` across all partitions to identify expired rows, and the DELETE routes each row to the correct partition via `user_id`.

| Aspect | Non-Partitioned | Hash-Partitioned (16) |
|--------|----------------|----------------------|
| **Index** | 1 global partial index | 16 local partial indexes (auto-created) |
| **DELETE scan** | Single index scan | Cross-partition scan (all 16 partitions) |
| **Batch performance** | ~11ms per 1,000 rows | **estimated** ~31ms per 1,000 rows (cross-partition scan of 16 small local indexes) |
| **Acceptable?** | Yes | Yes — background hourly job, not latency-critical |

### Why Cross-Partition Scan Is Acceptable

The cleanup query filters by `expires_at` (not `user_id`), so it must scan all partitions. This is acceptable because:

1. **Background job**: Runs hourly, not in the request path
2. **Batched**: 1,000 rows per batch with 50ms pause — no lock contention
3. **Small index**: Only rotating goals have `expires_at IS NOT NULL`, so each partition's local index is small
4. **~31ms per batch** (estimated): Well within the 50ms budget for a background operation

### GDPR `DeleteUserData` Is Partition-Optimal

Unlike cleanup, GDPR deletion includes `user_id`:
```sql
DELETE FROM user_goal_progress WHERE user_id = $1
```
This routes to a **single partition** — same performance as non-partitioned (~1ms).

---

## Implementation Phases

### Phase 1: Database Migration & Index (0.5 days)
- [x] Create `extend-challenge-service/migrations/003_add_expired_cleanup_index.up.sql` with partial index on `expires_at`
- [x] Create `extend-challenge-service/migrations/003_add_expired_cleanup_index.down.sql`
- [x] Test migration runs cleanly on fresh DB and with existing data
- [x] Verify index is used by EXPLAIN ANALYZE on cleanup query

### Phase 2: `GetEnvBool` Helper & Configuration (0.5 days)
- [x] Add `GetEnvBool` to `extend-challenge-service/pkg/common/utils.go`
- [x] Add unit tests for `GetEnvBool` (true/false/1/0/yes/no/empty/invalid)
- [x] Create `CleanupConfig` struct and `NewCleanupConfigFromEnv()`
- [x] Add unit tests for config defaults and overrides

### Phase 3: Repository Methods (1 day)
- [x] Add `DeleteExpiredRows(ctx, cutoff, batchSize)` to `GoalRepository` interface
- [x] Add `DeleteUserData(ctx, userID)` to `GoalRepository` interface
- [x] Implement `DeleteExpiredRows` in `PostgresGoalRepository` using CTE + primary key
- [x] Implement `DeleteUserData` in `PostgresGoalRepository`
- [x] Update all mock and implementation structs (adding `DeleteExpiredRows` and `DeleteUserData` stubs/implementations):

  **`MockGoalRepository` stubs (5 files) — add `DeleteExpiredRows` and `DeleteUserData` methods:**
  1. `extend-challenge-event-handler/pkg/buffered/buffered_repository_test.go` — `MockGoalRepository` at line 26 (uses `testify/mock`):
    ```go
    func (m *MockGoalRepository) DeleteExpiredRows(ctx context.Context, cutoff time.Time, batchSize int) (int64, error) {
        args := m.Called(ctx, cutoff, batchSize)
        return args.Get(0).(int64), args.Error(1)
    }

    func (m *MockGoalRepository) DeleteUserData(ctx context.Context, userID string) (int64, error) {
        args := m.Called(ctx, userID)
        return args.Get(0).(int64), args.Error(1)
    }
    ```
  2. `extend-challenge-service/tests/integration/setup_test.go` — `MockGoalRepository` at line 330: add same stubs
  3. `extend-challenge-service/pkg/server/challenge_service_server_test.go` — `MockGoalRepository` at line 73: add same stubs
  4. `extend-challenge-service/pkg/service/progress_query_test.go` — `MockGoalRepository` at line 68: add same stubs
  5. `extend-challenge-service/pkg/handler/optimized_challenges_handler_test.go` — `MockGoalRepository` at line 83: add same stubs

  **`PostgresTxRepository` implementation (1 file) — `TxRepository` embeds `GoalRepository`, so implementations are required:**
  6. `extend-challenge-common/pkg/repository/postgres_goal_repository.go` — `PostgresTxRepository` at line 1031: add `DeleteExpiredRows` and `DeleteUserData` methods delegating to `r.tx` (matching the pattern used by all other `GoalRepository` methods on this struct)

  **`MockTxRepository` stubs (2 files) — same reason as above:**
  7. `extend-challenge-service/pkg/server/challenge_service_server_test.go` — `MockTxGoalRepository` at line 175: add same stubs
  8. `extend-challenge-service/pkg/service/claim_test.go` — `MockTxRepository` at line 41: add same stubs
- [x] Write integration tests following the pattern in `extend-challenge-common/pkg/repository/postgres_goal_repository_test.go`:
  - Connect to Docker-compose test DB at `localhost:5433` (DSN: `postgres://testuser:testpass@localhost:5433/testdb?sslmode=disable`)
  - Use inline `setupTestDB()` with `CREATE TABLE IF NOT EXISTS` and `t.Skipf` on connection failure
  - Test cases:
    - Insert rows with various `expires_at` values, verify only rows past cutoff are deleted
    - Verify rows with `expires_at IS NULL` are never deleted
    - Verify batch size is respected (insert 2,500 rows, batch=1000, expect 3 batches)
    - Verify `DeleteUserData` deletes all rows for target user and no others

### Phase 4: Cleanup Goroutine & Observability (1.5 days)

Create all files in `extend-challenge-service/pkg/cleanup/`. Start with metrics (referenced by cleanup.go):

- [x] Create `pkg/cleanup/metrics.go` — Prometheus metrics vars and `Collectors()` function (see [Observability](#observability))
- [x] Create `pkg/cleanup/cleanup.go` — `Cleaner` interface, `StartCleanupGoroutine`, `runCleanupCycle` with metrics wired in
- [x] Add structured logging for each cycle (`total_deleted`, `batches`, `duration_ms`, `cutoff`)
- [x] Add error logging with context (`batch` number, `total_deleted` so far)
- [x] Verify metrics appear in `Collectors()` return value
- [x] Write unit tests with mock `Cleaner`:
  - Verify cleanup is skipped when `Enabled = false`
  - Verify cleanup calls `DeleteExpiredRows` with correct cutoff
  - Verify cleanup stops when `ctx` is cancelled
  - Verify cleanup logs error and increments `cleanupErrors` counter on failure
  - Verify cleanup loops until `deleted < batchSize`
  - Verify `Collectors()` returns all 4 metrics

### Phase 5: Service Integration (0.5 days)

Wire cleanup into `extend-challenge-service/main.go` using these exact variables:

| Reference | Variable | Type | Line |
|-----------|----------|------|------|
| Repository | `goalRepo` | `*PostgresGoalRepository` (satisfies `Cleaner`) | 233 |
| Logger | `slogLogger` | `*slog.Logger` | 196 |
| Context | `ctx` | from `context.WithCancel(context.Background())` | 80 |
| Prometheus registry | `prometheusRegistry` | `*prometheus.Registry` | 330 |
| Insert point | After `MustRegister(...)` block | Before metrics HTTP goroutine | 335→337 |

- [x] Add `"extend-challenge-service/pkg/cleanup"` to imports
- [x] Insert after `MustRegister(...)` block (line 335), before metrics HTTP goroutine (line 337):
  ```go
  cleanupCfg := cleanup.NewCleanupConfigFromEnv()
  prometheusRegistry.MustRegister(cleanup.Collectors()...)
  go cleanup.StartCleanupGoroutine(ctx, goalRepo, cleanupCfg, slogLogger)
  ```
- [x] Verify graceful shutdown stops cleanup (context cancellation propagates)
- [x] Add `CLEANUP_*` env vars to `.env.example` and to the `challenge-service` service's `environment:` section in `docker-compose.yml` (not the event handler — the cleanup goroutine only runs in the backend service)

### Phase 6: Documentation (0.5 days)

**Priority 1 — Must-do (blocks "M6 complete" claim):**
- [x] `docs/STATUS.md`:
  - Add row: `| M6 | Expired Row Cleanup | Complete | TECH_SPEC_M6.md |`
  - Update "Next Milestone" section to M7 or Backlog
- [x] `docs/MILESTONES.md`:
  - Update M6 status from "Planned" to "Complete"
  - Add features: background cleanup goroutine, GDPR `DeleteUserData`, partial index, Prometheus metrics
- [x] `docs/INDEX.md`:
  - Update version header from "M5" to "M6"
  - Add M6 section under Technical Specifications:
    ```
    ### M6: Expired Row Cleanup
    - [TECH_SPEC_M6.md](./TECH_SPEC_M6.md) — Cleanup goroutine, GDPR deletion, partial index
    ```

**Priority 2 — Should-do (improves cross-reference accuracy):**
- [x] `docs/TECH_SPEC_DATABASE.md`:
  - Add `003_add_expired_cleanup_index` to migrations list
  - Add `idx_user_goal_progress_expires_at` partial index to indexes section
  - Add `DeleteExpiredRows` (CTE + PK batch delete) and `DeleteUserData` to queries section
- [x] `docs/TECH_SPEC_OBSERVABILITY.md` — add cleanup metrics to catalog:

  | Metric | Type | Description |
  |--------|------|-------------|
  | `challenge_cleanup_rows_deleted_total` | Counter | Total expired rows deleted |
  | `challenge_cleanup_duration_seconds` | Histogram | Duration of each cleanup cycle |
  | `challenge_cleanup_cycles_total` | Counter | Total cleanup cycles executed |
  | `challenge_cleanup_errors_total` | Counter | Total cleanup cycle errors |

**Priority 3 — Nice-to-have:**
- [x] `README.md` — add feature bullet: "Automatic expired row cleanup with configurable retention"
- [x] `extend-challenge-service/README.md` — document `CLEANUP_*` environment variables
- [x] `extend-challenge-common/pkg/repository/README_TESTS.md` — add coverage for `DeleteExpiredRows` and `DeleteUserData`
- [x] `tests/loadtest/README.md` — add Scenario 6 section (see Phase 7)

**Verification:**
- [x] All doc links resolve (no broken cross-references)
- [x] `docs/INDEX.md` version header updated to M6

### Phase 7: Load Testing (1 day) — DEFERRED

> **Status:** NOT DONE — Deferred to a future session. Phases 1-6 (core implementation) are complete and verified by unit and integration tests. Load testing under sustained cleanup will be done when the next performance milestone is planned.

**Decision: Create new `scenario6_m6_cleanup.js`** (not update existing scenarios).

Rationale: One scenario per milestone (scenario4 → M4, scenario5 → M5). Cleanup testing has unique requirements (table size monitoring, background process validation) that don't fit existing scenarios.

**Template:** Use `tests/loadtest/k6/scenario5_m5_rotation.js` as starting point.

**Reusable from scenario5:**
- `SharedArray` for token/user fixtures (`../fixtures/tokens.json`, `../fixtures/users.json`)
- `__ENV.*` configuration pattern (`BASE_URL`, `EVENT_HANDLER_ADDR`, `TARGET_VUS`, etc.)
- API user session flow (`browse → select → progress → claim`)
- gRPC event sender pattern with per-VU connection state
- Per-endpoint threshold tagging (`tags: { endpoint: '...' }`)
- Helper functions: `createHeaders()`, `generateEventID()`, `randomBetween()`

**Unique to scenario6:**
- SQL seed script (`tests/loadtest/sql/seed_expired_rows.sql`): pre-populate 100K rows with `expires_at < NOW() - INTERVAL '7 days'`
- Table size monitor scenario: periodic `SELECT count(*) FROM user_goal_progress` to track row count convergence
- Prometheus metrics scraping: fetch `/metrics` endpoint to read `challenge_cleanup_rows_deleted_total`
- `CLEANUP_INTERVAL_MINUTES=1` env override in docker-compose for faster test observation

**k6 skeleton:**
```js
import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000/challenge';

export let options = {
  scenarios: {
    api_load: {
      executor: 'per-vu-iterations',
      vus: parseInt(__ENV.TARGET_VUS || '150'),
      iterations: parseInt(__ENV.ITERATIONS || '120'),
      maxDuration: '30m',
      exec: 'apiUserSession',  // Reuse scenario5 user flow
    },
    event_load: {
      executor: 'constant-arrival-rate',
      rate: parseInt(__ENV.TARGET_EPS || '500'),
      duration: '30m',
      preAllocatedVUs: 1000,
      exec: 'eventLoad',       // Reuse scenario5 event sender
    },
    table_monitor: {
      executor: 'constant-arrival-rate',
      rate: 1,                  // 1 check per second
      duration: '30m',
      preAllocatedVUs: 1,
      exec: 'monitorTableSize',
    },
  },
};

export function setup() {
  // Verify seed data: SELECT count(*) WHERE expires_at < NOW() - INTERVAL '7 days'
}

export function monitorTableSize() {
  // GET /metrics → parse challenge_cleanup_rows_deleted_total
}

export function teardown(data) {
  // Log final cleanup_rows_deleted_total, table row count
}
```

**Checklist:**
- [ ] Create `tests/loadtest/k6/scenario6_m6_cleanup.js` (use scenario5 as template)
- [ ] Create `tests/loadtest/sql/seed_expired_rows.sql` to pre-populate 100K expired rows
- [ ] Add Scenario 6 section to `tests/loadtest/README.md`
- [ ] Run full test suite: `go test ./... -coverprofile=coverage.out`, verify coverage >= 80%
- [ ] Run linter: `golangci-lint run ./...`
- [ ] Execute scenario6 with `CLEANUP_INTERVAL_MINUTES=1`, capture results
- [ ] Create `docs/M6_PERFORMANCE_RESULTS.md` with cleanup throughput and API latency impact
- [ ] Verify cleanup keeps table size stable (row count before vs after should converge)

**Success criteria for Scenario 6:**
- API p95 < 5% regression vs clean-DB baseline
- Cleanup throughput: 100K rows in < 60 seconds
- Table row count stabilizes (does not grow unbounded)
- Zero cleanup errors during 30-minute test
- `challenge_cleanup_rows_deleted_total` metric increases in `/metrics`

**Total: ~7 days**

---

## Testing Strategy

### Unit Tests

| Test | What It Verifies |
|------|-----------------|
| `GetEnvBool` edge cases | true/false/1/0/yes/no/empty/invalid/case-insensitive |
| `CleanupConfig` defaults | All defaults match documented values |
| `CleanupConfig` overrides | Env vars override defaults correctly |
| `runCleanupCycle` happy path | Calls `DeleteExpiredRows` in loop, logs summary |
| `runCleanupCycle` error handling | Logs error, increments Prometheus counter, returns |
| `runCleanupCycle` batching | Loops when `deleted == batchSize`, stops when `deleted < batchSize` |
| `StartCleanupGoroutine` disabled | Returns immediately when `Enabled = false` |
| `StartCleanupGoroutine` shutdown | Stops when context is cancelled |

### Integration Tests

| Test | What It Verifies |
|------|-----------------|
| `DeleteExpiredRows` basic | Deletes rows past cutoff, leaves others |
| `DeleteExpiredRows` null safety | Rows with `expires_at IS NULL` are never deleted |
| `DeleteExpiredRows` status agnostic | Deletes `claimed`, `completed`, `in_progress`, `not_started` equally |
| `DeleteExpiredRows` batch limit | Respects batch size (e.g., 2,500 rows with batch=1000 → 3 calls) |
| `DeleteExpiredRows` boundary | Row exactly at cutoff is deleted; row 1ms after cutoff is not |
| `DeleteUserData` isolation | Deletes all rows for target user, no rows for other users |
| `DeleteUserData` empty user | Returns 0 for user with no rows (no error) |
| Migration 003 | Index created, EXPLAIN shows index usage for cleanup query |

### Load Tests

| Test | What It Verifies |
|------|-----------------|
| Cleanup under load | API latency not degraded while cleanup runs |
| Accumulated data stability | Table size stays bounded after multiple rotation cycles with cleanup enabled |
| Cleanup throughput | 100K expired rows cleaned in < 60 seconds |

---

## Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| Batch DELETE latency | < 20ms per 1,000 rows | Comparable to batch UPSERT performance |
| Cleanup cycle (10K rows) | < 2 seconds | 10 batches × (20ms query + 50ms pause) |
| Cleanup cycle (100K rows) | < 15 seconds | 100 batches × (20ms + 50ms) + overhead |
| API latency impact | < 5% p95 increase | Background batches with 50ms pause between |
| Index size overhead | < 10 MB for 1M rows | Partial index (only non-NULL `expires_at`) |

---

## Observability

### Prometheus Metrics

**Package:** `extend-challenge-service/pkg/cleanup/metrics.go`

> **IMPORTANT:** `main.go` uses a **custom Prometheus registry** (`prometheus.NewRegistry()`), not the
> default global registry. Metrics created with `prometheus.NewCounter()` register on the **global**
> registry and will never appear on the `/metrics` endpoint. The cleanup package must **export** its
> collectors so `main.go` can register them on the custom registry.

```go
// Collectors returns all Prometheus collectors for registration with a custom registry.
// Call this from main.go: prometheusRegistry.MustRegister(cleanup.Collectors()...)
//
// Style note: An alternative pattern is Register(registry *prometheus.Registry) which
// encapsulates registration. We use Collectors() here to match the existing MustRegister(...)
// call pattern in main.go, keeping the registration site visible in one place.
func Collectors() []prometheus.Collector {
    return []prometheus.Collector{
        cleanupRowsDeleted,
        cleanupDuration,
        cleanupCyclesTotal,
        cleanupErrors,
    }
}

var (
    cleanupRowsDeleted = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "challenge_cleanup_rows_deleted_total",
        Help: "Total number of expired rows deleted by cleanup",
    })

    cleanupDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
        Name:    "challenge_cleanup_duration_seconds",
        Help:    "Duration of each cleanup cycle in seconds.",
        Buckets: prometheus.DefBuckets,
    })

    cleanupCyclesTotal = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "challenge_cleanup_cycles_total",
        Help: "Total number of cleanup cycles executed",
    })

    cleanupErrors = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "challenge_cleanup_errors_total",
        Help: "Total number of cleanup cycle errors",
    })
)
```

**Registration in `main.go`** — add cleanup collectors to the existing custom `prometheusRegistry` (line 330). Insert after the `MustRegister(...)` block (line 335), before the metrics HTTP goroutine (line 337):

```go
prometheusRegistry.MustRegister(cleanup.Collectors()...)
```

### Structured Logging

Each cleanup cycle logs:

```json
{
  "level": "INFO",
  "msg": "cleanup cycle complete",
  "total_deleted": 4523,
  "batches": 5,
  "duration_ms": 487,
  "cutoff": "2026-02-23T10:30:00Z"
}
```

Error logging includes context for debugging:

```json
{
  "level": "ERROR",
  "msg": "cleanup batch failed",
  "error": "connection refused",
  "batch": 3,
  "total_deleted": 2000
}
```

---

## Design Decisions

### Decision 1: Background Goroutine vs External Cron

**Decision:** Use a background goroutine inside `extend-challenge-service`.

**Rationale:**
- No additional infrastructure (no separate cron job, no Kubernetes CronJob)
- Lifecycle tied to the service (starts/stops with the service)
- Access to the same database connection pool
- Consistent with M5's rotation scheduler pattern (also a goroutine)

**Trade-off:** If the service has 3 replicas, all 3 run cleanup. This is acceptable because DELETE is idempotent — duplicate deletes are harmless (they find 0 rows).

### Decision 2: 7-Day Retention Period

**Decision:** Default to 7 days after `expires_at` before deletion.

**Rationale:**
- Gives operators time to investigate issues with expired goals
- Allows late reward claims to be debugged (even though claims fail after expiry)
- 7 days matches common log retention practices
- Configurable via `CLEANUP_RETENTION_DAYS` if operators want shorter/longer

### Decision 3: Delete All Statuses (No Status Filter)

**Decision:** Delete all rows matching `expires_at < cutoff` regardless of `status`.

**Rationale:**
- `claimed`: Reward already granted, row is bookkeeping — safe to delete
- `completed` but unclaimed: 7 days past expiry, player had their chance
- `in_progress` / `not_started`: Goal expired, no longer relevant
- Simplicity: One rule, no edge cases, no status-dependent logic
- If historical tracking is needed (backlog item 5), it should be an archive table, not keeping rows in the hot table

### Decision 4: CTE + Primary Key for Batched Deletes

**Decision:** Use `WITH expired AS (SELECT user_id, goal_id ... LIMIT N) DELETE ... USING expired WHERE ... = expired.*`.

**Rationale:**
- Uses the composite primary key `(user_id, goal_id)` for partition-safe batch identification
- More efficient than `DELETE ... WHERE ... LIMIT N` (which PostgreSQL does not support directly)
- The CTE identifies the batch, the DELETE executes it — clean separation
- Partition-safe: `user_id` is the hash partition key, so each DELETE routes to the correct partition
- Well-established PostgreSQL pattern for batched deletes

### Decision 5: No Distributed Lock

**Decision:** Do not use Redis or any distributed lock for cleanup.

**Rationale:**
- `DELETE FROM ... USING expired WHERE ...` is idempotent — if two replicas try to delete the same row, one succeeds and the other deletes 0 rows
- No data corruption risk from concurrent cleanup
- Simpler than M5's rotation scheduler (which needs a lock to prevent duplicate rotations)
- Worst case: slightly more DB queries (2-3 replicas each scanning for expired rows), but the partial index makes this cheap

### Decision 6: Hourly Default Interval

**Decision:** Default cleanup interval of 1 hour.

**Rationale:**
- Frequent enough to prevent significant accumulation between cycles
- Infrequent enough to avoid constant background I/O
- Each cycle is fast (< 15 seconds for 100K rows), so hourly is plenty
- Configurable via `CLEANUP_INTERVAL_MINUTES` for operators who want more/less aggressive cleanup

### Decision 7: 50ms Pause Between Batches

**Decision:** Sleep 50ms between each batch of 1,000 deletes.

**Rationale:**
- Prevents sustained write I/O from starving concurrent API queries
- At 1,000 rows per batch with 50ms pause: ~70 rows/ms throughput
- 10K rows cleaned in ~2 seconds (10 × (20ms query + 50ms pause))
- Load test evidence shows even 20ms query bursts can cause p95 spikes if sustained — the pause gives VACUUM and API queries breathing room

---

## Follow-Up: Interruptible Inter-Batch Sleep

The current implementation at `extend-challenge-service/pkg/cleanup/cleanup.go:69` uses `time.Sleep(50ms)` for the inter-batch pause. This is not interruptible during shutdown — if a cleanup cycle is mid-batch when the service receives a shutdown signal, it will block for up to 50ms before the goroutine checks `ctx.Done()`.

**Current code:**
```go
time.Sleep(50 * time.Millisecond)
```

**Recommended improvement:**
```go
select {
case <-ctx.Done():
    logger.Info("cleanup interrupted", "total_deleted", totalDeleted)
    return
case <-time.After(50 * time.Millisecond):
}
```

**Priority:** Low — 50ms is negligible for graceful shutdown. Address if shutdown latency requirements tighten.

---

## References

- **Load Test Evidence (Dirty DB):** [smoke_post_optimization ANALYSIS.md](../tests/loadtest/results/smoke_post_optimization_20260302_112944/ANALYSIS.md)
- **Load Test Evidence (Clean DB):** [smoke_clean_post_optimization ANALYSIS.md](../tests/loadtest/results/smoke_clean_post_optimization_20260302_114513/ANALYSIS.md)
- **Database Partitioning Strategy:** [TECH_SPEC_DATABASE_PARTITIONING.md](./TECH_SPEC_DATABASE_PARTITIONING.md)
- **M5 Rotation Spec:** [TECH_SPEC_M5.md](./TECH_SPEC_M5.md)
- **GoalRepository Interface:** `extend-challenge-common/pkg/repository/goal_repository.go`
- **Utility Helpers:** `extend-challenge-service/pkg/common/utils.go`
- **Milestones Roadmap:** [MILESTONES.md](./MILESTONES.md)

---

**Document Status:** Complete (Phases 1-6), Phase 7 (Load Testing) deferred
