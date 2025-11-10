# Challenge Demo App - Terminal UI Technical Specification

## Document Purpose

This technical specification defines the **Bubble Tea terminal user interface**, including models, views, keyboard handling, screen navigation, and styling.

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - Core interfaces and dependency injection
- [DESIGN.md](./DESIGN.md) - UI mockups and user flows

---

## 1. Overview

### 1.1 Bubble Tea Architecture

**Bubble Tea follows the Elm Architecture pattern:**

```
┌──────────────────────────────────────────────────┐
│                   Initialize                      │
│  (Create initial model with default state)       │
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│                     View                          │
│  (Render current state to terminal)              │
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│                   Update                          │
│  (Handle messages, update state, return commands)│
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
                   (Repeat)
```

**Key Concepts:**
- **Model:** Application state (immutable)
- **View:** Renders model to string
- **Update:** Handles messages, returns new model + commands
- **Command:** Async operation that produces a message

---

## 2. Root Application

### 2.1 App Struct

**Entry point for the TUI:**

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/app"
)

// App is the root Bubble Tea application
type App struct {
    container *app.Container
}

// NewApp creates a new TUI app
func NewApp(container *app.Container) *App {
    return &App{container: container}
}

// Run starts the TUI application
func (a *App) Run() error {
    // Create initial model
    model := NewAppModel(a.container)

    // Configure Bubble Tea program
    p := tea.NewProgram(
        model,
        tea.WithAltScreen(),        // Use alternate screen buffer
        tea.WithMouseCellMotion(),  // Enable mouse (optional)
    )

    // Start program
    _, err := p.Run()
    return err
}
```

---

### 2.2 AppModel (Root Model)

**Contains all screen models:**

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/app"
)

// Screen represents the current screen
type Screen int

const (
    ScreenDashboard Screen = iota
    ScreenEventSimulator
    ScreenDebug
    ScreenConfig
)

// AppModel is the root model containing all screen models
type AppModel struct {
    container     *app.Container
    currentScreen Screen
    width         int
    height        int

    // Screen models
    dashboard  *DashboardModel
    eventSim   *EventSimulatorModel
    debug      *DebugModel
    config     *ConfigModel

    // Global state
    watchMode  bool
    errorMsg   string
}

// NewAppModel creates the initial app model
func NewAppModel(container *app.Container) AppModel {
    return AppModel{
        container:     container,
        currentScreen: ScreenDashboard,
        width:         80,
        height:        24,
        dashboard:     NewDashboardModel(container.APIClient),
        eventSim:      NewEventSimulatorModel(container.EventTrigger, container.Config),
        debug:         NewDebugModel(container.APIClient),
        config:        NewConfigModel(container.Config),
        watchMode:     false,
    }
}
```

---

### 2.3 AppModel Init

**Initialize and start background tasks:**

```go
// Init initializes the model and returns initial commands
func (m AppModel) Init() tea.Cmd {
    return tea.Batch(
        m.dashboard.Init(),
        tokenRefreshTickCmd(),  // Start token refresh ticker
    )
}
```

---

### 2.4 AppModel Update

**Route messages to appropriate screen:**

```go
// Update handles messages and returns updated model
func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    var cmd tea.Cmd

    // Handle global messages first
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "ctrl+c", "q":
            return m, tea.Quit

        case "1":
            m.currentScreen = ScreenDashboard
            return m, m.dashboard.Init()

        case "2":
            m.currentScreen = ScreenEventSimulator
            return m, m.eventSim.Init()

        case "d":
            m.currentScreen = ScreenDebug
            return m, nil

        case "x":
            m.currentScreen = ScreenConfig
            return m, nil

        case "w":
            m.watchMode = !m.watchMode
            if m.watchMode {
                return m, watchModeTickCmd()
            }
            return m, nil
        }

    case tea.WindowSizeMsg:
        m.width = msg.Width
        m.height = msg.Height
        return m, nil

    case TickMsg:
        // Handle token refresh check
        token := m.container.AuthProvider.GetToken(context.Background())
        if token != nil && token.ExpiresIn() < 5*time.Minute {
            return m, refreshTokenCmd(m.container.AuthProvider)
        }
        return m, tokenRefreshTickCmd()

    case WatchTickMsg:
        // Handle watch mode refresh
        if m.watchMode {
            return m, tea.Batch(
                m.dashboard.loadChallengesCmd(),
                watchModeTickCmd(),
            )
        }
        return m, nil

    case ErrorMsg:
        m.errorMsg = msg.err.Error()
        return m, nil
    }

    // Route message to current screen
    switch m.currentScreen {
    case ScreenDashboard:
        newDashboard, cmd := m.dashboard.Update(msg)
        m.dashboard = newDashboard.(*DashboardModel)
        return m, cmd

    case ScreenEventSimulator:
        newEventSim, cmd := m.eventSim.Update(msg)
        m.eventSim = newEventSim.(*EventSimulatorModel)
        return m, cmd

    case ScreenDebug:
        newDebug, cmd := m.debug.Update(msg)
        m.debug = newDebug.(*DebugModel)
        return m, cmd

    case ScreenConfig:
        newConfig, cmd := m.config.Update(msg)
        m.config = newConfig.(*ConfigModel)
        return m, cmd
    }

    return m, cmd
}
```

---

### 2.5 AppModel View

**Render the current screen:**

