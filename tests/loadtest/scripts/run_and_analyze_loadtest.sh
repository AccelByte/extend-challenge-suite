#!/bin/bash

# Automated Load Test Runner with Monitoring and Analysis
#
# This script:
# 1. Sets up a timestamped results directory
# 2. Starts k6 loadtest (30 minutes)
# 3. Starts monitoring script (profiles at 15-min mark)
# 4. Waits for completion
# 5. Analyzes results and generates summary
#
# Usage: ./run_and_analyze_loadtest.sh [scenario_name] [target_vus] [target_eps]
# Example: ./run_and_analyze_loadtest.sh scenario4 150 500

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LOADTEST_DIR="${PROJECT_ROOT}/tests/loadtest"
K6_DIR="${LOADTEST_DIR}/k6"
RESULTS_BASE_DIR="${LOADTEST_DIR}/results"

# Default parameters
SCENARIO_NAME="${1:-scenario4}"
TARGET_VUS="${2:-150}"
TARGET_EPS="${3:-500}"
ITERATIONS="${4:-120}"

# Validate scenario file exists
# Try exact match first (e.g. scenario5_m5_rotation), then glob for prefix
SCENARIO_FILE="${K6_DIR}/${SCENARIO_NAME}.js"
if [ ! -f "${SCENARIO_FILE}" ]; then
    SCENARIO_FILE=$(ls "${K6_DIR}/${SCENARIO_NAME}"*.js 2>/dev/null | head -1)
fi
if [ -z "${SCENARIO_FILE}" ] || [ ! -f "${SCENARIO_FILE}" ]; then
    echo "❌ ERROR: No scenario file found matching: ${SCENARIO_NAME}"
    echo "Available scenarios:"
    ls -1 "${K6_DIR}"/scenario*.js 2>/dev/null || echo "  (none found)"
    exit 1
fi

# ============================================================================
# SETUP
# ============================================================================

# Create timestamped results directory
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RESULTS_DIR="${RESULTS_BASE_DIR}/${SCENARIO_NAME}_${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

# Set up log files
K6_LOG="${RESULTS_DIR}/k6_output.log"
MONITOR_LOG="${RESULTS_DIR}/monitor_output.log"
SUMMARY_FILE="${RESULTS_DIR}/analysis_summary.md"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Automated Load Test Runner & Analyzer                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Scenario:     ${SCENARIO_NAME}"
echo "  Target VUs:   ${TARGET_VUS}"
echo "  Target EPS:   ${TARGET_EPS}"
echo "  Iterations:   ${ITERATIONS}"
echo "  Results Dir:  ${RESULTS_DIR}"
echo ""
echo "Start Time:     $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================

# Load environment variables if .env exists
if [ -f "${PROJECT_ROOT}/.env" ]; then
    echo "Loading environment from ${PROJECT_ROOT}/.env"
    set -a
    source "${PROJECT_ROOT}/.env"
    set +a
fi

# Set default environment variables for k6
export BASE_URL="${BASE_URL:-http://localhost:8000/challenge}"
export EVENT_HANDLER_ADDR="${EVENT_HANDLER_ADDR:-localhost:6566}"
export NAMESPACE="${NAMESPACE:-test}"
export CHALLENGE_ID="${CHALLENGE_ID:-daily-challenges}"
export TARGET_VUS="${TARGET_VUS}"
export TARGET_EPS="${TARGET_EPS}"
export ITERATIONS="${ITERATIONS}"

echo "Environment:"
echo "  BASE_URL:            ${BASE_URL}"
echo "  EVENT_HANDLER_ADDR:  ${EVENT_HANDLER_ADDR}"
echo "  NAMESPACE:           ${NAMESPACE}"
echo "  CHALLENGE_ID:        ${CHALLENGE_ID}"
echo ""

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Pre-Flight Checks                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if services are running
echo "Checking service health..."

