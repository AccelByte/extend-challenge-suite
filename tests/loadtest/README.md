# M2 Load Testing Guide

This directory contains all resources for Milestone 2 (M2) performance profiling and load testing.

**Objective:** Determine actual system limits under resource constraints and document bottlenecks.

**Related Documents:**
- [TECH_SPEC_M2.md](../docs/TECH_SPEC_M2.md) - Complete technical specification
- [PERFORMANCE_BASELINE.md](../docs/PERFORMANCE_BASELINE.md) - Results template
- [CAPACITY_PLANNING.md](../docs/CAPACITY_PLANNING.md) - Scaling guide template
- [PERFORMANCE_TUNING.md](../docs/PERFORMANCE_TUNING.md) - Optimization guide template

---

## Directory Structure

```
test/
├── k6/                          # k6 load test scripts
│   ├── scenario1_api_load.js   # API load testing (isolated)
│   ├── scenario2_event_load.js # Event processing load (isolated)
│   └── scenario3_combined.js   # Combined API + Event load
├── fixtures/                    # Test data
│   ├── users.json              # 10,000 test users (generated)
│   ├── tokens.json             # JWT tokens (generated)
│   └── challenges.json         # 10 challenges, 50 goals each
├── scripts/                     # Helper scripts
│   ├── generate_users.sh       # Generate users.json
│   ├── generate_tokens.sh      # Generate tokens.json
│   ├── generate_challenges.sh  # Generate challenges.json
│   ├── monitor_db.sh           # Real-time database monitoring
│   ├── analyze_db_performance.sql  # Post-test query analysis
│   └── run_all_scenarios.sh    # Automated test runner
├── results/                     # Test results (gitignored)
│   ├── scenario1/
│   ├── scenario2/
│   ├── scenario3/
│   ├── scenario4/
│   └── scenario5/
└── README.md                    # This file
```

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

## Environment Configuration for M2 Load Testing

**IMPORTANT:** Before running load tests, configure `.env` for mock mode to avoid external AGS dependencies.

### Required Configuration

Edit `.env` in the project root and set these variables:

```bash
# ============================================================================
# M2 Load Testing Configuration (Mock Mode)
# ============================================================================

# Backend Service: Use mock reward client (no real AGS calls)
REWARD_CLIENT_MODE=mock

# Backend Service: Disable JWT validation (accept mock tokens)
PLUGIN_GRPC_SERVER_AUTH_ENABLED=false

# AGS Namespace (still required for config validation)
AB_NAMESPACE=test

# Database Configuration (leave as default for local docker-compose)
DB_HOST=postgres
DB_PORT=5432
DB_NAME=challenge_db
DB_USER=postgres
DB_PASSWORD=postgres

# Redis Configuration (leave as default)
REDIS_HOST=redis
REDIS_PORT=6379
```

### Why Mock Mode?

**M2 load testing goals:**
- Test service performance limits (CPU, memory, DB)
- Identify bottlenecks in event processing and API handling
- Measure buffer flush performance and batch UPSERT efficiency

**Using real AGS during load testing would:**
- Introduce external latency (network calls to AGS)
- Risk hitting AGS rate limits
- Make results harder to interpret (AGS performance vs our service performance)
- Require managing thousands of real test users

**Mock mode ensures:**
- ✅ Isolated testing (no external dependencies)
- ✅ Reproducible results (no network variability)
- ✅ Faster test execution (no AGS API calls)
- ✅ Focus on service limits (CPU, memory, DB) not external factors

### Verification

After updating `.env`, verify configuration:

```bash
# Check .env file
cat .env | grep -E "REWARD_CLIENT_MODE|PLUGIN_GRPC_SERVER_AUTH_ENABLED|AB_NAMESPACE"

# Expected output:
# REWARD_CLIENT_MODE=mock
# PLUGIN_GRPC_SERVER_AUTH_ENABLED=false
# AB_NAMESPACE=test
```

---

## Setup Instructions

### 1. Start Services

```bash
# From project root
make dev-up

# Verify services are healthy
make dev-ps

# Expected output:
# NAME                    STATUS
# challenge-postgres      Up (healthy)
# challenge-redis         Up (healthy)
# challenge-service       Up
# challenge-event-handler Up
```

