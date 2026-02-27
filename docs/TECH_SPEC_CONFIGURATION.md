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
      "challengeId": "string (unique challenge identifier)",
      "name": "string (display name)",
      "description": "string (user-facing description)",
      "goals": [
        {
          "goalId": "string (unique goal identifier)",
          "name": "string (display name)",
          "description": "string (user-facing description)",
          "eventSource": "string ('login' or 'statistic')",
          "defaultAssigned": "boolean (optional, default: false, M3: auto-assign to new players)",
          "requirement": {
            "statCode": "string (event field to track)",
            "operator": "string (only '>=' supported in M1)",
            "targetValue": "number (goal threshold)",
            "progressMode": "string ('absolute' or 'relative', default: 'absolute')"
          },
          "reward": {
            "type": "string ('ITEM' or 'WALLET')",
            "rewardId": "string (item code or currency code)",
            "quantity": "number (amount to grant)"
          },
          "prerequisites": ["array of goal IDs (can be empty)"],
          "rotation": {
            "enabled": "boolean (required if rotation block present)",
            "type": "string (only 'global' in M5)",
            "schedule": "string ('daily', 'weekly', or 'monthly')",
            "onExpiry": {
              "resetProgress": "boolean",
              "allowReselection": "boolean"
            }
          }
        }
      ]
    }
  ]
}
```

**Note:** The `rotation` block is optional. Omit it entirely for non-rotating goals.

### Progress Modes

**Updated in M5**: Goals use a `progressMode` field on the `requirement` object to determine how progress is tracked. This replaces the previous `type` and `daily` fields from earlier milestones.

#### Absolute (`"absolute"`)
**Usage:** Track absolute stat values. Progress equals the latest stat value from events.

**Best for:** Lifetime achievements and cumulative stats -- total kills, total logins, player level, high scores.

**Behavior:**
- Progress value = latest stat value from event
- Example: User has 100 kills -> progress = 100
- Works with both login and statistic event sources
- No baseline tracking needed

**Config Example:**
```json
{
  "goalId": "kill-100-enemies",
  "name": "Century Slayer",
  "description": "Defeat 100 enemies total",
  "eventSource": "statistic",
  "defaultAssigned": true,
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 100,
    "progressMode": "absolute"
  },
  "reward": {
    "type": "WALLET",
    "rewardId": "GEMS",
    "quantity": 25
  },
  "prerequisites": []
}
```

**Event Flow:**
```
Stat Event: { statCode: "kills", value: 50 }  -> progress = 50
Stat Event: { statCode: "kills", value: 75 }  -> progress = 75
Stat Event: { statCode: "kills", value: 100 } -> progress = 100, status = completed
```

---

#### Relative (`"relative"`)
**Usage:** Track progress relative to a baseline captured at the start of a rotation period. Progress equals the current stat value minus the baseline.

**Best for:** Time-based rotating goals -- daily quests, weekly challenges, monthly missions. The baseline is captured when the rotation period begins, so only progress made during the current period counts.

**Behavior:**
- Baseline captured at rotation period start (e.g., start of day for daily rotation)
- Progress value = current stat value - baseline
- Example: Baseline = 50 kills, current = 65 kills -> progress = 15
- Requires a `rotation` block on the goal (validation enforces this)
- When rotation period expires, baseline is recaptured and progress resets

**Config Example:**
```json
{
  "goalId": "daily-kill-10",
  "name": "Daily Slayer",
  "description": "Defeat 10 enemies today",
  "eventSource": "statistic",
  "defaultAssigned": true,
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 10,
    "progressMode": "relative"
  },
  "reward": {
    "type": "WALLET",
    "rewardId": "GEMS",
    "quantity": 5
  },
  "prerequisites": [],
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

