# Challenge Demo App - Authentication Technical Specification

## Document Purpose

This technical specification defines the **AuthProvider interface** and its implementations for authentication (AGS OAuth2 vs mock auth).

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - Core interfaces
- [../JWT_AUTHENTICATION.md](../JWT_AUTHENTICATION.md) - Challenge Service JWT authentication

---

## 1. Overview

### 1.1 Purpose

The Auth Provider component handles **JWT token acquisition and management** for authenticating with AGS services.

**Implementation Note:** This spec uses the **AccelByte Go SDK** (`github.com/AccelByte/accelbyte-go-sdk`) for all AGS IAM authentication operations instead of manual HTTP calls. The SDK provides:
- Type-safe parameter structures
- Automatic error handling
- Built-in retry logic
- Consistent client configuration
- Simplified OAuth2 flows

**IMPORTANT: Demo App Supports Dual Authentication**

The demo app can operate with **two tokens simultaneously** for comprehensive testing and verification:

### Primary Authentication (Required)
Used for **Challenge Service API** operations:
- **Calls**: `GET /v1/challenges`, `POST /v1/challenges/{id}/goals/{id}/claim`
- **Requires**: Token with real `user_id` in JWT "sub" claim
- **Modes**:
  - **Password Mode**: OAuth2 Password Grant (email + password) → User token with real user_id
  - **Mock Mode**: Static JWT with configurable user_id (local dev, no AGS)

### Admin Authentication (Optional - for Verification)
Used for **AGS Admin API** verification operations:
- **Calls**: `QueryUserEntitlementsShort`, `GetUserWalletShort`, etc.
- **Requires**: Service token with admin permissions
- **Mode**: OAuth2 Client Credentials (admin client_id + secret) → Admin token
- **Purpose**: Verify rewards were actually granted by querying AGS Platform APIs
- **When to Use**: Enable with `--admin-client-id` and `--admin-client-secret` flags

### Dual Token Workflow Example
```bash
# User token: for Challenge Service operations
# Admin token: for AGS Platform verification

1. User claims reward via Challenge Service (uses user token)
2. Demo app verifies entitlement was granted (uses admin token)
3. Demo app confirms wallet balance updated (uses admin token)
```

**Configuration Modes:**
1. **Single Token (User Only)**: `--auth-mode=password` or `--auth-mode=mock`
   - Challenge Service operations only
   - No verification of rewards in AGS

2. **Dual Token (User + Admin)**: Add admin credentials
   - Challenge Service operations (user token)
   - AGS Platform verification (admin token)
   - Recommended for complete testing

**Note:** Event Handler gRPC calls can use either user or admin token depending on handler configuration.

---

### 1.2 Interface (from TECH_SPEC_ARCHITECTURE.md)

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

    // IsTokenValid checks if the token is still valid
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

---

## 2. Password Auth Provider (User Authentication)

### 2.1 PasswordAuthProvider Implementation

**Implements OAuth2 Password Grant flow for user login:**

```go
package auth

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "net/url"
    "strings"
    "sync"
    "time"
)

// PasswordAuthProvider implements AuthProvider using AGS IAM Password Grant
// This is used for USER authentication (email + password → user token)
type PasswordAuthProvider struct {
    iamURL       string
    clientID     string    // Still required for Password Grant
    clientSecret string    // Still required for Password Grant
    namespace    string
    email        string    // User email
    password     string    // User password

    httpClient   *http.Client
    currentToken *Token
    mu           sync.RWMutex  // Protects currentToken
}

// NewPasswordAuthProvider creates a new password auth provider
// Parameters:
//   - iamURL: AGS IAM base URL (e.g., "https://demo.accelbyte.io/iam")
//   - clientID: OAuth2 client ID (required even for password grant)
//   - clientSecret: OAuth2 client secret (required even for password grant)
//   - namespace: AGS namespace
//   - email: User email for login
//   - password: User password for login
func NewPasswordAuthProvider(iamURL, clientID, clientSecret, namespace, email, password string) *PasswordAuthProvider {
    return &PasswordAuthProvider{
        iamURL:       iamURL,
        clientID:     clientID,
        clientSecret: clientSecret,
        namespace:    namespace,
        email:        email,
        password:     password,
        httpClient:   &http.Client{Timeout: 10 * time.Second},
    }
}
```

---

### 2.2 Authenticate Implementation (Password Grant)

**OAuth2 Password Grant flow using AccelByte Go SDK:**

