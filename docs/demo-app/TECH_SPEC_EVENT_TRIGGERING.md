# Challenge Demo App - Event Triggering Technical Specification

## Document Purpose

This technical specification defines the **EventTrigger interface** and its implementations for triggering test events (local gRPC vs AGS Event Bus).

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - Core interfaces
- [../TECH_SPEC_EVENT_PROCESSING.md](../TECH_SPEC_EVENT_PROCESSING.md) - Event handler event processing

---

## 1. Overview

### 1.1 Purpose

The Event Trigger component allows the demo app to **simulate gameplay events** for testing challenge progress without deploying a full game client.

**Three Modes:**
1. **Local Mode (`local`):** Direct gRPC call to event handler OnMessage (for local development)
2. **AGS gRPC Mode (`ags-grpc`):** Direct gRPC call to event handler OnMessage (if accessible in AGS)
3. **AGS SDK Mode (`ags-sdk`):** Use AccelByte Go SDK to update user statistics, which triggers real statistic update events

**Configuration:** Switch modes via `EVENT_TRIGGER_MODE` env var (`local`, `ags-grpc`, or `ags-sdk`).

**Implementation Note:**
- **gRPC Modes:** For local development and testing, we use **direct gRPC calls to OnMessage RPC** which bypasses Kafka and tests the event handler logic directly.
- **SDK Mode:** For production-like testing with AGS, we use the **AccelByte Go SDK's statistic service** to update user stats, which triggers real statistic update events that flow through Kafka to the event handler.
- **Important:** Direct Kafka publishing is **not supported** - AGS Kafka is only accessible to AGS services themselves.

---

### 1.2 Interface (from TECH_SPEC_ARCHITECTURE.md)

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

---

### 1.3 Port Configuration

**Docker Compose Port Mapping (Local Development):**

The docker-compose setup maps internal container ports to different host ports to avoid conflicts:

| Service | Internal Port | Host Port | Description |
|---------|--------------|-----------|-------------|
| challenge-service | 6565 | 6565 | REST API (gRPC Gateway) |
| challenge-event-handler | 6565 | **6566** | Event Handler gRPC |
| challenge-service | 8000 | 8000 | gRPC Gateway HTTP |
| challenge-event-handler | 8080 | 8081 | Prometheus metrics |

**⚠️ IMPORTANT:** When connecting to the event handler from the demo app running on the host:
- ✅ Use `localhost:6566` (event handler gRPC)
- ❌ Don't use `localhost:6565` (that's the service REST API, not the event handler!)

**Default Configuration:**
```go
eventHandlerURL := "localhost:6566"  // Correct port for local development
```

See `docker-compose.yml` lines 63-64 for port mapping details.

---

## 2. Local Event Trigger (gRPC)

### 2.1 LocalEventTrigger Implementation

**Calls event handler OnMessage via gRPC:**

```go
package events

import (
    "context"
    "encoding/json"
    "fmt"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"

    pb "github.com/AccelByte/accelbyte-api-proto/asyncapi/accelbyte/event/event/v1"
)

// LocalEventTrigger triggers events by calling event handler OnMessage
type LocalEventTrigger struct {
    conn   *grpc.ClientConn
    client pb.EventClient
}

// NewLocalEventTrigger creates a new local event trigger
func NewLocalEventTrigger(eventHandlerAddr string) (*LocalEventTrigger, error) {
    // Connect to event handler
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    conn, err := grpc.DialContext(ctx, eventHandlerAddr,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithBlock(),
    )
    if err != nil {
        return nil, fmt.Errorf("failed to connect to event handler: %w", err)
    }

    client := pb.NewEventClient(conn)

    return &LocalEventTrigger{
        conn:   conn,
        client: client,
    }, nil
}

// Close closes the gRPC connection
func (t *LocalEventTrigger) Close() error {
    return t.conn.Close()
}
```

