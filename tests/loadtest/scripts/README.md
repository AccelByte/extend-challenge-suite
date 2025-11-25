# Load Test Automation Scripts

This directory contains scripts for automated load testing, monitoring, profiling, and analysis.

## Scripts

### `run_and_analyze_loadtest.sh`

**Fully automated load test orchestrator** - Runs loadtest, monitors services, captures profiles, and generates analysis summary.

#### Features

- ✅ **Automated Orchestration**: Starts k6 and monitor in parallel
- ✅ **Pre-flight Checks**: Validates services are healthy before starting
- ✅ **15-Minute Profiling**: Captures CPU, heap, goroutine, and mutex profiles
- ✅ **Database Monitoring**: Tracks PostgreSQL performance stats
- ✅ **Automated Analysis**: Parses k6 results and checks thresholds
- ✅ **Markdown Summary**: Generates comprehensive analysis report
- ✅ **Exit Code Propagation**: Returns k6 exit code for CI/CD integration

#### Usage

```bash
# Basic usage (uses defaults)
./run_and_analyze_loadtest.sh

# Custom configuration
./run_and_analyze_loadtest.sh <scenario_name> <target_vus> <target_eps> <iterations>

# Examples
./run_and_analyze_loadtest.sh scenario4 150 500 120
./run_and_analyze_loadtest.sh scenario4 300 1000 200  # Stress test
./run_and_analyze_loadtest.sh scenario4 50 200 60     # Light test
```

#### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `scenario_name` | `scenario4` | k6 scenario file (without `.js`) |
| `target_vus` | `150` | Target virtual users (concurrent sessions) |
| `target_eps` | `500` | Target events per second (gRPC events) |
| `iterations` | `120` | Iterations per VU (sessions per user) |

#### Output

Creates timestamped results directory in `tests/loadtest/results/`:

```
results/scenario4_20251123_143022/
├── k6_output.log                    # Full k6 console output
├── k6_metrics.json                  # Raw metrics (JSON lines)
├── k6_summary.json                  # Aggregated summary
├── monitor_output.log               # Monitor script output
├── analysis_summary.md              # 📊 MAIN ANALYSIS REPORT
│
├── service_cpu_15min.pprof          # CPU profile (service)
├── service_heap_15min.pprof         # Heap profile (service)
├── service_goroutine_15min.txt      # Goroutine dump (service)
├── service_mutex_15min.pprof        # Mutex contention (service)
│
├── handler_cpu_15min.pprof          # CPU profile (event handler)
├── handler_heap_15min.pprof         # Heap profile (event handler)
├── handler_goroutine_15min.txt      # Goroutine dump (handler)
├── handler_mutex_15min.pprof        # Mutex contention (handler)
│
├── postgres_stats_15min.txt         # PostgreSQL container stats
└── all_containers_stats_15min.txt   # All Docker container stats
```

#### Analysis Summary

The script generates `analysis_summary.md` with:

- **Test configuration and duration**
- **Pass/fail status** (based on k6 exit code)
- **Key metrics table**:
  - HTTP request duration (p95, p99, avg)
  - HTTP request failure rate
  - Checks pass rate
  - Total requests
- **M4 endpoint performance** (strict < 50ms threshold):
  - Batch Select p95
  - Random Select p95
- **Profile file inventory**
- **Database performance stats**
- **Actionable recommendations** based on results

#### Example Analysis Summary

```markdown
# Load Test Analysis Summary

**Test:** scenario4
**Duration:** 1847 seconds (30 minutes)

## Test Result: ✅ PASSED

## Key Metrics

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| HTTP Request Duration (p95) | 87.3 ms | < 2000 ms | ✅ |
| HTTP Request Failed Rate | 0.02% | < 1% | ✅ |
| Checks Pass Rate | 99.98% | > 99% | ✅ |

### M4 Endpoint Performance

| Endpoint | p95 Latency | Threshold | Status |
|----------|-------------|-----------|--------|
| Batch Select | 23.1 ms | < 50 ms | ✅ PASS |
| Random Select | 18.7 ms | < 50 ms | ✅ PASS |

## Recommendations

✅ All thresholds passed! The system is performing within acceptable limits.
```

#### Pre-flight Checks

The script validates before starting:

- ✅ Scenario file exists
- ✅ Challenge Service is healthy (`/healthz`)
- ✅ Event Handler is reachable (port 6566)
- ✅ PostgreSQL is ready

If any check fails, the script exits early with a helpful error message.

#### Analyzing Profiles

After test completion, analyze profiles using Go pprof:

```bash
# CPU profiles (interactive web UI)
go tool pprof -http=:8082 results/scenario4_20251123_143022/service_cpu_15min.pprof

# Heap profiles
go tool pprof -http=:8082 results/scenario4_20251123_143022/service_heap_15min.pprof

# Goroutine analysis
go tool pprof -http=:8082 results/scenario4_20251123_143022/service_goroutine_15min.txt

# Mutex contention
go tool pprof -http=:8082 results/scenario4_20251123_143022/service_mutex_15min.pprof

# Command-line top functions
go tool pprof -top results/scenario4_20251123_143022/service_cpu_15min.pprof
```