```go
// View renders the current screen
func (m AppModel) View() string {
    // Render header
    header := m.renderHeader()

    // Render current screen
    var content string
    switch m.currentScreen {
    case ScreenDashboard:
        content = m.dashboard.View()
    case ScreenEventSimulator:
        content = m.eventSim.View()
    case ScreenDebug:
        content = m.debug.View()
    case ScreenConfig:
        content = m.config.View()
    }

    // Render footer
    footer := m.renderFooter()

    // Combine with borders
    return lipgloss.JoinVertical(
        lipgloss.Left,
        header,
        content,
        footer,
    )
}

// renderHeader renders the status bar
func (m AppModel) renderHeader() string {
    env := m.container.Config.Environment
    user := m.container.Config.UserID

    token := m.container.AuthProvider.GetToken(context.Background())
    authStatus := "✗ No auth"
    if token != nil && !token.IsExpired() {
        expiresIn := token.ExpiresIn()
        authStatus = fmt.Sprintf("✓ %dm", int(expiresIn.Minutes()))
    }

    watchStatus := ""
    if m.watchMode {
        watchStatus = " [Watch ON]"
    }

    return headerStyle.Render(
        fmt.Sprintf("Env: %s | User: %s | Auth: %s%s | [q] Quit",
            env, user, authStatus, watchStatus),
    )
}

// renderFooter renders keyboard shortcuts
func (m AppModel) renderFooter() string {
    var shortcuts string
    switch m.currentScreen {
    case ScreenDashboard:
        shortcuts = "[↑↓] Navigate [Enter] Details [e] Events [d] Debug [w] Watch [c] Claim"
    case ScreenEventSimulator:
        shortcuts = "[↑↓] Select [Enter] Trigger [Esc] Back"
    case ScreenDebug:
        shortcuts = "[↑↓] Scroll [y] Copy JSON [u] Copy Curl [Esc] Back"
    case ScreenConfig:
        shortcuts = "[↑↓] Navigate [Enter] Edit [s] Save [Esc] Back"
    }

    return footerStyle.Render(shortcuts)
}
```

---

## 3. Dashboard Screen

### 3.1 DashboardModel

**Shows challenges and goals:**

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

// ViewMode represents the dashboard view mode
type ViewMode int

const (
    ViewModeList ViewMode = iota  // Challenge list view
    ViewModeDetail                 // Single challenge detail view
)

// DashboardModel represents the challenge dashboard screen
type DashboardModel struct {
    apiClient       api.APIClient
    challenges      []api.Challenge
    viewMode        ViewMode
    challengeCursor int  // Selected challenge index (in list view)
    goalCursor      int  // Selected goal index (in detail view)
    loading         bool
    errorMsg        string
}

// NewDashboardModel creates a new dashboard model
func NewDashboardModel(apiClient api.APIClient) *DashboardModel {
    return &DashboardModel{
        apiClient:       apiClient,
        viewMode:        ViewModeList,
        challengeCursor: 0,
        goalCursor:      0,
    }
}

// Init loads challenges
func (m *DashboardModel) Init() tea.Cmd {
    return m.loadChallengesCmd()
}

// loadChallengesCmd returns a command to fetch challenges
func (m *DashboardModel) loadChallengesCmd() tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        challenges, err := m.apiClient.ListChallenges(ctx)
        return ChallengesLoadedMsg{challenges: challenges, err: err}
    }
}
```

---

### 3.2 Dashboard Messages

**Custom messages for dashboard:**

```go
// ChallengesLoadedMsg is sent when challenges are loaded
type ChallengesLoadedMsg struct {
    challenges []api.Challenge
    err        error
}

// RewardClaimedMsg is sent when a reward is claimed
type RewardClaimedMsg struct {
    challengeID string
    goalID      string
    result      *api.ClaimResult
    err         error
}
```

---

### 3.3 Dashboard Update

**Handle keyboard and messages:**

```go
// Update handles messages for the dashboard
func (m *DashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "up", "k":
            if m.viewMode == ViewModeList {
                // Navigate challenge list
                if m.challengeCursor > 0 {
                    m.challengeCursor--
                }
            } else {
                // Navigate goal list
                if m.goalCursor > 0 {
                    m.goalCursor--
                }
            }
            return m, nil

        case "down", "j":
            if m.viewMode == ViewModeList {
                // Navigate challenge list
                if m.challengeCursor < len(m.challenges)-1 {
                    m.challengeCursor++
                }
            } else {
                // Navigate goal list
                challenge := m.challenges[m.challengeCursor]
                if m.goalCursor < len(challenge.Goals)-1 {
                    m.goalCursor++
                }
            }
            return m, nil

        case "enter":
            // Drill down into selected challenge
            if m.viewMode == ViewModeList {
                m.viewMode = ViewModeDetail
                m.goalCursor = 0  // Reset goal cursor
            }
            return m, nil

        case "esc":
            // Go back to challenge list
            if m.viewMode == ViewModeDetail {
                m.viewMode = ViewModeList
            }
            return m, nil

        case "r":
            // Manual refresh
            m.loading = true
            return m, m.loadChallengesCmd()

        case "c":
            // Claim reward for selected goal (only in detail view)
            if m.viewMode == ViewModeDetail {
                return m, m.claimRewardCmd()
            }
            return m, nil
        }

    case ChallengesLoadedMsg:
        m.loading = false
        if msg.err != nil {
            m.errorMsg = "Failed to load challenges: " + msg.err.Error()
            return m, nil
        }
        m.challenges = msg.challenges
        m.errorMsg = ""
        return m, nil

    case RewardClaimedMsg:
        if msg.err != nil {
            m.errorMsg = "Failed to claim reward: " + msg.err.Error()
            return m, nil
        }
        m.errorMsg = ""
        // Refresh challenges to update status
        return m, m.loadChallengesCmd()
    }

    return m, nil
}

// claimRewardCmd returns a command to claim the selected goal's reward
func (m *DashboardModel) claimRewardCmd() tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        challenge := m.challenges[m.challengeCursor]
        goal := challenge.Goals[m.goalCursor]

        result, err := m.apiClient.ClaimReward(ctx, challenge.ID, goal.ID)
        return RewardClaimedMsg{
            challengeID: challenge.ID,
            goalID:      goal.ID,
            result:      result,
            err:         err,
        }
    }
}
```

---

### 3.4 Dashboard View

**Render challenges with progress bars:**

```go
// View renders the dashboard
func (m *DashboardModel) View() string {
    if m.loading {
        return spinnerStyle.Render("Loading challenges...")
    }

    if m.errorMsg != "" {
        return errorStyle.Render("Error: " + m.errorMsg)
    }

    if len(m.challenges) == 0 {
        return dimStyle.Render("No challenges found")
    }

    if m.viewMode == ViewModeList {
        return m.renderChallengeList()
    }
    return m.renderChallengeDetail()
}

