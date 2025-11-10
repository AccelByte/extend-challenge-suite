# Suggested Commands

## Testing Commands

### Unit Tests
```bash
# Run unit tests
go test ./... -v

# Run unit tests excluding integration tests
go test $(go list ./... | grep -v /tests/integration) -v

# Run tests with coverage
go test ./... -coverprofile=coverage.out
go tool cover -func=coverage.out | grep total

# View coverage in browser
go tool cover -html=coverage.out
```

### Integration Tests (Backend Service Only)
```bash
# Run full integration test suite (setup + test + teardown)
cd extend-challenge-service
make test-integration

# Manual control
make test-integration-setup     # Start test database
make test-integration-run       # Run tests
make test-integration-teardown  # Stop and clean
```

## Linting and Formatting

### Linting
```bash
# Run linter (must pass before committing)
golangci-lint run ./...

# Run linter with auto-fix
golangci-lint run --fix ./...
```

### Formatting
```bash
# Format all Go files
gofmt -w .

# Fix imports
goimports -w .
```

## Building

### Backend Service
```bash
cd extend-challenge-service
make build    # Builds after generating proto files
```

### Event Handler
```bash
cd extend-challenge-event-handler
go build -o event-handler ./cmd
```

### Demo App (To Be Implemented)
```bash
cd extend-challenge-demo-app
go build -o challenge-demo ./cmd/challenge-demo
```

## Running Locally

### Start All Services (docker-compose)
```bash
# Start all services
make dev-up

# View logs
make dev-logs

# Check status
make dev-ps

# Stop services
make dev-down

# Clean restart (removes volumes)
make dev-clean
```

### Service Endpoints
- Backend gRPC: `localhost:6565`
- Backend HTTP REST: `localhost:8080`
- Backend gRPC Gateway: `localhost:8000`
- Event Handler gRPC: `localhost:6566`
- Event Handler Metrics: `localhost:8081`
- PostgreSQL: `localhost:5432`
- Redis: `localhost:6379`

## Database Migrations

```bash
cd extend-challenge-service

# Run migrations (up)
migrate -path ./migrations -database "postgresql://user:password@localhost:5432/challenge?sslmode=disable" up

# Rollback one migration
migrate -path ./migrations -database "postgresql://user:password@localhost:5432/challenge?sslmode=disable" down 1
```

## Combined Quality Checks

### Backend Service
```bash
cd extend-challenge-service

# Run all checks (lint + unit tests + integration tests)
make test-all
```

### Per-Module Checks
```bash
# Lint
make lint

# Unit tests only
make test

# Unit tests with coverage
make test-coverage
```

## Git Commands

```bash
# Standard Git operations
git status
git add <file>
git commit -m "message"
git push
git pull

# Branch management
git checkout -b feature/branch-name
git branch -a
git merge branch-name
```

## Docker Commands

```bash
# View running containers
docker ps

# View logs for a specific service
docker logs -f extend-challenge-service
docker logs -f extend-challenge-event-handler

# Rebuild specific service
docker-compose up -d --build extend-challenge-service
```

## Proto Generation (Backend Service)

```bash
cd extend-challenge-service
make proto
```

## Common Workflows

### Before Committing Code
```bash
# 1. Run linter
golangci-lint run ./...

# 2. Run tests with coverage
go test ./... -coverprofile=coverage.out
go tool cover -func=coverage.out | grep total  # Should be ≥ 80%

# 3. For backend service, also run integration tests
cd extend-challenge-service
make test-integration
```

### Creating a New Feature
```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Write tests first (TDD)
# 3. Implement feature
# 4. Run linter and tests
golangci-lint run ./...
go test ./... -v

# 5. Commit
git add .
git commit -m "feat: description"
git push -u origin feature/my-feature
```

### Debugging Issues
```bash
# Check service logs
make dev-logs

# Check specific service
docker logs -f extend-challenge-service

# Connect to database
psql -h localhost -U postgres -d challenge

# Check database tables
docker exec -it <postgres-container> psql -U postgres -d challenge -c "SELECT * FROM user_goal_progress LIMIT 10;"
```
