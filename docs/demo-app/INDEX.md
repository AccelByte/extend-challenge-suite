# Challenge Demo App - Documentation Index

This folder contains all design and technical specifications for the **Challenge Service Demo Application** (TUI).

---

## 📋 Overview

The demo app is a **Terminal UI (TUI)** tool for testing, debugging, and demonstrating the Challenge Service. It provides a keyboard-driven interface for developers, QA engineers, and DevOps teams.

**Key Features:**
- View challenges and goals with real-time progress
- Trigger gameplay events (login, stat updates)
- Claim rewards and observe AGS Platform integration
- Debug mode with raw JSON inspection
- Multi-environment support (local, staging, production)

**Technology:** Go + Bubble Tea (TUI framework)

**Estimated Development:** 3-4 days (6 phases)

---

## 📚 Documentation Structure

### Design Specifications

| Document | Purpose | Status |
|----------|---------|--------|
| **[DESIGN.md](./DESIGN.md)** | High-level design spec (why, what, user flows) | ✅ Complete |
| **[STATUS.md](./STATUS.md)** | Implementation progress tracker (checklist) | 🔄 Active |

**What's in DESIGN.md:**
- User personas and use cases
- UI layouts and keyboard shortcuts
- Technology stack rationale (Bubble Tea, Lip Gloss)
- Development phases (6 phases)
- Design principles and UX guidelines

**What's in STATUS.md:**
- Implementation phase checklist (Phase 0-6)
- Task breakdowns with spec references
- Overall progress tracking (0% → 100%)
- Testing checklist
- Dependency status

---

### Technical Specifications

| Document | Purpose | Status |
|----------|---------|--------|
| **[TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md)** | Overall architecture, interfaces, and components | ✅ Complete |
| **[TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md)** | Bubble Tea app structure, models, views, updates | ✅ Complete |
| **[TECH_SPEC_API_CLIENT.md](./TECH_SPEC_API_CLIENT.md)** | HTTP client, JWT handling, retry logic | ✅ Complete |
| **[TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md)** | Configuration loading, wizard, persistence | ✅ Complete |
| **[TECH_SPEC_EVENT_TRIGGERING.md](./TECH_SPEC_EVENT_TRIGGERING.md)** | EventTrigger interface, local vs AGS implementations | ✅ Complete |
| **[TECH_SPEC_AUTHENTICATION.md](./TECH_SPEC_AUTHENTICATION.md)** | AuthProvider interface, AGS vs mock implementations | ✅ Complete |
| **[TECH_SPEC_CLI_MODE.md](./TECH_SPEC_CLI_MODE.md)** | Non-interactive CLI commands for automation | ✅ Complete |

---

## 🏗️ Technical Specifications Breakdown

### 1. TECH_SPEC_ARCHITECTURE.md

**Scope:** Overall system architecture and core interfaces.

**Contents:**
- Component diagram (TUI → API Client → Backend Service)
- Core interfaces: `APIClient`, `AuthProvider`, `EventTrigger`, `ConfigManager`
- Dependency injection pattern
- Error handling strategy
- Logging strategy

**Key Decisions:**
- Interface-driven design for testability
- Switch between local/AGS implementations via env vars
- All data fetched from running service (no direct DB access)

---

### 2. TECH_SPEC_TUI.md

**Scope:** Bubble Tea application structure and UI implementation.

**Contents:**
- Bubble Tea architecture (Elm pattern: Model, View, Update)
- Main app model and state management
- Screen models:
  - `DashboardModel` - Challenge list view
  - `EventSimulatorModel` - Event triggering panel
  - `DebugModel` - Debug panel with JSON inspector
- Keyboard input handling (key mappings)
- Screen transitions and navigation
- Styling with Lip Gloss (colors, borders, progress bars)

**Key Decisions:**
- Single-screen focus (no split panes in MVP)
- Modal dialogs for event simulator and config editor
- Shared styles in `styles.go`

---

### 3. TECH_SPEC_API_CLIENT.md

**Scope:** HTTP client for calling Challenge Service REST API.

**Contents:**
- `APIClient` interface definition
- HTTP client implementation with `net/http`
- JWT token management (attach to requests, auto-refresh)
- Retry logic (exponential backoff for 5xx errors)
- Request/response logging for debug mode
- Error handling and user-friendly error messages
- API method implementations:
  - `ListChallenges() ([]Challenge, error)`
  - `GetChallenge(id string) (*Challenge, error)`
  - `ClaimReward(challengeID, goalID string) error`

**Key Decisions:**
- Single HTTP client instance (reused across requests)
- Timeout: 10 seconds for API calls
- Retry up to 3 times for 5xx errors

---

### 4. TECH_SPEC_CONFIG.md

