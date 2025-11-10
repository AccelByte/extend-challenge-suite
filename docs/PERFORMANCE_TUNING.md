# Performance Tuning Guide - M2

**Based on:** Performance Baseline Report (PERFORMANCE_BASELINE.md)
**Last Updated:** [FILL IN]

---

## Configuration Optimizations

### 1. Database Connection Pool

**Current:** 50 connections
**Recommended:** [FILL IN] connections (based on test results)

**Update `.env`:**
```bash
DB_MAX_OPEN_CONNS=[FILL IN]
DB_MAX_IDLE_CONNS=[FILL IN]
DB_CONN_MAX_LIFETIME=30m
DB_CONN_MAX_IDLE_TIME=5m
```

**Rationale:**
[Explain based on test results - e.g., "Load tests showed pool saturation at >500 RPS. Increasing to 100 provides headroom."]

**Expected impact:**
- Capacity increase: [FILL IN]%
- Latency improvement: [FILL IN]%

---

### 2. Buffer Flush Interval

**Current:** 1 second
**Consider:** [FILL IN] seconds for very high event load (>10,000 EPS)

**Update `.env` for event handler:**
```bash
BUFFER_FLUSH_INTERVAL=[FILL IN]s
BUFFER_SIZE_LIMIT=[FILL IN]
```

**Trade-off analysis:**
| Interval | E2E Latency | DB Writes/sec | Throughput | Recommendation |
|----------|-------------|---------------|------------|----------------|
| 0.5s     | Better      | Higher        | Lower      | [FILL IN]      |
| 1s       | Good        | Moderate      | Good       | **Current**    |
| 2s       | Worse       | Lower         | Higher     | [FILL IN]      |
| 5s       | Poor        | Lowest        | Highest    | [FILL IN]      |

**Recommendation:** [Based on test results, recommend optimal interval]

---

### 3. PostgreSQL Configuration

**Tuning for performance:**

Create `postgresql-tuning.conf`:
```conf
# Memory Configuration
shared_buffers = 2GB              # 25% of RAM (for 8GB instance)
effective_cache_size = 6GB        # 75% of RAM
maintenance_work_mem = 512MB
work_mem = 10MB

# Checkpoint Configuration
checkpoint_completion_target = 0.9
wal_buffers = 16MB
min_wal_size = 1GB
max_wal_size = 4GB

# Query Planning
default_statistics_target = 100
random_page_cost = 1.1            # For SSD storage
effective_io_concurrency = 200    # For SSD storage

# Connection Configuration
max_connections = 200             # Adjust based on instances

# Performance Monitoring
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
```

**Apply to docker-compose.yml:**
```yaml
postgres:
  command:
    - "postgres"
    - "-c"
    - "config_file=/etc/postgresql/postgresql-tuning.conf"
  volumes:
    - ./postgresql-tuning.conf:/etc/postgresql/postgresql-tuning.conf
```

**Expected impact:**
- Query performance: [FILL IN]% improvement
- Connection handling: [FILL IN]% better
- Cache hit ratio: [FILL IN]% (target: >95%)

---

### 4. Index Optimization

**Verified indexes (from test results):**

```sql
-- Primary key (already exists)
ALTER TABLE user_goal_progress ADD PRIMARY KEY (user_id, goal_id);

-- Composite index for challenge queries
CREATE INDEX IF NOT EXISTS idx_user_challenge
ON user_goal_progress(user_id, challenge_id);

-- Partial index for unclaimed completed goals
CREATE INDEX IF NOT EXISTS idx_completed_unclaimed
ON user_goal_progress(user_id, status)
WHERE status = 'completed' AND claimed_at IS NULL;
```

**Index usage verification (from test results):**
| Index Name | Scans | Tuples Read | Efficiency |
|------------|-------|-------------|------------|
| [FILL IN]  | [FILL]| [FILL]      | [FILL]%    |
| [FILL IN]  | [FILL]| [FILL]      | [FILL]%    |
| [FILL IN]  | [FILL]| [FILL]      | [FILL]%    |

**Recommendations:**
- [Based on test results, recommend keeping or removing indexes]
- [Suggest additional indexes if needed]

---

## Code-Level Optimizations

### 1. Reduce JSON Allocations

**Issue identified:** [If found in profiling, describe]

**Current bottleneck (from pprof):**
```
[Function name]: [percentage]% CPU time
Location: [file:line]
```

**Optimization:** Use `json.RawMessage` for partial parsing

**Before:**
```go
var fullPayload ChallengeResponse
json.Unmarshal(data, &fullPayload)
```

