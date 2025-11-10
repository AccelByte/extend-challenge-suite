# Milestone 2 Brainstorming: Performance Profiling & Load Testing

**Date:** 2025-10-23
**Purpose:** Deep dive into M2 planning, identify gaps in current plan, and elaborate on implementation details

---

## Current Plan Analysis

The M2 plan in `MILESTONES.md` provides a solid foundation with 4 test scenarios:
1. API Load Testing (isolated)
2. Event Processing Load (isolated)
3. Memory Profiling
4. CPU Profiling

**Strengths:**
- Clear metrics defined (RPS, EPS, latency percentiles)
- Resource constraints specified (1 vCPU, 1 GB RAM)
- Multiple variables to test (challenge count, goal count, concurrent users)
- Deliverables defined (3 documentation outputs)

**Gaps Identified:**
1. ❌ No combined load testing (API + Events simultaneously)
2. ❌ No realistic user behavior patterns
3. ❌ Limited database-specific optimization guidance
4. ❌ No end-to-end latency testing
5. ❌ No failure scenario testing
6. ❌ Monitoring/observability setup not detailed
7. ❌ Load testing tool implementation not specified
8. ❌ Optimization iteration cycle not defined

---

## Critical Addition: Combined Load Testing

### Why This Matters

**In production, both services run simultaneously:**
- Backend Service handles API requests (GET challenges, POST claims)
- Event Handler processes events (login, stat updates)
- Both compete for:
  - Database connections (shared pool)
  - CPU cycles (same machine or different machines?)
  - Memory (if co-located)
  - Network I/O to database

**Real-world scenario:**
```
9:00 AM - 1,000 players login (1,000 login events/second)
9:01 AM - Players check challenges (500 GET /v1/challenges requests/second)
9:05 AM - Players play games (2,000 stat update events/second)
9:10 AM - Players claim rewards (200 POST /claim requests/second)
```

**Without combined testing, we might miss:**
- Database connection pool saturation (both services fighting for connections)
- CPU contention (event processing vs API handling)
- Memory pressure (buffer growth + API response caching)
- Cascading failures (slow events → slow API)

### Proposed: Scenario 5 - Combined Load Testing

**Scenario 5: Realistic User Journey Testing**

**Deployment Configuration:**
```
Option A: Co-located (single machine, 1 vCPU, 1 GB RAM total)
  - Backend Service: 0.5 vCPU, 512 MB
  - Event Handler: 0.5 vCPU, 512 MB
  - Database: Separate machine (realistic for production)

Option B: Separate machines (1 vCPU, 1 GB each)
  - Backend Service: 1 vCPU, 1 GB
  - Event Handler: 1 vCPU, 1 GB
  - Database: Shared connection pool (50 connections total)
```

**Test Pattern: Simulated Player Day**

```
Phase 1: Morning Login Rush (0-5 minutes)
  - 1,000 concurrent logins
  - Event Handler: 1,000 login events/sec
  - Backend Service: Idle (players haven't opened challenge UI yet)
  - Expected: Event buffer fills, DB flush every 1 second

Phase 2: Challenge Check (5-10 minutes)
  - 500 players check challenges
  - Backend Service: 500 GET /v1/challenges requests/sec
  - Event Handler: 100 stat update events/sec (background gameplay)
  - Expected: Database connection contention, read/write mix

Phase 3: Heavy Gameplay (10-20 minutes)
  - Players actively playing games
  - Event Handler: 2,000 stat update events/sec (peak load)
  - Backend Service: 200 GET requests/sec + 50 POST /claim/sec
  - Expected: CPU contention, buffer memory growth, reward API calls

Phase 4: Claim Rewards (20-25 minutes)
  - Players claiming completed goals
  - Backend Service: 200 POST /claim requests/sec (high)
  - Event Handler: 500 stat update events/sec
  - Expected: AGS Platform Service latency, transaction locks

Phase 5: Idle (25-30 minutes)
  - Low activity (baseline)
  - Event Handler: 50 events/sec
  - Backend Service: 20 requests/sec
  - Expected: Resource recovery, GC cycles
```

**Metrics to Collect:**

*System-Wide:*
- Total CPU utilization (% across both services)
- Total memory utilization (RSS + heap)
- Database connection pool utilization (active/idle/max)
- Database query queue depth
- Network I/O to database

*Per-Service:*
- API response times (p50, p95, p99)
- Event processing latency (p50, p95, p99)
- Error rates (500s, timeouts, DB errors)
- Goroutine count
- GC pause times

*Database:*
- Active connections per service
- Query execution time (per query type)
- Lock wait time
- Transaction throughput (commits/sec)
- Index hit rate

**Success Criteria:**
- API p95 latency < 200ms during combined load
- Event processing p95 < 50ms during combined load
- Error rate < 0.1% across all phases
- Database connection pool never saturated (< 90% utilization)
- No OOM crashes during 30-minute test

**Tools:**
- k6 for API load generation
- Custom Go program for event generation
- Prometheus + Grafana for metrics collection
- pganalyze or pg_stat_statements for database analysis

---

## Elaboration: Realistic User Patterns

### Problem with Uniform Load

Current plan tests constant load (e.g., "1,000 events/sec for 10 minutes"). Real traffic has:
- Spikes (login rush, event completion)
- Bursts (game session ends → many stat updates)
- Idle periods (night time)
- Seasonal patterns (weekend vs weekday)

### Proposed: Pattern-Based Load Testing

**Pattern 1: Login Rush**
```
Simulate 1,000 players logging in over 60 seconds
- Poisson distribution (random arrival times)
- Each login triggers 1 login event
- 50% of players immediately check challenges (GET /v1/challenges)
```

**Pattern 2: Game Session Burst**
```
Simulate 100 players finishing a game session simultaneously
- Each player: 5-10 stat updates in rapid succession
- Event Handler: 500-1,000 events in < 1 second (burst)
- Backend Service: 20-30 GET requests/sec (players checking progress)
```

**Pattern 3: Goal Completion Wave**
```
Simulate tiered goal completion:
- Goal 1 (easy): 500 players complete at T=0
- Goal 2 (medium): 200 players complete at T=5min
- Goal 3 (hard): 50 players complete at T=10min
- Each completion: 1 stat update event + 1 POST /claim request
```

**Pattern 4: Daily Active User (DAU) Curve**
```
24-hour simulation (compressed to 30 minutes):
- 00:00-08:00: Low (50 events/sec)
- 08:00-10:00: Morning rush (1,000 events/sec)
- 10:00-18:00: Steady (300 events/sec)
- 18:00-22:00: Evening peak (2,000 events/sec)
- 22:00-24:00: Decline (200 events/sec)
```

### Implementation

Use k6 scenarios with stages:
```javascript
export let options = {
  scenarios: {
    morning_rush: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 1000,
      stages: [
        { duration: '2m', target: 1000 }, // Ramp up
        { duration: '3m', target: 1000 }, // Sustain
        { duration: '2m', target: 50 },   // Ramp down
      ],
    },
    // ... more scenarios
  },
};
```

---

## Elaboration: Database Performance Deep Dive

### Current Gap

M2 plan mentions "database query time" but doesn't specify:
- Which queries to optimize
- How to identify slow queries
- Connection pool tuning strategy
- Index effectiveness validation

### Proposed: Database-Specific Testing

**Test 1: Query Performance Analysis**

