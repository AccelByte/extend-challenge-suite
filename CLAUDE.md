# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **Challenge Service** as an AccelByte Extend application. The system enables game developers to implement challenge systems (daily missions, seasonal events, quests, achievements) with minimal configuration through a JSON config file. This is an open-source application that game developers can fork and customize.

## Architecture

The system consists of two separate AccelByte Extend microservices plus a shared library:

1. **Backend Service - `extend-challenge-service` (REST API)**
   - Based on: `extend-service-extension-go` template
   - Provides REST API endpoints for challenge queries and reward claiming
   - Integrates with AGS Platform Service for reward distribution
   - Handles JWT authentication and authorization
   - **⚠️ CRITICAL**: `GET /v1/challenges` uses optimized HTTP handler (not gRPC-Gateway)
     - See `docs/ADR_001_OPTIMIZED_HTTP_HANDLER.md` for feature parity requirements
     - When modifying this endpoint, update BOTH handlers (gRPC + HTTP)

2. **Event Handler Service - `extend-challenge-event-handler` (gRPC)**
   - Based on: `extend-event-handler-go` template
   - Receives AGS events via gRPC (Extend platform abstracts Kafka)
   - Updates challenge progress in real-time with buffering (1,000,000x DB load reduction)
   - Supports IAM login events and Statistic update events

3. **Shared Library - `extend-challenge-common`**
   - Domain models, interfaces, and business logic
   - Config loading and validation
   - Shared by both services for consistency

### Key Integration Points

- **AGS IAM Service**: Authentication (JWT validation), login events via `{namespace}.iam.account.v1.userLoggedIn`
- **AGS Platform Service**: Reward grants (item entitlements, wallet credits) using Extend SDK
- **AGS Statistic Service**: Stat update events via `{namespace}.social.statistic.v1.statItemUpdated`
- **PostgreSQL 15+**: Primary data store for user goal progress
- **Redis (optional)**: Caching layer (not critical for M1)

## Core Data Model

### user_goal_progress Table

```sql
CREATE TABLE user_goal_progress (
    user_id VARCHAR(100) NOT NULL,
    goal_id VARCHAR(100) NOT NULL,
    challenge_id VARCHAR(100) NOT NULL,
    namespace VARCHAR(100) NOT NULL,
    progress INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'not_started',
    completed_at TIMESTAMP NULL,
    claimed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, goal_id)
);
```

**Key Design Features:**
- **Lazy Initialization**: Rows created on-demand (no pre-population)
- **Composite Primary Key**: `(user_id, goal_id)` optimized for partitioning
- **Status State Machine**: `not_started` → `in_progress` → `completed` → `claimed`
- **Claimed Protection**: UPSERT queries skip updates for claimed goals
- **Partition-Ready**: Design scores 9/10 for future partitioning (see TECH_SPEC_DATABASE_PARTITIONING.md)

## API Endpoints

### Backend Service (M1 Scope)

- `GET /v1/challenges` - List all challenges with user's progress
- `GET /v1/challenges/{challenge_id}` - Get specific challenge with user's progress
- `POST /v1/challenges/{challenge_id}/goals/{goal_id}/claim` - Claim reward for completed goal
- `GET /healthz` - Liveness probe

All endpoints require AGS IAM Bearer token authentication (JWT validation).

## Event Processing Flow

### High-Performance Buffered Processing

1. **Event Ingestion**: Extend platform consumes from Kafka, delivers to handler via gRPC
   - IAM login events: `{namespace}.iam.account.v1.userLoggedIn`
   - Statistic updates: `{namespace}.social.statistic.v1.statItemUpdated`

2. **Event Processing**: Handler validates event → looks up affected goals from in-memory cache

3. **Buffered Updates**: Instead of immediate DB writes:
   - Per-user mutex prevents race conditions
   - Map-based deduplication (only latest progress per user-goal pair)
   - Periodic flush every 1 second

4. **Batch UPSERT**: Flush operation uses single SQL query for all buffered updates
   - 1,000 updates = 1 database query (not 1,000 queries)
   - Result: **1,000,000x DB load reduction**
   - ~20ms per flush for 1,000 rows

