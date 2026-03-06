package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/lib/pq"
)

// BenchmarkBatchRead tests the "1 batch read + 1 batch write per flush" approach.
//
// Pattern:
//  1. Single SELECT ... INNER JOIN UNNEST() to read all affected rows at once
//  2. App-side rotation logic over batch results
//  3. Batch UPSERT with rotation-adjusted values
//
// This avoids N individual reads (Bench 2) while keeping rotation logic in Go (not SQL).
func BenchmarkBatchRead(b *testing.B) {
	sizes := []int{100, 500, 1000}

	for _, size := range sizes {
		b.Run(fmt.Sprintf("Size%d", size), func(b *testing.B) {
			batch := generateEventBatchNRows(size)

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := batchReadWriteBatch(context.Background(), testDB, batch); err != nil {
					b.Fatalf("batch read: %v", err)
				}
			}
		})
	}
}

// batchReadWriteBatch does one batch SELECT, applies rotation in Go, then batch writes.
func batchReadWriteBatch(ctx context.Context, db *sql.DB, batch []eventRow) error {
	rotationBoundary := todayMidnightUTC()

	// Phase 1: Collect unique (user_id, goal_id) pairs
	userIDs := make([]string, len(batch))
	goalIDs := make([]string, len(batch))
	for i, ev := range batch {
		userIDs[i] = ev.UserID
		goalIDs[i] = ev.GoalID
	}

	// Phase 2: Single batch SELECT using UNNEST join
	rows, err := db.QueryContext(ctx, `
		SELECT ugp.user_id, ugp.goal_id, ugp.progress, ugp.status,
		       ugp.baseline_value, ugp.updated_at
		FROM bench_user_goal_progress ugp
		INNER JOIN UNNEST($1::VARCHAR[], $2::VARCHAR[])
			AS t(uid, gid) ON ugp.user_id = t.uid AND ugp.goal_id = t.gid
	`, pq.Array(userIDs), pq.Array(goalIDs))
	if err != nil {
		return fmt.Errorf("batch SELECT: %w", err)
	}
	defer rows.Close()

	// Build lookup map
	type rowState struct {
		Progress      int
		Status        string
		BaselineValue sql.NullInt64
		UpdatedAt     time.Time
	}
	stateMap := make(map[string]*rowState, len(batch))

	for rows.Next() {
		var s rowState
		var userID, goalID string
		if err := rows.Scan(&userID, &goalID, &s.Progress, &s.Status,
			&s.BaselineValue, &s.UpdatedAt); err != nil {
			return fmt.Errorf("scan row: %w", err)
		}
		stateMap[userID+":"+goalID] = &s
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("rows iteration: %w", err)
	}

	// Phase 3: App-side rotation logic
	adjusted := make([]eventRow, 0, len(batch))
	for _, ev := range batch {
		key := ev.UserID + ":" + ev.GoalID
		state, exists := stateMap[key]

		if !exists {
			adjusted = append(adjusted, ev)
			continue
		}

		// Skip claimed
		if state.Status == "claimed" {
			continue
		}

		// Rotation detection in Go
		if ev.ProgressMode == "relative" && state.UpdatedAt.Before(rotationBoundary) {
			// Reset baseline
			_ = ev.Progress - ev.IncValue // new baseline (would be stored)
		}

		adjusted = append(adjusted, ev)
	}

	// Phase 4: Batch UPSERT (same as Benchmark 1)
	return blindUpsertBatch(ctx, db, adjusted)
}
