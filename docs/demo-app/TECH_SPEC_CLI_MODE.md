# Challenge Demo App - Non-Interactive CLI Mode Technical Specification

## Document Purpose

This technical specification defines the **non-interactive CLI mode** for the Challenge Demo App, enabling command-line operations without the TUI for automation, scripting, and CI/CD integration.

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - Core interfaces and architecture
- [TECH_SPEC_API_CLIENT.md](./TECH_SPEC_API_CLIENT.md) - API client used by CLI commands
- [DESIGN.md](./DESIGN.md) - Overall design philosophy

---

## 1. Overview

### 1.1 Purpose

The non-interactive CLI mode provides **command-line interface** for Challenge Service operations without launching the TUI, enabling:

- **Automation**: Script user journeys and test scenarios
- **CI/CD Integration**: Run automated tests in pipelines
- **Quick Operations**: Execute single commands without TUI overhead
- **Tooling Integration**: Pipe output to `jq`, `grep`, etc.
- **Documentation**: Show exact commands in examples

### 1.2 Design Principles

1. **Progressive Disclosure**: Interactive TUI is default, CLI mode is opt-in
2. **Unix Philosophy**: Do one thing well, composable commands
3. **Machine-Readable Output**: JSON by default for scripting
4. **Human-Readable Option**: Table/text format for direct use
5. **Exit Codes**: Follow conventions (0 = success, 1 = error, 2 = usage error)
6. **Consistent Flags**: Reuse auth/connection flags across commands

### 1.3 Command Structure

```bash
# Command pattern
challenge-demo [global-flags] <command> [command-flags] [args]

# Examples
challenge-demo list-challenges --format=json
challenge-demo trigger-event login --user-id=alice
challenge-demo claim-reward daily login-3
challenge-demo watch --interval=5s
```

---

## 2. Command Reference

### 2.1 Command Hierarchy

```
challenge-demo
├── list-challenges      # List all challenges with progress
├── get-challenge       # Get specific challenge details
├── trigger-event       # Trigger gameplay events
│   ├── login          # Trigger login event
│   └── stat-update    # Trigger stat update event
├── claim-reward        # Claim reward for completed goal
├── watch              # Continuous challenge monitoring
├── verify-entitlement  # Verify item entitlement (Phase 8)
├── verify-wallet       # Verify wallet balance (Phase 8)
├── list-inventory      # List all entitlements (Phase 8)
├── list-wallets        # List all wallets (Phase 8)
└── tui                # Launch interactive TUI (default if no command)
```

### 2.2 Global Flags

**Available on all commands:**

```bash
# API Configuration
--backend-url string         Challenge service backend URL
                             (default: http://localhost:8000/challenge)
--iam-url string            AGS IAM URL
                             (default: https://demo.accelbyte.io/iam)
--namespace string          AccelByte namespace
                             (default: accelbyte)

# Primary Authentication (for Challenge Service)
--auth-mode string          Authentication mode (mock|password|client)
                             (default: mock)
--user-id string            User ID for mock mode
                             (default: test-user-123)
--email string              User email (for password mode)
--password string           User password (for password mode)
--client-id string          OAuth2 client ID (for password/client mode)
--client-secret string      OAuth2 client secret (for password/client mode)

# Admin Authentication (optional - for verification)
--admin-client-id string    Admin OAuth2 client ID
--admin-client-secret string Admin OAuth2 client secret

# Event Triggering
--event-handler-url string  Event handler gRPC address
                             (default: localhost:6566)

# Output
--format string             Output format (json|table|text)
                             (default: json)
--quiet                     Suppress informational output
--debug                     Enable debug logging
```

**Dual Token Usage:**
```bash
# Single Token: User only (Challenge Service operations)
challenge-demo list-challenges --auth-mode=password --email=user@example.com --password=pass123

# Dual Token: User + Admin (Challenge Service + Verification)
challenge-demo list-challenges \
  --auth-mode=password --email=user@example.com --password=pass123 \
  --admin-client-id=admin-xxx --admin-client-secret=admin-yyy
```

---

## 3. Commands Implementation

### 3.1 list-challenges

**Purpose:** List all challenges with user's progress.

**Signature:**
```bash
challenge-demo list-challenges [flags]
```

**Flags:**
```bash
--format string    Output format (json|table|text) (default: json)
--show-goals       Include goal details in output
```

**JSON Output:**
```json
{
  "challenges": [
    {
      "id": "daily-missions",
      "name": "Daily Missions",
      "description": "Complete daily tasks",
      "goals": [
        {
          "id": "login-3",
          "name": "Login 3 times",
          "description": "Login on 3 different days",
          "progress": 2,
          "target": 3,
          "status": "in_progress",
          "reward": {
            "type": "ITEM",
            "item_id": "gold-100",
            "quantity": 1
          }
        }
      ]
    }
  ],
  "total": 3
}
```

**Table Output:**
```
ID               NAME             PROGRESS  STATUS
daily-missions   Daily Missions   2/5       in_progress
weekly-quest     Weekly Quest     0/3       not_started
season-pass      Season Pass      1/10      in_progress
```

**Exit Codes:**
- `0`: Success
- `1`: API error or authentication failure
- `2`: Invalid flags

