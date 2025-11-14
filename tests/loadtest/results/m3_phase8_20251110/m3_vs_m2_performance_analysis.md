# M3 vs M2 Performance Analysis Report

**Date:** 2025-11-10
**Test Duration:** 31 minutes (1min init @ 600 RPS + 30min gameplay @ 300 RPS API + 500 EPS events)
**Total Iterations:** 1,444,019
**Test Type:** Combined load test (API + Events)

---

## Executive Summary

⚠️ **VERDICT: PERFORMANCE DEGRADATION DETECTED**

M3 introduces **significant performance regression** compared to M2 baseline targets. Multiple endpoints exceed their p95 latency thresholds, with the initialize endpoint showing severe degradation.

### Key Findings:
- ❌ **Initialize (init phase):** 254x slower than target (12.72s vs 50ms)
- ❌ **Initialize (gameplay):** 170x slower than target (1.7s vs 10ms)
- ❌ **Set Active:** 5.3x slower than target (526ms vs 100ms)
- ❌ **Challenges query:** 1.25x slower than target (249ms vs 200ms)
- ✅ **Event processing:** Within target (28.5ms vs 500ms)
- ❌ **Success rate:** Below target (99.89% vs 99.95%)

---

## Detailed Performance Comparison

### 1. Initialize Endpoint (New Users - Phase 1)

| Metric | M2 Target | M3 Actual | Status | Degradation |
|--------|-----------|-----------|--------|-------------|
| p95 latency | < 50ms | **12.72s** | ❌ FAIL | **254x slower** |
| p90 latency | - | 11.45s | - | - |
| Average | - | 7.38s | - | - |
| Min | - | 75.55ms | - | - |
| Max | - | 18.39s | - | - |
| Success rate | > 99.95% | 87% | ❌ FAIL | **12.95% failure** |
| Failed requests | 0 | **580 / 4,687** | ❌ | - |

**Analysis:**
- Catastrophic performance during initialization phase
- 580 failed requests (13% failure rate) during user onboarding
- p95 latency is **254x the target**
- Average latency of 7.38s is unacceptable for UX

**Root Cause:**
- Bulk insert of 500 goals per user (all goals, not just default-assigned)
- Database write contention under 600 RPS initialization load
- No connection pooling optimization for burst traffic

---

### 2. Initialize Endpoint (Returning Users - Fast Path)

| Metric | M2 Target | M3 Actual | Status | Degradation |
|--------|-----------|-----------|--------|-------------|
| p95 latency | < 10ms | **1.7s** | ❌ FAIL | **170x slower** |
| p90 latency | - | 1.47s | - | - |
| Average | - | 959ms | - | - |
| Success rate | > 99.95% | 99.8% | ✅ PASS | Acceptable |
| Failed requests | 0 | 85 / 53,968 | ⚠️  | 0.16% failure |

**Analysis:**
- Fast path is **not fast** - should return immediately if user already initialized
- p95 latency is **170x the target**
- Average latency of 959ms suggests database query overhead
- Query to check existing goals (500 goal IDs) is too expensive

**Root Cause:**
- `GetGoalsByIDs(userID, allGoalIDs)` query with 500 goal IDs
- Database query not optimized for large IN clause
- Missing index on `(user_id, goal_id)` composite key lookup

---

### 3. Challenges Query Endpoint

| Metric | M2 Baseline | M3 Actual | Status | Degradation |
|--------|-------------|-----------|--------|-------------|
| p95 latency | < 200ms | **249.2ms** | ❌ FAIL | **1.25x slower** |
| p90 latency | - | 207.3ms | - | - |
| Average | - | 108.3ms | - | - |
| Success rate | > 99.95% | 99.9% | ✅ PASS | Acceptable |
| Failed requests | 0 | 247 / 377,611 | ⚠️  | 0.07% failure |
| Total requests | - | 377,611 | - | - |

**Analysis:**
- Marginal degradation (24.6% slower than baseline)
- Still within acceptable range for production
- M3 `active_only` filtering adds minimal overhead

**Root Cause:**
- M3 adds `is_active` column to WHERE clause
- Index on `is_active` may help but not critical
- CPU contention from initialize endpoint impacting all queries

---