**After:**
```go
var partial struct {
    Challenges json.RawMessage `json:"challenges"`
}
json.Unmarshal(data, &partial)
// Only unmarshal challenges if needed
```

**Expected impact:** [FILL IN]% CPU reduction (if applicable)

---

### 2. Connection Pool Pre-warming

**Issue identified:** [If cold start delays observed]

**Optimization:** Add to service startup

```go
// Add to main() or service initialization
func warmupConnectionPool(db *sql.DB, count int) {
    log.Info("Warming up database connection pool", "connections", count)

    var wg sync.WaitGroup
    for i := 0; i < count; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            _, err := db.Exec("SELECT 1")
            if err != nil {
                log.Warn("Connection pool warm-up failed", "error", err)
            }
        }()
    }
    wg.Wait()

    log.Info("Connection pool warm-up complete")
}

// Call during startup
warmupConnectionPool(db, 10)
```

**Expected impact:** [FILL IN] ms faster first-request latency

---

### 3. Batch Processing Optimization

**Issue identified:** [If batch processing bottleneck found]

**Current performance (from test results):**
- Batch UPSERT time: [FILL IN] ms for [FILL IN] rows
- Throughput: [FILL IN] rows/sec

**Optimization options:**

**Option A: Increase batch size**
```go
// Current
const maxBatchSize = 1000

// Recommended
const maxBatchSize = [FILL IN]  // Based on test results
```

**Option B: Parallel batching**
```go
// Process multiple batches concurrently
const numWorkers = 4
batches := splitIntoBatches(updates, maxBatchSize)

var wg sync.WaitGroup
for _, batch := range batches {
    wg.Add(1)
    go func(b []Update) {
        defer wg.Done()
        processBatch(b)
    }(batch)
}
wg.Wait()
```

**Recommendation:** [Based on test results]

---

### 4. Mutex Granularity

**Issue identified:** [If lock contention found in pprof]

**Current:** Per-user mutex (good)

**Check with pprof:**
```bash
go tool pprof -text http://localhost:8080/debug/pprof/mutex
```

**If high contention found:**

**Option A: Sharded mutexes**
```go
const numShards = 256

type ShardedMap struct {
    shards [numShards]struct {
        sync.Mutex
        data map[string]*UserBuffer
    }
}

func (m *ShardedMap) getShard(userID string) *struct {
    sync.Mutex
    data map[string]*UserBuffer
} {
    hash := fnv32a(userID)
    return &m.shards[hash%numShards]
}
```

**Option B: sync.Map (for read-heavy workloads)**
```go
var userBuffers sync.Map

// Get
if v, ok := userBuffers.Load(userID); ok {
    buffer := v.(*UserBuffer)
    // ...
}

// Set
userBuffers.Store(userID, buffer)
```

**Recommendation:** [Based on profiling results]

---

## Monitoring Alerts

**Set up alerts for:**

### 1. Connection Pool Saturation
```yaml
alert: DatabaseConnectionPoolHigh
expr: db_connections_active / db_connections_max > 0.8
for: 5m
severity: warning
action: Increase connection pool or scale database
```

### 2. High API Latency
```yaml
alert: HighAPILatency
expr: http_request_duration_p95 > 500
for: 2m
severity: warning
action: Scale up backend instances
```

### 3. High Event Processing Latency
```yaml
alert: HighEventLatency
expr: grpc_request_duration_p95 > 100
for: 2m
severity: warning
action: Scale up event handler instances
```

### 4. Error Rate Spike
```yaml
alert: HighErrorRate
expr: http_errors_rate > 0.01  # 1%
for: 1m
severity: critical
action: Investigate immediately, check logs
```

### 5. Buffer Overflow Risk
```yaml
alert: BufferSizeHigh
expr: event_buffer_size > 80000  # 80% of 100,000 limit
for: 5m
severity: warning
action: Increase flush frequency or scale event handler
```

---

## Load Testing in Production

**Use k6 cloud for distributed load testing:**

```bash
# Install k6 cloud CLI
k6 login cloud

# Run from multiple regions
k6 cloud test/k6/scenario1_api_load.js

# Ramp up gradually
export K6_CLOUD_PROJECT_ID=your-project-id
k6 cloud run \
  --vus-max 1000 \
  --duration 10m \
  --ramp-up-time 2m \
  test/k6/scenario1_api_load.js
```

**Monitor during production load:**

