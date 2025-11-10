#!/bin/bash

# Generate challenges.json with 10 challenges and 50 goals each
# Output: test/fixtures/challenges.json

OUTPUT_FILE="test/fixtures/challenges.json"

echo "Generating 10 challenges with 50 goals each..."

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

# Generate 10 challenges
for c in $(seq 0 9); do
  CHALLENGE_ID=$(printf "challenge-%03d" $((c + 1)))
  CHALLENGE_NAME="${CHALLENGE_THEMES[$c]}"

  # Choose primary stat for this challenge
  PRIMARY_STAT=${STAT_CODES[$((c % 5))]}

  echo "    {" >> "$OUTPUT_FILE"
  echo "      \"id\": \"$CHALLENGE_ID\"," >> "$OUTPUT_FILE"
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
    echo "          \"id\": \"$GOAL_ID\"," >> "$OUTPUT_FILE"
    echo "          \"name\": \"$GOAL_NAME\"," >> "$OUTPUT_FILE"
    echo "          \"description\": \"Reach $TARGET_VALUE $PRIMARY_STAT to complete this goal\"," >> "$OUTPUT_FILE"
    echo "          \"type\": \"absolute\"," >> "$OUTPUT_FILE"
    echo "          \"event_source\": \"$EVENT_SOURCE\"," >> "$OUTPUT_FILE"
    echo "          \"requirement\": {" >> "$OUTPUT_FILE"
    echo "            \"stat_code\": \"$PRIMARY_STAT\"," >> "$OUTPUT_FILE"
    echo "            \"operator\": \">=\"," >> "$OUTPUT_FILE"
    echo "            \"target_value\": $TARGET_VALUE" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"reward\": {" >> "$OUTPUT_FILE"
    echo "            \"type\": \"$REWARD_TYPE\"," >> "$OUTPUT_FILE"
    echo "            \"reward_id\": \"$REWARD_ID\"," >> "$OUTPUT_FILE"
    echo "            \"quantity\": $REWARD_QTY" >> "$OUTPUT_FILE"
    echo "          }," >> "$OUTPUT_FILE"
    echo "          \"prerequisites\": []" >> "$OUTPUT_FILE"

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

echo "✅ Generated challenges.json with 10 challenges and 50 goals each (500 total goals)"
echo "📄 Output: $OUTPUT_FILE"

# Validate JSON
if command -v jq &> /dev/null; then
  if jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "✅ JSON is valid"
    GOAL_COUNT=$(jq '[.challenges[].goals[]] | length' "$OUTPUT_FILE")
    echo "📊 Total goals: $GOAL_COUNT"
  else
    echo "❌ JSON validation failed"
    exit 1
  fi
else
  echo "⚠️  jq not found, skipping JSON validation"
fi
