#!/bin/bash

# Generate 10,000 test users
# Output: test/fixtures/users.json

OUTPUT_FILE="test/fixtures/users.json"
USER_COUNT=10000

echo "Generating $USER_COUNT test users..."

mkdir -p test/fixtures

# Generate JSON array of users
echo "[" > "$OUTPUT_FILE"

for i in $(seq 1 $USER_COUNT); do
  USER_ID=$(printf "user-%06d" $i)

  if [ $i -eq $USER_COUNT ]; then
    echo "  {\"id\": \"$USER_ID\", \"namespace\": \"test\"}" >> "$OUTPUT_FILE"
  else
    echo "  {\"id\": \"$USER_ID\", \"namespace\": \"test\"}," >> "$OUTPUT_FILE"
  fi
done

echo "]" >> "$OUTPUT_FILE"

echo "Generated $USER_COUNT users in $OUTPUT_FILE"
