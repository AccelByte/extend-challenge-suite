# Challenge Service - Brainstorming Doc (Compact)

**Last Updated:** 2025-10-15

---

## Core Understanding

Building a **comprehensive Challenge Service** for AccelByte Gaming Services (AGS). Open-source Extend app for game developers to implement challenge systems (daily missions, seasonal events, quests).

### Reference Use Cases from PRD
1. **Winter Challenge** - 3-month seasonal, 3 goals/week, randomized from pool
2. **Daily Mission** - Infinite duration, 2-3 goals/day, allows repetition
3. **Apprentice Quest** - 1-month event, 15 fixed goals in 3 tiers
4. **Sunrise Sign In** - Daily login, 7-day weekly cycle with escalating rewards
5. **Odyssey of Ascendancy** - Long-term quest list, 50 fixed goals, no time limit

---

## Key Design Decisions ✅

### Architecture
- **Two Extend apps:** Service Extension (REST API) + Event Handler (gRPC)
- **Event-driven:** No AGS API calls for player operations, only consume events
- **Extend platform** handles Kafka (we just implement gRPC handlers)

### Technology Stack
- **PostgreSQL** - Primary data store (typed schema, ACID)
- **In-memory cache** - Goal configs (no JOINs, no DB reads on events)
- **Buffering** - 1000x DB load reduction (1 query/sec vs 1K queries/sec)
- **Interface-driven** - Swap DB/cache implementations easily

### Philosophy
- **Open source, forkable** - Code-first, not config-first
- **No JSONB/rules engine** - Typed columns, users modify Go code for customization
- **Clean interfaces** - `GoalRepository`, `GoalCache` for testability

### Performance Architecture
```
Event → In-memory cache lookup (~1μs) → Buffer write (~10μs) → Periodic flush (1 sec)
Total latency: ~1ms per event
DB load: ~1 query/sec (1000x reduction)
Memory: ~102MB (2MB buffer + 100MB goal cache)
```

### Data Consistency
- **Eventual consistency** (M1 default) - 0-1 sec delay in progress visibility
- **Can upgrade to read-your-writes** in M2+ if needed

---

### Initial Architecture Decisions (Updated for Single-Namespace)

#### Critical Architectural Discovery 🚨
**Extend apps are deployed per namespace** - This simplifies architecture significantly:
- No multi-namespace handling needed in application code
- No `WHERE namespace = ?` in queries
- Simpler cache keys (no namespace prefix needed)
- Config file doesn't need namespace field
- Each namespace gets its own deployment with isolated DB

---

### Implementation Decisions - Round 2

#### 21. Config File Format & Structure ✅
**Decision:** JSON format with human-readable IDs

**Key choices:**
- JSON over YAML (strict, machine-parseable)
- Human-readable IDs (e.g., `"winter-challenge-2025"`, not UUIDs)
- No `namespace` field (implicit from deployment)

**Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

---

#### 22. Config Validation Strategy ✅
**Decision:** Fail fast on startup if invalid config

**Validations:**
- Required fields present (id, name, stat_code, reward, etc.)
- No duplicate challenge/goal IDs
- Valid reward types (`ITEM`, `CURRENCY`, `ENTITLEMENT`)
- Prerequisite goals exist in config
- No circular dependencies in prerequisites

**Behavior:** App crashes on startup with detailed error message if validation fails

---

#### 23. Goal Progress Initialization ✅
**Decision:** Lazy initialization on first event

**Implementation:**
- User gets stat event → check if `user_goal_progress` row exists → UPSERT
- No wasted DB rows for inactive users
- Slightly slower first event (extra DB check), but negligible with proper indexing

---

#### 24. Multi-Tenancy Deployment ✅
**Decision:** One app instance per namespace (Extend platform requirement)

**Implications:**
- No `namespace` column needed in DB tables (can add for debugging/portability if desired)
- No `WHERE namespace = ?` in queries
- Simpler cache keys (no namespace prefix)
- Each deployment has isolated DB
- Namespace passed via environment variable `NAMESPACE` (standard Extend convention)

---

#### 25. Reward Grant Retry Strategy ✅
**Decision:** Retry with exponential backoff + jitter (3 retries, 1s base delay)

**Rationale:**
- Network failures common in distributed systems
- Exponential backoff prevents overwhelming downstream services
- Jitter prevents synchronized retry storms

**Config:**
- Default: 3 retries, 1s base delay
- Configurable via `REWARD_GRANT_MAX_RETRIES` env var

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Reward Client Implementation

---

#### 26. Event Schema Versioning ✅
**Decision:** Trust AGS backward compatibility guarantees

- Assume AGS maintains backward compatibility in event schemas
- Use latest event schema version available in AGS docs
- Document which event schema version we're using in README
- If breaking change occurs, update code and redeploy

---

#### 27. Database Connection Pooling ✅
**Decision:** Configurable via environment variables with sensible defaults

**Defaults:** MaxOpenConns: 25, MaxIdleConns: 5, ConnMaxLifetime: 5min

**Environment variables:** `DB_MAX_OPEN_CONNS`, `DB_MAX_IDLE_CONNS`, `DB_CONN_MAX_LIFETIME`

**Tuning notes:**
- Event handler may need higher `MaxOpenConns` for high throughput
- API service typically fine with defaults

**Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

#### 28. Buffer Flush on Shutdown ✅
**Decision:** Flush with 30-second timeout, log on failure

**Crash handling:**
- No disk persistence (Extend limitation)
- Log error with buffer size for monitoring
- Acceptable data loss: ~1 second of events (buffer window)

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md) - Graceful Shutdown

---

#### 29. API Authentication & Authorization ✅
**Decision:** Use Extend template's existing JWT validation

**Key claims:** Extract `userId` from `sub` field, `namespace` from claims

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Authentication & Authorization

---

#### 30. Challenge/Goal ID Strategy ✅
**Decision:** Human-readable IDs in JSON config (kebab-case)

**Rules:**
- Use kebab-case: `winter-challenge-2025`, `kill-10-snowmen`
- Must be unique across all challenges/goals
- Validation on startup catches duplicates

**Rationale:** Easier debugging, logging, and documentation vs UUIDs

---

#### 31. Prerequisite Evaluation Timing ✅
**Decision:** Evaluate prerequisites on API call using in-memory cache

**Approach:**
1. Fetch user's goal progress from DB
2. Load challenges from in-memory cache
3. Filter goals based on prerequisites (in-memory map lookup)

**Performance:** Fast - config cached, simple map lookup, no JOINs

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md)

---

#### 32. Concurrent Event Processing ✅
**Decision:** Use per-user mutex for concurrent event safety

**Approach:** `sync.Map` storing per-user mutexes, acquired during event processing

**Rationale:** Buffering deduplicates most cases, mutex adds safety layer for edge cases

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

---

#### 33. Config Hot Reload ✅
**Decision:** No hot reload - require rebuild and restart

**Rationale:**
- Config changes require rebuild anyway (baked into binary or container)
- Simpler implementation
- No cache invalidation complexity
- Game devs already deploy frequently
- Defer to M2+ if needed

---

#### 34. Error Recovery from Buffer ✅
**Decision:** Log error and retry failed writes

**Behavior:** Failed writes stay in buffer and retry every flush interval (1 sec)

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md) - Error Recovery

---

#### 35. Time Zone Handling ✅
**Decision:** Everything in UTC, no time zone conversions

**Standards:**
- All DB timestamps: `TIMESTAMP` type, UTC
- API responses: ISO 8601 with `Z` suffix (`2025-10-15T10:30:00Z`)
- No time zone conversion logic
- Document in API spec: "All timestamps are in UTC"

---

## Decisions Made ✅

### All Questions Answered (2025-10-15)

#### Additional Decisions - M1 Scope Refinement

**6. Rotation Reset Behavior ✅**
- **Decision:** Hard reset on rotation (progress lost, start fresh next period)
- No carry over, no grace period, no retroactive claims
- Keeps implementation simple for M1

**7. Prerequisites Implementation ✅**
- **Decision:** Goal prerequisites = other completed goals only
- Check on API response: Filter out goals where prerequisite not completed
- No challenge-level prerequisites in M1
- No stat checks, entitlement checks (defer to M5)
- **Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

**8. Localization Strategy ✅**
- **Decision:** No localization support in M1
- Store English text only
- Users can fork and add localization themselves in future

**9. Challenge Versioning ✅**
- **Decision:** Allow admin to modify active challenges with warnings
- Show warning in API docs: "Modifying active challenges may affect user progress"
- No versioning system in M1
- Users responsible for testing changes before deploying

**10. Analytics & Metrics ✅**
- **Decision:** Use Extend template's built-in metrics emitter
- Add minimal metrics for M1 (event processing duration, buffer flush metrics)
- Defer complex analytics to M2+
- **Implementation:** See [TECH_SPEC_OBSERVABILITY.md](./TECH_SPEC_OBSERVABILITY.md)

**11. Admin Portal ✅**
- **Decision:** No admin portal/UI
- Open-source app = game devs modify code directly
- No CRUD API for challenges/goals (config-first, not API-first)
- Users edit config file → build → deploy

**12. Testing Strategy ✅**
- **Decision:**
  - Deploy to real AGS Extend from the start
  - Always test against real AGS services
  - **Unit tests:** Run locally, mock interfaces (`GoalRepository`, `GoalCache`, AGS clients)
  - **Integration tests:** Hit running app (local docker-compose OR deployed in AGS)
  - No need for "fake AGS" mode

**13. Database Migrations ✅**
- **Decision:** Use `golang-migrate` (standard in Go ecosystem)
- Migrations in `migrations/` folder
- Up/down migration files

**14. Error Handling Standards ✅**
- **Decision:** Define own simple error response format
- Structure: `{error: code, message: string, details: object}`
- Extend app is separate microservice, can have own conventions
- **Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Error Responses

**15. Rate Limiting ✅**
- **Decision:** No rate limiting for M1
- AGS gateway may provide rate limiting
- Can add later if needed

**16. Goal Requirement Operators ✅**
- **Decision:** M1 supports `>=` (greater than or equal) only
- Example: "Get at least 10 kills"
- Can add `==`, `<=`, `!=` in future milestones
- **Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

**17. Progress Accumulation Strategy ✅**
- **Decision:** AGS stat events contain **absolute total values** (not deltas)
- Example: User has 10 kills → event: `{statCode: "kills", value: 10}`
- No need to sum/accumulate in our app
- Simply compare: `event.value >= goal.target_value`

**18. Configuration Management ✅**
- **Decision:** Config file-based challenge/goal definitions (not API-managed)
- Challenges and goals defined in YAML/JSON config file
- Game devs edit config → rebuild app → restart service
- **No admin CRUD API** for challenges/goals
- Benefit: No cache refresh problem (restart loads new config)
- Simpler architecture for open-source use case

**19. Challenge Lifecycle States ✅**
- **Decision:** No challenge states/status
- If challenge is in config file → it's active
- Remove challenge from config → rebuild → it's gone
- No `draft`, `paused`, `expired` states in M1

**20. Goal Completion Timestamp ✅**
- **Decision:** Track `completed_at` timestamp in DB
- Expose in API responses for analytics and user history
- **Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

### Critical Questions Answered (Initial Architecture)

#### 1. Multi-Namespace Isolation ✅ (UPDATED)
**Decision:** One deployment per namespace - no multi-namespace handling needed

**Simplified approach:**
- No `WHERE namespace = ?` in queries (optional: keep column for debugging)
- Simple cache keys: `goalsByStatCode["kills"] = [...]`
- Namespace from environment variable `NAMESPACE`
- Each namespace has isolated deployment + DB

---

#### 2. Reward Schema ✅
**Decision:** Single reward per goal (M1 simplicity)

**Schema fields:** goal_id, reward_type (ITEM/WALLET), reward_id, quantity

**M2+:** Can add multiple rewards per goal

**Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

---

#### 3. Event Schema Mapping ✅
**Decision:** Use official AccelByte event schemas

**Documentation:**
- How to listen: https://docs.accelbyte.io/gaming-services/services/extend/event-handler/how-to-listen-and-handle-different-ags-events/#identify-and-download-specific-event-descriptors
- All event schemas: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/achievement/
- Full service list: Available in docs navigation (17+ services with events)

**Expected event sources:**
- `IAM Service` - Login events
- `Statistics Service` - Stat update events
- `Achievement Service` - Achievement unlock events
- `Platform Service` - Entitlement grant events (for prerequisites)

**Implementation:** Download `.proto` files from AGS docs, generate Go code

---

#### 4. Claim Flow - Synchronous with AGS Idempotency ✅
**Decision:** Synchronous API flow - trust AGS Platform Service idempotency

**Flow:**
1. Force flush buffer
2. Begin transaction with row lock (FOR UPDATE)
3. Validate status = 'completed'
4. Call AGS Platform Service
5. Update DB (mark as claimed)
6. Commit transaction

**Error Handling:**
- AGS call succeeds, DB fails → User retries, AGS idempotency prevents double grant
- AGS call fails → Rollback transaction, return 502, user can retry

**Why this works:**
- ✅ AGS Platform Service is idempotent
- ✅ Force flush ensures latest progress visible
- ✅ Row lock prevents concurrent claims
- ✅ Simple - no job queue needed

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Claim Flow

---

#### 5. Assignment Logic ✅
**Decision:** M1 supports **fixed goals only** (no rotation, no randomization)

**M1 Scope:**
- Admin creates challenge with fixed set of goals
- All users see same goals
- No time-based rotation
- No randomization
- Example: "Odyssey of Ascendancy" - 50 fixed goals, complete anytime

**Defer to M3:**
- Daily/weekly rotation (cron scheduler)
- Randomized assignment (pool selection)
- Per-user goal assignment

---

### Implementation Decisions - Round 3 (Final Details)

#### 36. Database Schema - Namespace Column ✅
**Decision:** Keep namespace column for debugging/portability

**Schema:** user_id, goal_id (composite PK), challenge_id, namespace, progress, status, timestamps

**Benefit:** Easier debugging, future-proof for data migration

**Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

#### 37. Config File Location & Loading ✅
**Decision:** JSON file in Docker container, loaded on startup

