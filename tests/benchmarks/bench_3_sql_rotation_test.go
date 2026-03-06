package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/lib/pq"
)

// BenchmarkSQLRotation is the key benchmark. It pushes ALL rotation detection
// into SQL CASE expressions, preserving the blind-write architecture.
//
// The temp table carries extra metadata columns that the event processor
// already knows from the in-memory config cache:
//   - progress_mode: "relative" or "absolute"
//   - inc_value: increment from this event
//   - target_value: completion target
//   - rotation_boundary: midnight UTC (or weekly boundary)
//   - new_expires_at: next expiry timestamp
//
// The UPDATE's SET clause uses CASE WHEN to:
//   - Detect rotation:   WHEN ugp.updated_at < temp.rotation_boundary
//   - Reset baseline:    THEN temp.progress - temp.inc_value
//   - Preserve claimed: WHEN ugp.status = 'claimed'; completed resets when stale
//   - Compute relative:  (progress - baseline) >= target_value
func BenchmarkSQLRotation(b *testing.B) {
	// Sub-benchmarks with different rotation percentages
	b.Run("Size1000/AllRotated", func(b *testing.B) {
		// Use only stale daily-relative goals (all will trigger rotation)
		batch := generateRotationBatch(1000, true)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if err := sqlRotationBatch(context.Background(), testDB, batch); err != nil {
				b.Fatalf("sql rotation: %v", err)
			}
		}
	})

	b.Run("Size1000/NoneRotated", func(b *testing.B) {
		// Use only fresh goals (none will trigger rotation)
		batch := generateRotationBatch(1000, false)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if err := sqlRotationBatch(context.Background(), testDB, batch); err != nil {
				b.Fatalf("sql rotation: %v", err)
			}
		}
	})

	b.Run("Size1000/Mixed40pct", func(b *testing.B) {
		// Realistic mix: 40% stale daily-relative + 60% fresh
		batch := generateEventBatchNRows(1000)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if err := sqlRotationBatch(context.Background(), testDB, batch); err != nil {
				b.Fatalf("sql rotation: %v", err)
			}
		}
	})

	// Compare against baseline at same sizes
	for _, size := range []int{100, 500, 1000} {
		b.Run(fmt.Sprintf("Size%d", size), func(b *testing.B) {
			batch := generateEventBatchNRows(size)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := sqlRotationBatch(context.Background(), testDB, batch); err != nil {
					b.Fatalf("sql rotation: %v", err)
				}
			}
		})
	}
}

// generateRotationBatch creates events targeting only stale or fresh goals.
func generateRotationBatch(size int, staleOnly bool) []eventRow {
	batch := make([]eventRow, 0, size)
	for i := 0; i < size; i++ {
		userIdx := i % seedUsers
		userID := fmt.Sprintf("user-%05d", userIdx)

		var goalID string
		if staleOnly {
			goalID = fmt.Sprintf("goal-daily-rel-%d", i%4) // all stale
		} else {
			goalID = fmt.Sprintf("goal-abs-%d", i%2) // all fresh
		}

		mode := "relative"
		if !staleOnly {
			mode = "absolute"
		}

		batch = append(batch, eventRow{
			UserID:           userID,
			GoalID:           goalID,
			ChallengeID:      challengeID,
			Namespace:        namespace,
			Progress:         108,
			IncValue:         3,
			TargetValue:      10,
			ProgressMode:     mode,
			ResetProgress:    true,
			AllowReselection: false,
		})
	}
	return batch
}