```go
import (
    "github.com/AccelByte/accelbyte-go-sdk/iam-sdk/pkg/iamclient/o_auth2_0"
    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/iam"
    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/factory"
)

// Authenticate performs OAuth2 Password Grant flow using AccelByte Go SDK
func (p *PasswordAuthProvider) Authenticate(ctx context.Context) (*Token, error) {
    // Create SDK configuration
    configRepo := factory.NewConfigRepositoryImpl()
    configRepo.SetClientId(p.clientID)
    configRepo.SetClientSecret(p.clientSecret)
    configRepo.SetBaseURL(p.iamURL)

    // Create OAuth service
    oAuth20Service := iam.OAuth20Service{
        Client:          factory.NewIamClient(configRepo),
        TokenRepository: factory.NewTokenRepositoryImpl(),
    }

    // Prepare token grant parameters for password grant
    params := &o_auth2_0.TokenGrantV3Params{
        GrantType: "password",
        Username:  &p.email,     // User email
        Password:  &p.password,  // User password
        Context:   ctx,
    }

    // Call TokenGrantV3
    result, err := oAuth20Service.TokenGrantV3Short(params)
    if err != nil {
        return nil, fmt.Errorf("password grant failed: %w", err)
    }

    // Extract token response
    tokenResp := result.Response
    if tokenResp == nil {
        return nil, fmt.Errorf("empty token response")
    }

    // Create token from SDK response
    token := &Token{
        AccessToken:  *tokenResp.AccessToken,
        TokenType:    *tokenResp.TokenType,
        ExpiresAt:    time.Now().Add(time.Duration(*tokenResp.ExpiresIn) * time.Second),
        RefreshToken: tokenResp.RefreshToken, // May be nil for some flows
    }

    // Store current token
    p.mu.Lock()
    p.currentToken = token
    p.mu.Unlock()

    return token, nil
}
```

**Key Difference from Client Credentials:**
- `grant_type=password` (not `client_credentials`)
- Includes `username` (email) and `password` fields
- Returns JWT with real `user_id` in "sub" claim
- Returns `refresh_token` for token renewal

---

### 2.3 RefreshToken, GetToken, IsTokenValid

**These methods use the AccelByte Go SDK:**

```go
// RefreshToken refreshes an existing token using refresh_token grant
func (p *PasswordAuthProvider) RefreshToken(ctx context.Context, token *Token) (*Token, error) {
    if token.RefreshToken == nil || *token.RefreshToken == "" {
        // No refresh token, perform full authentication
        return p.Authenticate(ctx)
    }

    // Create SDK configuration
    configRepo := factory.NewConfigRepositoryImpl()
    configRepo.SetClientId(p.clientID)
    configRepo.SetClientSecret(p.clientSecret)
    configRepo.SetBaseURL(p.iamURL)

    // Create OAuth service
    oAuth20Service := iam.OAuth20Service{
        Client:          factory.NewIamClient(configRepo),
        TokenRepository: factory.NewTokenRepositoryImpl(),
    }

    // Prepare token grant parameters for refresh token grant
    params := &o_auth2_0.TokenGrantV3Params{
        GrantType:    "refresh_token",
        RefreshToken: token.RefreshToken,
        Context:      ctx,
    }

    // Call TokenGrantV3
    result, err := oAuth20Service.TokenGrantV3Short(params)
    if err != nil {
        // Refresh failed, try full authentication
        return p.Authenticate(ctx)
    }

    // Extract token response
    tokenResp := result.Response
    if tokenResp == nil {
        return nil, fmt.Errorf("empty token response")
    }

    // Create new token
    newToken := &Token{
        AccessToken:  *tokenResp.AccessToken,
        TokenType:    *tokenResp.TokenType,
        ExpiresAt:    time.Now().Add(time.Duration(*tokenResp.ExpiresIn) * time.Second),
        RefreshToken: tokenResp.RefreshToken,
    }

    // Store current token
    p.mu.Lock()
    p.currentToken = newToken
    p.mu.Unlock()

    return newToken, nil
}

// GetToken returns the current valid token, refreshing if necessary
func (p *PasswordAuthProvider) GetToken(ctx context.Context) (*Token, error) {
    p.mu.RLock()
    token := p.currentToken
    p.mu.RUnlock()

    // No token yet
    if token == nil {
        return p.Authenticate(ctx)
    }

    // Token expired
    if token.IsExpired() {
        return p.RefreshToken(ctx, token)
    }

    // Token expiring soon (within 5 minutes)
    if token.ExpiresIn() < 5*time.Minute {
        // Try to refresh in background, but return current token
        go func() {
            refreshCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
            defer cancel()
            p.RefreshToken(refreshCtx, token)
        }()
    }

    return token, nil
}

// IsTokenValid checks if a token is still valid
func (p *PasswordAuthProvider) IsTokenValid(token *Token) bool {
    if token == nil {
        return false
    }
    return !token.IsExpired()
}
```

---

## 3. Client Credentials Auth Provider (Service Authentication)

### 3.1 ClientAuthProvider Implementation

**Implements OAuth2 Client Credentials flow for service authentication:**

