# AccelByte Extend Challenge Service - Documentation Index

**Version**: M3 (Milestone 3 Complete)
**Last Updated**: 2025-11-10

This document serves as the primary navigation guide for all technical documentation in the AccelByte Extend Challenge Service platform.

---

## Quick Start Guides

Perfect for developers getting started with the platform.

| Document | Purpose | Audience |
|----------|---------|----------|
| [**README.md**](../README.md) | Platform overview, quick start, local development setup | All developers |
| [**AGS_SETUP_GUIDE.md**](../AGS_SETUP_GUIDE.md) | Configure AccelByte Gaming Services integration (production) | DevOps, Backend Engineers |
| [**tests/e2e/QUICK_START.md**](../tests/e2e/QUICK_START.md) | Run E2E tests in under 5 minutes | QA, Backend Engineers |

---

## Technical Specifications (M1 Foundation)

Core technical documentation for the initial milestone (M1).

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M1.md**](TECH_SPEC_M1.md) | **Main technical spec (start here)** | Architecture, interfaces, technology stack, implementation phases |
| [**TECH_SPEC_DATABASE.md**](TECH_SPEC_DATABASE.md) | Database design and queries | `user_goal_progress` table, UPSERT, batch operations, migrations |
| [**TECH_SPEC_API.md**](TECH_SPEC_API.md) | REST API endpoints | GET /v1/challenges, POST claim endpoint, JWT auth |
| [**TECH_SPEC_EVENT_PROCESSING.md**](TECH_SPEC_EVENT_PROCESSING.md) | Event-driven architecture | IAM/Stat events, buffering (1M× query reduction), concurrency |
| [**TECH_SPEC_CONFIGURATION.md**](TECH_SPEC_CONFIGURATION.md) | Challenge configuration format | `challenges.json` schema, validation, in-memory cache |
| [**TECH_SPEC_TESTING.md**](TECH_SPEC_TESTING.md) | Testing strategy | Unit tests, integration tests, E2E tests, coverage targets (80%+) |
| [**TECH_SPEC_DEPLOYMENT.md**](TECH_SPEC_DEPLOYMENT.md) | Deployment guide | Local dev, Extend deployment, Kubernetes, monitoring |

---

## Technical Specifications (M2 Extensions)

Milestone 2 adds multiple challenges, tagging, and performance optimizations.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M2.md**](TECH_SPEC_M2.md) | M2 feature specification | Multiple challenges, tags, filtering, assignment rules |
| [**TECH_SPEC_M2_OPTIMIZATION.md**](TECH_SPEC_M2_OPTIMIZATION.md) | Performance optimizations for M2 | Query optimization, indexing strategy, caching |

---

## Technical Specifications (M3 Time-Based Challenges)

Milestone 3 introduces time-based challenges, schedules, and rotation.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M3.md**](TECH_SPEC_M3.md) | M3 feature specification | Schedules, timezones, rotation, prerequisites, visibility |

---

## Architecture & Design

Deep dive into design decisions and system architecture.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**BRAINSTORM.md**](BRAINSTORM.md) | M1 design decisions (70 decisions) | Event-driven rationale, buffering analysis, interface design |
| [**BRAINSTORM_M2.md**](BRAINSTORM_M2.md) | M2 design decisions | Multi-challenge architecture, tagging system, filtering |
| [**TECH_SPEC_TEMPLATE_ARCHITECTURE.md**](TECH_SPEC_TEMPLATE_ARCHITECTURE.md) | AccelByte template architecture | Template structure, customization boundaries, Extend patterns |
| [**JWT_AUTHENTICATION.md**](JWT_AUTHENTICATION.md) | JWT authentication architecture | Token validation, user extraction, security model |
| [**ADR_001_OPTIMIZED_HTTP_HANDLER.md**](ADR_001_OPTIMIZED_HTTP_HANDLER.md) | Architecture Decision Record: Optimized HTTP handler | GET /v1/challenges optimization, dual handler approach |

---

## Performance & Optimization