Identify slow queries using `pg_stat_statements`:
```sql
SELECT
  query,
  calls,
  total_exec_time / calls AS avg_time_ms,
  max_exec_time AS max_time_ms,
  stddev_exec_time AS stddev_ms
FROM pg_stat_statements
WHERE query LIKE '%user_goal_progress%'
ORDER BY total_exec_time DESC
LIMIT 10;
```

**Expected Queries to Profile:**
1. Batch UPSERT (event processing)
   ```sql
   INSERT INTO user_goal_progress (...) VALUES (...)
   ON CONFLICT (user_id, goal_id) DO UPDATE ...
   ```
   - Target: < 20ms for 1,000 rows

2. Get User Challenges (API)
   ```sql
   SELECT * FROM user_goal_progress
   WHERE user_id = $1
   ORDER BY challenge_id, created_at;
   ```
   - Target: < 10ms

3. Claim Reward (API)
   ```sql
   UPDATE user_goal_progress
   SET status = 'claimed', claimed_at = NOW()
   WHERE user_id = $1 AND goal_id = $2 AND status = 'completed'
   RETURNING *;
   ```
   - Target: < 5ms

**Test 2: Index Effectiveness**

Use `EXPLAIN ANALYZE` to verify index usage:
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_goal_progress
WHERE user_id = 'test-user-123';
```

Expected output:
```
Index Scan using user_goal_progress_pkey on user_goal_progress (cost=0.29..8.31 rows=1 width=200) (actual time=0.012..0.014 rows=1 loops=1)
  Index Cond: (user_id = 'test-user-123'::text)
  Buffers: shared hit=4
Planning Time: 0.050 ms
Execution Time: 0.025 ms
```

**If index not used:** Investigate why (stats outdated? Wrong index? Query pattern mismatch?)

**Test 3: Connection Pool Tuning**

Test different pool sizes:
```
Pool Size: 10, 25, 50, 100, 200
Workload: 1,000 events/sec + 500 API requests/sec
Measure: Connection wait time, query throughput
```

Expected findings:
- Too small (10): High wait time, low throughput
- Optimal (50-100): Low wait time, high throughput
- Too large (200): Diminishing returns, higher memory

**Test 4: Transaction Isolation Impact**

Test different isolation levels:
```
READ UNCOMMITTED, READ COMMITTED, REPEATABLE READ, SERIALIZABLE
```

For challenge service, likely: **READ COMMITTED** (default)
- Sufficient for progress updates (eventual consistency OK)
- Lower lock contention than REPEATABLE READ
- No dirty reads

**Deliverable: Database Tuning Checklist**
```markdown
# Database Performance Checklist

## Indexes
- [ ] Primary key index exists on (user_id, goal_id)
- [ ] Composite index on (user_id, challenge_id) for GET challenges query
- [ ] Partial index on (status) WHERE status = 'completed' for analytics
- [ ] EXPLAIN ANALYZE shows index scans (not seq scans)

## Connection Pool
- [ ] Max connections: 50-100 for 1,000 events/sec workload
- [ ] Idle timeout: 5 minutes
- [ ] Max lifetime: 30 minutes (prevent stale connections)
- [ ] Connection wait timeout: 5 seconds

## Query Optimization
- [ ] Batch UPSERT: < 20ms for 1,000 rows
- [ ] Get challenges: < 10ms
- [ ] Claim reward: < 5ms
- [ ] VACUUM ANALYZE scheduled (daily or weekly)

## Monitoring
- [ ] pg_stat_statements enabled
- [ ] Slow query log enabled (queries > 100ms)
- [ ] Connection pool metrics exported to Prometheus
```

---

## Elaboration: End-to-End Latency Testing

### Current Gap

M2 plan tests components in isolation, but doesn't measure:
- **Eventual consistency delay**: Time from event → progress visible in API
- **Full user journey**: Login → event → progress update → claim reward

### Proposed: E2E Latency Scenarios

**Scenario: Event-to-API Consistency Delay**

**Test Flow:**
```
1. t=0s: Generate stat update event (enemy_kills += 1)
2. t=?s: Event Handler processes event
3. t=?s: Event Handler flushes buffer to database
4. t=?s: API GET /v1/challenges returns updated progress
```

**What to measure:**
- Event ingestion latency (Kafka → gRPC handler)
- Event processing latency (handler → buffer)
- Buffer flush latency (buffer → database UPSERT)
- API query latency (database → API response)
- **Total E2E latency** (event generated → visible in API)

**Expected:**
- Best case: < 100ms (event processed before next flush)
- Worst case: < 1,100ms (event waits for next flush cycle)
- Average: ~500ms (depends on flush interval)

**How to test:**
```go
// Pseudo-code
func TestE2ELatency(t *testing.T) {
    // Generate event with timestamp
    event := StatUpdateEvent{
        UserID: "user-123",
        StatCode: "enemy_kills",
        Value: 10,
        Timestamp: time.Now(),
    }

    // Send event to handler
    eventClient.Send(event)

    // Poll API until progress appears
    start := time.Now()
    for {
        resp, _ := apiClient.Get("/v1/challenges")
        if resp.Challenges[0].Goals[0].Progress >= 10 {
            e2eLatency := time.Since(start)
            t.Logf("E2E latency: %v", e2eLatency)
            break
        }
        time.Sleep(10 * time.Millisecond)
    }
}
```

**Scenario: Full Claim Flow**

**Test Flow:**
```
1. User completes goal (progress reaches target)
2. User calls POST /v1/challenges/{id}/goals/{id}/claim
3. Backend validates status = 'completed'
4. Backend calls AGS Platform Service (grant entitlement or credit wallet)
5. AGS Platform Service responds
6. Backend updates status = 'claimed'
7. Backend returns success to user
```

**What to measure:**
- Database query time (validate status)
- AGS Platform Service latency (external call)
- Database update time (set claimed)
- Total claim latency

**Expected:**
- Best case: 50ms (fast AGS response)
- Worst case: 500ms (slow AGS response or retry)
- Timeout threshold: 5 seconds (return 502 if exceeded)

---

## Elaboration: Failure Scenario Testing

### Current Gap

M2 plan assumes happy path. What about:
- Database connection failures
- AGS Platform Service timeouts
- Network partitions
- Out-of-memory conditions

### Proposed: Chaos Engineering Tests

**Test 1: Database Connection Failure**

**Scenario:** Database goes down mid-test
```
1. Start load test (1,000 events/sec)
2. t=5min: Kill database connection
3. Observe: Event Handler behavior
4. t=6min: Restore database
5. Measure: Recovery time, data loss
```

**Expected Behavior:**
- Event Handler: Log errors, keep buffering events (don't drop)
- Backend Service: Return 503 Service Unavailable
- On restore: Event Handler flushes buffered events (no data loss)

**Test 2: AGS Platform Service Timeout**

**Scenario:** Slow external API during claim flow
```
1. Configure AGS Platform Service mock with 10-second delay
2. User calls POST /claim
3. Observe: Backend behavior
```

**Expected Behavior:**
- Retry 3 times with exponential backoff
- If all retries fail: Return 502 Bad Gateway
- Do NOT mark as claimed (preserve consistency)

**Test 3: Event Buffer Overflow**

**Scenario:** Events arrive faster than flush can handle
```
1. Generate 10,000 events/sec (10x target)
2. Observe: Event Handler memory growth
3. Measure: Time to OOM or buffer size limit
```

**Expected Behavior:**
- Buffer has max size limit (e.g., 100,000 entries)
- If limit reached: Drop oldest events (FIFO) OR backpressure (block)
- Log warnings when buffer > 50% full

**Test 4: Database Lock Contention**

**Scenario:** Many users claim same reward simultaneously
```
1. 1,000 users complete same goal
2. All call POST /claim at same time
3. Observe: Database lock wait time
```

**Expected Behavior:**
- Row-level locking (SELECT ... FOR UPDATE)
- Only one transaction succeeds per user-goal pair
- Others get "already claimed" error
- No deadlocks

---

## Elaboration: Monitoring & Observability

### Current Gap

M2 plan mentions collecting metrics but doesn't specify:
- Which metrics to expose
- How to visualize
- Alerting thresholds

### Proposed: Metrics & Dashboards

**Metrics to Expose (Prometheus format):**

*Backend Service:*
```
# HTTP request metrics
http_requests_total{method, path, status}
http_request_duration_seconds{method, path}

