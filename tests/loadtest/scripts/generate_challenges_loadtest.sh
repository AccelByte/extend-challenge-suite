#!/bin/bash

# Generate challenges.json with ALL goals default-assigned for load testing
# This creates realistic production data during k6 tests without needing a separate initialization script
#
# Output: test/fixtures/challenges_loadtest.json
#
# Usage:
#   ./generate_challenges_loadtest.sh [goals_per_user]
#
# Examples:
#   ./generate_challenges_loadtest.sh 50    # 50 default goals (medium scale)
#   ./generate_challenges_loadtest.sh 500   # 500 default goals (large scale)

set -e

GOALS_PER_USER=${1:-50}
OUTPUT_FILE="test/fixtures/challenges_loadtest.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Generating Load Test Challenge Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Default goals per user: $GOALS_PER_USER"
echo "Output: $OUTPUT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p test/fixtures

# Stat codes to use for variety
STAT_CODES=("login_count" "enemy_kills" "games_played" "headshots" "wins")

# Challenge themes
CHALLENGE_THEMES=(
  "Daily Login Streak"
  "Combat Mastery"
  "Game Participation"
  "Precision Shooter"
  "Victory Ladder"
  "Weekend Warrior"
  "Monthly Marathon"
  "Achievement Hunter"
  "Skill Builder"
  "Champion's Path"
)

# Start JSON
cat > "$OUTPUT_FILE" << 'EOF'
{
  "challenges": [
EOF

# Calculate how many goals to assign per challenge
TOTAL_GOALS=500
GOALS_PER_CHALLENGE=50
CHALLENGES_TO_FILL=$((GOALS_PER_USER / GOALS_PER_CHALLENGE))
REMAINING_GOALS=$((GOALS_PER_USER % GOALS_PER_CHALLENGE))

echo "📊 Configuration:"
echo "   Total goals available: $TOTAL_GOALS"
echo "   Goals per challenge: $GOALS_PER_CHALLENGE"
echo "   Challenges to fully assign: $CHALLENGES_TO_FILL"
echo "   Remaining goals: $REMAINING_GOALS"
echo ""

# Generate 10 challenges
for c in $(seq 0 9); do
  CHALLENGE_ID=$(printf "challenge-%03d" $((c + 1)))
  CHALLENGE_NAME="${CHALLENGE_THEMES[$c]}"

  # Choose primary stat for this challenge
  PRIMARY_STAT=${STAT_CODES[$((c % 5))]}

  echo "    {" >> "$OUTPUT_FILE"
  echo "      \"challengeId\": \"$CHALLENGE_ID\"," >> "$OUTPUT_FILE"
  echo "      \"name\": \"$CHALLENGE_NAME\"," >> "$OUTPUT_FILE"
  echo "      \"description\": \"Complete goals to earn rewards\"," >> "$OUTPUT_FILE"
  echo "      \"goals\": [" >> "$OUTPUT_FILE"

  # Generate 50 goals per challenge
  for g in $(seq 1 50); do
    GOAL_ID=$(printf "%s-goal-%02d" "$CHALLENGE_ID" $g)
    GOAL_NAME="Goal $g"

    # Progressive target values and event source
    if [ "$PRIMARY_STAT" = "login_count" ]; then
      TARGET_VALUE=$g
      EVENT_SOURCE="login"
    elif [ "$PRIMARY_STAT" = "enemy_kills" ]; then
      TARGET_VALUE=$((g * 10))
      EVENT_SOURCE="statistic"
    elif [ "$PRIMARY_STAT" = "games_played" ]; then
      TARGET_VALUE=$((g * 2))
      EVENT_SOURCE="statistic"
    elif [ "$PRIMARY_STAT" = "headshots" ]; then
      TARGET_VALUE=$((g * 5))
      EVENT_SOURCE="statistic"
    else # wins
      TARGET_VALUE=$g
      EVENT_SOURCE="statistic"
    fi

    # Progressive rewards
    if [ $((g % 10)) -eq 0 ]; then
      # Every 10th goal: larger reward
      REWARD_TYPE="WALLET"
      REWARD_ID="GEMS"
      REWARD_QTY=$((g * 50))
    elif [ $((g % 5)) -eq 0 ]; then
      # Every 5th goal: item reward
      REWARD_TYPE="ITEM"
      REWARD_ID="LOOTBOX_SILVER"
      REWARD_QTY=1
    else
      # Regular goals: small gem reward
      REWARD_TYPE="WALLET"
      REWARD_ID="GEMS"
      REWARD_QTY=$((g * 10))
    fi

    echo "        {" >> "$OUTPUT_FILE"
    echo "          \"goalId\": \"$GOAL_ID\"," >> "$OUTPUT_FILE"
    echo "          \"name\": \"$GOAL_NAME\"," >> "$OUTPUT_FILE"
    echo "          \"description\": \"Reach $TARGET_VALUE $PRIMARY_STAT to complete this goal\"," >> "$OUTPUT_FILE"
    echo "          \"type\": \"absolute\"," >> "$OUTPUT_FILE"
    echo "          \"eventSource\": \"$EVENT_SOURCE\"," >> "$OUTPUT_FILE"
    echo "          \"requirement\": {" >> "$OUTPUT_FILE"
    echo "            \"statCode\": \"$PRIMARY_STAT\"," >> "$OUTPUT_FILE"
    echo "            \"operator\": \">=\"," >> "$OUTPUT_FILE"
    echo "            \"targetValue\": $TARGET_VALUE" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"reward\": {" >> "$OUTPUT_FILE"
    echo "            \"type\": \"$REWARD_TYPE\"," >> "$OUTPUT_FILE"
    echo "            \"rewardId\": \"$REWARD_ID\"," >> "$OUTPUT_FILE"
    echo "            \"quantity\": $REWARD_QTY" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"prerequisites\": []," >> "$OUTPUT_FILE"

    # Determine if this goal should be default-assigned
    # Logic: Assign goals from first N challenges completely, then remaining from next challenge
    DEFAULT_ASSIGNED=false

    if [ $c -lt $CHALLENGES_TO_FILL ]; then
      # This challenge is fully assigned
      DEFAULT_ASSIGNED=true
    elif [ $c -eq $CHALLENGES_TO_FILL ] && [ $g -le $REMAINING_GOALS ]; then
      # This is the partial challenge - assign first N goals only
      DEFAULT_ASSIGNED=true
    fi

    if [ "$DEFAULT_ASSIGNED" = true ]; then
      echo "          \"defaultAssigned\": true" >> "$OUTPUT_FILE"
    else
      echo "          \"defaultAssigned\": false" >> "$OUTPUT_FILE"
    fi

    # Add comma if not last goal
    if [ $g -lt 50 ]; then
      echo "        }," >> "$OUTPUT_FILE"
    else
      echo "        }" >> "$OUTPUT_FILE"
    fi
  done

  echo "      ]" >> "$OUTPUT_FILE"

  # Add comma if not last challenge
  if [ $c -lt 9 ]; then
    echo "    }," >> "$OUTPUT_FILE"
  else
    echo "    }" >> "$OUTPUT_FILE"
  fi
done

# End JSON
cat >> "$OUTPUT_FILE" << 'EOF'
  ]
}
EOF