**Default path:** `/app/config/challenges.json` (configurable via `CONFIG_PATH` env var)

**Deployment:** Config changes require rebuild + redeploy

**Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

---

#### 38. API Endpoints Definition ✅
**Decision:** 7 endpoints for M1

**Player Endpoints:** GET /v1/challenges, GET /v1/challenges/{id}, POST /v1/challenges/{id}/goals/{id}/claim

**Admin Endpoints:** GET /v1/admin/users/{id}/progress, DELETE /v1/admin/users/{id}/progress

**Health:** GET /healthz (liveness probe only)

**Note:** Extend environment only supports `/healthz`. No `/readyz` endpoint.

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md)

---

#### 39. Progress Update Logic ✅
**Decision:** Event handler with cache lookup and buffered write

**Flow:**
1. Acquire per-user lock
2. Find all goals tracking this stat_code (in-memory cache)
3. Check if target reached
4. Update progress via buffered repository
5. Release lock

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

---

#### 40. Multiple Goals Same Stat ✅
**Decision:** Yes, supported (progressive milestones pattern)

**Example:** `kill-10`, `kill-50`, `kill-100` all tracking same `kills` stat

**Behavior:** Single stat event updates all matching goals

---

#### 41. Reward Type Implementation ✅
**Decision:** Support 2 reward types - WALLET (currency) and ITEM (entitlement)

**Fields:**
- WALLET: type, currency_code, amount
- ITEM: type, item_id, quantity

**Implementation:** Use AGS Extend SDK MCP to find correct AccelByte Go SDK functions for wallet credit and item grant

**Reference:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

---

#### 42. Event Handler gRPC Contract ✅
**Decision:** Follow Extend Event Handler template's gRPC interface

**Use template's existing interface for:**
- gRPC service definition
- Message structures
- Event routing
- Error handling

**Note:** Both Service Extension and Event Handler templates have gRPC - follow their patterns

---

#### 43. Goal Progress Table Primary Key ✅
**Decision:** Use composite PK (user_id, goal_id)

**Benefit:** Natural key, enforces one progress per user-goal pair

**Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

#### 44. Challenge and Goal Tables ✅
**Decision:** No DB tables for challenges/goals - config-only

**Architecture:**
- JSON config loaded into memory on startup
- In-memory cache for fast lookups
- DB only stores `user_goal_progress`
- Config is single source of truth

**Benefits:**
- Simpler schema
- No sync complexity
- Faster lookups (no JOINs needed)

---

#### 45. Goal Progress Status Values ✅
**Decision:** Use 4-state model for clarity

**Status constants:**
```go
const (
    StatusNotStarted = "not_started"  // Goal exists but no progress yet (default)
    StatusInProgress = "in_progress"  // User has made progress but not completed
    StatusCompleted  = "completed"    // Target reached, reward not claimed
    StatusClaimed    = "claimed"      // Reward claimed
)
```

**Rationale:**
- More explicit than 3-state model
- Clear distinction between "goal exists but user hasn't started" vs "user has started but not finished"
- Better developer experience when debugging
- Minimal overhead (just one extra string value)

---

#### 46. Error Response Format ✅
**Decision:** Maintain error codes in `internal/errors/codes.go`

**Response format:** `{error: code, message: string, details: object}`

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Error Responses

---

#### 47. Logging Structure ✅
**Decision:** Use Extend template's logger with structured key-value pairs

**Standard fields:** userId, goalId, challengeId, namespace, error, duration

**Implementation:** See [TECH_SPEC_OBSERVABILITY.md](./TECH_SPEC_OBSERVABILITY.md)

---

#### 48. Metrics Labels ✅
**Decision:** Minimal metrics for M1 - event processing duration, buffer flush metrics

**Labels:** eventType, status (success/failure), bufferType (absolute/increment)

**Deferred to M2+:** Goal completion counters, reward claim counters, per-challenge metrics

**Implementation:** See [TECH_SPEC_OBSERVABILITY.md](./TECH_SPEC_OBSERVABILITY.md)

---

#### 49. Database Indexes ✅
**Decision:** Performance-focused indexes from the start

**Indexes:**
- Composite PK on (user_id, goal_id)
- idx_user_goal_progress_user_challenge on (user_id, challenge_id)
- Additional indexes for common query patterns

**Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

#### 50. Config Validation ✅
**Decision:** Use Go struct tags with validator library (`github.com/go-playground/validator/v10`)

**Validations:**
- Required fields (id, name, stat_code, reward, etc.)
- No duplicate challenge/goal IDs
- Prerequisite goals exist in config
- No circular dependencies
- Valid reward types (WALLET, ITEM)
- Valid operators (>= in M1)

**Behavior:** App crashes on startup with detailed error if validation fails

**Implementation:** See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md)

---

### Implementation Decisions - Round 4 (Edge Cases & API Contracts)

#### 51. Orphaned Progress Data ✅
**Decision:** Ignore in API, keep in DB

**Behavior:**
- `GET /v1/challenges`: Filter out progress for goals not in current config
- `POST /claim`: Return 404 "goal_not_found" for removed goals
- Keep orphaned data in DB (not deleted)
- **Note for game devs:** If you remove goals from config, you may want to manually clean up orphaned `user_goal_progress` rows from DB. This app does not auto-delete progress data.

**Benefit:** Supports rollback scenarios, preserves data for analytics

---

#### 52. Config Change During Runtime ✅
**Decision:** Always follow latest config

**Behavior:**
```
Before restart: goal "kill-100-zombies" target=100, user progress=50/100
After restart: goal "kill-100-zombies" target=200
API returns: progress=50/200
```

**Note:** Users may see target changes between sessions. Document this behavior in README.

---

#### 53. Buffer Data Structure ✅
**Decision:** Map-based buffer with periodic flush (1-second interval)

**Structure:**
- Key: `{userId}:{goalId}`
- Value: Latest progress update (deduplication)
- Mutex: `sync.RWMutex` for concurrent access
- Ticker: Periodic flush every 1 second

**Behavior:** Failed writes kept in buffer, retry on next flush

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

---

#### 54. In-Memory Cache Structure ✅
**Decision:** Multi-index map structure for fast lookups

**Indexes:**
- All challenges (for GET /v1/challenges)
- Challenges by ID (for GET /v1/challenges/{id})
- Goals by ID (for validation)
- Goals by stat_code (for event processing)

**Concurrency:** `sync.RWMutex` for thread-safe access

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

---

#### 55. UPSERT Query ✅
**Decision:** PostgreSQL UPSERT with claimed status protection

**Key features:**
- ON CONFLICT (user_id, goal_id) DO UPDATE
- WHERE clause: `status != 'claimed'` prevents overwriting claimed goals

**Protection:** Events cannot overwrite claimed status

**Implementation:** See [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md)

---

#### 56. Claim Flow Implementation ✅
**Decision:** Force flush + transaction flow via repository interfaces

**Flow:**
1. Force flush buffer
2. Begin transaction
3. Get progress with lock (SELECT FOR UPDATE)
4. Validate status
5. Get reward details from cache
6. Grant reward via AGS client interface
7. Mark as claimed
8. Commit transaction

**Key principle:** All DB access via `GoalRepository` interface, never direct `*sql.DB` access

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Claim Flow

---

#### 57. API Response Schema ✅
**Decision:** Nested JSON format with challenge → goals → progress structure

**Key fields:**
- Challenge: id, name, description, goals[]
- Goal: id, name, requirement, reward, prerequisites, locked, progress
- Progress: current, target, status, completed_at, claimed_at

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md)

---

#### 58. Prerequisites - Locked Goals ✅
**Decision:** Include locked goals with `locked: true` flag in API responses

**Benefit:** Better UX - players can see what's coming next

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md)

---

#### 59. Admin Endpoint Authorization ✅
**Decision:** Use Extend template's JWT permission checker

**Approach:**
- Define required permissions in protobuf annotations
- Admin endpoints require specific permissions (e.g., CHALLENGE:DELETE)
- Template's middleware validates JWT claims

**Implementation:** See [TECH_SPEC_API.md](./TECH_SPEC_API.md) - Admin Endpoints

---

#### 60. Database Migration Files ✅
**Decision:** Approved - golang-migrate structure

**File structure:**
```
migrations/
├── 000001_create_user_goal_progress.up.sql
├── 000001_create_user_goal_progress.down.sql
└── README.md
```

**Migration content confirmed** (see previous proposal)

---

### Implementation Decisions - Round 5 (Project Structure & Tooling)

#### 61. Project Folder Structure ✅
**Decision:** 3 separate projects - follow AccelByte Extend template structure

**Structure:**
```
extend-challenge/                           # Workspace root
├── docs/
│   ├── BRAINSTORM.md
│   └── ...
├── extend-challenge-service/               # Service Extension (REST API)
│   ├── [Follow extend-service-extension-go template structure]
│   ├── Dockerfile
│   ├── Makefile                            # From template
│   ├── go.mod
│   └── README.md
├── extend-challenge-event-handler/         # Event Handler (gRPC)
│   ├── [Follow extend-event-handler-go template structure]
│   ├── Dockerfile
│   ├── Makefile                            # From template
│   ├── go.mod
│   └── README.md
├── extend-challenge-common/                # Shared code
│   ├── pkg/
│   │   ├── config/                         # Config loading & validation
│   │   ├── domain/                         # Domain models
│   │   ├── repository/                     # Repository interfaces
│   │   ├── cache/                          # Cache interfaces
│   │   └── client/                         # AGS client interfaces
│   ├── go.mod
│   └── README.md
├── docker-compose.yml                      # Local development
└── README.md                               # Workspace README
```

**Key points:**
- Follow template structure from GitHub repos
- `extend-challenge-common` imported by both service and event handler
- Each project has own `go.mod`

**Template repos:**
- Service Extension: `https://github.com/AccelByte/extend-service-extension-go`
- Event Handler: `https://github.com/AccelByte/extend-event-handler-go`

#### 62. Core Interface Definitions ✅
**Decision:** Approved - interfaces defined in `extend-challenge-common/pkg`

**Interfaces confirmed:**
- `GoalRepository` - Progress operations, transactions, buffered flush
- `GoalCache` - Config loading, lookups by ID/stat_code, prerequisite checks
- `RewardClient` - Reward granting (wallet & item)

**Location:** `extend-challenge-common/pkg/repository/interfaces.go`, `pkg/cache/interfaces.go`, `pkg/client/interfaces.go`

---

#### 63. Environment Variables ✅
**Decision:** Approved - standard AGS Extend environment variables

**Key variables:**
- `NAMESPACE` - Deployment namespace
- `DB_*` - PostgreSQL connection settings
- `CONFIG_PATH` - Path to challenges.json
- `AGS_*` - AGS service credentials
- `BUFFER_FLUSH_INTERVAL` - Flush interval (default: 1s)
- `REWARD_GRANT_MAX_RETRIES` - Retry count (default: 3)

---

#### 64. Example Config File ✅
**Decision:** Approved - 2 challenges, 6 goals with prerequisites

**Example includes:**
- Winter Challenge: 4 goals (tutorial, snowmen milestones, snowflake collection)
- Daily Missions: 2 goals (login, win matches)
- Both WALLET and ITEM reward types
- Goal prerequisites demonstrated

---

#### 65. Code Sharing Strategy ✅
**Decision:** Separate shared module `extend-challenge-common`

**Structure:**
```
extend-challenge-common/
├── pkg/
│   ├── config/       # Config loading & validation
│   ├── domain/       # Challenge, Goal, Progress models
│   ├── repository/   # GoalRepository interface
│   ├── cache/        # GoalCache interface
│   └── client/       # RewardClient interface
├── go.mod
└── README.md
```

**Import in service & event handler:**
```go
import "github.com/yourgame/extend-challenge-common/pkg/domain"
```

---

#### 66. Unit Test Structure ✅
**Decision:** Approved - mock-based testing with testify

**Structure:**
```
internal/service/challenge_service_test.go
internal/repository/buffered_repository_test.go
internal/cache/goal_cache_test.go
internal/handler/challenge_handler_test.go
```

**Mocking:** Use testify/mock for interface mocks

---

#### 67. Integration Test Setup ✅
**Decision:** docker-compose to start services, configurable test suite

**Approach:**
1. Start services with `docker-compose up`
2. Test suite with configurable URL (env var `TEST_API_URL`)
3. Can point to:
   - Local: `http://localhost:8080`
   - Deployed: `https://your-namespace.extend.accelbyte.io`

**Benefits:** Same test suite works for local and deployed environments

---

#### 68. Docker Configuration ✅
**Decision:** Minimize changes from Extend template Dockerfile

**Key points:**
- Follow template's multi-stage build pattern
- Only modify if necessary for challenges.json config
- Keep template's best practices intact

---

#### 69. README Content ✅
**Decision:** Combine template README with challenge-specific content

**Structure:**
- Use template's README structure as base
- Add challenge-specific sections:
  - challenges.json configuration guide
  - M1 scope and limitations
  - Forking and customization guide
- **Keep template's Extend deployment section** (most important)

---

#### 70. Makefile Targets ✅
**Decision:** Use template Makefile as-is, add minimal customizations

**Additions:**
- `make test` - Run unit tests
- Document `docker-compose up` for local development (not in Makefile)

**Keep from template:**
- All existing build, deploy, lint targets
- Template's deployment commands for AGS Extend

---

## Summary: ALL 70 Decisions Complete - Ready for Implementation ✅

### Brainstorming Complete!
**Total decisions documented:** 70
**Rounds completed:** 5
**Outstanding questions:** 0

---

### Core Architecture (Decisions 1-20)
1. ✅ Two Extend apps: Service Extension (REST API) + Event Handler (gRPC)
2. ✅ Event-driven: Consume AGS stat events, no API calls for player operations
3. ✅ PostgreSQL + in-memory cache: Typed schema, interface-driven, no JOINs
4. ✅ Buffering: 1 sec flush, 1000x DB load reduction
5. ✅ Config-first: JSON file, no admin CRUD API
6. ✅ Single-namespace deployment: Per-namespace isolation
7. ✅ Single reward per goal: WALLET or ITEM types
8. ✅ Synchronous claim: Trust AGS idempotency
9. ✅ Fixed goals only: No rotation in M1
10. ✅ Goal prerequisites: Other completed goals only