if ! curl -f -s "${BASE_URL}/healthz" > /dev/null 2>&1; then
    echo "❌ Challenge Service not responding at ${BASE_URL}/healthz"
    echo "   Please start services with: docker-compose up -d"
    exit 1
fi
echo "✅ Challenge Service is healthy"

if ! nc -z localhost 6566 2>/dev/null; then
    echo "❌ Event Handler not reachable at localhost:6566"
    echo "   Please start services with: docker-compose up -d"
    exit 1
fi
echo "✅ Event Handler is reachable"

# Check if database is accessible
if ! docker exec challenge-postgres pg_isready -U postgres > /dev/null 2>&1; then
    echo "❌ PostgreSQL is not ready"
    exit 1
fi
echo "✅ PostgreSQL is ready"

echo ""

# ============================================================================
# SCENARIO-SPECIFIC PRE-FLIGHT: STALE ROW SEEDING (M5 ROTATION)
# ============================================================================

STALE_SEED_PID=""

if [[ "${SCENARIO_NAME}" == *"scenario5"* ]]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║              Seeding Stale Rotation Rows (M5)                  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Back-dating ~40% of daily rotation rows to simulate previous-period data."
    echo "This triggers the SQL CASE rotation reset logic in the event handler."
    echo ""

    docker exec challenge-postgres psql -U postgres -d challenge_db -c "
        UPDATE user_goal_progress
        SET updated_at = NOW() - INTERVAL '2 days'
        WHERE goal_id LIKE 'daily-goal-%'
          AND random() < 0.4;
    " 2>/dev/null || true
    echo "✅ Stale rows seeded (40% of daily goals backdated)"
    echo ""
fi

# ============================================================================
# START LOAD TEST
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Starting Load Test                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Start k6 in background
echo "Starting k6 loadtest..."
k6 run "${SCENARIO_FILE}" \
    --out json="${RESULTS_DIR}/k6_metrics.json" \
    --summary-export="${RESULTS_DIR}/k6_summary.json" \
    > "${K6_LOG}" 2>&1 &

K6_PID=$!
echo "✅ k6 started (PID: ${K6_PID})"
echo "   Log: ${K6_LOG}"
echo ""

# Give k6 a moment to start
sleep 5

# Verify k6 is still running
if ! ps -p ${K6_PID} > /dev/null; then
    echo "❌ k6 failed to start. Check log:"
    tail -20 "${K6_LOG}"
    exit 1
fi

# Start periodic stale-row re-seeding for rotation scenarios
if [[ "${SCENARIO_NAME}" == *"scenario5"* ]]; then
    echo "Starting periodic stale-row re-seeding (every 5 minutes)..."
    (
        while kill -0 ${K6_PID} 2>/dev/null; do
            sleep 300
            docker exec challenge-postgres psql -U postgres -d challenge_db -c "
                UPDATE user_goal_progress
                SET updated_at = NOW() - INTERVAL '2 days'
                WHERE goal_id LIKE 'daily-goal-%'
                  AND random() < 0.4;
            " 2>/dev/null || true
            echo "$(date '+%H:%M:%S') Re-seeded stale rotation rows"
        done
    ) &
    STALE_SEED_PID=$!
    echo "✅ Stale-row re-seeder started (PID: ${STALE_SEED_PID})"
    echo ""
fi

# ============================================================================
# START MONITORING
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Starting Monitor                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Start monitor script in background
echo "Starting monitoring script..."
"${SCRIPT_DIR}/monitor_loadtest.sh" "${RESULTS_DIR}" > "${MONITOR_LOG}" 2>&1 &

MONITOR_PID=$!
echo "✅ Monitor started (PID: ${MONITOR_PID})"
echo "   Log: ${MONITOR_LOG}"
echo ""

# ============================================================================
# WAIT FOR COMPLETION
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Running Load Test                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Test is running... This will take approximately 30 minutes."
echo "You can monitor progress in real-time:"
echo "  - k6 output:     tail -f ${K6_LOG}"
echo "  - Monitor log:   tail -f ${MONITOR_LOG}"
echo ""

