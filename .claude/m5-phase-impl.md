# M5 Phase Implementation Prompt

> Give this prompt to a fresh Claude agent. Replace `{{PHASE}}` with the phase identifier (e.g., `0.5`, `1`, `2`, … `8`).

---

## Your Task

Implement **Phase {{PHASE}}** of M5 (Time-Based Rotation) from the tech spec.

Read `docs/TECH_SPEC_M5.md` fully before writing any code. Find the section **"Phase {{PHASE}}"** — it contains the checklist of deliverables. Every checked box (`[x]`) is already done; implement only unchecked boxes (`[ ]`).

---

## Project Architecture

Three Go modules in a monorepo:

| Module | Path | `go.mod` name | Role |
|--------|------|---------------|------|
| **Common** | `extend-challenge-common/` | `github.com/AccelByte/extend-challenge-common` | Domain models, interfaces, config, shared logic |
| **Service** | `extend-challenge-service/` | `extend-challenge-service` | REST API (AccelByte Extend service extension) |
| **Event Handler** | `extend-challenge-event-handler/` | `extend-challenge-event-handler` | gRPC event processor with buffered writes |

Both services depend on common via `replace` directive in their `go.mod`.

### Key Source Files

**Common — Domain & Config:**
- `extend-challenge-common/pkg/domain/models.go` — `Goal`, `Requirement`, `UserGoalProgress`, `Reward` structs
- `extend-challenge-common/pkg/config/loader.go` — JSON config loading
- `extend-challenge-common/pkg/config/validator.go` — Config validation rules
- `extend-challenge-common/pkg/cache/in_memory_goal_cache.go` — In-memory goal cache
- `extend-challenge-common/pkg/repository/goal_repository.go` — `GoalRepository` interface
- `extend-challenge-common/pkg/repository/postgres_goal_repository.go` — PostgreSQL implementation

**Service — REST API:**
- `extend-challenge-service/pkg/handler/optimized_challenges_handler.go` — Optimized GET /v1/challenges (HTTP, not gRPC-Gateway)
- `extend-challenge-service/pkg/handler/challenges_grpc_handler.go` — gRPC handler (feature parity required with optimized handler)
- `extend-challenge-service/pkg/service/claim.go` — Claim reward logic
- `extend-challenge-service/migrations/001_create_user_goal_progress.up.sql` — DB schema

**Event Handler — Event Processing:**
- `extend-challenge-event-handler/pkg/processor/event_processor.go` — Routes events to goal handlers
- `extend-challenge-event-handler/pkg/buffered/buffered_repository.go` — Buffered writes with periodic flush

**Benchmarks (reference implementation for SQL rotation):**
- `tests/benchmarks/bench_3_sql_rotation_test.go` — SQL CASE rotation benchmark
- `tests/benchmarks/verify_test.go` — Rotation correctness verification tests
- `tests/benchmarks/helpers_test.go` — `eventRow` struct, test helpers
- `tests/benchmarks/schema.go` — Benchmark table schema with M5 columns

---

## M5 Phases Overview

| Phase | Name | Summary |
|-------|------|---------|
| **0.5** | GoalType → ProgressMode Migration + Inc Extraction | Replace `GoalType` enum with `ProgressMode` (`absolute`/`relative`). Extract `Inc` from events. ~34 files. |
| **1** | Database Schema | Add `baseline_value INT NULL` column to migration. Update `UserGoalProgress` struct. |
| **2** | Unified COPY Path | Replace 3 buffer maps with single unified buffer. Remove `IncrementProgress`/`BatchIncrementProgress`. |
| **3** | Config Schema | Add `rotation` config block. Validate rotation constraints. Update `challenges.json`. |
| **4** | Rotation Detection Utilities | Boundary calculation functions: `CalculateLastRotationBoundary`, `HasRotationOccurred`, etc. |
| **5** | SQL CASE Rotation | Port SQL CASE rotation logic from benchmarks to production `BatchUpsertProgressWithCOPY`. |
| **6** | API Handler Updates | Lazy rotation detection in all endpoints. `calculateDisplayedProgress`. `expires_at` response fields. |
| **7** | Testing + Benchmark Updates | Integration/E2E tests for rotation. Full linter + coverage check. |
| **8** | Documentation Updates | Replace GoalType refs with ProgressMode across all docs. Add rotation config docs. |

---

## Workflow: Strict Red/Green TDD

For every deliverable in the phase checklist, follow this cycle:

### 1. RED — Write a failing test first

- Write the test **before** writing or modifying any production code.
- Run the test and confirm it **fails** (compilation error counts as red).
- Name tests: `Test<Unit>_<Scenario>` (e.g., `TestCalculateLastRotationBoundary_Daily`).

