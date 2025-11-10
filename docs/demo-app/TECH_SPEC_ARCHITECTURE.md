# Challenge Demo App - Architecture Technical Specification

## Document Purpose

This technical specification defines the **overall architecture** of the Challenge Demo TUI application, including core interfaces, dependency injection, and how components interact.

**Related Documents:**
- [DESIGN.md](./DESIGN.md) - High-level design decisions
- [INDEX.md](./INDEX.md) - Documentation structure

---

## 1. Project Metadata

| Property | Value |
|----------|-------|
| **Module** | `github.com/AccelByte/extend-challenge/extend-challenge-demo-app` |
| **Binary Name** | `challenge-demo` |
| **Config Path** | `~/.challenge-demo/config.yaml` |
| **Go Version** | 1.21+ (match main project's `go.mod`) |

**Dependencies (Major):**
- Bubble Tea: Latest stable (pin at implementation)
- Viper: Latest stable (pin at implementation)
- AccelByte API Proto: Match event handler version
- gRPC: Compatible with AccelByte proto version

---

## 2. Architecture Overview

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Terminal UI (Bubble Tea)                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  Dashboard   │  │    Event     │  │    Debug     │      │
│  │    Model     │  │  Simulator   │  │    Panel     │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                     Application Core                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  APIClient   │  │ AuthProvider │  │EventTrigger  │      │
│  │  (interface) │  │ (interface)  │  │ (interface)  │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                  │                  │              │
│         ▼                  ▼                  ▼              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │HTTP Client   │  │AGS/Mock Auth │  │Local/AGS     │      │
│  │Implementation│  │Implementation│  │Event Trigger │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   External Services                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  Challenge   │  │   AGS IAM    │  │Event Handler │      │
│  │   Service    │  │    OAuth2    │  │ gRPC/AGS Bus │      │
│  │  (REST API)  │  │              │  │              │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Component Responsibilities

| Component | Responsibility | Key Interfaces |
|-----------|---------------|----------------|
| **TUI Layer** | User interface, keyboard input, rendering | Bubble Tea models |
| **Application Core** | Business logic, orchestration | APIClient, AuthProvider, EventTrigger |
| **Config** | Configuration loading, persistence | ConfigManager |
| **External Services** | Backend APIs, authentication, event bus | - |

---

## 3. Core Interfaces

### 2.1 APIClient Interface

**Purpose:** Abstract HTTP communication with Challenge Service REST API.

**Definition:**
```go
package api

import (
    "context"
    "time"
)

// APIClient defines methods for interacting with Challenge Service API
type APIClient interface {
    // ListChallenges retrieves all challenges with user progress
    ListChallenges(ctx context.Context) ([]Challenge, error)

    // GetChallenge retrieves a specific challenge by ID
    GetChallenge(ctx context.Context, challengeID string) (*Challenge, error)

    // ClaimReward claims a completed goal's reward
    ClaimReward(ctx context.Context, challengeID, goalID string) (*ClaimResult, error)

    // GetLastRequest returns the last HTTP request for debug mode
    GetLastRequest() *RequestDebugInfo

    // GetLastResponse returns the last HTTP response for debug mode
    GetLastResponse() *ResponseDebugInfo
}

// GetChallengesResponse wraps the list of challenges returned by the API
// Backend returns {"challenges": [...]}, not a direct array
type GetChallengesResponse struct {
    Challenges []Challenge `json:"challenges"`
}

// Challenge represents a challenge with goals and user progress
// JSON field names are camelCase (protojson format from gRPC-gateway)
type Challenge struct {
    ID          string `json:"challengeId"` // camelCase, not snake_case
    Name        string `json:"name"`
    Description string `json:"description"`
    Goals       []Goal `json:"goals"`
}

// Goal represents a goal within a challenge
// JSON field names are camelCase (protojson format from gRPC-gateway)
type Goal struct {
    ID            string      `json:"goalId"`        // camelCase
    Name          string      `json:"name"`
    Description   string      `json:"description"`
    Requirement   Requirement `json:"requirement"`   // Struct, not string
    Reward        Reward      `json:"reward"`
    Prerequisites []string    `json:"prerequisites"` // Array of prerequisite goal IDs
    Progress      int32       `json:"progress"`      // Current progress value
    Status        string      `json:"status"`        // not_started, in_progress, completed, claimed
    Locked        bool        `json:"locked"`        // Whether locked by prerequisites
    CompletedAt   string      `json:"completedAt"`   // RFC3339 timestamp or empty (camelCase)
    ClaimedAt     string      `json:"claimedAt"`     // RFC3339 timestamp or empty (camelCase)
}

// Requirement specifies what is needed to complete a goal
type Requirement struct {
    StatCode    string `json:"statCode"`    // Stat code to check (camelCase)
    Operator    string `json:"operator"`    // "gte", "lte", "eq"
    TargetValue int32  `json:"targetValue"` // Target value (camelCase)
}

// Reward represents a goal's reward
// JSON field names are camelCase (protojson format from gRPC-gateway)
type Reward struct {
    Type     string `json:"type"`     // ITEM or WALLET
    RewardID string `json:"rewardId"` // Item code or currency code (camelCase)
    Quantity int32  `json:"quantity"`
}

// ClaimResult represents the result of claiming a reward
// Matches the protobuf ClaimRewardResponse message (camelCase fields)
type ClaimResult struct {
    GoalID    string `json:"goalId"`    // camelCase
    Status    string `json:"status"`    // e.g., "claimed"
    Reward    Reward `json:"reward"`
    ClaimedAt string `json:"claimedAt"` // RFC3339 timestamp (camelCase)
}

// RequestDebugInfo contains debug information about the last HTTP request
type RequestDebugInfo struct {
    Method  string
    URL     string
    Headers map[string]string
    Body    string
    Time    time.Time
}

// ResponseDebugInfo contains debug information about the last HTTP response
type ResponseDebugInfo struct {
    StatusCode int
    Headers    map[string]string
    Body       string
    Duration   time.Duration
    Time       time.Time
}
```

**Implementations:**
- `HTTPAPIClient` - Real HTTP client (see TECH_SPEC_API_CLIENT.md)

**Design Rationale:**
- Interface allows for future mock implementation (for testing without backend)
- Debug info methods enable raw JSON inspection in debug mode
- Context support for cancellation and timeouts

---

### 2.2 AuthProvider Interface

**Purpose:** Abstract authentication with AGS IAM or mock auth.

**Definition:**
```go
package auth

import (
    "context"
    "time"
)

// AuthProvider handles authentication and token management
type AuthProvider interface {
    // Authenticate performs initial authentication and returns a token
    Authenticate(ctx context.Context) (*Token, error)

    // RefreshToken refreshes an existing token
    RefreshToken(ctx context.Context, token *Token) (*Token, error)

    // GetToken returns the current valid token (auto-refreshes if needed)
    GetToken(ctx context.Context) (*Token, error)

    // IsTokenValid checks if the current token is still valid
    IsTokenValid(token *Token) bool
}

// Token represents an authentication token
type Token struct {
    AccessToken  string
    TokenType    string    // Usually "Bearer"
    ExpiresAt    time.Time
    RefreshToken string    // Optional
}

// IsExpired checks if the token has expired
func (t *Token) IsExpired() bool {
    return time.Now().After(t.ExpiresAt)
}

// ExpiresIn returns the duration until token expiration
func (t *Token) ExpiresIn() time.Duration {
    return time.Until(t.ExpiresAt)
}
```

**Implementations:**
- `AGSAuthProvider` - Real OAuth2 Client Credentials flow (see TECH_SPEC_AUTHENTICATION.md)
- `MockAuthProvider` - Returns static JWT for local dev (see TECH_SPEC_AUTHENTICATION.md)

**Selection Logic:**
```go
func NewAuthProvider(config *Config) AuthProvider {
    switch config.AuthMode {
    case "ags":
        return NewAGSAuthProvider(config)
    case "mock":
        return NewMockAuthProvider()
    default:
        return NewAGSAuthProvider(config) // Default to real auth
    }
}
```

**Design Rationale:**
- `GetToken()` auto-refreshes if token is near expiration (5 minutes before)
- Supports both access token and refresh token (for OAuth2)
- `IsTokenValid()` allows checking without blocking

---

### 2.3 EventTrigger Interface

**Purpose:** Abstract event triggering for testing (local gRPC vs AGS Event Bus).

**Definition:**
```go
package events

import "context"

// EventTrigger handles triggering gameplay events for testing
type EventTrigger interface {
    // TriggerLogin simulates a user login event
    TriggerLogin(ctx context.Context, userID, namespace string) error

    // TriggerStatUpdate simulates a statistic update event
    TriggerStatUpdate(ctx context.Context, userID, namespace, statCode string, value int) error
}
```

**Implementations:**
- `LocalEventTrigger` - Calls event handler gRPC endpoint (see TECH_SPEC_EVENT_TRIGGERING.md)
- `AGSEventTrigger` - Publishes to AGS Event Bus (see TECH_SPEC_EVENT_TRIGGERING.md)

**Selection Logic:**
```go
func NewEventTrigger(config *Config) EventTrigger {
    switch config.EventTriggerMode {
    case "local":
        return NewLocalEventTrigger(config.EventHandlerURL)
    case "ags":
        return NewAGSEventTrigger(config)
    default:
        return NewLocalEventTrigger(config.EventHandlerURL) // Default to local
    }
}
```

**Design Rationale:**
- Simple interface with two event types (matches M1 scope)
- Context support for cancellation and timeouts
- No event history in interface (handled by TUI layer)

---

### 2.4 ConfigManager Interface

**Purpose:** Abstract configuration loading and persistence.

**Definition:**
```go
package config

import "os"

// ConfigManager handles loading and saving configuration
type ConfigManager interface {
    // Load loads configuration from file, env vars, and CLI flags
    Load() (*Config, error)

    // Save saves configuration to file
    Save(config *Config) error

    // Exists checks if a config file exists
    Exists() bool
}

// Config represents the application configuration
type Config struct {
    // Environment
    Environment string `yaml:"environment"` // local, staging, prod

    // API Configuration
    BackendURL string `yaml:"backend_url"`
    IAMURL     string `yaml:"iam_url"`
    Namespace  string `yaml:"namespace"`

    // Authentication
    ClientID     string `yaml:"client_id"`
    ClientSecret string `yaml:"client_secret"`
    UserID       string `yaml:"user_id"`
    AuthMode     string `yaml:"auth_mode"` // ags or mock

    // Event Triggering
    EventHandlerURL   string `yaml:"event_handler_url"` // For local mode
    EventTriggerMode  string `yaml:"event_trigger_mode"` // local or ags

    // UI Preferences (optional)
    AutoRefresh       bool `yaml:"auto_refresh"`
    RefreshInterval   int  `yaml:"refresh_interval"` // seconds
}

// DefaultConfig returns a config with sensible defaults
func DefaultConfig() *Config {
    return &Config{
        Environment:      "local",
        BackendURL:       "http://localhost:8080",
        IAMURL:           "https://demo.accelbyte.io/iam",
        Namespace:        "demo",
        UserID:           "test-user",
        AuthMode:         "ags",
        EventHandlerURL:  "localhost:6566",
        EventTriggerMode: "local",
        AutoRefresh:      false,
        RefreshInterval:  2,
    }
}

// Validate checks if the config is valid
func (c *Config) Validate() error {
    if c.BackendURL == "" {
        return ErrMissingBackendURL
    }
    if c.Namespace == "" {
        return ErrMissingNamespace
    }
    if c.UserID == "" {
        return ErrMissingUserID
    }
    if c.AuthMode == "ags" && (c.ClientID == "" || c.ClientSecret == "") {
        return ErrMissingCredentials
    }
    return nil
}
```

**Implementation:**
- Uses Viper library for loading (see TECH_SPEC_CONFIG.md)

**Design Rationale:**
- Supports multiple config sources (file, env vars, CLI flags)
- YAML format for human-readability
- Validation ensures required fields are present

---

## 4. Dependency Injection

### 3.1 Application Container

**Purpose:** Central container for all dependencies.

**Definition:**
```go
package app

import (
    "context"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/auth"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/config"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/events"
)

// Container holds all application dependencies
type Container struct {
    Config        *config.Config
    APIClient     api.APIClient
    AuthProvider  auth.AuthProvider
    EventTrigger  events.EventTrigger
}

// NewContainer creates a new dependency container
func NewContainer(cfg *config.Config) (*Container, error) {
    // Create auth provider
    authProvider := auth.NewAuthProvider(cfg)

    // Authenticate
    ctx := context.Background()
    token, err := authProvider.Authenticate(ctx)
    if err != nil {
        return nil, fmt.Errorf("authentication failed: %w", err)
    }

    // Create API client with authenticated token
    apiClient := api.NewHTTPAPIClient(cfg.BackendURL, authProvider)

    // Create event trigger
    eventTrigger := events.NewEventTrigger(cfg)

    return &Container{
        Config:       cfg,
        APIClient:    apiClient,
        AuthProvider: authProvider,
        EventTrigger: eventTrigger,
    }, nil
}
```

**Usage in main.go:**
```go
func main() {
    // Load config
    configMgr := config.NewViperConfigManager()
    cfg, err := configMgr.Load()
    if err != nil {
        log.Fatal(err)
    }

    // Create container
    container, err := app.NewContainer(cfg)
    if err != nil {
        log.Fatal(err)
    }

    // Create TUI app
    tuiApp := tui.NewApp(container)

    // Run
    if err := tuiApp.Run(); err != nil {
        log.Fatal(err)
    }
}
```

**Design Rationale:**
- Single place to initialize all dependencies
- Easy to swap implementations (via interfaces)
- Simplifies testing (inject mocks)

---

### 3.2 TUI Integration

**How TUI receives dependencies:**

```go
package tui

import tea "github.com/charmbracelet/bubbletea"

// App is the root Bubble Tea application
type App struct {
    container *app.Container
}

// NewApp creates a new TUI app with dependencies
func NewApp(container *app.Container) *App {
    return &App{
        container: container,
    }
}

// Run starts the TUI application
func (a *App) Run() error {
    // Create initial model with dependencies
    model := NewAppModel(a.container)

    // Start Bubble Tea program
    p := tea.NewProgram(model, tea.WithAltScreen())
    _, err := p.Run()
    return err
}
```

**Models receive dependencies:**
```go
type AppModel struct {
    container       *app.Container
    currentScreen   Screen
    dashboardModel  *DashboardModel
    eventSimModel   *EventSimulatorModel
    debugModel      *DebugModel
}

func NewAppModel(container *app.Container) AppModel {
    return AppModel{
        container:      container,
        currentScreen:  ScreenDashboard,
        dashboardModel: NewDashboardModel(container.APIClient),
        eventSimModel:  NewEventSimulatorModel(container.EventTrigger, container.Config),
        debugModel:     NewDebugModel(container.APIClient),
    }
}
```

**Design Rationale:**
- Container passed to TUI at startup
- Each screen model receives only what it needs (API client, event trigger, etc.)
- Models don't need to know about factory functions or config details

---

## 5. Error Handling Strategy

### 4.1 Error Types

**Domain Errors:**
```go
package errors

import "errors"

// API Errors
var (
    ErrUnauthorized     = errors.New("unauthorized: invalid or expired token")
    ErrNotFound         = errors.New("resource not found")
    ErrAlreadyClaimed   = errors.New("reward already claimed")
    ErrNotCompleted     = errors.New("goal not completed")
    ErrNetworkTimeout   = errors.New("network timeout")
    ErrServerError      = errors.New("server error")
)

// Config Errors
var (
    ErrMissingBackendURL   = errors.New("backend URL is required")
    ErrMissingNamespace    = errors.New("namespace is required")
    ErrMissingUserID       = errors.New("user ID is required")
    ErrMissingCredentials  = errors.New("client ID and secret required for AGS auth")
    ErrInvalidConfig       = errors.New("invalid configuration")
)

// Auth Errors
var (
    ErrAuthFailed      = errors.New("authentication failed")
    ErrInvalidToken    = errors.New("invalid token")
    ErrTokenExpired    = errors.New("token expired")
)

// Event Errors
var (
    ErrEventFailed     = errors.New("event trigger failed")
    ErrInvalidEvent    = errors.New("invalid event type or parameters")
)
```

### 4.2 Error Wrapping

**Use `fmt.Errorf` with `%w` for context:**

```go
func (c *HTTPAPIClient) ListChallenges(ctx context.Context) ([]Challenge, error) {
    resp, err := c.doRequest(ctx, "GET", "/v1/challenges", nil)
    if err != nil {
        return nil, fmt.Errorf("list challenges: %w", err)
    }
    // ...
}
```

**Check for specific errors in TUI:**
```go
func (m DashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case ChallengesLoadedMsg:
        if msg.err != nil {
            if errors.Is(msg.err, apierrors.ErrUnauthorized) {
                return m, showErrorMsg("Authentication failed. Please check credentials.")
            }
            return m, showErrorMsg("Failed to load challenges: " + msg.err.Error())
        }
        // ...
    }
}
```

### 4.3 User-Facing Error Messages

**Principles:**
1. **Simple by default:** "Failed to load challenges"
2. **Actionable:** "Authentication failed. Please check credentials in config."
3. **Detailed in debug mode:** Show full error chain

**Example:**
```go
// Simple mode
errorMsg := "Failed to claim reward"

// Debug mode
errorMsg := fmt.Sprintf(
    "Failed to claim reward\nError: %v\nRequest: POST /v1/challenges/%s/goals/%s/claim\nStatus: %d",
    err, challengeID, goalID, statusCode,
)
```

---

## 6. Logging Strategy

### 5.1 Logger Interface

**Definition:**
```go
package logging

type Logger interface {
    Debug(msg string, fields ...Field)
    Info(msg string, fields ...Field)
    Warn(msg string, fields ...Field)
    Error(msg string, fields ...Field)
}

type Field struct {
    Key   string
    Value interface{}
}

func F(key string, value interface{}) Field {
    return Field{Key: key, Value: value}
}
```

### 5.2 Implementation

**Use `log/slog` (Go 1.21+):**

```go
package logging

import "log/slog"

type SlogLogger struct {
    logger *slog.Logger
}

func NewSlogLogger() *SlogLogger {
    return &SlogLogger{
        logger: slog.Default(),
    }
}

func (l *SlogLogger) Info(msg string, fields ...Field) {
    l.logger.Info(msg, fieldsToAttrs(fields)...)
}

func fieldsToAttrs(fields []Field) []any {
    attrs := make([]any, 0, len(fields)*2)
    for _, f := range fields {
        attrs = append(attrs, f.Key, f.Value)
    }
    return attrs
}
```

### 5.3 Logging in Components

**API Client Example:**
```go
func (c *HTTPAPIClient) ListChallenges(ctx context.Context) ([]Challenge, error) {
    c.logger.Debug("listing challenges", logging.F("url", c.baseURL+"/v1/challenges"))

    resp, err := c.doRequest(ctx, "GET", "/v1/challenges", nil)
    if err != nil {
        c.logger.Error("failed to list challenges", logging.F("error", err))
        return nil, err
    }

    c.logger.Info("challenges loaded", logging.F("count", len(challenges)))
    return challenges, nil
}
```

**Log Levels:**
- **DEBUG:** HTTP requests, state transitions
- **INFO:** User actions (claim reward, trigger event)
- **WARN:** Retries, near-expiration tokens
- **ERROR:** API failures, auth failures

**Log Output:**
- Default: Write to `~/.challenge-demo/debug.log`
- Option: `--log-level debug` to increase verbosity
- TUI doesn't show logs by default (use debug panel for API inspection)

---

## 7. Concurrency Model

### 6.1 Bubble Tea Commands

**Bubble Tea uses commands for async operations:**

```go
// Command to fetch challenges
func fetchChallengesCmd(apiClient api.APIClient) tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        challenges, err := apiClient.ListChallenges(ctx)
        return ChallengesLoadedMsg{challenges: challenges, err: err}
    }
}

// Message sent when challenges are loaded
type ChallengesLoadedMsg struct {
    challenges []api.Challenge
    err        error
}
```

### 6.2 Token Auto-Refresh

**Use `tea.Tick` to periodically check token expiration:**

```go
func tokenRefreshTickCmd() tea.Cmd {
    return tea.Tick(time.Minute, func(t time.Time) tea.Msg {
        return TickMsg{time: t}
    })
}

type TickMsg struct {
    time time.Time
}

func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case TickMsg:
        // Check if token is expiring soon (within 5 minutes)
        token := m.container.AuthProvider.GetToken(context.Background())
        if token.ExpiresIn() < 5*time.Minute {
            return m, refreshTokenCmd(m.container.AuthProvider)
        }
        return m, tokenRefreshTickCmd() // Schedule next tick
    }
}
```

### 6.3 Concurrency Rules

**Rules:**
1. **No goroutines in models:** Use Bubble Tea commands instead
2. **Context with timeout:** All API calls use context with 10s timeout
3. **Cancellation:** Cancel pending requests when switching screens (future enhancement)
4. **Single token refresh:** Only one token refresh in flight at a time

---

## 8. Testing Strategy

### 7.1 Unit Tests

**Test each interface implementation in isolation:**

```go
func TestHTTPAPIClient_ListChallenges(t *testing.T) {
    // Create mock HTTP server
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode([]api.Challenge{
            {ID: "test-challenge", Name: "Test Challenge"},
        })
    }))
    defer server.Close()

    // Create client
    client := api.NewHTTPAPIClient(server.URL, mockAuthProvider)

    // Test
    challenges, err := client.ListChallenges(context.Background())
    assert.NoError(t, err)
    assert.Len(t, challenges, 1)
    assert.Equal(t, "test-challenge", challenges[0].ID)
}
```

### 7.2 Integration Tests

**Test TUI with mock implementations:**

```go
func TestDashboard_LoadChallenges(t *testing.T) {
    // Create mock API client
    mockClient := &MockAPIClient{
        challenges: []api.Challenge{
            {ID: "test", Name: "Test"},
        },
    }

    // Create container with mock
    container := &app.Container{
        APIClient: mockClient,
    }

    // Create model
    model := tui.NewDashboardModel(container.APIClient)

    // Simulate loading
    msg := tui.ChallengesLoadedMsg{Challenges: mockClient.challenges}
    newModel, _ := model.Update(msg)

    // Assert state
    assert.Len(t, newModel.Challenges, 1)
}
```

### 7.3 Mock Implementations

**Create mocks for each interface:**

```go
type MockAPIClient struct {
    challenges []api.Challenge
    claimErr   error
}

func (m *MockAPIClient) ListChallenges(ctx context.Context) ([]api.Challenge, error) {
    return m.challenges, nil
}

func (m *MockAPIClient) ClaimReward(ctx context.Context, challengeID, goalID string) (*api.ClaimResult, error) {
    if m.claimErr != nil {
        return nil, m.claimErr
    }
    return &api.ClaimResult{Success: true}, nil
}
```

---

## 9. Project Structure (Detailed)

```
extend-challenge-demo/
├── cmd/
│   └── challenge-demo/
│       └── main.go                  # Entry point, creates container
│
├── internal/
│   ├── app/
│   │   └── container.go             # Dependency injection container
│   │
│   ├── api/                         # API Client (TECH_SPEC_API_CLIENT.md)
│   │   ├── client.go                # APIClient interface
│   │   ├── http_client.go           # HTTP implementation
│   │   ├── models.go                # Challenge, Goal, Reward structs
│   │   └── client_test.go
│   │
│   ├── auth/                        # Authentication (TECH_SPEC_AUTHENTICATION.md)
│   │   ├── provider.go              # AuthProvider interface
│   │   ├── ags_provider.go          # AGS OAuth2 implementation
│   │   ├── mock_provider.go         # Mock for local dev
│   │   └── provider_test.go
│   │
│   ├── events/                      # Event Triggering (TECH_SPEC_EVENT_TRIGGERING.md)
│   │   ├── trigger.go               # EventTrigger interface
│   │   ├── local_trigger.go         # gRPC implementation
│   │   ├── ags_trigger.go           # AGS Event Bus implementation
│   │   └── trigger_test.go
│   │
│   ├── config/                      # Configuration (TECH_SPEC_CONFIG.md)
│   │   ├── config.go                # Config struct and validation
│   │   ├── manager.go               # ConfigManager interface
│   │   ├── viper_manager.go         # Viper implementation
│   │   ├── wizard.go                # First-time setup wizard
│   │   └── config_test.go
│   │
│   ├── tui/                         # Terminal UI (TECH_SPEC_TUI.md)
│   │   ├── app.go                   # Main Bubble Tea app
│   │   ├── model.go                 # Root model
│   │   ├── dashboard.go             # Dashboard screen
│   │   ├── event_simulator.go       # Event simulator screen
│   │   ├── debug.go                 # Debug panel
│   │   ├── styles.go                # Lip Gloss styles
│   │   ├── keys.go                  # Keyboard mappings
│   │   ├── commands.go              # Bubble Tea commands
│   │   └── messages.go              # Custom messages
│   │
│   ├── errors/
│   │   └── errors.go                # Domain-specific errors
│   │
│   └── logging/
│       ├── logger.go                # Logger interface
│       └── slog_logger.go           # slog implementation
│
├── go.mod
├── go.sum
├── Makefile
├── .goreleaser.yaml
└── README.md
```

---

## 10. Build and Release

### 9.1 Makefile Targets

```makefile
.PHONY: build test lint run clean

build:
	@echo "Building challenge-demo..."
	@go build -o bin/challenge-demo cmd/challenge-demo/main.go

test:
	@echo "Running tests..."
	@go test -v -race -coverprofile=coverage.out ./...

lint:
	@echo "Running linter..."
	@golangci-lint run ./...

run:
	@echo "Running challenge-demo..."
	@go run cmd/challenge-demo/main.go

clean:
	@echo "Cleaning..."
	@rm -rf bin/ dist/ coverage.out
```

### 9.2 GoReleaser Configuration

```yaml
# .goreleaser.yaml
builds:
  - id: challenge-demo
    main: ./cmd/challenge-demo
    binary: challenge-demo
    env:
      - CGO_ENABLED=0
    goos:
      - linux
      - darwin
      - windows
    goarch:
      - amd64
      - arm64

archives:
  - format: tar.gz
    name_template: "challenge-demo_{{ .Version }}_{{ .Os }}_{{ .Arch }}"
    format_overrides:
      - goos: windows
        format: zip

checksum:
  name_template: "checksums.txt"

release:
  github:
    owner: yourusername
    name: challenge-demo
```

---

## 11. Dependencies

### 10.1 Direct Dependencies

```go
// go.mod
module github.com/AccelByte/extend-challenge/extend-challenge-demo-app

go 1.21

require (
    github.com/charmbracelet/bubbletea v0.25.0
    github.com/charmbracelet/lipgloss v0.9.1
    github.com/charmbracelet/bubbles v0.17.1
    github.com/spf13/viper v1.18.0
    github.com/atotto/clipboard v0.1.4
    golang.org/x/oauth2 v0.15.0
    google.golang.org/grpc v1.60.0
)
```

### 10.2 Dependency Justification

| Library | Purpose | Alternatives Considered |
|---------|---------|------------------------|
| **bubbletea** | TUI framework | tview (less idiomatic), termui (less active) |
| **lipgloss** | Terminal styling | Manual ANSI codes (error-prone) |
| **bubbles** | UI components | Build from scratch (slower) |
| **viper** | Config management | Manual YAML parsing (more code) |
| **clipboard** | Copy to clipboard | Manual exec (platform-specific) |
| **oauth2** | OAuth2 client | Manual HTTP (reinventing wheel) |
| **grpc** | gRPC client | HTTP/JSON (event handler uses gRPC) |

---

## 11. Security Considerations

### 11.1 Credential Storage

**Current Approach (MVP):**
- Store credentials in plaintext YAML file
- Set file permissions to `0600` (owner read/write only)
- Warn user if permissions are too open

**Future Enhancement:**
- Encrypt credentials using OS keychain (keyring library)
- Prompt for credentials at runtime (no storage)

### 11.2 Token Handling

**Security Measures:**
- Never log full token (log first 8 chars only)
- Auto-refresh before expiration (no stale tokens)
- Clear token on exit (future enhancement)

### 11.3 Environment Detection

**Production Warning:**
```go
if cfg.Environment == "prod" {
    fmt.Println("⚠️  WARNING: You are connecting to PRODUCTION environment!")
    fmt.Print("Continue? (y/N): ")
    var confirm string
    fmt.Scanln(&confirm)
    if confirm != "y" && confirm != "Y" {
        os.Exit(0)
    }
}
```

---

## 12. Performance Considerations

### 12.1 API Call Optimization

**Principles:**
1. **Cache challenges:** Don't refetch unless user triggers refresh
2. **Debounce refresh:** In watch mode, wait 2 seconds between fetches
3. **Cancel pending requests:** When switching screens (future)

### 12.2 TUI Rendering

**Optimization:**
- Use `lipgloss.Render()` caching (automatic)
- Only re-render on state change (Bubble Tea handles this)
- Avoid expensive operations in `View()` method

---

## 13. Observability

### 13.1 Metrics (Future)

**Potential Metrics:**
- API call latency (p50, p95, p99)
- API success rate
- Token refresh frequency
- User actions (events triggered, rewards claimed)

**Implementation:** Not in MVP scope, add later if needed.

### 13.2 Debug Mode

**Current Approach:**
- Store last 10 HTTP requests/responses in memory
- Display in debug panel (press 'd')
- Copy JSON/curl for manual reproduction

---

## 14. Future Enhancements

### Phase 7+ (Post-MVP)

1. **CLI Mode:** Support headless commands (`challenge-demo list --output json`)
2. **Split Pane:** Show challenges + debug side-by-side
3. **Log Streaming:** Tail event handler logs in TUI
4. **Offline Demo Mode:** Mock API client with sample data
5. **Config Encryption:** Use OS keychain for credentials
6. **Request Cancellation:** Cancel pending requests when switching screens

---

## 15. Related Documents

- **[DESIGN.md](./DESIGN.md)** - Design decisions and user flows
- **[INDEX.md](./INDEX.md)** - Documentation structure
- **[TECH_SPEC_API_CLIENT.md](./TECH_SPEC_API_CLIENT.md)** - HTTP client implementation
- **[TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md)** - Bubble Tea app structure
- **[TECH_SPEC_EVENT_TRIGGERING.md](./TECH_SPEC_EVENT_TRIGGERING.md)** - Event trigger implementations
- **[TECH_SPEC_AUTHENTICATION.md](./TECH_SPEC_AUTHENTICATION.md)** - Auth provider implementations
- **[TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md)** - Configuration management

---

## 16. Summary

**Key Architectural Decisions:**

1. **Interface-Driven:** All external dependencies (API, auth, events) abstracted behind interfaces
2. **Dependency Injection:** Container pattern for managing dependencies
3. **Bubble Tea:** Elm architecture for predictable state management
4. **No Offline Mode:** Always requires running backend service (Option A from design questions)
5. **Swappable Implementations:** Switch between local/AGS via env vars

**Benefits:**
- ✅ Testable (mock interfaces)
- ✅ Flexible (swap implementations)
- ✅ Maintainable (clear separation of concerns)
- ✅ Idiomatic Go (follows community best practices)

**Next Steps:**
1. Review and approve this architecture spec
2. Create remaining tech specs (API Client, TUI, Events, Auth, Config)
3. Begin implementation (Phase 1: Core UI & API Client)

---

**Document Version:** 1.0
**Last Updated:** 2025-10-20
**Status:** ✅ Ready for Review