```go
package auth

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "net/url"
    "strings"
    "sync"
    "time"
)

// ClientAuthProvider implements AuthProvider using AGS IAM OAuth2 Client Credentials
// This is used for SERVICE authentication (client_id + secret → service token)
// WARNING: This token does NOT have a user_id in the "sub" claim!
type ClientAuthProvider struct {
    iamURL       string
    clientID     string
    clientSecret string
    namespace    string

    httpClient   *http.Client
    currentToken *Token
    mu           sync.RWMutex  // Protects currentToken
}

// NewClientAuthProvider creates a new client auth provider
func NewClientAuthProvider(iamURL, clientID, clientSecret, namespace string) *ClientAuthProvider {
    return &ClientAuthProvider{
        iamURL:       iamURL,
        clientID:     clientID,
        clientSecret: clientSecret,
        namespace:    namespace,
        httpClient:   &http.Client{Timeout: 10 * time.Second},
    }
}
```

---

### 3.2 Authenticate Implementation (Client Credentials)

**OAuth2 Client Credentials flow using AccelByte Go SDK:**

```go
// Authenticate performs OAuth2 Client Credentials flow using AccelByte Go SDK
func (p *ClientAuthProvider) Authenticate(ctx context.Context) (*Token, error) {
    // Create SDK configuration
    configRepo := factory.NewConfigRepositoryImpl()
    configRepo.SetClientId(p.clientID)
    configRepo.SetClientSecret(p.clientSecret)
    configRepo.SetBaseURL(p.iamURL)

    // Create OAuth service
    oAuth20Service := iam.OAuth20Service{
        Client:          factory.NewIamClient(configRepo),
        TokenRepository: factory.NewTokenRepositoryImpl(),
    }

    // Prepare token grant parameters for client credentials grant
    params := &o_auth2_0.TokenGrantV3Params{
        GrantType: "client_credentials",
        Context:   ctx,
    }

    // Call TokenGrantV3
    result, err := oAuth20Service.TokenGrantV3Short(params)
    if err != nil {
        return nil, fmt.Errorf("client credentials grant failed: %w", err)
    }

    // Extract token response
    tokenResp := result.Response
    if tokenResp == nil {
        return nil, fmt.Errorf("empty token response")
    }

    // Create token from SDK response
    token := &Token{
        AccessToken:  *tokenResp.AccessToken,
        TokenType:    *tokenResp.TokenType,
        ExpiresAt:    time.Now().Add(time.Duration(*tokenResp.ExpiresIn) * time.Second),
        RefreshToken: tokenResp.RefreshToken,
    }

    // Store current token
    p.mu.Lock()
    p.currentToken = token
    p.mu.Unlock()

    return token, nil
}
```

---

### 2.3 RefreshToken Implementation

**Refresh an existing token:**

```go
// RefreshToken refreshes an existing token
func (p *ClientAuthProvider) RefreshToken(ctx context.Context, token *Token) (*Token, error) {
    if token.RefreshToken == "" {
        // No refresh token, perform full authentication
        return p.Authenticate(ctx)
    }

    // Build refresh request
    data := url.Values{}
    data.Set("grant_type", "refresh_token")
    data.Set("refresh_token", token.RefreshToken)

    tokenURL := fmt.Sprintf("%s/oauth/token", p.iamURL)

    req, err := http.NewRequestWithContext(ctx, "POST", tokenURL, strings.NewReader(data.Encode()))
    if err != nil {
        return nil, fmt.Errorf("create refresh request: %w", err)
    }

    req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    req.SetBasicAuth(p.clientID, p.clientSecret)

    // Send request
    resp, err := p.httpClient.Do(req)
    if err != nil {
        return nil, fmt.Errorf("refresh request failed: %w", err)
    }
    defer resp.Body.Close()

    // Check status
    if resp.StatusCode != http.StatusOK {
        // Refresh failed, try full authentication
        return p.Authenticate(ctx)
    }

    // Parse response (same structure as authenticate)
    var tokenResp struct {
        AccessToken  string `json:"access_token"`
        TokenType    string `json:"token_type"`
        ExpiresIn    int    `json:"expires_in"`
        RefreshToken string `json:"refresh_token,omitempty"`
    }

    if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
        return nil, fmt.Errorf("decode refresh response: %w", err)
    }

    // Create new token
    newToken := &Token{
        AccessToken:  tokenResp.AccessToken,
        TokenType:    tokenResp.TokenType,
        ExpiresAt:    time.Now().Add(time.Duration(tokenResp.ExpiresIn) * time.Second),
        RefreshToken: tokenResp.RefreshToken,
    }

    // Store current token
    p.mu.Lock()
    p.currentToken = newToken
    p.mu.Unlock()

    return newToken, nil
}
```

---

### 2.4 GetToken Implementation

**Get current token with auto-refresh:**