START_TIME=$(date +%s)

# Wait for k6 to complete
wait ${K6_PID}
K6_EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Load Test Completed                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "End Time:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "Duration:     ${DURATION} seconds ($((DURATION / 60)) minutes)"
echo "k6 Exit Code: ${K6_EXIT_CODE}"
echo ""

# Stop stale-row re-seeder if running
if [ -n "${STALE_SEED_PID}" ]; then
    kill ${STALE_SEED_PID} 2>/dev/null || true
    wait ${STALE_SEED_PID} 2>/dev/null || true
    echo "✅ Stale-row re-seeder stopped"
fi

# Wait for monitor to finish (it should detect k6 completion)
echo "Waiting for monitor to finish..."
wait ${MONITOR_PID} 2>/dev/null || true
echo ""

# ============================================================================
# ANALYZE RESULTS
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Analyzing Results                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Start building summary file
cat > "${SUMMARY_FILE}" << EOF
# Load Test Analysis Summary

**Test:** ${SCENARIO_NAME}
**Timestamp:** $(date '+%Y-%m-%d %H:%M:%S')
**Duration:** ${DURATION} seconds ($((DURATION / 60)) minutes)
**Configuration:**
- Target VUs: ${TARGET_VUS}
- Target EPS: ${TARGET_EPS}
- Iterations: ${ITERATIONS}

---

## Test Result: $([ ${K6_EXIT_CODE} -eq 0 ] && echo "✅ PASSED" || echo "❌ FAILED")

k6 Exit Code: ${K6_EXIT_CODE}

---

## Key Metrics

EOF

# Extract key metrics from k6 summary JSON
if [ -f "${RESULTS_DIR}/k6_summary.json" ]; then
    echo "Extracting metrics from k6 summary..."

    # Use jq to parse JSON (if available), otherwise parse manually
    if command -v jq &> /dev/null; then
        # k6 summary format: .metrics.<name>["p(95)"] (not .values.p95)
        # Handle both old (.values.X) and current (.X) formats
        _jq_val() {
            local result
            result=$(jq -r "$1" "${RESULTS_DIR}/k6_summary.json" 2>/dev/null)
            if [ "$result" = "null" ] || [ -z "$result" ]; then echo "N/A"; else echo "$result"; fi
        }

        # HTTP Request Duration
        HTTP_P95=$(_jq_val '.metrics.http_req_duration["p(95)"]')
        HTTP_P99=$(_jq_val '.metrics.http_req_duration["p(99)"]')
        HTTP_AVG=$(_jq_val '.metrics.http_req_duration.avg')

        # HTTP Request Failed Rate
        HTTP_FAILED_RATE=$(_jq_val '.metrics.http_req_failed.rate // .metrics.http_req_failed.values.rate')

        # Checks
        CHECKS_RATE=$(_jq_val '.metrics.checks.rate // .metrics.checks.values.rate')

        # Endpoint metrics
        BATCH_SELECT_P95=$(_jq_val '.metrics["http_req_duration{endpoint:batch_select}"]["p(95)"]')
        RANDOM_SELECT_P95=$(_jq_val '.metrics["http_req_duration{endpoint:random_select}"]["p(95)"]')
        INITIALIZE_P95=$(_jq_val '.metrics["http_req_duration{endpoint:initialize}"]["p(95)"]')
        BROWSE_P95=$(_jq_val '.metrics["http_req_duration{endpoint:browse_challenges}"]["p(95)"]')
        CLAIM_P95=$(_jq_val '.metrics["http_req_duration{endpoint:claim}"]["p(95)"]')
        ROTATION_STATUS_P95=$(_jq_val '.metrics["http_req_duration{endpoint:rotation_status}"]["p(95)"]')
        CHECK_PROGRESS_P95=$(_jq_val '.metrics["http_req_duration{endpoint:check_progress}"]["p(95)"]')

        # gRPC metrics
        GRPC_P95=$(_jq_val '.metrics.grpc_req_duration["p(95)"]')
        GRPC_AVG=$(_jq_val '.metrics.grpc_req_duration.avg')

        # Total requests
        HTTP_REQS=$(_jq_val '.metrics.http_reqs.count')

        cat >> "${SUMMARY_FILE}" << EOF
