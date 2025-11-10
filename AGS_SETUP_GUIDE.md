# AGS Integration Setup Guide

This guide walks you through setting up AccelByte Gaming Services (AGS) credentials for real reward integration.

## Prerequisites

- Access to an AccelByte Admin Portal (staging or production environment)
- Namespace created in AGS
- Service account with appropriate permissions

## Step 1: Create Service Account

1. **Log in to AccelByte Admin Portal**
   - URL: `https://your-environment.accelbyte.io/admin`
   - Use your admin credentials

2. **Navigate to IAM → Clients**
   - Go to the IAM section in the left sidebar
   - Click on "Clients"

3. **Create New OAuth Client**
   - Click "Create Client"
   - **Client Type**: Select "Service" or "Confidential"
   - **Client Name**: `challenge-service` (or your preferred name)
   - Click "Create"

4. **Save Credentials**
   - Copy the **Client ID** (will look like: `abc123def456`)
   - Copy the **Client Secret** (will look like: `xyz789abc123...`)
   - **IMPORTANT**: Store these securely - the secret is only shown once!

## Step 2: Grant Permissions

Your service account needs permissions to grant rewards.

1. **Navigate to IAM → Roles**
   - Find or create a role with the following permissions:
     - `ADMIN:NAMESPACE:{namespace}:ENTITLEMENT [CREATE, READ]`
     - `ADMIN:NAMESPACE:{namespace}:WALLET [CREATE, READ, UPDATE]`

2. **Assign Role to Service Account**
   - Go back to IAM → Clients
   - Click on your `challenge-service` client
   - Go to "Permissions" or "Roles" tab
   - Assign the role you created/found

Alternatively, if using a predefined role:
- Assign **"Platform Admin"** role (broader permissions)
- Or create custom role with just entitlement and wallet permissions (recommended)

## Step 3: Configure Environment Variables

1. **Edit `.env` file** in the project root:

```bash
# AccelByte AGS Configuration
AB_BASE_URL=https://your-environment.accelbyte.io
AB_CLIENT_ID=your-service-account-client-id
AB_CLIENT_SECRET=your-service-account-client-secret
AB_NAMESPACE=your-namespace

# Enable Real Reward Client
REWARD_CLIENT_MODE=real
```

**Important Notes**:
- `AB_BASE_URL`: Your AGS environment URL (no trailing slash)
- `AB_CLIENT_ID`: The client ID from Step 1
- `AB_CLIENT_SECRET`: The client secret from Step 1
- `AB_NAMESPACE`: Your game namespace (e.g., `mygame-dev`, `mygame-prod`)
- `REWARD_CLIENT_MODE`: Set to `real` to enable actual AGS reward grants

2. **Verify other settings** in `.env`:

```bash
# These should already be set from .env.example
PLUGIN_GRPC_SERVER_AUTH_ENABLED=false  # For local dev, set true in production
DB_HOST=postgres
DB_PORT=5432
# ... other database settings
```

## Step 4: Configure Rewards in AGS

### Required Currencies and Items

Based on the current `challenges.json` configuration, you need to create the following in AGS:

#### Currencies (WALLET rewards)

| Currency Code | Type | Decimals | Used In Goals |
|--------------|------|----------|---------------|
| **GOLD** | VIRTUAL | 0 | complete-tutorial (50), reach-level-5 (100), daily-login (10) |
| **GEMS** | VIRTUAL | 0 | win-1-match (5) |

#### Items (ITEM rewards)

| Item ID | Item Type | Entitleable | Used In Goals |
|---------|-----------|-------------|---------------|
| **winter_sword** | INGAMEITEM | Yes | kill-10-snowmen (qty: 1) |
| **loyalty_badge** | INGAMEITEM | Yes | login-7-days (qty: 1) |
| **daily_chest** | LOOTBOX or INGAMEITEM | Yes | play-3-matches (qty: 1) |

**Important Notes:**
- All currency codes and item IDs are **case-sensitive**
- Items must be **published and active** before testing
- Currencies must exist before rewards can be granted
- The challenge service reads from `extend-challenge-service/config/challenges.json`
- The event handler reads from `extend-challenge-event-handler/config/challenges.json` (must be identical)

### Sample challenges.json Structure

```json
{
  "challenges": [
    {
      "id": "winter-challenge-2025",
      "goals": [
        {
          "id": "complete-tutorial",
          "reward": {
            "type": "WALLET",
            "reward_id": "GOLD",  # Must exist in AGS Platform → Currencies
            "quantity": 50
          }
        },
        {
          "id": "kill-10-snowmen",
          "reward": {
            "type": "ITEM",
            "reward_id": "winter_sword",  # Must exist in AGS Platform → Items
            "quantity": 1
          }
        }
      ]
    }
  ]
}
```