```go
// GetToken returns the current valid token, refreshing if necessary
func (p *ClientAuthProvider) GetToken(ctx context.Context) (*Token, error) {
    p.mu.RLock()
    token := p.currentToken
    p.mu.RUnlock()

    // No token yet
    if token == nil {
        return p.Authenticate(ctx)
    }

    // Token expired
    if token.IsExpired() {
        return p.RefreshToken(ctx, token)
    }

    // Token expiring soon (within 5 minutes)
    if token.ExpiresIn() < 5*time.Minute {
        // Try to refresh in background, but return current token
        // If refresh fails, current token is still valid
        go func() {
            refreshCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
            defer cancel()
            p.RefreshToken(refreshCtx, token)
        }()
    }

    return token, nil
}
```

---

### 2.5 IsTokenValid Implementation

**Check token validity:**

```go
// IsTokenValid checks if a token is still valid
func (p *ClientAuthProvider) IsTokenValid(token *Token) bool {
    if token == nil {
        return false
    }
    return !token.IsExpired()
}
```

---

## 3. Mock Auth Provider

### 3.1 MockAuthProvider Implementation

**Returns static JWT for local development:**

```go
package auth

import (
    "context"
    "time"
)

// MockAuthProvider implements AuthProvider with a static token
type MockAuthProvider struct {
    token     *Token
    userID    string  // User ID to embed in JWT
    namespace string  // Namespace to embed in JWT
}

// NewMockAuthProvider creates a new mock auth provider
// Parameters:
//   - userID: User ID to include in JWT "sub" claim (from --user-id CLI flag)
//   - namespace: Namespace to include in JWT "namespace" claim (from --namespace CLI flag)
func NewMockAuthProvider(userID, namespace string) *MockAuthProvider {
    // Create a static token that expires in 1 hour
    token := &Token{
        AccessToken:  generateMockJWT(userID, namespace),
        TokenType:    "Bearer",
        ExpiresAt:    time.Now().Add(1 * time.Hour),
        RefreshToken: "",
    }

    return &MockAuthProvider{
        token:     token,
        userID:    userID,
        namespace: namespace,
    }
}

// Authenticate returns the static token
func (p *MockAuthProvider) Authenticate(ctx context.Context) (*Token, error) {
    return p.token, nil
}

// RefreshToken returns a new static token
func (p *MockAuthProvider) RefreshToken(ctx context.Context, token *Token) (*Token, error) {
    // Generate new token with 1 hour expiry using stored userID and namespace
    newToken := &Token{
        AccessToken:  generateMockJWT(p.userID, p.namespace),
        TokenType:    "Bearer",
        ExpiresAt:    time.Now().Add(1 * time.Hour),
        RefreshToken: "",
    }

    p.token = newToken
    return newToken, nil
}

// GetToken returns the current static token
func (p *MockAuthProvider) GetToken(ctx context.Context) (*Token, error) {
    // If expired, refresh
    if p.token.IsExpired() {
        return p.RefreshToken(ctx, p.token)
    }
    return p.token, nil
}

// IsTokenValid checks if token is valid
func (p *MockAuthProvider) IsTokenValid(token *Token) bool {
    if token == nil {
        return false
    }
    return !token.IsExpired()
}
```

---

### 3.2 Mock JWT Generation

**Generate a simple JWT-like token with configurable user_id and namespace:**

```go
import (
    "encoding/base64"
    "encoding/json"
    "fmt"
    "time"
)

// generateMockJWT generates a mock JWT token
// Parameters:
//   - userID: User ID to embed in "sub" claim (allows testing different users)
//   - namespace: Namespace to embed in "namespace" claim
func generateMockJWT(userID, namespace string) string {
    header := map[string]interface{}{
        "alg": "HS256",
        "typ": "JWT",
    }

    payload := map[string]interface{}{
        "sub":       userID,      // Use parameter, not hardcoded
        "namespace": namespace,   // Use parameter, not hardcoded
        "iat":       time.Now().Unix(),
        "exp":       time.Now().Add(1 * time.Hour).Unix(),
    }

    // Encode header and payload (no signature for mock)
    headerJSON, _ := json.Marshal(header)
    payloadJSON, _ := json.Marshal(payload)

    headerB64 := base64.RawURLEncoding.EncodeToString(headerJSON)
    payloadB64 := base64.RawURLEncoding.EncodeToString(payloadJSON)

    // Mock JWT: header.payload.mock-signature
    return fmt.Sprintf("%s.%s.mock-signature", headerB64, payloadB64)
}
```

**Note:** This mock JWT is NOT cryptographically valid. For local development, the backend service should be run with `PLUGIN_GRPC_SERVER_AUTH_ENABLED=false` to disable JWT validation.

**Usage Example:**
```bash
# Test different users in mock mode
./challenge-demo --auth-mode=mock --user-id=alice --namespace=accelbyte
# JWT payload: {"sub": "alice", "namespace": "accelbyte", ...}

./challenge-demo --auth-mode=mock --user-id=bob --namespace=accelbyte
# JWT payload: {"sub": "bob", "namespace": "accelbyte", ...}
```

---

## 4. Factory Pattern