**Key Points:**
- Uses AccelByte's official Event proto (`accelbyte-api-proto`)
- Calls existing `OnMessage` RPC (same as Kafka events would trigger)
- Constructs AGS-compatible event payloads
- No need for separate test endpoint

---

### 2.2 TriggerLogin Implementation

**Call OnMessage with AGS IAM login event:**

```go
// TriggerLogin triggers a login event via OnMessage
func (t *LocalEventTrigger) TriggerLogin(ctx context.Context, userID, namespace string) error {
    // Construct AGS IAM login event payload
    // See: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/iam-account/
    payload := map[string]interface{}{
        "userId":    userID,
        "namespace": namespace,
    }

    payloadJSON, err := json.Marshal(payload)
    if err != nil {
        return fmt.Errorf("marshal payload: %w", err)
    }

    // Create Event message matching AGS format
    event := &pb.Event{
        Id:        generateEventID(),
        Name:      fmt.Sprintf("%s.iam.account.v1.userLoggedIn", namespace),
        Namespace: namespace,
        UserId:    userID,
        Timestamp: time.Now().Format(time.RFC3339),
        Payload:   payloadJSON,
    }

    // Call OnMessage
    _, err = t.client.OnMessage(ctx, &pb.MessageRequest{
        Event: event,
    })
    if err != nil {
        return fmt.Errorf("trigger login event failed: %w", err)
    }

    return nil
}

// generateEventID generates a unique event ID
func generateEventID() string {
    return fmt.Sprintf("demo-event-%d", time.Now().UnixNano())
}
```

**Event Schema:**
- **Event Name:** `{namespace}.iam.account.v1.userLoggedIn`
- **Payload:** `{"userId": "...", "namespace": "..."}`
- Matches AGS IAM login event format exactly

---

### 2.3 TriggerStatUpdate Implementation

**Call OnMessage with AGS Statistic update event:**

```go
// TriggerStatUpdate triggers a stat update event via OnMessage
func (t *LocalEventTrigger) TriggerStatUpdate(ctx context.Context, userID, namespace, statCode string, value int) error {
    // Construct AGS Statistic update event payload
    // See: https://docs.accelbyte.io/gaming-services/knowledge-base/api-events/social-statistic/
    payload := map[string]interface{}{
        "userId":    userID,
        "namespace": namespace,
        "statCode":  statCode,
        "value":     value,
    }

    payloadJSON, err := json.Marshal(payload)
    if err != nil {
        return fmt.Errorf("marshal payload: %w", err)
    }

    // Create Event message matching AGS format
    event := &pb.Event{
        Id:        generateEventID(),
        Name:      fmt.Sprintf("%s.social.statistic.v1.statItemUpdated", namespace),
        Namespace: namespace,
        UserId:    userID,
        Timestamp: time.Now().Format(time.RFC3339),
        Payload:   payloadJSON,
    }

    // Call OnMessage
    _, err = t.client.OnMessage(ctx, &pb.MessageRequest{
        Event: event,
    })
    if err != nil {
        return fmt.Errorf("trigger stat update event failed: %w", err)
    }

    return nil
}
```

**Event Schema:**
- **Event Name:** `{namespace}.social.statistic.v1.statItemUpdated`
- **Payload:** `{"userId": "...", "namespace": "...", "statCode": "kills", "value": 10}`
- Matches AGS Statistic update event format exactly

---

### 2.4 AccelByte Event Proto

**Use official AccelByte proto definitions:**

The event handler service already imports and uses AccelByte's proto definitions:

```go
import pb "github.com/AccelByte/accelbyte-api-proto/asyncapi/accelbyte/event/event/v1"
```

**Key Message Types:**

```protobuf
// Event represents an AccelByte event
message Event {
  string id = 1;
  string name = 2;        // Event name (e.g., "demo.iam.account.v1.userLoggedIn")
  string namespace = 3;
  string user_id = 4;
  string timestamp = 5;   // RFC3339 format
  bytes payload = 6;      // JSON-encoded event payload
}

// MessageRequest wraps an event
message MessageRequest {
  Event event = 1;
}

// MessageResponse contains the processing result
message MessageResponse {
  bool success = 1;
  string message = 2;
}
```

