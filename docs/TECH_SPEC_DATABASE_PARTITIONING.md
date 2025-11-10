# Database Partitioning Strategy

**Document Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

## Overview

This document analyzes the current database schema's readiness for partitioning and provides a migration path for scaling to larger user bases and challenge counts.

---

## Current Design Analysis

### Schema Characteristics

```sql
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,      -- Natural partition key
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    ...
    PRIMARY KEY (user_id, goal_id),     -- Partition key is first column ✅
);

CREATE INDEX idx_user_goal_progress_user_challenge
ON user_goal_progress(user_id, challenge_id);  -- Partition key is first column ✅
```

### Query Patterns

All queries include `user_id`:

```sql
-- UPSERT (event processing)
WHERE user_id = $1 AND goal_id = $2  ✅

-- Get user progress for challenge (API)
WHERE user_id = $1 AND challenge_id = $2  ✅

-- Get all user progress (API)
WHERE user_id = $1  ✅

-- Claim flow
WHERE user_id = $1 AND goal_id = $2  ✅
```

### Partition-Readiness Score: 9/10

✅ **Strengths:**
- Natural partition key (`user_id`) present in all queries
- Primary key includes partition key as first column
- Index includes partition key as first column
- No cross-user queries (data is user-scoped)
- No foreign keys to complicate partitioning
- Lazy initialization (only active users have rows)

⚠️ **Minor Considerations:**
- Namespace column exists but not needed for partitioning (single namespace per deployment)

---

## Partitioning Strategy

### Option 1: Hash Partitioning (Recommended)

**Strategy:** Distribute users evenly across partitions using hash function

```sql
-- PostgreSQL 10+ declarative partitioning
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    namespace VARCHAR(100) NOT NULL,
    progress INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'not_started',
    completed_at TIMESTAMP NULL,
    claimed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, goal_id),

    CONSTRAINT check_status CHECK (status IN ('not_started', 'in_progress', 'completed', 'claimed')),
    CONSTRAINT check_progress_non_negative CHECK (progress >= 0),
    CONSTRAINT check_claimed_implies_completed CHECK (claimed_at IS NULL OR completed_at IS NOT NULL)
) PARTITION BY HASH (user_id);

-- Create 16 partitions (good starting point)
CREATE TABLE user_goal_progress_p0 PARTITION OF user_goal_progress
    FOR VALUES WITH (MODULUS 16, REMAINDER 0);

CREATE TABLE user_goal_progress_p1 PARTITION OF user_goal_progress
    FOR VALUES WITH (MODULUS 16, REMAINDER 1);

-- ... repeat for p2 through p15
```

**Pros:**
- Even distribution of data across partitions
- No hot partitions
- Simple to implement
- Scales horizontally

**Cons:**
- Cannot easily move partition to different physical database
- Harder to archive old data (data mixed across partitions)

**When to Use:**
- User base grows beyond 10M users
- Write throughput exceeds single table capacity (>10K writes/sec)
- Need to distribute I/O load

---

### Option 2: Range Partitioning

**Strategy:** Partition by user ID ranges (if IDs are sequential)

```sql
CREATE TABLE user_goal_progress (
    ...
) PARTITION BY RANGE (user_id);

CREATE TABLE user_goal_progress_p0 PARTITION OF user_goal_progress
    FOR VALUES FROM ('00000000') TO ('1fffffff');

CREATE TABLE user_goal_progress_p1 PARTITION OF user_goal_progress
    FOR VALUES FROM ('1fffffff') TO ('3fffffff');

-- ... continue for all ranges
```

**Pros:**
- Easy to add new partitions for new user ID ranges
- Can archive old user ranges
- Can move partitions to different physical storage

**Cons:**
- Risk of hot partitions if new users concentrated in one range
- Requires predictable user ID format

**When to Use:**
- User IDs are sequential or have meaningful ranges
- Need to archive/move old user data
- Different SLAs for different user tiers

---

### Option 3: List Partitioning

**Strategy:** Group specific users together (e.g., by shard ID, region, tier)

```sql
-- Requires adding a shard_id or region column
ALTER TABLE user_goal_progress ADD COLUMN shard_id INT;

CREATE TABLE user_goal_progress (
    ...
    shard_id INT NOT NULL,
) PARTITION BY LIST (shard_id);

CREATE TABLE user_goal_progress_shard0 PARTITION OF user_goal_progress
    FOR VALUES IN (0);

CREATE TABLE user_goal_progress_shard1 PARTITION OF user_goal_progress
    FOR VALUES IN (1);
```