// sqlRotationBatch executes the enhanced COPY+UPDATE with SQL-side rotation logic.
func sqlRotationBatch(ctx context.Context, db *sql.DB, batch []eventRow) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	// Step 1: Create enhanced temp table with M5 metadata columns
	_, err = tx.ExecContext(ctx, `
		CREATE TEMP TABLE IF NOT EXISTS temp_bench_rotation (
			user_id            VARCHAR(100) NOT NULL,
			goal_id            VARCHAR(100) NOT NULL,
			challenge_id       VARCHAR(100) NOT NULL,
			namespace          VARCHAR(100) NOT NULL,
			progress           INT          NOT NULL,
			progress_mode      VARCHAR(20)  NOT NULL,
			inc_value          INT          NOT NULL DEFAULT 0,
			target_value       INT          NOT NULL DEFAULT 0,
			rotation_boundary  TIMESTAMP    NULL,
			new_expires_at     TIMESTAMP    NULL,
			allow_reselection  BOOLEAN      NOT NULL DEFAULT false,
			reset_progress     BOOLEAN      NOT NULL DEFAULT true,
			updated_at         TIMESTAMP    NOT NULL DEFAULT NOW()
		) ON COMMIT DROP
	`)
	if err != nil {
		return fmt.Errorf("create temp: %w", err)
	}

	// Step 2: COPY events into temp table
	stmt, err := tx.PrepareContext(ctx, pq.CopyIn(
		"temp_bench_rotation",
		"user_id", "goal_id", "challenge_id", "namespace",
		"progress", "progress_mode", "inc_value", "target_value",
		"rotation_boundary", "new_expires_at",
		"allow_reselection", "reset_progress", "updated_at",
	))
	if err != nil {
		return fmt.Errorf("prepare COPY: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	now := time.Now().UTC()
	rotationBoundary := todayMidnightUTC()
	newExpiresAt := rotationBoundary.Add(24 * time.Hour) // next midnight

	for _, row := range batch {
		var rb, nea any
		if row.ProgressMode == "relative" {
			rb = rotationBoundary
			nea = newExpiresAt
		}

		_, err = stmt.ExecContext(ctx,
			row.UserID, row.GoalID, row.ChallengeID, row.Namespace,
			row.Progress, row.ProgressMode, row.IncValue, row.TargetValue,
			rb, nea, row.AllowReselection, row.ResetProgress, now,
		)
		if err != nil {
			return fmt.Errorf("COPY row: %w", err)
		}
	}

	_, err = stmt.ExecContext(ctx) // flush
	if err != nil {
		return fmt.Errorf("flush COPY: %w", err)
	}

	// Step 3: SQL-side rotation UPDATE with CASE expressions
	//
	// Key logic:
	//   - For relative goals where updated_at < rotation_boundary:
	//     * Reset baseline to (new_progress - inc_value) when reset_progress=true
	//     * Keep existing baseline when reset_progress=false
	//     * Set progress to new_progress from event
	//     * Update expires_at to next rotation
	//   - For absolute goals or non-rotated relative goals:
	//     * Simple progress update (same as production)
	//   - Claimed goals: reset when allow_reselection=true + stale, else excluded
	//   - Completed goals: reset when stale + reset_progress=true, keep when reset_progress=false
	_, err = tx.ExecContext(ctx, `
		UPDATE bench_user_goal_progress AS ugp
		SET
			-- Progress: always set from event (absolute stat value)
			progress = temp.progress,

			-- Baseline: rotation detection via SQL CASE
			baseline_value = CASE
				-- Absolute mode: baseline stays NULL
				WHEN temp.progress_mode = 'absolute'
					THEN ugp.baseline_value

				-- Claimed + reselectable + stale: reset baseline for new period
				WHEN temp.progress_mode = 'relative'
				     AND ugp.status = 'claimed'
				     AND temp.allow_reselection = true
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
					THEN temp.progress - temp.inc_value

				-- Relative + rotated + reset_progress=true: reset baseline
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND ugp.status != 'claimed'
				     AND temp.reset_progress = true
					THEN temp.progress - temp.inc_value

				-- Relative + rotated + reset_progress=false: keep existing baseline
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND ugp.status != 'claimed'
				     AND temp.reset_progress = false
					THEN ugp.baseline_value

				-- Relative + first event (no baseline yet): initialize
				WHEN temp.progress_mode = 'relative'
				     AND ugp.baseline_value IS NULL
					THEN temp.progress - temp.inc_value

				-- Relative + not rotated: keep existing baseline
				ELSE ugp.baseline_value
			END,

			-- Status: compute based on new progress vs baseline
			status = CASE
				-- Claimed + allow_reselection + stale: reset for new period
				WHEN ugp.status = 'claimed'
				     AND temp.allow_reselection = true
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
					THEN 'not_started'

				-- Claimed + not reselectable (or not stale): preserve
				WHEN ugp.status = 'claimed'
					THEN 'claimed'

				-- Completed + NOT stale: preserve
				WHEN ugp.status = 'completed'
				     AND NOT (temp.progress_mode = 'relative'
				              AND temp.rotation_boundary IS NOT NULL
				              AND ugp.updated_at < temp.rotation_boundary)
					THEN 'completed'

				-- Completed + stale + reset_progress=false: preserve completed
				WHEN ugp.status = 'completed'
				     AND temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = false
					THEN 'completed'

				-- Absolute mode: simple threshold
				WHEN temp.progress_mode = 'absolute'
				     AND temp.progress >= temp.target_value
					THEN 'completed'

				-- Relative + rotated + reset_progress=true: check inc_value against target
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = true
				     AND temp.inc_value >= temp.target_value
					THEN 'completed'

				-- Relative + rotated + reset_progress=false: check against existing baseline
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = false
				     AND ugp.baseline_value IS NOT NULL
				     AND (temp.progress - ugp.baseline_value) >= temp.target_value
					THEN 'completed'

				-- Relative + not rotated: check against existing baseline
				WHEN temp.progress_mode = 'relative'
				     AND NOT (temp.rotation_boundary IS NOT NULL AND ugp.updated_at < temp.rotation_boundary)
				     AND ugp.baseline_value IS NOT NULL
				     AND (temp.progress - ugp.baseline_value) >= temp.target_value
					THEN 'completed'

				-- Default: in_progress
				ELSE 'in_progress'
			END,

			-- Completed timestamp
			completed_at = CASE
				-- Claimed + reselectable + stale: clear for new period
				WHEN ugp.status = 'claimed'
				     AND temp.allow_reselection = true
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
					THEN NULL
				WHEN ugp.status = 'claimed' THEN ugp.completed_at
				-- Completed + stale + reset_progress=false: preserve
				WHEN ugp.status = 'completed'
				     AND temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = false
					THEN ugp.completed_at
				WHEN ugp.status = 'completed'
				     AND NOT (temp.progress_mode = 'relative'
				              AND temp.rotation_boundary IS NOT NULL
				              AND ugp.updated_at < temp.rotation_boundary)
					THEN ugp.completed_at
				-- Newly completed (any mode)
				WHEN temp.progress_mode = 'absolute'
				     AND temp.progress >= temp.target_value
				     AND ugp.completed_at IS NULL
					THEN NOW()
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = true
				     AND temp.inc_value >= temp.target_value
					THEN NOW()
				WHEN temp.progress_mode = 'relative'
				     AND NOT (temp.rotation_boundary IS NOT NULL AND ugp.updated_at < temp.rotation_boundary)
				     AND ugp.baseline_value IS NOT NULL
				     AND (temp.progress - ugp.baseline_value) >= temp.target_value
				     AND ugp.completed_at IS NULL
					THEN NOW()
				-- Rotated + reset_progress=true but not completed: clear old completed_at
				WHEN temp.progress_mode = 'relative'
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
				     AND temp.reset_progress = true
					THEN NULL
				ELSE ugp.completed_at
			END,

			-- Claimed_at: clear for reselectable goals on rotation
			claimed_at = CASE
				WHEN ugp.status = 'claimed'
				     AND temp.allow_reselection = true
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
					THEN NULL
				ELSE ugp.claimed_at
			END,

			-- Expires: update on rotation
			expires_at = CASE
				WHEN temp.new_expires_at IS NOT NULL
				     AND temp.rotation_boundary IS NOT NULL
				     AND ugp.updated_at < temp.rotation_boundary
					THEN temp.new_expires_at
				WHEN temp.new_expires_at IS NOT NULL AND ugp.expires_at IS NULL
					THEN temp.new_expires_at
				ELSE ugp.expires_at
			END,

			updated_at = NOW()

		FROM temp_bench_rotation AS temp
		WHERE ugp.user_id    = temp.user_id
		  AND ugp.goal_id    = temp.goal_id
		  AND ugp.is_active  = true
		  AND NOT (ugp.status = 'claimed' AND temp.allow_reselection = false)
	`)
	if err != nil {
		return fmt.Errorf("UPDATE with rotation: %w", err)
	}

	err = tx.Commit()
	if err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	return nil
}