**No need to define custom protos** - we reuse AccelByte's existing definitions.

---

## 4. SDK-Based Statistic Update (Alternative AGS Mode)

### 4.1 SDKStatUpdateTrigger Implementation

**Uses AccelByte Go SDK to update user statistics, triggering real events:**

```go
package events

import (
    "context"
    "fmt"

    "github.com/AccelByte/accelbyte-go-sdk/social-sdk/pkg/socialclient/user_statistic"
    "github.com/AccelByte/accelbyte-go-sdk/social-sdk/pkg/socialclientmodels"
    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/social"
    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/factory"
)

// SDKStatUpdateTrigger triggers statistic updates using AccelByte Go SDK
// This creates real statistic update events that flow through Kafka
type SDKStatUpdateTrigger struct {
    configRepo      factory.ConfigRepository
    tokenRepo       factory.TokenRepository
    userStatService social.UserStatisticService
}

// NewSDKStatUpdateTrigger creates a new SDK-based stat update trigger
func NewSDKStatUpdateTrigger(baseURL, clientID, clientSecret string) (*SDKStatUpdateTrigger, error) {
    configRepo := factory.NewConfigRepositoryImpl()
    configRepo.SetBaseURL(baseURL)
    configRepo.SetClientId(clientID)
    configRepo.SetClientSecret(clientSecret)

    tokenRepo := factory.NewTokenRepositoryImpl()

    userStatService := social.UserStatisticService{
        Client:          factory.NewSocialClient(configRepo),
        TokenRepository: tokenRepo,
    }

    return &SDKStatUpdateTrigger{
        configRepo:      configRepo,
        tokenRepo:       tokenRepo,
        userStatService: userStatService,
    }, nil
}
```

---

### 4.2 TriggerLogin Implementation (SDK)

**Note:** SDK doesn't directly trigger login events. Use gRPC method instead.

```go
// TriggerLogin is not supported in SDK mode - login events cannot be simulated via SDK
// Use LocalEventTrigger or AGSEventTrigger (gRPC) instead
func (t *SDKStatUpdateTrigger) TriggerLogin(ctx context.Context, userID, namespace string) error {
    return fmt.Errorf("login event trigger not supported in SDK mode, use gRPC mode instead")
}
```

---

### 4.3 TriggerStatUpdate Implementation (SDK)

**Update user statistic using SDK, triggering a real statistic update event:**

```go
// TriggerStatUpdate updates a user's statistic using the SDK
// This creates a real statistic update event that flows through Kafka to the event handler
func (t *SDKStatUpdateTrigger) TriggerStatUpdate(ctx context.Context, userID, namespace, statCode string, value int) error {
    // Prepare update request
    updateStrategy := "INCREMENT" // Can be OVERRIDE, INCREMENT, MAX, or MIN
    inc := float64(value)

    statUpdate := &socialclientmodels.StatItemInc{
        Inc:      &inc,
        StatCode: &statCode,
    }

    params := &user_statistic.UpdateUserStatItemValue1Params{
        Namespace:    namespace,
        StatCode:     statCode,
        UserID:       userID,
        Body:         statUpdate,
        Context:      ctx,
    }

    // Call SDK to update statistic
    result, err := t.userStatService.UpdateUserStatItemValue1Short(params)
    if err != nil {
        return fmt.Errorf("SDK stat update failed: %w", err)
    }

    if result.Response == nil {
        return fmt.Errorf("empty stat update response")
    }

    // The SDK call triggers a real statistic update event:
    // Event: {namespace}.social.statistic.v1.statItemUpdated
    // This event will be consumed by the event handler via Kafka

    return nil
}
```

**Key Benefits of SDK Approach:**
- **Real Event Flow**: Updates trigger actual events through Kafka
- **Production-like Testing**: Tests the full event pipeline
- **No Direct Event Handler Access Needed**: Works even if event handler gRPC is not exposed
- **Type-safe**: Uses SDK models for parameters and responses