# Database metrics
db_query_duration_seconds{query_type}
db_connections_active
db_connections_idle
db_connections_max

# AGS Platform Service metrics
ags_platform_request_duration_seconds{operation}
ags_platform_request_errors_total{operation}

# Business metrics
challenges_claimed_total{challenge_id}
rewards_granted_total{reward_type}
```

*Event Handler:*
```
# Event processing metrics
events_received_total{event_type}
events_processed_total{event_type}
event_processing_duration_seconds{event_type}

# Buffer metrics
event_buffer_size
event_buffer_flush_duration_seconds
event_buffer_flush_rows

# Database metrics (same as backend)
```

**Grafana Dashboard Layout:**

```
Row 1: System Overview
  - CPU Usage (%)
  - Memory Usage (MB)
  - Goroutine Count
  - GC Pause Time (ms)

Row 2: API Performance
  - Request Rate (req/sec)
  - Response Time (p50, p95, p99)
  - Error Rate (%)
  - Concurrent Requests

Row 3: Event Processing
  - Event Rate (events/sec)
  - Processing Latency (p50, p95, p99)
  - Buffer Size (entries)
  - Flush Duration (ms)

Row 4: Database
  - Connection Pool Utilization (%)
  - Query Duration (p50, p95, p99)
  - Active Connections
  - Lock Wait Time (ms)

Row 5: Business Metrics
  - Challenges Claimed (count)
  - Rewards Granted (count)
  - Active Users (gauge)
```

**Alerting Rules:**

```yaml
# API response time
- alert: HighAPILatency
  expr: http_request_duration_seconds{quantile="0.95"} > 0.2
  for: 5m
  annotations:
    summary: "API p95 latency > 200ms"

# Event processing backlog
- alert: EventBufferHigh
  expr: event_buffer_size > 50000
  for: 2m
  annotations:
    summary: "Event buffer > 50k entries"

# Database connection saturation
- alert: DBConnectionPoolSaturated
  expr: db_connections_active / db_connections_max > 0.9
  for: 5m
  annotations:
    summary: "DB connection pool > 90% utilized"

# Error rate spike
- alert: HighErrorRate
  expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.01
  for: 5m
  annotations:
    summary: "Error rate > 1%"
```

---

## Elaboration: Load Testing Tools Implementation

### Current Gap

M2 plan mentions k6 and custom event generator, but doesn't specify:
- k6 script structure
- Event generator architecture
- Test data generation strategy

### Proposed: Load Testing Tool Details

**k6 Script Structure:**

```javascript
// test/k6/api_load_test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
let errorRate = new Rate('errors');
let claimDuration = new Trend('claim_duration');

// Configuration
export let options = {
  stages: [
    { duration: '2m', target: 100 },  // Ramp up
    { duration: '5m', target: 100 },  // Sustain
    { duration: '2m', target: 0 },    // Ramp down
  ],
  thresholds: {
    'http_req_duration': ['p(95)<200'],  // 95% < 200ms
    'errors': ['rate<0.01'],             // Error rate < 1%
  },
};

// Test data
const userIds = generateUserIds(10000);
const challenges = loadChallengeConfig();

export default function () {
  // Randomly select user
  const userId = userIds[Math.floor(Math.random() * userIds.length)];
  const token = getJWT(userId);

  // Test GET /v1/challenges
  let resp = http.get(`${BASE_URL}/v1/challenges`, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  check(resp, {
    'status is 200': (r) => r.status === 200,
    'has challenges': (r) => JSON.parse(r.body).challenges.length > 0,
  });

  errorRate.add(resp.status !== 200);

  // 10% of users claim rewards
  if (Math.random() < 0.1) {
    const body = JSON.parse(resp.body);
    const completedGoals = findCompletedGoals(body);

    if (completedGoals.length > 0) {
      const goal = completedGoals[0];
      const claimResp = http.post(
        `${BASE_URL}/v1/challenges/${goal.challengeId}/goals/${goal.goalId}/claim`,
        null,
        { headers: { 'Authorization': `Bearer ${token}` } }
      );

      claimDuration.add(claimResp.timings.duration);
    }
  }

  sleep(1); // 1 second between iterations
}
```

**Event Generator Architecture:**

```go
// test/event_generator/main.go
package main

import (
    "context"
    "fmt"
    "math/rand"
    "time"

    "google.golang.org/grpc"
    pb "github.com/AccelByte/accelbyte-api-proto/event-handler"
)

type EventGenerator struct {
    client pb.EventServiceClient
    userPool []string
    statCodes []string
    eventRate int // events per second
}

func (g *EventGenerator) Run(ctx context.Context, duration time.Duration) {
    ticker := time.NewTicker(time.Second / time.Duration(g.eventRate))
    defer ticker.Stop()

    endTime := time.Now().Add(duration)

    for time.Now().Before(endTime) {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            g.sendEvent()
        }
    }
}

func (g *EventGenerator) sendEvent() {
    // Randomly choose event type
    if rand.Float64() < 0.2 {
        g.sendLoginEvent()
    } else {
        g.sendStatUpdateEvent()
    }
}

func (g *EventGenerator) sendLoginEvent() {
    userID := g.userPool[rand.Intn(len(g.userPool))]
    event := &pb.Event{
        EventName: "userLoggedIn",
        Namespace: "test-namespace",
        Payload: map[string]interface{}{
            "userId": userID,
            "platform": "PC",
        },
    }
    g.client.HandleEvent(context.Background(), event)
}

func (g *EventGenerator) sendStatUpdateEvent() {
    userID := g.userPool[rand.Intn(len(g.userPool))]
    statCode := g.statCodes[rand.Intn(len(g.statCodes))]

    event := &pb.Event{
        EventName: "statItemUpdated",
        Namespace: "test-namespace",
        Payload: map[string]interface{}{
            "userId": userID,
            "statCode": statCode,
            "value": rand.Intn(100),
        },
    }
    g.client.HandleEvent(context.Background(), event)
}

func main() {
    conn, _ := grpc.Dial("localhost:6565", grpc.WithInsecure())
    defer conn.Close()

    client := pb.NewEventServiceClient(conn)

    generator := &EventGenerator{
        client: client,
        userPool: generateUserPool(10000),
        statCodes: []string{"enemy_kills", "login_count", "games_played"},
        eventRate: 1000, // 1,000 events/sec
    }

    generator.Run(context.Background(), 10*time.Minute)
}
```

**Test Data Generation:**

```go
// test/testdata/generator.go
func generateUserPool(count int) []string {
    users := make([]string, count)
    for i := 0; i < count; i++ {
        users[i] = fmt.Sprintf("user-%06d", i)
    }
    return users
}