**Examples:**
```bash
# JSON output (default)
challenge-demo list-challenges

# Human-readable table
challenge-demo list-challenges --format=table

# Include goal details
challenge-demo list-challenges --show-goals

# Use with jq
challenge-demo list-challenges | jq '.challenges[].name'

# Count in_progress challenges
challenge-demo list-challenges | jq '[.challenges[] | select(.status=="in_progress")] | length'
```

---

### 3.2 get-challenge

**Purpose:** Get details for a specific challenge.

**Signature:**
```bash
challenge-demo get-challenge <challenge-id> [flags]
```

**Flags:**
```bash
--format string    Output format (json|table|text) (default: json)
```

**JSON Output:**
```json
{
  "id": "daily-missions",
  "name": "Daily Missions",
  "description": "Complete daily tasks",
  "goals": [
    {
      "id": "login-3",
      "name": "Login 3 times",
      "description": "Login on 3 different days",
      "progress": 2,
      "target": 3,
      "status": "in_progress",
      "reward": {
        "type": "ITEM",
        "item_id": "gold-100",
        "quantity": 1
      }
    }
  ]
}
```

**Text Output:**
```
Challenge: Daily Missions
ID: daily-missions
Description: Complete daily tasks

Goals:
  [IN_PROGRESS] Login 3 times (2/3)
    Reward: ITEM gold-100 x1

  [NOT_STARTED] Win 5 matches (0/5)
    Reward: ITEM gem-50 x1
```

**Exit Codes:**
- `0`: Success
- `1`: Challenge not found or API error
- `2`: Invalid challenge ID format

**Examples:**
```bash
# Get challenge details
challenge-demo get-challenge daily-missions

# Human-readable output
challenge-demo get-challenge daily-missions --format=text

# Check if challenge exists
challenge-demo get-challenge daily-missions --quiet && echo "exists"

# Get specific goal's progress
challenge-demo get-challenge daily-missions | jq '.goals[] | select(.id=="login-3") | .progress'
```

---

### 3.3 trigger-event

**Purpose:** Trigger gameplay events for testing.

**Signature:**
```bash
challenge-demo trigger-event <event-type> [flags]
```

**Event Types:**
- `login`: Trigger user login event
- `stat-update`: Trigger statistic update event

#### 3.3.1 trigger-event login

**Flags:**
```bash
--user-id string    User ID to trigger event for (overrides global --user-id)
```

**JSON Output:**
```json
{
  "event": "login",
  "user_id": "alice",
  "timestamp": "2025-10-21T10:30:00Z",
  "status": "success",
  "duration_ms": 45
}
```

**Exit Codes:**
- `0`: Event triggered successfully
- `1`: Event handler connection error
- `2`: Invalid user ID

**Examples:**
```bash
# Trigger login event for current user
challenge-demo trigger-event login

# Trigger login for specific user
challenge-demo trigger-event login --user-id=alice

# Trigger multiple logins in script
for i in {1..3}; do
  challenge-demo trigger-event login --quiet
  sleep 1
done
```

#### 3.3.2 trigger-event stat-update

**Flags:**
```bash
--user-id string      User ID to trigger event for
--stat-code string    Statistic code (required)
--value int           New statistic value (required)
```

**JSON Output:**
```json
{
  "event": "stat-update",
  "user_id": "alice",
  "stat_code": "matches-won",
  "value": 10,
  "timestamp": "2025-10-21T10:30:00Z",
  "status": "success",
  "duration_ms": 52
}
```

**Exit Codes:**
- `0`: Event triggered successfully
- `1`: Event handler connection error
- `2`: Missing required flags (stat-code or value)

**Examples:**
```bash
# Update stat
challenge-demo trigger-event stat-update --stat-code=matches-won --value=10

# Increment stat in script
current=$(challenge-demo get-challenge daily | jq '.goals[0].progress')
new=$((current + 1))
challenge-demo trigger-event stat-update --stat-code=matches-won --value=$new
```

---

### 3.4 claim-reward

**Purpose:** Claim reward for a completed goal.

**Signature:**
```bash
challenge-demo claim-reward <challenge-id> <goal-id> [flags]
```

**Flags:**
```bash
--format string    Output format (json|text) (default: json)
```

**JSON Output:**
```json
{
  "challenge_id": "daily-missions",
  "goal_id": "login-3",
  "status": "success",
  "reward": {
    "type": "ITEM",
    "item_id": "gold-100",
    "quantity": 1
  },
  "timestamp": "2025-10-21T10:30:00Z"
}
```

**Error Output:**
```json
{
  "challenge_id": "daily-missions",
  "goal_id": "login-3",
  "status": "error",
  "error": "goal not completed",
  "error_code": "GOAL_NOT_COMPLETED"
}
```

**Exit Codes:**
- `0`: Reward claimed successfully
- `1`: Goal not completed, already claimed, or API error
- `2`: Invalid challenge/goal ID

**Examples:**
```bash
# Claim reward
challenge-demo claim-reward daily-missions login-3

# Human-readable output
challenge-demo claim-reward daily-missions login-3 --format=text

# Claim all completed goals (script)
challenge-demo list-challenges --show-goals | \
  jq -r '.challenges[].goals[] | select(.status=="completed") | "\(.challenge_id) \(.goal_id)"' | \
  while read cid gid; do
    challenge-demo claim-reward "$cid" "$gid"
  done
```

