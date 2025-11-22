#!/bin/bash
# E2E Test Helper Functions
# Location: tests/e2e/helpers.sh
#
# Usage:
#   1. Mock Mode (default - for local testing):
#      ./test-login-flow.sh
#
#   2. Password Mode (real user authentication):
#      AUTH_MODE=password \
#      EMAIL=user@example.com \
#      PASSWORD=yourpassword \
#      CLIENT_ID=your-client-id \
#      IAM_URL=https://demo.accelbyte.io/iam \
#      NAMESPACE=your-namespace \
#      ./test-login-flow.sh
#
#   3. Dual Token Mode (user + admin for Platform verification):
#      AUTH_MODE=password \
#      EMAIL=user@example.com \
#      PASSWORD=yourpassword \
#      CLIENT_ID=your-client-id \
#      ADMIN_CLIENT_ID=admin-client-id \
#      ADMIN_CLIENT_SECRET=admin-client-secret \
#      IAM_URL=https://demo.accelbyte.io/iam \
#      PLATFORM_URL=https://demo.accelbyte.io/platform \
#      NAMESPACE=your-namespace \
#      ./test-login-flow.sh
#
#   4. Using .env file (recommended):
#      cp .env.example .env
#      # Edit .env with your credentials
#      set -a && source .env && set +a && ./test-login-flow.sh
#
# Note: set -a enables auto-export of variables so they're available to the script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration (can be overridden by environment variables)
DEMO_APP="${DEMO_APP:-../../extend-challenge-demo-app/bin/challenge-demo}"
USER_ID="${USER_ID:-test-user-e2e}"
NAMESPACE="${NAMESPACE:-test}"
BACKEND_URL="${BACKEND_URL:-http://localhost:8000/challenge}"
EVENT_HANDLER_URL="${EVENT_HANDLER_URL:-localhost:6566}"

# Authentication configuration
# AUTH_MODE: mock | password | client
# - mock: Use mock JWT with USER_ID (default for testing)
# - password: Use real user authentication (requires EMAIL, PASSWORD, CLIENT_ID, IAM_URL)
# - client: Use client credentials (requires CLIENT_ID, CLIENT_SECRET, IAM_URL)
AUTH_MODE="${AUTH_MODE:-mock}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-}"
CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
IAM_URL="${IAM_URL:-https://demo.accelbyte.io/iam}"

# Admin credentials for Platform Service verification (dual token mode)
# Required for verifying rewards in real AGS Platform Service
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-}"
ADMIN_CLIENT_SECRET="${ADMIN_CLIENT_SECRET:-}"
PLATFORM_URL="${PLATFORM_URL:-https://demo.accelbyte.io/platform}"

# Assert equals
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}Expected:${NC} $expected"
        echo -e "  ${BLUE}Actual:${NC}   $actual"
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
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}Should not equal:${NC} $expected"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Assert contains (check if string contains substring)
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}String:${NC} $haystack"
        echo -e "  ${BLUE}Should contain:${NC} $needle"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Assert greater than or equal
assert_gte() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    if [ "$actual" -lt "$expected" ]; then
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}Expected:${NC} >= $expected"
        echo -e "  ${BLUE}Actual:${NC}   $actual"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Extract JSON value using jq
extract_json_value() {
    local json="$1"
    local jq_filter="$2"
    
    # Check if json is empty
    if [ -z "$json" ]; then
        echo -e "${RED}❌ ERROR${NC}: Empty JSON response" >&2
        echo -e "  Filter: $jq_filter" >&2
        return 1
    fi
    
    # Try to parse JSON and capture errors
    local result
    if ! result=$(echo "$json" | jq -r "$jq_filter" 2>&1); then
        echo -e "${RED}❌ ERROR${NC}: Failed to parse JSON" >&2
        echo -e "  Filter: $jq_filter" >&2
        echo -e "  JSON: ${json:0:200}..." >&2
        echo -e "  jq error: $result" >&2
        return 1
    fi
    
    echo "$result"
}

# Extract JSON from mixed output (log lines + JSON)
# The demo app outputs log lines to stderr/stdout mixed with JSON
# This function extracts only the JSON object/array part
extract_json_from_output() {
    local output="$1"

    # Extract lines starting with { or [ (JSON start)
    # and everything until the matching closing brace/bracket
    echo "$output" | sed -n '/{/,/}/p' | grep -v "^[0-9]"
}

