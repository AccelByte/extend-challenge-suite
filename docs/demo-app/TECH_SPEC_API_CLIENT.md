# Challenge Demo App - API Client Technical Specification

## Document Purpose

This technical specification defines the **HTTP API client** for communicating with the Challenge Service REST API, including request/response handling, JWT authentication, retry logic, and debug instrumentation.

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - Core interfaces and dependency injection
- [../TECH_SPEC_API.md](../TECH_SPEC_API.md) - Challenge Service REST API specification

---

## ⚠️ IMPORTANT: JSON Format Discovery

**The backend uses gRPC-gateway with protojson marshaling, which has critical implications:**

1. **Field Names are camelCase**, not snake_case:
   - `challengeId` (not `challenge_id`)
   - `goalId` (not `goal_id`)
   - `statCode` (not `stat_code`)
   - `targetValue` (not `target_value`)
   - `rewardId` (not `reward_id`)
   - `completedAt` (not `completed_at`)
   - `claimedAt` (not `claimed_at`)

2. **Response is Wrapped**: `/v1/challenges` returns `{"challenges": [...]}`, not a direct array

3. **Timestamps are strings**, not objects: RFC3339 format or empty string

4. **Reference**: See `extend-challenge-service/pkg/pb/service.pb.go` for the generated protobuf types that define the JSON format via the `json=` directive in protobuf tags.

All model definitions in this spec reflect these findings.

---

## 1. Overview

### 1.1 Responsibilities

The API Client is responsible for:
- Making HTTP requests to Challenge Service endpoints
- Attaching JWT bearer tokens to requests
- Retrying failed requests (5xx errors)
- Recording request/response data for debug mode
- Deserializing JSON responses into Go structs
- Mapping HTTP errors to domain errors

### 1.2 Interface (from TECH_SPEC_ARCHITECTURE.md)

```go
type APIClient interface {
    ListChallenges(ctx context.Context) ([]Challenge, error)
    GetChallenge(ctx context.Context, challengeID string) (*Challenge, error)
    ClaimReward(ctx context.Context, challengeID, goalID string) (*ClaimResult, error)
    GetLastRequest() *RequestDebugInfo
    GetLastResponse() *ResponseDebugInfo
}
```

---

## 2. Implementation

### 2.1 HTTPAPIClient Struct

**Definition:**
```go
package api

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"

    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/auth"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/errors"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/logging"
)

// HTTPAPIClient implements APIClient using net/http
type HTTPAPIClient struct {
    baseURL      string
    httpClient   *http.Client
    authProvider auth.AuthProvider
    logger       logging.Logger

    // Debug instrumentation
    lastRequest  *RequestDebugInfo
    lastResponse *ResponseDebugInfo
}

// NewHTTPAPIClient creates a new HTTP API client
func NewHTTPAPIClient(baseURL string, authProvider auth.AuthProvider) *HTTPAPIClient {
    return &HTTPAPIClient{
        baseURL:      baseURL,
        httpClient:   &http.Client{Timeout: 10 * time.Second},
        authProvider: authProvider,
        logger:       logging.NewSlogLogger(),
    }
}
```

**Design Decisions:**
- **Single http.Client:** Reuse client for connection pooling
- **10-second timeout:** Prevent hanging requests
- **Auth provider injection:** Allows token refresh without client recreation

---

### 2.2 Core HTTP Method

**Base request method with retry logic:**