### M1 Scope Decisions (Decisions 21-35)
11. ✅ JSON config with human-readable IDs
12. ✅ Fail-fast validation on startup
13. ✅ Lazy progress initialization
14. ✅ Retry with exponential backoff + jitter
15. ✅ Trust AGS backward compatibility
16. ✅ Configurable DB connection pooling
17. ✅ 30s shutdown timeout with flush
18. ✅ Use Extend template JWT validation
19. ✅ Per-user mutex for concurrent events
20. ✅ No config hot reload

### Database & API Design (Decisions 36-50)
21. ✅ Keep namespace column for debugging
22. ✅ JSON file in Docker container
23. ✅ 7 API endpoints (player + admin + health)
24. ✅ Event handler logic confirmed
25. ✅ Multiple goals can track same stat
26. ✅ 2 reward types: wallet + item
27. ✅ Follow Extend template gRPC patterns
28. ✅ Composite PK (user_id, goal_id)
29. ✅ No challenge/goal DB tables (config-only)
30. ✅ 4-state model (not_started, in_progress, completed, claimed)

### Edge Cases & Contracts (Decisions 51-60)
31. ✅ Ignore orphaned progress in API, keep in DB
32. ✅ Always follow latest config
33. ✅ Map-based buffer with periodic flush
34. ✅ Multi-index cache structure
35. ✅ UPSERT with claimed status protection
36. ✅ Force flush + transaction via interfaces
37. ✅ Nested JSON API response format
38. ✅ Include locked goals with flag
39. ✅ Use Extend template permission checker
40. ✅ golang-migrate structure

### Project Structure & Tooling (Decisions 61-70)
41. ✅ 3 projects: service + event-handler + common
42. ✅ Interfaces in extend-challenge-common
43. ✅ Standard AGS Extend env variables
44. ✅ Example config with 2 challenges, 6 goals
45. ✅ Shared module for common code
46. ✅ Mock-based unit tests with testify
47. ✅ docker-compose with configurable test URL
48. ✅ Minimize changes to template Dockerfile
49. ✅ Combine template README with challenge docs
50. ✅ Use template Makefile, add `make test`

---

## Next Steps - Ready for M1 Technical Specification ✅

### Phase 1: Write M1 Technical Specification
**Document to create:** `docs/TECH_SPEC_M1.md`

**Contents:**
1. **Architecture Overview**
   - System diagram (3 components: service, event-handler, common)
   - Data flow diagrams
   - Deployment architecture

2. **Database Schema**
   - Complete `user_goal_progress` table definition
   - All indexes (4 total)
   - Migration files (up/down SQL)

3. **API Specification**
   - Full OpenAPI 3.0 spec
   - Request/response examples
   - Error codes catalog

4. **Config File Schema**
   - JSON Schema for challenges.json
   - Validation rules
   - Complete examples

5. **Interface Contracts**
   - GoalRepository interface (10 methods)
   - GoalCache interface (5 methods)
   - RewardClient interface (3 methods)

6. **Event Processing Flow**
   - gRPC event handler sequence
   - Buffering mechanism
   - Cache lookup patterns

7. **Claim Flow Implementation**
   - Transaction sequence
   - AGS integration
   - Error handling

8. **Development Setup**
   - Prerequisites
   - docker-compose configuration
   - Local testing guide

9. **Deployment Guide**
   - AGS Extend deployment steps
   - Environment configuration
   - Monitoring setup

### Phase 2: Project Setup
1. Clone Extend templates
2. Create extend-challenge-common module
3. Set up docker-compose.yml
4. Create initial challenges.json

### Phase 3: Implementation (TDD)
1. **Week 1:** Interfaces + Config + Cache
2. **Week 2:** Repository + Buffering
3. **Week 3:** Event Handler
4. **Week 4:** REST API + Claim Flow
5. **Week 5:** Testing + Integration
6. **Week 6:** Documentation + Deployment

---

## Readiness Checklist

- ✅ All architectural decisions made (70/70)
- ✅ Technology stack finalized
- ✅ Database schema designed
- ✅ API contracts defined
- ✅ Project structure planned
- ✅ Testing strategy established
- ✅ Deployment approach confirmed

**Status:** ✅ READY FOR IMPLEMENTATION - All 70 decisions finalized, 1 discrepancy resolved

---

## ✅ Resolved Question (2025-10-15)

### Question 71: Status State Machine - RESOLVED ✅

**Resolution:** Use **4-state model** throughout all specs

**Final Decision:**
- States: `not_started` (default) → `in_progress` → `completed` → `claimed`
- Updated Decision #45 in BRAINSTORM.md to reflect 4-state model
- All specs now consistent (TECH_SPEC_DATABASE.md, CLAUDE.md, BRAINSTORM.md)

**Rationale:**
- More explicit and clearer semantics
- Better developer experience when debugging
- Minimal overhead (just one extra string value)
- Already implemented in database schema

---

## References

**AccelByte Documentation:**
- Extend Service Extension: https://github.com/AccelByte/extend-service-extension-go
- Extend Event Handler: https://github.com/AccelByte/extend-event-handler-go
- AGS Event Schemas: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/
- Platform Service API: https://docs.accelbyte.io/api/platform/

**Project Documents:**
- Product Requirements: `docs/[Engagement] PRD - Challenge Service.docx.pdf`
- This Brainstorm: `docs/BRAINSTORM.md`
- Technical Specs: `docs/TECH_SPEC_M1.md` and detailed specs (created)

---

## Phase 1.5 Learnings: Template Architecture Deep Dive ✅

**Date Completed:** 2025-10-16
**Status:** Complete

### Overview
Studied both AccelByte Extend templates to understand their architecture patterns before implementing custom challenge logic.

---

### Service Extension Template (`extend-challenge-service`)

#### REST API Architecture Pattern

**Key Discovery:** Uses **protobuf-first approach** with gRPC Gateway for HTTP/REST

**Architecture Flow:**
```
.proto files → protoc code generation → gRPC service → gRPC-Gateway → HTTP/REST API
```

**Components:**
1. **Proto Definitions** (`pkg/proto/service.proto`)
   - gRPC service methods with Google API annotations
   - Maps gRPC to HTTP routes: `option (google.api.http) = { post: "/v1/..." }`
   - Permission annotations: `option (permission.action) = CREATE`
   - OpenAPI annotations for documentation

2. **Code Generation** (`proto.sh` + Makefile)
   - Docker-based protoc execution (consistent environment)
   - Generates: Go gRPC stubs, gRPC-Gateway code, OpenAPI/Swagger JSON
   - Output: `pkg/pb/` (Go code), `gateway/apidocs/` (Swagger)

3. **Server Architecture**
   - **gRPC server** (port 6565) - Core service implementation
   - **gRPC-Gateway HTTP server** (port 8000) - Auto-translates HTTP → gRPC
   - **Prometheus metrics** (port 8080) - `/metrics` endpoint
   - **Swagger UI** - Served at `{basePath}/apidocs/`

4. **Authentication & Authorization**
   - JWT validation via interceptors
   - Permission checking against proto annotations
   - Token validator with auto-refresh (configurable interval)
   - Extracts `userId` and `namespace` from JWT claims

5. **Multi-Stage Dockerfile**
   ```
   Stage 1: Proto generation (protoc container)
   Stage 2: Go build (golang:1.24-alpine)
   Stage 3: Runtime (alpine:3.22 with minimal deps)
   ```

**Example Proto Pattern:**
```protobuf
service Service {
  rpc CreateOrUpdateGuildProgress (Request) returns (Response) {
    option (permission.action) = CREATE;
    option (permission.resource) = "ADMIN:NAMESPACE:{namespace}:CLOUDSAVE:RECORD";
    option (google.api.http) = {
      post: "/v1/admin/namespace/{namespace}/progress"
      body: "*"
    };
  }
}
```

---

### Event Handler Template (`extend-challenge-event-handler`)

#### Event Processing Architecture Pattern

**Key Discovery:** AGS **abstracts Kafka completely** - we only implement gRPC handlers

**Architecture Flow:**
```
AGS Kafka → Extend Platform → gRPC call → Our OnMessage handler
```

**Components:**
1. **Event Proto Definitions** (`pkg/proto/accelbyte-asyncapi/`)
   - Downloaded from AGS documentation
   - IAM events: `iam/account/v1/account.proto`
   - Each event type has its own gRPC service
   - Example: `UserAuthenticationUserLoggedInService`

2. **Event Schema Structure**
   - Standard event wrapper fields: `id`, `version`, `name`, `namespace`, `timestamp`, `userId`, `traceId`
   - Typed payload: `message UserLoggedIn` with specific fields
   - OneOf pattern for channels with multiple event types

3. **Handler Implementation Pattern**
   ```go
   type LoginHandler struct {
       pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
       fulfillment platform.FulfillmentService
   }

   func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
       // Process event
       // Call AGS SDK services if needed
       return &emptypb.Empty{}, nil
   }
   ```

4. **AGS SDK Integration**
   - Template shows Platform Service usage: `FulfillItemShort`
   - Client creation: `factory.NewPlatformClient(configRepo)`
   - OAuth login: `oauthService.LoginClient(&clientId, &clientSecret)`

5. **gRPC Service Registration**
   ```go
   pb.RegisterUserAuthenticationUserLoggedInServiceServer(s, loginHandler)
   reflection.Register(s)  // For debugging
   grpc_health_v1.RegisterHealthServer(s, health.NewServer())
   ```

**Event Proto Example:**
```protobuf
message UserLoggedIn {
    AnonymousSchema19 payload = 1 [json_name = "payload"];  // Contains user_account + user_authentication
    string id = 2;
    string namespace = 5;
    string user_id = 9;
    string timestamp = 7;
    // ... standard event fields
}

service UserAuthenticationUserLoggedInService {
    rpc OnMessage(UserLoggedIn) returns (google.protobuf.Empty);
}
```

---

### Build & Deployment Patterns

#### Makefile Structure (Both Templates)
```makefile
.PHONY: proto build

proto:
    docker run --rm --user $(id -u):$(id -g) \
        --volume $(pwd):/build \
        rvolosatovs/protoc:4.1.0 \
        proto.sh

build: proto
```

**Key Points:**
- Minimal targets (keep template simple)
- Proto generation always runs before build
- Docker-based protoc ensures consistency

#### Dockerfile Patterns (Both Templates)
```dockerfile
# Stage 1: Proto generation
FROM rvolosatovs/protoc:4.1.0 AS proto-builder
COPY proto.sh .
COPY pkg/proto/ pkg/proto/
RUN chmod +x proto.sh && ./proto.sh

# Stage 2: Go build
FROM golang:1.24-alpine3.22 AS builder
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=proto-builder /build/pkg/pb pkg/pb
RUN go build -o service

# Stage 3: Runtime
FROM alpine:3.22
COPY --from=proto-builder /build/gateway/apidocs gateway/apidocs
COPY --from=builder /build/service service
EXPOSE 6565 8000 8080
CMD ["/app/service"]
```

**Pattern Benefits:**
- Reproducible builds (same protoc version)
- Optimized layer caching
- Minimal runtime image size

#### docker-compose Patterns
Both templates have `docker-compose.yaml` for local testing. Pattern:
```yaml
services:
  service:
    build: .
    ports:
      - "6565:6565"  # gRPC
      - "8000:8000"  # HTTP Gateway
      - "8080:8080"  # Metrics
    environment:
      - AB_CLIENT_ID=${AB_CLIENT_ID}
      - AB_CLIENT_SECRET=${AB_CLIENT_SECRET}
      - AB_BASE_URL=${AB_BASE_URL}
      - AB_NAMESPACE=${AB_NAMESPACE}
```

---

### Integration Test Strategy Decision ✅

**Chosen Approach: Hybrid docker-compose Strategy**

**Architecture:**
```
Root Level (extend-challenge/):
└── docker-compose.yml           # Full integration testing
    ├── postgres (shared)
    ├── redis (shared)
    ├── challenge-service
    └── challenge-event-handler

Template Level:
├── extend-challenge-service/
│   └── docker-compose.yaml      # Standalone service development
└── extend-challenge-event-handler/
    └── docker-compose.yaml      # Standalone event handler development
```

**Benefits:**
1. **Root-level compose**: Full system integration tests (both services + DB + Redis)
2. **Template compose**: Independent service development/testing
3. **Flexibility**: Developers can work on one service OR test full system
4. **Template compatibility**: Keep template files for reference/updates

**Test Strategy:**
```bash
# Unit tests (local, mocked)
make test

# Integration tests - option 1: Local full system
docker-compose up -d  # In root directory
go test ./test/integration/...

# Integration tests - option 2: Deployed to AGS
TEST_API_URL=https://namespace.extend.accelbyte.io go test ./test/integration/...
```

---

### Critical Implementation Notes for Challenge Service

#### 1. Proto Structure for Challenge Service

**Recommended structure:**
```
pkg/proto/
├── service.proto                    # Our challenge API
├── permission.proto                 # From template
├── google/api/annotations.proto     # From template
├── google/api/http.proto            # From template
└── protoc-gen-openapiv2/...        # From template
```

**Our service.proto will define:**
```protobuf
service ChallengeService {
  // GET /v1/challenges
  rpc ListChallenges (ListChallengesRequest) returns (ListChallengesResponse) {
    option (google.api.http) = { get: "/v1/challenges" };
  }

  // POST /v1/challenges/{challenge_id}/goals/{goal_id}/claim
  rpc ClaimReward (ClaimRewardRequest) returns (ClaimRewardResponse) {
    option (google.api.http) = {
      post: "/v1/challenges/{challenge_id}/goals/{goal_id}/claim"
      body: "*"
    };
  }
}
```

#### 2. Event Handler Proto Structure

**Download from AGS:**
- IAM events: For login-based challenges
- Statistic events: For progress tracking
- Location: `pkg/proto/accelbyte-asyncapi/`

