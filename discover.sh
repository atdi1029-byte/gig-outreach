#!/bin/bash
# =============================================================
# Venue Discovery — Google Maps "People also search for" Scraper
#
# Reads past gigs from the sheet, opens each on Google Maps,
# scrapes "People also search for" / "Similar nearby" results,
# filters to relevant venue types, and adds new ones to sheet.
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

# Venue types we care about (lowercase match)
GOOD_TYPES="restaurant|fine dining|hotel|inn|resort|winery|vineyard|country club|golf club|museum|event venue|banquet|bistro|steakhouse|french restaurant|italian restaurant|seafood restaurant|american restaurant|mediterranean restaurant"
SKIP_TYPES="pub|bar|fast food|pizza|diner|gas station|grocery|pharmacy|convenience|laundromat|car wash|dentist|doctor|bank|atm"

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
GIGS_JSON=$(curl -sL "${APPS_SCRIPT_URL}?action=get_gigs")
GIG_COUNT=$(echo "$GIGS_JSON" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len([g for g in d.get('gigs',[]) if g.get('venue_name','') != '(DELETED)']))" 2>/dev/null || echo "0")

if [ "$GIG_COUNT" = "0" ]; then
    log "No past gigs found. Add some gigs first!"
    exit 1
fi
log "Found $GIG_COUNT past gigs"

# --- Step 2: Fetch existing venues (for dedup) ---
log "Fetching existing venues..."
EXISTING_JSON=$(curl -sL "${APPS_SCRIPT_URL}?action=venues")
EXISTING_NAMES=$(echo "$EXISTING_JSON" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for v in d.get('venues',[]):
    print(v.get('name','').lower().strip())
" 2>/dev/null)

# --- Step 3: For each past gig, scrape Google Maps ---
ALL_DISCOVERED="[]"

echo "$GIGS_JSON" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for g in d.get('gigs',[]):
    if g.get('venue_name','') != '(DELETED)':
        print(g['venue_name'] + '|||' + g.get('category',''))
" 2>/dev/null | while IFS='|||' read -r VENUE_NAME CATEGORY; do
    [ -z "$VENUE_NAME" ] && continue
    log ""
    log "--- Searching: $VENUE_NAME ---"

    # URL-encode the venue name
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$VENUE_NAME'))")

    # Navigate to Google Maps search
    MAPS_URL="https://www.google.com/maps/search/${ENCODED}"
    osascript -e "tell application \"Google Chrome\" to activate" -e "delay 0.5" -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${MAPS_URL}\""
    rand_delay 4 6

    # Click first result to open place details
    osascript << 'CLICKEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            // Click the first place result
            var results = document.querySelectorAll('a[href*=\"/maps/place/\"]');
            if (results.length > 0) {
                results[0].click();
                return 'clicked';
            }
            // Try h3/div links
            var divs = document.querySelectorAll('div[role=feed] > div');
            if (divs.length > 0) {
                divs[0].click();
                return 'clicked-div';
            }
            return 'no-results';
        })()
    "
end tell
CLICKEOF
    rand_delay 3 5

    # Scroll down to find "People also search for" / "Similar nearby"
    log "  Scrolling to find recommendations..."
    osascript << 'SCROLLEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var panel = document.querySelector('div[role=main]');
            if (panel) {
                var scrollable = panel.querySelector('.m6QErb.DxyBCb.kA9KIf.dS8AEf');
                if (!scrollable) scrollable = panel.querySelector('[tabindex=\"-1\"]');
                if (!scrollable) scrollable = panel;
                // Scroll down multiple times
                var i = 0;
                var timer = setInterval(function() {
                    scrollable.scrollTop += 600;
                    i++;
                    if (i > 12) clearInterval(timer);
                }, 300);
            }
            return 'scrolling';
        })()
    "