**Pros:**
- Explicit control over partition assignment
- Can group related users (same region, same tier)
- Easy to move entire shard to different database

**Cons:**
- Requires additional column
- Manual shard assignment logic needed
- Risk of unbalanced partitions

**When to Use:**
- Multi-region deployment (partition by region)
- Different SLAs per user tier (VIP vs free)
- Need to move shards to separate databases

---

## Migration Path

### Phase 1: Preparation (No Downtime)

**Before partitioning, ensure:**

1. **Add partition key to all queries** (already done ✅)
   ```sql
   -- All queries include user_id
   WHERE user_id = $1 AND ...
   ```

2. **Verify primary key includes partition key** (already done ✅)
   ```sql
   PRIMARY KEY (user_id, goal_id)
   ```

3. **Verify indexes include partition key** (already done ✅)
   ```sql
   CREATE INDEX ... ON user_goal_progress(user_id, challenge_id)
   ```

4. **Test queries on partitioned test database**
   ```bash
   # Create test database with partitions
   # Run integration tests
   # Verify performance
   ```

### Phase 2: Create Partitioned Table (Scheduled Downtime)

**Option A: In-Place Migration (Recommended)**

Uses `pg_partman` extension for automated partition management:

```sql
-- Install pg_partman
CREATE EXTENSION pg_partman;

-- Create parent table with partitioning
CREATE TABLE user_goal_progress_new (
    -- Same schema as before
    ...
) PARTITION BY HASH (user_id);

-- Use pg_partman to create partitions
SELECT create_parent('public.user_goal_progress_new', 'user_id', 'partman', 'hash', p_premake := 16);

-- Copy data (can be done in batches with minimal downtime)
INSERT INTO user_goal_progress_new
SELECT * FROM user_goal_progress;

-- Swap tables atomically
BEGIN;
ALTER TABLE user_goal_progress RENAME TO user_goal_progress_old;
ALTER TABLE user_goal_progress_new RENAME TO user_goal_progress;
COMMIT;

-- Drop old table after verification
DROP TABLE user_goal_progress_old;
```

**Downtime:** ~5-10 minutes for table swap

**Option B: Blue-Green Migration (Zero Downtime)**

1. Create new partitioned database
2. Dual-write to both old and new databases
3. Backfill new database
4. Verify data consistency
5. Switch reads to new database
6. Stop writes to old database
7. Decommission old database

**Downtime:** 0 minutes (but more complex)

### Phase 3: Update Application Code (No Changes Needed)

**Good news:** Application code doesn't need changes because:
- All queries already include partition key
- PostgreSQL handles partition routing transparently
- Connection string remains the same

**Optional optimization:**
```go
// Add query hint for partition-aware query planner (PostgreSQL 11+)
// This is optional - PostgreSQL usually figures it out
db.Exec("SET enable_partition_pruning = on")
```

---

## Scaling Limits

### Current Single Table Limits

| Metric | Threshold | Note |
|--------|-----------|------|
| Rows | ~1B | PostgreSQL can handle, but performance degrades |
| Table Size | ~500 GB | Before vacuum/index performance issues |
| Write Throughput | ~10K writes/sec | Before contention issues |
| Index Size | ~100 GB | Before index scan slowdown |

**Calculation for 1M users × 1000 goals:**
- Max rows: 1B rows
- Row size: ~200 bytes
- Table size: ~200 GB
- Index size: ~50 GB

**Verdict:** Single table works for 1M users, partitioning needed beyond 10M users

### Partitioned Table Limits (16 Partitions)

| Metric | Threshold | Improvement |
|--------|-----------|-------------|
| Rows | ~16B | 16x improvement |
| Table Size | ~8 TB | 16x improvement |
| Write Throughput | ~160K writes/sec | 16x improvement |
| Index Size | ~1.6 TB | 16x improvement |

**Verdict:** 16 partitions supports 100M+ users comfortably

---

## Partition Management

### Adding New Partitions (Hash)

**When to add:** When partition size exceeds 50GB

```sql
-- Cannot add partitions to existing hash partitioning
-- Must recreate with more partitions (32, 64, etc.)

-- Migration path:
-- 1. Create new table with 32 partitions
-- 2. Copy data
-- 3. Swap tables
```

**Limitation:** Hash partitioning doesn't support dynamic partition addition

**Workaround:** Start with enough partitions (16-32) to cover expected growth