**Implement services:**
```go
// For login events
pb.RegisterUserAuthenticationUserLoggedInServiceServer(s, loginHandler)

// For stat events (need to find correct proto)
// pb.RegisterStatisticUpdatedServiceServer(s, statHandler)
```

#### 3. Statistic Event Research Needed 🔍

**Question for implementation phase:**
We need to find the correct proto definition for "statistic updated" events.

**Resources:**
- AGS Event Docs: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/
- Look for: `social.statistic.v1.statItemUpdated` or similar
- Download proto from: https://github.com/AccelByte/accelbyte-api-proto

---

### Questions & Considerations

#### Questions to Address in Implementation

1. **Statistic Event Proto** 🔍
   Where is the proto definition for statistic update events?
   Expected path: `pkg/proto/accelbyte-asyncapi/social/statistic/v1/statistic.proto`

2. **Base Path Configuration**
   Template uses `common.GetBasePath()` - understand this for our API routing
   Likely from env var: `OTEL_SERVICE_NAME` or similar

3. **Config File in Docker**
   How to mount `challenges.json` - likely `COPY challenges.json /app/config/` in Dockerfile

---

### Key Takeaways for Implementation

1. **Follow Template Patterns Religiously**
   - Don't reinvent auth, metrics, logging - use what's there
   - Only modify `service.proto` and business logic

2. **Proto-First Development**
   - Define API in proto → generate code → implement handlers
   - Never write HTTP handlers manually

3. **Event Handler is Simple**
   - Just implement `OnMessage(context.Context, *Event) (*emptypb.Empty, error)`
   - Platform handles all Kafka complexity

4. **Testing Strategy**
   - Mock interfaces for unit tests
   - Use docker-compose for integration tests
   - Can test against real AGS deployment

5. **Keep Templates Updated**
   - Minimal modifications to template files
   - Easy to pull upstream updates

---

### Action Items for Next Phase

1. ✅ Document findings (this section)
2. ⏭️  Update STATUS.md with Phase 1.5 completion
3. ⏭️  Research statistic event proto location
4. ⏭️  Start Phase 2: Domain & Interfaces implementation

---

**Phase 1.5 Status:** ✅ COMPLETE
**Next Phase:** Phase 2 - Domain & Interfaces

---

## Phase 1.5.1: Spec Update Questions & Clarifications 🔍

**Date Started:** 2025-10-16
**Context:** Updating TECH_SPEC_API.md, TECH_SPEC_EVENT_PROCESSING.md, TECH_SPEC_DEPLOYMENT.md based on Phase 1.5 findings

### Questions for User ✅ ANSWERED

#### Q1: JWT User ID Extraction ✅
**Question:** How do we extract `userId` from context in gRPC handlers?
**Answer:** We need to modify `pkg/common/authServerInterceptor.go` to inject token claims into context.

**Implementation approach:**
1. After `Validator.Validate()` succeeds, the validator's `JwtClaims` field contains user token claims
2. **Problem:** `Validator` is currently stored as `validator.AuthTokenValidator` interface, not concrete `iam.TokenValidator`
3. **Solution:** Change `Validator` from interface to concrete type `*iam.TokenValidator` to access `JwtClaims`
4. In `checkAuthorizationMetadata()`, after validation, inject claims into context:
   ```go
   // After Validator.Validate() succeeds
   claims := Validator.JwtClaims
   ctx = context.WithValue(ctx, "userId", claims.Subject)
   ctx = context.WithValue(ctx, "namespace", claims.Namespace)
   ```
5. Create helper: `func GetUserIDFromContext(ctx context.Context) string`

**Files to modify:**
- `pkg/common/authServerInterceptor.go` - Change Validator type, inject claims
- `pkg/common/context_helpers.go` - New file with `GetUserIDFromContext()`, `GetNamespaceFromContext()`

#### Q2: JWT Auth Interceptor Configuration ✅
**Question:** Is the JWT validation interceptor already provided by the template?
**Answer:** Yes, `pkg/common/authServerInterceptor.go` is provided by template, but we need to modify it (same modifications as Q1).

**What template provides:**
- JWT validation interceptor (`NewUnaryAuthServerIntercept`, `NewStreamAuthServerIntercept`)
- Permission extraction from proto annotations
- Token validator initialization

**What we need to add:**
- Context injection after successful validation
- Helper functions to extract claims from context

#### Q3: Domain-to-Proto Mapping ✅
**Question:** Do we need to implement domain-to-proto conversion functions manually?
**Answer:** Yes, all mappers need to be implemented ourselves.

**Implementation plan:**
- Location: `internal/mapper/` package
- Files:
  - `challenge_mapper.go` - `mapChallengesToProto()`, `mapChallengeToProto()`
  - `goal_mapper.go` - `mapGoalToProto()`
  - `reward_mapper.go` - `mapRewardToProto()`
  - `progress_mapper.go` - `mapProgressToProto()`

#### Q4: Statistic Event Proto Location ✅
**Status:** Confirmed correct
**Location:** `social/statistic/v1/statistic.proto` from AccelByte proto repo

---

### Spec Update Results ✅

**Date Completed:** 2025-10-16
**All three spec files successfully updated with Phase 1.5 findings.**

#### TECH_SPEC_API.md Updates
- ✅ Removed Phase 1.5 warning section
- ✅ Added protobuf-first architecture overview
- ✅ Documented 3-port server architecture (gRPC 6565, HTTP 8000, Metrics 8080)
- ✅ Added complete proto service definition examples
- ✅ Added gRPC handler implementation pattern
- ✅ Documented code generation workflow (proto.sh)
- ✅ Replaced manual HTTP handler examples with gRPC Gateway approach

#### TECH_SPEC_EVENT_PROCESSING.md Updates
- ✅ Removed Phase 1.5 warning section
- ✅ Added OnMessage pattern documentation
- ✅ Documented event proto download and generation process
- ✅ Added separate handler examples for IAM login and Statistic events
- ✅ Documented gRPC service registration in main.go
- ✅ Clarified Kafka abstraction by Extend platform
- ✅ Updated event schema references with proto examples

#### TECH_SPEC_DEPLOYMENT.md Updates
- ✅ Removed Phase 1.5 warning section
- ✅ Documented hybrid docker-compose strategy decision
- ✅ Added 3-stage Dockerfile pattern (proto generation → build → runtime)
- ✅ Documented Makefile patterns from templates
- ✅ Updated local testing workflow for event handlers (direct gRPC calls)
- ✅ Added integration testing strategy
- ✅ Clarified architecture comparison (production vs local dev)

---

### Required Template Modifications 📝

Based on Q&A above, 4 template modifications are required to inject JWT claims into context for user ID extraction.

**See:** [TECH_SPEC_API.md](./TECH_SPEC_API.md) - "Required Template Modifications for JWT Context" section for complete implementation details.

**Summary of changes:**
1. Change Validator type from interface to `*iam.TokenValidator` (authServerInterceptor.go)
2. Modify `checkAuthorizationMetadata()` to inject claims into context (authServerInterceptor.go)
3. Create `context_helpers.go` with `GetUserIDFromContext()` and `GetNamespaceFromContext()` (new file)
4. Update main.go Validator initialization to return concrete type

---

**Phase 1.5.1 Status:** ✅ COMPLETE
**Phase 1.5.2 Status:** ✅ COMPLETE (Q&A + Template Modifications Documented)
**Phase 1.5.3 Status:** ✅ COMPLETE (Specs Updated with Template Modifications)
**Ready for:** Phase 2 - Domain & Interfaces Implementation

---

## Phase 6: REST API Implementation - Design Decisions ✅

**Date:** 2025-10-18
**Status:** All decisions finalized, documented in specs
**Context:** REST API with protobuf-first approach, business logic, and AGS integration

---

### Phase 6 Decisions Summary (11 Total)

| # | Topic | Decision | Rationale |
|---|-------|----------|-----------|
| **Q1** | **Protobuf Service** | Option C: Rename template's `Service`, replace methods | Moderate template adherence, no unused code |
| **Q2** | **Mapper Location** | Option A: `pkg/mapper/` package with pure functions | Clean separation, validate and fail early, return errors |
| **Q2a-c** | **Mapper Pattern** | Pure functions, validate early, return errors | Simplicity, testability |
| **Q3** | **Transaction Scope** | AGS call INSIDE transaction (M1) | Simplicity over scalability for M1 |
| **Q3a-c** | **Transaction Timeout** | 10s context timeout, retry AGS call only, limit retries to <10s total | Best practice, avoid connection exhaustion |
| **Q4** | **Force Flush** | Option D: Accept eventual consistency, client retries in 1s | Simple, no inter-service communication |
| **Q5** | **Service Architecture** | Option C: Single service + helpers (`claim_flow.go`, `progress_query.go`) | Balance simplicity and organization |
| **Q5a-c** | **Service Responsibilities** | Service owns transaction+AGS, separate validator, separate ProgressService/file | Clear boundaries, testable |
| **Q6** | **Error Handling** | Custom error types in handler layer, include details for NotFound/validation | Structured logging, better debugging |
| **Q7** | **Prerequisites** | Option C: Separate `PrerequisiteChecker`, cache in memory, trust flag in claim | Testable, reusable, config validation catches circular deps |
| **Q8** | **Reward Testing** | Mock only, no env switching, log with proper levels | Simple, sufficient for M1 |
| **Q9** | **Daily Progress** | Use DB data as-is, no mutation, always UTC | Trust DB, avoid data modification |
| **Q10** | **DB Connection** | Shared package `extend-challenge-common/pkg/db/`, same pool settings (25/5), health check | DRY, consistency, health monitoring |
| **Q11** | **OpenAPI Docs** | Title: "AccelByte Challenge Service API", base_path: "/v1", detailed descriptions | Professional, clear documentation |

### Implementation Order

1. ✅ Update proto file (Q1, Q11)
2. ✅ Add shared DB init package (Q10)
3. ⏭️ Implement mapper package (Q2)
4. ⏭️ Implement service layer + helpers (Q5)
5. ⏭️ Implement prerequisite checker (Q7)
6. ⏭️ Implement claim flow with transaction (Q3, Q4)
7. ⏭️ Add error types + mapping (Q6)
8. ⏭️ Test with mocks (Q8)

### Specs Updated

- ✅ **TECH_SPEC_API.md**: Phase 6 decisions section, proto definition, claim flow, error message
- ✅ **TECH_SPEC_DATABASE.md**: Shared DB init package section with code examples

---

### Phase 6 Follow-up Questions & Decisions ✅

**Date:** 2025-10-18
**Status:** All 5 follow-up questions answered

| # | Topic | Decision | Implementation |
|---|-------|----------|----------------|
| **FQ1** | **AGS Retry Timing** | Option B: 500ms base delay | 3 retries with 500ms base = ~3.5s delays + 4-8s AGS calls = 7.5-11.5s (fits in 10s timeout) |
| **FQ2** | **Daily Progress Computation** | Yes, computation in mapper | Mapper derives `progress` value from `completed_at` timestamp, no domain mutation |
| **FQ3** | **Progress Service Structure** | Option B: Separate file with helpers | `progress_query.go` with helper functions, not separate service class |
| **FQ4** | **Prerequisite Cache Scope** | Option A: Per-request map | Simple function-scoped map from userProgress for O(1) lookups, not persistent cache |
| **FQ5** | **Health Check Protocol** | Both HTTP and gRPC | HTTP `/healthz` verifies DB connectivity, gRPC health for service mesh |

**Specs Updated:**
- ✅ TECH_SPEC_API.md - Retry config, health check, prerequisite checking, daily progress computation
- ✅ TECH_SPEC_CONFIGURATION.md - REWARD_GRANT_BASE_DELAY = 500ms
- ✅ All FQ decisions documented inline in Phase 6 sections

**Status:** Ready for Phase 6 implementation

---

## Phase 5.2: Login Event Handler Design Decision 🔍

**Date:** 2025-10-17
**Context:** How to handle login events (binary) in a system designed for stat values (numeric)?

**Problem:** Login events are boolean ("user logged in"), but EventProcessor expects numeric stat values.

### Initial Exploration: Counter-Based Approaches (Options A-D)

**Explored 4 approaches for treating login as a countable stat:**

| Option | Approach | Verdict | Reason |
|--------|----------|---------|--------|
| A | Each login = value 1 | ❌ Rejected | Doesn't match absolute value pattern, "Login 5 times" would never work |
| B | DB counter (read-increment-write) | ❌ Rejected | Requires DB read per event, defeats buffering |
| C | In-memory counter (lazy-loaded) | ⚠️ Complex | Requires state management, lost on restart |
| D | Separate code path (no buffering) | ❌ Rejected | Abandons buffering benefit |

**Initial recommendation:** Option C (in-memory counter) - but adds complexity with state management

---

### Alternative Exploration: Date-Based Tracking (Options 1-4)

**User insight:** Instead of counting, track login DATE for simpler claim validation.

**Explored 4 date-based approaches:**

| Option | Approach | Supports Count | Supports Daily | Schema Change | Complexity |
|--------|----------|----------------|----------------|---------------|------------|
| 1 | Store date as integer in `progress` | ❌ No | ✅ Yes | None | Low |
| 2 | Add `last_login_date` column | ✅ Yes | ✅ Yes | Migration | Medium |
| 3 | Reuse `completed_at` for date | ⚠️ Hacky | ✅ Yes | None | Medium |
| 4 | M1: Daily login only | ❌ No | ✅ Yes | None | Very Low |

**Recommendation:** Option 4 for M1 (daily login only), defer counting to M2.

---

### Final Design: Explicit Goal Types (Option 5) ✅

**User insight:** "Make a new goal type where we can explicitly call 'increment' interface to the repo, and the SQL query explicitly increment the progress by an input number"

**Key Concepts:**

1. **Three Goal Types:**
   - `absolute`: Stat value is absolute (e.g., kills=100) → Replace progress with stat value
   - `increment`: Each event increments by 1 (e.g., login count) → Atomic DB increment: `progress = progress + delta`
   - `daily`: Check if event occurred today (e.g., daily login) → Store `completed_at` timestamp

