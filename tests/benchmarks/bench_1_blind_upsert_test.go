package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/lib/pq"
)

// BenchmarkBlindUpsert replicates the exact production COPY-based batch UPSERT
// from postgres_goal_repository.go:237-333. This is the baseline: zero reads,
// pure blind writes.
//
// Pattern:
//  1. BEGIN
//  2. CREATE TEMP TABLE ON COMMIT DROP
//  3. COPY FROM STDIN (pq.CopyIn)
//  4. UPDATE ... FROM temp WHERE is_active AND status != 'claimed'
//  5. COMMIT
func BenchmarkBlindUpsert(b *testing.B) {
	sizes := []int{100, 500, 1000}

	for _, size := range sizes {
		b.Run(fmt.Sprintf("Size%d", size), func(b *testing.B) {
			batch := generateEventBatchNRows(size)

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := blindUpsertBatch(context.Background(), testDB, batch); err != nil {
					b.Fatalf("blind upsert: %v", err)
				}
			}
		})
	}
}

// blindUpsertBatch executes the production-identical COPY+UPDATE pattern.
func blindUpsertBatch(ctx context.Context, db *sql.DB, batch []eventRow) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	// Step 1: Create temp table
	_, err = tx.ExecContext(ctx, `
		CREATE TEMP TABLE IF NOT EXISTS temp_bench_upsert (
			user_id      VARCHAR(100) NOT NULL,
			goal_id      VARCHAR(100) NOT NULL,
			challenge_id VARCHAR(100) NOT NULL,
			namespace    VARCHAR(100) NOT NULL,
			progress     INT          NOT NULL,
			status       VARCHAR(20)  NOT NULL,
			completed_at TIMESTAMP    NULL,
			updated_at   TIMESTAMP    NOT NULL DEFAULT NOW()
		) ON COMMIT DROP
	`)
	if err != nil {
		return fmt.Errorf("create temp: %w", err)
	}

	// Step 2: COPY into temp table
	stmt, err := tx.PrepareContext(ctx, pq.CopyIn(
		"temp_bench_upsert",
		"user_id", "goal_id", "challenge_id", "namespace",
		"progress", "status", "completed_at", "updated_at",
	))
	if err != nil {
		return fmt.Errorf("prepare COPY: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	now := time.Now().UTC()
	for _, row := range batch {
		status := "in_progress"
		if row.Progress >= row.TargetValue {
			status = "completed"
		}

		_, err = stmt.ExecContext(ctx,
			row.UserID, row.GoalID, row.ChallengeID, row.Namespace,
			row.Progress, status, nil, now,
		)
		if err != nil {
			return fmt.Errorf("COPY row: %w", err)
		}
	}

	_, err = stmt.ExecContext(ctx) // flush COPY
	if err != nil {
		return fmt.Errorf("flush COPY: %w", err)
	}

	// Step 3: UPDATE from temp (production-identical query)
	_, err = tx.ExecContext(ctx, `
		UPDATE bench_user_goal_progress
		SET
			progress     = temp.progress,
			status       = temp.status,
			completed_at = temp.completed_at,
			updated_at   = NOW()
		FROM temp_bench_upsert AS temp
		WHERE bench_user_goal_progress.user_id  = temp.user_id
		  AND bench_user_goal_progress.goal_id  = temp.goal_id
		  AND bench_user_goal_progress.is_active = true
		  AND bench_user_goal_progress.status   != 'claimed'
	`)
	if err != nil {
		return fmt.Errorf("UPDATE from temp: %w", err)
	}

	err = tx.Commit()
	if err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	return nil
}