### Adding New Partitions (Range)

```sql
-- Easy to add new range partitions
CREATE TABLE user_goal_progress_p16 PARTITION OF user_goal_progress
    FOR VALUES FROM ('ffffffff') TO ('ffffffff');
```

### Partition Maintenance

```sql
-- View partition sizes
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE tablename LIKE 'user_goal_progress_p%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Vacuum partition
VACUUM ANALYZE user_goal_progress_p0;

-- Rebuild partition index
REINDEX TABLE user_goal_progress_p0;
```

---

## Performance Testing

### Benchmark Setup

**Test partitioned vs non-partitioned:**

```bash
# Setup
docker run -d --name postgres-test postgres:15
psql -h localhost -U postgres -c "CREATE DATABASE test_partitioned"
psql -h localhost -U postgres -c "CREATE DATABASE test_single"

# Load 100M rows into each
pgbench -i -s 1000 test_single
pgbench -i -s 1000 test_partitioned

# Benchmark queries
pgbench -T 60 -c 10 test_single
pgbench -T 60 -c 10 test_partitioned
```

### Expected Results

| Operation | Single Table | Partitioned (16) | Improvement |
|-----------|-------------|-----------------|-------------|
| INSERT | 10K/sec | 100K/sec | 10x |
| SELECT by PK | 5ms (p95) | 3ms (p95) | 1.6x |
| SELECT by user | 10ms (p95) | 5ms (p95) | 2x |
| UPDATE | 8ms (p95) | 4ms (p95) | 2x |

**Why improvement:**
- Smaller indexes per partition (faster scans)
- Less lock contention
- Parallel partition access
- Better vacuum performance

---

## Multi-Database Sharding

### When Single Database Isn't Enough

**Threshold:** >100M users or >10TB data

**Strategy:** Move partitions to separate physical databases

```
Database 1 (Shard 0): Partitions 0-7   (50M users)
Database 2 (Shard 1): Partitions 8-15  (50M users)
```

### Application Changes Required

```go
// Add shard router
type ShardRouter struct {
    shards map[int]*sql.DB
}

func (r *ShardRouter) GetShardForUser(userID string) *sql.DB {
    shardID := hash(userID) % len(r.shards)
    return r.shards[shardID]
}

// Usage in repository
func (repo *PostgresGoalRepository) GetProgress(userID, goalID string) (*UserGoalProgress, error) {
    db := repo.router.GetShardForUser(userID)
    // Execute query on correct shard
    return repo.queryProgress(db, userID, goalID)
}
```

**Complexity:** Medium - requires application-level shard routing

---

## Recommendations

### Current State (M1)

**Recommendation:** ✅ **Use single table**

**Rationale:**
- Supports 1M users comfortably
- Simpler operations
- No partitioning overhead
- Easier debugging

**When to revisit:** When reaching 10M users or 100GB table size

### Future State (10M+ users)

**Recommendation:** ✅ **Use hash partitioning (16 partitions)**

**Rationale:**
- Even data distribution
- 10x write throughput improvement
- Supports 100M+ users
- Minimal application changes (none if using PostgreSQL 10+)

**Migration effort:** 1-2 days (including testing)

### Far Future (100M+ users)

**Recommendation:** ✅ **Multi-database sharding**

**Rationale:**
- Horizontal scaling across databases
- Geographic distribution possible
- Supports unlimited users

**Migration effort:** 1-2 weeks (requires application changes)

---

## Conclusion

### Current Design Score: 9/10 for Partition-Readiness

The current database schema is **exceptionally well-designed for future partitioning**:

✅ **No schema changes needed** - partition key already optimal
✅ **No query changes needed** - all queries include partition key
✅ **No index changes needed** - indexes include partition key
✅ **No application code changes needed** - PostgreSQL handles routing

**Migration Path:**
1. **Today (M1)**: Single table - works perfectly for 1M users
2. **At 10M users**: Add hash partitioning (16 partitions) - 2 days effort
3. **At 100M users**: Multi-database sharding - 2 weeks effort

**Key Insight:** The decision to use `(user_id, goal_id)` as the primary key makes future partitioning trivial. This was an excellent architectural choice.

---

## References

- **PostgreSQL Partitioning Docs**: https://www.postgresql.org/docs/current/ddl-partitioning.html
- **pg_partman Extension**: https://github.com/pgpartman/pg_partman
- **Current Schema**: [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

**Document Status:** Reference - For future scaling considerations
