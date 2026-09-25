#!/bin/bash
# =============================================================
# Repair Locations — fix city/state from stored address data
#
# Usage:
#   ./repair_locations.sh              — audit only (dry run)
#   ./repair_locations.sh --apply      — fix the sheet
#   ./repair_locations.sh --limit 100  — audit first N
#
# Uses the address field already in venue_detail (no new Google
# API calls). Parses actual city/state from stored addresses.
#
# Priority order:
#   1. Stored address field (from Google Place data)
#   2. Known neighborhood → city, only inside the matching state
#      (Georgetown DC → Washington; Georgetown DE stays Georgetown)
#   3. Leave unknown if can't determine
#
# Safe by construction: preview is the default, every run starts from fresh
# temp files, --apply aborts if the audit failed, a field is never written
# empty, and every update_venue response is checked (failures are counted).
# DC quadrant addresses ("1309 5th St NE, Washington, DC") parse as DC.
#
# Idempotent — safe to run multiple times.
# =============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
source "$SCRIPT_DIR/.env" 2>/dev/null || true
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

APPLY=0
LIMIT=0
LIMIT_NEXT=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --limit) LIMIT_NEXT=1 ;;
        *)
            if [ "$LIMIT_NEXT" = "1" ]; then
                LIMIT=$arg
                LIMIT_NEXT=0
            else
                echo "Unknown argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done
case "$LIMIT" in
    ''|*[!0-9]*) echo "--limit needs a number (got '$LIMIT')" >&2; exit 1 ;;
esac

# Fresh files every run: an --apply must never replay an older audit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/repair_locations.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
VENUES_JSON="$WORK/venues.json"
IDS_FILE="$WORK/venue_ids.txt"
DETAILS="$WORK/details.jsonl"
UPDATES="$WORK/updates.tsv"

if [ "$APPLY" = "0" ]; then
    echo "[DRY RUN] Audit only. Use --apply to update the sheet."
fi

echo "Fetching all venues..."
if ! curl -fsSL --max-time 120 "${APPS_SCRIPT_URL}?action=venues" -o "$VENUES_JSON"; then
    echo "ERROR: could not fetch venues — nothing done." >&2
    exit 1
fi

# Get venue IDs for untouched venues
if ! python3 - "$VENUES_JSON" "$IDS_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    venues = json.load(f).get('venues', [])
untouched = [v for v in venues if v.get('status') == 'untouched']
with open(sys.argv[2], 'w') as f:
    for v in untouched:
        f.write(v['venue_id'] + '\n')
print(f'Untouched venues to audit: {len(untouched)}')
PY
then
    echo "ERROR: venues response was not valid JSON — nothing done." >&2
    exit 1
fi

TOTAL=$(wc -l < "$IDS_FILE" | tr -d ' ')
echo "Fetching venue details for $TOTAL venues..."
echo "(This will take a while — ~1 request per second)"

# Fetch venue details and save to JSONL
: > "$DETAILS"
count=0
fetch_failed=0
while read -r vid; do
    if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
        break
    fi
    if detail=$(curl -fsSL --max-time 60 --get --data-urlencode "action=venue_detail" --data-urlencode "venue_id=${vid}" "${APPS_SCRIPT_URL}"); then
        printf '%s\n' "$detail" >> "$DETAILS"
    else
        fetch_failed=$((fetch_failed + 1))
    fi
    count=$((count + 1))
    if [ $((count % 50)) -eq 0 ]; then
        echo "  ... fetched $count / $TOTAL"
    fi
done < "$IDS_FILE"

echo "Fetched $count venue details ($fetch_failed failed to fetch)."
echo "Analyzing locations..."

if ! python3 - "$DETAILS" "$UPDATES" "$SCRIPT_DIR" <<'PYEOF'
import json, sys
from collections import Counter

details_path, updates_path, script_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, script_dir)
from site_discovery import parse_location  # DC quadrants aren't Nebraska

# Known DC neighborhoods that are NOT standalone cities
DC_NEIGHBORHOODS = {
    'georgetown', 'dupont circle', 'foggy bottom', 'penn quarter',
    'capitol hill', 'logan circle', 'adams morgan', 'u street',
    'cleveland park', 'woodley park', 'tenleytown', 'shaw',
    'columbia heights', 'petworth', 'brookland', 'anacostia',
    'navy yard', 'southwest waterfront', 'the wharf',
    'kalorama', 'embassy row', 'spring valley', 'glover park',
    'friendship heights',
}

# Baltimore neighborhoods
BALT_NEIGHBORHOODS = {
    'roland park', 'guilford', 'homeland', 'mt. washington',
    'mt washington', 'mount washington', 'ruxton', 'lutherville',
    'hampden', 'fells point', 'federal hill', 'inner harbor',
    'canton', 'charles village', 'remington', 'station north',
    'highlandtown', 'locust point',
}


def neighborhood_fix(city, state):
    """(city, state, changed) — map a neighborhood to its city only inside its own state."""
    low = (city or '').strip().lower()
    if low in DC_NEIGHBORHOODS and state == 'DC':
        return 'Washington', state, True
    if low in BALT_NEIGHBORHOODS and state == 'MD':
        return 'Baltimore', state, True
    return city, state, False


