# Challenge Demo App - Technical Specification Questions

This document tracks open technical questions that need answers during implementation. These are implementation-level decisions, not design decisions.

**Document Status:** 🔄 Active (continuously updated)

---

## Question Categories

- 🔧 **Implementation Details** - How to implement a feature
- 📦 **Library Choices** - Which library/package to use
- ⚖️ **Trade-offs** - Performance vs simplicity decisions
- 🧪 **Testing** - How to test specific components
- 🚀 **Build/Deploy** - Build and release process

---

## Open Questions

**None! All implementation questions have been resolved.**

---

## Resolved Questions

Below are all previously resolved questions. Full details are documented in the respective tech specs.

| # | Question | Decision | Reference |
|---|----------|----------|-----------|
| 1 | Interface-Based Design | ✅ YES - Interfaces for testability | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 2 | Config File Format | ✅ YAML | [TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md) |
| 3 | TUI Framework | ✅ Bubble Tea | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 4 | Bubble Tea State Management | ✅ Nested Models (Parent + Child) | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 5 | Config File Management | ✅ Viper | [TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md) |
| 6 | Clipboard Access | ✅ atotto/clipboard | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 7 | Token Auto-Refresh | ✅ Bubble Tea Tick Command | [TECH_SPEC_AUTHENTICATION.md](./TECH_SPEC_AUTHENTICATION.md) |
| 8 | Error Handling Strategy | ✅ Contextual Debug Mode | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 9 | Bubble Tea Unit Tests | ✅ Table-driven tests for Update() | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 10 | Event Triggering Method | ✅ Use existing OnMessage RPC (no new endpoint) | [TECH_SPEC_EVENT_TRIGGERING.md](./TECH_SPEC_EVENT_TRIGGERING.md) |
| 11 | Cross-Platform Compilation | ✅ GoReleaser + GitHub Actions | [DESIGN.md](./DESIGN.md) |
| 12 | Progress Bar Rendering | ✅ Solid Blocks `[████░░]` | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 13 | Config Wizard Flow | ✅ Prompt user on first launch | [TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md) |
| 14 | Integration Test Strategy | ✅ Dependency injection with mocks | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 15 | Binary Distribution | ✅ GitHub Releases (primary) | [DESIGN.md](./DESIGN.md) |
| 16 | Dashboard Navigation | ✅ Drill-down model (Enter/Esc) | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 17 | Mock Auth Backend | ✅ Use `PLUGIN_GRPC_SERVER_AUTH_ENABLED=false` | [TECH_SPEC_AUTHENTICATION.md](./TECH_SPEC_AUTHENTICATION.md) |
| 18 | Project Repository | ✅ `extend-challenge/extend-challenge-demo-app/` | All specs |
| 19 | Text Input Component | ✅ Bubbles TextInput | [TECH_SPEC_TUI.md](./TECH_SPEC_TUI.md) |
| 20 | Binary Naming | ✅ `challenge-demo` | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 21 | Config Directory | ✅ `~/.challenge-demo/` | [TECH_SPEC_CONFIG.md](./TECH_SPEC_CONFIG.md) |
| 22 | AccelByte Proto Version | ✅ Match event handler | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 23 | Go Version | ✅ 1.21+ | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |
| 24 | Dependency Pinning | ✅ Pin latest stable | [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) |

---

## Recently Resolved Questions (Current Session)

These questions were resolved in the current session based on user decisions:

| # | Question | Decision | Notes |
|---|----------|----------|-------|
| 20 | Dashboard Navigation | ✅ Drill-down (Enter/Esc) | Spec updated in TECH_SPEC_TUI.md |
| 21 | Event Handler Endpoint | ✅ Use existing OnMessage RPC | No new endpoint needed - simplified implementation |
| 22 | Mock Auth Backend | ✅ `PLUGIN_GRPC_SERVER_AUTH_ENABLED=false` | Existing env var, no backend changes |
| 23 | Project Structure | ✅ `extend-challenge-demo-app/` at root | Module: `github.com/AccelByte/extend-challenge/extend-challenge-demo-app` |
| 24 | Text Input Component | ✅ Bubbles TextInput | Standard choice for Bubble Tea apps |
| 25 | Binary Naming | ✅ `challenge-demo` | Short, easy to type |
| 26 | Config Directory | ✅ `~/.challenge-demo/` | Matches binary name |
| 27 | AccelByte Proto Version | ✅ Match event handler version | Check event handler's `go.mod` |
| 28 | Go Version | ✅ 1.21+ (match main project) | Check main project's `go.mod` |
| 29 | Dependency Pinning | ✅ Pin latest stable at implementation | Control breaking changes |

---

## Question Resolution Process

When a question is resolved:
1. Move it to "Resolved Questions" section
2. Document the decision and rationale
3. Add date decided
4. Update relevant tech spec document

---

## Related Documents

- [DESIGN.md](./DESIGN.md) - High-level design decisions
- [INDEX.md](./INDEX.md) - Documentation structure
- [STATUS.md](./STATUS.md) - Implementation progress tracker
- Individual tech specs (all complete)

---

## Last Updated

- **2025-10-20**: Initial document created with 12 open questions
- **2025-10-20**: All 12 questions resolved based on recommendations
