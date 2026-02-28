#!/bin/bash

# Generate challenges.json for load testing with correct camelCase schema
# Includes 10 absolute challenges (50 goals each) + daily + weekly rotation challenges
#
# Output: ../fixtures/challenges.json (relative to this script's directory)
#
# Usage:
#   ./generate_challenges_loadtest.sh [goals_per_user]
#
# Examples:
#   ./generate_challenges_loadtest.sh 50    # 50 default absolute goals (medium scale)
#   ./generate_challenges_loadtest.sh 500   # 500 default absolute goals (large scale)

set -e

GOALS_PER_USER=${1:-50}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/../fixtures/challenges.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Generating Load Test Challenge Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Default absolute goals per user: $GOALS_PER_USER"
echo "Output: $OUTPUT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$(dirname "$OUTPUT_FILE")"

# Stat codes to use for variety
STAT_CODES=("login_count" "enemy_kills" "games_played" "headshots" "wins")

# Challenge themes for absolute challenges
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

# Calculate how many absolute goals to assign per challenge
GOALS_PER_CHALLENGE=50
CHALLENGES_TO_FILL=$((GOALS_PER_USER / GOALS_PER_CHALLENGE))
REMAINING_GOALS=$((GOALS_PER_USER % GOALS_PER_CHALLENGE))

echo "  Configuration:"
echo "   Absolute challenges: 10 (50 goals each = 500 total)"
echo "   Daily rotation goals: 50"
echo "   Weekly rotation goals: 50"
echo "   Total goals: ~600"
echo "   Default-assigned absolute goals per user: $GOALS_PER_USER"
echo "   All rotation goals: defaultAssigned"
echo ""

# Start JSON
echo '{' > "$OUTPUT_FILE"
echo '  "challenges": [' >> "$OUTPUT_FILE"

# ============================================================================
# Generate 10 absolute challenges (50 goals each)
# ============================================================================
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
      REWARD_TYPE="WALLET"
      REWARD_ID="GEMS"
      REWARD_QTY=$((g * 50))
    elif [ $((g % 5)) -eq 0 ]; then
      REWARD_TYPE="ITEM"
      REWARD_ID="LOOTBOX_SILVER"
      REWARD_QTY=1
    else
      REWARD_TYPE="WALLET"
      REWARD_ID="GEMS"
      REWARD_QTY=$((g * 10))
    fi

    # Determine if this goal should be default-assigned
    DEFAULT_ASSIGNED=false
    if [ $c -lt $CHALLENGES_TO_FILL ]; then
      DEFAULT_ASSIGNED=true
    elif [ $c -eq $CHALLENGES_TO_FILL ] && [ $g -le $REMAINING_GOALS ]; then
      DEFAULT_ASSIGNED=true
    fi

    echo "        {" >> "$OUTPUT_FILE"
    echo "          \"goalId\": \"$GOAL_ID\"," >> "$OUTPUT_FILE"
    echo "          \"name\": \"$GOAL_NAME\"," >> "$OUTPUT_FILE"
    echo "          \"description\": \"Reach $TARGET_VALUE $PRIMARY_STAT to complete this goal\"," >> "$OUTPUT_FILE"
    echo "          \"eventSource\": \"$EVENT_SOURCE\"," >> "$OUTPUT_FILE"
    echo "          \"requirement\": {" >> "$OUTPUT_FILE"
    echo "            \"statCode\": \"$PRIMARY_STAT\"," >> "$OUTPUT_FILE"
    echo "            \"operator\": \">=\"," >> "$OUTPUT_FILE"
    echo "            \"targetValue\": $TARGET_VALUE," >> "$OUTPUT_FILE"
    echo "            \"progressMode\": \"absolute\"" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"reward\": {" >> "$OUTPUT_FILE"
    echo "            \"type\": \"$REWARD_TYPE\"," >> "$OUTPUT_FILE"
    echo "            \"rewardId\": \"$REWARD_ID\"," >> "$OUTPUT_FILE"
    echo "            \"quantity\": $REWARD_QTY" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"prerequisites\": []," >> "$OUTPUT_FILE"
    echo "          \"defaultAssigned\": $DEFAULT_ASSIGNED" >> "$OUTPUT_FILE"

    if [ $g -lt 50 ]; then
      echo "        }," >> "$OUTPUT_FILE"
    else
      echo "        }" >> "$OUTPUT_FILE"
    fi
  done

  echo "      ]" >> "$OUTPUT_FILE"
  echo "    }," >> "$OUTPUT_FILE"
done

# ============================================================================
# Generate daily-challenges (50 daily rotation goals)
# ============================================================================
echo "    {" >> "$OUTPUT_FILE"
echo "      \"challengeId\": \"daily-challenges\"," >> "$OUTPUT_FILE"
echo "      \"name\": \"Daily Challenges\"," >> "$OUTPUT_FILE"
echo "      \"description\": \"Daily rotating challenges that reset each day\"," >> "$OUTPUT_FILE"
echo "      \"goals\": [" >> "$OUTPUT_FILE"

