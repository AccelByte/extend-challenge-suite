# Technical Specification: Challenge Service M1

**Version:** 1.0
**Date:** 2025-10-15
**Status:** READY FOR IMPLEMENTATION

## Overview

The Challenge Service is an AccelByte Extend application that enables game developers to implement challenge systems (daily missions, seasonal events, quests) with minimal configuration. This is an open-source application that game developers can fork and customize via a JSON config file.

## M1 Scope

### In Scope
- **Fixed Goals Only**: Predefined goals with static requirements (e.g., "Kill 10 enemies")
- **Two Reward Types**: Item entitlements and wallet credits via AGS Platform Service
- **Event-Driven Progress**: Automatic progress tracking from AGS events via Kafka
- **REST API**: Query challenges and claim rewards
- **Config-First**: JSON file defines challenges/goals (no admin UI)
- **Single Namespace**: Each deployment operates in one AGS namespace

### Out of Scope
- Dynamic goals (runtime generation)
- Leaderboards
- Admin portal/CRUD API
- Multi-language localization
- Rate limiting
- Multiple goal operators (only `>=` supported)

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                    AccelByte Gaming Services                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │   IAM    │  │ Platform │  │  Basic   │  │  Kafka   │   │
│  │ Service  │  │ Service  │  │ Service  │  │  Broker  │   │
│  └────┬─────┘  └────▲─────┘  └──────────┘  └────┬─────┘   │
└───────┼─────────────┼───────────────────────────┼─────────┘
        │ Auth        │ Rewards            Events │
        │             │                            │
┌───────▼─────────────┴────────────────────────────▼─────────┐
│              Extend Challenge Application                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  extend-challenge-service (REST API)                │   │
│  │  - GET /v1/challenges                               │   │
│  │  - POST /v1/challenges/{id}/goals/{id}/claim        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  extend-challenge-event-handler (gRPC)              │   │
│  │  - Consumes AGS events via gRPC                     │   │
│  │  - Updates user_goal_progress via BufferedRepo      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  extend-challenge-common (Shared Library)           │   │
│  │  - Domain models, interfaces, error codes           │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────┬──────────────────┘
                       │                  │
                ┌──────▼────┐      ┌──────▼────┐
                │PostgreSQL │      │   Redis   │
                │(Primary)  │      │ (Optional)│
                └───────────┘      └───────────┘
