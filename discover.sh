#!/bin/bash
# =============================================================
# Venue Discovery — Google Maps Scraper
#
# Modes:
#   ./discover.sh           — crawl "People also search for" from past gigs
#   ./discover.sh --learn   — scrape Google Maps attributes from 8.5+ gigs,
#                             build taste_keywords.json
#   ./discover.sh --taste   — use taste profile to search for new venues
#                             (combines keywords × venue types × locations)
#
# Env vars:
#   MAX_GIGS=N     — limit gigs processed (default mode + --learn)
#   MAX_QUERIES=N  — limit search queries (--taste mode, default 20)
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
TASTE_KEYWORDS_FILE="${SCRIPT_DIR}/taste_keywords.json"
TASTE_QUERIES_FILE="${SCRIPT_DIR}/taste_queries.txt"
touch "$DISCOVERED_FILE"
touch "$TASTE_QUERIES_FILE"

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

# =============================================================
# MODE: --learn
# Scrape Google Maps attributes from taste_venues.txt to build
# a keyword profile (taste_keywords.json)
# =============================================================
if [ "$1" = "--learn" ]; then
    log "=== Taste Learn Mode Started ==="
    TASTE_VENUES_FILE="${SCRIPT_DIR}/taste_venues.txt"

    if [ ! -f "$TASTE_VENUES_FILE" ]; then
        log "ERROR: taste_venues.txt not found!"
        exit 1
    fi

    # Read venue list and match against past gigs for location/score
    log "Fetching past gigs for location data..."
    GIGS_TMP="/tmp/taste_learn_gigs.json"
    curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o "$GIGS_TMP"

    DREAM_GIGS=$(python3 - "$TASTE_VENUES_FILE" "$GIGS_TMP" << 'PYEOF'
import json, sys, re

venues_file = sys.argv[1]
gigs_file = sys.argv[2]

with open(gigs_file) as f:
    gigs_data = json.loads(f.read())

# Load venue whitelist
whitelist = set()
with open(venues_file) as f:
    for line in f:
        name = line.strip()
        if name:
            whitelist.add(name.lower())

# Match against past gigs for location + score
for g in gigs_data.get('gigs', []):
    name = g.get('venue_name', '')
    if name.lower() not in whitelist:
        continue
    score = g.get('overall_score', 0)
    notes = g.get('notes', '')
    loc = '_'
    m = re.search(r'(?:in |at )?([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),?\s*(?:VA|MD|DC|PA)', notes)
    if m:
        loc = m.group(0).strip().lstrip('in ').lstrip('at ')
    print(name + '\t' + loc + '\t' + str(score))

# Also add venues from whitelist not in gigs (no score/location)
gig_names = set(g.get('venue_name', '').lower() for g in gigs_data.get('gigs', []))
for v in whitelist:
    if v not in gig_names:
        with open(venues_file) as f:
            for line in f:
                if line.strip().lower() == v:
                    print(line.strip() + '\t_\t0')
                    break
PYEOF
    )

    DREAM_COUNT=$(echo "$DREAM_GIGS" | grep -c '[a-zA-Z]')
    if [ "$DREAM_COUNT" = "0" ]; then
        log "No venues found in taste_venues.txt!"
        exit 1
    fi
    log "Found $DREAM_COUNT taste venues"

    # For each dream gig, visit Google Maps and extract attributes
    ALL_ATTRS_FILE="/tmp/taste_learn_attrs.json"
    echo "[]" > "$ALL_ATTRS_FILE"
    GIGS_PROCESSED=0
    MAX_GIGS=${MAX_GIGS:-0}

    while IFS=$'\t' read -r VENUE_NAME VENUE_LOC VENUE_SCORE; do
        [ -z "$VENUE_NAME" ] && continue
        if [ "$MAX_GIGS" -gt 0 ] && [ "$GIGS_PROCESSED" -ge "$MAX_GIGS" ]; then
            log "  MAX_GIGS=$MAX_GIGS reached — stopping."
            break
        fi

        log ""
        log "=== Learning from: $VENUE_NAME ($VENUE_SCORE) ==="

        SEARCH_QUERY="$VENUE_NAME"
        [ -n "$VENUE_LOC" ] && [ "$VENUE_LOC" != "_" ] && SEARCH_QUERY="$VENUE_NAME $VENUE_LOC"
        ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$SEARCH_QUERY'''))")
        MAPS_URL="https://www.google.com/maps/search/${ENCODED}"

        osascript -e "tell application \"Google Chrome\" to activate" \
                  -e "delay 0.5" \
                  -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${MAPS_URL}\""
        rand_delay 4 6

        # Click first result if on search results page
        CLICK_RESULT=$(run_js_file "${JS_DIR}/click_first_result.js")
        if [ "$CLICK_RESULT" = "clicked" ]; then
            log "  Clicked first search result..."
            rand_delay 3 5
        fi

        # Try clicking About tab to reveal attributes
        ABOUT_RESULT=$(run_js_file "${JS_DIR}/click_about_tab.js")
        if [ "$ABOUT_RESULT" = "clicked" ]; then
            log "  Opened About tab"
            rand_delay 2 3
        fi

        # Scroll to load all content
        run_js_file "${JS_DIR}/scroll_panel.js"
        rand_delay 3 5

        # Extract venue attributes
        ATTRS_JSON=$(run_js_file "${JS_DIR}/extract_venue_attributes.js")
        if [ -z "$ATTRS_JSON" ] || [ "$ATTRS_JSON" = "missing value" ]; then
            ATTRS_JSON='{"category":"","price":"","attributes":[]}'
            log "  No attributes extracted"
        else
            ATTR_COUNT=$(echo "$ATTRS_JSON" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('attributes',[])))" 2>/dev/null || echo "0")
            log "  Extracted $ATTR_COUNT attributes"
        fi

        # Append to collected data
        ATTRS_TMP="/tmp/taste_learn_single.json"
        echo "$ATTRS_JSON" > "$ATTRS_TMP"
        python3 - "$ATTRS_TMP" "$VENUE_NAME" "$VENUE_SCORE" "$ALL_ATTRS_FILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    attrs = json.loads(f.read())
attrs['venue'] = sys.argv[2]
attrs['score'] = float(sys.argv[3])
out_file = sys.argv[4]

with open(out_file, 'r') as f:
    all_data = json.loads(f.read())
all_data.append(attrs)
with open(out_file, 'w') as f:
    json.dump(all_data, f, indent=2)
PYEOF

        GIGS_PROCESSED=$((GIGS_PROCESSED + 1))
        rand_delay 3 5
    done <<< "$DREAM_GIGS"

    # Aggregate keywords and build taste_keywords.json
    log ""
    log "Aggregating keywords..."
    python3 << PYEOF
import json
from collections import Counter
from datetime import datetime

with open('$ALL_ATTRS_FILE', 'r') as f:
    all_data = json.loads(f.read())

keyword_counts = Counter()
keyword_gigs = {}
price_counts = Counter()
categories = Counter()

for venue in all_data:
    vname = venue.get('venue', '')
    cat = venue.get('category', '')
    price = venue.get('price', '')
    attrs = venue.get('attributes', [])

    if cat:
        categories[cat] += 1
    if price:
        price_counts[price] += 1
    for attr in attrs:
        keyword_counts[attr] += 1
        if attr not in keyword_gigs:
            keyword_gigs[attr] = []
        keyword_gigs[attr].append(vname)

# Build output
ranked = [kw for kw, _ in keyword_counts.most_common(30)]
keywords = {}
for kw in ranked:
    keywords[kw] = {
        'count': keyword_counts[kw],
        'gigs': keyword_gigs[kw]
    }

result = {
    'generated': datetime.now().isoformat(),
    'source_gigs': len(all_data),
    'min_score': 8.5,
    'keywords': keywords,
    'ranked_keywords': ranked,
    'price_levels': dict(price_counts),
    'common_categories': [c for c, _ in categories.most_common(10)]
}

with open('$TASTE_KEYWORDS_FILE', 'w') as f:
    json.dump(result, f, indent=2)

print(f"Saved taste_keywords.json: {len(ranked)} keywords from {len(all_data)} gigs")
print(f"Top keywords: {', '.join(ranked[:10])}")
PYEOF

    log "=== Taste Learn Complete ==="
    exit 0
fi

# =============================================================
# MODE: --taste
# Use taste profile to generate search queries and find new venues
# =============================================================
if [ "$1" = "--taste" ]; then
    log "=== Taste Discovery Mode Started ==="

    # Check that taste_keywords.json exists
    if [ ! -f "$TASTE_KEYWORDS_FILE" ]; then
        log "ERROR: taste_keywords.json not found. Run --learn first!"
        echo "Run './discover.sh --learn' first to build your taste profile."
        exit 1
    fi

    MAX_QUERIES=${MAX_QUERIES:-20}
    log "MAX_QUERIES=$MAX_QUERIES"

    # Fetch existing venues for dedup
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

    # Generate prioritized search queries
    log "Generating search queries from taste profile..."
    QUERIES_FILE="/tmp/taste_generated_queries.txt"
    python3 - "$TASTE_KEYWORDS_FILE" "$TASTE_QUERIES_FILE" << 'PYEOF' > "$QUERIES_FILE"
import json, sys

taste_file = sys.argv[1]
queries_file = sys.argv[2]

with open(taste_file, 'r') as f:
    taste = json.loads(f.read())

completed = set()
try:
    with open(queries_file, 'r') as f:
        for line in f:
            completed.add(line.strip().lower())
except: pass

ranked_kws = taste.get('ranked_keywords', [])[:8]

tier1_types = [
    'luxury hotel', 'fine dining restaurant',
    'historic fine dining restaurant',
    'French restaurant', 'European bistro',
    'private club', 'wine bar', 'country club', 'winery'
]
tier2_types = [
    'upscale restaurant', 'Italian fine dining',
    'boutique hotel', 'historic inn', 'museum event space'
]

tier1_locations = [
    ('Georgetown', 'DC'), ('Dupont Circle', 'DC'),
    ('Potomac', 'MD'), ('Bethesda', 'MD'), ('Chevy Chase', 'MD'),
    ('Great Falls', 'VA'), ('McLean', 'VA'),
    ('Alexandria', 'VA'), ('Reston', 'VA'),
    ('Middleburg', 'VA'), ('Leesburg', 'VA'),
    ('St. Michaels', 'MD'), ('Easton', 'MD'),
    ('Annapolis', 'MD'), ('Roland Park Baltimore', 'MD')
]
tier2_locations = [
    ('Charlottesville', 'VA'), ('Shepherdstown', 'WV'),
    ('Greenville', 'DE'), ('Wilmington', 'DE'),
    ('Kennett Square', 'PA'), ('Bryn Mawr', 'PA'),
    ('Rehoboth Beach', 'DE'), ('Lancaster', 'PA'),
    ('Ellicott City', 'MD'), ('Severna Park', 'MD'),
    ('Vienna', 'VA'), ('Herndon', 'VA'),
    ('Chadds Ford', 'PA'), ('Oxford', 'MD')
]

queries = []

# P1: Tier 1 types x Tier 1 locations
for vtype in tier1_types:
    for city, state in tier1_locations:
        q = f"{vtype} {city} {state}"
        if q.lower() not in completed:
            queries.append(q)

# P2: Tier 1 types x Tier 2 locations
for vtype in tier1_types:
    for city, state in tier2_locations:
        q = f"{vtype} {city} {state}"
        if q.lower() not in completed:
            queries.append(q)

# P3: Tier 2 types x Tier 1 locations
for vtype in tier2_types:
    for city, state in tier1_locations:
        q = f"{vtype} {city} {state}"
        if q.lower() not in completed:
            queries.append(q)

# P4: Keyword-enhanced (top keywords x best types x best locations)
for kw in ranked_kws[:5]:
    for vtype in tier1_types[:4]:
        for city, state in tier1_locations[:8]:
            q = f"{kw} {vtype} {city} {state}"
            if q.lower() not in completed:
                queries.append(q)

for q in queries:
    print(q)
PYEOF

    TOTAL_QUERIES=$(wc -l < "$QUERIES_FILE" | tr -d ' ')
    log "Generated $TOTAL_QUERIES queries ($MAX_QUERIES will run this session)"

    # Process queries
    TOTAL_ADDED=0
    QUERIES_RUN=0

    while IFS= read -r QUERY; do
        [ -z "$QUERY" ] && continue
        if [ "$QUERIES_RUN" -ge "$MAX_QUERIES" ]; then
            log "  MAX_QUERIES=$MAX_QUERIES reached — stopping."
            break
        fi

        log ""
        log "=== Taste Query [$((QUERIES_RUN + 1))/$MAX_QUERIES]: $QUERY ==="

        ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$QUERY'''))")
        MAPS_URL="https://www.google.com/maps/search/${ENCODED}"

        osascript -e "tell application \"Google Chrome\" to activate" \
                  -e "delay 0.5" \
                  -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${MAPS_URL}\""
        rand_delay 4 6

        # Scroll to load all search results
        log "  Scrolling search results..."
        run_js_file "${JS_DIR}/scroll_search_results.js"
        rand_delay 6 8

        # Extract search results
        log "  Extracting results..."
        RESULTS_JSON=$(run_js_file "${JS_DIR}/extract_search_results.js")

        if [ -z "$RESULTS_JSON" ] || [ "$RESULTS_JSON" = "[]" ] || [ "$RESULTS_JSON" = "missing value" ]; then
            log "  No results found"
            echo "$QUERY" >> "$TASTE_QUERIES_FILE"
            QUERIES_RUN=$((QUERIES_RUN + 1))
            rand_delay 3 5
            continue
        fi

        RESULT_COUNT=$(echo "$RESULTS_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
        log "  Found $RESULT_COUNT results"

        # Pre-score, filter, and add venues
        RESULTS_TMP="/tmp/taste_search_results.json"
        echo "$RESULTS_JSON" > "$RESULTS_TMP"
        ADDED_REAL=$(python3 - "$RESULTS_TMP" "$EXISTING_FILE" "$APPS_SCRIPT_URL" "$QUERY" << 'PYEOF2'
import json, sys, urllib.parse, subprocess, re

results_file = sys.argv[1]
existing_file = sys.argv[2]
api = sys.argv[3]
query = sys.argv[4]

with open(results_file) as f:
    results = json.loads(f.read())

existing = set()
with open(existing_file) as f:
    existing = set(line.strip() for line in f)

skip_cats = ['pub', 'irish pub', 'sports bar', 'fast food', 'pizza',
             'diner', 'gas station', 'grocery', 'pharmacy', 'convenience',
             'deli', 'food truck', 'taco', 'burger', 'sandwich',
             'chicken', 'ramen', 'noodle', 'donut', 'bagel', 'juice',
             'bar & grill', 'hookah', 'karaoke', 'nightclub']

skip_names = ['cottage', 'apartment', 'vacation rental', 'retreat',
              'airbnb', 'vrbo', 'walk to', 'screened porch',
              'king room', 'queen room', 'deluxe room', 'suite -',
              'one-bedroom', 'fitness', 'gym', 'urgent care']

tier1_cats = ['country_club', 'private_club', 'yacht_club']
tier2_cats = ['restaurant', 'winery', 'hotel', 'wine_bar', 'museum',
              'event', 'resort', 'art_gallery', 'spa']
tier3_cats = ['golf_club', 'senior_living', 'wedding_venue', 'corporate']

sweet_spots = set([
    'georgetown', 'dupont circle', 'kalorama', 'cleveland park',
    'potomac', 'chevy chase', 'bethesda', 'cabin john',
    'roland park', 'guilford', 'homeland', 'ruxton',
    'st. michaels', 'easton', 'oxford', 'tilghman island',
    'annapolis', 'severna park',
    'great falls', 'mclean', 'alexandria', 'reston', 'vienna',
    'middleburg', 'leesburg', 'purcellville',
    'greenville', 'hockessin', 'wilmington',
    'gladwyne', 'bryn mawr', 'kennett square', 'chadds ford'
])

target_states = {'MD', 'VA', 'DC', 'PA', 'DE', 'WV'}
state_re = re.compile(r'\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\b')

def map_category(cat):
    cl = cat.lower()
    if any(t in cl for t in ['hotel', 'inn', 'resort', 'lodge']): return 'hotel'
    if any(t in cl for t in ['winery', 'vineyard']): return 'winery'
    if any(t in cl for t in ['country club', 'golf club']): return 'country_club'
    if 'wine bar' in cl: return 'wine_bar'
    if any(t in cl for t in ['museum', 'gallery']): return 'museum'
    if any(t in cl for t in ['event', 'banquet', 'wedding']): return 'event'
    if any(t in cl for t in ['yacht', 'sailing']): return 'yacht_club'
    if any(t in cl for t in ['private club', 'social club']): return 'private_club'
    if 'spa' in cl: return 'spa'
    return 'restaurant'

def pre_score(venue):
    score = 0
    cat = venue.get('category', '')
    our_cat = map_category(cat)
    if our_cat in tier1_cats: score += 30
    elif our_cat in tier2_cats: score += 20
    elif our_cat in tier3_cats: score += 10

    location = venue.get('location', '')
    state_match = state_re.search(location)
    state = state_match.group(1) if state_match else ''
    if state in target_states: score += 10
    else: score -= 50

    loc_lower = location.lower()
    for city in sweet_spots:
        if city in loc_lower:
            score += 10
            break

    rating = float(venue.get('rating', 0) or 0)
    reviews = int(venue.get('reviews', 0) or 0)
    if rating >= 4.7: score += 20
    elif rating >= 4.4: score += 15
    elif rating >= 4.0: score += 10
    elif rating >= 3.5: score += 5
    if reviews > 1000: score += 5
    elif reviews > 500: score += 3

    cat_lower = cat.lower()
    if any(s in cat_lower for s in skip_cats): score -= 50

    return max(0, min(100, score)), our_cat, state

added = 0
for venue in results:
    name = venue.get('name', '').strip()
    cat = venue.get('category', '').strip()
    if not name or len(name) < 3: continue

    name_lower = name.lower()
    if any(s in name_lower for s in skip_names): continue
    if name.lower().strip() in existing: continue
    if ' - ' in name and any(w in name_lower for w in ['room', 'suite', 'cottage', 'cabin']): continue

    score, our_cat, state = pre_score(venue)
    if score < 40:
        print(f"  SKIP (score {score}): {name} -- {cat}")
        continue

    rating = venue.get('rating', '')
    reviews = venue.get('reviews', '')
    location = venue.get('location', '')

    city = ''
    if location:
        before_state = state_re.split(location)[0].rstrip(', ') if state_re.search(location) else location
        parts = before_state.split(',')
        city = parts[-1].strip() if parts else ''
        if city and city[0].isdigit(): city = ''

    upscale = 3
    if rating:
        r = float(rating)
        if r >= 4.7: upscale = 5
        elif r >= 4.4: upscale = 4
        elif r >= 4.0: upscale = 3
        else: upscale = 2
    if reviews and int(reviews) > 1000: upscale = min(5, upscale + 1)

    notes = f"Google Maps '{cat}'. {rating}* ({reviews} reviews). Pre-score: {score}. Taste query: {query}"

    params = {
        'action': 'add_venue',
        'name': name,
        'category': our_cat,
        'city': city,
        'state': state,
        'address': location if location else name,
        'upscale_score': str(upscale),
        'source': f'taste:{query[:60]}',
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
            vid = result.get('venue_id', '')
            print(f"  ADDED (score {score}): {name} ({our_cat}, {rating}*, {reviews} reviews)")
            print(f"  WEBSITE_LOOKUP:{vid}:{name}:{state}")
        else:
            print(f"  SKIP: {name} -- {result.get('message', 'duplicate')}")
    except Exception as e:
        print(f"  ERROR: {name} -- {e}")

print(f"ADDED_COUNT:{added}")
PYEOF2
)

        echo "$ADDED_REAL"
        BATCH_ADDED=$(echo "$ADDED_REAL" | grep "ADDED_COUNT:" | sed 's/ADDED_COUNT://')
        BATCH_ADDED=${BATCH_ADDED:-0}
        TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
        log "  Added $BATCH_ADDED new venues from query"

        # Look up websites for newly added venues
        echo "$ADDED_REAL" | grep "WEBSITE_LOOKUP:" | while IFS=':' read -r _ VID VNAME VSTATE; do
            log "  [WEBSITE] Looking up: $VNAME"
            SEARCH_Q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$VNAME''' + ' ' + '''$VSTATE'''))")
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_Q}\""
            sleep 3
            FOUND_WEB=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${JS_DIR}/extract_cite.js"'")' 2>/dev/null)
            if [ -n "$FOUND_WEB" ] && [ "$FOUND_WEB" != "missing value" ] && [ "$FOUND_WEB" != "" ]; then
                log "    Website: $FOUND_WEB"
                curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=website&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$FOUND_WEB'''))")" > /dev/null
            else
                log "    No website found"
            fi
            sleep 1
        done

        # Mark query as completed
        echo "$QUERY" >> "$TASTE_QUERIES_FILE"
        QUERIES_RUN=$((QUERIES_RUN + 1))
        rand_delay 5 8
    done < "$QUERIES_FILE"

    # Calculate distances for new venues
    if [ "$TOTAL_ADDED" -gt 0 ]; then
        log "Calculating distances for new venues..."
        curl -sL "${APPS_SCRIPT_URL}?action=calc_distances" -o /tmp/taste_distances.json
        DIST_COUNT=$(python3 -c "import json; print(json.load(open('/tmp/taste_distances.json')).get('calculated',0))" 2>/dev/null)
        log "  Distances calculated: $DIST_COUNT"
    fi

    REMAINING=$((TOTAL_QUERIES - QUERIES_RUN))
    log ""
    log "=== Taste Discovery Complete ==="
    log "  Queries run: $QUERIES_RUN"
    log "  Venues added: $TOTAL_ADDED"
    log "  Queries remaining: $REMAINING"
    echo ""
    echo "Next steps:"
    echo "  1. Run 'pipeline.sh --smart-picks' to scrape contacts for new venues"
    echo "  2. Run './discover.sh --taste' again to continue with more queries"
    exit 0
