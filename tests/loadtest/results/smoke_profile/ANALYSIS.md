# Smoke Test Profiling Analysis

**Date:** 2026-03-02
**Branch:** M5-Rotation
**Test:** `scenario3_smoke.js` (100 RPS API, 200 EPS events, 5 min)
**Config:** 600 goals (loadtest fixtures)

## 1. Per-Endpoint Latency Breakdown

| Endpoint | Count | Avg | p50 | p90 | p95 | p99 | Max | Threshold | Result |
|----------|-------|-----|-----|-----|-----|-----|-----|-----------|--------|
| list_challenges | 20,251 | 5.7ms | 2.8ms | 7.3ms | 11.7ms | 56.1ms | 905ms | — | — |
| batch_select | 1,118 | 55.8ms | 4.1ms | 24.1ms | **113.8ms** | 1,821ms | 4,058ms | p95<100ms | FAIL |
| claim | 871 | 52.7ms | 4.1ms | 22.2ms | **114.6ms** | 1,634ms | 3,981ms | p95<100ms | FAIL |
| set_active | 2,250 | 57.5ms | 3.0ms | 19.3ms | **123.0ms** | 1,357ms | 4,277ms | p95<100ms | FAIL |
| login_event | 8,652 | 47.3ms | 0.5ms | 2.5ms | 19.2ms | 1,489ms | 4,399ms | — | — |
| stat_event | 34,371 | 41.0ms | 0.5ms | 2.2ms | 8.3ms | 1,326ms | 4,482ms | — | — |

**Key pattern:** p50 is fast (2.8-4.1ms), p90 is reasonable (19-24ms), but p95 jumps to 113-123ms and p99 explodes to 1.3-1.8s. This "long tail" pattern is classic GC/contention behavior.

## 2. CPU Hotspots

### Challenge Service (26.34% CPU utilization)

| Function | Flat | Cumulative | % of CPU |
|----------|------|-----------|----------|
| `processGoalsArray` | 0.98s | 1.67s | 21.0% |
| `Syscall6` (network I/O) | 1.31s | 1.31s | 16.5% |
| **GC (gcDrain + scanobject)** | 0.35s | **2.60s** | **32.7%** |
| `mallocgc` (allocations) | 0.08s | 0.96s | 12.1% |
| `GetUserProgress` + `scanProgressRows` | 0.03s | 1.23s | 15.5% |

**Finding:** GC consumes **32.7% of service CPU** — nearly a third of all CPU time is spent on garbage collection, not serving requests.

### Event Handler (22.26% CPU utilization)

| Function | Flat | Cumulative | % of CPU |
|----------|------|-----------|----------|
| `BufferedRepository.Flush` | 0.05s | 2.88s | 42.9% |
| `BatchUpsertProgressWithCOPY` | — | 2.48s | 37.0% |
| `Syscall6` (network I/O) | 1.54s | 1.54s | 23.0% |
| `mallocgc` | 0.07s | 1.09s | 16.2% |

**Finding:** Handler is healthy — almost all CPU goes to batch UPSERT operations as intended.

## 3. Memory Allocation Patterns

### Service (total allocations during profile window)

| Allocator | Total Alloc | % of Total |
|-----------|------------|------------|
| `InjectProgressIntoChallenge` | 2,202 MB | 23.8% |
| `InjectProgressIntoGoal` | 2,167 MB | 23.4% |
| `BuildChallengesResponse` | 2,159 MB | 23.3% |
| **Total JSON response building** | **6,528 MB** | **70.5%** |
| `scanProgressRows` (DB) | 917 MB | 9.9% |
| `convertAssignRows` (DB) | 534 MB | 5.8% |

**Finding:** The JSON injection code allocates **6.5 GB in 5 minutes** despite current in-use heap being only 3.94 MB. This means the GC must run thousands of times to reclaim these short-lived allocations, causing stop-the-world pauses that spike tail latency.

**Per-request estimate:** 20,251 list_challenges requests / 5 min = ~67 RPS. At 6,528 MB total = ~1.6 MB allocated per list_challenges request (600 goals × multiple buffer copies).

### Handler (total allocations)

| Allocator | Total Alloc | % of Total |
|-----------|------------|------------|
| `driverArgsConnLocked` | 1,439 MB | 27.1% |
| `prepareCopyIn` | 708 MB | 13.4% |
| `namedValueToValue` | 513 MB | 9.7% |

Handler allocations are expected and are dominated by database driver operations for the COPY-based batch inserts.

## 4. Lock Contention Analysis

**Both services show ZERO mutex contention.** The per-user mutex in the event handler is not a bottleneck, and the service has no mutex contention.

## 5. Goroutine Analysis

| Service | Goroutine Count | Status |
|---------|----------------|--------|
| Challenge Service | 129 | Healthy (mostly idle HTTP listeners) |
| Event Handler | 1,228 | Elevated but stable (~134 gRPC connections × 3 goroutines each) |