**Limitations:**
- **Cannot trigger login events**: SDK doesn't provide login simulation
- **Requires AGS statistic service**: Statistic items must be configured in AGS admin portal
- **Auth required**: Needs valid service token with statistic update permissions

---

## 5. Factory Pattern

### 5.1 NewEventTrigger Factory

**Create appropriate implementation based on config:**

```go
package events

import (
    "fmt"
    "strings"

    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/config"
)

// NewEventTrigger creates an EventTrigger based on config
func NewEventTrigger(cfg *config.Config) (EventTrigger, error) {
    switch cfg.EventTriggerMode {
    case "local":
        // Direct gRPC to event handler OnMessage
        return NewLocalEventTrigger(cfg.EventHandlerURL)

    case "ags-grpc":
        // Direct gRPC to event handler OnMessage (if accessible in AGS)
        return NewLocalEventTrigger(cfg.EventHandlerURL)

    case "ags-sdk":
        // Use AccelByte Go SDK to update statistics (triggers real events)
        return NewSDKStatUpdateTrigger(
            cfg.IAMURL,
            cfg.ClientID,
            cfg.ClientSecret,
        )

    default:
        return nil, fmt.Errorf("invalid event trigger mode: %s (expected 'local', 'ags-grpc', or 'ags-sdk')", cfg.EventTriggerMode)
    }
}
```

---

## 6. Configuration

### 6.1 Config Fields

**Add to Config struct (from TECH_SPEC_CONFIG.md):**

```go
type Config struct {
    // ... other fields ...

    // Event Triggering
    EventTriggerMode  string `yaml:"event_trigger_mode"`  // "local", "ags-grpc", or "ags-sdk"
    EventHandlerURL   string `yaml:"event_handler_url"`   // For local/ags-grpc mode (e.g., "localhost:6566")

    // Note: Kafka brokers removed - direct Kafka publishing is not supported
}
```

### 6.2 Default Config

```go
func DefaultConfig() *Config {
    return &Config{
        // ... other defaults ...
        EventTriggerMode: "local",
        EventHandlerURL:  "localhost:6566",
    }
}
```

### 6.3 Config Validation

```go
func (c *Config) Validate() error {
    // ... other validations ...

    validModes := []string{"local", "ags-grpc", "ags-sdk"}
    validMode := false
    for _, mode := range validModes {
        if c.EventTriggerMode == mode {
            validMode = true
            break
        }
    }
    if !validMode {
        return fmt.Errorf("event_trigger_mode must be one of %v, got: %s", validModes, c.EventTriggerMode)
    }

    // Mode-specific validation
    switch c.EventTriggerMode {
    case "local", "ags-grpc":
        if c.EventHandlerURL == "" {
            return errors.New("event_handler_url required for local/ags-grpc mode")
        }

    case "ags-sdk":
        // SDK mode uses IAM URL, client ID, and client secret from main config
        // Validation happens in main config validation
    }

    return nil
}
```

---

## 6. No Special Event Handler Changes Needed

### 6.1 Using Existing OnMessage RPC

**The event handler service already has everything we need:**

✅ **OnMessage RPC** - Processes events from Kafka, same method works for local testing
✅ **AccelByte Event Proto** - Standard event format is already defined
✅ **Event Processing Logic** - Existing handlers work with both Kafka and gRPC inputs

**No modifications required** to the event handler service!

---

### 6.2 How It Works

**Event Flow:**

```
Demo App                    Event Handler
   │                              │
   │  1. Construct AGS Event     │
   │     (IAM login or Stat)     │
   │                              │
   │  2. Call OnMessage RPC      │
   ├────────────────────────────>│
   │                              │
   │                              │  3. Process like Kafka event
   │                              │  4. Update challenge progress
   │                              │
   │  5. Return success/error    │
   │<────────────────────────────┤
   │                              │
```