// renderChallengeList renders the challenge list view
func (m *DashboardModel) renderChallengeList() string {
    var b strings.Builder
    b.WriteString(titleStyle.Render("CHALLENGES") + "\n\n")

    for i, challenge := range m.challenges {
        b.WriteString(m.renderChallenge(challenge, i == m.challengeCursor))
        b.WriteString("\n")
    }

    return b.String()
}

// renderChallengeDetail renders the detail view for selected challenge
func (m *DashboardModel) renderChallengeDetail() string {
    challenge := m.challenges[m.challengeCursor]

    var b strings.Builder
    b.WriteString(titleStyle.Render(challenge.Name) + "\n")
    b.WriteString(dimStyle.Render(challenge.Description) + "\n\n")

    b.WriteString(subtitleStyle.Render("GOALS") + "\n\n")

    for i, goal := range challenge.Goals {
        b.WriteString(m.renderGoalDetailed(goal, i == m.goalCursor))
    }

    b.WriteString("\n" + dimStyle.Render("[Esc] Back to list") + "\n")

    return b.String()
}

// renderChallenge renders a single challenge with goals
func (m *DashboardModel) renderChallenge(challenge api.Challenge, selected bool) string {
    var b strings.Builder

    // Challenge header
    cursor := " "
    if selected {
        cursor = "►"
    }

    completed := challenge.CompletedGoalCount()
    total := len(challenge.Goals)

    header := fmt.Sprintf("%s %s   %d/%d goals",
        cursor, challenge.Name, completed, total)

    if selected {
        b.WriteString(selectedStyle.Render(header) + "\n")
    } else {
        b.WriteString(header + "\n")
    }

    // Goals
    for _, goal := range challenge.Goals {
        b.WriteString(m.renderGoal(goal))
    }

    return b.String()
}

// renderGoal renders a single goal with progress bar (compact, for list view)
func (m *DashboardModel) renderGoal(goal api.Goal) string {
    // Status icon
    var icon string
    var style lipgloss.Style
    switch goal.Status {
    case "not_started":
        icon = "○"
        style = dimStyle
    case "in_progress":
        icon = "●"
        style = progressStyle
    case "completed":
        icon = "✓"
        style = completedStyle
    case "claimed":
        icon = "⚡"
        style = claimedStyle
    }

    // Progress bar
    progressBar := renderProgressBar(goal.Progress, goal.Target, 10)

    line := fmt.Sprintf("  %s %s %s %d/%d",
        icon, goal.Name, progressBar, goal.Progress, goal.Target)

    return style.Render(line) + "\n"
}

// renderGoalDetailed renders a single goal with full details (for detail view)
func (m *DashboardModel) renderGoalDetailed(goal api.Goal, selected bool) string {
    // Status icon
    var icon string
    var style lipgloss.Style
    switch goal.Status {
    case "not_started":
        icon = "○"
        style = dimStyle
    case "in_progress":
        icon = "●"
        style = progressStyle
    case "completed":
        icon = "✓"
        style = completedStyle
    case "claimed":
        icon = "⚡"
        style = claimedStyle
    }

    // Cursor indicator
    cursor := " "
    if selected {
        cursor = "►"
    }

    // Progress bar
    progressBar := renderProgressBar(goal.Progress, goal.Target, 20)

    // Claim button
    claimButton := ""
    if goal.CanClaim() && selected {
        claimButton = highlightStyle.Render(" [c] Claim")
    }

    // Build output
    var b strings.Builder
    b.WriteString(fmt.Sprintf("%s %s %s\n", cursor, icon, goal.Name))
    b.WriteString(fmt.Sprintf("  %s\n", dimStyle.Render(goal.Description)))

    // Show requirement details (stat code, operator, target value)
    if goal.Requirement.StatCode != "" {
        operatorSymbol := convertOperator(goal.Requirement.Operator) // gte -> >=, lte -> <=, eq -> ==
        requirementInfo := fmt.Sprintf("Requirement: %s %s %d",
            goal.Requirement.StatCode, operatorSymbol, goal.Requirement.TargetValue)
        b.WriteString(fmt.Sprintf("  %s\n", dimStyle.Render(requirementInfo)))
    }

    b.WriteString(fmt.Sprintf("  %s %d/%d%s\n", progressBar, goal.Progress, goal.Target, claimButton))
    b.WriteString(fmt.Sprintf("  Reward: %s\n\n", goal.Reward.DisplayString()))

    if selected {
        return selectedStyle.Render(b.String())
    }
    return style.Render(b.String())
}

// renderProgressBar renders a progress bar using block characters
func renderProgressBar(current, target, width int) string {
    if target == 0 {
        return strings.Repeat("░", width)
    }

    filled := (current * width) / target
    if filled > width {
        filled = width
    }

    return fmt.Sprintf("[%s%s]",
        strings.Repeat("█", filled),
        strings.Repeat("░", width-filled))
}
```

---

## 4. Event Simulator Screen

### 4.1 EventSimulatorModel

**Trigger test events:**

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/events"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/config"
)

// EventType represents the type of event to trigger
type EventType int

const (
    EventLogin EventType = iota
    EventStatUpdate
)

// EventSimulatorModel represents the event simulator screen
type EventSimulatorModel struct {
    eventTrigger events.EventTrigger
    config       *config.Config

    selectedType EventType
    statCodeInput  textinput.Model  // Bubbles text input
    statValueInput textinput.Model  // Bubbles text input
    focusedInput   int              // 0=event type, 1=stat code, 2=stat value

    history      []EventHistoryEntry
    sending      bool
    errorMsg     string
}

// IsInputFocused returns true if any text input is currently focused
// Used by AppModel to skip global shortcuts when user is typing
func (m *EventSimulatorModel) IsInputFocused() bool {
    return m.focusedInput == 1 || m.focusedInput == 2
}

// EventHistoryEntry represents a triggered event
type EventHistoryEntry struct {
    Time      time.Time
    EventType string
    Details   string
    Success   bool
    Duration  time.Duration
}

// NewEventSimulatorModel creates a new event simulator model
func NewEventSimulatorModel(trigger events.EventTrigger, cfg *config.Config) *EventSimulatorModel {
    return &EventSimulatorModel{
        eventTrigger: trigger,
        config:       cfg,
        selectedType: EventLogin,
        history:      make([]EventHistoryEntry, 0, 10),
    }
}

// Init initializes the event simulator
func (m *EventSimulatorModel) Init() tea.Cmd {
    return nil
}
```