```go
// doRequest performs an HTTP request with retry logic
func (c *HTTPAPIClient) doRequest(ctx context.Context, method, path string, body interface{}) (*http.Response, error) {
    url := c.baseURL + path

    // Serialize body if provided
    var reqBody io.Reader
    if body != nil {
        jsonBytes, err := json.Marshal(body)
        if err != nil {
            return nil, fmt.Errorf("marshal request body: %w", err)
        }
        reqBody = bytes.NewReader(jsonBytes)
    }

    // Create request
    req, err := http.NewRequestWithContext(ctx, method, url, reqBody)
    if err != nil {
        return nil, fmt.Errorf("create request: %w", err)
    }

    // Set headers
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("Accept", "application/json")

    // Get auth token
    token, err := c.authProvider.GetToken(ctx)
    if err != nil {
        return nil, fmt.Errorf("get auth token: %w", err)
    }
    req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", token.AccessToken))

    // Record request for debug mode
    c.recordRequest(req, body)

    // Perform request with retry
    var resp *http.Response
    var lastErr error

    maxRetries := 3
    for attempt := 0; attempt < maxRetries; attempt++ {
        if attempt > 0 {
            // Exponential backoff: 1s, 2s, 4s
            backoff := time.Duration(1<<uint(attempt-1)) * time.Second
            c.logger.Warn("retrying request",
                logging.F("attempt", attempt),
                logging.F("backoff", backoff))
            time.Sleep(backoff)
        }

        startTime := time.Now()
        resp, lastErr = c.httpClient.Do(req)
        duration := time.Since(startTime)

        if lastErr != nil {
            c.logger.Error("request failed",
                logging.F("error", lastErr),
                logging.F("attempt", attempt))
            continue
        }

        // Record response for debug mode
        c.recordResponse(resp, duration)

        // Check status code
        if resp.StatusCode >= 500 {
            // Server error, retry
            c.logger.Warn("server error, retrying",
                logging.F("status", resp.StatusCode),
                logging.F("attempt", attempt))
            resp.Body.Close()
            lastErr = fmt.Errorf("server error: status %d", resp.StatusCode)
            continue
        }

        // Success or client error (don't retry)
        return resp, nil
    }

    // All retries exhausted
    return nil, fmt.Errorf("request failed after %d attempts: %w", maxRetries, lastErr)
}
```

**Retry Logic:**
- **Retry on:** 5xx errors, network errors
- **Don't retry:** 4xx errors (client errors)
- **Max retries:** 3
- **Backoff:** Exponential (1s, 2s, 4s)

---

### 2.3 ListChallenges Implementation

**Fetch all challenges with user progress:**

```go
// ListChallenges retrieves all challenges with user progress
func (c *HTTPAPIClient) ListChallenges(ctx context.Context) ([]Challenge, error) {
    c.logger.Debug("listing challenges")

    resp, err := c.doRequest(ctx, "GET", "/v1/challenges", nil)
    if err != nil {
        return nil, fmt.Errorf("list challenges: %w", err)
    }
    defer resp.Body.Close()

    // Check status code
    if err := c.checkStatusCode(resp); err != nil {
        return nil, err
    }

    // Decode response wrapper (backend returns {"challenges": [...]})
    var response GetChallengesResponse
    if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    c.logger.Info("challenges loaded", logging.F("count", len(response.Challenges)))
    return response.Challenges, nil
}
```

**Note:** The backend returns a response wrapper `{"challenges": [...]}`, not a direct array.

---

### 2.4 GetChallenge Implementation

**Fetch a specific challenge by ID:**

```go
// GetChallenge retrieves a specific challenge by ID
func (c *HTTPAPIClient) GetChallenge(ctx context.Context, challengeID string) (*Challenge, error) {
    c.logger.Debug("getting challenge", logging.F("challenge_id", challengeID))

    path := fmt.Sprintf("/v1/challenges/%s", challengeID)
    resp, err := c.doRequest(ctx, "GET", path, nil)
    if err != nil {
        return nil, fmt.Errorf("get challenge: %w", err)
    }
    defer resp.Body.Close()

    // Check status code
    if err := c.checkStatusCode(resp); err != nil {
        return nil, err
    }

    // Decode response
    var challenge Challenge
    if err := json.NewDecoder(resp.Body).Decode(&challenge); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    c.logger.Info("challenge loaded",
        logging.F("challenge_id", challengeID),
        logging.F("goal_count", len(challenge.Goals)))
    return &challenge, nil
}
```

---

### 2.5 ClaimReward Implementation

**Claim a completed goal's reward:**