### 4.1 NewAuthProvider Factory

**Create appropriate implementation based on config:**

```go
package auth

import (
    "fmt"

    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/config"
)

// NewAuthProvider creates the primary AuthProvider based on config
func NewAuthProvider(cfg *config.Config) AuthProvider {
    switch cfg.AuthMode {
    case "password":
        // User authentication (email + password → user token)
        // RECOMMENDED for Challenge Service API testing
        return NewPasswordAuthProvider(
            cfg.IAMURL,
            cfg.ClientID,
            cfg.ClientSecret,
            cfg.Namespace,
            cfg.Email,     // User email
            cfg.Password,  // User password
        )

    case "client":
        // Service authentication (client credentials → service token)
        // WARNING: Service token does NOT have user_id!
        // Only use for Event Handler or other service APIs
        return NewClientAuthProvider(
            cfg.IAMURL,
            cfg.ClientID,
            cfg.ClientSecret,
            cfg.Namespace,
        )

    case "mock":
        // Mock authentication with configurable user_id
        // Pass userID and namespace from config (CLI flags override these)
        return NewMockAuthProvider(cfg.UserID, cfg.Namespace)

    default:
        // Default to mock mode with config values
        return NewMockAuthProvider(cfg.UserID, cfg.Namespace)
    }
}

// NewAdminAuthProvider creates an optional admin AuthProvider for verification
// Returns nil if admin credentials are not configured
func NewAdminAuthProvider(cfg *config.Config) AuthProvider {
    // Check if admin credentials are configured
    if cfg.AdminClientID == "" || cfg.AdminClientSecret == "" {
        return nil
    }

    // Always use Client Credentials for admin operations
    return NewClientAuthProvider(
        cfg.IAMURL,
        cfg.AdminClientID,
        cfg.AdminClientSecret,
        cfg.Namespace,
    )
}
```

---

## 5. Configuration

### 5.1 Config Fields

**Add to Config struct (from TECH_SPEC_CONFIG.md):**

```go
type Config struct {
    // ... other fields ...

    // Primary Authentication (for Challenge Service API)
    IAMURL       string `yaml:"iam_url"`       // AGS IAM URL
    ClientID     string `yaml:"client_id"`     // OAuth2 client ID
    ClientSecret string `yaml:"client_secret"` // OAuth2 client secret
    AuthMode     string `yaml:"auth_mode"`     // "mock", "password", or "client"

    // User Credentials (for password mode)
    Email        string `yaml:"email"`         // User email (for password grant)
    Password     string `yaml:"password"`      // User password (for password grant)

    // User ID (for mock mode)
    UserID       string `yaml:"user_id"`       // User ID for mock JWT

    // Admin Authentication (optional - for AGS Platform verification)
    AdminClientID     string `yaml:"admin_client_id"`     // Admin OAuth2 client ID
    AdminClientSecret string `yaml:"admin_client_secret"` // Admin OAuth2 client secret
}
```

**Security Note:** Passwords and secrets should NOT be stored in config files in production. For MVP, we accept this for testing convenience with a warning about file permissions (chmod 600).

**Dual Token Configuration:**
- **User Token**: Set via `AuthMode`, `Email`, `Password`, OR `UserID` (for mock)
- **Admin Token**: Set via `AdminClientID` and `AdminClientSecret` (optional)
- If admin credentials are not set, verification commands will not be available

### 5.2 Default Config

```go
func DefaultConfig() *Config {
    return &Config{
        // ... other defaults ...
        IAMURL:       "https://demo.accelbyte.io/iam",
        ClientID:     "",
        ClientSecret: "",
        AuthMode:     "mock",      // Default to mock mode for ease of use
        Email:        "",
        Password:     "",
        UserID:       "test-user", // Default user ID for mock mode
    }
}
```

### 5.3 Config Validation

```go
func (c *Config) Validate() error {
    // ... other validations ...

    // Validate auth mode
    validModes := []string{"mock", "password", "client"}
    validMode := false
    for _, mode := range validModes {
        if c.AuthMode == mode {
            validMode = true
            break
        }
    }
    if !validMode {
        return fmt.Errorf("auth_mode must be 'mock', 'password', or 'client', got: %s", c.AuthMode)
    }

    // Mode-specific validation
    switch c.AuthMode {
    case "password":
        if c.IAMURL == "" {
            return errors.New("iam_url required for password auth")
        }
        if c.ClientID == "" || c.ClientSecret == "" {
            return errors.New("client_id and client_secret required for password auth")
        }
        if c.Email == "" || c.Password == "" {
            return errors.New("email and password required for password auth")
        }

    case "client":
        if c.IAMURL == "" {
            return errors.New("iam_url required for client auth")
        }
        if c.ClientID == "" || c.ClientSecret == "" {
            return errors.New("client_id and client_secret required for client auth")
        }

    case "mock":
        if c.UserID == "" {
            return errors.New("user_id required for mock auth")
        }
    }

    return nil
}
```