# Extract user ID from JWT token (decode the "sub" claim from JWT payload)
# Parameters:
#   $1: JWT token (format: header.payload.signature)
# Returns: user ID from the "sub" claim
extract_user_id_from_jwt() {
    local token="$1"

    if [ -z "$token" ]; then
        echo ""
        return 1
    fi

    # JWT format: header.payload.signature
    # Extract the payload (second part)
    local payload=$(echo "$token" | cut -d'.' -f2)

    # Add padding if necessary (base64 requires padding)
    local padding_len=$((4 - ${#payload} % 4))
    if [ $padding_len -ne 4 ]; then
        payload="${payload}$(printf '=%.0s' $(seq 1 $padding_len))"
    fi

    # Decode base64 and extract "sub" claim using jq
    local user_id=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.sub // empty')

    echo "$user_id"
}

# Validate USER_ID for password mode
# In password mode, USER_ID must be set to match the actual AGS user ID
validate_user_id_for_password_mode() {
    if [ "$AUTH_MODE" != "password" ]; then
        return 0
    fi

    # Check if USER_ID is still the default value
    if [ "$USER_ID" = "test-user-e2e" ]; then
        echo -e "${RED}❌ ERROR${NC}: When using AUTH_MODE=password, you must set USER_ID in .env"
        echo ""
        echo "The USER_ID must match your actual AGS user ID (from the JWT token's 'sub' claim)."
        echo ""
        echo "To find your user ID:"
        echo "  1. Log in to AGS Admin Portal"
        echo "  2. Go to IAM > Users > Find your user"
        echo "  3. Copy the User ID"
        echo "  4. Add to .env: USER_ID=your-actual-user-id"
        echo ""
        echo "Alternatively, you can use mock mode for testing:"
        echo "  AUTH_MODE=mock"
        echo ""
        exit 1
    fi

    echo -e "${GREEN}✓${NC} USER_ID configured for password mode: $USER_ID"
}

# Wait for buffer flush (configurable delay)
wait_for_flush() {
    local seconds="${1:-2}"
    echo -e "${BLUE}⏳${NC} Waiting ${seconds}s for buffer flush..."
    sleep "$seconds"
}

# Cleanup test data (delete user_goal_progress for test user)
cleanup_test_data() {
    echo -e "${BLUE}🧹${NC} Cleaning up test data for user: $USER_ID"
    # Connect to postgres via docker-compose service name
    docker compose exec -T postgres \
        psql -U postgres -d challenge_db \
        -c "DELETE FROM user_goal_progress WHERE user_id = '$USER_ID';" \
        > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Test data cleaned"
    else
        echo -e "${YELLOW}⚠${NC} Warning: Could not clean test data (this is OK if user had no data)"
    fi
}

# Run demo app command with common flags
run_cli() {
    # Build base command
    local cmd="$DEMO_APP \
        --backend-url=$BACKEND_URL \
        --event-handler-url=$EVENT_HANDLER_URL \
        --namespace=$NAMESPACE \
        --auth-mode=$AUTH_MODE"

    # Add auth-specific flags based on mode
    case "$AUTH_MODE" in
        mock)
            cmd="$cmd --user-id=$USER_ID"
            ;;
        password)
            if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
                echo -e "${RED}❌ ERROR${NC}: AUTH_MODE=password requires EMAIL, PASSWORD, CLIENT_ID, and CLIENT_SECRET"
                exit 1
            fi
            cmd="$cmd --email=$EMAIL --password=$PASSWORD --client-id=$CLIENT_ID --client-secret=$CLIENT_SECRET --iam-url=$IAM_URL"

            # Add platform URL if provided (optional for some commands, required for Platform SDK operations)
            if [ -n "$PLATFORM_URL" ]; then
                cmd="$cmd --platform-url=$PLATFORM_URL"
            fi

            # Add admin credentials if provided (optional - for dual token mode)
            if [ -n "$ADMIN_CLIENT_ID" ] && [ -n "$ADMIN_CLIENT_SECRET" ]; then
                cmd="$cmd --admin-client-id=$ADMIN_CLIENT_ID --admin-client-secret=$ADMIN_CLIENT_SECRET"
            fi
            ;;
        client)
            if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
                echo -e "${RED}❌ ERROR${NC}: AUTH_MODE=client requires CLIENT_ID and CLIENT_SECRET"
                exit 1
            fi
            cmd="$cmd --client-id=$CLIENT_ID --client-secret=$CLIENT_SECRET --iam-url=$IAM_URL"
            ;;
        *)
            echo -e "${RED}❌ ERROR${NC}: Invalid AUTH_MODE: $AUTH_MODE (must be: mock, password, or client)"
            exit 1
            ;;
    esac

    # Execute command with additional arguments
    local output
    local exit_code
    
    # Capture both stdout and stderr, and the exit code
    output=$(eval "$cmd $*" 2>&1)
    exit_code=$?
    
    # If command failed, show detailed error
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}❌ CLI Command Failed${NC}" >&2
        echo -e "  Command: $cmd $*" >&2
        echo -e "  Exit code: $exit_code" >&2
        echo -e "  Output:" >&2
        echo "$output" | head -20 | sed 's/^/    /' >&2
        return $exit_code
    fi
    
    # If format=json is requested, extract only the JSON part (filter out log lines)
    # The demo app outputs log lines like "2025/11/10 15:09:17 ..." mixed with JSON
    if [[ "$*" == *"--format=json"* ]] || [[ "$*" == *"format=json"* ]]; then
        # Extract only JSON (lines starting with { or [, or continuation lines)
        # Filter out lines that look like log timestamps
        output=$(echo "$output" | grep -v "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}" || echo "$output")
    fi
    
    echo "$output"
}