### HTTP Metrics

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| HTTP Request Duration (p95) | ${HTTP_P95} ms | < 2000 ms | $([ "${HTTP_P95}" != "N/A" ] && awk "BEGIN {exit !(${HTTP_P95} < 2000)}" && echo "✅" || echo "❌") |
| HTTP Request Duration (p99) | ${HTTP_P99} ms | - | - |
| HTTP Request Duration (avg) | ${HTTP_AVG} ms | - | - |
| HTTP Request Failed Rate | $([ "${HTTP_FAILED_RATE}" != "N/A" ] && awk "BEGIN {printf \"%.2f%%\", ${HTTP_FAILED_RATE} * 100}" || echo "N/A") | < 1% | $([ "${HTTP_FAILED_RATE}" != "N/A" ] && awk "BEGIN {exit !(${HTTP_FAILED_RATE} < 0.01)}" && echo "✅" || echo "❌") |
| Checks Pass Rate | $([ "${CHECKS_RATE}" != "N/A" ] && awk "BEGIN {printf \"%.2f%%\", ${CHECKS_RATE} * 100}" || echo "N/A") | > 99% | $([ "${CHECKS_RATE}" != "N/A" ] && awk "BEGIN {exit !(${CHECKS_RATE} > 0.99)}" && echo "✅" || echo "❌") |
| Total HTTP Requests | ${HTTP_REQS} | - | - |

### Endpoint Performance

| Endpoint | p95 Latency | Threshold | Status |
|----------|-------------|-----------|--------|
| Batch Select | ${BATCH_SELECT_P95} ms | < 50 ms | $([ "${BATCH_SELECT_P95}" != "N/A" ] && awk "BEGIN {exit !(${BATCH_SELECT_P95} < 50)}" && echo "✅ PASS" || echo "❌ FAIL") |
| Random Select | ${RANDOM_SELECT_P95} ms | < 50 ms | $([ "${RANDOM_SELECT_P95}" != "N/A" ] && awk "BEGIN {exit !(${RANDOM_SELECT_P95} < 50)}" && echo "✅ PASS" || echo "❌ FAIL") |
| Initialize | ${INITIALIZE_P95} ms | < 100 ms | $([ "${INITIALIZE_P95}" != "N/A" ] && awk "BEGIN {exit !(${INITIALIZE_P95} < 100)}" && echo "✅ PASS" || echo "- ") |
| Browse Challenges | ${BROWSE_P95} ms | < 500 ms | $([ "${BROWSE_P95}" != "N/A" ] && awk "BEGIN {exit !(${BROWSE_P95} < 500)}" && echo "✅ PASS" || echo "- ") |
| Claim | ${CLAIM_P95} ms | < 100 ms | $([ "${CLAIM_P95}" != "N/A" ] && awk "BEGIN {exit !(${CLAIM_P95} < 100)}" && echo "✅ PASS" || echo "- ") |
| Rotation Status | ${ROTATION_STATUS_P95} ms | < 100 ms | $([ "${ROTATION_STATUS_P95}" != "N/A" ] && awk "BEGIN {exit !(${ROTATION_STATUS_P95} < 100)}" && echo "✅ PASS" || echo "- ") |
| Check Progress | ${CHECK_PROGRESS_P95} ms | < 500 ms | $([ "${CHECK_PROGRESS_P95}" != "N/A" ] && awk "BEGIN {exit !(${CHECK_PROGRESS_P95} < 500)}" && echo "✅ PASS" || echo "- ") |

