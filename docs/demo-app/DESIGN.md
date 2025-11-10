# Challenge Service Demo Application - Design Specification

## Document Purpose

This is a **design specification** (not a technical spec) for a standalone demo and testing application that provides a Terminal UI (TUI) for interacting with the Challenge Service. This document focuses on the "why" and "what" rather than implementation details.

---

## 1. Overview

### 1.1 Purpose

Create a **simple, portable terminal application** that allows developers, QA engineers, and stakeholders to:
- **Demo** the Challenge Service features to potential customers
- **Test** challenge mechanics without writing integration tests
- **Debug** event processing and progress tracking in real-time
- **Validate** deployments (both local and AGS-hosted)

### 1.2 Why TUI? (Design Rationale)

**Simplicity & Portability:**
- ✅ Single binary (download and run, no installation)
- ✅ Zero dependencies (no Node.js, no browser, no CORS issues)
- ✅ Works everywhere (Linux, macOS, Windows, SSH sessions)
- ✅ Scriptable (can be used in CI/CD pipelines)
- ✅ Fast to build (2-3 days vs 5-7 days for web app)

**Developer Experience:**
- ✅ Familiar to technical audience (like k9s, lazygit, htop)
- ✅ Keyboard-driven (faster than mouse for power users)
- ✅ Copy/paste friendly (raw JSON in terminal)
- ✅ Demo-ready (project terminal during presentations)

**Trade-offs Accepted:**
- ⚠️ Less polished than web UI for executive demos
- ⚠️ Requires basic terminal knowledge
- ⚠️ Not suitable for non-technical stakeholders without guidance

**Decision:** TUI provides the best balance of simplicity, portability, and developer experience for this use case.

---

### 1.3 Target Audience

| Persona | Use Case | Key Needs |
|---------|----------|-----------|
| **Game Developer** | Evaluating the Challenge Service for their game | See challenges in action, understand reward flow |
| **QA Engineer** | Testing challenge configurations and edge cases | Trigger events manually, observe progress updates |
| **Backend Developer** | Debugging event processing and API responses | See raw JSON, trigger specific scenarios |
| **DevOps Engineer** | Validating deployments and health checks | Quick smoke tests, environment switching |

**Note:** Product Managers/non-technical stakeholders can still use this tool but may require initial guidance or a screen share demo.

---

### 1.4 Non-Goals (What This Is NOT)

- ❌ Production-ready player-facing UI
- ❌ Admin panel for creating/editing challenges (M1 uses JSON config)
- ❌ Performance testing tool (use k6 for that)
- ❌ Monitoring/observability dashboard (use Grafana)
- ❌ Multi-user concurrent testing (single-user focused)

---

## 2. Core Use Cases

### 2.1 Primary User Flows

#### Flow 1: Quick Start (Zero Config)
```
User → Download single binary
     → Run ./challenge-demo
     → Presented with config wizard
     → Enter environment (local/staging/prod)
     → Authenticate (credentials from config file or prompt)
     → View challenges dashboard
```

**Design Principle:** First-time user should see challenges within 60 seconds.

---

#### Flow 2: Navigate Challenges
```
User → View challenge list (main screen)
     → Arrow keys to select challenge
     → Press Enter to view details
     → See goals with progress bars
     → Tab to switch between challenges/goals/events
```

**Design Principle:** Keyboard-driven navigation (no mouse required).

---

#### Flow 3: Simulate Gameplay Events
```
User → Press 'e' to open event simulator
     → Select event type (login / stat update)
     → Enter parameters (stat code, value)
     → Press Enter to trigger
     → See confirmation + timestamp
     → Auto-refresh shows updated progress
```

**Design Principle:** Common actions should be single-key shortcuts.

---

#### Flow 4: Claim Rewards
```
User → Navigate to completed goal
     → Press 'c' to claim reward
     → See loading spinner
     → Success: ✓ Reward claimed! (details shown)
     → Failure: ✗ Error message with reason
```

**Design Principle:** Immediate visual feedback for all actions.

---

