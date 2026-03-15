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

VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\"}"
VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\"}"
OUTPUT_FILE="/Users/alexbarnett/Documents/Code/Claude/Email/apollo_emails.csv"
ZEROBOUNCE_KEY="7a47396026644791a236621ebe3d2584"
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

# --- PRE-CHECK: Fetch existing contacts from sheet ---
echo "--- Pre-check: Loading existing contacts ---"
EXISTING_EMAILS=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VENUE_ID}" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    emails = set()
    names = set()
    for c in d.get('contacts', []):
        if c.get('email'): emails.add(c['email'].lower())
        if c.get('name'): names.add(c['name'].lower().strip())
    print('EMAILS:' + '|||'.join(emails))
    print('NAMES:' + '|||'.join(names))
except:
    print('EMAILS:')
    print('NAMES:')
" 2>/dev/null)

KNOWN_EMAILS=$(echo "$EXISTING_EMAILS" | grep '^EMAILS:' | cut -d: -f2)
KNOWN_NAMES=$(echo "$EXISTING_EMAILS" | grep '^NAMES:' | cut -d: -f2)
echo "  Existing emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
echo "  Existing names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"
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
PAGE=1
while true; do
    echo ""
    echo "--- Page $PAGE ---"
    rand_delay 2 4

    # Read all rows: get name, title, color
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
    var paths = rows[i].querySelectorAll('svg path, svg circle');
    var color = 'unknown';
    for (var s = 0; s < paths.length; s++) {
        var fill = paths[s].getAttribute('fill') || '';
        if (fill === '#3DCC85') { color = 'GREEN'; break; }
        if (fill === '#D93636') { color = 'RED'; break; }
        if (fill === '#474747') { color = 'GREY'; break; }
    }
    if (color === 'GREEN') results.push(name + ':::' + title);
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
            GNAME=$(echo "$ENTRY" | cut -d':::' -f1)
            GTITLE=$(echo "$ENTRY" | cut -d':::' -f3)
            if [ -z "$GNAME" ]; then continue; fi

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
echo "Emails collected: $TOTAL_CLICKED | Skipped (already in sheet): $TOTAL_SKIPPED"
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

    RESULT=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$EMAIL")
    STATUS=$(echo "$RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)

    echo "  $EMAIL → $STATUS"
    echo "$NAME,$TITLE,$EMAIL,$VNAME,$VID,$STATUS" >> "$VALID_FILE"

    sleep 1
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