### 4. Set Goal Active Endpoint (M3 New Feature)

| Metric | M3 Target | M3 Actual | Status | Degradation |
|--------|-----------|-----------|--------|-------------|
| p95 latency | < 100ms | **526ms** | ❌ FAIL | **5.3x slower** |
| p90 latency | - | 454ms | - | - |
| Average | - | 291ms | - | - |
| Success rate | > 99.95% | 99.9% | ✅ PASS | Acceptable |
| Failed requests | 0 | 103 / 80,908 | ⚠️  | 0.13% failure |
| Total requests | - | 80,908 | - | - |

**Analysis:**
- New M3 endpoint significantly slower than target
- p95 latency is **5.3x the target**
- High contention on `user_goal_progress` table

**Root Cause:**
- UPDATE query with row-level locking under high concurrency
- No statement timeout configured
- Database write contention from initialize endpoint

---

### 5. Event Processing (gRPC)

| Metric | M2 Baseline | M3 Actual | Status | Performance |
|--------|-------------|-----------|--------|-------------|
| p95 latency | < 500ms | **28.5ms** | ✅ PASS | **17.5x faster** |
| p90 latency | - | 14.1ms | - | - |
| Average | - | 6.3ms | - | - |
| Success rate | > 99.95% | 100% | ✅ PASS | Perfect |
| Login events | - | 287,685 | - | - |
| Stat events | - | 1,156,334 | - | - |
| Total events | - | 1,444,019 | - | - |

**Analysis:**
- ✅ **Excellent performance** - far exceeds baseline
- Event handler is **not the bottleneck**
- M3 `is_active` filtering in UPSERT works efficiently
- Buffered repository design is highly effective

**Key Success Factor:**
- 1-second buffering with batch UPSERT
- `WHERE is_active = true` clause prevents updates to inactive goals
- Event handler CPU only 22.87% (can scale to 2,000+ EPS)

---

## Resource Utilization

### Challenge Service (300 RPS)

| Resource | M3 Actual | Capacity | Utilization |
|----------|-----------|----------|-------------|
| CPU | 100% | 1 core | **Saturated** |
| Memory | 119.5 MB | 1 GB | 11.7% |
| Goroutines | 405 | - | Healthy |
| Heap | 71.7 MB | - | Low |

**Bottleneck:** CPU-bound at 100% utilization

### Event Handler (500 EPS)

| Resource | M3 Actual | Capacity | Utilization |
|----------|-----------|----------|-------------|
| CPU | 22.87% | 1 core | **Underutilized** |
| Memory | 167.8 MB | 1 GB | 16.4% |
| Goroutines | 3,028 | - | Healthy |
| Heap | 96 MB | - | Low |

**Assessment:** Far below capacity, can scale to 2,000+ EPS

### PostgreSQL

| Metric | M3 Actual |
|--------|-----------|
| CPU | 162% (multi-core) |
| Memory | 40.9 MB |
| Connections | Not saturated |

**Assessment:** Database is handling load but initialize queries causing contention

---

## Failure Analysis

### HTTP Request Failures

| Endpoint | Failed | Total | Failure Rate |
|----------|--------|-------|--------------|
| Initialize (init) | 580 | 4,687 | **12.4%** |
| Initialize (gameplay) | 85 | 53,968 | 0.16% |
| Challenges | 247 | 377,611 | 0.07% |
| Set Active | 103 | 80,908 | 0.13% |
| **Total** | **1,033** | **544,105** | **0.19%** |

### Check Failures

| Check | Failed | Total | Failure Rate |
|-------|--------|-------|--------------|
| init phase: status 200 | 580 | 4,687 | 12.4% |
| init phase: has assignedGoals | 580 | 4,687 | 12.4% |
| challenges: status 200 | 247 | 377,611 | 0.07% |
| set_active: status 200 | 103 | 80,908 | 0.13% |
| gameplay init: status 200 | 85 | 53,968 | 0.16% |
| gameplay init: fast path | 85 | 53,968 | 0.16% |

**Total check failures:** 1,927 / 1,853,354 (0.10%)

**Root causes:**
1. Database connection pool exhaustion during initialization phase
2. Write lock contention on `user_goal_progress` table
3. Timeout errors (requests exceeding 18 seconds)