---

### 4.2 Event Simulator Update

**Handle form input and triggering:**

```go
// Update handles messages for the event simulator
func (m *EventSimulatorModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "tab":
            // Cycle through inputs (event type → stat code → stat value)
            m.focusedInput = (m.focusedInput + 1) % 3
            m.updateInputFocus()
            return m, nil

        case "up", "k":
            if m.focusedInput == 0 {
                if m.selectedType == EventStatUpdate {
                    m.selectedType = EventTypeLogin
                }
            }
            return m, nil

        case "down", "j":
            if m.focusedInput == 0 {
                if m.selectedType == EventTypeLogin {
                    m.selectedType = EventTypeStatUpdate
                }
            }
            return m, nil

        case "enter":
            // Trigger selected event
            m.sending = true
            return m, m.triggerEventCmd()
        }

    case EventTriggeredMsg:
        m.sending = false
        if msg.err != nil {
            m.errorMsg = "Failed to trigger event: " + msg.err.Error()
            return m, nil
        }

        // Add to history
        m.history = append([]EventHistoryEntry{msg.entry}, m.history...)
        if len(m.history) > 10 {
            m.history = m.history[:10]
        }
        m.errorMsg = ""
        return m, nil
    }

    return m, nil
}

// triggerEventCmd returns a command to trigger the selected event
func (m *EventSimulatorModel) triggerEventCmd() tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()

        startTime := time.Now()
        var err error
        var eventType, details string

        switch m.selectedType {
        case EventLogin:
            err = m.eventTrigger.TriggerLogin(ctx, m.config.UserID, m.config.Namespace)
            eventType = "Login"
            details = "User logged in"

        case EventStatUpdate:
            value, _ := strconv.Atoi(m.statValue)
            err = m.eventTrigger.TriggerStatUpdate(ctx, m.config.UserID, m.config.Namespace, m.statCode, value)
            eventType = "StatUpdate"
            details = fmt.Sprintf("%s = %d", m.statCode, value)
        }

        duration := time.Since(startTime)

        return EventTriggeredMsg{
            entry: EventHistoryEntry{
                Time:      time.Now(),
                EventType: eventType,
                Details:   details,
                Success:   err == nil,
                Duration:  duration,
            },
            err: err,
        }
    }
}
```

---

### 4.3 Event Simulator Messages

```go
// EventTriggeredMsg is sent when an event is triggered
type EventTriggeredMsg struct {
    entry EventHistoryEntry
    err   error
}
```

---

### 4.4 Event Simulator View

**Render event form and history:**

```go
// View renders the event simulator
func (m *EventSimulatorModel) View() string {
    var b strings.Builder
    b.WriteString(titleStyle.Render("EVENT SIMULATOR") + "\n\n")

    // Event type selection
    b.WriteString("Select event type:\n")
    if m.selectedType == EventLogin {
        b.WriteString(selectedStyle.Render("► Login Event") + "\n")
    } else {
        b.WriteString("  Login Event\n")
    }

    if m.selectedType == EventStatUpdate {
        b.WriteString(selectedStyle.Render("► Stat Update Event") + "\n")
    } else {
        b.WriteString("  Stat Update Event\n")
    }

    b.WriteString("\n")

    // Parameters (if stat update selected)
    if m.selectedType == EventStatUpdate {
        b.WriteString("Parameters:\n")
        b.WriteString(fmt.Sprintf("  Stat Code: %s\n", m.statCode))
        b.WriteString(fmt.Sprintf("  Value: %s\n", m.statValue))
        b.WriteString("\n")
    }

    // Trigger button
    if m.sending {
        b.WriteString(spinnerStyle.Render("⠋ Triggering event...") + "\n")
    } else {
        b.WriteString(highlightStyle.Render("[Enter] Trigger Event") + " " +
            dimStyle.Render("[Esc] Back") + "\n")
    }

    b.WriteString("\n" + dividerStyle.Render(strings.Repeat("─", 60)) + "\n\n")

    // Event history
    b.WriteString(titleStyle.Render("Recent Events:") + "\n")
    if len(m.history) == 0 {
        b.WriteString(dimStyle.Render("  No events triggered yet") + "\n")
    } else {
        for _, entry := range m.history {
            b.WriteString(m.renderHistoryEntry(entry))
        }
    }

    if m.errorMsg != "" {
        b.WriteString("\n" + errorStyle.Render("Error: "+m.errorMsg) + "\n")
    }

    return b.String()
}

// renderHistoryEntry renders a single event history entry
func (m *EventSimulatorModel) renderHistoryEntry(entry EventHistoryEntry) string {
    icon := "✓"
    style := successStyle
    if !entry.Success {
        icon = "✗"
        style = errorStyle
    }

    timestamp := entry.Time.Format("15:04:05")
    line := fmt.Sprintf("  %s %s - %s: %s (%dms)",
        icon, timestamp, entry.EventType, entry.Details, entry.Duration.Milliseconds())

    return style.Render(line) + "\n"
}
```

---

## 5. Debug Screen

### 5.1 DebugModel

**Show raw API requests/responses:**

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

// DebugModel represents the debug panel screen
type DebugModel struct {
    apiClient api.APIClient
    scroll    int
}

// NewDebugModel creates a new debug model
func NewDebugModel(apiClient api.APIClient) *DebugModel {
    return &DebugModel{apiClient: apiClient}
}

// Init initializes the debug panel
func (m *DebugModel) Init() tea.Cmd {
    return nil
}