### 5.4 CLI Flags

**Add CLI flags for authentication:**

```go
var (
    // Primary authentication
    flagAuthMode string
    flagEmail    string
    flagPassword string
    flagUserID   string

    // Admin authentication (optional)
    flagAdminClientID     string
    flagAdminClientSecret string

    // ... other flags ...
)

func init() {
    // Primary authentication
    rootCmd.PersistentFlags().StringVar(&flagAuthMode, "auth-mode", "", "Auth mode (mock/password/client)")
    rootCmd.PersistentFlags().StringVar(&flagEmail, "email", "", "User email (for password mode)")
    rootCmd.PersistentFlags().StringVar(&flagPassword, "password", "", "User password (for password mode)")
    rootCmd.PersistentFlags().StringVar(&flagUserID, "user-id", "", "User ID (for mock mode)")

    // Admin authentication
    rootCmd.PersistentFlags().StringVar(&flagAdminClientID, "admin-client-id", "", "Admin client ID (for verification)")
    rootCmd.PersistentFlags().StringVar(&flagAdminClientSecret, "admin-client-secret", "", "Admin client secret (for verification)")

    // ... other flags ...
}
```

**Apply CLI flag overrides:**

```go
// Apply CLI flag overrides for primary auth
if flagAuthMode != "" {
    cfg.AuthMode = flagAuthMode
}
if flagEmail != "" {
    cfg.Email = flagEmail
}
if flagPassword != "" {
    cfg.Password = flagPassword
}
if flagUserID != "" {
    cfg.UserID = flagUserID
}

// Apply CLI flag overrides for admin auth
if flagAdminClientID != "" {
    cfg.AdminClientID = flagAdminClientID
}
if flagAdminClientSecret != "" {
    cfg.AdminClientSecret = flagAdminClientSecret
}
```

**Usage Examples:**

```bash
# Single Token: Mock mode (default)
./challenge-demo --auth-mode=mock --user-id=alice

# Single Token: Password mode (user authentication)
./challenge-demo --auth-mode=password --email=alice@example.com --password=secret123

# Dual Token: Password mode + Admin verification
./challenge-demo --auth-mode=password \
  --email=alice@example.com --password=secret123 \
  --admin-client-id=admin-xxx --admin-client-secret=admin-yyy

# Dual Token: Mock mode + Admin verification (local dev)
./challenge-demo --auth-mode=mock --user-id=alice \
  --admin-client-id=admin-xxx --admin-client-secret=admin-yyy
```

---

## 6. Error Handling

### 6.1 Error Types

```go
package auth

import "errors"

var (
    ErrAuthFailed      = errors.New("authentication failed")
    ErrInvalidToken    = errors.New("invalid token")
    ErrTokenExpired    = errors.New("token expired")
    ErrRefreshFailed   = errors.New("token refresh failed")
    ErrInvalidCredentials = errors.New("invalid client credentials")
)
```

### 6.2 Error Handling in Implementations

**Wrap errors with context:**

```go
func (p *ClientAuthProvider) Authenticate(ctx context.Context) (*Token, error) {
    // ... make request ...

    if resp.StatusCode == http.StatusUnauthorized {
        return nil, fmt.Errorf("%w: invalid client credentials", ErrInvalidCredentials)
    }

    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("%w: status %d", ErrAuthFailed, resp.StatusCode)
    }

    // ... parse response ...
}
```

---

## 7. Testing

### 7.1 Unit Tests for ClientAuthProvider

**Test OAuth2 flow with httptest:**

```go
func TestClientAuthProvider_Authenticate(t *testing.T) {
    // Create mock IAM server
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Verify request
        assert.Equal(t, "POST", r.Method)
        assert.Equal(t, "/oauth/token", r.URL.Path)
        assert.Equal(t, "application/x-www-form-urlencoded", r.Header.Get("Content-Type"))

        // Check Basic Auth
        username, password, ok := r.BasicAuth()
        assert.True(t, ok)
        assert.Equal(t, "test-client", username)
        assert.Equal(t, "test-secret", password)

        // Return token response
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(map[string]interface{}{
            "access_token": "test-token",
            "token_type":   "Bearer",
            "expires_in":   3600,
        })
    }))
    defer server.Close()

    // Create provider
    provider := NewClientAuthProvider(server.URL, "test-client", "test-secret", "demo")

    // Test authenticate
    token, err := provider.Authenticate(context.Background())
    assert.NoError(t, err)
    assert.Equal(t, "test-token", token.AccessToken)
    assert.Equal(t, "Bearer", token.TokenType)
    assert.False(t, token.IsExpired())
}
```

---

### 7.2 Unit Tests for MockAuthProvider