**Event Flow (Daily Rotation):**
```
Day 1 starts, baseline captured: kills = 50
  Stat Event: { statCode: "kills", value: 55 }  -> progress = 55 - 50 = 5
  Stat Event: { statCode: "kills", value: 60 }  -> progress = 60 - 50 = 10, status = completed
  User claims reward

Day 2 starts, baseline recaptured: kills = 65
  Stat Event: { statCode: "kills", value: 68 }  -> progress = 68 - 65 = 3
  Stat Event: { statCode: "kills", value: 75 }  -> progress = 75 - 65 = 10, status = completed
  User claims reward again
```

---

### Progress Mode Decision Matrix

| Progress Mode | Progress Tracking | Rotation | Use Case |
|---------------|------------------|----------|----------|
| `absolute` | Latest stat value | Not allowed | Lifetime kills, total logins, player level |
| `relative` | Stat value minus baseline | Required | Daily quests, weekly challenges, monthly missions |

---

### Rotation Config

**New in M5**: Goals can include an optional `rotation` block that enables time-based rotation. When a rotation period expires, the goal resets and becomes available again in the next period.

#### Schema

```json
{
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

#### Field Reference

| Field | Type | Required | Values | Description |
|-------|------|----------|--------|-------------|
| `enabled` | boolean | Yes | `true`, `false` | Whether rotation is active for this goal |
| `type` | string | Yes | `"global"` | Rotation type. M5 supports only `"global"` (all users share same rotation schedule) |
| `schedule` | string | Yes | `"daily"`, `"weekly"`, `"monthly"` | How often the goal rotates |
| `onExpiry.resetProgress` | boolean | Yes | `true`, `false` | Whether to reset progress when the rotation period expires |
| `onExpiry.allowReselection` | boolean | Yes | `true`, `false` | Whether the goal can be re-assigned in the next rotation period |

#### Schedule Details

| Schedule | Period Start | Period End | Example |
|----------|-------------|------------|---------|
| `daily` | 00:00 UTC | 23:59:59 UTC | Resets every day at midnight UTC |
| `weekly` | Monday 00:00 UTC | Sunday 23:59:59 UTC | Resets every Monday at midnight UTC |
| `monthly` | 1st of month 00:00 UTC | Last day of month 23:59:59 UTC | Resets on the 1st of each month |

#### Constraints

- **Rotation requires `progressMode: "relative"`**: A goal with a `rotation` block must use `progressMode: "relative"` on its requirement. This is enforced by the config validator. Using `progressMode: "absolute"` with rotation is an error because absolute progress does not support baseline tracking.
- **Rotation `type` must be `"global"`**: M5 only supports global rotation (all players share the same schedule). Per-user rotation types may be added in future milestones.
- **`enabled: false`**: If `enabled` is `false`, the rotation block is ignored and the goal behaves as a non-rotating relative goal.

---

### Config Examples

#### Example 1: Daily Rotating Goal

A goal that resets every day. Players must defeat 10 enemies each day to earn the reward.

```json
{
  "goalId": "daily-kill-10",
  "name": "Daily Slayer",
  "description": "Defeat 10 enemies today",
  "eventSource": "statistic",
  "defaultAssigned": true,
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 10,
    "progressMode": "relative"
  },
  "reward": {
    "type": "WALLET",
    "rewardId": "GEMS",
    "quantity": 5
  },
  "prerequisites": [],
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

#### Example 2: Weekly Rotating Goal

A goal that resets every Monday. Players must win 20 matches during the week.