5. **Reward Claiming**: Client calls `/v1/challenges/{id}/goals/{id}/claim`
   - Backend validates status = 'completed'
   - Calls AGS Platform Service (Extend SDK)
   - Marks as 'claimed' in database
   - Row-level locking prevents double claims

### Event Schema References

- **IAM Events**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/
- **Statistic Events**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/
- **Proto Definitions**: https://github.com/AccelByte/accelbyte-api-proto

## Development Workflow

### Philosophy

We minimize changes to the AccelByte templates to maintain compatibility with upstream updates. Only customize:
- Module names in `go.mod`
- Project descriptions in `README.md`
- Business logic in `internal/` directories
- Database migrations (backend service only)
- Configuration values (not structure)

**Keep template's existing Makefiles, Dockerfiles, and config structure intact.**

### Initial Setup

```bash
# Clone backend service template
git clone https://github.com/AccelByte/extend-service-extension-go extend-challenge-service

# Clone event handler template
git clone https://github.com/AccelByte/extend-event-handler-go extend-challenge-event-handler

# Create shared library
mkdir extend-challenge-common
```

### Database Schema

Apply PostgreSQL schema from `docs/TECH_SPEC_DATABASE.md`:
- Table: `user_goal_progress` with primary key `(user_id, goal_id)`
- Index: `idx_user_goal_progress_user_challenge` on `(user_id, challenge_id)`
- Use `golang-migrate` for migrations (see `migrations/` folder)

### Configuration

**Environment Variables** (both services):
```bash
DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD    # PostgreSQL
REDIS_HOST, REDIS_PORT, REDIS_PASSWORD             # Redis (optional for M1)
AB_CLIENT_ID, AB_CLIENT_SECRET                     # AGS service account
AB_BASE_URL, AB_NAMESPACE                          # AGS connection
```

**Challenge Configuration** (JSON file in `config/challenges.json`):
- Define challenges and goals
- Specify requirements (stat checks, prerequisites)
- Configure rewards (ITEM or WALLET)
- See `docs/TECH_SPEC_CONFIGURATION.md` for full schema

## Important Implementation Notes

### Key Design Principles

1. **Config-First Approach**: Challenges defined in JSON file, no admin CRUD API in M1
2. **Event-Driven Progress**: Stats updated via events, not API calls
3. **Buffering Strategy**: 1-second flush interval with batch UPSERT for 1,000,000x query reduction
4. **Lazy Initialization**: User progress rows created on-demand
5. **Interface-Driven**: GoalRepository, GoalCache, RewardClient interfaces for testability
6. **Single Namespace**: Each deployment operates in one AGS namespace

### Concurrency & Idempotency

- **Per-User Mutex**: Prevents concurrent event processing for same user
- **Map-Based Deduplication**: Buffer keeps only latest progress per user-goal pair
- **Status-Based Protection**: UPSERT queries skip updates for 'claimed' goals
- **Row-Level Locking**: `SELECT ... FOR UPDATE` in claim flow prevents double claims

### Performance Targets

- API response time: < 200ms (p95)
- Event processing time: < 50ms (p95)
- Database query time: < 50ms (p95)
- Batch UPSERT: < 20ms for 1,000 rows (p95)
- Cache lookup: < 1ms (O(1) in-memory)

### Error Handling

- Event processing: Log errors but continue (events are fire-and-forget)
- Reward grants: 3 retries with exponential backoff, return 502 on failure
- Database errors: Retry flush on next interval, keep buffer intact
- Structured logging with `userId`, `goalID`, `challengeID`, `namespace`

### Security

- **JWT Validation**: Validate signature and expiration on every REST request
- **Extract from Token**: Get `userId` and `namespace` from JWT claims (never trust request body)
- **Centralized Auth**: JWT decoding handled by auth interceptor (see `docs/JWT_AUTHENTICATION.md`)
- **No PII**: Store only `userId`, no personal information
- **GDPR Compliance**: Support data deletion via `DELETE FROM user_goal_progress WHERE user_id = $1`

## Testing Strategy

### Coverage Target
**Aim for 80% code coverage using unit tests** for all packages. This is the industry standard for production-quality code and ensures critical paths are well-tested.

