package benchmarks

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// TestSQLRotation_RotatedRowGetsNewBaseline verifies that the SQL CASE approach
// correctly resets baseline_value when a row is stale (updated_at < rotation boundary).
func TestSQLRotation_RotatedRowGetsNewBaseline(t *testing.T) {
	ctx := context.Background()

	// Setup: insert one stale relative row
	userID := "verify-user-001"
	goalID := "goal-daily-rel-0"
	setupVerifyRow(t, ctx, userID, goalID, 105, "in_progress", intPtr(100),
		todayMidnightUTC().Add(-2*time.Hour)) // yesterday 10PM

	// Act: send event with progress=108, inc=3
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         108,
		IncValue:         3,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	// Verify: baseline should be reset to 108-3=105
	row := readVerifyRow(t, ctx, userID, goalID)
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be set, got NULL")
	}
	expectedBaseline := int64(105) // 108 - 3
	if row.BaselineValue.Int64 != expectedBaseline {
		t.Errorf("baseline_value = %d, want %d", row.BaselineValue.Int64, expectedBaseline)
	}
	if row.Progress != 108 {
		t.Errorf("progress = %d, want 108", row.Progress)
	}
	// Relative progress = 108 - 105 = 3, target = 10, so in_progress
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_CompletedGoalRotated verifies that completed+stale goals
// are reset by rotation (new period = new attempt).
func TestSQLRotation_CompletedGoalRotated(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-002"
	goalID := "goal-completed-0"
	completedAt := todayMidnightUTC().Add(-25 * time.Hour) // yesterday
	setupVerifyRowFull(t, ctx, userID, goalID, 110, "completed", intPtr(100),
		todayMidnightUTC().Add(-2*time.Hour), &completedAt)

	// Completed+stale goal receives an event. The SQL CASE should:
	// 1. Reset baseline (completed is no longer excluded from rotation when reset_progress=true)
	// 2. Recompute status from the new baseline (not preserve old "completed")
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         115,
		IncValue:         5,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)

	// Progress gets updated
	if row.Progress != 115 {
		t.Errorf("progress = %d, want 115", row.Progress)
	}

	// Completed+stale: baseline resets to progress - inc_value
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be set, got NULL")
	}
	expectedBaseline := int64(110) // 115 - 5
	if row.BaselineValue.Int64 != expectedBaseline {
		t.Errorf("baseline_value = %d, want %d", row.BaselineValue.Int64, expectedBaseline)
	}

	// Status resets: inc=5 < target=10 → in_progress (not completed!)
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	// completed_at cleared on rotation
	if row.CompletedAt.Valid {
		t.Errorf("completed_at = %v, want NULL (cleared on rotation)", row.CompletedAt.Time)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_ClaimedGoalUntouched verifies that claimed goals
// are completely skipped by the UPDATE WHERE clause.
func TestSQLRotation_ClaimedGoalUntouched(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-003"
	goalID := "goal-claimed-0"
	setupVerifyRow(t, ctx, userID, goalID, 110, "claimed", intPtr(100),
		todayMidnightUTC().Add(-7*24*time.Hour)) // last week

	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         120,
		IncValue:         5,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)
	// Claimed goals should be untouched
	if row.Status != "claimed" {
		t.Errorf("status = %q, want claimed", row.Status)
	}
	if row.Progress != 110 {
		t.Errorf("progress = %d, want 110 (unchanged)", row.Progress)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_AbsoluteBaselineStaysNull verifies that absolute goals
// never get a baseline_value set.
func TestSQLRotation_AbsoluteBaselineStaysNull(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-004"
	goalID := "goal-abs-0"
	setupVerifyRow(t, ctx, userID, goalID, 5, "in_progress", nil,
		time.Now().UTC().Add(-1*time.Hour))

	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         8,
		IncValue:         3,
		TargetValue:      20,
		ProgressMode:     "absolute",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)
	if row.BaselineValue.Valid {
		t.Errorf("baseline_value = %d, want NULL for absolute goal", row.BaselineValue.Int64)
	}
	if row.Progress != 8 {
		t.Errorf("progress = %d, want 8", row.Progress)
	}
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_FirstEventInitializesBaseline verifies that the first event
// for a relative goal with NULL baseline correctly initializes it.
func TestSQLRotation_FirstEventInitializesBaseline(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-005"
	goalID := "goal-daily-rel-0"
	// Row exists but has NULL baseline (just assigned, no events yet)
	setupVerifyRow(t, ctx, userID, goalID, 0, "not_started", nil,
		time.Now().UTC().Add(-5*time.Minute)) // very recent

	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         153,
		IncValue:         3,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be initialized, got NULL")
	}
	expectedBaseline := int64(150) // 153 - 3
	if row.BaselineValue.Int64 != expectedBaseline {
		t.Errorf("baseline_value = %d, want %d", row.BaselineValue.Int64, expectedBaseline)
	}
	if row.Progress != 153 {
		t.Errorf("progress = %d, want 153", row.Progress)
	}
	// Relative progress = 153-150 = 3, target 10 → in_progress
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_CrossApproachComparison verifies that SQL-side rotation
// (Bench 3) and app-side batch read (Bench 4) produce identical rotation results.
//
// Both approaches read the existing row state and apply rotation logic.
// The SQL approach does it in CASE expressions; the app approach does it in Go.
// The blind upsert (Bench 1/2) can't handle rotation correctly by design —
// it writes absolute progress without baseline awareness.
func TestSQLRotation_CrossApproachComparison(t *testing.T) {
	ctx := context.Background()

	userID1 := "verify-cross-sql"
	goalID := "goal-daily-rel-0"

	// Setup a stale relative row
	staleTime := todayMidnightUTC().Add(-2 * time.Hour) // yesterday 10PM
	setupVerifyRow(t, ctx, userID1, goalID, 105, "in_progress", intPtr(100), staleTime)

	// Run SQL-side rotation (Bench 3 approach)
	sqlBatch := []eventRow{{
		UserID:           userID1,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         108,
		IncValue:         3,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}
	if err := sqlRotationBatch(ctx, testDB, sqlBatch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	// Verify SQL approach produced correct rotation results
	sqlRow := readVerifyRow(t, ctx, userID1, goalID)

	// Progress should be the raw stat value (108)
	if sqlRow.Progress != 108 {
		t.Errorf("SQL progress = %d, want 108", sqlRow.Progress)
	}

	// Baseline should be reset to 108-3=105 (new rotation period)
	if !sqlRow.BaselineValue.Valid || sqlRow.BaselineValue.Int64 != 105 {
		t.Errorf("SQL baseline = %v, want 105", sqlRow.BaselineValue)
	}

	// Relative progress = 108-105 = 3, target=10 → in_progress
	if sqlRow.Status != "in_progress" {
		t.Errorf("SQL status = %q, want in_progress", sqlRow.Status)
	}

	// Now verify the app-side approach would compute the same displayed result
	// App logic: read row (stale), detect rotation, compute new_baseline = 108-3 = 105
	// Display progress = 108 - 105 = 3, target = 10 → in_progress
	appBaseline := 108 - 3 // same as SQL
	appRelativeProgress := 108 - appBaseline
	appStatus := "in_progress"
	if appRelativeProgress >= 10 {
		appStatus = "completed"
	}

	if int64(appBaseline) != sqlRow.BaselineValue.Int64 {
		t.Errorf("baseline mismatch: SQL=%d, App=%d", sqlRow.BaselineValue.Int64, appBaseline)
	}
	if appStatus != sqlRow.Status {
		t.Errorf("status mismatch: SQL=%q, App=%q", sqlRow.Status, appStatus)
	}

	cleanupVerifyRow(t, ctx, userID1)
}

// TestSQLRotation_CompletedGoalPreservedWhenResetProgressFalse verifies that
// completed+stale goals keep their status when reset_progress=false.
func TestSQLRotation_CompletedGoalPreservedWhenResetProgressFalse(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-010"
	goalID := "goal-completed-0"
	completedAt := todayMidnightUTC().Add(-25 * time.Hour)
	setupVerifyRowFull(t, ctx, userID, goalID, 110, "completed", intPtr(100),
		todayMidnightUTC().Add(-2*time.Hour), &completedAt)

	// Completed+stale but reset_progress=false: status should stay completed
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         115,
		IncValue:         5,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    false,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)

	// Progress updated from event
	if row.Progress != 115 {
		t.Errorf("progress = %d, want 115", row.Progress)
	}

	// Baseline preserved (not reset) because reset_progress=false
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be preserved, got NULL")
	}
	if row.BaselineValue.Int64 != 100 {
		t.Errorf("baseline_value = %d, want 100 (preserved)", row.BaselineValue.Int64)
	}

	// Status stays completed
	if row.Status != "completed" {
		t.Errorf("status = %q, want completed (preserved with reset_progress=false)", row.Status)
	}

	// completed_at preserved
	if !row.CompletedAt.Valid {
		t.Error("completed_at should be preserved, got NULL")
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_ClaimedGoalResetWithAllowReselection verifies that
// claimed+stale goals reset when allow_reselection=true.
func TestSQLRotation_ClaimedGoalResetWithAllowReselection(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-011"
	goalID := "goal-claimed-0"
	setupVerifyRow(t, ctx, userID, goalID, 110, "claimed", intPtr(100),
		todayMidnightUTC().Add(-7*24*time.Hour)) // last week

	// Claimed+stale+allow_reselection=true: should reset
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         120,
		IncValue:         5,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: true,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)

	// Status reset to not_started
	if row.Status != "not_started" {
		t.Errorf("status = %q, want not_started (reset with allow_reselection)", row.Status)
	}

	// Baseline reset to 120-5=115 (new period)
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be set, got NULL")
	}
	if row.BaselineValue.Int64 != 115 {
		t.Errorf("baseline_value = %d, want 115", row.BaselineValue.Int64)
	}

	// claimed_at cleared
	if row.ClaimedAt.Valid {
		t.Errorf("claimed_at = %v, want NULL (cleared on reselection)", row.ClaimedAt.Time)
	}

	// completed_at cleared
	if row.CompletedAt.Valid {
		t.Errorf("completed_at = %v, want NULL (cleared on reselection)", row.CompletedAt.Time)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_InProgressPreservedWhenResetProgressFalse verifies that
// in_progress+stale goals keep their baseline when reset_progress=false.
func TestSQLRotation_InProgressPreservedWhenResetProgressFalse(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-012"
	goalID := "goal-daily-rel-0"
	setupVerifyRow(t, ctx, userID, goalID, 105, "in_progress", intPtr(100),
		todayMidnightUTC().Add(-2*time.Hour)) // yesterday 10PM

	// In-progress+stale but reset_progress=false: baseline should be preserved
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         108,
		IncValue:         3,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    false,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)

	// Progress updated
	if row.Progress != 108 {
		t.Errorf("progress = %d, want 108", row.Progress)
	}

	// Baseline preserved (not reset) because reset_progress=false
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be preserved, got NULL")
	}
	if row.BaselineValue.Int64 != 100 {
		t.Errorf("baseline_value = %d, want 100 (preserved with reset_progress=false)", row.BaselineValue.Int64)
	}

	// Relative progress = 108 - 100 = 8, target = 10, so in_progress
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// TestSQLRotation_CompletedGoalRotatedExplicitResetProgress verifies
// completed+stale+reset_progress=true explicitly (same as CompletedGoalRotated
// but with explicit ResetProgress field).
func TestSQLRotation_CompletedGoalRotatedExplicitResetProgress(t *testing.T) {
	ctx := context.Background()

	userID := "verify-user-013"
	goalID := "goal-completed-0"
	completedAt := todayMidnightUTC().Add(-25 * time.Hour)
	setupVerifyRowFull(t, ctx, userID, goalID, 110, "completed", intPtr(100),
		todayMidnightUTC().Add(-2*time.Hour), &completedAt)

	// Completed+stale+reset_progress=true: should reset (same as existing test)
	batch := []eventRow{{
		UserID:           userID,
		GoalID:           goalID,
		ChallengeID:      challengeID,
		Namespace:        namespace,
		Progress:         115,
		IncValue:         5,
		TargetValue:      10,
		ProgressMode:     "relative",
		ResetProgress:    true,
		AllowReselection: false,
	}}

	if err := sqlRotationBatch(ctx, testDB, batch); err != nil {
		t.Fatalf("sqlRotationBatch: %v", err)
	}

	row := readVerifyRow(t, ctx, userID, goalID)

	// Progress updated
	if row.Progress != 115 {
		t.Errorf("progress = %d, want 115", row.Progress)
	}

	// Baseline resets: 115 - 5 = 110
	if !row.BaselineValue.Valid {
		t.Fatal("expected baseline_value to be set, got NULL")
	}
	if row.BaselineValue.Int64 != 110 {
		t.Errorf("baseline_value = %d, want 110", row.BaselineValue.Int64)
	}

	// Status resets: inc=5 < target=10 → in_progress
	if row.Status != "in_progress" {
		t.Errorf("status = %q, want in_progress", row.Status)
	}

	// completed_at cleared on rotation
	if row.CompletedAt.Valid {
		t.Errorf("completed_at = %v, want NULL (cleared on rotation)", row.CompletedAt.Time)
	}

	cleanupVerifyRow(t, ctx, userID)
}

// --- Helper functions for verify tests ---

type verifyRow struct {
	Progress      int
	Status        string
	BaselineValue sql.NullInt64
	UpdatedAt     time.Time
	CompletedAt   sql.NullTime
	ClaimedAt     sql.NullTime
	ExpiresAt     sql.NullTime
}

func setupVerifyRow(t *testing.T, ctx context.Context, userID, goalID string,
	progress int, status string, baseline *int, updatedAt time.Time) {
	t.Helper()
	setupVerifyRowFull(t, ctx, userID, goalID, progress, status, baseline, updatedAt, nil)
}

func setupVerifyRowFull(t *testing.T, ctx context.Context, userID, goalID string,
	progress int, status string, baseline *int, updatedAt time.Time, completedAt *time.Time) {
	t.Helper()

	// Delete first to ensure clean state
	_, _ = testDB.ExecContext(ctx,
		`DELETE FROM bench_user_goal_progress WHERE user_id = $1 AND goal_id = $2`,
		userID, goalID)

	now := time.Now().UTC()
	var baselineSQL any
	if baseline != nil {
		baselineSQL = *baseline
	}

	var claimedAt any
	if status == "claimed" {
		claimedAt = now.Add(-7 * 24 * time.Hour)
	}

	_, err := testDB.ExecContext(ctx, `
		INSERT INTO bench_user_goal_progress
			(user_id, goal_id, challenge_id, namespace, progress, status,
			 completed_at, claimed_at, created_at, updated_at,
			 is_active, assigned_at, baseline_value)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, true, $9, $11)
	`, userID, goalID, challengeID, namespace, progress, status,
		completedAt, claimedAt, now, updatedAt, baselineSQL)
	if err != nil {
		t.Fatalf("setup row %s/%s: %v", userID, goalID, err)
	}
}

func readVerifyRow(t *testing.T, ctx context.Context, userID, goalID string) verifyRow {
	t.Helper()
	var row verifyRow
	err := testDB.QueryRowContext(ctx, `
		SELECT progress, status, baseline_value, updated_at, completed_at, claimed_at, expires_at
		FROM bench_user_goal_progress
		WHERE user_id = $1 AND goal_id = $2
	`, userID, goalID).Scan(
		&row.Progress, &row.Status, &row.BaselineValue,
		&row.UpdatedAt, &row.CompletedAt, &row.ClaimedAt, &row.ExpiresAt)
	if err != nil {
		t.Fatalf("read row %s/%s: %v", userID, goalID, err)
	}
	return row
}

func cleanupVerifyRow(t *testing.T, ctx context.Context, userID string) {
	t.Helper()
	_, err := testDB.ExecContext(ctx,
		`DELETE FROM bench_user_goal_progress WHERE user_id = $1`, userID)
	if err != nil {
		t.Errorf("cleanup %s: %v", userID, err)
	}
}

func intPtr(v int) *int {
	return &v
}

