# Technical Specification: Event Processing

**Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Overview](#overview)
2. [Event Flow](#event-flow)
3. [Event Schemas](#event-schemas)
4. [Buffering Strategy](#buffering-strategy)
5. [Concurrency Control](#concurrency-control)
6. [Performance Optimization](#performance-optimization)
7. [Implementation Details](#implementation-details)

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
- Extract `statCode` and `value` from payload
- Lookup matching goals via cache using `statCode`
- Update progress for all matching goals with the `value`

**Critical Design Decision:**
- AGS Statistic Service events provide **absolute values** (not deltas)
- Example: `"value": 7.0` means user has 7 total kills, not +7 more
- No calculation needed in event handler (just compare `value` against `target_value`)
- This is confirmed in the Statistic Service event schema

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

## Goal Type Routing

### Overview

The EventProcessor routes events to different repository methods based on the goal's `type` field. This allows the system to handle different progress tracking patterns efficiently:

- **Absolute goals**: Track absolute stat values (e.g., kills=100)
- **Increment goals**: Count event occurrences with atomic DB increments (e.g., login count)
- **Daily goals**: Check if event occurred today using timestamp comparison

### Goal Types

#### 1. Absolute Type (`"absolute"`)

**Use Case:** Track absolute stat values from AGS Statistic Service

**Example Goals:**
- Kill 100 snowmen: `stat_code: "snowman_kills"`, `target_value: 100`
- Reach level 50: `stat_code: "player_level"`, `target_value: 50`
- Earn 10,000 coins: `stat_code: "total_coins"`, `target_value: 10000`

**Event Processing:**
```go
// Statistic event provides absolute value
statUpdate := event.Payload.Value  // e.g., 7 (user has 7 total kills)

// Update progress with absolute value
repo.UpdateProgress(&UserGoalProgress{
    UserID:   userID,
    GoalID:   goalID,
    Progress: int(statUpdate),  // Store absolute value: 7
    Status:   calculateStatus(statUpdate, targetValue),
})
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

#### 2. Increment Type (`"increment"`)

**Use Case:** Count event occurrences (binary events with no stat value)

**Example Goals:**
- Login 5 times: `stat_code: "login_count"`, `target_value: 5`
- Complete 10 matches: `stat_code: "match_complete"`, `target_value: 10`
- Visit shop 3 times: `stat_code: "shop_visit"`, `target_value: 3`

**Event Processing:**
```go
// Each login event increments by 1
delta := 1

// Accumulate deltas in buffer
bufferedRepo.IncrementProgress(userID, goalID, delta)
```

**BufferedRepository Behavior:**
```go
// Multiple events before flush:
// Event 1: IncrementProgress(userA, goal1, 1)  → buffer[userA:goal1] = {delta: 1}
// Event 2: IncrementProgress(userA, goal1, 1)  → buffer[userA:goal1] = {delta: 2}
// Event 3: IncrementProgress(userA, goal1, 1)  → buffer[userA:goal1] = {delta: 3}

// At flush: Single query with delta=3
repo.IncrementProgress(userID, goalID, 3, targetValue)
```

**Database Operation:** Atomic increment
```sql
-- progress = progress + 3 (atomic, race-free)
progress = user_goal_progress.progress + $delta
```

**Key Characteristics:**
- Each event occurrence adds +1 to counter
- BufferedRepository accumulates deltas before flush
- Database increments atomically (no race conditions)
- Three login events → one query with delta=3

#### 2b. Increment with Daily Flag (`type: "increment", daily: true`)

**Use Case:** Count distinct days with event occurrence (accumulates toward one-time reward)

**Important:** This is fundamentally different from Daily Type. Increment with Daily Flag accumulates progress across days for a one-time reward, while Daily Type resets daily for repeatable rewards.

**Example Goals:**
- Login 7 days: `stat_code: "login_count"`, `target_value: 7`, `daily: true`
- Play 14 distinct days: `stat_code: "daily_activity"`, `target_value: 14`, `daily: true`
- Monthly challenge (30 days): `stat_code: "monthly_login"`, `target_value: 30`, `daily: true`

**Event Processing:**
```go
// Each login event increments by 1, but only once per day
delta := 1

// BufferedRepository checks date before buffering
isDailyIncrement := true
bufferedRepo.IncrementProgress(userID, goalID, delta, isDailyIncrement)
```

**BufferedRepository Behavior:**
```go
// Client-side date checking prevents same-day duplicates:
// Day 1, Login 1: IncrementProgress(userA, goal1, 1, true) → buffer[userA:goal1] = {delta: 1}
// Day 1, Login 2: IncrementProgress(userA, goal1, 1, true) → SKIPPED (same day)
// Day 1, Login 3: IncrementProgress(userA, goal1, 1, true) → SKIPPED (same day)

// Day 2, Login 1: IncrementProgress(userA, goal1, 1, true) → buffer[userA:goal1] = {delta: 1}

// At flush (Day 2): Single query with delta=1 (not 3)
repo.IncrementProgress(userID, goalID, 1, targetValue, isDailyIncrement=true)
```

**Database Operation:** Atomic increment with SQL date check
```sql
-- progress = progress + 1 (atomic, race-free)
-- Only increments if DATE(completed_at) != CURRENT_DATE
UPDATE user_goal_progress
SET
    progress = CASE
        WHEN DATE(completed_at) = CURRENT_DATE THEN progress  -- Same day: no increment
        ELSE progress + $delta  -- New day: increment
    END,
    completed_at = CASE
        WHEN DATE(completed_at) = CURRENT_DATE THEN completed_at  -- Keep timestamp
        ELSE NOW()  -- Update timestamp
    END
WHERE user_id = $user_id AND goal_id = $goal_id
```

**Key Characteristics:**
- **Accumulative progress**: 0 → 1 → 2 → 3... (never resets)
- **One-time reward**: User claims once after reaching target (e.g., 7 days)
- **Daily deduplication**: Only increments once per day (client + server side)
- **Same-day events**: Ignored after first event of the day
- **Database field**: Uses `progress` counter + `updated_at` timestamp
- **Typical use case**: "Login 7 days" challenge, "Play 30 days" monthly quest

**Example Flow:**
```
Day 1: User logs in → progress=1, completed_at="2025-10-17", status="in_progress"
Day 1: User logs in again → NO INCREMENT (same day, deduplication)
Day 2: User logs in → progress=2, completed_at="2025-10-18", status="in_progress"
Day 3: User doesn't log in → progress=2 (no change)
Day 4: User logs in → progress=3, completed_at="2025-10-20", status="in_progress"
...
Day 10: User logs in → progress=7, completed_at="2025-10-26", status="completed" (reached target)
Day 10: User claims reward → claimed_at="2025-10-26" (one-time reward)
Day 11: User logs in → NO INCREMENT (already completed and claimed)
```

**Daily vs Daily Increment Comparison:**

| Aspect | Daily Type | Increment with Daily Flag |
|--------|-----------|---------------------------|
| **Progress Range** | 0 or 1 | 0 to target_value |
| **Target Value** | Always 1 | Any number (7, 14, 30+) |
| **Resets** | Daily (via claim check) | Never (accumulates) |
| **Claim Frequency** | Once per day | Once after reaching target |
| **Same-Day Events** | Overwrites timestamp | Ignored (no double count) |
| **Reward Type** | Repeatable daily reward | One-time reward |
| **Database Method** | `UpdateProgress()` | `IncrementProgress(isDailyIncrement=true)` |

#### 3. Daily Type (`"daily"`)

**Use Case:** Binary daily check for repeatable rewards (resets every day)

**Important:** This is fundamentally different from Increment with Daily Flag (see below). Daily type is for repeatable daily rewards, while Increment with Daily Flag is for accumulating distinct days toward a one-time reward.

**Example Goals:**
- Daily login bonus: `stat_code: "login_daily"`, `target_value: 1`
- Daily spin wheel: `stat_code: "daily_spin"`, `target_value: 1`
- Play one match today: `stat_code: "daily_match"`, `target_value: 1`

**Event Processing:**
```go
// For daily goals, set completed_at to NOW if event occurs
repo.UpdateProgress(&UserGoalProgress{
    UserID:      userID,
    GoalID:      goalID,
    Progress:    1,  // Always 1 for daily goals
    Status:      "completed",
    CompletedAt: time.Now(),  // Key: timestamp for daily check
})
```

**Claim Validation:**
```go
// In claim flow, check if completed today
progress := repo.GetProgress(userID, goalID)

today := time.Now().Truncate(24 * time.Hour)
completedDate := progress.CompletedAt.Truncate(24 * time.Hour)

if completedDate.Equal(today) {
    // Completed today - allow claim
    grantReward()
} else {
    return errors.New("goal not completed today")
}
```

**Database Operation:** UPSERT with timestamp
```sql
-- Sets progress = 1, completed_at = NOW()
progress = 1,
completed_at = NOW(),
status = 'completed'
```

**Key Characteristics:**
- **Binary progress**: Always 0 or 1 (never accumulates)
- **Resets daily**: Claim checks if completed_at is today (not status field)
- **Repeatable reward**: User can claim once per day, every day
- **Same-day events**: Multiple logins per day → last timestamp wins (deduplication)
- **Database field**: Uses `completed_at` timestamp (not progress counter)
- **Typical use case**: Daily login bonus, daily spin, daily quest

**Example Flow:**
```
Day 1: User logs in → progress=1, completed_at="2025-10-17", status="completed"
Day 1: User claims reward → claimed_at="2025-10-17" (claimed today)
Day 1: User logs in again → completed_at updated, can claim again today
Day 2: User logs in → completed_at="2025-10-18", status="completed" (reset)
Day 2: User can claim again (new day, repeatable reward)
```

### EventProcessor Routing Logic

The `ProcessEvent` method uses a single entry point with switch-based routing to different repository methods based on goal type. This design follows Decision Q13 from Phase 5.2.2d (see BRAINSTORM.md).

**Architectural Decision:** Single `ProcessEvent()` method with switch statement routing (not separate methods per event type). Benefits: unified error handling, simpler concurrency control, easier testing.

```go
func (p *EventProcessor) ProcessEvent(ctx context.Context, userID, namespace string, event *Event) error {
    // Acquire per-user mutex (prevents race conditions)
    lock := p.getUserLock(userID)
    lock.Lock()
    defer lock.Unlock()

    // Extract stat updates from event (Decision Q14: handle both login and stat events)
    statUpdates := extractStatUpdates(event)  // map[statCode]value

    // For each stat update
    for statCode, value := range statUpdates {
        // Get goals tracking this stat (O(1) cache lookup)
        goals := p.goalCache.GetGoalsByStatCode(statCode)

        for _, goal := range goals {
            // Skip if already claimed (Decision Q16: no updates to claimed goals)
            if p.isAlreadyClaimed(userID, goal.ID) {
                continue
            }

            // Skip if prerequisites not met (Decision Q16: locked goals)
            if p.isGoalLocked(userID, goal) {
                continue
            }

            // Route based on goal type (Decision Q13: switch statement)
            switch goal.Type {
            case domain.GoalTypeAbsolute:
                // Absolute stat value (e.g., kills=100)
                // Decision Q17: Always replace with new stat value
                p.processAbsoluteGoal(userID, namespace, goal, int(value))

            case domain.GoalTypeIncrement:
                // Increment counter (e.g., login count, daily login days)
                // Decision Q14: Login events use IncrementProgress
                // Decision Q18: Daily flag affects BufferedRepository behavior
                p.processIncrementGoal(userID, namespace, goal, 1)  // Always +1

            case domain.GoalTypeDaily:
                // Daily occurrence check (e.g., daily login bonus)
                // Decision Q18: Daily type is different from Increment with daily flag
                p.processDailyGoal(userID, namespace, goal)

            default:
                // Decision Q16: Graceful degradation for unknown types
                p.logger.Warnf("Unknown goal type '%s' for goal %s, skipping", goal.Type, goal.ID)
            }
        }
    }

    return nil
}
```

**Design Decisions Referenced:**
- **Q13 (BRAINSTORM.md):** Single ProcessEvent method with switch routing
- **Q14 (BRAINSTORM.md):** Login events route by goal type (not hardcoded to increment)
- **Q15 (BRAINSTORM.md):** Add validation for negative stat values with graceful degradation
- **Q16 (BRAINSTORM.md):** Unknown goal types log warning and skip (no panic)
- **Q17 (BRAINSTORM.md):** Absolute goals always replace with new stat value
- **Q18 (BRAINSTORM.md):** Daily type vs Increment with daily flag are fundamentally different

### Repository Method Routing

The EventProcessor delegates to three helper methods based on goal type. Each method encapsulates the specific logic for that goal type.

```go
// processAbsoluteGoal handles stat-based goals with absolute values
// Decision Q17: Always replace with new stat value (no comparison needed)
func (p *EventProcessor) processAbsoluteGoal(userID, namespace string, goal *domain.Goal, value int) {
    // Decision Q15: Add validation for negative values
    if value < 0 {
        p.logger.Warnf("Negative stat value %d for goal %s, user %s, skipping",
            value, goal.ID, userID)
        return  // Graceful degradation: skip invalid values
    }

    // Calculate status based on progress vs target
    status := "in_progress"
    var completedAt *time.Time
    if value >= goal.Requirement.TargetValue {
        status = "completed"
        now := time.Now()
        completedAt = &now
    }

    // Update progress with absolute value
    p.bufferedRepo.UpdateProgress(&domain.UserGoalProgress{
        UserID:      userID,
        GoalID:      goal.ID,
        ChallengeID: goal.ChallengeID,
        Namespace:   namespace,
        Progress:    value,  // Absolute value (replaces previous)
        Status:      status,
        CompletedAt: completedAt,
    })
}

// processIncrementGoal handles counter-based goals (both regular and daily)
// Decision Q14: Login events use IncrementProgress (not UpdateProgress)
// Decision Q18: Daily flag affects BufferedRepository behavior (date checking)
func (p *EventProcessor) processIncrementGoal(userID, namespace string, goal *domain.Goal, delta int) {
    // BufferedRepository accumulates deltas before flush
    // For daily increments: BufferedRepository checks date before buffering
    // Multiple events: delta=1, delta=1, delta=1 → flush with delta=3 (regular)
    //                  delta=1, delta=SKIP, delta=SKIP → flush with delta=1 (daily)
    p.bufferedRepo.IncrementProgress(
        userID,
        goal.ID,
        goal.ChallengeID,
        namespace,
        delta,  // Always 1 for login events
        goal.Requirement.TargetValue,
        goal.Daily,  // Decision Q18: Pass daily flag to BufferedRepository
    )
}

// processDailyGoal handles binary daily check goals
// Decision Q18: Daily type is different from Increment with daily flag
func (p *EventProcessor) processDailyGoal(userID, namespace string, goal *domain.Goal) {
    now := time.Now()

    // Daily goals always set progress=1 and completed_at=NOW()
    // Claim validation checks if completed_at is today (repeatable reward)
    p.bufferedRepo.UpdateProgress(&domain.UserGoalProgress{
        UserID:      userID,
        GoalID:      goal.ID,
        ChallengeID: goal.ChallengeID,
        Namespace:   namespace,
        Progress:    1,  // Always 1 for daily (binary check)
        Status:      "completed",
        CompletedAt: &now,  // Key: timestamp for daily check
    })
}
```

**Helper Method Responsibilities:**

| Method | Goal Type | Repository Method | Validation | Key Logic |
|--------|-----------|-------------------|------------|-----------|
| `processAbsoluteGoal` | `absolute` | `UpdateProgress()` | Negative value check | Replace with absolute value |
| `processIncrementGoal` | `increment` | `IncrementProgress()` | None (delta always 1) | Accumulate deltas, daily flag controls date checking |
| `processDailyGoal` | `daily` | `UpdateProgress()` | None | Always progress=1, completed_at=NOW() |

### Event to Goal Type Mapping

**Updated based on Decision Q13-Q18 (BRAINSTORM.md Phase 5.2.2d):**

| Event Type | Event Field | Goal Type | Goal.Daily Flag | Repository Method | Database Operation | Use Case |
|------------|-------------|-----------|-----------------|-------------------|-------------------|----------|
| Statistic Update | `payload.value` (absolute) | `absolute` | N/A | `UpdateProgress(value)` | `progress = value` | Kill 100 snowmen |
| IAM Login | No value (binary) | `increment` | `false` | `IncrementProgress(1, isDailyIncrement=false)` | `progress = progress + 1` | Login 5 times total |
| IAM Login | No value (binary) | `increment` | `true` | `IncrementProgress(1, isDailyIncrement=true)` | `progress = progress + 1` (max once/day) | Login 7 distinct days |
| IAM Login | No value (binary) | `daily` | N/A | `UpdateProgress(progress=1, completed_at=NOW)` | `completed_at = NOW()` | Daily login bonus |

**Key Decision Points:**
- **Decision Q14:** Login events route by goal type (not hardcoded to increment)
- **Decision Q17:** Absolute goals always replace with new stat value
- **Decision Q18:** Daily type vs Increment with daily flag are fundamentally different

### Configuration Examples

**Example 1: Stat-Based Goal (Absolute)**
```json
{
  "id": "kill-100-snowmen",
  "name": "Snowman Hunter",
  "type": "absolute",
  "requirement": {
    "stat_code": "snowman_kills",
    "operator": ">=",
    "target_value": 100
  },
  "reward": {
    "type": "ITEM",
    "item_id": "rare_weapon_skin",
    "quantity": 1
  }
}
```

**Example 2: Login Count Goal (Increment - Regular)**
```json
{
  "id": "login-5-times",
  "name": "Frequent Player",
  "type": "increment",
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 5
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "GOLD",
    "amount": 100
  }
}
```

**Example 3: Login 7 Days Goal (Increment with Daily Flag)**
```json
{
  "id": "login-7-days-challenge",
  "name": "Weekly Warrior",
  "type": "increment",
  "daily": true,
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 7
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "PREMIUM_CURRENCY",
    "amount": 500
  }
}
```

**Example 4: Daily Login Bonus (Daily Type)**
```json
{
  "id": "daily-login-bonus",
  "name": "Daily Check-In",
  "type": "daily",
  "requirement": {
    "stat_code": "login_daily",
    "operator": ">=",
    "target_value": 1
  },
  "reward": {
    "type": "WALLET",
    "currency_code": "GOLD",
    "amount": 50
  }
}
```

**Key Differences in Configuration:**

| Goal Type | Config Example | Daily Flag | Target Value | Reward Frequency |
|-----------|----------------|------------|--------------|------------------|
| Absolute | `"type": "absolute"` | N/A | Any (e.g., 100) | One-time |
| Increment (Regular) | `"type": "increment"` | Not present or `false` | Any (e.g., 5) | One-time |
| Increment (Daily) | `"type": "increment", "daily": true` | `true` | Any (e.g., 7, 30) | One-time |
| Daily | `"type": "daily"` | N/A | Always 1 | Repeatable (daily) |

### Design Benefits

1. **Type Safety**: Explicit goal types prevent misuse (e.g., treating login as stat value)
2. **Performance**: Atomic increments avoid read-modify-write races
3. **Correctness**: Daily goals use timestamps, not counters
4. **Buffering Compatibility**: All three types work with buffering (1,000,000x reduction preserved)
5. **Extensibility**: Easy to add new goal types (e.g., `weekly`, `streak`)

### Migration Path

**For Existing Deployments:**

If `type` field is missing from goal config, default to `"absolute"` for backward compatibility:

```go
func (v *Validator) validateGoal(goal *domain.Goal) error {
    // Default to absolute if type not specified
    if goal.Type == "" {
        goal.Type = domain.GoalTypeAbsolute
    }

    // Validate type
    validTypes := []domain.GoalType{
        domain.GoalTypeAbsolute,
        domain.GoalTypeIncrement,
        domain.GoalTypeDaily,
    }

    if !contains(validTypes, goal.Type) {
        return fmt.Errorf("invalid goal type: %s", goal.Type)
    }

    return nil
}
```

**See Also:**
- [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md) - Goal type schema and validation
- [TECH_SPEC_DATABASE.md](./TECH_SPEC_DATABASE.md) - Atomic increment SQL query
- [BRAINSTORM.md](./BRAINSTORM.md) - Option 5 design decision

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
  "type": "daily",
  "requirement": {"stat_code": "login_daily", "target_value": 1}
}
```

**Config Validation:**
- `event_source` is required (no default)
- Must be `"login"` or `"statistic"`
- See [TECH_SPEC_CONFIGURATION.md](./TECH_SPEC_CONFIGURATION.md#event-sources)

#### Q2: Login Event Stat Value ✅

**Decision:** Always use `statValue = 1` for login events

**Rationale:**
- Login is a binary event (happened or not)
- Increment goals count occurrences: 1 login = 1 increment
- Daily goals just check timestamp, stat value unused
- Absolute goals not applicable for login events

**Implementation:**
```go
func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    statValue := 1  // Always 1 for login events

    // Find all login-triggered goals
    goals := h.goalCache.GetAllGoals()
    for _, goal := range goals {
        if goal.EventSource == domain.EventSourceLogin {
            h.processor.ProcessEvent(userID, goal.ID, statValue)
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
            "type", goal.Type)

        // Always use statValue=1 for login events (Decision Q2)
        err := h.processor.ProcessEvent(userID, goal.ID, 1)
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
        Type: domain.GoalTypeDaily,
    }

    mockCache.On("GetAllGoals").Return([]*domain.Goal{loginGoal})
    mockProcessor.On("ProcessEvent", "user123", "daily-login", 1).Return(nil)

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

```go
type BufferedRepository struct {
    buffer        map[string]*UserGoalProgress  // key: "{user_id}:{goal_id}"
    mu            sync.RWMutex
    ticker        *time.Ticker
    repo          GoalRepository
    logger        *log.Logger
    maxBufferSize int  // Maximum entries before forcing flush
}

func NewBufferedRepository(repo GoalRepository, flushInterval time.Duration, maxBufferSize int) *BufferedRepository {
    r := &BufferedRepository{
        buffer:        make(map[string]*UserGoalProgress),
        ticker:        time.NewTicker(flushInterval),
        repo:          repo,
        maxBufferSize: maxBufferSize,  // Default: 1000
    }

    go r.startFlusher()

    return r
}
```

### Buffer Operations

#### 1. UpdateProgress (Write to Buffer)

```go
func (r *BufferedRepository) UpdateProgress(progress *UserGoalProgress) {
    r.mu.Lock()
    defer r.mu.Unlock()

    key := fmt.Sprintf("%s:%s", progress.UserID, progress.GoalID)

    // Overwrite previous buffered update (deduplication)
    r.buffer[key] = progress

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
- Map key ensures only one pending update per user-goal pair
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
    r.buffer = make(map[string]*UserGoalProgress)

    r.mu.Unlock()  // ← Release lock BEFORE processing (Decision Q2, Phase 5.2.2c)

    // Early return if nothing to flush
    if len(bufferToFlush) == 0 {
        return nil
    }

    r.logger.Info("Flushing buffered updates", "count", len(bufferToFlush))

    // Collect all buffered updates (outside lock)
    updates := make([]*UserGoalProgress, 0, len(bufferToFlush))
    for _, progress := range bufferToFlush {
        updates = append(updates, progress)
    }

    // Batch UPSERT all updates in single database call (outside lock)
    err := r.repo.BatchUpsertProgress(updates)
    if err != nil {
        r.logger.Error("Failed to flush batch", "count", len(updates), "error", err)

        // Re-acquire lock to restore failed updates for retry
        r.mu.Lock()
        for key, progress := range bufferToFlush {
            // Only restore if not already updated by newer event
            if _, exists := r.buffer[key]; !exists {
                r.buffer[key] = progress
            }
        }
        r.mu.Unlock()

        return err
    }

    r.logger.Info("Successfully flushed updates", "count", len(updates))
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
func (r *BufferedRepository) UpdateProgress(ctx context.Context, progress *domain.UserGoalProgress) error {
    // Input validation
    if progress == nil {
        return fmt.Errorf("progress cannot be nil")
    }
    if progress.UserID == "" {
        return fmt.Errorf("userID cannot be empty")
    }
    if progress.GoalID == "" {
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
            "user_id":     progress.UserID,
            "goal_id":     progress.GoalID,
        }).Error("Buffer overflow: too many failed flushes")
        return fmt.Errorf("buffer overflow: size %d exceeds max %d (database may be unavailable)", len(r.buffer), r.maxBufferSize*2)
    }

    key := fmt.Sprintf("%s:%s", progress.UserID, progress.GoalID)
    r.buffer[key] = progress

    // ... rest of implementation
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

func (r *BufferedRepository) UpdateProgress(ctx context.Context, progress *domain.UserGoalProgress) error {
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

### Daily Increment Buffering

**New in Phase 5.2**: Support for daily increment goals ("Login 7 days") requires client-side date checking to prevent same-day duplicates.

#### Problem Statement

Daily increment goals (`type: "increment", daily: true`) should only increment once per day:
- User logs in 3 times on Day 1 → progress = 1 (not 3)
- User logs in 1 time on Day 2 → progress = 2
- Without client-side checking, all 3 Day 1 events would be buffered and flushed, causing incorrect DB increments

#### Solution: Dual Buffer Strategy

Buff eredRepository maintains TWO separate buffer maps:

```go
type BufferedRepository struct {
    // Existing fields
    buffer        map[string]*UserGoalProgress  // Absolute/daily goals
    mu            sync.RWMutex
    ticker        *time.Ticker
    repo          GoalRepository
    maxBufferSize int

    // NEW: Daily increment tracking
    bufferIncrement     map[string]int        // Regular increments: "userID:goalID" -> delta
    bufferIncrementDaily map[string]time.Time  // Daily increments: "userID:goalID" -> last_event_time
}
```

**Key Design:**
- `bufferIncrement`: Accumulates deltas for regular increment goals (e.g., total login count)
- `bufferIncrementDaily`: Tracks last event time for daily increment goals (e.g., login days)

#### IncrementProgress Implementation

```go
func (r *BufferedRepository) IncrementProgress(ctx context.Context, userID, goalID, challengeID, namespace string,
    delta, targetValue int, isDailyIncrement bool) error {

    r.mu.Lock()
    defer r.mu.Unlock()

    key := fmt.Sprintf("%s:%s", userID, goalID)

    if isDailyIncrement {
        // Client-side date checking for daily increments
        lastEventTime, exists := r.bufferIncrementDaily[key]
        now := time.Now()
        // Use shared date utility to ensure consistency with SQL DATE() function
        // (Decision Q3a, Phase 5.2.2c)
        today := dateutil.GetCurrentDateUTC()  // From: extend-challenge-common/pkg/common/dateutil.go

        if exists {
            lastEventDate := dateutil.TruncateToDateUTC(lastEventTime)
            if lastEventDate.Equal(today) {
                // Same day - skip buffering
                r.logger.Debug("Skipping daily increment: same day",
                    "userID", userID,
                    "goalID", goalID,
                    "lastEvent", lastEventTime,
                    "currentEvent", now)
                return nil
            }
        }

        // Graceful degradation: Check if bufferIncrementDaily is at capacity
        // Hard limit: 200K entries (Decision Q1b, Phase 5.2.2c)
        if len(r.bufferIncrementDaily) >= 200000 && !exists {
            // Buffer full - skip storing timestamp, but still increment progress
            // SQL DATE() check in database will prevent same-day duplicates
            // (Decision Q1d, Phase 5.2.2c)
            r.logger.Warn("bufferIncrementDaily at capacity, relying on SQL date check",
                "size", len(r.bufferIncrementDaily),
                "userID", userID,
                "goalID", goalID)
            // Fall through to buffer the increment (DB will deduplicate)
        } else {
            // Normal case: New day or first event - buffer timestamp
            r.bufferIncrementDaily[key] = now
        }

        // Always add to increment buffer for flush (even if daily buffer is full)
        r.bufferIncrement[key] = delta  // Always 1 for daily

    } else {
        // Regular increment - accumulate deltas
        r.bufferIncrement[key] += delta
    }

    return nil
}
```

**Client-Side Date Checking:**
1. Check if we've already seen event for this user-goal today
2. If yes (same day): Skip buffering (no duplicate increment)
3. If no (new day or first event): Buffer the increment

#### Shared Date Utility Functions

**Location:** `extend-challenge-common/pkg/common/dateutil.go` (Decision Q3a, Phase 5.2.2c)

**Purpose:** Ensure consistent date calculation between Go code and PostgreSQL SQL `DATE()` function.

**Implementation:**

```go
package dateutil

import "time"

// GetCurrentDateUTC returns the current date in UTC, truncated to midnight (00:00:00).
// This matches PostgreSQL's DATE() function behavior for consistency.
//
// Example:
//   - Input: 2025-10-17 14:23:45 UTC
//   - Output: 2025-10-17 00:00:00 UTC
func GetCurrentDateUTC() time.Time {
    return time.Now().UTC().Truncate(24 * time.Hour)
}

// TruncateToDateUTC truncates the given time to midnight (00:00:00) in UTC.
// This matches PostgreSQL's DATE() function behavior for consistency.
//
// Example:
//   - Input: 2025-10-17 14:23:45 UTC
//   - Output: 2025-10-17 00:00:00 UTC
func TruncateToDateUTC(t time.Time) time.Time {
    return t.UTC().Truncate(24 * time.Hour)
}
```

**Usage in BufferedRepository:**
- Daily increment date checking (IncrementProgress)
- Ensures Go date logic matches SQL `DATE(completed_at)` in database queries
- Prevents edge case mismatches between Go and PostgreSQL date calculations

**Testing:** Integration test verifies Go date calculation matches SQL `DATE()` function (Decision Q3b, Phase 5.2.2c).

**See Also:** `TECH_SPEC_DATABASE.md` for SQL date handling in `BatchIncrementProgress` query.

#### Map Growth Control

**Problem:** `bufferIncrementDaily` map grows unbounded as more users trigger daily increments.

**Solution:** Periodic cleanup removes entries older than 48 hours.

```go
type BufferedRepository struct {
    // ... existing fields
    cleanupTicker *time.Ticker  // Cleanup every 1 hour
}

func NewBufferedRepository(repo GoalRepository, flushInterval time.Duration, maxBufferSize int) *BufferedRepository {
    r := &BufferedRepository{
        buffer:              make(map[string]*UserGoalProgress),
        bufferIncrement:     make(map[string]int),
        bufferIncrementDaily: make(map[string]time.Time),
        ticker:              time.NewTicker(flushInterval),
        cleanupTicker:       time.NewTicker(1 * time.Hour),  // NEW
        repo:                repo,
        maxBufferSize:       maxBufferSize,
    }

    go r.startFlusher()
    go r.startDailyBufferCleanup()  // NEW

    return r
}

func (r *BufferedRepository) startDailyBufferCleanup() {
    for range r.cleanupTicker.C {
        r.cleanupOldDailyEntries()
    }
}

func (r *BufferedRepository) cleanupOldDailyEntries() {
    r.mu.Lock()
    defer r.mu.Unlock()

    now := time.Now()
    cutoff := now.Add(-48 * time.Hour)  // Keep last 2 days
    cleaned := 0

    for key, lastEventTime := range r.bufferIncrementDaily {
        if lastEventTime.Before(cutoff) {
            delete(r.bufferIncrementDaily, key)
            cleaned++
        }
    }

    if cleaned > 0 {
        r.logger.Info("Cleaned up old daily increment entries",
            "cleaned", cleaned,
            "remaining", len(r.bufferIncrementDaily))
    }
}
```

**Cleanup Characteristics:**

| Aspect | Value | Notes |
|--------|-------|-------|
| **Cleanup interval** | 1 hour | Balance between overhead and memory |
| **Retention period** | 48 hours | Keeps today + yesterday for safety |
| **Memory impact** | Minimal | ~40 bytes per entry × active users |
| **Max map size** | ~100K entries | 1M daily active users × ~10% daily goals |

**Growth Scenario:**
- 1M daily active users
- 10 daily increment goals per user
- Worst case: 10M entries before first cleanup
- With cleanup: Caps at ~200K entries (today + yesterday's active users)
- Memory: 200K × 40 bytes = ~8MB (acceptable)

#### Graceful Degradation When Buffer is Full

**Hard Limit:** 200K entries in `bufferIncrementDaily` (Decision Q1b, Phase 5.2.2c)

**Problem:** During extreme traffic (e.g., 10M daily active users), `bufferIncrementDaily` could exceed memory budget before hourly cleanup runs.

**Solution:** Graceful degradation - rely on SQL `DATE()` check when buffer is full (Decision Q1d, Phase 5.2.2c)

**Behavior When Buffer Reaches 200K:**

1. **Check capacity** before adding new entry to `bufferIncrementDaily`
2. **If full** (≥200K entries):
   - Skip storing timestamp in `bufferIncrementDaily`
   - Still add delta to `bufferIncrement` (progress tracking continues)
   - Log warning with buffer size and user/goal info
3. **Database handles deduplication**:
   - `BatchIncrementProgress` SQL query uses `DATE(completed_at) = CURRENT_DATE` check
   - Prevents same-day duplicate increments even without client-side tracking
   - Slight performance cost (DB query instead of map lookup), but system remains functional

**Degradation Characteristics:**

| Aspect | Normal Operation | Degraded (Buffer Full) |
|--------|------------------|------------------------|
| **Client-side dedup** | ✅ Map lookup (O(1)) | ❌ Skipped |
| **DB-side dedup** | ✅ SQL DATE() check | ✅ SQL DATE() check |
| **Correctness** | ✅ Guaranteed | ✅ Guaranteed |
| **Performance** | Optimal | Slightly slower (extra DB check) |
| **Memory usage** | Bounded (200K cap) | Bounded (200K cap) |

**Why This is Acceptable:**

- **Rare scenario**: Requires 10M+ daily users before hourly cleanup runs
- **Maintains correctness**: No duplicate increments, progress tracking continues
- **Bounded memory**: Caps at 200K entries (~8MB), prevents OOM
- **Automatic recovery**: Hourly cleanup will free space, restoring normal operation
- **Observable**: Warning logs allow monitoring and capacity planning

**Example Scenario:**

```
Day 1, 00:00: System starts, bufferIncrementDaily empty
Day 1, 08:00: 150K users login, buffer has 150K entries
Day 1, 09:00: Cleanup runs, keeps last 48h (~150K entries remain)
Day 1, 16:00: Another 150K new users, buffer reaches 200K limit
Day 1, 16:01: User #200,001 logs in:
  - bufferIncrementDaily full, skip storing timestamp
  - Still add to bufferIncrement
  - SQL DATE() check prevents duplicate if user logs in again today
Day 1, 17:00: Cleanup runs, frees entries >48h old
Day 1, 17:01: Buffer back to normal capacity, client-side dedup resumes
```

**Monitoring:**

Watch for log entries: `"bufferIncrementDaily at capacity, relying on SQL date check"`

If frequent, consider:
- Reducing cleanup interval (30 minutes instead of 1 hour)
- Increasing hard limit (500K instead of 200K)
- Horizontal scaling (more event handler replicas)

#### Flush Integration

Modified flush logic handles both buffer types using **separate transactions** (Decision: BRAINSTORM.md Q12) and **swap pattern** for faster unlock (Decision Q2, Phase 5.2.2c):

```go
func (r *BufferedRepository) Flush() error {
    r.mu.Lock()

    // Swap pattern: Copy all buffer references and create new empty buffers
    // This releases the lock immediately, allowing event processing to continue
    absoluteToFlush := r.buffer
    r.buffer = make(map[string]*UserGoalProgress)

    incrementToFlush := r.bufferIncrement
    r.bufferIncrement = make(map[string]int)

    dailyToFlush := r.bufferIncrementDaily
    r.bufferIncrementDaily = make(map[string]time.Time)

    r.mu.Unlock()  // ← Release lock BEFORE processing (Decision Q2, Phase 5.2.2c)

    // Early return if nothing to flush
    if len(absoluteToFlush) == 0 && len(incrementToFlush) == 0 {
        return nil
    }

    var flushErrors []error

    // 1. Flush absolute/daily goals (INDEPENDENT TRANSACTION)
    if len(absoluteToFlush) > 0 {
        absoluteUpdates := make([]*UserGoalProgress, 0, len(absoluteToFlush))
        for _, progress := range absoluteToFlush {
            absoluteUpdates = append(absoluteUpdates, progress)
        }

        err := r.repo.BatchUpsertProgress(context.Background(), absoluteUpdates)
        if err != nil {
            r.logger.Error("Failed to flush absolute updates, will retry",
                "count", len(absoluteUpdates),
                "error", err)
            flushErrors = append(flushErrors, fmt.Errorf("absolute flush: %w", err))

            // Re-acquire lock to restore failed updates for retry
            r.mu.Lock()
            for key, progress := range absoluteToFlush {
                if _, exists := r.buffer[key]; !exists {
                    r.buffer[key] = progress
                }
            }
            r.mu.Unlock()
        } else {
            r.logger.Info("Successfully flushed absolute updates",
                "count", len(absoluteUpdates))
            // Buffer already cleared via swap pattern (no action needed)
        }
    }

    // 2. Flush increment goals (INDEPENDENT TRANSACTION)
    if len(incrementToFlush) > 0 {
        // Collect all increments into batch array
        increments := make([]ProgressIncrement, 0, len(incrementToFlush))

        for key, delta := range incrementToFlush {
            parts := strings.Split(key, ":")
            userID, goalID := parts[0], parts[1]

            // Look up goal metadata from cache
            goal := r.goalCache.GetGoalByID(goalID)
            if goal == nil {
                r.logger.Warn("Goal not found for increment", "goalID", goalID)
                continue
            }

            // Add to batch
            increments = append(increments, ProgressIncrement{
                UserID:            userID,
                GoalID:            goalID,
                ChallengeID:       goal.ChallengeID,
                Namespace:         r.namespace,
                Delta:             delta,
                TargetValue:       goal.Requirement.TargetValue,
                IsDailyIncrement:  goal.Daily,
            })
        }

        // Batch increment all goals in single database query
        if len(increments) > 0 {
            err := r.repo.BatchIncrementProgress(context.Background(), increments)
            if err != nil {
                r.logger.Error("Failed to flush increment updates, will retry",
                    "count", len(increments),
                    "error", err)
                flushErrors = append(flushErrors, fmt.Errorf("increment flush: %w", err))

                // Re-acquire lock to restore failed updates for retry
                r.mu.Lock()
                for key, delta := range incrementToFlush {
                    // Accumulate with any new deltas that arrived during flush
                    r.bufferIncrement[key] += delta
                }
                // Restore daily tracking map (timestamp preservation - Decision Q5, Phase 5.2.2c)
                for key, timestamp := range dailyToFlush {
                    if _, exists := r.bufferIncrementDaily[key]; !exists {
                        r.bufferIncrementDaily[key] = timestamp  // Keep original timestamp
                    }
                }
                r.mu.Unlock()
            } else {
                r.logger.Info("Successfully flushed increment updates",
                    "count", len(increments))
                // Buffers already cleared via swap pattern (no action needed)
                // Note: bufferIncrementDaily was also swapped but not restored on success
                // (Cleanup goroutine will remove old entries after 48h)
            }
        }
    }

    // Return combined errors (if any), but don't fail the flush entirely
    // This allows partial success: one buffer type can succeed while the other retries
    if len(flushErrors) > 0 {
        return fmt.Errorf("flush partial failure: %v", flushErrors)
    }

    return nil
}
```

**Transaction Strategy (BRAINSTORM.md Q12):**
- **Option B: Separate Transactions** (APPROVED)
- Each buffer type (absolute vs increment) uses independent transaction
- **Benefits:**
  - Simpler implementation (no cross-buffer coordination)
  - Independent failure recovery (absolute success doesn't depend on increment success)
  - Fault isolation (database error in one query type doesn't block the other)
- **Trade-off Accepted:**
  - Eventual consistency (one buffer might flush while other fails and retries in 1 sec)
  - Acceptable for M1: Event-driven system with 1-sec retry interval

**Key Points:**
- Flush both absolute and increment buffers independently
- Use `BatchIncrementProgress` for all increments in single query (vs N individual queries)
- Keep `bufferIncrementDaily` entries even after flush (for date checking)
- Periodic cleanup removes old entries (not flush)
- Partial success allowed: One buffer type can succeed while the other retries

**Performance Benefit:**
```
❌ Individual IncrementProgress calls (1,000 goals):
  - Queries: 1,000 queries
  - Time: ~1,000ms (1ms per query × 1,000)
  - Network overhead: 1,000 round trips

✅ BatchIncrementProgress (1,000 goals):
  - Queries: 1 query
  - Time: ~20ms
  - Network overhead: 1 round trip

Improvement: 50× faster, 1,000× fewer round trips
```

#### Performance Impact

**Memory Usage:**

| Component | Size per Entry | Max Entries | Total Memory |
|-----------|---------------|-------------|--------------|
| `bufferIncrement` | ~32 bytes (string + int) | 1,000 | ~32KB |
| `bufferIncrementDaily` | ~40 bytes (string + time.Time) | 200,000 (2 days) | ~8MB |
| **Total** | - | - | **~8MB** (acceptable) |

**Benefits:**
- Same-day duplicate prevention (client-side, no DB queries)
- Bounded memory growth (periodic cleanup)
- Fast lookups (map O(1))
- No performance penalty for regular increments

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

    // For login-based goals, treat as a "login_count" stat increment
    statUpdates := map[string]int{
        "login_count": 1,  // Simple increment for login tracking
    }

    // Process using common event processor
    err := h.processor.ProcessEvent(ctx, userID, namespace, statUpdates)
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

    h.logger.Infof("Processing stat update: user=%s stat=%s value=%d", userID, statCode, value)

    // Create stat updates map
    statUpdates := map[string]int{
        statCode: value,
    }

    // Process using common event processor
    err := h.processor.ProcessEvent(ctx, userID, namespace, statUpdates)
    if err != nil {
        h.logger.Errorf("Failed to process stat event: %v", err)
        return &emptypb.Empty{}, status.Errorf(codes.Internal, "failed to process event: %v", err)
    }

    duration := time.Since(startTime)
    h.logger.Infof("Stat event processed: user=%s stat=%s value=%d duration=%dms",
        userID, statCode, value, duration.Milliseconds())

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

```go
func (p *EventProcessor) ProcessEvent(ctx context.Context, userID, namespace string, statUpdates map[string]int) error {
    // 1. Acquire user lock
    lock := p.getUserLock(userID)
    lock.Lock()
    defer lock.Unlock()

    // 2. For each stat update
    for statCode, value := range statUpdates {
        // 3. Get goals tracking this stat (O(1) cache lookup)
        goals := p.goalCache.GetGoalsByStatCode(statCode)

        for _, goal := range goals {
            // 4. Check if already claimed
            progress := p.getProgress(userID, goal.ID)
            if progress != nil && progress.Status == "claimed" {
                continue
            }

            // 5. Check prerequisites
            if p.isGoalLocked(userID, goal) {
                continue
            }

            // 6. Calculate new status
            newStatus := "in_progress"
            var completedAt *time.Time
            if value >= goal.Requirement.TargetValue {
                newStatus = "completed"
                now := time.Now()
                completedAt = &now
            }

            // 7. Buffer update
            p.bufferedRepo.UpdateProgress(&UserGoalProgress{
                UserID:      userID,
                GoalID:      goal.ID,
                ChallengeID: goal.ChallengeID,
                Namespace:   namespace,
                Progress:    value,
                Status:      newStatus,
                CompletedAt: completedAt,
            })
        }
    }

    return nil
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
    float value = 2;
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

    // Buffer some updates
    repo.UpdateProgress(&progress1)
    repo.UpdateProgress(&progress2)
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
    r.buffer = make(map[string]*UserGoalProgress)

    r.mu.Unlock()  // Release lock before DB operation

    // Early return if nothing to flush
    if len(bufferToFlush) == 0 {
        return nil
    }

    r.logger.Info("Flushing buffered updates", "count", len(bufferToFlush))

    // Collect updates for batch operation
    updates := make([]*UserGoalProgress, 0, len(bufferToFlush))
    for _, progress := range bufferToFlush {
        updates = append(updates, progress)
    }

    // Attempt batch UPSERT
    err := r.repo.BatchUpsertProgress(context.Background(), updates)
    if err != nil {
        r.logger.Error("Failed to flush batch, will retry on next interval",
            "count", len(updates),
            "error", err,
            "nextRetry", "1 second")

        // ERROR RECOVERY: Re-add failed updates to buffer for retry
        r.mu.Lock()
        for key, progress := range bufferToFlush {
            // Only restore if not already updated by newer event
            // (Newer event takes precedence - "last write wins")
            if _, exists := r.buffer[key]; !exists {
                r.buffer[key] = progress
            }
        }
        r.mu.Unlock()

        return err
    }

    r.logger.Info("Successfully flushed updates", "count", len(updates))
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
// M2+ enhancement (not in M1)
func (r *BufferedRepository) FlushWithFallback() error {
    err := r.repo.BatchUpsertProgress(updates)
    if err != nil {
        // Try individual UPSERTs to identify bad row
        for _, update := range updates {
            if err := r.repo.UpsertProgress(update); err != nil {
                r.logger.Error("Permanently failed update",
                    "userID", update.UserID,
                    "goalID", update.GoalID,
                    "error", err)
                // Skip this update (don't retry)
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

    // Buffer some updates
    repo.UpdateProgress(&progress1)
    repo.UpdateProgress(&progress2)

    // First flush fails
    err := repo.Flush()
    assert.Error(t, err)
    assert.Equal(t, 2, repo.GetBufferSize())  // Updates still in buffer

    // Fix database
    mockDB.BatchUpsertError = nil

    // Second flush succeeds
    err = repo.Flush()
    assert.NoError(t, err)
    assert.Equal(t, 0, repo.GetBufferSize())  // Buffer cleared
}

func TestFlushPreservesNewerUpdates(t *testing.T) {
    mockDB := &MockRepository{
        BatchUpsertError: errors.New("timeout"),
    }
    repo := NewBufferedRepository(mockDB, 1*time.Second, 1000)

    // Buffer update (progress=5)
    repo.UpdateProgress(&UserGoalProgress{
        UserID: "user1",
        GoalID: "goal1",
        Progress: 5,
    })

    // Flush fails
    repo.Flush()
    assert.Equal(t, 1, repo.GetBufferSize())

    // New event with higher progress
    repo.UpdateProgress(&UserGoalProgress{
        UserID: "user1",
        GoalID: "goal1",
        Progress: 10,  // Newer value
    })

    // Verify newer value takes precedence
    assert.Equal(t, 1, repo.GetBufferSize())
    buffered := repo.GetFromBuffer("user1", "goal1")
    assert.Equal(t, 10, buffered.Progress)  // Not 5
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

**Document Status:** Complete - Ready for implementation