---

### 3.5 watch

**Purpose:** Continuously monitor challenges and output updates.

**Signature:**
```bash
challenge-demo watch [flags]
```

**Flags:**
```bash
--interval duration    Refresh interval (default: 5s)
--format string        Output format (json|text) (default: text)
--challenge string     Watch specific challenge only
--once                 Print once and exit (no continuous watching)
```

**Text Output (Default):**
```
[2025-10-21 10:30:00] Watching challenges (interval: 5s)

Daily Missions       2/5 goals   in_progress
  Login 3 times      2/3         in_progress
  Win 5 matches      0/5         not_started

Weekly Quest         0/3 goals   not_started
  ...

[2025-10-21 10:30:05] Refreshing...

Daily Missions       3/5 goals   in_progress  [CHANGED]
  Login 3 times      3/3         completed    [COMPLETED]
  Win 5 matches      0/5         not_started
```

**JSON Output (--format=json):**
```json
{
  "timestamp": "2025-10-21T10:30:00Z",
  "challenges": [...],
  "changes": [
    {
      "challenge_id": "daily-missions",
      "goal_id": "login-3",
      "old_progress": 2,
      "new_progress": 3,
      "old_status": "in_progress",
      "new_status": "completed"
    }
  ]
}
```

**Exit Codes:**
- `0`: Normal exit (user pressed Ctrl+C)
- `1`: API error or authentication failure

**Examples:**
```bash
# Watch all challenges
challenge-demo watch

# Watch with 2-second interval
challenge-demo watch --interval=2s

# Watch specific challenge
challenge-demo watch --challenge=daily-missions

# Print once and exit
challenge-demo watch --once

# JSON output for logging
challenge-demo watch --format=json >> challenge-log.jsonl
```

---

### 3.6 tui (Default Command)

**Purpose:** Launch interactive TUI (existing functionality).

**Signature:**
```bash
challenge-demo tui [flags]
challenge-demo            # Same as 'tui' (default)
```

**This is the existing interactive mode - no changes needed.**

---

## 4. Implementation Architecture

### 4.1 Package Structure

```
extend-challenge-demo-app/
├── cmd/challenge-demo/
│   └── main.go                    # Root command + subcommands
├── internal/
│   ├── cli/                       # NEW: CLI mode implementation
│   │   ├── commands/
│   │   │   ├── list.go           # list-challenges command
│   │   │   ├── get.go            # get-challenge command
│   │   │   ├── trigger.go        # trigger-event command
│   │   │   ├── claim.go          # claim-reward command
│   │   │   └── watch.go          # watch command
│   │   ├── output/
│   │   │   ├── formatter.go      # Output formatting interface
│   │   │   ├── json.go           # JSON formatter
│   │   │   ├── table.go          # Table formatter
│   │   │   └── text.go           # Text formatter
│   │   └── runner.go              # Command execution helpers
│   ├── app/                       # Existing: Container
│   ├── api/                       # Existing: API client (reused)
│   ├── auth/                      # Existing: Auth providers (reused)
│   ├── events/                    # Existing: Event triggers (reused)
│   └── tui/                       # Existing: Interactive TUI
```

### 4.2 Cobra Integration

**Use Cobra for command structure:**

```go
package main

import (
    "github.com/spf13/cobra"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/cli/commands"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/tui"
)

func main() {
    rootCmd := &cobra.Command{
        Use:   "challenge-demo",
        Short: "Challenge Service Demo CLI",
        Long:  `Interactive TUI and CLI tool for testing AccelByte Challenge Service`,
        // If no subcommand, launch TUI (default behavior)
        Run: func(cmd *cobra.Command, args []string) {
            // Launch TUI (existing code)
            app := tui.NewApp(container)
            app.Run()
        },
    }

    // Global flags (available to all commands)
    rootCmd.PersistentFlags().StringVar(&backendURL, "backend-url", "http://localhost:8000/challenge", "Backend URL")
    rootCmd.PersistentFlags().StringVar(&authMode, "auth-mode", "mock", "Auth mode")
    rootCmd.PersistentFlags().StringVar(&userID, "user-id", "test-user-123", "User ID")
    rootCmd.PersistentFlags().StringVar(&namespace, "namespace", "accelbyte", "Namespace")
    rootCmd.PersistentFlags().StringVar(&format, "format", "json", "Output format")
    // ... other global flags

    // Subcommands
    rootCmd.AddCommand(commands.NewListCommand())
    rootCmd.AddCommand(commands.NewGetCommand())
    rootCmd.AddCommand(commands.NewTriggerCommand())
    rootCmd.AddCommand(commands.NewClaimCommand())
    rootCmd.AddCommand(commands.NewWatchCommand())
    rootCmd.AddCommand(commands.NewTUICommand())  // Explicit TUI command

    if err := rootCmd.Execute(); err != nil {
        os.Exit(1)
    }
}
```

---

## 5. Output Formatting

### 5.1 Formatter Interface

