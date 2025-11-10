# E2E Tests - Quick Start Guide

## TL;DR

```bash
# Mock mode (local testing)
make test-e2e

# Real authentication (copy .env.example to .env and edit)
cd tests/e2e
cp .env.example .env
nano .env  # Fill in your credentials
set -a && source .env && set +a && ./run-all-tests.sh
```

---

## 1. Mock Mode (Default - Local Testing)

**Use when:** Testing locally against local services

**Setup:** None required!

**Run:**
```bash
make test-e2e
# or
./tests/e2e/run-all-tests.sh
```

**What it does:**
- Uses mock JWT tokens
- Test user ID: `test-user-e2e`
- No real authentication required
- Perfect for local development

---

## 2. Password Mode (Real User Testing)

**Use when:** Testing with real AccelByte user accounts

**Setup:**
1. Create `.env` file:
   ```bash
   cd tests/e2e
   cp .env.example .env
   ```

2. Edit `.env`:
   ```bash
   AUTH_MODE=password
   EMAIL=your.email@example.com
   PASSWORD=your-password
   CLIENT_ID=your-oauth-client-id
   NAMESPACE=your-namespace
   IAM_URL=https://demo.accelbyte.io/iam
   ```

**Run:**
```bash
set -a && source tests/e2e/.env && set +a && make test-e2e
# or
cd tests/e2e && set -a && source .env && set +a && ./run-all-tests.sh
```

**What you need:**
- Real AccelByte user account (email + password)
- OAuth2 client ID that supports password grant
- Namespace where you have access

---

## 3. Client Mode (Service Authentication)

**Use when:** Testing service-to-service authentication

**Setup:**
1. Create `.env` file:
   ```bash
   cd tests/e2e
   cp .env.example .env
   ```

2. Edit `.env`:
   ```bash
   AUTH_MODE=client
   CLIENT_ID=your-service-client-id
   CLIENT_SECRET=your-service-client-secret
   NAMESPACE=your-namespace
   IAM_URL=https://demo.accelbyte.io/iam
   ```

**Run:**
```bash
set -a && source tests/e2e/.env && set +a && make test-e2e
# or
cd tests/e2e && set -a && source .env && set +a && ./run-all-tests.sh
```

**What you need:**
- OAuth2 client ID with client credentials grant
- OAuth2 client secret
- Namespace where the client has access

---

## Environment Variables Reference

| Variable | Required For | Example |
|----------|--------------|---------|
| `AUTH_MODE` | All modes | `mock`, `password`, or `client` |
| `USER_ID` | Mock mode | `test-user-e2e` |
| `EMAIL` | Password mode | `user@example.com` |
| `PASSWORD` | Password mode | `your-password` |
| `CLIENT_ID` | Password/Client mode | `abc123def456` |
| `CLIENT_SECRET` | Client mode | `secret123` |
| `NAMESPACE` | All modes | `accelbyte` or `your-game` |
| `IAM_URL` | Password/Client mode | `https://demo.accelbyte.io/iam` |

---

## Common Commands

```bash
# Run all tests
make test-e2e

# Run specific test
make test-e2e-login
./tests/e2e/test-login-flow.sh

# Run with custom user ID (mock mode)
USER_ID=alice ./tests/e2e/test-login-flow.sh

# Run with password mode (one-liner)
AUTH_MODE=password \
EMAIL=user@example.com \
PASSWORD=pass123 \
CLIENT_ID=client123 \
NAMESPACE=mygame \
./tests/e2e/test-login-flow.sh

# Show all test targets
make test-e2e-help
```

---

## Troubleshooting

### "Demo app binary not found"
```bash
cd extend-challenge-demo-app
mkdir -p bin
go build -o bin/challenge-demo ./cmd/challenge-demo
cd ..
```

### "Services are not running"
```bash
make dev-up
docker compose ps  # Verify all services are healthy
```

### "jq: command not found"
```bash
# Ubuntu/Debian
sudo apt install jq

# macOS
brew install jq
```

### Authentication failed (password/client mode)
- Double-check credentials in `.env`
- Verify IAM_URL is accessible: `curl https://demo.accelbyte.io/iam/healthz`
- Ensure client has proper permissions
- Check namespace is correct

---

## Next Steps

- Read full documentation: [tests/e2e/README.md](./README.md)
- Understand authentication modes: [TECH_SPEC_AUTHENTICATION.md](../../docs/demo-app/TECH_SPEC_AUTHENTICATION.md)
- Learn about CLI mode: [TECH_SPEC_CLI_MODE.md](../../docs/demo-app/TECH_SPEC_CLI_MODE.md)