**Key Insight:** The event handler doesn't care if events come from Kafka or gRPC - both use the same `OnMessage` handler.

---

## 7. Error Handling

### 7.1 Error Types

```go
package events

import "errors"

var (
    ErrEventFailed     = errors.New("event trigger failed")
    ErrInvalidEvent    = errors.New("invalid event type or parameters")
    ErrConnectionFailed = errors.New("connection to event handler failed")
    ErrTimeout         = errors.New("event trigger timed out")
)
```

### 7.2 Error Handling in Implementations

**Wrap errors with context:**

```go
func (t *LocalEventTrigger) TriggerLogin(ctx context.Context, userID, namespace string) error {
    req := &pb.TriggerEventRequest{...}

    resp, err := t.client.TriggerEvent(ctx, req)
    if err != nil {
        // Check for specific gRPC errors
        if status.Code(err) == codes.DeadlineExceeded {
            return fmt.Errorf("%w: %v", ErrTimeout, err)
        }
        if status.Code(err) == codes.Unavailable {
            return fmt.Errorf("%w: %v", ErrConnectionFailed, err)
        }
        return fmt.Errorf("%w: %v", ErrEventFailed, err)
    }

    if !resp.Success {
        return fmt.Errorf("%w: %s", ErrEventFailed, resp.Message)
    }

    return nil
}
```

---

## 8. Testing

### 8.1 Unit Tests with Mock gRPC Server

**Test LocalEventTrigger:**

```go
func TestLocalEventTrigger_TriggerLogin(t *testing.T) {
    // Create mock gRPC server
    lis := bufconn.Listen(bufSize)
    s := grpc.NewServer()
    pb.RegisterTestEventServiceServer(s, &mockTestEventServer{})
    go s.Serve(lis)
    defer s.Stop()

    // Create client
    conn, _ := grpc.DialContext(context.Background(), "",
        grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
            return lis.Dial()
        }),
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    trigger := &LocalEventTrigger{
        conn:   conn,
        client: pb.NewTestEventServiceClient(conn),
    }

    // Test
    err := trigger.TriggerLogin(context.Background(), "test-user", "demo")
    assert.NoError(t, err)
}

type mockTestEventServer struct {
    pb.UnimplementedTestEventServiceServer
}

func (s *mockTestEventServer) TriggerEvent(ctx context.Context, req *pb.TriggerEventRequest) (*pb.TriggerEventResponse, error) {
    return &pb.TriggerEventResponse{
        Success: true,
        Message: "event processed",
    }, nil
}
```

---

### 8.2 Integration Tests

**Test with real event handler:**

```go
func TestLocalEventTrigger_Integration(t *testing.T) {
    // Skip if event handler not running
    if testing.Short() {
        t.Skip("skipping integration test")
    }

    trigger, err := NewLocalEventTrigger("localhost:6566")
    require.NoError(t, err)
    defer trigger.Close()

    // Trigger login
    err = trigger.TriggerLogin(context.Background(), "test-user", "demo")
    assert.NoError(t, err)

    // Trigger stat update
    err = trigger.TriggerStatUpdate(context.Background(), "test-user", "demo", "kills", 10)
    assert.NoError(t, err)
}
```

---

## 9. Usage Example

### 9.1 In TUI Event Simulator

```go
// In event simulator model

func (m *EventSimulatorModel) triggerEventCmd() tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()

        var err error
        startTime := time.Now()

        switch m.selectedType {
        case EventLogin:
            err = m.eventTrigger.TriggerLogin(ctx, m.config.UserID, m.config.Namespace)

        case EventStatUpdate:
            value, _ := strconv.Atoi(m.statValue)
            err = m.eventTrigger.TriggerStatUpdate(ctx, m.config.UserID, m.config.Namespace, m.statCode, value)
        }

        duration := time.Since(startTime)

        return EventTriggeredMsg{
            success:  err == nil,
            duration: duration,
            err:      err,
        }
    }
}
```

---

## 10. Dependencies

### 10.1 Go Packages