#### Flow 5: Watch Mode (Real-Time Monitoring)
```
User → Press 'w' to toggle watch mode
     → Screen auto-refreshes every 2 seconds
     → Changed values highlighted in color
     → Trigger events from separate terminal (curl)
     → Observe progress updates in real-time
     → Press 'w' again to pause
```

**Design Principle:** Non-intrusive auto-refresh that doesn't disrupt reading.

---

### 2.2 Secondary User Flows

#### Flow 6: Debug Mode
```
Developer → Press 'd' to toggle debug panel
          → See raw JSON requests/responses
          → Press 'y' to copy JSON to clipboard
          → Press 'u' to copy as curl command
          → Use for bug reports or manual testing
```

**Design Principle:** Easy access to raw data for debugging.

---

#### Flow 7: Multi-User Simulation
```
QA Engineer → Press 'u' to switch user
            → Enter different user_id
            → Re-authenticate with new context
            → View progress for different user
            → Press 'u' again to switch back
```

**Design Principle:** Quick context switching without restarting app.

---

#### Flow 8: Environment Switching
```
DevOps → Press '1' for local, '2' for staging, '3' for prod
       → Or press 'x' to open config editor
       → Modify API URL, credentials, namespace
       → Press Enter to reconnect
       → See connection status indicator
```

**Design Principle:** Fast environment switching for deployment validation.

---

## 3. Key Features

### 3.1 Environment Configuration

**Requirement:** Support testing against multiple backend environments without restarting the app.

