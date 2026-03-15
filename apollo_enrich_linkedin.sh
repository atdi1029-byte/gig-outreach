#!/bin/bash
# =============================================================
# Apollo LinkedIn Enrichment Script
# Takes a JSON file of LinkedIn-discovered people, searches each
# on Apollo by name, checks email icon color, clicks Access email
# if green, verifies with ZeroBounce, pushes to sheet.
#
# Usage: ./apollo_enrich_linkedin.sh "Venue Name" "VENUE_ID" people.json
#   people.json: [{"name":"Katherine Saad","title":"Director of Sales"},...]
#
# Rules:
#   - ONLY click green email icons (#3DCC85) — skip red/grey
#   - 5-6 min random delay between Access email clicks
#   - Navigate back to Apollo home between each person
#   - Navigate to chrome://newtab when done with all people
#
# Requirements:
#   - Chrome open and logged into app.apollo.io
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\" people.json}"
VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\" people.json}"
PEOPLE_FILE="${3:?Usage: $0 \"Venue Name\" \"VENUE_ID\" people.json}"
ZEROBOUNCE_KEY="7a47396026644791a236621ebe3d2584"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"

if [ ! -f "$PEOPLE_FILE" ]; then
    echo "[ERROR] People file not found: $PEOPLE_FILE"
    exit 1
fi

# Random delay function (min, max in seconds)
rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

# Read people from JSON file
PEOPLE_COUNT=$(python3 -c "import json; print(len(json.load(open('$PEOPLE_FILE'))))")
echo "=== Apollo LinkedIn Enrichment ==="
echo "Venue: $VENUE"
echo "Venue ID: $VENUE_ID"
echo "People to enrich: $PEOPLE_COUNT"
echo ""

if [ "$PEOPLE_COUNT" = "0" ]; then
    echo "No people to enrich. Done."
    exit 0
fi

# --- Pre-check: Load existing contacts from sheet ---
echo "--- Pre-check: Loading existing contacts ---"
EXISTING=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VENUE_ID}" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    emails = set()
    for c in d.get('contacts', []):
        if c.get('email'): emails.add(c['email'].lower())
    print('|||'.join(emails))
except:
    print('')
" 2>/dev/null)
echo "  Existing emails: $(echo "$EXISTING" | tr '|||' '\n' | grep -c .)"
echo ""

TOTAL_ENRICHED=0
TOTAL_SKIPPED=0
TOTAL_RED=0
FIRST_CLICK=true

# Activate Chrome
osascript -e 'tell application "Google Chrome" to activate'
rand_delay 1 2

# Loop through each person
for i in $(seq 0 $((PEOPLE_COUNT - 1))); do
    # Get person info
    PERSON=$(python3 -c "
import json
people = json.load(open('$PEOPLE_FILE'))
p = people[$i]
print(p.get('name', ''))
print(p.get('title', ''))
")
    PNAME=$(echo "$PERSON" | head -1)
    PTITLE=$(echo "$PERSON" | tail -1)

    if [ -z "$PNAME" ]; then continue; fi

    echo ""
    echo "=== [$((i+1))/$PEOPLE_COUNT] $PNAME ($PTITLE) ==="

    # --- Step 1: Navigate to Apollo home ---
    osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'
    rand_delay 3 5

    # --- Step 2: Open search (Cmd+K) ---
    osascript -e 'tell application "System Events" to keystroke "k" using command down'
    rand_delay 1 2

    # --- Step 3: Paste person name ---
    echo -n "$PNAME" | pbcopy
    osascript -e 'tell application "System Events" to keystroke "v" using command down'
    rand_delay 4 7

    # --- Step 4: Find person in search results ---
    SEARCH_RESULT=$(osascript << 'SEARCHEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var m = document.querySelector('[data-testid=omni-search-modal]');
if(!m) return 'NO_MODAL';
var text = m.innerText;
if(text.indexOf('People') === -1) return 'NO_PEOPLE_SECTION';
// Return first 2000 chars of modal content for analysis
return text.substring(0, 2000);
})()"
end tell
SEARCHEOF
    )

    if [ "$SEARCH_RESULT" = "NO_MODAL" ] || [ "$SEARCH_RESULT" = "NO_PEOPLE_SECTION" ]; then
        echo "  [SKIP] Could not find in Apollo search"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    # Click the first People result (top match)
    # We use the person's name to find the right result
    CLICK_RESULT=$(osascript << CLICKEOF
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var m = document.querySelector('[data-testid=omni-search-modal]');
if(!m) return 'no modal';
// Find all clickable items in the People section
var items = m.querySelectorAll('[role=option], [role=listitem], a, div[class]');
var best = null, bestLen = 99999;
for(var i = 0; i < items.length; i++){
    var t = items[i].textContent;
    if(t.indexOf('$PNAME') > -1 && t.length < bestLen && t.length > 0 && items[i].childElementCount > 0){
        bestLen = t.length;
        best = items[i];
    }
}
if(best){ best.click(); return 'CLICKED'; }
return 'NOT_FOUND';
})()"
end tell
CLICKEOF
    )

    if [ "$CLICK_RESULT" != "CLICKED" ]; then
        echo "  [SKIP] Could not click person in search results"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    echo "  Opened profile..."
    rand_delay 3 5

    # --- Step 5: Check email icon color ---
    EMAIL_STATUS=$(osascript << 'COLOREOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
// Check for already-visible email first
var allText = document.body.innerText;
var emailMatch = allText.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}/);