fi

# =============================================================
# DEFAULT MODE: crawl "People also search for" from past gigs
# =============================================================
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
MAX_GIGS=${MAX_GIGS:-0}  # 0 = unlimited; set MAX_GIGS=2 to limit
GIGS_PROCESSED=0

while IFS=$'\t' read -r VENUE_NAME VENUE_LOC; do
    [ -z "$VENUE_NAME" ] && continue

    # Limit check (0 = unlimited)
    if [ "$MAX_GIGS" -gt 0 ] && [ "$GIGS_PROCESSED" -ge "$MAX_GIGS" ]; then
        log "  MAX_GIGS=$MAX_GIGS reached — stopping."
        break
    fi

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

    # Parse location into city/state/address
    import re
    location = card.get('location', '').strip()
    city = ''
    state = ''
    address = location if location else f"{name}, {state}" if state else name  # fallback to venue name for geocoding
    state_match = re.search(r'\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\b', location)
    if state_match:
        state = state_match.group(1)
        # Extract city: text before state, after last comma or start
        before = location[:state_match.start()].rstrip(', ')
        parts = before.split(',')
        city = parts[-1].strip() if parts else ''
        # If city looks like a street number, try the part before it
        if city and city[0].isdigit() and len(parts) > 1:
            city = ''

    params = {
        'action': 'add_venue',
        'name': name,
        'category': our_cat,
        'city': city,
        'state': state,
        'address': address,
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
            vid = result.get('venue_id', '')
            print(f"  ADDED: {name} ({our_cat}, {rating}★, {reviews} reviews)")
            # Save venue_id for website lookup after Python exits
            print(f"  WEBSITE_LOOKUP:{vid}:{name}:{state}")
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

    # Look up websites for newly added venues via Chrome Google search
    echo "$ADDED" | grep "WEBSITE_LOOKUP:" | while IFS=':' read -r _ VID VNAME VSTATE; do
        log "  [WEBSITE] Looking up: $VNAME"
        SEARCH_Q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$VNAME''' + ' ' + '''$VSTATE'''))")
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_Q}\""
        sleep 3
        FOUND_WEB=
        FOUND_WEB=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_cite.js"'")' 2>/dev/null)
        if [ -n "$FOUND_WEB" ] && [ "$FOUND_WEB" != "missing value" ] && [ "$FOUND_WEB" != "" ]; then
            log "    Website: $FOUND_WEB"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=website&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$FOUND_WEB'''))")" > /dev/null
        else
            log "    No website found"
        fi
        sleep 1
    done

    # Mark this gig as discovered so we skip it next time
    echo "$VENUE_NAME" >> "$DISCOVERED_FILE"
    GIGS_PROCESSED=$((GIGS_PROCESSED + 1))

    rand_delay 3 5
