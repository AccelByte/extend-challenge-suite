-- =============================================================================
-- Seed Expired Rows for M6 Cleanup Load Testing
-- =============================================================================
-- Creates 100,000 expired rows (10,000 users x 10 goals) that are immediately
-- eligible for cleanup (expired 8+ days ago, past the 7-day retention window).
--
-- Usage:
--   docker exec -i challenge-postgres psql -U postgres -d challenge_db \
--     < tests/loadtest/sql/seed_expired_rows.sql
--
-- Idempotent: safe to run multiple times.
-- =============================================================================

\echo '=== M6 Cleanup Seed: Starting ==='

-- Clean up any previous seed data (idempotent)
\echo 'Removing previous seed data...'
DELETE FROM user_goal_progress WHERE user_id LIKE 'cleanup-test-user-%';

-- Insert 100,000 expired rows: 10,000 users x 10 goals
-- Status distribution: 50% not_started, 30% in_progress, 10% completed, 10% claimed
\echo 'Inserting 100,000 expired rows (10,000 users x 10 goals)...'

INSERT INTO user_goal_progress (
    user_id,
    goal_id,
    challenge_id,
    namespace,
    progress,
    status,
    completed_at,
    claimed_at,
    is_active,
    assigned_at,
    expires_at,
    baseline_value,
    created_at,
    updated_at
)
SELECT
    'cleanup-test-user-' || LPAD(u.n::TEXT, 6, '0') AS user_id,
    'daily-goal-' || LPAD(g.n::TEXT, 2, '0') AS goal_id,
    'daily-challenges' AS challenge_id,
    'test' AS namespace,
    -- Progress varies by status
    CASE
        WHEN (u.n * 10 + g.n) % 10 < 5 THEN 0                          -- not_started: 0
        WHEN (u.n * 10 + g.n) % 10 < 8 THEN (u.n % 50) + 1             -- in_progress: 1-50
        ELSE 100                                                         -- completed/claimed: 100
    END AS progress,
    -- Status: 50% not_started, 30% in_progress, 10% completed, 10% claimed
    CASE
        WHEN (u.n * 10 + g.n) % 10 < 5 THEN 'not_started'
        WHEN (u.n * 10 + g.n) % 10 < 8 THEN 'in_progress'
        WHEN (u.n * 10 + g.n) % 10 < 9 THEN 'completed'
        ELSE 'claimed'
    END AS status,
    -- completed_at for completed/claimed rows
    CASE
        WHEN (u.n * 10 + g.n) % 10 >= 8 THEN NOW() - INTERVAL '9 days'
        ELSE NULL
    END AS completed_at,
    -- claimed_at for claimed rows only
    CASE
        WHEN (u.n * 10 + g.n) % 10 = 9 THEN NOW() - INTERVAL '8 days'
        ELSE NULL
    END AS claimed_at,
    false AS is_active,                                                   -- All inactive (expired)
    NOW() - INTERVAL '15 days' AS assigned_at,                           -- Assigned 15 days ago
    NOW() - INTERVAL '8 days' AS expires_at,                             -- Expired 8 days ago (past 7-day retention)
    0 AS baseline_value,
    NOW() - INTERVAL '15 days' AS created_at,
    NOW() - INTERVAL '8 days' AS updated_at
FROM
    generate_series(1, 10000) AS u(n),
    generate_series(1, 10) AS g(n)
ON CONFLICT (user_id, goal_id) DO NOTHING;

-- =============================================================================
-- Verification
-- =============================================================================

\echo ''
\echo '=== Verification ==='

\echo 'Total seed rows:'
SELECT COUNT(*) AS total_rows
FROM user_goal_progress
WHERE user_id LIKE 'cleanup-test-user-%';

\echo 'Status distribution:'
SELECT status, COUNT(*) AS count,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM user_goal_progress
WHERE user_id LIKE 'cleanup-test-user-%'
GROUP BY status
ORDER BY count DESC;

\echo 'Rows eligible for cleanup (expires_at < NOW() - 7 days, not claimed):'
SELECT COUNT(*) AS eligible_rows
FROM user_goal_progress
WHERE user_id LIKE 'cleanup-test-user-%'
  AND expires_at < NOW() - INTERVAL '7 days'
  AND status != 'claimed';

\echo 'Table size:'
SELECT pg_size_pretty(pg_total_relation_size('user_goal_progress')) AS total_size,
       pg_size_pretty(pg_relation_size('user_goal_progress')) AS table_size,
       pg_size_pretty(pg_indexes_size('user_goal_progress')) AS index_size;

\echo ''
\echo '=== M6 Cleanup Seed: Complete ==='
\echo 'Run cleanup with CLEANUP_INTERVAL_MINUTES=1 to process these rows.'
