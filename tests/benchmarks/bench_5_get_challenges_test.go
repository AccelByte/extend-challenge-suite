package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/lib/pq"
)

// BenchmarkGetChallenges tests the GET /v1/challenges read path impact.
// Operates on a single user's 10 goals (simulates one API request).
//
// Variants:
//   - PureRead:          SELECT only (current M1-M4 behavior)
//   - ReadComputeNoWrite: SELECT + compute rotation in Go (no DB write)
//   - ReadSyncWriteback:  SELECT + compute + batch UPDATE rotated rows
func BenchmarkGetChallenges(b *testing.B) {
	userID := "user-00042" // arbitrary test user

	b.Run("PureRead", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := getChallengesPureRead(context.Background(), testDB, userID); err != nil {
				b.Fatalf("pure read: %v", err)
			}
		}
	})

	b.Run("ReadComputeNoWrite", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := getChallengesReadCompute(context.Background(), testDB, userID); err != nil {
				b.Fatalf("read+compute: %v", err)
			}
		}
	})

	b.Run("ReadSyncWriteback", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := getChallengesReadWriteback(context.Background(), testDB, userID); err != nil {
				b.Fatalf("read+writeback: %v", err)
			}
		}
	})
}

// goalResponse represents one goal in the API response.
type goalResponse struct {
	GoalID          string
	Progress        int
	DisplayProgress int // relative: progress - baseline, absolute: progress
	Status          string
	IsRotated       bool
}

// getChallengesPureRead is the current M1-M4 approach: simple SELECT, return as-is.
func getChallengesPureRead(ctx context.Context, db *sql.DB, userID string) ([]goalResponse, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT goal_id, progress, status, baseline_value, updated_at
		FROM bench_user_goal_progress
		WHERE user_id = $1 AND challenge_id = $2 AND is_active = true
		ORDER BY goal_id
	`, userID, challengeID)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	var results []goalResponse
	for rows.Next() {
		var g goalResponse
		var baseline sql.NullInt64
		var updatedAt time.Time
		if err := rows.Scan(&g.GoalID, &g.Progress, &g.Status, &baseline, &updatedAt); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		g.DisplayProgress = g.Progress
		if baseline.Valid {
			g.DisplayProgress = g.Progress - int(baseline.Int64)
		}
		results = append(results, g)
	}
	return results, rows.Err()
}

// getChallengesReadCompute reads goals, computes rotation state in-memory,
// and returns adjusted results WITHOUT writing to database.
// This answers Q5: can we keep GET read-only?
func getChallengesReadCompute(ctx context.Context, db *sql.DB, userID string) ([]goalResponse, error) {
	rotationBoundary := todayMidnightUTC()

	rows, err := db.QueryContext(ctx, `
		SELECT goal_id, progress, status, baseline_value, updated_at
		FROM bench_user_goal_progress
		WHERE user_id = $1 AND challenge_id = $2 AND is_active = true
		ORDER BY goal_id
	`, userID, challengeID)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	var results []goalResponse
	for rows.Next() {
		var g goalResponse
		var baseline sql.NullInt64
		var updatedAt time.Time
		if err := rows.Scan(&g.GoalID, &g.Progress, &g.Status, &baseline, &updatedAt); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}

		// In-memory rotation computation
		isRelative := baseline.Valid
		if isRelative && updatedAt.Before(rotationBoundary) && g.Status != "claimed" {
			// Stale: reset display state (completed goals also reset — new period)
			g.IsRotated = true
			g.DisplayProgress = 0
			g.Status = "not_started"
		} else if isRelative {
			g.DisplayProgress = g.Progress - int(baseline.Int64)
		} else {
			g.DisplayProgress = g.Progress
		}

		results = append(results, g)
	}
	return results, rows.Err()
}

// getChallengesReadWriteback reads goals, computes rotation, returns results,
// AND writes back rotated rows synchronously.
func getChallengesReadWriteback(ctx context.Context, db *sql.DB, userID string) ([]goalResponse, error) {
	rotationBoundary := todayMidnightUTC()

	rows, err := db.QueryContext(ctx, `
		SELECT goal_id, progress, status, baseline_value, updated_at
		FROM bench_user_goal_progress
		WHERE user_id = $1 AND challenge_id = $2 AND is_active = true
		ORDER BY goal_id
	`, userID, challengeID)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	var results []goalResponse
	var rotatedGoalIDs []string

	for rows.Next() {
		var g goalResponse
		var baseline sql.NullInt64
		var updatedAt time.Time
		if err := rows.Scan(&g.GoalID, &g.Progress, &g.Status, &baseline, &updatedAt); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}

		isRelative := baseline.Valid
		if isRelative && updatedAt.Before(rotationBoundary) && g.Status != "claimed" {
			g.IsRotated = true
			g.DisplayProgress = 0
			g.Status = "not_started"
			rotatedGoalIDs = append(rotatedGoalIDs, g.GoalID)
		} else if isRelative {
			g.DisplayProgress = g.Progress - int(baseline.Int64)
		} else {
			g.DisplayProgress = g.Progress
		}

		results = append(results, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Synchronous writeback of rotated rows
	if len(rotatedGoalIDs) > 0 {
		_, err := db.ExecContext(ctx, `
			UPDATE bench_user_goal_progress
			SET baseline_value = progress,
			    status = 'not_started',
			    completed_at = NULL,
			    updated_at = NOW(),
			    expires_at = $3
			WHERE user_id = $1
			  AND goal_id = ANY($2)
			  AND is_active = true
			  AND status NOT IN ('claimed')
		`, userID, pq.Array(rotatedGoalIDs), todayMidnightUTC().Add(24*time.Hour))
		if err != nil {
			return nil, fmt.Errorf("writeback: %w", err)
		}
	}

	return results, nil
}