### Creating Currencies in AGS (for WALLET rewards)

1. **Navigate to Platform → Currencies** in AccelByte Admin Portal

2. **Create Currency: GOLD**
   - **Currency Code**: `GOLD` (must match exactly)
   - **Currency Type**: `VIRTUAL`
   - **Decimals**: `0` (whole numbers only)
   - **Display Name**: "Gold Coins"
   - **Save and Publish**

3. **Create Currency: GEMS**
   - **Currency Code**: `GEMS` (must match exactly)
   - **Currency Type**: `VIRTUAL`
   - **Decimals**: `0` (whole numbers only)
   - **Display Name**: "Gems"
   - **Save and Publish**

### Creating Items in AGS (for ITEM rewards)

1. **Navigate to Platform → Items** in AccelByte Admin Portal

2. **Create Item: winter_sword**
   - **Item ID**: `winter_sword` (must match exactly)
   - **Item Type**: `INGAMEITEM`
   - **Name**: "Winter Sword"
   - **Description**: "A legendary sword forged from ice"
   - **Entitleable**: ✓ Check this box (required for rewards)
   - **Status**: Active
   - **Save and Publish**

3. **Create Item: loyalty_badge**
   - **Item ID**: `loyalty_badge` (must match exactly)
   - **Item Type**: `INGAMEITEM`
   - **Name**: "Loyalty Badge"
   - **Description**: "Awarded for logging in 7 days"
   - **Entitleable**: ✓ Check this box (required for rewards)
   - **Status**: Active
   - **Save and Publish**

4. **Create Item: daily_chest**
   - **Item ID**: `daily_chest` (must match exactly)
   - **Item Type**: `LOOTBOX` or `INGAMEITEM` (your choice)
   - **Name**: "Daily Chest"
   - **Description**: "Contains random rewards for daily players"
   - **Entitleable**: ✓ Check this box (required for rewards)
   - **Status**: Active
   - **Save and Publish**

## Step 5: Create Test User

1. **Navigate to IAM → Users**
2. **Create Test User** or use existing user
3. **Note the User ID** (will look like: `abc123456789`)

## Step 6: Restart Services

```bash
# Rebuild and restart with new configuration
make dev-restart

# Check logs to verify AGS connection
make dev-logs
```

Look for log messages like:
```
INFO: AGSRewardClient initialized
INFO: Platform SDK services configured
```

## Step 7: Test Reward Grant

### Using Demo CLI

```bash
cd extend-challenge-demo-app

# Configure demo app with your test user
export DEMO_USER_ID=your-test-user-id
export AB_NAMESPACE=your-namespace

# Trigger event to complete goal
go run main.go events trigger login

# Wait for buffer flush
sleep 2

# Claim reward (will grant via real AGS)
go run main.go challenges claim daily-quests daily-login
```

### Expected Output

```
Claiming reward for goal: daily-login (Challenge: daily-quests)
✓ Reward claimed successfully!
```

Check backend service logs:
```bash
docker-compose logs challenge-service | grep -i "reward"
```

Expected log entries:
```
INFO: Granting ITEM reward: item_id=DAILY_LOGIN_BOX, quantity=1, user_id=abc123...
INFO: Successfully granted entitlement to user
```

### Verify in AGS Admin Portal

**For ITEM rewards**:
1. Navigate to **Platform → Entitlements**
2. Search by User ID
3. Verify entitlement created with:
   - Item ID: `DAILY_LOGIN_BOX`
   - Quantity: 1
   - Status: Active

**For WALLET rewards**:
1. Navigate to **Platform → Wallets**
2. Search by User ID
3. Verify wallet credited with:
   - Currency: `GOLD`
   - Amount: +100

---

## Step 7: Verify Rewards with Demo App (Phase 8 - Planned)

**Status**: ⏳ Planned feature (not yet implemented)

Once Phase 8 is complete, the demo app will include built-in reward verification commands and TUI screens to check entitlements and wallets directly from the CLI or TUI.

### CLI Verification Commands

**Check specific entitlement:**
```bash
challenge-demo verify-entitlement --item-id=winter_sword --format=json
```

**Expected output:**
```json
{
  "item_id": "winter_sword",
  "entitlement_id": "ent-abc123",
  "status": "ACTIVE",
  "quantity": 1,
  "granted_at": "2025-10-22T10:30:00Z",
  "namespace": "mygame"
}
```

**Check wallet balance:**
```bash
challenge-demo verify-wallet --currency=GOLD --format=json
```