**Features:**
- **Environment Presets:**
  - `1` = Local Development (http://localhost:8080)
  - `2` = AGS Staging (custom URL)
  - `3` = AGS Production (custom URL)
  - `x` = Edit configuration

- **Configuration Inputs:**
  - Backend API Base URL
  - AGS IAM Base URL
  - Client ID / Client Secret (for service account auth)
  - Namespace
  - Test User ID (for simulating different users)

- **Persistence:**
  - Save configuration to `~/.challenge-demo/config.yaml`
  - Load on startup (skip wizard if config exists)
  - Override with CLI flags: `--env prod --user test-123`

**Rationale:**
Developers need to quickly switch between local testing and cloud deployments. TUI allows both keyboard shortcuts (1/2/3) and config file editing.

---

### 3.2 Authentication

**Requirement:** Authenticate with AGS IAM to obtain valid JWT tokens for API requests.

**Features:**
- **Service Account Login:**
  - Use OAuth2 Client Credentials flow
  - Input: Client ID, Client Secret (from config or prompt)
  - Output: Bearer token (auto-refreshed)

- **User Impersonation:**
  - Simulate different users by entering user_id (press 'u')
  - Token scoped to specified namespace

- **Token Status Indicator:**
  - Show token expiration in status bar: `[Auth: ✓ expires in 45m]`
  - Auto-refresh before expiration
  - Visual warning when nearing expiration

**Rationale:**
All Challenge Service endpoints require JWT authentication. The app must handle this transparently so users can focus on testing features, not auth mechanics.

---

### 3.3 Challenge Dashboard (Main Screen)

**Requirement:** Visual overview of all challenges and their goals.

**Layout Example:**
```
┌─ Challenge Service Demo ─────────────────────────────────────┐
│ Env: Local │ User: test-user-123 │ Auth: ✓ 45m │ [q] Quit    │
├───────────────────────────────────────────────────────────────┤
│ CHALLENGES                                       [w] Watch On │
│                                                                │
│ ► Daily Login Challenge                          2/3 goals    │
│   ├─ ● Login 3 times           [████████░░] 2/3              │
│   ├─ ● Login 5 days straight   [██░░░░░░░░] 1/5              │
│   └─ ● Complete daily quest    [░░░░░░░░░░] 0/1              │
│                                                                │
│   Combat Challenge                                3/3 goals    │
│   ├─ ✓ Get 10 kills            [██████████] 10/10 [c] Claim  │
│   ├─ ✓ Get 50 kills            [██████████] 50/50 [c] Claim  │
│   └─ ⚡ Get 100 kills          [██████████] 100/100 CLAIMED   │
│                                                                │
├───────────────────────────────────────────────────────────────┤
│ [↑↓] Navigate [Enter] Details [e] Trigger Event [d] Debug    │
└───────────────────────────────────────────────────────────────┘
```

**Features:**
- **Challenge List:**
  - Show all challenges from `GET /v1/challenges`
  - Collapsible tree view (challenge → goals)
  - Progress indicators: `●` (in progress), `✓` (completed), `⚡` (claimed)

- **Goal Details:**
  - Name, description, requirement
  - Progress bar with percentage
  - Status badges with color coding:
    - Gray: Not started
    - Blue: In progress
    - Green: Completed (claimable)
    - Gold: Claimed

- **Visual Design:**
  - Box drawing characters for borders
  - ANSI colors for status (gray/blue/green/gold)
  - Progress bars using block characters (█)
  - Clear keyboard shortcuts in footer

**Rationale:**
This is the primary interface for demos. Terminal UI can be surprisingly visual with proper use of colors, box characters, and layout. Inspired by k9s and lazygit.

---

### 3.4 Event Simulator

**Requirement:** Manually trigger AGS events to test progress tracking without deploying a full game client.

**Layout Example:**
```
┌─ Event Simulator ─────────────────────────────────────────────┐
│ Select event type:                                             │
│ ► Login Event                                                  │
│   Stat Update Event                                            │
│                                                                │
│ Parameters:                                                    │
│ (none required for login event)                               │
│                                                                │
│ [Enter] Send Event  [Esc] Cancel                              │
├───────────────────────────────────────────────────────────────┤
│ Recent Events:                                                 │
│ ✓ 14:32:15 - Login event processed (150ms)                    │
│ ✓ 14:31:42 - Stat update: kills=15 (89ms)                     │
│ ✓ 14:30:01 - Login event processed (142ms)                    │
└───────────────────────────────────────────────────────────────┘
```

**Features:**
- **Event Types:**
  - **Login Event:** Simulates `{namespace}.iam.account.v1.userLoggedIn`
  - **Stat Update Event:** Simulates `{namespace}.social.statistic.v1.statItemUpdated`
    - Input fields: Stat code (dropdown), new value (number)
    - Presets: kills, deaths, wins, losses, score

- **Batch Triggering:**
  - Quick actions: `+10` (login 10 times), `+5` (increment stat by 5)
  - Press 'b' to open batch mode

- **Event History:**
  - Last 10 events with timestamps
  - Success/failure indicator
  - Processing time for performance monitoring

**Implementation Note:**
This will call a test endpoint on the event handler service (to be added) or publish to AGS Event Bus (for cloud deployments).

**Rationale:**
QA engineers need to test event processing without writing code. TUI form is faster than web form for repetitive testing.

---

### 3.5 Reward Claiming

**Requirement:** Test the reward claim flow and observe grant results.

**Features:**
- **Claim Action:**
  - Navigate to completed goal → Press 'c'
  - Show loading spinner: `⠋ Claiming reward...`
  - Success: `✓ Reward claimed! 100 Gold Coins added to wallet`
  - Failure: `✗ Failed: Goal already claimed`

- **Result Display:**
  - Show reward details (type, code, quantity)
  - Display API response time
  - For failures, show error code and message

- **Claim History (Optional):**
  - Press 'h' to view claim history
  - List of claimed rewards with timestamps

**Rationale:**
Reward claiming involves external AGS Platform calls. Developers need visibility into grant success/failure for debugging integration issues.

---

### 3.6 Real-Time Progress Monitoring (Watch Mode)

**Requirement:** Observe challenge progress updates as events are processed.

**Features:**
- **Watch Mode Toggle:**
  - Press 'w' to enable (status bar shows: `[w] Watch On`)
  - Polls API every 2 seconds
  - Visual indicator when refreshing: `[Refreshing... ⠋]`

- **Change Highlighting:**
  - Changed values flash or use different color
  - Example: `2/3` → `3/3` (green background for 1 second)

- **Performance Metrics:**
  - Show API response time in status bar: `[API: 125ms]`
  - Display last refresh timestamp

**Rationale:**
Event processing is asynchronous (buffered, 1-second flush). Developers need to see progress updates propagate in near real-time. Watch mode allows monitoring while triggering events from another terminal.

---

### 3.7 Debug Tools

**Requirement:** Provide low-level debugging capabilities for developers.

**Layout Example:**
```
┌─ Debug View ──────────────────────────────────────────────────┐
│ Last Request:                                 [y] Copy JSON   │
│ GET /v1/challenges/daily-login                                 │
│                                                                │
│ Response (200 OK, 142ms):                                      │
│ {                                                              │
│   "id": "daily-login",                                         │
│   "name": "Daily Login Challenge",                             │
│   "goals": [...]                                               │
│ }                                                              │
│                                                                │
│ Curl Command:                                 [u] Copy Curl   │
│ curl -X GET http://localhost:8080/v1/challenges/daily-login \ │
│   -H "Authorization: Bearer eyJ..."                            │
├───────────────────────────────────────────────────────────────┤
│ [d] Hide Debug  [↑↓] Scroll  [PgUp/PgDn] Page                 │
└───────────────────────────────────────────────────────────────┘
```

**Features:**
- **Request/Response Inspector:**
  - Toggle with 'd' key
  - Show raw JSON (syntax highlighted if possible)
  - Scrollable view for long responses

- **Copy Functions:**
  - Press 'y' to copy JSON to clipboard
  - Press 'u' to copy as curl command (for manual testing)

- **Event Payload Viewer:**
  - In event simulator, show raw event JSON before sending
  - Copy event payload for reproduction

**Rationale:**
When things go wrong, developers need raw data to reproduce issues and file bug reports. Terminal clipboard integration makes this seamless.

---

## 4. Technology Stack (Recommendations)

### 4.1 Architecture

**Approach:** Single Go binary with terminal UI library.

**Components:**
1. **TUI Framework:** Bubble Tea (Elm architecture for Go)
   - Component-based UI with state management
   - Built-in support for keyboard input, animations, spinners

2. **Styling Library:** Lip Gloss
   - Terminal styling (colors, borders, padding)
   - Consistent visual design system

3. **UI Components:** Bubbles
   - Pre-built components (progress bars, spinners, lists, tables)
   - Saves development time

4. **API Client:** Standard Go `net/http` + custom client
   - JWT handling
   - Retry logic for event triggering

**Rationale:**
Bubble Tea is the de facto standard for modern Go TUIs. Used by many popular tools (gh, glow, soft-serve). Mature, well-documented, actively maintained.

---

### 4.2 Technology Choices (Justified)

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **TUI Framework** | Bubble Tea | Industry standard, Elm architecture, great docs |
| **Styling** | Lip Gloss | Designed for Bubble Tea, declarative styling |
| **UI Components** | Bubbles | Official component library, consistent UX |
| **Config Management** | Viper | Standard Go config library, supports YAML/ENV |
| **Clipboard** | atotto/clipboard | Cross-platform clipboard access |
| **HTTP Client** | net/http | Standard library, no external dependencies |
| **JWT** | golang-jwt/jwt | Standard JWT library, used by main service |

**Dependencies:** Minimal (~5 external libraries)

---

### 4.3 Why Not CLI?

**Question:** Why TUI instead of simple CLI commands?

**Answer:**
- CLI requires memorizing commands and flags
- TUI provides visual feedback and guided workflows
- Better for demos (visual > text output)
- Easier for non-frequent users (self-documenting UI)

**When CLI is Better:**
- CI/CD pipelines (scripting)
- Single-action tasks (e.g., `challenge-demo claim daily-login goal-1`)

**Solution:** Support both modes:
- `challenge-demo` → Launch TUI (default)
- `challenge-demo list` → CLI command (for scripting)
- `challenge-demo trigger login` → CLI command

---

## 5. User Interface Design Principles

### 5.1 Discoverability Over Memorization

**Guideline:** Users should be able to explore the UI without reading docs.

**Examples:**
- Always show available keyboard shortcuts in footer
- Use descriptive labels (not cryptic symbols)
- Help panel accessible via '?' key

---

### 5.2 Immediate Feedback

**Guideline:** Every action should have visible confirmation.

**Examples:**
- Button press → Highlight or color change
- API call → Loading spinner with message
- Success/failure → Clear icon and message (✓/✗)

---

### 5.3 Graceful Degradation

**Guideline:** App should work in minimal terminal environments.

**Examples:**
- Fallback to ASCII if Unicode box drawing not supported
- Monochrome mode if colors unavailable (use bold/dim instead)
- Test in: macOS Terminal, iTerm2, Windows Terminal, PuTTY

---

### 5.4 Inspired by Best-in-Class TUIs

**Reference Tools:**
- **k9s** - Kubernetes dashboard (navigation, real-time updates)
- **lazygit** - Git client (keyboard shortcuts, panels)
- **htop** - Process monitor (progress bars, colors)
- **gh** - GitHub CLI (forms, confirmation prompts)

**Design Guideline:** If in doubt, follow conventions from these tools.

---

## 6. Deployment Models

### 6.1 Local Development

**Scenario:** Developer running Challenge Service locally via docker-compose.

**Setup:**
```bash
# Download binary (or build from source)
wget https://github.com/.../challenge-demo-linux-amd64
chmod +x challenge-demo-linux-amd64
mv challenge-demo-linux-amd64 /usr/local/bin/challenge-demo

# Run
challenge-demo

# First-time wizard
Environment: [1] Local  [2] Staging  [3] Prod
> 1

Backend URL: [http://localhost:8080]
> (Enter)

Namespace: [demo]
> (Enter)

User ID: [test-user]
> (Enter)

# Credentials (optional, can skip for local dev)
# Config saved to ~/.challenge-demo/config.yaml
# Launching...
```

**Requirements:**
- Challenge Service running on `http://localhost:8080`
- No CORS issues (direct API calls)

---

### 6.2 Shared Testing Environment

**Scenario:** QA team testing against a shared AGS deployment.

**Setup:**
```bash
# Download binary once
# Run with preset config
challenge-demo --config ~/.challenge-demo/staging.yaml

# Or create config file
cat > ~/.challenge-demo/staging.yaml <<EOF
environment: staging
backend_url: https://challenge-api.dev.accelbyte.io
iam_url: https://iam.dev.accelbyte.io
namespace: qa-namespace
client_id: xxx
client_secret: yyy
user_id: test-user-123
EOF

# Switch environments with flag
challenge-demo --env staging
challenge-demo --env prod
```

**Requirements:**
- Binary distributed to QA team (via GitHub Releases)
- Config files shared via docs or onboarding

---

### 6.3 Pre-built Binaries

**Scenario:** Distribute via GitHub Releases for easy access.

**Platforms:**
- `challenge-demo-linux-amd64`
- `challenge-demo-darwin-amd64` (macOS Intel)
- `challenge-demo-darwin-arm64` (macOS Apple Silicon)
- `challenge-demo-windows-amd64.exe`

**Distribution:**
- GitHub Releases (automated via CI)
- Install script: `curl -sSL https://.../install.sh | sh`
- Homebrew (future): `brew install challenge-demo`

**Benefits:**
- No dependencies (static binary)
- Works offline (after auth)
- Easy to update (`challenge-demo --update`)

---

## 7. Development Phases

### Phase 1: Core UI & API Client (1 day)
**Goal:** Basic TUI skeleton with API integration.

**Features:**
- Bubble Tea app with main screen
- Config loading from YAML file
- OAuth2 authentication flow
- Fetch and display challenges (GET /v1/challenges)
- Keyboard navigation (arrow keys, Enter, q to quit)

**Validation:**
- Developer can run binary → see challenge list → quit

---

### Phase 2: Event Simulation (1 day)
**Goal:** Add event triggering for testing progress updates.

**Features:**
- Event simulator panel (press 'e' to open)
- Form for login/stat update events
- Call event handler test endpoint
- Manual refresh (press 'r')

**Validation:**
- Developer can trigger login event → refresh → see progress update

---

### Phase 3: Watch Mode & Claiming (0.5 day)
**Goal:** Auto-refresh and reward claiming.

**Features:**
- Watch mode toggle (press 'w', poll every 2 seconds)
- Claim reward action (press 'c' on completed goal)
- Loading spinners for API calls

**Validation:**
- Developer can claim reward → see success message

---

### Phase 4: Debug Tools & Polish (0.5 day)
**Goal:** Debug panel and UX improvements.

**Features:**
- Debug panel (press 'd' to toggle)
- Copy JSON/curl to clipboard
- Improved error messages
- Help panel (press '?')

**Validation:**
- Developer can copy API request for bug report

---

### Phase 5: Multi-Environment & Config (0.5 day)
**Goal:** Support switching environments and config management.

**Features:**
- Environment presets (1/2/3 keys)
- Config editor (press 'x')
- Save/load config from file
- CLI flags for overrides

**Validation:**
- Developer can switch from local to staging without restarting

---

### Phase 6: Build & Distribution (0.5 day)
**Goal:** Cross-platform binaries and release.

**Features:**
- GoReleaser config for multi-platform builds
- GitHub Actions for automated releases
- Install script for easy setup

**Validation:**
- Non-developer can download and run binary on macOS/Linux/Windows

---

**Total Estimated Effort:** 3-4 days

---

## 8. Open Design Questions

### 8.1 Event Triggering Mechanism

**Question:** How should the TUI trigger events for testing?

**Options:**

| Option | Pros | Cons |
|--------|------|------|
| **A) Call Event Handler Test Endpoint** | Direct, fast, no AGS dependency | Requires exposing internal endpoint |
| **B) Publish to AGS Event Bus** | Realistic, tests full flow | Requires AGS credentials, complex |
| **C) Call Backend Service Endpoint** | Backend forwards to event handler | Adds custom endpoint |

