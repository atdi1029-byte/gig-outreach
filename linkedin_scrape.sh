#!/bin/bash
# =============================================================
# LinkedIn People Search Scraper (Cleanup Step)
# Searches LinkedIn for employees at a venue, extracts names + titles.
# Cross-references with existing contacts in the sheet.
# NEW people get added as contacts (source=linkedin, no email).
#
# This is the LAST step in the pipeline — Apollo does the heavy lifting.
# LinkedIn catches people Apollo missed.
#
# Usage: ./linkedin_scrape.sh "Venue Name" "VENUE_ID"
# Optional: ./linkedin_scrape.sh "Venue Name" "VENUE_ID" 3   (pages, default 3)
#
# Requirements:
#   - Chrome open and logged into LinkedIn
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\" [pages]}"
VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\" [pages]}"
MAX_PAGES="${3:-3}"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
OUTPUT_FILE="/Users/alexbarnett/Documents/Code/Claude/Email/linkedin_results.json"

# Random delay function (min, max in seconds)
rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

echo "=== LinkedIn People Search ==="
echo "Venue: $VENUE"
echo "Venue ID: $VENUE_ID"
echo "Pages: $MAX_PAGES"
echo ""

# --- Activate Chrome ---
osascript -e 'tell application "Google Chrome" to activate'
rand_delay 1 2

ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$VENUE'))")
ALL_RESULTS="[]"