### Test Types
- **Unit Tests**: Mock all interfaces (GoalRepository, GoalCache, RewardClient)
  - Target: **80%+ coverage** for all packages
  - Focus on business logic and error handling
  - Fast execution (< 1 second for full suite)
- **Integration Tests**: Use testcontainers for PostgreSQL, test real database queries
  - Target: 70-80% coverage for repository implementations
  - Validate database operations and constraints
- **E2E Tests**: Full flow (event → progress update → claim), test buffering and batch UPSERT
  - Small number of tests (5-10) covering critical user journeys
- **Performance Tests**: k6 load testing for 1,000 events/sec, verify < 50ms processing time
  - Benchmark batch operations and API response times

See `docs/TECH_SPEC_TESTING.md` for detailed test plans and fixtures.

### Integration Test Setup

Integration tests require a PostgreSQL database with test credentials (user: `testuser`, password: `testpass`, database: `testdb`).

**Option 1: Use Main Postgres Container (One-time Setup)**

If you already have the main postgres container running from `docker-compose.yml`, use this one-liner to create the test database:

```bash
docker-compose up -d postgres && sleep 3 && docker exec challenge-postgres psql -U postgres -c "CREATE DATABASE testdb;" 2>/dev/null || true && docker exec challenge-postgres psql -U postgres -c "CREATE USER testuser WITH PASSWORD 'testpass';" 2>/dev/null || true && docker exec challenge-postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE testdb TO testuser;" && docker exec challenge-postgres psql -U postgres -d testdb -c "ALTER SCHEMA public OWNER TO testuser;"
```

This is **idempotent** - safe to run multiple times. After running once, simply run tests anytime:
```bash
cd extend-challenge-service && go test ./tests/integration/... -v
```

**Option 2: Dedicated Test Container (Isolated)**

For isolated test environment, use the dedicated test container (requires stopping main postgres first if on same port):

```bash
# Stop main postgres if running
docker-compose down postgres

# Start dedicated test container
docker-compose -f docker-compose.test.yml up -d postgres-test

# Run tests
cd extend-challenge-service && make test-integration-run

# Teardown
docker-compose -f docker-compose.test.yml down -v
```

**Using Makefile:**
```bash
cd extend-challenge-service
make test-integration-setup    # Start test database
make test-integration-run      # Run integration tests
make test-integration-teardown # Clean up
```

**Or run all in one command:**
```bash
cd extend-challenge-service && make test-integration
```

**Test database credentials:**
- Host: `localhost`
- Port: `5433`
- Database: `testdb`
- User: `testuser`
- Password: `testpass`

## Deployment

### Local Development

```bash
docker-compose up -d  # PostgreSQL + Redis
# Run migrations
# Start services in separate terminals
```

### AccelByte Extend

- Deploy using `extend-helper-cli` or manual Docker image push
- Service Extension: Exposed as REST API in namespace
- Event Handler: Automatically receives events via gRPC
- See `docs/TECH_SPEC_DEPLOYMENT.md` for full deployment guide

### Production Recommendations

- **Service**: 3 replicas, HPA on CPU (70%), 500m CPU / 512Mi RAM
- **Event Handler**: 2 replicas, 250m CPU / 256Mi RAM
- **Database**: PostgreSQL 15+ with connection pooling (max 150 connections)
- **Monitoring**: Prometheus + Grafana for metrics, structured logging to stdout

## Code Style Conventions

Per global `.claude/CLAUDE.md`:
- Use **early return** style (avoid nested conditionals)
- Ask before destructive database operations

## Project Structure