# Check if demo app binary exists
check_demo_app() {
    if [ ! -f "$DEMO_APP" ]; then
        echo -e "${RED}❌ ERROR${NC}: Demo app binary not found at: $DEMO_APP"
        echo "Please build the demo app first:"
        echo "  From the suite root: make build-demo-app"
        echo "  Or manually: cd extend-challenge-demo-app && mkdir -p bin && go build -o bin/challenge-demo ./cmd/challenge-demo"
        exit 1
    fi
}

# Check if services are running
check_services() {
    echo -e "${BLUE}🔍${NC} Checking if services are running..."

    # Check if docker-compose services are up
    if ! docker compose ps | grep -q "challenge-service"; then
        echo -e "${RED}❌ ERROR${NC}: Services are not running"
        echo "Please start services first:"
        echo "  make dev-up"
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Services are running"
}

# Print test header
print_test_header() {
    local test_name="$1"
    echo ""
    echo "=========================================="
    echo "  $test_name"
    echo "=========================================="
    echo ""
}

# Print step header
print_step() {
    local step_num="$1"
    local step_desc="$2"
    
    # Store current step for error reporting
    export CURRENT_TEST_STEP="Step $step_num: $step_desc"
    
    echo ""
    echo -e "${BLUE}Step $step_num:${NC} $step_desc"
}

# Print success message
print_success() {
    local message="$1"
    echo ""
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}: $message"
}

# Print error and exit
error_exit() {
    local message="$1"
    echo -e "${RED}❌ ERROR${NC}: $message"
    exit 1
}

# Run verification command with admin credentials (dual token mode)
# Uses admin client credentials for Platform Service verification
run_verification_with_client() {
    # Check if admin credentials are provided
    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo -e "${YELLOW}⚠${NC} Warning: Admin credentials not provided, skipping AGS verification"
        echo "  To enable verification, set: ADMIN_CLIENT_ID and ADMIN_CLIENT_SECRET"
        return 0
    fi

    # Build command with admin credentials
    local cmd="$DEMO_APP \
        --backend-url=$BACKEND_URL \
        --namespace=$NAMESPACE \
        --auth-mode=password \
        --email=$EMAIL \
        --password=$PASSWORD \
        --client-id=$CLIENT_ID \
        --client-secret=$CLIENT_SECRET \
        --admin-client-id=$ADMIN_CLIENT_ID \
        --admin-client-secret=$ADMIN_CLIENT_SECRET \
        --iam-url=$IAM_URL \
        --platform-url=$PLATFORM_URL"

    # Execute command with additional arguments
    local output
    local exit_code
    
    # Capture both stdout and stderr, and the exit code
    output=$(eval "$cmd $*" 2>&1)
    exit_code=$?
    
    # If command failed, show detailed error
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}❌ Verification Command Failed${NC}" >&2
        echo -e "  Command: $cmd $*" >&2
        echo -e "  Exit code: $exit_code" >&2
        echo -e "  Output:" >&2
        echo "$output" | head -20 | sed 's/^/    /' >&2
        return $exit_code
    fi
    
    # If format=json is requested, extract only the JSON part (filter out log lines)
    if [[ "$*" == *"--format=json"* ]] || [[ "$*" == *"format=json"* ]]; then
        output=$(echo "$output" | grep -v "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}" || echo "$output")
    fi
    
    echo "$output"
}