done <<< "$GIG_LIST"

# --- Cleanup: remove discovered entries already in the app ---
log "Cleaning up discovered_gigs.txt..."
CLEANUP_VENUES=$(curl -sL "${APPS_SCRIPT_URL}?action=venues")
CLEANUP_GIGS=$(curl -sL "${APPS_SCRIPT_URL}?action=get_gigs")
echo "$CLEANUP_VENUES" > /tmp/discover_cleanup_venues.json
echo "$CLEANUP_GIGS" > /tmp/discover_cleanup_gigs.json
python3 - "$DISCOVERED_FILE" << 'CLEANEOF'
import json, sys

disc_file = sys.argv[1]

# Load venue names from app
names = set()
try:
    with open('/tmp/discover_cleanup_venues.json') as f:
        for v in json.load(f).get('venues', []):
            names.add(v.get('name', '').lower().strip())
except: pass

# Load past gig names from app
gig_names = set()
try:
    with open('/tmp/discover_cleanup_gigs.json') as f:
        for g in json.load(f).get('gigs', []):
            gig_names.add(g.get('venue_name', '').lower().strip())
except: pass

# Keep only entries not yet in venues AND not a past gig (past gigs are seeds, not todos)
kept = []
removed = 0
with open(disc_file, 'r') as f:
    for line in f:
        name = line.strip()
        if not name:
            continue
        low = name.lower()
        if low not in gig_names and low in names:
            print(f"  CLEANUP: removed '{name}'")
            removed += 1
        else:
            kept.append(name)

with open(disc_file, 'w') as f:
    for name in kept:
        f.write(name + '\n')

print(f"  Cleanup done: removed {removed}, kept {len(kept)}")
CLEANEOF

if [ "$TOTAL_ADDED" -gt 0 ]; then
    log "Calculating distances for new venues..."
    curl -sL "${APPS_SCRIPT_URL}?action=calc_distances" -o /tmp/discover_distances.json
    DIST_COUNT=$(python3 -c "import json; print(json.load(open('/tmp/discover_distances.json')).get('calculated',0))" 2>/dev/null)
    log "  Distances calculated: $DIST_COUNT"
fi

log ""
log "=== Discovery Complete — Total new venues: $TOTAL_ADDED ==="
echo ""
echo "Next steps:"
echo "  1. Run pipeline on new venues to find contacts + emails"
echo "  2. Check Smart Picks in the app for ranked results"
