# Technical Specification: API Design

**Version:** 2.0
**Date:** 2025-11-17
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Overview](#overview)
2. [Client Integration Requirements](#client-integration-requirements)
3. [Authentication](#authentication)
4. [Endpoints](#endpoints)
   - [Get User Challenges](#1-get-user-challenges)
   - [Claim Goal Reward](#2-claim-goal-reward)
   - [Initialize Player Goals](#3-initialize-player-goals-m3)
   - [Set Goal Active/Inactive](#4-set-goal-activeinactive-m3)
   - [Health Check](#5-health-check-fq5)
   - [Batch Manual Selection (M4)](#6-batch-manual-selection-m4)
   - [Random Goal Selection (M4)](#7-random-goal-selection-m4)
5. [Error Handling](#error-handling)
6. [HTTP Handler Implementation](#http-handler-implementation)

---

## Overview

### API Style
- **Type**: RESTful HTTP API (via gRPC Gateway)
- **Format**: JSON request/response bodies
- **Framework**: Extend Service Extension template (protobuf-first with gRPC Gateway)
- **Base Path**: `/v1`

### Protobuf-First Architecture

The extend-service-extension-go template uses a **protobuf-first approach**:

1. **Define Services in .proto**: Write gRPC service definitions with HTTP annotations
2. **Generate Code**: Run `proto.sh` to generate Go gRPC handlers and HTTP Gateway
3. **Implement Handlers**: Implement the generated gRPC service interface
4. **Automatic HTTP Translation**: gRPC Gateway auto-translates HTTP/REST → gRPC

**Key Benefits:**
- ✅ Type-safe API definitions
- ✅ No manual HTTP routing/parsing
- ✅ Auto-generated OpenAPI/Swagger docs
- ✅ Built-in JWT auth via permission annotations

### Server Architecture

The template runs **3 servers simultaneously**:

| Port | Protocol | Purpose |
|------|----------|---------|
| 6565 | gRPC | Native gRPC API (internal) |
| 8000 | HTTP | gRPC Gateway (REST API for clients) |
| 8080 | HTTP | Prometheus metrics endpoint |

**Client Access:** Use HTTP on port 8000 for REST API calls (gRPC Gateway translates to gRPC internally)

### Design Principles
- **User-scoped**: All operations scoped to authenticated user (extracted from JWT)
- **Read-heavy**: Most requests are GET (list challenges)
- **Idempotent claims**: Claiming already-claimed reward returns 400 (not 500)
- **No pagination**: M1 assumes reasonable number of challenges (<100 goals per user)
- **Flexible selection (M4)**: Three patterns for goal activation:
  - Individual manual (M3): PUT /goals/{goal_id}/active
  - Batch manual (M4): POST /goals/batch-select
  - Random selection (M4): POST /goals/random-select

---

## Client Integration Requirements

> **IMPORTANT**: Game clients MUST follow these integration requirements for the Challenge Service to function correctly.

### Required: Call `/initialize` on Every Game Session Start

```http
POST /v1/challenges/initialize
Authorization: Bearer <JWT>
```

**When to call:**
- ✅ **Every time the game client starts** (not just first login)
- ✅ **After user authentication completes** (JWT must be valid)
- ✅ **Before displaying challenges UI** (ensures data is ready)

**Why this is required:**

| Purpose | Description |
|---------|-------------|
| **New player setup** | Creates goal progress rows for players who never played before |
| **Config sync** | Assigns new goals added to config since last login |
| **Rotation sync** | Updates baselines for daily/weekly goals (M5) |
| **Stat baseline capture** | Records current stat values for relative progress tracking (M5) |

**Performance characteristics:**
- First call (new player): ~10-20ms (creates rows, fetches stats)
- Subsequent calls (returning player): ~1-2ms (fast SELECT, no writes if nothing changed)

**What happens if you DON'T call `/initialize`:**
- ❌ New players won't have any goals assigned
- ❌ Players won't receive newly added goals from config updates
- ❌ Daily/weekly goals won't reset properly (M5)
- ❌ Relative progress tracking won't work correctly (M5)

### Recommended: Client Integration Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Game Client Startup                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. User launches game                                       │
│           │                                                  │
│           ▼                                                  │
│  2. Authenticate with AGS IAM → Get JWT                      │
│           │                                                  │
│           ▼                                                  │
│  3. POST /v1/challenges/initialize  ← REQUIRED               │
│           │                                                  │
│           ▼                                                  │
│  4. GET /v1/challenges → Display challenges UI               │
│           │                                                  │
│           ▼                                                  │
│  5. User plays game → Events update progress automatically   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Example Integration Code

```typescript
// Game client startup
async function onGameStart() {
  // 1. Authenticate
  const jwt = await agsIAM.login(username, password);

  // 2. Initialize challenges (REQUIRED - do this every session!)
  await challengeService.initialize(jwt);

  // 3. Fetch and display challenges
  const challenges = await challengeService.getChallenges(jwt);
  displayChallengesUI(challenges);
}

// Call on every game session start
onGameStart();
```

### Do NOT:
- ❌ Cache the initialize response and skip calling it
- ❌ Only call initialize for new players
- ❌ Call initialize only when displaying challenges UI
- ❌ Assume challenges will work without calling initialize

---

## Authentication

> **📖 Detailed Implementation Guide**: See [JWT_AUTHENTICATION.md](./JWT_AUTHENTICATION.md) for complete JWT authentication architecture, interceptor design, context-based user extraction, and testing patterns.

### JWT Bearer Token

All endpoints require AccelByte IAM Bearer token in Authorization header.

```http
Authorization: Bearer <JWT_TOKEN>
```

### JWT Claims

The JWT token contains claims that must be validated and extracted:

```json
{
  "user_id": "abc123",
  "namespace": "mygame",
  "permissions": ["NAMESPACE:{namespace}:USER"],
  "exp": 1697123456,
  "iat": 1697120000
}
```

### Validation Steps

1. **Signature Verification**: Validate JWT signature against AGS IAM public key
2. **Expiration Check**: Ensure `exp` is in the future
3. **Namespace Match**: Verify `namespace` matches deployment namespace
4. **User ID Extraction**: Extract `user_id` for database queries

### Implementation

The Challenge Service uses a **centralized auth interceptor approach** where JWT validation and claim extraction happen in the gRPC interceptor, not in individual handlers. See [JWT_AUTHENTICATION.md](./JWT_AUTHENTICATION.md) for the complete implementation.

**Key Points:**
- Auth interceptor validates JWT signature and permissions
- User ID and namespace are extracted and stored in context
- Service handlers retrieve user ID from context using `common.GetUserIDFromContext(ctx)`
- No JWT decoding in service handlers (DRY principle)

**Example Handler:**
```go
import "extend-challenge-service/pkg/common"

func (s *ChallengeServiceServer) GetUserChallenges(ctx context.Context, req *pb.Request) (*pb.Response, error) {
    // Extract authenticated user ID from context (populated by auth interceptor)
    userID, err := common.GetUserIDFromContext(ctx)
    if err != nil {
        return nil, err
    }

    // Use userID for database queries
    challenges, err := s.service.GetChallenges(ctx, userID, s.namespace)
    ...
}
```

**See Also:**
- [JWT_AUTHENTICATION.md](./JWT_AUTHENTICATION.md) - Complete authentication flow and architecture
- `pkg/common/authServerInterceptor.go` - Auth interceptor implementation
- `pkg/server/challenge_service_server.go` - Service handler examples

### Error Responses

**401 Unauthorized:**
- Missing Authorization header
- Invalid JWT signature
- Expired token
- Malformed token

**403 Forbidden:**
- Namespace mismatch
- Missing required permissions

---

## Endpoints

### 1. Get User Challenges

Retrieve all challenges for the authenticated user with current progress.

```http
GET /v1/challenges?active_only=true
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
```

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `active_only` | boolean | `false` | Only show assigned goals (`isActive = true`) |

**Behavior:**
- `active_only=false` (default): Show all goals from config with user's progress (if any)
- `active_only=true`: Only show goals where user has `isActive = true` in database

#### Response 200 OK

```json
{
  "challenges": [
    {
      "challengeId": "winter-challenge-2025",
      "name": "Winter Challenge",
      "description": "Complete winter-themed goals",
      "goals": [
        {
          "goalId": "kill-10-snowmen",
          "name": "Snowman Slayer",
          "description": "Defeat 10 snowmen",
          "requirement": {
            "statCode": "snowman_kills",
            "operator": ">=",
            "targetValue": 10
          },
          "reward": {
            "type": "ITEM",
            "rewardId": "winter_sword",
            "quantity": 1
          },
          "prerequisites": [],
          "progress": 7,
          "status": "in_progress",
          "locked": false,
          "completedAt": null,
          "claimedAt": null
        },
        {
          "goalId": "reach-level-5",
          "name": "Level Up",
          "description": "Reach character level 5",
          "requirement": {
            "statCode": "player_level",
            "operator": ">=",
            "targetValue": 5
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GOLD",
            "quantity": 100
          },
          "prerequisites": ["kill-10-snowmen"],
          "progress": 0,
          "status": "not_started",
          "locked": true,
          "completedAt": null,
          "claimedAt": null
        }
      ]
    }
  ]
}
```

#### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `challengeId` | string | Unique challenge identifier |
| `name` | string | Display name of challenge |
| `description` | string | User-facing challenge description |
| `goals` | array | List of goals in this challenge |
| `goalId` | string | Unique goal identifier |
| `requirement.statCode` | string | Event field to track |
| `requirement.operator` | string | Always `">="` in M1 |
| `requirement.targetValue` | int | Goal threshold |
| `reward.type` | string | `"ITEM"` or `"WALLET"` |
| `reward.rewardId` | string | Item code or currency code |
| `reward.quantity` | int | Amount to grant |
| `prerequisites` | array | Goal IDs that must be completed first |
| `progress` | int | Current progress (may exceed target_value) |
| `status` | string | `not_started`, `in_progress`, `completed`, `claimed` |
| `locked` | bool | `true` if prerequisites not completed |
| `completedAt` | string/null | ISO 8601 timestamp when completed |
| `claimedAt` | string/null | ISO 8601 timestamp when claimed |

#### Response Notes

- **Orphaned goals**: Goals removed from config are excluded from response
- **Always latest config**: If target_value changes in config, API shows progress against new target
- **Locked goals**: `locked: true` if any prerequisite not in `completed` or `claimed` status
- **No pagination**: Returns all challenges (assumes <100 goals per user)

#### Response 401 Unauthorized

```json
{
  "errorCode": "UNAUTHORIZED",
  "message": "Invalid or expired token"
}
```

#### Response 500 Internal Server Error

```json
{
  "errorCode": "INTERNAL_ERROR",
  "message": "Failed to retrieve challenges"
}
```

---

### 2. Claim Goal Reward

Claim reward for a completed goal.

```http
POST /v1/challenges/{challenge_id}/goals/{goal_id}/claim
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
```

**Path Parameters:**
- `challenge_id`: Challenge identifier (e.g., `winter-challenge-2025`)
- `goal_id`: Goal identifier (e.g., `kill-10-snowmen`)

**Body:** None (empty POST)

#### Response 200 OK

```json
{
  "goalId": "kill-10-snowmen",
  "status": "claimed",
  "reward": {
    "type": "ITEM",
    "rewardId": "winter_sword",
    "quantity": 1
  },
  "claimedAt": "2025-10-15T10:30:00Z"
}
```

#### Response 400 Bad Request

**Scenario 1: Goal Not Completed**
```json
{
  "errorCode": "GOAL_NOT_COMPLETED",
  "message": "Goal not completed. Please wait 1 second and try again."
}
```

**Note:** This error may occur due to eventual consistency (buffered event processing). The progress may be updating but not yet visible in the database. Client should retry after 1 second.

**Note for Daily Goals:** For daily-type goals, this error is also returned when:
- `completed_at` is NULL (user hasn't completed goal today)
- `completed_at` date doesn't match today (e.g., user completed yesterday but didn't claim)
  - Example: User completed daily login on 2025-10-17, tries to claim on 2025-10-18 → `GOAL_NOT_COMPLETED`
  - Daily goals must be claimed same day they're completed (repeatable daily)

**Scenario 2: Already Claimed**
```json
{
  "errorCode": "ALREADY_CLAIMED",
  "message": "Reward has already been claimed"
}
```

**Scenario 3: Prerequisites Not Met**
```json
{
  "errorCode": "GOAL_LOCKED",
  "message": "Prerequisites not completed"
}
```

#### Response 404 Not Found

```json
{
  "errorCode": "GOAL_NOT_FOUND",
  "message": "Goal not found or removed from config"
}
```

**Reasons:**
- Goal ID does not exist in config
- Goal was removed from config (orphaned DB row)
- Challenge ID does not match goal's parent challenge

#### Response 502 Bad Gateway

```json
{
  "errorCode": "REWARD_GRANT_FAILED",
  "message": "Failed to grant reward via Platform Service after 3 retries"
}
```

**Reasons:**
- AGS Platform Service unavailable
- Invalid reward configuration (item/currency not found)
- Network timeout

---

### 3. Initialize Player Goals (M3)

Assign default goals to new players or sync existing players with config changes.

```http
POST /v1/challenges/initialize
Authorization: Bearer <JWT>
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
```

**Body:** Empty (user ID and namespace extracted from JWT)

#### Response 200 OK

```json
{
  "assignedGoals": [
    {
      "challengeId": "combat-master",
      "goalId": "defeat-10-enemies",
      "name": "Defeat 10 Enemies",
      "description": "Defeat 10 enemies in combat",
      "isActive": true,
      "assignedAt": "2025-11-04T12:00:00Z",
      "expiresAt": null,
      "progress": 0,
      "target": 10,
      "status": "not_started",
      "requirement": {
        "statCode": "enemy_defeats",
        "operator": ">=",
        "targetValue": 10
      },
      "reward": {
        "type": "ITEM",
        "rewardId": "combat_badge",
        "quantity": 1
      }
    }
  ],
  "newAssignments": 1,
  "totalActive": 1
}
```

#### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `assignedGoals` | array | List of assigned goals with current progress |
| `newAssignments` | int | Number of new goals assigned in this call |
| `totalActive` | int | Total number of active goals for this user |

**When to Call:**
- ✅ On player first login (new player onboarding)
- ✅ On every subsequent login (config sync)
- ✅ Idempotent: Only creates missing goals, skips existing

**Performance:**
- First login: ~10ms (creates 5-10 rows)
- Subsequent logins: ~1-2ms (just SELECT, usually 0 INSERTs)

#### Response 401 Unauthorized

```json
{
  "error": "unauthorized",
  "message": "Invalid or expired token"
}
```

#### Response 500 Internal Server Error

```json
{
  "error": "internal_error",
  "message": "Failed to initialize goals"
}
```

---

### 4. Set Goal Active/Inactive (M3)

Allow players to manually control goal assignment.

```http
PUT /v1/challenges/{challenge_id}/goals/{goal_id}/active
Authorization: Bearer <JWT>
Content-Type: application/json
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
Content-Type: application/json
```

**Path Parameters:**
- `challenge_id`: Challenge identifier (e.g., `combat-master`)
- `goal_id`: Goal identifier (e.g., `defeat-10-enemies`)

**Body:**
```json
{
  "isActive": true
}
```

#### Response 200 OK

```json
{
  "challengeId": "combat-master",
  "goalId": "defeat-10-enemies",
  "isActive": true,
  "assignedAt": "2025-11-04T12:05:00Z",
  "message": "Goal activated successfully"
}
```

**Behavior:**
- `isActive = true`: Creates row if doesn't exist (assigns goal), updates `assignedAt`
- `isActive = false`: Sets `isActive = false` (deactivates goal)
- Setting `isActive = false` stops event processing for that goal
- Only affects the authenticated user's goals

#### Response 404 Not Found

```json
{
  "error": "not_found",
  "message": "Goal 'invalid-goal' not found in challenge 'combat-master'"
}
```

#### Response 400 Bad Request

```json
{
  "error": "bad_request",
  "message": "Field 'isActive' is required"
}
```

---

### 5. Health Check (FQ5)

Liveness probe for Kubernetes with database connectivity verification.

```http
GET /healthz
```

#### Response 200 OK

```json
{
  "status": "healthy"
}
```

**No authentication required.**

#### Response 503 Service Unavailable

```json
{
  "errorCode": "DATABASE_UNHEALTHY",
  "message": "Database connectivity check failed"
}
```

**Database Health Check:**
- Executes `db.PingContext()` with 2-second timeout
- Returns 503 if database is unreachable
- Used by Kubernetes liveness probe

#### gRPC Health Check Protocol (FQ5)

The service also implements standard gRPC health check protocol for gRPC clients:

```protobuf
// Standard gRPC health check (optional)
import "grpc.health.v1.health.proto";

service Health {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
}
```

**Registration in main.go:**
```go
import "google.golang.org/grpc/health/grpc_health_v1"
import "google.golang.org/grpc/health"

// Register standard gRPC health check
grpc_health_v1.RegisterHealthServer(grpcServer, health.NewServer())
```

**Both protocols supported:**
- **HTTP `/healthz`**: For Kubernetes liveness probe and HTTP clients
- **gRPC Health Check**: For gRPC clients and service mesh integration

---

### 6. Batch Manual Selection (M4)

Activate multiple goals at once via explicit selection.

```http
POST /v1/challenges/{challenge_id}/goals/batch-select
Authorization: Bearer <JWT>
Content-Type: application/json
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
Content-Type: application/json
```

**Path Parameters:**
- `challenge_id`: Challenge identifier (e.g., `daily-challenges`)

**Body:**
```json
{
  "goal_ids": [
    "daily-login",
    "daily-10-kills",
    "daily-3-matches"
  ],
  "replace_existing": false
}
```

**Request Fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `goal_ids` | array | Yes | - | List of goal IDs to activate |
| `replace_existing` | boolean | No | `false` | Deactivate existing active goals first |

#### Response 200 OK

```json
{
  "selected_goals": [
    {
      "goal_id": "daily-login",
      "name": "Daily Login",
      "status": "activated",
      "progress": 0,
      "target": 1,
      "is_active": true
    },
    {
      "goal_id": "daily-10-kills",
      "name": "Get 10 Kills",
      "status": "activated",
      "progress": 0,
      "target": 10,
      "is_active": true
    },
    {
      "goal_id": "daily-3-matches",
      "name": "Play 3 Matches",
      "status": "activated",
      "progress": 0,
      "target": 3,
      "is_active": true
    }
  ],
  "challenge_id": "daily-challenges",
  "total_active_goals": 3,
  "replaced_goals": []
}
```

**Behavior:**
- `replace_existing: true` → Deactivate all active goals in challenge, then activate specified goals
- `replace_existing: false` → Keep existing active goals, add new activations (subject to max limit)
- Atomic operation: All goals activated or none (transaction rollback on error)
- Deactivated goals keep their progress (not reset to 0)

#### Response 400 Bad Request

**Scenario: Invalid Goal IDs**
```json
{
  "errorCode": "INVALID_REQUEST",
  "message": "Invalid goal IDs: goal-xyz does not exist in challenge daily-challenges"
}
```

**Scenario: Empty Goal List**
```json
{
  "errorCode": "INVALID_REQUEST",
  "message": "goal_ids cannot be empty"
}
```

#### Response 404 Not Found

```json
{
  "errorCode": "CHALLENGE_NOT_FOUND",
  "message": "Challenge 'invalid-id' not found"
}
```

---

### 7. Random Goal Selection (M4)

System randomly selects and activates N goals from a challenge.

```http
POST /v1/challenges/{challenge_id}/goals/random-select
Authorization: Bearer <JWT>
Content-Type: application/json
```

#### Request

**Headers:**
```
Authorization: Bearer <JWT>
Content-Type: application/json
```

**Path Parameters:**
- `challenge_id`: Challenge identifier (e.g., `daily-challenges`)

**Body:**
```json
{
  "count": 3,
  "replace_existing": false,
  "exclude_active": true
}
```

**Request Fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `count` | int | Yes | - | Number of goals to randomly select |
| `replace_existing` | boolean | No | `false` | Deactivate existing active goals first |
| `exclude_active` | boolean | No | `false` | Exclude already-active goals from selection pool |

#### Response 200 OK

```json
{
  "selected_goals": [
    {
      "goal_id": "daily-login",
      "name": "Daily Login",
      "description": "Login to the game",
      "requirement": {
        "stat_code": "login_count",
        "target_value": 1
      },
      "reward": {
        "type": "WALLET",
        "reward_id": "GEMS",
        "quantity": 50
      },
      "status": "activated",
      "progress": 0,
      "is_active": true
    },
    {
      "goal_id": "daily-10-kills",
      "name": "Get 10 Kills",
      "requirement": {
        "stat_code": "enemy_kills",
        "target_value": 10
      },
      "reward": {
        "type": "ITEM",
        "reward_id": "bronze_sword",
        "quantity": 1
      },
      "status": "activated",
      "progress": 0,
      "is_active": true
    }
  ],
  "challenge_id": "daily-challenges",
  "total_active_goals": 2,
  "replaced_goals": []
}
```

**Smart Filtering (Auto-Applied):**
- ✅ Excludes goals with `status = 'claimed'` (already got reward)
- ✅ Excludes goals with `status = 'completed'` (completed but not claimed yet)
- ✅ Excludes goals with unmet prerequisites
- ✅ Optionally excludes already-active goals (if `exclude_active: true`)

**Partial Results:**
- If fewer goals are available than requested (but > 0), API returns all available goals
- Example: Request 5 goals, only 3 available → returns 3 goals
- Only returns error if 0 goals available after filtering

#### Response 400 Bad Request

**Scenario: Invalid Count**
```json
{
  "errorCode": "INVALID_COUNT",
  "message": "Count must be > 0",
  "requested_count": 0
}
```

**Scenario: No Goals Available**
```json
{
  "errorCode": "INSUFFICIENT_GOALS",
  "message": "No goals available for selection",
  "available_count": 0,
  "requested_count": 3,
  "suggestion": "Complete or claim existing goals, or adjust filters"
}
```

**Note:** This error only occurs when 0 goals are available. If 1-2 goals are available when 3 are requested, the API returns those 1-2 goals as a partial result (200 OK).

#### Response 404 Not Found

```json
{
  "errorCode": "CHALLENGE_NOT_FOUND",
  "message": "Challenge 'invalid-id' not found",
  "challenge_id": "invalid-id"
}
```

---

## Error Handling

### Error Response Format

All error responses follow this structure:

```json
{
  "errorCode": "ERROR_CODE_CONSTANT",
  "message": "Human-readable error message"
}
```

### Error Codes

Defined in `extend-challenge-common/pkg/errors/codes.go`:

```go
const (
    // Authentication errors (401)
    ErrCodeUnauthorized = "UNAUTHORIZED"

    // Authorization errors (403)
    ErrCodeForbidden = "FORBIDDEN"

    // Validation errors (400)
    ErrCodeInvalidRequest = "INVALID_REQUEST"
    ErrCodeGoalNotCompleted = "GOAL_NOT_COMPLETED"
    ErrCodeAlreadyClaimed = "ALREADY_CLAIMED"
    ErrCodeGoalLocked = "GOAL_LOCKED"
    ErrCodeInvalidCount = "INVALID_COUNT"           // M4: Count must be > 0
    ErrCodeInsufficientGoals = "INSUFFICIENT_GOALS" // M4: No goals available for random selection

    // Not found errors (404)
    ErrCodeGoalNotFound = "GOAL_NOT_FOUND"
    ErrCodeChallengeNotFound = "CHALLENGE_NOT_FOUND"

    // External service errors (502)
    ErrCodeRewardGrantFailed = "REWARD_GRANT_FAILED"

    // Internal errors (500)
    ErrCodeDatabaseError = "DATABASE_ERROR"
    ErrCodeInternalError = "INTERNAL_ERROR"
)
```

### HTTP Status Code Mapping

| HTTP Status | Error Code | Scenario |
|-------------|-----------|----------|
| 400 | `INVALID_REQUEST` | Malformed request body/params |
| 400 | `GOAL_NOT_COMPLETED` | Trying to claim incomplete goal |
| 400 | `ALREADY_CLAIMED` | Trying to claim already-claimed goal |
| 400 | `GOAL_LOCKED` | Prerequisites not met |
| 400 | `INVALID_COUNT` | M4: Count must be > 0 for random selection |
| 400 | `INSUFFICIENT_GOALS` | M4: No goals available for random selection |
| 401 | `UNAUTHORIZED` | Invalid/expired JWT |
| 403 | `FORBIDDEN` | Namespace mismatch |
| 404 | `GOAL_NOT_FOUND` | Goal doesn't exist in config |
| 404 | `CHALLENGE_NOT_FOUND` | Challenge doesn't exist in config |
| 500 | `DATABASE_ERROR` | Database query failure |
| 500 | `INTERNAL_ERROR` | Unexpected panic/error |
| 502 | `REWARD_GRANT_FAILED` | AGS Platform Service failure |

### Error Handler

```go
func writeError(w http.ResponseWriter, statusCode int, errorCode, message string) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)

    errorResp := ErrorResponse{
        ErrorCode: errorCode,
        Message:   message,
    }

    json.NewEncoder(w).Encode(errorResp)
}
```

---

## Phase 6 Implementation Decisions

### Service Structure (Decision Q1, Q5)
- **Protobuf Service:** Rename template's `Service` to `ChallengeService`, replace methods (Option C)
- **Service Layer:** Single `challenge_service.go` with extracted helpers in `claim_flow.go` and `progress_query.go` (Option C)
- **Package:** `extend-challenge-service/pkg/service/`

### Claim Flow & Transaction Management (Decision Q3, Q4)
- **Transaction Scope:** AGS Platform call INSIDE transaction for M1 simplicity
- **Transaction Timeout:** 10 seconds (context.WithTimeout)
- **AGS Retry Limit:** Configure retries to complete within 10s total
- **Force Flush Strategy:** Accept eventual consistency (Option D)
  - No inter-service communication between REST API and Event Handler
  - If goal shows as incomplete, return `400 GOAL_NOT_COMPLETED` with message: "Goal not completed. Please wait 1 second and try again."
  - Client handles retry logic

### Mapper Architecture (Decision Q2)
- **Location:** `extend-challenge-service/pkg/mapper/` package (Option A)
- **Pattern:** Pure functions (no struct/dependency injection)
- **Validation:** Validate proto models during mapping, fail early with error return
- **Error Handling:** Return errors (not panic) for nil pointers, invalid enums
- **Files:**
  - `challenge_mapper.go` - Challenge and goal mapping
  - `progress_mapper.go` - Progress field computation
  - `error_mapper.go` - Domain errors → gRPC status codes

### Error Handling (Decision Q6)
- **Domain Errors:** Custom error types with structured data
  ```go
  type GoalNotFoundError struct {
      GoalID      string
      ChallengeID string
  }
  ```
- **Mapping Location:** Handler layer (`pkg/handler/error_mapper.go`)
- **gRPC Status Details:** Include for NotFound/validation errors, exclude for security-sensitive errors

### Prerequisite Checking (Decision Q7, FQ4)
- **Implementation:** Separate `PrerequisiteChecker` in `pkg/service/prerequisite_checker.go`
- **Per-Request Optimization (FQ4):** Build simple map from `userProgress` array for O(1) prerequisite lookups within single request
  - Not a persistent cache - just function-scoped map for efficient lookups
  - For 50 goals with 2 prerequisites each: 100 map lookups vs 2,500 linear search comparisons
  - Scope: Created and discarded within `GetUserChallenges()` call, not shared across requests
- **Validation:** Config validation catches circular dependencies at startup
- **Claim Flow:** Trust `locked` flag from prerequisite checker (no re-check during claim)

### Daily Goal Progress Handling (Decision Q9, FQ2)
- **Strategy:** Use DB data as-is, no mutation in service layer
- **Computation (FQ2):** Mapper layer computes progress field from `completed_at` timestamp for daily goals
  - "No mutation" means: Don't modify domain.UserGoalProgress struct in service layer
  - "Computation allowed" means: Mapper can derive `progress` value (0 or 1) for proto response based on date check
  - Example: If `completed_at = 2025-10-18` and today is 2025-10-18, mapper returns `progress = 1`
- **Timezone:** Always UTC (`time.Now().UTC()`)
- **Data Trust:** Trust DB data (no defensive checks for inconsistency)
- **Status:** Do not modify status field based on date (show DB value from database)

### Reward Client Testing (Decision Q8)
- **Unit Tests:** Mock RewardClient using testify/mock
- **Retry Testing:** Mock controls response sequence (error, error, success)
- **Logging:** Log all grant attempts with proper log levels (Info for success, Warn for retry, Error for failure)
- **No Environment Switching:** Always use mock in tests (no fake server or real AGS mode switching)

### Database Connection Management (Decision Q10)
- **Shared Package:** Create `extend-challenge-common/pkg/db/postgres.go` for initialization
- **Connection Pool:** Same settings as event handler (MaxOpenConns: 25, MaxIdleConns: 5)
- **Health Check:** `/healthz` verifies DB connectivity, returns 503 if DB down
- **Transaction Management:** Repository provides transaction functions, service layer orchestrates transaction + AGS calls

### OpenAPI Documentation (Decision Q11)
- **Title:** "AccelByte Challenge Service API"
- **Base Path:** `/v1` (matches route prefix)
- **Descriptions:** Add detailed descriptions to proto messages
- **Generation:** Ensure `proto.sh` generates OpenAPI spec from `service.proto`

### Follow-up Clarifications (FQ1-FQ5)

**FQ1: AGS Retry Timing** → Reduced base delay to 500ms for faster retries
- 3 retries with 500ms base: ~3.5s delays + 4-8s AGS calls = 7.5-11.5s total (fits in 10s timeout)

**FQ2: Daily Progress Computation** → Computation allowed in mapper layer
- "No mutation" = Don't modify domain.UserGoalProgress struct
- "Computation" = Mapper derives `progress` value from `completed_at` timestamp

**FQ3: Progress Service Structure** → Separate file `progress_query.go` with helper functions
- Not a separate service class, just helpers used by ChallengeService

**FQ4: Prerequisite Cache Scope** → Simple function-scoped map for O(1) lookups
- Not a persistent cache - just build map from userProgress array within request
- Optimize 100 lookups vs 2,500 linear search comparisons

**FQ5: Health Check Protocol** → Implement both HTTP `/healthz` and gRPC health
- HTTP endpoint verifies DB connectivity, returns 503 if unhealthy
- gRPC health check for service mesh integration

---

## Protobuf Service Definition

### Define Service in .proto File

**Path:** `extend-challenge-service/pkg/proto/service.proto` (rename from template)

**Note:** Rename template's `Service` to `ChallengeService`, replace Guild Progress methods with Challenge methods.

```protobuf
syntax = "proto3";

option csharp_namespace = "AccelByte.Extend.ChallengeService";
option go_package = "accelbyte.net/extend/challengeservice";
option java_package = "net.accelbyte.extend.challengeservice";
option java_multiple_files = true;

package service;

import "google/api/annotations.proto";
import "protoc-gen-openapiv2/options/annotations.proto";
import "permission.proto";

// Challenge Service - Renamed from template's Service
service Service {
  // Get all challenges with user progress
  rpc GetUserChallenges (GetChallengesRequest) returns (GetChallengesResponse) {
    option (google.api.http) = {
      get: "/v1/challenges"
    };
    option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
      summary: "Get user challenges";
      description: "Retrieve all challenges for the authenticated user with current progress";
      tags: "Challenges";
    };
  }

  // Claim reward for completed goal
  rpc ClaimGoalReward (ClaimRewardRequest) returns (ClaimRewardResponse) {
    option (google.api.http) = {
      post: "/v1/challenges/{challenge_id}/goals/{goal_id}/claim"
      body: "*"
    };
    option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
      summary: "Claim goal reward";
      description: "Claim reward for a completed goal";
      tags: "Challenges";
    };
  }

  // Health check endpoint
  rpc HealthCheck (HealthCheckRequest) returns (HealthCheckResponse) {
    option (google.api.http) = {
      get: "/healthz"
    };
  }

  // Batch manual selection (M4)
  rpc BatchSelectGoals (BatchSelectRequest) returns (BatchSelectResponse) {
    option (google.api.http) = {
      post: "/v1/challenges/{challenge_id}/goals/batch-select"
      body: "*"
    };
    option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
      summary: "Batch select goals";
      description: "Activate multiple goals at once via explicit selection";
      tags: "Challenges";
    };
  }

  // Random goal selection (M4)
  rpc RandomSelectGoals (RandomSelectRequest) returns (RandomSelectResponse) {
    option (google.api.http) = {
      post: "/v1/challenges/{challenge_id}/goals/random-select"
      body: "*"
    };
    option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
      summary: "Random select goals";
      description: "System randomly selects and activates N goals from a challenge";
      tags: "Challenges";
    };
  }
}

// Request/Response Messages
message GetChallengesRequest {
  // User ID extracted from JWT (not from request body)
}

message GetChallengesResponse {
  repeated Challenge challenges = 1;
}

message ClaimRewardRequest {
  string challenge_id = 1;
  string goal_id = 2;
}

message ClaimRewardResponse {
  string goal_id = 1;
  string status = 2;
  Reward reward = 3;
  string claimed_at = 4;
}

message HealthCheckRequest {}

message HealthCheckResponse {
  string status = 1;
}

message BatchSelectRequest {
  string challenge_id = 1;
  repeated string goal_ids = 2;
  bool replace_existing = 3;
}

message BatchSelectResponse {
  repeated SelectedGoal selected_goals = 1;
  string challenge_id = 2;
  int32 total_active_goals = 3;
  repeated string replaced_goals = 4;
}

message RandomSelectRequest {
  string challenge_id = 1;
  int32 count = 2;
  bool replace_existing = 3;
  bool exclude_active = 4;
}

message RandomSelectResponse {
  repeated SelectedGoal selected_goals = 1;
  string challenge_id = 2;
  int32 total_active_goals = 3;
  repeated string replaced_goals = 4;
}

message SelectedGoal {
  string goal_id = 1;
  string name = 2;
  string description = 3;
  Requirement requirement = 4;
  Reward reward = 5;
  string status = 6;
  int32 progress = 7;
  int32 target = 8;
  bool is_active = 9;
}

// Domain Models
message Challenge {
  string challenge_id = 1;
  string name = 2;
  string description = 3;
  repeated Goal goals = 4;
}

message Goal {
  string goal_id = 1;
  string name = 2;
  string description = 3;
  Requirement requirement = 4;
  Reward reward = 5;
  repeated string prerequisites = 6;
  int32 progress = 7;
  string status = 8;
  bool locked = 9;
  string completed_at = 10;
  string claimed_at = 11;
}

message Requirement {
  string stat_code = 1;
  string operator = 2;
  int32 target_value = 3;
}

message Reward {
  string type = 1;
  string reward_id = 2;
  int32 quantity = 3;
}

// OpenAPI options for the entire API (Decision Q11)
option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_swagger) = {
  info: {
    title: "AccelByte Challenge Service API";
    version: "1.0";
    description: "Challenge service for managing user challenge progress and reward claims";
  };
  base_path: "/v1";

  security_definitions: {
    security: {
      key: "Bearer";
      value: {
        type: TYPE_API_KEY;
        in: IN_HEADER;
        name: "Authorization";
      }
    }
  };
};
```

### Code Generation

Run the template's code generation script:

```bash
# Generate gRPC and HTTP Gateway code
cd extend-challenge-service
./proto.sh

# This generates (from pkg/proto/service.proto):
# - pkg/pb/service.pb.go            (gRPC service interface)
# - pkg/pb/service.pb.gw.go         (HTTP Gateway handlers)
# - gateway/apidocs/swagger.json    (OpenAPI spec)
```

### Implement gRPC Service Handler

**Path:** `extend-challenge-service/internal/handler/challenge_handler.go`

```go
package handler

import (
    "context"
    pb "extend-challenge-service/pkg/pb"
    "extend-challenge-service/internal/service"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

// ChallengeServiceServer implements the generated gRPC service interface
type ChallengeServiceServer struct {
    pb.UnimplementedChallengeServiceServer
    service *service.ChallengeService
}

func NewChallengeServiceServer(svc *service.ChallengeService) *ChallengeServiceServer {
    return &ChallengeServiceServer{
        service: svc,
    }
}

// GetUserChallenges implements the gRPC handler
func (s *ChallengeServiceServer) GetUserChallenges(
    ctx context.Context,
    req *pb.GetChallengesRequest,
) (*pb.GetChallengesResponse, error) {
    // Extract user ID from JWT claims in context (added by auth interceptor)
    userID := getUserIDFromContext(ctx)
    if userID == "" {
        return nil, status.Error(codes.Unauthenticated, "user ID not found in token")
    }

    // Call business logic
    challenges, err := s.service.GetUserChallenges(ctx, userID)
    if err != nil {
        return nil, status.Error(codes.Internal, "failed to retrieve challenges")
    }

    // Convert domain models to protobuf (TODO: implement mapper)
    pbChallenges := mapChallengesToProto(challenges)

    return &pb.GetChallengesResponse{
        Challenges: pbChallenges,
    }, nil
}

// ClaimGoalReward implements the gRPC handler
func (s *ChallengeServiceServer) ClaimGoalReward(
    ctx context.Context,
    req *pb.ClaimRewardRequest,
) (*pb.ClaimRewardResponse, error) {
    // Extract user ID from JWT
    userID := getUserIDFromContext(ctx)
    if userID == "" {
        return nil, status.Error(codes.Unauthenticated, "user ID not found in token")
    }

    // Call business logic
    claimResult, err := s.service.ClaimReward(ctx, userID, req.ChallengeId, req.GoalId)
    if err != nil {
        // Map business errors to gRPC status codes
        return nil, mapErrorToGRPCStatus(err)
    }

    // Convert to protobuf
    return &pb.ClaimRewardResponse{
        GoalId:    claimResult.GoalID,
        Status:    claimResult.Status,
        Reward:    mapRewardToProto(claimResult.Reward),
        ClaimedAt: claimResult.ClaimedAt.Format(time.RFC3339),
    }, nil
}

// HealthCheck implements the health check endpoint (FQ5)
func (s *ChallengeServiceServer) HealthCheck(
    ctx context.Context,
    req *pb.HealthCheckRequest,
) (*pb.HealthCheckResponse, error) {
    // Verify database connectivity (Decision Q10c, FQ5)
    if err := s.dbHealthCheck(); err != nil {
        return nil, status.Error(codes.Unavailable, "database unhealthy")
    }

    return &pb.HealthCheckResponse{
        Status: "healthy",
    }, nil
}

// dbHealthCheck verifies database connectivity with 2-second timeout
func (s *ChallengeServiceServer) dbHealthCheck() error {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()

    if err := s.db.PingContext(ctx); err != nil {
        return fmt.Errorf("database ping failed: %w", err)
    }

    return nil
}
```

### Register Service in main.go

**Path:** `extend-challenge-service/cmd/main.go`

```go
// Create gRPC server
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(authInterceptor), // JWT auth
)

// Register Challenge Service
challengeHandler := handler.NewChallengeServiceServer(challengeService)
pb.RegisterChallengeServiceServer(grpcServer, challengeHandler)

// Start gRPC server (port 6565)
go func() {
    lis, _ := net.Listen("tcp", ":6565")
    grpcServer.Serve(lis)
}()

// Start HTTP Gateway (port 8000) - auto-generated by template
// Gateway translates HTTP requests to gRPC calls
go func() {
    mux := runtime.NewServeMux()
    pb.RegisterChallengeServiceHandlerServer(ctx, mux, challengeHandler)
    http.ListenAndServe(":8000", mux)
}()

// Start Metrics server (port 8080)
go func() {
    http.Handle("/metrics", promhttp.Handler())
    http.ListenAndServe(":8080", nil)
}()
```

### Key Implementation Notes

**JWT Authentication:**
- Template provides JWT auth interceptor (requires modifications - see below)
- User ID extracted from JWT claims via `common.GetUserIDFromContext(ctx)`
- Never trust user ID from request body - always extract from validated JWT

**Required Template Modifications for JWT Context:**

Based on Phase 1.5 analysis, the template's `pkg/common/authServerInterceptor.go` needs modifications to inject JWT claims into context. Here are the necessary changes:

#### 1. Change Validator Type (authServerInterceptor.go)

**File:** `pkg/common/authServerInterceptor.go`

**Change:**
```go
// BEFORE (line 33)
var (
    Validator validator.AuthTokenValidator
)

// AFTER
var (
    Validator *iam.TokenValidator  // Changed from interface to concrete type
)
```

**Rationale:** Need to access `JwtClaims` field after validation, which is only available on concrete type.

#### 2. Inject Claims into Context (authServerInterceptor.go)

**File:** `pkg/common/authServerInterceptor.go`

**Modify `checkAuthorizationMetadata()` function:**
```go
func checkAuthorizationMetadata(ctx context.Context, permission *iam.Permission) (context.Context, error) {
    if Validator == nil {
        return ctx, status.Error(codes.Internal, "authorization token validator is not set")
    }

    meta, found := metadata.FromIncomingContext(ctx)
    if !found {
        return ctx, status.Error(codes.Unauthenticated, "metadata is missing")
    }

    if _, ok := meta["authorization"]; !ok {
        return ctx, status.Error(codes.Unauthenticated, "authorization metadata is missing")
    }

    if len(meta["authorization"]) == 0 {
        return ctx, status.Error(codes.Unauthenticated, "authorization metadata length is 0")
    }

    authorization := meta["authorization"][0]
    token := strings.TrimPrefix(authorization, "Bearer ")
    namespace := getNamespace()

    err := Validator.Validate(token, permission, &namespace, nil)
    if err != nil {
        return ctx, status.Error(codes.PermissionDenied, err.Error())
    }

    // ✨ NEW: Inject claims into context after successful validation
    claims := Validator.JwtClaims
    ctx = context.WithValue(ctx, contextKeyUserID, claims.Subject)
    ctx = context.WithValue(ctx, contextKeyNamespace, claims.Namespace)

    return ctx, nil  // Now returns modified context
}
```

**Also update interceptor functions to use returned context:**
```go
func NewUnaryAuthServerIntercept(...) func(...) (...) {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
        if !skipCheckAuthorizationMetadata(info.FullMethod) {
            permission, err := permissionExtractor.ExtractPermission(info, nil)
            if err != nil {
                return nil, err
            }

            ctx, err = checkAuthorizationMetadata(ctx, permission)  // ✨ Use returned context
            if err != nil {
                return nil, err
            }
        }

        return handler(ctx, req)
    }
}
```

#### 3. Add Context Helper Functions (NEW FILE)

**File:** `pkg/common/context_helpers.go` (create new)

```go
package common

import "context"

type contextKey string

const (
    contextKeyUserID    contextKey = "userId"
    contextKeyNamespace contextKey = "namespace"
)

// GetUserIDFromContext extracts user ID from JWT claims in context
func GetUserIDFromContext(ctx context.Context) string {
    if userID, ok := ctx.Value(contextKeyUserID).(string); ok {
        return userID
    }
    return ""
}

// GetNamespaceFromContext extracts namespace from JWT claims in context
func GetNamespaceFromContext(ctx context.Context) string {
    if namespace, ok := ctx.Value(contextKeyNamespace).(string); ok {
        return namespace
    }
    return ""
}
```

#### 4. Update main.go Validator Initialization

**File:** `cmd/main.go` (or wherever validator is initialized)

**Change:**
```go
// BEFORE
common.Validator = common.NewTokenValidator(authService, refreshInterval, validateLocally)

// AFTER
common.Validator = common.NewTokenValidator(authService, refreshInterval, validateLocally).(*iam.TokenValidator)
```

Or modify `NewTokenValidator` to return concrete type:
```go
func NewTokenValidator(...) *iam.TokenValidator {
    return &iam.TokenValidator{
        // ... existing initialization
    }
}
```

**Permission Annotations (Advanced):**
```protobuf
rpc ClaimGoalReward (ClaimRewardRequest) returns (ClaimRewardResponse) {
  option (permission.action) = UPDATE;
  option (permission.resource) = "NAMESPACE:{namespace}:USER:{userId}:CHALLENGE";
  option (google.api.http) = {
    post: "/v1/challenges/{challenge_id}/goals/{goal_id}/claim"
    body: "*"
  };
}
```

**Error Mapping:**
```go
func mapErrorToGRPCStatus(err error) error {
    switch {
    case errors.Is(err, service.ErrGoalNotFound):
        return status.Error(codes.NotFound, "goal not found")
    case errors.Is(err, service.ErrGoalNotCompleted):
        return status.Error(codes.FailedPrecondition, "goal not completed")
    case errors.Is(err, service.ErrAlreadyClaimed):
        return status.Error(codes.AlreadyExists, "reward already claimed")
    case errors.Is(err, service.ErrRewardGrantFailed):
        return status.Error(codes.Unavailable, "failed to grant reward")
    default:
        return status.Error(codes.Internal, "internal error")
    }
}
```

---

## Request/Response Examples

### Example 1: New User First Request

**Request:**
```http
GET /v1/challenges
Authorization: Bearer eyJhbGc...
```

**Response:** (200 OK)
```json
{
  "challenges": [
    {
      "challengeId": "daily-quests",
      "name": "Daily Quests",
      "description": "Complete daily objectives",
      "goals": [
        {
          "goalId": "daily-login",
          "name": "Daily Login",
          "description": "Log in to the game",
          "requirement": {
            "statCode": "login_count",
            "operator": ">=",
            "targetValue": 1
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GOLD",
            "quantity": 10
          },
          "prerequisites": [],
          "progress": 0,
          "status": "not_started",
          "locked": false,
          "completedAt": null,
          "claimedAt": null
        }
      ]
    }
  ]
}
```

### Example 2: User With Progress

**Request:**
```http
GET /v1/challenges
Authorization: Bearer eyJhbGc...
```

**Response:** (200 OK)
```json
{
  "challenges": [
    {
      "challengeId": "winter-challenge-2025",
      "name": "Winter Challenge",
      "description": "Complete winter-themed goals",
      "goals": [
        {
          "goalId": "kill-10-snowmen",
          "name": "Snowman Slayer",
          "description": "Defeat 10 snowmen",
          "requirement": {
            "statCode": "snowman_kills",
            "operator": ">=",
            "targetValue": 10
          },
          "reward": {
            "type": "ITEM",
            "rewardId": "winter_sword",
            "quantity": 1
          },
          "prerequisites": [],
          "progress": 12,
          "status": "completed",
          "locked": false,
          "completedAt": "2025-10-15T09:15:32Z",
          "claimedAt": null
        }
      ]
    }
  ]
}
```

### Example 3: Claim Reward Success

**Request:**
```http
POST /v1/challenges/winter-challenge-2025/goals/kill-10-snowmen/claim
Authorization: Bearer eyJhbGc...
```

**Response:** (200 OK)
```json
{
  "goalId": "kill-10-snowmen",
  "status": "claimed",
  "reward": {
    "type": "ITEM",
    "rewardId": "winter_sword",
    "quantity": 1
  },
  "claimedAt": "2025-10-15T10:30:00Z"
}
```

### Example 4: Claim Already Claimed Goal

**Request:**
```http
POST /v1/challenges/winter-challenge-2025/goals/kill-10-snowmen/claim
Authorization: Bearer eyJhbGc...
```

**Response:** (400 Bad Request)
```json
{
  "errorCode": "ALREADY_CLAIMED",
  "message": "Reward has already been claimed"
}
```

---

## Reward Client Implementation

### RewardClient Interface

The RewardClient handles granting rewards via AGS Platform Service.

**Path:** `extend-challenge-common/pkg/client/reward_client.go`

```go
type RewardClient interface {
    GrantItemReward(ctx context.Context, userID, itemID string, quantity int) error
    GrantWalletReward(ctx context.Context, userID, currencyCode string, amount int) error
    GrantReward(ctx context.Context, userID string, reward domain.Reward) error
}
```

### NoOpRewardClient for M1 (Phase 6.6)

For M1 development and testing without AGS integration, a no-op implementation is provided.

**Path:** `extend-challenge-service/pkg/client/noop_reward_client.go`

**Purpose:**
- Logs reward grants instead of calling AGS Platform Service
- Allows service to run without AGS credentials during local development
- Used in integration tests for reward claim flow

**Usage:**
```go
rewardClient := client.NewNoOpRewardClient(logger)
err := rewardClient.GrantReward(ctx, namespace, userID, reward)
// Always returns nil (success), logs reward details
```

**Replacement in Phase 7:**
- Replace with real AGS SDK client in `pkg/client/ags_reward_client.go`
- Use Extend SDK MCP Server tools to find AGS Platform Service functions:
  - `mcp__extend-sdk-mcp-server__search_functions` - Search for "grant entitlement" or "credit wallet"
  - `mcp__extend-sdk-mcp-server__get_bulk_functions` - Get function details and examples
- Implement retry logic with exponential backoff
- Handle AGS-specific errors (400/404 non-retryable, 502/503 retryable)

### Retry Strategy (Decision 25, FQ1)

**Configuration:**
```go
const (
    MaxRetries  = 3                           // Configurable via env var REWARD_GRANT_MAX_RETRIES
    BaseDelay   = 500 * time.Millisecond      // Configurable via env var REWARD_GRANT_BASE_DELAY (500ms for faster retries)
    MaxDelay    = 10 * time.Second            // Configurable via env var REWARD_GRANT_MAX_DELAY
    JitterRange = 0.1                         // 10% jitter to prevent thundering herd
)
```

**Retry Timing (with 500ms base delay):**
- Attempt 1: immediate (0ms)
- Attempt 2: ~500ms delay
- Attempt 3: ~1000ms delay
- Attempt 4 (if max retries = 3): ~2000ms delay
- **Total delay**: ~3.5s + AGS call time per attempt (~1-3s each) = 7.5-11.5s total
- **Fits within**: 10-second transaction timeout (acceptable for M1)

**Implementation:**
```go
func (c *RewardClient) GrantReward(ctx context.Context, userID string, reward domain.Reward) error {
    var lastErr error

    for attempt := 1; attempt <= MaxRetries; attempt++ {
        err := c.grantRewardOnce(ctx, userID, reward)
        if err == nil {
            // Success
            c.logger.Info("Reward granted",
                "userId", userID,
                "rewardType", reward.Type,
                "rewardId", reward.RewardID,
                "attempt", attempt,
            )
            return nil
        }

        lastErr = err
        c.logger.Warn("Reward grant failed, will retry",
            "userId", userID,
            "rewardType", reward.Type,
            "rewardId", reward.RewardID,
            "attempt", attempt,
            "maxRetries", MaxRetries,
            "error", err,
        )

        // Don't sleep after last attempt
        if attempt < MaxRetries {
            // Exponential backoff with jitter
            delay := calculateBackoff(attempt, BaseDelay, MaxDelay, JitterRange)
            time.Sleep(delay)
        }
    }

    // All retries exhausted
    c.logger.Error("Reward grant failed after max retries",
        "userId", userID,
        "rewardType", reward.Type,
        "rewardId", reward.RewardID,
        "attempts", MaxRetries,
        "error", lastErr,
    )

    return fmt.Errorf("failed to grant reward after %d attempts: %w", MaxRetries, lastErr)
}

func calculateBackoff(attempt int, baseDelay, maxDelay time.Duration, jitterRange float64) time.Duration {
    // Exponential backoff: baseDelay * 2^(attempt-1)
    // With 500ms base: Attempt 1: 500ms, Attempt 2: 1s, Attempt 3: 2s
    delay := baseDelay * time.Duration(1<<(attempt-1))

    // Cap at maxDelay
    if delay > maxDelay {
        delay = maxDelay
    }

    // Add jitter: ±10% randomness to prevent thundering herd
    jitter := float64(delay) * jitterRange * (2*rand.Float64() - 1)
    delay += time.Duration(jitter)

    return delay
}
```

### AGS Platform Service Integration (Phase 7 Implementation Plan)

**SDK Functions Identified:**
- ITEM Rewards: `GrantUserEntitlementShort@platform` (EntitlementService)
- WALLET Rewards: `CreditUserWalletShort@platform` (WalletService)

**See BRAINSTORM.md Phase 7 section for complete investigation results (NQ1-NQ10)**

#### AGSRewardClient Structure

```go
package client

import (
    "context"
    "fmt"
    "time"

    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/platform"
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/entitlement"
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/wallet"
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclientmodels"
    "github.com/sirupsen/logrus"

    commonClient "extend-challenge-common/pkg/client"
    commonDomain "extend-challenge-common/pkg/domain"
)

type AGSRewardClient struct {
    entitlementService *platform.EntitlementService
    walletService      *platform.WalletService
    logger             *logrus.Logger
}

func NewAGSRewardClient(
    entitlementService *platform.EntitlementService,
    walletService      *platform.WalletService,
    logger             *logrus.Logger,
) commonClient.RewardClient {
    return &AGSRewardClient{
        entitlementService: entitlementService,
        walletService:      walletService,
        logger:             logger,
    }
}
```

#### Grant Item Reward Implementation

```go
func (c *AGSRewardClient) GrantItemReward(ctx context.Context, namespace, userID, itemID string, quantity int) error {
    return c.withRetry(ctx, "grant_item", func() error {
        // Create entitlement grant request
        grant := &platformclientmodels.EntitlementGrant{
            ItemID:        itemID,
            ItemNamespace: namespace, // Same namespace as deployment
            Quantity:      int32(quantity), // NOTE: int32, not int
        }

        params := &entitlement.GrantUserEntitlementParams{
            Namespace: namespace,
            UserID:    userID,
            Body:      []*platformclientmodels.EntitlementGrant{grant}, // NOTE: Array!
        }

        // Call SDK
        response, err := c.entitlementService.GrantUserEntitlementShort(params)
        if err != nil {
            return fmt.Errorf("failed to grant item reward: %w", err)
        }

        // Log response for audit (NQ7: don't validate, just log)
        c.logger.WithFields(logrus.Fields{
            "namespace": namespace,
            "userID":    userID,
            "itemID":    itemID,
            "quantity":  quantity,
            "response":  response, // Log entire response
        }).Info("Item reward granted successfully")

        return nil
    })
}
```

#### Grant Wallet Reward Implementation

```go
func (c *AGSRewardClient) GrantWalletReward(ctx context.Context, namespace, userID, currencyCode string, amount int) error {
    return c.withRetry(ctx, "grant_wallet", func() error {
        // Create credit request
        creditReq := &platformclientmodels.CreditRequest{
            Amount: int64(amount), // NOTE: int64, not int
            // Optional fields can be added here: Reason, Source, Origin, Metadata
        }

        params := &wallet.CreditUserWalletParams{
            Namespace:    namespace,
            UserID:       userID,
            CurrencyCode: currencyCode,
            Body:         creditReq,
        }

        // Call SDK
        response, err := c.walletService.CreditUserWalletShort(params)
        if err != nil {
            return fmt.Errorf("failed to credit wallet: %w", err)
        }

        // Log response for audit (NQ7: don't validate, just log)
        c.logger.WithFields(logrus.Fields{
            "namespace":    namespace,
            "userID":       userID,
            "currencyCode": currencyCode,
            "amount":       amount,
            "response":     response, // Log entire response
        }).Info("Wallet credited successfully")

        return nil
    })
}
```

#### Retry Wrapper Implementation (NQ10)

**Decision NQ8**: Use 10-second total timeout for all retry attempts (Option B)

```go
func (c *AGSRewardClient) withRetry(ctx context.Context, operation string, fn func() error) error {
    maxRetries := 3
    baseDelay := 500 * time.Millisecond
    totalTimeout := 10 * time.Second // NQ8: 10s total timeout for all retries

    // Create context with total timeout to prevent exceeding transaction timeout
    timeoutCtx, cancel := context.WithTimeout(ctx, totalTimeout)
    defer cancel()

    var lastErr error
    for attempt := 1; attempt <= maxRetries+1; attempt++ {
        // Check context cancellation before retry (NQ4: always check ctx.Err())
        if err := timeoutCtx.Err(); err != nil {
            c.logger.WithFields(logrus.Fields{
                "operation": operation,
                "attempt":   attempt,
                "error":     err,
            }).Warn("Context cancelled or timeout exceeded, stopping retries")
            return fmt.Errorf("context cancelled: %w", err)
        }

        // Execute operation with timeout context
        err := fn()
        if err == nil {
            // Success
            if attempt > 1 {
                c.logger.WithFields(logrus.Fields{
                    "operation": operation,
                    "attempt":   attempt,
                }).Info("Reward grant succeeded after retry")
            }
            return nil
        }

        lastErr = err

        // Check if error is retryable (uses commonClient.IsRetryableError)
        if !commonClient.IsRetryableError(err) {
            c.logger.WithFields(logrus.Fields{
                "operation": operation,
                "attempt":   attempt,
                "error":     err,
            }).Error("Non-retryable error, failing immediately")
            return fmt.Errorf("non-retryable error: %w", err)
        }

        // Don't sleep after last attempt
        if attempt <= maxRetries {
            delay := baseDelay * time.Duration(1<<(attempt-1)) // Exponential backoff
            c.logger.WithFields(logrus.Fields{
                "operation": operation,
                "attempt":   attempt,
                "nextDelay": delay,
                "error":     err,
            }).Warn("Reward grant failed, will retry")

            // Use time.After with select to respect context cancellation during sleep
            select {
            case <-time.After(delay):
                // Continue to next retry
            case <-timeoutCtx.Done():
                c.logger.WithFields(logrus.Fields{
                    "operation": operation,
                    "attempt":   attempt,
                }).Warn("Timeout during backoff delay")
                return fmt.Errorf("timeout during retry backoff: %w", timeoutCtx.Err())
            }
        }
    }

    // All retries exhausted
    c.logger.WithFields(logrus.Fields{
        "operation": operation,
        "attempts":  maxRetries + 1,
        "error":     lastErr,
    }).Error("Reward grant failed after all retries")
    return fmt.Errorf("failed after %d attempts: %w", maxRetries+1, lastErr)
}
```

#### Dispatcher Implementation

```go
func (c *AGSRewardClient) GrantReward(ctx context.Context, namespace, userID string, reward commonDomain.Reward) error {
    switch reward.Type {
    case "ITEM":
        return c.GrantItemReward(ctx, namespace, userID, reward.RewardID, reward.Quantity)
    case "WALLET":
        return c.GrantWalletReward(ctx, namespace, userID, reward.RewardID, reward.Quantity)
    default:
        c.logger.WithFields(logrus.Fields{
            "namespace":   namespace,
            "userID":      userID,
            "rewardType":  reward.Type,
        }).Warn("Unknown reward type")
        return fmt.Errorf("unsupported reward type: %s", reward.Type)
    }
}
```

**Key Implementation Notes**:
1. ✅ **GrantUserEntitlementParams.Body is an array** - wrap single grant in array
2. ✅ **ItemNamespace must equal deployment namespace** - no cross-namespace grants
3. ✅ **Type conversions**: `int32(quantity)` for items, `int64(amount)` for wallet
4. ✅ **No EntitlementType field** - AGS infers from itemID via catalog (NQ6)
5. ✅ **Context cancellation check** - before each retry attempt (NQ4)
6. ✅ **Error wrapping** - simple `fmt.Errorf("...: %w", err)` (NQ9)
7. ✅ **Response logging** - log for audit, don't validate (NQ7)
8. ✅ **10-second total timeout** - prevents transaction timeout (NQ8)

**User Decisions Implemented**:
- ✅ **NQ1**: Error extraction using type assertion pattern (Option A)
- ✅ **NQ8**: 10-second total timeout for retry loop (Option B)

#### Error Extraction Helper (Phase 7.6: Type Assertion for SDK Errors)

**Phase 7.6 Investigation**: AccelByte Go SDK v0.80.0 error types discovered (see BRAINSTORM.md Phase 7.6)

**Key Findings:**
- SDK error types DO NOT implement `StatusCode() int` method
- Status codes embedded in type names and `Error()` string format
- Each operation has specific error types per HTTP status code

**SDK Error Types Identified:**
- `GrantUserEntitlementNotFound` (404) - Item not found in namespace
- `GrantUserEntitlementUnprocessableEntity` (422) - Validation error
- `CreditUserWalletBadRequest` (400) - Wallet inactive
- `CreditUserWalletUnprocessableEntity` (422) - Validation error
- Generic errors: `"... returns an error {code}: {body}"` format

**User Decisions (Phase 7.6):**
- ✅ **Q1**: Option B - Type assertion for each SDK error type (type-safe, explicit)
- ✅ **Q2**: Keep current approach with Option B extraction
- ✅ **Q3**: Update test mocks to match real SDK structure (remove StatusCode method)
- ✅ **Q4**: Map SDK errors to status codes, use for retry logic via IsRetryableError()
- ✅ **Q5**: Pin SDK version to v0.80.0 in go.mod (no auto-upgrades)

**Implementation:**

```go
import (
    "regexp"
    "strconv"
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/entitlement"
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/wallet"
)

// extractStatusCode extracts HTTP status code from SDK error using type assertion
// Phase 7.6: Updated to match actual SDK error types (no StatusCode() method)
func (c *AGSRewardClient) extractStatusCode(err error) (int, bool) {
    if err == nil {
        return 0, false
    }

    // Type assertion for known SDK error types (Q1: Option B)
    switch err.(type) {
    case *entitlement.GrantUserEntitlementNotFound:
        return 404, true
    case *entitlement.GrantUserEntitlementUnprocessableEntity:
        return 422, true
    case *wallet.CreditUserWalletBadRequest:
        return 400, true
    case *wallet.CreditUserWalletUnprocessableEntity:
        return 422, true
    default:
        // Fallback: Parse generic SDK error message format
        // Generic errors have format: "... returns an error {code}: {body}"
        errMsg := err.Error()
        if strings.Contains(errMsg, "returns an error") {
            re := regexp.MustCompile(`returns an error (\d{3}):`)
            matches := re.FindStringSubmatch(errMsg)
            if len(matches) > 1 {
                if code, parseErr := strconv.Atoi(matches[1]); parseErr == nil {
                    return code, true
                }
            }
        }

        // Could not extract status code - log for debugging
        c.logger.WithFields(logrus.Fields{
            "errorType": fmt.Sprintf("%T", err),
            "error":     err.Error(),
        }).Debug("Could not extract status code from SDK error")

        return 0, false
    }
}

// wrapSDKError wraps SDK error with custom error type based on HTTP status code
// Phase 7.6: Uses extractStatusCode with type assertion (Q1: Option B)
func (c *AGSRewardClient) wrapSDKError(err error, message string) error {
    if err == nil {
        return nil
    }

    // Extract status code using type assertion (Q1: Option B)
    statusCode, ok := c.extractStatusCode(err)
    if !ok {
        // Could not extract status code - wrap with generic message
        return fmt.Errorf("%s: %w", message, err)
    }

    // Map status code to appropriate error type (Q4: for IsRetryableError check)
    switch statusCode {
    case 400:
        return &commonClient.BadRequestError{Message: err.Error()}
    case 401:
        return &commonClient.AuthenticationError{Message: err.Error()}
    case 403:
        return &commonClient.ForbiddenError{Message: err.Error()}
    case 404:
        return &commonClient.NotFoundError{Resource: err.Error()}
    case 422:
        return &commonClient.BadRequestError{Message: err.Error()} // Treat validation as bad request
    default:
        return &commonClient.AGSError{StatusCode: statusCode, Message: err.Error()}
    }
}

// Usage in error classification (already implemented in commonClient.IsRetryableError):
// The IsRetryableError function in extend-challenge-common/pkg/client/reward_client.go
// already handles status code extraction via HTTPStatusCodeError interface.
```

**SDK Version Pinning (Q5 Decision):**

To ensure error extraction remains stable, pin AccelByte Go SDK version in `go.mod`:

```go
require (
    github.com/AccelByte/accelbyte-go-sdk v0.80.0  // Pinned - do not auto-upgrade
    // ... other dependencies
)
```

**Upgrade Process:**
1. Review SDK CHANGELOG for error type changes
2. Update `extractStatusCode()` type assertion cases if needed
3. Run integration tests (Phase 7.5) to verify error handling
4. Update SDK version in go.mod manually

**Test Mock Updates (Q3 Decision):**

Update test mocks to match real SDK error structure (remove `StatusCode()` method):

```go
// OLD: mockSDKError with StatusCode() method (incorrect)
type mockSDKError struct {
    statusCode int
    message    string
}
func (e *mockSDKError) StatusCode() int { return e.statusCode }

// NEW: Use actual SDK error types in tests (correct)
// Import SDK error types and use them directly in test assertions
import (
    "github.com/AccelByte/accelbyte-go-sdk/platform-sdk/pkg/platformclient/entitlement"
)

// Test example:
err := &entitlement.GrantUserEntitlementNotFound{...}
statusCode, ok := client.extractStatusCode(err)
assert.True(t, ok)
assert.Equal(t, 404, statusCode)
// and refine the extraction logic if needed.
```

**Implementation Strategy**:
1. Start with type assertion for `StatusCode() int` method
2. Log all SDK errors during development to observe actual error types
3. Refine extraction logic based on actual SDK error structure during Phase 7.5
4. Fallback to `IsRetryableError` message pattern matching if type assertion fails

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REWARD_GRANT_MAX_RETRIES` | 3 | Maximum retry attempts |
| `REWARD_GRANT_BASE_DELAY` | 500 (ms) | Base delay for exponential backoff (FQ1: faster retries) |
| `REWARD_GRANT_MAX_DELAY` | 10000 (ms) | Maximum delay between retries |

### Error Handling

**Retryable Errors:**
- Network timeout
- 502/503 Bad Gateway / Service Unavailable
- Connection refused
- Temporary DNS failures

**Non-Retryable Errors (fail immediately):**
- 400 Bad Request (invalid item/currency)
- 404 Not Found (item doesn't exist)
- 403 Forbidden (insufficient permissions)
- Authentication errors

**Implementation:**
```go
func isRetryable(err error) bool {
    if err == nil {
        return false
    }

    // Network errors are retryable
    var netErr net.Error
    if errors.As(err, &netErr) && netErr.Timeout() {
        return true
    }

    // gRPC errors
    if status, ok := status.FromError(err); ok {
        switch status.Code() {
        case codes.Unavailable, codes.DeadlineExceeded, codes.ResourceExhausted:
            return true
        case codes.InvalidArgument, codes.NotFound, codes.PermissionDenied, codes.Unauthenticated:
            return false
        }
    }

    // Default: retry
    return true
}
```

### Testing

**Mock RewardClient for unit tests:**
```go
type MockRewardClient struct {
    mock.Mock
}

func (m *MockRewardClient) GrantReward(ctx context.Context, userID string, reward domain.Reward) error {
    args := m.Called(ctx, userID, reward)
    return args.Error(0)
}

// Test retry behavior
func TestRewardClient_RetriesOnFailure(t *testing.T) {
    client := NewRewardClient(platformClient, logger)

    // Simulate 2 failures, then success
    platformClient.On("GrantUserEntitlement", mock.Anything, mock.Anything).
        Return(errors.New("timeout")).Once()
    platformClient.On("GrantUserEntitlement", mock.Anything, mock.Anything).
        Return(errors.New("timeout")).Once()
    platformClient.On("GrantUserEntitlement", mock.Anything, mock.Anything).
        Return(nil).Once()

    err := client.GrantReward(ctx, "user123", reward)
    assert.NoError(t, err)
    assert.Equal(t, 3, platformClient.CallCount("GrantUserEntitlement"))
}
```

---

## References

- **Extend Service Extension Template**: https://github.com/AccelByte/extend-service-extension-go
- **Go net/http Package**: https://pkg.go.dev/net/http
- **JWT Best Practices**: https://tools.ietf.org/html/rfc8725
- **AGS SDK Functions**: Use Extend SDK MCP Server to search for IAM authentication functions:
  - `mcp__extend-sdk-mcp-server__search_functions` with query "jwt validate" or "token verify"
  - `mcp__extend-sdk-mcp-server__get_bulk_functions` to get detailed function signatures

---

**Document Status:** Complete - Ready for implementation