```
extend-challenge/
├── docs/                                    # All specifications and documentation
│   ├── TECH_SPEC_M1.md                     # Main technical spec (index)
│   ├── TECH_SPEC_DATABASE.md               # Database schema, queries, migrations
│   ├── TECH_SPEC_API.md                    # REST API endpoints and schemas
│   ├── TECH_SPEC_EVENT_PROCESSING.md       # Event flow, buffering, batch UPSERT
│   ├── TECH_SPEC_CONFIGURATION.md          # Config file format and validation
│   ├── TECH_SPEC_DEPLOYMENT.md             # Local dev and Extend deployment
│   ├── TECH_SPEC_TESTING.md                # Test strategy and fixtures
│   ├── JWT_AUTHENTICATION.md               # JWT auth architecture and implementation
│   ├── TECH_SPEC_DATABASE_PARTITIONING.md  # Future scaling strategy
│   ├── BRAINSTORM.md                       # 70 design decisions (5 rounds)
│   ├── MILESTONES.md                       # M1-M6 feature roadmap
│   └── STATUS.md                           # Current implementation progress
│
├── extend-challenge-service/               # REST API service extension
│   ├── cmd/main.go
│   ├── internal/
│   │   ├── handler/                       # HTTP handlers
│   │   ├── service/                       # Business logic
│   │   └── repository/                    # Database layer
│   ├── migrations/                        # Database migrations
│   ├── Dockerfile
│   └── go.mod
│
├── extend-challenge-event-handler/         # gRPC event handler
│   ├── cmd/main.go
│   ├── internal/
│   │   ├── processor/                     # Event processing logic
│   │   └── buffered/                      # BufferedRepository
│   ├── Dockerfile
│   └── go.mod
│
├── extend-challenge-common/                # Shared library
│   └── pkg/
│       ├── config/                         # Config loader and cache
│       ├── domain/                         # Domain models
│       ├── repository/                     # Repository interfaces
│       ├── cache/                          # GoalCache interface
│       ├── client/                         # RewardClient interface
│       └── errors/                         # Error types
│
├── docker-compose.yml                      # Local development
├── .env.example
├── CLAUDE.md                               # This file
└── README.md
```

## Technical Documentation Structure

### Start Here

**[docs/TECH_SPEC_M1.md](./docs/TECH_SPEC_M1.md)** - Main technical specification
- Overview and architecture
- Technology stack
- Core interfaces (GoalRepository, GoalCache, RewardClient)
- Links to all detailed specifications
- Implementation phases (9 phases, ~2 weeks)

### Detailed Specifications

1. **[docs/TECH_SPEC_DATABASE.md](./docs/TECH_SPEC_DATABASE.md)** - Database design
   - `user_goal_progress` table schema
   - Indexes and constraints
   - UPSERT and Batch UPSERT queries
   - Migration scripts (golang-migrate)
   - Connection pooling configuration

2. **[docs/TECH_SPEC_API.md](./docs/TECH_SPEC_API.md)** - REST API
   - Endpoints: GET /v1/challenges, POST /v1/challenges/{id}/goals/{id}/claim
   - Request/response schemas
   - JWT authentication
   - Error codes and handling

3. **[docs/TECH_SPEC_EVENT_PROCESSING.md](./docs/TECH_SPEC_EVENT_PROCESSING.md)** - Event handling
   - Event flow diagrams
   - IAM and Statistic event schemas
   - Buffering strategy (1,000,000x query reduction)
   - Batch UPSERT implementation
   - Per-user mutex and concurrency control

4. **[docs/TECH_SPEC_CONFIGURATION.md](./docs/TECH_SPEC_CONFIGURATION.md)** - Configuration
   - Environment variables
   - `challenges.json` file format
   - Config validation rules
   - In-memory cache structure

5. **[docs/TECH_SPEC_DEPLOYMENT.md](./docs/TECH_SPEC_DEPLOYMENT.md)** - Deployment
   - Local development setup (docker-compose)
   - AccelByte Extend deployment
   - Kubernetes configuration
   - Monitoring and alerting

6. **[docs/TECH_SPEC_TESTING.md](./docs/TECH_SPEC_TESTING.md)** - Testing
   - Unit test strategy with mocks
   - Integration tests with testcontainers
   - E2E test scenarios
   - Performance testing with k6

### Design Documentation

- **[docs/BRAINSTORM.md](./docs/BRAINSTORM.md)** - All design decisions
  - 70 decisions across 5 rounds of iteration
  - Event-driven architecture rationale
  - Buffering strategy analysis
  - Interface-driven design choices

- **[docs/MILESTONES.md](./docs/MILESTONES.md)** - Product roadmap
  - M1: Foundation (simple fixed challenges) ← **Current**
  - M2: Multiple challenges & tagging
  - M3: Time-based challenges & rotation
  - M4: Randomized assignment
  - M5: Prerequisites & visibility control
  - M6: Advanced assignment & claim rules