**Scope:** Configuration management and persistence.

**Contents:**
- Config file format (YAML)
- Config schema:
  ```yaml
  environment: local|staging|prod
  backend_url: http://localhost:8080
  iam_url: https://iam.accelbyte.io
  namespace: demo
  client_id: xxx
  client_secret: yyy (encrypted?)
  user_id: test-user-123
  auth_mode: ags|mock
  event_trigger_mode: local|ags
  ```
- Config loading (from file or env vars)
- First-time setup wizard (interactive prompts)
- Config validation (required fields, valid URLs)
- Config persistence (save to `~/.challenge-demo/config.yaml`)
- CLI flags for overrides (`--env prod --user test-user`)

**Key Decisions:**
- YAML format (human-readable, comments supported)
- Env vars override config file
- CLI flags override env vars
- Store credentials in plaintext for MVP (add encryption later)

---

### 5. TECH_SPEC_EVENT_TRIGGERING.md

**Scope:** Event triggering for testing progress updates.

**Contents:**
- `EventTrigger` interface:
  ```go
  type EventTrigger interface {
      TriggerLogin(ctx context.Context, userID string) error
      TriggerStatUpdate(ctx context.Context, userID, statCode string, value int) error
  }
  ```
- `LocalEventTrigger` implementation:
  - Calls event handler existing `OnMessage` RPC
  - Constructs AGS-compatible event payloads
  - No new endpoint needed - reuses existing infrastructure
- `AGSEventTrigger` implementation:
  - Publishes to AGS Event Bus (Kafka)
  - Constructs proper event payload (match AGS event schema)
  - Requires AGS credentials
- Factory pattern for creating correct implementation based on config
- Event payload construction (IAM login, Statistic update)

**Key Decisions:**
- Switch via `EVENT_TRIGGER_MODE` env var
- Default: `local` (for local development)
- Uses existing `OnMessage` RPC - no backend changes needed

**Dependencies on Backend:**
- ✅ None! Uses existing event handler OnMessage RPC

---

### 6. TECH_SPEC_AUTHENTICATION.md

**Scope:** Authentication with AGS IAM or mock auth for local dev.

**Contents:**
- `AuthProvider` interface:
  ```go
  type AuthProvider interface {
      Authenticate(ctx context.Context) (*Token, error)
      RefreshToken(ctx context.Context, token *Token) (*Token, error)
      GetToken() *Token
  }
  ```
- `AGSAuthProvider` implementation:
  - OAuth2 Client Credentials flow
  - Calls AGS IAM: `POST /oauth/token`
  - Token caching and auto-refresh (before expiration)
  - Error handling (invalid credentials, network errors)
- `MockAuthProvider` implementation:
  - Returns static JWT (valid for 1 hour)
  - No network calls
  - Useful for local dev without AGS
- Factory pattern for creating correct implementation based on config
- Token struct: `{AccessToken, ExpiresAt, RefreshToken}`

**Key Decisions:**
- Switch via `AUTH_MODE` env var
- Default: `ags` (real auth)
- Use `mock` for local dev without AGS IAM
- Auto-refresh token 5 minutes before expiration

---

### 7. TECH_SPEC_CLI_MODE.md

**Scope:** Non-interactive CLI commands for automation, scripting, and CI/CD integration.

**Contents:**
- Command structure using Cobra framework
- Available commands:
  - `list-challenges` - List all challenges with progress
  - `get-challenge <id>` - Get specific challenge details
  - `trigger-event login` - Trigger login event
  - `trigger-event stat-update` - Trigger stat update event
  - `claim-reward <cid> <gid>` - Claim reward for completed goal
  - `watch` - Continuous challenge monitoring
  - `tui` - Launch interactive TUI (default if no command)
- Output formatters:
  - `JSONFormatter` - Machine-readable (default)
  - `TableFormatter` - Human-readable table
  - `TextFormatter` - Human-readable text
- Global flags: `--backend-url`, `--auth-mode`, `--format`, `--user-id`, etc.
- Exit codes: 0=success, 1=error, 2=usage error
- Integration examples for automation and CI/CD

**Key Decisions:**
- Cobra for command structure
- TUI launches by default (no subcommand = TUI)
- JSON output by default for scripting
- Reuse existing API client, auth, events packages
- Commands return proper exit codes
- Support piping to `jq`, `grep`, etc.

**Use Cases:**
- Automation: Script test scenarios
- CI/CD: Automated testing in pipelines
- Quick operations: Single commands without TUI
- Monitoring: Continuous watch mode with logging

---

## 🔄 Development Workflow

### Phase-by-Phase Implementation

