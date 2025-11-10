#!/bin/bash

# Monitor PostgreSQL performance during load test
# Usage: ./monitor_db.sh <output_file>

OUTPUT_FILE=${1:-"db_performance.log"}
INTERVAL=5  # seconds

# Database connection settings
DB_HOST=${DB_HOST:-"localhost"}
DB_PORT=${DB_PORT:-"5433"}
DB_NAME=${DB_NAME:-"challenge_db"}
DB_USER=${DB_USER:-"postgres"}
export PGPASSWORD=${DB_PASSWORD:-"postgres"}

echo "Monitoring PostgreSQL performance..."
echo "Output: $OUTPUT_FILE"
echo "Interval: ${INTERVAL}s"
echo "Database: $DB_NAME at $DB_HOST:$DB_PORT"
echo ""

# Header
echo "timestamp,active_connections,idle_connections,total_queries,slow_queries,avg_query_time_ms" > "$OUTPUT_FILE"

while true; do
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  # Query PostgreSQL stats
  STATS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "
    SELECT
      COUNT(*) FILTER (WHERE state = 'active') as active_conn,
      COUNT(*) FILTER (WHERE state = 'idle') as idle_conn,
      COALESCE((SELECT SUM(calls) FROM pg_stat_statements WHERE query LIKE '%user_goal_progress%'), 0) as total_queries,
      COALESCE((SELECT COUNT(*) FROM pg_stat_statements WHERE mean_exec_time > 100 AND query LIKE '%user_goal_progress%'), 0) as slow_queries,
      COALESCE((SELECT AVG(mean_exec_time) FROM pg_stat_statements WHERE query LIKE '%user_goal_progress%'), 0) as avg_time
    FROM pg_stat_activity;
  " 2>/dev/null | tr -d ' ' | tr '|' ',')

  if [ $? -eq 0 ] && [ -n "$STATS" ]; then
    echo "${TIMESTAMP},${STATS}" >> "$OUTPUT_FILE"
    echo "[$TIMESTAMP] $STATS"
  else
    echo "[$TIMESTAMP] Error querying database" >&2
  fi

  sleep $INTERVAL
done