**Recommendation:** Start with **Option A** (test endpoint) for local development. The event handler service should expose a `/test/trigger-event` endpoint (only enabled in dev mode).

---

### 8.2 CLI vs TUI Mode

**Question:** Should the app support both CLI and TUI modes?

**Recommendation:** Start with TUI-only for MVP. Add CLI commands in Phase 7 if needed for CI/CD integration.

**Example CLI Commands (Future):**
```bash
challenge-demo list                           # List challenges (JSON output)
challenge-demo show daily-login               # Show challenge details
challenge-demo trigger login                  # Trigger login event
challenge-demo claim daily-login goal-1       # Claim reward
challenge-demo watch                          # Watch mode (live updates)
```

---

### 8.3 Offline Mode

**Question:** Should the app work offline after initial auth?

**Recommendation:** No for MVP. All data is fetched from API in real-time. Caching can be added later if needed.

---

## 9. Success Metrics

### 9.1 Developer Experience

**Metrics:**
- Time to first successful API call: < 60 seconds
- Time to trigger event and see progress update: < 30 seconds
- Time to switch environments: < 10 seconds

### 9.2 Demo Effectiveness

**Metrics:**
- Technical stakeholder can run demo without help: Yes/No
- Demo covers all M1 features: Yes/No
- Can be presented via terminal projection: Yes/No

