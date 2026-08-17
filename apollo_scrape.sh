#!/bin/bash
# =============================================================
# Apollo.io Employee Email Scraper
# Full automation: search venue → people tab → access emails → save → ZeroBounce verify → push to sheet
#
# Usage: ./apollo_scrape.sh "Venue Name" "VENUE_ID"
#
# Requirements:
#   - Chrome open and logged into app.apollo.io
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
#
# Rate limits: 5-6 min random between "Access email" clicks
# Free tier: ~100 email reveals per month
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
ZB_GUARD="$SCRIPT_DIR/zerobounce_guard.py"
ZB_RUN_ID="${ZB_RUN_ID:-apollo-scrape-$(date +%Y%m%dT%H%M%S)-$$}"
export ZB_RUN_ID
VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\"}"
VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\"}"
OUTPUT_FILE="/Users/alexbarnett/Documents/Code/Claude/Email/apollo_emails.csv"
ZEROBOUNCE_KEY="${ZEROBOUNCE_KEY:-}"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"

# Random delay function (min, max in seconds)
rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

echo "=== Apollo Email Scraper ==="
echo "Venue: $VENUE"
echo "Venue ID: $VENUE_ID"
echo "Output: $OUTPUT_FILE"
echo ""

# --- PRE-CHECK: Fetch existing contacts + venue location from sheet ---
echo "--- Pre-check: Loading existing contacts + venue location ---"
PRECHECK_DATA=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VENUE_ID}" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    emails = set()
    names = set()
    for c in d.get('contacts', []):
        if c.get('email'): emails.add(c['email'].lower())
        if c.get('name'): names.add(c['name'].lower().strip())
    venue = d.get('venue', {})
    state = venue.get('state', '').strip()
    city = venue.get('city', '').strip()
    print('EMAILS:' + '|||'.join(emails))
    print('NAMES:' + '|||'.join(names))
    print('STATE:' + state)
    print('CITY:' + city)
except:
    print('EMAILS:')
    print('NAMES:')
    print('STATE:')
    print('CITY:')
" 2>/dev/null)

KNOWN_EMAILS=$(echo "$PRECHECK_DATA" | grep '^EMAILS:' | cut -d: -f2)
KNOWN_NAMES=$(echo "$PRECHECK_DATA" | grep '^NAMES:' | cut -d: -f2)
VENUE_STATE=$(echo "$PRECHECK_DATA" | grep '^STATE:' | cut -d: -f2)
VENUE_CITY=$(echo "$PRECHECK_DATA" | grep '^CITY:' | cut -d: -f2)
echo "  Existing emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
echo "  Existing names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"
echo "  Venue location: $VENUE_CITY, $VENUE_STATE"

# Build allowed-states list (venue state + neighboring states within ~50mi)
# Target region: MD, VA, DC, WV, PA, DE
ALLOWED_STATES=$(python3 -c "
state = '$VENUE_STATE'.upper().strip()
# Nearby-state clusters — any state in a cluster allows all others
clusters = [
    {'DC', 'MD', 'VA'},
    {'PA', 'DE', 'MD'},
    {'WV', 'VA', 'MD'},
]
allowed = {state} if state else set()
for c in clusters:
    if state in c:
        allowed |= c
# Print as lowercase pipe-separated for easy grep matching
print('|'.join(s.lower() for s in sorted(allowed)) if allowed else '')
" 2>/dev/null)

if [ -n "$ALLOWED_STATES" ]; then
    echo "  Chain filter: only contacts in states: $(echo "$ALLOWED_STATES" | tr '|' ', ')"
else
    echo "  Chain filter: OFF (no venue state found — will accept all locations)"
fi
echo ""

# --- STEP 1: Open Apollo ---
echo "--- Step 1: Opening Apollo ---"
osascript -e 'tell application "Google Chrome" to activate'
osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'
rand_delay 4 7

# --- STEP 2: Search for venue ---
echo "--- Step 2: Searching for $VENUE ---"
osascript -e 'tell application "System Events" to keystroke "k" using command down'
rand_delay 1 2
echo -n "$VENUE" | pbcopy
osascript -e 'tell application "System Events" to keystroke "v" using command down'
rand_delay 4 7

# --- STEP 3: Click company in search results ---
echo "--- Step 3: Clicking company ---"
CLICK_RESULT=$(osascript << CLICKEOF
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var m=document.querySelector('[data-testid=omni-search-modal]');
if(!m) return 'no modal';
var text=m.innerText;
var compIdx=text.indexOf('Companies');
if(compIdx===-1) return 'no companies section';
var divs=m.querySelectorAll('div');
var best=null, bestLen=99999;
for(var i=0;i<divs.length;i++){
    var t=divs[i].textContent;
    if(t.includes('$VENUE') && t.length<bestLen && t.length>0 && divs[i].childElementCount>0){
        bestLen=t.length;
        best=divs[i];
    }
}
if(best){best.click(); return 'CLICKED';}
return 'not found';
})()"
end tell
CLICKEOF
)
echo "  Result: $CLICK_RESULT"
if [ "$CLICK_RESULT" != "CLICKED" ]; then
    echo "  [ERROR] Could not find company. Exiting."
    exit 1
