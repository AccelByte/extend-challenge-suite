# AccelByte Extend Challenge Service - Documentation Index

**Version**: M5 (Milestone 5 Complete)
**Last Updated**: 2026-03-01

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

## Technical Specifications (M2 Performance Profiling & Load Testing)

Milestone 2 profiles system limits under load and validates scaling assumptions.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M2.md**](TECH_SPEC_M2.md) | M2 feature specification | Load testing with k6, bottleneck discovery, scaling |
| [**TECH_SPEC_M2_OPTIMIZATION.md**](TECH_SPEC_M2_OPTIMIZATION.md) | Performance optimizations for M2 | Query optimization, indexing strategy, caching |

---

## Technical Specifications (M3 Per-User Goal Assignment Control)

Milestone 3 adds per-user goal assignment, the Initialize endpoint, and activate/deactivate flows.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M3.md**](TECH_SPEC_M3.md) | M3 feature specification | Goal assignment, initialization endpoint, activate/deactivate |

---

## Technical Specifications (M4 Batch & Random Selection)

Milestone 4 adds flexible goal selection patterns.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M4.md**](TECH_SPEC_M4.md) | M4 feature specification | Batch manual selection, random selection, BatchUpsertGoalActive |

---

## Technical Specifications (M5 Time-Based Rotation)

Milestone 5 adds time-based goal rotation with ProgressMode and rotation configuration.

| Document | Description | Key Topics |
|----------|-------------|------------|
| [**TECH_SPEC_M5.md**](TECH_SPEC_M5.md) | M5 feature specification | ProgressMode (absolute/relative), rotation config, SQL CASE rotation, baseline_value, expires_at |

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
| [**PERFORMANCE_BASELINE.md**](PERFORMANCE_BASELINE.md) | Current performance baseline metrics | Throughput (500 events/sec), latency (p95), batch performance |
| [**M5_PERFORMANCE_RESULTS.md**](M5_PERFORMANCE_RESULTS.md) | M5 load test report | Rotation overhead, combined load, scaling analysis |
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
| [**tests/e2e/README.md**](../tests/e2e/README.md) | E2E testing guide (comprehensive) | All test scenarios, auth modes, dual-token, multi-user, debugging |
| [**tests/e2e/QUICK_START.md**](../tests/e2e/QUICK_START.md) | E2E quick start (5 minutes) | Minimal setup, run tests immediately |

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
| [**demo-app/**](demo-app/) | Demo app documentation ([full index](demo-app/INDEX.md)) | CLI usage, TUI interface, testing tools, architecture |

---

## Reading Paths by Audience

| Audience | Start with | Then read |
|----------|-----------|-----------|
| **New developers** | [README.md](../README.md) | [TECH_SPEC_M1.md](TECH_SPEC_M1.md), [QUICK_START.md](../tests/e2e/QUICK_START.md) |
| **Backend engineers** | [TECH_SPEC_M1.md](TECH_SPEC_M1.md) | [Database](TECH_SPEC_DATABASE.md), [Events](TECH_SPEC_EVENT_PROCESSING.md), [JWT](JWT_AUTHENTICATION.md) |
| **DevOps / SRE** | [AGS_SETUP_GUIDE.md](../AGS_SETUP_GUIDE.md) | [Deployment](TECH_SPEC_DEPLOYMENT.md), [Observability](TECH_SPEC_OBSERVABILITY.md), [Capacity](CAPACITY_PLANNING.md) |
| **QA engineers** | [QUICK_START.md](../tests/e2e/QUICK_START.md) | [E2E README](../tests/e2e/README.md), [Testing](TECH_SPEC_TESTING.md) |
| **Product managers** | [README.md](../README.md) | [MILESTONES.md](MILESTONES.md), [STATUS.md](STATUS.md) |
| **Performance engineers** | [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md) | [Tuning](PERFORMANCE_TUNING.md), [Profiling](PROFILING_GUIDE.md) |
| **Customers (forking)** | [README.md](../README.md) | [Configuration](TECH_SPEC_CONFIGURATION.md), [AGS Setup](../AGS_SETUP_GUIDE.md), [Deployment](TECH_SPEC_DEPLOYMENT.md) |
| **AI agents** | [CLAUDE.md](../CLAUDE.md) | [INDEX.md](INDEX.md), [STATUS.md](STATUS.md), [TECH_SPEC_M1.md](TECH_SPEC_M1.md) |

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