DAILY_STAT_CODES=("enemy_kills" "games_played" "headshots" "wins" "login_count")

for g in $(seq 1 50); do
  GOAL_ID=$(printf "daily-goal-%02d" $g)
  STAT_INDEX=$(( (g - 1) % 5 ))
  STAT_CODE="${DAILY_STAT_CODES[$STAT_INDEX]}"

  if [ "$STAT_CODE" = "login_count" ]; then
    EVENT_SOURCE="login"
    TARGET_VALUE=$(( (g / 5) + 1 ))
  else
    EVENT_SOURCE="statistic"
    TARGET_VALUE=$(( g * 3 ))
  fi

  # Rewards: alternate between wallet and item
  if [ $((g % 5)) -eq 0 ]; then
    REWARD_TYPE="ITEM"
    REWARD_ID="LOOTBOX_DAILY"
    REWARD_QTY=1
  else
    REWARD_TYPE="WALLET"
    REWARD_ID="GOLD"
    REWARD_QTY=$((g * 20))
  fi

  echo "        {" >> "$OUTPUT_FILE"
  echo "          \"goalId\": \"$GOAL_ID\"," >> "$OUTPUT_FILE"
  echo "          \"name\": \"Daily Goal $g\"," >> "$OUTPUT_FILE"
  echo "          \"description\": \"Reach $TARGET_VALUE $STAT_CODE today\"," >> "$OUTPUT_FILE"
  echo "          \"eventSource\": \"$EVENT_SOURCE\"," >> "$OUTPUT_FILE"
  echo "          \"requirement\": {" >> "$OUTPUT_FILE"
  echo "            \"statCode\": \"$STAT_CODE\"," >> "$OUTPUT_FILE"
  echo "            \"operator\": \">=\"," >> "$OUTPUT_FILE"
  echo "            \"targetValue\": $TARGET_VALUE," >> "$OUTPUT_FILE"
  echo "            \"progressMode\": \"relative\"" >> "$OUTPUT_FILE"
  echo "          }," >> "$OUTPUT_FILE"
  echo "          \"reward\": {" >> "$OUTPUT_FILE"
  echo "            \"type\": \"$REWARD_TYPE\"," >> "$OUTPUT_FILE"
  echo "            \"rewardId\": \"$REWARD_ID\"," >> "$OUTPUT_FILE"
  echo "            \"quantity\": $REWARD_QTY" >> "$OUTPUT_FILE"
  echo "          }," >> "$OUTPUT_FILE"
  echo "          \"prerequisites\": []," >> "$OUTPUT_FILE"
  echo "          \"defaultAssigned\": true," >> "$OUTPUT_FILE"
  echo "          \"rotation\": {" >> "$OUTPUT_FILE"
  echo "            \"enabled\": true," >> "$OUTPUT_FILE"
  echo "            \"type\": \"global\"," >> "$OUTPUT_FILE"
  echo "            \"schedule\": \"daily\"," >> "$OUTPUT_FILE"
  echo "            \"onExpiry\": {" >> "$OUTPUT_FILE"
  echo "              \"resetProgress\": true," >> "$OUTPUT_FILE"
  echo "              \"allowReselection\": true" >> "$OUTPUT_FILE"
  echo "            }" >> "$OUTPUT_FILE"
  echo "          }" >> "$OUTPUT_FILE"

  if [ $g -lt 50 ]; then
    echo "        }," >> "$OUTPUT_FILE"
  else
    echo "        }" >> "$OUTPUT_FILE"
  fi
done

echo "      ]" >> "$OUTPUT_FILE"
echo "    }," >> "$OUTPUT_FILE"

# ============================================================================
# Generate weekly-challenges (50 weekly rotation goals)
# ============================================================================
echo "    {" >> "$OUTPUT_FILE"
echo "      \"challengeId\": \"weekly-challenges\"," >> "$OUTPUT_FILE"
echo "      \"name\": \"Weekly Challenges\"," >> "$OUTPUT_FILE"
echo "      \"description\": \"Weekly rotating challenges with higher targets\"," >> "$OUTPUT_FILE"
echo "      \"goals\": [" >> "$OUTPUT_FILE"

WEEKLY_STAT_CODES=("enemy_kills" "games_played" "headshots" "wins" "login_count")