for PAGE in $(seq 1 $MAX_PAGES); do
    URL="https://www.linkedin.com/search/results/people/?keywords=${ENCODED}&origin=GLOBAL_SEARCH_HEADER&page=${PAGE}"

    echo "--- Page $PAGE ---"
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${URL}\""
    rand_delay 4 7

    # Wait for results to load
    COUNT=0
    for RETRY in 1 2 3 4 5; do
        COUNT=$(osascript -e '
tell application "Google Chrome"
    execute active tab of front window javascript "document.querySelectorAll(\"[data-view-name=search-entity-result-universal-template]\").length"
end tell' 2>/dev/null)
        if [ "$COUNT" -gt 0 ] 2>/dev/null; then
            break
        fi
        sleep 2
    done

    if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
        echo "  No results on page $PAGE — stopping."
        break
    fi
    echo "  Found $COUNT results"

    # Extract structured data
    PAGE_JSON=$(osascript -e '
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var results = [];
            var cards = document.querySelectorAll(\"[data-view-name=search-entity-result-universal-template]\");
            cards.forEach(function(card) {
                var nameEl = card.querySelector(\"span[aria-hidden=true]\");
                var name = nameEl ? nameEl.textContent.trim() : \"?\";
                var lines = card.innerText.split(\"\\n\").map(function(l){return l.trim()}).filter(function(l){return l.length > 0});
                var title = \"\", loc = \"\";
                for (var j = 0; j < lines.length; j++) {
                    if (lines[j].match(/degree connection/)) {
                        if (j+1 < lines.length) title = lines[j+1];
                        if (j+2 < lines.length) loc = lines[j+2];
                        break;
                    }
                }
                var isCurrent = !title.toLowerCase().includes(\"past:\") && !title.toLowerCase().startsWith(\"former\");
                results.push(JSON.stringify({name:name, title:title, location:loc, current:isCurrent}));
            });
            return \"[\" + results.join(\",\") + \"]\";
        })()
    "
end tell' 2>/dev/null)

    # Print results
    echo "$PAGE_JSON" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for p in data:
    flag = '  ' if p['current'] else 'XX'
    print(f\"  [{flag}] {p['name']} — {p['title']} ({p['location']})\")
"

    # Merge into ALL_RESULTS
    ALL_RESULTS=$(python3 -c "
import json
a = json.loads('''$ALL_RESULTS''')
b = json.loads('''$PAGE_JSON''')
a.extend(b)
print(json.dumps(a))
")

    if [ "$PAGE" -lt "$MAX_PAGES" ]; then
        rand_delay 5 10
    fi
done

# Save raw results
echo "$ALL_RESULTS" | python3 -m json.tool > "$OUTPUT_FILE"

# Filter to confirmed employees (venue name in title) + current only
echo ""
echo "=== Filtering to confirmed employees ==="
CONFIRMED=$(python3 << PYEOF
import json, sys, urllib.parse, urllib.request

data = json.loads('''$ALL_RESULTS''')
venue = '''$VENUE'''.lower()
venue_id = '''$VENUE_ID'''
api = '''$APPS_SCRIPT_URL'''

# Key words from venue name (skip short filler words)
skip = {'the','at','in','of','and','for','a','an','by','on','to','&'}
venue_words = [w for w in venue.split() if w.lower() not in skip and len(w) > 2]

# Filter: must have venue name in title + be current employee
confirmed = []
for p in data:
    if not p.get('current', True):
        continue
    title_lower = p['title'].lower()
    has_venue = any(w in title_lower for w in venue_words)
    if has_venue:
        confirmed.append(p)
        print(f"  {p['name']} — {p['title']}")

print(f"\n  Confirmed: {len(confirmed)} | Total scraped: {len(data)}")

# Fetch existing contacts for this venue
print("\n--- Cross-referencing with sheet ---")
try:
    url = f"{api}?action=venue_detail&venue_id={venue_id}"
    resp = urllib.request.urlopen(url, timeout=15)
    sheet_data = json.loads(resp.read())
    existing_names = set()
    if sheet_data.get('status') == 'ok':
        for c in sheet_data.get('contacts', []):
            existing_names.add(c.get('name', '').lower().strip())
    print(f"  Existing contacts in sheet: {len(existing_names)}")
except Exception as e:
    existing_names = set()
    print(f"  [WARN] Could not fetch existing contacts: {e}")

# Find NEW people not already in sheet
new_people = []
for p in confirmed:
    name_lower = p['name'].lower().strip()
    if name_lower not in existing_names and name_lower != '?':
        new_people.append(p)
        print(f"  NEW: {p['name']} — {p['title']}")
    else:
        print(f"  SKIP (already in sheet): {p['name']}")

print(f"\n  New people to add: {len(new_people)}")

# Add new people as contacts (source=linkedin, no email)
added = 0
for p in new_people:
    name_parts = p['name'].strip().split(' ', 1)
    encoded = {
        'action': 'add_contact',
        'venue_id': venue_id,
        'name': p['name'],
        'title': p['title'],
        'source': 'linkedin',
        'verified': 'pending'
    }
    params = urllib.parse.urlencode(encoded)
    try:
        resp = urllib.request.urlopen(f"{api}?{params}", timeout=15)
        result = json.loads(resp.read())
        if result.get('status') == 'ok':
            added += 1
            print(f"  Added: {p['name']} ({result.get('contact_id', '?')})")
        else:
            print(f"  [WARN] {p['name']}: {result.get('message', 'unknown error')}")
    except Exception as e:
        print(f"  [ERROR] {p['name']}: {e}")

print(f"\n  Total added to sheet: {added}")

# Save new people to JSON for Apollo enrichment
enrich_file = '/Users/alexbarnett/Documents/Code/Claude/Email/linkedin_new_people.json'
import json as j2
with open(enrich_file, 'w') as f:
    j2.dump(new_people, f, indent=2)
print(f"\n  Saved {len(new_people)} new people to: {enrich_file}")
PYEOF
)

echo "$CONFIRMED"
echo ""
echo "=== LinkedIn cleanup complete ==="
echo "Raw results: $OUTPUT_FILE"

# --- Apollo enrichment for new people ---
ENRICH_FILE="/Users/alexbarnett/Documents/Code/Claude/Email/linkedin_new_people.json"
ENRICH_COUNT=$(python3 -c "import json; print(len(json.load(open('$ENRICH_FILE'))))" 2>/dev/null || echo "0")

if [ "$ENRICH_COUNT" -gt 0 ]; then
    echo ""
    echo "=== Starting Apollo enrichment for $ENRICH_COUNT new people ==="
    echo "(This will take ~5-6 min per person with green email icons)"
    echo ""
    /Users/alexbarnett/Documents/Code/Claude/Email/apollo_enrich_linkedin.sh "$VENUE" "$VENUE_ID" "$ENRICH_FILE"
else
    echo ""
    echo "No new people to enrich via Apollo."
fi