2. **Repository Interface:**
   - Existing: `UpdateProgress(progress)` - for absolute/daily goals
   - NEW: `IncrementProgress(userId, goalId, delta)` - for increment goals

3. **BufferedRepository Behavior:**
   - Absolute/daily: Last value wins (deduplication)
   - Increment: Accumulates deltas (3 login events → single query with delta=3)

4. **Atomic DB Increment:**
   ```sql
   ON CONFLICT (user_id, goal_id) DO UPDATE SET
       progress = user_goal_progress.progress + $delta  -- Atomic!
   ```

5. **EventProcessor Routing:**
   - Routes events to different repository methods based on `goal.Type`
   - Switch statement: `absolute` → `UpdateProgress()`, `increment` → `IncrementProgress()`, `daily` → `UpdateProgress()`

6. **Config Examples:**
   ```json
   {"id": "kill-100", "type": "absolute", "stat_code": "kills", "target": 100}
   {"id": "login-5-times", "type": "increment", "stat_code": "login_count", "target": 5}
   {"id": "daily-login", "type": "daily", "stat_code": "login_daily", "target": 1}
   ```

**Benefits:**
- ✅ **Type Safety**: Explicit goal types prevent misuse
- ✅ **Performance**: Atomic increments avoid read-modify-write races
- ✅ **Correctness**: Daily goals use timestamps, not counters
- ✅ **Buffering**: All three types preserve buffering benefits (1,000,000x reduction)
- ✅ **No In-Memory State**: Everything in database
- ✅ **Future-Proof**: Easy to add new types (weekly, streak, etc.)

**Implementation:** See tech specs for details:
- [TECH_SPEC_CONFIGURATION.md](../TECH_SPEC_CONFIGURATION.md) - Goal type schema
- [TECH_SPEC_DATABASE.md](../TECH_SPEC_DATABASE.md) - Atomic increment SQL
- [TECH_SPEC_EVENT_PROCESSING.md](../TECH_SPEC_EVENT_PROCESSING.md) - EventProcessor routing

---
## Recommendation: Option 5 ✅

**This is the best approach** because:

1. ✅ **Explicit and Clean**: Goal type is explicit in config
2. ✅ **Supports All Patterns**: Absolute stats, increment counting, daily checks
3. ✅ **No In-Memory State**: All state in database
4. ✅ **Atomic Operations**: DB-level atomic increments
5. ✅ **Preserves Buffering**: Accumulates deltas before flushing
6. ✅ **Type-Safe**: Clear distinction between goal types
7. ✅ **Future-Proof**: Easy to add new goal types (streak, milestone, etc.)

**Implementation Effort:**
- Add `type` field to config schema ✅
- Add `IncrementProgress()` to repository interface ✅
- Update `BufferedRepository` to track deltas ✅
- Update `EventProcessor` to route by goal type ✅
- Update claim logic to check by goal type ✅

**Estimated: ~200 lines of code, 1-2 hours implementation**

---

**Status:** ✅ CONFIRMED - Proceeding with Option 5 (Explicit Increment Goal Type)

---

## Phase 5.2.2a: Design Decisions - Quick Reference ✅

**Date:** 2025-10-17 | **Status:** All 11 questions answered

### Quick Reference Summary

**Q1: GoalType Location** → Add to `models.go` with constants: `absolute`, `increment`, `daily`

**Q2: Type Default** → Validator defaults empty type to `"absolute"` (mutation during validation is acceptable)

**Q3: IncrementProgress Signature** → Yes, include `context.Context` as first parameter (consistency)

**Q4: TargetValue Parameter** → Caller extracts from config, passes to repository (separation of concerns: repo has no config access)

**Q5: Daily Increment Goals** → Add optional `daily: true` flag to increment-type goals
- Dual buffer strategy: `bufferIncrement` (deltas) + `bufferIncrementDaily` (timestamps)
- Client-side date checking: Skip buffering if event already occurred today
- Periodic cleanup: Hourly, 48h retention, ~8MB cap
- SQL: Regular increment (`progress + delta`) vs daily increment (CASE with date check)
- Specs updated: TECH_SPEC_CONFIGURATION.md, TECH_SPEC_DATABASE.md, TECH_SPEC_EVENT_PROCESSING.md

**Q6: Test Scope (Phase 5.2.2a)** → Test all 3: (1) Update fixtures with explicit type, (2) Comprehensive validation tests (~16 cases), (3) Default/backward compat tests

**Q7: Backward Compat Test** → Add now in Phase 5.2.2a: `TestGoalTypeBackwardCompatibility` (config without type field → defaults to "absolute")

**Q8: Method Documentation** → Yes, add explicit usage docs to all repository methods in interface (when to use UpsertProgress vs IncrementProgress vs BatchIncrementProgress)

**Q9: BatchIncrementProgress Method** → Yes, add for performance (1 query vs N queries, consistent with BatchUpsertProgress pattern)
- Interface: `BatchIncrementProgress(ctx, []ProgressIncrement) error`
- Struct: `ProgressIncrement{UserID, GoalID, ChallengeID, Namespace, Delta, TargetValue, IsDailyIncrement}`

**Q10: Store goal_type in DB?** → No, always look up from config cache (simpler, config is source of truth, consistent with Decision #52)

**Q11: Claim Validation for Daily Goals** → Use existing `GOAL_NOT_COMPLETED` error for both NULL `completed_at` and date mismatch scenarios


---

## Phase 5.2.2: Implementation Concerns & Risks ⚠️

**Date:** 2025-10-17

### Phase 5.2.2a Concerns (Models & Interfaces)

**Risk: Missing Test Fixtures** ⚠️ MEDIUM
- **Problem:** Test fixtures scattered across multiple packages (`config/`, `cache/`, `repository/`)
- **Impact:** Compilation failures if any fixture missing explicit `type` field
- **Mitigation:** Search for all `.json` test files, grep for `"goals"` patterns before making changes
- **Action:** Run `find . -name "*_test.go" -exec grep -l "Goal{" {} \;` to find all test files with Goal structs

**Risk: Validation Order** ⚠️ LOW
- **Problem:** Type defaulting must happen BEFORE `daily` flag validation
- **Impact:** Validation error if `daily: true` on goal without explicit type (defaults after validation)
- **Mitigation:** Ensure validator defaults type in first pass, validates relationships in second pass
- **Action:** Add explicit test case: `{"daily": true, "requirement": {"stat_code": "x", "target": 1}}` (no type field) → should default to "absolute" then fail validation

---

### Phase 5.2.2c Concerns (BufferedRepository - Dual Tracking)

**Risk: Memory Leak in bufferIncrementDaily** ⚠️ HIGH
- **Problem:** Map grows unbounded if cleanup doesn't run or fails
- **Impact:** Event handler OOM after processing millions of daily increment events
- **Mitigation:**
  - Periodic cleanup ticker (every 1 hour)
  - Hard limit on map size (reject new entries if >200K)
  - Graceful degradation: if limit reached, log warning and process event anyway (skip date check)
- **Action:** Add test that simulates 200K unique user-goal pairs, verify cleanup runs and map shrinks

**Risk: Race Condition Between Flush and IncrementProgress** ⚠️ HIGH
- **Problem:** Flush reads `bufferIncrement` while `IncrementProgress` is writing to it
- **Impact:** Lost increments or incorrect delta accumulation
- **Current Design:** Both use `mu sync.RWMutex` - should be safe if used correctly
- **Concern:** Flush must use `Lock()` not `RLock()` to prevent concurrent writes during read
- **Mitigation:**
  - Flush acquires write lock: `mu.Lock()` (not `RLock()`)
  - Create snapshot of buffers, clear them, then release lock
  - Process snapshot outside of lock
- **Action:** Add concurrent test: 1000 goroutines calling IncrementProgress while Flush runs in background

**Risk: Daily Increment Date Checking Logic** ⚠️ MEDIUM
- **Problem:** Client-side date checking must match server-side SQL date checking
- **Impact:** Duplicate increments if logic differs (e.g., client uses local time, server uses UTC)
- **Mitigation:** Both use `time.Now().UTC().Truncate(24 * time.Hour)` for consistency
- **Action:** Add test with timestamp exactly at midnight UTC boundary to verify no off-by-one errors

**Risk: Flush Logic Complexity** ⚠️ HIGH
- **Problem:** Flush must now handle TWO buffers: `bufferAbsolute` (existing) + `bufferIncrement` (new)
- **Impact:** Code complexity, potential bugs if one buffer flushes but other fails
- **Current Design:**
  - Collect absolute updates → `BatchUpsertProgress()`
  - Collect increment updates → `BatchIncrementProgress()`
  - Both use separate transactions? Or single transaction?
- **Concern:** If BatchUpsertProgress succeeds but BatchIncrementProgress fails, buffers are inconsistent
- **Mitigation:**
  - **Option A:** Single transaction for both operations (complex)
  - **Option B:** Independent transactions, accept eventual consistency (simpler)
  - **Recommendation:** Option B for M1 (keep it simple)
- **Action:** Document in code: "Absolute and increment flushes are independent. Failures in one do not affect the other."

---

### Phase 5.2.2c Decisions ✅

**Date:** 2025-10-17

#### Decision Q1: Memory Leak in bufferIncrementDaily ✅

**Q1a: Cleanup Configuration**
- **Decision:** Hourly cleanup for entries more than 48h old
- Fixed interval (not configurable)

**Q1b: Hard Limit Value**
- **Decision:** 200K entries is acceptable
- Calculation: ~40 bytes per entry × 200K = ~8MB (acceptable memory overhead)

**Q1c: Metrics & Monitoring**
- **Decision:** Skip Prometheus metrics for buffer size
- Simpler implementation, sufficient for M1

**Q1d: Graceful Degradation Behavior**
- **Decision:** If bufferIncrementDaily is full, skip adding to it but still append to bufferIncrement
- Database query will handle date checking via SQL DATE() function
- No risk of data loss - SQL is the source of truth for date validation

#### Decision Q2: Flush Locking Strategy ✅

**Decision:** Use swap pattern for buffer flush

**Approach:**
- Acquire lock
- Swap buffers with new empty maps
- Release lock immediately
- Process swapped buffers outside lock

**Benefits:**
- Faster mutex release (new events can buffer during flush)
- Cleaner separation between snapshot and processing

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

#### Decision Q3: Date Checking Consistency ✅

**Decision:** Create shared UTC date calculation function

**Location:** `pkg/common/dateutil.go` - `GetCurrentDateUTC()`

**Usage:**
- BufferedRepository: Client-side date checking before buffering
- PostgreSQL query: Server-side CASE with `DATE(completed_at AT TIME ZONE 'UTC')`
- Integration test: Midnight UTC boundary verification

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

#### Decision Q4: Buffer Cleanup Locking ✅

**Decision:** Buffer cleanup uses write lock (consistent with flush)

**Approach:** Acquire `mu.Lock()`, delete entries older than 48h, release lock

**Result:** No race condition - cleanup and flush both use write lock

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md)

#### Decision Q5: Flush Failure Retry for Daily Increments ✅

**Decision:** Keep the original timestamp (first occurrence wins)

**Scenario:**
1. User logs in at 2025-10-17 10:00 AM
2. Buffer accumulated: `{user1:login} -> delta=1, timestamp=2025-10-17`
3. Flush fails (DB error)
4. Retry at 10:01 AM
5. **Behavior:** Preserve timestamp as 2025-10-17 (do NOT update to current time)

**Rationale:**
- User DID log in on 2025-10-17, so we preserve that fact
- Original event timestamp is more accurate than retry timestamp
- Even if retry happens days later (e.g., 2025-10-18), we keep 2025-10-17

**Implementation:**
- `bufferIncrementDaily` entries are NOT updated during retry
- Only removed on successful flush or cleanup

---

### Summary: Phase 1.5 Complete ✅

**Total Findings:**
- ✅ Protobuf-first REST API architecture (gRPC Gateway)
- ✅ OnMessage pattern for event handlers (Kafka abstracted)
- ✅ 3-stage Dockerfile pattern (proto gen → build → runtime)
- ✅ Hybrid docker-compose strategy
- ✅ JWT auth modifications required
- ✅ Domain-to-proto mappers to implement

**Documentation Updated:**
- ✅ BRAINSTORM.md - Phase 1.5 findings + Q&A + Template modifications
- ✅ TECH_SPEC_API.md - Protobuf-first approach + JWT context modifications
- ✅ TECH_SPEC_EVENT_PROCESSING.md - OnMessage pattern + proto download
- ✅ TECH_SPEC_DEPLOYMENT.md - Multi-stage Dockerfile + docker-compose strategy

**Implementation Checklist:**
1. Clone templates (extend-service-extension-go, extend-event-handler-go)
2. Create extend-challenge-common module
3. Modify authServerInterceptor.go (Validator type + context injection)
4. Create context_helpers.go (GetUserIDFromContext, GetNamespaceFromContext)
5. Download event protos from AccelByte
6. Implement domain-to-proto mappers

---

## Phase 5.2.3: LoginHandler Implementation Design Decisions ✅

**Date:** 2025-10-18
**Context:** Preparing Phase 5.2.3 implementation - replace template loginHandler.go with challenge-specific implementation

**Status:** Specifications Complete - Ready for Implementation

---

### Design Questions & Answers

#### Q1: How should LoginHandler identify which goals to process? ✅

**Question:** Should we use string matching on `stat_code` (e.g., "login*") or add an explicit field to goal config?

**Answer:** Add explicit `event_source` field to goal config

**Decision Rationale:**
- Type-safe and explicit (no brittle string matching on stat_code)
- Config schema: `"event_source": "login"` or `"event_source": "statistic"`
- LoginHandler filters goals where `event_source == "login"`
- StatisticHandler filters goals where `event_source == "statistic"`
- Easy to extend (e.g., add "achievement", "entitlement" event sources in future)

**Implementation:**
- Updated TECH_SPEC_CONFIGURATION.md with event_source field specification
- Added validation: `event_source` must be "login" or "statistic"
- Updated all example configs in challenges.json

---

#### Q2: What stat value should be passed for login events? ✅