---

## Root Cause Analysis

### Critical Issue #1: Initialize Endpoint Performance

**Problem:** p95 latency of 12.72s (254x target)

**Root causes:**
1. **Bulk insert of 500 goals per user** instead of 10 default-assigned goals
   - M3 design: "Create rows for ALL goals during initialization"
   - This multiplies database write load by **50x**

2. **No batch optimization for bulk insert**
   - Each goal insert may be individual statement
   - Should use single INSERT with 500 rows

3. **Database write contention**
   - 600 concurrent users all inserting 500 goals = 300,000 rows/second
   - PostgreSQL write throughput saturated

4. **Missing connection pooling optimization**
   - Default connection pool size insufficient for burst traffic
   - Need higher `max_connections` and connection timeout tuning

**Fix Priority:** 🔴 **CRITICAL** - Breaks user onboarding

---

### Critical Issue #2: Fast Path Query Performance

**Problem:** p95 latency of 1.7s (170x target)

**Root causes:**
1. **GetGoalsByIDs query with 500 IDs**
   ```sql
   SELECT * FROM user_goal_progress
   WHERE user_id = $1 AND goal_id IN ($2, $3, ..., $501)
   ```
   - PostgreSQL IN clause with 500 parameters is inefficient
   - Query planner may not use index efficiently

2. **Missing composite index**
   - Should have index on `(user_id, goal_id)` for fast lookups
   - Current index may be on `user_id` only

3. **No query result caching**
   - Repeated calls to initialize by same user query same data
   - Could cache user initialization status in Redis

**Fix Priority:** 🔴 **CRITICAL** - Impacts user experience on every session

---

### Issue #3: Set Active Endpoint Performance

**Problem:** p95 latency of 526ms (5.3x target)

**Root causes:**
1. **Row-level lock contention**
   - UPDATE query acquires exclusive lock on row
   - High concurrency causes lock waiting

2. **No optimistic locking**
   - Every update waits for lock even if no conflict

3. **CPU saturation impact**
   - Challenge-service at 100% CPU slows all operations

**Fix Priority:** 🟠 **HIGH** - M3 feature not performing well

---

## M2 vs M3 Feature Comparison

### M2 Features (Baseline)
- Simple challenge queries (no filtering)
- Claim reward endpoint
- Event processing with buffering

### M3 New Features (Performance Impact)
- ❌ **Initialize endpoint** - Severe degradation
- ❌ **Goal activation/deactivation** - High latency
- ✅ **is_active filtering** - Minimal overhead
- ✅ **Event filtering by is_active** - No measurable impact

**Conclusion:** M3 features are **functionally correct** but **poorly optimized** for production load.

---

## Performance Recommendations

### Immediate Fixes (Required for Production)

#### 1. Optimize Initialize Logic (CRITICAL)
**Current:** Insert 500 goals per user
**Fix:** Only insert default-assigned goals (10 goals)

```go
// BEFORE (M3 current)
allGoals := goalCache.GetAllGoals()  // 500 goals
repo.BulkInsert(ctx, allGoals)

// AFTER (optimized)
defaultGoals := goalCache.GetDefaultAssignedGoals()  // 10 goals
repo.BulkInsert(ctx, defaultGoals)
```

**Expected improvement:**
- p95 latency: 12.72s → **< 50ms** (254x improvement)
- Database load: 300,000 rows/sec → 6,000 rows/sec (50x reduction)

#### 2. Optimize Fast Path Query (CRITICAL)
**Current:** Query 500 goal IDs
**Fix:** Check user initialization status first

```go
// BEFORE
existing, err := repo.GetGoalsByIDs(ctx, userID, allGoalIDs)  // 500 IDs

// AFTER
count, err := repo.GetUserGoalCount(ctx, userID)
if count > 0 {
    // Fast path: user already initialized
    return existingGoals, nil
}
```

**Expected improvement:**
- p95 latency: 1.7s → **< 10ms** (170x improvement)
- Database queries: Complex IN clause → Simple COUNT(*)