# Verify that an entitlement was granted in AGS Platform Service
# Parameters:
#   $1: item_id (UUID of the item)
# Returns: 0 if entitlement found, 1 otherwise
verify_entitlement_granted() {
    local item_id="$1"

    if [ -z "$item_id" ]; then
        error_exit "verify_entitlement_granted: item_id parameter is required"
    fi

    echo -e "${BLUE}🔍${NC} Verifying entitlement for item: $item_id"

    # Skip verification if admin credentials not provided
    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo -e "${YELLOW}⚠${NC} Skipping entitlement verification (no admin credentials)"
        return 0
    fi

    # Wait for Platform Service to propagate the entitlement grant
    echo -e "${BLUE}⏳${NC} Waiting 3 seconds for Platform Service to propagate entitlement grant..."
    sleep 3

    # Retry up to 3 times with 2-second delays
    local max_retries=3
    local retry_delay=2

    for attempt in $(seq 1 $max_retries); do
        echo -e "${BLUE}🔍${NC} Querying entitlement (attempt $attempt/$max_retries)..."

        # Query entitlement using admin credentials
        local result=$(run_verification_with_client verify-entitlement --item-id="$item_id" --format=json 2>&1 || true)

        # Check if entitlement was found
        if echo "$result" | grep -qi "\"status\".*:.*\"ACTIVE\""; then
            # Extract JSON from mixed output (removes log lines)
            local json=$(extract_json_from_output "$result")
            local entitlement_id=$(extract_json_value "$json" '.entitlementId // .entitlement_id // "unknown"')
            local quantity=$(extract_json_value "$json" '.quantity // 1')
            echo -e "${GREEN}✓${NC} Entitlement verified: ID=$entitlement_id, Quantity=$quantity"
            return 0
        elif echo "$result" | grep -qi "error\|not found\|failed"; then
            if [ $attempt -lt $max_retries ]; then
                echo -e "${YELLOW}⚠${NC} Entitlement not found yet, waiting ${retry_delay}s before retry..."
                sleep $retry_delay
            else
                echo -e "${RED}✗${NC} Entitlement NOT found for item: $item_id after $max_retries attempts"
                echo "  Last result: $result"
            fi
        else
            echo -e "${YELLOW}⚠${NC} Unable to verify entitlement (unexpected response)"
            echo "  Result: $result"
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
            fi
        fi
    done

    # All retries exhausted
    echo -e "${RED}✗${NC} Entitlement verification failed"
    echo -e "${YELLOW}ℹ${NC} This might indicate:"
    echo "  - Platform Service eventual consistency delay (rare)"
    echo "  - Entitlement grant failed in Platform Service (check challenge-service logs)"
    echo "  - Admin credentials don't have permission to query user entitlements"
    return 1
}

# Verify wallet balance in AGS Platform Service
# Parameters:
#   $1: currency_code (e.g., GOLD, GEM)
#   $2: expected_min_balance (optional - minimum expected balance)
# Returns: 0 if wallet found, 1 otherwise
verify_wallet_balance() {
    local currency_code="$1"
    local expected_min="${2:-0}"

    if [ -z "$currency_code" ]; then
        error_exit "verify_wallet_balance: currency_code parameter is required"
    fi

    echo -e "${BLUE}🔍${NC} Verifying wallet balance for currency: $currency_code"

    # Skip verification if admin credentials not provided
    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo -e "${YELLOW}⚠${NC} Skipping wallet verification (no admin credentials)"
        return 0
    fi

    # Query wallet using admin credentials
    local result=$(run_verification_with_client verify-wallet --currency="$currency_code" --format=json 2>&1 || true)

    # Check if wallet was found
    if echo "$result" | grep -qi "\"balance\""; then
        local balance=$(extract_json_value "$result" '.balance // 0')
        echo -e "${GREEN}✓${NC} Wallet found: Currency=$currency_code, Balance=$balance"

        # Check minimum balance if specified
        if [ "$expected_min" -gt 0 ]; then
            if [ "$balance" -ge "$expected_min" ]; then
                echo -e "${GREEN}✓${NC} Balance meets minimum requirement (>= $expected_min)"
                return 0
            else
                echo -e "${RED}✗${NC} Balance below minimum: $balance < $expected_min"
                return 1
            fi
        fi
        return 0
    elif echo "$result" | grep -qi "error\|not found\|failed"; then
        echo -e "${RED}✗${NC} Wallet NOT found for currency: $currency_code"
        echo "  Result: $result"
        return 1
    else
        echo -e "${YELLOW}⚠${NC} Unable to verify wallet (unexpected response)"
        echo "  Result: $result"
        return 1
    fi
}

