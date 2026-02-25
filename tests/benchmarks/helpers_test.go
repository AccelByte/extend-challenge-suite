package benchmarks

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

var testDB *sql.DB

func TestMain(m *testing.M) {
	dsn := os.Getenv("BENCHMARK_DB_DSN")
	if dsn == "" {
		dsn = "postgres://postgres:postgres@localhost:5433/challenge_db?sslmode=disable"
	}

	var err error
	testDB, err = sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer testDB.Close()

	testDB.SetMaxOpenConns(20)
	testDB.SetMaxIdleConns(10)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := testDB.PingContext(ctx); err != nil {
		log.Fatalf("Failed to ping database: %v", err)
	}

	log.Println("Creating benchmark schema...")
	if err := createSchema(ctx, testDB); err != nil {
		log.Fatalf("Failed to create schema: %v", err)
	}

	log.Println("Seeding 100K rows (10K users x 10 goals)...")
	seedStart := time.Now()
	if err := seedData(ctx, testDB); err != nil {
		log.Fatalf("Failed to seed data: %v", err)
	}
	log.Printf("Seeded in %v", time.Since(seedStart))

	code := m.Run()

	log.Println("Dropping benchmark schema...")
	if err := dropSchema(context.Background(), testDB); err != nil {
		log.Printf("Warning: failed to drop schema: %v", err)
	}

	os.Exit(code)
}

// resetData truncates and re-seeds the bench table. Call with b.StopTimer()/b.StartTimer().
func resetData(b *testing.B) {
	b.Helper()
	b.StopTimer()
	ctx := context.Background()
	if err := truncateData(ctx, testDB); err != nil {
		b.Fatalf("truncate: %v", err)
	}
	if err := seedData(ctx, testDB); err != nil {
		b.Fatalf("re-seed: %v", err)
	}
	b.StartTimer()
}

// todayMidnightUTC returns today's midnight UTC (the rotation boundary for daily goals).
func todayMidnightUTC() time.Time {
	now := time.Now().UTC()
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
}

// eventRow represents a single event in a simulated batch.
type eventRow struct {
	UserID       string
	GoalID       string
	ChallengeID  string
	Namespace    string
	Progress     int    // absolute stat value from event
	IncValue     int    // increment from this event
	TargetValue  int    // completion target
	ProgressMode string // "relative" or "absolute"
}

// generateEventBatch creates simulated event data for N distinct users.
// Each user gets events for their 4 daily-relative goals (the rotatable ones)
// plus 2 absolute goals, for 6 events per user total.
// The returned batch has N*6 rows if N <= seedUsers.
func generateEventBatch(n int) []eventRow {
	if n > seedUsers {
		n = seedUsers
	}

	// Each user generates events for 6 goals (4 daily-relative + 2 absolute)
	eventGoals := []struct {
		goalID       string
		progressMode string
		targetValue  int
	}{
		{"goal-daily-rel-0", "relative", 10},
		{"goal-daily-rel-1", "relative", 10},
		{"goal-daily-rel-2", "relative", 10},
		{"goal-daily-rel-3", "relative", 10},
		{"goal-abs-0", "absolute", 20},
		{"goal-abs-1", "absolute", 20},
	}

	batch := make([]eventRow, 0, n*len(eventGoals))
	for i := 0; i < n; i++ {
		userID := fmt.Sprintf("user-%05d", i)
		for _, eg := range eventGoals {
			newProgress := 108 // absolute stat value (baseline was 100, so +8 relative)
			if eg.progressMode == "absolute" {
				newProgress = 8
			}
			batch = append(batch, eventRow{
				UserID:       userID,
				GoalID:       eg.goalID,
				ChallengeID:  challengeID,
				Namespace:    namespace,
				Progress:     newProgress,
				IncValue:     3,
				TargetValue:  eg.targetValue,
				ProgressMode: eg.progressMode,
			})
		}
	}
	return batch
}

// generateEventBatchNUsers creates a batch with exactly `size` event rows
// spread across users. Each user contributes one event for a random goal.
func generateEventBatchNRows(size int) []eventRow {
	batch := make([]eventRow, 0, size)
	for i := 0; i < size; i++ {
		userIdx := i % seedUsers
		goalIdx := i % 4 // rotate among daily-relative goals
		userID := fmt.Sprintf("user-%05d", userIdx)
		goalID := fmt.Sprintf("goal-daily-rel-%d", goalIdx)

		batch = append(batch, eventRow{
			UserID:       userID,
			GoalID:       goalID,
			ChallengeID:  challengeID,
			Namespace:    namespace,
			Progress:     108, // absolute stat (baseline=100, so relative=8)
			IncValue:     3,
			TargetValue:  10,
			ProgressMode: "relative",
		})
	}
	return batch
}