```go
func TestMockAuthProvider_Authenticate(t *testing.T) {
    provider := NewMockAuthProvider("test-user-123", "demo")

    token, err := provider.Authenticate(context.Background())
    assert.NoError(t, err)
    assert.NotEmpty(t, token.AccessToken)
    assert.Equal(t, "Bearer", token.TokenType)
    assert.False(t, token.IsExpired())

    // Verify JWT contains correct user_id
    // (Would need to decode JWT in real test)
}

func TestMockAuthProvider_GetToken_AutoRefresh(t *testing.T) {
    provider := NewMockAuthProvider("alice", "demo")

    // Manually expire token
    provider.token.ExpiresAt = time.Now().Add(-1 * time.Hour)

    // GetToken should auto-refresh
    token, err := provider.GetToken(context.Background())
    assert.NoError(t, err)
    assert.False(t, token.IsExpired())
}

func TestMockAuthProvider_DifferentUsers(t *testing.T) {
    // Test that different userIDs produce different tokens
    providerAlice := NewMockAuthProvider("alice", "demo")
    providerBob := NewMockAuthProvider("bob", "demo")

    tokenAlice, _ := providerAlice.GetToken(context.Background())
    tokenBob, _ := providerBob.GetToken(context.Background())

    // Tokens should be different (different user_id in payload)
    assert.NotEqual(t, tokenAlice.AccessToken, tokenBob.AccessToken)
}
```

---

### 7.3 Integration Tests

**Test with real AGS IAM:**

```go
func TestClientAuthProvider_Integration(t *testing.T) {
    // Skip if credentials not provided
    if testing.Short() {
        t.Skip("skipping integration test")
    }

    clientID := os.Getenv("AGS_CLIENT_ID")
    clientSecret := os.Getenv("AGS_CLIENT_SECRET")
    if clientID == "" || clientSecret == "" {
        t.Skip("AGS credentials not set")
    }

    provider := NewClientAuthProvider(
        "https://demo.accelbyte.io/iam",
        clientID,
        clientSecret,
        "demo",
    )

    // Test authenticate
    token, err := provider.Authenticate(context.Background())
    require.NoError(t, err)
    assert.NotEmpty(t, token.AccessToken)
    assert.False(t, token.IsExpired())

    // Test get token (should return cached)
    token2, err := provider.GetToken(context.Background())
    require.NoError(t, err)
    assert.Equal(t, token.AccessToken, token2.AccessToken)
}
```

---

## 8. Usage Example

### 8.1 In API Client

**Attach token to requests:**

```go
// In HTTPAPIClient.doRequest()

func (c *HTTPAPIClient) doRequest(ctx context.Context, method, path string, body interface{}) (*http.Response, error) {
    // ... create request ...

    // Get auth token
    token, err := c.authProvider.GetToken(ctx)
    if err != nil {
        return nil, fmt.Errorf("get auth token: %w", err)
    }

    // Attach token to request
    req.Header.Set("Authorization", fmt.Sprintf("%s %s", token.TokenType, token.AccessToken))

    // ... send request ...
}
```

---

### 8.2 In TUI for Token Display

**Show token status in header:**

```go
// In AppModel.renderHeader()

func (m AppModel) renderHeader() string {
    token := m.container.AuthProvider.GetToken(context.Background())

    authStatus := "✗ No auth"
    if token != nil && !token.IsExpired() {
        expiresIn := token.ExpiresIn()
        authStatus = fmt.Sprintf("✓ %dm", int(expiresIn.Minutes()))
    }

    return headerStyle.Render(
        fmt.Sprintf("Env: %s | User: %s | Auth: %s | [q] Quit",
            m.container.Config.Environment,
            m.container.Config.UserID,
            authStatus),
    )
}
```

---

## 9. Security Considerations

### 9.1 Credential Storage

**Current Approach (MVP):**
- Store in config file (plaintext YAML)
- File permissions: `chmod 600 ~/.challenge-demo/config.yaml`
- Warn if file permissions too open

**Warning on Start:**
```go
func checkConfigPermissions(path string) {
    info, _ := os.Stat(path)
    mode := info.Mode().Perm()

    if mode&0077 != 0 {
        fmt.Printf("⚠️  WARNING: Config file permissions too open (%o). Run: chmod 600 %s\n", mode, path)
    }
}
```

**Future Enhancement:**
- Use OS keychain (macOS Keychain, Windows Credential Manager, Linux Secret Service)
- Library: `github.com/99designs/keyring`

---

### 9.2 Token Logging

**Never log full token:**

```go
// Bad
logger.Info("token received", "token", token.AccessToken)

// Good
logger.Info("token received", "token_prefix", token.AccessToken[:8]+"...")
```

---

### 9.3 Token Transmission

**Always use HTTPS:**
- Validate config: `IAMURL` and `BackendURL` must use `https://` (except for localhost)
- Warn if using `http://` in non-local environment

---

## 10. Future Enhancements

### Phase 7+ (Post-MVP)

