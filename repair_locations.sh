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
#   2. Website domain hints
#   3. Leave unknown if can't determine
#
# Idempotent — safe to run multiple times.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env" 2>/dev/null || true
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"

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
            fi
            ;;
    esac
done

if [ "$APPLY" = "0" ]; then
    echo "[DRY RUN] Audit only. Use --apply to update the sheet."
fi

echo "Fetching all venues..."
curl -sL "${APPS_SCRIPT_URL}?action=venues" -o /tmp/repair_venues.json

# Get venue IDs for untouched venues
python3 -c "
import json
with open('/tmp/repair_venues.json') as f:
    venues = json.load(f).get('venues', [])
untouched = [v for v in venues if v.get('status') == 'untouched']
with open('/tmp/repair_venue_ids.txt', 'w') as f:
    for v in untouched:
        f.write(v['venue_id'] + '\n')
print(f'Untouched venues to audit: {len(untouched)}')
"

TOTAL=$(wc -l < /tmp/repair_venue_ids.txt | tr -d ' ')
echo "Fetching venue details for $TOTAL venues..."
echo "(This will take a while — ~1 request per second)"

# Fetch venue details and save to JSONL
> /tmp/repair_details.jsonl
count=0
while read -r vid; do
    if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
        break
    fi
    detail=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${vid}" 2>/dev/null)
    echo "$detail" >> /tmp/repair_details.jsonl
    count=$((count + 1))
    if [ $((count % 50)) -eq 0 ]; then
        echo "  ... fetched $count / $TOTAL"
    fi
done < /tmp/repair_venue_ids.txt

echo "Fetched $count venue details."
echo "Analyzing locations..."

cd "$SCRIPT_DIR"

python3 << 'PYEOF'
import json, sys, re, os
from collections import Counter

APPLY = int(os.environ.get('APPLY_FLAG', '0'))

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

# State abbreviation regex
STATE_RE = re.compile(
    r'\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|'
    r'LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|'
    r'OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\b')

def parse_city_state_from_address(address):
    """Extract city and state from a formatted address string.
    Returns (city, state) or (None, None) if unparseable."""
    if not address or len(address) < 5:
        return None, None

    # Try to find state abbreviation
    state_match = STATE_RE.search(address)
    if not state_match:
        return None, None

    state = state_match.group(1)

    # Extract city: text before state, after last comma
    before = address[:state_match.start()].rstrip(', ')
    parts = before.split(',')

    if not parts:
        return None, state

    # Last part before state is usually the city
    city_candidate = parts[-1].strip()

    # If it looks like a street number, try the part before
    if city_candidate and city_candidate[0].isdigit():
        if len(parts) > 1:
            city_candidate = parts[-2].strip()
        else:
            return None, state

    # Clean up
    city_candidate = city_candidate.strip()
    if not city_candidate or len(city_candidate) < 2:
        return None, state

    # Don't accept garbage
    if any(c in city_candidate.lower() for c in [
        'http', 'www.', '.com', '@', 'phone', 'email']):
        return None, state

    return city_candidate, state


