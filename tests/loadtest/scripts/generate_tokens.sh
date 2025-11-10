#!/bin/bash

# Generate AGS JWT tokens for test users
# Output: test/fixtures/tokens.json
#
# Usage:
#   MOCK_MODE=true ./generate_tokens.sh    # Generate mock tokens for local testing
#   ./generate_tokens.sh                   # Generate real AGS tokens (requires credentials)

AGS_BASE_URL=${AGS_BASE_URL:-"https://demo.accelbyte.io"}
AGS_CLIENT_ID=${AGS_CLIENT_ID}
AGS_CLIENT_SECRET=${AGS_CLIENT_SECRET}
AGS_NAMESPACE=${AGS_NAMESPACE:-"test"}
MOCK_MODE=${MOCK_MODE:-"false"}

USER_FILE="test/fixtures/users.json"
OUTPUT_FILE="test/fixtures/tokens.json"

if [ ! -f "$USER_FILE" ]; then
  echo "Error: $USER_FILE not found. Run generate_users.sh first."
  exit 1
fi

echo "Generating AGS tokens for users in $USER_FILE..."

if [ "$MOCK_MODE" = "true" ]; then
  echo "⚠️  MOCK MODE: Generating mock JWT tokens for local testing (not valid for real AGS)"

  # Generate mock tokens array (same length as users array)
  USER_COUNT=$(jq 'length' "$USER_FILE")

  echo "[" > "$OUTPUT_FILE"
  for i in $(seq 1 $USER_COUNT); do
    # Generate a mock JWT token (not cryptographically valid, but useful for testing)
    USER_ID=$(jq -r ".[$i-1].id" "$USER_FILE")
    MOCK_TOKEN="mock-jwt-token-for-${USER_ID}"

    if [ $i -eq $USER_COUNT ]; then
      echo "  \"$MOCK_TOKEN\"" >> "$OUTPUT_FILE"
    else
      echo "  \"$MOCK_TOKEN\"," >> "$OUTPUT_FILE"
    fi
  done
  echo "]" >> "$OUTPUT_FILE"

  echo "✅ Generated $USER_COUNT mock tokens in $OUTPUT_FILE"
  echo "⚠️  These tokens are for local testing only and will not work with real AGS"

else
  # Real AGS token generation
  if [ -z "$AGS_CLIENT_ID" ] || [ -z "$AGS_CLIENT_SECRET" ]; then
    echo "Error: AGS_CLIENT_ID and AGS_CLIENT_SECRET must be set for real token generation"
    echo ""
    echo "For local testing, use MOCK_MODE:"
    echo "  MOCK_MODE=true ./generate_tokens.sh"
    echo ""
    echo "For real AGS tokens, set environment variables:"
    echo "  export AGS_CLIENT_ID=your-client-id"
    echo "  export AGS_CLIENT_SECRET=your-client-secret"
    echo "  export AGS_BASE_URL=https://demo.accelbyte.io"
    echo "  export AGS_NAMESPACE=your-namespace"
    echo "  ./generate_tokens.sh"
    exit 1
  fi

  echo "🔐 Authenticating with AGS..."

  # Get OAuth token for service account
  ACCESS_TOKEN=$(curl -s -X POST \
    "$AGS_BASE_URL/iam/v3/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "$AGS_CLIENT_ID:$AGS_CLIENT_SECRET" \
    -d "grant_type=client_credentials" | jq -r '.access_token')

  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "❌ Error: Failed to get OAuth token from AGS"
    echo "Check your AGS credentials and base URL"
    exit 1
  fi

  echo "✅ Authenticated successfully"

  # TODO: Implement user token generation via AGS IAM API
  # This requires creating test users first via AGS Admin API
  # For now, use service account token for all users (not ideal but works for load testing)

  USER_COUNT=$(jq 'length' "$USER_FILE")

  echo "[" > "$OUTPUT_FILE"
  for i in $(seq 1 $USER_COUNT); do
    # In production, you would generate a unique token per user
    # For load testing, we can reuse the service account token
    if [ $i -eq $USER_COUNT ]; then
      echo "  \"$ACCESS_TOKEN\"" >> "$OUTPUT_FILE"
    else
      echo "  \"$ACCESS_TOKEN\"," >> "$OUTPUT_FILE"
    fi
  done
  echo "]" >> "$OUTPUT_FILE"

  echo "✅ Generated $USER_COUNT tokens in $OUTPUT_FILE"
  echo "⚠️  Using service account token for all users (acceptable for load testing)"
  echo "Tokens valid for 24 hours"
fi