# Get wallet balance before test (for comparison)
# Parameters:
#   $1: currency_code
# Returns: balance as integer, or 0 if not found
get_initial_wallet_balance() {
    local currency_code="$1"

    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo "0"
        return 0
    fi

    local result=$(run_verification_with_client verify-wallet --currency="$currency_code" --format=json 2>&1 || true)

    if echo "$result" | grep -qi "\"balance\""; then
        # Extract JSON from mixed output (removes log lines)
        local json=$(extract_json_from_output "$result")
        local balance=$(extract_json_value "$json" '.balance // 0')
        echo "$balance"
    else
        echo "0"
    fi
}

# Verify wallet balance increased by expected amount
# Parameters:
#   $1: currency_code
#   $2: initial_balance
#   $3: expected_increase
verify_wallet_increased() {
    local currency_code="$1"
    local initial_balance="$2"
    local expected_increase="$3"

    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo -e "${YELLOW}⚠${NC} Skipping wallet increase verification (no admin credentials)"
        return 0
    fi

    # Wait for Platform Service to propagate the wallet update
    # Challenge Service writes to Platform Service, but there may be a delay
    # before the update is visible in queries (eventual consistency)
    echo -e "${BLUE}⏳${NC} Waiting 3 seconds for Platform Service to propagate wallet update..."
    sleep 3

    # Retry up to 3 times with 2-second delays (total 6 seconds + initial 3 second wait)
    local max_retries=3
    local retry_delay=2
    local current_balance=0

    for attempt in $(seq 1 $max_retries); do
        current_balance=$(get_initial_wallet_balance "$currency_code")
        local expected_balance=$((initial_balance + expected_increase))

        echo -e "${BLUE}🔍${NC} Verifying wallet increase (attempt $attempt/$max_retries):"
        echo "  Initial balance: $initial_balance"
        echo "  Expected increase: +$expected_increase"
        echo "  Expected final balance: $expected_balance"
        echo "  Actual balance: $current_balance"

        if [ "$current_balance" -ge "$expected_balance" ]; then
            echo -e "${GREEN}✓${NC} Wallet balance increased as expected"
            return 0
        else
            if [ $attempt -lt $max_retries ]; then
                echo -e "${YELLOW}⚠${NC} Balance not updated yet, waiting ${retry_delay}s before retry..."
                sleep $retry_delay
            fi
        fi
    done

    # All retries exhausted
    echo -e "${RED}✗${NC} Wallet balance did not increase as expected after $max_retries attempts"
    echo -e "${YELLOW}ℹ${NC} This might indicate:"
    echo "  - Platform Service eventual consistency delay (rare)"
    echo "  - Wallet credit failed in Platform Service (check challenge-service logs)"
    echo "  - Admin credentials don't have permission to query user wallets"
    return 1
}

# =====================================================
# M3: Goal Assignment Control Functions
# =====================================================

# Initialize player goals (M3 feature)
# Assigns default goals to the player based on challenge configuration
initialize_player() {
    run_cli initialize-player --format=json
}

# Activate goal (M3 feature)
# Usage: activate_goal <challenge-id> <goal-id>
activate_goal() {
    local challenge_id=$1
    local goal_id=$2
    run_cli set-goal-active "$challenge_id" "$goal_id" --active=true --format=json
}

# Deactivate goal (M3 feature)
# Usage: deactivate_goal <challenge-id> <goal-id>
deactivate_goal() {
    local challenge_id=$1
    local goal_id=$2
    run_cli set-goal-active "$challenge_id" "$goal_id" --active=false --format=json
}

# List active challenges only (M3 feature)
# Returns JSON array of challenges with only active goals
list_active_challenges() {
    run_cli list-challenges --active-only --format=json
}