func generateChallengeConfig(challengeCount, goalsPerChallenge int) ChallengeConfig {
    challenges := make([]Challenge, challengeCount)
    for i := 0; i < challengeCount; i++ {
        challenges[i] = Challenge{
            ID: fmt.Sprintf("challenge-%d", i),
            Name: fmt.Sprintf("Challenge %d", i),
            Goals: generateGoals(goalsPerChallenge),
        }
    }
    return ChallengeConfig{Challenges: challenges}
}

func generateGoals(count int) []Goal {
    goals := make([]Goal, count)
    statCodes := []string{"enemy_kills", "login_count", "games_played"}

    for i := 0; i < count; i++ {
        goals[i] = Goal{
            ID: fmt.Sprintf("goal-%d", i),
            Name: fmt.Sprintf("Goal %d", i),
            Requirement: Requirement{
                StatCode: statCodes[i % len(statCodes)],
                Operator: ">=",
                TargetValue: rand.Intn(100) + 10,
            },
            Reward: generateReward(),
        }
    }
    return goals
}
```

---

## Elaboration: Optimization Iteration Cycle

### Current Gap

M2 plan describes profiling, but doesn't define:
- When to stop optimizing
- Iteration process
- Minimum acceptable performance

### Proposed: Optimization Workflow

**Phase 1: Baseline Measurement (Week 1)**
1. Deploy M1 code (unoptimized)
2. Run all 5 test scenarios
3. Collect baseline metrics
4. Identify top 3 bottlenecks

**Phase 2: First Optimization Pass (Week 1)**
1. Fix most critical bottleneck (based on profiling)
2. Re-run tests
3. Compare before/after metrics
4. Document improvement (e.g., "20% latency reduction")

**Phase 3: Second Optimization Pass (Week 2)**
1. Fix second bottleneck
2. Re-run tests
3. Measure improvement
4. Check if minimum targets met

**Phase 4: Final Validation (Week 2)**
1. Run all scenarios with optimized code
2. Validate against success criteria
3. Document final performance numbers
4. Create tuning guides

**Completion Criteria:**

M2 is complete when:
- ✅ All 5 test scenarios executed
- ✅ Baseline metrics documented
- ✅ Minimum performance targets met:
  - API p95 latency < 200ms (under 500 RPS load)
  - Event processing p95 < 50ms (under 1,000 EPS load)
  - Combined load: API p95 < 300ms, Event p95 < 100ms
  - Error rate < 0.1% across all scenarios
  - Database connection pool < 90% utilized
- ✅ Top 3 bottlenecks identified and documented
- ✅ At least 2 optimization passes completed
- ✅ 3 deliverable documents created (Performance Report, Capacity Planning Guide, Tuning Guide)

**If targets not met:**
- Document why (architectural limitation? need more resources?)
- Recommend changes (e.g., "need 2 vCPU" or "need Redis cache")
- Mark as blocker for production deployment

---

## Decision: Do We Need Combined Events + Endpoint Testing?

### Answer: **YES, absolutely critical**

**Reasoning:**

1. **Resource Contention:**
   - Backend Service and Event Handler share database connection pool
   - Under separate testing, each gets full pool (50 connections)
   - Under combined testing, they compete (25 each effectively)
   - This changes performance characteristics dramatically

2. **Real-World Accuracy:**
   - Production will ALWAYS have both running simultaneously
   - Separate testing gives false confidence
   - Example: "API handles 1,000 RPS" ← but that's with NO events processing
   - Reality: "API handles 500 RPS when events are at 1,000 EPS"

3. **Cascading Failures:**
   - Slow event processing → database connections held longer → API requests starved
   - High API traffic → database CPU high → event flushes timeout
   - Cannot discover these issues without combined testing

4. **Deployment Decisions:**
   - Separate testing says: "1 vCPU is enough"
   - Combined testing says: "Need 2 vCPUs or separate machines"
   - This directly impacts cost and architecture

### Recommendation: Add Scenario 5 to M2

**Scenario 5: Combined Load Testing**
- Test both services simultaneously
- Use realistic traffic patterns (not uniform load)
- Measure resource contention
- Identify optimal deployment configuration
- Validate end-to-end latency

This should be a **REQUIRED** part of M2, not optional.

---

## Summary: Enhanced M2 Plan

### Original Plan (MILESTONES.md)
- Scenario 1: API Load (isolated)
- Scenario 2: Event Load (isolated)
- Scenario 3: Memory Profiling
- Scenario 4: CPU Profiling

### Enhanced Plan (BRAINSTORM_M2.md)
- **Scenario 1:** API Load (isolated) ← Keep
- **Scenario 2:** Event Load (isolated) ← Keep
- **Scenario 3:** Memory Profiling ← Keep
- **Scenario 4:** CPU Profiling ← Keep
- **Scenario 5:** Combined Load (API + Events) ← **NEW, CRITICAL**
- **Scenario 6:** Realistic User Patterns ← **NEW**
- **Scenario 7:** Database Performance Deep Dive ← **NEW**
- **Scenario 8:** End-to-End Latency ← **NEW**
- **Scenario 9:** Failure Scenarios (Chaos) ← **NEW**

### Additional Deliverables
- Monitoring & Observability Setup Guide
- Load Testing Tool Implementation (k6 + event generator)
- Optimization Iteration Log

### Estimated Duration
- Original: 1 week
- Enhanced: **2-3 weeks** (more comprehensive)

---

## Decisions Made (2025-10-23)

Based on project requirements and resource constraints, the following decisions were made:

### 1. ✅ Deployment Configuration

**Decision: Local docker-compose deployment (co-located services)**

- Both services run on same machine via `docker-compose.yml`
- Backend Service (REST API) + Event Handler (gRPC) share resources
- PostgreSQL: 2 CPU, 4 GB RAM (realistic DB deployment)
- Redis: Standard configuration (7-alpine)

**Resource Allocation:**
```
Backend Service: No resource limits (docker-compose default)
Event Handler: No resource limits (docker-compose default)
PostgreSQL: 2 CPU, 4 GB RAM
Redis: Standard (no limits)
```

**Rationale:** Matches actual local development environment, simpler setup

### 2. ✅ AGS Platform Service Integration

**Decision: Mock AGS Platform Service**

- Use mock implementation for reward grants
- No external API calls during load testing
- Configurable latency for claim testing (will decide later)

**Rationale:** Eliminates external dependencies, cost, and rate limits

### 3. ✅ Failure Testing Scope

**Decision: Remove Scenario 9 (Chaos Engineering)**

- ❌ ~~Database connection failures~~
- ❌ ~~AGS Platform Service timeouts~~
- ❌ ~~Buffer overflow testing~~
- ❌ ~~Network partitions~~

**Rationale:** Focus M2 on finding performance limits, not failure modes

### 4. ✅ Success Criteria Philosophy

**Decision: Document Reality (not hard requirements)**

- Goal: Find the **actual limits** of the system
- If we can only handle 500 EPS instead of 1,000 EPS → document it
- Recommend resource adjustments based on findings
- Don't spend weeks optimizing to hit arbitrary targets

**Rationale:** M2 is about discovery, not forcing performance targets

### 5. ✅ Test Data Scale

**Decision: Multiple scales to reach upper limit**

Test progression (from small to breaking point):
```
Scale 1: Small Baseline
  - 1,000 users
  - 10 challenges
  - 10 goals per challenge
  - Existing records: 5,000 (50% of users have progress)