```json
{
  "goalId": "weekly-wins-20",
  "name": "Weekly Victor",
  "description": "Win 20 matches this week",
  "eventSource": "statistic",
  "defaultAssigned": true,
  "requirement": {
    "statCode": "matches_won",
    "operator": ">=",
    "targetValue": 20,
    "progressMode": "relative"
  },
  "reward": {
    "type": "ITEM",
    "rewardId": "weekly_chest",
    "quantity": 1
  },
  "prerequisites": [],
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "weekly",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

#### Example 3: Monthly Rotating Goal

A goal that resets on the 1st of each month. Players must earn 5000 score during the month.

```json
{
  "goalId": "monthly-score-5000",
  "name": "Monthly Grinder",
  "description": "Earn 5000 score this month",
  "eventSource": "statistic",
  "defaultAssigned": false,
  "requirement": {
    "statCode": "score",
    "operator": ">=",
    "targetValue": 5000,
    "progressMode": "relative"
  },
  "reward": {
    "type": "WALLET",
    "rewardId": "GEMS",
    "quantity": 100
  },
  "prerequisites": [],
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "monthly",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

#### Example 4: Non-Rotating Absolute Goal

A lifetime achievement goal with no rotation. Progress tracks the total stat value.

```json
{
  "goalId": "reach-level-50",
  "name": "Veteran",
  "description": "Reach player level 50",
  "eventSource": "statistic",
  "defaultAssigned": true,
  "requirement": {
    "statCode": "player_level",
    "operator": ">=",
    "targetValue": 50,
    "progressMode": "absolute"
  },
  "reward": {
    "type": "ITEM",
    "rewardId": "veteran_badge",
    "quantity": 1
  },
  "prerequisites": []
}
```

**Note:** Non-rotating goals do not include a `rotation` block. The field is omitted entirely (not set to `enabled: false`).

---

### GoalType to ProgressMode Migration Guide

**M5 replaced the `type` and `daily` fields with `progressMode` and `rotation`.** This section documents how to migrate existing challenge configurations.

#### Migration Rules

| Old Config | New Config | Notes |
|------------|------------|-------|
| `"type": "absolute"` | `"progressMode": "absolute"` on requirement | Behavior unchanged. Progress equals stat value. |
| `"type": "increment"` | `"progressMode": "absolute"` on requirement | Was always tracking the absolute stat value from events. No rotation block needed. |
| `"type": "increment", "daily": true` | `"progressMode": "relative"` on requirement + `rotation` block | Daily deduplication is now handled by relative progress mode with daily rotation. |
| `"type": "daily"` | `"progressMode": "relative"` on requirement + `rotation` block with `"schedule": "daily"` | Daily reset behavior now handled by rotation with `resetProgress: true`. |

#### Migration Example: Increment Goal

**Before (old format):**
```json
{
  "id": "kill-100-enemies",
  "type": "increment",
  "event_source": "statistic",
  "requirement": {
    "stat_code": "kills",
    "operator": ">=",
    "target_value": 100
  }
}
```

**After (new format):**
```json
{
  "goalId": "kill-100-enemies",
  "eventSource": "statistic",
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 100,
    "progressMode": "absolute"
  }
}
```

#### Migration Example: Daily Goal

**Before (old format):**
```json
{
  "id": "daily-login-bonus",
  "type": "daily",
  "event_source": "login",
  "daily": true,
  "requirement": {
    "stat_code": "login_daily",
    "operator": ">=",
    "target_value": 1
  }
}
```

**After (new format):**
```json
{
  "goalId": "daily-login-bonus",
  "eventSource": "login",
  "requirement": {
    "statCode": "login_daily",
    "operator": ">=",
    "targetValue": 1,
    "progressMode": "relative"
  },
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

#### Removed Fields

The following fields no longer exist in the config schema:
- **`type`** on goal object: Replaced by `progressMode` on the `requirement` object.
- **`daily`** on goal object: Replaced by the `rotation` block with `schedule: "daily"`.

---

### Default Progress Mode

If `progressMode` is omitted from the requirement, it defaults to `"absolute"`.

```json
{
  "goalId": "kill-100-enemies",
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 100
  }
}
```

This is equivalent to explicitly setting `"progressMode": "absolute"`.

### Example Config

```json
{
  "challenges": [
    {
      "challengeId": "winter-challenge-2025",
      "name": "Winter Challenge",
      "description": "Complete winter-themed goals to earn exclusive rewards",
      "goals": [
        {
          "goalId": "complete-tutorial",
          "name": "Tutorial Master",
          "description": "Complete the game tutorial",
          "eventSource": "statistic",
          "defaultAssigned": true,
          "requirement": {
            "statCode": "tutorial_completed",
            "operator": ">=",
            "targetValue": 1,
            "progressMode": "absolute"
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GOLD",
            "quantity": 50
          },
          "prerequisites": []
        },
        {
          "goalId": "kill-10-snowmen",
          "name": "Snowman Slayer",
          "description": "Defeat 10 snowmen in the frozen forest",
          "eventSource": "statistic",
          "defaultAssigned": false,
          "requirement": {
            "statCode": "snowman_kills",
            "operator": ">=",
            "targetValue": 10,
            "progressMode": "absolute"
          },
          "reward": {
            "type": "ITEM",
            "rewardId": "winter_sword",
            "quantity": 1
          },
          "prerequisites": ["complete-tutorial"]
        },
        {
          "goalId": "reach-level-5",
          "name": "Level Up",
          "description": "Reach character level 5",
          "eventSource": "statistic",
          "defaultAssigned": false,
          "requirement": {
            "statCode": "player_level",
            "operator": ">=",
            "targetValue": 5,
            "progressMode": "absolute"
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GOLD",
            "quantity": 100
          },
          "prerequisites": ["kill-10-snowmen"]
        }
      ]
    },
    {
      "challengeId": "daily-quests",
      "name": "Daily Quests",
      "description": "Complete daily objectives for rewards",
      "goals": [
        {
          "goalId": "daily-login",
          "name": "Daily Login",
          "description": "Log in to the game today",
          "eventSource": "login",
          "defaultAssigned": true,
          "requirement": {
            "statCode": "login_daily",
            "operator": ">=",
            "targetValue": 1,
            "progressMode": "relative"
          },
          "reward": {
            "type": "WALLET",
            "rewardId": "GOLD",
            "quantity": 10
          },
          "prerequisites": [],
          "rotation": {
            "enabled": true,
            "type": "global",
            "schedule": "daily",
            "onExpiry": {
              "resetProgress": true,
              "allowReselection": true
            }
          }
        },
        {
          "goalId": "weekly-wins",
          "name": "Weekly Victor",
          "description": "Win 10 matches this week",
          "eventSource": "statistic",
          "defaultAssigned": false,
          "requirement": {
            "statCode": "matches_won",
            "operator": ">=",
            "targetValue": 10,
            "progressMode": "relative"
          },
          "reward": {
            "type": "ITEM",
            "rewardId": "weekly_chest",
            "quantity": 1
          },
          "prerequisites": [],
          "rotation": {
            "enabled": true,
            "type": "global",
            "schedule": "weekly",
            "onExpiry": {
              "resetProgress": true,
              "allowReselection": true
            }
          }
        },
        {
          "goalId": "play-3-matches",
          "name": "Match Veteran",
          "description": "Complete 3 matches (total, lifetime)",
          "eventSource": "statistic",
          "defaultAssigned": false,
          "requirement": {
            "statCode": "matches_played",
            "operator": ">=",
            "targetValue": 3,
            "progressMode": "absolute"
          },
          "reward": {
            "type": "ITEM",
            "rewardId": "daily_chest",
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

Goals must specify which event source triggers progress updates.

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
  "goalId": "daily-login",
  "eventSource": "login",
  "requirement": {
    "statCode": "login_daily",
    "operator": ">=",
    "targetValue": 1,
    "progressMode": "relative"
  },
  "rotation": {
    "enabled": true,
    "type": "global",
    "schedule": "daily",
    "onExpiry": {
      "resetProgress": true,
      "allowReselection": true
    }
  }
}
```

**Statistic Event Goal:**
```json
{
  "goalId": "kill-100-enemies",
  "eventSource": "statistic",
  "requirement": {
    "statCode": "kills",
    "operator": ">=",
    "targetValue": 100,
    "progressMode": "absolute"
  }
}
```

---

### Config Rules

1. **Challenge IDs**: Must be unique across all challenges
2. **Goal IDs**: Must be globally unique (not just within challenge)
3. **Progress Mode**: Must be `"absolute"` or `"relative"` (defaults to `"absolute"` if omitted)
4. **Event Sources**: Must be one of `"login"` or `"statistic"` (required field, no default)
5. **Rotation Block**: Optional. When present, the following rules apply:
   - `type` must be `"global"` (only supported value in M5)
   - `schedule` must be `"daily"`, `"weekly"`, or `"monthly"`
   - Rotation requires `progressMode: "relative"` on the requirement (error if `absolute`)
   - All `onExpiry` fields (`resetProgress`, `allowReselection`) are required when rotation is present
6. **Default Assigned** (M3): Boolean flag (defaults to `false` if omitted)
   - Controls whether goal is assigned to new players during initialization
   - Typically set to `true` for 5-10 beginner/tutorial goals out of 500+ total goals
   - Goals with `defaultAssigned = false` are created lazily when user activates them
   - See [TECH_SPEC_M3.md](./TECH_SPEC_M3.md) for lazy materialization details
7. **Stat Codes**: Match event payload field names exactly
8. **Operator**: Only `">="` supported in M1
9. **Prerequisites**: Must reference valid goal IDs (validated on load)
10. **Reward Types**: Only `"ITEM"` or `"WALLET"` allowed
11. **Quantities**: Must be positive integers

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
    goalsByStatCode map[string][]*domain.Goal         // "statCode" -> [Goals]
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

    // Validate event source (required field, no default)
    if goal.EventSource == "" {
        return errors.New("eventSource cannot be empty")
    }
    if goal.EventSource != domain.EventSourceLogin &&
       goal.EventSource != domain.EventSourceStatistic {
        return fmt.Errorf("unsupported eventSource '%s' (must be 'login' or 'statistic')", goal.EventSource)
    }

    // Validate progress mode (default to "absolute" if empty)
    if goal.Requirement.ProgressMode == "" {
        goal.Requirement.ProgressMode = domain.ProgressModeAbsolute
    }
    if goal.Requirement.ProgressMode != domain.ProgressModeAbsolute &&
       goal.Requirement.ProgressMode != domain.ProgressModeRelative {
        return fmt.Errorf("unsupported progressMode '%s' (must be 'absolute' or 'relative')",
            goal.Requirement.ProgressMode)
    }

    // Validate rotation block (if present)
    if goal.Rotation != nil {
        if goal.Requirement.ProgressMode != domain.ProgressModeRelative {
            return errors.New("rotation requires progressMode 'relative'")
        }
        if goal.Rotation.Type != "global" {
            return fmt.Errorf("unsupported rotation type '%s' (must be 'global')", goal.Rotation.Type)
        }
        if goal.Rotation.Schedule != "daily" &&
           goal.Rotation.Schedule != "weekly" &&
           goal.Rotation.Schedule != "monthly" {
            return fmt.Errorf("unsupported rotation schedule '%s' (must be 'daily', 'weekly', or 'monthly')",
                goal.Rotation.Schedule)
        }
    }

    // Validate requirement
    if goal.Requirement.StatCode == "" {
        return errors.New("statCode cannot be empty")
    }
    if goal.Requirement.Operator != ">=" {
        return fmt.Errorf("unsupported operator '%s' (only '>=' supported)", goal.Requirement.Operator)
    }
    if goal.Requirement.TargetValue <= 0 {
        return errors.New("targetValue must be positive")
    }

    // Validate reward
    if goal.Reward.Type != "ITEM" && goal.Reward.Type != "WALLET" {
        return fmt.Errorf("unsupported reward type '%s' (only 'ITEM' or 'WALLET' allowed)", goal.Reward.Type)
    }
    if goal.Reward.RewardID == "" {
        return errors.New("rewardId cannot be empty")
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

## Default Assignment Strategy (M3)

### Lazy Materialization Performance Optimization

**M3 Phase 9 Implementation:** The system uses **lazy materialization** to optimize player initialization performance. Instead of creating database rows for ALL goals (which could be 500+ goals), it only creates rows for goals marked with `defaultAssigned = true`.

**Performance Benefits:**
- **50x reduction** in database rows during player initialization
- **First login:** Creates 10 rows instead of 500 rows (~20ms vs ~5,000ms)
- **Subsequent logins:** Fast-path query returns active goals only (~5ms)
- **Database load:** 98% reduction in I/O during player onboarding

**How It Works:**

1. **Default-assigned goals** (`defaultAssigned = true`):
   - Created during `/initialize` endpoint on first login
   - Set with `is_active = true` immediately
   - Receive event updates from event processor
   - Typically 5-10 beginner/tutorial goals

2. **Non-default goals** (`defaultAssigned = false`):
   - NOT created during initialization
   - Created later when user manually activates them via `SetGoalActive()` endpoint
   - Receive event updates only after activation
   - Typically 490+ intermediate/advanced goals

3. **Event processing compatibility:**
   - Event processor uses UPDATE-only queries with `WHERE is_active = true`
   - Events for inactive goals → UPDATE affects 0 rows (silent no-op)
   - Events for goals without DB rows → UPDATE affects 0 rows (no error)
   - No performance regression, no race conditions

### Recommended Distribution

| Goal Category | `defaultAssigned` Value | Quantity | Purpose |
|---------------|-------------------------|----------|---------|
| Tutorial goals | `true` | 3-5 | New player onboarding |
| Beginner goals | `true` | 2-5 | First progression steps |
| Intermediate goals | `false` | 50-100 | User discovers and activates manually |
| Advanced goals | `false` | 400+ | Unlocked after progression |
| **Total** | **5-10 default, 490+ manual** | **500+** | **50x performance improvement** |

### Example Configuration Strategy

```json
{
  "challenges": [
    {
      "challengeId": "onboarding",
      "name": "New Player Experience",
      "goals": [
        {
          "goalId": "complete-tutorial",
          "defaultAssigned": true  // ← Auto-assigned (1/10)
        },
        {
          "goalId": "reach-level-5",
          "defaultAssigned": true  // ← Auto-assigned (2/10)
        },
        {
          "goalId": "daily-login",
          "defaultAssigned": true  // ← Auto-assigned (3/10)
        }
        // ... 7 more default goals
      ]
    },
    {
      "challengeId": "advanced-challenges",
      "name": "Expert Challenges",
      "goals": [
        {
          "goalId": "defeat-100-enemies",
          "defaultAssigned": false  // ← Manual activation (1/490)
        },
        {
          "goalId": "complete-nightmare-mode",
          "defaultAssigned": false  // ← Manual activation (2/490)
        }
        // ... 488 more manual-activation goals
      ]
    }
  ]
}
```

**Key Insight:** Set `defaultAssigned = true` only for the minimal set of goals that ALL new players should start with. This maximizes performance while maintaining good UX.

---

## Config Change Behavior

### Scenario 1: Goal Target Value Changes

**Before:**
```json
{
  "goalId": "kill-10-snowmen",
  "requirement": { "statCode": "snowman_kills", "targetValue": 10, "progressMode": "absolute" }
}
```

**After:**
```json
{
  "goalId": "kill-10-snowmen",
  "requirement": { "statCode": "snowman_kills", "targetValue": 20, "progressMode": "absolute" }
}
```

**User has progress: 15 snowmen killed**

**API Response:**
```json
{
  "goalId": "kill-10-snowmen",
  "progress": 15,
  "requirement": { "targetValue": 20 },
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