```go
package output

import (
    "io"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

// Formatter formats API responses for CLI output
type Formatter interface {
    // FormatChallenges formats a list of challenges
    FormatChallenges(challenges []api.Challenge) (string, error)

    // FormatChallenge formats a single challenge
    FormatChallenge(challenge *api.Challenge) (string, error)

    // FormatEventResult formats an event trigger result
    FormatEventResult(result *EventResult) (string, error)

    // FormatClaimResult formats a claim reward result
    FormatClaimResult(result *ClaimResult) (string, error)
}

// NewFormatter creates a formatter for the given format type
func NewFormatter(format string) Formatter {
    switch format {
    case "json":
        return &JSONFormatter{}
    case "table":
        return &TableFormatter{}
    case "text":
        return &TextFormatter{}
    default:
        return &JSONFormatter{}
    }
}
```

### 5.2 JSON Formatter

```go
package output

import (
    "encoding/json"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

type JSONFormatter struct{}

func (f *JSONFormatter) FormatChallenges(challenges []api.Challenge) (string, error) {
    output := map[string]interface{}{
        "challenges": challenges,
        "total":      len(challenges),
    }

    data, err := json.MarshalIndent(output, "", "  ")
    if err != nil {
        return "", err
    }

    return string(data), nil
}

func (f *JSONFormatter) FormatChallenge(challenge *api.Challenge) (string, error) {
    data, err := json.MarshalIndent(challenge, "", "  ")
    if err != nil {
        return "", err
    }

    return string(data), nil
}
```

### 5.3 Table Formatter

```go
package output

import (
    "fmt"
    "strings"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

type TableFormatter struct{}

func (f *TableFormatter) FormatChallenges(challenges []api.Challenge) (string, error) {
    var b strings.Builder

    // Header
    b.WriteString(fmt.Sprintf("%-20s %-30s %-15s %-15s\n", "ID", "NAME", "PROGRESS", "STATUS"))
    b.WriteString(strings.Repeat("-", 80) + "\n")

    // Rows
    for _, c := range challenges {
        completed := 0
        for _, g := range c.Goals {
            if g.Status == "completed" || g.Status == "claimed" {
                completed++
            }
        }

        progress := fmt.Sprintf("%d/%d", completed, len(c.Goals))
        b.WriteString(fmt.Sprintf("%-20s %-30s %-15s %-15s\n",
            c.ID, truncate(c.Name, 30), progress, c.Status))
    }

    return b.String(), nil
}

func truncate(s string, maxLen int) string {
    if len(s) <= maxLen {
        return s
    }
    return s[:maxLen-3] + "..."
}
```

### 5.4 Text Formatter

```go
package output

import (
    "fmt"
    "strings"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/api"
)

type TextFormatter struct{}

func (f *TextFormatter) FormatChallenge(challenge *api.Challenge) (string, error) {
    var b strings.Builder

    b.WriteString(fmt.Sprintf("Challenge: %s\n", challenge.Name))
    b.WriteString(fmt.Sprintf("ID: %s\n", challenge.ID))
    b.WriteString(fmt.Sprintf("Description: %s\n\n", challenge.Description))

    b.WriteString("Goals:\n")
    for _, g := range challenge.Goals {
        status := strings.ToUpper(g.Status)
        progress := fmt.Sprintf("(%d/%d)", g.Progress, g.Target)

        b.WriteString(fmt.Sprintf("  [%s] %s %s\n", status, g.Name, progress))

        if g.Reward != nil {
            b.WriteString(fmt.Sprintf("    Reward: %s %s", g.Reward.Type, g.Reward.ItemID))
            if g.Reward.Quantity > 1 {
                b.WriteString(fmt.Sprintf(" x%d", g.Reward.Quantity))
            }
            b.WriteString("\n")
        }
        b.WriteString("\n")
    }

    return b.String(), nil
}
```

---

## 6. Command Implementations

### 6.1 List Command

```go
package commands

import (
    "context"
    "fmt"
    "os"

    "github.com/spf13/cobra"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/app"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/cli/output"
)

func NewListCommand() *cobra.Command {
    var showGoals bool

    cmd := &cobra.Command{
        Use:   "list-challenges",
        Short: "List all challenges with progress",
        Long:  `List all challenges available to the user with their current progress.`,
        RunE: func(cmd *cobra.Command, args []string) error {
            // Get global flags from root command
            format, _ := cmd.Flags().GetString("format")

            // Create container (reuse existing app.NewContainer)
            container := getContainerFromFlags(cmd)

            // Call API
            ctx := context.Background()
            challenges, err := container.APIClient.ListChallenges(ctx)
            if err != nil {
                return fmt.Errorf("failed to list challenges: %w", err)
            }

            // Format output
            formatter := output.NewFormatter(format)
            result, err := formatter.FormatChallenges(challenges)
            if err != nil {
                return fmt.Errorf("failed to format output: %w", err)
            }

            fmt.Println(result)
            return nil
        },
    }

    cmd.Flags().BoolVar(&showGoals, "show-goals", false, "Include goal details")

    return cmd
}

// Helper to create Container from Cobra flags
func getContainerFromFlags(cmd *cobra.Command) *app.Container {
    backendURL, _ := cmd.Flags().GetString("backend-url")
    authMode, _ := cmd.Flags().GetString("auth-mode")
    userID, _ := cmd.Flags().GetString("user-id")
    namespace, _ := cmd.Flags().GetString("namespace")
    // ... get all other flags

    return app.NewContainer(
        backendURL,
        authMode,
        "", // eventHandlerURL not needed for list
        userID,
        namespace,
        "", "", "", "", "", // auth params
    )
}
```

