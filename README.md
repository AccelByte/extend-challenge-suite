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

✅ **Config-First Design** - Define challenges in `challenges.json`, no admin UI needed
✅ **Event-Driven Progress** - Real-time updates via AGS IAM login and Statistic events
✅ **High Performance** - Buffered processing with 1,000,000× DB query reduction
✅ **3 Goal Types** - Absolute, Increment, Daily with flexible requirements
✅ **Prerequisites** - Chain goals together with dependency management
✅ **AGS Integration** - Automatic reward grants (ITEM entitlements, WALLET credits)
✅ **Production-Ready** - 95%+ test coverage, observability, horizontal scaling

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

### 3. Start All Services

```bash
# Start PostgreSQL, Redis, Backend Service, Event Handler
make dev-up

# View logs
make dev-logs

# Stop services
make dev-down
```

This starts:
- **PostgreSQL** on port 5432
- **Redis** on port 6379
- **Challenge Service** on ports 6565 (gRPC), 8000 (HTTP), 8080 (metrics)
- **Event Handler** on ports 6566 (gRPC), 8081 (metrics)

### 4. Test the API

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

### 5. Run End-to-End Tests

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
```

**Test Coverage**: 95%+ comprehensive coverage across unit, integration, and E2E tests.

See [tests/e2e/README.md](tests/e2e/README.md) for detailed testing guide.

---

## Performance Metrics

- **API Response Time**: < 200ms (p95)
- **Event Processing**: < 50ms per event (p95)
- **Throughput**: 500+ events/sec tested, 1,000+ events/sec target
- **DB Query Reduction**: 1,000,000× via buffered batch UPSERT
- **Buffer Flush**: < 20ms for 1,000 rows (p95)

See [docs/PERFORMANCE_BASELINE.md](docs/PERFORMANCE_BASELINE.md) for detailed metrics.

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
| **M2** | ✅ Complete | Multiple challenges, tagging, filtering |
| **M3** | ✅ Complete | Time-based challenges, schedules, rotation |
| **M4** | 🚧 Planned | Randomized assignment, player segmentation |
| **M5** | 🚧 Planned | Advanced prerequisites, visibility control |
| **M6** | 🚧 Planned | Advanced assignment rules, claim conditions |

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
