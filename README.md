# AccelByte Extend Challenge Suite

**A complete challenge system suite for AccelByte Extend - Production-ready and open source.**

[![Go Version](https://img.shields.io/badge/Go-1.25+-00ADD8?style=flat&logo=go)](https://golang.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![AccelByte](https://img.shields.io/badge/AccelByte-Extend-orange)](https://accelbyte.io)

This repository serves as the **orchestration and documentation hub** for the AccelByte Extend Challenge Service ecosystem. It contains comprehensive documentation, end-to-end tests, and local development orchestration for all microservices.

---

## What is the Challenge Suite?

The Challenge Suite enables game developers to implement **daily missions, seasonal events, quests, and achievements** through simple JSON configuration - no custom backend code required. The system integrates seamlessly with AccelByte Gaming Services (AGS) for authentication, event processing, and reward distribution.

### Key Features

**M5 (Current Release):**
✅ **Time-Based Rotation** - Daily, weekly, and monthly goal rotation with automatic expiry
✅ **2 Progress Modes** - Absolute (lifetime stats) and Relative (baseline-relative for rotation)
✅ **Rotation Status API** - `GET /v1/challenges/{id}/rotation` for schedule info
✅ **Lazy Rotation Detection** - Returning players get rotation updates on Initialize

**M4:**
✅ **Batch Goal Selection** - Select multiple goals at once
✅ **Random Goal Selection** - System picks random goals from pool

**M3:**
✅ **Goal Assignment Control** - Users manage which goals they actively work on
✅ **Initialize Endpoint** - One-call setup for new players (16.84ms P95, 316x optimized)

**Core Features:**
✅ **Config-First Design** - Define challenges in `challenges.json`, no admin UI needed
✅ **Event-Driven Progress** - Real-time updates via AGS IAM login and Statistic events
✅ **High Performance** - Buffered processing with 1,000,000× DB query reduction via unified COPY path
✅ **Prerequisites** - Chain goals together with dependency management
✅ **AGS Integration** - Automatic reward grants (ITEM entitlements, WALLET credits)
✅ **Production-Ready** - 96%+ test coverage, observability, horizontal scaling validated

---

## Architecture Overview

The suite consists of **3 microservices** and a **shared library**:

```
┌──────────────────────────────────────────────────────────────┐
│                    Challenge Suite                            │
│  (This repo - Docs, E2E tests, Orchestration)                │
└──────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐   ┌─────────────┐
│  Backend      │   │ Event Handler │   │ Demo App    │
│  Service      │   │  Service      │   │  (CLI/TUI)  │
│               │   │               │   │             │
│  REST API     │   │  gRPC Events  │   │  Testing    │
│  Claim Flow   │   │  Buffering    │   │  Tool       │
└───────┬───────┘   └───────┬───────┘   └──────┬──────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                  ┌─────────▼────────┐
                  │ Common Library   │
                  │                  │
                  │ • Domain Models  │
                  │ • Interfaces     │
                  │ • Config Loader  │
                  └──────────────────┘
```

### Repositories

| Repository | Purpose | GitHub URL |
|------------|---------|------------|
| **extend-challenge-suite** | Suite docs, E2E tests, orchestration | [github.com/AccelByte/extend-challenge-suite](https://github.com/AccelByte/extend-challenge-suite) |
| **extend-challenge-common** | Shared library (domain models, interfaces) | [github.com/AccelByte/extend-challenge-common](https://github.com/AccelByte/extend-challenge-common) |
| **extend-challenge-service** | REST API service (gRPC + HTTP Gateway) | [github.com/AccelByte/extend-challenge-service](https://github.com/AccelByte/extend-challenge-service) |
| **extend-challenge-event-handler** | Event processing service (gRPC) | [github.com/AccelByte/extend-challenge-event-handler](https://github.com/AccelByte/extend-challenge-event-handler) |
| **extend-challenge-demo-app** | Demo CLI/TUI tool for testing | [github.com/AccelByte/extend-challenge-demo-app](https://github.com/AccelByte/extend-challenge-demo-app) |

---

## Quick Start (Local Development)

### Prerequisites

**Required:**
- **Docker** 20.10+ and **Docker Compose** 2.0+
- **[Go](https://go.dev/doc/install)** 1.25+ (builds the demo app) — check: `go version`
- **jq** (used by test scripts)
- **Make**

**Optional** (for specific test types):
- **[golangci-lint](https://golangci-lint.run/welcome/install/)** (for `make lint`)
- **[k6](https://grafana.com/docs/k6/latest/set-up/install-k6/)** (for `make test-loadtest-smoke`)

Run `make check-prereqs` to verify everything is installed.

### Option A: One Command

```bash
git clone https://github.com/AccelByte/extend-challenge-suite.git
cd extend-challenge-suite
make quickstart      # checks prereqs, clones, builds, starts (~5 min first time)
make test-e2e        # run all 34 E2E tests
```

### Option B: Step by Step

```bash
# 1. Clone suite repo
git clone https://github.com/AccelByte/extend-challenge-suite.git
cd extend-challenge-suite

# 2. Check prerequisites
make check-prereqs

# 3. Clone service repositories
make setup

# 4. Build demo app (used by E2E tests)
make build-demo-app

# 5. Start all services (first run builds images ~3 min)
make dev-up

# 6. Smoke test the API
curl -s http://localhost:8000/challenge/v1/challenges \
  -H "Authorization: Bearer mock" | jq .

# 7. Run all E2E tests
make test-e2e
```

**Next steps:** Run all test types: `make test-unit && make dev-down && make test-integration && make dev-up && make test-e2e`.
See [tests/e2e/QUICK_START.md](tests/e2e/QUICK_START.md) for the E2E testing guide.

Services started by `make dev-up`:
- **PostgreSQL** on port 5433
- **Redis** on port 6379
- **Challenge Service** on ports 6565 (gRPC), 8000 (HTTP), 8080 (metrics)
- **Event Handler** on ports 6566 (gRPC), 8081 (metrics)

**Real AGS mode**: To run E2E tests with real authentication, follow [AGS_SETUP_GUIDE.md](AGS_SETUP_GUIDE.md) to configure your namespace.

See [tests/e2e/QUICK_START.md](tests/e2e/QUICK_START.md) for detailed testing guide.

---

## Documentation

### Start Here

| Document | Purpose |
|----------|---------|
| **[docs/INDEX.md](docs/INDEX.md)** | **Main documentation index (start here)** |
| [README.md](README.md) | This file - Suite overview |
| [AGS_SETUP_GUIDE.md](AGS_SETUP_GUIDE.md) | AccelByte Gaming Services setup |

### Technical Specifications

| Document | Description |
|----------|-------------|
| [TECH_SPEC_M1.md](docs/TECH_SPEC_M1.md) | **Core architecture and interfaces** |
| [TECH_SPEC_DATABASE.md](docs/TECH_SPEC_DATABASE.md) | Database design, queries, migrations |
| [TECH_SPEC_API.md](docs/TECH_SPEC_API.md) | REST API endpoints and schemas |
| [TECH_SPEC_EVENT_PROCESSING.md](docs/TECH_SPEC_EVENT_PROCESSING.md) | Event handling and buffering |
| [TECH_SPEC_CONFIGURATION.md](docs/TECH_SPEC_CONFIGURATION.md) | Challenge configuration format |
| [TECH_SPEC_TESTING.md](docs/TECH_SPEC_TESTING.md) | Testing strategy (unit, integration, E2E) |
| [TECH_SPEC_DEPLOYMENT.md](docs/TECH_SPEC_DEPLOYMENT.md) | Deployment guide (local, Extend, K8s) |

### Additional Guides

| Document | Description |
|----------|-------------|
| [tests/e2e/README.md](tests/e2e/README.md) | End-to-end testing guide |
| [CLAUDE.md](CLAUDE.md) | AI agent development guide |
| [MILESTONES.md](docs/MILESTONES.md) | Product roadmap (M1-M6) |

**Full documentation index**: [docs/INDEX.md](docs/INDEX.md)

---

## Repository Contents

```
extend-challenge-suite/
├── docs/                          # All technical documentation
│   ├── INDEX.md                   # Main documentation index
│   ├── TECH_SPEC_M1.md           # Core architecture spec
│   ├── TECH_SPEC_DATABASE.md     # Database design
│   ├── TECH_SPEC_API.md          # REST API spec
│   └── ... (20+ documents)
│
├── tests/e2e/                     # End-to-end integration tests
│   ├── README.md                  # E2E testing guide
│   ├── QUICK_START.md            # 5-minute quick start
│   ├── test-*.sh                 # Test scripts
│   └── helpers.sh                # Test utilities
│
├── tests/loadtest/                # Load testing suite (k6)
│   ├── README.md                  # Load testing guide
│   ├── k6/                        # k6 test scripts
│   ├── fixtures/                  # Test data (users, tokens, challenges)
│   └── scripts/                   # Helper scripts
│
├── docker-compose.yml             # Local development orchestration
├── docker-compose.test.yml       # Test environment
├── Makefile                       # Build and orchestration commands
├── .env.example                   # Example configuration
├── AGS_SETUP_GUIDE.md            # AccelByte setup guide
├── CLAUDE.md                      # AI agent instructions
└── README.md                      # This file
```

---

## Configuration

### Environment Variables

`.env` is auto-created from `.env.example` when you run `make dev-up`. Edit it to change settings:

```bash
# Database (PostgreSQL)
DB_HOST=postgres
DB_PORT=5432
DB_NAME=challenge_db
DB_USER=postgres
DB_PASSWORD=postgres

# Redis (optional for M1)
REDIS_HOST=redis
REDIS_PORT=6379

# AccelByte AGS (for production)
AB_BASE_URL=https://your-environment.accelbyte.io
AB_CLIENT_ID=your-service-account-client-id
AB_CLIENT_SECRET=your-service-account-client-secret
AB_NAMESPACE=your-namespace

# Reward Client Mode
REWARD_CLIENT_MODE=mock  # Use 'real' for AGS integration
```

### Challenge Configuration

Define challenges in `extend-challenge-service/config/challenges.json`:

```json
{
  "challenges": [
    {
      "challengeId": "daily-quests",
      "name": "Daily Quests",
      "goals": [
        {
          "goalId": "daily-login",
          "name": "Daily Login",
          "eventSource": "login",
          "requirement": {
            "statCode": "login_count",
            "operator": ">=",
            "targetValue": 1,
            "progressMode": "absolute"
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GEMS",
            "quantity": 10
          },
          "prerequisites": [],
          "defaultAssigned": true
        }
      ]
    }
  ]
}
```

Key fields: `eventSource` is `"login"` (IAM events) or `"statistic"` (stat updates).
`progressMode` is `"absolute"` (lifetime value) or `"relative"` (baseline-relative, for rotation).
See [docs/TECH_SPEC_CONFIGURATION.md](docs/TECH_SPEC_CONFIGURATION.md) for full schema.

---

## Testing

All test types can be run from the **suite root** — no need to `cd` into sub-projects.

**Recommended order:** unit → lint → integration → (start services with `make dev-up`) → e2e → load.
Integration tests manage their own database containers and need services **stopped**.
E2E and load tests need services **running**.

| Command | What it runs | Time | Requires |
|---------|-------------|------|----------|
| `make test-unit` | Unit tests across all 3 projects | ~30s | Go |
| `make test-integration` | Integration tests with auto DB lifecycle | ~2 min | Docker |
| `make lint` | golangci-lint across all 3 projects | ~20s | golangci-lint |
| `make test-e2e` | All 34 E2E tests | ~3 min | Services running (`make dev-up`) |
| `make test-loadtest-smoke` | Scenario 3 smoke test | ~5 min | [k6](https://grafana.com/docs/k6/latest/set-up/install-k6/), services running |
| `cd extend-challenge-common && make bench` | Database query benchmarks | ~2 min | Go, Docker |

### Run All Tests (Recommended Sequence)

```bash
# 1. Unit tests (no services needed)
make test-unit

# 2. Lint (no services needed)
make lint

# 3. Integration tests (need services STOPPED — auto-manages its own DB)
make dev-down
make test-integration

# 4. E2E tests (need services RUNNING)
make dev-up
make test-e2e

# 5. Load test smoke (optional, needs k6 installed)
make test-loadtest-smoke
```

### Unit Tests

```bash
make test-unit         # No database or services needed
```

Runs `go test` (excluding integration tests) in `extend-challenge-common`, `extend-challenge-service`, and `extend-challenge-event-handler`.

### Integration Tests

```bash
make test-integration  # Manages its own DB containers — no services needed
```

Each project's test database is started, tests run, and the database is torn down automatically.

> **Important:** Stop services first with `make dev-down` — integration tests need
> port 5433, which conflicts with the main PostgreSQL container.
> Restart with `make dev-up` afterward for E2E tests.

### Linting

```bash
make lint              # Requires golangci-lint installed
```

### End-to-End Tests

Requires services to be running (`make dev-up`):

```bash
make test-e2e              # Run all 34 E2E tests
make test-e2e-help         # Show all 34 individual test targets (e.g., test-e2e-login, test-e2e-m5-rotation-basic)
```

**34 E2E tests by category:**

| Category | Count | Examples |
|----------|-------|---------|
| Core (login, stat, daily, prereqs, mixed, buffering) | 6 | `make test-e2e-login` |
| M3 (initialization, inactive filtering) | 2 | `make test-e2e-m3-init` |
| M4 (batch, random selection) | 2 | `make test-e2e-m4-batch` |
| M5 Rotation (daily/weekly/monthly, reset, expiry, etc.) | 21 | `make test-e2e-m5-rotation-basic` |
| Error scenarios (errors, rewards, multi-user) | 3 | `make test-e2e-errors` |

**Test Coverage**: 95%+ comprehensive coverage across unit, integration, and E2E tests.

See [tests/e2e/README.md](tests/e2e/README.md) for detailed E2E testing guide.

### Load Testing

Requires [k6](https://grafana.com/docs/k6/latest/set-up/install-k6/) installed.

```bash
# Quick smoke test (~5 min) — auto-switches to loadtest config and back
make test-loadtest-smoke
```

| Scenario | Script | Focus |
|----------|--------|-------|
| 1 - API Load | `scenario1_api_load.js` | HTTP endpoints up to 5,000 RPS |
| 2 - Event Load | `scenario2_event_load.js` | gRPC events up to 10,000 EPS |
| 3 - Combined | `scenario3_combined.js` | API + Events together |
| 3 - Smoke | `scenario3_smoke.js` | Quick combined smoke (~5 min) |
| 4 - Realistic Sessions | `scenario4_m4_realistic_sessions.js` | M4 batch/random user flows |
| 5 - M5 Rotation | `scenario5_m5_rotation.js` | Rotation + expiry under load |

For manual runs with custom parameters:

```bash
# Switch to loadtest config
make dev-up-loadtest

# Generate fixtures (first time only)
cd tests/loadtest
./scripts/generate_users.sh
./scripts/generate_challenges.sh
MOCK_MODE=true ./scripts/generate_tokens.sh

# Run a scenario
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run k6/scenario1_api_load.js

# Switch back to E2E config
cd ../.. && make dev-up
```

See [tests/loadtest/README.md](tests/loadtest/README.md) for detailed load testing guide.

---

## Performance Metrics

**M5 Baseline (Feb 2026) — single Docker instance, 30-min sustained load.**

> **Quick glossary:** **p95** = 95th-percentile latency (95% of requests finish faster).
> **RPS** = HTTP requests/sec. **EPS** = gRPC events/sec. **VU** = virtual (simulated) user.

### Latency

| Layer | p95 | Notes |
|-------|-----|-------|
| HTTP API (overall) | **3.89 ms** | GET challenges, claim, initialize, etc. |
| gRPC event processing | **0.60 ms** | Includes rotation SQL CASE overhead |
| Rotation status endpoint | **0.97 ms** | New in M5 |

### Throughput (single instance)

| Workload | Sustained rate | Error rate |
|----------|---------------|------------|
| Events only | 500 EPS | 0 % |
| Realistic sessions | 150 VUs | 0 % |
| Combined (API + Events) | 300 RPS + 500 EPS | 0 % HTTP, gRPC tail spikes under contention |

### Test Coverage

- **34 E2E tests** (login, stat, rotation, prerequisites, multi-user, error scenarios)
- **95 %+** unit/integration coverage across all services

See [docs/PERFORMANCE_BASELINE.md](docs/PERFORMANCE_BASELINE.md) for the full baseline and
[docs/M5_PERFORMANCE_RESULTS.md](docs/M5_PERFORMANCE_RESULTS.md) for the detailed load-test report.

---

## Deployment

### Local Development

```bash
# Start all services (fastest — reuses existing images)
make dev-up

# Rebuild with cache after Go code changes (fast, iterative dev)
make dev-rebuild

# Full rebuild from scratch, no cache (use if cached build seems wrong)
make dev-restart

# Stop services
make dev-down
```

### AccelByte Extend Deployment

1. Build Docker images for each service
2. Push to AccelByte Extend using `extend-helper-cli`
3. Configure environment variables in Extend console
4. Deploy services to your namespace

See [docs/TECH_SPEC_DEPLOYMENT.md](docs/TECH_SPEC_DEPLOYMENT.md) for detailed deployment guide.

### Production Recommendations

- **Service**: 3 replicas, HPA on CPU (70%), 500m CPU / 512Mi RAM
- **Event Handler**: 2 replicas, 250m CPU / 256Mi RAM
- **Database**: PostgreSQL 15+ with connection pooling (max 150 connections)
- **Monitoring**: Prometheus + Grafana for metrics, structured logging

---

## Contributing

We welcome contributions! Here's how to get started:

1. **Fork the repository** you want to contribute to
2. **Read the documentation** in [docs/INDEX.md](docs/INDEX.md)
3. **Follow coding standards** in [CLAUDE.md](CLAUDE.md)
4. **Write tests** (target: 80%+ coverage)
5. **Submit a pull request**

### Development Workflow

1. Make code changes in service repository
2. Write unit tests (aim for 80%+ coverage)
3. Run linter: `make lint`
4. Run tests: `make test-unit`
5. Run E2E tests from suite repo: `make test-e2e`
6. Submit PR with clear description

---

## Troubleshooting

### Services won't start

```bash
# Check logs
make dev-logs

# Clean up and restart
make dev-clean
make dev-up
```

### Database connection failed

```bash
# Verify PostgreSQL is running
docker-compose ps

# Check database health
docker-compose exec postgres pg_isready -U postgres
```

### Events not updating progress

1. Check event handler logs: `docker-compose logs -f challenge-event-handler`
2. Wait for buffer flush (default: 1 second interval)
3. Verify goal configuration has correct `eventSource` field

### Port 5433 already in use

Integration tests and the main stack both use port 5433. Stop services first:

```bash
make dev-down           # stop main stack
make test-integration   # run tests
make dev-up             # restart services afterward
```

### Services stuck in restart loop

If `docker-compose ps` shows services "Restarting", the database container may be
missing (e.g., after integration tests). Fix with:

```bash
make dev-up             # recreates all containers
```

### Choosing between dev-up, dev-rebuild, dev-restart, dev-clean

| Command | Use when | Speed |
|---------|----------|-------|
| `make dev-up` | Starting services / no code changes | ~30s |
| `make dev-rebuild` | After Go code changes | ~1 min |
| `make dev-restart` | Cached build seems wrong | ~3 min |
| `make dev-clean && make dev-up` | Nuclear reset (wipes DB) | ~3 min |

See [tests/e2e/README.md](tests/e2e/README.md) for more troubleshooting tips.

---

## Roadmap

| Milestone | Status | Key Features |
|-----------|--------|--------------|
| **M1** | ✅ Complete | Foundation - Simple fixed challenges |
| **M2** | ✅ Complete | Performance profiling & load testing |
| **M3** | ✅ Complete | Per-user goal activation control |
| **M4** | ✅ Complete | Batch & random goal selection |
| **M5** | ✅ Complete | Time-based rotation |
| **M6** | 🚧 Planned | Advanced prerequisites, visibility control |

See [docs/MILESTONES.md](docs/MILESTONES.md) for detailed roadmap.

---

## License

[Apache 2.0 License](LICENSE)

---

## Support

- **Documentation**: [docs/INDEX.md](docs/INDEX.md)
- **E2E Testing Guide**: [tests/e2e/README.md](tests/e2e/README.md)
- **AccelByte Docs**: https://docs.accelbyte.io/extend/
- **Issues**: GitHub Issues (each repository)

---

## About AccelByte Extend

AccelByte Extend allows game developers to build custom game services that integrate seamlessly with AccelByte Gaming Services (AGS). This challenge suite is an open-source reference implementation that demonstrates best practices for building production-ready Extend applications.

**Learn more**: https://accelbyte.io/extend/