# Check if goal is active in JSON response
# Usage: is_goal_active <json> <goal-id>
# Returns: 0 if active, 1 if inactive or not found
is_goal_active() {
    local json=$1
    local goal_id=$2

    local is_active=$(echo "$json" | jq -r ".challenges[].goals[] | select(.goalId == \"$goal_id\") | .isActive // false" 2>/dev/null)

    if [ "$is_active" == "true" ]; then
        return 0
    else
        return 1
    fi
}

# Count active goals in JSON response
# Usage: count_active_goals <json>
# Returns: Number of active goals
count_active_goals() {
    local json=$1
    echo "$json" | jq '[.challenges[].goals[] | select(.isActive == true)] | length' 2>/dev/null || echo "0"
}

# =====================================================
# AGS User Management Functions (for multi-user testing)
# =====================================================

# Get admin OAuth2 token using client credentials
# Returns: access_token or empty string on failure
get_admin_token() {
    if [ -z "$ADMIN_CLIENT_ID" ] || [ -z "$ADMIN_CLIENT_SECRET" ]; then
        echo -e "${RED}❌ ERROR${NC}: get_admin_token requires ADMIN_CLIENT_ID and ADMIN_CLIENT_SECRET"
        return 1
    fi

    local token_response=$(curl -s -X POST "$IAM_URL/v3/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$ADMIN_CLIENT_ID:$ADMIN_CLIENT_SECRET" \
        -d "grant_type=client_credentials" 2>&1)

    if [ $? -ne 0 ]; then
        echo -e "${RED}✗${NC} Failed to get admin token: curl error"
        return 1
    fi

    local access_token=$(echo "$token_response" | jq -r '.access_token // empty')

    if [ -z "$access_token" ]; then
        echo -e "${RED}✗${NC} Failed to get admin token"
        echo "  Response: $token_response"
        return 1
    fi

    echo "$access_token"
}

# Create test users via AGS IAM API
# Parameters:
#   $1: count - number of users to create (max 100)
# Returns: JSON array of created users
# Example output: [{"userId":"uuid1","username":"test_user_1","emailAddress":"test_user_1@test.com","password":"pass123"}]
create_test_users() {
    local count="$1"

    if [ -z "$count" ]; then
        echo -e "${RED}❌ ERROR${NC}: create_test_users requires count parameter"
        return 1
    fi

    if [ "$count" -gt 100 ]; then
        echo -e "${RED}❌ ERROR${NC}: Maximum 100 test users can be created at once"
        return 1
    fi

    echo -e "${BLUE}🔧${NC} Creating $count test users via AGS IAM API..." >&2

    local admin_token=$(get_admin_token)

    if [ -z "$admin_token" ]; then
        echo -e "${RED}❌ ERROR${NC}: Failed to get admin token" >&2
        return 1
    fi

    # Try test_users endpoint first (no verification email)
    # POST /iam/v4/admin/namespaces/{namespace}/test_users
    local create_response=$(curl -s -X POST \
        "$IAM_URL/v4/admin/namespaces/$NAMESPACE/test_users" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"count\": $count, \"userInfo\": {\"country\": \"US\"}}" 2>&1)

    # Check if it's a permission error
    if echo "$create_response" | jq -e '.errorCode == 20013' > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠${NC} Test user endpoint requires additional permissions" >&2
        echo -e "${BLUE}🔧${NC} Falling back to regular user creation (one by one)..." >&2

        # Fall back to creating users one by one
        local users_json="["
        local timestamp=$(date +%s)

        for i in $(seq 1 $count); do
            local username="e2e_test_user_${timestamp}_${i}"
            local email="${username}@test.accelbyte.io"
            local password="TestPass123!"
            local dob="1990-01-01"

            # POST /iam/v4/admin/namespaces/{namespace}/users
            local user_response=$(curl -s -X POST \
                "$IAM_URL/v4/admin/namespaces/$NAMESPACE/users" \
                -H "Authorization: Bearer $admin_token" \
                -H "Content-Type: application/json" \
                -d "{
                    \"authType\": \"EMAILPASSWD\",
                    \"emailAddress\": \"$email\",
                    \"username\": \"$username\",
                    \"password\": \"$password\",
                    \"country\": \"US\",
                    \"dateOfBirth\": \"$dob\"
                }" 2>&1)

            # Check if user was created
            local user_id=$(echo "$user_response" | jq -r '.userId // empty')

            if [ -z "$user_id" ]; then
                echo -e "${RED}✗${NC} Failed to create user $i" >&2
                echo "  Response: $user_response" >&2
                return 1
            fi

            # Add to array (with comma except for first)
            if [ $i -gt 1 ]; then
                users_json+=","
            fi

            users_json+="{\"userId\":\"$user_id\",\"username\":\"$username\",\"emailAddress\":\"$email\",\"password\":\"$password\"}"

            echo "  Created user $i: $email (ID: $user_id)" >&2
        done

        users_json+="]"
        create_response="$users_json"
    else
        # Check if test_users response has data array (AGS test user endpoint format)
        if echo "$create_response" | jq -e '.data | type == "array"' > /dev/null 2>&1; then
            # Extract data array from response
            create_response=$(echo "$create_response" | jq -c '.data')
        elif ! echo "$create_response" | jq -e 'type == "array"' > /dev/null 2>&1; then
            echo -e "${RED}✗${NC} Failed to create test users" >&2
            echo "  Response: $create_response" >&2
            return 1
        fi
    fi

    local created_count=$(echo "$create_response" | jq 'length')
    echo -e "${GREEN}✓${NC} Created $created_count test users" >&2

    echo "$create_response"
}