### 2. Enable PostgreSQL Extensions

```bash
# Enable pg_stat_statements for query performance monitoring
docker exec -it challenge-postgres psql -U postgres -d challenge_db -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# Verify extension
docker exec -it challenge-postgres psql -U postgres -d challenge_db -c "\dx"
```

### 3. Generate Test Fixtures

```bash
# Generate 10,000 test users
./test/scripts/generate_users.sh

# Generate 10 challenges with 50 goals each (500 total goals)
./test/scripts/generate_challenges.sh

# Generate JWT tokens (mock mode for local testing)
MOCK_MODE=true ./test/scripts/generate_tokens.sh

# For real AGS tokens (requires credentials):
# export AGS_CLIENT_ID=your-client-id
# export AGS_CLIENT_SECRET=your-client-secret
# export AGS_BASE_URL=https://demo.accelbyte.io
# export AGS_NAMESPACE=your-namespace
# ./test/scripts/generate_tokens.sh
```

**Verify fixtures:**
```bash
ls -lh test/fixtures/
# Expected:
# users.json       (~500 KB, 10,000 users)
# tokens.json      (~500 KB, 10,000 tokens)
# challenges.json  (~100 KB, 10 challenges, 500 goals)
```

### 4. Load Challenge Configuration

```bash
# Copy challenges to service config
cp test/fixtures/challenges.json extend-challenge-service/config/challenges.json
cp test/fixtures/challenges.json extend-challenge-event-handler/config/challenges.json

# Restart services to load new config
make dev-restart
```

### 5. Verify System Health

```bash
# Test API endpoint
curl http://localhost:8000/challenge/healthz
# Expected: {"status":"healthy"}

# Test event handler (requires gRPC client)
# Or check logs:
docker logs challenge-event-handler | tail -20
```

---

## Running Tests

### Quick Start: Single Scenario

```bash
# Enable web dashboard and run test
K6_WEB_DASHBOARD=true TARGET_RPS=100 k6 run \
  --out json=test/results/scenario1/test1.json \
  test/k6/scenario1_api_load.js

# Access dashboard at: http://localhost:5665
# Shows real-time metrics: request rate, latency (p50/p95/p99), errors, active VUs
```

### Automated Test Runner (All Scenarios)

```bash
# Run all scenarios at multiple load levels
./test/scripts/run_all_scenarios.sh

# This will:
# 1. Test API load at 50, 100, 200, 500, 1000, 2000, 5000 RPS
# 2. Test event load at 100, 500, 1000, 2000, 5000, 10000 EPS
# 3. Test combined load (matrix of API × Event)
# 4. Run database performance analysis
# 5. Validate E2E latency
#
# Estimated runtime: 6-12 hours (stops at failure)
```

---

## Test Scenarios

### Scenario 1: API Load Testing (Isolated)

**Objective:** Find maximum sustainable API request rate

**Duration:** 30 minutes per load level

**Run single level:**
```bash
TARGET_RPS=500 k6 run \
  --out json=test/results/scenario1/level_500rps.json \
  test/k6/scenario1_api_load.js
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

**Duration:** 30 minutes per load level

**Run single level:**
```bash
TARGET_EPS=1000 k6 run \
  --out json=test/results/scenario2/level_1000eps.json \
  test/k6/scenario2_event_load.js
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

**Duration:** 30 minutes per combination

**Run single combination:**
```bash
TARGET_RPS=200 TARGET_EPS=1000 k6 run \
  --out json=test/results/scenario3/level_200rps_1000eps.json \
  test/k6/scenario3_combined.js
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

### Scenario 4: Database Performance Deep Dive

**Objective:** Analyze database bottlenecks under load

**Duration:** 30 minutes

**Run with monitoring:**
```bash
# Terminal 1: Start database monitoring
./test/scripts/monitor_db.sh test/results/scenario4/db_monitor.log

# Terminal 2: Run combined load test
TARGET_RPS=500 TARGET_EPS=2000 k6 run \
  --out json=test/results/scenario4/results.json \
  test/k6/scenario3_combined.js

# After test completes, stop monitoring (Ctrl+C in Terminal 1)