No goroutine explosion detected.

## 6. DB Query Performance

### Connection Pool

- **29 idle + 6 active = 35 total connections** — Pool is NOT saturated.

### Index Usage

- **seq_scan: 12** vs **idx_scan: 48,248,792** — 99.99% index usage. Excellent.

### Top Queries by Total Time

| Query | Calls | Mean (ms) | Max (ms) | Total (s) |
|-------|-------|-----------|----------|-----------|
| COPY temp_event_progress | 197,959 | 1.73 | 288 | 342.0 |
| CREATE TEMP TABLE | 197,959 | 1.25 | **675** | 247.4 |
| INSERT INTO (batch upsert) | 8,852 | 4.81 | 297 | 42.6 |
| SELECT (GetUserProgress) | 92,045 | 0.44 | **622** | 40.1 |
| SELECT (GetUserProgress 2) | 82,645 | 0.42 | **570** | 35.0 |
| SELECT (filtered) | 43,904 | 0.47 | 299 | 20.6 |
| SELECT COUNT(*) | 52,894 | 0.18 | **600** | 9.7 |
| INSERT (initialize) | 1,828 | 2.57 | 11 | 4.7 |
| UPDATE (set_active) | 34,310 | 0.12 | **575** | 4.2 |

**Finding:** Mean query times are excellent (0.12-4.81ms), but MAX times are alarming (297-675ms). The max spikes on SELECT/UPDATE queries correlate with the buffer flush operations that create temp tables and do bulk inserts, causing transient lock contention.

## 7. Root Cause Determination

### Primary: GC Pressure from JSON Response Building (Service)

The `BuildChallengesResponse` → `InjectProgressIntoChallenge` → `processGoalsArray` → `InjectProgressIntoGoal` pipeline allocates **~1.6 MB per list_challenges request** across multiple intermediate buffer copies:

1. `InjectProgressIntoChallenge` allocates a `bytes.Buffer` per challenge
2. `processGoalsArray` iterates 600 goals, calling `InjectProgressIntoGoal` for each
3. `InjectProgressIntoGoal` allocates a `result` slice + `buildProgressFields` allocates a `bytes.Buffer` per goal
4. `BuildChallengesResponse` allocates another `bytes.Buffer` for the final response

At 67 RPS, this produces **107 MB/sec of garbage**, forcing the GC to run aggressively. GC stop-the-world pauses (typically 0.1-1ms each, but potentially 10-50ms under pressure) cause the latency spikes visible at p95.

**Why it affects batch_select/claim/set_active:** All endpoints share the same Go process. When GC pauses to scan/sweep, ALL goroutines are stopped — including those handling batch_select, claim, and set_active requests. The 62% of traffic that's list_challenges creates the GC pressure that spikes latency on the 38% of traffic that's other endpoints.

### Secondary: Database Contention During Buffer Flushes (Handler → Service)

The event handler's 1-second buffer flush creates temp tables and bulk inserts that occasionally block concurrent SELECT queries:
- CREATE TEMP TABLE max: 675ms
- SELECT max: 622ms
- These correlate temporally — a slow flush blocks SELECTs

This explains the extreme p99 tail (1.3-4s): when a large buffer flush coincides with a batch_select/claim/set_active query, the API request waits for the database operation to complete.

## 8. Recommended Fixes (Priority Order)

### Fix 1: Reduce GC Pressure (High Impact, Low Risk)

**Option A — Tune GOGC:** Set `GOGC=200` (or higher) in Docker environment. This doubles the heap size before GC triggers, reducing GC frequency by ~50%.

```yaml
environment:
  GOGC: "200"
```

**Option B — Use GOMEMLIMIT:** Set `GOMEMLIMIT=256MiB` to let Go use more memory before triggering GC, combined with `GOGC=off` for maximum throughput.

**Option C — Pool buffers:** Use `sync.Pool` for the `bytes.Buffer` allocations in `InjectProgressIntoGoal` and `buildProgressFields` to reuse buffers instead of allocating new ones.

### Fix 2: Reduce Allocations in Hot Path (High Impact, Medium Effort)

- Pre-allocate a single large buffer per request in `BuildChallengesResponse` and pass it down
- Avoid the intermediate `[]byte` copy in `InjectProgressIntoGoal` — write directly to the parent buffer
- Replace `string(goalJSON[...])` in `extractGoalID` with a byte comparison (avoids heap allocation)

### Fix 3: Isolate DB Operations (Medium Impact, Low Risk)

- Use separate connection pools for read (API queries) and write (buffer flushes)
- This prevents flush operations from starving API queries for connections

### Fix 4: Relax Thresholds (Pragmatic)

The current thresholds (p95 < 100ms) may be overly aggressive for a smoke test with 600 goals. Consider:
- Raising smoke test thresholds to p95 < 200ms (the existing `list_challenges` threshold)
- Or reducing the goal count in smoke tests to match the expected production workload
