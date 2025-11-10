# Codebase Structure

## Root Directory Layout

```
extend-challenge/
├── docs/                                    # All specifications and documentation
├── extend-challenge-service/               # REST API service (backend)
├── extend-challenge-event-handler/         # gRPC event handler
├── extend-challenge-common/                # Shared library
├── extend-challenge-demo-app/              # TUI demo app (to be created)
├── docker-compose.yml                      # Local development orchestration
├── docker-compose.test.yml                 # Test environment
├── Makefile                                # Top-level dev commands
├── CLAUDE.md                               # Claude Code instructions
├── .env.example                            # Environment variable template
└── .gitignore
```

## Backend Service Structure

```
extend-challenge-service/
├── cmd/                                    # Entry points
├── pkg/
│   ├── common/                            # Shared utilities
│   ├── pb/                                # Generated protobuf code
│   ├── server/                            # gRPC server implementation
│   │   ├── handler/                       # HTTP REST handlers
│   │   ├── service/                       # Business logic layer
│   │   └── repository/                    # Database access layer
├── config/                                 # Configuration files
│   └── challenges.json                    # Challenge definitions
├── migrations/                             # Database schema migrations
│   └── postgres/
│       ├── 000001_create_user_goal_progress.up.sql
│       └── 000001_create_user_goal_progress.down.sql
├── tests/
│   ├── integration/                       # Integration tests with testcontainers
│   └── fixtures/                          # Test data
├── third_party/                           # Proto definitions
├── gateway/                               # gRPC-Gateway configuration
├── docs/                                  # Service-specific docs
├── Dockerfile
├── Makefile                               # Service-specific commands
├── docker-compose.yaml                    # Service-only compose
├── docker-compose.test.yml                # Test database
├── .golangci.yml                          # Linter configuration
├── go.mod
└── main.go
```

## Event Handler Structure

```
extend-challenge-event-handler/
├── pkg/
│   ├── common/                            # Shared utilities
│   ├── pb/                                # Generated protobuf code
│   ├── server/                            # gRPC server implementation
│   │   ├── processor/                     # Event processing logic
│   │   └── buffered/                      # BufferedRepository implementation
├── config/                                # Configuration files
├── demo/                                  # Demo/testing utilities
├── docs/                                  # Handler-specific docs
├── Dockerfile
├── Makefile
├── .golangci.yml
├── go.mod
└── main.go
```

## Common Library Structure

```
extend-challenge-common/
└── pkg/
    ├── config/                             # Config loader and validator
    │   ├── loader.go                      # JSON config loading
    │   └── cache.go                       # In-memory config cache
    ├── domain/                             # Domain models
    │   ├── challenge.go                   # Challenge, Goal structs
    │   └── progress.go                    # UserGoalProgress struct
    ├── repository/                         # Repository interfaces
    │   └── interfaces.go                  # GoalRepository interface
    ├── cache/                              # Cache interfaces
    │   └── interfaces.go                  # GoalCache interface
    ├── client/                             # External client interfaces
    │   └── interfaces.go                  # RewardClient interface
    └── errors/                             # Custom error types
        └── errors.go                      # Domain-specific errors
```

## Demo App Structure (To Be Created)

```
extend-challenge-demo-app/
├── cmd/
│   └── challenge-demo/                    # Main entry point
│       └── main.go
├── internal/
│   ├── app/                               # Application setup
│   │   └── container.go                   # Dependency injection
│   ├── api/                               # HTTP API client
│   │   ├── client.go                      # HTTPAPIClient implementation
│   │   └── interfaces.go                 # APIClient interface
│   ├── auth/                              # Authentication
│   │   ├── mock.go                        # MockAuthProvider
│   │   └── interfaces.go                 # AuthProvider interface
│   ├── events/                            # Event triggering
│   │   ├── local.go                       # LocalEventTrigger implementation
│   │   └── interfaces.go                 # EventTrigger interface
│   ├── config/                            # Configuration management
│   │   ├── config.go                      # Config struct
│   │   ├── loader.go                      # ViperConfigManager
│   │   └── wizard.go                     # Interactive config wizard
│   └── tui/                               # Terminal UI
│       ├── app.go                         # Root AppModel
│       ├── dashboard.go                   # Dashboard screen
│       ├── event_simulator.go            # Event simulator screen
│       ├── debug.go                       # Debug panel
│       └── styles.go                     # Lip Gloss styles
├── .gitignore
├── go.mod
└── README.md
```

## Documentation Structure

```
docs/
├── TECH_SPEC_M1.md                        # Main technical spec (index)
├── TECH_SPEC_DATABASE.md                  # Database schema and queries
├── TECH_SPEC_API.md                       # REST API endpoints
├── TECH_SPEC_EVENT_PROCESSING.md          # Event flow and buffering
├── TECH_SPEC_CONFIGURATION.md             # Config format
├── TECH_SPEC_DEPLOYMENT.md                # Deployment guide
├── TECH_SPEC_TESTING.md                   # Test strategy
├── TECH_SPEC_DATABASE_PARTITIONING.md     # Scaling strategy
├── JWT_AUTHENTICATION.md                  # JWT auth architecture
├── BRAINSTORM.md                          # Design decisions
├── MILESTONES.md                          # Feature roadmap (M1-M6)
├── STATUS.md                              # Implementation progress
└── demo-app/                              # Demo app specs
    ├── DESIGN.md                          # High-level design
    ├── STATUS.md                          # Implementation status
    ├── INDEX.md                           # Spec index
    ├── TECH_SPEC_ARCHITECTURE.md          # Architecture
    ├── TECH_SPEC_TUI.md                   # Bubble Tea TUI
    ├── TECH_SPEC_API_CLIENT.md            # HTTP client
    ├── TECH_SPEC_EVENT_TRIGGERING.md      # Event simulation
    ├── TECH_SPEC_AUTHENTICATION.md        # Auth providers
    ├── TECH_SPEC_CONFIG.md                # Config management
    └── TECH_SPEC_QUESTIONS.md             # Resolved questions
```

## Key File Locations

### Configuration
- Backend config: `extend-challenge-service/config/challenges.json`
- Environment vars: `.env` (from `.env.example`)

### Migrations
- PostgreSQL: `extend-challenge-service/migrations/postgres/`

### Proto Definitions
- Backend: `extend-challenge-service/third_party/`
- Event Handler: `extend-challenge-event-handler/third_party/` (likely)

### Tests
- Backend integration: `extend-challenge-service/tests/integration/`
- Unit tests: Co-located with source files (`*_test.go`)

### Generated Code
- Protobuf: `*/pkg/pb/`

## Module Relationships

```
extend-challenge-service/go.mod
  └─> replace extend-challenge-common => ../extend-challenge-common

extend-challenge-event-handler/go.mod
  └─> replace extend-challenge-common => ../extend-challenge-common

extend-challenge-demo-app/go.mod (to be created)
  └─> No dependency on common (independent TUI app)
```
