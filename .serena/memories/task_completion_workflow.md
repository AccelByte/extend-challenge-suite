# Task Completion Workflow

## Mandatory Steps Before Marking Any Task Complete

### 1. Run Unit Tests

```bash
go test ./... -v
```

**Expected**: All tests pass

### 2. Check Test Coverage

```bash
go test ./... -coverprofile=coverage.out
go tool cover -func=coverage.out | grep total
```

**Expected**: ≥ 80% coverage

If below 80%, add more tests before proceeding.

### 3. Run Linter (MANDATORY)

```bash
golangci-lint run ./...
```

**Expected**: Zero issues

This is **NON-NEGOTIABLE**. Fix all linter issues before proceeding.

### 4. Auto-Fix Simple Issues (Optional)

```bash
golangci-lint run --fix ./...
```

Review changes before committing.

### 5. For Backend Service: Run Integration Tests

```bash
cd extend-challenge-service
make test-integration
```

**Expected**: All integration tests pass

### 6. Combined Check (Recommended)

```bash
# For backend service
cd extend-challenge-service
make test-all  # Runs lint + unit tests + integration tests
```

## Task Completion Checklist

Before marking a task as "done", verify:

- ✅ All tests pass
- ✅ Test coverage ≥ 80%
- ✅ Linter reports zero issues
- ✅ Code follows early return style
- ✅ All errors are checked (no `errcheck` warnings)
- ✅ No nil pointer dereferences (no `staticcheck` warnings)
- ✅ Code is formatted (`gofmt`, `goimports`)
- ✅ Copyright headers present on all files

## Common Linter Issues and Fixes

### Issue: Early Return Style Violation (nestif)

**Problem:**
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

**Fix:**
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

### Issue: Unchecked Error (errcheck)

**Problem:**
```go
json.Marshal(data)  // Error ignored
```

**Fix:**
```go
_, err := json.Marshal(data)
if err != nil {
    return fmt.Errorf("marshal failed: %w", err)
}
```

### Issue: Missing Nil Check (staticcheck)

**Problem:**
```go
func UpdateProgress(p *Progress) error {
    key := p.UserID + p.GoalID  // Panic if p is nil
}
```

**Fix:**
```go
func UpdateProgress(p *Progress) error {
    if p == nil {
        return errors.New("progress cannot be nil")
    }

    key := p.UserID + p.GoalID
}
```

## Workflow for Different Task Types

### When Implementing a Feature

1. Write tests first (TDD approach)
2. Implement feature
3. Run tests: `go test ./... -v`
4. Check coverage: `go test ./... -coverprofile=coverage.out`
5. Run linter: `golangci-lint run ./...` ← **MANDATORY**
6. Fix all linter issues
7. Commit changes

### When Fixing Bugs

1. Write failing test that reproduces bug
2. Fix bug
3. Verify test passes
4. Run linter: `golangci-lint run ./...` ← **MANDATORY**
5. Fix any issues introduced
6. Commit fix

### When Refactoring

1. Ensure tests exist and pass
2. Refactor code
3. Run tests to ensure behavior unchanged
4. Run linter: `golangci-lint run ./...` ← **MANDATORY**
5. Address any new linter issues
6. Commit refactoring

## Expected Behavior with Claude Code

When working with Claude Code:

1. **During implementation**: Claude writes code following best practices
2. **Before task completion**: Claude runs `golangci-lint run ./...`
3. **If issues found**: Claude fixes all linter issues automatically
4. **Final verification**: Claude confirms zero linter issues before marking task complete

## What to Do When Tests Fail

1. Read the error message carefully
2. Identify which test failed and why
3. Fix the underlying issue (not the test, unless test is wrong)
4. Re-run tests to verify fix
5. Run linter again (the fix might introduce new issues)

## What to Do When Linter Fails

1. Read each linter error/warning
2. Understand what rule is being violated
3. Fix the code to comply with the rule
4. If unsure, consult `.golangci.yml` for rule configuration
5. Re-run linter to verify all issues resolved
6. **Do not disable linter rules** without discussing with team

## Integration with Git Workflow

```bash
# Before committing
golangci-lint run ./...
go test ./... -v

# If all pass
git add .
git commit -m "feat: description"

# If anything fails
# Fix issues first, then commit
```

## Documentation Update

After implementing a feature, update relevant docs:

- `docs/STATUS.md` - Mark phase/task as complete
- `CHANGELOG.md` - Add entry (if exists)
- `README.md` - Update if user-facing changes
- Inline comments - Update if logic changed

## Performance Considerations

- Unit tests should run quickly (< 10 seconds total)
- Integration tests can be slower (< 2 minutes total)
- Linter should complete in < 30 seconds

If tests/linting take longer, investigate optimization opportunities.