// Update handles messages for the debug panel
func (m *DebugModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "up", "k":
            if m.scroll > 0 {
                m.scroll--
            }
            return m, nil

        case "down", "j":
            m.scroll++
            return m, nil

        case "y":
            // Copy JSON to clipboard
            return m, copyJSONCmd(m.apiClient)

        case "u":
            // Copy curl command
            return m, copyCurlCmd(m.apiClient)
        }
    }

    return m, nil
}

// View renders the debug panel
func (m *DebugModel) View() string {
    var b strings.Builder
    b.WriteString(titleStyle.Render("DEBUG VIEW") + "\n\n")

    req := m.apiClient.GetLastRequest()
    resp := m.apiClient.GetLastResponse()

    if req == nil || resp == nil {
        return b.String() + dimStyle.Render("No requests yet. Trigger an API call from the dashboard.")
    }

    // Request info
    b.WriteString(subtitleStyle.Render("Last Request:") + "\n")
    b.WriteString(fmt.Sprintf("%s %s\n", req.Method, req.URL))
    b.WriteString(fmt.Sprintf("Time: %s\n\n", req.Time.Format("15:04:05")))

    // Response info
    b.WriteString(subtitleStyle.Render("Response:") + "\n")
    statusColor := successStyle
    if resp.StatusCode >= 400 {
        statusColor = errorStyle
    }
    b.WriteString(statusColor.Render(fmt.Sprintf("%d %s", resp.StatusCode, http.StatusText(resp.StatusCode))) + "\n")
    b.WriteString(fmt.Sprintf("Duration: %dms\n\n", resp.Duration.Milliseconds()))

    // Response body (scrollable)
    b.WriteString(subtitleStyle.Render("Body:") + "\n")
    bodyLines := strings.Split(resp.Body, "\n")

    // Apply scroll offset
    startLine := m.scroll
    if startLine >= len(bodyLines) {
        startLine = len(bodyLines) - 1
    }
    if startLine < 0 {
        startLine = 0
    }

    maxLines := 15 // Show 15 lines at a time
    endLine := startLine + maxLines
    if endLine > len(bodyLines) {
        endLine = len(bodyLines)
    }

    for i := startLine; i < endLine; i++ {
        b.WriteString(codeStyle.Render(bodyLines[i]) + "\n")
    }

    // Scroll indicator
    if len(bodyLines) > maxLines {
        b.WriteString(fmt.Sprintf("\n%s (Line %d-%d of %d)",
            dimStyle.Render("Use ↑↓ to scroll"),
            startLine+1, endLine, len(bodyLines)))
    }

    b.WriteString("\n\n")
    b.WriteString(highlightStyle.Render("[y]") + " Copy JSON  " +
        highlightStyle.Render("[u]") + " Copy Curl\n")

    return b.String()
}
```

---

### 5.2 Debug Commands

**Copy to clipboard:**

```go
// copyJSONCmd copies the response JSON to clipboard
func copyJSONCmd(apiClient api.APIClient) tea.Cmd {
    return func() tea.Msg {
        resp := apiClient.GetLastResponse()
        if resp == nil {
            return ErrorMsg{err: errors.New("no response to copy")}
        }

        err := clipboard.WriteAll(resp.Body)
        if err != nil {
            return ErrorMsg{err: fmt.Errorf("copy failed: %w", err)}
        }

        return SuccessMsg{msg: "JSON copied to clipboard"}
    }
}

// copyCurlCmd copies the curl command to clipboard
func copyCurlCmd(apiClient api.APIClient) tea.Cmd {
    return func() tea.Msg {
        req := apiClient.GetLastRequest()
        if req == nil {
            return ErrorMsg{err: errors.New("no request to copy")}
        }

        // Build curl command
        var curlCmd strings.Builder
        curlCmd.WriteString(fmt.Sprintf("curl -X %s '%s'", req.Method, req.URL))

        for key, value := range req.Headers {
            curlCmd.WriteString(fmt.Sprintf(" \\\n  -H '%s: %s'", key, value))
        }

        if req.Body != "" {
            curlCmd.WriteString(fmt.Sprintf(" \\\n  -d '%s'", req.Body))
        }

        err := clipboard.WriteAll(curlCmd.String())
        if err != nil {
            return ErrorMsg{err: fmt.Errorf("copy failed: %w", err)}
        }

        return SuccessMsg{msg: "Curl command copied to clipboard"}
    }
}
```

---

## 6. Styling with Lip Gloss

### 6.1 Style Definitions

**Central style definitions:**

```go
package tui

import "github.com/charmbracelet/lipgloss"

var (
    // Colors
    primaryColor   = lipgloss.Color("39")  // Blue
    successColor   = lipgloss.Color("42")  // Green
    warningColor   = lipgloss.Color("214") // Orange
    errorColor     = lipgloss.Color("196") // Red
    dimColor       = lipgloss.Color("240") // Gray
    highlightColor = lipgloss.Color("226") // Yellow

    // Base styles
    headerStyle = lipgloss.NewStyle().
        Background(primaryColor).
        Foreground(lipgloss.Color("0")).
        Bold(true).
        Padding(0, 1)

    footerStyle = lipgloss.NewStyle().
        Foreground(dimColor).
        Padding(0, 1)

    titleStyle = lipgloss.NewStyle().
        Foreground(primaryColor).
        Bold(true)

    subtitleStyle = lipgloss.NewStyle().
        Foreground(primaryColor)

    selectedStyle = lipgloss.NewStyle().
        Foreground(highlightColor).
        Bold(true)

    dimStyle = lipgloss.NewStyle().
        Foreground(dimColor)

    // Status styles
    progressStyle = lipgloss.NewStyle().
        Foreground(primaryColor)

    completedStyle = lipgloss.NewStyle().
        Foreground(successColor)

    claimedStyle = lipgloss.NewStyle().
        Foreground(highlightColor)

    errorStyle = lipgloss.NewStyle().
        Foreground(errorColor)

    successStyle = lipgloss.NewStyle().
        Foreground(successColor)

    warningStyle = lipgloss.NewStyle().
        Foreground(warningColor)

    highlightStyle = lipgloss.NewStyle().
        Foreground(highlightColor).
        Bold(true)

    // Code/debug styles
    codeStyle = lipgloss.NewStyle().
        Foreground(lipgloss.Color("252"))

    dividerStyle = lipgloss.NewStyle().
        Foreground(dimColor)

    spinnerStyle = lipgloss.NewStyle().
        Foreground(primaryColor)
)
```

---

## 7. Messages and Commands

### 7.1 Global Messages

```go
package tui