```

### Technology Stack

| Component | Technology | Justification |
|-----------|-----------|---------------|
| Language | Go 1.25+ | Required by AccelByte Extend templates |
| REST API | Extend Service Extension template | Official AGS template |
| Event Handler | Extend Event Handler template | Official AGS template, gRPC abstraction |
| Database | PostgreSQL | Template default, ACID compliance needed |
| Cache | Redis (optional) | Template default, not critical for M1 |
| Config | JSON file | Simple, version-controlled |
| Migrations | golang-migrate | Standard Go migration tool |
| Testing | testify/mock | Standard Go testing framework |

## Detailed Specifications

This technical specification is organized into focused documents:

### [Database Design](./TECH_SPEC_DATABASE.md)
- Database schema and tables
- Indexes and constraints
- UPSERT queries
- Migration strategy

### [API Design](./TECH_SPEC_API.md)
- REST endpoints
- Request/response schemas
- Authentication & authorization (see [JWT_AUTHENTICATION.md](./JWT_AUTHENTICATION.md) for implementation details)
- Error handling

### [Event Processing](./TECH_SPEC_EVENT_PROCESSING.md)
- Event flow diagrams
- Event schemas
- Buffering strategy
- Concurrency control
- Performance optimization

### [Configuration](./TECH_SPEC_CONFIGURATION.md)
- Environment variables
- Challenge config file format
- Config loading and validation
- Cache structure

### [Deployment](./TECH_SPEC_DEPLOYMENT.md)
- Local development setup
- Docker configuration
- AccelByte Extend deployment
- Infrastructure requirements

### [Testing Strategy](./TECH_SPEC_TESTING.md)
- Unit testing approach
- Integration testing
- Test data and fixtures
- Performance testing

## Project Structure

```
extend-challenge/
├── docs/
│   ├── TECH_SPEC_M1.md (this file)
│   ├── TECH_SPEC_DATABASE.md
│   ├── TECH_SPEC_API.md
│   ├── TECH_SPEC_EVENT_PROCESSING.md
│   ├── TECH_SPEC_CONFIGURATION.md
│   ├── TECH_SPEC_DEPLOYMENT.md
│   ├── TECH_SPEC_TESTING.md
│   ├── JWT_AUTHENTICATION.md
│   ├── BRAINSTORM.md
│   └── demo-app/                      # Demo app specifications
│       ├── STATUS.md                  # Demo app implementation progress
│       ├── INDEX.md                   # Demo app documentation index
│       ├── DESIGN.md                  # Demo app high-level design
│       ├── TECH_SPEC_ARCHITECTURE.md  # Demo app architecture
│       ├── TECH_SPEC_TUI.md           # Terminal UI implementation
│       ├── TECH_SPEC_API_CLIENT.md    # HTTP API client
│       ├── TECH_SPEC_AUTHENTICATION.md # Auth providers
│       ├── TECH_SPEC_EVENT_TRIGGERING.md # Event simulation
│       ├── TECH_SPEC_CONFIG.md        # Configuration management
│       ├── TECH_SPEC_CLI_MODE.md      # Non-interactive CLI mode
│       └── TECH_SPEC_QUESTIONS.md     # Resolved design questions
│
├── extend-challenge-service/          # Service Extension (REST API)
│   ├── cmd/
│   ├── internal/
│   ├── migrations/
│   ├── config/
│   ├── Dockerfile
│   ├── Makefile
│   └── go.mod
│
├── extend-challenge-event-handler/    # Event Handler (gRPC)
│   ├── pkg/
│   │   ├── service/       # Event handlers (LoginHandler, StatisticHandler)
│   │   ├── processor/     # EventProcessor
│   │   ├── buffered/      # BufferedRepository
│   │   ├── common/        # Utilities (from template)
│   │   ├── proto/         # Downloaded proto files
│   │   └── pb/            # Generated Go code from proto
│   ├── config/
│   ├── Dockerfile
│   ├── Makefile
│   ├── proto.sh           # Proto code generation script
│   └── go.mod
│
├── extend-challenge-common/           # Shared library
│   ├── pkg/
│   │   ├── config/
│   │   ├── domain/
│   │   ├── repository/
│   │   ├── cache/
│   │   ├── client/
│   │   └── errors/
│   └── go.mod
│
├── extend-challenge-demo-app/         # Demo application (Terminal UI + CLI)
│   ├── cmd/challenge-demo/            # Main entry point
│   ├── internal/
│   │   ├── api/           # HTTP API client
│   │   ├── auth/          # Auth providers (mock, password, client)
│   │   ├── events/        # Event triggering (gRPC OnMessage)
│   │   ├── tui/           # Terminal UI (Bubble Tea)
│   │   ├── cli/           # CLI commands and formatters
│   │   ├── app/           # Dependency injection container
│   │   └── config/        # Configuration management
│   ├── bin/               # Built binaries
│   ├── go.mod
│   └── README.md          # Demo app usage guide
│
├── tests/
│   └── e2e/               # End-to-end test scripts (CLI-based)
│       ├── test-login-flow.sh
│       ├── test-stat-flow.sh
│       ├── test-daily-goal.sh
│       ├── test-buffering-performance.sh
│       ├── test-prerequisites.sh
│       ├── test-mixed-goals.sh
│       ├── test-error-scenarios.sh
│       ├── test-reward-failures.sh
│       ├── test-multi-user.sh
│       ├── run-all-tests.sh
│       ├── helpers.sh
│       ├── README.md      # E2E testing documentation
│       └── QUICK_START.md
│
├── docker-compose.yml
├── Makefile               # Root-level orchestration
├── .env.example
├── .env
├── AGS_SETUP_GUIDE.md     # AccelByte AGS credential setup guide
└── README.md
```

## Core Interfaces

### GoalRepository
Handles all database operations for user goal progress.

```go
type GoalRepository interface {
    GetProgress(userID, goalID string) (*UserGoalProgress, error)
    GetUserProgress(userID string) ([]*UserGoalProgress, error)
    GetChallengeProgress(userID, challengeID string) ([]*UserGoalProgress, error)
    UpsertProgress(progress *UserGoalProgress) error
    BatchUpsertProgress(updates []*UserGoalProgress) error
    MarkAsClaimed(userID, goalID string) error
    BeginTx() (TxRepository, error)
}
```

### GoalCache
Provides O(1) in-memory lookups for goal configurations.

```go
type GoalCache interface {
    GetGoalByID(goalID string) *Goal
    GetGoalsByStatCode(statCode string) []*Goal
    GetChallengeByChallengeID(challengeID string) *Challenge
    GetAllChallenges() []*Challenge
    Reload() error
}
```

### RewardClient
Integrates with AGS Platform Service for reward grants.

```go
type RewardClient interface {
    GrantItemReward(userID, itemID string, quantity int) error
    GrantWalletReward(userID, currencyCode string, amount int) error
    GrantReward(userID string, reward Reward) error
}
```

## Key Design Decisions

All design decisions documented in [BRAINSTORM.md](./BRAINSTORM.md):
- 70 total decisions across 5 rounds of iteration
- Event-driven architecture with buffering (1000x DB load reduction)
- Interface-driven design for testability
- Config-first approach (no admin UI)
- Single-namespace deployment model
- PostgreSQL with in-memory cache
- Lazy initialization of user progress records

## Performance Targets

| Metric | Target (p95) |
|--------|-------------|
| API Response Time | < 200ms |
| Event Processing Time | < 50ms |
| Event Processing Lag | < 5s |
| Database Query Time | < 50ms |
| Cache Lookup Time | < 1ms |

## Implementation Phases

### Phase 1: Project Setup (Day 1)
- Clone Extend templates
- Remove .git folders and rename references
- Create project structure
- Set up docker-compose for local dev

### Phase 1.5: Learn Template Architecture (Day 1)
- Study extend-service-extension-go REST API architecture
  - Protobuf definitions + gRPC Gateway approach
  - Code generation workflow
  - Makefile targets and build process
  - Dockerfile structure
- Study extend-event-handler-go event processing
  - Proto spec download/management
  - Event handler implementation patterns
  - Makefile targets and build process
  - Dockerfile structure
- Review docker-compose configurations in templates
- Design integration test docker-compose strategy
- Update TECH_SPEC_API.md with findings
- Update TECH_SPEC_EVENT_PROCESSING.md with findings
- Update TECH_SPEC_DEPLOYMENT.md with build/deployment workflow

### Phase 2: Domain & Interfaces (Day 1-2)
- Define domain models
- Define interfaces
- Write domain unit tests

### Phase 3: Database Layer (Day 2-3)
- Write migrations
- Implement GoalRepository
- Write repository tests

### Phase 4: Cache Layer (Day 3)
- Implement GoalCache
- Write config loader
- Write cache tests

### Phase 5: Event Handler (Day 4-5)

**Phase 5.1: Infrastructure & Dependencies (Day 4 Morning)**
- Download statistic event proto files from AccelByte proto repository
- Run `make proto` to generate Go code for both IAM and Statistic events
- Set up database connection in event handler main.go
- Implement BufferedRepository with dual-flush mechanism (time + size based)
- Write BufferedRepository tests (80%+ coverage)
- Set up EventProcessor structure with per-user mutex

**Phase 5.2: IAM Login Event Handler (Day 4 Afternoon)**
- Replace template loginHandler.go with challenge-specific implementation
- Integrate EventProcessor with LoginHandler
- Process login events as "login_count" stat updates
- Write LoginHandler tests (80%+ coverage)
- Test end-to-end: IAM event → progress update → DB flush

**Phase 5.3: Statistic Event Handler (Day 5)**
- Implement StatisticHandler for stat update events
- Register StatisticHandler with gRPC server
- Process stat updates via EventProcessor
- Write StatisticHandler tests (80%+ coverage)
- Test end-to-end: Stat event → progress update → DB flush
- Performance test: Verify <50ms event processing, <20ms batch flush

### Phase 6: REST API (Day 5-6)
- Implement business logic
- Implement HTTP handlers
- Write service tests

### Phase 7: AGS Integration (Day 6-7)
- Implement RewardClient
- Add retry logic
- Write client tests

### Phase 8: Integration Testing (Day 7-8)
- Write end-to-end tests
- Test against local and deployed environments

### Phase 9: Documentation (Day 8)
- Complete README
- Add code comments
- Update STATUS.md

**Note on Demo Application**: The demo application (`extend-challenge-demo-app`) was developed in parallel with the core services to support E2E testing. It has its own implementation phases (0-7) documented in [demo-app/STATUS.md](./demo-app/STATUS.md) with complete technical specifications in `docs/demo-app/`. The demo app provides both a Terminal UI and CLI mode for testing and demonstrating the Challenge Service. See the [Demo Application section in STATUS.md](../STATUS.md#demo-application-cli-tool) for complete details.

## References

- **AccelByte Extend Docs**: https://docs.accelbyte.io/extend/
- **Service Extension Template**: https://github.com/AccelByte/extend-service-extension-go
- **Event Handler Template**: https://github.com/AccelByte/extend-event-handler-go
- **AGS Platform API**: Use Extend SDK MCP Server (`mcp__extend-sdk-mcp-server__*` tools) to search for Platform Service functions
- **AGS IAM API**: Use Extend SDK MCP Server (`mcp__extend-sdk-mcp-server__*` tools) to search for IAM Service functions
- **golang-migrate**: https://github.com/golang-migrate/migrate
- **testify**: https://github.com/stretchr/testify

---

**Document Status:** Ready for implementation. All design decisions finalized with 0 outstanding questions.

**Next Steps:**
1. Review detailed specifications in linked documents
2. Begin Phase 1 implementation
3. Track progress in `docs/STATUS.md`