echo "✅ Generated load test challenges configuration"
echo ""

# Validate JSON
if command -v jq &> /dev/null; then
  if jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "✅ JSON is valid"

    TOTAL_GOAL_COUNT=$(jq '[.challenges[].goals[]] | length' "$OUTPUT_FILE")
    DEFAULT_ASSIGNED_COUNT=$(jq '[.challenges[].goals[] | select(.defaultAssigned == true)] | length' "$OUTPUT_FILE")

    echo "📊 Statistics:"
    echo "   Total goals: $TOTAL_GOAL_COUNT"
    echo "   Default-assigned goals: $DEFAULT_ASSIGNED_COUNT"
    echo "   Non-assigned goals: $((TOTAL_GOAL_COUNT - DEFAULT_ASSIGNED_COUNT))"
    echo ""
    echo "🎯 Expected database rows per user: $DEFAULT_ASSIGNED_COUNT"
    echo ""
    echo "💡 Usage:"
    echo "   1. Copy to service config: cp $OUTPUT_FILE ../../extend-challenge-service/config/challenges.json"
    echo "   2. Restart services: docker-compose restart"
    echo "   3. Run k6 test: k6 run k6/scenario3_combined.js"
    echo ""
    echo "   With 10,000 unique users in k6 test:"
    echo "   Expected DB rows: $((DEFAULT_ASSIGNED_COUNT * 10000))"
    echo "   Expected DB size: ~$((DEFAULT_ASSIGNED_COUNT * 10000 / 2000)) MB"
  else
    echo "❌ JSON validation failed"
    exit 1
  fi
else
  echo "⚠️  jq not found, skipping JSON validation"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