Performance testing, profiling, and optimization guides.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**PERFORMANCE_BASELINE.md**](PERFORMANCE_BASELINE.md) | M1 performance baseline metrics | Throughput (500 events/sec), latency (p95), batch performance |
| [**M3_PHASE5_PERFORMANCE_RESULTS.md**](M3_PHASE5_PERFORMANCE_RESULTS.md) | M3 Phase 5 performance results | Comparison vs M1, regression testing |
| [**PERFORMANCE_TUNING.md**](PERFORMANCE_TUNING.md) | Performance tuning guide | Profiling, optimization techniques, bottleneck identification |
| [**PROFILING_GUIDE.md**](PROFILING_GUIDE.md) | Go profiling guide | pprof usage, CPU/memory profiling, flame graphs |
| [**BATCH_INCREMENT_OPTIMIZATION.md**](BATCH_INCREMENT_OPTIMIZATION.md) | Batch increment optimization | SQL query optimization for batch UPSERT |
| [**PREVENTING_OPTIMIZATION_TRAP.md**](PREVENTING_OPTIMIZATION_TRAP.md) | Avoiding premature optimization | When to optimize, when to defer, trade-off analysis |

---

## Operational Guides

Production deployment, monitoring, and capacity planning.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_OBSERVABILITY.md**](TECH_SPEC_OBSERVABILITY.md) | Observability and monitoring | Metrics, logs, traces, Prometheus, Grafana, alerting |
| [**CAPACITY_PLANNING.md**](CAPACITY_PLANNING.md) | Capacity planning guide | Resource sizing, scaling thresholds, load estimates |
| [**TECH_SPEC_DATABASE_PARTITIONING.md**](TECH_SPEC_DATABASE_PARTITIONING.md) | Database partitioning strategy | Scaling to 10M+ users, hash partitioning, migration path |

---

## Testing

End-to-end testing guides and test documentation.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**tests/e2e/README.md**](../tests/e2e/README.md) | E2E testing guide (comprehensive) | All test scenarios, setup, troubleshooting |
| [**tests/e2e/QUICK_START.md**](../tests/e2e/QUICK_START.md) | E2E quick start (5 minutes) | Minimal setup, run tests immediately |
| [**tests/e2e/E2E_TESTING_GUIDE.md**](../tests/e2e/E2E_TESTING_GUIDE.md) | Detailed E2E testing guide | Test structure, helpers, writing new tests |
| [**tests/e2e/MULTI_USER_TESTING.md**](../tests/e2e/MULTI_USER_TESTING.md) | Multi-user testing guide | Concurrency testing, isolation verification |

---

## Development Process

Project status, milestones, and development workflows.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**STATUS.md**](STATUS.md) | Current implementation status | Current phase, completed features, next steps |
| [**MILESTONES.md**](MILESTONES.md) | Product roadmap (M1-M6) | Feature roadmap, milestone breakdown, future plans |
| [**CODE_REVIEW_ISSUES.md**](CODE_REVIEW_ISSUES.md) | Code review findings | Known issues, technical debt, improvement opportunities |
| [**CLAUDE.md**](../CLAUDE.md) | AI agent development guide | Project conventions, coding standards, workflow |

---

## Product Documentation