for g in $(seq 1 50); do
  GOAL_ID=$(printf "weekly-goal-%02d" $g)
  STAT_INDEX=$(( (g - 1) % 5 ))
  STAT_CODE="${WEEKLY_STAT_CODES[$STAT_INDEX]}"

  if [ "$STAT_CODE" = "login_count" ]; then
    EVENT_SOURCE="login"
    TARGET_VALUE=$(( (g / 5) + 3 ))
  else
    EVENT_SOURCE="statistic"
    TARGET_VALUE=$(( g * 15 ))
  fi

  # Rewards: bigger than daily
  if [ $((g % 5)) -eq 0 ]; then
    REWARD_TYPE="ITEM"
    REWARD_ID="LOOTBOX_WEEKLY"
    REWARD_QTY=1
  else
    REWARD_TYPE="WALLET"
    REWARD_ID="GEMS"
    REWARD_QTY=$((g * 50))
  fi

  echo "        {" >> "$OUTPUT_FILE"
  echo "          \"goalId\": \"$GOAL_ID\"," >> "$OUTPUT_FILE"
  echo "          \"name\": \"Weekly Goal $g\"," >> "$OUTPUT_FILE"
  echo "          \"description\": \"Reach $TARGET_VALUE $STAT_CODE this week\"," >> "$OUTPUT_FILE"
  echo "          \"eventSource\": \"$EVENT_SOURCE\"," >> "$OUTPUT_FILE"
  echo "          \"requirement\": {" >> "$OUTPUT_FILE"
  echo "            \"statCode\": \"$STAT_CODE\"," >> "$OUTPUT_FILE"
  echo "            \"operator\": \">=\"," >> "$OUTPUT_FILE"
  echo "            \"targetValue\": $TARGET_VALUE," >> "$OUTPUT_FILE"
  echo "            \"progressMode\": \"relative\"" >> "$OUTPUT_FILE"
  echo "          }," >> "$OUTPUT_FILE"
  echo "          \"reward\": {" >> "$OUTPUT_FILE"
  echo "            \"type\": \"$REWARD_TYPE\"," >> "$OUTPUT_FILE"
  echo "            \"rewardId\": \"$REWARD_ID\"," >> "$OUTPUT_FILE"
  echo "            \"quantity\": $REWARD_QTY" >> "$OUTPUT_FILE"
  echo "          }," >> "$OUTPUT_FILE"
  echo "          \"prerequisites\": []," >> "$OUTPUT_FILE"
  echo "          \"defaultAssigned\": true," >> "$OUTPUT_FILE"
  echo "          \"rotation\": {" >> "$OUTPUT_FILE"
  echo "            \"enabled\": true," >> "$OUTPUT_FILE"
  echo "            \"type\": \"global\"," >> "$OUTPUT_FILE"
  echo "            \"schedule\": \"weekly\"," >> "$OUTPUT_FILE"
  echo "            \"onExpiry\": {" >> "$OUTPUT_FILE"
  echo "              \"resetProgress\": true," >> "$OUTPUT_FILE"
  echo "              \"allowReselection\": true" >> "$OUTPUT_FILE"
  echo "            }" >> "$OUTPUT_FILE"
  echo "          }" >> "$OUTPUT_FILE"

  if [ $g -lt 50 ]; then
    echo "        }," >> "$OUTPUT_FILE"
  else
    echo "        }" >> "$OUTPUT_FILE"
  fi
done

echo "      ]" >> "$OUTPUT_FILE"
echo "    }" >> "$OUTPUT_FILE"

# End JSON
echo '  ]' >> "$OUTPUT_FILE"
echo '}' >> "$OUTPUT_FILE"

echo ""
echo "  Generated load test challenges configuration"
echo ""

# Validate JSON
if command -v jq &> /dev/null; then
  if jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "  JSON is valid"

    CHALLENGE_COUNT=$(jq '.challenges | length' "$OUTPUT_FILE")
    TOTAL_GOAL_COUNT=$(jq '[.challenges[].goals[]] | length' "$OUTPUT_FILE")
    ABSOLUTE_COUNT=$(jq '[.challenges[].goals[] | select(.rotation == null or .rotation.enabled == false)] | length' "$OUTPUT_FILE")
    DAILY_COUNT=$(jq '[.challenges[].goals[] | select(.rotation != null and .rotation.enabled == true and .rotation.schedule == "daily")] | length' "$OUTPUT_FILE")
    WEEKLY_COUNT=$(jq '[.challenges[].goals[] | select(.rotation != null and .rotation.enabled == true and .rotation.schedule == "weekly")] | length' "$OUTPUT_FILE")
    DEFAULT_ASSIGNED_COUNT=$(jq '[.challenges[].goals[] | select(.defaultAssigned == true)] | length' "$OUTPUT_FILE")

    echo "  Statistics:"
    echo "   Challenges: $CHALLENGE_COUNT"
    echo "   Total goals: $TOTAL_GOAL_COUNT"
    echo "   Absolute goals: $ABSOLUTE_COUNT"
    echo "   Daily rotation goals: $DAILY_COUNT"
    echo "   Weekly rotation goals: $WEEKLY_COUNT"
    echo "   Rotation percentage: $(echo "scale=1; ($DAILY_COUNT + $WEEKLY_COUNT) * 100 / $TOTAL_GOAL_COUNT" | bc)%"
    echo "   Default-assigned goals: $DEFAULT_ASSIGNED_COUNT"
    echo ""
    echo "  Usage:"
    echo "   Start services with loadtest config:"
    echo "     make dev-up-loadtest"
    echo ""
    echo "   Switch back to E2E config:"
    echo "     make dev-up"
    echo ""
    echo "   Run k6 test:"
    echo "     k6 run tests/loadtest/k6/scenario3_combined.js"
  else
    echo "  JSON validation failed"
    exit 1
  fi
else
  echo "  jq not found, skipping JSON validation"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