```go
// ClaimReward claims a completed goal's reward
func (c *HTTPAPIClient) ClaimReward(ctx context.Context, challengeID, goalID string) (*ClaimResult, error) {
    c.logger.Info("claiming reward",
        logging.F("challenge_id", challengeID),
        logging.F("goal_id", goalID))

    path := fmt.Sprintf("/v1/challenges/%s/goals/%s/claim", challengeID, goalID)
    resp, err := c.doRequest(ctx, "POST", path, nil)
    if err != nil {
        return nil, fmt.Errorf("claim reward: %w", err)
    }
    defer resp.Body.Close()

    // Check status code
    if err := c.checkStatusCode(resp); err != nil {
        return nil, err
    }

    // Decode response
    var result ClaimResult
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    c.logger.Info("reward claimed",
        logging.F("challenge_id", challengeID),
        logging.F("goal_id", goalID),
        logging.F("reward_type", result.Reward.Type))
    return &result, nil
}
```

---

### 2.6 Status Code Handling

**Map HTTP status codes to domain errors:**

```go
// checkStatusCode checks the HTTP status code and returns appropriate error
func (c *HTTPAPIClient) checkStatusCode(resp *http.Response) error {
    switch resp.StatusCode {
    case http.StatusOK:
        return nil
    case http.StatusUnauthorized:
        return apierrors.ErrUnauthorized
    case http.StatusNotFound:
        return apierrors.ErrNotFound
    case http.StatusConflict:
        // Parse error message from response body
        var errResp struct {
            Error string `json:"error"`
        }
        if err := json.NewDecoder(resp.Body).Decode(&errResp); err == nil {
            if errResp.Error == "already_claimed" {
                return apierrors.ErrAlreadyClaimed
            }
            if errResp.Error == "not_completed" {
                return apierrors.ErrNotCompleted
            }
        }
        return fmt.Errorf("conflict: %s", errResp.Error)
    case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
        return apierrors.ErrServerError
    default:
        return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
    }
}
```

**Status Code Mapping:**

| HTTP Status | Domain Error | Retry? |
|-------------|--------------|--------|
| 200 OK | nil | - |
| 401 Unauthorized | `ErrUnauthorized` | No |
| 404 Not Found | `ErrNotFound` | No |
| 409 Conflict (already_claimed) | `ErrAlreadyClaimed` | No |
| 409 Conflict (not_completed) | `ErrNotCompleted` | No |
| 500-504 Server errors | `ErrServerError` | Yes (3x) |

---

## 3. Debug Instrumentation

### 3.1 Recording Requests

**Capture request details for debug mode:**

```go
// recordRequest captures request details for debug inspection
func (c *HTTPAPIClient) recordRequest(req *http.Request, body interface{}) {
    var bodyStr string
    if body != nil {
        bodyBytes, _ := json.Marshal(body)
        bodyStr = string(bodyBytes)
    }

    headers := make(map[string]string)
    for key, values := range req.Header {
        // Redact authorization header (show first 8 chars only)
        if key == "Authorization" && len(values) > 0 {
            if len(values[0]) > 16 {
                headers[key] = values[0][:16] + "..."
            } else {
                headers[key] = values[0]
            }
        } else {
            headers[key] = strings.Join(values, ", ")
        }
    }

    c.lastRequest = &RequestDebugInfo{
        Method:  req.Method,
        URL:     req.URL.String(),
        Headers: headers,
        Body:    bodyStr,
        Time:    time.Now(),
    }
}
```

---

### 3.2 Recording Responses

**Capture response details for debug mode:**

```go
// recordResponse captures response details for debug inspection
func (c *HTTPAPIClient) recordResponse(resp *http.Response, duration time.Duration) {
    headers := make(map[string]string)
    for key, values := range resp.Header {
        headers[key] = strings.Join(values, ", ")
    }

    // Read body for debug (must re-wrap for actual parsing)
    bodyBytes, _ := io.ReadAll(resp.Body)
    resp.Body.Close()
    resp.Body = io.NopCloser(bytes.NewReader(bodyBytes))

    c.lastResponse = &ResponseDebugInfo{
        StatusCode: resp.StatusCode,
        Headers:    headers,
        Body:       string(bodyBytes),
        Duration:   duration,
        Time:       time.Now(),
    }
}
```

**Note:** We read the body for debug, then re-wrap it so the caller can still read it.

---

### 3.3 Debug Info Getters

**Expose debug info to TUI:**

```go
// GetLastRequest returns debug info for the last HTTP request
func (c *HTTPAPIClient) GetLastRequest() *RequestDebugInfo {
    return c.lastRequest
}

// GetLastResponse returns debug info for the last HTTP response
func (c *HTTPAPIClient) GetLastResponse() *ResponseDebugInfo {
    return c.lastResponse
}
```

