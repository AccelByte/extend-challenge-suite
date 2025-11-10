# Technical Specification: AccelByte Extend Template Architecture

**Version:** 1.0
**Date:** 2025-10-16
**Status:** Reference Documentation

## Table of Contents
1. [Overview](#overview)
2. [Service Extension Template](#service-extension-template)
3. [Event Handler Template](#event-handler-template)
4. [Build & Deployment Patterns](#build--deployment-patterns)
5. [Required Template Modifications](#required-template-modifications)
6. [Testing Strategy](#testing-strategy)

---

## Overview

This document captures the architecture patterns and design decisions from the AccelByte Extend templates. This information was gathered during **Phase 1.5: Template Architecture Deep Dive** (2025-10-16) to understand how to properly implement challenge logic on top of the templates.

### Key Learnings

**Critical Discovery:** Extend templates use a **protobuf-first approach** with gRPC Gateway for REST APIs, not traditional HTTP handlers. This significantly impacts implementation strategy.

**Templates Used:**
- **extend-service-extension-go**: REST API service (port 8000 HTTP, port 6565 gRPC, port 8080 metrics)
- **extend-event-handler-go**: Event processing service (Kafka fully abstracted by Extend platform)

**Philosophy:** Minimize changes to templates to maintain compatibility with upstream updates. Only customize:
- Module names in `go.mod`
- Project descriptions in `README.md`
- Business logic in `internal/` directories
- Database migrations (backend service only)
- Configuration values (not structure)

---

## Service Extension Template

### Protobuf-First REST API Architecture

**Key Discovery:** Uses **protobuf-first approach** with gRPC Gateway for HTTP/REST, NOT manual HTTP handlers.

#### Architecture Flow

```
.proto files → protoc code generation → gRPC service → gRPC-Gateway → HTTP/REST API
```

**How it Works:**
1. Define API in `.proto` files with gRPC service methods
2. Add Google API annotations to map gRPC methods to HTTP routes
3. Run `proto.sh` to generate Go code (gRPC stubs + Gateway code)
4. Implement gRPC service interface in Go
5. gRPC-Gateway automatically translates HTTP/REST requests to gRPC calls

#### Components

**1. Proto Definitions** (`pkg/proto/service.proto`)
- gRPC service methods with Google API annotations
- Maps gRPC to HTTP routes: `option (google.api.http) = { post: "/v1/..." }`
- Permission annotations: `option (permission.action) = CREATE`
- OpenAPI annotations for documentation

**Example Proto Pattern:**
```protobuf
service ChallengeService {
  rpc GetUserChallenges (GetChallengesRequest) returns (GetChallengesResponse) {
    option (permission.action) = READ;
    option (permission.resource) = "NAMESPACE:{namespace}:USER:{userId}:CHALLENGE";
    option (google.api.http) = {
      get: "/v1/challenges"
    };
  }

  rpc ClaimGoalReward (ClaimRewardRequest) returns (ClaimRewardResponse) {
    option (permission.action) = UPDATE;
    option (permission.resource) = "NAMESPACE:{namespace}:USER:{userId}:CHALLENGE";
    option (google.api.http) = {
      post: "/v1/challenges/{challenge_id}/goals/{goal_id}/claim"
      body: "*"
    };
  }
}
```

**2. Code Generation** (`proto.sh` + Makefile)
- Docker-based protoc execution (consistent environment)
- Generates: Go gRPC stubs, gRPC-Gateway code, OpenAPI/Swagger JSON
- Output: `pkg/pb/` (Go code), `gateway/apidocs/` (Swagger)

**Command:**
```bash
# Run proto generation
./proto.sh

# Generates:
# - pkg/pb/*.pb.go           (gRPC service interfaces)
# - pkg/pb/*.pb.gw.go        (gRPC Gateway HTTP translation)
# - gateway/apidocs/swagger.json  (OpenAPI spec)
```

**3. Server Architecture**

The template runs **3 servers simultaneously**:

| Port | Server Type | Purpose |
|------|-------------|---------|
| 6565 | gRPC | Core service implementation |
| 8000 | HTTP | gRPC-Gateway (translates HTTP → gRPC) |
| 8080 | HTTP | Prometheus `/metrics` endpoint |

**All clients use port 8000** (HTTP/REST) - Gateway auto-translates to gRPC on port 6565.

**main.go Pattern:**
```go
// 1. gRPC server (port 6565) - Core service
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(authInterceptor),
    grpc.StatsHandler(otelgrpc.NewServerHandler()),
)
pb.RegisterChallengeServiceServer(grpcServer, challengeHandler)
go func() {
    lis, _ := net.Listen("tcp", ":6565")
    grpcServer.Serve(lis)
}()

// 2. gRPC-Gateway HTTP server (port 8000) - REST API
mux := runtime.NewServeMux()
pb.RegisterChallengeServiceHandlerServer(ctx, mux, challengeHandler)
go func() {
    http.ListenAndServe(":8000", mux)
}()

// 3. Prometheus metrics (port 8080)
go func() {
    http.Handle("/metrics", promhttp.Handler())
    http.ListenAndServe(":8080", nil)
}()
```

**4. Authentication & Authorization**

- **JWT validation** via interceptors (template-provided)
- **Permission checking** against proto annotations
- **Token validator** with auto-refresh (configurable interval)
- **User ID extraction** from JWT claims (`sub` field)
- **Namespace extraction** from JWT claims (`namespace` field)

**Auth Flow:**
1. HTTP request arrives at port 8000 with `Authorization: Bearer <JWT>` header
2. gRPC-Gateway forwards to gRPC server on port 6565
3. Auth interceptor validates JWT signature and expiration
4. Extracts claims (user ID, namespace, permissions)
5. Checks permission annotations on gRPC method
6. If authorized, injects claims into context and calls handler
7. Handler extracts user ID from context (never from request body)

**5. Multi-Stage Dockerfile**

```dockerfile
# Stage 1: Proto generation (protoc container)
FROM rvolosatovs/protoc:4.1.0 AS proto-builder
COPY proto.sh .
COPY pkg/proto/ pkg/proto/
RUN chmod +x proto.sh && ./proto.sh

# Stage 2: Go build (golang:1.24-alpine)
FROM golang:1.24-alpine3.22 AS builder
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=proto-builder /build/pkg/pb pkg/pb
RUN go build -o service

# Stage 3: Runtime (alpine:3.22 with minimal deps)
FROM alpine:3.22
COPY --from=proto-builder /build/gateway/apidocs gateway/apidocs
COPY --from=builder /build/service service
EXPOSE 6565 8000 8080
CMD ["/app/service"]
```

**Pattern Benefits:**
- Reproducible builds (same protoc version)
- Optimized layer caching
- Minimal runtime image size

---

## Event Handler Template

### Event Processing Architecture

**Key Discovery:** AGS **abstracts Kafka completely** - we only implement gRPC handlers.

#### Architecture Flow

```
AGS Kafka → Extend Platform → gRPC call → Our OnMessage handler
```

**No Kafka Code Needed:** Extend platform manages:
- Kafka consumer groups
- Offset commits
- Retries for transient failures
- Dead letter queues for permanent failures

#### Components

**1. Event Proto Definitions** (`pkg/proto/accelbyte-asyncapi/`)

- Downloaded from AGS documentation: https://github.com/AccelByte/accelbyte-api-proto
- IAM events: `iam/account/v1/account.proto`
- Statistic events: `social/statistic/v1/statistic.proto`
- Each event type has its own gRPC service

**Event Schema Structure:**
- Standard event wrapper fields: `id`, `version`, `name`, `namespace`, `timestamp`, `userId`, `traceId`
- Typed payload: `message UserLoggedIn` with specific fields
- OneOf pattern for channels with multiple event types

**Example Event Proto:**
```protobuf
message UserLoggedIn {
    AnonymousSchema19 payload = 1 [json_name = "payload"];  // user_account + user_authentication
    string id = 2;
    string namespace = 5;
    string user_id = 9;
    string timestamp = 7;
    // ... standard event fields
}

service UserAuthenticationUserLoggedInService {
    rpc OnMessage(UserLoggedIn) returns (google.protobuf.Empty);
}
```

**2. Handler Implementation Pattern**

```go
type LoginHandler struct {
    pb.UnimplementedUserAuthenticationUserLoggedInServiceServer
    processor *EventProcessor  // Your business logic
    logger    *logrus.Logger
}

func (h *LoginHandler) OnMessage(ctx context.Context, msg *pb.UserLoggedIn) (*emptypb.Empty, error) {
    // Extract fields from event
    userID := msg.UserId
    namespace := msg.Namespace

    // Process event using your business logic
    err := h.processor.ProcessEvent(ctx, userID, namespace, event)
    if err != nil {
        h.logger.Errorf("Failed to process event: %v", err)
        return &emptypb.Empty{}, status.Errorf(codes.Internal, "failed to process event: %v", err)
    }

    return &emptypb.Empty{}, nil
}
```

**Key Points:**
- Return `&emptypb.Empty{}` on success
- Return gRPC status error on failure
- Extend platform handles retry logic based on error type
- No need to manage Kafka offsets or consumer groups

**3. AGS SDK Integration**

The template shows Platform Service usage:

```go
// Create AGS SDK client
platformClient := factory.NewPlatformClient(configRepo)

// OAuth login for service account
oauthService.LoginClient(&clientId, &clientSecret)

// Use SDK methods
platformClient.FulfillItemShort(userId, itemId, quantity)
```

**Finding SDK Functions:**
- Use Extend SDK MCP Server tools: `mcp__extend-sdk-mcp-server__search_functions`
- Example: Search for "grant entitlement" or "credit wallet"
- Get details: `mcp__extend-sdk-mcp-server__get_bulk_functions`

**4. gRPC Service Registration**

```go
// Create gRPC server
grpcServer := grpc.NewServer(
    grpc.StatsHandler(otelgrpc.NewServerHandler()),
)

// Register event handlers
loginHandler := service.NewLoginHandler(eventProcessor, logger)
pb.RegisterUserAuthenticationUserLoggedInServiceServer(grpcServer, loginHandler)

statHandler := service.NewStatisticHandler(eventProcessor, logger)
pb.RegisterStatItemUpdatedServiceServer(grpcServer, statHandler)

// Enable gRPC reflection for debugging
reflection.Register(grpcServer)

// Enable health check
grpc_health_v1.RegisterHealthServer(grpcServer, health.NewServer())

// Start server on port 6565
lis, _ := net.Listen("tcp", ":6565")
grpcServer.Serve(lis)
```

---

## Build & Deployment Patterns

### Makefile Structure

Both templates use minimal Makefiles:

```makefile
.PHONY: proto build

proto:
    docker run --rm --user $(id -u):$(id -g) \
        --volume $(pwd):/build \
        rvolosatovs/protoc:4.1.0 \
        proto.sh

build: proto
    go build -o service cmd/main.go
```

**Key Points:**
- Minimal targets (keep template simple)
- Proto generation always runs before build
- Docker-based protoc ensures consistency

**Challenge Service Additions:**
```makefile
.PHONY: test lint

test:
    go test ./... -v -coverprofile=coverage.out

lint:
    golangci-lint run ./...

test-all: lint test
    @echo "✅ All checks passed!"
```

### docker-compose Pattern

Both templates have `docker-compose.yaml` for local testing:

```yaml
services:
  service:
    build: .
    ports:
      - "6565:6565"  # gRPC
      - "8000:8000"  # HTTP Gateway
      - "8080:8080"  # Metrics
    environment:
      - AB_CLIENT_ID=${AB_CLIENT_ID}
      - AB_CLIENT_SECRET=${AB_CLIENT_SECRET}
      - AB_BASE_URL=${AB_BASE_URL}
      - AB_NAMESPACE=${AB_NAMESPACE}
```

### Hybrid docker-compose Strategy

**Decision:** Use both root-level and template-level compose files.

**Architecture:**
```
Root Level (extend-challenge/):
└── docker-compose.yml           # Full integration testing
    ├── postgres (shared)
    ├── redis (shared)
    ├── challenge-service
    └── challenge-event-handler

Template Level:
├── extend-challenge-service/
│   └── docker-compose.yaml      # Standalone service development
└── extend-challenge-event-handler/
    └── docker-compose.yaml      # Standalone event handler development
```

**Benefits:**
1. **Root-level compose**: Full system integration tests (both services + DB + Redis)
2. **Template compose**: Independent service development/testing
3. **Flexibility**: Developers can work on one service OR test full system
4. **Template compatibility**: Keep template files for reference/updates

**Test Strategy:**
```bash
# Unit tests (local, mocked)
make test

# Integration tests - option 1: Local full system
docker-compose up -d  # In root directory
go test ./test/integration/...

# Integration tests - option 2: Deployed to AGS
TEST_API_URL=https://namespace.extend.accelbyte.io go test ./test/integration/...
```

---

## Required Template Modifications

### JWT Context Injection

**Problem:** Template validates JWT but doesn't inject claims into context. Handlers need user ID from JWT.

**Solution:** Modify `pkg/common/authServerInterceptor.go` and add context helpers.

#### 1. Change Validator Type

**File:** `pkg/common/authServerInterceptor.go`

**Before:**
```go
var (
    Validator validator.AuthTokenValidator  // Interface type
)
```

**After:**
```go
var (
    Validator *iam.TokenValidator  // Concrete type (to access JwtClaims field)
)
```

**Rationale:** Need to access `JwtClaims` field after validation, which is only available on concrete type.

#### 2. Inject Claims into Context

**File:** `pkg/common/authServerInterceptor.go`

**Modify `checkAuthorizationMetadata()` function:**

```go
func checkAuthorizationMetadata(ctx context.Context, permission *iam.Permission) (context.Context, error) {
    // ... existing validation code ...

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

**Update interceptor functions to use returned context:**
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

#### 3. Add Context Helper Functions

**File:** `pkg/common/context_helpers.go` (CREATE NEW)

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

**File:** `cmd/main.go`

**Option A: Type assertion**
```go
common.Validator = common.NewTokenValidator(authService, refreshInterval, validateLocally).(*iam.TokenValidator)
```

**Option B: Modify NewTokenValidator return type**
```go
func NewTokenValidator(...) *iam.TokenValidator {
    return &iam.TokenValidator{
        // ... existing initialization
    }
}
```

### Usage in Handlers

```go
func (h *ChallengeHandler) GetUserChallenges(
    ctx context.Context,
    req *pb.GetChallengesRequest,
) (*pb.GetChallengesResponse, error) {
    // Extract user ID from JWT (injected by auth interceptor)
    userID := common.GetUserIDFromContext(ctx)
    if userID == "" {
        return nil, status.Error(codes.Unauthenticated, "user ID not found in token")
    }

    // Never trust user ID from request body - always use JWT claims
    challenges, err := h.service.GetUserChallenges(ctx, userID)
    // ...
}
```

---

## Testing Strategy

### Local Testing with docker-compose

**1. Start Services:**
```bash
# Root directory - full system
docker-compose up -d

# Services available:
# - HTTP Gateway: http://localhost:8000 (REST API)
# - gRPC: localhost:6565 (internal)
# - Metrics: http://localhost:8080/metrics
```

**2. Test REST API:**
```bash
# Get challenges
curl -H "Authorization: Bearer <JWT>" http://localhost:8000/v1/challenges

# Claim reward
curl -X POST \
  -H "Authorization: Bearer <JWT>" \
  http://localhost:8000/v1/challenges/winter-2025/goals/kill-10-snowmen/claim
```

**3. Test Event Handler (gRPC):**
```bash
# Use grpcurl for manual testing
grpcurl -plaintext \
  -d '{"user_id": "user123", "namespace": "mygame"}' \
  localhost:6565 \
  accelbyte.iam.account.v1.UserAuthenticationUserLoggedInService/OnMessage
```

### Unit Testing

**Mock Template Components:**
```go
// Mock JWT validator
type MockValidator struct{}

func (m *MockValidator) Validate(token string, permission *iam.Permission, namespace *string, clientID *string) error {
    // Mock validation logic
    return nil
}

// Test handler
func TestGetUserChallenges(t *testing.T) {
    // Inject mock user ID into context
    ctx := context.WithValue(context.Background(), contextKeyUserID, "testuser123")

    handler := NewChallengeHandler(mockService, mockCache)
    resp, err := handler.GetUserChallenges(ctx, &pb.GetChallengesRequest{})

    assert.NoError(t, err)
    assert.NotNil(t, resp)
}
```

### Integration Testing

**Test Against Real AGS:**
```go
func TestE2E_ClaimReward(t *testing.T) {
    // Get JWT from AGS IAM
    jwt := getTestUserJWT()

    // Call API
    req := &pb.ClaimRewardRequest{
        ChallengeId: "winter-2025",
        GoalId: "kill-10-snowmen",
    }

    ctx := metadata.AppendToOutgoingContext(context.Background(),
        "authorization", "Bearer "+jwt)

    resp, err := client.ClaimGoalReward(ctx, req)

    assert.NoError(t, err)
    assert.Equal(t, "claimed", resp.Status)
}
```

---

## Key Takeaways for Implementation

### 1. Follow Template Patterns Religiously
- Don't reinvent auth, metrics, logging - use what's provided
- Only modify `service.proto` and business logic in `internal/`
- Keep template's Makefile, Dockerfile structure intact

### 2. Proto-First Development
- Define API in proto → generate code → implement handlers
- Never write HTTP handlers manually
- Use gRPC Gateway for REST API (automatic translation)

### 3. Event Handler is Simple
- Just implement `OnMessage(context.Context, *Event) (*emptypb.Empty, error)`
- Extend platform handles all Kafka complexity
- No consumer groups, offsets, or retry logic needed

### 4. Testing Strategy
- Mock interfaces for unit tests
- Use docker-compose for integration tests
- Can test against real AGS deployment
- No need for "fake AGS" mode - use real services or mocks

### 5. Keep Templates Updated
- Minimal modifications to template files
- Easy to pull upstream updates from AccelByte repos
- Document all modifications in this spec

---

## References

- **Extend Service Extension Template**: https://github.com/AccelByte/extend-service-extension-go
- **Extend Event Handler Template**: https://github.com/AccelByte/extend-event-handler-go
- **AccelByte API Proto**: https://github.com/AccelByte/accelbyte-api-proto
- **gRPC Gateway**: https://github.com/grpc-ecosystem/grpc-gateway
- **Protocol Buffers**: https://protobuf.dev/

---

**Document Status:** Complete - Reference documentation from Phase 1.5 analysis