**Question:** Login events are binary (occurred/not occurred), but EventProcessor expects numeric stat values. What value should we pass?

**Answer:** Always use `statValue=1` for login events

**Decision Rationale:**
- Login is an occurrence-based event (not a stat with numeric value)
- For increment-type login goals (e.g., "login 7 times"), each event increments by delta=1
- For daily-type login goals (e.g., "daily login bonus"), the value doesn't matter (date check is what matters)
- Consistent pattern: every login event = 1 occurrence

**Implementation:**
```go
// In LoginHandler.OnMessage()
for _, goal := range loginGoals {
    err := h.processor.ProcessEvent(userID, goal.ID, 1)  // Always pass 1 for login events
}
```

---

#### Q3: Should we filter goals by challenge activation status? ✅

**Question:** Should LoginHandler only process goals from "active" challenges, or process all login goals from config?

**Answer:** Option A - Process all login goals from config (no challenge status filtering in M1)

**Decision Rationale:**
- M1 has simple fixed challenges with no lifecycle management
- If challenge is in config → it's active (per Decision #19)
- No `draft`, `paused`, `expired` states in M1
- Challenge status filtering can be added in M2+ if needed
- Simpler implementation for M1

**Implementation:**
- LoginHandler processes ALL goals where `event_source == "login"`
- No challenge status checks
- Remove challenge from config if you don't want it to be active

---

#### Q4: How should LoginHandler handle errors? ✅

**Question:** Should we log errors and continue (graceful degradation) or return gRPC error to Extend platform?

**Answer:** Hybrid approach - log normal errors, return gRPC error if buffer is full

**Decision Rationale:**
- **Normal errors** (e.g., validation failure, nil message): Log and continue processing other goals
  - Graceful degradation prevents single bad event from blocking all events
  - Event is marked consumed, Extend platform moves to next event
- **Critical errors** (e.g., buffer full): Return gRPC error code
  - Event NOT marked consumed
  - Extend platform will retry the event later
  - Prevents data loss when system is under extreme load

**Implementation:**
```go
err := h.processor.ProcessEvent(userID, goal.ID, 1)
if err != nil {
    // Buffer full or critical error - return error for Extend platform retry
    h.logger.Error("Failed to process login event, returning error for retry",
        "userID", userID, "goalID", goal.ID, "error", err)
    return nil, status.Errorf(codes.Internal, "failed to buffer event: %v", err)
}
```

