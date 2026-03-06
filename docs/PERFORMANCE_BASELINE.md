# Performance Baseline Report

**Last Updated:** 2026-02-28 (M5 — Time-Based Rotation)
**Test Duration:** 30 minutes per scenario
**Environment:** Local docker-compose
**Resources:** 1 CPU / 1 GB per service, 2 CPU / 4 GB database

---

## Glossary

| Term | Meaning |
|------|---------|
| **p50 / p95 / p99** | Percentile latencies. p95 = 95% of requests completed within this time. |
| **EPS** | Events Per Second — rate of incoming gRPC events from the Extend platform. |
| **RPS** | Requests Per Second — rate of incoming HTTP API requests. |
| **VU** | Virtual User — a simulated concurrent user in k6 load tests. |
| **COPY** | PostgreSQL bulk-insert protocol used by the batch UPSERT flush path. |
| **mean_exec_time** | Average time to execute a single database query (milliseconds). |
| **max_exec_time** | Longest single execution of a database query (milliseconds). |
| **Index Scan** | Database reads a specific row via an index (fast, targeted lookup). |
| **Sequential Scan** | Database reads every row in a table to find matches (slower, full scan). |

---

## Executive Summary

Maximum sustainable capacity under resource constraints (M5 with rotation):
- **Event Processing:** 500 EPS sustained (gRPC p95 = 0.60ms)
- **Concurrent Users:** 150 VUs with realistic session patterns
- **API Throughput:** ~29 req/sec (session-based with think time)
- **Combined Load:** 300 API RPS + 500 EPS (gRPC tail latency increases under extreme combined load)

Primary bottleneck: PostgreSQL CPU under combined API + event load (125-160% CPU)

---

## Current Baseline Numbers (M5)

These numbers serve as the baseline for M6 comparison.

### gRPC Event Processing

| Metric | M4 Baseline | M5 Current | Change |
|--------|-------------|------------|--------|
| p95 | 1.22ms | 0.60ms | -51% (faster) |
| avg | 2.19ms | 2.19ms | 0% |
| median | — | 0.33ms | — |

### HTTP API Endpoints (p95)

| Endpoint | M4 Baseline | M5 Current | Change |
|----------|-------------|------------|--------|
| Overall HTTP | 8.72ms | 3.89ms | -55% |
| Batch Select | 10.03ms | 4.84ms | -52% |
| Random Select | 9.58ms | 1.99ms | -79% |
| Initialize | 9.19ms | 3.07ms | -67% |
| Browse Challenges | 8.55ms | 3.53ms | -59% |
| Claim | 0.77ms | 0.48ms | -38% |
| Check Progress | 7.90ms | 3.52ms | -55% |
| Rotation Status | N/A | 0.97ms | New |

### Resource Utilization (at 150 VUs + 500 EPS)

| Container | CPU % | Memory | Mem % |
|-----------|-------|--------|-------|
| challenge-service | 3.61% | 29 MB | 2.80% |
| challenge-event-handler | 36.71% | 224 MB | 21.90% |
| challenge-postgres | 105.84% | 1,412 MB | 35.30% |
| challenge-redis | 0.34% | 5 MB | 0.02% |

### Database Stats (30-min run at 500 EPS)

| Metric | Value |
|--------|-------|
| Inserts | 1,203,558 |
| Updates | 4,115,484 |
| Live Rows | 22,500 |
| Index Scans | 603,859,612 |
| Sequential Scans | 1,368,609 |
| Index/Seq Ratio | 441:1 |
| COPY mean_exec_time (avg query time) | 1.47ms |
| COPY max_exec_time (worst-case query time) | 86.48ms |

### Threshold Summary

| Threshold | Target | Actual | Status |
|-----------|--------|--------|--------|
| HTTP p95 | < 2,000ms | 3.89ms | PASS |
| HTTP failed rate | < 1% | 0.00% | PASS |
| Checks pass rate | > 99% | 100% | PASS |
| gRPC p95 | < 500ms | 0.60ms | PASS |
| Batch Select p95 | < 50ms | 4.84ms | PASS |
| Rotation Status p95 | < 100ms | 0.97ms | PASS |
| Browse Challenges p95 | < 500ms | 3.53ms | PASS |
| Initialize p95 | < 100ms | 3.07ms | PASS |
| Claim p95 | < 100ms | 0.48ms | PASS |

---

## Detailed Results

For full load test analysis with pprof profiles, database deep dive, and comparison tables, see:
- [M5_PERFORMANCE_RESULTS.md](./M5_PERFORMANCE_RESULTS.md) — M5 load test report
- [M3_PHASE5_PERFORMANCE_RESULTS.md](./M3_PHASE5_PERFORMANCE_RESULTS.md) — M3 micro-benchmark results
- [TECH_SPEC_M5.md](./TECH_SPEC_M5.md) — M5 micro-benchmark results (SQL CASE overhead analysis)

## Test Artifacts

| Scenario | Results Directory |
|----------|-------------------|
| Scenario 3 (combined) | `tests/loadtest/results/scenario3_combined_20260228_092911/` |
| Scenario 4 (realistic) | `tests/loadtest/results/scenario4_m4_realistic_sessions_20260228_100012/` |
| Scenario 5 (rotation) | `tests/loadtest/results/scenario5_m5_rotation_20260228_103116/` |
| M4 Baseline | `tests/loadtest/results/scenario4_20251124_110149/` |

---

## Scaling Recommendations

1. **1,000 EPS (events/sec):** Add 1 event handler replica (horizontal scaling)
2. **5,000 EPS (events/sec):** Add database read replicas, consider partitioning `user_goal_progress`
3. **10,000 EPS (events/sec):** Implement hash partitioning (see [TECH_SPEC_DATABASE_PARTITIONING.md](./TECH_SPEC_DATABASE_PARTITIONING.md))
4. **Rotation-specific:** No additional scaling needed — SQL CASE overhead is negligible

---

**Document Status:** Filled with M5 load test results (2026-02-28). Update with M6 numbers when available.
