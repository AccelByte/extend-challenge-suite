# Code Style and Conventions

## Core Principles

### 1. Early Return Style (Mandatory)

**Always write functions in "early return" style rather than nested conditional.**

Bad:
```go
func Process(data *Data) error {
    if data != nil {
        if data.Valid() {
            return processData(data)
        }
    }
    return errors.New("invalid")
}
```

Good:
```go
func Process(data *Data) error {
    if data == nil {
        return errors.New("data cannot be nil")
    }
    
    if !data.Valid() {
        return errors.New("invalid data")
    }
    
    return processData(data)
}
```

### 2. Error Handling

- **Never ignore errors** - all errors must be checked
- Use `fmt.Errorf("context: %w", err)` for error wrapping
- Return errors early, don't nest

### 3. Naming Conventions

- **Interfaces**: Named after behavior (e.g., `GoalRepository`, `EventTrigger`)
- **Implementations**: Descriptive names (e.g., `PostgresGoalRepository`, `LocalEventTrigger`)
- **Packages**: Lowercase, single word when possible
- **Files**: Lowercase with underscores (e.g., `buffered_repository.go`)

### 4. Documentation

- **Copyright Headers**: Required on all files (AccelByte Inc 2025)
- **Package Comments**: Required for public packages
- **Exported Functions**: Require GoDoc comments
- **Complex Logic**: Inline comments explaining "why", not "what"

### 5. Interface-Driven Design

- Define interfaces in consumer packages, not implementations
- Use interfaces for testability (repository, client, cache)
- Mock interfaces in unit tests

### 6. Testing Standards

- **Coverage Target**: ≥ 80% for all packages
- **Test File Naming**: `*_test.go`
- **Test Function Naming**: `Test<FunctionName>_<Scenario>` (e.g., `TestUpdateProgress_WithNilProgress`)
- **Use Table-Driven Tests**: For multiple scenarios

### 7. Concurrency

- Use mutexes for shared state protection
- Avoid goroutine leaks - always clean up
- Document goroutine lifecycle

### 8. Configuration

- Environment variables for runtime config
- JSON files for business logic (challenges)
- Never hardcode secrets or URLs

## Linter Configuration

The project uses `golangci-lint` with these key rules:
- **nestif**: Enforces early return style (max 3 levels)
- **errcheck**: Ensures all errors are checked
- **gosec**: Security vulnerability detection
- **govet**: Standard Go vet checks
- **staticcheck**: Advanced static analysis
- **goheader**: Copyright header validation
