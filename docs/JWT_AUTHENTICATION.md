# JWT Authentication Architecture

**Last Updated**: 2025-10-19
**Component**: extend-challenge-service (REST API)

---

## Overview

The Challenge Service uses a **centralized JWT authentication approach** where the auth interceptor validates JWT tokens and extracts user claims into the request context. Service handlers then retrieve user information from context without needing to understand JWT format or perform decoding.

---

## Authentication Flow

```
┌─────────────┐
│   Client    │
│ (Game SDK)  │
└──────┬──────┘
       │ 1. HTTP Request
       │    Authorization: Bearer <jwt>
       ▼
┌─────────────────────────────────────────────────────────────┐
│ gRPC Gateway (HTTP → gRPC)                                  │
│ Converts REST request to gRPC with metadata                 │
└──────┬──────────────────────────────────────────────────────┘
       │ 2. gRPC Request
       │    Metadata: authorization = "Bearer <jwt>"
       ▼
┌─────────────────────────────────────────────────────────────┐
│ Auth Interceptor (authServerInterceptor.go)                 │
│                                                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Step 3: checkAuthorizationMetadata()                    │ │
│ │                                                          │ │
│ │ a. Extract JWT from metadata                            │ │
│ │ b. Validate JWT signature using AccelByte validator     │ │
│ │ c. Check expiration and permissions                     │ │
│ │ d. Decode JWT payload (base64 → JSON)                   │ │
│ │ e. Extract claims: user_id, namespace                   │ │
│ │ f. Store claims in context                              │ │
│ │                                                          │ │
│ │    ctx = context.WithValue(ctx, ContextKeyUserID, ...)  │ │
│ │    ctx = context.WithValue(ctx, ContextKeyNamespace,...)│ │
│ └─────────────────────────────────────────────────────────┘ │
└──────┬──────────────────────────────────────────────────────┘
       │ 4. Modified context with user claims
       ▼
┌─────────────────────────────────────────────────────────────┐
│ gRPC Handler (challenge_service_server.go)                  │
│                                                              │
│ func (s *Server) GetUserChallenges(ctx, req) {              │
│     // Extract user ID from context (no JWT decoding!)      │
│     userID, err := common.GetUserIDFromContext(ctx)         │
│                                                              │
│     // Use userID for business logic                        │
│     challenges := s.service.GetChallenges(userID)           │
│     ...                                                      │
│ }                                                            │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Components

### 1. Auth Interceptor (`pkg/common/authServerInterceptor.go`)

**Responsibilities:**
- Validate JWT signature using AccelByte's token validator
- Check JWT expiration and permissions
- Decode JWT payload and extract claims
- Store user_id and namespace in context
- Provide helper functions for context extraction

**Key Functions:**
```go
// Called by gRPC interceptor for every request
func checkAuthorizationMetadata(ctx context.Context, permission *iam.Permission) (context.Context, error)

// Decodes JWT payload (base64 → JSON)
func decodeJWTClaims(token string) (*JWTClaims, error)

// Extract user ID from context (called by handlers)
func GetUserIDFromContext(ctx context.Context) (string, error)

// Extract namespace from context
func GetNamespaceFromContext(ctx context.Context) string
```

**Context Keys:**
```go
const (
    ContextKeyUserID    contextKey = "user_id"
    ContextKeyNamespace contextKey = "namespace"
)
```

### 2. Service Handlers (`pkg/server/challenge_service_server.go`)

**Responsibilities:**
- Extract user ID from context (NOT from JWT)
- Implement business logic
- Return gRPC responses

**Example:**
```go
func (s *ChallengeServiceServer) GetUserChallenges(ctx context.Context, req *pb.Request) (*pb.Response, error) {
    // Extract authenticated user ID from context
    userID, err := extractUserIDFromContext(ctx)
    if err != nil {
        return nil, err
    }

    // extractUserIDFromContext is a wrapper around common.GetUserIDFromContext
    // No JWT decoding happens here!

    // Use userID for business logic
    challenges, err := s.service.GetChallenges(ctx, userID, s.namespace)
    ...
}
```

---

## Benefits

### 1. **Single Point of JWT Validation (DRY)**
- JWT validation logic exists in ONE place (auth interceptor)
- No duplicate JWT decoding across multiple handlers
- Consistent error handling for authentication failures

### 2. **Simplified Handlers**
- Handlers don't need to understand JWT format
- No base64 decoding or JSON parsing in business logic
- Clear separation of concerns (auth vs. business logic)

### 3. **Performance**
- JWT decoded **once per request** in the interceptor
- Context value lookup is O(1) in handlers
- No redundant cryptographic operations

### 4. **Easy Testing**
Service handler tests don't need to construct valid JWTs:

```go
// Before (complex):
token := createJWTToken("user123", "test-namespace")
md := metadata.New(map[string]string{"authorization": "Bearer " + token})
ctx := metadata.NewIncomingContext(context.Background(), md)

