# End-to-End Tests

CLI-based E2E tests for the Challenge Service using the demo app.

## Prerequisites

- Docker images up-to-date with source code: `make dev-rebuild` (run after any Go code changes)
- Docker Compose services running: `make dev-up`
- Demo app built: `cd extend-challenge-demo-app && go build -o bin/challenge-demo ./cmd/challenge-demo/`
- `jq` installed: `apt install jq` or `brew install jq`

## Running Tests

### Quick Start (Mock Mode - Local Testing)

```bash
# Run all tests
make test-e2e

# Run individual test
make test-e2e-login
./tests/e2e/test-login-flow.sh

# Show all available test targets
make test-e2e-help
```

### Using Real Authentication

#### Option 1: Environment Variables

```bash
# Password Mode (real user)
AUTH_MODE=password \
EMAIL=user@example.com \
PASSWORD=yourpassword \
CLIENT_ID=your-client-id \
NAMESPACE=your-namespace \
IAM_URL=https://demo.accelbyte.io/iam \
./tests/e2e/test-login-flow.sh

# Client Mode (service-to-service)
AUTH_MODE=client \
CLIENT_ID=your-client-id \
CLIENT_SECRET=your-client-secret \
NAMESPACE=your-namespace \
IAM_URL=https://demo.accelbyte.io/iam \
./tests/e2e/test-login-flow.sh
```

#### Option 2: .env File (Recommended)

```bash
# 1. Copy example config
cd tests/e2e
cp .env.example .env

# 2. Edit .env and fill in your credentials
nano .env

# 3. Source and run tests
set -a && source .env && set +a && ./test-login-flow.sh

# Or run all tests with .env
set -a && source .env && set +a && ./run-all-tests.sh
```

## Authentication Modes

### Mock Mode (Default)

Best for local development and testing. Uses mock JWT tokens.

**Required:**
- `USER_ID` (default: `test-user-e2e`)
- `NAMESPACE` (default: `accelbyte`)

**Example:**
```bash
./tests/e2e/test-login-flow.sh
```

### Password Mode

Use real AccelByte user authentication. Requires a real user account.

**Required:**
- `AUTH_MODE=password`
- `EMAIL` - User email
- `PASSWORD` - User password
- `CLIENT_ID` - OAuth2 client ID
- `NAMESPACE` - AccelByte namespace
- `IAM_URL` - IAM service URL (default: `https://demo.accelbyte.io/iam`)

**Example:**
```bash
AUTH_MODE=password \
EMAIL=testuser@example.com \
PASSWORD=mypassword \
CLIENT_ID=abc123 \
NAMESPACE=mygame \
./tests/e2e/test-login-flow.sh
```

### Client Mode

Use service-to-service authentication with client credentials.

**Required:**
- `AUTH_MODE=client`
- `CLIENT_ID` - OAuth2 client ID
- `CLIENT_SECRET` - OAuth2 client secret
- `NAMESPACE` - AccelByte namespace
- `IAM_URL` - IAM service URL (default: `https://demo.accelbyte.io/iam`)

**Example:**
```bash
AUTH_MODE=client \
CLIENT_ID=service-client \
CLIENT_SECRET=supersecret \
NAMESPACE=mygame \
./tests/e2e/test-login-flow.sh
```

## Available Tests

### Happy Path Tests

| Test Script | Description | Coverage |
|-------------|-------------|----------|
| `test-login-flow.sh` | Login events → progress tracking → reward claiming | Login flow, increment goals, daily goals |
| `test-stat-flow.sh` | Stat update events and absolute goal type | Absolute goals, stat updates, claimed protection |
| `test-daily-goal.sh` | Daily goal behavior and idempotency | Daily goals, same-day idempotency |
| `test-prerequisites.sh` | Prerequisite validation and claim ordering | Prerequisites, locked goals, claim order |
| `test-mixed-goals.sh` | All 3 goal types working together | Absolute, increment, daily goals |
| `test-buffering-performance.sh` | Event throughput and batch UPSERT performance | 1000 events, buffering, performance |

### M3 Feature Tests

| Test Script | Description | Coverage |
|-------------|-------------|----------|
| `test-m3-initialization.sh` | Player initialization and default goal assignment | M3 initialization flow |
| `test-inactive-goal-filtering.sh` | Inactive goals filtered from API responses | M3 goal activation control |

### M4 Feature Tests

| Test Script | Description | Coverage |
|-------------|-------------|----------|
| `test-m4-batch-selection.sh` | Batch goal selection mechanics | M4 batch selection |
| `test-m4-random-selection.sh` | Random goal selection from pool | M4 random selection |

### M5 Feature Tests (Time-Based Rotation)

| Test Script | Description | Coverage |
|-------------|-------------|----------|
| `test-m5-rotation-basic.sh` | Relative progress mode with baseline calculation | Baseline init, relative progress, completion |
| `test-m5-rotation-reset.sh` | Daily rotation with progress reset | Display-only rotation, SQL CASE reset, baseline reset |
| `test-m5-rotation-no-reset.sh` | Weekly rotation preserving progress | `resetProgress=false`, progress survives rotation |
| `test-m5-rotation-claimed.sh` | Claimed goal behavior across rotation | `allowReselection` true vs false |
| `test-m5-rotation-status.sh` | Rotation status endpoint | `GET /v1/challenges/{id}/rotation` |
| `test-m5-rotation-expiry-fields.sh` | Expiry fields on rotation goals | `expiresAt`, `expiresInSeconds` presence |

### Error Scenario Tests

