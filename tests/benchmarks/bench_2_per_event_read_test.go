package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"
)

// BenchmarkPerEventRead simulates the naive M5 approach: read each row individually
// before writing. This is the worst-case upper bound.
//
// Pattern per flush:
//  1. For each event: SELECT ... WHERE user_id=$1 AND goal_id=$2 (N reads)
//  2. App-side rotation check + baseline adjustment
//  3. Same batch UPSERT as Benchmark 1
func BenchmarkPerEventRead(b *testing.B) {
	sizes := []int{100, 500, 1000}

	for _, size := range sizes {
		b.Run(fmt.Sprintf("Size%d", size), func(b *testing.B) {
			batch := generateEventBatchNRows(size)

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := perEventReadBatch(context.Background(), testDB, batch); err != nil {
					b.Fatalf("per-event read: %v", err)
				}
			}
		})
	}
}

// existingRow holds the data read from the database for rotation checks.
type existingRow struct {
	UserID        string
	GoalID        string
	Progress      int
	Status        string
	BaselineValue sql.NullInt64
	UpdatedAt     time.Time
}

// perEventReadBatch reads each row individually, applies rotation logic, then batch writes.
func perEventReadBatch(ctx context.Context, db *sql.DB, batch []eventRow) error {
	rotationBoundary := todayMidnightUTC()

	// Phase 1: Individual reads for each event (the expensive part)
	adjusted := make([]eventRow, 0, len(batch))
	for _, ev := range batch {
		var row existingRow
		err := db.QueryRowContext(ctx, `
			SELECT user_id, goal_id, progress, status,
			       baseline_value, updated_at
			FROM bench_user_goal_progress
			WHERE user_id = $1 AND goal_id = $2
		`, ev.UserID, ev.GoalID).Scan(
			&row.UserID, &row.GoalID, &row.Progress, &row.Status,
			&row.BaselineValue, &row.UpdatedAt,
		)

		if err == sql.ErrNoRows {
			// New row, use event as-is
			adjusted = append(adjusted, ev)
			continue
		}
		if err != nil {
			return fmt.Errorf("read row %s/%s: %w", ev.UserID, ev.GoalID, err)
		}

		// Skip claimed goals
		if row.Status == "claimed" {
			continue
		}

		// App-side rotation detection
		if ev.ProgressMode == "relative" && row.UpdatedAt.Before(rotationBoundary) {
			// Rotation needed: reset baseline to (current stat - increment)
			newBaseline := ev.Progress - ev.IncValue
			ev.Progress = newBaseline + ev.IncValue // = ev.Progress (same, but conceptually reset)
			// In real impl, we'd also update baseline_value in the write
		}

		adjusted = append(adjusted, ev)
	}

	// Phase 2: Batch UPSERT (same as Benchmark 1)
	return blindUpsertBatch(ctx, db, adjusted)
}