#### CI/CD Integration

The script is designed for automated testing:

```bash
# Run test and capture exit code
./run_and_analyze_loadtest.sh scenario4 150 500
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Performance test passed"
else
  echo "❌ Performance test failed"
  exit 1
fi
```

#### Tips for Effective Testing

1. **Warm-up period**: First 2-3 minutes of data may show initialization overhead
2. **15-minute mark**: Profiles captured when system is under sustained load
3. **Compare runs**: Keep old results directories for historical comparison
4. **Incremental load**: Start with low VUs/EPS, increase gradually
5. **Monitor resources**: Check Docker stats during test (`docker stats`)

#### Troubleshooting

**Issue: "Scenario file not found"**
```bash
# List available scenarios
ls tests/loadtest/k6/scenario*.js

# Use correct scenario name (without .js extension)
./run_and_analyze_loadtest.sh scenario1
```

**Issue: "Challenge Service not responding"**
```bash
# Start services
docker-compose up -d

# Check service health
curl http://localhost:8000/challenge/healthz
```

**Issue: "jq not installed - skipping JSON parsing"**
```bash
# Install jq for detailed metrics analysis
sudo apt-get install jq  # Ubuntu/Debian
brew install jq          # macOS
```

**Issue: Test completes before 15 minutes**
```bash
# Check k6 output for early termination
cat results/scenario4_*/k6_output.log | tail -50

# Common causes:
# - Services crashed (check docker-compose logs)
# - Database connection issues
# - Invalid configuration
```

---

### `monitor_loadtest.sh`

**Standalone monitoring and profiling script** - Can be used independently of the automated runner.

#### Usage

```bash
./monitor_loadtest.sh <results_dir>
```

See script header for detailed documentation.

---

## Workflow Examples

### Standard Performance Test

```bash
cd tests/loadtest/scripts

# Run automated test (30 minutes)
./run_and_analyze_loadtest.sh

# Results in: tests/loadtest/results/scenario4_<timestamp>/
# View summary: cat tests/loadtest/results/scenario4_<timestamp>/analysis_summary.md
```

### Stress Test (Higher Load)

```bash
# Double the load
./run_and_analyze_loadtest.sh scenario4 300 1000 200

# Triple the load
./run_and_analyze_loadtest.sh scenario4 450 1500 300
```

### Quick Validation Test (5 minutes)

```bash
# Modify scenario file to set maxDuration: '5m'
# Or create a new scenario5 with shorter duration

./run_and_analyze_loadtest.sh scenario5 50 200 20
```

### Compare Multiple Configurations

```bash
# Baseline
./run_and_analyze_loadtest.sh scenario4 150 500 120
# Save results path: results/scenario4_baseline/

# Optimized code (after changes)
./run_and_analyze_loadtest.sh scenario4 150 500 120
# Save results path: results/scenario4_optimized/

# Compare
diff results/scenario4_baseline/k6_summary.json \
     results/scenario4_optimized/k6_summary.json
```

---

## Requirements

- **k6**: Load testing tool
  ```bash
  # Install k6
  brew install k6  # macOS
  sudo snap install k6  # Linux
  ```

- **jq**: JSON parsing (optional but recommended)
  ```bash
  sudo apt-get install jq  # Ubuntu/Debian
  brew install jq          # macOS
  ```

- **Docker**: For service containers and database access

- **Go**: For pprof analysis (`go tool pprof`)

---

## Integration with Development Workflow

### Before Merging PR

```bash
# Run performance regression test
./run_and_analyze_loadtest.sh scenario4 150 500 120

# If failed, investigate profiles before merging
```

### After Optimization

```bash
# Baseline before changes
./run_and_analyze_loadtest.sh scenario4 150 500 120
mv results/scenario4_<timestamp> results/scenario4_before

# Make optimizations...

# Test after changes
./run_and_analyze_loadtest.sh scenario4 150 500 120
mv results/scenario4_<timestamp> results/scenario4_after

# Compare
echo "Before:"
jq .metrics.http_req_duration.values.p95 results/scenario4_before/k6_summary.json

echo "After:"
jq .metrics.http_req_duration.values.p95 results/scenario4_after/k6_summary.json
```

### Continuous Monitoring

```bash
# Weekly performance baseline test
crontab -e

# Add:
# 0 2 * * 1 cd /path/to/project && ./tests/loadtest/scripts/run_and_analyze_loadtest.sh
```

---

## See Also

- **k6 Scenarios**: `../k6/README_SCENARIO4.md`
- **Load Test Documentation**: `../../docs/TECH_SPEC_TESTING.md`
- **Performance Targets**: `../../docs/TECH_SPEC_M4.md`