end tell
SCROLLEOF
    rand_delay 5 7

    # Extract "People also search for" and "Similar nearby" cards
    log "  Extracting recommendations..."
    CARDS_JSON=$(osascript << 'EXTRACTEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var results = [];
            // Method 1: Look for 'People also search for' or 'Similar' section headers
            var headers = document.querySelectorAll('h2, h3');
            for (var h = 0; h < headers.length; h++) {
                var text = headers[h].textContent.toLowerCase();
                if (text.indexOf('people also') > -1 || text.indexOf('similar') > -1) {
                    // Get the next sibling container with cards
                    var container = headers[h].nextElementSibling || headers[h].parentElement.nextElementSibling;
                    if (!container) continue;
                    var cards = container.querySelectorAll('a');
                    for (var c = 0; c < cards.length; c++) {
                        var card = cards[c];
                        var name = '';
                        var rating = '';
                        var reviews = '';
                        var category = '';
                        var nameEl = card.querySelector('div[class*=\"fontHeadlineSmall\"], span[class*=\"fontHeadlineSmall\"]');
                        if (!nameEl) {
                            var spans = card.querySelectorAll('span');
                            for (var s = 0; s < spans.length; s++) {
                                if (spans[s].textContent.length > 3 && spans[s].textContent.length < 60 && !spans[s].textContent.match(/^[0-9.]+$/)) {
                                    name = spans[s].textContent.trim();
                                    break;
                                }
                            }
                        } else {
                            name = nameEl.textContent.trim();
                        }
                        // Get all text to find rating/category
                        var allText = card.textContent;
                        var ratingMatch = allText.match(/([0-9]\\.[0-9])\\s*[★⭐]/);
                        if (!ratingMatch) ratingMatch = allText.match(/([0-9]\\.[0-9])\\s*\\(/);
                        if (ratingMatch) rating = ratingMatch[1];
                        var reviewMatch = allText.match(/\\(([0-9,]+)\\)/);
                        if (reviewMatch) reviews = reviewMatch[1].replace(',','');
                        // Category is usually the last descriptive line
                        var lines = allText.split('\\n').map(function(l){return l.trim()}).filter(function(l){return l.length > 2 && l.length < 40});
                        for (var li = lines.length - 1; li >= 0; li--) {
                            if (!lines[li].match(/^[0-9.$,\\s()+★⭐·]+$/) && lines[li] !== name) {
                                category = lines[li];
                                break;
                            }
                        }
                        if (name && name !== '?') {
                            results.push(JSON.stringify({name: name, rating: rating, reviews: reviews, category: category}));
                        }
                    }
                }
            }
            // Method 2: Fallback — look for card containers with images + place info
            if (results.length === 0) {
                var allLinks = document.querySelectorAll('a[href*=\"/maps/place/\"]');
                var mainPlace = document.querySelector('h1');
                var mainName = mainPlace ? mainPlace.textContent.trim().toLowerCase() : '';
                for (var a = 0; a < allLinks.length; a++) {
                    var link = allLinks[a];
                    var img = link.querySelector('img');
                    if (!img) continue;
                    var lt = link.textContent.trim();
                    if (lt.toLowerCase().indexOf(mainName) > -1) continue; // skip the main place itself
                    var nm = '';
                    var spans2 = link.querySelectorAll('span, div');
                    for (var s2 = 0; s2 < spans2.length; s2++) {
                        var st = spans2[s2].textContent.trim();
                        if (st.length > 3 && st.length < 50 && !st.match(/^[0-9.$,\\s()+★⭐·mi away]+$/)) {
                            nm = st;
                            break;
                        }
                    }
                    if (!nm) continue;
                    var rt2 = lt.match(/([0-9]\\.[0-9])/);
                    results.push(JSON.stringify({name: nm, rating: rt2 ? rt2[1] : '', reviews: '', category: ''}));
                }
            }
            return '[' + results.join(',') + ']';
        })()
    "
end tell
EXTRACTEOF
)

    # Process results
    if [ -z "$CARDS_JSON" ] || [ "$CARDS_JSON" = "[]" ]; then
        log "  No recommendations found for $VENUE_NAME"
        continue
    fi

    FOUND_COUNT=$(echo "$CARDS_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
    log "  Found $FOUND_COUNT recommendations"

    # Filter and add to sheet
    echo "$CARDS_JSON" | python3 << PYEOF
import json, sys, urllib.parse, urllib.request

cards = json.loads(sys.stdin.read())
existing = set('''$EXISTING_NAMES'''.strip().lower().split('\n'))
good_types = '''$GOOD_TYPES'''.lower().split('|')
skip_types = '''$SKIP_TYPES'''.lower().split('|')
api = '''$APPS_SCRIPT_URL'''
source_venue = '''$VENUE_NAME'''

added = 0
for card in cards:
    name = card.get('name', '').strip()
    cat = card.get('category', '').lower()
    rating = card.get('rating', '')

    if not name or len(name) < 3:
        continue

    # Skip if already in sheet
    if name.lower().strip() in existing:
        print(f"  SKIP (exists): {name}")
        continue

    # Skip bad types
    if any(s in cat for s in skip_types):
        print(f"  SKIP (type): {name} — {cat}")
        continue

    # Determine category for our system
    our_cat = 'restaurant'  # default
    cat_lower = cat.lower()
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

    # Determine upscale score from rating
    upscale = 3
    if rating:
        r = float(rating)
        if r >= 4.7: upscale = 5
        elif r >= 4.4: upscale = 4
        elif r >= 4.0: upscale = 3
        else: upscale = 2

    # Add to sheet
    params = {
        'action': 'add_venue',
        'name': name,
        'category': our_cat,
        'state': '',  # Will be filled by pipeline later
        'upscale_score': str(upscale),
        'source': f'gmaps_discover:{source_venue}',
        'notes': f'Google Maps: {cat}. Rating: {rating}. Discovered from {source_venue}.'
    }
    encoded = urllib.parse.urlencode(params)
    try:
        resp = urllib.request.urlopen(f"{api}?{encoded}", timeout=15)
        result = json.loads(resp.read())
        if result.get('status') == 'ok' and 'Duplicate' not in result.get('message', ''):
            added += 1
            existing.add(name.lower().strip())
            print(f"  ADDED: {name} ({our_cat}, {rating}★) — from {source_venue}")
        else:
            print(f"  SKIP: {name} — {result.get('message', 'duplicate')}")
    except Exception as e:
        print(f"  ERROR: {name} — {e}")

print(f"\n  Total added from {source_venue}: {added}")
PYEOF

    rand_delay 3 5
done

log ""
log "=== Discovery Complete ==="
echo ""
echo "Now run the pipeline on new venues to find contacts + emails."
echo "Then check Smart Picks in the app for ranked results."
