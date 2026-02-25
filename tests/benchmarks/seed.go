package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/lib/pq"
)

const (
	seedUsers    = 10_000
	goalsPerUser = 10
	challengeID  = "challenge-daily-001"
	namespace    = "bench-ns"
)

// goalMeta describes the seeding parameters for each goal.
type goalMeta struct {
	goalID        string
	isRelative    bool   // relative vs absolute progress mode
	status        string // not_started, in_progress, completed, claimed
	isStale       bool   // updated_at set to yesterday (needs rotation)
	baselineValue *int   // NULL for absolute, set for relative
}

func goalMetadata() []goalMeta {
	baseline := 100
	return []goalMeta{
		// 4 daily-relative goals: stale (yesterday 11PM), in_progress, baseline=100
		{goalID: "goal-daily-rel-0", isRelative: true, status: "in_progress", isStale: true, baselineValue: &baseline},
		{goalID: "goal-daily-rel-1", isRelative: true, status: "in_progress", isStale: true, baselineValue: &baseline},
		{goalID: "goal-daily-rel-2", isRelative: true, status: "in_progress", isStale: true, baselineValue: &baseline},
		{goalID: "goal-daily-rel-3", isRelative: true, status: "in_progress", isStale: true, baselineValue: &baseline},
		// 2 weekly-relative goals: fresh (1 hour ago), in_progress, baseline=50
		{goalID: "goal-weekly-rel-0", isRelative: true, status: "in_progress", isStale: false, baselineValue: &baseline},
		{goalID: "goal-weekly-rel-1", isRelative: true, status: "in_progress", isStale: false, baselineValue: &baseline},
		// 2 absolute goals: fresh, in_progress, baseline=NULL
		{goalID: "goal-abs-0", isRelative: false, status: "in_progress", isStale: false, baselineValue: nil},
		{goalID: "goal-abs-1", isRelative: false, status: "in_progress", isStale: false, baselineValue: nil},
		// 1 completed relative goal: stale but status preserved
		{goalID: "goal-completed-0", isRelative: true, status: "completed", isStale: true, baselineValue: &baseline},
		// 1 claimed relative goal: old, skip on rotation
		{goalID: "goal-claimed-0", isRelative: true, status: "claimed", isStale: true, baselineValue: &baseline},
	}
}

// seedData inserts 100K rows (10K users x 10 goals) using COPY protocol.
func seedData(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin seed tx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	stmt, err := tx.PrepareContext(ctx, pq.CopyIn(
		"bench_user_goal_progress",
		"user_id", "goal_id", "challenge_id", "namespace",
		"progress", "status", "completed_at", "claimed_at",
		"created_at", "updated_at",
		"is_active", "assigned_at", "expires_at", "baseline_value",
	))
	if err != nil {
		return fmt.Errorf("prepare COPY: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	now := time.Now().UTC()
	yesterday11PM := now.Add(-25 * time.Hour).Truncate(time.Hour).Add(23 * time.Hour)
	oneHourAgo := now.Add(-1 * time.Hour)
	lastWeek := now.Add(-7 * 24 * time.Hour)
	meta := goalMetadata()

	for i := 0; i < seedUsers; i++ {
		userID := fmt.Sprintf("user-%05d", i)

		for _, gm := range meta {
			var updatedAt time.Time
			if gm.isStale {
				updatedAt = yesterday11PM
			} else {
				updatedAt = oneHourAgo
			}

			var completedAt, claimedAt *time.Time
			if gm.status == "completed" || gm.status == "claimed" {
				t := yesterday11PM
				completedAt = &t
			}
			if gm.status == "claimed" {
				claimedAt = &lastWeek
			}

			// Progress: stale rows have baseline+5, fresh have baseline+3
			progress := 0
			if gm.baselineValue != nil {
				if gm.isStale {
					progress = *gm.baselineValue + 5
				} else {
					progress = *gm.baselineValue + 3
				}
			} else {
				progress = 5 // absolute goals
			}

			// For completed goals, set progress at target
			if gm.status == "completed" || gm.status == "claimed" {
				progress = 110 // past target of 10 relative
			}

			var baselineSQL any
			if gm.baselineValue != nil {
				baselineSQL = *gm.baselineValue
			} else {
				baselineSQL = nil
			}

			_, err = stmt.ExecContext(ctx,
				userID, gm.goalID, challengeID, namespace,
				progress, gm.status, completedAt, claimedAt,
				now, updatedAt,
				true, &now, nil, baselineSQL,
			)
			if err != nil {
				return fmt.Errorf("COPY row user=%s goal=%s: %w", userID, gm.goalID, err)
			}
		}
	}

	// Flush COPY buffer
	_, err = stmt.ExecContext(ctx)
	if err != nil {
		return fmt.Errorf("flush COPY: %w", err)
	}

	err = tx.Commit()
	if err != nil {
		return fmt.Errorf("commit seed: %w", err)
	}

	return nil
}

// truncateData removes all rows from the bench table.
func truncateData(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, `TRUNCATE TABLE bench_user_goal_progress`)
	return err
}