fi
rand_delay 2 5

# --- STEP 4: Click People tab ---
echo "--- Step 4: Clicking People tab ---"
PEOPLE_RESULT=$(osascript << 'EOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var labels = document.querySelectorAll('label');
for(var i=0;i<labels.length;i++){
    if(labels[i].textContent.trim()==='People'){
        labels[i].click();
        return 'CLICKED';
    }
}
return 'not found';
})()"
end tell
EOF
)
echo "  Result: $PEOPLE_RESULT"
if [ "$PEOPLE_RESULT" != "CLICKED" ]; then
    echo "  [ERROR] Could not find People tab. Exiting."
    exit 1
fi
rand_delay 2 4

# --- STEP 5 & 6: Loop through pages, click green Access email ---
echo "--- Step 5-6: Accessing emails ---"

# Add CSV header if file doesn't exist
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "name,title,email,venue,venue_id" > "$OUTPUT_FILE"
fi

TOTAL_CLICKED=0
TOTAL_SKIPPED=0
TOTAL_FILTERED=0
PAGE=1
while true; do
    echo ""
    echo "--- Page $PAGE ---"
    rand_delay 2 4

    # Read all rows: get name, title, location, color
    ROWS=$(osascript << 'EOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var rows = document.querySelectorAll('[role=row]');
var results = [];
for (var i = 0; i < rows.length; i++) {
    var t = rows[i].textContent;
    if (t.indexOf('Access email') === -1) continue;
    var links = rows[i].querySelectorAll('a');
    var name = '', title = '';
    for (var j = 0; j < links.length; j++) {
        var lt = links[j].textContent.trim();
        if (lt.length > 2 && lt.length < 50 && lt.indexOf('@') === -1) {
            if (!name) name = lt;
            else if (!title) title = lt;
        }
    }
    // Read person's location from the row cells
    var loc = '';
    var cells = rows[i].querySelectorAll('td, [role=cell], [role=gridcell]');
    for (var c = 0; c < cells.length; c++) {
        var ct = cells[c].textContent.trim();
        // Location cells typically have comma-separated city/state/country
        if (ct.match(/,\\s*(United States|US|USA|Canada|UK|Australia|India|Saudi|UAE|Germany|France|Italy|Spain|Brazil|Japan|China|Singapore|Mexico)/i) ||
            ct.match(/,\\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\\b/i)) {
            loc = ct;
            break;
        }
    }
    // Fallback: check all spans for location-like text
    if (!loc) {
        var spans = rows[i].querySelectorAll('span');
        for (var s2 = 0; s2 < spans.length; s2++) {
            var st = spans[s2].textContent.trim();
            if (st.match(/,\\s*(United States|US|USA|AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\\b/i) && st.length < 80) {
                loc = st;
                break;
            }
        }
    }
    var paths = rows[i].querySelectorAll('svg path, svg circle');
    var color = 'unknown';
    for (var s = 0; s < paths.length; s++) {
        var fill = paths[s].getAttribute('fill') || '';
        if (fill === '#3DCC85') { color = 'GREEN'; break; }
        if (fill === '#D93636') { color = 'RED'; break; }
        if (fill === '#474747') { color = 'GREY'; break; }
    }
    if (color === 'GREEN') results.push(name + ':::' + title + ':::' + loc);
}
return results.join('|||');
})()"
end tell
EOF
    )

    if [ -z "$ROWS" ]; then
        echo "  No green Access email buttons on this page."
    else
        # Split by ||| and process each green contact
        IFS='|||' read -ra GREEN_ENTRIES <<< "$ROWS"
        for ENTRY in "${GREEN_ENTRIES[@]}"; do
            if [ -z "$ENTRY" ]; then continue; fi
            GNAME=$(echo "$ENTRY" | cut -d':' -f1-2 | sed 's/::$//')
            # Parse :::‐delimited fields
            GNAME=$(echo "$ENTRY" | python3 -c "import sys; parts=sys.stdin.read().strip().split(':::'); print(parts[0] if parts else '')")
            GTITLE=$(echo "$ENTRY" | python3 -c "import sys; parts=sys.stdin.read().strip().split(':::'); print(parts[1] if len(parts)>1 else '')")
            GLOC=$(echo "$ENTRY" | python3 -c "import sys; parts=sys.stdin.read().strip().split(':::'); print(parts[2] if len(parts)>2 else '')")
            if [ -z "$GNAME" ]; then continue; fi

            # LOCATION FILTER: skip contacts not in allowed states (for chain venues)
            if [ -n "$ALLOWED_STATES" ] && [ -n "$GLOC" ]; then
                LOC_MATCH=$(python3 -c "
loc = '''$GLOC'''.lower()
allowed = '''$ALLOWED_STATES'''.split('|')
# Check if any allowed state abbreviation or name appears in location
state_names = {
    'dc': 'district of columbia', 'md': 'maryland', 'va': 'virginia',
    'pa': 'pennsylvania', 'de': 'delaware', 'wv': 'west virginia',
    'ny': 'new york', 'nj': 'new jersey', 'nc': 'north carolina',
    'ct': 'connecticut', 'oh': 'ohio'
}
for st in allowed:
    # Match state abbrev (word boundary) or full name
    import re
    if re.search(r'\b' + re.escape(st) + r'\b', loc):
        print('yes'); exit()
    full = state_names.get(st, '')
    if full and full in loc:
        print('yes'); exit()
print('no')
" 2>/dev/null)
                if [ "$LOC_MATCH" = "no" ]; then
                    echo "  [FILTERED] $GNAME — location '$GLOC' not in allowed states"
                    TOTAL_FILTERED=$((TOTAL_FILTERED + 1))
                    continue
                fi
            fi

            # DEDUP CHECK: skip if name already in sheet
            GNAME_LOWER=$(echo "$GNAME" | tr '[:upper:]' '[:lower:]' | xargs)
            if echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -qi "^${GNAME_LOWER}$" 2>/dev/null; then
                echo "  [SKIP] $GNAME — already in sheet"
                TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                continue
            fi

            echo "  Clicking Access email for: $GNAME ($GTITLE)"

            # Click the Access email button for this person
            osascript << CLICKEOF
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var rows = document.querySelectorAll('[role=row]');
for (var i = 0; i < rows.length; i++) {
    if (rows[i].textContent.indexOf('$GNAME') === -1) continue;
    if (rows[i].textContent.indexOf('Access email') === -1) continue;
    var btns = rows[i].querySelectorAll('button');
    for (var j = 0; j < btns.length; j++) {
        if (btns[j].textContent.trim() === 'Access email') {
            btns[j].click();
            return 'CLICKED';
        }
    }
}
return 'not found';
})()"
end tell
CLICKEOF

            # Wait a moment for email to reveal
            sleep 3

            # Read the revealed email
            EMAIL_DATA=$(osascript << 'READEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var rows = document.querySelectorAll('[role=row]');
for (var i = 0; i < rows.length; i++) {
    var t = rows[i].textContent;
    var emailMatch = t.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/);
    if (emailMatch) {
        var links = rows[i].querySelectorAll('a');
        var name = '', title = '';
        for (var j = 0; j < links.length; j++) {
            var lt = links[j].textContent.trim();
            if (lt.length > 2 && lt.length < 50 && lt.indexOf('@') === -1) {
                if (!name) name = lt;
                else if (!title) title = lt;
            }
        }
        return name + '|||' + title + '|||' + emailMatch[0];
    }
}
return '';
})()"
end tell
READEOF
            )

            if [ -n "$EMAIL_DATA" ]; then
                IFS='|||' read -r ENAME ETITLE EEMAIL <<< "$EMAIL_DATA"
                echo "  >>> $ENAME | $ETITLE | $EEMAIL"
                echo "$ENAME,$ETITLE,$EEMAIL,$VENUE,$VENUE_ID" >> "$OUTPUT_FILE"
                TOTAL_CLICKED=$((TOTAL_CLICKED + 1))
                # Add to known names so we don't re-click on later pages
                KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$ENAME" | tr '[:upper:]' '[:lower:]')"
            else
                echo "  [WARN] Could not read revealed email"
            fi

            # Wait 5-6 minutes before next click (anti-detection)
            echo "  Waiting 5-6 min before next access..."
            rand_delay 300 360
        done
    fi

    # --- STEP 6: Check for next page ---
    HAS_NEXT=$(osascript << 'EOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var btns = document.querySelectorAll('button');
for (var i = 0; i < btns.length; i++) {
    var label = btns[i].getAttribute('aria-label') || '';
    if (label.toLowerCase().indexOf('next') > -1 && !btns[i].disabled) return 'yes';
}
return 'no';
})()"
end tell
EOF
    )

    if [ "$HAS_NEXT" = "yes" ]; then
        echo "  Next page available — clicking..."
        osascript << 'EOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var btns = document.querySelectorAll('button');
