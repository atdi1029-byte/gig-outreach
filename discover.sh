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
LOG_FILE="${SCRIPT_DIR}/discover.log"

rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] ${delay}s..."
    sleep $delay
}

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

echo "" >> "$LOG_FILE"
log "=== Venue Discovery Started ==="

# --- Step 1: Fetch past gigs ---
log "Fetching past gigs..."
GIGS_RAW=$(curl -sL "${APPS_SCRIPT_URL}?action=get_gigs")
GIG_LIST=$(echo "$GIGS_RAW" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for g in d.get('gigs',[]):
    if g.get('venue_name','') != '(DELETED)':
        print(g['venue_name'])
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

echo "$GIG_LIST" | while read -r VENUE_NAME; do
    [ -z "$VENUE_NAME" ] && continue
    log ""
    log "=== Discovering from: $VENUE_NAME ==="

    # URL-encode the venue name
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$VENUE_NAME'''))")

    # Navigate to Google Maps
    MAPS_URL="https://www.google.com/maps/search/${ENCODED}"
    osascript << NAVEOF
tell application "Google Chrome" to activate
delay 0.5
tell application "Google Chrome" to set URL of active tab of front window to "${MAPS_URL}"
NAVEOF
    rand_delay 4 6

    # Scroll down to load "People also search for" section
    log "  Scrolling to find recommendations..."
    osascript << 'SCROLLEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var panels = document.querySelectorAll('.m6QErb');
            var scrollable = null;
            for (var p = 0; p < panels.length; p++) {
                if (panels[p].scrollHeight > panels[p].clientHeight + 100) {
                    scrollable = panels[p];
                    break;
                }
            }
            if (!scrollable) return 'no panel';
            var i = 0;
            var timer = setInterval(function() {
                scrollable.scrollTop += 800;
                i++;
                if (i > 15) clearInterval(timer);
            }, 200);
            return 'scrolling';
        })()
    "
end tell
SCROLLEOF
    rand_delay 5 7

    # Extract "People also search for" cards using the working pattern
    log "  Extracting cards..."
    CARDS_JSON=$(osascript << 'EXTRACTEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var headers = document.querySelectorAll('h2');
            var targetH2 = null;
            for (var h = 0; h < headers.length; h++) {
                if (headers[h].textContent.trim().toLowerCase().indexOf('people also search') > -1) {
                    targetH2 = headers[h];
                    break;
                }
            }
            if (!targetH2) return '[]';
            var section = targetH2.parentElement.parentElement;
            var nameEls = section.querySelectorAll('span.GgK1If');
            var names = [];
            for (var n = 0; n < nameEls.length; n++) {
                var nm = nameEls[n].textContent.trim();
                if (nm && nm.length > 2) names.push(nm);
            }
            var fullText = section.textContent;
            var results = [];
            for (var i = 0; i < names.length; i++) {
                var start = fullText.indexOf(names[i]);
                if (start === -1) continue;
                var after = start + names[i].length;
                var end = (i < names.length - 1) ? fullText.indexOf(names[i+1], after) : fullText.length;
                var chunk = fullText.substring(after, end);
                var rating = '';
                var reviews = '';
                var category = '';
                var rm = chunk.match(/([0-9]\.[0-9])/);
                if (rm) rating = rm[1];
                var revm = chunk.match(/\(([0-9,]+)\)/);
                if (revm) reviews = revm[1].replace(/,/g,'');
                var catMatch = chunk.match(/\)[\s]*([A-Za-z][A-Za-z ]+)/);
                if (catMatch) category = catMatch[1].trim();
                results.push(JSON.stringify({name:names[i], rating:rating, reviews:reviews, category:category}));
            }
            return '[' + results.join(',') + ']';
        })()
    "
end tell
EXTRACTEOF
)

    if [ -z "$CARDS_JSON" ] || [ "$CARDS_JSON" = "[]" ] || [ "$CARDS_JSON" = "missing value" ]; then
        log "  No 'People also search for' found"
    fi

    # Also try to get "Similar hotels/places nearby" if present
    SIMILAR_JSON=$(osascript << 'SIMEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var headers = document.querySelectorAll('h2');
            var targetH2 = null;
            for (var h = 0; h < headers.length; h++) {
                var t = headers[h].textContent.trim().toLowerCase();
                if (t.indexOf('similar') > -1 && (t.indexOf('hotel') > -1 || t.indexOf('nearby') > -1)) {
                    targetH2 = headers[h];
                    break;
                }
            }
            if (!targetH2) return '[]';
            var section = targetH2.parentElement.parentElement;
            var nameEls = section.querySelectorAll('span.GgK1If');
            var names = [];
            for (var n = 0; n < nameEls.length; n++) {
                var nm = nameEls[n].textContent.trim();
                if (nm && nm.length > 2) names.push(nm);
            }
            var fullText = section.textContent;
            var results = [];
            for (var i = 0; i < names.length; i++) {
                var start = fullText.indexOf(names[i]);
                if (start === -1) continue;
                var after = start + names[i].length;
                var end = (i < names.length - 1) ? fullText.indexOf(names[i+1], after) : fullText.length;
                var chunk = fullText.substring(after, end);
                var rating = '';
                var reviews = '';
                var category = 'Hotel';
                var rm = chunk.match(/([0-9]\.[0-9])/);
                if (rm) rating = rm[1];
                var revm = chunk.match(/\(([0-9,]+)\)/);
                if (revm) reviews = revm[1].replace(/,/g,'');
                results.push(JSON.stringify({name:names[i], rating:rating, reviews:reviews, category:category}));
            }
            return '[' + results.join(',') + ']';
        })()
    "
end tell
SIMEOF
)

    # Try clicking "View more nearby hotels" to get expanded list
    VIEW_MORE_CLICKED=$(osascript << 'VMEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var btns = document.querySelectorAll('button');
            for (var i = 0; i < btns.length; i++) {
                var t = btns[i].textContent.trim().toLowerCase();
                if (t.indexOf('view more') > -1 && (t.indexOf('hotel') > -1 || t.indexOf('nearby') > -1)) {
                    btns[i].click();
                    return 'clicked';
                }
            }
            return 'none';
        })()
    "
end tell
VMEOF
)
    EXPANDED_JSON="[]"
    if [ "$VIEW_MORE_CLICKED" = "clicked" ]; then
        log "  Clicked 'View more' — loading expanded list..."
        rand_delay 4 6
        EXPANDED_JSON=$(osascript << 'EXPEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var panels = document.querySelectorAll('.m6QErb');
            var scrollable = null;
            for (var p = 0; p < panels.length; p++) {
                if (panels[p].scrollHeight > panels[p].clientHeight + 50) {
                    scrollable = panels[p];
                    break;
                }
            }
            if (!scrollable) return '[]';
            scrollable.scrollTop = scrollable.scrollHeight;
            var cards = scrollable.querySelectorAll('[jsaction*=\"mouseover\"]');
            var results = [];
            var seen = {};
            for (var c = 0; c < cards.length; c++) {
                var text = cards[c].textContent;
                var headline = cards[c].querySelector('.fontHeadlineSmall, .NrDZNb, .qBF1Pd');
                if (!headline) continue;
                var name = headline.textContent.trim();
                if (!name || name.length < 3 || name.length > 60) continue;
                if (seen[name]) continue;
                seen[name] = true;
                var rating = '';
                var rm = text.match(/([0-9]\\.[0-9])/);
                if (rm) rating = rm[1];
                var reviews = '';
                var revm = text.match(/\\(([0-9,]+)\\)/);
                if (revm) reviews = revm[1].replace(/,/g,'');
                results.push(JSON.stringify({name: name, rating: rating, reviews: reviews, category: 'Hotel'}));
            }
            return '[' + results.join(',') + ']';
        })()
    "
end tell
EXPEOF
)
        log "  Expanded list: found $(echo "$EXPANDED_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo 0) hotels"

        # Navigate back to the venue page for any further scraping
        osascript << BACKEOF
tell application "Google Chrome" to set URL of active tab of front window to "${MAPS_URL}"
BACKEOF
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
skip_cats = ['pub', 'irish pub', 'bar', 'sports bar', 'fast food', 'pizza',
             'diner', 'gas station', 'grocery', 'pharmacy', 'convenience',
             'coffee', 'cafe', 'bakery', 'deli', 'food truck', 'taco',
             'burger', 'sandwich', 'chicken', 'sushi', 'ramen', 'noodle',
             'ice cream', 'donut', 'bagel', 'juice']

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

    rand_delay 3 5
done

log ""
log "=== Discovery Complete — Total new venues: $TOTAL_ADDED ==="
echo ""
echo "Next steps:"
echo "  1. Run pipeline on new venues to find contacts + emails"
echo "  2. Check Smart Picks in the app for ranked results"