```go
// go.mod additions
require (
    // For gRPC modes (local, ags-grpc)
    google.golang.org/grpc v1.60.0
    google.golang.org/protobuf v1.32.0
    github.com/AccelByte/accelbyte-api-proto v0.0.0-latest

    // For SDK mode (ags-sdk)
    github.com/AccelByte/accelbyte-go-sdk/social-sdk v1.x.x
    github.com/AccelByte/accelbyte-go-sdk/services-api v1.x.x
)
```

### 10.2 AccelByte Proto Dependency

**No proto compilation needed** - we use AccelByte's pre-compiled protos:

```go
// Import for gRPC event messages
import pb "github.com/AccelByte/accelbyte-api-proto/asyncapi/accelbyte/event/event/v1"
```

**Import in code:**
```go
import pb "github.com/AccelByte/accelbyte-api-proto/asyncapi/accelbyte/event/event/v1"
```

---

## 11. Future Enhancements

### Phase 7+ (Post-MVP)

1. **Batch Event Triggering:** Trigger multiple events in one call
2. **Event Templates:** Pre-configured event scenarios (e.g., "complete combat challenge")
3. **Event Recording:** Record and replay event sequences for testing
4. **Custom Events:** Support for custom event types (beyond login/stat update)
5. **Event Validation:** Validate event payloads before sending

---

## 12. Summary

**Key Implementation Details:**

1. **EventTrigger Interface:** Unified interface for all triggering modes
2. **Local/AGS gRPC Modes:** Direct gRPC calls to event handler OnMessage
3. **AGS SDK Mode:** Uses AccelByte Go SDK to trigger real events
4. **Factory Pattern:** Config-driven implementation selection
5. **Event Compatibility:** Constructs AGS-compatible event payloads

**Configuration:**
- `EVENT_TRIGGER_MODE=local` → LocalEventTrigger (gRPC)
- `EVENT_TRIGGER_MODE=ags-grpc` → LocalEventTrigger (gRPC)
- `EVENT_TRIGGER_MODE=ags-sdk` → SDKStatUpdateTrigger (AccelByte Go SDK)

**Event Types Supported:**
- ✅ Login events (`{namespace}.iam.account.v1.userLoggedIn`)
- ✅ Stat update events (`{namespace}.social.statistic.v1.statItemUpdated`)

**Next Steps:**
1. Review and approve this spec
2. Implement LocalEventTrigger (Phase 2) - gRPC to OnMessage
3. Test with running event handler service
4. Implement SDKStatUpdateTrigger (Phase 3) - SDK-based stat updates

---

**Document Version:** 2.0 (Added SDK-based statistic update mode)
**Last Updated:** 2025-10-21
**Status:** ✅ Ready for Implementation

**Event Triggering Modes Summary:**

1. **Local Mode (`local`):**
   - Direct gRPC call to event handler OnMessage
   - Best for: Local development, unit testing event handler
   - Requirement: Event handler running locally

2. **AGS gRPC Mode (`ags-grpc`):**
   - Direct gRPC call to event handler OnMessage (if accessible)
   - Best for: Integration testing with deployed event handler
   - Requirement: Event handler gRPC endpoint accessible

3. **AGS SDK Mode (`ags-sdk`):**
   - Use AccelByte Go SDK to update user statistics
   - Triggers real statistic update events through Kafka
   - Best for: Production-like testing, end-to-end validation
   - Requirement: AGS statistic service, configured stat items
   - **Limitation:** Cannot trigger login events (use gRPC modes for that)

**Important Note:**
- ❌ **Direct Kafka publishing is NOT supported** - AGS Kafka is only accessible to AGS services
- ✅ Use gRPC modes for direct event handler testing
- ✅ Use SDK mode to trigger real events through AGS services

**Recommended Approach:**
- **Development:** Use `local` mode
- **Testing:** Use `ags-sdk` mode for statistic events, `local` or `ags-grpc` for login events
- **Production Simulation:** Use `ags-sdk` mode