```bash
# Terminal 1: Real-time dashboard
watch -n 1 'docker stats --no-stream'

# Terminal 2: Database connections
watch -n 5 'psql -c "SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state"'

# Terminal 3: Query performance
watch -n 5 'psql -c "SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5"'

# Terminal 4: Application logs
docker logs -f challenge-service | grep -E "ERROR|WARN|latency"
```

---

## Optimization Checklist

### Before Load Testing
- [ ] Database connection pool configured
- [ ] PostgreSQL tuning parameters set
- [ ] Indexes created and verified
- [ ] Buffer configuration optimized
- [ ] Monitoring and alerting configured

### During Load Testing
- [ ] Monitor CPU and memory usage
- [ ] Track database connection pool utilization
- [ ] Collect CPU and memory profiles (pprof)
- [ ] Monitor error rates
- [ ] Track buffer flush performance

### After Load Testing
- [ ] Analyze profiling data
- [ ] Identify bottlenecks
- [ ] Document findings
- [ ] Implement optimizations
- [ ] Re-test to verify improvements

---

## Optimization Workflow

### 1. Identify Bottleneck
   - Run load test until failure
   - Collect metrics: CPU, memory, database, latency
   - Use pprof to find CPU/memory hotspots
   - Check database slow queries

### 2. Hypothesize Solution
   - Based on metrics, identify root cause
   - Propose specific optimization
   - Estimate expected impact

### 3. Implement Optimization
   - Make targeted change (one at a time)
   - Document change clearly
   - Keep rollback plan ready

### 4. Verify Improvement
   - Re-run same load test
   - Compare metrics before/after
   - Verify no regressions
   - Document actual impact

### 5. Iterate
   - If improvement insufficient, find next bottleneck
   - Repeat process
   - Stop when target performance achieved

---

## Optimization Log Template

```markdown
## Optimization #[N]: [Name]

**Date:** [FILL IN]
**Issue:** [Describe bottleneck]
**Evidence:** [Metrics showing issue]

**Hypothesis:** [Proposed solution]
**Expected impact:** [Prediction]

**Implementation:**
- Changed: [What was modified]
- Code: [Link to PR/commit]

**Results:**
- Before: [Metrics before]
- After: [Metrics after]
- Actual impact: [Measured improvement]

**Conclusion:** [Success/failure, lessons learned]
```

---

## Common Performance Issues

### Issue: Database Connection Pool Saturation

**Symptoms:**
- API latency spikes
- Error logs: "too many connections"
- Connection wait time >100ms

**Solution:**
1. Increase `DB_MAX_OPEN_CONNS`
2. Reduce `DB_CONN_MAX_IDLE_TIME` (free connections faster)
3. Scale database vertically
4. Use connection pooler (PgBouncer)

**Expected improvement:** [FILL IN based on tests]

---

### Issue: High CPU Usage

**Symptoms:**
- CPU >80% sustained
- Increased latency under load
- No single hotspot in profiling

**Solution:**
1. Scale horizontally (add instances)
2. Optimize hot code paths (from pprof)
3. Reduce unnecessary JSON marshaling
4. Use more efficient algorithms

**Expected improvement:** [FILL IN based on tests]

---

### Issue: Memory Pressure

**Symptoms:**
- Memory usage >90%
- Frequent GC pauses
- OOM kills

**Solution:**
1. Reduce buffer size limits
2. Optimize data structures
3. Fix memory leaks (check pprof heap)
4. Scale vertically (more RAM)

**Expected improvement:** [FILL IN based on tests]

---

### Issue: Buffer Overflow

**Symptoms:**
- Event handler errors: "buffer full"
- Events dropped
- Increased latency

**Solution:**
1. Increase `BUFFER_SIZE_LIMIT`
2. Decrease `BUFFER_FLUSH_INTERVAL`
3. Scale event handler horizontally
4. Optimize batch UPSERT performance

**Expected improvement:** [FILL IN based on tests]

---

## Performance Testing Best Practices

1. **Test one thing at a time**
   - Change one variable per test
   - Isolate API vs event load
   - Clear attribution of impact

2. **Use realistic data**
   - 10,000+ unique users
   - 10 challenges, 50 goals each
   - Realistic stat distributions

3. **Run long enough**
   - 30 minutes minimum
   - Capture steady-state behavior
   - Avoid warmup artifacts

4. **Monitor everything**
   - Application metrics (latency, errors)
   - Resource metrics (CPU, memory)
   - Database metrics (queries, connections)

5. **Document findings**
   - Record all test parameters
   - Save results JSON files
   - Note any anomalies

---

**Document Status:** Template - Fill in with optimization results