### 6.2 Trigger Event Command

```go
package commands

import (
    "context"
    "fmt"
    "time"

    "github.com/spf13/cobra"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/cli/output"
)

func NewTriggerCommand() *cobra.Command {
    cmd := &cobra.Command{
        Use:   "trigger-event",
        Short: "Trigger gameplay events",
        Long:  `Trigger gameplay events for testing (login, stat updates).`,
    }

    // Subcommands
    cmd.AddCommand(newTriggerLoginCommand())
    cmd.AddCommand(newTriggerStatUpdateCommand())

    return cmd
}

func newTriggerLoginCommand() *cobra.Command {
    var userID string

    cmd := &cobra.Command{
        Use:   "login",
        Short: "Trigger user login event",
        RunE: func(cmd *cobra.Command, args []string) error {
            container := getContainerFromFlags(cmd)

            // Use flag user-id or fall back to global user-id
            if userID == "" {
                userID, _ = cmd.Flags().GetString("user-id")
            }

            ctx := context.Background()
            start := time.Now()

            err := container.EventTrigger.TriggerLogin(ctx, userID)
            duration := time.Since(start)

            // Format output
            format, _ := cmd.Flags().GetString("format")
            formatter := output.NewFormatter(format)

            result := &output.EventResult{
                Event:      "login",
                UserID:     userID,
                Timestamp:  time.Now(),
                Status:     "success",
                DurationMs: duration.Milliseconds(),
                Error:      err,
            }

            if err != nil {
                result.Status = "error"
            }

            output, _ := formatter.FormatEventResult(result)
            fmt.Println(output)

            if err != nil {
                return err
            }

            return nil
        },
    }

    cmd.Flags().StringVar(&userID, "user-id", "", "User ID to trigger event for")

    return cmd
}
```

### 6.3 Watch Command

```go
package commands

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/spf13/cobra"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/cli/output"
)

func NewWatchCommand() *cobra.Command {
    var interval time.Duration
    var challengeID string
    var once bool

    cmd := &cobra.Command{
        Use:   "watch",
        Short: "Continuously monitor challenges",
        Long:  `Watch challenges and output updates at regular intervals.`,
        RunE: func(cmd *cobra.Command, args []string) error {
            container := getContainerFromFlags(cmd)
            format, _ := cmd.Flags().GetString("format")
            formatter := output.NewFormatter(format)

            ctx := context.Background()

            // Setup signal handling for Ctrl+C
            sigChan := make(chan os.Signal, 1)
            signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

            ticker := time.NewTicker(interval)
            defer ticker.Stop()

            var prevChallenges []api.Challenge

            // Helper to fetch and print
            fetchAndPrint := func() error {
                challenges, err := container.APIClient.ListChallenges(ctx)
                if err != nil {
                    return err
                }

                // Filter if specific challenge requested
                if challengeID != "" {
                    filtered := []api.Challenge{}
                    for _, c := range challenges {
                        if c.ID == challengeID {
                            filtered = append(filtered, c)
                        }
                    }
                    challenges = filtered
                }

                // Detect changes
                changes := detectChanges(prevChallenges, challenges)

                // Format and print
                result, err := formatter.FormatChallenges(challenges)
                if err != nil {
                    return err
                }

                fmt.Printf("[%s] ", time.Now().Format("2006-01-02 15:04:05"))
                if len(changes) > 0 {
                    fmt.Printf("%d change(s) detected\n", len(changes))
                } else {
                    fmt.Println("No changes")
                }
                fmt.Println(result)

                prevChallenges = challenges
                return nil
            }

            // Initial fetch
            if err := fetchAndPrint(); err != nil {
                return err
            }

            // If --once, exit
            if once {
                return nil
            }

            // Continuous watching
            for {
                select {
                case <-ticker.C:
                    if err := fetchAndPrint(); err != nil {
                        fmt.Fprintf(os.Stderr, "Error: %v\n", err)
                    }

                case <-sigChan:
                    fmt.Println("\nStopping watch...")
                    return nil
                }
            }
        },
    }

    cmd.Flags().DurationVar(&interval, "interval", 5*time.Second, "Refresh interval")
    cmd.Flags().StringVar(&challengeID, "challenge", "", "Watch specific challenge only")
    cmd.Flags().BoolVar(&once, "once", false, "Print once and exit")

    return cmd
}
```

---

## 7. Testing Strategy

### 7.1 Unit Tests

**Test each command in isolation:**

```go
func TestListCommand(t *testing.T) {
    // Create mock API client
    mockClient := &MockAPIClient{
        challenges: []api.Challenge{
            {ID: "daily", Name: "Daily Missions"},
        },
    }

    // Create command with mock container
    cmd := NewListCommand()
    cmd.SetArgs([]string{"--format=json"})

    // Capture output
    buf := new(bytes.Buffer)
    cmd.SetOut(buf)

    // Execute
    err := cmd.Execute()
    require.NoError(t, err)

    // Verify output
    var result map[string]interface{}
    err = json.Unmarshal(buf.Bytes(), &result)
    require.NoError(t, err)

    assert.Equal(t, 1, result["total"])
}
```

