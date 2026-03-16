#!/bin/bash
# =============================================================
# Venue Discovery — Google Maps "People also search for" Scraper
#
# Reads past gigs from the sheet, opens each on Google Maps,
# scrapes "People also search for" results, filters to relevant
# venue types, and adds new ones to the Venues sheet.
#
# Usage: ./discover.sh
#   (no args — pulls past gigs automatically)
#
# Requirements:
#   - Chrome open
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JS_DIR="${SCRIPT_DIR}/js"
LOG_FILE="${SCRIPT_DIR}/discover.log"
DISCOVERED_FILE="${SCRIPT_DIR}/discovered_gigs.txt"
touch "$DISCOVERED_FILE"

rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] ${delay}s..."
    sleep $delay
}

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Helper: run JS from file in Chrome via AppleScript
run_js_file() {
    local js_file="$1"
    osascript -e 'tell application "Google Chrome"' \
              -e "set jsCode to read POSIX file \"${js_file}\"" \
              -e 'execute active tab of front window javascript jsCode' \
              -e 'end tell' 2>/dev/null
}

echo "" >> "$LOG_FILE"
log "=== Venue Discovery Started ==="

# --- Step 1: Fetch past gigs ---
log "Fetching past gigs..."
GIGS_RAW=$(curl -sL "${APPS_SCRIPT_URL}?action=get_gigs")
GIG_LIST=$(echo "$GIGS_RAW" | python3 -c "
import json,sys,re
d=json.loads(sys.stdin.read())
for g in d.get('gigs',[]):
    if g.get('venue_name','') != '(DELETED)':
        name = g['venue_name']
        notes = g.get('notes','')
        # Extract city/state from notes for better Google Maps search
        loc = ''
        m = re.search(r'(?:in |at )?([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),?\s*(?:VA|MD|DC|PA)', notes)
        if m:
            loc = m.group(0).strip().lstrip('in ').lstrip('at ')
        print(name + '\t' + loc)
" 2>/dev/null)

GIG_COUNT=$(echo "$GIG_LIST" | grep -c '[a-zA-Z]')

if [ "$GIG_COUNT" = "0" ]; then
    log "No past gigs found. Add some gigs first!"
    exit 1
fi
log "Found $GIG_COUNT past gigs"

# --- Step 2: Fetch existing venue names (for dedup) ---
log "Fetching existing venues for dedup..."
EXISTING_RAW=$(curl -sL "${APPS_SCRIPT_URL}?action=venues")
EXISTING_FILE="/tmp/discover_existing.txt"
echo "$EXISTING_RAW" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for v in d.get('venues',[]):
    print(v.get('name','').lower().strip())
" > "$EXISTING_FILE" 2>/dev/null

EXISTING_COUNT=$(wc -l < "$EXISTING_FILE" | tr -d ' ')
log "Existing venues: $EXISTING_COUNT"

# --- Step 3: For each past gig, scrape Google Maps ---
TOTAL_ADDED=0

echo "$GIG_LIST" | while IFS=$'\t' read -r VENUE_NAME VENUE_LOC; do
    [ -z "$VENUE_NAME" ] && continue

    # Skip gigs already discovered
    if grep -qFx "$VENUE_NAME" "$DISCOVERED_FILE" 2>/dev/null; then
        log "  SKIP (already discovered): $VENUE_NAME"
        continue
    fi

    log ""
    log "=== Discovering from: $VENUE_NAME ==="

    # Build search query with location for specificity
    SEARCH_QUERY="$VENUE_NAME"
    if [ -n "$VENUE_LOC" ]; then
        SEARCH_QUERY="$VENUE_NAME $VENUE_LOC"
        log "  (searching: $SEARCH_QUERY)"
    fi

    # URL-encode the search query
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$SEARCH_QUERY'''))")

    # Navigate to Google Maps
    MAPS_URL="https://www.google.com/maps/search/${ENCODED}"
    osascript -e "tell application \"Google Chrome\" to activate" \
              -e "delay 0.5" \
              -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${MAPS_URL}\""
    rand_delay 4 6

    # If we landed on search results instead of venue page, click first result
    CLICK_RESULT=$(run_js_file "${JS_DIR}/click_first_result.js")
    if [ "$CLICK_RESULT" = "clicked" ]; then
        log "  Clicked first search result..."
        rand_delay 3 5
    fi

    # Scroll down to load "People also search for" section
    log "  Scrolling to find recommendations..."
    run_js_file "${JS_DIR}/scroll_panel.js"
    rand_delay 5 7

    # Extract "People also search for" cards
    log "  Extracting cards..."
    CARDS_JSON=$(run_js_file "${JS_DIR}/extract_cards.js")

    if [ -z "$CARDS_JSON" ] || [ "$CARDS_JSON" = "[]" ] || [ "$CARDS_JSON" = "missing value" ]; then
        log "  No 'People also search for' found"
        CARDS_JSON="[]"
    else
        CARD_COUNT=$(echo "$CARDS_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
        log "  Found $CARD_COUNT 'People also search for' results"
    fi

    # Also try to get "Similar hotels/places nearby" if present
    SIMILAR_JSON=$(run_js_file "${JS_DIR}/extract_similar.js")
    if [ -z "$SIMILAR_JSON" ] || [ "$SIMILAR_JSON" = "missing value" ]; then
        SIMILAR_JSON="[]"
    fi

    # Try clicking "View more nearby hotels" to get expanded list
    VIEW_MORE_CLICKED=$(osascript -e 'tell application "Google Chrome"' \
        -e 'execute active tab of front window javascript "
(function() {
    var btns = document.querySelectorAll('"'"'button'"'"');
    for (var i = 0; i < btns.length; i++) {
        var t = btns[i].textContent.trim().toLowerCase();
        if (t.indexOf('"'"'view more'"'"') > -1) {
            btns[i].click();
            return '"'"'clicked'"'"';
        }
    }
    return '"'"'none'"'"';
})()"' \
        -e 'end tell' 2>/dev/null)

    EXPANDED_JSON="[]"
    if [ "$VIEW_MORE_CLICKED" = "clicked" ]; then
        log "  Clicked 'View more' — loading expanded list..."
        rand_delay 4 6
        EXPANDED_JSON=$(run_js_file "${JS_DIR}/extract_expanded.js")
        if [ -z "$EXPANDED_JSON" ] || [ "$EXPANDED_JSON" = "missing value" ]; then
            EXPANDED_JSON="[]"
        fi
        log "  Expanded list: found $(echo "$EXPANDED_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo 0) venues"

        # Navigate back to the venue page
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${MAPS_URL}\""
        sleep 3
    fi

    # Merge all results (People also search + Similar nearby + Expanded view more)
    MERGED=$(python3 -c "
import json
a = json.loads('''$CARDS_JSON''') if '''$CARDS_JSON'''.startswith('[') else []
b = json.loads('''$SIMILAR_JSON''') if '''$SIMILAR_JSON'''.startswith('[') else []
c = json.loads('''$EXPANDED_JSON''') if '''$EXPANDED_JSON'''.startswith('[') else []
seen = set()
merged = []
for item in a + b + c:
    if item['name'] not in seen:
        seen.add(item['name'])
        merged.append(item)
print(json.dumps(merged))
" 2>/dev/null || echo "$CARDS_JSON")

    FOUND_COUNT=$(echo "$MERGED" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
    log "  Found $FOUND_COUNT total recommendations"

    # Filter and add to sheet
    ADDED=$(python3 << PYEOF
import json, sys, urllib.parse, subprocess

cards = json.loads('''$MERGED''')
existing_file = open('$EXISTING_FILE')
existing = set(line.strip() for line in existing_file)
existing_file.close()

api = '$APPS_SCRIPT_URL'
source_venue = '''$VENUE_NAME'''

# Skip types - not useful for classical guitar gigs
skip_cats = ['pub', 'irish pub', 'sports bar', 'fast food', 'pizza',
             'diner', 'gas station', 'grocery', 'pharmacy', 'convenience',
             'deli', 'food truck', 'taco',
             'burger', 'sandwich', 'chicken', 'ramen', 'noodle',
             'donut', 'bagel', 'juice']

added = 0
for card in cards:
    name = card.get('name', '').strip()
    cat = card.get('category', '').strip()
    rating = card.get('rating', '')
    reviews = card.get('reviews', '')

    if not name or len(name) < 3:
        continue

    # Skip vacation rentals, room listings, Airbnbs by name pattern
    name_lower = name.lower()
    skip_names = ['cottage', 'apartment', 'vacation rental', 'retreat', 'bedroom',
                  'airbnb', 'vrbo', 'walk to', 'screened porch', 'historic house',
                  'king room', 'queen room', 'deluxe room', 'suite -', 'one-bedroom']
    if any(s in name_lower for s in skip_names):
        print(f"  SKIP (rental): {name}")
        continue

    # Skip room listings (e.g. "Hotel Name - King Room")
    if ' - ' in name and any(w in name_lower for w in ['room', 'suite', 'cottage', 'cabin']):
        print(f"  SKIP (room listing): {name}")
        continue

    # Skip if already in sheet
    if name.lower().strip() in existing:
        print(f"  SKIP (exists): {name}")
        continue

    # Skip bad types
    cat_lower = cat.lower()
    if any(s in cat_lower for s in skip_cats):
        print(f"  SKIP (type): {name} -- {cat}")
        continue

    # Determine our category
    our_cat = 'restaurant'
    if any(t in cat_lower for t in ['hotel', 'inn', 'resort', 'lodge']):
        our_cat = 'hotel'
    elif any(t in cat_lower for t in ['winery', 'vineyard']):
        our_cat = 'winery'
    elif any(t in cat_lower for t in ['country club', 'golf club', 'club']):
        our_cat = 'country_club'
    elif any(t in cat_lower for t in ['museum', 'gallery']):
        our_cat = 'museum'
    elif any(t in cat_lower for t in ['event', 'banquet', 'wedding']):
        our_cat = 'event'

    # Upscale score from rating + review count
    upscale = 3
    if rating:
        r = float(rating)
        if r >= 4.7: upscale = 5
        elif r >= 4.4: upscale = 4
        elif r >= 4.0: upscale = 3
        else: upscale = 2
    # Boost for high review count (popular = bigger audience)
    if reviews and int(reviews) > 1000: upscale = min(5, upscale + 1)

    notes = f"Google Maps '{cat}'. {rating}★ ({reviews} reviews). Discovered from: {source_venue}"

    params = {
        'action': 'add_venue',
        'name': name,
        'category': our_cat,
        'state': '',
        'upscale_score': str(upscale),
        'source': f'gmaps:{source_venue}',
        'notes': notes
    }
    encoded = urllib.parse.urlencode(params)
    url = f"{api}?{encoded}"
    try:
        result_raw = subprocess.run(['curl', '-sL', url], capture_output=True, text=True, timeout=20)
        result = json.loads(result_raw.stdout)
        if result.get('status') == 'ok' and 'Duplicate' not in result.get('message', ''):
            added += 1
            existing.add(name.lower().strip())
            print(f"  ADDED: {name} ({our_cat}, {rating}★, {reviews} reviews)")
        else:
            print(f"  SKIP: {name} -- {result.get('message', 'duplicate')}")
    except Exception as e:
        print(f"  ERROR: {name} -- {e}")

print(f"ADDED_COUNT:{added}")
PYEOF
)

    echo "$ADDED"
    BATCH_ADDED=$(echo "$ADDED" | grep "ADDED_COUNT:" | sed 's/ADDED_COUNT://')
    TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
    log "  Added $BATCH_ADDED new venues from $VENUE_NAME"

    # Mark this gig as discovered so we skip it next time
    echo "$VENUE_NAME" >> "$DISCOVERED_FILE"

    rand_delay 3 5
done

log ""
log "=== Discovery Complete — Total new venues: $TOTAL_ADDED ==="
echo ""
echo "Next steps:"
echo "  1. Run pipeline on new venues to find contacts + emails"
echo "  2. Check Smart Picks in the app for ranked results"
