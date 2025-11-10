# Multi-User E2E Testing Guide

The `test-multi-user.sh` script tests concurrent user access with 10 simultaneous users.

## Quick Start (Mock Mode - No AGS Required)

The simplest way to run the multi-user test:

```bash
cd tests/e2e
AUTH_MODE=mock ./test-multi-user.sh
```

This runs the test with mock authentication (no real AGS users).

## AGS Integration (Password Mode)

To test with real AGS users, you have two options:

### Option 1: Auto-Generated Users (Requires Admin Permissions)

**Prerequisites:**
Your admin client must have this IAM permission:
- **Resource**: `ADMIN:NAMESPACE:{namespace}:USER`
- **Action**: `CREATE` (action code: 1)

**How to grant permission:**
1. Go to AGS Admin Portal → IAM → Clients
2. Find your admin client (from `.env`: `ADMIN_CLIENT_ID`)
3. Go to Permissions tab
4. Add permission: `ADMIN:NAMESPACE:*:USER` with action `CREATE`

**Run the test:**
```bash
cd tests/e2e
set -a && source .env && set +a
./test-multi-user.sh
```

The test will:
- Auto-create 10 test users via AGS API
- Run all multi-user tests
- Auto-delete users on cleanup

### Option 2: Pre-Created Users (No Special Permissions Needed)

If you can't grant admin permissions, manually create 10 test users once:

**1. Create test users in AGS Admin Portal:**
   - Email pattern: `test-multi-1@yourcompany.com` through `test-multi-10@yourcompany.com`
   - Password: `TestPass123!` (same for all)
   - Country: US
   - Date of Birth: 1990-01-01

**2. Update `.env` with user details:**
```bash
# Add these to your .env file

# Multi-user test configuration
MULTI_USER_EMAILS=(
    "test-multi-1@yourcompany.com"
    "test-multi-2@yourcompany.com"
    "test-multi-3@yourcompany.com"
    "test-multi-4@yourcompany.com"
    "test-multi-5@yourcompany.com"
    "test-multi-6@yourcompany.com"
    "test-multi-7@yourcompany.com"
    "test-multi-8@yourcompany.com"
    "test-multi-9@yourcompany.com"
    "test-multi-10@yourcompany.com"
)

MULTI_USER_PASSWORD="TestPass123!"
```

**3. Run the test with pre-created users:**
```bash
cd tests/e2e
set -a && source .env && set +a
./test-multi-user.sh
```

## What the Test Verifies

The multi-user test validates:

1. **User Isolation** - Each user has independent progress
2. **No Data Leakage** - Users can't see each other's progress
3. **Concurrent Event Processing** - 10 users trigger events simultaneously
4. **Concurrent Claims** - 10 users claim rewards at the same time
5. **Per-User Mutex** - Prevents race conditions
6. **Buffering** - Handles concurrent load correctly
7. **Transaction Locking** - Database prevents double-claims

## Test Output Example

```
==========================================
  Multi-User Concurrent Access E2E Test
==========================================

Test configuration:
  Number of users: 10
  Challenge: daily-quests
  Goal: daily-login (completes with 1 login)
  Auth mode: password

Step 1: Preparing test users...
🔧 Creating 10 test users via AGS IAM API...
✓ Created 10 test users

Step 2: Triggering login events for 10 users concurrently...
✓ Triggered 10 login events in 2s (concurrent)

Step 3: Verifying user isolation (each user has independent progress)...
  Users with correct progress: 10/10
✅ PASS: All 10 users have independent progress

Step 4: Verifying users cannot see each other's progress...
✅ PASS: Users have isolated progress (no data leakage)

Step 5: Testing concurrent claims from 10 users...
✓ Processed 10 concurrent claims in 3s

Step 6: Verifying all users successfully claimed rewards...
✅ PASS: All 10 users successfully claimed rewards

Step 7: Testing concurrent stat updates from multiple users...
✓ Triggered 50 stat updates in 4s

Step 8: Verifying stat updates for all users...
✅ PASS: All 10 users processed stat updates correctly

Step 9: Cleaning up test users...
✓ Deleted 10/10 test users from AGS
✓ Cleanup complete

✅ ALL TESTS PASSED: Multi-user concurrent access test completed successfully
```

## Troubleshooting

### Error: "insufficient permissions"

**Problem**: Admin client can't create users.

**Solution**: Either:
- Grant `ADMIN:NAMESPACE:*:USER` CREATE permission to admin client (Option 1)
- Use pre-created users (Option 2)
- Use mock mode: `AUTH_MODE=mock ./test-multi-user.sh`

### Error: "Demo app binary not found"

**Problem**: Demo app not built.

**Solution**:
```bash
cd extend-challenge-demo-app
make build
```

### Error: "Services are not running"

**Problem**: Docker services not started.

**Solution**:
```bash
cd /home/ab/projects/extend-challenge
make dev-up
```

## Performance Benchmarks

Expected performance with 10 users:

- **Concurrent login events**: < 5 seconds
- **Concurrent claims**: < 5 seconds
- **Concurrent stat updates** (50 total): < 10 seconds
- **Total test time**: < 60 seconds (mock mode), < 120 seconds (password mode)

## Notes

- **Mock mode** is fastest and requires no AGS setup
- **Password mode** tests real AGS integration (IAM authentication + Platform rewards)
- Auto-generated users are cleaned up automatically
- Pre-created users are NOT deleted (reusable across test runs)