import "time"

// TickMsg is sent periodically for background tasks
type TickMsg struct {
    time time.Time
}

// WatchTickMsg is sent periodically in watch mode
type WatchTickMsg struct {
    time time.Time
}

// ErrorMsg is sent when an error occurs
type ErrorMsg struct {
    err error
}

// SuccessMsg is sent when an operation succeeds
type SuccessMsg struct {
    msg string
}
```

---

### 7.2 Global Commands

```go
// tokenRefreshTickCmd returns a command that ticks every minute
func tokenRefreshTickCmd() tea.Cmd {
    return tea.Tick(time.Minute, func(t time.Time) tea.Msg {
        return TickMsg{time: t}
    })
}

// watchModeTickCmd returns a command that ticks every 2 seconds
func watchModeTickCmd() tea.Cmd {
    return tea.Tick(2*time.Second, func(t time.Time) tea.Msg {
        return WatchTickMsg{time: t}
    })
}

// refreshTokenCmd refreshes the auth token
func refreshTokenCmd(authProvider auth.AuthProvider) tea.Cmd {
    return func() tea.Msg {
        ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        token, err := authProvider.GetToken(ctx)
        if err != nil {
            return ErrorMsg{err: fmt.Errorf("token refresh failed: %w", err)}
        }

        newToken, err := authProvider.RefreshToken(ctx, token)
        if err != nil {
            return ErrorMsg{err: fmt.Errorf("token refresh failed: %w", err)}
        }

        return SuccessMsg{msg: "Token refreshed"}
    }
}
```

---

## 8. Keyboard Shortcuts

### 8.1 Global Shortcuts

| Key | Action |
|-----|--------|
| `Ctrl+C` | Quit application (always works, even with focused inputs) |
| `q` | Quit application (disabled when input focused) |
| `1` | Switch to Dashboard (disabled when input focused) |
| `2` or `e` | Switch to Event Simulator (disabled when input focused) |
| `d` | Toggle Debug panel (disabled when input focused) |
| `x` | Open Config editor (disabled when input focused) |
| `w` | Toggle Watch mode (disabled when input focused) |
| `r` | Manual refresh (disabled when input focused) |

**Input Focus Handling:**
- When a text input field is focused (in Event Simulator), all global shortcuts are disabled
- This allows typing any character including 'q', 'e', '1', '2' in stat codes (e.g., "quest_completed", "tutorial_completed")
- **Only `Ctrl+C` works for quitting** when input is focused (safety escape hatch)
- **Arrow keys (←→)** work for cursor movement within the text input
- **`Esc` key** unfocuses the input and returns to navigation mode
- **`Tab` key** cycles through input fields
- **Context-aware UI**: Header and footer show different shortcuts based on focus state
  - **Input focused**: Shows "⚠ Input Mode: Navigation disabled" with unfocus hints
  - **Navigation mode**: Shows normal navigation shortcuts

### 8.2 Dashboard Shortcuts

**List View:**

| Key | Action |
|-----|--------|
| `↑`/`k` | Move cursor up (select previous challenge) |
| `↓`/`j` | Move cursor down (select next challenge) |
| `Enter` | Drill down into selected challenge (show details) |

**Detail View:**

| Key | Action |
|-----|--------|
| `↑`/`k` | Move cursor up (select previous goal) |
| `↓`/`j` | Move cursor down (select next goal) |
| `c` | Claim reward (on selected completed goal) |
| `Esc` | Go back to challenge list |

**Both Views:**

| Key | Action |
|-----|--------|
| `r` | Manual refresh |
| `w` | Toggle watch mode |
| `e` | Open Event Simulator |
| `d` | Toggle Debug panel |

### 8.3 Event Simulator Shortcuts

**Navigation Mode (not focused on input):**

| Key | Action |
|-----|--------|
| `↑`/`k` | Select previous event type |
| `↓`/`j` | Select next event type |
| `Tab` | Focus first input field (stat code for Stat Update) |
| `Enter` | Trigger event |
| `Esc` | Back to Dashboard |

**Note:** Selecting "Stat Update Event" does NOT auto-focus inputs. Press `Tab` explicitly to start typing.

**Input Mode (focused on text field):**

| Key | Action |
|-----|--------|
| `←`/`→` | Move cursor within input field |
| `Tab` | Next field (stat code → value → back to event type) |
| `Esc` | Unfocus input (return to navigation mode) |
| `Enter` | Trigger event (works even when focused) |
| Any letter/number | Type into field (including 'q', 'e', '1', '2') |

### 8.4 Debug Panel Shortcuts

| Key | Action |
|-----|--------|
| `↑`/`k` | Scroll up |
| `↓`/`j` | Scroll down |
| `y` | Copy JSON to clipboard |
| `u` | Copy curl command |
| `Esc` | Back to Dashboard |

---

## 9. Testing

### 9.1 Unit Tests for Models

**Test state transitions:**

```go
func TestDashboardModel_Update_ChallengesLoaded(t *testing.T) {
    mockClient := &MockAPIClient{
        challenges: []api.Challenge{
            {ID: "test", Name: "Test Challenge"},
        },
    }

    model := NewDashboardModel(mockClient)

    // Send challenges loaded message
    msg := ChallengesLoadedMsg{challenges: mockClient.challenges}
    newModel, _ := model.Update(msg)

    dashboard := newModel.(*DashboardModel)
    assert.Len(t, dashboard.challenges, 1)
    assert.Equal(t, "Test Challenge", dashboard.challenges[0].Name)
    assert.Empty(t, dashboard.errorMsg)
}
```

---

### 9.2 View Tests

**Test rendering:**

```go
func TestDashboardModel_View_EmptyChallenges(t *testing.T) {
    model := NewDashboardModel(&MockAPIClient{})

    view := model.View()
    assert.Contains(t, view, "No challenges found")
}