# Get user ID by email address
# Parameters:
#   $1: email - email address to search for
# Returns: user_id or empty string if not found
get_user_id_by_email() {
    local email="$1"

    if [ -z "$email" ]; then
        echo -e "${RED}❌ ERROR${NC}: get_user_id_by_email requires email parameter"
        return 1
    fi

    local admin_token=$(get_admin_token)

    if [ -z "$admin_token" ]; then
        return 1
    fi

    # Search user by email using AGS IAM API
    # GET /iam/v3/admin/namespaces/{namespace}/users?emailAddress={email}
    local url_encoded_email=$(echo "$email" | jq -sRr @uri)
    local search_response=$(curl -s -X GET \
        "$IAM_URL/v3/admin/namespaces/$NAMESPACE/users?emailAddress=$url_encoded_email" \
        -H "Authorization: Bearer $admin_token" 2>&1)

    if [ $? -ne 0 ]; then
        return 1
    fi

    local user_id=$(echo "$search_response" | jq -r '.userId // empty')
    echo "$user_id"
}

# Delete test user via AGS IAM API
# Parameters:
#   $1: user_id - user ID to delete
# Returns: 0 on success, 1 on failure
delete_test_user() {
    local user_id="$1"

    if [ -z "$user_id" ]; then
        echo -e "${RED}❌ ERROR${NC}: delete_test_user requires user_id parameter"
        return 1
    fi

    local admin_token=$(get_admin_token)

    if [ -z "$admin_token" ]; then
        return 1
    fi

    # Delete user using AGS IAM API
    # DELETE /iam/v3/admin/namespaces/{namespace}/users/{userId}/information
    local delete_response=$(curl -s -w "\n%{http_code}" -X DELETE \
        "$IAM_URL/v3/admin/namespaces/$NAMESPACE/users/$user_id/information" \
        -H "Authorization: Bearer $admin_token" 2>&1)

    local http_code=$(echo "$delete_response" | tail -n1)
    local response_body=$(echo "$delete_response" | sed '$d')

    if [ "$http_code" = "204" ] || [ "$http_code" = "404" ]; then
        # 204 = deleted successfully, 404 = already deleted
        return 0
    else
        echo -e "${RED}✗${NC} Failed to delete user $user_id (HTTP $http_code)"
        if [ -n "$response_body" ]; then
            echo "  Response: $response_body"
        fi
        return 1
    fi
}

# Delete test user by email address
# Parameters:
#   $1: email - email address to delete
# Returns: 0 on success, 1 on failure
delete_test_user_by_email() {
    local email="$1"

    if [ -z "$email" ]; then
        echo -e "${RED}❌ ERROR${NC}: delete_test_user_by_email requires email parameter"
        return 1
    fi

    local user_id=$(get_user_id_by_email "$email")

    if [ -z "$user_id" ]; then
        # User not found, consider it already deleted
        return 0
    fi

    delete_test_user "$user_id"
}

# =====================================================
# M4: Batch & Random Goal Selection Functions
# =====================================================

# Batch select goals (M4 feature)
# Usage: batch_select_goals <challenge-id> "goal1,goal2,goal3" [replace_existing_bool]
batch_select_goals() {
    local challenge_id="$1"
    local goal_ids="$2"
    local replace_existing="${3:-false}"
    
    if [ -z "$challenge_id" ]; then
        error_exit "batch_select_goals requires challenge_id parameter"
    fi
    
    run_cli batch-select "$challenge_id" \
        --goal-ids="$goal_ids" \
        --replace-existing="$replace_existing" \
        --format=json
}