Scale 2: Medium Load
  - 10,000 users
  - 10 challenges
  - 50 goals per challenge
  - Existing records: 50,000

Scale 3: Large Load
  - 50,000 users
  - 10 challenges
  - 50 goals per challenge
  - Existing records: 250,000

Scale 4: Breaking Point
  - Keep increasing until system breaks
  - Document max sustainable load
```

**Rationale:** Identify where performance degrades, find actual capacity

### 6. ✅ Optimization Iteration Limit

**Decision: TBD (will decide after baseline measurement)**

- Run baseline tests first
- Identify bottlenecks
- Then decide how many optimization passes to do

**Rationale:** Can't plan optimizations without knowing what's slow

### 7. ✅ Database Resource Configuration

**Decision: 2 CPU, 4 GB RAM for PostgreSQL**

- Reflects realistic production DB deployment
- Not unlimited (simulates real constraints)
- Not severely limited (avoids testing DB limits)

**Rationale:** Balance between realistic and performance-focused testing

### 8. ✅ Combined Load Test Matrix

**Decision: Simplified test matrix**

**Fixed Variables:**
- Deployment: Local docker-compose only
- Challenges: 10 challenges
- Goals per challenge: 50 goals
- Users: Start at 10,000, increase to find limit

**Variable Parameters:**
```
API Request Rate (RPS):
  - 50, 100, 200, 500, 1000, 2000, 5000 (until breaking)

Event Rate (EPS):
  - 100, 500, 1000, 2000, 5000, 10000 (until breaking)
```

**Test Strategy:**
- Start with low rates, gradually increase
- For each EPS level, test all API rates
- Stop when error rate > 1% or latency > 10x baseline
- Document maximum sustainable combination

**Estimated Test Combinations:** 7 API rates × 6 Event rates = **42 combinations** (but we'll stop at breaking point)

**Rationale:** Focus on finding limits, not exhaustive testing

### 9. ✅ Deliverables Detail Level

**Decision: Moderate detail, focus on upper limits**

Each deliverable should:
- Be 5-10 pages
- Include key graphs and data tables
- Focus on **maximum capacity** findings
- Provide actionable recommendations
- Avoid overwhelming raw data dumps

**Deliverables:**
1. **Performance Baseline Report**
   - Maximum RPS achieved (with error rate < 1%)
   - Maximum EPS achieved (with latency < threshold)
   - Maximum combined load (RPS + EPS)
   - Bottleneck identification

2. **Capacity Planning Guide**
   - Recommended limits for docker-compose deployment
   - Resource scaling recommendations
   - Cost/performance tradeoffs

3. **Performance Tuning Guide**
   - Configuration optimizations
   - Database tuning tips
   - Code-level improvements

**Rationale:** Actionable insights, not academic research

---

## Updated Test Scenarios

### Removed Scenarios

- ❌ **Scenario 6:** Realistic User Patterns (not needed - just find limits)
- ❌ **Scenario 9:** Failure Scenarios (out of scope for M2)

### Retained Scenarios (Original Plan)

- ✅ **Scenario 1:** API Load Testing (isolated)
- ✅ **Scenario 2:** Event Processing Load (isolated)
- ✅ **Scenario 3:** Memory Profiling
- ✅ **Scenario 4:** CPU Profiling

### Enhanced Scenarios

- ✅ **Scenario 5:** Combined Load Testing ← **CRITICAL ADDITION**
- ✅ **Scenario 7:** Database Performance Deep Dive
- ✅ **Scenario 8:** End-to-End Latency Testing

---

## Final Configuration Decisions (2025-10-23 - Part 2)

### 10. ✅ Test Duration

**Decision: Progressive duration based on test type**

- **Setup validation tests:** 5 minutes (quick feedback, verify configuration)
- **Real performance tests:** 30 minutes (sustained load, memory leak detection)
- **Rationale:** Short tests for iteration speed, long tests for stability validation

**Test Phases:**
```
Phase 1: Setup validation (5 min each)
  - Verify k6 can hit API
  - Verify k6 can hit gRPC event handler
  - Verify metrics collection works

Phase 2: Performance testing (30 min each)
  - All 7 scenarios use 30-minute duration
  - Sufficient for buffer flush patterns
  - Catches memory leaks and GC issues
```

### 11. ✅ Event Buffer Configuration

**Decision: Fix buffer parameters (discover issues on the fly)**

- **Flush interval:** Fixed at **1 second**
- **Buffer size limit:** Fixed at **100,000 entries**
- **Adjustment strategy:** If bottleneck identified, adjust and re-test

**Rationale:** Don't over-optimize before finding actual bottlenecks

### 12. ✅ Database Connection Pool

**Decision: Fix at 50 connections (adjust if needed)**

- **Initial pool size:** 50 connections
- **Adjustment:** Only change if database connection contention identified
- **Monitoring:** Track pool utilization during tests

**Rationale:** Standard starting point, adjust based on data

### 13. ✅ Metrics Collection Setup

**Decision: k6 built-in web dashboard (no Prometheus/Grafana needed)**

- **Primary tool:** k6 with `--web-dashboard` flag
- **Access:** Real-time dashboard at `http://localhost:5665`
- **Export:** JSON summary after test completion
- **Additional:** Docker stats for resource monitoring

**Why k6 Web Dashboard:**
- ✅ Built-in, no extra setup
- ✅ Real-time metrics visualization
- ✅ p50, p95, p99 latencies automatically calculated
- ✅ Request rate, error rate, data transfer metrics
- ✅ Timeline graphs and trends
- ❌ No need for Prometheus + Grafana complexity

**Reference:** https://grafana.com/docs/k6/latest/results-output/web-dashboard/

**Metrics to Track:**
```
From k6 dashboard:
  - HTTP request duration (p50, p95, p99)
  - gRPC request duration (p50, p95, p99)
  - Request rate (RPS, EPS)
  - Error rate (%)
  - Data sent/received

From docker stats:
  - CPU usage (%)
  - Memory usage (MB)
  - Network I/O

From PostgreSQL pg_stat_statements:
  - Query execution time
  - Connection pool usage
```

### 14. ✅ Test Progression Strategy

**Decision: Discrete levels (predefined load steps)**

**Progression:**
```
Level 1: Baseline (light load)
  - API: 50 RPS
  - Events: 100 EPS

Level 2: Low load
  - API: 100 RPS
  - Events: 500 EPS

Level 3: Medium load
  - API: 200 RPS
  - Events: 1,000 EPS

Level 4: High load
  - API: 500 RPS
  - Events: 2,000 EPS

Level 5: Very high load
  - API: 1,000 RPS
  - Events: 5,000 EPS

Level 6+: Push to limit
  - API: 2,000, 5,000 RPS
  - Events: 10,000, 20,000 EPS
  - Stop when system breaks
```

**Rationale:** Clear steps, easy to compare, predictable progression

### 15. ✅ Upper Limit Definition

**Decision: Combination of latency and error rate**

