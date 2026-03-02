# M6 Technical Specification: Expired Row Cleanup

**Status:** Planned
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
| `SELECT` max query time | **55ms** | **4,163ms** | 75x worse |
| `UPDATE` max query time | **42ms** | **4,118ms** | 98x worse |
| `INSERT` max query time | **23ms** | **4,049ms** | 176x worse |
| `claim` endpoint p95 | **34.2ms** | **1,469ms** | 43x worse |
| `batch_select` endpoint p95 | **49.6ms** | **848ms** | 17x worse |
| `set_active` endpoint p95 | **48.9ms** | **1,116ms** | 23x worse |
| Dead tuples | **717** | **196,816** | 274x worse |

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
CREATE INDEX CONCURRENTLY idx_user_goal_progress_expires_at
ON user_goal_progress(expires_at)
WHERE expires_at IS NOT NULL;
```

| Property | Value |
|----------|-------|
| **Migration file** | `003_add_expired_cleanup_index.up.sql` |
| **Index type** | B-tree partial index |
| **Condition** | `WHERE expires_at IS NOT NULL` |
| **Size impact** | Small — only rotating goals have non-NULL `expires_at` |
| **Creation method** | `CONCURRENTLY` — no table lock during creation |

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

// DeleteExpiredRows deletes rows where expires_at < cutoff in batches.
// Returns the total number of rows deleted across all batches.
// Uses CTE + ctid for efficient batched deletes with LIMIT.
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
| `CLEANUP_INTERVAL` | int | `3600` | Seconds between cleanup cycles (default: 1 hour) |
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
        Interval:      time.Duration(common.GetEnvInt("CLEANUP_INTERVAL", 3600)) * time.Second,
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
-- Delete one batch of expired rows using CTE + ctid
WITH expired AS (
    SELECT ctid
    FROM user_goal_progress
    WHERE expires_at IS NOT NULL
      AND expires_at < $1  -- cutoff = NOW() - retention_period
    LIMIT $2               -- batch_size (default: 1000)
)
DELETE FROM user_goal_progress
WHERE ctid IN (SELECT ctid FROM expired);
```

| Property | Value | Rationale |
|----------|-------|-----------|
| **CTE + `ctid`** | Physical row ID | Avoids expensive subquery re-evaluation |
| **LIMIT** | 1,000 rows/batch | Keeps lock duration short (~5-10ms per batch) |
| **Pause between batches** | 50ms | Prevents sustained I/O pressure on concurrent queries |

### Cleanup Goroutine

```go
func StartCleanupGoroutine(ctx context.Context, repo GoalRepository, cfg CleanupConfig, logger *slog.Logger) {
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

func runCleanupCycle(ctx context.Context, repo GoalRepository, cfg CleanupConfig, logger *slog.Logger) {
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
            return
        }

        totalDeleted += deleted
        batchCount++

        if deleted < int64(cfg.BatchSize) {
            break // No more rows to delete
        }

        // Pause between batches to reduce I/O pressure
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
    cleanupCycleDuration.Observe(duration.Seconds())
    cleanupCyclesTotal.Inc()
}
```

### Integration Point

The cleanup goroutine is started in `extend-challenge-service/main.go` alongside the existing server setup, using the same `context.Context` for graceful shutdown:

```go
// In main.go, after repository initialization
cleanupCfg := cleanup.NewCleanupConfigFromEnv()
go cleanup.StartCleanupGoroutine(ctx, goalRepo, cleanupCfg, logger)
```

---

## GDPR User Deletion

M6 adds a `DeleteUserData` method to the `GoalRepository` interface for GDPR compliance:

```go
// DeleteUserData deletes all rows for a specific user.
func (r *PostgresGoalRepository) DeleteUserData(ctx context.Context, userID string) (int64, error) {
    result, err := r.db.Exec(ctx,
        "DELETE FROM user_goal_progress WHERE user_id = $1",
        userID,
    )
    if err != nil {
        return 0, fmt.Errorf("delete user data: %w", err)
    }

    return result.RowsAffected(), nil
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

| Aspect | Non-Partitioned | Hash-Partitioned (16) |
|--------|----------------|----------------------|
| **Index** | 1 global partial index | 16 local partial indexes (auto-created) |
| **DELETE scan** | Single index scan | Cross-partition scan (all 16 partitions) |
| **Batch performance** | ~11ms per 1,000 rows | ~31ms per 1,000 rows |
| **Acceptable?** | Yes | Yes — background hourly job, not latency-critical |

### Why Cross-Partition Scan Is Acceptable

The cleanup query filters by `expires_at` (not `user_id`), so it must scan all partitions. This is acceptable because:

1. **Background job**: Runs hourly, not in the request path
2. **Batched**: 1,000 rows per batch with 50ms pause — no lock contention
3. **Small index**: Only rotating goals have `expires_at IS NOT NULL`, so each partition's local index is small
4. **31ms per batch**: Well within the 50ms budget for a background operation

### GDPR `DeleteUserData` Is Partition-Optimal

Unlike cleanup, GDPR deletion includes `user_id`:
```sql
DELETE FROM user_goal_progress WHERE user_id = $1
```
This routes to a **single partition** — same performance as non-partitioned (~1ms).

---

## Implementation Phases

### Phase 1: Database Migration & Index (0.5 days)
- [ ] Create `003_add_expired_cleanup_index.up.sql` with partial index on `expires_at`
- [ ] Create `003_add_expired_cleanup_index.down.sql`
- [ ] Test migration runs cleanly on fresh DB and with existing data
- [ ] Verify index is used by EXPLAIN ANALYZE on cleanup query

### Phase 2: `GetEnvBool` Helper & Configuration (0.5 days)
- [ ] Add `GetEnvBool` to `extend-challenge-service/pkg/common/utils.go`
- [ ] Add unit tests for `GetEnvBool` (true/false/1/0/yes/no/empty/invalid)
- [ ] Create `CleanupConfig` struct and `NewCleanupConfigFromEnv()`
- [ ] Add unit tests for config defaults and overrides

### Phase 3: Repository Methods (1 day)
- [ ] Add `DeleteExpiredRows(ctx, cutoff, batchSize)` to `GoalRepository` interface
- [ ] Add `DeleteUserData(ctx, userID)` to `GoalRepository` interface
- [ ] Implement `DeleteExpiredRows` in `PostgresGoalRepository` using CTE + ctid
- [ ] Implement `DeleteUserData` in `PostgresGoalRepository`
- [ ] Add mock implementations for testing
- [ ] Write integration tests with testcontainers:
  - Insert rows with various `expires_at` values
  - Verify only rows past cutoff are deleted
  - Verify rows with `expires_at IS NULL` are never deleted
  - Verify batch size is respected (insert 2,500 rows, batch=1000, expect 3 batches)
  - Verify `DeleteUserData` deletes all rows for target user and no others

### Phase 4: Cleanup Goroutine (1 day)
- [ ] Implement `StartCleanupGoroutine` with ticker and context cancellation
- [ ] Implement `runCleanupCycle` with batched deletes and logging
- [ ] Add Prometheus metrics (see [Observability](#observability))
- [ ] Write unit tests with mock repository:
  - Verify cleanup is skipped when disabled
  - Verify cleanup calls `DeleteExpiredRows` with correct cutoff
  - Verify cleanup stops when `ctx` is cancelled
  - Verify cleanup logs error and increments counter on failure
  - Verify cleanup loops until `deleted < batchSize`

### Phase 5: Service Integration (0.5 days)
- [ ] Wire `CleanupConfig` in `main.go`
- [ ] Start cleanup goroutine with service context
- [ ] Verify graceful shutdown stops cleanup
- [ ] Add `CLEANUP_*` env vars to `.env.example` and `docker-compose.yml`

### Phase 6: Observability (0.5 days)
- [ ] Register Prometheus metrics
- [ ] Add structured logging for each cycle (total_deleted, batches, duration_ms, cutoff)
- [ ] Add error logging with context (batch number, total_deleted so far)
- [ ] Verify metrics appear in `/metrics` endpoint

### Phase 7: Documentation & Final Testing (1 day)
- [ ] Update `docs/STATUS.md`
- [ ] Run full test suite: `go test ./... -coverprofile=coverage.out`
- [ ] Verify coverage >= 80% for new packages
- [ ] Run linter: `golangci-lint run ./...`
- [ ] Run load test with cleanup enabled, verify no performance regression
- [ ] Run load test with 2x iterations to accumulate rows, verify cleanup keeps table size stable

**Total: ~6 days**

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

```go
var (
    cleanupRowsDeleted = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "challenge_cleanup_rows_deleted_total",
        Help: "Total number of expired rows deleted by cleanup",
    })

    cleanupCycleDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
        Name:    "challenge_cleanup_cycle_duration_seconds",
        Help:    "Duration of each cleanup cycle",
        Buckets: []float64{0.1, 0.5, 1, 5, 15, 30, 60},
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

### Decision 4: CTE + `ctid` for Batched Deletes

**Decision:** Use `WITH expired AS (SELECT ctid ... LIMIT N) DELETE WHERE ctid IN (...)`.

**Rationale:**
- `ctid` (physical tuple ID) avoids re-evaluating the WHERE clause in the DELETE
- More efficient than `DELETE ... WHERE ... LIMIT N` (which PostgreSQL does not support directly)
- The CTE identifies the batch, the DELETE executes it — clean separation
- Well-established PostgreSQL pattern for batched deletes

### Decision 5: No Distributed Lock

**Decision:** Do not use Redis or any distributed lock for cleanup.

**Rationale:**
- `DELETE FROM ... WHERE ctid IN (...)` is idempotent — if two replicas try to delete the same row, one succeeds and the other deletes 0 rows
- No data corruption risk from concurrent cleanup
- Simpler than M5's rotation scheduler (which needs a lock to prevent duplicate rotations)
- Worst case: slightly more DB queries (2-3 replicas each scanning for expired rows), but the partial index makes this cheap

### Decision 6: Hourly Default Interval

**Decision:** Default cleanup interval of 1 hour.

**Rationale:**
- Frequent enough to prevent significant accumulation between cycles
- Infrequent enough to avoid constant background I/O
- Each cycle is fast (< 15 seconds for 100K rows), so hourly is plenty
- Configurable via `CLEANUP_INTERVAL` for operators who want more/less aggressive cleanup

### Decision 7: 50ms Pause Between Batches

**Decision:** Sleep 50ms between each batch of 1,000 deletes.

**Rationale:**
- Prevents sustained write I/O from starving concurrent API queries
- At 1,000 rows per batch with 50ms pause: ~70 rows/ms throughput
- 10K rows cleaned in ~2 seconds (10 × (20ms query + 50ms pause))
- Load test evidence shows even 20ms query bursts can cause p95 spikes if sustained — the pause gives VACUUM and API queries breathing room

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

**Document Status:** Planned — Ready for implementation