for (var i = 0; i < btns.length; i++) {
    var label = btns[i].getAttribute('aria-label') || '';
    if (label.toLowerCase().indexOf('next') > -1) { btns[i].click(); return 'CLICKED'; }
}
return 'none';
})()"
end tell
EOF
        PAGE=$((PAGE + 1))
        rand_delay 3 6
    else
        echo "  No more pages."
        break
    fi
done

echo ""
echo "=== Email collection complete ==="
echo "Emails collected: $TOTAL_CLICKED | Skipped (already in sheet): $TOTAL_SKIPPED | Filtered (wrong location): $TOTAL_FILTERED"
echo ""

# --- STEP 7: ZeroBounce bulk verify ---
echo "--- Step 7: ZeroBounce verification ---"
VALID_FILE="/Users/alexbarnett/Documents/Code/Claude/Email/apollo_valid_emails.csv"
echo "name,title,email,venue,venue_id,status" > "$VALID_FILE"

while IFS=, read -r NAME TITLE EMAIL VNAME VID; do
    if [ "$NAME" = "name" ]; then continue; fi
    if [ -z "$EMAIL" ]; then continue; fi

    # Skip if email already in sheet
    EMAIL_LOWER=$(echo "$EMAIL" | tr '[:upper:]' '[:lower:]')
    if echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -qi "^${EMAIL_LOWER}$" 2>/dev/null; then
        echo "  [SKIP] $EMAIL — already verified in sheet"
        continue
    fi

    ZB_JSON=$(python3 "$ZB_GUARD" verify "$EMAIL" --source "apollo_scrape" --run-id "$ZB_RUN_ID" 2>/dev/null || true)
    STATUS=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','deferred'))" 2>/dev/null || echo deferred)
    ZB_REASON=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('reason','unknown'))" 2>/dev/null || echo guard_error)
    ZB_CHARGED=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('charged',False))" 2>/dev/null || echo False)

    echo "  [ZB SAFE] $EMAIL → $STATUS ($ZB_REASON; charged=$ZB_CHARGED)"
    echo "$NAME,$TITLE,$EMAIL,$VNAME,$VID,$STATUS" >> "$VALID_FILE"

    if [ "$ZB_CHARGED" = "True" ] || [ "$ZB_CHARGED" = "true" ]; then sleep 1; fi
done < "$OUTPUT_FILE"

echo ""
echo "=== Verification complete ==="

# --- STEP 8: Push valid emails to Google Sheet ---
echo "--- Step 8: Pushing valid emails to sheet ---"
VALID_COUNT=0
while IFS=, read -r NAME TITLE EMAIL VNAME VID STATUS; do
    if [ "$NAME" = "name" ]; then continue; fi
    if [ "$STATUS" != "valid" ]; then continue; fi

    ENCODED=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '''$VID''',
    'name': '''$NAME''',
    'title': '''$TITLE''',
    'email': '''$EMAIL''',
    'verified': 'valid',
    'source': 'apollo'
}))
")

    curl -sL "${APPS_SCRIPT_URL}?${ENCODED}" > /dev/null
    echo "  Added: $NAME ($EMAIL)"
    VALID_COUNT=$((VALID_COUNT + 1))
    sleep 1
done < "$VALID_FILE"

echo ""
echo "=== DONE ==="
echo "Valid emails added to sheet: $VALID_COUNT"
echo "Total collected: $TOTAL_CLICKED"
echo "Skipped (already known): $TOTAL_SKIPPED"
echo "Filtered (wrong location): $TOTAL_FILTERED"