### 7.2 Integration Tests

**Test with real backend (optional):**

```go
func TestListCommand_Integration(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }

    // Run actual command
    cmd := exec.Command("./challenge-demo", "list-challenges", "--format=json")
    output, err := cmd.CombinedOutput()
    require.NoError(t, err)

    // Verify JSON is valid
    var result map[string]interface{}
    err = json.Unmarshal(output, &result)
    require.NoError(t, err)
}
```

### 7.3 Output Format Tests

```go
func TestJSONFormatter(t *testing.T) {
    formatter := &JSONFormatter{}

    challenges := []api.Challenge{
        {ID: "daily", Name: "Daily Missions"},
    }

    output, err := formatter.FormatChallenges(challenges)
    require.NoError(t, err)

    var result map[string]interface{}
    err = json.Unmarshal([]byte(output), &result)
    require.NoError(t, err)

    assert.Equal(t, 1, result["total"])
}
```

---

## 8. Usage Examples

### 8.1 Automation Scripts

**Test user journey:**

```bash
#!/bin/bash
# test-user-journey.sh

USER_ID="test-user-123"
CHALLENGE_ID="daily-missions"

echo "=== Testing Challenge Service ==="

# 1. List initial state
echo "Initial challenges:"
challenge-demo list-challenges --format=table

# 2. Trigger login events
echo "Triggering 3 login events..."
for i in {1..3}; do
    challenge-demo trigger-event login --user-id=$USER_ID
    sleep 1
done

# 3. Check progress
echo "Checking progress after logins..."
challenge-demo get-challenge $CHALLENGE_ID --format=text

# 4. Claim completed goals
echo "Claiming completed goals..."
challenge-demo list-challenges --show-goals | \
    jq -r '.challenges[].goals[] | select(.status=="completed") | "\(.challenge_id) \(.goal_id)"' | \
    while read cid gid; do
        echo "Claiming $cid / $gid"
        challenge-demo claim-reward "$cid" "$gid"
    done

# 5. Verify final state
echo "Final state:"
challenge-demo list-challenges --format=table
```

### 8.2 CI/CD Pipeline

```yaml
# .github/workflows/e2e-test.yml
name: E2E Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:15
        # ... postgres config

      challenge-service:
        image: challenge-service:latest
        # ... service config

    steps:
      - uses: actions/checkout@v3

      - name: Install demo app
        run: |
          cd extend-challenge-demo-app
          go build -o challenge-demo ./cmd/challenge-demo

      - name: Run E2E tests
        run: |
          # Test list
          ./challenge-demo list-challenges --format=json

          # Test trigger events
          ./challenge-demo trigger-event login --user-id=test-user

          # Verify progress updated
          PROGRESS=$(./challenge-demo get-challenge daily-missions | jq '.goals[0].progress')
          test "$PROGRESS" -eq 1

          # Test claim (when goal completed)
          # ...
```

### 8.3 Monitoring Script

```bash
#!/bin/bash
# monitor-challenges.sh - Log challenge updates

LOG_FILE="challenge-updates.jsonl"

echo "Monitoring challenges (logging to $LOG_FILE)"

challenge-demo watch --format=json --interval=10s | \
    jq -c '. + {timestamp: now | todate}' >> $LOG_FILE
```

---

## 9. Error Handling

### 9.1 Exit Codes

**Standard exit codes:**

```go
const (
    ExitSuccess       = 0  // Command succeeded
    ExitError         = 1  // General error (API, auth, network)
    ExitUsageError    = 2  // Invalid flags or arguments
    ExitNotFound      = 3  // Resource not found (optional)
    ExitUnauthorized  = 4  // Authentication failed (optional)
)
```

### 9.2 Error Messages

**User-friendly error output:**

```go
func handleError(err error) {
    if err == nil {
        return
    }

    // Check error type
    var apiErr *api.APIError
    if errors.As(err, &apiErr) {
        fmt.Fprintf(os.Stderr, "Error: API request failed (%d): %s\n",
            apiErr.StatusCode, apiErr.Message)

        if apiErr.StatusCode == 401 {
            fmt.Fprintln(os.Stderr, "Hint: Check your authentication settings (--auth-mode, --email, --password)")
            os.Exit(ExitUnauthorized)
        }

        os.Exit(ExitError)
    }

    // Generic error
    fmt.Fprintf(os.Stderr, "Error: %v\n", err)
    os.Exit(ExitError)
}
```

---

## 10. Documentation

### 10.1 Help Text

**Cobra auto-generates help:**

```bash
$ challenge-demo --help
Challenge Service Demo CLI

Interactive TUI and CLI tool for testing AccelByte Challenge Service.

Usage:
  challenge-demo [command]

Available Commands:
  list-challenges   List all challenges with progress
  get-challenge     Get specific challenge details
  trigger-event     Trigger gameplay events
  claim-reward      Claim reward for completed goal
  watch             Continuously monitor challenges
  tui               Launch interactive TUI (default)
  help              Help about any command

Global Flags:
      --backend-url string         Backend URL (default: http://localhost:8000/challenge)
      --auth-mode string           Auth mode (mock|password|client) (default: mock)
      --format string              Output format (json|table|text) (default: json)
      --user-id string             User ID (default: test-user-123)
      --namespace string           Namespace (default: accelbyte)
  -h, --help                       Help for challenge-demo

Use "challenge-demo [command] --help" for more information about a command.
```