### gRPC Event Processing

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|
| gRPC Duration (p95) | ${GRPC_P95} ms | < 500 ms | $([ "${GRPC_P95}" != "N/A" ] && awk "BEGIN {exit !(${GRPC_P95} < 500)}" && echo "✅ PASS" || echo "- ") |
| gRPC Duration (avg) | ${GRPC_AVG} ms | - | - |

EOF

        # Print to console
        echo "HTTP Metrics:"
        echo "  - Request Duration (p95): ${HTTP_P95} ms"
        echo "  - Request Duration (p99): ${HTTP_P99} ms"
        echo "  - Request Failed Rate:    $([ "${HTTP_FAILED_RATE}" != "N/A" ] && awk "BEGIN {printf \"%.2f%%\", ${HTTP_FAILED_RATE} * 100}" || echo "N/A")"
        echo "  - Checks Pass Rate:       $([ "${CHECKS_RATE}" != "N/A" ] && awk "BEGIN {printf \"%.2f%%\", ${CHECKS_RATE} * 100}" || echo "N/A")"
        echo ""
        echo "Endpoint Performance:"
        echo "  - Batch Select (p95):     ${BATCH_SELECT_P95} ms"
        echo "  - Random Select (p95):    ${RANDOM_SELECT_P95} ms"
        echo "  - Initialize (p95):       ${INITIALIZE_P95} ms"
        echo "  - Browse (p95):           ${BROWSE_P95} ms"
        echo "  - Claim (p95):            ${CLAIM_P95} ms"
        echo "  - Rotation Status (p95):  ${ROTATION_STATUS_P95} ms"
        echo ""
        echo "gRPC Event Processing:"
        echo "  - gRPC p95: ${GRPC_P95} ms"
        echo "  - gRPC avg: ${GRPC_AVG} ms"
        echo ""
    else
        echo "⚠️  jq not installed - skipping JSON parsing"
        echo "Install jq for detailed metric analysis: sudo apt-get install jq"
        cat >> "${SUMMARY_FILE}" << EOF
### Metrics

*(jq not available - see k6_summary.json for raw data)*

EOF
    fi
else
    echo "⚠️  k6 summary file not found: ${RESULTS_DIR}/k6_summary.json"
    cat >> "${SUMMARY_FILE}" << EOF
### Metrics

*(Summary file not generated - test may have failed early)*

EOF
fi

# ============================================================================
# PROFILE ANALYSIS
# ============================================================================

cat >> "${SUMMARY_FILE}" << EOF

---

## Profile Files

EOF