- **[docs/TECH_SPEC_DATABASE_PARTITIONING.md](./docs/TECH_SPEC_DATABASE_PARTITIONING.md)** - Scaling strategy
  - Partition-readiness analysis (score: 9/10)
  - Hash partitioning strategy for 10M+ users
  - Migration path (2 days effort)
  - Multi-database sharding for 100M+ users

### External References

- **AccelByte Extend**: https://docs.accelbyte.io/extend/
- **Service Extension Template**: https://github.com/AccelByte/extend-service-extension-go
- **Event Handler Template**: https://github.com/AccelByte/extend-event-handler-go
- **AGS SDK Functions**: Use Extend SDK MCP Server (`mcp__extend-sdk-mcp-server__*` tools)
- **AGS Event Schemas**:
  - IAM Events: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/
  - Statistic Events: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/
  - Proto Definitions: https://github.com/AccelByte/accelbyte-api-proto

## Project Conventions

- **All specs in `docs/` folder**: Keep documentation centralized
- **Modular spec structure**: Each spec focuses on one aspect
- **Track progress**: Update `docs/STATUS.md` before starting new work (keep under 100 lines)
- **Reference by link**: Use relative links like `[TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)`
- **No implementation code in specs**: Specs describe design, not implementation

## Working with This Project

### When starting a new task:
1. Read `docs/TECH_SPEC_M1.md` for overview
2. Navigate to relevant detailed spec
3. Check `docs/BRAINSTORM.md` for design rationale
4. Update `docs/STATUS.md` with current phase

### When adding new features (M2+):
1. Check `docs/MILESTONES.md` for planned features
2. Create new spec documents if needed
3. Update `docs/TECH_SPEC_M1.md` links
4. Document design decisions in `docs/BRAINSTORM.md`

### When looking for AGS SDK functions:
- Use Extend SDK MCP Server tools:
  - `mcp__extend-sdk-mcp-server__search_functions` - Find SDK functions
  - `mcp__extend-sdk-mcp-server__get_bulk_functions` - Get function details
- Do NOT use AccelByte documentation URLs for SDK references

### When looking for event schemas:
- Use AccelByte API Events documentation (NOT MCP Server)
- Check proto definitions on GitHub for exact payload structure

## Code Quality Workflow

### Always Run Linter After Completing Tasks

**IMPORTANT:** Before marking any implementation task as complete, ALWAYS run the linter to ensure code quality.

#### Required Steps

1. **Run tests with coverage**
   ```bash
   go test ./... -coverprofile=coverage.out
   go tool cover -func=coverage.out | grep total
   ```
   - **Target:** ≥ 80% coverage
   - If below 80%, add more tests before proceeding

2. **Run linter**
   ```bash
   golangci-lint run ./...
   ```
   - **Target:** Zero issues
   - Fix all issues before proceeding

3. **Auto-fix simple issues**
   ```bash
   golangci-lint run --fix ./...
   ```
   - Automatically fixes formatting, imports, etc.
   - Review changes before committing

4. **Verify all checks pass**
   ```bash
   make test-all  # Runs both tests and linter
   ```

#### Task Completion Checklist

Before marking a task as "done", verify:

- ✅ All tests pass
- ✅ Test coverage ≥ 80%
- ✅ Linter reports zero issues
- ✅ Code follows early return style
- ✅ All errors are checked (no `errcheck` warnings)
- ✅ No nil pointer dereferences (no `staticcheck` warnings)
- ✅ Code is formatted (`gofmt`, `goimports`)

#### Integration with Claude Code Workflow

**When implementing a feature:**

```
1. Write tests (TDD approach)
2. Implement feature
3. Run tests: `go test ./... -v`
4. Check coverage: `go test ./... -coverprofile=coverage.out`
5. Run linter: `golangci-lint run ./...`  ← MANDATORY
6. Fix all linter issues
7. Commit changes
```

**When fixing bugs:**