**System at limit when ANY of:**
- ✅ **Error rate > 1%** (unacceptable for production)
- ✅ **API p95 latency > 2 seconds** (10x baseline of 200ms)
- ✅ **Event processing p95 > 500ms** (10x baseline of 50ms)

**Do NOT use resource exhaustion alone:**
- ❌ CPU at 95% doesn't mean system is failing (might be efficient)
- ❌ Memory at 90% is OK if stable (no leaks)

**Rationale:** User-facing metrics matter more than resource utilization

### 16. ✅ Mock AGS Latency Configuration

**Decision: Typical latency (50-200ms)**

- **Mock response time:** Random between **50-200ms**
- **Simulates:** Real AGS Platform Service behavior
- **Implementation:** `time.Sleep(50ms + rand.Intn(150ms))`

**Rationale:** Realistic without being pessimistic

---

## Load Testing Tool Decision

### Decision: ✅ k6 for Both REST and gRPC

**Tool:** k6 (https://k6.io)

**Why k6:**
1. ✅ **Unified tool** - Supports both HTTP and gRPC natively
2. ✅ **Built-in metrics** - p50, p95, p99, RPS, error rates automatic
3. ✅ **Web dashboard** - Real-time visualization without Prometheus/Grafana
4. ✅ **Combined scenarios** - Can run REST + gRPC load simultaneously
5. ✅ **Thresholds** - Automatic pass/fail criteria
6. ✅ **Well documented** - Large community, many examples
7. ✅ **Fast setup** - No custom metrics implementation needed

**k6 Capabilities:**
```javascript
import http from 'k6/http';      // REST API load
import grpc from 'k6/net/grpc';  // gRPC event load

// Scenario 5: Combined load
export let options = {
  scenarios: {
    api_load: {
      executor: 'constant-arrival-rate',
      rate: 500,  // 500 RPS
      duration: '30m',
      exec: 'apiTest',
    },
    event_load: {
      executor: 'constant-arrival-rate',
      rate: 2000,  // 2,000 EPS
      duration: '30m',
      exec: 'eventTest',
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<2000'],  // Fail if p95 > 2s
    'http_req_failed': ['rate<0.01'],     // Fail if error rate > 1%
  },
};
```

**Running k6 with Web Dashboard:**
```bash
k6 run --web-dashboard --out json=results.json scenario5_combined.js

# Access dashboard at: http://localhost:5665
# Real-time graphs, metrics, timeline
```

**Alternatives Considered:**
- ❌ Custom Go tool: More work, need to implement metrics
- ❌ ghz + k6: Two separate tools, harder to coordinate
- ❌ Prometheus + Grafana: Over-engineering, k6 dashboard is sufficient

**Project Structure:**
```
test/
├── k6/
│   ├── scenario1_api_isolated.js
│   ├── scenario2_events_isolated.js
│   ├── scenario3_memory_profile.js
│   ├── scenario4_cpu_profile.js
│   ├── scenario5_combined.js          ← Critical
│   ├── scenario7_db_deep_dive.js
│   ├── scenario8_e2e_latency.js
│   ├── helpers/
│   │   ├── jwt.js                     # JWT token generation
│   │   ├── users.js                   # User pool data
│   │   └── challenges.js              # Challenge config
│   └── README.md
├── fixtures/
│   ├── users.json                     # 10,000 test users
│   └── challenges.json                # 10 challenges, 50 goals
└── scripts/
    ├── run_all_scenarios.sh
    └── generate_fixtures.sh
```

---

## Implementation Details Decisions (2025-10-23 - Part 3)

### 17. ✅ JWT Token Generation for k6

**Decision: Pre-generate real AGS IAM tokens with automatic refresh**

- Generate real JWT tokens from AGS IAM service
- Save to `test/fixtures/tokens.json`
- Load in k6 scripts
- **Automatic token refresh** when expired (tokens typically valid 1-24 hours)

**Implementation:**
```bash
# Script to generate tokens
test/scripts/generate_tokens.sh

# Calls AGS IAM API to get real tokens for test users
# Saves to fixtures/tokens.json
```

**Token Management for Long Tests:**
- Tests can run for 30+ minutes
- Tokens may expire during test
- Need automatic refresh mechanism

**Options for auto-refresh:**

**Option A: Pre-generate long-lived tokens**
- Request tokens with max expiration (24 hours)
- Sufficient for test duration
- Regenerate manually between test runs

**Option B: Token refresh in k6**
- k6 checks token expiration before each request
- Calls refresh endpoint if expired
- More complex, requires token management logic in JavaScript

**Option C: Token refresh service**
- Small Go service that proxies token requests
- Automatically refreshes tokens when needed
- k6 calls proxy instead of direct API
- Cleaner separation of concerns

**Recommendation: Option A for M2** (simplest)
- Request 24-hour tokens from AGS IAM
- Sufficient for all test scenarios (max 30 min each)
- If tokens expire between test runs, regenerate with script

**Future: Option C if needed** (if tests span multiple days)

**Rationale:** Simplest approach for M2, can enhance later if needed

### 18. ✅ Database Seeding Strategy

**Decision: No pre-seeding (start with empty database)**

- Database starts empty
- Records created on-demand as events are processed
- Simulates fresh deployment scenario

**Rationale:**
- Simpler setup
- Tests lazy initialization (realistic for new users)
- Can still test with existing data by running load test twice (second run has data from first)

### 19. ✅ Docker Resource Limits

**Decision: Add CPU and memory limits to services**

Update `docker-compose.yml`:
```yaml
challenge-service:
  deploy:
    resources:
      limits:
        cpus: '1.0'
        memory: 1G
      reservations:
        cpus: '0.5'
        memory: 512M

challenge-event-handler:
  deploy:
    resources:
      limits:
        cpus: '1.0'
        memory: 1G
      reservations:
        cpus: '0.5'
        memory: 512M

postgres:
  deploy:
    resources:
      limits:
        cpus: '2.0'
        memory: 4G
      reservations:
        cpus: '1.0'
        memory: 2G
```

**Rationale:** Simulates resource-constrained deployment, finds real limits

### 20. ✅ Memory/CPU Profiling Integration

**Decision: Profile during Scenario 5 (no separate scenarios)**

**Approach:**
- Run Scenario 5 (combined load)
- While k6 runs, collect pprof data
- No separate Scenario 3 & 4

**Commands (run while k6 is running):**
```bash
# CPU profile (30 seconds)
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30

# Memory heap profile
go tool pprof http://localhost:8080/debug/pprof/heap

# Goroutine profile
go tool pprof http://localhost:8080/debug/pprof/goroutine
```

**Rationale:** More realistic profiling under actual load, reduces test scenarios from 7 to 5

### 21. ✅ Database Performance Analysis

**Decision: Manual queries during/after tests**

**During test:**
```bash
# Monitor live queries
watch -n 5 "psql -U postgres -d challenge_db -c \"
  SELECT query, calls, mean_exec_time, max_exec_time
  FROM pg_stat_statements
  WHERE query LIKE '%user_goal_progress%'
  ORDER BY mean_exec_time DESC
  LIMIT 10;
\""
```

**After test:**
```bash
# Full analysis
psql -U postgres -d challenge_db -f test/scripts/analyze_db_performance.sql
```

**Rationale:** Flexible, can investigate on-the-fly, no complex automation needed

### 22. ✅ Mock AGS Platform Service

**Decision: Built into backend service (feature flag)**

**Already implemented:**
```go
// Backend service already has mock
if os.Getenv("MOCK_AGS") == "true" {
    rewardClient = NewMockRewardClient()
}
```

**Configuration:**
```env
# .env for load testing
MOCK_AGS=true
MOCK_AGS_LATENCY_MS=100  # Random 50-200ms
```

**Rationale:** Already exists, simple feature flag, no extra service needed

### 23. ✅ E2E Latency Measurement

**Decision: Measure buffer flush time only**

**Approach:**
- E2E latency = Event processing time + Buffer flush interval
- Event processing: < 50ms (target)
- Buffer flush interval: 1 second (fixed)
- **Expected E2E latency: ~1 second** (worst case)

**Measurement:**
```
Best case: Event arrives just before flush → ~50ms delay
Worst case: Event arrives just after flush → ~1,050ms delay
Average: ~500ms delay
```

**No need for complex k6 polling**, just document buffer flush as E2E delay.

**Rationale:** Simpler, buffer flush time is the dominant factor

---

## Updated Test Scenarios

After merging profiling and simplifying E2E:

### Final Scenarios (5 total)

1. ✅ **Scenario 1:** API Load Testing (isolated) - 30 min
2. ✅ **Scenario 2:** Event Processing Load (isolated) - 30 min
3. ✅ **Scenario 3:** Combined Load Testing (API + Events) - 30 min ← **CRITICAL**
   - **Profiling done during this scenario** (CPU, memory, goroutines)
4. ✅ **Scenario 4:** Database Performance Deep Dive - 30 min
   - Same as Scenario 3, but with active database monitoring
5. ✅ **Scenario 5:** E2E Latency Validation - 5 min
   - Measure: Event processing time + flush interval
   - Expected: ~1 second (buffer flush dominant)

**Removed scenarios:**
- ❌ Memory Profiling (merged into Scenario 3)
- ❌ CPU Profiling (merged into Scenario 3)

---

## CRITICAL: Event Concurrency Behavior (CORRECTED 2025-10-23)

### ❌ Previous Understanding (WRONG)
- Extend platform batches 500 events into 1 gRPC call
- Sequential processing (wait for response before next batch)

### ✅ Actual Extend Platform Behavior (CORRECT)

**Extend platform uses concurrent streaming:**
```
1. Extend platform opens 1 persistent gRPC connection
2. Receives events from Kafka
3. Calls OnMessage() up to 500 times CONCURRENTLY
4. Each OnMessage = 1 event = 1 gRPC call
5. All 500 calls happen in parallel (not sequential)
```

**Example:**
```
T=0s: 2,000 events arrive from Kafka
T=0s: Extend opens gRPC connection (if not already open)
T=0s: Calls OnMessage() 500 times concurrently (first wave)
T=0.05s: First wave completes (500 concurrent calls processed)
T=0.05s: Calls OnMessage() 500 times concurrently (second wave)
T=0.10s: Second wave completes
T=0.10s: Calls OnMessage() 500 times concurrently (third wave)
T=0.15s: Third wave completes
T=0.15s: Calls OnMessage() 500 times concurrently (fourth wave)
T=0.20s: Fourth wave completes

Total: 2,000 events processed in ~200ms (with concurrency)
```

### Implications for Load Testing

**Previous wrong assumption:**
- 2,000 EPS = 4 batches/sec = 4 gRPC calls/sec
- Batch processing time is bottleneck

**Correct behavior:**
- 2,000 EPS = 2,000 gRPC calls/sec
- **Up to 500 concurrent calls at a time**
- Each call processes 1 event
- Concurrency handling is critical

### Updated k6 Event Load Strategy

**Scenario 2 & 3 must simulate concurrent calls:**

```javascript
import grpc from 'k6/net/grpc';

const MAX_CONCURRENT_EVENTS = 500;
const EVENTS_PER_SECOND = 2000;

export let options = {
  scenarios: {
    event_concurrency: {
      executor: 'constant-arrival-rate',
      rate: EVENTS_PER_SECOND,  // 2,000 events/sec
      duration: '30m',
      preAllocatedVUs: MAX_CONCURRENT_EVENTS,  // 500 VUs (virtual users)
      maxVUs: MAX_CONCURRENT_EVENTS,
    },
  },
};

export default function() {
  const client = new grpc.Client();
  client.connect('localhost:6566', { timeout: '10s' });

  // Generate single event
  const event = {
    eventName: 'statItemUpdated',
    namespace: 'test',
    userId: randomUser(),
    payload: {
      statCode: 'enemy_kills',
      value: Math.floor(Math.random() * 100),
    },
  };

  // Send single event via OnMessage
  const response = client.invoke('EventService/OnMessage', event);

  check(response, {
    'event processed successfully': (r) => r && r.status === grpc.StatusOK,
  });

  client.close();
}
```

**Key k6 configuration:**
- `preAllocatedVUs: 500` - Allows up to 500 concurrent requests
- `rate: 2000` - Target 2,000 events/sec
- k6 will automatically distribute load across VUs

### Event Handler gRPC Proto (No Changes Needed)

**Already correct:**

```protobuf
service EventService {
  // Single event handler (actual Extend platform behavior)
  rpc OnMessage(Event) returns (EventResponse);
}

message Event {
  string event_name = 1;
  string namespace = 2;
  string user_id = 3;
  map<string, string> payload = 4;
}

message EventResponse {
  bool success = 1;
  string error = 2;
}
```

**No batch endpoint needed** - Extend platform calls OnMessage concurrently.

### Performance Implications

**Concurrency model:**
- Event handler must handle **up to 500 concurrent OnMessage calls**
- Each call processes 1 event → buffers progress update
- Concurrent calls share resources (DB pool, memory, CPU)

**Bottleneck changes:**
- ✅ **Concurrency handling** becomes critical (goroutine management)
- ✅ **Per-user mutex** prevents race conditions
- ✅ **Buffer management** under concurrent load
- ✅ **Database connection pool** must handle concurrent writes

**New performance targets:**
- **Single event processing: < 50ms** (p95)
- **Concurrent capacity: 500 simultaneous events**
- **Sustained throughput: 2,000+ events/sec**
- **No goroutine leaks** under load

**Resource contention:**
- 500 concurrent goroutines processing events
- Each goroutine needs:
  - Per-user mutex lock
  - Buffer map access
  - Potential database connection (if buffer full)

### Updated Event Processing Flow

```
1. Extend Platform receives 2,000 events from Kafka
2. Opens persistent gRPC connection to event handler
3. Calls OnMessage() 500 times concurrently (first wave)
4. Event Handler (for each concurrent call):
   a. Acquire per-user mutex
   b. Process event (update progress in buffer)
   c. Release mutex
   d. Return success response
5. Extend Platform calls next 500 OnMessage() (second wave)
6. Repeat until all events processed

Parallel to above:
7. Buffer flush goroutine runs every 1 second
8. Flushes all buffered updates to database (batch UPSERT)
```

### Load Test Implications

**Scenario 2 (Event Load Isolated):**
- Test concurrency levels: 100, 250, 500 concurrent calls
- Measure single event processing time
- Find max sustainable EPS with 500 concurrent limit
- Monitor goroutine count, memory usage

**Scenario 3 (Combined Load):**
- API load + Concurrent event load
- Monitor resource contention (DB pool, CPU, memory)
- Test if 500 concurrent event calls impact API latency

**Critical Questions to Answer:**
1. How fast can handler process single event under concurrency?
2. What's the max sustained EPS with 500 concurrent limit?
3. Does concurrent event processing starve API requests?
4. Are there goroutine leaks or memory leaks?
5. Does per-user mutex cause bottlenecks?

---

## Next Steps

1. ✅ **All decisions documented** (23 decisions total)
2. **Write TECH_SPEC_M2.md** - Detailed technical specification
3. **Implement event handler batch processing** - Update gRPC proto and handler
4. **Write k6 test scripts** - 5 scenarios with batching support
5. **Update docker-compose.yml** - Add resource limits
6. **Create test fixtures** - Generate JWT tokens, user pools
7. **Execute load tests** - Find actual system limits
8. **Document findings** - 3 deliverables (Performance Report, Capacity Planning, Tuning Guide)

---

## Summary: Finalized M2 Plan

### Core Scenarios (5 total)

1. **Scenario 1:** API Load Testing (isolated) - 30 min
   - Test GET /v1/challenges and POST /claim endpoints
   - Find max sustainable RPS (requests per second)

2. **Scenario 2:** Event Processing Load (isolated) - 30 min
   - Test event batching (up to 500 events per batch)
   - Find max sustainable batches/sec
   - **Critical:** Must simulate Extend platform batching behavior

3. **Scenario 3:** Combined Load Testing - 30 min ← **MOST CRITICAL**
   - Run API + Event load simultaneously
   - Profile CPU, memory, goroutines during this test
   - Identify resource contention

4. **Scenario 4:** Database Performance Deep Dive - 30 min
   - Same as Scenario 3 with active database monitoring
   - Analyze query performance with pg_stat_statements
   - Identify slow queries and index effectiveness

5. **Scenario 5:** E2E Latency Validation - 5 min
   - Measure event processing time
   - Document buffer flush latency (~1 second)

### Test Environment

**Deployment:**
- Local docker-compose deployment
- Backend Service: 1 CPU, 1 GB RAM (limits enforced)
- Event Handler: 1 CPU, 1 GB RAM (limits enforced)
- PostgreSQL: 2 CPU, 4 GB RAM
- Mock AGS Platform Service (50-200ms latency)

**Configuration:**
- 10 challenges, 50 goals each
- Empty database (no pre-seeding)
- Buffer flush interval: 1 second
- DB connection pool: 50 connections

**Load Variables:**
- API Request Rate: 50, 100, 200, 500, 1000, 2000, 5000 RPS
- Event Rate: 100, 500, 1000, 2000, 5000, 10000 EPS
- Max Concurrent Events: **500 concurrent OnMessage calls** (Extend platform limit)

### Critical Discovery: Event Concurrency (CORRECTED)

**Extend Platform Behavior:**
- Opens 1 persistent gRPC connection
- Calls OnMessage() up to **500 times CONCURRENTLY**
- Each call processes 1 event
- **Parallel processing**, not sequential batching

**Implication:**
- 2,000 EPS = 2,000 gRPC calls/sec (NOT batched)
- **Up to 500 concurrent calls at a time**
- **Concurrency handling becomes critical**
- Per-user mutex, buffer management, goroutine management

**New Performance Targets:**
- Single event processing: < 50ms (p95)
- Concurrent capacity: 500 simultaneous events
- Sustained throughput: 2,000+ events/sec
- No goroutine/memory leaks under load

### Load Testing Tools

**k6 for everything:**
- ✅ HTTP (REST API load)
- ✅ gRPC (Event batch load)
- ✅ Built-in web dashboard (real-time metrics)
- ✅ Combined scenarios (run API + Events in parallel)

**Additional tools:**
- `go tool pprof` - CPU/memory profiling during tests
- `docker stats` - Resource monitoring
- `pg_stat_statements` - Database query analysis

### Goals

- Find **maximum sustainable RPS** (API)
- Find **maximum sustainable batches/sec** (Events)
- Find **maximum combined load** (API + Events)
- Identify **bottlenecks** (CPU, memory, DB, network)
- Document **actual limits** (not force arbitrary targets)
- Provide **scaling recommendations**

### Upper Limit Definition

System at limit when:
- ✅ Error rate > 1%
- ✅ API p95 latency > 2 seconds
- ✅ Event processing p95 > 500ms

### Deliverables

1. **Performance Baseline Report** (5-10 pages)
   - Maximum RPS achieved
   - Maximum batches/sec achieved
   - Maximum combined load
   - Bottleneck identification
   - Resource utilization graphs

2. **Capacity Planning Guide** (5-10 pages)
   - Recommended limits for docker-compose deployment
   - Horizontal vs vertical scaling recommendations
   - Cost/performance tradeoffs

3. **Performance Tuning Guide** (5-10 pages)
   - Configuration optimizations
   - Database tuning tips
   - Code-level improvements identified

### Duration

- **Setup:** 2-3 days (write k6 scripts, token generation, docker config)
- **Testing:** 1+ weeks (run 5 scenarios at multiple load levels)
  - 5 scenarios × ~6 load levels = 30 test runs
  - Each test run: 30 minutes (some 5 minutes)
  - Total test time: ~15 hours of active testing
  - **Long test duration is acceptable** - track progress systematically
- **Analysis:** 3-5 days (profiling, optimization, documentation)
- **Total:** 2-3+ weeks (flexible timeline, no hard deadline)

**Timeline Philosophy:**
- ✅ **No pressure on timeline** - focus on thoroughness
- ✅ **Long tests are OK** - 30 min per test is fine
- ✅ **Track progress** - Document which tests completed, results captured
- ✅ **Quality over speed** - Better to test properly than rush

**Progress Tracking:**
```
Test Progress Log (example):
- [x] Scenario 1, Level 1 (50 RPS) - Complete, p95=45ms
- [x] Scenario 1, Level 2 (100 RPS) - Complete, p95=67ms
- [x] Scenario 1, Level 3 (200 RPS) - Complete, p95=123ms
- [ ] Scenario 1, Level 4 (500 RPS) - In progress...
```

---

## Ready for Tech Spec

All decisions are finalized. The following are locked in:

✅ **23 configuration decisions** documented
✅ **5 test scenarios** defined
✅ **Event concurrency behavior** understood and corrected (500 concurrent OnMessage calls)
✅ **k6 tool selection** with web dashboard
✅ **Resource limits** defined
✅ **Performance targets** set (but flexible - document reality)
✅ **Deliverables** scoped
✅ **Token management** strategy defined (24-hour tokens, manual refresh between runs)
✅ **Timeline** flexible (no pressure, long tests OK, track progress)

**Key Corrections Made:**
- ❌ Previous: Event batching (500 events per batch, sequential)
- ✅ Correct: Event concurrency (500 concurrent calls, parallel)
- This changes k6 implementation (use VUs, not batching)
- No new gRPC endpoint needed (OnMessage already exists)

**Additional Clarifications:**
- Token refresh: Use 24-hour tokens, regenerate as needed
- Long tests: 30 min per test is acceptable, ~15 hours total
- No timeline pressure: Quality over speed
- Progress tracking: Document each test result systematically

**Next action:** Write comprehensive `TECH_SPEC_M2.md` with:
- Detailed scenario descriptions with k6 scripts
- Concurrency-based event load simulation
- Token generation scripts
- Docker resource limit configuration
- Step-by-step execution guide
- Metrics collection procedures
- Analysis and reporting templates