### 9.3 Testing Utility

**Metrics:**
- QA engineer can reproduce bug with TUI: Yes/No
- Developer can debug API issue using debug tools: Yes/No
- App works with both local and AGS deployments: Yes/No

---

## 10. Future Enhancements (Post-M1)

### M2: Multi-Challenge Support
- Filter challenges by tag (press 'f')
- Search challenges (press '/')

### M3: Time-Based Challenges
- Show challenge start/end times
- Countdown timers for expiring challenges

### M4: CLI Mode
- Scriptable commands for CI/CD
- JSON output mode (`--output json`)

### M5: Advanced Features
- Split-pane view (challenges + debug side-by-side)
- Log streaming (tail event handler logs)
- Performance profiling (events/sec, latency graphs)

---

## 11. Dependencies and Constraints

### 11.1 Dependencies on Challenge Service

**Requirements:**
- Challenge Service API must be accessible from TUI
- For event testing: Event handler exposes `/test/trigger-event` endpoint (dev mode only)

### 11.2 Constraints

**Technical:**
- Must work in modern terminals (UTF-8 support, ANSI colors)
- Minimum terminal size: 80x24 (standard)
- Single-user focused (no concurrent sessions)

**Security:**
- Do NOT bundle production AGS credentials in binary
- Store credentials in config file with restricted permissions (chmod 600)
- Warn users when using production environment

