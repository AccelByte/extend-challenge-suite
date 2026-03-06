# Load Testing Guide

This directory contains all resources for performance profiling and load testing (M2-M5).

**Objective:** Determine actual system limits under resource constraints and document bottlenecks.

**Related Documents:**
- [TECH_SPEC_M2.md](../../docs/TECH_SPEC_M2.md) - Complete technical specification
- [PERFORMANCE_BASELINE.md](../../docs/PERFORMANCE_BASELINE.md) - Results template
- [CAPACITY_PLANNING.md](../../docs/CAPACITY_PLANNING.md) - Scaling guide template
- [PERFORMANCE_TUNING.md](../../docs/PERFORMANCE_TUNING.md) - Optimization guide template

---

## Key Terms

| Term | Meaning |
|------|---------|
| **TARGET_RPS** | Target Requests Per Second — how many HTTP API calls k6 will attempt per second. |
| **TARGET_EPS** | Target Events Per Second — how many gRPC events k6 will send per second. |
| **TARGET_VUS** | Target Virtual Users — number of simulated concurrent users. |
| **p50 / p95 / p99** | Percentile latencies. p95 means 95% of requests completed within this time. |
| **k6** | Open-source load testing tool used to simulate traffic. |
| **pprof** | Go profiling tool for inspecting CPU usage, memory allocations, and goroutines. |

---

## Quick Start

Get started in under 2 minutes:

> **Before you begin:** You need a `.env` file in the project root. If you don't have one, copy the example and review it:
> ```bash
> cp .env.example .env
> ```
> See [Environment Configuration](#environment-configuration) below for details.

```bash
# 1. Start services with loadtest config (from project root)
make dev-up-loadtest

# 2. Create results directories (from tests/loadtest/)
cd tests/loadtest
mkdir -p results/{scenario1,scenario2,scenario3}

# 3. Run a quick smoke test (~5 min, combined API + events)
K6_WEB_DASHBOARD=true k6 run k6/scenario3_smoke.js

# 4. Or run API-only load test (~10 min, no gRPC needed)
TARGET_RPS=50 k6 run k6/scenario1_api_load.js

# 5. When done, switch back to E2E config
cd ../..
make dev-up
```

**What to look for:**
- `http_req_duration` p95 < 2000ms (95% of requests completed within 2 seconds)
- `http_req_failed` rate < 1% (fewer than 1 in 100 requests returned an error)
- Web dashboard at http://localhost:5665 (if `K6_WEB_DASHBOARD=true`)

For automated testing with profiling and analysis, see [`scripts/README.md`](scripts/README.md).

---

## Prerequisites

### Required Tools

1. **k6** - Load testing tool
   ```bash
   # macOS
   brew install k6

   # Linux (Debian/Ubuntu)
   sudo gpg -k
   sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
     --keyserver hkp://keyserver.ubuntu.com:80 \
     --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
   echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
     sudo tee /etc/apt/sources.list.d/k6.list
   sudo apt-get update
   sudo apt-get install k6

   # Verify installation
   k6 version
   # Tested with: k6 v1.3.0 or later
   ```

   **Note:** To enable the web dashboard, use the `K6_WEB_DASHBOARD=true` environment variable (not a command-line flag). See "Monitoring During Tests" section below for details.

2. **PostgreSQL Client** - For database monitoring and analysis
   ```bash
   # macOS
   brew install postgresql@15

   # Linux (Debian/Ubuntu)
   sudo apt-get install postgresql-client-15

   # Verify installation
   psql --version
   ```

3. **Go** - For profiling (pprof)
   ```bash
   # macOS
   brew install go

   # Linux
   sudo apt-get install golang

   # Verify installation
   go version
   ```

4. **Docker & Docker Compose** - For running services
   ```bash
   # Verify installation
   docker --version
   docker-compose --version
   # Or use make commands (preferred):
   make dev-ps
   ```

5. **jq** - For JSON processing (optional but recommended)
   ```bash
   # macOS
   brew install jq

   # Linux
   sudo apt-get install jq
   ```

---

## Environment Configuration

**Before running load tests**, ensure your `.env` (in the project root) has these two critical settings for mock mode:

```bash
# Use mock reward client (no real AGS calls)
REWARD_CLIENT_MODE=mock

# Disable JWT validation (accept mock tokens)
PLUGIN_GRPC_SERVER_AUTH_ENABLED=false
```

All other variables (DB, Redis, paths) have sensible defaults in `.env.example` that work with docker-compose out of the box. If you don't have a `.env` file yet:

```bash
cp .env.example .env
```

**Why mock mode?** Load testing should measure *your service* performance (CPU, memory, DB), not external AGS API latency. Mock mode ensures isolated, reproducible results with no external dependencies.

**Verify configuration:**
```bash
grep -E "REWARD_CLIENT_MODE|PLUGIN_GRPC_SERVER_AUTH_ENABLED" .env
# Expected:
# REWARD_CLIENT_MODE=mock
# PLUGIN_GRPC_SERVER_AUTH_ENABLED=false
```

---

## Setup Instructions

### 1. Start Services with Loadtest Config

```bash
# From project root — uses docker-compose.loadtest.yml overlay
make dev-up-loadtest

# Verify services are healthy
make dev-ps

# Expected output:
# NAME                    STATUS
# challenge-postgres      Up (healthy)
# challenge-redis         Up (healthy)
# challenge-service       Up
# challenge-event-handler Up
```

This volume-mounts `tests/loadtest/fixtures/challenges.json` into the services. To switch back to the E2E config, run `make dev-up`.

After code changes, rebuild with:
```bash
make dev-rebuild-loadtest
```

### 2. Enable PostgreSQL Extensions

```bash
# Enable pg_stat_statements for query performance monitoring
docker exec -it challenge-postgres psql -U postgres -d challenge_db -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# Verify extension
docker exec -it challenge-postgres psql -U postgres -d challenge_db -c "\dx"
```

### 3. Generate Test Fixtures (Optional)

> **Fixtures are pre-generated and committed to the repo.** You only need to regenerate if you want different data (more users, different challenges, etc.).

All commands below assume CWD is `tests/loadtest/`:

```bash
cd tests/loadtest

# Generate 10,000 test users
./scripts/generate_users.sh

# Generate 12 challenges with ~600 goals (loadtest fixture)
./scripts/generate_challenges_loadtest.sh

# Generate JWT tokens (mock mode for local testing)
MOCK_MODE=true ./scripts/generate_tokens.sh

# For real AGS tokens (requires credentials):
# export AGS_CLIENT_ID=your-client-id
# export AGS_CLIENT_SECRET=your-client-secret
# export AGS_BASE_URL=https://demo.accelbyte.io
# export AGS_NAMESPACE=your-namespace
# ./scripts/generate_tokens.sh
```

**Verify fixtures:**
```bash
ls -lh fixtures/
# Expected:
# users.json       (~500 KB, 10,000 users)
# tokens.json      (~500 KB, 10,000 tokens)
# challenges.json  (~100 KB, 12 challenges, ~600 goals)
```

### 4. Load Challenge Configuration

The loadtest fixture (`fixtures/challenges.json`) contains 12 challenges
with ~600 goals: 500 absolute + 50 daily rotation + 50 weekly rotation (~17% rotation).

The fixture is volume-mounted via `make dev-up-loadtest` — no file copying needed.

To regenerate the fixture:
```bash
cd tests/loadtest/scripts && ./generate_challenges_loadtest.sh
```

### 5. Create Results Directories

k6 does not auto-create parent directories for output files. Create them before running tests:

```bash
cd tests/loadtest
mkdir -p results/{scenario1,scenario2,scenario3}
```

### 6. Verify System Health

```bash
# Test API endpoint
curl http://localhost:8000/challenge/healthz
# Expected: {"status":"healthy"}

# Test event handler (requires gRPC client)
# Or check logs:
docker logs challenge-event-handler | tail -20
```

---

## Directory Structure

```
tests/loadtest/
├── README.md                          # This file
├── .gitignore
├── k6/                                # k6 load test scripts
│   ├── scenario1_api_load.js          # API load (isolated, HTTP only)
│   ├── scenario2_event_load.js        # Event processing (isolated, gRPC)
│   ├── scenario3_combined.js          # Combined API + Events (30 min)
│   ├── scenario3_init_only.js         # Init endpoint investigation
│   ├── scenario3_smoke.js             # Quick smoke test (~5 min)
│   ├── scenario4_m4_realistic_sessions.js  # M4 realistic sessions
│   ├── scenario5_m5_rotation.js            # M5 rotation stress test
│   └── README_SCENARIO4.md            # Scenario 4 documentation
├── fixtures/                          # Test data (pre-generated)
│   ├── challenges.json                # 12 challenges, ~600 goals
│   ├── users.json                     # 10,000 test users
│   └── tokens.json                    # Mock JWT tokens
├── scripts/                           # Helper scripts
│   ├── README.md                      # Script documentation
│   ├── generate_challenges_loadtest.sh
│   ├── generate_users.sh
│   ├── generate_tokens.sh
│   ├── run_all_scenarios.sh
│   ├── run_and_analyze_loadtest.sh    # Automated orchestrator
│   ├── monitor_db.sh
│   ├── monitor_loadtest.sh
│   ├── monitor_init_test.sh
│   ├── profile_at_15min.sh
│   └── analyze_db_performance.sql
├── sql/                               # SQL analysis queries
│   ├── investigate_init_performance.sql
│   └── quick_benchmark.sql
└── results/                           # Test output (gitignored)
```

---

## Scenario Guide

| Scenario | Script | Purpose | Duration (per-run) | Requires gRPC | Best For |
|----------|--------|---------|----------|---------------|----------|
| 1 | `scenario1_api_load.js` | API only | 10m | No | Quick API validation |
| 2 | `scenario2_event_load.js` | Events only | 10m | Yes | Event handler testing |
| 3 | `scenario3_combined.js` | API + Events | 30m | Yes | Full system stress |
| 3 (smoke) | `scenario3_smoke.js` | Quick combined | ~5m | Yes | CI / pre-merge check |
| 3 (init) | `scenario3_init_only.js` | Init investigation | 10m | No | Debug init performance |
| 4 | `scenario4_m4_realistic_sessions.js` | M4 realistic | 30m | Yes | M4/M5 feature validation |
| 5 | `scenario5_m5_rotation.js` | M5 rotation stress | 30m | Yes | Rotation-specific validation |

**Tips:**
- Start with **scenario1** or **scenario3_smoke** for a quick sanity check.
- Use **scenario3_combined** for pre-release stress testing.
- Use **scenario4** for M4+ feature validation with realistic user sessions.
- Use **scenario5** for M5 rotation-specific validation (expiresAt, rotation status, rotation goal selection).
- The "Duration" column shows how long a single k6 run takes. The detailed sections below describe multi-level testing strategies that run the same script multiple times.

---

## Running Tests

All commands below assume CWD is `tests/loadtest/`.

### Single Scenario

```bash
# Ensure results directories exist
mkdir -p results/{scenario1,scenario2,scenario3}

# Enable web dashboard and run test (~10 min)
K6_WEB_DASHBOARD=true TARGET_RPS=100 k6 run \
  --out json=results/scenario1/test1.json \
  k6/scenario1_api_load.js

# Access dashboard at: http://localhost:5665
# Shows real-time metrics: request rate, latency (p50/p95/p99), errors, active VUs
```

### Automated Test Runner (All Scenarios)

```bash
# Run all scenarios at multiple load levels
./scripts/run_all_scenarios.sh

# This will:
# 1. Test API load at 50, 100, 200, 500, 1000, 2000, 5000 RPS
# 2. Test event load at 100, 500, 1000, 2000, 5000, 10000 EPS
# 3. Test combined load (matrix of API x Event)
# 4. Run database performance analysis
# 5. Validate E2E latency
#
# Estimated runtime: 6-12 hours (stops at failure)
```

### Automated Orchestrator with Profiling

For fully automated testing with profiling, monitoring, and analysis reports:

```bash
cd scripts
./run_and_analyze_loadtest.sh                         # Defaults
./run_and_analyze_loadtest.sh scenario4 150 500 120   # Custom
```

See [`scripts/README.md`](scripts/README.md) for full documentation of `run_and_analyze_loadtest.sh`.

---

## Test Scenarios

### Scenario 1: API Load Testing (Isolated)

**Objective:** Find maximum sustainable API request rate

**Duration:** 10 min per run. Test multiple load levels to find the breaking point.

**Run single level:**
```bash
TARGET_RPS=500 k6 run \
  --out json=results/scenario1/level_500rps.json \
  k6/scenario1_api_load.js
```

**Load levels to test:**
- 50 RPS (baseline)
- 100 RPS
- 200 RPS
- 500 RPS
- 1,000 RPS
- 2,000 RPS
- 5,000 RPS (or until failure)

**Success criteria:**
- Error rate < 1%
- p95 latency < 2 seconds

---

### Scenario 2: Event Processing Load (Isolated)

**Objective:** Find maximum sustainable event processing rate

**Duration:** 10 min per run. Test multiple load levels to find the breaking point.

**Run single level:**
```bash
TARGET_EPS=1000 k6 run \
  --out json=results/scenario2/level_1000eps.json \
  k6/scenario2_event_load.js
```

**Load levels to test:**
- 100 EPS (baseline)
- 500 EPS
- 1,000 EPS
- 2,000 EPS
- 5,000 EPS
- 10,000 EPS (or until failure)

**Success criteria:**
- Error rate < 1%
- p95 latency < 500ms

---

### Scenario 3: Combined Load Testing

**Objective:** Test API + Event load simultaneously (most critical)

**Duration:** 30 min per combination

**Run single combination:**
```bash
TARGET_RPS=200 TARGET_EPS=1000 k6 run \
  --out json=results/scenario3/level_200rps_1000eps.json \
  k6/scenario3_combined.js
```

**While test is running, collect profiling data:**

```bash
# Terminal 2: CPU profiling (30 seconds)
go tool pprof -http=:8081 http://localhost:8080/debug/pprof/profile?seconds=30

# Terminal 3: Memory heap profiling
go tool pprof -http=:8082 http://localhost:8080/debug/pprof/heap

# Terminal 4: Goroutine profiling
go tool pprof -http=:8083 http://localhost:8080/debug/pprof/goroutine

# Terminal 5: Monitor docker stats
watch -n 2 'docker stats --no-stream challenge-service challenge-event-handler challenge-postgres challenge-redis'
```

**Test matrix (start conservative):**
| API RPS | Event EPS | Priority |
|---------|-----------|----------|
| 50      | 100       | High     |
| 100     | 500       | High     |
| 200     | 1,000     | High     |
| 500     | 2,000     | Medium   |
| 1,000   | 5,000     | Low      |

---

### Advanced: Database Performance Deep Dive

**Objective:** Analyze database bottlenecks under load

**Duration:** 30 minutes

**Run with monitoring:**
```bash
# Terminal 1: Start database monitoring
./scripts/monitor_db.sh results/db_monitor.log

# Terminal 2: Run combined load test
TARGET_RPS=500 TARGET_EPS=2000 k6 run \
  --out json=results/scenario3/db_deepdive.json \
  k6/scenario3_combined.js

# After test completes, stop monitoring (Ctrl+C in Terminal 1)

# Analyze database performance
docker exec -i challenge-postgres psql -U postgres -d challenge_db \
  < scripts/analyze_db_performance.sql \
  > results/scenario3/query_analysis.txt
```

---

### Scenario 5: M5 Rotation Stress Test

**Objective:** Validate M5 time-based rotation under sustained load

**Duration:** 30 min per run

This scenario targets rotation-specific features:
- `expiresAt` and `expiresInSeconds` fields in GET /challenges responses
- GET /challenges/{id}/rotation endpoint for rotation status
- Batch-select with rotation goals (daily + weekly challenges)
- Background stat events with `inc` field for baseline computation

**Run:**
```bash
# Using automated orchestrator (recommended)
cd scripts && ./run_and_analyze_loadtest.sh scenario5_m5_rotation 150 500 120

# Or directly with k6
TARGET_VUS=150 TARGET_EPS=500 ITERATIONS=120 k6 run \
  --out json=results/scenario5/test.json \
  --summary-export=results/scenario5/summary.json \
  k6/scenario5_m5_rotation.js
```

**Optional: Test with stale rows (simulates returning users after rotation boundary):**
```bash
# Seed stale rows before test
docker exec challenge-postgres psql -U postgres -d challenge_db -c \
  "UPDATE user_goal_progress SET updated_at = NOW() - INTERVAL '2 days' WHERE goal_id LIKE '%daily%' AND random() < 0.4;"

# Run with stale rows flag
DB_SEED_STALE_ROWS=true ./run_and_analyze_loadtest.sh scenario5_m5_rotation 150 500 120
```

**Success criteria:**
- rotation_status p95 < 100ms
- browse_challenges p95 < 500ms (with expiresAt computation)
- batch_select p95 < 50ms
- gRPC event p95 < 500ms
- `expiresAt` checks > 99% pass rate

**Performance results:** See [M5_PERFORMANCE_RESULTS.md](../../docs/M5_PERFORMANCE_RESULTS.md)

---

### Advanced: E2E Latency Validation

**Objective:** Measure end-to-end latency from event to API visibility

**Duration:** 5 minutes

**Run short test:**
```bash
TARGET_EPS=1000 k6 run \
  --duration=5m \
  --out json=results/scenario2/e2e_latency.json \
  k6/scenario2_event_load.js

# Check buffer flush timing
docker logs challenge-event-handler 2>&1 | grep "buffer flush" > results/scenario2/flush_timing.log
```

---

## Monitoring During Tests

### Real-time k6 Web Dashboard

**Enable web dashboard with environment variable:**
```bash
# Set K6_WEB_DASHBOARD=true before running any k6 test
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run k6/scenario1_api_load.js
```

**Dashboard features:**
- **URL:** http://localhost:5665 (automatically opens during test)
- **Real-time metrics:** Request rate, latency percentiles (p50, p95, p99), error rate, active VUs
- **Live graphs:** Performance trends updated every second
- **No configuration needed:** Built-in k6 feature, works out of the box
- **Terminal output:** k6 also prints progress to terminal and shows final summary

### Docker Resource Usage

```bash
# Monitor CPU and memory in real-time
watch -n 2 'docker stats --no-stream challenge-service challenge-event-handler challenge-postgres'

# Expected output:
# NAME                    CPU %     MEM USAGE / LIMIT
# challenge-service       45.2%     512MB / 1GB
# challenge-event-handler 23.8%     256MB / 1GB
# challenge-postgres      67.3%     2.1GB / 4GB
```

### Database Monitoring

```bash
# Monitor active connections
watch -n 5 'docker exec challenge-postgres psql -U postgres -d challenge_db -c "SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state"'

# Monitor query performance
watch -n 5 'docker exec challenge-postgres psql -U postgres -d challenge_db -c "SELECT query, calls, mean_exec_time FROM pg_stat_statements WHERE query LIKE \"%user_goal_progress%\" ORDER BY mean_exec_time DESC LIMIT 5"'
```

### Application Logs

```bash
# Backend service logs
docker logs -f challenge-service | grep -E "ERROR|WARN|latency"

# Event handler logs
docker logs -f challenge-event-handler | grep -E "ERROR|WARN|buffer"
```

---

## Analyzing Results

### k6 Results

**JSON output files are in `results/`**

```bash
# View summary from k6 JSON output
jq '.metrics | {
  http_req_duration_p95: .http_req_duration.values."p(95)",
  http_req_failed_rate: .http_req_failed.values.rate,
  http_reqs_rate: .http_reqs.values.rate
}' results/scenario1/level_500rps.json

# Expected output:
# {
#   "http_req_duration_p95": 234.5,
#   "http_req_failed_rate": 0.005,
#   "http_reqs_rate": 498.3
# }
```

### pprof Profiles

**CPU profile:**
```bash
# View top CPU consumers
go tool pprof -top results/scenario3/cpu_500rps_2000eps.txt

# Generate flame graph (interactive)
go tool pprof -http=:8080 results/scenario3/cpu_500rps_2000eps.txt
```

**Memory profile:**
```bash
# View top memory allocations
go tool pprof -top results/scenario3/heap_500rps_2000eps.txt
```

### Database Performance

**View query analysis:**
```bash
cat results/scenario3/query_analysis.txt

# Look for:
# - Slowest queries (mean_exec_time)
# - Connection pool saturation
# - Cache hit ratio
# - Index usage efficiency
```

---

## Troubleshooting

### Issue: k6 test fails immediately

**Symptom:** Test exits with error before starting

**Possible causes:**
1. Services not running
   ```bash
   make dev-ps
   # If any service is not "Up", restart:
   make dev-restart
   ```

2. Fixtures not generated
   ```bash
   ls -lh fixtures/
   # Should see users.json, tokens.json, challenges.json
   # If missing, run generate scripts (see Setup step 3)
   ```

3. Port conflicts
   ```bash
   # Check if ports are in use
   lsof -i :8000  # Backend REST API
   lsof -i :8080  # Backend metrics/pprof
   lsof -i :6566  # Event handler gRPC
   ```

---

### Issue: Database connection errors

**Symptom:** Logs show "too many connections" or timeouts

**Solution:**
```bash
# Check current connections
docker exec challenge-postgres psql -U postgres -d challenge_db \
  -c "SELECT COUNT(*) FROM pg_stat_activity"

# Increase max_connections (requires restart)
# Edit postgresql.conf or docker-compose.yml, then:
make dev-restart
```

---

### Issue: Event handler not processing events

**Symptom:** Buffer never flushes, progress not updating

**Check event handler logs:**
```bash
docker logs challenge-event-handler | tail -50

# Look for:
# - "buffer flush" messages (should appear every 1 second)
# - Error messages
# - gRPC connection errors
```

**Verify gRPC connectivity:**
```bash
# Check if port is listening
docker exec challenge-event-handler netstat -tuln | grep 6565
```

---

### Issue: k6 dashboard not accessible

**Symptom:** http://localhost:5665 not loading

**Solution:**

1. **Ensure K6_WEB_DASHBOARD environment variable is set:**
   ```bash
   # Correct way to enable dashboard
   K6_WEB_DASHBOARD=true k6 run k6/scenario1_api_load.js

   # NOT via command-line flag (this doesn't exist):
   # k6 run --web-dashboard k6/scenario1_api_load.js
   ```

2. **Check if port 5665 is available:**
   ```bash
   lsof -i :5665
   # If port is in use, kill the process or use a different port
   ```

3. **Change dashboard port (if needed):**
   ```bash
   K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_PORT=5666 k6 run k6/scenario1_api_load.js
   # Dashboard will be available at http://localhost:5666
   ```

4. **Check k6 version:**
   ```bash
   k6 version
   # Should be v0.46.0 or later
   # If older, upgrade: brew upgrade k6 (macOS) or sudo apt-get upgrade k6 (Linux)
   ```

---

## Best Practices

### 1. Reset Between Tests

**Always reset database and stats between tests:**
```bash
# Truncate progress table
docker exec challenge-postgres psql -U postgres -d challenge_db \
  -c "TRUNCATE TABLE user_goal_progress;"

# Reset query statistics
docker exec challenge-postgres psql -U postgres -d challenge_db \
  -c "SELECT pg_stat_statements_reset();"
```

### 2. Cool Down Period

**Wait 60 seconds between tests:**
- Allows system to stabilize
- Prevents carry-over effects
- Ensures clean baseline

### 3. Save All Results

**Don't skip result collection:**
- k6 JSON output (--out json=...)
- pprof profiles (CPU, memory, goroutines)
- Database analysis (pg_stat_statements)
- Docker stats snapshots

### 4. Document Anomalies

**If you see unexpected behavior:**
- Note exact time it occurred
- Save logs from that period
- Document what you were testing
- Include in final report

---

## Next Steps After Testing

### 1. Analyze Results

Fill in the documentation templates with your findings:
- `docs/PERFORMANCE_BASELINE.md` - Test results and bottlenecks
- `docs/CAPACITY_PLANNING.md` - Scaling recommendations
- `docs/PERFORMANCE_TUNING.md` - Optimization guide

### 2. Identify Bottlenecks

**Look for:**
- Database connection pool saturation
- CPU hotspots (from pprof)
- Memory leaks or excessive allocations
- Slow queries (from pg_stat_statements)
- Buffer overflow or high flush times

### 3. Prioritize Optimizations

**Focus on:**
- Highest impact (bottleneck causing most limitation)
- Easiest to fix (configuration vs code change)
- Lowest risk (well-understood optimization)

### 4. Implement and Re-test

**For each optimization:**
- Make one change at a time
- Re-run same test
- Compare before/after metrics
- Document actual vs expected impact

---

## References

- [TECH_SPEC_M2.md](../../docs/TECH_SPEC_M2.md) - Full specification
- [k6 Documentation](https://k6.io/docs/)
- [k6 Web Dashboard](https://grafana.com/docs/k6/latest/results-output/web-dashboard/)
- [PostgreSQL Performance](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [Go pprof Guide](https://go.dev/blog/pprof)

---

## Quick Command Reference

All commands assume CWD is `tests/loadtest/` unless noted otherwise.

```bash
# --- From project root ---
make dev-up-loadtest           # Start services with loadtest config
make dev-rebuild-loadtest      # Rebuild services with loadtest config
make dev-up                    # Switch back to E2E config

# --- From tests/loadtest/ ---

# Create results directories (one-time)
mkdir -p results/{scenario1,scenario2,scenario3}

# Generate fixtures (only needed if you want different data)
./scripts/generate_users.sh
./scripts/generate_challenges_loadtest.sh
MOCK_MODE=true ./scripts/generate_tokens.sh

# Run single scenario
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run --out json=results/scenario1/test.json k6/scenario1_api_load.js   # ~10 min
K6_WEB_DASHBOARD=true TARGET_EPS=1000 k6 run --out json=results/scenario2/test.json k6/scenario2_event_load.js # ~10 min
K6_WEB_DASHBOARD=true TARGET_RPS=200 TARGET_EPS=1000 k6 run --out json=results/scenario3/test.json k6/scenario3_combined.js  # ~30 min
K6_WEB_DASHBOARD=true k6 run k6/scenario3_smoke.js  # ~5 min
K6_WEB_DASHBOARD=true TARGET_VUS=150 TARGET_EPS=500 ITERATIONS=120 k6 run k6/scenario5_m5_rotation.js  # ~30 min

# Run all scenarios
./scripts/run_all_scenarios.sh

# Automated orchestrator (with profiling + analysis report)
cd scripts && ./run_and_analyze_loadtest.sh

# Monitor database
./scripts/monitor_db.sh results/db_monitor.log

# Analyze database
docker exec -i challenge-postgres psql -U postgres -d challenge_db < scripts/analyze_db_performance.sql

# Reset database
docker exec challenge-postgres psql -U postgres -d challenge_db -c "TRUNCATE TABLE user_goal_progress;"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "SELECT pg_stat_statements_reset();"

# View results
jq '.metrics.http_req_duration.values."p(95)"' results/scenario1/level_500rps.json
go tool pprof -top results/scenario3/cpu_500rps_2000eps.txt
```
