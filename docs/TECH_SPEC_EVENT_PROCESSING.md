# Technical Specification: Event Processing

**Version:** 2.0 (M5 Update)
**Date:** 2026-02-27
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Overview](#overview)
2. [Event Flow](#event-flow)
3. [Event Schemas](#event-schemas)
4. [Progress Mode Handling](#progress-mode-handling)
5. [Buffering Strategy](#buffering-strategy)
6. [Concurrency Control](#concurrency-control)
7. [Performance Optimization](#performance-optimization)
8. [Implementation Details](#implementation-details)

---

## Overview

### Event-Driven Architecture

The Challenge Service uses event-driven progress tracking where user actions in the game generate events that automatically update challenge progress without requiring explicit API calls from the game client.

### Key Benefits

- **Real-time Progress**: User progress updates within 0-1 seconds of action
- **Decoupled Design**: Game client doesn't need challenge-awareness
- **Scalable**: Event processing parallelizable across users
- **Idempotent**: Safe to process same event multiple times

### Event Handler Type

- **Framework**: AccelByte Extend Event Handler (gRPC)
- **Event Source**: AGS Kafka broker (fully abstracted by Extend platform)
- **Subscription**: Configured per-namespace topic subscription in Extend app config
- **Protocol**: gRPC calls (Extend platform consumes from Kafka and delivers events to your handler via gRPC)
- **Key Point**: You do NOT implement Kafka consumer code - Extend platform handles all Kafka operations

### Event Handler Implementation Pattern

**Key Discovery:** Extend platform abstracts Kafka completely - we only implement **gRPC OnMessage handlers**.

**Implementation Steps:**

1. **Download Event Proto Definitions**
   - Download from AGS proto repository: https://github.com/AccelByte/accelbyte-api-proto
   - Place in: `pkg/proto/accelbyte-asyncapi/`
   - Example paths:
     - IAM events: `iam/account/v1/account.proto`
     - Statistic events: `social/statistic/v1/statistic.proto`

2. **Generate Go Code from Proto**
   - Run template's `proto.sh` script (Docker-based protoc)
   - Generates: `pkg/pb/` with Go gRPC service interfaces

3. **Implement OnMessage Handler**
   ```go
   type LoginHandler struct {
       pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
       // Your dependencies (DB repo, cache, etc.)
   }

   func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
       // Process event
       return &emptypb.Empty{}, nil
   }
   ```

4. **Register Handler with gRPC Server**
   ```go
   // In main.go
   loginHandler := service.NewLoginHandler(...)
   pb.RegisterUserAuthenticationUserLoggedInServiceServer(grpcServer, loginHandler)
   ```

**No Kafka Code Needed:** Extend platform handles consumer groups, offset commits, retries, and dead letter queues.

---

## Event Flow

### High-Level Flow

```
User Action → Game Server → AGS Service → Kafka → Extend Platform → Your Event Handler → Update DB
     ↓              ↓            ↓           ↓           ↓                ↓                   ↓
"Kill enemy"   Stat API    Publishes    Topic    Consumes Kafka    gRPC Handler         PostgreSQL
                           event                  + delivers via    + Buffer
                                                  gRPC
```

**Key Architecture Points:**
- **Extend Platform**: Manages Kafka subscription, consumer groups, offset management
- **Your Handler**: Receives events via gRPC `HandleEvent(ctx, event)` method
- **No Kafka Code**: You never write Kafka consumer code - it's all abstracted away

**Event Subscriptions for Challenge Service:**
- Subscribe to `{namespace}.iam.account.v1.userLoggedIn` for login tracking
- Subscribe to `{namespace}.social.statistic.v1.statItemUpdated` for stat-based goals
- Configure subscriptions in Extend app deployment config

### Detailed Processing Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Event Arrives via gRPC                                   │
│    - Extend platform handles Kafka consumption              │
│    - Event delivered to HandleEvent(ctx, event)             │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Validate Event Schema                                     │
│    - Check required fields (user_id, namespace, payload)    │
│    - Validate event_type                                    │
│    - Extract stat updates from payload                      │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Acquire Per-User Mutex                                   │
│    - lock := userLocks[event.UserID]                        │
│    - lock.Lock() → prevents concurrent updates             │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Cache Lookup (O(1))                                      │
│    - goals := cache.GetGoalsByStatCode(stat_code)           │
│    - Returns all goals tracking this stat                   │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. For Each Matching Goal                                   │
│    ├─► Check if already claimed (skip if so)               │
│    ├─► Check prerequisites via cache                        │
│    ├─► If locked: skip                                      │
│    ├─► Calculate new status:                                │
│    │   - progress >= target → completed                     │
│    │   - progress < target → in_progress                    │
│    └─► Buffer update (map key: user_id:goal_id)            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. Release Per-User Mutex                                   │
│    - lock.Unlock()                                          │
│    - Other events for same user can now proceed             │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 7. Return Success                                           │
│    - Buffered updates will flush within 1 second            │
└─────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────┐
│ Periodic Flush (Every 1 Second)                             │
│    ├─► Acquire buffer lock                                  │
│    ├─► For each buffered update:                            │
│    │   - Execute UPSERT query                               │
│    │   - Delete from buffer map on success                  │
│    └─► Release buffer lock                                  │
└─────────────────────────────────────────────────────────────┘
```

### Error Handling in Flow

```
Event Processing Error
       │
       ├─► Transient Error (DB timeout, network)
       │   └─► Retry with exponential backoff (1s, 2s, 4s)
       │       └─► Max 3 retries
       │           └─► Dead Letter Queue (DLQ)
       │
       └─► Permanent Error (invalid schema, missing user)
           └─► Log error + send to DLQ (no retry)
```

---

## Event Schemas

### 1. AGS IAM Login Event

**Event Name:** `userLoggedIn`

**Topic:** `{namespace}.iam.account.v1.userLoggedIn` (verify actual topic format in your environment)

**Event Schema Reference:**
- Documentation: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/#userloggedin
- Proto Definition: https://github.com/AccelByte/accelbyte-api-proto/tree/main/asyncapi/accelbyte/iam/account/v1/account.proto

**Example Event Structure:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "namespace": "mygame",
  "userId": "abc123",
  "clientId": "game-client-id",
  "traceId": "trace-123",
  "sessionId": "session-456",
  "spanContext": "span-789",
  "payload": {
    "userId": "abc123",
    "namespace": "mygame",
    "displayName": "PlayerOne",
    "platformId": "steam",
    "platformUserId": "steam-user-123",
    "country": "US",
    "deviceId": "device-xyz"
  },
  "version": 1,
  "timestamp": "2025-10-15T10:00:00Z"
}
```

**Important:**
- Always refer to the official AccelByte API Events documentation for the exact schema
- Field names may vary (e.g., `userId` vs `user_id` depending on serialization)
- Use the proto definitions for type-safe implementation

**Mapping to Challenge:**
- Track login count: `stat_code: "login_count"`, `value: 1`
- Goal: "Daily Login" (complete 1 login per day)

### 2. AGS Statistic Update Event

**Event Name:** `statItemUpdated`

**Topic:** `{namespace}.social.statistic.v1.statItemUpdated` (verify actual topic format in your environment)

**Event Schema Reference:**
- Documentation: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/#statitemupdated
- Proto Definition: https://github.com/AccelByte/accelbyte-api-proto/tree/main/asyncapi/accelbyte/social/statistic/v1/statistic.proto

**Example Event Structure:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440001",
  "namespace": "mygame",
  "userId": "abc123",
  "clientId": "game-client-id",
  "traceId": "trace-123",
  "sessionId": "session-456",
  "spanContext": "span-789",
  "payload": {
    "userId": "abc123",
    "namespace": "mygame",
    "statCode": "snowman_kills",
    "statName": "Snowman Kills",
    "value": 7.0,
    "tags": ["combat", "winter-event"],
    "updatedAt": "2025-10-15T10:05:00Z",
    "additionalData": {
      "sessionId": "session-456",
      "platform": "steam"
    }
  },
  "version": 1,
  "timestamp": "2025-10-15T10:05:00Z"
}
```

**Important:**
- Always refer to the official AccelByte API Events documentation for the exact schema
- Field names may vary depending on serialization format
- Use the proto definitions for type-safe implementation

**Mapping to Challenges:**
- Extract `statCode`, `value`, and `inc` from payload
- Lookup matching goals via cache using `statCode`
- Create `StatUpdate{Value: &value, Inc: inc}` for the event processor
- `value` is absolute (cumulative), `inc` is the incremental delta

**Critical Design Decision:**
- AGS Statistic Service events provide both **absolute values** and **incremental deltas**
- Example: `"value": 7.0` means user has 7 total kills; `"inc": 3.0` means +3 from this event
- For absolute mode goals: progress = `value` (direct comparison against `target_value`)
- For relative mode goals: `inc` is used for baseline initialization (`baseline = value - inc`)
- Both fields are extracted and passed to the event processor as `StatUpdate`

### 3. Event Field Descriptions

**Note:** Field names depend on serialization format (protobuf vs JSON). Always verify with proto definitions.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string (UUID) | Yes | Unique event identifier for idempotency |
| `namespace` | string | Yes | AGS namespace (must match deployment) |
| `userId` | string | Yes | AGS user identifier |
| `clientId` | string | No | Client application identifier |
| `traceId` | string | No | Distributed tracing ID |
| `sessionId` | string | No | User session identifier |
| `payload` | object | Yes | Event-specific data (varies by event type) |
| `version` | integer | Yes | Event schema version |
| `timestamp` | string (ISO 8601) | Yes | When event was generated |

**Proto Definition Fields:**
- See https://github.com/AccelByte/accelbyte-api-proto for authoritative field names
- Proto messages use camelCase (e.g., `userId`, not `user_id`)
- JSON serialization may vary depending on configuration

---

## Progress Mode Handling

### Overview

**Updated in M5:** The event processing pipeline uses a unified 2-way routing model based on `ProgressMode` (not the legacy 3-way `GoalType` routing). Every event -- whether from AGS Statistic Service or IAM Login -- flows through a single `processGoal()` method that creates a `BufferedEvent` for the unified buffer.

The two progress modes are:

- **Absolute** (`progress_mode: "absolute"`): Progress equals the latest stat value directly (e.g., kills=100)
- **Relative** (`progress_mode: "relative"`): Progress is computed as `stat_value - baseline_value`, allowing the system to track incremental progress from when the user first engaged with the goal

### Progress Modes

#### 1. Absolute Mode (`"absolute"`)

**Use Case:** Track absolute stat values from AGS Statistic Service, or count login occurrences.

**Example Goals:**
- Kill 100 snowmen: `stat_code: "snowman_kills"`, `target_value: 100`
- Reach level 50: `stat_code: "player_level"`, `target_value: 50`
- Earn 10,000 coins: `stat_code: "total_coins"`, `target_value: 10000`

**Event Processing:**
```go
// For stat events: Progress = absolute stat value, IncValue = incremental change
bufferedEvent := &domain.BufferedEvent{
    UserID:       userID,
    GoalID:       goal.ID,
    ChallengeID:  goal.ChallengeID,
    Namespace:    namespace,
    Progress:     &statValue,        // Absolute stat value (e.g., 7)
    IncValue:     incValue,          // Incremental delta from event
    ProgressMode: domain.ProgressModeAbsolute,
}
```

**Database Operation:** UPSERT with absolute value replacement
```sql
-- Sets progress = 7 (not progress + 7)
progress = $progress_value
```

**Key Characteristics:**
- Events contain absolute values (not deltas)
- No accumulation needed - just replace with latest value
- Status calculated by comparing `progress >= target_value`
- For login events, `Progress` is nil and `IncValue` is 1; the SQL layer handles incrementing

#### 2. Relative Mode (`"relative"`)

**Use Case:** Track progress relative to a baseline established on first event. Useful for rotation scenarios where a user's stat is already at some value when a new rotation period begins.

**Example Goals:**
- Kill 50 snowmen this week (rotation): `stat_code: "snowman_kills"`, `target_value: 50`, `progress_mode: "relative"`
- Earn 1,000 coins this season: `stat_code: "total_coins"`, `target_value: 1000`, `progress_mode: "relative"`

**Event Processing:**
```go
// Same BufferedEvent creation, just with ProgressModeRelative
bufferedEvent := &domain.BufferedEvent{
    UserID:       userID,
    GoalID:       goal.ID,
    ChallengeID:  goal.ChallengeID,
    Namespace:    namespace,
    Progress:     &statValue,
    IncValue:     incValue,
    ProgressMode: domain.ProgressModeRelative,
}
```

**Database Operation:** SQL CASE handles baseline initialization
```sql
-- On first event: baseline = progress - inc_value
-- On subsequent events: progress = stat_value - baseline_value
-- See "SQL CASE Rotation Logic" section for full details
```

**Key Characteristics:**
- **Baseline initialization**: First event sets `baseline_value = stat_value - inc_value`
- **Progress computation**: `effective_progress = stat_value - baseline_value`
- **Rotation support**: When `expires_at < NOW()`, baseline resets for the new period
- **No client-side accumulation**: All computation happens in SQL

**Example Flow:**
```
User has 500 total kills when rotation starts
Event 1: stat_value=503, inc=3 → baseline=500, progress=3 (503-500)
Event 2: stat_value=510, inc=7 → baseline=500, progress=10 (510-500)
Event 3: stat_value=550, inc=40 → baseline=500, progress=50 (550-500) → completed!
```

### Unified processGoal() Routing

**Updated in M5:** The EventProcessor uses a single `processGoal()` method for ALL events. There is no longer a switch statement routing to different helper methods. Every goal, regardless of `ProgressMode`, creates a `BufferedEvent` and adds it to the unified buffer.

```go
func (p *EventProcessor) processGoal(userID, namespace string, goal *domain.Goal, statUpdate *domain.StatUpdate) {
    // Create BufferedEvent for unified buffer (same path for all progress modes)
    event := &domain.BufferedEvent{
        UserID:       userID,
        GoalID:       goal.ID,
        ChallengeID:  goal.ChallengeID,
        Namespace:    namespace,
        Progress:     statUpdate.Value,        // nil for login events, &statValue for stat events
        IncValue:     statUpdate.Inc,          // Always >= 1
        ProgressMode: goal.Requirement.ProgressMode,
    }

    // Add to unified buffer (single Add() method)
    p.bufferedRepo.Add(event)
}
```

**Key Design Points:**
- **No switch statement**: A single code path handles both `absolute` and `relative` modes
- **No separate helper methods**: The old `processAbsoluteGoal()`, `processIncrementGoal()`, `processDailyGoal()` methods are removed
- **ProgressMode from config**: Each goal declares its `progress_mode` in `Requirement.ProgressMode`
- **StatUpdate struct**: Encapsulates both `Value` (absolute) and `Inc` (incremental delta)
- **SQL handles complexity**: Status computation, baseline initialization, and rotation detection all happen in SQL CASE branches during batch flush

**M3+ Note:** The EventProcessor does NOT check `is_active` before buffering updates. This is delegated to the repository layer:
- `BatchUpsertProgressWithCOPY`: Has `WHERE is_active = true` check (production version)
- All batch methods consistently filter by assignment status
- Future optimization: EventProcessor could check `is_active` before buffering to reduce query parameters

### StatUpdate Extraction

The EventProcessor extracts a `StatUpdate` struct from each incoming event before passing it to `processGoal()`:

```go
type StatUpdate struct {
    Value *int  // Absolute stat value (nil for login events)
    Inc   int   // Incremental change (always >= 1)
}
```

**For AGS Statistic events:**
```go
statUpdate := &domain.StatUpdate{
    Value: &msg.Payload.StatValue,  // Absolute value from AGS (e.g., 503)
    Inc:   msg.Payload.Inc,         // Incremental delta from AGS (e.g., 3)
}
```

**For IAM Login events:**
```go
statUpdate := &domain.StatUpdate{
    Value: nil,  // No absolute stat value for login events
    Inc:   1,    // Synthetic: each login counts as 1
}
```

### Inc Field Extraction

**Added in M5:** The `Inc` field is critical for baseline computation in relative mode goals.

**AGS Statistic Events:**
- The AGS statistic update event payload includes an `inc` field representing the incremental change
- Example: If a user had 500 kills and got 3 more, the event contains `value=503` and `inc=3`
- The event processor extracts `msg.Payload.Inc` directly

**IAM Login Events:**
- Login events are binary (no stat payload), so a synthetic `incValue = 1` is used
- Each login occurrence counts as exactly 1 increment
- This synthetic value is used for baseline computation: `baseline = progress - inc_value`

**Why Inc Matters:**
- For absolute mode: `Inc` is stored but not used for progress computation (progress = stat value)
- For relative mode: `Inc` is essential for baseline initialization (`baseline = first_stat_value - inc_value`)
- The `Inc` value ensures the baseline is correctly set to the user's stat value *before* the triggering event

### Baseline Initialization

**Added in M5:** Relative mode goals require a baseline to compute progress. The baseline is initialized on the first event for each user-goal pair.

**How It Works:**
1. First event arrives for a relative-mode goal (e.g., stat_value=503, inc=3)
2. SQL detects `baseline_value IS NULL AND progress_mode = 'relative'`
3. SQL sets `baseline_value = stat_value - inc_value` (e.g., 503 - 3 = 500)
4. Progress is computed as `stat_value - baseline_value` (e.g., 503 - 500 = 3)

**SQL CASE branch:**
```sql
baseline_value = CASE
    -- First event for relative mode: initialize baseline
    WHEN ugp.baseline_value IS NULL AND t.progress_mode = 'relative'
        THEN t.progress - t.inc_value
    -- Rotation boundary: reset baseline for new period
    WHEN ugp.expires_at IS NOT NULL AND ugp.expires_at < NOW() AND t.progress_mode = 'relative'
        THEN t.progress - t.inc_value
    -- Otherwise: keep existing baseline
    ELSE ugp.baseline_value
END
```

**Key Points:**
- Baseline is set lazily (on first event, not on initialization)
- The formula `stat_value - inc_value` gives the user's stat value *before* the triggering event
- For login events (Progress=nil, Inc=1), baseline defaults to 0 (progress starts from 0)
- On rotation boundary (`expires_at < NOW()`), baseline resets to allow fresh progress tracking

### SQL CASE Rotation Logic

**Added in M5:** The batch UPDATE query (`BatchUpsertProgressWithCOPY`) uses SQL CASE branches to handle rotation boundaries, baseline initialization, and status computation in a single database round trip.

**Overview of SQL CASE branches:**

1. **Baseline initialization** (described above): Sets baseline on first event or rotation boundary
2. **Rotation detection**: When `expires_at IS NOT NULL AND expires_at < NOW()`, the goal has crossed a rotation boundary
   - Baseline resets: `baseline = stat_value - inc_value`
   - Progress resets: Computed from new baseline
   - Status resets: Re-evaluated against target
   - `expires_at` updates to next rotation period
3. **Status computation**: `CASE WHEN progress >= target THEN 'completed' ELSE 'in_progress' END`
4. **Claimed protection**: Skip updates for rows with `status = 'claimed'` (unless `allowReselection` is enabled for the goal)

**See [TECH_SPEC_M5.md](./TECH_SPEC_M5.md) for the full SQL query and detailed rotation logic.**

### Event to Progress Mode Mapping

| Event Type | Value Field | Inc Field | Progress Mode | Repository Method | Use Case |
|------------|-------------|-----------|---------------|-------------------|----------|
| Statistic Update | `payload.value` (absolute) | `payload.inc` (delta) | `absolute` | `Add(BufferedEvent)` | Kill 100 snowmen (lifetime) |
| Statistic Update | `payload.value` (absolute) | `payload.inc` (delta) | `relative` | `Add(BufferedEvent)` | Kill 50 snowmen this week |
| IAM Login | `nil` | `1` (synthetic) | `absolute` | `Add(BufferedEvent)` | Login 5 times total |
| IAM Login | `nil` | `1` (synthetic) | `relative` | `Add(BufferedEvent)` | Login 10 times this season |

### Configuration Examples

**Example 1: Stat-Based Goal (Absolute Mode)**
```json
{
  "id": "kill-100-snowmen",
  "name": "Snowman Hunter",
  "requirement": {
    "stat_code": "snowman_kills",
    "operator": ">=",
    "target_value": 100,
    "progressMode": "absolute"
  },
  "reward": {
    "type": "ITEM",
    "item_id": "rare_weapon_skin",
    "quantity": 1
  }
}
```

**Example 2: Stat-Based Goal (Relative Mode - Rotation)**
```json
{
  "id": "weekly-snowman-kills",
  "name": "Weekly Snowman Hunter",
  "requirement": {
    "stat_code": "snowman_kills",
    "operator": ">=",
    "target_value": 50,
    "progressMode": "relative"
  },
  "rotation": {
    "type": "weekly",
    "day_of_week": "monday"
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "GOLD",
    "amount": 200
  }
}
```

**Example 3: Login Goal (Absolute Mode)**
```json
{
  "id": "login-5-times",
  "name": "Frequent Player",
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 5,
    "progressMode": "absolute"
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "GOLD",
    "amount": 100
  }
}
```

**Example 4: Login Goal (Relative Mode - Seasonal Rotation)**
```json
{
  "id": "seasonal-login-challenge",
  "name": "Seasonal Dedication",
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 30,
    "progressMode": "relative"
  },
  "rotation": {
    "type": "custom",
    "duration_days": 90
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "PREMIUM_CURRENCY",
    "amount": 500
  }
}
```

**Key Differences in Configuration:**

| Progress Mode | Config Example | Baseline | Rotation Support | Use Case |
|---------------|----------------|----------|------------------|----------|
| Absolute | `"progressMode": "absolute"` | N/A (progress = stat value) | No (lifetime tracking) | Kill 100 snowmen total |
| Relative | `"progressMode": "relative"` | Set on first event | Yes (baseline resets) | Kill 50 snowmen this week |

### Design Benefits

1. **Simplicity**: 2-way routing (not 3-way) reduces code complexity
2. **Unified buffer**: Single `BufferedEvent` struct and single `Add()` method for all events
3. **SQL-driven logic**: Status, baseline, and rotation handled in SQL (not Go code)
4. **Rotation support**: Relative mode enables time-based rotation with baseline reset
5. **Extensibility**: New progress modes can be added by extending the SQL CASE branches

### Migration Path

**From M1-M4 (GoalType) to M5 (ProgressMode):**

The old `type` field (`absolute`, `increment`, `daily`) is replaced by `progress_mode` in the requirement:

| Old Config (M1-M4) | New Config (M5) |
|---------------------|-----------------|
| `"type": "absolute"` | `"progressMode": "absolute"` |
| `"type": "increment"` | `"progressMode": "relative"` (or `"absolute"` for lifetime counters) |
| `"type": "daily"` | Use rotation config with `"progressMode": "relative"` |
| `"type": "increment", "daily": true` | Use rotation config with `"progressMode": "relative"` |

**Backward compatibility:** If `progress_mode` is missing from goal config, it defaults to `"absolute"`.

```go
func (v *Validator) validateGoal(goal *domain.Goal) error {
    // Default to absolute if progress_mode not specified
    if goal.Requirement.ProgressMode == "" {
        goal.Requirement.ProgressMode = domain.ProgressModeAbsolute
    }

    // Validate progress_mode
    validModes := []domain.ProgressMode{
        domain.ProgressModeAbsolute,
        domain.ProgressModeRelative,
    }

    if !contains(validModes, goal.Requirement.ProgressMode) {
        return fmt.Errorf("invalid progress_mode: %s", goal.Requirement.ProgressMode)
    }

    return nil
}
```

**See Also:**
- [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md) - Progress mode schema and validation
- [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md) - SQL CASE rotation queries
- [TECH_SPEC_M5.md](./TECH_SPEC_M5.md) - Full M5 rotation specification
- [BRAINSTORM.md](./BRAINSTORM.md) - Design decision history

---

## LoginHandler Implementation (Phase 5.2.3)

**Status:** Ready for implementation
**Est. Time:** 2 hours
**Test Coverage Target:** 80%+

### Overview

The LoginHandler processes IAM login events and updates progress for login-based goals. Instead of string matching or database lookups, goals explicitly declare their `event_source` in the config file, making routing simple and type-safe.

### Design Decisions (Q1-Q6)

#### Q1: Event Source Routing ✅

**Decision:** Add `event_source` field to goal config (not string matching)

**Rationale:**
- Explicit and type-safe (no brittle string matching on `stat_code`)
- Clear separation of event types in config
- Easy to add new event sources in future (e.g., `achievement`, `matchmaking`)

**Implementation:**
```json
{
  "id": "daily-login",
  "event_source": "login",
  "requirement": {"stat_code": "login_daily", "target_value": 1, "progressMode": "absolute"}
}
```

**Config Validation:**
- `event_source` is required (no default)
- Must be `"login"` or `"statistic"`
- See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md#event-sources)

#### Q2: Login Event Stat Value ✅

**Decision:** Always use `Inc = 1` and `Value = nil` for login events

**Rationale:**
- Login is a binary event (happened or not)
- Each login counts as 1 increment (`Inc = 1`)
- No absolute stat value available for login events (`Value = nil`)
- The `Inc` value is used for baseline computation in relative mode

**Implementation:**
```go
func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    // Create StatUpdate with synthetic values for login events
    statUpdate := &domain.StatUpdate{
        Value: nil,  // No absolute stat value for login
        Inc:   1,    // Synthetic: each login counts as 1
    }

    // Find all login-triggered goals
    goals := h.goalCache.GetAllGoals()
    for _, goal := range goals {
        if goal.EventSource == domain.EventSourceLogin {
            h.processor.ProcessGoal(userID, namespace, goal, statUpdate)
        }
    }

    return &emptypb.Empty{}, nil
}
```

#### Q3: Goal Filtering Strategy ✅

**Decision:** Process ALL login goals from config (Option A)

**Rationale:**
- M1 has simple fixed challenges (no challenge lifecycle/status)
- No need for challenge activation filtering
- Simpler implementation (stateless, just iterate config)
- Challenge filtering comes in M3 (time-based challenges)

**Implementation:**
```go
// No filtering - process all goals with event_source="login"
goals := h.goalCache.GetAllGoals()
for _, goal := range goals {
    if goal.EventSource == domain.EventSourceLogin {
        // Process this goal
    }
}
```

#### Q4: Error Handling Strategy ✅

**Decision:** Option A with buffer check (graceful degradation + critical error handling)

**Error Handling:**
- **EventProcessor errors**: Log and continue (fire-and-forget, eventual consistency)
- **Buffer full / event rejected**: Return gRPC error (event not consumed, Extend platform will retry)
- **Goal lookup failures**: Log warning and skip (config may be temporarily unavailable)

**Implementation:**
```go
func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    userID := msg.UserId

    // Find all login goals
    goals := h.goalCache.GetAllGoals()

    for _, goal := range goals {
        if goal.EventSource != domain.EventSourceLogin {
            continue
        }

        // Process event (returns error if buffer full/rejected)
        err := h.processor.ProcessEvent(userID, goal.ID, 1)
        if err != nil {
            // Critical error - event cannot be buffered
            h.logger.Error("Failed to process login event, returning error for retry",
                "userID", userID,
                "goalID", goal.ID,
                "error", err)
            return nil, status.Errorf(codes.Internal, "failed to buffer event: %v", err)
        }
    }

    // Success - event fully processed
    return &emptypb.Empty{}, nil
}
```

**Extend Platform Retry Behavior:**
- If handler returns error, Extend platform will retry event delivery
- This ensures no events are lost if buffer is temporarily full
- Event marked consumed only on successful return

#### Q5: AGS SDK Dependencies ✅

**Decision:** Option A - Remove unused imports, document future use

**Current Implementation (M1):**
- Remove all AGS Platform SDK imports (no reward granting yet)
- LoginHandler only updates progress via EventProcessor
- Keep template's OAuth client setup in main.go (needed for future phases)

**Future Use (Phase 7: AGS Integration):**
- RewardClient will use AGS Platform SDK for item/wallet grants
- Will add back imports:
  ```go
  "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/fulfillment"
  "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/platform"
  ```
- For implementation, use Extend SDK MCP Server to find correct functions:
  - `mcp__extend-sdk-mcp-server__search_functions` with query "entitlement grant"
  - `mcp__extend-sdk-mcp-server__search_functions` with query "wallet credit"

**Code Comments:**
```go
// LoginHandler processes IAM login events and updates challenge progress.
// Note: This handler does NOT grant rewards (rewards granted via REST API claim endpoint).
// For reward implementation, see Phase 7: AGS Integration.
type LoginHandler struct {
    pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
    processor  *processor.EventProcessor
    goalCache  cache.GoalCache
    logger     *logrus.Logger
}
```

#### Q6: Test Strategy ✅

**Decision:** Mock-based unit tests (sufficient for M1)

**Test Coverage (15+ test cases):**

1. **Event Processing Tests:**
   - ✅ Valid login event → processes all login goals
   - ✅ Login event with 3 login goals → ProcessEvent called 3 times with statValue=1
   - ✅ Login event with no login goals → no ProcessEvent calls
   - ✅ Mixed goals (login + statistic) → only login goals processed

2. **Error Handling Tests:**
   - ✅ ProcessEvent returns error → gRPC error returned
   - ✅ ProcessEvent succeeds → empty response returned
   - ✅ Goal cache empty → empty response (no errors)
   - ✅ Goal cache returns error → warning logged, empty response

3. **Event Parsing Tests:**
   - ✅ Extract userID from UserLoggedIn message
   - ✅ Nil message → error returned
   - ✅ Empty userID in message → error returned

4. **Integration Tests (with mocks):**
   - ✅ End-to-end: login event → goal lookup → ProcessEvent → buffer → flush
   - ✅ Multiple login events same user → buffer accumulates correctly
   - ✅ Buffer full error → gRPC error propagated

5. **Event Source Filtering Tests:**
   - ✅ Only event_source="login" goals processed
   - ✅ event_source="statistic" goals ignored
   - ✅ Mixed event sources → correct filtering

**Mocking Strategy:**
```go
// Use testify/mock for interfaces
mockProcessor := new(MockEventProcessor)
mockGoalCache := new(MockGoalCache)

// Setup expectations
mockGoalCache.On("GetAllGoals").Return([]*domain.Goal{...})
mockProcessor.On("ProcessEvent", "user123", "daily-login", 1).Return(nil)

// Create handler with mocks
handler := NewLoginHandler(mockProcessor, mockGoalCache, logger)

// Test
resp, err := handler.OnMessage(ctx, loginEvent)

// Verify
mockProcessor.AssertExpectations(t)
```

**Integration Tests (Future - Phase 8):**
- Real EventProcessor + BufferedRepository + PostgreSQL (testcontainers)
- End-to-end: IAM event → DB flush → verify progress updated

### LoginHandler Structure

```go
// extend-challenge-event-handler/pkg/service/loginHandler.go

package service

import (
    "context"
    pb "extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/iam/account/v1"
    "extend-challenge-event-handler/pkg/processor"
    "extend-challenge-common/pkg/cache"
    "extend-challenge-common/pkg/domain"

    "github.com/sirupsen/logrus"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
    "google.golang.org/protobuf/types/known/emptypb"
)

// LoginHandler processes IAM login events and updates challenge progress.
// This handler does NOT grant rewards (rewards granted via REST API claim endpoint).
type LoginHandler struct {
    pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
    processor  *processor.EventProcessor
    goalCache  cache.GoalCache
    logger     *logrus.Logger
}

func NewLoginHandler(
    processor *processor.EventProcessor,
    goalCache cache.GoalCache,
    logger *logrus.Logger,
) *LoginHandler {
    return &LoginHandler{
        processor: processor,
        goalCache: goalCache,
        logger:    logger,
    }
}

func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    // Validation
    if msg == nil {
        return nil, status.Error(codes.InvalidArgument, "message cannot be nil")
    }

    userID := msg.UserId
    if userID == "" {
        return nil, status.Error(codes.InvalidArgument, "userId cannot be empty")
    }

    h.logger.Info("Processing login event",
        "userID", userID,
        "eventID", msg.Id,
        "timestamp", msg.Timestamp)

    // Find all login-triggered goals
    goals := h.goalCache.GetAllGoals()
    if goals == nil {
        h.logger.Warn("Goal cache returned nil, skipping event processing")
        return &emptypb.Empty{}, nil
    }

    // Process each login goal
    for _, goal := range goals {
        if goal.EventSource != domain.EventSourceLogin {
            continue
        }

        h.logger.Debug("Processing login goal",
            "userID", userID,
            "goalID", goal.ID,
            "challengeID", goal.ChallengeID,
            "progressMode", goal.Requirement.ProgressMode)

        // Create StatUpdate: Value=nil, Inc=1 for login events (Decision Q2)
        statUpdate := &domain.StatUpdate{Value: nil, Inc: 1}
        err := h.processor.ProcessGoal(userID, namespace, goal, statUpdate)
        if err != nil {
            // Buffer full or critical error - return error for Extend platform retry
            h.logger.Error("Failed to process login event, returning error for retry",
                "userID", userID,
                "goalID", goal.ID,
                "error", err)
            return nil, status.Errorf(codes.Internal, "failed to buffer event: %v", err)
        }
    }

    h.logger.Info("Successfully processed login event",
        "userID", userID,
        "goalsProcessed", h.countLoginGoals(goals))

    return &emptypb.Empty{}, nil
}

func (h *LoginHandler) countLoginGoals(goals []*domain.Goal) int {
    count := 0
    for _, goal := range goals {
        if goal.EventSource == domain.EventSourceLogin {
            count++
        }
    }
    return count
}
```

### Main.go Integration

Replace template loginHandler initialization with challenge-specific implementation:

```go
// In main.go

// Create EventProcessor (already initialized in Phase 5.2.2d)
eventProcessor := processor.NewEventProcessor(bufferedRepo, goalCache, namespace, logrusLogger)

// Create LoginHandler (replaces template handler)
loginHandler := service.NewLoginHandler(eventProcessor, goalCache, logrusLogger)

// Register with gRPC server
pb.RegisterUserAuthenticationUserLoggedInServiceServer(s, loginHandler)
```

**Remove from main.go:**
- Template's OAuth service account setup for Platform SDK (not needed in M1)
- Template's FulfillmentService initialization (will add in Phase 7)
- `ITEM_ID_TO_GRANT` environment variable

**Keep in main.go:**
- Database connection (already added in Phase 5.1)
- Config loader and goal cache (already added in Phase 5.1)
- BufferedRepository (already added in Phase 5.2.2c)
- EventProcessor (already added in Phase 5.2.2d)

### Test File Structure

```go
// extend-challenge-event-handler/pkg/service/loginHandler_test.go

package service

import (
    "context"
    "testing"

    pb "extend-challenge-event-handler/pkg/pb/accelbyte-asyncapi/iam/account/v1"
    "extend-challenge-common/pkg/domain"

    "github.com/sirupsen/logrus"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
)

// Mock implementations
type MockEventProcessor struct {
    mock.Mock
}

func (m *MockEventProcessor) ProcessEvent(userID, goalID string, statValue int) error {
    args := m.Called(userID, goalID, statValue)
    return args.Error(0)
}

type MockGoalCache struct {
    mock.Mock
}

func (m *MockGoalCache) GetAllGoals() []*domain.Goal {
    args := m.Called()
    return args.Get(0).([]*domain.Goal)
}

// Test cases
func TestLoginHandler_OnMessage_Success(t *testing.T) {
    // Setup mocks
    mockProcessor := new(MockEventProcessor)
    mockCache := new(MockGoalCache)

    // Test data
    loginGoal := &domain.Goal{
        ID: "daily-login",
        ChallengeID: "daily-quests",
        EventSource: domain.EventSourceLogin,
        Requirement: domain.Requirement{
            ProgressMode: domain.ProgressModeAbsolute,
        },
    }

    mockCache.On("GetAllGoals").Return([]*domain.Goal{loginGoal})
    statUpdate := &domain.StatUpdate{Value: nil, Inc: 1}
    mockProcessor.On("ProcessGoal", "user123", mock.Anything, loginGoal, statUpdate).Return(nil)

    // Create handler
    handler := NewLoginHandler(mockProcessor, mockCache, logrus.New())

    // Execute
    msg := &pb.UserLoggedIn{UserId: "user123", Id: "event-123"}
    resp, err := handler.OnMessage(context.Background(), msg)

    // Assert
    assert.NoError(t, err)
    assert.NotNil(t, resp)
    mockProcessor.AssertExpectations(t)
    mockCache.AssertExpectations(t)
}

// ... 15+ more test cases
```

### Implementation Checklist

- [ ] Remove template loginHandler.go implementation
- [ ] Create new LoginHandler struct with EventProcessor + GoalCache dependencies
- [ ] Implement OnMessage method with event source filtering
- [ ] Extract userID from proto message
- [ ] Call ProcessEvent for each login goal with statValue=1
- [ ] Implement error handling (log + return gRPC error on buffer full)
- [ ] Update main.go to wire new LoginHandler
- [ ] Write 15+ unit tests with mocks
- [ ] Run linter: `golangci-lint run ./...`
- [ ] Verify 80%+ coverage: `go test -coverprofile=coverage.out`
- [ ] Test end-to-end (optional): Mock IAM event → buffer → verify ProcessEvent called

### Performance Expectations

- **Event processing time**: < 1ms (in-memory cache lookup + buffer write)
- **Throughput**: 10,000+ login events/sec per replica
- **Memory overhead**: Minimal (no event queuing, immediate buffer write)

**See Also:**
- [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md#event-sources) - Event source config
- [TECH_SPEC_TESTING.md](./TECH_SPEC_TESTING.md) - LoginHandler test strategy
- [STATUS.md](./STATUS.md) - Phase 5.2.3 implementation status

---

## Buffering Strategy

### Overview

The buffering strategy uses a **dual-trigger flush mechanism** to balance throughput and safety:

1. **Time-Based Flush**: Every 1 second (handles steady-state traffic)
2. **Size-Based Flush**: When buffer reaches 1,000 entries (handles burst traffic)

Whichever condition is met first triggers the flush. This provides:
- **High throughput**: Batch 1,000s of updates into single DB query
- **Memory safety**: Bounded buffer size prevents OOM crashes
- **Low latency**: Consistent ~20ms flush time
- **Burst resilience**: Handles traffic spikes gracefully

### Problem Statement

Without buffering:
- 1,000 events/sec → 1,000 DB queries/sec
- High database load
- Potential connection pool exhaustion

With time-based buffering only:
- 1,000 events/sec → ~10 DB queries/sec (100x reduction)
- Map-based deduplication (last update wins)
- Eventual consistency with 0-1 second delay
- **Risk**: Unbounded memory growth during burst traffic

With time-based + size-based buffering (recommended):
- **Flush triggers**: Every 1 second OR when buffer reaches 1,000 entries (whichever comes first)
- **Burst protection**: Prevents memory exhaustion during traffic spikes
- **Bounded data loss**: Maximum 1,000 updates lost on crash (vs unlimited)
- **Predictable performance**: Flush time stays under 20ms even during bursts

### BufferedRepository Design

**Updated in M5:** The BufferedRepository uses a single unified buffer of `*domain.BufferedEvent` entries. The old multi-buffer design (separate maps for absolute, increment, and daily-increment goals) has been replaced with a single `map[string]*domain.BufferedEvent`.

```go
type BufferedRepository struct {
    buffer        map[string]*domain.BufferedEvent  // key: "userID:goalID"
    mu            sync.Mutex
    ticker        *time.Ticker
    repo          GoalRepository
    logger        *log.Logger
    maxBufferSize int  // Maximum entries before forcing flush
}

func NewBufferedRepository(repo GoalRepository, flushInterval time.Duration, maxBufferSize int) *BufferedRepository {
    r := &BufferedRepository{
        buffer:        make(map[string]*domain.BufferedEvent),
        ticker:        time.NewTicker(flushInterval),
        repo:          repo,
        maxBufferSize: maxBufferSize,  // Default: 1000
    }

    go r.startFlusher()

    return r
}
```

**BufferedEvent struct:**
```go
type BufferedEvent struct {
    UserID       string
    GoalID       string
    ChallengeID  string
    Namespace    string
    Progress     *int          // Absolute stat value (nil for login events)
    IncValue     int           // Increment delta; always >= 1
    ProgressMode ProgressMode  // "absolute" or "relative"
}
```

### Buffer Operations

#### 1. Add (Write to Buffer)

**Updated in M5:** The single `Add()` method replaces the old `UpdateProgress()` and `IncrementProgress()` methods. All events use the same entry point.

```go
func (r *BufferedRepository) Add(event *domain.BufferedEvent) {
    r.mu.Lock()
    defer r.mu.Unlock()

    key := fmt.Sprintf("%s:%s", event.UserID, event.GoalID)

    // Overwrite previous buffered event (deduplication: latest event wins)
    r.buffer[key] = event

    // Size-based flush: trigger flush if buffer exceeds threshold
    if len(r.buffer) >= r.maxBufferSize {
        r.logger.Warn("Buffer size threshold reached, triggering flush",
            "size", len(r.buffer),
            "threshold", r.maxBufferSize)
        // Async flush to avoid blocking event processing
        go r.Flush()
    }
}
```

**Key Features:**
- Single `Add()` method for all event types (stat updates and login events)
- Map key `"userID:goalID"` ensures only one pending event per user-goal pair
- Latest event overwrites previous (map-based deduplication)
- **Dual flush triggers**: Time-based (1s) OR size-based (1000 entries)
- Size-based flush runs async to avoid blocking event processing

#### 2. Flush (Periodic Write to DB)

```go
func (r *BufferedRepository) startFlusher() {
    for range r.ticker.C {
        r.Flush()
    }
}

func (r *BufferedRepository) Flush() error {
    r.mu.Lock()

    // Swap pattern: Copy buffer reference and create new empty buffer
    // This allows us to release the lock immediately (faster unlock)
    bufferToFlush := r.buffer
    r.buffer = make(map[string]*domain.BufferedEvent)

    r.mu.Unlock()  // Release lock BEFORE processing

    // Early return if nothing to flush
    if len(bufferToFlush) == 0 {
        return nil
    }

    r.logger.Info("Flushing buffered events", "count", len(bufferToFlush))

    // Collect all buffered events (outside lock)
    events := make([]*domain.BufferedEvent, 0, len(bufferToFlush))
    for _, event := range bufferToFlush {
        events = append(events, event)
    }

    // Single COPY flush: BatchUpsertProgressWithCOPY handles all event types
    err := r.repo.BatchUpsertProgressWithCOPY(context.Background(), events)
    if err != nil {
        r.logger.Error("Failed to flush batch", "count", len(events), "error", err)

        // Re-acquire lock to restore failed events for retry
        r.mu.Lock()
        for key, event := range bufferToFlush {
            // Only restore if not already updated by newer event
            if _, exists := r.buffer[key]; !exists {
                r.buffer[key] = event
            }
        }
        r.mu.Unlock()

        return err
    }

    r.logger.Info("Successfully flushed events", "count", len(events))
    return nil
}
```

**Key Improvements:**
- ✅ Single database round trip for entire batch
- ✅ All-or-nothing flush (transaction-based)
- ✅ Much faster: 1000 updates in ~10-20ms vs 1000ms

**Error Handling:**
- Failed batch keeps ALL updates in buffer
- Will retry entire batch on next flush (1 second later)
- Trade-off: One bad row fails entire batch (acceptable for retry logic)

**Implementation Notes:**
- Flush method must be idempotent (can be called from multiple goroutines)
- Use mutex to prevent concurrent flushes from racing
- Async flush (via `go r.Flush()`) doesn't block event processing
- If size-based flush is running and time-based flush triggers, only one proceeds

#### 3. Force Flush (Claim Flow)

```go
func (r *BufferedRepository) ForceFlush() error {
    // Block until flush completes
    r.Flush()
    return nil
}
```

**Usage:** Called before claim flow to ensure latest progress is in DB

#### 4. Buffer Overflow Protection

**Problem:** During prolonged database outages, buffer could grow unbounded and cause OOM crashes.

**Solution:** Overflow protection at 2x threshold prevents unbounded growth.

```go
func (r *BufferedRepository) Add(event *domain.BufferedEvent) error {
    // Input validation
    if event == nil {
        return fmt.Errorf("event cannot be nil")
    }
    if event.UserID == "" {
        return fmt.Errorf("userID cannot be empty")
    }
    if event.GoalID == "" {
        return fmt.Errorf("goalID cannot be empty")
    }

    r.mu.Lock()
    defer r.mu.Unlock()

    // Check for buffer overflow (2x threshold)
    // This prevents unbounded memory growth during prolonged database outages
    if len(r.buffer) >= r.maxBufferSize*2 {
        r.logger.WithFields(logrus.Fields{
            "buffer_size": len(r.buffer),
            "max_allowed": r.maxBufferSize * 2,
            "user_id":     event.UserID,
            "goal_id":     event.GoalID,
        }).Error("Buffer overflow: too many failed flushes")
        return fmt.Errorf("buffer overflow: size %d exceeds max %d (database may be unavailable)", len(r.buffer), r.maxBufferSize*2)
    }

    key := fmt.Sprintf("%s:%s", event.UserID, event.GoalID)
    r.buffer[key] = event

    // ... rest of implementation (size-based flush check)
}
```

**Overflow Protection Characteristics:**

| Aspect | Value | Notes |
|--------|-------|-------|
| **Threshold** | 2x maxBufferSize | Default: 2000 entries (for maxBufferSize=1000) |
| **Memory at overflow** | ~400KB | 200 bytes/entry × 2000 entries |
| **Behavior** | Return error | Signals system degradation to caller |
| **Benefit** | Prevents OOM | System remains stable during DB outages |

**Failure Scenario Example:**
- Database down for 5 minutes during high traffic (1,000 events/sec)
- Without protection: 300,000 buffered entries (~60MB) → OOM risk
- With protection: Caps at 2,000 entries (~400KB) → returns error after limit
- Operations team can monitor overflow errors and take action

**Design Choice:**
- **Chosen approach**: Return error (not drop oldest entries)
- **Rationale**:
  - Provides clear signal that system is degraded
  - Allows event handler to implement backpressure patterns
  - Prevents silent data loss
  - Error can be logged and alerted on

#### 5. Goroutine Flood Prevention

**Problem:** During burst traffic, multiple size-based flush goroutines could spawn before first flush completes.

**Solution:** Atomic flag ensures only one async flush runs at a time.

```go
type BufferedRepository struct {
    // ... existing fields

    // flushInProgress tracks if an async flush is currently running
    // Prevents goroutine spawning flood during burst traffic
    flushInProgress atomic.Bool
}

func (r *BufferedRepository) Add(event *domain.BufferedEvent) error {
    // ... validation and buffering logic

    // Early return if buffer size is below threshold
    if len(r.buffer) < r.maxBufferSize {
        return nil
    }

    // Try to acquire flush lock (non-blocking)
    // Only spawn goroutine if no flush is already in progress
    if !r.flushInProgress.CompareAndSwap(false, true) {
        // Flush already in progress, skip spawning another goroutine
        r.logger.Debug("Size-based flush skipped: flush already in progress")
        return nil
    }

    // Size threshold reached and no flush in progress - trigger async flush
    r.logger.WithFields(logrus.Fields{
        "buffer_size": len(r.buffer),
        "threshold":   r.maxBufferSize,
    }).Warn("Buffer size threshold reached, triggering async flush")

    // Async flush to avoid blocking event processing
    go func() {
        defer r.flushInProgress.Store(false)

        if err := r.Flush(context.Background()); err != nil {
            r.logger.WithError(err).Error("Async size-based flush failed")
        }
    }()

    return nil
}
```

**Benefits:**
- **Resource efficiency**: No wasted goroutine creation during bursts
- **Predictable behavior**: At most one async flush at a time
- **Lower lock contention**: Fewer goroutines competing for flush mutex
- **Better performance**: Reduced CPU and memory usage during traffic spikes

**Burst Scenario Example:**
- Without protection: 5,000 events in 100ms → spawns ~5 flush goroutines
- With protection: 5,000 events in 100ms → spawns 1 flush goroutine, others skip
- Result: Same functionality, lower resource usage

#### 6. Configuration

**Environment Variables:**

```bash
# Time-based flush (existing)
BUFFER_FLUSH_INTERVAL=1s        # How often to flush buffer (default: 1 second)

# Size-based flush (new)
BUFFER_MAX_SIZE=1000            # Max entries before forcing flush (default: 1000)
```

**Recommended Thresholds:**

| Threshold | Use Case | Flush Time | Memory Usage |
|-----------|----------|------------|--------------|
| **1,000** | **Recommended** | ~10-20ms | ~200KB |
| 5,000 | High throughput | ~50-100ms | ~1MB |
| 10,000 | Very high throughput | ~100-200ms | ~2MB |

**Decision Factors:**
- **Lower threshold** (500-1,000): Better burst protection, lower data loss risk, faster flush
- **Higher threshold** (5,000-10,000): Better deduplication, fewer DB round trips, higher throughput

**Start with 1,000** and tune based on your workload:
- If seeing frequent size-based flushes → increase threshold
- If seeing memory pressure → decrease threshold
- If seeing long flush times (>100ms) → decrease threshold

### Unified Buffer Architecture (M5)

**Updated in M5:** The old multi-buffer design (separate `buffer`, `bufferIncrement`, `bufferIncrementDaily` maps) has been replaced with a single unified buffer. All event types flow through one `Add()` method and one `Flush()` method, with all complexity delegated to SQL CASE branches in the `BatchUpsertProgressWithCOPY` query.

#### Single Buffer Design

```go
type BufferedRepository struct {
    buffer        map[string]*domain.BufferedEvent  // key: "userID:goalID"
    mu            sync.Mutex
    ticker        *time.Ticker
    repo          GoalRepository
    maxBufferSize int
}
```

**Key Design:**
- Single `map[string]*domain.BufferedEvent` holds ALL pending events
- Key format: `"userID:goalID"` ensures one pending event per user-goal pair
- Latest event overwrites previous (map-based deduplication)
- No separate increment or daily maps needed

#### Add Method

```go
func (r *BufferedRepository) Add(event *domain.BufferedEvent) error {
    r.mu.Lock()
    defer r.mu.Unlock()

    key := fmt.Sprintf("%s:%s", event.UserID, event.GoalID)

    // Overwrite previous buffered event (deduplication: latest event wins)
    r.buffer[key] = event

    // Size-based flush check (same as before)
    // ...
    return nil
}
```

**Deduplication behavior:**
- Multiple events for the same user-goal pair within a flush interval: latest wins
- For stat events: the latest absolute value is kept (correct, since stats are cumulative)
- For login events: only the latest `IncValue=1` is kept (SQL handles accumulation via `progress + inc_value`)

#### Flush Method (Single COPY Path)

```go
func (r *BufferedRepository) Flush() error {
    r.mu.Lock()
    bufferToFlush := r.buffer
    r.buffer = make(map[string]*domain.BufferedEvent)
    r.mu.Unlock()

    if len(bufferToFlush) == 0 {
        return nil
    }

    // Collect all buffered events
    events := make([]*domain.BufferedEvent, 0, len(bufferToFlush))
    for _, event := range bufferToFlush {
        events = append(events, event)
    }

    // Single COPY flush handles ALL event types
    err := r.repo.BatchUpsertProgressWithCOPY(context.Background(), events)
    if err != nil {
        // Restore failed events for retry (same pattern as before)
        r.mu.Lock()
        for key, event := range bufferToFlush {
            if _, exists := r.buffer[key]; !exists {
                r.buffer[key] = event
            }
        }
        r.mu.Unlock()
        return err
    }

    return nil
}
```

**Key Points:**
- Single flush path (no separate absolute/increment transactions)
- `BatchUpsertProgressWithCOPY` handles all progress modes via SQL CASE branches
- Failed flushes restore events to buffer for retry on next interval
- Newer events take precedence over restored events ("last write wins")

#### Why Single Buffer is Better

| Aspect | Old (Multi-Buffer) | New (Unified Buffer) |
|--------|-------------------|---------------------|
| **Buffer maps** | 3 maps (`buffer`, `bufferIncrement`, `bufferIncrementDaily`) | 1 map (`buffer`) |
| **Add methods** | 2 methods (`UpdateProgress`, `IncrementProgress`) | 1 method (`Add`) |
| **Flush paths** | 2 separate DB calls (absolute + increment) | 1 COPY call |
| **Daily dedup** | Client-side map + SQL DATE() fallback | SQL-only (CASE branches) |
| **Cleanup goroutine** | Required (hourly cleanup of daily map) | Not needed |
| **Code complexity** | High (3 maps, 2 methods, cleanup) | Low (1 map, 1 method) |
| **Memory overhead** | ~8MB (200K daily entries) | ~200KB (1K entries) |

#### Performance Impact

**Memory Usage:**

| Component | Size per Entry | Max Entries | Total Memory |
|-----------|---------------|-------------|--------------|
| `buffer` | ~100 bytes (BufferedEvent) | 1,000 | ~100KB |
| **Total** | - | - | **~100KB** |

**Performance Benefit:**
```
Single COPY flush (1,000 events):
  - Queries: 1 COPY + 1 batch UPDATE
  - Time: ~10-20ms
  - Network overhead: 2 round trips

Result: Same 1,000,000x query reduction, simpler code
```

### Performance Analysis

**Scenario:** 1,000 events/sec, 1,000 goals per user

**Without Buffering:**
- Updates: 1,000 events × 1,000 goals = 1,000,000 DB queries/sec
- Result: Database overwhelmed

**With Buffering (One-by-One UPSERT):**
- Updates: 1,000 unique user-goal pairs buffered
- Flush: 1,000 queries/flush × 1 flush/sec = 1,000 queries/sec
- Result: 1000x reduction in queries
- **But:** 1000 round trips per flush = ~1 second flush time

**With Buffering + Batch UPSERT (Recommended):**
- Updates: 1,000 unique user-goal pairs buffered
- Flush: 1 batch query/flush × 1 flush/sec = 1 query/sec
- Result: 1,000,000x reduction in queries
- **Performance:** 1 round trip per flush = ~10-20ms flush time

**Actual Load:** Much lower due to:
- Not all events match all goals
- Many users inactive
- Typical: 1 query/sec (batch of ~100 updates) for 1,000 events/sec

### Burst Traffic Handling

**Scenario:** Sudden spike to 10,000 events/sec for 0.5 seconds (e.g., daily reset, special event)

**Without Size-Based Flushing:**
- 0.5 seconds × 10,000 events/sec = 5,000 buffered updates
- Next time-based flush (at 1.0s mark) processes all 5,000 updates
- Flush time: ~50-100ms
- **Risk:** If burst continues, buffer grows unbounded → OOM crash

**With Size-Based Flushing (1,000 threshold):**
- First 1,000 events → buffer fills → size-based flush triggered
- Flush 1: 1,000 updates in ~10-20ms (async)
- Next 1,000 events → second size-based flush
- Flush 2: 1,000 updates in ~10-20ms (async)
- Process continues with bounded memory
- **Result:** System stays healthy during burst, no OOM risk

**Key Benefits:**
1. **Memory Safety**: Buffer never exceeds 1,000 entries
2. **Predictable Latency**: Flush time stays consistent (~20ms)
3. **Graceful Degradation**: System handles bursts without crashing
4. **Lower Data Loss**: Maximum 1,000 updates lost on crash (not 5,000+)

---

## Concurrency Control

### Per-User Mutex

**Problem:** Race condition when multiple events for same user arrive concurrently

**Example Race Condition:**
```
Event A: snowman_kills = 7
Event B: snowman_kills = 10

Without mutex:
- Both read progress = 5
- Both write progress = 7 (or 10, unpredictable)

With mutex:
- Event A locks → reads 5 → writes 7 → unlocks
- Event B locks → reads 7 → writes 10 → unlocks
```

### Implementation

```go
type EventProcessor struct {
    userLocks *sync.Map  // user_id -> *sync.Mutex
    // ... other fields
}

func (p *EventProcessor) getUserLock(userID string) *sync.Mutex {
    lock, _ := p.userLocks.LoadOrStore(userID, &sync.Mutex{})
    return lock.(*sync.Mutex)
}

func (p *EventProcessor) ProcessEvent(ctx context.Context, event *Event) error {
    // 1. Acquire user lock
    lock := p.getUserLock(event.UserID)
    lock.Lock()
    defer lock.Unlock()

    // 2. Process event (safe from race conditions)
    // ...

    return nil
}
```

### Lock Characteristics

| Characteristic | Value |
|---------------|-------|
| Scope | Per user (different users don't block each other) |
| Type | Exclusive (only one event per user at a time) |
| Duration | ~5-10ms (event processing time) |
| Granularity | Coarse (locks entire user, not per-goal) |

### Deadlock Prevention

- Single lock per event (no nested locks)
- Always lock in same order (only user lock)
- Lock released via `defer` (guaranteed even on panic)

---

## Performance Optimization

### 1. Cache-First Design

**Strategy:** All goal lookups via in-memory cache (zero DB reads)

```go
// O(1) lookup by stat code
goals := cache.GetGoalsByStatCode("snowman_kills")

// O(1) lookup for prerequisites
for _, prereqID := range goal.Prerequisites {
    prereqGoal := cache.GetGoalByID(prereqID)
}
```

**Performance:**
- Cache lookup: ~1 μs
- Database read: ~5-10 ms
- Speedup: 5,000-10,000x

### 2. Prerequisite Validation

**Strategy:** Check prerequisites via cache + buffered repo

```go
func (p *EventProcessor) isGoalLocked(userID string, goal *Goal) bool {
    for _, prereqID := range goal.Prerequisites {
        // Check in buffer first (most recent state)
        progress := p.bufferedRepo.GetFromBuffer(userID, prereqID)
        if progress == nil {
            // Not in buffer, check DB (cached result)
            progress, _ = p.repo.GetProgress(userID, prereqID)
        }

        if progress == nil || (progress.Status != "completed" && progress.Status != "claimed") {
            return true  // Locked
        }
    }

    return false  // All prerequisites met
}
```

**Optimization:** Check buffer before DB to get latest state

### 3. Batch Processing (Future Optimization)

**Current:** Process events one-by-one
**Future:** Batch multiple events for same user

```go
// Batch events for same user
userEvents := groupByUser(events)

for userID, events := range userEvents {
    lock := getUserLock(userID)
    lock.Lock()

    // Process all events for user
    for _, event := range events {
        processEvent(event)
    }

    lock.Unlock()
}
```

**Not implemented in M1 (keep simple)**

---

## Implementation Details

### Event Handler Structure

```go
// Handler for IAM login events
type LoginHandler struct {
    pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
    processor *EventProcessor
    logger    *logrus.Logger
}

// Handler for Statistic update events
type StatisticHandler struct {
    statpb.UnimplementedStatisticStatItemUpdatedServiceServer
    processor *EventProcessor
    logger    *logrus.Logger
}

type EventProcessor struct {
    goalCache     cache.GoalCache
    bufferedRepo  *BufferedRepository
    userLocks     *sync.Map
    logger        *logrus.Logger
}
```

### OnMessage Method Pattern

**Key Pattern:** Each event type has its own gRPC service with an `OnMessage` method.

**IAM Login Event Handler:**

```go
// OnMessage is called by Extend platform for each userLoggedIn event
// The Extend platform handles:
// - Kafka consumer group management
// - Offset commits
// - Retry logic for transient failures
// - Dead letter queue for permanent failures
func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    startTime := time.Now()
    scope := common.GetScopeFromContext(ctx, "LoginHandler.OnMessage")
    defer scope.Finish()

    // Extract user ID from event message
    userID := msg.UserId
    namespace := msg.Namespace

    h.logger.Infof("Processing login event: user=%s namespace=%s", userID, namespace)

    // For login-based goals: Value=nil, Inc=1 (synthetic)
    statUpdate := &domain.StatUpdate{
        Value: nil,  // No absolute stat value for login
        Inc:   1,    // Each login counts as 1
    }

    // Process using common event processor
    err := h.processor.ProcessEvent(ctx, userID, namespace, statUpdate)
    if err != nil {
        h.logger.Errorf("Failed to process login event: %v", err)
        return &emptypb.Empty{}, status.Errorf(codes.Internal, "failed to process event: %v", err)
    }

    duration := time.Since(startTime)
    h.logger.Infof("Login event processed: user=%s duration=%dms", userID, duration.Milliseconds())

    return &emptypb.Empty{}, nil
}
```

**Statistic Update Event Handler:**

```go
// OnMessage is called by Extend platform for each statItemUpdated event
func (h *StatisticHandler) OnMessage(ctx context.Context, msg *pb.StatItemUpdated) (*emptypb.Empty, error) {
    startTime := time.Now()
    scope := common.GetScopeFromContext(ctx, "StatisticHandler.OnMessage")
    defer scope.Finish()

    // Extract fields from event message (refer to actual proto for exact field names)
    userID := msg.UserId
    namespace := msg.Namespace
    statCode := msg.Payload.StatCode
    value := int(msg.Payload.Value)  // Convert float64 to int
    inc := int(msg.Payload.Inc)      // Incremental change from AGS event

    h.logger.Infof("Processing stat update: user=%s stat=%s value=%d inc=%d", userID, statCode, value, inc)

    // Create StatUpdate with absolute value and incremental delta
    statUpdate := &domain.StatUpdate{
        Value: &value,  // Absolute stat value from AGS
        Inc:   inc,     // Incremental delta from AGS event
    }

    // Process using common event processor
    err := h.processor.ProcessEvent(ctx, userID, namespace, statUpdate)
    if err != nil {
        h.logger.Errorf("Failed to process stat event: %v", err)
        return &emptypb.Empty{}, status.Errorf(codes.Internal, "failed to process event: %v", err)
    }

    duration := time.Since(startTime)
    h.logger.Infof("Stat event processed: user=%s stat=%s value=%d inc=%d duration=%dms",
        userID, statCode, value, inc, duration.Milliseconds())

    return &emptypb.Empty{}, nil
}
```

**gRPC Service Registration (main.go):**

```go
// Create gRPC server
grpcServer := grpc.NewServer(
    grpc.StatsHandler(otelgrpc.NewServerHandler()),
    grpc.ChainUnaryInterceptor(unaryServerInterceptors...),
    grpc.ChainStreamInterceptor(streamServerInterceptors...),
)

// Register event handlers
loginHandler := service.NewLoginHandler(eventProcessor, logger)
pb.RegisterUserAuthenticationUserLoggedInServiceServer(grpcServer, loginHandler)

statHandler := service.NewStatisticHandler(eventProcessor, goalCache, namespace, logger)
statpb.RegisterStatisticStatItemUpdatedServiceServer(grpcServer, statHandler)

// Enable gRPC reflection for debugging
reflection.Register(grpcServer)

// Enable health check
grpc_health_v1.RegisterHealthServer(grpcServer, health.NewServer())

// Start server on port 6565
lis, _ := net.Listen("tcp", ":6565")
grpcServer.Serve(lis)
```

### ProcessEvent Method

**Updated in M5:** The ProcessEvent method now uses `StatUpdate` and delegates to `processGoal()` which creates `BufferedEvent` entries for the unified buffer. Status computation is delegated to SQL CASE branches (not computed in Go).

```go
func (p *EventProcessor) ProcessEvent(ctx context.Context, userID, namespace string, statUpdate *domain.StatUpdate) error {
    // 1. Acquire user lock
    lock := p.getUserLock(userID)
    lock.Lock()
    defer lock.Unlock()

    // 2. Get goals tracking this stat (O(1) cache lookup)
    goals := p.goalCache.GetGoalsByStatCode(statUpdate.StatCode)

    for _, goal := range goals {
        // 3. Check if already claimed
        progress := p.getProgress(userID, goal.ID)
        if progress != nil && progress.Status == "claimed" {
            continue
        }

        // 4. Check prerequisites
        if p.isGoalLocked(userID, goal) {
            continue
        }

        // 5. Create BufferedEvent and add to unified buffer
        //    Status computation delegated to SQL CASE branches
        p.processGoal(userID, namespace, goal, statUpdate)
    }

    return nil
}

func (p *EventProcessor) processGoal(userID, namespace string, goal *domain.Goal, statUpdate *domain.StatUpdate) {
    event := &domain.BufferedEvent{
        UserID:       userID,
        GoalID:       goal.ID,
        ChallengeID:  goal.ChallengeID,
        Namespace:    namespace,
        Progress:     statUpdate.Value,                  // nil for login, &value for stat
        IncValue:     statUpdate.Inc,                    // Always >= 1
        ProgressMode: goal.Requirement.ProgressMode,     // "absolute" or "relative"
    }

    p.bufferedRepo.Add(event)
}
```

### Event Proto Schema Reference

**Important:** Always refer to official AccelByte proto definitions for exact field names and types.

**Proto Sources:**
- Repository: https://github.com/AccelByte/accelbyte-api-proto
- Download proto files and place in `pkg/proto/accelbyte-asyncapi/`

**IAM Login Event:**
```protobuf
// From: iam/account/v1/account.proto
message UserLoggedIn {
    string id = 2;
    string namespace = 5;
    string user_id = 9;
    string timestamp = 7;
    AnonymousSchema19 payload = 1;  // Contains user_account + user_authentication
}

service UserAuthenticationUserLoggedInService {
    rpc OnMessage(UserLoggedIn) returns (google.protobuf.Empty);
}
```

**Statistic Update Event:**
```protobuf
// From: social/statistic/v1/statistic.proto (TODO: Verify exact location)
message StatItemUpdated {
    string id = 2;
    string namespace = 5;
    string user_id = 9;
    string timestamp = 7;
    StatItemPayload payload = 1;
}

message StatItemPayload {
    string stat_code = 1;
    float value = 2;      // Absolute stat value (cumulative)
    float inc = 3;        // Incremental change from this update
    // ... other fields
}

service StatisticUpdatedService {
    rpc OnMessage(StatItemUpdated) returns (google.protobuf.Empty);
}
```

**Implementation Steps:**
1. Download proto files from AccelByte proto repository
2. Place in `pkg/proto/accelbyte-asyncapi/`
3. Run `proto.sh` to generate Go code
4. Implement `OnMessage` methods for each event type
5. Register services with gRPC server in main.go

---

## Metrics and Monitoring

### Key Metrics

```go
type EventMetrics struct {
    ProcessingTime   histogram  // Event processing duration
    EventsProcessed  counter    // Total events processed
    EventsFailed     counter    // Total events failed
    BufferSize       gauge      // Current buffer size
    FlushDuration    histogram  // Flush operation duration
}
```

### Prometheus Metrics

```go
eventProcessingTime := prometheus.NewHistogram(prometheus.HistogramOpts{
    Name:    "challenge_event_processing_seconds",
    Help:    "Time to process a single event",
    Buckets: prometheus.ExponentialBuckets(0.001, 2, 10),  // 1ms to 1s
})

bufferSize := prometheus.NewGauge(prometheus.GaugeOpts{
    Name: "challenge_buffer_size",
    Help: "Number of buffered updates pending flush",
})

flushDuration := prometheus.NewHistogram(prometheus.HistogramOpts{
    Name:    "challenge_flush_duration_seconds",
    Help:    "Time to flush buffered updates to database",
    Buckets: prometheus.LinearBuckets(0.01, 0.01, 10),  // 10ms to 100ms
})
```

### Logging

```go
log.Info("Event processed",
    "event_id", event.EventID,
    "user_id", event.UserID,
    "event_type", event.EventType,
    "namespace", event.Namespace,
    "stat_count", len(statUpdates),
    "goals_updated", goalsUpdated,
    "duration_ms", duration.Milliseconds(),
)
```

---

## Buffer Flush on Shutdown (Decision 28)

### Graceful Shutdown Flow

**Requirement:** When the event handler service shuts down (e.g., pod termination, deployment), flush all buffered updates before exiting.

**Implementation:**

```go
func main() {
    // ... initialization ...

    // Create shutdown signal channel
    shutdownChan := make(chan os.Signal, 1)
    signal.Notify(shutdownChan, syscall.SIGTERM, syscall.SIGINT)

    // Run gRPC server in goroutine
    go func() {
        if err := grpcServer.Serve(lis); err != nil {
            logger.Fatalf("Failed to serve: %v", err)
        }
    }()

    // Wait for shutdown signal
    <-shutdownChan
    logger.Info("Shutdown signal received, initiating graceful shutdown...")

    // Execute graceful shutdown
    if err := gracefulShutdown(grpcServer, bufferedRepo, logger); err != nil {
        logger.Errorf("Graceful shutdown encountered errors: %v", err)
        os.Exit(1)
    }

    logger.Info("Graceful shutdown completed successfully")
    os.Exit(0)
}

func gracefulShutdown(grpcServer *grpc.Server, bufferedRepo *BufferedRepository, logger *logrus.Logger) error {
    // 1. Stop accepting new gRPC requests
    logger.Info("Stopping gRPC server...")
    grpcServer.GracefulStop()  // Waits for in-flight RPCs to complete

    // 2. Flush buffer with timeout
    logger.Info("Flushing buffered updates...")
    flushCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    if err := bufferedRepo.FlushWithContext(flushCtx); err != nil {
        logger.WithError(err).Error("Failed to flush buffer on shutdown")
        logger.WithField("bufferSize", bufferedRepo.GetBufferSize()).Error("Data loss may have occurred")
        return fmt.Errorf("flush failed: %w", err)
    }

    logger.Info("Buffer flushed successfully")

    // 3. Close database connections
    logger.Info("Closing database connections...")
    if err := bufferedRepo.Close(); err != nil {
        logger.WithError(err).Warn("Failed to close database connections cleanly")
        // Don't fail shutdown - connections will be closed by OS anyway
    }

    return nil
}
```

### FlushWithContext Implementation

```go
func (r *BufferedRepository) FlushWithContext(ctx context.Context) error {
    // Create channel to signal flush completion
    done := make(chan error, 1)

    // Run flush in goroutine
    go func() {
        done <- r.Flush()
    }()

    // Wait for flush or timeout
    select {
    case err := <-done:
        return err
    case <-ctx.Done():
        r.logger.Error("Flush timed out, some data may be lost",
            "timeout", "30s",
            "bufferSize", len(r.buffer))
        return fmt.Errorf("flush timeout: %w", ctx.Err())
    }
}
```

### Shutdown Characteristics

| Aspect | Value | Notes |
|--------|-------|-------|
| **Timeout** | 30 seconds | Configurable via `SHUTDOWN_TIMEOUT` env var |
| **gRPC stop** | Graceful | Waits for in-flight RPCs to complete |
| **Buffer flush** | With timeout | Ensures DB write attempt within 30s |
| **Data loss window** | 0-1 second | Only buffered updates (not flushed yet) |
| **Kubernetes termination** | 30s grace period | Matches Kubernetes default |

### Kubernetes Integration

**Pod Termination Sequence:**

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: challenge-event-handler
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 35  # Slightly longer than shutdown timeout
      containers:
      - name: event-handler
        image: challenge-event-handler:latest
        env:
        - name: SHUTDOWN_TIMEOUT
          value: "30"  # 30 seconds
```

**Termination Flow:**
1. Kubernetes sends `SIGTERM` to container
2. Application receives signal, stops accepting new RPCs
3. Application flushes buffer (30s timeout)
4. Application closes database connections
5. Application exits
6. If not exited after 35s, Kubernetes sends `SIGKILL` (forceful)

### Crash Handling

**Without graceful shutdown (crash/SIGKILL):**

- **Data loss:** Up to 1 second of buffered updates (~1,000 updates max)
- **Database:** No corruption (all writes atomic)
- **Recovery:** Next flush will retry failed updates (if any)
- **Impact:** Minimal - users see slightly stale progress until next event

**Acceptable Trade-offs:**

- No disk persistence (Extend limitation - ephemeral containers)
- No distributed buffer (keeping it simple for M1)
- ~1s data loss on crash is acceptable for event-driven system
- Users will generate new events soon after restart

### Logging on Shutdown

```go
logger.Info("Graceful shutdown initiated")
logger.WithFields(logrus.Fields{
    "bufferSize": len(buffer),
    "timeout": "30s",
}).Info("Flushing buffer...")

// On success
logger.WithFields(logrus.Fields{
    "flushedCount": len(buffer),
    "duration": duration.Milliseconds(),
}).Info("Buffer flushed successfully on shutdown")

// On timeout/failure
logger.WithFields(logrus.Fields{
    "bufferSize": len(buffer),
    "error": err,
    "elapsed": elapsed,
}).Error("Failed to flush buffer on shutdown, data loss may have occurred")
```

### Testing

```go
func TestGracefulShutdown(t *testing.T) {
    repo := NewBufferedRepository(...)

    // Buffer some events
    repo.Add(&event1)
    repo.Add(&event2)
    assert.Equal(t, 2, repo.GetBufferSize())

    // Graceful shutdown
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    err := repo.FlushWithContext(ctx)
    assert.NoError(t, err)
    assert.Equal(t, 0, repo.GetBufferSize())  // Buffer cleared

    // Verify DB has updates
    progress := mockDB.GetProgress(user1, goal1)
    assert.NotNil(t, progress)
}
```

---

## Error Recovery from Buffer (Decision 34)

### Retry Strategy for Failed Flushes

**Problem:** Database outages or transient errors can cause flush operations to fail. We need to retry failed writes without losing data.

**Solution:** Keep failed updates in buffer and retry on next flush interval.

### Implementation

```go
func (r *BufferedRepository) Flush() error {
    r.mu.Lock()

    // Swap pattern: Copy buffer and create new empty buffer
    bufferToFlush := r.buffer
    r.buffer = make(map[string]*domain.BufferedEvent)

    r.mu.Unlock()  // Release lock before DB operation

    // Early return if nothing to flush
    if len(bufferToFlush) == 0 {
        return nil
    }

    r.logger.Info("Flushing buffered events", "count", len(bufferToFlush))

    // Collect events for batch operation
    events := make([]*domain.BufferedEvent, 0, len(bufferToFlush))
    for _, event := range bufferToFlush {
        events = append(events, event)
    }

    // Attempt batch COPY flush
    err := r.repo.BatchUpsertProgressWithCOPY(context.Background(), events)
    if err != nil {
        r.logger.Error("Failed to flush batch, will retry on next interval",
            "count", len(events),
            "error", err,
            "nextRetry", "1 second")

        // ERROR RECOVERY: Re-add failed events to buffer for retry
        r.mu.Lock()
        for key, event := range bufferToFlush {
            // Only restore if not already updated by newer event
            // (Newer event takes precedence - "last write wins")
            if _, exists := r.buffer[key]; !exists {
                r.buffer[key] = event
            }
        }
        r.mu.Unlock()

        return err
    }

    r.logger.Info("Successfully flushed events", "count", len(events))
    return nil
}
```

### Error Recovery Characteristics

| Aspect | Behavior | Notes |
|--------|----------|-------|
| **Retry interval** | 1 second | Same as normal flush interval |
| **Retry count** | Unlimited | Retries until success |
| **Data preservation** | Keep in buffer | Failed updates not lost |
| **Newer updates** | Take precedence | If user-goal updated again, use newer value |
| **Partial success** | Not supported | Batch is all-or-nothing (transaction) |

### Error Scenarios

#### 1. Transient Database Error

```
Timeline:
00:00 - Event arrives, buffer has 100 updates
00:01 - Flush triggered, database timeout (5s)
00:06 - Flush fails, 100 updates restored to buffer
00:07 - Event arrives, buffer has 101 updates (100 old + 1 new)
00:08 - Flush triggered, database available
00:09 - Flush succeeds, buffer cleared (all 101 updates written)
```

**Outcome:** No data loss, 1-second delay for failed updates

#### 2. Database Outage (5 minutes)

```
Timeline:
00:00 - Database goes down
00:01 - Flush #1 fails, 100 updates in buffer
00:02 - Flush #2 fails, 200 updates in buffer (100 old + 100 new)
00:03 - Flush #3 fails, 300 updates in buffer
... (continues for 5 minutes)
00:300 - Flush #300 fails, buffer reaches 2000 (overflow protection triggers)
00:301 - New updates return error (buffer full)
05:00 - Database comes back
05:01 - Flush #301 succeeds, buffer cleared
05:02 - New updates accepted (buffer has space)
```

**Outcome:**
- Buffered updates preserved (up to 2000 entries)
- Overflow protection prevents OOM
- Automatic recovery when database returns

#### 3. Partial Failure (One Bad Row)

**Problem:** If batch contains one invalid row (e.g., foreign key violation), entire batch fails.

**Current Behavior:**
- Entire batch retries (including valid rows)
- Bad row causes indefinite retry loop
- **This is acceptable for M1** - bad data should be fixed in config or database

**Future Enhancement (M2+):**
- Split failed batch into individual rows
- Retry each row separately
- Identify and skip permanently failed rows (after N attempts)
- Log permanently failed rows for manual investigation

```go
// Future enhancement: fallback to individual writes to identify bad rows
func (r *BufferedRepository) FlushWithFallback() error {
    err := r.repo.BatchUpsertProgressWithCOPY(ctx, events)
    if err != nil {
        // Try individual writes to identify bad row
        for _, event := range events {
            if err := r.repo.UpsertProgressSingle(ctx, event); err != nil {
                r.logger.Error("Permanently failed event",
                    "userID", event.UserID,
                    "goalID", event.GoalID,
                    "error", err)
                // Skip this event (don't retry)
            }
        }
    }
}
```

### Monitoring Failed Flushes

**Metrics:**

```go
flushFailureCount := prometheus.NewCounterVec(
    prometheus.CounterOpts{
        Name: "challenge_buffer_flush_failures_total",
        Help: "Total number of failed buffer flushes",
    },
    []string{"error_type"},  // "timeout", "connection", "constraint", etc.
)

consecutiveFailures := prometheus.NewGauge(
    prometheus.GaugeOpts{
        Name: "challenge_buffer_flush_consecutive_failures",
        Help: "Number of consecutive failed flush attempts",
    },
)
```

**Alerting:**

```yaml
groups:
  - name: challenge_buffer
    rules:
      - alert: BufferFlushFailures
        expr: challenge_buffer_flush_consecutive_failures > 5
        for: 1m
        annotations:
          summary: "Buffer flush failing repeatedly"
          description: "Buffer has failed to flush {{$value}} times in a row"

      - alert: BufferNearCapacity
        expr: challenge_buffer_size > 1500  # 1500/2000 = 75%
        for: 2m
        annotations:
          summary: "Buffer approaching capacity"
          description: "Buffer has {{$value}} entries (max 2000)"
```

### Logging

```go
// On flush failure
r.logger.WithFields(logrus.Fields{
    "error": err,
    "bufferSize": len(updates),
    "consecutiveFailures": consecutiveFailures,
    "nextRetryIn": "1 second",
}).Error("Buffer flush failed, updates preserved for retry")

// On recovery
r.logger.WithFields(logrus.Fields{
    "bufferSize": len(updates),
    "consecutiveFailures": consecutiveFailures,
    "outagesDuration": duration,
}).Info("Buffer flush recovered after failures")
```

### Testing

```go
func TestFlushRetryOnFailure(t *testing.T) {
    mockDB := &MockRepository{
        BatchUpsertError: errors.New("database timeout"),
    }
    repo := NewBufferedRepository(mockDB, 1*time.Second, 1000)

    // Buffer some events
    repo.Add(&event1)
    repo.Add(&event2)

    // First flush fails
    err := repo.Flush()
    assert.Error(t, err)
    assert.Equal(t, 2, repo.GetBufferSize())  // Events still in buffer

    // Fix database
    mockDB.BatchUpsertError = nil

    // Second flush succeeds
    err = repo.Flush()
    assert.NoError(t, err)
    assert.Equal(t, 0, repo.GetBufferSize())  // Buffer cleared
}

func TestFlushPreservesNewerEvents(t *testing.T) {
    mockDB := &MockRepository{
        BatchUpsertError: errors.New("timeout"),
    }
    repo := NewBufferedRepository(mockDB, 1*time.Second, 1000)

    progress5 := 5
    // Buffer event (progress=5)
    repo.Add(&domain.BufferedEvent{
        UserID:       "user1",
        GoalID:       "goal1",
        Progress:     &progress5,
        IncValue:     5,
        ProgressMode: domain.ProgressModeAbsolute,
    })

    // Flush fails
    repo.Flush()
    assert.Equal(t, 1, repo.GetBufferSize())

    progress10 := 10
    // New event with higher progress
    repo.Add(&domain.BufferedEvent{
        UserID:       "user1",
        GoalID:       "goal1",
        Progress:     &progress10,
        IncValue:     5,
        ProgressMode: domain.ProgressModeAbsolute,
    })

    // Verify newer event takes precedence
    assert.Equal(t, 1, repo.GetBufferSize())
    buffered := repo.GetFromBuffer("user1", "goal1")
    assert.Equal(t, 10, *buffered.Progress)  // Not 5
}
```

### Recovery Guarantees

**Guaranteed:**
- ✅ No data loss (failed updates preserved in buffer)
- ✅ Automatic retry (every flush interval)
- ✅ Newer updates take precedence ("last write wins")
- ✅ Bounded memory (overflow protection at 2x threshold)

**Not Guaranteed:**
- ❌ Exact retry count (retries until success or overflow)
- ❌ Ordering preservation (map-based storage loses insertion order)
- ❌ Partial batch success (all-or-nothing transaction)

**Acceptable for M1:**
- Event-driven system with 1-second retry is sufficient
- Users generate new events frequently (fresh data)
- Progress updates are idempotent (safe to retry)

---

## M3 Updates: Lazy Materialization and Assignment Control

### Overview

M3 introduces **lazy materialization** (rows created by `/initialize` API, not by events) and **assignment control** (users choose which goals to track via `is_active` field). This changes how event processing queries interact with the database.

### Key Changes from M1/M2

**M1/M2 Behavior:**
- Events could create new rows via INSERT in UPSERT queries
- All goals tracked by default (no assignment control)

**M3 Behavior:**
- `/initialize` API creates ALL rows before events arrive (lazy materialization)
- Users assign/unassign goals via `/v1/challenges/{id}/goals/{id}/assign` endpoint
- `is_active` field controls whether goal receives event updates
- `BatchUpsertProgressWithCOPY` (production) has `WHERE is_active = true` check

### Query Patterns in M3/M5

#### BatchUpsertProgressWithCOPY (Production - COPY Path)

**Updated in M5:** This is now the only flush path. It handles all progress modes via SQL CASE branches.

```sql
-- 1. COPY data into temp table
-- 2. Batch UPDATE with SQL CASE branches for:
--    - Baseline initialization (relative mode)
--    - Rotation detection (expires_at < NOW())
--    - Status computation (progress >= target)
--    - Claimed protection (status != 'claimed')
--    - Assignment control (is_active = true)
```

**Key Design Points:**
- Single COPY + UPDATE replaces all old flush paths
- `is_active = true` check in WHERE clause prevents updates to unassigned goals
- Events for unassigned goals: UPDATE affects 0 rows (silent no-op)
- Maintains single-query performance (no separate is_active lookup)
- See [TECH_SPEC_M5.md](./TECH_SPEC_M5.md) for full SQL query

#### Legacy Methods (Removed in M5)

The following methods have been removed in the M5 refactor:
- `BatchIncrementProgress`: Replaced by SQL CASE branches in `BatchUpsertProgressWithCOPY`
- `IncrementProgress`: Replaced by unified `Add()` method on BufferedRepository
- `BatchUpsertProgress` (UNNEST version): Replaced by COPY path

### Event Handler Responsibilities

**Current Implementation (M3+):**
1. Event arrives -> lookup affected goals from cache
2. Buffer events for ALL matching goals (no `is_active` check in handler)
3. Flush calls `BatchUpsertProgressWithCOPY` with all buffered events
4. Repository filters based on `is_active` in SQL WHERE clause

**Future Optimization:**
- Event handler could check `goal.DefaultAssigned` and user's assignment status
- Skip buffering for unassigned goals at handler level
- Reduces buffer size and database query parameters
- Currently deferred (lazy materialization handles most cases efficiently)

### Performance Impact

**M3+ maintains M1/M2 performance:**
- Still single query per batch (no additional is_active lookups)
- Unassigned goals: 0 rows updated (silent no-op, fast)
- No regression in throughput or latency

### Backward Compatibility

**M1 behavior preserved:**
- Set `default_assigned = true` on all goals in config
- Call `/initialize` on first login (creates all rows as active)
- All goals receive event updates -> same as M1

**M3 behavior:**
- Set `default_assigned = true` only on beginner goals
- Call `/initialize` on first login (creates all rows, some inactive)
- Only assigned goals receive event updates → better performance

---

## References

- **AccelByte API Events Documentation**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/
  - Browse sidebar to find events for each AGS service
  - **IAM Account Events**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/
    - User Login Event: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/#userloggedin
  - **Social Statistic Events**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/
    - Stat Item Updated Event: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/#statitemupdated
  - **Platform Events**: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/platform/
- **AccelByte API Proto Definitions**: https://github.com/AccelByte/accelbyte-api-proto
  - IAM Account Proto: https://github.com/AccelByte/accelbyte-api-proto/tree/main/asyncapi/accelbyte/iam/account/v1/account.proto
  - Social Statistic Proto: https://github.com/AccelByte/accelbyte-api-proto/tree/main/asyncapi/accelbyte/social/statistic/v1/statistic.proto
  - Use these proto files to generate type-safe event handlers
- **Extend Event Handler Template**: https://github.com/AccelByte/extend-event-handler-go
  - Extend platform handles Kafka consumption and delivers events via gRPC
  - Your handler receives events through gRPC calls (Kafka abstracted away)

---

**Document Status:** Updated for M5 - Unified buffer architecture, ProgressMode routing, SQL CASE rotation logic
