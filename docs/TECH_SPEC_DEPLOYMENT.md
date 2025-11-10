# Technical Specification: Deployment

**Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Local Development](#local-development)
2. [Docker Configuration](#docker-configuration)
3. [Testing Event Handler Locally](#testing-event-handler-locally-no-kafka-required)
4. [Integration Testing Setup](#integration-testing-setup-to-be-decided-in-phase-15)
5. [AccelByte Extend Deployment](#accelbyte-extend-deployment)
6. [Database Migrations](#database-migrations)
7. [Monitoring and Operations](#monitoring-and-operations)

---

## Local Development

### Build & Deployment Architecture

**Decision:** Hybrid docker-compose strategy for maximum flexibility

**Architecture:**
```
extend-challenge/                      # Root workspace
├── docker-compose.yml                 # Full integration (all services + DB)
├── extend-challenge-service/
│   ├── docker-compose.yaml            # Standalone service development
│   ├── Dockerfile                     # Multi-stage build with proto generation
│   ├── Makefile                       # From template (proto, build, test)
│   └── proto.sh                       # Docker-based protoc
└── extend-challenge-event-handler/
    ├── docker-compose.yaml            # Standalone event handler development
    ├── Dockerfile                     # Multi-stage build with proto generation
    ├── Makefile                       # From template
    └── proto.sh                       # Docker-based protoc
```

**Development Workflows:**

1. **Full System Integration Testing**
   ```bash
   # Start all services (API + Event Handler + DB + Redis)
   cd extend-challenge
   docker-compose up -d
   ```

2. **Standalone Service Development**
   ```bash
   # Work on API service only
   cd extend-challenge-service
   docker-compose up -d  # Uses template's compose file
   ```

3. **Standalone Event Handler Development**
   ```bash
   # Work on event handler only
   cd extend-challenge-event-handler
   docker-compose up -d  # Uses template's compose file
   ```

**Benefits:**
- ✅ Root-level compose for E2E integration tests
- ✅ Per-service compose for focused development
- ✅ Maintains template compatibility
- ✅ Maximum flexibility for different workflows

### Makefile Patterns (From Templates)

Both templates provide minimal, focused Makefiles:

```makefile
.PHONY: proto build test

proto:
	./proto.sh

build: proto
	go build -o bin/service ./cmd/main.go

test:
	go test ./... -v
```

**Key Points:**
- Proto generation always runs before build
- Docker-based protoc ensures consistent environment
- Keep Makefile simple - follow template patterns

### Prerequisites

```bash
# Required tools
- Docker Desktop (or Docker Engine + Docker Compose)
- Go 1.25+
- golang-migrate CLI
- PostgreSQL client (psql) - optional for debugging
- Git
```

### Installation Steps

#### 1. Install Docker

**macOS:**
```bash
brew install docker docker-compose
```

**Linux:**
```bash
# Install Docker Engine
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

#### 2. Install Go

```bash
# macOS
brew install go

# Linux
wget https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

#### 3. Install golang-migrate

```bash
# macOS
brew install golang-migrate

# Linux
curl -L https://github.com/golang-migrate/migrate/releases/download/v4.16.2/migrate.linux-amd64.tar.gz | tar xvz
sudo mv migrate /usr/local/bin/
```

### Project Setup

```bash
# 1. Clone repository
cd extend-challenge

# 2. Copy environment template
cp .env.example .env

# 3. Edit .env with your AGS credentials
nano .env
# Fill in:
# - NAMESPACE (your AGS namespace)
# - AGS_CLIENT_ID (from AGS Admin Portal)
# - AGS_CLIENT_SECRET (from AGS Admin Portal)

# 4. Start infrastructure
docker-compose up -d postgres redis

# 5. Run database migrations
cd extend-challenge-service
export DATABASE_URL="postgres://postgres:secretpassword@localhost:5432/challenge_db?sslmode=disable"
migrate -path migrations -database "${DATABASE_URL}" up

# 6. Build services
cd extend-challenge-service
make build

cd ../extend-challenge-event-handler
make build

# 7. Start all services
cd ..
docker-compose up
```

### Accessing Services

| Service | URL | Credentials |
|---------|-----|-------------|
| REST API | http://localhost:8080 | Bearer token from AGS IAM |
| PostgreSQL | localhost:5432 | postgres / secretpassword |
| Redis | localhost:6379 | (no password) |

### Development Workflow

```bash
# Run unit tests
cd extend-challenge-service
make test

cd ../extend-challenge-event-handler
make test

# Run integration tests
cd ../tests/integration
TEST_API_URL=http://localhost:8080 go test -v ./...

# Test event handler via direct gRPC calls (no Kafka needed)
# See section below for details

# View logs
docker-compose logs -f challenge-service
docker-compose logs -f challenge-event-handler

# Restart service after code changes
docker-compose restart challenge-service

# Stop all services
docker-compose down

# Clean up (removes volumes)
docker-compose down -v
```

---

## Docker Configuration

### Docker Compose Strategy (To Be Decided in Phase 1.5)

**Note**: The docker-compose.yml structure shown below is preliminary and will be revised after studying the templates. Key questions:

1. Do the templates already include docker-compose files?
2. Should we have one docker-compose at root, or per-service, or both?
3. How should integration tests reference services (same compose file or separate)?

See Phase 1.5 action items above for the decision-making process.

### docker-compose.yml (Preliminary)

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: redis-server ${REDIS_PASSWORD:+--requirepass $REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  challenge-service:
    build:
      context: ./extend-challenge-service
      dockerfile: Dockerfile
    env_file: .env
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ./extend-challenge-service/config:/app/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5

  challenge-event-handler:
    build:
      context: ./extend-challenge-event-handler
      dockerfile: Dockerfile
    env_file: .env
    ports:
      - "6565:6565"  # gRPC port for local testing (no Kafka needed)
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ./extend-challenge-event-handler/config:/app/config

volumes:
  postgres_data:
  redis_data:
```

### Dockerfile Pattern (From Templates)

**Key Pattern:** 3-stage build for proto generation, Go build, and minimal runtime

**Path:** `extend-challenge-service/Dockerfile` (similar for event handler)

```dockerfile
# Stage 1: Proto generation
FROM rvolosatovs/protoc:4.1.0 AS proto-builder
WORKDIR /build
COPY proto.sh .
COPY pkg/proto/ pkg/proto/
RUN chmod +x proto.sh && ./proto.sh

# Stage 2: Go build
FROM golang:1.24-alpine3.22 AS builder
WORKDIR /build

# Copy go.mod and download dependencies
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Copy generated proto files from stage 1
COPY --from=proto-builder /build/pkg/pb pkg/pb

# Build binary
RUN go build -o service main.go

# Stage 3: Runtime
FROM alpine:3.22
WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/service .

# Copy generated API docs for Swagger UI
COPY --from=proto-builder /build/gateway/apidocs gateway/apidocs

# Copy config file (challenges.json)
COPY config/challenges.json /app/config/

# Copy database migrations (service only)
COPY migrations/ /app/migrations/

# Expose ports
# Service: 6565 (gRPC), 8000 (HTTP Gateway), 8080 (Metrics)
# Event Handler: 6565 (gRPC), 8080 (Metrics)
EXPOSE 6565 8000 8080

# Run service
CMD ["/app/service"]
```

**Key Features:**
- ✅ **Stage 1:** Docker-based protoc ensures reproducible builds
- ✅ **Stage 2:** Go build with generated proto code
- ✅ **Stage 3:** Minimal runtime image (~50MB)
- ✅ **Multi-architecture:** Works on amd64 and arm64
- ✅ **API docs:** Swagger JSON baked into image

**Customizations for Challenge Service:**
```dockerfile
# Add challenges.json config
COPY config/challenges.json /app/config/

# Add database migrations
COPY migrations/ /app/migrations/
```

**Event Handler Dockerfile:**
Same pattern, but:
- No migrations folder
- No HTTP Gateway (port 8000)
- Only expose gRPC (6565) and metrics (8080)

### Build and Push Images

```bash
# Build service image
cd extend-challenge-service
docker build -t challenge-service:v1.0.0 .

# Build event handler image
cd ../extend-challenge-event-handler
docker build -t challenge-event-handler:v1.0.0 .

# Tag for registry (replace with your registry)
docker tag challenge-service:v1.0.0 your-registry/challenge-service:v1.0.0
docker tag challenge-event-handler:v1.0.0 your-registry/challenge-event-handler:v1.0.0

# Push to registry
docker push your-registry/challenge-service:v1.0.0
docker push your-registry/challenge-event-handler:v1.0.0
```

### Testing Event Handler Locally (No Kafka Required)

**Key Discovery:** AGS Extend platform completely abstracts Kafka - locally test via direct gRPC calls.

#### Architecture Comparison

**Production (AGS Extend):**
```
User Action → Game Server → AGS Service → Kafka → Extend Platform → gRPC → Your OnMessage Handler
```

**Local Development:**
```
Test Script → gRPC Client → Your OnMessage Handler
```

#### Why No Kafka Locally?

- ✅ **Simpler setup**: No Kafka broker needed
- ✅ **Faster iteration**: Direct gRPC calls
- ✅ **Same code path**: OnMessage handlers work identically
- ✅ **Template pattern**: Event handler listens on port 6565 (gRPC)

#### Testing Approach

**Option 1: Use grpcurl (Recommended)**

```bash
# Install grpcurl
brew install grpcurl  # macOS
# or
go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest

# Call event handler with test event
grpcurl -plaintext \
  -d '{
    "id": "test-event-001",
    "namespace": "mygame",
    "userId": "test-user-123",
    "eventType": "statItemUpdated",
    "payload": "{\"statCode\":\"snowman_kills\",\"value\":7}",
    "timestamp": "2025-10-15T10:00:00Z"
  }' \
  localhost:6565 \
  accelbyte.EventHandler/HandleEvent
```

**Option 2: Write Go Test Client**

```go
// tests/event_client_test.go
package tests

import (
    "context"
    "testing"
    pb "github.com/AccelByte/accelbyte-api-proto/asyncapi/accelbyte/event/v1"
    "google.golang.org/grpc"
)

func TestEventHandler(t *testing.T) {
    // Connect to event handler gRPC server
    conn, err := grpc.Dial("localhost:6565", grpc.WithInsecure())
    if err != nil {
        t.Fatalf("Failed to connect: %v", err)
    }
    defer conn.Close()

    client := pb.NewEventHandlerClient(conn)

    // Send test event
    event := &pb.Event{
        Id:        "test-event-001",
        Namespace: "mygame",
        UserId:    "test-user-123",
        EventType: "statItemUpdated",
        Payload:   `{"statCode":"snowman_kills","value":7}`,
        Timestamp: "2025-10-15T10:00:00Z",
    }

    resp, err := client.HandleEvent(context.Background(), event)
    if err != nil {
        t.Fatalf("HandleEvent failed: %v", err)
    }

    if !resp.Success {
        t.Errorf("Event processing failed")
    }
}
```

**Option 3: Use Postman/BloomRPC**

- Import proto definitions from extend-event-handler-go template
- Create gRPC requests with test event payloads
- Send to `localhost:6565`

#### Event Handler gRPC Port

The event handler template typically exposes gRPC on port **6565** (verify in Phase 1.5 when studying templates).

Update docker-compose.yml to expose the port:

```yaml
challenge-event-handler:
  build:
    context: ./extend-challenge-event-handler
    dockerfile: Dockerfile
  env_file: .env
  ports:
    - "6565:6565"  # Add this for local testing
  depends_on:
    postgres:
      condition: service_healthy
```

#### Test Workflow

```bash
# 1. Start services
docker-compose up -d

# 2. Verify event handler is listening
grpcurl -plaintext localhost:6565 list

# 3. Send test login event
grpcurl -plaintext -d '{
  "id": "login-001",
  "namespace": "mygame",
  "userId": "user-123",
  "eventType": "userLoggedIn",
  "payload": "{}",
  "timestamp": "2025-10-15T10:00:00Z"
}' localhost:6565 accelbyte.EventHandler/HandleEvent

# 4. Check database for progress update
psql -h localhost -U postgres -d challenge_db \
  -c "SELECT * FROM user_goal_progress WHERE user_id = 'user-123';"

# 5. Send stat update event
grpcurl -plaintext -d '{
  "id": "stat-001",
  "namespace": "mygame",
  "userId": "user-123",
  "eventType": "statItemUpdated",
  "payload": "{\"statCode\":\"snowman_kills\",\"value\":10}",
  "timestamp": "2025-10-15T10:05:00Z"
}' localhost:6565 accelbyte.EventHandler/HandleEvent

# 6. Verify progress updated
psql -h localhost -U postgres -d challenge_db \
  -c "SELECT * FROM user_goal_progress WHERE user_id = 'user-123';"
```

#### Integration Test Example

```go
// tests/integration/event_to_claim_test.go
func TestEventToClaimFlow(t *testing.T) {
    // 1. Send event via gRPC to event handler
    eventClient := createEventHandlerClient("localhost:6565")
    sendStatUpdateEvent(eventClient, "user-123", "snowman_kills", 10)

    // 2. Wait for buffer flush (1 second)
    time.Sleep(2 * time.Second)

    // 3. Query API to check progress
    apiClient := createAPIClient("http://localhost:8080")
    challenges := apiClient.GetChallenges("user-123")

    // 4. Verify goal completed
    goal := findGoal(challenges, "kill-10-snowmen")
    assert.Equal(t, "completed", goal.Status)
    assert.Equal(t, 10, goal.Progress)

    // 5. Claim reward via API
    claimResult := apiClient.ClaimReward("user-123", "winter-challenge", "kill-10-snowmen")
    assert.Equal(t, "claimed", claimResult.Status)

    // 6. Verify cannot claim again
    _, err := apiClient.ClaimReward("user-123", "winter-challenge", "kill-10-snowmen")
    assert.ErrorContains(t, err, "ALREADY_CLAIMED")
}
```

**Proto Reflection Enabled:** Templates enable gRPC reflection, making grpcurl commands work without proto files.

---

### Integration Testing Strategy

**Implemented:** Hybrid docker-compose approach (documented at top of this file)

**End-to-End Test Workflow:**

```bash
# 1. Start full system (from root)
cd extend-challenge
docker-compose up -d

# 2. Wait for services to be healthy
docker-compose ps

# 3. Run integration tests
# Test event handler with gRPC
grpcurl -plaintext -d '{...event...}' localhost:6565 accelbyte.EventHandler/OnMessage

# Test API service with HTTP
curl -H "Authorization: Bearer $JWT" http://localhost:8000/v1/challenges

# 4. Run automated integration test suite
go test ./tests/integration/... -v

# 5. Tear down
docker-compose down
```

**CI/CD Integration:**
```yaml
# .github/workflows/integration-test.yml
- name: Run Integration Tests
  run: |
    docker-compose up -d
    sleep 10  # Wait for services
    go test ./tests/integration/... -v
    docker-compose down
```

---

## AccelByte Extend Deployment

### Prerequisites

1. **AccelByte Admin Portal Access**
   - Namespace admin or higher permissions
   - Ability to create service accounts

2. **Service Account**
   ```
   Go to: Admin Portal → Namespace → Service Accounts → Create
   Permissions needed:
   - NAMESPACE:{namespace}:PLATFORM:ENTITLEMENT [CREATE]
   - NAMESPACE:{namespace}:PLATFORM:WALLET [UPDATE]
   ```

**Note**: Kafka topic subscriptions are configured in the Extend app deployment config below. The Extend platform handles all Kafka consumer setup - you do not need to manually configure Kafka topics or consumer groups.

### Deployment Steps

#### 1. Prepare Configuration

Create `extend-app-config.yaml`:

```yaml
# Service Extension (REST API)
serviceExtension:
  name: challenge-service
  image: your-registry/challenge-service:v1.0.0
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  env:
    - name: NAMESPACE
      value: "mygame"
    - name: DB_HOST
      value: "postgres.database.svc.cluster.local"
    - name: AGS_CLIENT_ID
      valueFrom:
        secretKeyRef:
          name: challenge-service-secret
          key: client-id
    - name: AGS_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: challenge-service-secret
          key: client-secret
  healthCheck:
    path: /healthz
    port: 8080

# Event Handler
eventHandler:
  name: challenge-event-handler
  image: your-registry/challenge-event-handler:v1.0.0
  replicas: 2
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  env:
    - name: NAMESPACE
      value: "mygame"
    - name: DB_HOST
      value: "postgres.database.svc.cluster.local"
    - name: AGS_CLIENT_ID
      valueFrom:
        secretKeyRef:
          name: challenge-event-handler-secret
          key: client-id
    - name: AGS_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: challenge-event-handler-secret
          key: client-secret
  # Kafka subscription (production only - Extend platform manages this)
  # For local testing, use direct gRPC calls to event handler
  kafkaSubscription:
    topics:
      - "{namespace}.iam.account.v1.userLoggedIn"
      - "{namespace}.social.statistic.v1.statItemUpdated"
    consumerGroup: "challenge-event-handler"
```

#### 2. Create Secrets

```bash
# Service secrets
kubectl create secret generic challenge-service-secret \
  --from-literal=client-id=YOUR_CLIENT_ID \
  --from-literal=client-secret=YOUR_CLIENT_SECRET \
  -n mygame

# Event handler secrets
kubectl create secret generic challenge-event-handler-secret \
  --from-literal=client-id=YOUR_CLIENT_ID \
  --from-literal=client-secret=YOUR_CLIENT_SECRET \
  -n mygame
```

#### 3. Deploy via AccelByte Extend CLI

```bash
# Install Extend CLI
npm install -g @accelbyte/extend-cli

# Login
extend-cli login

# Deploy service extension
extend-cli deploy service \
  --namespace mygame \
  --config extend-app-config.yaml \
  --app challenge-service

# Deploy event handler
extend-cli deploy event-handler \
  --namespace mygame \
  --config extend-app-config.yaml \
  --app challenge-event-handler
```

#### 4. Verify Deployment

```bash
# Check service status
extend-cli status service --namespace mygame --app challenge-service

# Check event handler status
extend-cli status event-handler --namespace mygame --app challenge-event-handler

# View logs
extend-cli logs service --namespace mygame --app challenge-service --tail 100
extend-cli logs event-handler --namespace mygame --app challenge-event-handler --tail 100
```

### Infrastructure Requirements

#### Database

**Option 1: Managed PostgreSQL (Recommended)**
- AWS RDS PostgreSQL
- Google Cloud SQL for PostgreSQL
- Azure Database for PostgreSQL

**Specifications:**
- Version: PostgreSQL 15+
- Instance: db.m5.large (2 vCPU, 8 GB RAM)
- Storage: 100 GB SSD with auto-scaling
- Connections: max_connections = 200

**Option 2: Self-Hosted PostgreSQL**
```bash
# Using Kubernetes StatefulSet
kubectl apply -f postgres-statefulset.yaml
```

#### Redis (Optional for M1)

**Option 1: Managed Redis**
- AWS ElastiCache for Redis
- Google Cloud Memorystore
- Azure Cache for Redis

**Specifications:**
- Version: Redis 7+
- Instance: cache.m5.large (2 vCPU, 6.4 GB RAM)
- Persistence: AOF enabled

**Option 2: Not required for M1**
- Template includes Redis support
- Not critical for M1 functionality
- Can skip Redis deployment

---

## Database Migrations

### Running Migrations in Production

#### Option 1: Init Container (Recommended)

Add init container to service Deployment:

```yaml
initContainers:
  - name: migrate
    image: migrate/migrate
    command:
      - migrate
      - -path
      - /migrations
      - -database
      - $(DATABASE_URL)
      - up
    env:
      - name: DATABASE_URL
        value: "postgres://user:pass@postgres:5432/challenge_db?sslmode=require"
    volumeMounts:
      - name: migrations
        mountPath: /migrations
volumes:
  - name: migrations
    configMap:
      name: challenge-migrations
```

#### Option 2: Manual Migration Job

```bash
# Create migration Job
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: challenge-migrate
  namespace: mygame
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: migrate/migrate
        command:
          - migrate
          - -path
          - /migrations
          - -database
          - \$(DATABASE_URL)
          - up
        env:
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: database-secret
                key: url
        volumeMounts:
          - name: migrations
            mountPath: /migrations
      restartPolicy: Never
      volumes:
        - name: migrations
          configMap:
            name: challenge-migrations
EOF

# Check migration status
kubectl logs job/challenge-migrate -n mygame
```

#### Option 3: Standalone Migration Script

```bash
# From local machine (requires network access to production DB)
export DATABASE_URL="postgres://user:pass@prod-db:5432/challenge_db?sslmode=require"

# Dry run (check what will be applied)
migrate -path migrations -database "${DATABASE_URL}" version

# Apply migrations
migrate -path migrations -database "${DATABASE_URL}" up

# Rollback (if needed)
migrate -path migrations -database "${DATABASE_URL}" down 1
```

### Migration Safety

**Pre-Deployment Checklist:**
- [ ] Backup database before migration
- [ ] Test migration on staging environment
- [ ] Review migration SQL for destructive operations
- [ ] Ensure migration is idempotent
- [ ] Plan rollback strategy

**Rollback Plan:**
```bash
# If migration fails, rollback
migrate -path migrations -database "${DATABASE_URL}" down 1

# Restore from backup if necessary
pg_restore -h prod-db -U postgres -d challenge_db backup.sql
```

---

## Monitoring and Operations

### Health Checks

#### Liveness Probe

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

**Endpoint:** `GET /healthz`
**Response:** `{"status": "healthy"}`
**Purpose:** Restart pod if unhealthy

**Note:** Extend environment only supports `/healthz` endpoint. Use this for both liveness and readiness probes.

### Metrics

#### Prometheus Metrics Endpoint

```
GET /metrics
```

**Key Metrics:**
```
# Event processing
challenge_event_processing_seconds_bucket
challenge_event_processing_seconds_count
challenge_event_processing_seconds_sum

# API latency
challenge_api_request_duration_seconds_bucket
challenge_api_request_duration_seconds_count

# Database
challenge_db_query_duration_seconds_bucket
challenge_db_connections_active

# Buffering
challenge_buffer_size
challenge_flush_duration_seconds_bucket
```

#### Grafana Dashboard

```json
{
  "dashboard": {
    "title": "Challenge Service Metrics",
    "panels": [
      {
        "title": "Event Processing Time (p95)",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(challenge_event_processing_seconds_bucket[5m]))"
          }
        ]
      },
      {
        "title": "API Request Rate",
        "targets": [
          {
            "expr": "rate(challenge_api_request_duration_seconds_count[5m])"
          }
        ]
      },
      {
        "title": "Buffer Size",
        "targets": [
          {
            "expr": "challenge_buffer_size"
          }
        ]
      }
    ]
  }
}
```

### Logging

#### Log Format

```json
{
  "timestamp": "2025-10-15T10:30:00Z",
  "level": "info",
  "message": "Event processed",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "user_id": "abc123",
  "namespace": "mygame",
  "duration_ms": 15
}
```

#### Log Aggregation

**Option 1: ELK Stack**
```bash
# Ship logs to Elasticsearch
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/challenge-*.log

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
```

**Option 2: CloudWatch Logs (AWS)**
```yaml
# Add CloudWatch log driver to container
logging:
  driver: awslogs
  options:
    awslogs-group: /ecs/challenge-service
    awslogs-region: us-east-1
    awslogs-stream-prefix: challenge
```

### Alerts

#### Prometheus Alert Rules

```yaml
groups:
  - name: challenge_service
    rules:
      - alert: HighEventProcessingLatency
        expr: histogram_quantile(0.95, rate(challenge_event_processing_seconds_bucket[5m])) > 0.05
        for: 5m
        annotations:
          summary: "Event processing latency is high (p95 > 50ms)"

      - alert: HighAPILatency
        expr: histogram_quantile(0.95, rate(challenge_api_request_duration_seconds_bucket[5m])) > 0.2
        for: 5m
        annotations:
          summary: "API latency is high (p95 > 200ms)"

      - alert: HighErrorRate
        expr: rate(challenge_errors_total[5m]) > 0.01
        for: 5m
        annotations:
          summary: "Error rate is high (> 1%)"

      - alert: DatabaseConnectionPoolExhausted
        expr: challenge_db_connections_active / challenge_db_connections_max > 0.9
        for: 5m
        annotations:
          summary: "Database connection pool usage > 90%"
```

### Scaling

#### Horizontal Pod Autoscaler (HPA)

```yaml
# Service HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: challenge-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: challenge-service
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70

# Event Handler HPA (based on CPU/Memory)
# Note: Kafka lag metrics are managed by Extend platform
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: challenge-event-handler-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: challenge-event-handler
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

---

## References

- **AccelByte Extend Docs**: https://docs.accelbyte.io/extend/
- **Docker Compose**: https://docs.docker.com/compose/
- **Kubernetes Deployments**: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- **Prometheus Monitoring**: https://prometheus.io/docs/

---

**Document Status:** Complete - Ready for implementation