**Maintenance:**
- Keep dependencies minimal (< 10 external packages)
- Code should be easy to modify (well-documented Go code)
- Follow standard Go project layout

---

## 12. Project Structure

```
extend-challenge-demo/
├── cmd/
│   └── challenge-demo/
│       └── main.go              # Entry point
├── internal/
│   ├── tui/
│   │   ├── app.go               # Main Bubble Tea app
│   │   ├── dashboard.go         # Challenge list view (model)
│   │   ├── event_simulator.go  # Event trigger panel (model)
│   │   ├── debug.go             # Debug panel (model)
│   │   └── styles.go            # Lip Gloss styles
│   ├── api/
│   │   ├── client.go            # HTTP client with JWT handling
│   │   ├── challenges.go        # Challenge API endpoints
│   │   ├── auth.go              # AGS IAM authentication
│   │   └── events.go            # Event triggering
│   ├── config/
│   │   ├── config.go            # Config loading/saving
│   │   └── wizard.go            # First-time setup wizard
│   └── models/
│       ├── challenge.go         # Challenge domain models
│       └── event.go             # Event domain models
├── go.mod
├── go.sum
├── Makefile
├── .goreleaser.yaml             # Multi-platform build config
└── README.md
```

---

## 13. Documentation Requirements

### For End Users
- **README.md:** Quick start guide (60 seconds to first demo)
- **Keyboard Shortcuts Reference:** Built into TUI (press '?')
- **Troubleshooting:** Common issues (auth errors, connectivity)