echo "Profile files captured:"
if ls "${RESULTS_DIR}"/*15min* 1> /dev/null 2>&1; then
    ls -lh "${RESULTS_DIR}"/*15min* | awk '{print "  - " $9 " (" $5 ")"}'

    cat >> "${SUMMARY_FILE}" << EOF
The following profile files were captured at the 15-minute mark:

EOF

    for file in "${RESULTS_DIR}"/*15min*; do
        FILENAME=$(basename "${file}")
        FILESIZE=$(du -h "${file}" | cut -f1)
        echo "- \`${FILENAME}\` (${FILESIZE})" >> "${SUMMARY_FILE}"
    done

    cat >> "${SUMMARY_FILE}" << EOF

### How to Analyze Profiles

#### CPU Profiles
\`\`\`bash
go tool pprof -http=:8082 ${RESULTS_DIR}/service_cpu_15min.pprof
go tool pprof -http=:8082 ${RESULTS_DIR}/handler_cpu_15min.pprof
\`\`\`

#### Heap Profiles
\`\`\`bash
go tool pprof -http=:8082 ${RESULTS_DIR}/service_heap_15min.pprof
go tool pprof -http=:8082 ${RESULTS_DIR}/handler_heap_15min.pprof
\`\`\`

#### Goroutine Analysis
\`\`\`bash
go tool pprof -http=:8082 ${RESULTS_DIR}/service_goroutine_15min.txt
\`\`\`

#### Mutex Contention
\`\`\`bash
go tool pprof -http=:8082 ${RESULTS_DIR}/service_mutex_15min.pprof
\`\`\`

EOF
else
    echo "  ⚠️  No profile files found (test may have completed before 15-minute mark)"
    cat >> "${SUMMARY_FILE}" << EOF
*(No profile files captured - test may have completed before 15-minute mark)*

EOF
fi

echo ""

# ============================================================================
# DATABASE STATS
# ============================================================================

cat >> "${SUMMARY_FILE}" << EOF

---

## Database Performance

EOF

if docker exec challenge-postgres psql -U postgres -d challenge_db -c "SELECT 1" > /dev/null 2>&1; then
    echo "Collecting database stats..."

    # Get final table stats
    FINAL_STATS=$(docker exec challenge-postgres psql -U postgres -d challenge_db -t -c "
        SELECT
            n_tup_ins as inserts,
            n_tup_upd as updates,
            n_live_tup as live_rows,
            idx_scan as index_scans,
            seq_scan as seq_scans
        FROM pg_stat_user_tables
        WHERE relname = 'user_goal_progress';
    " | tr -s ' ' | sed 's/^ //g')

    cat >> "${SUMMARY_FILE}" << EOF
### Table Stats (user_goal_progress)

\`\`\`
${FINAL_STATS}
\`\`\`

EOF

    echo "  ✅ Database stats captured"
else
    echo "  ⚠️  Could not connect to database"
    cat >> "${SUMMARY_FILE}" << EOF
*(Database stats unavailable)*

EOF
fi

echo ""

# ============================================================================
# RECOMMENDATIONS
# ============================================================================

cat >> "${SUMMARY_FILE}" << EOF

---

## Recommendations

EOF

# Generate recommendations based on results
if [ ${K6_EXIT_CODE} -eq 0 ]; then
    cat >> "${SUMMARY_FILE}" << EOF
✅ **All thresholds passed!** The system is performing within acceptable limits.

### Suggested Next Steps:
1. Review profile data for potential optimizations
2. Check for any anomalies in the monitoring logs
3. Consider increasing load for stress testing
4. Archive these results for future comparison

EOF
else
    cat >> "${SUMMARY_FILE}" << EOF
❌ **Some thresholds failed.** Review the metrics above and investigate:

### Troubleshooting Steps:
1. Check which specific thresholds failed (see metrics table)
2. Review CPU profiles for hotspots
3. Analyze heap profiles for memory issues
4. Check database query performance
5. Review application logs for errors
6. Consider optimizations based on profile analysis

### Common Issues:
- **High latency**: Check CPU profiles for bottlenecks
- **Failed requests**: Review application logs
- **Low throughput**: Analyze database connection pooling
- **Memory growth**: Investigate heap profiles

EOF
fi

# ============================================================================
# FINALIZE
# ============================================================================

cat >> "${SUMMARY_FILE}" << EOF

---

## Files Generated

- **k6 Output:** \`k6_output.log\`
- **k6 Metrics:** \`k6_metrics.json\`
- **k6 Summary:** \`k6_summary.json\`
- **Monitor Log:** \`monitor_output.log\`
- **This Summary:** \`analysis_summary.md\`
- **Results Directory:** \`${RESULTS_DIR}\`

---

*Generated by run_and_analyze_loadtest.sh on $(date '+%Y-%m-%d %H:%M:%S')*
EOF

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Analysis Complete                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Summary Report: ${SUMMARY_FILE}"
echo ""
echo "View full report:"
echo "  cat ${SUMMARY_FILE}"
echo ""
echo "Or in your browser (if you have markdown viewer):"
echo "  open ${SUMMARY_FILE}  # macOS"
echo "  xdg-open ${SUMMARY_FILE}  # Linux"
echo ""

# Exit with same code as k6
exit ${K6_EXIT_CODE}
