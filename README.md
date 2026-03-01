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

- **Docker** 20.10+ and **Docker Compose** 2.0+
- **Make** (optional but recommended)
- **Go** 1.25+ (for running demo app directly)

### 1. Clone Suite Repository

```bash
git clone https://github.com/AccelByte/extend-challenge-suite.git
cd extend-challenge-suite
```

### 2. Clone Service Repositories

```bash
# Run setup command to clone all service repos
make setup

# Or clone manually:
git clone https://github.com/AccelByte/extend-challenge-service.git
git clone https://github.com/AccelByte/extend-challenge-event-handler.git
git clone https://github.com/AccelByte/extend-challenge-demo-app.git
```

### 3. Build Demo App

```bash
# Build the demo app for testing
make build-demo-app
```

### 4. Start All Services

```bash
# Start PostgreSQL, Redis, Backend Service, Event Handler
make dev-up

# View logs
make dev-logs

# Stop services
make dev-down
```

This starts:
- **PostgreSQL** on port 5433
- **Redis** on port 6379
- **Challenge Service** on ports 6565 (gRPC), 8000 (HTTP), 8080 (metrics)
- **Event Handler** on ports 6566 (gRPC), 8081 (metrics)

### 5. Test the API

**List all challenges**:
```bash
cd extend-challenge-demo-app
go run main.go challenges list
```

**Trigger login event** (increments daily-login progress):
```bash
go run main.go events trigger login
```

**Claim reward**:
```bash
go run main.go challenges claim daily-quests daily-login
```

### 6. Run End-to-End Tests

**Mock mode** (default): No AGS credentials needed — tests use mock authentication.

**Real AGS mode**: Before running E2E tests with real authentication, you must create required AGS items in your namespace. Follow [AGS_SETUP_GUIDE.md](AGS_SETUP_GUIDE.md) Step 4 to create:
- Items: `winter_sword`, `loyalty_badge`, `daily_chest` (INGAMEITEM, entitleable, active)
- Currencies: `GOLD`, `GEMS` (VIRTUAL, published)

```bash
# Run all E2E tests
make test-e2e

# Run specific test
make test-e2e-login
```

See [tests/e2e/QUICK_START.md](tests/e2e/QUICK_START.md) for detailed testing guide.

---

## Documentation

### Start Here

| Document | Purpose |
|----------|---------|
| **[docs/INDEX.md](docs/INDEX.md)** | **📍 Main documentation index (start here)** |
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
├── docs/                          # 📚 All technical documentation
│   ├── INDEX.md                   # Main documentation index
│   ├── TECH_SPEC_M1.md           # Core architecture spec
│   ├── TECH_SPEC_DATABASE.md     # Database design
│   ├── TECH_SPEC_API.md          # REST API spec
│   └── ... (20+ documents)
│
├── tests/e2e/                     # 🧪 End-to-end integration tests
│   ├── README.md                  # E2E testing guide
│   ├── QUICK_START.md            # 5-minute quick start
│   ├── test-*.sh                 # Test scripts
│   └── helpers.sh                # Test utilities
│
├── tests/loadtest/                # ⚡ Load testing suite (k6)
│   ├── README.md                  # Load testing guide
│   ├── k6/                        # k6 test scripts
│   ├── fixtures/                  # Test data (users, tokens, challenges)
│   └── scripts/                   # Helper scripts
│
├── docker-compose.yml             # 🐳 Local development orchestration
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

Copy `.env.example` to `.env` and configure:

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
      "id": "daily-quests",
      "name": "Daily Quests",
      "goals": [
        {
          "id": "daily-login",
          "name": "Daily Login",
          "type": "daily",
          "event_source": "login",
          "requirement": {
            "target": 1
          },
          "reward": {
            "type": "ITEM",
            "item_id": "daily-reward-box",
            "quantity": 1
          }
        }
      ]
    }
  ]
}
```

See [docs/TECH_SPEC_CONFIGURATION.md](docs/TECH_SPEC_CONFIGURATION.md) for full schema.

---

## Testing

### Unit & Integration Tests

Each service repository has its own test suite:

```bash
# Backend service
cd extend-challenge-service
make test

# Event handler
cd extend-challenge-event-handler
make test

# Common library
cd extend-challenge-common
go test ./...
```

### End-to-End Tests

Run from suite root:

```bash
# All E2E tests
make test-e2e

# Individual tests
make test-e2e-login        # Login flow
make test-e2e-stat         # Stat update flow
make test-e2e-daily        # Daily goal behavior
make test-e2e-buffering    # Performance & buffering
make test-e2e-prereqs      # Prerequisites
make test-e2e-mixed        # Mixed goal types
make test-e2e-errors       # Error scenarios
make test-e2e-multiuser    # Multi-user isolation
make test-e2e-m3-init      # M3 player initialization
make test-e2e-inactive     # Inactive goal filtering
make test-e2e-m4-batch     # M4 batch goal selection
make test-e2e-m4-random    # M4 random goal selection

# M5 rotation tests
make test-e2e-m5-rotation-basic    # Basic rotation mechanics
make test-e2e-m5-rotation-reset    # Rotation progress reset
make test-e2e-m5-rotation-no-reset # Rotation without reset
make test-e2e-m5-rotation-claimed  # Claimed goal rotation
make test-e2e-m5-rotation-status   # Rotation status endpoint
make test-e2e-m5-rotation-expiry   # Rotation expiry fields
```

**Test Coverage**: 95%+ comprehensive coverage across unit, integration, and E2E tests.

See [tests/e2e/README.md](tests/e2e/README.md) for detailed E2E testing guide.

### Load Testing

Performance and load testing with k6:

```bash
cd tests/loadtest

# Generate test fixtures
./scripts/generate_users.sh
./scripts/generate_challenges.sh
MOCK_MODE=true ./scripts/generate_tokens.sh

# Run individual scenarios
K6_WEB_DASHBOARD=true TARGET_RPS=500 k6 run k6/scenario1_api_load.js
K6_WEB_DASHBOARD=true TARGET_EPS=1000 k6 run k6/scenario2_event_load.js
K6_WEB_DASHBOARD=true TARGET_RPS=200 TARGET_EPS=1000 k6 run k6/scenario3_combined.js

# Or run all scenarios (6-12 hours)
./scripts/run_all_scenarios.sh
```

**Load Test Capabilities**:
- API load testing up to 5,000 RPS
- Event processing load up to 10,000 EPS
- Combined load testing (API + Events)
- Real-time monitoring with k6 web dashboard
- Database performance analysis
- pprof CPU and memory profiling

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
# Start all services
make dev-up

# Make changes and rebuild
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
4. Run tests: `make test`
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
3. Verify goal configuration has correct `event_source` field

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

---

**Quick Links:**
- [📚 Documentation Index](docs/INDEX.md)
- [🚀 Quick Start Guide](tests/e2e/QUICK_START.md)
- [🏗️ Architecture Spec](docs/TECH_SPEC_M1.md)
- [🎯 AGS Setup](AGS_SETUP_GUIDE.md)
- [🧪 Testing Guide](tests/e2e/README.md)