**Key Distinction:**
- Validation errors (nil message, empty userID): Return error immediately (don't try to process)
- Processing errors (buffer full): Return error to enable retry
- Normal processing: Return `&emptypb.Empty{}, nil` (success)

---

#### Q5: Should we keep AGS SDK imports from template? ✅

**Question:** Template loginHandler.go uses AGS Platform SDK for reward granting. Should we keep these imports for Phase 5.2.3?

**Answer:** Option A - Remove AGS SDK imports for M1, document usage for Phase 7

**Decision Rationale:**
- Phase 5.2.3 focuses on login event processing, NOT reward granting
- Reward granting happens in Phase 7 (REST API claim flow)
- Event handler should NOT grant rewards (separation of concerns)
- Keeping unused imports adds unnecessary dependencies

**Implementation:**
- Remove AGS Platform SDK imports from loginHandler.go
- Add code comments explaining where AGS SDK will be used:
  ```go
  // NOTE: Reward granting is handled by the REST API service (Phase 7)
  // When implementing reward grants in Phase 7, use:
  //   - factory.NewPlatformClient(configRepo) for client creation
  //   - platform.FulfillmentService for item grants
  //   - See template loginHandler.go for reference implementation
  ```
- Document in TECH_SPEC_EVENT_PROCESSING.md

---

#### Q6: What testing approach for LoginHandler? ✅

**Question:** Should we write integration tests with real database, or are mock-based unit tests sufficient for M1?

**Answer:** Mock-based unit tests are sufficient for M1

**Decision Rationale:**
- LoginHandler has simple responsibilities: validate message, filter goals, call EventProcessor
- EventProcessor already has comprehensive integration tests (Phase 5.2.2e)
- Mocking EventProcessor and GoalCache provides good coverage
- Integration tests can be added in Phase 5.3 (end-to-end event flow)

**Test Coverage Target:** 80%+ with 15+ test cases

**Test Cases:**
1. Valid login event with single login goal → processes successfully
2. Valid login event with multiple login goals → processes all
3. Nil message → returns InvalidArgument error
4. Empty userID → returns InvalidArgument error
5. No login goals in config → returns success (no-op)
6. Goal cache returns nil → logs warning, returns success
7. Mixed event sources (login + statistic goals) → only processes login goals
8. EventProcessor returns error → returns Internal error for retry
9. Multiple login events for same user → all processed (deduplication handled by buffer)
10. Login goal with absolute type → processes correctly
11. Login goal with increment type → processes correctly
12. Login goal with daily type → processes correctly
13. Context cancellation → returns error
14. Concurrent login events for different users → all processed
15. Login event with traceID → propagates to logs

**Implementation:** See [TECH_SPEC_EVENT_PROCESSING.md](./TECH_SPEC_EVENT_PROCESSING.md) - Phase 5.2.3 section

---

### Summary: Phase 5.2.3 Decisions

**All 6 questions answered:**
- ✅ Q1: Add `event_source` field to config (not string matching)
- ✅ Q2: Use statValue=1 for all login events
- ✅ Q3: Process all login goals from config (no filtering)
- ✅ Q4: Hybrid error handling (log normal, return error if buffer full)
- ✅ Q5: Remove AGS SDK imports, document for Phase 7
- ✅ Q6: Mock-based unit tests (80%+ coverage, 15+ test cases)

**Specifications Updated:**
- ✅ TECH_SPEC_CONFIGURATION.md - event_source field added
- ✅ TECH_SPEC_EVENT_PROCESSING.md - Phase 5.2.3 implementation guide
- ✅ challenges.json - event_source field on all goals
- ✅ STATUS.md - Phase 5.2.3 marked as "Specification Complete"

**Ready for Implementation:** 2-hour estimate
- Replace template loginHandler.go
- Integrate EventProcessor and GoalCache
- Filter by event_source field
- Write 15+ unit tests with mocks
- Run linter (zero issues target)

---

## Phase 6.7: Integration Testing - Decisions ✅

**Date Decided:** 2025-10-19
**Context:** Phase 6.7 REST API integration testing approach
**Status:** All Decisions Made - Ready for Implementation

### Decisions Made

**IQ1: Test Infrastructure Strategy** → **Option B: docker-compose**
- Use docker-compose.test.yml for test infrastructure
- Simple, familiar approach matching TECH_SPEC_TESTING.md examples
- Containers persist between tests for faster execution

**IQ2: Database Migration Execution** → **Option B: golang-migrate Go library**
- Use `github.com/golang-migrate/migrate/v4` library
- Migration files located: `extend-challenge-service/migrations/`
- Go-native approach with proper version tracking

**IQ3: JWT Token Generation** → **Option B: Test JWT generator**
- Generate test JWTs with RSA key pair (in-memory, test-only)
- Realistic JWT structure for integration testing
- Disable auth interceptor in docker-compose (`PLUGIN_GRPC_SERVER_AUTH_ENABLED=false`)

**IQ4: RewardClient Testing** → **Option B: Mock RewardClient**
- Use testify/mock for RewardClient in integration tests
- Enables verification of reward granting behavior
- Can test retry logic and error scenarios

**IQ5: Event Processing Integration** → **Option A: Pre-populate Database**
- Insert test data directly via SQL for Phase 6.7
- Fast, simple tests that isolate REST API behavior
- Event handler integration deferred to Phase 8 (E2E tests)

**IQ6: Test Data Isolation** → **Option A: Truncate tables**
- Run `TRUNCATE user_goal_progress` before each test
- Simple, fast isolation strategy
- Acceptable for M1 scope

**IQ7: Parallel Test Execution** → **Option A: Serial execution**
- Run tests serially with `go test -p 1`
- Avoids port conflicts and database contention
- Simpler setup for M1

**IQ8: Error Scenario Coverage** → **Test all error scenarios**
- High Priority: 401 Unauthorized, 400 Goal Not Completed, 409 Already Claimed, 404 Goal Not Found
- Medium Priority: 400 Goal Locked, 503 Database Unavailable
- Low Priority: 502 Reward Grant Failed, 400 Invalid Request
- **All scenarios will be tested in Phase 6.7**

**IQ9: Health Check Testing** → **Deferred** (Low Priority)
**IQ10: Coverage Target** → **Scenario-based** (No coverage target, focus on critical paths)

### Implementation Impact

All decisions documented in `docs/TECH_SPEC_TESTING.md` with:
- Updated docker-compose.test.yml configuration
- Migration setup code using golang-migrate library
- Test JWT generator implementation
- Mock RewardClient setup
- Pre-population and truncation examples
- Comprehensive error scenario test structure

**Ready to proceed with Phase 6.7 implementation.**

---

## Phase 6.7: Integration Testing - Additional Decisions ✅

**Date Decided:** 2025-10-19
**Context:** Post-IQ1-IQ10 analysis revealed architecture mismatch
**Status:** All Decisions Made - Ready for Implementation

### Decisions Made

**AC1: Test Architecture** → **Option B: In-process testing**
- Tests create gRPC server in-process with injected dependencies
- docker-compose.test.yml contains **only PostgreSQL** (no challenge-service)
- Enables MockRewardClient injection for comprehensive error testing
- Uses bufconn (in-memory gRPC listener) for fast testing
- Rationale: Allows testing all error scenarios (IQ8) with full control over dependencies

**AC2: JWT Authentication** → **Option A: Disabled for Phase 6.7**
- Auth interceptor NOT included in integration tests
- gRPC server created without auth middleware
- Auth interceptor tested separately at unit test level
- Simplifies test setup, avoids JWT complexity
- Rationale: M1 focus is business logic, auth well-covered by unit tests

**AC3: Test Data Source** → **Use same challenges.json as production**
- Tests load from `extend-challenge-service/config/challenges.json`
- No separate `challenges.test.json` file
- Ensures test data matches production configuration
- Rationale: Consistency and reduced maintenance

### Implementation Impact

All decisions applied to `docs/TECH_SPEC_TESTING.md`:
- **docker-compose.test.yml**: Postgres only with tmpfs for speed
- **setupTestServer()**: Creates in-process gRPC server with bufconn
- **Test examples**: Updated to use gRPC client, not HTTP
- **Error tests**: All 8 scenarios using MockRewardClient
- **Auth testing**: Explicitly noted as unit-test concern

**Architecture:**
```
Integration Tests
├── PostgreSQL (docker-compose) ─── Real database
├── In-Process gRPC Server ──────── Created in test code
│   ├── MockRewardClient ────────── Injected for assertions
│   ├── PostgresGoalRepository ──── Real DB queries
│   └── InMemoryGoalCache ───────── Real config loading
└── bufconn (in-memory) ─────────── Fast gRPC client connection
```

**Key Benefit:** Full dependency injection enables testing reward failures (502), incomplete goals (400), locked goals (400), and all other error scenarios that require controlled mock behavior.

**Ready to proceed with Phase 6.7 implementation.**

---

## Phase 7: AGS Integration - Implementation Decisions ✅

**Date:** 2025-10-19
**Status:** Phase 7.1 Complete (SDK Discovery) - All Questions Answered

### SDK Function Discovery (Q1) ✅

**Admin Functions via Extend SDK MCP Server:**

1. **ITEM Rewards**: `GrantUserEntitlementShort@platform`
   - Service: `EntitlementService` (platform SDK)
   - Parameters: `*entitlement.GrantUserEntitlementParams`
   - Returns: `(*entitlement.GrantUserEntitlementResponse, error)`
   - Supported Types: APP, INGAMEITEM, CODE, SUBSCRIPTION, MEDIA, OPTIONBOX, LOOTBOX
   - Import: `github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/platform`

2. **WALLET Rewards**: `CreditUserWalletShort@platform`
   - Service: `WalletService` (platform SDK)
   - Parameters: `*wallet.CreditUserWalletParams`
   - Returns: `(*wallet.CreditUserWalletResponse, error)`
   - Auto-creates wallet if not exists
   - Import: `github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/platform`

### Implementation Decisions (Q2-Q10) ✅

**Q2: SDK Client Initialization** → Follow extend-service-extension-go/main.go pattern for CloudSave adminGameRecordService

**Q3: SDK Error Handling** → Already wrapped by SDK - inspect SDK code to extract HTTP status codes

**Q4: Context Timeout Handling** → YES, always check `ctx.Err()` before each retry attempt

**Q5: Namespace Parameter** → SDK uses namespace **per-call** (not per-client)

**Q6: OAuth2 Token Management** → YES, service token **refreshes automatically** via SDK

**Q7: Testing Strategy** → Mock SDK client in unit tests (follow recommendation)

**Q8: AGS Idempotency** → Trust AGS Platform Service idempotency (follow recommendation)

**Q9: Logging** → Use structured logging with logrus per spec (userId, rewardType, rewardId, attempt, error)

**Q10: Main.go Integration** → Replace NoOpRewardClient with AGSRewardClient, require real AGS credentials (no fallback)

### Implementation Guide (Detailed Breakdown in STATUS.md)

**Phases**: 7.1 (Discovery ✅) → 7.2 (Implementation) → 7.3 (Testing) → 7.4 (Integration) → 7.5 (E2E Testing)

**Key Implementation Points**:
- Use `EntitlementService.GrantUserEntitlementShort()` for ITEM rewards
- Use `WalletService.CreditUserWalletShort()` for WALLET rewards
- Always check `ctx.Err()` before retry attempts (Q4)
- Pass namespace per-call, not per-client (Q5)
- Trust SDK's automatic OAuth2 token refresh (Q6)
- Extract HTTP status codes from SDK errors for retry logic (Q3)
- Mock SDK services in unit tests using testify/mock (Q7)
- Trust AGS Platform Service idempotency (Q8)
- Use structured logging with logrus per spec (Q9)
- No NoOpRewardClient fallback in production (Q10)

**See STATUS.md Phase 7.2-7.5 for complete task breakdown**

---

### New Questions or Concerns (NQ1-NQ10) ✅

**Status**: All questions answered and documented in TECH_SPEC_API.md

**Complete implementation details**: See [TECH_SPEC_API.md - AGS Platform Service Integration (Phase 7)](./TECH_SPEC_API.md) section starting at line 1332

**Summary of Decisions**:
- **NQ1**: Error extraction using type assertion pattern (Option A)
- **NQ2**: SDK init pattern verified via main.go inspection
- **NQ3**: Complete SDK parameter structures discovered via MCP
- **NQ4**: Factory pattern for service initialization confirmed
- **NQ5**: Import package structure identified (3 SDK packages)
- **NQ6**: No EntitlementType field needed (AGS infers from itemID)
- **NQ7**: Log responses for audit, don't validate
- **NQ8**: 10-second total timeout for retry loop (Option B)
- **NQ9**: Simple error wrapping with `fmt.Errorf`
- **NQ10**: Retry logic in wrapper function pattern

---

### Phase 7 New Questions Summary Table (NQ1-NQ10)

| # | Question | Status | Answer/Decision | Impact |
|---|----------|--------|-----------------|--------|
| **NQ1** | SDK Error Extraction | ✅ **ANSWERED** | **Option A**: Type assertion pattern with discovery during testing | Critical - RESOLVED |
| **NQ2** | SDK Init Pattern Verification | ✅ Low Priority | Resolved via main.go inspection | Low - already verified |
| **NQ3** | SDK Parameter Structures | ✅ **ANSWERED** | Complete field definitions via MCP:<br>- GrantUserEntitlementParams: Namespace, UserID, Body (array)<br>- EntitlementGrant: ItemID, ItemNamespace, Quantity (int32)<br>- CreditUserWalletParams: Namespace, UserID, CurrencyCode, Body<br>- CreditRequest: Amount (int64) | Critical - RESOLVED |
| **NQ4** | Service Initialization | ✅ **ANSWERED** | Factory pattern:<br>`platformClient := factory.NewPlatformClient(configRepo)`<br>Then init services with client + repos | Critical - RESOLVED |
| **NQ5** | Import Package Structure | ✅ **ANSWERED** | 3 packages:<br>- services-api/pkg/service/platform<br>- platform-sdk/pkg/platformclient/*<br>- platform-sdk/pkg/platformclientmodels | Low - RESOLVED |
| **NQ6** | Entitlement Type Field | ✅ **ANSWERED** | NO EntitlementType field exists<br>AGS infers type from itemID via catalog | Medium - RESOLVED |
| **NQ7** | Response Validation | ✅ **DECIDED** | Log responses for audit, don't validate | Low - decision made |
| **NQ8** | Context Timeout | ✅ **ANSWERED** | **Option B**: 10s total timeout for all retry attempts | Important - RESOLVED |
| **NQ9** | Error Wrapping | ✅ **DECIDED** | Simple wrapping: `fmt.Errorf("...: %w", err)` | Low - decision made |
| **NQ10** | Retry Logic Location | ✅ **DECIDED** | Wrapper function pattern: `withRetry()` | Low - decision made |

**All Questions Answered**: 10/10 ✅
**Ready for Implementation**: YES ✅

---

### Phase 7 Decisions Summary ✅

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| **Q1** | SDK Functions | `GrantUserEntitlementShort@platform` (ITEM)<br>`CreditUserWalletShort@platform` (WALLET) | Admin endpoints via Extend SDK MCP Server |
| **Q2** | SDK Init | Follow extend-service-extension-go/main.go pattern | Template provides proven initialization |
| **Q3** | Error Handling | SDK wraps errors - inspect source for status codes | SDK already provides error abstraction |
| **Q4** | Context Cancel | Always check `ctx.Err()` before retry | Prevents wasted retries on timeout |
| **Q5** | Namespace | Per-call parameter | SDK design confirmed via MCP docs |
| **Q6** | OAuth2 Token | Auto-refresh by SDK | No manual token management needed |
| **Q7** | Testing | Mock SDK client with testify/mock | Standard Go testing pattern |
| **Q8** | Idempotency | Trust AGS Platform Service | Per spec recommendation |
| **Q9** | Logging | Structured logging with logrus | Per TECH_SPEC_API.md |
| **Q10** | Integration | Replace NoOpRewardClient, no fallback | Production-ready approach |

---

**Next Steps**: See STATUS.md Phase 7.2-7.5 for detailed implementation tasks

---

**Status**: Phase 7 Investigation Complete - ALL Questions Answered ✅

### Investigation Results Summary ✅

**ALL QUESTIONS ANSWERED (10/10)**:
- ✅ **NQ1**: SDK Error Extraction - **Option A**: Type assertion pattern
- ✅ **NQ2**: SDK Init Pattern - Resolved via main.go inspection
- ✅ **NQ3**: SDK Parameter Structures - Complete field definitions via MCP
- ✅ **NQ4**: Service Initialization - Factory pattern confirmed
- ✅ **NQ5**: Import Structure - 3 SDK packages identified
- ✅ **NQ6**: Entitlement Type - Not needed (AGS infers from itemID)
- ✅ **NQ7**: Response Validation - Log for audit, don't validate
- ✅ **NQ8**: Context Timeout - **Option B**: 10s total timeout
- ✅ **NQ9**: Error Wrapping - Simple `fmt.Errorf` pattern
- ✅ **NQ10**: Retry Logic Location - Wrapper function pattern

**Implementation Ready**: YES ✅

**Key Decisions Made**:
1. **Error Extraction**: Type assertion with discovery during testing (NQ1)
2. **Context Timeout**: 10-second total timeout for retry loop (NQ8)
3. **Param Structures**: Body fields are arrays/pointers, int32/int64 conversions
4. **Service Init**: Factory pattern with platform.EntitlementService/WalletService
5. **No EntitlementType**: AGS infers from itemID via catalog

**Implementation Plan**: See TECH_SPEC_API.md "AGS Platform Service Integration (Phase 7)" section

**Next Steps**:
1. ✅ **COMPLETE**: All questions answered and documented
2. ✅ **COMPLETE**: Implementation plan written to TECH_SPEC_API.md
3. ✅ **COMPLETE**: Questions compacted in BRAINSTORM.md
4. **NEXT**: Proceed with Phase 7.2 implementation (or raise new concerns if any)

**Detailed Implementation Tasks**: See `docs/STATUS.md` Phase 7.2-7.5 for complete breakdown

---

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| SDK API differs from docs | High | Medium | Use Extend SDK MCP Server for accurate function signatures |
| OAuth2 token refresh issues | High | Low | Research SDK OAuth2 implementation first, add token refresh retry |
| Error types incompatible | Medium | Medium | Wrap SDK errors in custom types, test thoroughly |
| Idempotency not guaranteed | High | Low | Trust AGS per spec, monitor for double grants in staging |
| Context timeout edge cases | Medium | Medium | Check `ctx.Err()` before each retry attempt |
| Namespace scoping mismatch | Low | Low | Verify SDK namespace pattern early |
| Integration test failures | Medium | Medium | Use staging environment, have fallback to NoOpRewardClient |

---

### Success Criteria

**Phase 7 Complete When**:
- ✅ AGSRewardClient implements RewardClient interface
- ✅ Item rewards granted successfully via AGS Platform Service
- ✅ Wallet rewards credited successfully via AGS E-Commerce Service
- ✅ Retry logic works with exponential backoff (3 retries, 500ms base)
- ✅ Non-retryable errors (400/404) fail immediately
- ✅ Retryable errors (502/503) retry up to 3 times
- ✅ Unit test coverage ≥ 80%
- ✅ Zero linter issues
- ✅ Integration tests pass in staging with real AGS
- ✅ main.go updated to use AGSRewardClient
- ✅ Documentation updated

---

**Status**: Ready for implementation - all questions documented, awaiting SDK function discovery

---

## Phase 6.7: Integration Testing - Final Review ✅

**Date:** 2025-10-19
**Context:** Post-AC1-AC3 decisions analysis
**Status:** No Critical Concerns - Ready for Implementation

### Analysis: Potential Concerns

#### Concern: gRPC-Gateway HTTP Layer Testing ⚠️

**Observation:**
- Phase 6.7 scope is "REST API integration testing"
- Updated approach tests **gRPC layer only** (via bufconn)
- **HTTP layer (gRPC-Gateway) not tested** in integration tests

**HTTP Layer Components Not Tested:**
- gRPC-Gateway transcoding (protobuf ↔ JSON)
- HTTP routing and path parameters
- HTTP error code mapping (gRPC codes → HTTP status codes)
- HTTP request/response headers
- CORS handling (if applicable)

**Risk Assessment:** 🟡 **MEDIUM**
- gRPC-Gateway is production component (main.go lines 209-222)
- JSON serialization bugs won't be caught
- HTTP-specific errors (path validation, content-type) not tested

**Options:**

**Option A: Accept gRPC-only testing for Phase 6.7**
- **Pro:** Simpler, faster tests
- **Pro:** gRPC-Gateway is mostly generated code (low bug risk)
- **Con:** HTTP layer untested in integration tests

**Option B: Add HTTP layer testing**
- Create gRPC-Gateway handler in setupTestServer
- Use httptest.Server for HTTP endpoint testing
- Test both gRPC AND HTTP in same test suite
- **Pro:** Full stack testing
- **Con:** More complex setup

**Option C: Separate HTTP-specific tests**
- Keep gRPC tests as-is
- Add small HTTP test suite for gateway behavior
- Focus on transcoding and error mapping only
- **Pro:** Focused, modular
- **Con:** Duplicate test setup

**Recommendation:** **Option A for Phase 6.7, Option C for Phase 7**

**Rationale:**
- gRPC-Gateway is well-tested framework with low bug probability
- JSON marshaling is standard protobuf behavior
- Business logic is tested via gRPC client (core concern)
- Can add HTTP-specific tests later if issues arise
- M1 priority is core functionality, not HTTP semantics

**Mitigation:**
- Add comment in TECH_SPEC_TESTING.md noting HTTP layer deferred
- Add manual testing checklist for HTTP endpoints (curl commands)
- Plan HTTP integration tests for Phase 7 if needed

---

#### Non-Concern: Helper Function Implementation

**Observation:** Test code references many helper functions (seedCompletedGoal, applyMigrations, etc.)

**Assessment:** ✅ **NOT A CONCERN**
- These are implementation details, not design concerns
- Straightforward SQL INSERT and migration library calls
- Will be implemented during Phase 6.7 coding
- No design decision needed

---

#### Non-Concern: Test Data Fixtures

**Observation:** AC3 mentions "2 users, 2 challenges, 4 goals" but no formal specification

**Assessment:** ✅ **NOT A CONCERN**
- Test data created on-demand per test (seedCompletedGoal, etc.)
- No need for pre-defined fixture files
- Each test creates only the data it needs for isolation
- Flexible approach suitable for Phase 6.7 scope

---

### Final Recommendation

**Proceed with Phase 6.7 implementation** using current design:
- In-process gRPC testing (AC1 Option B)
- Auth disabled (AC2 Option A)
- Production challenges.json (AC3)
- gRPC-only testing (defer HTTP layer to Phase 7)

**No blocking concerns identified.**

All design decisions documented and ready for implementation.

---

## Phase 7.6: SDK Error Type Investigation ✅

**Date:** 2025-10-20
**Status:** Decisions Made - Ready for Implementation

### Problem
Current `extractStatusCode()` expects SDK errors with `StatusCode() int` method, but AccelByte Go SDK v0.80.0 errors don't implement this interface.

**Current Implementation:**

Uses type assertion for `StatusCode() int` - **doesn't work with actual SDK!**

### Investigation Results

**SDK Error Types Discovered:**
- `GrantUserEntitlementNotFound` (404)
- `GrantUserEntitlementUnprocessableEntity` (422)
- `CreditUserWalletBadRequest` (400)
- `CreditUserWalletUnprocessableEntity` (422)
- Generic: `"... returns an error {code}: {body}"` format

**Key Findings:**
- No `StatusCode()` method on SDK errors
- Status codes embedded in type names
- Generic errors parse from error message

### User Decisions ✅

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Q1: Extraction Strategy** | Option B - Type assertion for each SDK error type | Type-safe, explicit, clear mapping |
| **Q2: Error Handling** | Keep current approach with Option B | Structured errors, visibility into failures |
| **Q3: Test Mocks** | Update mocks to match real SDK structure | Tests match production behavior |
| **Q4: Retry Logic** | Map SDK errors to status codes for IsRetryableError() | Existing pattern, no changes needed |
| **Q5: SDK Version** | Pin to v0.80.0 in go.mod | Predictable behavior, manual upgrades |

### Implementation

**Type Assertion with Regex Fallback:**
```go
switch err.(type) {
case *entitlement.GrantUserEntitlementNotFound: return 404, true
case *entitlement.GrantUserEntitlementUnprocessableEntity: return 422, true
case *wallet.CreditUserWalletBadRequest: return 400, true
case *wallet.CreditUserWalletUnprocessableEntity: return 422, true
default:
    // Fallback: Regex parse "returns an error (\d{3}):"
    // Log debug if extraction fails
}
```

**Test Updates:**
- Remove `mockSDKError` with `StatusCode()` method
- Use actual SDK error types in tests
- Verify type assertion for each known error type

**SDK Version:**
- Pin `github.com/AccelByte/accelbyte-go-sdk v0.80.0` in go.mod
- Manual upgrade process with error type validation

### Specifications Updated
- ✅ TECH_SPEC_API.md - Complete implementation with type assertions
- ✅ STATUS.md - Phase 7.6 entry added
- ✅ BRAINSTORM.md - Decisions compacted (this section)

### Next Steps
1. Update `extractStatusCode()` with type assertions
2. Update test mocks (remove StatusCode method)
3. Verify SDK version pinning in go.mod
4. Run tests (zero linter issues target)

**Estimated Time:** 30-45 minutes

---

### Additional Considerations (No Action Needed)

**Potential Future Questions (M2+):**
1. **New Reward Types**: If adding new SDK services (e.g., Achievement grants), add their error types to switch statement
2. **Unknown Error Codes**: Regex fallback handles new codes, debug logging identifies them
3. **Performance**: Type assertion is O(1), regex only for unknowns - acceptable
4. **Thread Safety**: extractStatusCode is read-only, no concerns

**Status:** ✅ **No Additional Questions** - All decisions made, ready for implementation

---

## Phase 8.0: Local Development Environment Setup

**Date**: 2025-10-20
**Context**: Before E2E testing, we need an easy way to start services and DB locally. Current setup is incomplete.

### Current State

**What We Have:**
- ✅ docker-compose.yml with PostgreSQL + Redis
- ✅ Both services implemented with main.go files
- ✅ Integration tests passing
- ✅ .env.example with all required variables

**What's Missing:**
- ❌ No active .env file (only .env.example)
- ❌ Services not in docker-compose.yml (commented out, lines 41-67)
- ❌ No root-level Makefile for unified commands
- ❌ No build targets in event handler Makefile
- ❌ No startup documentation

### Decisions ✅

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Q1: Build Strategy** | **Option A - Build inside Docker** | Reproducible builds, matches production, no local Go dependency |
| **Q2: Mock AGS Credentials** | **Option C - Environment variable conditional** | Follow existing pattern (PLUGIN_GRPC_SERVER_AUTH_ENABLED), flexibility for both workflows |
| **Q3: Hot-Reload** | **Option B - Manual rebuild only** | Simpler setup, explicit control, no extra dependencies |
| **Q4: Migration Strategy** | **Option A - Automatic on startup** | Always up-to-date schema, no manual steps, fail-fast on error |
| **Q5: Service Startup Order** | **Option A - depends_on with health checks** | Built-in Docker feature, no code changes needed |
| **Q6: docker-compose Files** | **Option A - Single docker-compose.yml** | Simple, single source of truth, easy to understand |
| **Q7: Event Simulation** | **Option A - Mock gRPC client** | Realistic simulation, tests full event flow |

### Key Implementation Details

**REWARD_CLIENT_MODE Environment Variable** (Q2)
- Values: `mock` (default) or `real`
- Location: Both service `main.go` files
- Default behavior: Use NoOpRewardClient for local dev safety

**Automatic Migrations** (Q4)
- Location: Backend service only (extend-challenge-service)
- Timing: After DB connection, before server start
- Failure: Exit with code 1 (fail-fast, no partial startup)

**Event Simulator Tool** (Q7)
- Location: `tools/event-simulator/`
- Usage: `make dev-trigger-event TYPE=login USER_ID=test-user`
- Supports: login events and statistic update events

---

### Final Decisions on New Questions ✅

| Question | Decision | Rationale |
|----------|----------|-----------|
| **NQ1: Migration Rollback** | **Option C - Fix-forward only** | Standard for production databases, safer than automated rollback |
| **NQ2: Docker Image Tagging** | **Option B - Semantic versioning (0.0.1)** | Clear version progression, starting from 0.0.1 for M1 |
| **NQ3: Health Check Endpoints** | **Use current implementation** | Challenge service has DB check in HealthCheck RPC, same pattern for event handler |
| **NQ4: Log Level** | **Option B - info level** | Balanced logging, not overwhelming for local dev |
| **NQ5: Event Simulator** | **Option A - CLI only for M1** | Simplicity first, can add batch support in M2+ |

### Implementation References

All implementation details documented in:
- **STATUS.md** - Phase 8.0 implementation tasks and success criteria
- **TECH_SPEC_DEPLOYMENT.md** - Docker, docker-compose, Makefile patterns (to be updated)
- **BRAINSTORM.md** - Architectural decisions and rationale (this file)

See STATUS.md Phase 8.0 for complete implementation checklist.

---

## Phase 8.0: Additional Implementation Questions

**Date**: 2025-10-20
**Context**: Detailed questions that may arise during Phase 8.0 implementation

### Final Decisions on Implementation Questions ✅

| Question | Decision | Rationale |
|----------|----------|-----------|
| **IQ1: Dockerfile base** | **Each service builds independently, root just orchestrates** | Simpler root setup, services self-contained, no root build steps |
| **IQ2: Proto dependencies** | **Download in simulator Makefile** | Single source of truth, no duplication |
| **IQ3: Makefile targets** | **Approved: 10 targets** | Comprehensive dev workflow |
| **IQ4: .env values** | **Approved: mock mode defaults** | Safe defaults for local dev |
| **IQ5: Port mapping** | **Keep current ports (8080, 6565, 5432, 6379)** | Standard ports, no conflicts |
| **IQ6: Volume mounts** | **Bake config/migrations into Docker images** | Self-contained images, no host dependencies |
| **IQ7: Seed data** | **Empty DB for M1** | Simpler, users learn system |
| **IQ8: Service dependencies** | **Both depend on DB/Redis** | Services need DB to function |
| **IQ9: Event handler health** | **DB + config check, HTTP + gRPC** | Same pattern as backend service |
| **IQ10: Event simulator** | **Local Go build, run via Makefile** | Simpler for quick testing |

### Key Architectural Changes

**IQ1: Service-First Build Strategy**
- Each service has its own complete Dockerfile in its repo
- Services build independently: `cd extend-challenge-service && docker build`
- Root docker-compose.yml references pre-built images
- No build steps in root Makefile (just orchestration: up, down, logs)
- Benefits: Clean separation, services testable independently

**IQ6: Self-Contained Images**
- COPY config/challenges.json into images during build
- COPY migrations into backend service image during build
- No volume mounts for config/migrations
- Trade-off: Must rebuild image to change config (acceptable for local dev)
- Benefit: Images are portable, no host path dependencies

### Implementation Impact

**Service Dockerfiles Must Include:**
- Backend service: COPY config/, COPY migrations/, expose port 8080
- Event handler: COPY config/, expose port 6565
- Both: Multi-stage build with proto generation

**Root docker-compose.yml:**
```yaml
services:
  challenge-service:
    build: ./extend-challenge-service  # Builds from service's Dockerfile
    image: challenge-service:0.0.1
    depends_on: [postgres, redis]

  challenge-event-handler:
    build: ./extend-challenge-event-handler
    image: challenge-event-handler:0.0.1
    depends_on: [postgres, redis]
```

**Root Makefile Simplified:**
- No build targets (services handle their own builds)
- Just orchestration: `dev-up`, `dev-down`, `dev-logs`, etc.
- docker-compose handles building via `build:` directives

---

## Phase 8.0: Additional Implementation Questions Round 2

**Date**: 2025-10-20
**Context**: Follow-up questions based on IQ1/IQ6 architectural decisions

### Final Decisions on Implementation Questions Round 2 ✅

| Question | Decision | Rationale |
|----------|----------|-----------|
| **IQ11: Image rebuild** | **Option C - docker-compose auto-build** | Simplest, auto-detects changes on first up |
| **IQ12: Image naming** | **Explicit names (challenge-service:0.0.1)** | Clear versioning, matches NQ2 |
| **IQ13: Build order** | **Option B - docker-compose auto-build** | No manual pre-build needed |
| **IQ14: Dockerfile updates** | **Use existing Dockerfiles, add COPY for config/migrations** | Template Dockerfiles already exist, minimal changes |
| **IQ15: Config path** | **Absolute path `/app/config/challenges.json`** | Clear, no ambiguity |

### Implementation Impact

**Existing Dockerfiles Found:**
- ✅ Backend service: `/extend-challenge-service/Dockerfile` (3-stage: proto, build, runtime)
- ✅ Event handler: `/extend-challenge-event-handler/Dockerfile` (3-stage: proto, build, runtime)

**Required Changes to Dockerfiles:**

**Backend Service** - Add to runtime stage (after line 70):
```dockerfile
COPY --from=builder /build/config /app/config
COPY --from=builder /build/migrations /app/migrations
```

**Event Handler** - Add to runtime stage (after line 66):
```dockerfile
COPY --from=builder /build/config /app/config
```

---

## Phase 8.0: Implementation Concerns & Questions Round 3

**Date**: 2025-10-20
**Context**: Final checks before implementation

### Implementation Concerns (IC1-IC8) - Final Decisions ✅

| Concern | Decision | Verification |
|---------|----------|--------------|
| **IC1: Dockerfile compat** | Keep existing template Dockerfiles, add COPY commands | ✅ Confirmed by user |
| **IC2: Proto dependency** | Config/migrations only in runtime stage (no proto stage changes) | ✅ Correct approach |
| **IC3: Migrations exist?** | ✅ 2 files in extend-challenge-service/migrations/ | ✅ Verified |
| **IC4: Config files exist?** | ✅ challenges.json in both service config/ directories | ✅ Verified |
| **IC5: Config path env vars** | ✅ Backend: CHALLENGE_CONFIG_PATH, Handler: CONFIG_PATH | ✅ Verified in main.go |
| **IC6: DB_HOST** | Change from `localhost` to `postgres` in .env | ⚠️ Action needed |
| **IC7: Port conflicts** | Backend: 6565/8000/8080, Handler: 6566/8081 | ⚠️ Action needed |
| **IC8: Third party dir** | ✅ embed.go + swagger-ui/ in backend service | ✅ Verified |

**Required Changes**:
1. **Backend Dockerfile** (line ~70): Add COPY for config + migrations
2. **Event Handler Dockerfile** (line ~66): Add COPY for config
3. **.env file**: DB_HOST=postgres, add REWARD_CLIENT_MODE=mock
4. **docker-compose.yml**: Port mappings (handler on 6566:6565, 8081:8080)

**Status**: ✅ All concerns resolved, ready for Phase 8.0 implementation

---

### Implementation Details (NC1-NC5) - Final Decisions ✅

| Question | Decision | Implementation |
|----------|----------|----------------|
| **NC1: Migration impl** | Extract to helper function | Create `pkg/migrations/runner.go` with `RunMigrations(db *sql.DB)` |
| **NC2: Mode switch** | Fail-fast on invalid mode | Only accept "mock" or "real", crash otherwise |
| **NC3: Event simulator** | Use grpcurl for now | Defer CLI tool to Phase 8.1 |
| **NC4: Makefile targets** | Standard orchestration | dev-up, dev-down, dev-restart, dev-logs, dev-ps, dev-clean |
| **NC5: .env creation** | Root .env file | Single source of truth at `/home/ab/projects/extend-challenge/.env` |

**Key Implementation Notes**:
- **NC1**: Migration runner pattern from `tests/integration/setup_test.go` using `golang-migrate/migrate/v4`
- **NC2**: REWARD_CLIENT_MODE switch in backend service main.go (event handler doesn't use RewardClient)
- **NC3**: Manual grpcurl commands: `grpcurl -plaintext -d '{...}' localhost:6566 service/method`
- **NC5**: Root .env with DB_HOST=postgres, REWARD_CLIENT_MODE=mock, PLUGIN_GRPC_SERVER_AUTH_ENABLED=false

**Verification**:
- ✅ NewMockRewardClient() constructor exists in extend-challenge-common/pkg/client/mock_reward_client.go:35
- ✅ Health checks already defined in docker-compose.yml for postgres and redis

**Status**: ✅ All decisions made, ready for Phase 8.0 implementation

---

## Phase 8.0: Final Implementation Concerns (Round 5)

**Date**: 2025-10-20
**Context**: Last verification before implementation

### FC1: PostgreSQL Password Consistency

**Context**: docker-compose.yml and .env have different passwords

**Current State**:
- docker-compose.yml: `POSTGRES_PASSWORD: secretpassword`
- Planned .env: `DB_PASSWORD=postgres`

**Issue**: Services won't be able to connect to database due to password mismatch

**Recommendation**: Update docker-compose.yml to use env var
```yaml
postgres:
  environment:
    POSTGRES_PASSWORD: ${DB_PASSWORD:-postgres}
```

---

### FC2: .gitignore for .env

**Context**: Root .env file contains local dev configuration

**Question**: Should .env be gitignored?

**Verification**: ✅ Already handled
- Root .gitignore already contains `.env` (line 2)
- No action needed

---

### FC3: Event Handler REWARD_CLIENT_MODE

**Context**: Only backend service uses RewardClient

**Observation**: Event handler main.go doesn't use RewardClient (verified)

**Recommendation**:
- Don't add REWARD_CLIENT_MODE to event handler
- Document in .env that REWARD_CLIENT_MODE only applies to backend service
- Event handler .env only needs: DB_HOST, DB_PORT, CONFIG_PATH

---

### FC4: Migration Runner Error Handling

**Context**: Migration failures should crash service (fail-fast)

**Question**: Should we log migration details before crash?

**Recommendation**: Yes
```go
if err := migrations.RunMigrations(db); err != nil {
    logrus.Errorf("Failed to run database migrations: %v", err)
    logrus.Fatal("Service cannot start without successful migrations")
}
logrus.Info("Database migrations completed successfully")
```

---

### FC5: Docker Build Context

**Context**: Dockerfiles COPY config and migrations from relative paths

**Current Dockerfile build context**: `./extend-challenge-service`

**Question**: Are relative paths correct in Dockerfile?

**Analysis**:
- Build context is service root directory
- `COPY config /app/config` copies from `extend-challenge-service/config/`
- `COPY migrations /app/migrations` copies from `extend-challenge-service/migrations/`

**Recommendation**: ✅ Paths are correct, no changes needed

---

### Proposed Answers Summary (Round 5)

| Concern | Recommendation | Status |
|---------|---------------|--------|
| **FC1: DB password** | Use ${DB_PASSWORD} env var in docker-compose.yml | ⏳ Action needed |
| **FC2: .gitignore** | ✅ Already in root .gitignore | ✅ Verified |
| **FC3: Handler mode** | Don't add REWARD_CLIENT_MODE to handler | ⏳ Action needed |
| **FC4: Migration logging** | Log before fatal exit | ⏳ Action needed |
| **FC5: Build paths** | ✅ Already correct | ✅ Verified |

**Status**: ⏳ Awaiting user approval for FC1, FC3, FC4

---