Product requirements and demo app guides.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**[Engagement] PRD - Challenge Service.docx.pdf**]([Engagement]%20PRD%20-%20Challenge%20Service.docx.pdf) | Product Requirements Document | Business requirements, use cases, customer needs |
| [**demo-app/**](demo-app/) | Demo app documentation | CLI usage, TUI interface, testing tools |

---

## Documentation for Different Audiences

### For New Developers (Getting Started)
1. Start with [README.md](../README.md) for platform overview
2. Read [TECH_SPEC_M1.md](TECH_SPEC_M1.md) for architecture overview
3. Follow [tests/e2e/QUICK_START.md](../tests/e2e/QUICK_START.md) to run tests
4. Review [TECH_SPEC_TEMPLATE_ARCHITECTURE.md](TECH_SPEC_TEMPLATE_ARCHITECTURE.md) to understand AccelByte patterns

### For Backend Engineers (Implementation)
1. [TECH_SPEC_M1.md](TECH_SPEC_M1.md) - Core architecture
2. [TECH_SPEC_DATABASE.md](TECH_SPEC_DATABASE.md) - Database design
3. [TECH_SPEC_EVENT_PROCESSING.md](TECH_SPEC_EVENT_PROCESSING.md) - Event handling
4. [JWT_AUTHENTICATION.md](JWT_AUTHENTICATION.md) - Auth implementation
5. [TECH_SPEC_TESTING.md](TECH_SPEC_TESTING.md) - Testing strategy

### For DevOps/SRE (Operations)
1. [AGS_SETUP_GUIDE.md](../AGS_SETUP_GUIDE.md) - AccelByte setup
2. [TECH_SPEC_DEPLOYMENT.md](TECH_SPEC_DEPLOYMENT.md) - Deployment guide
3. [TECH_SPEC_OBSERVABILITY.md](TECH_SPEC_OBSERVABILITY.md) - Monitoring
4. [CAPACITY_PLANNING.md](CAPACITY_PLANNING.md) - Resource planning
5. [TECH_SPEC_DATABASE_PARTITIONING.md](TECH_SPEC_DATABASE_PARTITIONING.md) - Scaling strategy

### For QA Engineers (Testing)
1. [tests/e2e/QUICK_START.md](../tests/e2e/QUICK_START.md) - Quick start
2. [tests/e2e/README.md](../tests/e2e/README.md) - Comprehensive guide
3. [tests/e2e/E2E_TESTING_GUIDE.md](../tests/e2e/E2E_TESTING_GUIDE.md) - Detailed guide
4. [TECH_SPEC_TESTING.md](TECH_SPEC_TESTING.md) - Testing strategy

### For Product Managers (Features)
1. [README.md](../README.md) - Feature overview
2. [[Engagement] PRD - Challenge Service.docx.pdf]([Engagement]%20PRD%20-%20Challenge%20Service.docx.pdf) - Product requirements
3. [MILESTONES.md](MILESTONES.md) - Feature roadmap
4. [STATUS.md](STATUS.md) - Current implementation status

### For Performance Engineers
1. [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md) - Baseline metrics
2. [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md) - Tuning guide
3. [PROFILING_GUIDE.md](PROFILING_GUIDE.md) - Profiling techniques
4. [M3_PHASE5_PERFORMANCE_RESULTS.md](M3_PHASE5_PERFORMANCE_RESULTS.md) - Latest results

### For Customers (Forking)
1. [README.md](../README.md) - Quick start
2. [AGS_SETUP_GUIDE.md](../AGS_SETUP_GUIDE.md) - AGS integration
3. [TECH_SPEC_CONFIGURATION.md](TECH_SPEC_CONFIGURATION.md) - Challenge configuration
4. [TECH_SPEC_DEPLOYMENT.md](TECH_SPEC_DEPLOYMENT.md) - Deployment

### For AI Agents (Claude Code, Copilot, etc.)
1. [CLAUDE.md](../CLAUDE.md) - Project structure, conventions, workflows
2. [INDEX.md](INDEX.md) - This document (navigation)
3. [STATUS.md](STATUS.md) - Current state
4. [TECH_SPEC_M1.md](TECH_SPEC_M1.md) - Architecture overview

---

## Documentation Organization by Type

### Specifications (TECH_SPEC_*)
- **M1**: [M1](TECH_SPEC_M1.md), [Database](TECH_SPEC_DATABASE.md), [API](TECH_SPEC_API.md), [Events](TECH_SPEC_EVENT_PROCESSING.md), [Config](TECH_SPEC_CONFIGURATION.md), [Testing](TECH_SPEC_TESTING.md), [Deployment](TECH_SPEC_DEPLOYMENT.md)
- **M2**: [M2](TECH_SPEC_M2.md), [M2 Optimization](TECH_SPEC_M2_OPTIMIZATION.md)
- **M3**: [M3](TECH_SPEC_M3.md)
- **Cross-cutting**: [Observability](TECH_SPEC_OBSERVABILITY.md), [Template Architecture](TECH_SPEC_TEMPLATE_ARCHITECTURE.md), [Database Partitioning](TECH_SPEC_DATABASE_PARTITIONING.md)

### Design Documents
- [BRAINSTORM.md](BRAINSTORM.md) - M1 design decisions
- [BRAINSTORM_M2.md](BRAINSTORM_M2.md) - M2 design decisions
- [JWT_AUTHENTICATION.md](JWT_AUTHENTICATION.md) - Auth design
- [ADR_001_OPTIMIZED_HTTP_HANDLER.md](ADR_001_OPTIMIZED_HTTP_HANDLER.md) - ADR example

### Performance Documents
- [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md) - Baseline metrics
- [M3_PHASE5_PERFORMANCE_RESULTS.md](M3_PHASE5_PERFORMANCE_RESULTS.md) - M3 results
- [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md) - Tuning guide
- [PROFILING_GUIDE.md](PROFILING_GUIDE.md) - Profiling guide
- [BATCH_INCREMENT_OPTIMIZATION.md](BATCH_INCREMENT_OPTIMIZATION.md) - Optimization example
- [PREVENTING_OPTIMIZATION_TRAP.md](PREVENTING_OPTIMIZATION_TRAP.md) - Best practices

### Operational Documents
- [CAPACITY_PLANNING.md](CAPACITY_PLANNING.md) - Resource planning
- [TECH_SPEC_DATABASE_PARTITIONING.md](TECH_SPEC_DATABASE_PARTITIONING.md) - Scaling strategy

### Project Management
- [STATUS.md](STATUS.md) - Current status
- [MILESTONES.md](MILESTONES.md) - Roadmap
- [CODE_REVIEW_ISSUES.md](CODE_REVIEW_ISSUES.md) - Known issues

---

## Document Status Legend

| Status | Description |
|--------|-------------|
| ✅ Complete | Document is comprehensive and up-to-date |
| 🔄 In Progress | Document exists but needs updates |
| 📝 Draft | Initial version, subject to change |
| 🚧 Planned | Document planned but not yet created |

---

## Contributing to Documentation

When adding new documentation:

1. **Add entry to this INDEX.md** - Keep navigation up-to-date
2. **Follow naming conventions**:
   - Specs: `TECH_SPEC_*.md`
   - Guides: `*_GUIDE.md`
   - Design: `BRAINSTORM*.md`, `ADR_*.md`
   - Performance: `PERFORMANCE_*.md`, `PROFILING_*.md`
3. **Link from related docs** - Cross-reference relevant documents
4. **Update CLAUDE.md** - Add context for AI agents if needed
5. **Keep under 500 lines** - Split large docs into focused documents

---

## Questions?

- **General Questions**: Start with [README.md](../README.md)
- **Technical Questions**: See [TECH_SPEC_M1.md](TECH_SPEC_M1.md)
- **Setup Issues**: See [AGS_SETUP_GUIDE.md](../AGS_SETUP_GUIDE.md)
- **Testing Issues**: See [tests/e2e/README.md](../tests/e2e/README.md)
- **Performance Issues**: See [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md)

For issues and bug reports, refer to the project repository's issue tracker.

---

**Next Steps:**

1. **New to the project?** → [README.md](../README.md) → [TECH_SPEC_M1.md](TECH_SPEC_M1.md)
2. **Setting up AGS?** → [AGS_SETUP_GUIDE.md](../AGS_SETUP_GUIDE.md)
3. **Running tests?** → [tests/e2e/QUICK_START.md](../tests/e2e/QUICK_START.md)
4. **Understanding architecture?** → [TECH_SPEC_M1.md](TECH_SPEC_M1.md) → [BRAINSTORM.md](BRAINSTORM.md)
5. **Performance tuning?** → [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md) → [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md)