### For Developers
- **Architecture Overview:** Bubble Tea models and update flow
- **Adding Features:** How to add new panels or actions
- **Building:** Cross-compilation and release process

---

## 14. Related Documents

- **[../TECH_SPEC_M1.md](../TECH_SPEC_M1.md)** - Challenge Service technical specification
- **[../TECH_SPEC_API.md](../TECH_SPEC_API.md)** - REST API endpoints
- **[../TECH_SPEC_EVENT_PROCESSING.md](../TECH_SPEC_EVENT_PROCESSING.md)** - Event handling details
- **[../MILESTONES.md](../MILESTONES.md)** - Product roadmap (M1-M6)

---

## 15. Conclusion

This Terminal UI demo application serves as a **portable, developer-friendly tool** for interacting with the Challenge Service. It prioritizes simplicity and speed over visual polish.

**Key Design Principles:**
1. **Portable First:** Single binary, zero dependencies, works everywhere
2. **Developer Experience:** Keyboard-driven, fast, copy/paste friendly
3. **Multi-Environment:** Quick switching between local/staging/prod
4. **Debug-Ready:** Raw data access, curl generation, request inspection

**Why TUI Over Web App:**
- ✅ 2-3 days vs 5-7 days development time
- ✅ Single binary vs multi-component deployment
- ✅ No CORS/browser/Node.js complexity
- ✅ Better for technical audience (developers, QA, DevOps)
- ⚠️ Trade-off: Less polished for executive demos (acceptable)

**Next Steps:**
1. Review this design spec with team
2. Set up Go project with Bubble Tea
3. Implement Phase 1 (Core UI & API Client)
4. Iterate based on feedback

**Estimated Total Effort:** 3-4 days for full implementation (Phases 1-6)