---

## 4. Data Models

**IMPORTANT:** All models use **camelCase** JSON field names because the backend uses gRPC-gateway with protojson marshaling, not standard Go JSON marshaling.

### 4.0 GetChallengesResponse Wrapper

```go
// GetChallengesResponse wraps the list of challenges returned by the API
// Backend returns {"challenges": [...]}, not a direct array
type GetChallengesResponse struct {
    Challenges []Challenge `json:"challenges"`
}
```

### 4.1 Challenge Model

```go
// Challenge represents a challenge with goals and user progress
// JSON field names are camelCase (protojson format from backend)
type Challenge struct {
    ID          string `json:"challengeId"` // Note: camelCase, not snake_case
    Name        string `json:"name"`
    Description string `json:"description"`
    Goals       []Goal `json:"goals"`
}

// ProgressPercentage calculates overall challenge progress (0-100)
func (c *Challenge) ProgressPercentage() int {
    if len(c.Goals) == 0 {
        return 0
    }

    completed := 0
    for _, goal := range c.Goals {
        if goal.Status == "completed" || goal.Status == "claimed" {
            completed++
        }
    }

    return (completed * 100) / len(c.Goals)
}

// CompletedGoalCount returns the number of completed goals
func (c *Challenge) CompletedGoalCount() int {
    count := 0
    for _, goal := range c.Goals {
        if goal.Status == "completed" || goal.Status == "claimed" {
            count++
        }
    }
    return count
}
```

---

### 4.2 Goal Model

```go
// Goal represents a goal within a challenge
// JSON field names are camelCase (protojson format from backend)
type Goal struct {
    ID            string      `json:"goalId"`      // Note: camelCase
    Name          string      `json:"name"`
    Description   string      `json:"description"`
    Requirement   Requirement `json:"requirement"` // Struct, not string
    Reward        Reward      `json:"reward"`
    Prerequisites []string    `json:"prerequisites"` // Array of prerequisite goal IDs
    Progress      int32       `json:"progress"`      // Current progress value
    Status        string      `json:"status"`        // not_started, in_progress, completed, claimed
    Locked        bool        `json:"locked"`        // Whether goal is locked by prerequisites
    CompletedAt   string      `json:"completedAt"`   // RFC3339 timestamp or empty (camelCase)
    ClaimedAt     string      `json:"claimedAt"`     // RFC3339 timestamp or empty (camelCase)
}

// Requirement specifies what is needed to complete a goal
type Requirement struct {
    StatCode    string `json:"statCode"`    // Stat code to check (camelCase)
    Operator    string `json:"operator"`    // "gte", "lte", "eq"
    TargetValue int32  `json:"targetValue"` // Target value (camelCase)
}

// ProgressPercentage calculates goal progress (0-100)
// Note: Target value is in Requirement.TargetValue, not a separate field
func (g *Goal) ProgressPercentage() int {
    target := int(g.Requirement.TargetValue)
    if target == 0 {
        return 0
    }
    progress := (int(g.Progress) * 100) / target
    if progress > 100 {
        return 100
    }
    return progress
}

// IsCompleted checks if the goal is completed
func (g *Goal) IsCompleted() bool {
    return g.Status == "completed"
}

// IsClaimed checks if the goal is claimed
func (g *Goal) IsClaimed() bool {
    return g.Status == "claimed"
}

// CanClaim checks if the goal can be claimed
func (g *Goal) CanClaim() bool {
    return g.Status == "completed"
}
```

---

### 4.3 Reward Model

```go
// Reward represents a goal's reward
// JSON field names are camelCase (protojson format from backend)
type Reward struct {
    Type     string `json:"type"`     // ITEM or WALLET
    RewardID string `json:"rewardId"` // Item code or currency code (camelCase)
    Quantity int32  `json:"quantity"`
}

// DisplayString returns a human-readable reward description
func (r *Reward) DisplayString() string {
    switch r.Type {
    case "ITEM":
        return fmt.Sprintf("%dx %s", r.Quantity, r.RewardID)
    case "WALLET":
        return fmt.Sprintf("%d %s", r.Quantity, r.RewardID)
    default:
        return fmt.Sprintf("%d %s", r.Quantity, r.RewardID)
    }
}
```