1. **Keychain Integration:** Store credentials securely in OS keychain
2. **Device Code Flow:** Support OAuth2 device code flow for easier setup
3. **Token Caching:** Persist tokens to disk to avoid re-authentication on restart
4. **Multiple Accounts:** Support switching between multiple AGS accounts
5. **SSO Support:** Integrate with browser-based SSO flow

---

## 11. Summary

**Key Implementation Details:**

1. **Dual Authentication Support:** Two independent AuthProvider instances
   - **Primary**: User authentication for Challenge Service API
   - **Admin** (Optional): Service authentication for AGS Platform verification
2. **Three Authentication Modes for Primary:**
   - **Password Mode:** OAuth2 Password Grant (user email + password → user token with user_id)
   - **Client Mode:** OAuth2 Client Credentials (service auth → service token, NO user_id)
   - **Mock Mode:** Static JWT with configurable userID and namespace
3. **Admin Authentication:** Always uses Client Credentials flow
4. **Factory Pattern:** Config-driven implementation selection
5. **Thread-Safe:** Mutex protects current token in OAuth2 providers

**Configuration:**

**Single Token Mode (Challenge Service only):**
- `AUTH_MODE=password` → PasswordAuthProvider (RECOMMENDED)
- `AUTH_MODE=mock` → MockAuthProvider (local dev)

**Dual Token Mode (Challenge Service + Verification):**
- Primary: `AUTH_MODE=password` or `mock`
- Admin: `ADMIN_CLIENT_ID` and `ADMIN_CLIENT_SECRET` (optional)

**Token Management:**
- Auto-refresh when expiring within 5 minutes
- Concurrent-safe token access
- Graceful fallback on refresh failure
- Refresh token support (password and client modes)

**Usage Examples:**

**Single Token - Mock Mode (local dev, no AGS):**
```bash
# Test different users with mock authentication
./challenge-demo --auth-mode=mock --user-id=alice --namespace=accelbyte
```

**Single Token - Password Mode (real user authentication):**
```bash
# Login as real AGS user
./challenge-demo --auth-mode=password --email=alice@example.com --password=secret123
```

**Dual Token - Password + Admin (full testing with verification):**
```bash
# User token for Challenge Service, Admin token for verification
./challenge-demo --auth-mode=password \
  --email=alice@example.com --password=secret123 \
  --admin-client-id=admin-xxx --admin-client-secret=admin-yyy

# Now you can:
# 1. Claim rewards (uses user token)
# 2. Verify entitlements granted (uses admin token)
# 3. Check wallet balances (uses admin token)
```

**Dual Token - Mock + Admin (local dev with verification):**
```bash
# Mock user token, real admin token
./challenge-demo --auth-mode=mock --user-id=alice \
  --admin-client-id=admin-xxx --admin-client-secret=admin-yyy
```

**Critical Design Decision:**

**Why Dual Token?**
- **User Token**: Challenge Service requires real `user_id` in JWT for operations
- **Admin Token**: AGS Platform Admin APIs require service credentials for verification
- **Separation**: User and admin permissions are separate in AGS
- **Testing Value**: Verify that claimed rewards are actually granted in AGS

**When to Use Each Mode:**
- **Mock only**: Local development, no AGS connection
- **Password only**: Testing Challenge Service without reward verification
- **Password + Admin**: Full end-to-end testing with AGS verification (RECOMMENDED)

**Local Development Reminder:**
- Backend: Set `PLUGIN_GRPC_SERVER_AUTH_ENABLED=false`
- Demo App: Use `--auth-mode=mock --user-id=<test-user>`
- This combination allows testing without AGS IAM while still simulating specific users

**Production-like Testing:**
- Backend: Enable JWT validation (default)
- Demo App: Use dual token mode with real credentials
- This tests complete flow including AGS Platform integration

**Next Steps:**
1. Review and approve this spec
2. Implement dual authentication in Container (Phase 8)
3. Add admin auth provider factory (Phase 8)
4. Update CLI flags and config for admin credentials (Phase 8)
5. Implement verification commands using admin token (Phase 8)
6. Test with real AGS IAM and Platform APIs (Phase 8)

---

**Document Version:** 4.0 (Major update: Added Dual Token Support)
**Last Updated:** 2025-10-22
**Status:** ✅ Ready for Implementation

**Changelog:**
- **v4.0 (2025-10-22)**: Added dual authentication support (user + admin tokens)
- **v3.0 (2025-10-21)**: Migrated to AccelByte Go SDK
- **v2.0**: Added password authentication mode
- **v1.0**: Initial version with mock and client modes

**SDK Migration Summary:**
- All OAuth2 flows now use `iam.OAuth20Service.TokenGrantV3Short()`
- Parameters use `o_auth2_0.TokenGrantV3Params` struct
- Responses use `OauthmodelTokenResponseV3` model
- SDK handles HTTP client creation, retries, and error mapping
- No manual HTTP request construction needed
