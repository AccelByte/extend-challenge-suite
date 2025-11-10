#!/bin/bash

# Run all M2 load testing scenarios
# This is a comprehensive test runner that executes all scenarios at multiple load levels
# Usage: ./run_all_scenarios.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Database connection settings
DB_HOST=${DB_HOST:-"localhost"}
DB_PORT=${DB_PORT:-"5433"}
DB_NAME=${DB_NAME:-"challenge_db"}
DB_USER=${DB_USER:-"postgres"}
export PGPASSWORD=${DB_PASSWORD:-"postgres"}

echo "=========================================="
echo "M2 Load Testing - Automated Test Runner"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v k6 &> /dev/null; then
    echo -e "${RED}❌ k6 not found. Please install k6 first.${NC}"
    exit 1
fi

if ! command -v psql &> /dev/null; then
    echo -e "${RED}❌ psql not found. Please install PostgreSQL client.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo ""

# Reset database function
reset_database() {
    echo "Resetting database..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "TRUNCATE TABLE user_goal_progress;" > /dev/null 2>&1
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_stat_statements_reset();" > /dev/null 2>&1
    echo -e "${GREEN}✅ Database reset${NC}"
}

# Cool down function
cooldown() {
    local duration=${1:-60}
    echo "Cooling down for ${duration}s..."
    sleep $duration
}

# ============================================================================
# Scenario 1: API Load (Isolated)
# ============================================================================
echo ""
echo "=========================================="
echo "Scenario 1: API Load Testing (Isolated)"
echo "=========================================="
echo ""

mkdir -p test/results/scenario1

API_LEVELS=(50 100 200 500 1000 2000 5000)

for RPS in "${API_LEVELS[@]}"; do
    echo ""
    echo -e "${YELLOW}Testing API load at $RPS RPS...${NC}"

    reset_database
    sleep 5

    TARGET_RPS=$RPS k6 run \
        --web-dashboard \
        --out json=test/results/scenario1/level_${RPS}rps.json \
        test/k6/scenario1_api_load.js

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Test FAILED at $RPS RPS - System at limit${NC}"
        echo "Maximum API RPS: $(($RPS / 2)) (estimate)"
        break
    fi

    echo -e "${GREEN}✅ Test PASSED at $RPS RPS${NC}"
    cooldown 60
done

# ============================================================================
# Scenario 2: Event Load (Isolated)
# ============================================================================
echo ""
echo "=========================================="
echo "Scenario 2: Event Load Testing (Isolated)"
echo "=========================================="
echo ""

mkdir -p test/results/scenario2

EVENT_LEVELS=(100 500 1000 2000 5000 10000)

for EPS in "${EVENT_LEVELS[@]}"; do
    echo ""
    echo -e "${YELLOW}Testing event load at $EPS EPS...${NC}"

    reset_database
    sleep 5

    TARGET_EPS=$EPS k6 run \
        --web-dashboard \
        --out json=test/results/scenario2/level_${EPS}eps.json \
        test/k6/scenario2_event_load.js

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Test FAILED at $EPS EPS - System at limit${NC}"
        echo "Maximum Event EPS: $(($EPS / 2)) (estimate)"
        break
    fi

    echo -e "${GREEN}✅ Test PASSED at $EPS EPS${NC}"
    cooldown 60
done

# ============================================================================
# Scenario 3: Combined Load
# ============================================================================
echo ""
echo "=========================================="
echo "Scenario 3: Combined Load Testing"
echo "=========================================="
echo ""

mkdir -p test/results/scenario3

# Test matrix: API RPS × Event EPS
# Start with conservative combinations
API_LEVELS=(50 100 200 500 1000)
EVENT_LEVELS=(100 500 1000 2000 5000)

for RPS in "${API_LEVELS[@]}"; do
    for EPS in "${EVENT_LEVELS[@]}"; do
        echo ""
        echo -e "${YELLOW}Testing combined load: $RPS RPS + $EPS EPS...${NC}"

        reset_database
        sleep 5

        # Start profiling in background
        echo "Starting CPU profiling (30s)..."
        go tool pprof -text http://localhost:8080/debug/pprof/profile?seconds=30 > test/results/scenario3/cpu_${RPS}rps_${EPS}eps.txt 2>&1 &
        PPROF_PID=$!

        TARGET_RPS=$RPS TARGET_EPS=$EPS k6 run \
            --web-dashboard \
            --out json=test/results/scenario3/level_${RPS}rps_${EPS}eps.json \
            test/k6/scenario3_combined.js

        K6_EXIT_CODE=$?

        # Wait for profiling to complete
        wait $PPROF_PID

        # Collect memory profile
        echo "Collecting memory profile..."
        go tool pprof -text http://localhost:8080/debug/pprof/heap > test/results/scenario3/heap_${RPS}rps_${EPS}eps.txt 2>&1

        if [ $K6_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}❌ Test FAILED at $RPS RPS + $EPS EPS - System at limit${NC}"
            echo "Maximum combined load reached"
            break 2
        fi

        echo -e "${GREEN}✅ Test PASSED at $RPS RPS + $EPS EPS${NC}"
        cooldown 60
    done
done

# ============================================================================
# Scenario 4: Database Deep Dive
# ============================================================================
echo ""
echo "=========================================="
echo "Scenario 4: Database Performance Analysis"
echo "=========================================="
echo ""

mkdir -p test/results/scenario4

RPS=500
EPS=2000

echo -e "${YELLOW}Testing with database monitoring: $RPS RPS + $EPS EPS...${NC}"

reset_database
sleep 5

# Start database monitoring
echo "Starting database monitoring..."
./test/scripts/monitor_db.sh test/results/scenario4/db_monitor.log &
MONITOR_PID=$!

# Run test
TARGET_RPS=$RPS TARGET_EPS=$EPS k6 run \
    --web-dashboard \
    --out json=test/results/scenario4/results.json \
    test/k6/scenario3_combined.js

# Stop monitoring
kill $MONITOR_PID 2>/dev/null || true

# Analyze queries
echo "Analyzing database performance..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f test/scripts/analyze_db_performance.sql > test/results/scenario4/query_analysis.txt

echo -e "${GREEN}✅ Scenario 4 complete${NC}"

# ============================================================================
# Scenario 5: E2E Latency Validation
# ============================================================================
echo ""
echo "=========================================="
echo "Scenario 5: E2E Latency Validation"
echo "=========================================="
echo ""

mkdir -p test/results/scenario5

# Short 5-minute test
echo -e "${YELLOW}Running 5-minute E2E latency test...${NC}"

reset_database
sleep 5

TARGET_EPS=1000 k6 run \
    --duration=5m \
    --web-dashboard \
    --out json=test/results/scenario5/results.json \
    test/k6/scenario2_event_load.js

# Check event handler logs for buffer flush timing
echo "Collecting buffer flush timing..."
docker logs challenge-event-handler 2>&1 | grep "buffer flush" > test/results/scenario5/flush_timing.log || true

echo -e "${GREEN}✅ Scenario 5 complete${NC}"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo "Test Execution Complete"
echo "=========================================="
echo ""
echo "Results saved in test/results/"
echo ""
echo "Next steps:"
echo "1. Review k6 result JSON files"
echo "2. Review pprof CPU and memory profiles"
echo "3. Review database performance analysis"
echo "4. Fill in documentation templates:"
echo "   - docs/PERFORMANCE_BASELINE.md"
echo "   - docs/CAPACITY_PLANNING.md"
echo "   - docs/PERFORMANCE_TUNING.md"
echo ""
echo -e "${GREEN}All scenarios complete!${NC}"