### 2. GREEN — Write minimal code to pass

- Write the **minimum** production code to make the test pass.
- Run the test and confirm it **passes**.

### 3. REFACTOR (if needed)

- Clean up only if the code is unclear. Don't gold-plate.
- Re-run tests to confirm nothing broke.

### Repeat for every checklist item.

---

## Test Conventions

**Framework:** `github.com/stretchr/testify` (assert, require, mock)

**Mocks:** Embed `mock.Mock` and implement the interface:
```go
type MockGoalCache struct {
    mock.Mock
}

func (m *MockGoalCache) GetGoalByID(goalID string) *domain.Goal {
    args := m.Called(goalID)
    if args.Get(0) == nil {
        return nil
    }
    return args.Get(0).(*domain.Goal)
}
```

**Assertions:**
- `require.*` for preconditions (test stops on failure)
- `assert.*` for verifications (test continues on failure)
- Always call `mock.AssertExpectations(t)` at the end

**File placement:**
- Unit tests: same package, `*_test.go` next to source
- Integration tests: `tests/integration/` directory
- E2E tests: `pkg/processor/*_test.go` with `TestE2E` prefix

**Copyright header** (required by linter on all new `.go` files):
```go
// Copyright (c) 2026 AccelByte Inc. All Rights Reserved.
// This is licensed software from AccelByte Inc, for limitations
// and restrictions contact your company contract manager.
```

---

## Quality Gates (Run Before Declaring Done)

Execute these in **all three modules**, not just the ones you modified:

```bash
# 1. Run unit tests with coverage in ALL modules
for dir in extend-challenge-common extend-challenge-service extend-challenge-event-handler; do
  echo "=== $dir ==="
  cd "$dir"
  go test ./... -coverprofile=coverage.out
  go tool cover -func=coverage.out | grep total
  cd ..
done
# Target: ≥ 80% (best effort — don't pad tests, but cover real paths)

# 2. Run linter in ALL modules — must be zero issues
for dir in extend-challenge-common extend-challenge-service extend-challenge-event-handler; do
  echo "=== $dir ==="
  cd "$dir" && golangci-lint run ./... && cd ..
done

# 3. Integration tests are MANDATORY when you touch DB schema, repository, or handlers.
# Ensure the test database is running before running integration tests.
# Start DB if needed:
docker-compose up -d postgres && sleep 3 && docker exec challenge-postgres psql -U postgres -c "CREATE DATABASE testdb;" 2>/dev/null || true && docker exec challenge-postgres psql -U postgres -c "CREATE USER testuser WITH PASSWORD 'testpass';" 2>/dev/null || true && docker exec challenge-postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE testdb TO testuser;" && docker exec challenge-postgres psql -U postgres -d testdb -c "ALTER SCHEMA public OWNER TO testuser;"

# Run integration tests:
cd extend-challenge-service
make test-integration-run
```

If the linter reports issues, fix them before moving on. Common issues:
- `nestif`: refactor to early-return style
- `errcheck`: handle all returned errors
- `govet` shadow: rename shadowed variables

---

## Key M5 Concepts (Quick Reference)

**ProgressMode** (replaces GoalType):
- `absolute` — progress = stat_value (blind write, no rotation)
- `relative` — progress = stat_value, displayed = progress - baseline (supports rotation)

**Baseline Snapshot:**
- First stat event sets baseline via SQL: `baseline = progress - inc_value`
- Never fetched from AGS API — derived from event data

**Truly Lazy Rotation (no background scheduler):**
- **API path (read-only):** `HasRotationOccurred(row, goal, now)` → display reset state, no DB write
- **Event path (SQL-side):** SQL CASE in batch UPDATE detects stale rows, resets baseline

**Unified Buffer:** Single `map[string]*BufferedEvent` replaces the old 3-map setup (`buffer`, `bufferIncrement`, `bufferIncrementDaily`).

**Rotation Reset Matrix:**

| Status | reset_progress=true | reset_progress=false |
|--------|---|---|
| not_started | Reset | Keep |
| in_progress | Reset to not_started | Keep |
| completed | Reset | Keep completed |
| claimed | Reset if allow_reselection | Skip |

---

## Exit Criteria

Phase {{PHASE}} is **done** when:

1. Every unchecked box (`[ ]`) in the phase checklist is implemented
2. All new code has corresponding tests (written first, TDD)
3. `go test ./...` passes in **all three modules** (common, service, event-handler) — not just the ones you touched
4. `golangci-lint run ./...` reports zero issues in **all three modules**
5. Coverage is ≥ 80% (best effort) in modified packages
6. No unrelated changes — only touch what the phase requires
7. Mark all completed checklist items as done (`[x]`) in `docs/TECH_SPEC_M5.md`