```
1. Write failing test that reproduces bug
2. Fix bug
3. Verify test passes
4. Run linter: `golangci-lint run ./...`  ← MANDATORY
5. Fix any issues introduced
6. Commit fix
```

**When refactoring:**

```
1. Ensure tests exist and pass
2. Refactor code
3. Run tests to ensure behavior unchanged
4. Run linter: `golangci-lint run ./...`  ← MANDATORY
5. Address any new linter issues
6. Commit refactoring
```

#### Common Linter Issues and Fixes

##### Issue: Early Return Style Violation (nestif)

**Problem:**
```go
func Process(data *Data) error {
    if data != nil {
        if data.Valid() {
            return processData(data)
        }
    }
    return errors.New("invalid")
}
```

**Fix:**
```go
func Process(data *Data) error {
    if data == nil {
        return errors.New("data cannot be nil")
    }

    if !data.Valid() {
        return errors.New("invalid data")
    }

    return processData(data)
}
```

##### Issue: Unchecked Error (errcheck)

**Problem:**
```go
json.Marshal(data)  // Error ignored
```

**Fix:**
```go
_, err := json.Marshal(data)
if err != nil {
    return fmt.Errorf("marshal failed: %w", err)
}
```

##### Issue: Missing Nil Check (staticcheck)

**Problem:**
```go
func UpdateProgress(p *Progress) error {
    key := p.UserID + p.GoalID  // Panic if p is nil
}
```

**Fix:**
```go
func UpdateProgress(p *Progress) error {
    if p == nil {
        return errors.New("progress cannot be nil")
    }

    key := p.UserID + p.GoalID
}
```

#### Makefile Integration

Add these targets to project Makefiles:

```makefile
.PHONY: lint
lint:
	@echo "Running golangci-lint..."
	@golangci-lint run ./...

.PHONY: lint-fix
lint-fix:
	@echo "Running golangci-lint with auto-fix..."
	@golangci-lint run --fix ./...

.PHONY: test
test:
	@echo "Running tests..."
	@go test ./... -v

.PHONY: test-coverage
test-coverage:
	@echo "Running tests with coverage..."
	@go test ./... -coverprofile=coverage.out
	@go tool cover -func=coverage.out | grep total

.PHONY: test-all
test-all: lint test-coverage
	@echo "✅ All checks passed!"
```

#### CI/CD Enforcement

The linter should run automatically in CI/CD to prevent merging code with issues:

```yaml
# .github/workflows/ci.yml
name: CI

on: [pull_request, push]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Run linter
        run: golangci-lint run ./...

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Run tests with coverage
        run: |
          go test ./... -coverprofile=coverage.out
          COVERAGE=$(go tool cover -func=coverage.out | grep total | awk '{print $3}' | sed 's/%//')
          if (( $(echo "$COVERAGE < 80" | bc -l) )); then
            echo "❌ Coverage $COVERAGE% below 80% target"
            exit 1
          fi
```

#### Expected Behavior

When working with Claude Code:

1. **During implementation:** Claude will write code following best practices
2. **Before task completion:** Claude will run `golangci-lint run ./...`
3. **If issues found:** Claude will fix all linter issues automatically
4. **Final verification:** Claude will confirm zero linter issues before marking task complete

**Example Claude Code workflow:**

```
User: "Implement UpdateProgress function"

Claude:
1. ✅ Writes implementation
2. ✅ Writes unit tests
3. ✅ Runs tests: go test -v
4. ✅ Runs linter: golangci-lint run ./...
5. ⚠️  Linter found 2 issues:
   - buffered_repository.go:45 - nestif: too many nested ifs
   - buffered_repository.go:52 - errcheck: unchecked error
6. ✅ Fixes linter issues
7. ✅ Re-runs linter: zero issues
8. ✅ Task complete

User receives: "Implementation complete. All tests pass (96% coverage), zero linter issues."
```

#### Benefits

- **Consistency:** All code follows project standards automatically
- **Quality:** Catches bugs, security issues, and style violations early
- **Documentation:** Linter config serves as executable coding standards
- **Efficiency:** Automated checks reduce manual code review burden
- **Learning:** Developers learn best practices from linter feedback

**See `docs/TECH_SPEC_TESTING.md` for detailed linter configuration and examples.**