func TestDashboardModel_View_WithChallenges(t *testing.T) {
    mockClient := &MockAPIClient{
        challenges: []api.Challenge{
            {ID: "test", Name: "Test Challenge", Goals: []api.Goal{}},
        },
    }

    model := NewDashboardModel(mockClient)
    model.challenges = mockClient.challenges

    view := model.View()
    assert.Contains(t, view, "Test Challenge")
    assert.Contains(t, view, "0/0 goals")
}
```

---

## 7. Inventory & Wallets Screen (Phase 8)

**Status:** ⏳ Planned

**Purpose:** Display user's item entitlements and wallet balances from AGS Platform to verify claimed rewards.

### 7.1 Screen Layout

```
┌────────────────────────────────────────────────────────────────────────┐
│ Challenge Demo - Inventory & Wallets                          Auth: ✓  │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌─ Item Entitlements ──────────────┐  ┌─ Wallet Balances ─────────┐ │
│  │ [ACTIVE] winter_sword            │  │ GOLD: 150                  │ │
│  │   Quantity: 1                    │  │ Status: ACTIVE             │ │
│  │   Granted: 2025-10-22 10:30      │  │                            │ │
│  │                                  │  │ GEMS: 25                   │ │
│  │ [ACTIVE] bronze_shield           │  │ Status: ACTIVE             │ │
│  │   Quantity: 2                    │  │                            │ │
│  │   Granted: 2025-10-21 15:00      │  │ XP_BOOST: 0                │ │
│  │                                  │  │ Status: INACTIVE           │ │
│  │ [INACTIVE] old_armor             │  │                            │ │
│  │   Quantity: 1                    │  └────────────────────────────┘ │
│  │   Granted: 2025-10-20 12:00      │                                │
│  │                                  │                                │
│  └──────────────────────────────────┘                                │
│                                                                        │
│  Showing 3 entitlements, 3 wallets                                    │
│                                                                        │
├────────────────────────────────────────────────────────────────────────┤
│ Keys: ↑/↓ scroll | r refresh | Esc back to main | q quit             │
└────────────────────────────────────────────────────────────────────────┘
```

### 7.2 InventoryModel Structure

```go
package tui

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/ags"
)

// InventoryModel shows entitlements and wallets
type InventoryModel struct {
    verifier      ags.RewardVerifier
    entitlements  []ags.Entitlement
    wallets       []ags.Wallet
    loading       bool
    err           error

    // UI state
    viewport      viewport.Model
    focusedPanel  string // "entitlements" or "wallets"
}

func NewInventoryModel(verifier ags.RewardVerifier) InventoryModel {
    return InventoryModel{
        verifier:     verifier,
        focusedPanel: "entitlements",
        viewport:     viewport.New(80, 20),
    }
}
```

### 7.3 Messages

```go
// LoadInventoryMsg triggers data loading
type LoadInventoryMsg struct{}

// InventoryLoadedMsg contains loaded data
type InventoryLoadedMsg struct {
    Entitlements []ags.Entitlement
    Wallets      []ags.Wallet
}

// InventoryErrorMsg contains load error
type InventoryErrorMsg struct {
    Err error
}
```

### 7.4 Update Function

```go
func (m InventoryModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "r":
            // Refresh data
            m.loading = true
            return m, m.loadInventoryCmd()

        case "tab":
            // Switch between panels
            if m.focusedPanel == "entitlements" {
                m.focusedPanel = "wallets"
            } else {
                m.focusedPanel = "entitlements"
            }
            return m, nil

        case "up", "down":
            // Scroll viewport
            var cmd tea.Cmd
            m.viewport, cmd = m.viewport.Update(msg)
            return m, cmd

        case "esc":
            // Return to main screen
            return m, func() tea.Msg { return SwitchScreenMsg{Screen: "dashboard"} }
        }

    case LoadInventoryMsg:
        m.loading = true
        return m, m.loadInventoryCmd()

    case InventoryLoadedMsg:
        m.loading = false
        m.entitlements = msg.Entitlements
        m.wallets = msg.Wallets
        m.err = nil
        return m, nil

    case InventoryErrorMsg:
        m.loading = false
        m.err = msg.Err
        return m, nil
    }

    return m, nil
}
```

### 7.5 Load Command

```go
func (m InventoryModel) loadInventoryCmd() tea.Cmd {
    return func() tea.Msg {
        // Query entitlements
        entitlements, err := m.verifier.QueryUserEntitlements(nil)
        if err != nil {
            return InventoryErrorMsg{Err: err}
        }

        // Query wallets
        wallets, err := m.verifier.QueryUserWallets()
        if err != nil {
            return InventoryErrorMsg{Err: err}
        }

        return InventoryLoadedMsg{
            Entitlements: entitlements,
            Wallets:      wallets,
        }
    }
}
```

### 7.6 View Rendering

```go
func (m InventoryModel) View() string {
    if m.loading {
        return lipgloss.NewStyle().
            Margin(10, 0).
            Render("Loading inventory and wallets...")
    }

    if m.err != nil {
        return lipgloss.NewStyle().
            Foreground(lipgloss.Color("9")). // Red
            Margin(2, 0).
            Render(fmt.Sprintf("Error: %v\n\nPress 'r' to retry or 'Esc' to go back", m.err))
    }

    // Render entitlements panel
    entitlementsView := m.renderEntitlements()

    // Render wallets panel
    walletsView := m.renderWallets()

    // Combine panels side-by-side
    content := lipgloss.JoinHorizontal(
        lipgloss.Top,
        entitlementsView,
        walletsView,
    )

    // Wrap in viewport
    m.viewport.SetContent(content)

    // Footer
    footer := fmt.Sprintf(
        "Showing %d entitlements, %d wallets",
        len(m.entitlements),
        len(m.wallets),
    )

    return lipgloss.JoinVertical(
        lipgloss.Left,
        headerStyle.Render("Challenge Demo - Inventory & Wallets"),
        m.viewport.View(),
        footerStyle.Render(footer),
        helpStyle.Render("Keys: ↑/↓ scroll | Tab switch panel | r refresh | Esc back | q quit"),
    )
}
```

### 7.7 Panel Rendering

```go
func (m InventoryModel) renderEntitlements() string {
    if len(m.entitlements) == 0 {
        return panelStyle.Render("No entitlements found")
    }

    var items []string
    for _, ent := range m.entitlements {
        status := "ACTIVE"
        if ent.Status != "ACTIVE" {
            status = "INACTIVE"
        }

        item := fmt.Sprintf(
            "[%s] %s\n  Quantity: %d\n  Granted: %s\n",
            status,
            ent.ItemID,
            ent.Quantity,
            ent.GrantedAt.Format("2006-01-02 15:04"),
        )
        items = append(items, item)
    }

    title := "Item Entitlements"
    if m.focusedPanel == "entitlements" {
        title = "► " + title
    }

    return panelStyle.
        Border(lipgloss.RoundedBorder()).
        BorderForeground(lipgloss.Color("63")).
        Width(40).
        Render(lipgloss.JoinVertical(
            lipgloss.Left,
            titleStyle.Render(title),
            strings.Join(items, "\n"),
        ))
}