**Expected output:**
```json
{
  "currency_code": "GOLD",
  "balance": 150,
  "wallet_id": "wallet-xyz789",
  "status": "ACTIVE",
  "namespace": "mygame"
}
```

**List all entitlements:**
```bash
challenge-demo list-inventory --format=table
```

**List all wallets:**
```bash
challenge-demo list-wallets --format=table
```

### TUI Inventory Screen

**Access inventory screen:**
1. Launch demo app in TUI mode: `./challenge-demo`
2. Press **'i'** key to open Inventory & Wallets screen
3. View two panels side-by-side:
   - **Left panel**: Item entitlements
   - **Right panel**: Wallet balances
4. Press **'r'** to refresh from AGS Platform
5. Press **'Esc'** to return to main screen

**Benefits of built-in verification:**
- ✅ No need to manually check AGS Admin Portal
- ✅ Verify rewards immediately after claiming
- ✅ Debug reward grant issues faster
- ✅ Complete end-to-end testing (claim → grant → verify)
- ✅ Works from both CLI and TUI modes

**Requirements:**
- Same AGS credentials as backend service (`AB_CLIENT_ID`, `AB_CLIENT_SECRET`)
- User authenticated with `--auth-mode=password` or `--auth-mode=client`
- Demo app will use same Platform SDK as backend service

---

## Troubleshooting

### Error: "401 Unauthorized"

**Cause**: Invalid client credentials or token expired

**Fix**:
1. Verify `AB_CLIENT_ID` and `AB_CLIENT_SECRET` are correct
2. Check client is active in AGS Admin Portal
3. Service token should auto-refresh (check logs for refresh errors)

### Error: "403 Forbidden"

**Cause**: Service account lacks permissions

**Fix**:
1. Verify service account has entitlement and wallet permissions
2. Check namespace matches (`AB_NAMESPACE` in .env)
3. Ensure permissions are for the correct namespace

### Error: "404 Not Found - Item not found"

**Cause**: Item ID doesn't exist in AGS

**Fix**:
1. Verify all required items are created (see Step 4):
   - `winter_sword`
   - `loyalty_badge`
   - `daily_chest`
2. Check item IDs in `challenges.json` match exactly (case-sensitive)
3. Verify items are **published and active** in AGS
4. Confirm correct namespace matches `AB_NAMESPACE` in .env

### Error: "404 Not Found - Currency not found"

**Cause**: Currency code doesn't exist in AGS

**Fix**:
1. Verify all required currencies are created (see Step 4):
   - `GOLD`
   - `GEMS`
2. Check currency codes in `challenges.json` match exactly (case-sensitive)
3. Verify currencies are **published** in AGS
4. Confirm correct namespace matches `AB_NAMESPACE` in .env

### Error: "422 Unprocessable Entity"

**Cause**: Invalid request parameters (e.g., quantity overflow)

**Fix**:
1. Check quantity doesn't exceed int32 max (2,147,483,647)
2. Verify item type supports entitlement grants
3. Verify currency exists for wallet grants (GOLD, GEMS)

### Service logs show "Retry attempt 1/3"

**This is normal** - The service automatically retries on transient errors:
- 502 Bad Gateway
- 503 Service Unavailable
- Network timeouts

If retries succeed, the claim will complete. Check logs for final success/failure.

### Error: "Transaction timeout"

**Cause**: AGS Platform took too long to respond (> 10s)

**Fix**:
1. Check AGS Platform status/health
2. Verify network connectivity to AGS
3. Consider increasing timeout in future if needed (default: 10s)

## Production Deployment

For production deployment to AccelByte Extend:

1. **Use Production Service Account**:
   - Create separate service account for production
   - Use production namespace
   - Never commit credentials to git

2. **Environment Variables**:
   - Set `PLUGIN_GRPC_SERVER_AUTH_ENABLED=true`
   - Use Kubernetes secrets for `AB_CLIENT_SECRET`
   - Set `REWARD_CLIENT_MODE=real`

3. **Monitoring**:
   - Monitor reward grant success/failure rates
   - Alert on high retry rates
   - Track AGS Platform latency

See [docs/TECH_SPEC_DEPLOYMENT.md](docs/TECH_SPEC_DEPLOYMENT.md) for full production deployment guide.

## Reference

- **AGS Platform Docs**: https://docs.accelbyte.io/gaming-services/services/platform/
- **IAM Service Accounts**: https://docs.accelbyte.io/gaming-services/services/iam/clients/
- **Entitlement API**: https://docs.accelbyte.io/gaming-services/services/platform/entitlement/
- **Wallet API**: https://docs.accelbyte.io/gaming-services/services/platform/wallet/