### 10.2 README Updates

**Add CLI mode section to README.md:**

```markdown
## CLI Mode (Non-Interactive)

For automation and scripting, use CLI mode commands:

### List challenges
```bash
challenge-demo list-challenges --format=json
challenge-demo list-challenges --format=table
```

### Trigger events
```bash
challenge-demo trigger-event login
challenge-demo trigger-event stat-update --stat-code=matches-won --value=10
```

### Claim rewards
```bash
challenge-demo claim-reward daily-missions login-3
```

### Watch for changes
```bash
challenge-demo watch --interval=5s
```

See [CLI Mode Documentation](docs/CLI_MODE.md) for complete reference.
```

---

## 11. Reward Verification Commands

**Status:** ⏳ Planned (Phase 8)

**Purpose:** Verify that claimed rewards are actually granted in AGS Platform by querying entitlements and wallet balances using admin token.

**Authentication:** These commands require admin authentication. Enable dual token mode with:
```bash
--admin-client-id=<admin-client-id> --admin-client-secret=<admin-secret>
```

**Why Admin Token?**
- AGS Platform Admin APIs require service credentials with admin permissions
- User tokens have limited access to their own data only
- Admin tokens can query any user's entitlements and wallets for verification

### 11.1 verify-entitlement

**Purpose:** Check if a specific item entitlement exists for the user.

**Usage:**
```bash
challenge-demo verify-entitlement --item-id=<item-id>
```

**Example:**
```bash
# Check for winter sword entitlement
challenge-demo verify-entitlement --item-id=winter_sword

# JSON output
{
  "item_id": "winter_sword",
  "entitlement_id": "ent-abc123",
  "status": "ACTIVE",
  "quantity": 1,
  "granted_at": "2025-10-22T10:30:00Z",
  "namespace": "mygame"
}
```

**Flags:**
- `--item-id` (required): Item ID to query

**Exit Codes:**
- `0`: Entitlement found and active
- `1`: Entitlement not found or API error

### 11.2 verify-wallet

**Purpose:** Check wallet balance for a specific currency.

**Usage:**
```bash
challenge-demo verify-wallet --currency=<currency-code>
```

**Example:**
```bash
# Check gold balance
challenge-demo verify-wallet --currency=GOLD

# JSON output
{
  "currency_code": "GOLD",
  "balance": 150,
  "wallet_id": "wallet-xyz789",
  "status": "ACTIVE",
  "namespace": "mygame"
}
```

**Flags:**
- `--currency` (required): Currency code to query

**Exit Codes:**
- `0`: Wallet found with balance
- `1`: Wallet not found or API error

### 11.3 list-inventory

**Purpose:** List all item entitlements owned by the user.

**Usage:**
```bash
challenge-demo list-inventory [flags]
```

**Example:**
```bash
# List all active entitlements
challenge-demo list-inventory --status=ACTIVE

# JSON output
{
  "entitlements": [
    {
      "item_id": "winter_sword",
      "entitlement_id": "ent-abc123",
      "status": "ACTIVE",
      "quantity": 1,
      "granted_at": "2025-10-22T10:30:00Z"
    },
    {
      "item_id": "bronze_shield",
      "entitlement_id": "ent-def456",
      "status": "ACTIVE",
      "quantity": 2,
      "granted_at": "2025-10-21T15:00:00Z"
    }
  ],
  "total": 2
}
```

**Flags:**
- `--status`: Filter by status (ACTIVE, INACTIVE, all)
- `--limit`: Maximum items to return (default: 20)
- `--offset`: Pagination offset (default: 0)

**Exit Codes:**
- `0`: Success (may return empty list)
- `1`: API error

### 11.4 list-wallets

**Purpose:** List all currency wallets and their balances.

**Usage:**
```bash
challenge-demo list-wallets
```

**Example:**
```bash
# List all wallets
challenge-demo list-wallets

# JSON output
{
  "wallets": [
    {
      "currency_code": "GOLD",
      "balance": 150,
      "wallet_id": "wallet-xyz789",
      "status": "ACTIVE"
    },
    {
      "currency_code": "GEMS",
      "balance": 25,
      "wallet_id": "wallet-abc123",
      "status": "ACTIVE"
    }
  ],
  "total": 2
}
```

**Exit Codes:**
- `0`: Success (may return empty list)
- `1`: API error

### 11.5 SDK Integration

**AGS Platform SDK Functions:**
- `GetUserEntitlementByItemIDShort@platform` - Query single entitlement
- `QueryUserEntitlementsShort@platform` - List all entitlements
- `GetUserWalletShort@platform` - Query single wallet
- `QueryUserCurrencyWalletsShort@platform` - List all wallets

**Requirements:**
- Real AGS credentials required (`AB_CLIENT_ID`, `AB_CLIENT_SECRET`)
- User must be authenticated (password or client mode)
- Mock mode will simulate responses for testing

**Error Handling:**
- 3 retries with exponential backoff (500ms, 1s, 2s)
- Graceful degradation on AGS API failures
- Clear error messages with troubleshooting hints

### 11.6 End-to-End Verification Workflow Example