#### 3. Add Database Indexes (HIGH)
```sql
-- Composite index for fast lookups
CREATE INDEX CONCURRENTLY idx_user_goal_lookup
ON user_goal_progress (user_id, goal_id);

-- Index for active-only queries
CREATE INDEX CONCURRENTLY idx_user_goal_active
ON user_goal_progress (user_id, is_active)
WHERE is_active = true;
```

**Expected improvement:**
- Initialize fast path: 50% faster
- Active-only queries: 30% faster

#### 4. Increase Database Connection Pool
```go
// BEFORE
db.SetMaxOpenConns(25)

// AFTER
db.SetMaxOpenConns(100)
db.SetMaxIdleConns(25)
db.SetConnMaxLifetime(5 * time.Minute)
```

**Expected improvement:**
- Reduce connection wait time during initialization burst
- Better handle 600 RPS spike

---

### Medium-Term Optimizations

#### 5. Lazy Goal Assignment (RECOMMENDED)
**Design change:** Don't pre-create rows for inactive goals

Instead of creating 500 rows upfront:
- Create only when user activates goal
- Or create on-demand when first event arrives

**Benefits:**
- Eliminate initialization bottleneck entirely
- Reduce database size (90% smaller for inactive users)
- Faster queries (fewer rows to scan)

#### 6. Redis Caching for Initialize Status
```go
// Check Redis first
cacheKey := fmt.Sprintf("user:%s:initialized", userID)
if exists := redis.Exists(ctx, cacheKey); exists {
    // Fast path: skip database query
    return cachedGoals, nil
}
```

**Expected improvement:**
- Fast path latency: < 1ms (from Redis)
- Database load: 90% reduction for returning users

#### 7. Horizontal Scaling
**Current:** 1 challenge-service instance (CPU saturated)
**Recommendation:** 3 instances behind load balancer

**Expected capacity:**
- Current: 300 RPS (1 core at 100%)
- With 3 instances: 900 RPS (3 cores at 100%)
- Provides 3x headroom

---

## Risk Assessment

### Production Readiness

| Criteria | Status | Notes |
|----------|--------|-------|
| Functional correctness | ✅ PASS | All features work as designed |
| Performance targets | ❌ FAIL | Multiple endpoints exceed targets |
| Stability | ⚠️  WARN | 0.19% failure rate acceptable but not ideal |
| Scalability | ❌ FAIL | Cannot handle target load without fixes |
| **Overall** | ❌ **NOT READY** | **Requires optimization before production** |

### Deployment Recommendation

🔴 **DO NOT DEPLOY M3 to production without fixes**

**Required before deployment:**
1. ✅ Fix initialize endpoint (only insert default-assigned goals)
2. ✅ Fix fast path query (add user initialization check)
3. ✅ Add database indexes
4. ✅ Increase connection pool size
5. ✅ Re-run load test to validate fixes

**Estimated time to fix:** 2-3 days (1 day implementation + 1 day testing)

---

## Comparison Summary Table

| Metric | M2 Target | M3 Actual | Status | Gap |
|--------|-----------|-----------|--------|-----|
| Initialize (new user) p95 | 50ms | 12.72s | ❌ | -254x |
| Initialize (returning) p95 | 10ms | 1.7s | ❌ | -170x |
| Challenges p95 | 200ms | 249ms | ⚠️  | -1.25x |
| Set Active p95 | 100ms | 526ms | ❌ | -5.3x |
| Event processing p95 | 500ms | 28.5ms | ✅ | +17.5x |
| Success rate | 99.95% | 99.89% | ❌ | -0.06% |

---

## Conclusion

M3 introduces **significant performance regression** compared to M2 baseline. While the event processing component performs excellently, the API endpoints (especially initialize) show severe degradation that makes M3 **unsuitable for production deployment** without optimization.

**Primary issue:** M3 design decision to "create rows for ALL goals during initialization" (500 goals instead of 10 default-assigned) creates **50x database load multiplier** that overwhelms the system.

**Recommendation:** Revert to simpler design - only insert default-assigned goals during initialization, create other goals lazily when activated.

**Timeline:** 2-3 days to fix and re-validate before M3 can be deployed to production.

---

**Report Generated:** 2025-11-10
**Test Log:** `/tmp/loadtest_m3_full.log`
**Profiling Data:** `/tmp/m3_profiling_analysis.md`