# Load venue details
details = []
with open('/tmp/repair_details.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            venue = d.get('venue', {})
            if venue:
                details.append(venue)
        except json.JSONDecodeError:
            continue

print(f"Loaded {len(details)} venue details")

# Analyze each venue
repairs = []
stats = {
    'total': len(details),
    'correct': 0,
    'city_fixed': 0,
    'state_fixed': 0,
    'city_state_fixed': 0,
    'no_address': 0,
    'unparseable': 0,
    'neighborhood_to_city': 0,
}

for v in details:
    vid = v.get('venue_id', '')
    name = v.get('name', '')
    old_city = (v.get('city', '') or '').strip()
    old_state = (v.get('state', '') or '').strip()
    address = (v.get('address', '') or '').strip()
    notes = (v.get('notes', '') or '')

    # Try to parse actual city/state from address
    if not address or address == name:
        # No useful address data
        # Check if notes contain location info
        addr_city, addr_state = None, None
        stats['no_address'] += 1
    else:
        addr_city, addr_state = parse_city_state_from_address(address)

    if addr_city is None and addr_state is None:
        stats['unparseable'] += 1
        # Can't fix — but flag if current city is a neighborhood
        old_lower = old_city.lower()
        if old_lower in DC_NEIGHBORHOODS:
            repairs.append({
                'venue_id': vid,
                'name': name,
                'old_city': old_city,
                'new_city': 'Washington',
                'old_state': old_state,
                'new_state': old_state or 'DC',
                'source': 'neighborhood_map',
                'address': address,
            })
            stats['neighborhood_to_city'] += 1
        elif old_lower in BALT_NEIGHBORHOODS:
            repairs.append({
                'venue_id': vid,
                'name': name,
                'old_city': old_city,
                'new_city': 'Baltimore',
                'old_state': old_state,
                'new_state': old_state or 'MD',
                'source': 'neighborhood_map',
                'address': address,
            })
            stats['neighborhood_to_city'] += 1
        continue

    # Compare parsed address to stored city/state
    new_city = addr_city or old_city
    new_state = addr_state or old_state

    # Normalize for comparison
    city_changed = (new_city.lower().strip() != old_city.lower().strip()) \
        if new_city and old_city else bool(new_city and not old_city)
    state_changed = (new_state != old_state) \
        if new_state and old_state else bool(new_state and not old_state)

    # Also fix DC neighborhoods to Washington
    if old_city.lower() in DC_NEIGHBORHOODS and not city_changed:
        new_city = 'Washington'
        city_changed = True

    if old_city.lower() in BALT_NEIGHBORHOODS and not city_changed:
        new_city = 'Baltimore'
        city_changed = True

    if city_changed or state_changed:
        repair_type = 'city+state' if city_changed and state_changed \
            else 'city' if city_changed else 'state'
        repairs.append({
            'venue_id': vid,
            'name': name,
            'old_city': old_city,
            'new_city': new_city,
            'old_state': old_state,
            'new_state': new_state,
            'source': 'address_parse',
            'address': address,
        })
        if city_changed and state_changed:
            stats['city_state_fixed'] += 1
        elif city_changed:
            stats['city_fixed'] += 1
        else:
            stats['state_fixed'] += 1
    else:
        stats['correct'] += 1

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

# Show repairs by type
print(f"\n=== REPAIR EXAMPLES (first 40) ===")
for r in repairs[:40]:
    city_change = f"{r['old_city']:20s} → {r['new_city']:20s}" \
        if r['old_city'] != r['new_city'] else f"{r['old_city']:20s}   (same)"
    state_change = f"{r['old_state']:3s}→{r['new_state']:3s}" \
        if r['old_state'] != r['new_state'] else f"{r['old_state']:3s}    "
    print(f"  {r['name']:40s}  {city_change}  {state_change}  [{r['source']}]")

# Common fix patterns
print(f"\n=== MOST COMMON CITY CHANGES ===")
changes = Counter()
for r in repairs:
    if r['old_city'] != r['new_city']:
        changes[f"{r['old_city']} → {r['new_city']}"] += 1
for change, count in changes.most_common(20):
    print(f"  {change}: {count}")

# Write repair file
with open('/tmp/repair_updates.tsv', 'w') as f:
    for r in repairs:
        f.write(f"{r['venue_id']}\t{r['new_city']}\t{r['new_state']}\n")
print(f"\nWrote {len(repairs)} repairs to /tmp/repair_updates.tsv")
PYEOF

if [ "$APPLY" = "1" ]; then
    total=$(wc -l < /tmp/repair_updates.tsv | tr -d ' ')
    echo ""
    echo "Applying $total location repairs..."
    count=0
    errors=0
    while IFS=$'\t' read -r vid new_city new_state; do
        # Update city
        if [ -n "$new_city" ]; then
            city_enc=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$new_city'))")
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${vid}&field=city&value=${city_enc}" > /dev/null 2>&1
        fi
        # Update state
        if [ -n "$new_state" ]; then
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${vid}&field=state&value=${new_state}" > /dev/null 2>&1
        fi
        count=$((count + 1))
        if [ $((count % 50)) -eq 0 ]; then
            echo "  ... $count / $total applied"
        fi
    done < /tmp/repair_updates.tsv
    echo ""
    echo "=== LOCATION REPAIR COMPLETE ==="
    echo "Applied: $count repairs"
fi