**Complete workflow showing dual token usage:**

```bash
#!/bin/bash
# dual-token-test.sh - Complete E2E test with verification

# Setup: Dual token authentication
USER_EMAIL="testuser@example.com"
USER_PASSWORD="testpass123"
ADMIN_CLIENT_ID="admin-xxx"
ADMIN_CLIENT_SECRET="admin-yyy"

FLAGS="--auth-mode=password \
       --email=$USER_EMAIL \
       --password=$USER_PASSWORD \
       --admin-client-id=$ADMIN_CLIENT_ID \
       --admin-client-secret=$ADMIN_CLIENT_SECRET"

echo "=== Dual Token E2E Test ==="
echo ""

# Step 1: Check initial state (uses admin token)
echo "1. Checking initial wallet balance..."
INITIAL_GOLD=$(challenge-demo list-wallets $FLAGS | jq '.wallets[] | select(.currency_code=="GOLD") | .balance')
echo "   Initial GOLD: $INITIAL_GOLD"

echo "2. Checking initial entitlements..."
INITIAL_COUNT=$(challenge-demo list-inventory $FLAGS | jq '.total')
echo "   Initial entitlements: $INITIAL_COUNT"

# Step 2: Trigger events to complete goals (uses user token for event handler)
echo ""
echo "3. Triggering 3 login events..."
for i in {1..3}; do
    challenge-demo trigger-event login $FLAGS
    sleep 1
done

# Step 3: Check challenge progress (uses user token)
echo ""
echo "4. Checking challenge progress..."
challenge-demo get-challenge daily-missions $FLAGS --format=text

# Step 4: Claim reward (uses user token)
echo ""
echo "5. Claiming reward for login-3 goal..."
challenge-demo claim-reward daily-missions login-3 $FLAGS

# Step 5: Verify reward was granted (uses admin token)
echo ""
echo "6. Verifying GOLD wallet was credited..."
FINAL_GOLD=$(challenge-demo list-wallets $FLAGS | jq '.wallets[] | select(.currency_code=="GOLD") | .balance')
echo "   Final GOLD: $FINAL_GOLD"
GOLD_DIFF=$((FINAL_GOLD - INITIAL_GOLD))
echo "   Difference: +$GOLD_DIFF GOLD"

if [ $GOLD_DIFF -eq 100 ]; then
    echo "   ✅ Wallet credit verified!"
else
    echo "   ❌ Expected +100 GOLD, got +$GOLD_DIFF"
    exit 1
fi

echo ""
echo "7. Verifying entitlement was granted..."
FINAL_COUNT=$(challenge-demo list-inventory $FLAGS | jq '.total')
echo "   Final entitlements: $FINAL_COUNT"
ITEM_DIFF=$((FINAL_COUNT - INITIAL_COUNT))
echo "   Difference: +$ITEM_DIFF items"

if [ $ITEM_DIFF -eq 1 ]; then
    echo "   ✅ Entitlement verified!"
else
    echo "   ❌ Expected +1 item, got +$ITEM_DIFF"
    exit 1
fi

echo ""
echo "=== All verifications passed! ==="
```

**What This Example Demonstrates:**
1. **Dual Token Setup**: Both user and admin credentials configured
2. **User Operations**: Trigger events, check challenges, claim rewards (user token)
3. **Admin Verification**: Query wallets and entitlements (admin token)
4. **End-to-End Confidence**: Proof that rewards were actually granted in AGS
5. **Automation**: Complete test can run in CI/CD

---

## 12. Future Enhancements

**Post-MVP features:**

1. **Batch Operations**
   ```bash
   challenge-demo trigger-event batch --file=events.json
   ```

2. **Filtering and Querying**
   ```bash
   challenge-demo list-challenges --status=in_progress --tag=daily
   ```

3. **Export/Import**
   ```bash
   challenge-demo export-progress > progress.json
   challenge-demo import-progress < progress.json
   ```

4. **Shell Completion**
   ```bash
   challenge-demo completion bash > /etc/bash_completion.d/challenge-demo
   ```

5. **Machine-Readable Logs**
   ```bash
   challenge-demo --log-format=json watch
   ```

---

## 13. Summary

**Key Design Decisions:**

1. **Cobra Framework**: Industry-standard CLI framework with subcommands
2. **Reuse Existing Code**: CLI mode uses same API client, auth, events as TUI
3. **Multiple Output Formats**: JSON (default), table, text
4. **Standard Exit Codes**: 0 = success, 1 = error, 2 = usage error
5. **Progressive Disclosure**: TUI is default, CLI is opt-in via subcommands

**Benefits:**

- ✅ **Automation**: Script test scenarios
- ✅ **CI/CD**: Run automated tests
- ✅ **Tooling**: Pipe to jq, grep, etc.
- ✅ **Documentation**: Show exact commands
- ✅ **Quick Operations**: Single commands without TUI

**Implementation Effort:**

- **Estimated Time**: 1 day (8 hours)
- **New Code**: ~800-1000 lines
- **Dependencies**: `cobra` (already included), `jq` (optional for users)
- **Testing**: Unit tests for commands + formatters

---

**Document Version:** 1.0
**Last Updated:** 2025-10-21
**Status:** ✅ Ready for Implementation