# Random select goals (M4 feature)
# Usage: random_select_goals <challenge-id> <count> [replace_existing_bool] [exclude_active_bool]
random_select_goals() {
    local challenge_id="$1"
    local count="$2"
    local replace_existing="${3:-false}"
    local exclude_active="${4:-false}"
    
    if [ -z "$challenge_id" ] || [ -z "$count" ]; then
        error_exit "random_select_goals requires challenge_id and count parameters"
    fi
    
    run_cli random-select "$challenge_id" \
        --count="$count" \
        --replace-existing="$replace_existing" \
        --exclude-active="$exclude_active" \
        --format=json
}

# Get specific goal progress value from JSON response
# Usage: get_goal_progress <json> <goal-id>
# Returns: Progress value as integer
get_goal_progress() {
    local json="$1"
    local goal_id="$2"
    
    if [ -z "$json" ] || [ -z "$goal_id" ]; then
        error_exit "get_goal_progress requires json and goal_id parameters"
    fi
    
    echo "$json" | jq -r ".challenges[].goals[] | select(.goalId == \"$goal_id\") | .progress // 0" 2>/dev/null || echo "0"
}

# Get specific goal active status from JSON response
# Usage: get_goal_active_status <json> <goal-id>
# Returns: "true" or "false"
get_goal_active_status() {
    local json="$1"
    local goal_id="$2"
    
    if [ -z "$json" ] || [ -z "$goal_id" ]; then
        error_exit "get_goal_active_status requires json and goal_id parameters"
    fi
    
    echo "$json" | jq -r ".challenges[].goals[] | select(.goalId == \"$goal_id\") | .isActive // false" 2>/dev/null || echo "false"
}

# Assert less than or equal
# Usage: assert_lte <actual> <expected> <message>
assert_lte() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    
    if [ "$actual" -gt "$expected" ]; then
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}Expected:${NC} <= $expected"
        echo -e "  ${BLUE}Actual:${NC}   $actual"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Assert not contains (check if string does NOT contain substring)
# Usage: assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo ""
        echo -e "${RED}❌ ASSERTION FAILED${NC}"
        if [ -n "$CURRENT_TEST_STEP" ]; then
            echo -e "  ${BLUE}During:${NC} $CURRENT_TEST_STEP"
        fi
        echo -e "  ${BLUE}Message:${NC} $message"
        echo -e "  ${BLUE}String:${NC} $haystack"
        echo -e "  ${BLUE}Should NOT contain:${NC} $needle"
        exit 1
    fi
    echo -e "${GREEN}✅ PASS${NC}: $message"
}

# Get user progress (list all challenges with progress)
# Returns: JSON response from list-challenges
get_user_progress() {
    run_cli list-challenges --format=json
}

# Complete a goal by triggering enough events to reach target
# Usage: complete_goal <challenge-id> <goal-id>
# Note: This is a simplified helper - actual implementation depends on goal requirements
complete_goal() {
    local challenge_id="$1"
    local goal_id="$2"
    
    if [ -z "$challenge_id" ] || [ -z "$goal_id" ]; then
        error_exit "complete_goal requires challenge_id and goal_id parameters"
    fi
    
    # Get goal details to find the requirement
    local challenges=$(get_user_progress)
    local stat_code=$(echo "$challenges" | jq -r ".challenges[] | select(.challengeId == \"$challenge_id\") | .goals[] | select(.goalId == \"$goal_id\") | .requirement.statCode" 2>/dev/null)
    local target=$(echo "$challenges" | jq -r ".challenges[] | select(.challengeId == \"$challenge_id\") | .goals[] | select(.goalId == \"$goal_id\") | .requirement.targetValue" 2>/dev/null)
    
    if [ -z "$stat_code" ] || [ "$stat_code" = "null" ]; then
        echo -e "${YELLOW}⚠${NC} Warning: Could not determine stat code for goal $goal_id"
        return 1
    fi
    
    # Trigger event to update stat to target value
    run_cli trigger-event stat-update --stat-code="$stat_code" --value="$target" > /dev/null 2>&1
    
    # Wait for event processing
    wait_for_flush 2
}