---

### 4.4 ClaimResult Model

```go
// ClaimResult represents the result of claiming a reward
// Matches the protobuf ClaimRewardResponse message (camelCase fields)
type ClaimResult struct {
    GoalID    string `json:"goalId"`    // camelCase
    Status    string `json:"status"`    // e.g., "claimed"
    Reward    Reward `json:"reward"`
    ClaimedAt string `json:"claimedAt"` // RFC3339 timestamp (camelCase)
}
```

**Note:** The backend does not return `Success` and `Message` fields. Instead, it returns the goal ID, status, reward details, and timestamp.

---

## 5. Error Handling

### 5.1 Error Types (from TECH_SPEC_ARCHITECTURE.md)

```go
package apierrors

import "errors"

var (
    ErrUnauthorized     = errors.New("unauthorized: invalid or expired token")
    ErrNotFound         = errors.New("resource not found")
    ErrAlreadyClaimed   = errors.New("reward already claimed")
    ErrNotCompleted     = errors.New("goal not completed")
    ErrNetworkTimeout   = errors.New("network timeout")
    ErrServerError      = errors.New("server error")
)
```

### 5.2 Error Handling in TUI

**TUI can check for specific errors:**

```go
challenges, err := apiClient.ListChallenges(ctx)
if err != nil {
    if errors.Is(err, apierrors.ErrUnauthorized) {
        return showErrorMsg("Authentication failed. Please check credentials.")
    }
    if errors.Is(err, apierrors.ErrNetworkTimeout) {
        return showErrorMsg("Request timed out. Check your network connection.")
    }
    return showErrorMsg("Failed to load challenges: " + err.Error())
}
```

---

## 6. Testing

### 6.1 Unit Tests with httptest

**Example: Testing ListChallenges:**

```go
func TestHTTPAPIClient_ListChallenges(t *testing.T) {
    // Create mock server
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Verify request
        assert.Equal(t, "GET", r.Method)
        assert.Equal(t, "/v1/challenges", r.URL.Path)
        assert.Contains(t, r.Header.Get("Authorization"), "Bearer")

        // Return mock response (wrapped with camelCase fields)
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(api.GetChallengesResponse{
            Challenges: []api.Challenge{
                {
                    ID:   "test-challenge",
                    Name: "Test Challenge",
                    Goals: []api.Goal{
                        {ID: "goal-1", Name: "Goal 1", Status: "completed"},
                    },
                },
            },
        })
    }))
    defer server.Close()

    // Create client
    mockAuth := &MockAuthProvider{
        token: &auth.Token{
            AccessToken: "test-token",
            ExpiresAt:   time.Now().Add(1 * time.Hour),
        },
    }
    client := api.NewHTTPAPIClient(server.URL, mockAuth)

    // Test
    challenges, err := client.ListChallenges(context.Background())
    assert.NoError(t, err)
    assert.Len(t, challenges, 1)
    assert.Equal(t, "test-challenge", challenges[0].ID)
    assert.Equal(t, "Test Challenge", challenges[0].Name)
    assert.Len(t, challenges[0].Goals, 1)
}
```

**Note:** Mock server returns wrapped response matching actual backend behavior.

---

### 6.2 Testing Retry Logic

**Example: Testing retry on 503 error:**

```go
func TestHTTPAPIClient_Retry_On_ServerError(t *testing.T) {
    attempts := 0
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        attempts++
        if attempts < 3 {
            // First 2 attempts fail
            w.WriteHeader(http.StatusServiceUnavailable)
            return
        }
        // Third attempt succeeds
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(api.GetChallengesResponse{Challenges: []api.Challenge{}})
    }))
    defer server.Close()

    client := api.NewHTTPAPIClient(server.URL, mockAuthProvider)

    // Should succeed after 2 retries
    challenges, err := client.ListChallenges(context.Background())
    assert.NoError(t, err)
    assert.Equal(t, 3, attempts)
    assert.NotNil(t, challenges)
}
```

---

### 6.3 Testing Error Mapping

