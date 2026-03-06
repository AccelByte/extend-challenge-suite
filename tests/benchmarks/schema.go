package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
)

// createSchema creates the bench_user_goal_progress table with M5 columns.
// Uses bench_ prefix to avoid conflicts with production schema.
func createSchema(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS bench_user_goal_progress (
			user_id       VARCHAR(100)  NOT NULL,
			goal_id       VARCHAR(100)  NOT NULL,
			challenge_id  VARCHAR(100)  NOT NULL,
			namespace     VARCHAR(100)  NOT NULL,
			progress      INT           NOT NULL DEFAULT 0,
			status        VARCHAR(20)   NOT NULL DEFAULT 'not_started',
			completed_at  TIMESTAMP     NULL,
			claimed_at    TIMESTAMP     NULL,
			created_at    TIMESTAMP     NOT NULL DEFAULT NOW(),
			updated_at    TIMESTAMP     NOT NULL DEFAULT NOW(),

			-- M3: User assignment control
			is_active     BOOLEAN       NOT NULL DEFAULT true,
			assigned_at   TIMESTAMP     NULL,

			-- M5: System rotation control
			expires_at    TIMESTAMP     NULL,

			-- M5: Baseline for relative progress mode
			baseline_value INT          NULL,

			PRIMARY KEY (user_id, goal_id),

			CONSTRAINT bench_check_status
				CHECK (status IN ('not_started', 'in_progress', 'completed', 'claimed')),
			CONSTRAINT bench_check_progress_non_negative
				CHECK (progress >= 0)
		)
	`)
	if err != nil {
		return fmt.Errorf("create bench table: %w", err)
	}

	// Same indexes as production
	_, err = db.ExecContext(ctx, `
		CREATE INDEX IF NOT EXISTS idx_bench_ugp_user_challenge
		ON bench_user_goal_progress(user_id, challenge_id)
	`)
	if err != nil {
		return fmt.Errorf("create user_challenge index: %w", err)
	}

	_, err = db.ExecContext(ctx, `
		CREATE INDEX IF NOT EXISTS idx_bench_ugp_user_active
		ON bench_user_goal_progress(user_id, is_active)
		WHERE is_active = true
	`)
	if err != nil {
		return fmt.Errorf("create user_active index: %w", err)
	}

	return nil
}

// dropSchema drops the bench table and all associated indexes.
func dropSchema(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, `DROP TABLE IF EXISTS bench_user_goal_progress CASCADE`)
	return err
}
