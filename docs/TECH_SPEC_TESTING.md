# Technical Specification: Testing Strategy

**Version:** 1.0
**Date:** 2025-10-15
**Parent:** [TECH_SPEC_M1.md](./TECH_SPEC_M1.md)

## Table of Contents
1. [Testing Philosophy](#testing-philosophy)
2. [Unit Testing](#unit-testing)
3. [Integration Testing](#integration-testing)
4. [End-to-End Testing](#end-to-end-testing)
5. [Performance Testing](#performance-testing)
6. [Test Data and Fixtures](#test-data-and-fixtures)

---

## Testing Philosophy

### Testing Principles

1. **Test-Driven Development (TDD)**: Write tests before implementation
2. **Interface-Based Mocking**: Use interfaces for all external dependencies
3. **Fast Feedback**: Unit tests run in <1 second, integration tests in <10 seconds
4. **Realistic Testing**: Integration tests against real AGS services from start
5. **Coverage Target**: **Aim for 80% code coverage using unit tests** for all packages

### Coverage Target Philosophy

**Why 80%?**
- Industry standard for production-quality code
- Balances thorough testing with diminishing returns
- 60-70%: Good, but misses edge cases
- 70-80%: Very good, comprehensive coverage
- **80%+: Excellent** ← Our target
- 90%+: Overkill, requires mocking trivial code

**Focus Areas:**
- All business logic functions
- Error handling paths
- Edge cases and boundary conditions
- State transitions (e.g., goal status changes)

**What NOT to Over-Test:**
- Trivial getters/setters
- Pure data structures without logic
- Third-party library wrappers (test integration, not the library)
- Database error scenarios (covered by integration tests)

### Test Pyramid

```
           E2E Tests
           (5 tests)
         /───────────\
        Integration Tests
         (20 tests)
      /─────────────────\
         Unit Tests
        (100+ tests)
   /───────────────────────\
```

**Distribution:**
- **Unit Tests (80%)**: Fast, isolated, mock all dependencies
- **Integration Tests (15%)**: Test against docker-compose services
- **E2E Tests (5%)**: Full flow against deployed AGS Extend environment

---

## Unit Testing

### Framework

**Tool:** [testify](https://github.com/stretchr/testify)

```bash
go get github.com/stretchr/testify
```

**Features:**
- `assert`: Assertion functions
- `mock`: Mock object generation
- `suite`: Test suite support

### Test Structure

```go
// extend-challenge-service/internal/service/challenge_service_test.go

package service

import (
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
)

// Test naming: Test<FunctionName>_<Scenario>
func TestClaimReward_Success(t *testing.T) {
    // Arrange
    mockRepo := new(MockGoalRepository)
    mockCache := new(MockGoalCache)
    mockClient := new(MockRewardClient)

    service := NewChallengeService(mockRepo, mockCache, mockClient)

    // Setup mocks
    mockRepo.On("GetProgress", "user123", "goal456").Return(&domain.UserGoalProgress{
        UserID:  "user123",
        GoalID:  "goal456",
        Status:  "completed",
        ClaimedAt: nil,
    }, nil)

    mockCache.On("GetGoalByID", "goal456").Return(&domain.Goal{
        ID: "goal456",
        Reward: domain.Reward{
            Type:     "ITEM",
            RewardID: "sword",
            Quantity: 1,
        },
        Prerequisites: []string{},
    })

    mockClient.On("GrantReward", "user123", mock.Anything).Return(nil)
    mockRepo.On("MarkAsClaimed", "user123", "goal456").Return(nil)

    // Act
    err := service.ClaimReward(context.Background(), "user123", "challenge789", "goal456")

    // Assert
    assert.NoError(t, err)
    mockClient.AssertExpectations(t)
    mockRepo.AssertExpectations(t)
}

func TestClaimReward_AlreadyClaimed(t *testing.T) {
    // Arrange
    mockRepo := new(MockGoalRepository)
    mockCache := new(MockGoalCache)
    mockClient := new(MockRewardClient)

    service := NewChallengeService(mockRepo, mockCache, mockClient)

    claimedAt := time.Now()
    mockRepo.On("GetProgress", "user123", "goal456").Return(&domain.UserGoalProgress{
        Status:    "claimed",
        ClaimedAt: &claimedAt,
    }, nil)

    // Act
    err := service.ClaimReward(context.Background(), "user123", "challenge789", "goal456")

    // Assert
    assert.Error(t, err)
    assert.ErrorIs(t, err, ErrAlreadyClaimed)
}
```

### Mock Interfaces

#### MockGoalRepository

```go
// extend-challenge-common/pkg/repository/mock_repository.go

package repository

import (
    "github.com/stretchr/testify/mock"
    "github.com/example/extend-challenge-common/pkg/domain"
)

type MockGoalRepository struct {
    mock.Mock
}

func (m *MockGoalRepository) GetProgress(userID, goalID string) (*domain.UserGoalProgress, error) {
    args := m.Called(userID, goalID)
    if args.Get(0) == nil {
        return nil, args.Error(1)
    }
    return args.Get(0).(*domain.UserGoalProgress), args.Error(1)
}

func (m *MockGoalRepository) GetUserProgress(userID string) ([]*domain.UserGoalProgress, error) {
    args := m.Called(userID)
    return args.Get(0).([]*domain.UserGoalProgress), args.Error(1)
}

func (m *MockGoalRepository) UpsertProgress(progress *domain.UserGoalProgress) error {
    args := m.Called(progress)
    return args.Error(0)
}

func (m *MockGoalRepository) MarkAsClaimed(userID, goalID string) error {
    args := m.Called(userID, goalID)
    return args.Error(0)
}

func (m *MockGoalRepository) BeginTx() (TxRepository, error) {
    args := m.Called()
    return args.Get(0).(TxRepository), args.Error(1)
}
```

#### MockGoalCache

```go
// extend-challenge-common/pkg/cache/mock_cache.go

package cache

import (
    "github.com/stretchr/testify/mock"
    "github.com/example/extend-challenge-common/pkg/domain"
)

type MockGoalCache struct {
    mock.Mock
}

func (m *MockGoalCache) GetGoalByID(goalID string) *domain.Goal {
    args := m.Called(goalID)
    if args.Get(0) == nil {
        return nil
    }
    return args.Get(0).(*domain.Goal)
}

func (m *MockGoalCache) GetGoalsByStatCode(statCode string) []*domain.Goal {
    args := m.Called(statCode)
    return args.Get(0).([]*domain.Goal)
}

func (m *MockGoalCache) GetChallengeByChallengeID(challengeID string) *domain.Challenge {
    args := m.Called(challengeID)
    if args.Get(0) == nil {
        return nil
    }
    return args.Get(0).(*domain.Challenge)
}

func (m *MockGoalCache) GetAllChallenges() []*domain.Challenge {
    args := m.Called()
    return args.Get(0).([]*domain.Challenge)
}

func (m *MockGoalCache) Reload() error {
    args := m.Called()
    return args.Error(0)
}
```

#### MockRewardClient

```go
// extend-challenge-common/pkg/client/mock_client.go

package client

import (
    "github.com/stretchr/testify/mock"
    "github.com/example/extend-challenge-common/pkg/domain"
)

type MockRewardClient struct {
    mock.Mock
}

func (m *MockRewardClient) GrantItemReward(userID, itemID string, quantity int) error {
    args := m.Called(userID, itemID, quantity)
    return args.Error(0)
}

func (m *MockRewardClient) GrantWalletReward(userID, currencyCode string, amount int) error {
    args := m.Called(userID, currencyCode, amount)
    return args.Error(0)
}

func (m *MockRewardClient) GrantReward(userID string, reward domain.Reward) error {
    args := m.Called(userID, reward)
    return args.Error(0)
}
```

### Config Validation Tests (Phase 5.2.2a)

**New in Phase 5.2.2a**: Tests for goal type validation, default behavior, and backward compatibility.

#### Goal Type Validation Tests

Located in: `extend-challenge-common/pkg/config/validator_test.go`

**Test 1: Valid Goal Types**

```go
func TestGoalTypeValidation_ValidTypes(t *testing.T) {
    tests := []struct {
        name     string
        goalType domain.GoalType
        wantErr  bool
    }{
        {
            name:     "absolute type is valid",
            goalType: domain.GoalTypeAbsolute,
            wantErr:  false,
        },
        {
            name:     "increment type is valid",
            goalType: domain.GoalTypeIncrement,
            wantErr:  false,
        },
        {
            name:     "daily type is valid",
            goalType: domain.GoalTypeDaily,
            wantErr:  false,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            goal := &domain.Goal{
                ID:          "test-goal",
                Name:        "Test Goal",
                Description: "Test",
                Type:        tt.goalType,
                Requirement: domain.Requirement{
                    StatCode:    "test_stat",
                    Operator:    ">=",
                    TargetValue: 10,
                },
                Reward: domain.Reward{
                    Type:     "WALLET",
                    RewardID: "GOLD",
                    Quantity: 100,
                },
            }

            validator := NewValidator()
            err := validator.ValidateGoal(goal)

            if tt.wantErr {
                assert.Error(t, err)
            } else {
                assert.NoError(t, err)
            }
        })
    }
}
```

**Test 2: Invalid Goal Types**

```go
func TestGoalTypeValidation_InvalidTypes(t *testing.T) {
    tests := []struct {
        name     string
        goalType domain.GoalType
    }{
        {
            name:     "unknown type rejected",
            goalType: "unknown",
        },
        {
            name:     "weekly type rejected (not supported in M1)",
            goalType: "weekly",
        },
        {
            name:     "streak type rejected (not supported in M1)",
            goalType: "streak",
        },
        {
            name:     "typo rejected",
            goalType: "abslute", // typo
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            goal := &domain.Goal{
                ID:          "test-goal",
                Name:        "Test Goal",
                Type:        tt.goalType,
                Requirement: domain.Requirement{
                    StatCode:    "test_stat",
                    Operator:    ">=",
                    TargetValue: 10,
                },
                Reward: domain.Reward{
                    Type:     "WALLET",
                    RewardID: "GOLD",
                    Quantity: 100,
                },
            }

            validator := NewValidator()
            err := validator.ValidateGoal(goal)

            assert.Error(t, err)
            assert.Contains(t, err.Error(), "invalid goal type")
        })
    }
}
```

**Test 3: Default Type Behavior**

```go
func TestGoalTypeValidation_DefaultBehavior(t *testing.T) {
    // Goal without type field
    goal := &domain.Goal{
        ID:          "test-goal",
        Name:        "Test Goal",
        Description: "Goal without explicit type",
        // Type field omitted
        Requirement: domain.Requirement{
            StatCode:    "test_stat",
            Operator:    ">=",
            TargetValue: 10,
        },
        Reward: domain.Reward{
            Type:     "WALLET",
            RewardID: "GOLD",
            Quantity: 100,
        },
    }

    validator := NewValidator()
    err := validator.ValidateGoal(goal)

    // Should pass validation
    assert.NoError(t, err)

    // Should default to absolute
    assert.Equal(t, domain.GoalTypeAbsolute, goal.Type,
        "Empty type field should default to 'absolute'")
}
```

**Test 4: Backward Compatibility**

```go
func TestGoalTypeValidation_BackwardCompatibility(t *testing.T) {
    // Simulate old config file without type field
    configJSON := `{
        "challenges": [
            {
                "id": "old-challenge",
                "name": "Old Challenge",
                "description": "From before type field existed",
                "goals": [
                    {
                        "id": "old-goal",
                        "name": "Kill 10 Enemies",
                        "description": "Old-style goal without type",
                        "requirement": {
                            "stat_code": "enemy_kills",
                            "operator": ">=",
                            "target_value": 10
                        },
                        "reward": {
                            "type": "WALLET",
                            "reward_id": "GOLD",
                            "quantity": 100
                        },
                        "prerequisites": []
                    }
                ]
            }
        ]
    }`

    // Load config
    loader := NewConfigLoader()
    config, err := loader.LoadFromJSON([]byte(configJSON))

    // Should load successfully
    assert.NoError(t, err)
    assert.NotNil(t, config)
    assert.Len(t, config.Challenges, 1)

    // Verify default type applied
    goal := config.Challenges[0].Goals[0]
    assert.Equal(t, domain.GoalTypeAbsolute, goal.Type,
        "Old config without type field should default to 'absolute'")

    // Should pass validation
    validator := NewValidator()
    err = validator.ValidateConfig(config)
    assert.NoError(t, err, "Old config should pass validation after defaulting")
}
```

**Test 5: Daily Flag Validation**

```go
func TestGoalTypeValidation_DailyFlagConstraints(t *testing.T) {
    tests := []struct {
        name    string
        goal    *domain.Goal
        wantErr bool
        errMsg  string
    }{
        {
            name: "daily flag valid with increment type",
            goal: &domain.Goal{
                ID:          "daily-login",
                Name:        "Daily Login",
                Type:        domain.GoalTypeIncrement,
                Daily:       true,
                Requirement: domain.Requirement{
                    StatCode:    "login_count",
                    Operator:    ">=",
                    TargetValue: 7,
                },
                Reward: domain.Reward{Type: "WALLET", RewardID: "GOLD", Quantity: 100},
            },
            wantErr: false,
        },
        {
            name: "daily flag invalid with absolute type",
            goal: &domain.Goal{
                ID:          "invalid-daily",
                Name:        "Invalid Daily Goal",
                Type:        domain.GoalTypeAbsolute,
                Daily:       true, // Invalid combination
                Requirement: domain.Requirement{
                    StatCode:    "kills",
                    Operator:    ">=",
                    TargetValue: 100,
                },
                Reward: domain.Reward{Type: "WALLET", RewardID: "GOLD", Quantity: 100},
            },
            wantErr: true,
            errMsg:  "daily flag can only be true for increment type goals",
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            validator := NewValidator()
            err := validator.ValidateGoal(tt.goal)

            if tt.wantErr {
                assert.Error(t, err)
                assert.Contains(t, err.Error(), tt.errMsg)
            } else {
                assert.NoError(t, err)
            }
        })
    }
}
```

**Test 6: All Test Fixtures Updated**

```go
func TestFixtures_AllHaveTypeField(t *testing.T) {
    // Ensure all test fixtures include explicit type field
    // This test would fail during Phase 5.2.2a if any fixture is missing the type field

    fixtures := []struct {
        name string
        goal *domain.Goal
    }{
        {"TestGoal1", TestGoal1()},
        {"TestGoal2", TestGoal2()},
        {"TestGoalAbsolute", TestGoalAbsolute()},
        {"TestGoalIncrement", TestGoalIncrement()},
        {"TestGoalDaily", TestGoalDaily()},
    }

    for _, fixture := range fixtures {
        t.Run(fixture.name, func(t *testing.T) {
            assert.NotEmpty(t, fixture.goal.Type,
                "Fixture %s must have explicit type field for clarity", fixture.name)

            // Verify type is valid
            validTypes := []domain.GoalType{
                domain.GoalTypeAbsolute,
                domain.GoalTypeIncrement,
                domain.GoalTypeDaily,
            }
            assert.Contains(t, validTypes, fixture.goal.Type,
                "Fixture %s has invalid type: %s", fixture.name, fixture.goal.Type)
        })
    }
}
```

#### Coverage Expectations for Phase 5.2.2a

**Test Count:**
- Valid type tests: 3 (absolute, increment, daily)
- Invalid type tests: 4 (unknown, weekly, streak, typo)
- Default behavior test: 1
- Backward compatibility test: 1
- Daily flag validation: 2 (valid + invalid)
- Fixture validation: 5+ fixtures

**Total: ~16 new test cases**

**Time Estimate:** 30-60 minutes (comprehensive test suite as per Q6)

**Coverage Impact:**
- Config validator: 90%+ coverage (high priority)
- Domain models: 100% coverage (trivial, but complete)
- Test fixtures: All updated with explicit `type` field

### Test Coverage

#### Generate Coverage Report

```bash
# Run tests with coverage
cd extend-challenge-service
go test ./... -coverprofile=coverage.out

# View coverage report
go tool cover -html=coverage.out

# Check coverage percentage
go tool cover -func=coverage.out | grep total
```

#### Coverage Targets

**Project-Wide Minimum: 80% using unit tests**

| Package | Target | Type | Reason |
|---------|--------|------|--------|
| `domain/` | 100% | Unit | Simple models, easy to test |
| `errors/` | 100% | Unit | Error constructors, critical |
| `service/` | 85%+ | Unit | Business logic (critical) |
| `handler/` | 80%+ | Unit | HTTP handlers |
| `cache/` | 85%+ | Unit | Cache logic and validation |
| `client/` | 80%+ | Unit | AGS integration (mocked) |
| `config/` | 85%+ | Unit | Config loading and validation |
| `repository/` | 80%+ | Integration | Database operations (real DB) |

**Measurement:**
```bash
# Check coverage across all packages
go test ./... -coverprofile=coverage.out
go tool cover -func=coverage.out | grep total

# Target: 80.0% or higher
```

### Running Unit Tests

```bash
# Run all unit tests
make test

# Run specific package
go test ./internal/service/...

# Run specific test
go test -run TestClaimReward_Success ./internal/service/...

# Run with verbose output
go test -v ./...

# Run with race detection
go test -race ./...
```

---

## Code Linting

### Linter Tool

**Tool:** [golangci-lint](https://golangci-lint.run/)

```bash
# Install
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

# Run
golangci-lint run

# Run with auto-fix
golangci-lint run --fix
```

**Features:**
- Aggregates 50+ linters in one tool
- Fast parallel execution
- Structured output for CI/CD
- Configurable via `.golangci.yml`
- Catches common Go issues automatically

### Linter Configuration

Create `.golangci.yml` in project root:

```yaml
# .golangci.yml
run:
  timeout: 5m
  tests: true
  skip-dirs:
    - vendor
    - proto  # Generated proto files

linters:
  enable:
    # Critical: Prevent bugs
    - errcheck       # Unchecked errors
    - gosec          # Security issues
    - govet          # Go vet issues
    - staticcheck    # Static analysis bugs
    - typecheck      # Type errors

    # Code quality
    - gosimple       # Simplification suggestions
    - ineffassign    # Unused assignments
    - unused         # Unused code
    - unconvert      # Unnecessary type conversions
    - unparam        # Unused function parameters

    # Style consistency
    - gofmt          # Code formatting
    - goimports      # Import formatting
    - misspell       # Spelling errors
    - whitespace     # Whitespace errors

    # Early return style enforcement
    - nestif         # Deep nested if statements (max 3 levels)

    # Performance
    - prealloc       # Slice preallocation

    # Error handling
    - goerr113       # Error wrapping

  disable:
    - lll            # Line length (not critical)
    - gocyclo        # Cyclomatic complexity (covered by nestif)
    - funlen         # Function length (can be noisy)

linters-settings:
  nestif:
    # Enforce early return style by limiting nesting
    # Per CLAUDE.md: "Always write functions in 'early return' style"
    min-complexity: 3  # Flag if-else chains with 3+ levels

  errcheck:
    # Don't ignore errors
    check-type-assertions: true
    check-blank: true

  gosec:
    excludes:
      - G104  # Unhandled errors (covered by errcheck)

  govet:
    check-shadowing: true

  staticcheck:
    checks: ["all"]

issues:
  exclude-rules:
    # Exclude some linters from running on tests
    - path: _test\.go
      linters:
        - gosec
        - errcheck  # Tests often skip error checks intentionally

  max-issues-per-linter: 0
  max-same-issues: 0

output:
  format: colored-line-number
  print-issued-lines: true
  print-linter-name: true
```

### Linting Targets

#### Project-Wide Standards

| Rule | Linter | Enforcement | Reason |
|------|--------|-------------|--------|
| Early return style | `nestif` | **MUST** | Per CLAUDE.md - avoid nested conditionals |
| Unchecked errors | `errcheck` | **MUST** | Prevent panics and bugs |
| Nil pointer checks | `staticcheck` | **MUST** | Prevent nil dereference panics |
| Security issues | `gosec` | **MUST** | Prevent vulnerabilities |
| Code formatting | `gofmt` | **MUST** | Consistent style |
| Import formatting | `goimports` | **MUST** | Organized imports |
| Unused code | `unused` | SHOULD | Code cleanliness |
| Spelling errors | `misspell` | SHOULD | Professional code |

### Running Linter

```bash
# Run linter on all packages
golangci-lint run ./...

# Run with auto-fix for simple issues
golangci-lint run --fix ./...

# Run on specific package
golangci-lint run ./pkg/buffered/...

# Run in CI mode (exit 1 on any issue)
golangci-lint run --out-format github-actions

# Generate report
golangci-lint run --out-format json > lint-report.json
```

### Integration with Workflow

#### Local Development

```bash
# Before committing code
make lint

# Fix auto-fixable issues
make lint-fix
```

Add to `Makefile`:

```makefile
.PHONY: lint
lint:
	@echo "Running golangci-lint..."
	golangci-lint run ./...

.PHONY: lint-fix
lint-fix:
	@echo "Running golangci-lint with auto-fix..."
	golangci-lint run --fix ./...

.PHONY: test-all
test-all: lint test
	@echo "All checks passed!"
```

#### Pre-commit Hook

Create `.git/hooks/pre-commit` (or use `pre-commit` framework):

```bash
#!/bin/bash
# Pre-commit hook to run linter

echo "Running golangci-lint..."
golangci-lint run --new-from-rev=HEAD~1

if [ $? -ne 0 ]; then
    echo "❌ Linting failed. Please fix issues before committing."
    echo "Run: golangci-lint run --fix"
    exit 1
fi

echo "✅ Linting passed!"
```

#### CI/CD Pipeline

Add to GitHub Actions (`.github/workflows/lint.yml`):

```yaml
name: Lint

on:
  pull_request:
  push:
    branches: [main, master]

jobs:
  golangci:
    name: golangci-lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: golangci-lint
        uses: golangci/golangci-lint-action@v3
        with:
          version: latest
          args: --timeout=5m
```

### Common Issues Caught by Linter

#### 1. Early Return Style Violations (nestif)

**Before (Violation):**
```go
func ProcessData(data *Data) error {
    if data != nil {
        if data.Valid() {
            // Process data
            return nil
        }
    }
    return errors.New("invalid data")
}
```

**After (Fixed):**
```go
func ProcessData(data *Data) error {
    if data == nil {
        return errors.New("data cannot be nil")
    }

    if !data.Valid() {
        return errors.New("invalid data")
    }

    // Process data
    return nil
}
```

#### 2. Unchecked Errors (errcheck)

**Before (Violation):**
```go
func SaveData(data *Data) {
    json.Marshal(data)  // Error ignored
}
```

**After (Fixed):**
```go
func SaveData(data *Data) error {
    _, err := json.Marshal(data)
    if err != nil {
        return fmt.Errorf("failed to marshal data: %w", err)
    }
    return nil
}
```

#### 3. Nil Pointer Checks (staticcheck)

**Before (Violation):**
```go
func UpdateProgress(progress *UserGoalProgress) error {
    key := fmt.Sprintf("%s:%s", progress.UserID, progress.GoalID)  // Panic if nil
    // ...
}
```

**After (Fixed):**
```go
func UpdateProgress(progress *UserGoalProgress) error {
    if progress == nil {
        return errors.New("progress cannot be nil")
    }

    key := fmt.Sprintf("%s:%s", progress.UserID, progress.GoalID)
    // ...
}
```

### Linter Reports

#### Example Output

```bash
$ golangci-lint run ./...

pkg/buffered/buffered_repository.go:127:1: `UpdateProgress` - too many nested if statements (nestif)
pkg/buffered/buffered_repository.go:135:5: Error return value is not checked (errcheck)
pkg/service/challenge_service.go:45:1: nil pointer dereference (staticcheck)
```

#### Interpreting Results

- **Line number**: Exact location of issue
- **Linter name**: Which rule caught it (in parentheses)
- **Description**: What the problem is

### Benefits

1. **Automated Code Review**: Catches issues before human review
2. **Consistent Standards**: Enforces project coding conventions automatically
3. **Early Detection**: Find bugs during development, not production
4. **CI/CD Integration**: Prevent bad code from merging
5. **Learning Tool**: Teaches developers Go best practices

### Coverage + Linting Strategy

**Complete Quality Check:**
```bash
# 1. Run tests with coverage
go test ./... -coverprofile=coverage.out

# 2. Check coverage meets 80% target
go tool cover -func=coverage.out | grep total

# 3. Run linter
golangci-lint run ./...

# 4. Only pass if both succeed
# - Coverage ≥ 80%
# - Zero linter issues
```

Add to CI:
```yaml
- name: Run Tests with Coverage
  run: |
    go test ./... -coverprofile=coverage.out
    COVERAGE=$(go tool cover -func=coverage.out | grep total | awk '{print $3}' | sed 's/%//')
    echo "Coverage: $COVERAGE%"
    if (( $(echo "$COVERAGE < 80" | bc -l) )); then
      echo "❌ Coverage $COVERAGE% is below 80% target"
      exit 1
    fi

- name: Run Linter
  run: golangci-lint run ./...
```

---

## Integration Testing

### Overview (Phase 6.7 Decisions)

Integration tests for Phase 6.7 use **in-process testing** approach:

- **Test Architecture:** In-process gRPC server creation (Decision AC1)
- **Infrastructure:** docker-compose for PostgreSQL only (Decision IQ1/AC1)
- **Database Migrations:** golang-migrate Go library (Decision IQ2)
- **Authentication:** Disabled for Phase 6.7 (Decision AC2)
- **Reward Client:** Mock RewardClient with assertions (Decision IQ4)
- **Test Data:** Pre-populated database (Decision IQ5)
- **Test Data Source:** Same challenges.json as production (Decision AC3)
- **Isolation:** Truncate tables before each test (Decision IQ6)
- **Execution:** Serial (non-parallel) tests (Decision IQ7)
- **Error Coverage:** Test all error scenarios (Decision IQ8)

**Key Principle:** Tests create the gRPC server in-process with injected dependencies (MockRewardClient, test DB), enabling full control over behavior and comprehensive error testing. This is a component/integration hybrid approach, not pure black-box E2E testing (which is deferred to Phase 8).

**Scope Note:** Phase 6.7 tests the **gRPC layer only** (business logic, data persistence, error handling). The HTTP layer (gRPC-Gateway transcoding, JSON serialization, HTTP status codes) is NOT tested in integration tests. Rationale: gRPC-Gateway is well-tested generated code with low bug probability. HTTP-specific tests can be added in Phase 7 if needed. See BRAINSTORM.md "gRPC-Gateway HTTP Layer Testing" for detailed analysis.

### Setup

Integration tests use **in-process server** with PostgreSQL in docker-compose.

**Note:** The `docker-compose.test.yml` file is localized in the `extend-challenge-service/` directory for better modularity.

```yaml
# extend-challenge-service/docker-compose.test.yml
version: '3.8'

services:
  postgres-test:
    image: postgres:15-alpine
    container_name: extend-challenge-service-test-db
    environment:
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
      POSTGRES_DB: testdb
    ports:
      - "5433:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U testuser"]
      interval: 5s
      timeout: 5s
      retries: 5
    tmpfs:
      - /var/lib/postgresql/data  # In-memory for faster tests
```

**Usage:**
```bash
# Navigate to service directory
cd extend-challenge-service

# Start PostgreSQL (or use make target)
docker-compose -f docker-compose.test.yml up -d postgres-test

# Wait for healthy
docker-compose -f docker-compose.test.yml ps

# Run integration tests
go test -v ./tests/integration/... -p 1

# Cleanup
docker-compose -f docker-compose.test.yml down -v
```

**Using Makefile targets (recommended):**
```bash
cd extend-challenge-service

# Run all integration tests (setup + run + teardown)
make test-integration

# Or run steps individually
make test-integration-setup    # Start database
make test-integration-run      # Run tests only
make test-integration-teardown # Stop database
```

### Database Migration Setup (Decision IQ2)

Integration tests use golang-migrate Go library to apply migrations:

```go
// tests/integration/setup_test.go

import (
    "database/sql"
    "testing"

    "github.com/golang-migrate/migrate/v4"
    "github.com/golang-migrate/migrate/v4/database/postgres"
    _ "github.com/golang-migrate/migrate/v4/source/file"
)

// applyMigrations applies database migrations from filesystem
func applyMigrations(t *testing.T, db *sql.DB) {
    driver, err := postgres.WithInstance(db, &postgres.Config{})
    if err != nil {
        t.Fatalf("Failed to create migrate driver: %v", err)
    }

    // Path relative to test file location
    m, err := migrate.NewWithDatabaseInstance(
        "file://../../extend-challenge-service/migrations",
        "testdb",
        driver,
    )
    if err != nil {
        t.Fatalf("Failed to create migrate instance: %v", err)
    }

    // Apply all up migrations
    if err := m.Up(); err != nil && err != migrate.ErrNoChange {
        t.Fatalf("Failed to apply migrations: %v", err)
    }

    t.Log("Migrations applied successfully")
}

// rollbackMigrations rolls back all migrations (cleanup)
func rollbackMigrations(t *testing.T, db *sql.DB) {
    driver, err := postgres.WithInstance(db, &postgres.Config{})
    if err != nil {
        t.Logf("Warning: Failed to create migrate driver for rollback: %v", err)
        return
    }

    m, err := migrate.NewWithDatabaseInstance(
        "file://../../extend-challenge-service/migrations",
        "testdb",
        driver,
    )
    if err != nil {
        t.Logf("Warning: Failed to create migrate instance for rollback: %v", err)
        return
    }

    // Rollback all migrations
    if err := m.Down(); err != nil && err != migrate.ErrNoChange {
        t.Logf("Warning: Failed to rollback migrations: %v", err)
    }
}
```

### Authentication (Decision AC2 - Updated Implementation)

**Phase 6.7 uses a simplified test auth interceptor instead of disabling auth completely.**

The in-process server uses a test auth interceptor that extracts user_id and namespace from gRPC metadata (instead of JWT validation). This enables testing auth flow without JWT complexity.

```go
// testAuthInterceptor extracts user_id/namespace from gRPC metadata
func testAuthInterceptor(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if ok {
        if userIDs := md.Get("user-id"); len(userIDs) > 0 {
            ctx = context.WithValue(ctx, serviceCommon.ContextKeyUserID, userIDs[0])
        }
        if namespaces := md.Get("namespace"); len(namespaces) > 0 {
            ctx = context.WithValue(ctx, serviceCommon.ContextKeyNamespace, namespaces[0])
        }
    }
    return handler(ctx, req)
}

// Create server with test auth interceptor
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(testAuthInterceptor),
)
```

**Test Helper - Create Auth Context:**
```go
// createAuthContext creates a context with user ID and namespace in gRPC metadata
func createAuthContext(userID, namespace string) context.Context {
    md := metadata.Pairs(
        "user-id", userID,
        "namespace", namespace,
    )
    return metadata.NewOutgoingContext(context.Background(), md)
}

// Usage in tests
ctx := createAuthContext("test-user-123", "test-namespace")
resp, err := client.GetUserChallenges(ctx, req)
```

**Rationale:**
- ✅ **Better than no auth**: Enables testing auth flow (user_id extraction from context)
- ✅ **Simpler than JWT**: Avoids JWT token generation and validation complexity
- ✅ **Tests auth errors**: Can test missing auth context scenarios
- ✅ **More realistic**: Simulates actual auth interceptor behavior

**Benefits over Completely Disabled Auth:**
1. Tests verify that user_id is correctly extracted from context
2. Tests verify user isolation (different users can't access each other's data)
3. Tests verify missing auth context returns Unauthenticated error
4. Service code paths match production (context extraction works the same)

**Note:** Full JWT validation is tested at unit test level (auth interceptor tests). True E2E testing with real JWT tokens can be added in Phase 7+.

### Test Data Pre-population (Decision IQ5)

Integration tests use pre-populated database for deterministic testing:

```go
// tests/integration/fixtures.go

// seedTestData inserts test progress data directly into database
func seedTestData(t *testing.T, db *sql.DB) {
    // Insert completed goal
    _, err := db.Exec(`
        INSERT INTO user_goal_progress
        (user_id, goal_id, challenge_id, namespace, progress, status, completed_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
    `, "test-user-123", "kill-10-snowmen", "winter-challenge-2025", "test-namespace", 10, "completed", time.Now())

    if err != nil {
        t.Fatalf("Failed to seed test data: %v", err)
    }

    // Insert in-progress goal
    _, err = db.Exec(`
        INSERT INTO user_goal_progress
        (user_id, goal_id, challenge_id, namespace, progress, status)
        VALUES ($1, $2, $3, $4, $5, $6)
    `, "test-user-123", "reach-level-5", "winter-challenge-2025", "test-namespace", 3, "in_progress")

    if err != nil {
        t.Fatalf("Failed to seed test data: %v", err)
    }
}
```

### Test Data Isolation (Decision IQ6)

Truncate tables before each test for clean state:

```go
// tests/integration/cleanup.go

// truncateTables clears all test data for isolation
func truncateTables(t *testing.T, db *sql.DB) {
    _, err := db.Exec("TRUNCATE user_goal_progress")
    if err != nil {
        t.Fatalf("Failed to truncate tables: %v", err)
    }
}

// setupTest prepares clean database state for each test
func setupTest(t *testing.T) *sql.DB {
    db := connectTestDB(t)
    truncateTables(t, db)
    return db
}
```

### Mock RewardClient (Decision IQ4)

Use mock RewardClient with testify assertions:

```go
// extend-challenge-common/pkg/client/mock_reward_client.go

package client

import (
    "context"
    "github.com/stretchr/testify/mock"
    "extend-challenge-common/pkg/domain"
)

// MockRewardClient is a mock implementation for testing
type MockRewardClient struct {
    mock.Mock
}

func (m *MockRewardClient) GrantReward(ctx context.Context, namespace, userID string, reward domain.Reward) error {
    args := m.Called(ctx, namespace, userID, reward)
    return args.Error(0)
}

// NewMockRewardClient creates a new mock reward client
func NewMockRewardClient() *MockRewardClient {
    return &MockRewardClient{}
}
```

**Usage in Integration Tests:**

```go
// Setup mock for claim tests
mockRewardClient := client.NewMockRewardClient()
mockRewardClient.On("GrantReward", mock.Anything, "test-namespace", "test-user-123", mock.Anything).Return(nil)

// Create server with mock
server := createTestServer(db, goalCache, goalRepo, mockRewardClient)

// After test, verify reward was granted
assert.True(t, mockRewardClient.AssertExpectations(t))
```

### Test Structure (In-Process Server)

```go
// extend-challenge-service/tests/integration/setup_test.go

package integration

import (
    "context"
    "database/sql"
    "log/slog"
    "net"
    "os"
    "testing"

    _ "github.com/lib/pq"
    "google.golang.org/grpc"
    "google.golang.org/grpc/test/bufconn"

    "extend-challenge-service/pkg/client"
    pb "extend-challenge-service/pkg/pb"
    "extend-challenge-service/pkg/server"

    commonCache "extend-challenge-common/pkg/cache"
    commonConfig "extend-challenge-common/pkg/config"
    commonRepo "extend-challenge-common/pkg/repository"
)

var (
    testDB *sql.DB
    logger *slog.Logger
)

func TestMain(m *testing.M) {
    // Setup logger
    logger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

    // Connect to test database (docker-compose postgres)
    dbURL := "postgres://testuser:testpass@localhost:5433/testdb?sslmode=disable"
    var err error
    testDB, err = sql.Open("postgres", dbURL)
    if err != nil {
        panic("Failed to connect to test DB: " + err.Error())
    }
    defer testDB.Close()

    // Apply migrations once for all tests
    applyMigrations(testDB)

    // Run all tests (serial execution - Decision IQ7)
    code := m.Run()

    // Cleanup: Rollback migrations
    rollbackMigrations(testDB)

    os.Exit(code)
}

// setupTestServer creates in-process gRPC server with injected dependencies
func setupTestServer(t *testing.T) (*grpc.Server, pb.ServiceClient, *client.MockRewardClient, func()) {
    // 1. Truncate tables for test isolation
    truncateTables(t, testDB)

    // 2. Load challenge config (use same config as production - Decision AC3)
    configPath := "../../config/challenges.json"
    configLoader := commonConfig.NewConfigLoader(configPath, logger)
    challengeConfig, err := configLoader.LoadConfig()
    if err != nil {
        t.Fatalf("Failed to load challenge config: %v", err)
    }

    // 3. Initialize dependencies
    goalCache := commonCache.NewInMemoryGoalCache(challengeConfig, configPath, logger)
    goalRepo := commonRepo.NewPostgresGoalRepository(testDB)
    mockRewardClient := client.NewMockRewardClient()

    // 4. Create ChallengeServiceServer with mocks
    challengeServer := server.NewChallengeServiceServer(
        goalCache,
        goalRepo,
        mockRewardClient,
        testDB,
        "test-namespace",
    )

    // 5. Create in-process gRPC server (no auth interceptors - Decision AC2)
    grpcServer := grpc.NewServer()
    pb.RegisterServiceServer(grpcServer, challengeServer)

    // 6. Create in-memory listener (bufconn) for testing
    const bufSize = 1024 * 1024
    listener := bufconn.Listen(bufSize)

    // 7. Start server in background
    go func() {
        if err := grpcServer.Serve(listener); err != nil {
            t.Logf("Server stopped: %v", err)
        }
    }()

    // 8. Create client connected to in-memory listener
    ctx := context.Background()
    conn, err := grpc.DialContext(ctx, "",
        grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
            return listener.Dial()
        }),
        grpc.WithInsecure(),
    )
    if err != nil {
        t.Fatalf("Failed to dial in-memory server: %v", err)
    }

    client := pb.NewServiceClient(conn)

    // 9. Return server, client, mock, and cleanup function
    cleanup := func() {
        conn.Close()
        grpcServer.Stop()
        listener.Close()
    }

    return grpcServer, client, mockRewardClient, cleanup
}

// Example test using in-process gRPC client
func TestGetChallenges_HappyPath(t *testing.T) {
    // Setup: Create in-process server with mocks
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed test data: completed goal
    seedCompletedGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025")

    // Test: Get challenges
    ctx := context.Background()
    req := &pb.GetChallengesRequest{
        UserId:    "test-user-123",
        Namespace: "test-namespace",
    }

    resp, err := client.GetChallenges(ctx, req)
    assert.NoError(t, err)
    assert.NotNil(t, resp)
    assert.Len(t, resp.Challenges, 2) // winter-challenge-2025 + daily-quests

    // Verify winter-challenge-2025 has completed goal
    winterChallenge := findChallenge(resp.Challenges, "winter-challenge-2025")
    assert.NotNil(t, winterChallenge)
    assert.Len(t, winterChallenge.Goals, 2) // kill-10-snowmen + reach-level-5

    completedGoal := findGoal(winterChallenge.Goals, "kill-10-snowmen")
    assert.NotNil(t, completedGoal)
    assert.Equal(t, "completed", completedGoal.Status)
    assert.Equal(t, int32(10), completedGoal.CurrentProgress)
    assert.Equal(t, int32(10), completedGoal.TargetProgress)

    // MockRewardClient should not be called for GetChallenges
    mockRewardClient.AssertNotCalled(t, "GrantReward")
}

func TestClaimReward_HappyPath(t *testing.T) {
    // Setup: Create in-process server with mocks
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed completed goal
    seedCompletedGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025")

    // Mock reward granting to succeed
    mockRewardClient.On("GrantReward",
        mock.Anything,
        "test-namespace",
        "test-user-123",
        mock.MatchedBy(func(reward domain.Reward) bool {
            return reward.Type == "ITEM" && reward.ItemID == "winter-sword"
        }),
    ).Return(nil)

    // Test: Claim reward
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    resp, err := client.ClaimReward(ctx, req)
    assert.NoError(t, err)
    assert.NotNil(t, resp)
    assert.Equal(t, "claimed", resp.Status)
    assert.NotNil(t, resp.ClaimedAt)

    // Verify reward was granted
    mockRewardClient.AssertExpectations(t)

    // Verify database updated
    var status string
    err = testDB.QueryRow(
        "SELECT status FROM user_goal_progress WHERE user_id = $1 AND goal_id = $2",
        "test-user-123", "kill-10-snowmen",
    ).Scan(&status)
    assert.NoError(t, err)
    assert.Equal(t, "claimed", status)
}

func TestClaimReward_Idempotency(t *testing.T) {
    // Setup
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed already-claimed goal
    seedClaimedGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025")

    // Test: Try to claim again (should fail)
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "ALREADY_CLAIMED")

    // Verify reward was NOT granted
    mockRewardClient.AssertNotCalled(t, "GrantReward")
}
```

### Error Scenario Testing (Decision IQ8 - Test All Errors)

Integration tests use in-process gRPC client to test **all error scenarios**:

```go
// tests/integration/error_scenarios_test.go

// High Priority Errors

func TestError_400_GoalNotCompleted(t *testing.T) {
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed in-progress goal (progress < target)
    seedInProgressGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025", 5, 10)

    // Try to claim incomplete goal
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "GOAL_NOT_COMPLETED")

    // Verify reward was NOT granted
    mockRewardClient.AssertNotCalled(t, "GrantReward")
}

func TestError_409_AlreadyClaimed(t *testing.T) {
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed already-claimed goal
    seedClaimedGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025")

    // Try to claim again
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "ALREADY_CLAIMED")

    // Verify reward was NOT granted (idempotency)
    mockRewardClient.AssertNotCalled(t, "GrantReward")
}

func TestError_404_GoalNotFound(t *testing.T) {
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Try to claim non-existent goal
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "non-existent-goal",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "GOAL_NOT_FOUND")

    mockRewardClient.AssertNotCalled(t, "GrantReward")
}

func TestError_404_ChallengeNotFound(t *testing.T) {
    _, client, _, cleanup := setupTestServer(t)
    defer cleanup()

    // Try to claim goal from non-existent challenge
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "non-existent-challenge",
        GoalId:      "some-goal",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "CHALLENGE_NOT_FOUND")
}

// Medium Priority Errors

func TestError_400_GoalLocked_PrerequisitesNotMet(t *testing.T) {
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Note: This test assumes reach-level-5 has prerequisite kill-10-snowmen in challenges.json
    // Seed completed goal WITHOUT completing prerequisite
    seedCompletedGoal(t, testDB, "test-user-123", "reach-level-5", "winter-challenge-2025")

    // Try to claim locked goal
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "reach-level-5",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "GOAL_LOCKED")

    mockRewardClient.AssertNotCalled(t, "GrantReward")
}

func TestError_503_DatabaseUnavailable(t *testing.T) {
    // This test requires stopping postgres mid-test
    // Approach: Create server, then stop postgres, then make request

    // Note: Stopping postgres affects all tests, so this should run last
    // or use a separate database container

    // Skip for now - requires careful test ordering
    t.Skip("Database unavailability testing requires test isolation improvements")
}

// Low Priority Errors

func TestError_502_RewardGrantFailed(t *testing.T) {
    _, client, mockRewardClient, cleanup := setupTestServer(t)
    defer cleanup()

    // Seed completed goal
    seedCompletedGoal(t, testDB, "test-user-123", "kill-10-snowmen", "winter-challenge-2025")

    // Mock reward client to fail (simulates AGS timeout or error)
    mockRewardClient.On("GrantReward", mock.Anything, mock.Anything, mock.Anything, mock.Anything).
        Return(errors.New("AGS Platform Service timeout"))

    // Try to claim
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "test-user-123",
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "REWARD_GRANT_FAILED")

    // Verify reward grant was attempted but failed
    mockRewardClient.AssertExpectations(t)

    // Verify database NOT updated to claimed (rollback on failure)
    var status string
    dbErr := testDB.QueryRow(
        "SELECT status FROM user_goal_progress WHERE user_id = $1 AND goal_id = $2",
        "test-user-123", "kill-10-snowmen",
    ).Scan(&status)
    assert.NoError(t, dbErr)
    assert.Equal(t, "completed", status) // Still completed, not claimed
}

func TestError_400_InvalidRequest_EmptyUserID(t *testing.T) {
    _, client, _, cleanup := setupTestServer(t)
    defer cleanup()

    // Try to claim with empty user ID
    ctx := context.Background()
    req := &pb.ClaimRewardRequest{
        UserId:      "", // Invalid
        Namespace:   "test-namespace",
        ChallengeId: "winter-challenge-2025",
        GoalId:      "kill-10-snowmen",
    }

    _, err := client.ClaimReward(ctx, req)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "INVALID_REQUEST")
}
```

**Note on Auth Error Testing:**

Phase 6.7 uses a simplified test auth interceptor (see Decision AC2 above). Full JWT validation is covered by unit tests.

**Known Limitations and Behaviors in Phase 6.7:**

1. **HTTP Layer Not Tested** (By Design)
   - Integration tests cover gRPC layer only
   - HTTP/REST layer (gRPC-Gateway transcoding, JSON serialization, HTTP status codes) is NOT tested
   - Rationale: gRPC-Gateway is well-tested generated code with low bug probability
   - Can add HTTP-specific tests in Phase 7 if needed

2. **Database Unavailability Test Skipped** (By Design)
   - TestError_503_DatabaseUnavailable is skipped
   - Rationale: Stopping postgres mid-test affects all tests (no isolation)
   - Database/repository failures are covered by unit tests with mocked dependencies
   - Can revisit in Phase 7 if dedicated test isolation is needed

3. **Namespace Validation is Permissive** (Acceptable for M1)
   - Current implementation: namespace from context is used for reward granting
   - Namespace doesn't strictly enforce isolation in goal lookup (goals are stored with namespace but not validated during claim)
   - This behavior is acceptable for M1 (single namespace deployment)
   - Can tighten namespace validation in future phases if multi-namespace support is needed

4. **Retry Logic Verification**
   - Integration tests verify retry behavior (failure + rollback)
   - Detailed retry count verification (4 attempts = 1 initial + 3 retries) is covered by unit tests
   - This division of responsibility is intentional and appropriate

### Test Scenarios

#### Scenario 1: Progress Tracking

```go
func TestProgressTracking_MultipleEvents(t *testing.T) {
    token := getTestToken(t)
    userID := "test-user-" + uuid.New().String()

    // Publish 5 kill events
    for i := 1; i <= 5; i++ {
        publishStatEvent(t, userID, "snowman_kills", i)
        time.Sleep(200 * time.Millisecond)
    }

    // Wait for buffer flush
    time.Sleep(2 * time.Second)

    // Verify progress
    challenges := getChallenges(t, token)
    goal := findGoal(challenges, "kill-10-snowmen")
    assert.Equal(t, 5, goal.Progress)
    assert.Equal(t, "in_progress", goal.Status)

    // Publish event to complete goal
    publishStatEvent(t, userID, "snowman_kills", 10)
    time.Sleep(2 * time.Second)

    // Verify completion
    challenges = getChallenges(t, token)
    goal = findGoal(challenges, "kill-10-snowmen")
    assert.Equal(t, 10, goal.Progress)
    assert.Equal(t, "completed", goal.Status)
    assert.NotNil(t, goal.CompletedAt)
}
```

#### Scenario 2: Prerequisites

```go
func TestPrerequisites_BlockedGoal(t *testing.T) {
    token := getTestToken(t)
    userID := "test-user-" + uuid.New().String()

    // Complete prerequisite goal first
    publishStatEvent(t, userID, "tutorial_completed", 1)
    time.Sleep(2 * time.Second)

    challenges := getChallenges(t, token)
    prereqGoal := findGoal(challenges, "complete-tutorial")
    assert.Equal(t, "completed", prereqGoal.Status)

    // Now dependent goal should be unlocked
    dependentGoal := findGoal(challenges, "kill-10-snowmen")
    assert.False(t, dependentGoal.Locked)

    // Try to claim without completing
    _, err := claimRewardExpectError(t, token, "winter-challenge-2025", "kill-10-snowmen")
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "GOAL_NOT_COMPLETED")
}
```

#### Scenario 3: Buffering

```go
func TestBuffering_DeduplicationCorrectness(t *testing.T) {
    token := getTestToken(t)
    userID := "test-user-" + uuid.New().String()

    // Publish 100 events rapidly (within 1 second buffer window)
    for i := 1; i <= 100; i++ {
        publishStatEvent(t, userID, "snowman_kills", i)
        time.Sleep(5 * time.Millisecond)  // 500ms total
    }

    // Wait for buffer flush
    time.Sleep(2 * time.Second)

    // Should show progress=100 (not some intermediate value)
    challenges := getChallenges(t, token)
    goal := findGoal(challenges, "kill-10-snowmen")
    assert.Equal(t, 100, goal.Progress)
}
```

### Running Integration Tests

```bash
# Navigate to service directory
cd extend-challenge-service

# Start test database
docker-compose -f docker-compose.test.yml up -d postgres-test

# Wait for database to be ready
sleep 5

# Run integration tests
go test -v ./tests/integration/... -p 1

# Stop test database
docker-compose -f docker-compose.test.yml down -v
```

**Using Makefile (recommended):**
```bash
cd extend-challenge-service
make test-integration  # Runs setup + tests + teardown
```

---

## End-to-End Testing

### Setup Against Real AGS Extend

```bash
# Deploy to test namespace
extend-cli deploy service --namespace test --app challenge-service

# Get service URL
export TEST_API_URL=$(extend-cli get-url service --namespace test --app challenge-service)

# Run E2E tests
cd tests/e2e
TEST_API_URL=$TEST_API_URL \
AGS_CLIENT_ID=$AGS_CLIENT_ID \
AGS_CLIENT_SECRET=$AGS_CLIENT_SECRET \
go test -v ./...
```

### E2E Test Scenarios

**Authentication Pattern**: E2E tests use **dual token mode** for comprehensive verification:
1. **User Token** (password grant): Used for Challenge Service API calls
2. **Client Token** (client credentials grant): Used for Platform Service verification with admin permissions

This pattern ensures:
- Tests authenticate as the actual user when interacting with Challenge Service
- Verification uses admin credentials to reliably query Platform Service
- Same authentication method the backend service uses to grant rewards

#### Scenario 1: Full User Journey

```go
func TestE2E_FullUserJourney(t *testing.T) {
    // 1. Create test user via AGS IAM
    testUser := createTestUser(t)
    defer deleteTestUser(t, testUser.ID)

    // 2. Login as test user (triggers login event)
    token := loginUser(t, testUser.Username, testUser.Password)

    // 3. Wait for event processing
    time.Sleep(5 * time.Second)

    // 4. Get challenges
    challenges := getChallenges(t, token)
    assert.NotEmpty(t, challenges)

    // 5. Find completable goal
    var completedGoal *Goal
    for _, challenge := range challenges {
        for _, goal := range challenge.Goals {
            if goal.Status == "completed" && goal.ClaimedAt == nil {
                completedGoal = &goal
                break
            }
        }
    }
    assert.NotNil(t, completedGoal, "Should have at least one completed goal")

    // 6. Claim reward
    claimResp := claimReward(t, token, completedGoal.ChallengeID, completedGoal.GoalID)
    assert.Equal(t, "claimed", claimResp.Status)

    // 7. Verify reward granted in AGS Platform Service (using client credentials)
    clientToken := getClientToken(t)  // Get client credentials token with admin permissions
    entitlements := getEntitlements(t, clientToken, testUser.ID)
    assert.Contains(t, entitlements, completedGoal.Reward.RewardID)
}
```

#### Scenario 2: High Concurrency

```go
func TestE2E_HighConcurrency(t *testing.T) {
    // Create 100 test users
    users := make([]*TestUser, 100)
    for i := 0; i < 100; i++ {
        users[i] = createTestUser(t)
        defer deleteTestUser(t, users[i].ID)
    }

    // Login all users concurrently
    var wg sync.WaitGroup
    for _, user := range users {
        wg.Add(1)
        go func(u *TestUser) {
            defer wg.Done()
            token := loginUser(t, u.Username, u.Password)

            // Each user completes and claims goals
            challenges := getChallenges(t, token)
            for _, challenge := range challenges {
                for _, goal := range challenge.Goals {
                    if goal.Status == "completed" {
                        claimReward(t, token, challenge.ID, goal.ID)
                    }
                }
            }
        }(user)
    }

    wg.Wait()

    // Verify all claims succeeded (check metrics)
    metrics := getServiceMetrics(t)
    assert.Equal(t, 0, metrics.ErrorCount)
}
```

---

## CLI-Based End-to-End Testing

### Overview

**Phase 8.1 uses CLI-based E2E testing** instead of traditional Go-based E2E tests. This approach uses the demo app CLI to test the full user journey, providing several key advantages:

### Directory Structure

E2E test scripts are located at the **root level** in `tests/e2e/` directory:

```
extend-challenge/                           # Project root
├── docs/                                   # Documentation
├── extend-challenge-service/               # Backend service
│   └── tests/
│       └── integration/                    # Service-specific integration tests (Go)
├── extend-challenge-event-handler/         # Event handler
├── extend-challenge-common/                # Shared library
├── extend-challenge-demo-app/              # Demo app
│   └── cmd/challenge-demo/
│       └── main.go
├── tests/                                  # ← System-level tests (NEW)
│   └── e2e/                               # ← E2E test scripts (Bash)
│       ├── helpers.sh                     # Shared helper functions
│       ├── test-login-flow.sh            # Login event test
│       ├── test-stat-flow.sh             # Stat update test
│       ├── test-daily-goal.sh            # Daily goal test
│       ├── test-prerequisites.sh         # Prerequisite test
│       ├── test-mixed-goals.sh           # Mixed goal types test
│       ├── test-buffering-performance.sh # Performance test
│       └── run-all-tests.sh              # Test runner
├── docker-compose.yml                      # System orchestration
├── Makefile                                # Root Makefile
└── .env                                    # Environment config
```

**Rationale for Root-Level Location:**

1. **System-Level Tests**: Tests the entire system (backend + event handler + demo app + database), not a single component
2. **Uses Root Infrastructure**: Depends on root-level `docker-compose.yml` and root `Makefile`
3. **Cross-Component**: Tests integration between all three components
4. **Follows Pattern**: Mirrors service-specific tests in `extend-challenge-service/tests/integration/`
5. **Build Artifact**: Builds demo app binary from `extend-challenge-demo-app/` and uses it for testing

**Script Paths in Commands:**

```bash
# From project root
bash tests/e2e/run-all-tests.sh

# Or via Makefile
make test-e2e
```

**Docker Compose Service Names:**

Test scripts interact with services using `docker compose` commands and service names from `docker-compose.yml`:

- **postgres** - PostgreSQL database service
- **challenge-service** - Backend REST API service
- **challenge-event-handler** - Event handler gRPC service
- **redis** - Redis cache service

**Examples:**

```bash
# Execute command in postgres service
docker compose exec -T postgres psql -U postgres -d challengedb -c "SELECT * FROM user_goal_progress"

# View logs from event handler
docker compose logs challenge-event-handler

# Check service status
docker compose ps
```

**Benefits:**
1. **Real User Experience**: Tests the actual client workflow (demo app → backend service → event handler → database)
2. **Dual Validation**: Tests both the Challenge Service AND the demo app CLI simultaneously
3. **Human-Readable**: Bash scripts are easier to understand than Go test code
4. **Manual + Automated**: Same scripts work for manual testing and CI/CD
5. **Easy Debugging**: Developers can copy-paste commands to reproduce issues
6. **No Additional Code**: Reuses demo app CLI infrastructure

### Test Architecture

```
┌─────────────────────────────────────────────────────┐
│  E2E Test Scripts (Bash)                            │
│  - test-login-flow.sh                               │
│  - test-stat-flow.sh                                │
│  - test-daily-goal.sh                               │
│  - test-buffering-performance.sh                    │
│  - test-prerequisites.sh                            │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
    ┌────────────────────────┐
    │  Demo App CLI          │
    │  (challenge-demo)      │
    └────────┬───────────────┘
             │
             ▼
┌────────────────────────────────────────────────────┐
│  Local Docker-Compose Environment                  │
│  - PostgreSQL                                       │
│  - Redis                                            │
│  - Challenge Service (REST API)                    │
│  - Event Handler (gRPC)                            │
└─────────────────────────────────────────────────────┘
```

### Test Helper Functions

Create reusable helper functions for common operations:

```bash
# tests/e2e/helpers.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DEMO_APP="${DEMO_APP:-./extend-challenge-demo-app/challenge-demo}"
USER_ID="${USER_ID:-test-user-e2e}"
NAMESPACE="${NAMESPACE:-accelbyte}"
BACKEND_URL="${BACKEND_URL:-http://localhost:8000/challenge}"
EVENT_HANDLER_URL="${EVENT_HANDLER_URL:-localhost:6566}"

# Assert equals
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Assert not equals
assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" == "$actual" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message"
        echo "  Should not equal: $expected"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Extract JSON value using jq
extract_json_value() {
    local json="$1"
    local jq_filter="$2"
    echo "$json" | jq -r "$jq_filter"
}

# Wait for buffer flush (configurable delay)
wait_for_flush() {
    local seconds="${1:-2}"
    echo "Waiting ${seconds}s for buffer flush..."
    sleep "$seconds"
}

# Cleanup test data (truncate user_goal_progress for test user)
cleanup_test_data() {
    echo "Cleaning up test data for user: $USER_ID"
    # Connect to postgres via docker-compose service name
    # Note: Container name is derived from docker-compose.yml service name
    docker compose exec -T postgres \
        psql -U postgres -d challengedb \
        -c "DELETE FROM user_goal_progress WHERE user_id = '$USER_ID';" \
        > /dev/null 2>&1
}

# Run demo app command with common flags
run_cli() {
    $DEMO_APP \
        --backend-url="$BACKEND_URL" \
        --event-handler-url="$EVENT_HANDLER_URL" \
        --auth-mode=mock \
        --user-id="$USER_ID" \
        --namespace="$NAMESPACE" \
        "$@"
}
```

### Example Test Script: Login Flow

```bash
#!/bin/bash
# tests/e2e/test-login-flow.sh

set -e  # Exit on error

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== E2E Test: Login Flow ==="

# Cleanup previous test data
cleanup_test_data

# 1. Check initial state
echo ""
echo "Step 1: Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .progress')
assert_equals "0" "$INITIAL_PROGRESS" "Initial progress should be 0"

# 2. Trigger login events
echo ""
echo "Step 2: Triggering 3 login events..."
for i in {1..3}; do
    echo "  Login event $i/3"
    run_cli trigger-event login --quiet
    sleep 0.5
done

# 3. Wait for buffer flush
wait_for_flush 2

# 4. Verify progress updated
echo ""
echo "Step 3: Verifying progress after login events..."
CHALLENGES=$(run_cli list-challenges --format=json)
NEW_PROGRESS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .progress')
STATUS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .status')

assert_equals "3" "$NEW_PROGRESS" "Progress should be 3 after 3 login events"
assert_equals "completed" "$STATUS" "Status should be 'completed' after reaching target"

# 5. Claim reward
echo ""
echo "Step 4: Claiming reward..."
CLAIM_RESULT=$(run_cli claim-reward daily-missions login-3 --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')
assert_equals "success" "$CLAIM_STATUS" "Claim should succeed"

# 6. Verify claimed status
echo ""
echo "Step 5: Verifying goal is marked as claimed..."
CHALLENGES=$(run_cli list-challenges --format=json)
FINAL_STATUS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .status')
assert_equals "claimed" "$FINAL_STATUS" "Status should be 'claimed' after claiming reward"

echo ""
echo -e "${GREEN}✅ ALL TESTS PASSED${NC}: Login flow test completed successfully"
```

### Reward Verification in Real AGS Mode (Dual Token Authentication)

**IMPORTANT**: When running E2E tests against real AccelByte Gaming Services (not mock mode), tests **MUST** verify that rewards are actually granted in the Platform Service after claiming.

**E2E tests use dual token mode**:
- **User Token** (password grant): For Challenge Service API calls (list challenges, claim rewards)
- **Client Token** (client credentials grant): For Platform Service verification with admin permissions

#### Why Reward Verification is Critical

The challenge claim flow involves multiple steps:
1. Client claims reward via Challenge Service REST API
2. Challenge Service calls AGS Platform Service SDK to grant rewards
3. Platform Service creates entitlements (for ITEM rewards) or credits wallets (for WALLET rewards)
4. Challenge Service marks goal as 'claimed' in database

**Without verification**, tests only confirm step 4 (database update) but don't verify that steps 2-3 succeeded in AGS Platform Service. This can lead to false positives where:
- Database shows `status=claimed`
- But no entitlement/wallet was actually granted in AGS
- Users complain they didn't receive rewards

#### Verification Commands

The demo app provides CLI commands for reward verification (added in Phase 8).

**IMPORTANT**: E2E tests should use `--auth-mode=client` (client credentials) for verification commands to get admin-level permissions:

```bash
# Verify item entitlement (using client credentials for admin permissions)
challenge-demo verify-entitlement \
    --item-id=winter_sword \
    --auth-mode=client \
    --client-id=$AB_CLIENT_ID \
    --client-secret=$AB_CLIENT_SECRET \
    --platform-url=$AB_PLATFORM_URL \
    --user-id=$USER_ID \
    --namespace=$AB_NAMESPACE \
    --format=json

# Verify wallet balance (using client credentials)
challenge-demo verify-wallet \
    --currency=GOLD \
    --auth-mode=client \
    --client-id=$AB_CLIENT_ID \
    --client-secret=$AB_CLIENT_SECRET \
    --platform-url=$AB_PLATFORM_URL \
    --user-id=$USER_ID \
    --namespace=$AB_NAMESPACE \
    --format=json

# List all entitlements (using client credentials)
challenge-demo list-inventory \
    --auth-mode=client \
    --client-id=$AB_CLIENT_ID \
    --client-secret=$AB_CLIENT_SECRET \
    --platform-url=$AB_PLATFORM_URL \
    --user-id=$USER_ID \
    --namespace=$AB_NAMESPACE \
    --format=json

# List all wallets (using client credentials)
challenge-demo list-wallets \
    --auth-mode=client \
    --client-id=$AB_CLIENT_ID \
    --client-secret=$AB_CLIENT_SECRET \
    --platform-url=$AB_PLATFORM_URL \
    --user-id=$USER_ID \
    --namespace=$AB_NAMESPACE \
    --format=json
```

**Why Client Credentials?**
- Client credentials grant has **admin permissions** to query any user's entitlements/wallets
- More reliable than user password authentication for verification
- Mimics production where backend service uses service account credentials
- Same authentication method the Challenge Service uses to grant rewards

#### Modified Helper Function for Real AGS

Update `helpers.sh` to support real AGS mode with **dual token authentication**:

**Why Dual Token Mode?**
- **User Token** (password auth): Used for Challenge Service API calls (list challenges, claim rewards)
- **Client Token** (client credentials): Used for verification with admin permissions
- **Benefit**: Client credentials have broader permissions to query any user's entitlements/wallets
- **Security**: More secure than storing user passwords in test scripts

```bash
# tests/e2e/helpers.sh

# Run demo app command with dual token authentication
# Uses user credentials (password grant) for Challenge Service API
# Uses admin credentials (client grant) for Platform Service verification
run_cli() {
    $DEMO_APP \
        --backend-url="$BACKEND_URL" \
        --event-handler-url="$EVENT_HANDLER_URL" \
        --auth-mode=password \
        --email="$AGS_TEST_EMAIL" \
        --password="$AGS_TEST_PASSWORD" \
        --client-id="$AGS_USER_CLIENT_ID" \
        --client-secret="$AGS_USER_CLIENT_SECRET" \
        --admin-client-id="$AGS_ADMIN_CLIENT_ID" \
        --admin-client-secret="$AGS_ADMIN_CLIENT_SECRET" \
        --iam-url="$AGS_IAM_URL" \
        --platform-url="$AGS_PLATFORM_URL" \
        --user-id="$USER_ID" \
        --namespace="$NAMESPACE" \
        "$@"
}

# Verify item entitlement exists in AGS Platform Service
# Uses admin credentials automatically via run_cli() for Platform SDK operations
verify_entitlement_granted() {
    local item_id="$1"
    local expected_quantity="$2"
    local message="$3"

    echo "  Verifying entitlement in AGS Platform Service: $item_id (using admin token)"

    # Platform SDK uses admin credentials from run_cli()
    ENTITLEMENT=$(run_cli verify-entitlement --item-id="$item_id" --format=json 2>/dev/null || echo '{}')

    if [ "$ENTITLEMENT" == "{}" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Entitlement not found"
        exit 1
    fi

    ACTUAL_QUANTITY=$(extract_json_value "$ENTITLEMENT" '.quantity')
    STATUS=$(extract_json_value "$ENTITLEMENT" '.status')

    if [ "$STATUS" != "ACTIVE" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Entitlement status is '$STATUS', expected 'ACTIVE'"
        exit 1
    fi

    if [ "$ACTUAL_QUANTITY" != "$expected_quantity" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Quantity is $ACTUAL_QUANTITY, expected $expected_quantity"
        exit 1
    fi

    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Verify wallet balance increased in AGS Platform Service
# Uses admin credentials automatically via run_cli() for Platform SDK operations
verify_wallet_balance() {
    local currency_code="$1"
    local min_balance="$2"
    local message="$3"

    echo "  Verifying wallet balance in AGS Platform Service: $currency_code (using admin token)"

    # Platform SDK uses admin credentials from run_cli()
    WALLET=$(run_cli verify-wallet --currency="$currency_code" --format=json 2>/dev/null || echo '{}')

    if [ "$WALLET" == "{}" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Wallet not found"
        exit 1
    fi

    BALANCE=$(extract_json_value "$WALLET" '.balance')
    STATUS=$(extract_json_value "$WALLET" '.status')

    if [ "$STATUS" != "ACTIVE" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Wallet status is '$STATUS', expected 'ACTIVE'"
        exit 1
    fi

    if [ "$BALANCE" -lt "$min_balance" ]; then
        echo -e "${RED}❌ FAIL${NC}: $message - Balance is $BALANCE, expected >= $min_balance"
        exit 1
    fi

    echo -e "${GREEN}✅ PASS${NC}: $message"
}
```

#### Example: Login Flow with Real AGS Verification

```bash
#!/bin/bash
# tests/e2e/test-login-flow-with-ags.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== E2E Test: Login Flow with AGS Reward Verification ==="

# Cleanup previous test data
cleanup_test_data

# 1. Check initial state
echo ""
echo "Step 1: Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_PROGRESS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .progress')
assert_equals "0" "$INITIAL_PROGRESS" "Initial progress should be 0"

# 2. Get initial wallet balance (before claiming) using client credentials
echo ""
echo "Step 2: Getting initial wallet balance (using client token)..."
INITIAL_WALLET=$(run_verification_with_client verify-wallet --currency=GOLD --format=json 2>/dev/null || echo '{"balance":0}')
INITIAL_BALANCE=$(extract_json_value "$INITIAL_WALLET" '.balance')
echo "  Initial GOLD balance: $INITIAL_BALANCE"

# 3. Trigger login events
echo ""
echo "Step 3: Triggering 3 login events..."
for i in {1..3}; do
    echo "  Login event $i/3"
    run_cli trigger-event login --quiet
    sleep 0.5
done

# 4. Wait for buffer flush
wait_for_flush 2

# 5. Verify progress updated
echo ""
echo "Step 4: Verifying progress after login events..."
CHALLENGES=$(run_cli list-challenges --format=json)
NEW_PROGRESS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .progress')
STATUS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .status')

assert_equals "3" "$NEW_PROGRESS" "Progress should be 3 after 3 login events"
assert_equals "completed" "$STATUS" "Status should be 'completed' after reaching target"

# 6. Claim reward
echo ""
echo "Step 5: Claiming reward..."
CLAIM_RESULT=$(run_cli claim-reward daily-missions login-3 --format=json)
CLAIM_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')
assert_equals "success" "$CLAIM_STATUS" "Claim should succeed"

# 7. Verify claimed status in Challenge Service
echo ""
echo "Step 6: Verifying goal is marked as claimed..."
CHALLENGES=$(run_cli list-challenges --format=json)
FINAL_STATUS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .status')
assert_equals "claimed" "$FINAL_STATUS" "Status should be 'claimed' after claiming reward"

# 8. **NEW**: Verify reward granted in AGS Platform Service
echo ""
echo "Step 7: Verifying reward in AGS Platform Service..."

# Get reward type and ID from config
REWARD_TYPE=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .reward.type')
REWARD_ID=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .reward.reward_id')
REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="login-3") | .reward.quantity')

if [ "$REWARD_TYPE" == "ITEM" ]; then
    # Verify item entitlement granted
    verify_entitlement_granted "$REWARD_ID" "$REWARD_QUANTITY" "Item entitlement should be granted in Platform Service"
elif [ "$REWARD_TYPE" == "WALLET" ]; then
    # Verify wallet balance increased
    EXPECTED_BALANCE=$((INITIAL_BALANCE + REWARD_QUANTITY))
    verify_wallet_balance "$REWARD_ID" "$EXPECTED_BALANCE" "Wallet balance should increase in Platform Service"
else
    echo -e "${RED}❌ FAIL${NC}: Unknown reward type: $REWARD_TYPE"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ ALL TESTS PASSED${NC}: Login flow test with AGS verification completed successfully"
```

#### Environment Variables for Real AGS Testing

**Dual Token Mode** requires credentials for both user authentication and admin credentials.
All credentials are passed via CLI flags (no need for SDK environment variables).

```bash
# User credentials (for Challenge Service API - password grant)
export AGS_TEST_EMAIL="test-user@example.com"
export AGS_TEST_PASSWORD="SecurePassword123!"
export AGS_USER_CLIENT_ID="user-client-id"              # OAuth client for password grant
export AGS_USER_CLIENT_SECRET="user-client-secret"

# Admin credentials (for Platform Service verification - admin permissions)
export AGS_ADMIN_CLIENT_ID="admin-client-id"            # Service account with admin permissions
export AGS_ADMIN_CLIENT_SECRET="admin-client-secret"    # Admin service account secret

# Service URLs and configuration
export AGS_IAM_URL="https://demo.accelbyte.io/iam"
export AGS_PLATFORM_URL="https://demo.accelbyte.io/platform"
export BACKEND_URL="http://localhost:8000/challenge"
export EVENT_HANDLER_URL="localhost:6566"
export NAMESPACE="your-namespace"
export USER_ID="test-user-id"

# Run test with real AGS
bash tests/e2e/test-login-flow-with-ags.sh
```

**Token Usage** (all via CLI flags):
- **User Token** (password grant): Used for Challenge Service API calls
  - Commands: `list-challenges`, `claim-reward`, `trigger-event`
  - Credentials: `--email` / `--password` / `--client-id` / `--client-secret`
  - Authenticates as the test user

- **Admin Token** (client credentials): Used automatically by Platform SDK for verification
  - Commands: `verify-entitlement`, `verify-wallet`, `list-inventory`, `list-wallets`
  - Credentials: `--admin-client-id` / `--admin-client-secret` (passed to Platform SDK)
  - Has admin permissions to query any user's data

**Benefits**:
1. **No Environment Variable Mixing**: All credentials via CLI flags, no need to set AB_CLIENT_ID/AB_CLIENT_SECRET
2. **Separation of Concerns**: Challenge operations use user token, verification uses admin token
3. **Realistic Testing**: Mimics production where backend service uses client credentials
4. **Broader Permissions**: Admin token can verify rewards for any user ID

#### Test Scenarios Requiring Verification

**All E2E tests that involve reward claiming MUST verify rewards when using real AGS:**

1. **test-login-flow.sh** → Add verification for login reward (typically WALLET/GOLD)
2. **test-stat-flow.sh** → Add verification for stat-based rewards (ITEM or WALLET)
3. **test-daily-goal.sh** → Add verification for daily goal rewards
4. **test-prerequisites.sh** → Add verification for chained rewards
5. **test-mixed-goals.sh** → Add verification for multiple reward types (ITEM + WALLET)

#### Mock Mode vs Real AGS Mode

**Mock Mode** (default):
- Tests Challenge Service logic only
- Does NOT verify Platform Service integration
- Fast, no external dependencies
- Suitable for development and CI/CD
- Uses `--auth-mode=mock`

**Real AGS Mode** (with dual token verification):
- Tests full integration including Platform Service
- Verifies rewards actually granted using client credentials
- Requires AGS credentials (user password + client credentials)
- Suitable for staging/pre-production testing
- Uses **dual token mode**:
  - User token (password grant) for Challenge Service operations
  - Client token (client credentials grant) for Platform Service verification

**Recommendation**: Run both modes in CI/CD pipeline:
- Mock mode: On every commit (fast feedback)
- Real AGS mode: Nightly or pre-release (comprehensive validation with dual token verification)

### Example Test Script: Buffering Performance

```bash
#!/bin/bash
# tests/e2e/test-buffering-performance.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== E2E Test: Buffering Performance ==="

cleanup_test_data

# 1. Trigger 1,000 events rapidly
echo ""
echo "Step 1: Triggering 1,000 stat-update events..."
START_TIME=$(date +%s)

for i in {1..1000}; do
    # Trigger stat update event (incrementing value)
    run_cli trigger-event stat-update \
        --stat-code=matches-won \
        --value=$i \
        --quiet &

    # Limit concurrent processes
    if [ $((i % 50)) -eq 0 ]; then
        wait  # Wait for batch to complete
        echo "  Triggered $i/1000 events..."
    fi
done

wait  # Wait for all background processes
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "  ✓ Triggered 1,000 events in ${ELAPSED}s"
RATE=$((1000 / ELAPSED))
echo "  ✓ Throughput: ~${RATE} events/sec"

# 2. Wait for buffer flush
wait_for_flush 3

# 3. Verify all progress updated
echo ""
echo "Step 2: Verifying all progress updated..."
CHALLENGES=$(run_cli list-challenges --format=json)
FINAL_PROGRESS=$(extract_json_value "$CHALLENGES" '.challenges[] | select(.id=="daily-missions") | .goals[] | select(.id=="win-matches") | .progress')

assert_equals "1000" "$FINAL_PROGRESS" "Progress should be 1000 after 1000 stat updates"

# 4. Check logs for batch UPSERT timing
echo ""
echo "Step 3: Checking batch UPSERT performance..."
# Get logs from event handler service via docker-compose
FLUSH_TIME=$(docker compose logs challenge-event-handler 2>&1 | \
    grep -i "batch upsert" | \
    tail -1 | \
    grep -oP '\d+ms' || echo "N/A")

echo "  Last batch UPSERT time: $FLUSH_TIME"

if [ "$FLUSH_TIME" != "N/A" ]; then
    # Extract numeric value
    FLUSH_MS=$(echo "$FLUSH_TIME" | grep -oP '\d+')
    if [ "$FLUSH_MS" -lt 20 ]; then
        echo -e "${GREEN}✅ PASS${NC}: Batch UPSERT < 20ms (target met)"
    else
        echo -e "${YELLOW}⚠ WARNING${NC}: Batch UPSERT ${FLUSH_MS}ms (target: <20ms)"
    fi
fi

echo ""
echo -e "${GREEN}✅ ALL TESTS PASSED${NC}: Buffering performance test completed"
echo "  Throughput: ~${RATE} events/sec (target: 1,000 events/sec)"
```

### Test Runner Script

```bash
#!/bin/bash
# tests/e2e/run-all-tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=========================================="
echo "  Challenge Service E2E Test Suite"
echo "=========================================="
echo ""

# Test tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Run a test script
run_test() {
    local test_script="$1"
    local test_name=$(basename "$test_script" .sh)

    TESTS_RUN=$((TESTS_RUN + 1))

    echo ""
    echo "Running: $test_name"
    echo "----------------------------------------"

    if bash "$SCRIPT_DIR/$test_script"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
    fi
}

# Start timer
START_TIME=$(date +%s)

# Run all test scripts
run_test "test-login-flow.sh"
run_test "test-stat-flow.sh"
run_test "test-daily-goal.sh"
run_test "test-prerequisites.sh"
run_test "test-mixed-goals.sh"
run_test "test-buffering-performance.sh"

# End timer
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Print summary
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total tests:   $TESTS_RUN"
echo -e "Passed:        ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:        ${RED}$TESTS_FAILED${NC}"
echo "Duration:      ${ELAPSED}s"

if [ $TESTS_FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    echo ""
    exit 1
else
    echo ""
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    echo ""
    exit 0
fi
```

### Makefile Integration

Add E2E testing targets to root Makefile:

```makefile
# Root Makefile

.PHONY: test-e2e
test-e2e: dev-up
	@echo "Building demo app CLI..."
	@cd extend-challenge-demo-app && go build -o challenge-demo ./cmd/challenge-demo
	@echo ""
	@echo "Running E2E tests..."
	@bash tests/e2e/run-all-tests.sh

.PHONY: test-e2e-quick
test-e2e-quick:
	@echo "Running E2E tests (assumes services already running)..."
	@cd extend-challenge-demo-app && go build -o challenge-demo ./cmd/challenge-demo
	@bash tests/e2e/run-all-tests.sh

.PHONY: test-e2e-single
test-e2e-single:
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-e2e-single TEST=test-login-flow.sh"; \
		exit 1; \
	fi
	@cd extend-challenge-demo-app && go build -o challenge-demo ./cmd/challenge-demo
	@bash tests/e2e/$(TEST)
```

### CI/CD Integration

```yaml
# .github/workflows/e2e-test.yml
name: E2E Tests

on:
  pull_request:
  push:
    branches: [main, master]

jobs:
  e2e-test:
    name: CLI-Based E2E Tests
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Install jq
        run: sudo apt-get install -y jq

      - name: Start services
        run: make dev-up

      - name: Wait for services to be ready
        run: |
          echo "Waiting for services..."
          sleep 10
          docker ps

      - name: Run E2E tests
        run: make test-e2e-quick

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: e2e-test-results
          path: tests/e2e/*.log

      - name: Stop services
        if: always()
        run: make dev-down
```

### Test Coverage

**Test Scripts (6):**
1. `test-login-flow.sh` - Login events → progress → claim
2. `test-stat-flow.sh` - Stat updates (absolute vs increment)
3. `test-daily-goal.sh` - Daily goal idempotency
4. `test-prerequisites.sh` - Prerequisite validation
5. `test-mixed-goals.sh` - Multiple goal types
6. `test-buffering-performance.sh` - Throughput and batch UPSERT

**Scenarios Covered:**
- ✅ Event triggering (login, stat-update)
- ✅ Progress tracking (absolute, increment, daily)
- ✅ Buffer flush mechanism
- ✅ Claim reward flow
- ✅ Prerequisite validation
- ✅ Goal status transitions
- ✅ Idempotency (claiming twice, daily same day)
- ✅ Performance (1,000 events/sec, batch UPSERT < 20ms)

### Success Criteria

**Phase 8.1 is complete when:**
- ✅ All 6 test scripts pass consistently
- ✅ Tests run in < 2 minutes total
- ✅ Buffering test confirms 1,000 events/sec throughput
- ✅ Batch UPSERT completes in < 20ms for 1,000 rows
- ✅ Tests integrated into CI/CD pipeline
- ✅ Test output is human-readable (colored output, clear pass/fail)
- ✅ Tests serve as documentation for demo app CLI usage

### Advantages Over Traditional E2E Tests

| Aspect | CLI-Based (Phase 8.1) | Traditional Go E2E |
|--------|----------------------|-------------------|
| **Code Reuse** | Reuses demo app CLI | Requires separate test code |
| **Dual Testing** | Tests service + CLI | Tests service only |
| **Readability** | Bash scripts (easy) | Go code (more complex) |
| **Manual Use** | Same scripts for manual testing | Can't run manually |
| **Debugging** | Copy-paste commands | Requires Go debugging |
| **Maintenance** | Low (follows CLI changes) | Higher (separate codebase) |
| **Documentation** | Doubles as CLI examples | No documentation value |

---

### Item Reward Testing Patterns

**Last Updated:** 2025-10-22 (after successful item entitlement testing with dual token mode)

This section documents critical learnings from testing ITEM-type rewards with real AGS Platform Service.

#### Critical Discovery: UUID vs SKU for Item Rewards

**Problem**: Challenge configuration files originally used item SKUs (human-readable strings like "winter_sword"), but AGS Platform API **requires item UUIDs** (e.g., `767d2217abe241aab2245794761e9dc4`).

**Symptom**: When claiming a goal with an ITEM reward configured using SKU:
```
Error: Item [winter_sword] does not exist in namespace [abtestdewa-competitive]
HTTP Status: 404 Not Found
```

**Root Cause**: Platform SDK's `GrantUserEntitlement` operation expects `itemId` (UUID format), not `sku` (string format).

**Solution**: Update `challenges.json` to use item UUIDs instead of SKUs.

#### Configuration Format (CRITICAL)

**❌ WRONG - Using SKU (will fail with 404)**:
```json
{
  "id": "kill-10-snowmen",
  "name": "Snowman Slayer",
  "reward": {
    "type": "ITEM",
    "reward_id": "winter_sword",  // ← SKU - NOT accepted by Platform API
    "quantity": 1
  }
}
```

**✅ CORRECT - Using UUID**:
```json
{
  "id": "kill-10-snowmen",
  "name": "Snowman Slayer",
  "reward": {
    "type": "ITEM",
    "reward_id": "767d2217abe241aab2245794761e9dc4",  // ← UUID - required
    "quantity": 1
  }
}
```

#### SKU-to-UUID Mapping Process

Before running E2E tests with ITEM rewards, you must convert SKUs to UUIDs:

1. **Create Test Items in AGS Platform** (one-time setup):
   ```bash
   # Use AGS API MCP or Platform Admin Portal to create items
   # Record the SKU and itemId (UUID) for each item
   ```

2. **Look Up Item UUID by SKU** (using AGS API MCP):
   ```bash
   # Use mcp__ags-api__run-apis tool with GetItemBySku operation
   apiId: "store:GET:/admin/namespaces/{namespace}/items/bySku"
   pathParams: { "namespace": "abtestdewa-competitive" }
   query: { "sku": "winter_sword" }

   # Response contains itemId (UUID):
   # {
   #   "itemId": "767d2217abe241aab2245794761e9dc4",
   #   "sku": "winter_sword",
   #   ...
   # }
   ```

3. **Update Configuration Files**:
   - `extend-challenge-service/config/challenges.json` - Update all ITEM rewards with UUIDs
   - `extend-challenge-event-handler/config/challenges.json` - **MUST match backend config exactly**

4. **Rebuild Services** (CRITICAL):
   ```bash
   # Configuration is embedded at build time, restart alone won't work
   docker-compose build backend
   docker-compose up -d backend
   ```

#### Verified Item Mappings (from testing session 2025-10-22)

For reference, here are the mappings used in successful E2E tests:

| SKU | UUID (itemId) | Challenge | Goal |
|-----|---------------|-----------|------|
| `winter_sword` | `767d2217abe241aab2245794761e9dc4` | `winter-challenge-2025` | `kill-10-snowmen` |
| `loyalty_badge` | `30804133e9494af79d0f466d0933d9b6` | `daily-quests` | `login-7-days` |
| `daily_chest` | `689cac44689c452290b12922c4d135fd` | `daily-quests` | `play-3-matches` |

#### Configuration Synchronization Requirements

**CRITICAL**: Both backend service and event handler must use **identical** challenge configurations.

**Files That Must Match**:
- `extend-challenge-service/config/challenges.json`
- `extend-challenge-event-handler/config/challenges.json`

**Why**: Event handler reads configuration to determine which goals are affected by stat updates. Mismatch causes:
- Events processed for wrong goals
- Progress not updated despite events
- Rewards use wrong item IDs

**Rebuild Required**: After changing configuration files:
```bash
# Restart alone won't reload config (it's embedded at build time)
docker-compose build backend event-handler
docker-compose up -d backend event-handler
```

#### Item Reward Testing Workflow

Complete workflow for testing ITEM-type rewards:

```bash
# 1. Create test item in AGS Platform (if not exists)
# (Use Platform Admin Portal or AGS API MCP)

# 2. Look up item UUID from SKU
# (Use GetItemBySku API via AGS API MCP)
ITEM_UUID="767d2217abe241aab2245794761e9dc4"

# 3. Update challenges.json with UUID
# (Edit both backend and event handler configs)

# 4. Rebuild services
docker-compose build backend event-handler
docker-compose up -d backend event-handler

# 5. Trigger stat events to complete goal (user token)
./challenge-demo trigger-event stat-update \
  --stat-code=snowman_kills \
  --value=10 \
  --auth-mode=password \
  --email=test@example.com \
  --password=secret \
  --backend-url=http://localhost:8000/challenge \
  --event-handler-url=localhost:6566

# Wait for event processing
sleep 3

# 6. Claim reward (user token for Challenge Service, admin token for Platform SDK)
./challenge-demo claim-reward winter-challenge-2025 kill-10-snowmen \
  --auth-mode=password \
  --email=test@example.com \
  --password=secret \
  --client-id=user-client-xxx \
  --client-secret=user-client-yyy \
  --admin-client-id=admin-client-xxx \
  --admin-client-secret=admin-client-yyy \
  --iam-url=https://demo.accelbyte.io/iam \
  --platform-url=https://demo.accelbyte.io/platform

# 7. Verify entitlement granted in AGS Platform (admin token)
./challenge-demo verify-entitlement \
  --item-id=$ITEM_UUID \
  --auth-mode=password \
  --email=test@example.com \
  --password=secret \
  --admin-client-id=admin-client-xxx \
  --admin-client-secret=admin-client-yyy \
  --platform-url=https://demo.accelbyte.io/platform \
  --format=json

# Expected output:
# {
#   "entitlement_id": "4aa605d3710e4abdb8e04244deca52bd",
#   "item_id": "767d2217abe241aab2245794761e9dc4",
#   "status": "ACTIVE",
#   "quantity": 1,
#   "granted_at": "2025-10-22T06:26:46Z"
# }
```

#### Verification Strategy: ITEM vs WALLET Rewards

**ITEM Rewards** (entitlements):
- Query entitlement by `itemId` (UUID)
- Verify `status == "ACTIVE"`
- Verify `quantity` matches expected value
- SDK Method: `GetUserEntitlementByItemIDShort`
- Demo App Command: `verify-entitlement --item-id=<UUID>`

**WALLET Rewards** (virtual currency):
- Query wallet by `currencyCode` (e.g., "GOLD", "GEMS")
- Record balance before claim
- Record balance after claim
- Verify delta equals reward quantity
- SDK Method: `QueryUserCurrencyWalletsShort` (returns all wallets, filter by currency)
- Demo App Command: `verify-wallet --currency=<CODE>`

#### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `Item [winter_sword] does not exist` | Using SKU instead of UUID in challenges.json | Look up UUID via GetItemBySku API, update config with UUID |
| Configuration changes not taking effect | Config embedded at build time | Rebuild services: `docker-compose build backend event-handler` |
| Entitlement not found after claim | Reward grant failed in Platform Service | Check backend logs for Platform API errors; verify admin credentials |
| Progress updated but reward not granted | Backend and event handler configs mismatched | Synchronize both config files, rebuild both services |
| Wrong item granted | Copied wrong UUID for different item | Verify SKU-to-UUID mapping using GetItemBySku API |

#### Platform SDK Usage Patterns (from ags_verifier.go)

**Entitlement Query**:
```go
params := &entitlement.GetUserEntitlementByItemIDParams{
    Namespace: namespace,
    UserID:    userID,
    ItemID:    itemID,  // Must be UUID, not SKU
}
resp, err := entitlementSvc.GetUserEntitlementByItemIDShort(params)
```

**Wallet Query**:
```go
// Note: GetUserWalletShort requires wallet UUID (not currency code)
// Solution: Query all wallets, filter by currency code
params := &wallet.QueryUserCurrencyWalletsParams{
    Namespace: namespace,
    UserID:    userID,
}
resp, err := walletSvc.QueryUserCurrencyWalletsShort(params)

// Filter results
for _, w := range resp {
    if w.CurrencyCode == currencyCode {
        return w
    }
}
```

**Retry Logic** (recommended for all AGS API calls):
```go
maxRetries := 3
retryDelay := 500 * time.Millisecond

for attempt := 0; attempt <= maxRetries; attempt++ {
    if attempt > 0 {
        time.Sleep(retryDelay)
        retryDelay *= 2  // Exponential backoff
    }

    result, err := agsAPICall()
    if err == nil {
        return result
    }

    if !isRetryable(err) {
        return err  // Don't retry 4xx errors
    }
}
```

**Authentication**: Platform SDK uses admin credentials from CLI flags:
- `--admin-client-id` - Service account client ID with admin permissions
- `--admin-client-secret` - Service account client secret
- `--platform-url` - Platform Service URL (e.g., `https://demo.accelbyte.io/platform`)

If admin credentials are not provided, Platform SDK falls back to regular `--client-id` and `--client-secret`.

#### E2E Test Script Template for ITEM Rewards

```bash
#!/bin/bash
# tests/e2e/test-item-reward.sh

set -e

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== E2E Test: Item Reward Flow ==="

# Configuration
CHALLENGE_ID="winter-challenge-2025"
GOAL_ID="kill-10-snowmen"
STAT_CODE="snowman_kills"
REQUIRED_VALUE=10
ITEM_UUID="767d2217abe241aab2245794761e9dc4"  # winter_sword

# Cleanup
cleanup_test_data

# Step 1: Verify initial state (goal not completed)
echo ""
echo "Step 1: Checking initial state..."
CHALLENGES=$(run_cli list-challenges --format=json)
INITIAL_STATUS=$(extract_json_value "$CHALLENGES" \
    ".challenges[] | select(.id==\"$CHALLENGE_ID\") | .goals[] | select(.id==\"$GOAL_ID\") | .status")
assert_equals "not_started" "$INITIAL_STATUS" "Initial status should be not_started"

# Step 2: Trigger stat events to complete goal
echo ""
echo "Step 2: Triggering stat events..."
run_cli trigger-event stat-update --stat-code="$STAT_CODE" --value=$REQUIRED_VALUE --quiet

# Wait for buffer flush
wait_for_flush 2

# Step 3: Verify goal completed
echo ""
echo "Step 3: Verifying goal completion..."
CHALLENGES=$(run_cli list-challenges --format=json)
STATUS=$(extract_json_value "$CHALLENGES" \
    ".challenges[] | select(.id==\"$CHALLENGE_ID\") | .goals[] | select(.id==\"$GOAL_ID\") | .status")
assert_equals "completed" "$STATUS" "Goal should be completed"

# Step 4: Claim reward (user token)
echo ""
echo "Step 4: Claiming reward..."
CLAIM_RESULT=$(run_cli claim-reward "$CHALLENGE_ID" "$GOAL_ID" --format=json)
CLAIMED_STATUS=$(extract_json_value "$CLAIM_RESULT" '.status')
assert_equals "claimed" "$CLAIMED_STATUS" "Goal should be marked as claimed"

# Step 5: Verify entitlement granted in AGS Platform (client token with admin permissions)
echo ""
echo "Step 5: Verifying entitlement in AGS Platform..."
verify_entitlement_granted "$ITEM_UUID" "1" "winter_sword entitlement should be granted"

echo ""
echo -e "${GREEN}✅ ALL TESTS PASSED${NC}: Item reward flow test completed successfully"
```

#### Key Takeaways for Phase 8.2 Implementation

1. **Always use UUIDs** for ITEM rewards in challenges.json, never SKUs
2. **Create SKU-to-UUID mapping** during test setup phase
3. **Synchronize configurations** between backend and event handler
4. **Rebuild services** after config changes (restart is not enough)
5. **Use dual token mode** for E2E tests:
   - User token for Challenge Service operations
   - Client/admin token for Platform Service verification
6. **Verify in Platform Service** after every claim (don't trust database status alone)
7. **Handle async processing** - wait 2-3 seconds after events before checking progress
8. **Implement retry logic** for AGS API calls (3 retries, exponential backoff)

---

## Performance Testing

### Load Testing with k6

```javascript
// tests/performance/load_test.js

import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
    stages: [
        { duration: '1m', target: 50 },   // Ramp up to 50 users
        { duration: '3m', target: 50 },   // Stay at 50 users
        { duration: '1m', target: 100 },  // Ramp up to 100 users
        { duration: '3m', target: 100 },  // Stay at 100 users
        { duration: '1m', target: 0 },    // Ramp down
    ],
    thresholds: {
        'http_req_duration': ['p(95)<200'],  // 95% of requests < 200ms
        'http_req_failed': ['rate<0.01'],    // Error rate < 1%
    },
};

const API_URL = __ENV.TEST_API_URL;
const TOKEN = __ENV.TEST_JWT_TOKEN;

export default function () {
    // Get challenges
    let res = http.get(`${API_URL}/v1/challenges`, {
        headers: { 'Authorization': `Bearer ${TOKEN}` },
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
        'response time < 200ms': (r) => r.timings.duration < 200,
    });

    sleep(1);
}
```

**Run Load Test:**
```bash
k6 run tests/performance/load_test.js \
  -e TEST_API_URL=http://localhost:8080 \
  -e TEST_JWT_TOKEN=eyJhbGc...
```

### Event Processing Performance

```go
// tests/performance/event_throughput_test.go

func TestEventThroughput_1000EventsPerSecond(t *testing.T) {
    eventCount := 10000
    duration := 10 * time.Second
    rateLimit := 1000.0 // events/sec

    limiter := rate.NewLimiter(rate.Limit(rateLimit), 100)

    start := time.Now()
    for i := 0; i < eventCount; i++ {
        limiter.Wait(context.Background())
        publishStatEvent(t, fmt.Sprintf("user-%d", i%100), "test_stat", i)
    }
    elapsed := time.Since(start)

    // Wait for processing
    time.Sleep(5 * time.Second)

    // Verify all events processed
    processedCount := getProcessedEventCount(t)
    assert.GreaterOrEqual(t, processedCount, eventCount)

    // Check p95 latency
    metrics := getEventHandlerMetrics(t)
    assert.Less(t, metrics.EventProcessingP95, 50.0, "p95 latency should be < 50ms")

    t.Logf("Processed %d events in %s (rate: %.2f events/sec)", eventCount, elapsed, float64(eventCount)/elapsed.Seconds())
}
```

---

## Test Data and Fixtures

### Test Config File

```json
// config/challenges.test.json
{
  "challenges": [
    {
      "id": "test-challenge",
      "name": "Test Challenge",
      "description": "For testing",
      "goals": [
        {
          "id": "test-goal-1",
          "name": "Test Goal 1",
          "description": "Simple goal for testing",
          "requirement": {
            "stat_code": "test_stat",
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
          "id": "test-goal-2",
          "name": "Test Goal 2",
          "description": "Goal with prerequisite",
          "requirement": {
            "stat_code": "test_stat_2",
            "operator": ">=",
            "target_value": 5
          },
          "reward": {
            "type": "ITEM",
            "reward_id": "test_item",
            "quantity": 1
          },
          "prerequisites": ["test-goal-1"]
        }
      ]
    }
  ]
}
```

### Test Fixtures

```go
// tests/fixtures/fixtures.go

package fixtures

import "github.com/example/extend-challenge-common/pkg/domain"

func TestChallenge() *domain.Challenge {
    return &domain.Challenge{
        ID:          "test-challenge",
        Name:        "Test Challenge",
        Description: "For testing",
        Goals: []domain.Goal{
            TestGoal1(),
            TestGoal2(),
        },
    }
}

func TestGoal1() domain.Goal {
    return domain.Goal{
        ID:          "test-goal-1",
        ChallengeID: "test-challenge",
        Name:        "Test Goal 1",
        Description: "Simple goal",
        Requirement: domain.Requirement{
            StatCode:    "test_stat",
            Operator:    ">=",
            TargetValue: 1,
        },
        Reward: domain.Reward{
            Type:     "WALLET",
            RewardID: "GOLD",
            Quantity: 10,
        },
        Prerequisites: []string{},
    }
}
```

---

## References

- **testify**: https://github.com/stretchr/testify
- **k6 Load Testing**: https://k6.io/docs/
- **Go Testing**: https://pkg.go.dev/testing

---

**Document Status:** Complete - Ready for implementation