func (m InventoryModel) renderWallets() string {
    if len(m.wallets) == 0 {
        return panelStyle.Render("No wallets found")
    }

    var items []string
    for _, wallet := range m.wallets {
        item := fmt.Sprintf(
            "%s: %d\nStatus: %s\n",
            wallet.CurrencyCode,
            wallet.Balance,
            wallet.Status,
        )
        items = append(items, item)
    }

    title := "Wallet Balances"
    if m.focusedPanel == "wallets" {
        title = "► " + title
    }

    return panelStyle.
        Border(lipgloss.RoundedBorder()).
        BorderForeground(lipgloss.Color("63")).
        Width(30).
        Render(lipgloss.JoinVertical(
            lipgloss.Left,
            titleStyle.Render(title),
            strings.Join(items, "\n"),
        ))
}
```

### 7.8 Integration with AppModel

**Add inventory screen to AppModel:**

```go
type AppModel struct {
    // ... existing fields
    inventoryModel InventoryModel
}

func NewAppModel(container *app.Container) AppModel {
    return AppModel{
        // ... existing initialization
        inventoryModel: NewInventoryModel(container.RewardVerifier),
    }
}

func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "i":
            // Switch to inventory screen
            m.currentScreen = "inventory"
            return m, func() tea.Msg { return LoadInventoryMsg{} }
        }
    }

    // ... existing update logic

    if m.currentScreen == "inventory" {
        newModel, cmd := m.inventoryModel.Update(msg)
        m.inventoryModel = newModel.(InventoryModel)
        return m, cmd
    }

    return m, nil
}

func (m AppModel) View() string {
    if m.currentScreen == "inventory" {
        return m.inventoryModel.View()
    }

    // ... existing view logic
}
```

### 7.9 Testing Inventory Screen

```go
func TestInventoryModel_LoadSuccess(t *testing.T) {
    mockVerifier := &MockRewardVerifier{
        entitlements: []ags.Entitlement{
            {ItemID: "sword", Status: "ACTIVE", Quantity: 1},
        },
        wallets: []ags.Wallet{
            {CurrencyCode: "GOLD", Balance: 100, Status: "ACTIVE"},
        },
    }

    model := NewInventoryModel(mockVerifier)

    // Trigger load
    _, cmd := model.Update(LoadInventoryMsg{})
    msg := cmd()

    // Verify loaded message
    loadedMsg, ok := msg.(InventoryLoadedMsg)
    assert.True(t, ok)
    assert.Len(t, loadedMsg.Entitlements, 1)
    assert.Len(t, loadedMsg.Wallets, 1)

    // Update model with loaded data
    model, _ = model.Update(loadedMsg)

    // Verify view
    view := model.View()
    assert.Contains(t, view, "sword")
    assert.Contains(t, view, "GOLD: 100")
}

func TestInventoryModel_LoadError(t *testing.T) {
    mockVerifier := &MockRewardVerifier{
        err: errors.New("AGS unavailable"),
    }

    model := NewInventoryModel(mockVerifier)

    // Trigger load
    _, cmd := model.Update(LoadInventoryMsg{})
    msg := cmd()

    // Verify error message
    errMsg, ok := msg.(InventoryErrorMsg)
    assert.True(t, ok)
    assert.Contains(t, errMsg.Err.Error(), "AGS unavailable")

    // Update model with error
    model, _ = model.Update(errMsg)

    // Verify error view
    view := model.View()
    assert.Contains(t, view, "Error: AGS unavailable")
    assert.Contains(t, view, "Press 'r' to retry")
}
```

### 7.10 Requirements

**For this screen to work:**
- AGS credentials configured (`AB_CLIENT_ID`, `AB_CLIENT_SECRET`)
- User authenticated with password or client mode
- RewardVerifier interface implemented in `internal/ags/`
- Platform SDK EntitlementService and WalletService initialized

**Benefits:**
- ✅ Verify rewards were actually granted in AGS
- ✅ Debug reward grant issues
- ✅ Show inventory changes in real-time
- ✅ Complete the demo experience (claim → grant → verify)

---

## 10. Summary

**Key TUI Components:**

1. **AppModel:** Root model with screen routing
2. **DashboardModel:** Main screen with challenges/goals
3. **EventSimulatorModel:** Event triggering panel
4. **DebugModel:** Raw API inspector
5. **Styling:** Centralized Lip Gloss styles

**Bubble Tea Patterns:**
- ✅ Nested models for modularity
- ✅ Commands for async operations
- ✅ Custom messages for state transitions
- ✅ Keyboard shortcuts for navigation
- ✅ Lip Gloss for consistent styling

**Next Steps:**
1. Review this spec
2. Implement Phase 1 (Dashboard + API integration)
3. Test with mock API client
4. Add remaining screens (Event Simulator, Debug)

---

**Document Version:** 1.0
**Last Updated:** 2025-10-20
**Status:** ✅ Ready for Review
