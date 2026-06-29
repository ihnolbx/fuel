#!/usr/bin/env bash
# Fuel sync test harness — runs against wrangler dev (http://localhost:8787).
#
# Usage:
#   TEST_TOKEN=<your-token> bash test/test-sync.sh
#
# Requires: curl, jq

set -euo pipefail

BASE="${BASE_URL:-http://localhost:8787}"
TOKEN="${TEST_TOKEN:?set TEST_TOKEN}"
AUTH="Authorization: Bearer $TOKEN"
CT="Content-Type: application/json"

PASS=0; FAIL=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label"
    echo "        got:  $got"
    echo "        want: $want"
    FAIL=$((FAIL+1))
  fi
}

sync() {
  # sync <cursor> <changes-json>  →  prints full response JSON
  local cursor="$1" changes="$2"
  curl -s -X POST "$BASE/sync" \
    -H "$AUTH" -H "$CT" \
    -d "{\"cursor\":$cursor,\"changes\":$changes}"
}

echo
echo "=== 1. Push then pull round-trip ==="

R=$(sync 0 '{
  "foods": [{
    "id": "food-aaa",
    "name": "Test Banana",
    "brand": null,
    "source": "manual",
    "external_id": null,
    "serving_qty": 100,
    "serving_unit": "g",
    "default_unit": "g",
    "kcal": 89, "protein": 1.1, "carbs": 23, "fat": 0.3,
    "updated_at": 1000,
    "deleted_at": null
  }]
}')

echo "$R" | jq .

NEW_CURSOR=$(echo "$R" | jq -r '.cursor')
FOOD_BACK=$(echo "$R" | jq -r '.changes.foods[0].id // "none"')
FOOD_REV=$(echo "$R" | jq -r '.changes.foods[0].rev // "none"')

check "cursor advanced from 0" "$NEW_CURSOR" "1"
check "pushed food returned in same response" "$FOOD_BACK" "food-aaa"
check "returned row has rev=1" "$FOOD_REV" "1"

# Pull from cursor=1 — should be empty
R2=$(sync 1 '{}')
FOOD_COUNT=$(echo "$R2" | jq '.changes.foods | length')
CURSOR2=$(echo "$R2" | jq -r '.cursor')
check "pull from current cursor returns no foods" "$FOOD_COUNT" "0"
check "pure-pull does not advance cursor" "$CURSOR2" "1"


echo
echo "=== 2. Two-device reconciliation ==="
# State so far: cursor=1, food-aaa at rev=1.
# Device A already has cursor=1.
# Device B starts at cursor=0.

# B pulls — should see food-aaa
RB1=$(sync 0 '{}')
B_CURSOR=$(echo "$RB1" | jq -r '.cursor')
B_FOOD=$(echo "$RB1" | jq -r '.changes.foods[0].id // "none"')
check "B sees A's food on first pull" "$B_FOOD" "food-aaa"
check "B cursor is now 1" "$B_CURSOR" "1"

# B pushes a weight entry
RB2=$(sync 1 '{
  "weight_entries": [{
    "id": "wt-bbb",
    "local_date": "2026-01-01",
    "measured_at": 2000,
    "weight_lbs": 165.5,
    "body_fat_pct": null,
    "notes": null,
    "updated_at": 2000,
    "deleted_at": null
  }]
}')
B_CURSOR2=$(echo "$RB2" | jq -r '.cursor')
WT_BACK=$(echo "$RB2" | jq -r '.changes.weight_entries[0].id // "none"')
check "B cursor after push is 2" "$B_CURSOR2" "2"
check "B sees its own weight entry in response" "$WT_BACK" "wt-bbb"

# A pulls from cursor=1 — should see B's weight entry
RA2=$(sync 1 '{}')
A_WT=$(echo "$RA2" | jq -r '.changes.weight_entries[0].id // "none"')
A_CURSOR2=$(echo "$RA2" | jq -r '.cursor')
check "A sees B's weight entry" "$A_WT" "wt-bbb"
check "A cursor is now 2" "$A_CURSOR2" "2"


echo
echo "=== 3. Conflict: last-write-wins on updated_at ==="
# Push food-ccc with updated_at=5000 (the "noon laptop edit")
sync 2 '{
  "foods": [{
    "id": "food-ccc",
    "name": "Conflict Food",
    "brand": null, "source": "manual", "external_id": null,
    "serving_qty": 1, "serving_unit": "serving", "default_unit": "serving",
    "kcal": 100, "protein": 5, "carbs": 10, "fat": 2,
    "updated_at": 5000,
    "deleted_at": null
  }]
}' > /dev/null

# Now push same id with updated_at=3000 (the "9am phone edit that synced late")
# This should LOSE — existing row has updated_at=5000 which is newer.
sync 3 '{
  "foods": [{
    "id": "food-ccc",
    "name": "Conflict Food STALE",
    "brand": null, "source": "manual", "external_id": null,
    "serving_qty": 1, "serving_unit": "serving", "default_unit": "serving",
    "kcal": 999, "protein": 99, "carbs": 99, "fat": 99,
    "updated_at": 3000,
    "deleted_at": null
  }]
}' > /dev/null

# Pull from cursor=2 to see what's actually stored
RC=$(sync 2 '{}')
WINNER_NAME=$(echo "$RC" | jq -r '[.changes.foods[] | select(.id=="food-ccc")] | last | .name')
WINNER_KCAL=$(echo "$RC" | jq -r '[.changes.foods[] | select(.id=="food-ccc")] | last | .kcal')

check "winning name is the newer write" "$WINNER_NAME" "Conflict Food"
check "winning kcal is the newer write" "$WINNER_KCAL" "100"


echo
echo "=== 4. Tombstone propagation ==="
FINAL_CURSOR=$(sync 0 '{}' | jq -r '.cursor')

# Push a setting with deleted_at set (tombstone)
sync "$FINAL_CURSOR" '{
  "settings": [{
    "id": "targets",
    "value": "{\"kcal\":2000}",
    "updated_at": 9000,
    "deleted_at": 9001
  }]
}' > /dev/null

NEW_C=$((FINAL_CURSOR + 1))

# Pull — tombstone row must come back with deleted_at set
RD=$(sync "$FINAL_CURSOR" '{}')
SETTING_DELETED=$(echo "$RD" | jq -r '.changes.settings[0].deleted_at // "none"')
check "tombstone row has deleted_at set" "$SETTING_DELETED" "9001"

# Pull from cursor=0 — row must still be present (not absent)
RD0=$(sync 0 '{}')
SETTING_PRESENT=$(echo "$RD0" | jq -r '[.changes.settings[] | select(.id=="targets")] | length')
check "tombstoned row still present in pull from cursor=0" "$SETTING_PRESENT" "1"

# Sanity: a row that was never pushed is absent, not a false positive
GHOST=$(echo "$RD0" | jq -r '[.changes.settings[] | select(.id=="does-not-exist")] | length')
check "nonexistent id is absent (sanity)" "$GHOST" "0"


echo
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  All tests passed." || { echo "  Some tests FAILED."; exit 1; }