| Test Script | Description | Coverage |
|-------------|-------------|----------|
| `test-error-scenarios.sh` | Invalid inputs, edge cases, concurrent claims | Negative values, empty stat codes, int32 boundary, concurrent claims, invalid IDs |
| `test-reward-failures.sh` | Reward grant failures and retry logic (mock mode) | Transaction atomicity, retry logic verification, multiple claims consistency |
| `test-multi-user.sh` | Multi-user concurrent access and isolation | 10 concurrent users, user isolation, concurrent events, concurrent claims |

## Configuration Variables

All variables can be set via environment or `.env` file:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_MODE` | `mock` | Authentication mode: `mock`, `password`, or `client` |
| `USER_ID` | `test-user-e2e` | User ID for mock mode |
| `EMAIL` | - | User email for password mode |
| `PASSWORD` | - | User password for password mode |
| `CLIENT_ID` | - | OAuth2 client ID (password/client mode) |
| `CLIENT_SECRET` | - | OAuth2 client secret (client mode) |
| `NAMESPACE` | `accelbyte` | AccelByte namespace |
| `IAM_URL` | `https://demo.accelbyte.io/iam` | IAM service URL |
| `BACKEND_URL` | `http://localhost:8000/challenge` | Challenge service backend URL |
| `EVENT_HANDLER_URL` | `localhost:6566` | Event handler gRPC address |
| `DEMO_APP` | `./extend-challenge-demo-app/bin/challenge-demo` | Demo app binary path |

## Test Output

### Successful Test
```
==========================================
  Login Flow E2E Test
==========================================

🔍 Checking if services are running...
✓ Services are running
🧹 Cleaning up test data for user: test-user-e2e

──────────────────────────────────────
  Step 1: Checking initial state...
──────────────────────────────────────

  Initial progress: 0
✅ PASS: Initial progress should be 0

...

✅ SUCCESS: Login flow test completed successfully
```

### Failed Test
```
❌ FAIL: Progress should be 3
  Expected: 3
  Actual:   2
```

## Troubleshooting

### Demo app binary not found
```bash
cd extend-challenge-demo-app
go build -o bin/challenge-demo ./cmd/challenge-demo/
```

### Services not running
```bash
make dev-up
# Wait for services to be healthy
docker compose ps
```

### jq not installed
```bash
# Ubuntu/Debian
sudo apt install jq

# macOS
brew install jq
```

### Authentication errors (password/client mode)
- Verify credentials are correct
- Check IAM_URL is accessible
- Ensure CLIENT_ID has proper permissions
- For password mode, ensure user account exists

### Tests hang or timeout
- Check if services are responding: `curl http://localhost:8000/challenge/v1/challenges`
- Check event handler: `docker compose logs challenge-event-handler`
- Increase wait times in test scripts if needed

### Tests fail with unexpected progress values or missing goals
This usually means Docker images are stale (built before recent code/config changes):
```bash
# Rebuild images with latest code
make dev-rebuild

# Or if config-only change, just restart (config is volume-mounted)
docker compose restart
```

## Directory Structure

```
tests/e2e/
├── README.md                          # This file
├── QUICK_START.md                     # Quick start guide
├── .env.example                       # Example configuration
├── helpers.sh                         # Test helper functions
├── run-all-tests.sh                   # Test runner (all 19 tests)
├── test-login-flow.sh                 # Login flow test
├── test-stat-flow.sh                  # Stat update test
├── test-daily-goal.sh                 # Daily goal test
├── test-prerequisites.sh              # Prerequisites test
├── test-mixed-goals.sh                # Mixed goals test
├── test-buffering-performance.sh      # Performance test
├── test-m3-initialization.sh          # M3: Player initialization
├── test-inactive-goal-filtering.sh    # M3: Inactive goal filtering
├── test-m4-batch-selection.sh         # M4: Batch selection
├── test-m4-random-selection.sh        # M4: Random selection
├── test-m5-rotation-basic.sh          # M5: Relative progress & baseline
├── test-m5-rotation-reset.sh          # M5: Daily rotation with reset
├── test-m5-rotation-no-reset.sh       # M5: Weekly rotation, no reset
├── test-m5-rotation-claimed.sh        # M5: Claimed goal across rotation
├── test-m5-rotation-status.sh         # M5: Rotation status endpoint
├── test-m5-rotation-expiry-fields.sh  # M5: Expiry field validation
├── test-error-scenarios.sh            # Error scenarios
├── test-reward-failures.sh            # Reward failure handling
└── test-multi-user.sh                 # Multi-user concurrency
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Start services
        run: make dev-up

      - name: Build demo app
        run: |
          cd extend-challenge-demo-app
          go build -o bin/challenge-demo ./cmd/challenge-demo/

      - name: Run E2E tests (mock mode)
        run: make test-e2e

      - name: Run E2E tests (password mode)
        env:
          AUTH_MODE: password
          EMAIL: ${{ secrets.TEST_USER_EMAIL }}
          PASSWORD: ${{ secrets.TEST_USER_PASSWORD }}
          CLIENT_ID: ${{ secrets.CLIENT_ID }}
          NAMESPACE: ${{ secrets.NAMESPACE }}
        run: ./tests/e2e/run-all-tests.sh
```

## Contributing

When adding new tests:

1. Follow the naming convention: `test-<feature>.sh`
2. Use helper functions from `helpers.sh`
3. Add comprehensive assertions
4. Include clear step descriptions
5. Test with both mock and real authentication
6. Update this README with new test description
7. Add test to `run-all-tests.sh`

## Related Documentation

- [TECH_SPEC_CLI_MODE.md](../../docs/demo-app/TECH_SPEC_CLI_MODE.md) - CLI mode specification
- [TECH_SPEC_AUTHENTICATION.md](../../docs/demo-app/TECH_SPEC_AUTHENTICATION.md) - Authentication modes
- [TECH_SPEC_TESTING.md](../../docs/TECH_SPEC_TESTING.md) - Testing strategy
