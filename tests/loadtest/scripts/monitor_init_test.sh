#!/bin/bash

# Initialize Endpoint Load Test Monitor
# Profiles CPU/Memory at 7-minute mark (mid-sustained phase)
# Provides real-time progress updates
#
# Usage: ./monitor_init_test.sh <results_dir>
# Example: ./monitor_init_test.sh tests/loadtest/results/init_investigation_20251113_123456
#
# Note: The results_dir should be the same directory where k6 is writing its output

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Validate arguments
if [ $# -ne 1 ]; then
    echo "ERROR: Wrong number of arguments"
    echo "Usage: $0 <results_dir>"
    echo "Example: $0 tests/loadtest/results/init_investigation_20251113_123456"
    exit 1
fi

RESULTS_DIR="$1"

# Validate results directory exists
if [ ! -d "${RESULTS_DIR}" ]; then
    echo "ERROR: Results directory does not exist: ${RESULTS_DIR}"
    exit 1
fi

# Convert to absolute path to avoid issues
RESULTS_DIR=$(cd "${RESULTS_DIR}" && pwd)

echo "=== Initialize Endpoint Load Test Monitor ==="
echo "Start time: $(date)"
echo "Results directory: ${RESULTS_DIR}"
echo ""

# Calculate target times
START_TIME=$(date +%s)
PROFILE_TIME=$((START_TIME + 420))  # 7 minutes = 420 seconds (mid-test)
EXPECTED_END=$((START_TIME + 600))  # 10 minutes = 600 seconds

echo "Timeline:"
echo "  - Warm-up:   0-2min   (10→50 RPS)"
echo "  - Ramp-up:   2-5min   (50→300 RPS)"
echo "  - Sustained: 5-10min  (300 RPS constant)"
echo ""
echo "  - Profile at: $(date -d @$PROFILE_TIME '+%Y-%m-%d %H:%M:%S') (7 min mark)"
echo "  - Expected end: $(date -d @$EXPECTED_END '+%Y-%m-%d %H:%M:%S') (10 min total)"
echo ""

# Function to check if k6 is still running
check_k6_running() {
    # Check if k6 process exists by looking for k6 command with our script
    # Use pidof to avoid false matches with shell commands
    if command -v pidof > /dev/null 2>&1; then
        pidof k6 > /dev/null 2>&1
        return $?
    else
        # Fallback to ps/grep if pidof not available
        ps aux | awk '/[k]6 run/ && /scenario3_init_only/ && !/awk/ {found=1} END {exit !found}'
        return $?
    fi
}

# Function to capture profiles
capture_profiles() {
    local MARK=$1
    local PROFILE_DIR="${RESULTS_DIR}/profiles"

    echo ""
    echo "=== PROFILING AT ${MARK} ==="
    echo "Time: $(date)"
    echo ""

    # Create profiles directory if it doesn't exist
    mkdir -p "${PROFILE_DIR}"

    # 1. pprof CPU Profile (30 seconds sample)
    echo "--- Go pprof CPU Profile (30s sample) ---"
    echo "  Challenge Service: Capturing CPU profile..."
    if curl -f -s --max-time 35 "http://localhost:8080/debug/pprof/profile?seconds=30" -o "${PROFILE_DIR}/service_cpu_${MARK}.pprof"; then
        echo "  ✓ Service CPU profile saved ($(du -h "${PROFILE_DIR}/service_cpu_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service CPU profile"
    fi

    echo "  Event Handler: Capturing CPU profile..."
    if curl -f -s --max-time 35 "http://localhost:8081/debug/pprof/profile?seconds=30" -o "${PROFILE_DIR}/handler_cpu_${MARK}.pprof"; then
        echo "  ✓ Handler CPU profile saved ($(du -h "${PROFILE_DIR}/handler_cpu_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler CPU profile"
    fi
    echo ""

    # 2. pprof Heap Profile (memory allocation)
    echo "--- Go pprof Heap Profile ---"
    echo "  Challenge Service: Capturing heap profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/heap" -o "${PROFILE_DIR}/service_heap_${MARK}.pprof"; then
        echo "  ✓ Service heap profile saved ($(du -h "${PROFILE_DIR}/service_heap_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service heap profile"
    fi

    echo "  Event Handler: Capturing heap profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/heap" -o "${PROFILE_DIR}/handler_heap_${MARK}.pprof"; then
        echo "  ✓ Handler heap profile saved ($(du -h "${PROFILE_DIR}/handler_heap_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler heap profile"
    fi
    echo ""

    # 3. pprof Goroutine Profile
    echo "--- Go pprof Goroutine Profile ---"
    echo "  Challenge Service: Capturing goroutine profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/goroutine" -o "${PROFILE_DIR}/service_goroutine_${MARK}.txt"; then
        echo "  ✓ Service goroutine profile saved ($(du -h "${PROFILE_DIR}/service_goroutine_${MARK}.txt" | cut -f1))"
        # Show goroutine count
        GOROUTINE_COUNT=$(curl -s "http://localhost:8080/debug/pprof/goroutine?debug=1" | grep -c "^goroutine" || echo "0")
        echo "  📊 Active goroutines: ${GOROUTINE_COUNT}"
    else
        echo "  ✗ Failed to capture service goroutine profile"
    fi

    echo "  Event Handler: Capturing goroutine profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/goroutine" -o "${PROFILE_DIR}/handler_goroutine_${MARK}.txt"; then
        echo "  ✓ Handler goroutine profile saved ($(du -h "${PROFILE_DIR}/handler_goroutine_${MARK}.txt" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler goroutine profile"
    fi
    echo ""

    # 4. pprof Mutex Profile (contention)
    echo "--- Go pprof Mutex Profile ---"
    echo "  Challenge Service: Capturing mutex profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/mutex" -o "${PROFILE_DIR}/service_mutex_${MARK}.pprof"; then
        echo "  ✓ Service mutex profile saved ($(du -h "${PROFILE_DIR}/service_mutex_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service mutex profile"
    fi

    echo "  Event Handler: Capturing mutex profile..."
    if curl -f -s "http://localhost:8081/debug/pprof/mutex" -o "${PROFILE_DIR}/handler_mutex_${MARK}.pprof"; then
        echo "  ✓ Handler mutex profile saved ($(du -h "${PROFILE_DIR}/handler_mutex_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture handler mutex profile"
    fi
    echo ""

    # 5. pprof Allocs Profile (allocation rate)
    echo "--- Go pprof Allocs Profile ---"
    echo "  Challenge Service: Capturing allocs profile..."
    if curl -f -s "http://localhost:8080/debug/pprof/allocs" -o "${PROFILE_DIR}/service_allocs_${MARK}.pprof"; then
        echo "  ✓ Service allocs profile saved ($(du -h "${PROFILE_DIR}/service_allocs_${MARK}.pprof" | cut -f1))"
    else
        echo "  ✗ Failed to capture service allocs profile"
    fi
    echo ""
}

# Function to capture database stats
capture_db_stats() {
    local MARK=$1
    local DB_STATS_FILE="${RESULTS_DIR}/db_stats_${MARK}.txt"

    echo "--- Database Performance Stats (${MARK}) ---" | tee "${DB_STATS_FILE}"

    echo "  Connection Stats:" | tee -a "${DB_STATS_FILE}"
    docker exec challenge-postgres psql -U postgres -d challenge_db -c "
        SELECT
            count(*) as total_connections,
            count(*) FILTER (WHERE state = 'active') as active,
            count(*) FILTER (WHERE state = 'idle') as idle,
            count(*) FILTER (WHERE state = 'idle in transaction') as idle_in_transaction,
            count(*) FILTER (WHERE wait_event_type = 'Client') as waiting_for_client
        FROM pg_stat_activity
        WHERE datname = 'challenge_db';
    " | tee -a "${DB_STATS_FILE}"
    echo "" | tee -a "${DB_STATS_FILE}"

    echo "  Active Queries:" | tee -a "${DB_STATS_FILE}"
    docker exec challenge-postgres psql -U postgres -d challenge_db -c "
        SELECT
            pid,
            state,
            wait_event_type,
            wait_event,
            EXTRACT(EPOCH FROM (NOW() - query_start))::int as duration_seconds,
            LEFT(query, 80) as query_preview
        FROM pg_stat_activity
        WHERE datname = 'challenge_db'
          AND state = 'active'
          AND pid != pg_backend_pid()
        ORDER BY query_start
        LIMIT 10;
    " | tee -a "${DB_STATS_FILE}"
    echo "" | tee -a "${DB_STATS_FILE}"

    echo "  Table Stats (user_goal_progress):" | tee -a "${DB_STATS_FILE}"
    docker exec challenge-postgres psql -U postgres -d challenge_db -c "
        SELECT
            seq_scan as sequential_scans,
            seq_tup_read as rows_seq_read,
            idx_scan as index_scans,
            idx_tup_fetch as rows_idx_fetched,
            n_tup_ins as inserts,
            n_tup_upd as updates,
            n_live_tup as live_rows,
            n_dead_tup as dead_rows
        FROM pg_stat_user_tables
        WHERE relname = 'user_goal_progress';
    " | tee -a "${DB_STATS_FILE}"
    echo "" | tee -a "${DB_STATS_FILE}"

    echo "  Database Size:" | tee -a "${DB_STATS_FILE}"
    docker exec challenge-postgres psql -U postgres -d challenge_db -c "
        SELECT
            pg_size_pretty(pg_database_size('challenge_db')) as db_size,
            (SELECT COUNT(*) FROM user_goal_progress) as total_rows,
            (SELECT COUNT(DISTINCT user_id) FROM user_goal_progress) as unique_users;
    " | tee -a "${DB_STATS_FILE}"
    echo "" | tee -a "${DB_STATS_FILE}"
}

# Function to capture container stats
capture_container_stats() {
    local MARK=$1
    local CONTAINER_STATS_FILE="${RESULTS_DIR}/container_stats_${MARK}.txt"

    echo "--- Docker Container Stats (${MARK}) ---" | tee "${CONTAINER_STATS_FILE}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" \
        challenge-service challenge-event-handler challenge-postgres challenge-redis | tee -a "${CONTAINER_STATS_FILE}"
    echo "" | tee -a "${CONTAINER_STATS_FILE}"
}

# Function to capture HTTP metrics
capture_http_metrics() {
    local MARK=$1
    local METRICS_FILE="${RESULTS_DIR}/http_metrics_${MARK}.txt"

    echo "--- HTTP Performance Metrics (${MARK}) ---" | tee "${METRICS_FILE}"

    echo "  Recent Initialize Requests (last 20):" | tee -a "${METRICS_FILE}"
    docker logs challenge-service --tail=200 2>&1 | grep -i "initialize" | tail -20 | tee -a "${METRICS_FILE}"
    echo "" | tee -a "${METRICS_FILE}"

    echo "  Slow Requests (>1s):" | tee -a "${METRICS_FILE}"
    docker logs challenge-service --tail=500 2>&1 | grep -i "slow\|timeout\|error" | tail -20 | tee -a "${METRICS_FILE}"
    echo "" | tee -a "${METRICS_FILE}"
}

# Wait for k6 to start (give it up to 10 seconds)
echo "Waiting for k6 to start..."
for i in {1..10}; do
    if check_k6_running; then
        echo "✓ k6 process detected"
        break
    fi
    echo "  Waiting for k6 process... ($i/10)"
    sleep 1
done

if ! check_k6_running; then
    echo "⚠️  WARNING: k6 process not detected after 10 seconds"
    echo "  Profiles may not be captured correctly"
fi

# Wait for 7 minutes or until test completes
echo ""
echo "Waiting for 7-minute mark to profile services..."
while [ $(date +%s) -lt $PROFILE_TIME ]; do
    if ! check_k6_running; then
        echo "⚠️  k6 process not found at $(date '+%H:%M:%S')"
        echo "  Load test may have completed early or failed to start"
        break
    fi
    sleep 15
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((ELAPSED * 100 / 420))

    # Show phase
    if [ $ELAPSED -lt 120 ]; then
        PHASE="Warm-up"
    elif [ $ELAPSED -lt 300 ]; then
        PHASE="Ramp-up"
    else
        PHASE="Sustained"
    fi

    echo "  $(date '+%H:%M:%S') - Phase: ${PHASE} | Elapsed: ${ELAPSED}s / 420s (${PERCENT}%) - k6 running: ✓"
done

# Profile at 7-minute mark if still running
if check_k6_running; then
    capture_profiles "7min"
    capture_db_stats "7min"
    capture_container_stats "7min"
    capture_http_metrics "7min"

    # List all captured files
    echo ""
    echo "📊 Profile files saved to: ${RESULTS_DIR}/profiles/"
    echo ""
    if ls "${RESULTS_DIR}"/profiles/*7min* 1> /dev/null 2>&1; then
        ls -lh "${RESULTS_DIR}"/profiles/*7min* | awk '{print "   " $9 " (" $5 ")"}'
    else
        echo "   ⚠️  No profile files found"
    fi
    echo ""
    echo "📊 Stats files saved to: ${RESULTS_DIR}/"
    ls -lh "${RESULTS_DIR}"/*7min*.txt | awk '{print "   " $9 " (" $5 ")"}'
    echo ""
    echo "📖 To analyze pprof files:"
    echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/profiles/service_cpu_7min.pprof"
    echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/profiles/service_heap_7min.pprof"
    echo "   go tool pprof -top ${RESULTS_DIR}/profiles/service_cpu_7min.pprof"
    echo ""
else
    echo ""
    echo "⚠️  Load test completed before 7-minute mark - no profiles captured"
    echo ""
fi

# Wait for completion
echo ""
echo "Waiting for load test completion..."
while check_k6_running; do
    sleep 15
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((ELAPSED * 100 / 600))
    echo "  $(date '+%H:%M:%S') - Elapsed: ${ELAPSED}s / 600s (${PERCENT}%)"
done

# Capture final stats
echo ""
echo "Capturing final stats..."
capture_db_stats "final"
capture_container_stats "final"

echo ""
echo "=== Load Test Completed ==="
echo "End time: $(date)"
TOTAL_DURATION=$(($(date +%s) - START_TIME))
echo "Total duration: ${TOTAL_DURATION} seconds ($(($TOTAL_DURATION / 60)) minutes)"
echo ""
echo "Results saved to: ${RESULTS_DIR}/"
echo ""
echo "📊 Quick Analysis Commands:"
echo ""
echo "1. Check k6 summary:"
echo "   cat ${RESULTS_DIR}/k6_output.log | tail -100"
echo ""
echo "2. Analyze CPU profile:"
echo "   go tool pprof -http=:8082 ${RESULTS_DIR}/profiles/service_cpu_7min.pprof"
echo ""
echo "3. Check for hot functions:"
echo "   go tool pprof -top ${RESULTS_DIR}/profiles/service_cpu_7min.pprof | head -20"
echo ""
echo "4. Check memory allocations:"
echo "   go tool pprof -top ${RESULTS_DIR}/profiles/service_allocs_7min.pprof | head -20"
echo ""
echo "5. Compare SQL performance:"
echo "   docker exec -i challenge-postgres psql -U postgres -d challenge_db < tests/loadtest/sql/quick_benchmark.sql"
echo ""
echo "6. Check database stats:"
echo "   cat ${RESULTS_DIR}/db_stats_7min.txt"
echo ""