// Look for Access email button and check its icon color
var btns = document.querySelectorAll('button');
var hasAccessEmail = false;
for(var i = 0; i < btns.length; i++){
    if(btns[i].textContent.trim() === 'Access email'){
        hasAccessEmail = true;
        // Check SVG icon color near this button
        var parent = btns[i].closest('div') || btns[i].parentElement;
        // Look up a few levels for the SVG
        var searchEl = btns[i];
        for(var p = 0; p < 5; p++){
            searchEl = searchEl.parentElement;
            if(!searchEl) break;
            var paths = searchEl.querySelectorAll('svg path, svg circle');
            for(var s = 0; s < paths.length; s++){
                var fill = paths[s].getAttribute('fill') || '';
                if(fill === '#3DCC85') return 'GREEN';
                if(fill === '#D93636') return 'RED';
                if(fill === '#474747') return 'GREY';
            }
        }
        break;
    }
}

// If email already visible (no Access email button needed)
if(!hasAccessEmail && emailMatch) return 'ALREADY_HAS:' + emailMatch[0];

// If we found the button but couldn't determine color, check more broadly
if(hasAccessEmail){
    var allPaths = document.querySelectorAll('svg path, svg circle');
    for(var i = 0; i < allPaths.length; i++){
        var fill = allPaths[i].getAttribute('fill') || '';
        if(fill === '#3DCC85') return 'GREEN';
        if(fill === '#D93636') return 'RED';
    }
    return 'UNKNOWN_COLOR';
}

if(emailMatch) return 'ALREADY_HAS:' + emailMatch[0];
return 'NO_ACCESS_BUTTON';
})()"
end tell
COLOREOF
    )

    echo "  Email status: $EMAIL_STATUS"

    # Handle already-visible email
    if echo "$EMAIL_STATUS" | grep -q "ALREADY_HAS:"; then
        EMAIL=$(echo "$EMAIL_STATUS" | cut -d: -f2)
        echo "  Email already visible: $EMAIL"
        # Skip to verification
    elif [ "$EMAIL_STATUS" = "RED" ]; then
        echo "  [SKIP] Red icon — bad email, not worth a credit"
        TOTAL_RED=$((TOTAL_RED + 1))
        continue
    elif [ "$EMAIL_STATUS" = "GREY" ]; then
        echo "  [SKIP] Grey icon — unverified, not worth a credit"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    elif [ "$EMAIL_STATUS" = "GREEN" ]; then
        # Wait 5-6 min before clicking (skip delay for the very first click)
        if [ "$FIRST_CLICK" = true ]; then
            FIRST_CLICK=false
            echo "  First click — no delay"
        else
            echo "  Waiting 5-6 min before clicking Access email..."
            rand_delay 300 360
        fi

        # Click Access email
        osascript << 'ACCESSEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var btns = document.querySelectorAll('button');
for(var i = 0; i < btns.length; i++){
    if(btns[i].textContent.trim() === 'Access email'){
        btns[i].click();
        return 'CLICKED';
    }
}
return 'not found';
})()"
end tell
ACCESSEOF
        sleep 3

        # Read revealed email
        EMAIL=$(osascript << 'READEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var allText = document.body.innerText;
var emailMatch = allText.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}/);
if(emailMatch) return emailMatch[0];
return '';
})()"
end tell
READEOF
        )
    else
        echo "  [SKIP] No Access email button or unknown state"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    if [ -z "$EMAIL" ]; then
        echo "  [WARN] Could not read email after clicking"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    echo "  Email found: $EMAIL"

    # Check if email already in sheet
    EMAIL_LOWER=$(echo "$EMAIL" | tr '[:upper:]' '[:lower:]')
    if echo "$EXISTING" | tr '|||' '\n' | grep -qi "^${EMAIL_LOWER}$" 2>/dev/null; then
        echo "  [SKIP] Email already in sheet"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    # --- Step 6: ZeroBounce verify ---
    echo "  Verifying with ZeroBounce..."
    ZB_RESULT=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$EMAIL")
    ZB_STATUS=$(echo "$ZB_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
    echo "  ZeroBounce: $ZB_STATUS"

    if [ "$ZB_STATUS" != "valid" ]; then
        echo "  [SKIP] Email not valid ($ZB_STATUS)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    # --- Step 7: Push to sheet ---
    ENCODED=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'update_contact_email',
    'venue_id': '''$VENUE_ID''',
    'name': '''$PNAME''',
    'email': '''$EMAIL''',
    'verified': 'valid',
    'source': 'apollo+linkedin'
}))
")
    curl -sL "${APPS_SCRIPT_URL}?${ENCODED}" > /dev/null
    echo "  Pushed to sheet: $PNAME <$EMAIL>"
    TOTAL_ENRICHED=$((TOTAL_ENRICHED + 1))

    # Add to existing emails to prevent re-processing
    EXISTING="${EXISTING}|||${EMAIL_LOWER}"
done

# --- Done: Navigate Chrome to new tab page ---
echo ""
echo "--- Cleanup: Navigating to new tab ---"
osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "chrome://newtab"'

echo ""
echo "=== Apollo LinkedIn Enrichment Complete ==="
echo "Enriched (valid email found): $TOTAL_ENRICHED"
echo "Skipped (already known/no email/invalid): $TOTAL_SKIPPED"
echo "Red icons (bad email, saved credits): $TOTAL_RED"