// After (simple):
ctx := context.WithValue(context.Background(), common.ContextKeyUserID, "user123")
ctx = context.WithValue(ctx, common.ContextKeyNamespace, "test-namespace")
```

### 5. **Security**
- JWT validation happens BEFORE any business logic
- Signature verification by AccelByte validator
- Expiration check ensures no expired tokens
- Permission validation per endpoint

---

## JWT Claims Structure

AccelByte JWT tokens contain standard claims:

```json
{
  "sub": "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d",  // User ID (UUID)
  "namespace": "mygame-prod",                      // Namespace
  "exp": 1729238400,                               // Expiration (Unix timestamp)
  "iat": 1729234800,                               // Issued at (Unix timestamp)
  "aud": ["accelbyte"],                            // Audience
  "iss": "https://demo.accelbyte.io/iam",          // Issuer
  "roles": [...],                                   // User roles
  "permissions": [...]                              // User permissions
}
```

**We extract:**
- `sub` → user_id (stored in context)
- `namespace` → namespace (stored in context)

**AccelByte Validator checks:**
- Signature validity (RSA public key)
- Expiration (`exp` claim)
- Permissions (based on proto annotations)
- Revoked users (optional)

---

## Configuration

### Environment Variables

```bash
# AccelByte credentials for JWT validation
AB_CLIENT_ID="your-client-id"
AB_CLIENT_SECRET="your-client-secret"
AB_BASE_URL="https://demo.accelbyte.io"
AB_NAMESPACE="mygame-prod"
```

### Initialization (in main.go)

```go
import (
    "extend-challenge-service/pkg/common"
    "github.com/AccelByte/accelbyte-go-sdk/services-api/pkg/service/iam"
)

// Initialize JWT validator
authService := iam.OAuth20Service{...}
common.Validator = common.NewTokenValidator(
    authService,
    15*time.Minute,  // Refresh interval for public keys
    true,            // Enable local validation
)

// Register auth interceptor
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(
        common.NewUnaryAuthServerIntercept(
            common.NewProtoPermissionExtractor(),
        ),
    ),
)
```

---

## Testing

### Unit Tests (Service Handlers)

Mock the auth interceptor by setting context values:

```go
func TestGetUserChallenges_Success(t *testing.T) {
    // Simulate auth interceptor
    ctx := context.Background()
    ctx = context.WithValue(ctx, common.ContextKeyUserID, "test-user-123")
    ctx = context.WithValue(ctx, common.ContextKeyNamespace, "test-namespace")

    // Call handler
    resp, err := server.GetUserChallenges(ctx, &pb.GetChallengesRequest{})

    assert.NoError(t, err)
    assert.NotNil(t, resp)
}
```

### Integration Tests (End-to-End)

Use real JWT tokens for full flow testing:

```go
// Get JWT token from AccelByte IAM
token := getValidJWTToken()

// Create gRPC metadata
md := metadata.New(map[string]string{
    "authorization": "Bearer " + token,
})
ctx := metadata.NewOutgoingContext(context.Background(), md)

// Make gRPC call
resp, err := grpcClient.GetUserChallenges(ctx, &pb.GetChallengesRequest{})
```

---

## Error Handling

### Authentication Errors

| Error | gRPC Code | Cause |
|-------|-----------|-------|
| Metadata missing | `Unauthenticated` | No authorization header |
| Invalid JWT format | `Unauthenticated` | Malformed token (not 3 parts) |
| Invalid signature | `PermissionDenied` | JWT signature verification failed |
| Token expired | `PermissionDenied` | JWT `exp` claim in the past |
| Missing user ID | `Unauthenticated` | JWT `sub` claim is empty |
| User ID not in context | `Unauthenticated` | Handler called without auth interceptor |

### Example Error Logs

```
level=error msg="Failed to extract user ID from context"
  error="rpc error: code = Unauthenticated desc = user ID not found in context"

level=error msg="JWT validation failed"
  error="rpc error: code = PermissionDenied desc = token expired"
```

---

## Health Check Exception

The `/healthz` endpoint **skips authentication**:

```go
func skipCheckAuthorizationMetadata(fullMethod string) bool {
    if strings.HasPrefix(fullMethod, "/grpc.health.v1.Health/") {
        return true
    }
    // Health check accessible without JWT
    return false
}
```

This allows Kubernetes liveness/readiness probes to work without authentication.

---

## Migration Notes

### Before (Phase 6.5 Initial)

Service handlers decoded JWT directly:

```go
func extractUserIDFromContext(ctx context.Context) (string, error) {
    md, _ := metadata.FromIncomingContext(ctx)
    token := strings.TrimPrefix(md["authorization"][0], "Bearer ")

    // Decode JWT payload
    parts := strings.Split(token, ".")
    payload, _ := base64.RawURLEncoding.DecodeString(parts[1])

    // Parse claims
    var claims JWTClaims
    json.Unmarshal(payload, &claims)

    return claims.Sub, nil
}
```

**Problems:**
- JWT decoded multiple times per request
- Duplicate code across handlers
- Hard to test (need valid JWT tokens)

### After (Refactored)

Auth interceptor handles JWT, handlers use context:

```go
// In auth interceptor
ctx = context.WithValue(ctx, ContextKeyUserID, claims.Sub)

// In service handler
func extractUserIDFromContext(ctx context.Context) (string, error) {
    return common.GetUserIDFromContext(ctx)
}
```

**Benefits:**
- JWT decoded once per request
- Single source of truth
- Easy to test (mock context)

---

## References

- **AccelByte JWT Documentation**: https://docs.accelbyte.io/gaming-services/services/access/authorization/jwt/
- **Template Auth Interceptor**: extend-service-extension-go/pkg/common/authServerInterceptor.go
- **gRPC Interceptors**: https://github.com/grpc/grpc-go/tree/master/examples/features/interceptor

---

## See Also

- `pkg/common/authServerInterceptor.go` - Auth interceptor implementation
- `pkg/server/challenge_service_server.go` - Service handler examples
- `pkg/server/challenge_service_server_test.go` - Testing patterns
- `docs/TECH_SPEC_API.md` - API authentication specification