# Load venue details
details = []
with open(details_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        venue = d.get('venue', {})
        if venue:
            details.append(venue)

print(f"Loaded {len(details)} venue details")

repairs = []
stats = Counter()
stats['total'] = len(details)

for v in details:
    vid = v.get('venue_id', '')
    name = v.get('name', '')
    old_city = (v.get('city', '') or '').strip()
    old_state = (v.get('state', '') or '').strip().upper()
    address = (v.get('address', '') or '').strip()

    addr_city, addr_state = '', ''
    if not address or address == name:
        stats['no_address'] += 1
    else:
        addr_city, addr_state = parse_location(address)
        if not addr_city and not addr_state:
            stats['unparseable'] += 1

    new_city = addr_city or old_city
    new_state = addr_state or old_state
    new_city, new_state, hood = neighborhood_fix(new_city, new_state)

    # Only ever replace a value with a non-empty one.
    city_changed = bool(new_city) and new_city.lower() != old_city.lower()
    state_changed = bool(new_state) and new_state != old_state
    if not (city_changed or state_changed):
        stats['correct'] += 1
        continue
    if city_changed and state_changed:
        stats['city_state_fixed'] += 1
    elif city_changed:
        stats['city_fixed'] += 1
    else:
        stats['state_fixed'] += 1
    if hood:
        stats['neighborhood_to_city'] += 1
    repairs.append({
        'venue_id': vid, 'name': name,
        'old_city': old_city, 'new_city': new_city if city_changed else '',
        'old_state': old_state, 'new_state': new_state if state_changed else '',
        'source': 'neighborhood_map' if hood and not addr_city else 'address_parse',
        'address': address,
    })

# Report
print(f"\n=== LOCATION AUDIT REPORT ===")
print(f"Total venues audited: {stats['total']}")
print(f"Correct (no change needed): {stats['correct']}")
print(f"City fixes: {stats['city_fixed']}")
print(f"State fixes: {stats['state_fixed']}")
print(f"City+State fixes: {stats['city_state_fixed']}")
print(f"Neighborhood → City: {stats['neighborhood_to_city']}")
print(f"No address data: {stats['no_address']}")
print(f"Unparseable address: {stats['unparseable']}")
print(f"Total repairs needed: {len(repairs)}")

print(f"\n=== REPAIR EXAMPLES (first 40) ===")
for r in repairs[:40]:
    nc = r['new_city'] or r['old_city']
    ns = r['new_state'] or r['old_state']
    city_change = f"{r['old_city']:20s} → {nc:20s}" if r['new_city'] else f"{r['old_city']:20s}   (same)"
    state_change = f"{r['old_state']:3s}→{ns:3s}" if r['new_state'] else f"{r['old_state']:3s}    "
    print(f"  {r['name'][:40]:40s}  {city_change}  {state_change}  [{r['source']}]")

print(f"\n=== MOST COMMON CITY CHANGES ===")
changes = Counter(f"{r['old_city']} → {r['new_city']}" for r in repairs if r['new_city'])
for change, count in changes.most_common(20):
    print(f"  {change}: {count}")

with open(updates_path, 'w') as f:
    for r in repairs:
        f.write(f"{r['venue_id']}\t{r['new_city']}\t{r['new_state']}\n")
print(f"\nPlanned {len(repairs)} repairs")
PYEOF
then
    echo "ERROR: location analysis failed — nothing applied." >&2
    exit 1
fi

# update_venue FIELD VALUE for one venue; succeeds only on a JSON status "ok".
update_field() {
    local vid="$1" field="$2" value="$3" resp
    [ -n "$value" ] || return 0
    resp=$(curl -fsSL --max-time 60 --get \
        --data-urlencode "action=update_venue" --data-urlencode "venue_id=${vid}" \
        --data-urlencode "field=${field}" --data-urlencode "value=${value}" \
        "${APPS_SCRIPT_URL}") || return 1
    printf '%s' "$resp" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") == "ok" else 1)' 2>/dev/null
}

if [ "$APPLY" = "1" ]; then
    total=$(wc -l < "$UPDATES" | tr -d ' ')
    echo ""
    echo "Applying $total location repairs..."
    count=0
    applied=0
    errors=0
    while IFS=$'\t' read -r vid new_city new_state; do
        [ -n "$vid" ] || continue
        ok=1
        if [ -n "$new_city" ] && ! update_field "$vid" city "$new_city"; then
            ok=0
            echo "  FAILED city update: $vid → $new_city" >&2
        fi
        if [ -n "$new_state" ] && ! update_field "$vid" state "$new_state"; then
            ok=0
            echo "  FAILED state update: $vid → $new_state" >&2
        fi
        count=$((count + 1))
        if [ "$ok" = "1" ]; then
            applied=$((applied + 1))
        else
            errors=$((errors + 1))
        fi
        if [ $((count % 50)) -eq 0 ]; then
            echo "  ... $count / $total processed"
        fi
    done < "$UPDATES"
    echo ""
    echo "=== LOCATION REPAIR COMPLETE ==="
    echo "Applied: $applied repairs (confirmed by the API)"
    echo "Failed:  $errors"
    [ "$errors" -eq 0 ] || exit 1
fi
