# Visual Flow Diagrams

**Interactive Mermaid diagrams** for the AccelByte Extend Challenge Service.
These render automatically on GitHub and in any Mermaid-compatible viewer ([mermaid.live](https://mermaid.live)).

---

## Table of Contents

1. [System Architecture Overview](#1-system-architecture-overview)
2. [Event Processing Pipeline](#2-event-processing-pipeline)
3. [Goal Status State Machine](#3-goal-status-state-machine)
4. [Reward Claiming Flow](#4-reward-claiming-flow)
5. [Goal Selection Patterns](#5-goal-selection-patterns)
6. [Time-Based Rotation Lifecycle](#6-time-based-rotation-lifecycle)
7. [Expired Row Cleanup](#7-expired-row-cleanup)
8. [GDPR User Data Deletion](#8-gdpr-user-data-deletion)

---

## 1. System Architecture Overview

Two Extend microservices share a common library and integrate with AGS platform services.

```mermaid
graph TB
    subgraph "Game Client"
        GC[Game Client]
    end

    subgraph "AccelByte Gaming Services"
        IAM[AGS IAM Service]
        PLAT[AGS Platform Service]
        STAT[AGS Statistic Service]
        KAFKA[Kafka / Extend Platform]
    end

    subgraph "Challenge Suite"
        subgraph "Backend Service (REST API)"
            API[HTTP Handlers<br/>Port 8000]
            SVC[Business Logic]
        end

        subgraph "Event Handler (gRPC)"
            GRPC[gRPC Handler<br/>Port 6566]
            BUF[Buffered Repository<br/>1s flush / Batch UPSERT]
        end

        COMMON[Common Library<br/>Domain Models · Interfaces · Config]
    end

    subgraph "Data Stores"
        PG[(PostgreSQL<br/>user_goal_progress)]
        REDIS[(Redis<br/>Optional Cache)]
    end

    GC -->|REST API calls| API
    GC -->|Login / Play| IAM
    GC -->|Play| STAT

    IAM -->|Login events| KAFKA
    STAT -->|Stat update events| KAFKA
    KAFKA -->|gRPC delivery| GRPC

    GRPC --> BUF
    BUF -->|Batch UPSERT| PG

    API --> SVC
    SVC -->|Query progress| PG
    SVC -->|Grant rewards| PLAT
    SVC -->|Validate JWT| IAM
    SVC -.->|Cache| REDIS

    API --- COMMON
    GRPC --- COMMON
```

---

## 2. Event Processing Pipeline

The core performance innovation: events are buffered and flushed as batch UPSERTs, achieving a **1,000,000x DB query reduction**.

```mermaid
flowchart LR
    A[Game Server] -->|User action| B[AGS Service<br/>IAM / Statistics]
    B -->|Publish event| C[Kafka]
    C -->|Deliver| D[Extend Platform]
    D -->|gRPC call| E[Event Handler]

    E --> F{Validate Event}
    F -->|Invalid| G[Log & Discard]
    F -->|Valid| H[Per-User Mutex<br/>Lock]

    H --> I[Cache Lookup<br/>Find affected goals]
    I --> J[Calculate Progress<br/>absolute or relative]
    J --> K[Write to Buffer<br/>Map deduplication]
    K --> L[Unlock Mutex]

    L --> M{1s Timer<br/>Tick?}
    M -->|No| N[Wait]
    M -->|Yes| O[Flush Buffer]
    O --> P[Batch UPSERT<br/>Single SQL query<br/>1000 rows ≈ 20ms]
    P --> Q[(PostgreSQL)]
```

**Key properties:**
- Per-user mutex serializes events for one user; different users process in parallel
- Map-based buffer keeps only the latest progress per `(user_id, goal_id)` pair
- 1,000 buffered updates = 1 database query (not 1,000 queries)

---

## 3. Goal Status State Machine

Every goal row follows this state machine. Rotation adds reset paths back to `not_started`.

```mermaid
stateDiagram-v2
    [*] --> not_started : Row created<br/>(lazy init)

    not_started --> in_progress : First event updates<br/>progress > 0

    in_progress --> completed : Progress ≥<br/>target value

    completed --> claimed : POST /claim<br/>reward granted

    claimed --> [*] : Terminal state<br/>(UPSERT skips)

    note right of not_started
        is_active = true (assigned)
        or is_active = false (inactive)
    end note

    note right of claimed
        UPSERT queries include
        WHERE status != 'claimed'
        to protect claimed rows
    end note

    %% Rotation reset paths
    completed --> not_started : Rotation boundary<br/>reset progress & baseline
    in_progress --> not_started : Rotation boundary<br/>reset progress & baseline
    not_started --> not_started : Rotation boundary<br/>update expires_at
```

---

## 4. Reward Claiming Flow

Row-level locking (`SELECT ... FOR UPDATE`) prevents double claims. Failed reward grants are retried 3 times with exponential backoff.

```mermaid
sequenceDiagram
    participant C as Game Client
    participant API as Backend Service
    participant DB as PostgreSQL
    participant AGS as AGS Platform<br/>Service

    C->>API: POST /v1/challenges/{id}/goals/{id}/claim
    API->>API: Validate JWT, extract userId

    API->>DB: BEGIN TRANSACTION
    API->>DB: SELECT ... FOR UPDATE<br/>WHERE user_id=$1 AND goal_id=$2

    alt Status ≠ completed
        DB-->>API: Row status check
        API-->>C: 400 Bad Request<br/>"goal not completed"
        API->>DB: ROLLBACK
    else Status = completed
        DB-->>API: Row locked

        alt Has prerequisites
            API->>DB: Check prerequisite goals status
            alt Prerequisites not met
                API-->>C: 400 Bad Request<br/>"prerequisites not met"
                API->>DB: ROLLBACK
            end
        end

        loop Up to 3 retries (exponential backoff)
            API->>AGS: Grant reward<br/>(ITEM entitlement or WALLET credit)
            alt Success
                AGS-->>API: 200 OK
            else Failure
                AGS-->>API: Error
            end
        end

        alt All retries failed
            API-->>C: 502 Bad Gateway<br/>"reward grant failed"
            API->>DB: ROLLBACK
        else Reward granted
            API->>DB: UPDATE status='claimed',<br/>claimed_at=NOW()
            API->>DB: COMMIT
            API-->>C: 200 OK<br/>{status: "claimed"}
        end
    end
```

---

## 5. Goal Selection Patterns

Three patterns for controlling which goals a player works on. Game developers choose based on their UX needs.

```mermaid
flowchart TD
    subgraph individual ["Individual Selection (M3)"]
        I1[Client calls<br/>PUT /goals/{id}/active] --> I2{Goal exists<br/>in config?}
        I2 -->|No| I3[404 Not Found]
        I2 -->|Yes| I4[UPSERT row<br/>is_active = true]
        I4 --> I5[Goal now tracks<br/>events]
    end

    subgraph batch ["Batch Selection (M4)"]
        B1[Client calls<br/>POST /goals/batch-select<br/>goalIds: list] --> B2{All IDs valid?}
        B2 -->|No| B3[400 Bad Request<br/>invalid goal IDs]
        B2 -->|Yes| B4[BatchUpsertGoalActive<br/>single SQL for all goals]
        B4 --> B5[All goals now<br/>active]
    end

    subgraph random ["Random Selection (M4)"]
        R1[Client calls<br/>POST /goals/random-select<br/>count: N] --> R2[Filter available<br/>goals from config]
        R2 --> R3[Exclude already<br/>active goals]
        R3 --> R4[Shuffle &<br/>pick N goals]
        R4 --> R5[BatchUpsertGoalActive<br/>single SQL]
        R5 --> R6[N random goals<br/>now active]
    end
```

---

## 6. Time-Based Rotation Lifecycle

Rotation uses **baseline-relative tracking** so cumulative stats (e.g., `matches_played: 150 → 160`) can power daily goals. Detection is **lazy** — triggered only when the player interacts.

```mermaid
sequenceDiagram
    participant Player
    participant API as Backend / Event Handler
    participant DB as PostgreSQL

    Note over Player,DB: Goal Activation
    Player->>API: Initialize / Select goal<br/>(progressMode: relative)
    API->>DB: UPSERT row<br/>baseline_value=NULL, progress=0<br/>expires_at = next boundary

    Note over Player,DB: Normal Event Processing
    Player->>API: Play game → stat event<br/>(matches_played = 155)
    API->>API: First event: derive baseline<br/>baseline = progress - increment
    API->>DB: Batch UPSERT<br/>SET progress=155, baseline_value=150<br/>effective progress = 155-150 = 5

    Player->>API: More events (stat = 160)
    API->>DB: SET progress=160<br/>effective = 160-150 = 10 → COMPLETED

    Note over Player,DB: Rotation Boundary Reached
    Player->>API: Next day: GET /challenges<br/>or stat event arrives

    API->>API: Lazy detection:<br/>expires_at < NOW()?

    alt Detected via API call
        API->>DB: Reset row:<br/>progress=0, baseline_value=NULL<br/>status=not_started<br/>expires_at = next boundary
        API-->>Player: Fresh goal, progress 0/10
    else Detected via event
        API->>DB: Batch UPSERT with SQL CASE:<br/>IF expires_at < NOW() THEN reset<br/>baseline + progress from event
    end

    Note over Player,DB: New rotation period begins
    Player->>API: New events update progress<br/>relative to new baseline
```

**Rotation types:** `daily` (midnight UTC), `weekly` (Monday midnight), `monthly` (1st of month).

---

## 7. Expired Row Cleanup

A background goroutine in the backend service prevents unbounded table growth from rotating goals. **Turbo mode** clears backlogs on startup.

```mermaid
flowchart TD
    START[Service Startup] --> CHECK{Cleanup<br/>enabled?}
    CHECK -->|No| DISABLED[Log: disabled<br/>Exit goroutine]
    CHECK -->|Yes| INIT[Start cleanup<br/>goroutine]

    INIT --> WAIT[Wait for<br/>ticker interval<br/>default: 60 min]
    WAIT --> TURBO{Cycle ≤<br/>initial_cycles?}

    TURBO -->|Yes| TLIMIT[Use turbo limit<br/>1000 batches max]
    TURBO -->|No| NLIMIT[Use normal limit<br/>100 batches max]

    TLIMIT --> CYCLE
    NLIMIT --> CYCLE

    CYCLE[Start cleanup cycle<br/>cutoff = NOW - 7 days] --> BATCH[DELETE batch<br/>1000 rows via CTE]

    BATCH --> RESULT{Rows deleted<br/>< batch size?}

    RESULT -->|Yes| DONE[Cycle complete<br/>Log total deleted]
    RESULT -->|No| MAXCHECK{Batch count<br/>≥ max limit?}

    MAXCHECK -->|Yes| DONE
    MAXCHECK -->|No| PAUSE[Pause 50ms<br/>between batches]
    PAUSE --> BATCH

    BATCH -->|DB error| ERR[Log error<br/>Increment error counter<br/>Abandon cycle]
    ERR --> WAIT

    DONE --> METRICS[Emit Prometheus metrics<br/>rows_deleted, duration,<br/>cycles_total]
    METRICS --> WAIT

    WAIT -->|ctx.Done| STOP[Goroutine exits<br/>graceful shutdown]
```

---

## 8. GDPR User Data Deletion

Per-user rate limiting (1 request/minute) prevents abuse. The delete is partition-optimal since `user_id` is the partition key.

```mermaid
sequenceDiagram
    participant C as Game Client
    participant API as Backend Service
    participant DB as PostgreSQL

    C->>API: DELETE /v1/users/me/data
    API->>API: Validate JWT<br/>Extract userId, namespace

    API->>API: Rate limit check<br/>(1 req/min per user)

    alt Rate limited
        API-->>C: 429 Too Many Requests
    else Allowed
        API->>DB: DELETE FROM user_goal_progress<br/>WHERE user_id = $1<br/>AND namespace = $2
        DB-->>API: Rows affected count

        API->>API: Structured audit log<br/>(userId, rowsDeleted, timestamp)

        API-->>C: 200 OK<br/>{rowsDeleted: N}
    end
```

---

## Rendering These Diagrams

- **GitHub**: Renders automatically in markdown preview
- **VS Code**: Install [Markdown Preview Mermaid Support](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid)
- **Online**: Paste into [mermaid.live](https://mermaid.live)

---

*See [INDEX.md](INDEX.md) for the full documentation index.*