# Analyze database performance
docker exec -it challenge-postgres psql -U postgres -d challenge_db \
  -f /host/test/scripts/analyze_db_performance.sql \
  > test/results/scenario4/query_analysis.txt
```

---

### Scenario 5: E2E Latency Validation

**Objective:** Measure end-to-end latency from event to API visibility

**Duration:** 5 minutes

**Run short test:**
```bash
TARGET_EPS=1000 k6 run \
  --duration=5m \
  --out json=test/results/scenario5/results.json \
  test/k6/scenario2_event_load.js

# Check buffer flush timing
docker logs challenge-event-handler 2>&1 | grep "buffer flush" > test/results/scenario5/flush_timing.log
```

---

## Monitoring During Tests

### Real-time k6 Web Dashboard

**Enable web dashboard with environment variable:**
```bash
# Set K6_WEB_DASHBOARD=true before running any k6 test
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run test/k6/scenario1_api_load.js
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

**JSON output files are in `test/results/scenarioN/`**

```bash
# View summary from k6 JSON output
jq '.metrics | {
  http_req_duration_p95: .http_req_duration.values."p(95)",
  http_req_failed_rate: .http_req_failed.values.rate,
  http_reqs_rate: .http_reqs.values.rate
}' test/results/scenario1/level_500rps.json

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
go tool pprof -top test/results/scenario3/cpu_500rps_2000eps.txt

# Generate flame graph (interactive)
go tool pprof -http=:8080 test/results/scenario3/cpu_500rps_2000eps.txt
```

**Memory profile:**
```bash
# View top memory allocations
go tool pprof -top test/results/scenario3/heap_500rps_2000eps.txt
```

### Database Performance

**View query analysis:**
```bash
cat test/results/scenario4/query_analysis.txt

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
   ls -lh test/fixtures/
   # Should see users.json, tokens.json, challenges.json
   # If missing, run generate scripts
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
   K6_WEB_DASHBOARD=true k6 run test/k6/scenario1_api_load.js

   # NOT via command-line flag (this doesn't exist):
   # k6 run --web-dashboard test/k6/scenario1_api_load.js  ❌
   ```

2. **Check if port 5665 is available:**
   ```bash
   lsof -i :5665
   # If port is in use, kill the process or use a different port
   ```

3. **Change dashboard port (if needed):**
   ```bash
   K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_PORT=5666 k6 run test/k6/scenario1_api_load.js
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

- [M2 Technical Spec](../docs/TECH_SPEC_M2.md) - Full specification
- [k6 Documentation](https://k6.io/docs/)
- [k6 Web Dashboard](https://grafana.com/docs/k6/latest/results-output/web-dashboard/)
- [PostgreSQL Performance](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [Go pprof Guide](https://go.dev/blog/pprof)

---

## Quick Command Reference

```bash
# Generate fixtures
./test/scripts/generate_users.sh
./test/scripts/generate_challenges.sh
MOCK_MODE=true ./test/scripts/generate_tokens.sh

# Run single scenario
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run --out json=test/results/scenario1/test.json test/k6/scenario1_api_load.js
K6_WEB_DASHBOARD=true TARGET_EPS=1000 k6 run --out json=test/results/scenario2/test.json test/k6/scenario2_event_load.js
K6_WEB_DASHBOARD=true TARGET_RPS=200 TARGET_EPS=1000 k6 run --out json=test/results/scenario3/test.json test/k6/scenario3_combined.js

# Run all scenarios
./test/scripts/run_all_scenarios.sh

# Monitor database
./test/scripts/monitor_db.sh test/results/db_monitor.log

# Analyze database
docker exec -it challenge-postgres psql -U postgres -d challenge_db -f /host/test/scripts/analyze_db_performance.sql

# Reset database
docker exec challenge-postgres psql -U postgres -d challenge_db -c "TRUNCATE TABLE user_goal_progress;"
docker exec challenge-postgres psql -U postgres -d challenge_db -c "SELECT pg_stat_statements_reset();"

# View results
jq '.metrics.http_req_duration.values."p(95)"' test/results/scenario1/level_500rps.json
go tool pprof -top test/results/scenario3/cpu_500rps_2000eps.txt
```

---

**Happy Load Testing!** 🚀
