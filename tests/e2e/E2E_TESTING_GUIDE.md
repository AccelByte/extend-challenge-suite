# E2E Testing Guide

**Version:** 2.0 (Dual Token Support)
**Date:** 2025-10-22
**Status:** Phase 8.2 Complete

## Table of Contents

1. [Overview](#overview)
2. [Test Modes](#test-modes)
3. [Setup Guide](#setup-guide)
4. [Running Tests](#running-tests)
5. [Dual Token Authentication](#dual-token-authentication)
6. [AGS Platform Verification](#ags-platform-verification)
7. [Test Scenarios](#test-scenarios)
8. [Troubleshooting](#troubleshooting)
9. [CI/CD Integration](#cicd-integration)

---

## Overview

The E2E test suite validates the complete challenge system workflow from event triggering through reward claiming and verification in AccelByte Gaming Services (AGS) Platform.

### What the Tests Cover

- ✅ Event triggering (login events, stat updates)
- ✅ Challenge progress tracking
- ✅ Goal completion detection
- ✅ Reward claiming via Challenge Service
- ✅ **NEW:** Reward verification in AGS Platform Service
- ✅ **NEW:** Dual token authentication (user + admin)
- ✅ Prerequisite enforcement
- ✅ Different goal types (increment, absolute, daily)
- ✅ Idempotency and error handling

### Test Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        E2E Test Suite                        │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ Challenge    │    │ Event        │    │ Platform     │
│ Service API  │    │ Handler      │    │ Service SDK  │
│ (User Token) │    │ (gRPC)       │    │ (Admin Token)│
└──────────────┘    └──────────────┘    └──────────────┘
       │                    │                    │
       └────────────────────┴────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  PostgreSQL  │
                    │  (Database)  │
                    └──────────────┘
```

---

## Test Modes

### 1. Mock Mode (Default)

**Purpose:** Fast local testing without external dependencies

**Characteristics:**
- Uses mock JWT authentication
- No AGS Platform verification
- Tests Challenge Service logic only
- Suitable for development and CI/CD

**Configuration:**
```bash
AUTH_MODE=mock
USER_ID=test-user-e2e
```

**When to use:**
- Local development
- Quick feedback during coding
- CI/CD pipeline (fast tests)
- Testing database operations

### 2. Password Mode (Real User Authentication)

**Purpose:** Test with real user authentication against AGS

**Characteristics:**
- Uses real user credentials
- OAuth2 password grant flow
- Tests Challenge Service with real tokens
- Optional Platform verification (if admin credentials provided)

**Configuration:**
```bash
AUTH_MODE=password
EMAIL=user@example.com
PASSWORD=SecurePassword123!
CLIENT_ID=user-client-id
CLIENT_SECRET=user-client-secret
```

**When to use:**
- Staging/pre-production testing
- Integration testing with real AGS
- Validating user authentication flow

### 3. Dual Token Mode (Full AGS Verification)

**Purpose:** Complete E2E testing with AGS Platform verification

**Characteristics:**
- User token (password grant) for Challenge Service operations
- Admin token (client credentials) for Platform Service verification
- Verifies rewards are actually granted in AGS Platform
- Most comprehensive test mode

**Configuration:**
```bash
AUTH_MODE=password
EMAIL=user@example.com
PASSWORD=SecurePassword123!
CLIENT_ID=user-client-id
CLIENT_SECRET=user-client-secret
ADMIN_CLIENT_ID=admin-client-id
ADMIN_CLIENT_SECRET=admin-client-secret
```

**When to use:**
- Pre-production validation
- Verifying complete reward flow
- Debugging reward grant issues
- Demonstrating end-to-end functionality

---

## Setup Guide

### Prerequisites

1. **Services Running:**
   ```bash
   docker-compose up -d
   ```

2. **Demo App Built:**
   ```bash
   cd extend-challenge-demo-app
   go build -o bin/challenge-demo ./cmd/challenge-demo
   cd ../tests/e2e
   ```

3. **Database Initialized:**
   - PostgreSQL should have challenge service schema
   - Migrations applied

### Quick Setup (Mock Mode)

```bash
# 1. Navigate to test directory
cd tests/e2e

# 2. Run tests directly (uses mock mode by default)
./test-login-flow.sh
```

### Setup with Real AGS (Dual Token Mode)

```bash
# 1. Copy environment template
cp .env.example .env

# 2. Edit .env with your credentials
# Set AUTH_MODE=password
# Fill in EMAIL, PASSWORD, CLIENT_ID, CLIENT_SECRET
# Fill in ADMIN_CLIENT_ID, ADMIN_CLIENT_SECRET

# 3. Load environment variables and run tests
set -a && source .env && set +a && ./test-login-flow.sh
```

**Note:** `set -a` enables auto-export of all variables, ensuring they're available to the script.

### AGS Credential Requirements

#### User Credentials (for Challenge Service)
- **Email:** Valid user account in your namespace
- **Password:** User's password
- **Client ID:** OAuth client configured for password grant
- **Client Secret:** OAuth client secret

#### Admin Credentials (for Platform Verification)
- **Admin Client ID:** Service account with Platform admin permissions
- **Admin Client Secret:** Service account secret
- **Required Permissions:**
  - `NAMESPACE:{namespace}:USER:*:ENTITLEMENT [READ]`
  - `NAMESPACE:{namespace}:USER:*:WALLET [READ]`

---

## Running Tests

### Run Individual Tests

```bash
# Mock mode (default)
./test-login-flow.sh
./test-stat-flow.sh
./test-daily-goal.sh
./test-prerequisites.sh
./test-mixed-goals.sh

# With environment variables from .env file
set -a && source .env && set +a && ./test-login-flow.sh
```

### Run All Tests

```bash
# Mock mode
./run-all-tests.sh

# Dual token mode (load .env first)
set -a && source .env && set +a && ./run-all-tests.sh
```

### Run with Custom Configuration

```bash
# Method 1: Override specific variables inline
AUTH_MODE=password \
EMAIL=user@test.com \
PASSWORD=pass123 \
CLIENT_ID=xyz \
ADMIN_CLIENT_ID=admin-xyz \
./test-login-flow.sh

# Method 2: Use .env file with overrides
set -a && source .env && set +a
AUTH_MODE=password ./test-login-flow.sh
```

### Understanding `set -a` and `set +a`

The `set -a` command enables automatic export of all variables that are set. This is essential when loading environment variables from a file:

```bash
# Without set -a (variables NOT exported to child processes)
source .env
./test-script.sh  # Won't see variables from .env

# With set -a (variables ARE exported to child processes)
set -a             # Enable auto-export
source .env        # Load variables and auto-export them
set +a             # Disable auto-export (good practice)
./test-script.sh   # Will see all variables from .env
```

**Why this matters:** When you run `source .env` without `set -a`, the variables are set in your current shell but not exported to child processes (like the test scripts). The test scripts won't see them!

---

## Dual Token Authentication

### How It Works

The dual token mode uses two independent authentication flows:

```
┌─────────────────────────────────────────────────────────┐
│                    Dual Token Flow                       │
└─────────────────────────────────────────────────────────┘

1. User Authentication (Password Grant)
   ┌──────────────┐
   │ Test Script  │
   └──────┬───────┘
          │ email + password
          ▼
   ┌──────────────┐      OAuth2 Password Grant
   │  IAM Service │─────────────────────────────┐
   └──────┬───────┘                             │
          │ user_token (JWT with user_id)       │
          ▼                                     │
   ┌──────────────┐                             │
   │ Challenge    │                             │
   │ Service API  │                             │
   └──────────────┘                             │
                                                │
2. Admin Authentication (Client Credentials)   │
   ┌──────────────┐                             │
   │ Test Script  │                             │
   └──────┬───────┘                             │
          │ client_id + secret                  │
          ▼                                     │
   ┌──────────────┐      OAuth2 Client Grant   │
   │  IAM Service │◄────────────────────────────┘
   └──────┬───────┘
          │ admin_token (JWT with admin perms)
          ▼
   ┌──────────────┐
   │ Platform     │
   │ Service SDK  │
   └──────────────┘
```

### Implementation Details

**User Token Flow:**
```bash
# Used for Challenge Service operations
run_cli list-challenges
run_cli claim-reward <challenge-id> <goal-id>
run_cli trigger-event login
```

**Admin Token Flow:**
```bash
# Used for Platform Service verification
run_verification_with_client verify-entitlement --item-id=<uuid>
run_verification_with_client verify-wallet --currency=<code>
```

### Helper Functions

#### `run_cli()`
Executes demo app commands with user authentication:
- Uses `AUTH_MODE`, `EMAIL`, `PASSWORD`, `CLIENT_ID`
- For Challenge Service API operations
- Returns JSON output from demo app

#### `run_verification_with_client()`
Executes demo app commands with admin authentication:
- Uses `ADMIN_CLIENT_ID`, `ADMIN_CLIENT_SECRET`
- For Platform Service verification
- Gracefully skips if admin credentials not provided

#### `verify_entitlement_granted(item_id)`
Verifies that an item entitlement was granted:
- Calls `run_verification_with_client verify-entitlement`
- Checks for `status: ACTIVE`
- Returns 0 if found, 1 otherwise

#### `verify_wallet_balance(currency_code, min_balance)`
Verifies wallet balance:
- Calls `run_verification_with_client verify-wallet`
- Checks balance meets minimum requirement
- Returns 0 if valid, 1 otherwise

#### `verify_wallet_increased(currency, initial, increase)`
Verifies wallet balance increased by expected amount:
- Compares current balance to initial + increase
- Accounts for other transactions (uses >= comparison)
- Returns 0 if increased as expected, 1 otherwise

---

## AGS Platform Verification

### Why Verification Matters

The challenge claim flow involves multiple steps:

```
1. Client calls Challenge Service API → POST /claim
2. Challenge Service validates goal status
3. Challenge Service calls Platform Service SDK → GrantReward()
4. Platform Service creates entitlement/wallet credit
5. Challenge Service updates database → status=claimed
6. Challenge Service returns success response
```

**Without verification**, tests only confirm step 5-6 (database update) but don't verify that step 3-4 succeeded. This can lead to false positives where:
- Database shows `status=claimed`
- But no entitlement/wallet was actually granted in AGS

### Verification Flow

**For WALLET Rewards:**
```bash
# 1. Get initial balance
INITIAL=$(get_initial_wallet_balance "GOLD")

# 2. Claim reward
run_cli claim-reward winter-challenge-2025 kill-10-snowmen

# 3. Verify balance increased
verify_wallet_increased "GOLD" "$INITIAL" 100
```

**For ITEM Rewards:**
```bash
# 1. Claim reward
run_cli claim-reward winter-challenge-2025 complete-tutorial

# 2. Verify entitlement granted
verify_entitlement_granted "767d2217abe241aab2245794761e9dc4"
```

### Example Test with Verification

```bash
#!/bin/bash
set -e

source helpers.sh

print_test_header "Login Flow with AGS Verification"

# Cleanup
cleanup_test_data

# Step 1: Check initial state
CHALLENGES=$(run_cli list-challenges --format=json)
REWARD_TYPE=$(extract_json_value "$CHALLENGES" "...reward.type")
REWARD_ID=$(extract_json_value "$CHALLENGES" "...reward.rewardId")
REWARD_QUANTITY=$(extract_json_value "$CHALLENGES" "...reward.quantity")

# Step 2: Get initial balance (if WALLET reward)
if [ "$REWARD_TYPE" = "WALLET" ]; then
    INITIAL_BALANCE=$(get_initial_wallet_balance "$REWARD_ID")
    echo "Initial $REWARD_ID balance: $INITIAL_BALANCE"
fi

# Step 3: Trigger events and complete goal
run_cli trigger-event login
wait_for_flush 2

# Step 4: Claim reward
CLAIM_RESULT=$(run_cli claim-reward daily-quests daily-login --format=json)
assert_equals "success" "$(extract_json_value "$CLAIM_RESULT" '.status')"

# Step 5: Verify reward in AGS Platform
if [ "$REWARD_TYPE" = "WALLET" ]; then
    verify_wallet_increased "$REWARD_ID" "$INITIAL_BALANCE" "$REWARD_QUANTITY"
elif [ "$REWARD_TYPE" = "ITEM" ]; then
    verify_entitlement_granted "$REWARD_ID"
fi

print_success "Test completed with AGS verification"
```

### Graceful Degradation

If admin credentials are not provided:
- Tests still run and validate Challenge Service behavior
- Verification functions log warnings and return success
- Database claim status is still verified
- No test failures due to missing credentials

Example output without admin credentials:
```
⚠ Warning: Admin credentials not provided, skipping AGS verification
  To enable verification, set: ADMIN_CLIENT_ID and ADMIN_CLIENT_SECRET
✅ PASS: Claim should succeed
✅ PASS: Status should be 'claimed' after claiming reward
```

---

## Test Scenarios

### test-login-flow.sh

**Tests:**
- Daily increment goal behavior
- Same-day idempotency
- Reward claiming
- AGS Platform verification (WALLET or ITEM)

**Verification:**
- Verifies `daily-login` reward granted in AGS

### test-stat-flow.sh

**Tests:**
- Absolute goal type (replaces value)
- Multiple stat update events
- Claimed goal protection

**Verification:**
- Verifies `win-1-match` reward granted in AGS

### test-daily-goal.sh

**Tests:**
- Daily goal completion on first event
- Same-day idempotency
- Claimed goal updates blocked

**Verification:**
- Verifies `daily-login` reward granted in AGS

### test-prerequisites.sh

**Tests:**
- Prerequisite enforcement
- Claim order validation
- Prerequisite chain (3 levels)

**Verification:**
- Verifies all 3 rewards granted in correct order:
  1. `complete-tutorial` reward
  2. `kill-10-snowmen` reward
  3. `reach-level-5` reward

### test-mixed-goals.sh

**Tests:**
- Absolute, increment, and daily goals together
- Different update behaviors
- Multiple reward claims

**Verification:**
- Verifies both `win-1-match` and `daily-login` rewards

---

## Troubleshooting

### Common Issues

#### Issue: "Demo app binary not found"

```
❌ ERROR: Demo app binary not found at: ./extend-challenge-demo-app/bin/challenge-demo
```

**Solution:**
```bash
cd extend-challenge-demo-app
go build -o bin/challenge-demo ./cmd/challenge-demo
cd ../tests/e2e
```

#### Issue: "Services are not running"

```
❌ ERROR: Services are not running
```

**Solution:**
```bash
cd ../..
docker-compose up -d
cd tests/e2e
```

#### Issue: "Authentication failed" (password mode)

```
❌ ERROR: AUTH_MODE=password requires EMAIL, PASSWORD, and CLIENT_ID
```

**Solution:**
- Verify credentials in `.env`
- Check client is configured for password grant
- Verify user exists in namespace

#### Issue: "Entitlement not found"

```
✗ Entitlement NOT found for item: winter_sword
```

**Root Cause:** Challenge configuration uses SKU instead of UUID

**Solution:**
```bash
# Use item UUID (not SKU) in challenges.json:
"reward": {
  "type": "ITEM",
  "reward_id": "767d2217abe241aab2245794761e9dc4",  # UUID (correct)
  "quantity": 1
}

# NOT:
"reward": {
  "type": "ITEM",
  "reward_id": "winter_sword",  # SKU (incorrect)
  "quantity": 1
}
```

#### Issue: "Wallet balance did not increase"

**Possible Causes:**
1. Reward grant failed in Platform Service
2. Currency doesn't exist in namespace
3. Race condition (check too soon)

**Solution:**
```bash
# 1. Check backend logs for grant errors
docker-compose logs backend | grep -i error

# 2. Verify currency exists in namespace
# Use Platform SDK or Admin Portal

# 3. Increase wait time before verification
wait_for_flush 3  # Instead of 2
```

### Debugging Tips

#### Enable Verbose Output

```bash
# Add to test script
set -x  # Enable bash debug mode

# Or run with bash -x
bash -x ./test-login-flow.sh
```

#### Check Database State

```bash
# Connect to database
docker-compose exec postgres psql -U postgres -d challenge_db

# Check user progress
SELECT * FROM user_goal_progress WHERE user_id = 'test-user-e2e';

# Check specific goal
SELECT * FROM user_goal_progress
WHERE user_id = 'test-user-e2e' AND goal_id = 'daily-login';
```

#### Manual Verification

```bash
# Test entitlement verification manually
./challenge-demo verify-entitlement \
  --item-id=767d2217abe241aab2245794761e9dc4 \
  --auth-mode=password \
  --email=user@test.com \
  --password=pass123 \
  --admin-client-id=admin-xyz \
  --admin-client-secret=secret \
  --format=json

# Test wallet verification manually
./challenge-demo verify-wallet \
  --currency=GOLD \
  --auth-mode=password \
  --email=user@test.com \
  --password=pass123 \
  --admin-client-id=admin-xyz \
  --admin-client-secret=secret \
  --format=json
```

---

## CI/CD Integration

### Recommended Strategy

Run both mock mode and dual token mode in CI/CD:

```yaml
# .github/workflows/e2e-tests.yml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e-mock:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Start services
        run: docker-compose up -d
      - name: Build demo app
        run: |
          cd extend-challenge-demo-app
          go build -o bin/challenge-demo ./cmd/challenge-demo
      - name: Run E2E tests (mock mode)
        run: |
          cd tests/e2e
          ./run-all-tests.sh

  e2e-ags:
    runs-on: ubuntu-latest
    needs: e2e-mock
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v3
      - name: Start services
        run: docker-compose up -d
      - name: Build demo app
        run: |
          cd extend-challenge-demo-app
          go build -o bin/challenge-demo ./cmd/challenge-demo
      - name: Run E2E tests (dual token mode)
        env:
          AUTH_MODE: password
          EMAIL: ${{ secrets.AGS_TEST_EMAIL }}
          PASSWORD: ${{ secrets.AGS_TEST_PASSWORD }}
          CLIENT_ID: ${{ secrets.AGS_CLIENT_ID }}
          CLIENT_SECRET: ${{ secrets.AGS_CLIENT_SECRET }}
          ADMIN_CLIENT_ID: ${{ secrets.AGS_ADMIN_CLIENT_ID }}
          ADMIN_CLIENT_SECRET: ${{ secrets.AGS_ADMIN_CLIENT_SECRET }}
          IAM_URL: https://staging.accelbyte.io/iam
          PLATFORM_URL: https://staging.accelbyte.io/platform
          NAMESPACE: staging-namespace
        run: |
          cd tests/e2e
          ./run-all-tests.sh
```

### GitHub Secrets Configuration

Add these secrets to your GitHub repository:

```
AGS_TEST_EMAIL              # User email for testing
AGS_TEST_PASSWORD           # User password
AGS_CLIENT_ID               # OAuth client for password grant
AGS_CLIENT_SECRET           # OAuth client secret
AGS_ADMIN_CLIENT_ID         # Service account client ID
AGS_ADMIN_CLIENT_SECRET     # Service account secret
```

---

## Best Practices

### Test Data Management

1. **Always cleanup before tests:**
   ```bash
   cleanup_test_data  # Removes user progress for test user
   ```

2. **Use consistent test user IDs:**
   ```bash
   USER_ID=test-user-e2e  # Don't use production user IDs
   ```

3. **Isolate test data:**
   - Use dedicated test namespace if possible
   - Clean up after tests complete

### Credential Management

1. **Never commit credentials:**
   ```bash
   # .gitignore
   tests/e2e/.env
   ```

2. **Use environment-specific credentials:**
   - Dev: Mock mode
   - Staging: Real AGS with staging namespace
   - Production: Never run E2E tests against production!

3. **Rotate credentials regularly:**
   - Test credentials should expire
   - Update CI/CD secrets periodically

### Test Maintenance

1. **Keep tests independent:**
   - Each test should run standalone
   - Don't depend on execution order

2. **Use meaningful assertions:**
   ```bash
   assert_equals "completed" "$STATUS" "Goal should be completed after meeting target"
   # NOT: assert_equals "completed" "$STATUS"
   ```

3. **Add verification for all claims:**
   - Every reward claim should verify in AGS Platform
   - Use helper functions consistently

---

## Quick Reference

### Common Commands

```bash
# Run single test (mock mode)
./test-login-flow.sh

# Run all tests (mock mode)
./run-all-tests.sh

# Run with .env file (dual token mode)
set -a && source .env && set +a && ./test-login-flow.sh

# Run all tests with .env file
set -a && source .env && set +a && ./run-all-tests.sh

# Override specific variables
AUTH_MODE=password EMAIL=user@test.com ./test-login-flow.sh

# Clean test data
docker-compose exec postgres psql -U postgres -d challenge_db \
  -c "DELETE FROM user_goal_progress WHERE user_id = 'test-user-e2e';"
```

### File Locations

```
tests/e2e/
├── .env.example              # Environment template (copy to .env)
├── helpers.sh                # Helper functions
├── test-login-flow.sh        # Login event tests
├── test-stat-flow.sh         # Stat update tests
├── test-daily-goal.sh        # Daily goal tests
├── test-prerequisites.sh     # Prerequisite chain tests
├── test-mixed-goals.sh       # Mixed goal type tests
├── run-all-tests.sh          # Run all tests
└── E2E_TESTING_GUIDE.md      # This file
```

---

## Related Documentation

- [TECH_SPEC_TESTING.md](../../docs/TECH_SPEC_TESTING.md) - Testing strategy
- [TECH_SPEC_AUTHENTICATION.md](../../docs/TECH_SPEC_AUTHENTICATION.md) - Auth implementation
- [demo-app/STATUS.md](../../docs/demo-app/STATUS.md) - Demo app status
- [demo-app/README.md](../../extend-challenge-demo-app/README.md) - Demo app usage

---

**Last Updated:** 2025-10-22
**Status:** Phase 8.2 Complete - Dual Token E2E Testing Implemented