1. **Phase 1: Core UI & API Client** (1 day)
   - Tech Specs: ARCHITECTURE, TUI (basic), API_CLIENT
   - Deliverable: TUI that lists challenges

2. **Phase 2: Event Simulation** (1 day)
   - Tech Specs: EVENT_TRIGGERING
   - Deliverable: Trigger events from TUI

3. **Phase 3: Watch Mode & Claiming** (0.5 day)
   - Tech Specs: (no new specs, build on existing)
   - Deliverable: Auto-refresh and claim rewards

4. **Phase 4: Debug Tools & Polish** (0.5 day)
   - Tech Specs: (no new specs, build on existing)
   - Deliverable: Debug panel with JSON inspector

5. **Phase 5: Multi-Environment & Config** (0.5 day)
   - Tech Specs: CONFIG, AUTHENTICATION
   - Deliverable: Environment switching

6. **Phase 6: Build & Distribution** (0.5 day)
   - Tech Specs: (deployment, not in scope for now)
   - Deliverable: Cross-platform binaries

---

## 📝 Open Questions Document

| Document | Purpose | Status |
|----------|---------|--------|
| **[TECH_SPEC_QUESTIONS.md](./TECH_SPEC_QUESTIONS.md)** | Technical questions to resolve during implementation | 🔄 TODO |

**What goes here:**
- Open implementation questions
- Trade-off decisions (performance vs simplicity)
- Library choices (which Bubble Tea components to use)
- Testing strategy
- Build and release process

---

## 🔗 Related Documentation

### Main Challenge Service Docs
- [../TECH_SPEC_M1.md](../TECH_SPEC_M1.md) - Challenge Service technical spec
- [../TECH_SPEC_API.md](../TECH_SPEC_API.md) - REST API endpoints
- [../TECH_SPEC_EVENT_PROCESSING.md](../TECH_SPEC_EVENT_PROCESSING.md) - Event handling

### Event Handler Service
- Event handler must expose test endpoint for local event triggering
- See TECH_SPEC_EVENT_TRIGGERING.md for requirements

---

## 🎯 Success Criteria

**Demo app is complete when:**
1. ✅ Developer can view challenges in TUI
2. ✅ Developer can trigger events (login, stat update)
3. ✅ Developer can claim rewards
4. ✅ Developer can switch environments (local/staging/prod)
5. ✅ Developer can view raw JSON in debug mode
6. ✅ App works with both local and AGS-deployed services
7. ✅ Cross-platform binaries available (Linux, macOS, Windows)

---

## 📦 Project Structure

```
extend-challenge-demo/
├── cmd/
│   └── challenge-demo/
│       └── main.go              # Entry point
├── internal/
│   ├── tui/                     # Bubble Tea UI (TECH_SPEC_TUI.md)
│   │   ├── app.go
│   │   ├── dashboard.go
│   │   ├── event_simulator.go
│   │   ├── debug.go
│   │   └── styles.go
│   ├── api/                     # API Client (TECH_SPEC_API_CLIENT.md)
│   │   ├── client.go
│   │   ├── challenges.go
│   │   └── auth.go
│   ├── auth/                    # Auth providers (TECH_SPEC_AUTHENTICATION.md)
│   │   ├── provider.go          # Interface
│   │   ├── ags_provider.go      # AGS OAuth2
│   │   └── mock_provider.go     # Mock for local dev
│   ├── events/                  # Event triggering (TECH_SPEC_EVENT_TRIGGERING.md)
│   │   ├── trigger.go           # Interface
│   │   ├── local_trigger.go     # gRPC call to event handler
│   │   └── ags_trigger.go       # AGS Event Bus
│   ├── config/                  # Config management (TECH_SPEC_CONFIG.md)
│   │   ├── config.go
│   │   └── wizard.go
│   └── models/
│       ├── challenge.go
│       └── event.go
├── go.mod
├── go.sum
├── Makefile
├── .goreleaser.yaml
└── README.md
```

---

## 🚀 Getting Started

### For Users
1. Download binary from GitHub Releases
2. Run `./challenge-demo`
3. Follow setup wizard
4. Start testing!

### For Developers
1. Read [DESIGN.md](./DESIGN.md) for high-level overview
2. Read tech specs (start with TECH_SPEC_ARCHITECTURE.md)
3. Set up Go development environment
4. Build: `make build`
5. Run: `./bin/challenge-demo`

---

## 📅 Last Updated

- **2025-10-20**: Created index, defined tech spec structure
- **2025-10-20**: Completed DESIGN.md

---

**Next Steps:**
1. Create TECH_SPEC_QUESTIONS.md for open implementation questions
2. Start writing TECH_SPEC_ARCHITECTURE.md (foundational spec)
3. Implement Phase 1 (Core UI & API Client)
