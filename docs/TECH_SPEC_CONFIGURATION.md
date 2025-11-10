# Technical Specification: Configuration

**Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Overview](#overview)
2. [Environment Variables](#environment-variables)
3. [Challenge Config File](#challenge-config-file)
4. [Config Loading](#config-loading)
5. [In-Memory Cache](#in-memory-cache)
6. [Config Validation](#config-validation)

---

## Overview

### Configuration Philosophy

**Config-First Approach:**
- Challenges and goals defined in JSON file (not database)
- Config file bundled in Docker image at build time
- Changes require build + restart (no runtime modification via API)
- Game developers fork repo and edit config file directly

**Rationale:**
- Simpler than admin CRUD API
- Version-controlled via git
- Suitable for open-source project that game devs customize
- No need for complex authorization around config changes

---

## Environment Variables

### Required Variables

Both `extend-challenge-service` and `extend-challenge-event-handler` require these environment variables:

```bash
# === Namespace ===
NAMESPACE=mygame

# === Database (PostgreSQL) ===
DB_HOST=localhost
DB_PORT=5432
DB_NAME=challenge_db
DB_USER=postgres
DB_PASSWORD=secretpassword
DB_SSL_MODE=disable

# === Redis (Optional for M1) ===
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0

# === AccelByte Services ===
AGS_BASE_URL=https://demo.accelbyte.io
AGS_CLIENT_ID=service-account-client-id
AGS_CLIENT_SECRET=service-account-secret

# === Challenge Config ===
CONFIG_PATH=/app/config/challenges.json

# === Buffering ===
BUFFER_FLUSH_INTERVAL=1s

# === Retry Configuration ===
REWARD_GRANT_MAX_RETRIES=3
REWARD_GRANT_BASE_DELAY=500      # milliseconds (FQ1: faster retries with 500ms base)

# === Logging ===
LOG_LEVEL=info

# === Server ===
SERVER_PORT=8080
```

### Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NAMESPACE` | Yes | - | AGS namespace this deployment serves |
| `DB_HOST` | Yes | - | PostgreSQL host |
| `DB_PORT` | No | 5432 | PostgreSQL port |
| `DB_NAME` | Yes | - | PostgreSQL database name |
| `DB_USER` | Yes | - | PostgreSQL username |
| `DB_PASSWORD` | Yes | - | PostgreSQL password |
| `DB_SSL_MODE` | No | disable | PostgreSQL SSL mode (disable, require) |
| `REDIS_HOST` | No | - | Redis host (optional) |
| `REDIS_PORT` | No | 6379 | Redis port |
| `REDIS_PASSWORD` | No | - | Redis password |
| `AGS_BASE_URL` | Yes | - | AccelByte Gaming Services base URL |
| `AGS_CLIENT_ID` | Yes | - | Service account client ID |
| `AGS_CLIENT_SECRET` | Yes | - | Service account secret |
| `CONFIG_PATH` | No | /app/config/challenges.json | Path to challenges config file |
| `BUFFER_FLUSH_INTERVAL` | No | 1s | How often to flush buffered updates |
| `REWARD_GRANT_MAX_RETRIES` | No | 3 | Max retries for reward grants |
| `REWARD_GRANT_BASE_DELAY` | No | 500 | Base retry delay in milliseconds (FQ1: exponential backoff) |
| `LOG_LEVEL` | No | info | Log level (debug, info, warn, error) |
| `SERVER_PORT` | No | 8080 | HTTP server port (service only) |

### .env.example

```bash
# Copy this file to .env and fill in your values
# DO NOT commit .env to version control

# === Namespace ===
NAMESPACE=mygame

# === Database ===
DB_HOST=localhost
DB_PORT=5432
DB_NAME=challenge_db
DB_USER=postgres
DB_PASSWORD=CHANGEME
DB_SSL_MODE=disable

# === Redis (Optional) ===
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0

# === AccelByte Services ===
# Get these from AccelByte Admin Portal → Service Account
AGS_BASE_URL=https://demo.accelbyte.io
AGS_CLIENT_ID=CHANGEME
AGS_CLIENT_SECRET=CHANGEME

# === Challenge Config ===
CONFIG_PATH=/app/config/challenges.json

# === Performance Tuning ===
BUFFER_FLUSH_INTERVAL=1s
REWARD_GRANT_MAX_RETRIES=3
REWARD_GRANT_RETRY_DELAY=1s

# === Logging ===
LOG_LEVEL=info

# === Server (Service Only) ===
SERVER_PORT=8080
```

---

## Challenge Config File

### File Location

```
extend-challenge-service/config/challenges.json
extend-challenge-event-handler/config/challenges.json
```

**Both services use same config file** (copied during Docker build).

### Schema

```json
{
  "challenges": [
    {
      "id": "string (unique challenge identifier)",
      "name": "string (display name)",
      "description": "string (user-facing description)",
      "goals": [
        {
          "id": "string (unique goal identifier)",
          "name": "string (display name)",
          "description": "string (user-facing description)",
          "type": "string ('absolute', 'increment', or 'daily')",
          "event_source": "string ('login' or 'statistic')",
          "daily": "boolean (optional, only for increment type, default: false)",
          "requirement": {
            "stat_code": "string (event field to track)",
            "operator": "string (only '>=' supported in M1)",
            "target_value": "number (goal threshold)"
          },
          "reward": {
            "type": "string ('ITEM' or 'WALLET')",
            "reward_id": "string (item code or currency code)",
            "quantity": "number (amount to grant)"
          },
          "prerequisites": ["array of goal IDs (can be empty)"]
        }
      ]
    }
  ]
}
```

### Goal Types

**New in Phase 5.2**: Goals have explicit types that determine how progress is tracked.

#### Absolute (`"absolute"`)
**Usage:** Track absolute stat values (default type).

**Behavior:**
- Progress value = latest stat value from event
- Example: User has 100 kills → progress = 100
- Works with AGS Statistic Service events

**Config Example:**
```json
{
  "id": "kill-100-enemies",
  "type": "absolute",
  "requirement": {
    "stat_code": "kills",
    "operator": ">=",
    "target_value": 100
  }
}
```

**Event Flow:**
```
Stat Event: { statCode: "kills", value: 50 }  → progress = 50
Stat Event: { statCode: "kills", value: 75 }  → progress = 75
Stat Event: { statCode: "kills", value: 100 } → progress = 100, status = completed
```

---

#### Increment (`"increment"`)
**Usage:** Count event occurrences (e.g., login count, match count).

**Behavior:**
- Each event increments progress by 1
- Progress accumulates across multiple events
- Uses atomic DB increment: `progress = progress + 1`
- Optional `daily: true` flag limits to once per day

**Config Example (Regular Increment):**
```json
{
  "id": "login-100-times",
  "type": "increment",
  "daily": false,
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 100
  }
}
```

**Event Flow (Regular):**
```
Login Event #1 → progress = 1
Login Event #2 → progress = 2
Login Event #3 → progress = 3
...
Login Event #100 → progress = 100, status = completed
```

**Config Example (Daily Increment):**
```json
{
  "id": "login-7-days",
  "type": "increment",
  "daily": true,
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 7
  }
}
```

**Event Flow (Daily):**
```
Day 1, Login #1 (10:00 AM) → progress = 1
Day 1, Login #2 (2:00 PM)  → progress = 1 (same day, no increment)
Day 2, Login #1 (9:00 AM)  → progress = 2 (new day, increment)
Day 3, Login #1 (11:00 AM) → progress = 3
...
Day 7, Login #1 → progress = 7, status = completed
```

**Buffering:**
- Regular increment: Multiple increments buffered and accumulated
  - Example: 3 logins in buffer → single DB query: `UPDATE ... SET progress = progress + 3`
- Daily increment: Client-side date checking prevents same-day duplicates
  - Example: 3 logins same day in buffer → only first one increments
  - Uses `updated_at` to track last increment date

---

#### Daily (`"daily"`)
**Usage:** Check if event occurred today (e.g., daily login reward).

**Behavior:**
- Stores last event timestamp in `completed_at`
- Claim checks if `completed_at` date equals today
- Progress value not used (or can be used for other purposes)

**Config Example:**
```json
{
  "id": "daily-login",
  "type": "daily",
  "requirement": {
    "stat_code": "login_daily",
    "operator": ">=",
    "target_value": 1
  }
}
```

**Event Flow:**
```
Login Event (10:00 AM) → completed_at = 2025-10-17 10:00:00, status = completed
Login Event (2:00 PM)  → completed_at = 2025-10-17 14:00:00, status = completed
Claim (same day)       → SUCCESS (completed_at date == today)
Claim (next day)       → ERROR: NotLoggedInToday
```

---

### Goal Type Decision Matrix

| Goal Type | Daily Flag | Progress Tracking | Claim Validation | Use Case |
|-----------|-----------|------------------|------------------|----------|
| `absolute` | N/A (ignored) | Latest stat value | `progress >= target` | Kills, level, score |
| `increment` | `false` (default) | Count every occurrence | `progress >= target` | Total login count, total matches |
| `increment` | `true` | Count once per day | `progress >= target` | Login 7 days, daily quest streak |
| `daily` | N/A (ignored) | Last event timestamp | `completed_at == today` | Daily login rewards (claim once/day) |

---

### Daily vs Daily Increment: Key Differences

**IMPORTANT:** Daily type and Increment type with `daily: true` are **different goal types** with distinct behaviors.

#### When to Use Daily Type (`type: "daily"`)

**Use Case:** Reward user for event occurrence on a single day (repeats daily)

**Examples:**
- "Daily Login Bonus" - get reward for logging in today
- "Daily Quest Completion" - complete quest, claim reward today, repeat tomorrow
- "Daily Free Spin" - spin wheel once per day

**Characteristics:**
- ✅ Progress is binary: completed today (1) or not (0)
- ✅ Target value is always 1
- ✅ Resets each day (tracked via `completed_at` timestamp)
- ✅ Must claim reward same day (expires at midnight)
- ✅ Repeatable every day (new day = new opportunity)

**Example Flow:**
```
Day 1:
  10:00 AM - User logs in → status = completed, completed_at = 2025-10-17 10:00:00
  12:00 PM - User logs in again → status still completed (no change)
  2:00 PM - User claims reward → reward granted

Day 2:
  9:00 AM - User logs in → status = completed, completed_at = 2025-10-18 09:00:00
  1:00 PM - User can claim again → reward granted (new day)
```

---

#### When to Use Increment with Daily Flag (`type: "increment", daily: true`)

**Use Case:** Count number of distinct days with event occurrence (accumulates)

**Examples:**
- "Login 7 Days" - user must log in on 7 different days (not consecutive)
- "Play 14 Days this Month" - user must play on 14 separate days
- "Daily Quest Streak" - complete daily quest on 30 different days

**Characteristics:**
- ✅ Progress accumulates across days (1, 2, 3, ..., target)
- ✅ Target value can be any number (7, 14, 30, etc.)
- ✅ Never resets (accumulates until goal completed)
- ✅ Claim reward once after reaching target (not daily)
- ✅ Multiple events same day only count once

**Example Flow:**
```
Day 1:
  10:00 AM - User logs in → progress = 1
  12:00 PM - User logs in again → progress = 1 (same day, no increment)

Day 2:
  9:00 AM - User logs in → progress = 2 (new day)

Day 3:
  (User doesn't log in) → progress = 2 (no change)

Day 4:
  8:00 AM - User logs in → progress = 3

... (continues until progress = 7)

Day 10:
  User has progress = 7 → status = completed → user claims reward ONCE
```

---

#### Comparison Table

| Aspect | Daily Type | Increment with Daily Flag |
|--------|-----------|---------------------------|
| **Purpose** | Daily repeatable reward | Count distinct days |
| **Progress Range** | 0 or 1 | 0 to target_value |
| **Target Value** | Always 1 | Any number (7, 14, 30+) |
| **Resets** | Daily (every midnight) | Never (accumulates) |
| **Claim Frequency** | Once per day | Once after reaching target |
| **Same-Day Events** | Overwrites timestamp | Ignored (no double count) |
| **Reward Window** | Must claim same day | Claim anytime after completion |
| **Database Field** | Uses `completed_at` timestamp | Uses `progress` counter + `updated_at` |
| **Buffer Method** | `UpdateProgress()` | `IncrementProgress(isDailyIncrement=true)` |
| **Typical Use Case** | Daily login bonus, daily spin | Login 7 days challenge, monthly activity |

---

#### Config Examples Side-by-Side

**Daily Type (Repeatable):**
```json
{
  "id": "daily-login-bonus",
  "name": "Daily Login Bonus",
  "type": "daily",
  "requirement": {
    "stat_code": "login_daily",
    "operator": ">=",
    "target_value": 1
  },
  "reward": {
    "type": "WALLET",
    "reward_id": "GOLD",
    "quantity": 50
  }
}
```

**Increment with Daily Flag (Accumulative):**
```json
{
  "id": "login-7-days-challenge",
  "name": "Weekly Warrior",
  "type": "increment",
  "daily": true,
  "requirement": {
    "stat_code": "login_count",
    "operator": ">=",
    "target_value": 7
  },
  "reward": {
    "type": "ITEM",
    "reward_id": "loyalty_badge",
    "quantity": 1
  }
}
```

**Key Takeaway:**
- Use **daily type** for "do this once a day, every day" (repeating reward)
- Use **increment with daily flag** for "do this X different days total" (one-time reward)

---

### Type Inference (Default)

If `"type"` field is omitted, it defaults to `"absolute"` (backward compatible).

```json
{
  "id": "kill-100-enemies",
  // "type": "absolute" is implicit
  "requirement": { "stat_code": "kills", "target_value": 100 }
}
```

### Example Config

```json
{
  "challenges": [
    {
      "id": "winter-challenge-2025",
      "name": "Winter Challenge",
      "description": "Complete winter-themed goals to earn exclusive rewards",
      "goals": [
        {
          "id": "complete-tutorial",
          "name": "Tutorial Master",
          "description": "Complete the game tutorial",
          "type": "absolute",
          "event_source": "statistic",
          "requirement": {
            "stat_code": "tutorial_completed",
            "operator": ">=",
            "target_value": 1
          },
          "reward": {
            "type": "WALLET",
            "reward_id": "GOLD",
            "quantity": 50
          },
          "prerequisites": []
        },
        {
          "id": "kill-10-snowmen",
          "name": "Snowman Slayer",
          "description": "Defeat 10 snowmen in the frozen forest",
          "type": "absolute",
          "event_source": "statistic",
          "requirement": {
            "stat_code": "snowman_kills",
            "operator": ">=",
            "target_value": 10
          },
          "reward": {
            "type": "ITEM",
            "reward_id": "winter_sword",
            "quantity": 1
          },
          "prerequisites": ["complete-tutorial"]
        },
        {
          "id": "reach-level-5",
          "name": "Level Up",
          "description": "Reach character level 5",
          "type": "absolute",
          "event_source": "statistic",
          "requirement": {
            "stat_code": "player_level",
            "operator": ">=",
            "target_value": 5
          },
          "reward": {
            "type": "WALLET",
            "reward_id": "GOLD",
            "quantity": 100
          },
          "prerequisites": ["kill-10-snowmen"]
        }
      ]
    },
    {
      "id": "daily-quests",
      "name": "Daily Quests",
      "description": "Complete daily objectives for rewards",
      "goals": [
        {
          "id": "daily-login",
          "name": "Daily Login",
          "description": "Log in to the game today",
          "type": "daily",
          "event_source": "login",
          "requirement": {
            "stat_code": "login_daily",
            "operator": ">=",
            "target_value": 1
          },
          "reward": {
            "type": "WALLET",
            "reward_id": "GOLD",
            "quantity": 10
          },
          "prerequisites": []
        },
        {
          "id": "login-7-days",
          "name": "Weekly Warrior",
          "description": "Log in on 7 different days",
          "type": "increment",
          "event_source": "login",
          "daily": true,
          "requirement": {
            "stat_code": "login_count",
            "operator": ">=",
            "target_value": 7
          },
          "reward": {
            "type": "ITEM",
            "reward_id": "loyalty_badge",
            "quantity": 1
          },
          "prerequisites": []
        },
        {
          "id": "play-3-matches",
          "name": "Match Veteran",
          "description": "Complete 3 matches (total)",
          "type": "absolute",
          "event_source": "statistic",
          "requirement": {
            "stat_code": "matches_played",
            "operator": ">=",
            "target_value": 3
          },
          "reward": {
            "type": "ITEM",
            "reward_id": "daily_chest",
            "quantity": 1
          },
          "prerequisites": ["daily-login"]
        }
      ]
    }
  ]
}
```

### Event Sources

**New in Phase 5.2.3**: Goals must specify which event source triggers progress updates.

#### Supported Event Sources

**`"login"`** - IAM Login Events
- Triggered when user logs into the game
- Event: `{namespace}.iam.account.v1.userLoggedIn`
- Stat value: Always 1 per login event
- Use cases: Daily login rewards, login streaks, total login count

**`"statistic"`** - Statistic Update Events
- Triggered when game updates a user stat via AGS Statistic Service
- Event: `{namespace}.social.statistic.v1.statItemUpdated`
- Stat value: Provided in event payload
- Use cases: Kills, wins, score, level, etc.

#### Event Source Examples

**Login Event Goal:**
```json
{
  "id": "daily-login",
  "type": "daily",
  "event_source": "login",
  "requirement": {
    "stat_code": "login_daily",
    "operator": ">=",
    "target_value": 1
  }
}
```

**Statistic Event Goal:**
```json
{
  "id": "kill-100-enemies",
  "type": "absolute",
  "event_source": "statistic",
  "requirement": {
    "stat_code": "kills",
    "operator": ">=",
    "target_value": 100
  }
}
```

---

### Config Rules

1. **Challenge IDs**: Must be unique across all challenges
2. **Goal IDs**: Must be globally unique (not just within challenge)
3. **Goal Types**: Must be one of `"absolute"`, `"increment"`, or `"daily"` (defaults to `"absolute"` if omitted)
4. **Event Sources**: Must be one of `"login"` or `"statistic"` (required field, no default)
5. **Daily Flag**: Only valid for `"increment"` type (defaults to `false` if omitted)
6. **Stat Codes**: Match event payload field names exactly
7. **Operator**: Only `">="` supported in M1
8. **Prerequisites**: Must reference valid goal IDs (validated on load)
9. **Reward Types**: Only `"ITEM"` or `"WALLET"` allowed
10. **Quantities**: Must be positive integers

---

## Config Loading

### Startup Sequence

```
Application Start
       │
       ▼
Load Config File (challenges.json)
       │
       ├─► Parse JSON
       ├─► Validate Schema
       ├─► Validate Business Rules
       │   ├─► Unique IDs
       │   ├─► Valid prerequisites
       │   └─► Supported operators
       │
       ├─► Build In-Memory Cache
       │   ├─► goalsByID map
       │   ├─► goalsByStatCode map
       │   └─► challengesByID map
       │
       └─► Application Ready
```

### Config Loader Implementation

```go
// extend-challenge-common/pkg/config/loader.go

type ConfigLoader struct {
    configPath string
    validator  *Validator
    logger     *log.Logger
}

func NewConfigLoader(configPath string, logger *log.Logger) *ConfigLoader {
    return &ConfigLoader{
        configPath: configPath,
        validator:  NewValidator(),
        logger:     logger,
    }
}

func (l *ConfigLoader) LoadConfig() (*Config, error) {
    // 1. Read file
    data, err := os.ReadFile(l.configPath)
    if err != nil {
        return nil, fmt.Errorf("failed to read config file: %w", err)
    }

    // 2. Parse JSON
    var config Config
    if err := json.Unmarshal(data, &config); err != nil {
        return nil, fmt.Errorf("failed to parse config JSON: %w", err)
    }

    // 3. Validate
    if err := l.validator.Validate(&config); err != nil {
        return nil, fmt.Errorf("config validation failed: %w", err)
    }

    l.logger.Info("Config loaded successfully",
        "challenges", len(config.Challenges),
        "total_goals", l.countGoals(&config),
    )

    return &config, nil
}

func (l *ConfigLoader) countGoals(config *Config) int {
    count := 0
    for _, challenge := range config.Challenges {
        count += len(challenge.Goals)
    }
    return count
}
```

---

## In-Memory Cache

### Cache Structure

```go
// extend-challenge-common/pkg/cache/goal_cache.go

type InMemoryGoalCache struct {
    goalsByID       map[string]*domain.Goal           // "goal-id" -> Goal
    goalsByStatCode map[string][]*domain.Goal         // "stat_code" -> [Goals]
    challengesByID  map[string]*domain.Challenge      // "challenge-id" -> Challenge
    challenges      []*domain.Challenge               // All challenges
    mu              sync.RWMutex
    logger          *log.Logger
}

func NewInMemoryGoalCache(config *config.Config, logger *log.Logger) *InMemoryGoalCache {
    cache := &InMemoryGoalCache{
        goalsByID:       make(map[string]*domain.Goal),
        goalsByStatCode: make(map[string][]*domain.Goal),
        challengesByID:  make(map[string]*domain.Challenge),
        challenges:      make([]*domain.Challenge, 0),
        logger:          logger,
    }

    cache.buildCache(config)

    return cache
}
```

### Building Cache Indexes

```go
func (c *InMemoryGoalCache) buildCache(config *config.Config) {
    c.mu.Lock()
    defer c.mu.Unlock()

    // Clear existing cache
    c.goalsByID = make(map[string]*domain.Goal)
    c.goalsByStatCode = make(map[string][]*domain.Goal)
    c.challengesByID = make(map[string]*domain.Challenge)
    c.challenges = make([]*domain.Challenge, 0)

    // Build indexes
    for _, challenge := range config.Challenges {
        // Index challenge by ID
        c.challengesByID[challenge.ID] = challenge
        c.challenges = append(c.challenges, challenge)

        for _, goal := range challenge.Goals {
            // Index goal by ID
            c.goalsByID[goal.ID] = goal

            // Index goal by stat code (multiple goals can track same stat)
            statCode := goal.Requirement.StatCode
            c.goalsByStatCode[statCode] = append(c.goalsByStatCode[statCode], goal)
        }
    }

    c.logger.Info("Cache built",
        "challenges", len(c.challenges),
        "goals", len(c.goalsByID),
        "stat_codes", len(c.goalsByStatCode),
    )
}
```

### Cache Lookup Methods

```go
func (c *InMemoryGoalCache) GetGoalByID(goalID string) *domain.Goal {
    c.mu.RLock()
    defer c.mu.RUnlock()

    return c.goalsByID[goalID]
}

func (c *InMemoryGoalCache) GetGoalsByStatCode(statCode string) []*domain.Goal {
    c.mu.RLock()
    defer c.mu.RUnlock()

    return c.goalsByStatCode[statCode]
}

func (c *InMemoryGoalCache) GetChallengeByChallengeID(challengeID string) *domain.Challenge {
    c.mu.RLock()
    defer c.mu.RUnlock()

    return c.challengesByID[challengeID]
}

func (c *InMemoryGoalCache) GetAllChallenges() []*domain.Challenge {
    c.mu.RLock()
    defer c.mu.RUnlock()

    return c.challenges
}
```

### Cache Reload (Future Use)

```go
func (c *InMemoryGoalCache) Reload() error {
    // Load config from file
    loader := config.NewConfigLoader(c.configPath, c.logger)
    newConfig, err := loader.LoadConfig()
    if err != nil {
        return fmt.Errorf("failed to reload config: %w", err)
    }

    // Rebuild cache
    c.buildCache(newConfig)

    return nil
}
```

**Note:** Reload requires restart in M1 (config baked into Docker image).

---

## Config Validation

### Validator Implementation

```go
// extend-challenge-common/pkg/config/validator.go

type Validator struct{}

func NewValidator() *Validator {
    return &Validator{}
}

func (v *Validator) Validate(config *Config) error {
    if len(config.Challenges) == 0 {
        return errors.New("config must have at least one challenge")
    }

    // Track unique IDs
    challengeIDs := make(map[string]bool)
    goalIDs := make(map[string]bool)
    allGoals := make(map[string]*domain.Goal)

    // First pass: collect all IDs and goals
    for _, challenge := range config.Challenges {
        // Validate challenge
        if err := v.validateChallenge(challenge); err != nil {
            return fmt.Errorf("invalid challenge '%s': %w", challenge.ID, err)
        }

        // Check duplicate challenge ID
        if challengeIDs[challenge.ID] {
            return fmt.Errorf("duplicate challenge ID: %s", challenge.ID)
        }
        challengeIDs[challenge.ID] = true

        // Validate goals
        for _, goal := range challenge.Goals {
            if err := v.validateGoal(goal); err != nil {
                return fmt.Errorf("invalid goal '%s' in challenge '%s': %w", goal.ID, challenge.ID, err)
            }

            // Check duplicate goal ID
            if goalIDs[goal.ID] {
                return fmt.Errorf("duplicate goal ID: %s", goal.ID)
            }
            goalIDs[goal.ID] = true

            allGoals[goal.ID] = goal
        }
    }

    // Second pass: validate prerequisites
    for _, goal := range allGoals {
        for _, prereqID := range goal.Prerequisites {
            if _, exists := allGoals[prereqID]; !exists {
                return fmt.Errorf("goal '%s' has invalid prerequisite: '%s' does not exist", goal.ID, prereqID)
            }
        }
    }

    return nil
}
```

### Validation Rules

```go
func (v *Validator) validateChallenge(challenge *domain.Challenge) error {
    if challenge.ID == "" {
        return errors.New("challenge ID cannot be empty")
    }
    if challenge.Name == "" {
        return errors.New("challenge name cannot be empty")
    }
    if len(challenge.Goals) == 0 {
        return errors.New("challenge must have at least one goal")
    }
    return nil
}

func (v *Validator) validateGoal(goal *domain.Goal) error {
    if goal.ID == "" {
        return errors.New("goal ID cannot be empty")
    }
    if goal.Name == "" {
        return errors.New("goal name cannot be empty")
    }

    // Validate goal type (default to "absolute" if empty)
    if goal.Type == "" {
        goal.Type = domain.GoalTypeAbsolute
    }
    if goal.Type != domain.GoalTypeAbsolute &&
       goal.Type != domain.GoalTypeIncrement &&
       goal.Type != domain.GoalTypeDaily {
        return fmt.Errorf("unsupported goal type '%s' (must be 'absolute', 'increment', or 'daily')", goal.Type)
    }

    // Validate event source (required field, no default)
    if goal.EventSource == "" {
        return errors.New("event_source cannot be empty")
    }
    if goal.EventSource != domain.EventSourceLogin &&
       goal.EventSource != domain.EventSourceStatistic {
        return fmt.Errorf("unsupported event_source '%s' (must be 'login' or 'statistic')", goal.EventSource)
    }

    // Validate daily flag (only valid for increment type)
    if goal.Daily && goal.Type != domain.GoalTypeIncrement {
        return errors.New("daily flag can only be true for increment-type goals")
    }

    // Validate requirement
    if goal.Requirement.StatCode == "" {
        return errors.New("stat_code cannot be empty")
    }
    if goal.Requirement.Operator != ">=" {
        return fmt.Errorf("unsupported operator '%s' (only '>=' supported)", goal.Requirement.Operator)
    }
    if goal.Requirement.TargetValue <= 0 {
        return errors.New("target_value must be positive")
    }

    // Validate reward
    if goal.Reward.Type != "ITEM" && goal.Reward.Type != "WALLET" {
        return fmt.Errorf("unsupported reward type '%s' (only 'ITEM' or 'WALLET' allowed)", goal.Reward.Type)
    }
    if goal.Reward.RewardID == "" {
        return errors.New("reward_id cannot be empty")
    }
    if goal.Reward.Quantity <= 0 {
        return errors.New("reward quantity must be positive")
    }

    return nil
}
```

### Startup Failure

If config validation fails, application must **exit immediately**:

```go
func main() {
    // Load config
    loader := config.NewConfigLoader(configPath, logger)
    cfg, err := loader.LoadConfig()
    if err != nil {
        logger.Fatal("Failed to load config", "error", err)
        os.Exit(1)  // Exit with error
    }

    // Build cache
    goalCache := cache.NewInMemoryGoalCache(cfg, logger)

    // Continue startup...
}
```

**Rationale:** Fail fast on invalid config (don't start with broken configuration).

---

## Config Change Behavior

### Scenario 1: Goal Target Value Changes

**Before:**
```json
{
  "id": "kill-10-snowmen",
  "requirement": { "stat_code": "snowman_kills", "target_value": 10 }
}
```

**After:**
```json
{
  "id": "kill-10-snowmen",
  "requirement": { "stat_code": "snowman_kills", "target_value": 20 }
}
```

**User has progress: 15 snowmen killed**

**API Response:**
```json
{
  "goal_id": "kill-10-snowmen",
  "progress": 15,
  "requirement": { "target_value": 20 },
  "status": "in_progress"
}
```

**Behavior:** Always follow latest config (show 15/20, not 15/10).

### Scenario 2: Goal Removed from Config

**User has progress in DB for removed goal.**

**API Response:** Goal excluded from response (orphaned DB row ignored).

**Claim Attempt:** Returns 404 `GOAL_NOT_FOUND`.

**Cleanup:** Game developer manually runs `DELETE FROM user_goal_progress WHERE goal_id = 'removed-goal'` if needed.

### Scenario 3: New Goal Added

**New goal added to config.**

**API Response:** Goal shows `progress: 0, status: "not_started"` for all users.

**DB Row:** Created lazily on first event or API request.

---

## Config Management Guidelines

### Modifying Active Challenges

**Decision:** Game developers can modify active challenges at any time, but must be aware of the implications.

**⚠️ IMPORTANT WARNINGS:**

1. **User Progress Disruption**
   - Changing goal requirements may cause user confusion
   - Example: User sees "15/10 completed" after target lowered from 20 to 10
   - Users may lose ability to claim rewards if goals removed

2. **No Config Versioning in M1**
   - No rollback mechanism
   - No config history tracking
   - Use git for version control of config files
   - Test config changes in staging environment first

3. **Database Inconsistencies**
   - Removing goals leaves orphaned rows in database
   - Renaming goal IDs creates duplicate entries (new goal ID = new DB row)
   - Manual cleanup may be required: `DELETE FROM user_goal_progress WHERE goal_id = 'old-goal-id'`

**Recommended Workflow:**

```bash
# 1. Test config changes locally
vim config/challenges.json
docker-compose up --build

# 2. Validate config loads successfully
# Check logs for: "Config loaded successfully"

# 3. Deploy to staging
git commit -m "Update challenge goals"
make deploy-staging

# 4. Test with real users on staging
# Check user progress API responses

# 5. Deploy to production
make deploy-production

# 6. Monitor for errors
# Watch logs for: "Config validation failed"
```

**Common Safe Changes:**

| Change Type | Safe? | Notes |
|-------------|-------|-------|
| Add new challenge | ✅ Yes | Users see new challenge with 0 progress |
| Add new goal | ✅ Yes | Users see new goal with 0 progress |
| Increase target value | ⚠️ Caution | Existing progress still valid, but harder to complete |
| Decrease target value | ⚠️ Caution | May auto-complete for users already past new threshold |
| Change reward | ⚠️ Caution | Users who already completed may complain |
| Remove goal | ❌ Not Recommended | Orphaned DB rows, users lose progress |
| Rename goal ID | ❌ Not Recommended | Creates new goal, old progress orphaned |
| Change stat code | ❌ Not Recommended | Breaks event routing, progress stalls |

**Migration Strategy (Future - M2+):**

- Config versioning with migration scripts
- Graceful deprecation of old goals
- User notification system for config changes
- Automatic data migration tools

---

### Config Hot Reload

**Decision:** Config changes require rebuild and restart (no hot reload).

**Why No Hot Reload in M1:**

1. **Config Baked into Container**
   - Config file copied into Docker image at build time
   - No external ConfigMap or volume mount
   - Changes require new image build

2. **Simpler Implementation**
   - No file watcher needed
   - No cache invalidation logic
   - No partial reload failures
   - Fewer failure modes

3. **Deployment Model**
   - Game developers already use CI/CD pipelines
   - Changes go through: git commit → build → deploy
   - Full deployment provides clean slate

4. **Consistency Guarantees**
   - All replicas restart with same config
   - No transient state where replicas have different configs
   - No race conditions during reload

**Config Update Flow:**

```
┌─────────────────────┐
│ Edit Config File    │
│ challenges.json     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Git Commit          │
│ git add config/     │
│ git commit          │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Build Docker Image  │
│ docker build .      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Deploy to Extend    │
│ extend-helper-cli   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Pods Restart        │
│ Config Loaded       │
└─────────────────────┘
```

**Estimated Downtime:**

- **Backend Service (REST API):** 5-10 seconds per replica (rolling restart)
- **Event Handler:** 30-35 seconds (graceful shutdown + buffer flush + restart)

**Minimizing Downtime:**

```yaml
# Kubernetes deployment.yaml
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1  # Only 1 pod down at a time
      maxSurge: 1        # Start new pod before killing old one

  template:
    spec:
      terminationGracePeriodSeconds: 35  # Allow buffer flush
      containers:
      - name: event-handler
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 3
```

**Hot Reload (Future - M2+):**

If hot reload becomes necessary:

1. **Mount config as ConfigMap volume**
   ```yaml
   volumes:
   - name: config
     configMap:
       name: challenge-config
   ```

2. **Watch config file for changes**
   ```go
   watcher, _ := fsnotify.NewWatcher()
   watcher.Add("/app/config/challenges.json")
   ```

3. **Reload on change**
   ```go
   go func() {
       for event := range watcher.Events {
           if event.Op&fsnotify.Write == fsnotify.Write {
               goalCache.Reload()
           }
       }
   }()
   ```

4. **Handle reload failures gracefully**
   - Validate new config before applying
   - Keep old config if validation fails
   - Log errors but don't crash

**Current Status:** Defer hot reload to M2+ based on user feedback.

---

## References

- **JSON Schema Validator**: https://github.com/xeipuuv/gojsonschema (optional, for stricter validation)
- **Environment Variables Best Practices**: https://12factor.net/config
- **AGS Platform Service SDK**: When implementing RewardClient, use Extend SDK MCP Server to find the correct SDK functions:
  - Search for "grant entitlement" for ITEM rewards: `mcp__extend-sdk-mcp-server__search_functions` with query "entitlement grant"
  - Search for "credit wallet" for WALLET rewards: `mcp__extend-sdk-mcp-server__search_functions` with query "wallet credit"
  - Get detailed function signatures: `mcp__extend-sdk-mcp-server__get_bulk_functions`

---

**Document Status:** Complete - Ready for implementation