**Example: Testing 409 Conflict → ErrAlreadyClaimed:**

```go
func TestHTTPAPIClient_ClaimReward_AlreadyClaimed(t *testing.T) {
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusConflict)
        json.NewEncoder(w).Encode(map[string]string{
            "error": "already_claimed",
        })
    }))
    defer server.Close()

    client := api.NewHTTPAPIClient(server.URL, mockAuthProvider)

    // Should return ErrAlreadyClaimed
    _, err := client.ClaimReward(context.Background(), "challenge-1", "goal-1")
    assert.Error(t, err)
    assert.True(t, errors.Is(err, apierrors.ErrAlreadyClaimed))
}
```

---

## 7. Usage Example

### 7.1 Basic Usage in TUI

```go
// In dashboard model
func (m DashboardModel) loadChallenges() tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        challenges, err := m.apiClient.ListChallenges(ctx)
        return ChallengesLoadedMsg{
            challenges: challenges,
            err:        err,
        }
    }
}

// Handle response
func (m DashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case ChallengesLoadedMsg:
        if msg.err != nil {
            m.errorMsg = "Failed to load challenges: " + msg.err.Error()
            return m, nil
        }
        m.challenges = msg.challenges
        m.errorMsg = ""
        return m, nil
    }
    return m, nil
}
```

---

### 7.2 Debug Mode Usage

```go
// In debug panel model
func (m DebugModel) View() string {
    req := m.apiClient.GetLastRequest()
    resp := m.apiClient.GetLastResponse()

    if req == nil || resp == nil {
        return "No requests yet"
    }

    return fmt.Sprintf(
        "Last Request:\n%s %s\n\n"+
        "Response: %d %s\nDuration: %s\n\n"+
        "Body:\n%s",
        req.Method, req.URL,
        resp.StatusCode, http.StatusText(resp.StatusCode), resp.Duration,
        resp.Body,
    )
}
```

---

## 8. Performance Considerations

### 8.1 Connection Pooling

**http.Client reuse enables connection pooling:**
- Keep-Alive connections maintained automatically
- Max 100 idle connections per host (Go default)
- Reduces latency for subsequent requests

### 8.2 Timeout Configuration

**Timeouts:**
- **http.Client.Timeout:** 10 seconds (total request time)
- **Context timeout:** 10 seconds (for cancellation)
- **Backoff on retry:** 1s, 2s, 4s (exponential)

**Total max time for a request:**
- Success: < 10 seconds
- With retries: Up to ~17 seconds (10s + 1s + 2s + 4s)

---

## 9. Future Enhancements

### Phase 7+ (Post-MVP)

1. **Request Cancellation:** Cancel in-flight requests when switching screens
2. **Batch Requests:** Support fetching multiple challenges in one request
3. **Caching:** Cache challenges for 30 seconds to reduce API load
4. **Compression:** Support gzip compression for large responses
5. **Metrics:** Track API latency and success rate

---

## 10. Related Documents

- **[TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md)** - Core interfaces
- **[TECH_SPEC_AUTHENTICATION.md](./TECH_SPEC_AUTHENTICATION.md)** - AuthProvider implementation
- **[../TECH_SPEC_API.md](../TECH_SPEC_API.md)** - Challenge Service REST API

---

## 11. Summary

**Key Implementation Details:**

1. **Retry Logic:** Exponential backoff for 5xx errors (max 3 attempts)
2. **Error Mapping:** HTTP status codes mapped to domain errors
3. **Debug Instrumentation:** Last request/response stored for inspection
4. **Token Management:** AuthProvider handles token refresh automatically
5. **Connection Pooling:** Single http.Client reused for efficiency

**API Coverage:**
- ✅ `GET /v1/challenges` - List all challenges
- ✅ `GET /v1/challenges/{id}` - Get specific challenge
- ✅ `POST /v1/challenges/{id}/goals/{id}/claim` - Claim reward

**Next Steps:**
1. Review and approve this spec
2. Implement HTTPAPIClient
3. Write unit tests with httptest
4. Integrate with TUI (TECH_SPEC_TUI.md)

---

**Document Version:** 1.0
**Last Updated:** 2025-10-20
**Status:** ✅ Ready for Review
