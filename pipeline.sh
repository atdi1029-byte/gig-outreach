#!/bin/bash
# =============================================================
# Gig Outreach Master Pipeline — FULLY SELF-CONTAINED
# One script does everything. No external dependencies.
#
# Usage:
#   ./pipeline.sh "Venue Name" "VENUE_ID" "https://website.com"
#   ./pipeline.sh --batch venues.json
#
# Steps (all inline):
#   1. Website scrape — emails + social links
#   2. Social media — Facebook/Instagram emails
#   3. Apollo scrape — search company, click green Access email
#   4. LinkedIn — find missed people, enrich via Apollo
#
# Requirements:
#   - Chrome open and logged into Apollo + LinkedIn
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
#   - Python 3 with requests
# =============================================================

APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="7a47396026644791a236621ebe3d2584"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/pipeline.log"
JUNK_DOMAINS="wix.com|wordpress|sentry.io|cloudflare|example.com|squarespace|shopify|mailchimp|googleapis|google.com|gstatic|facebook|instagram|twitter|hubspot|sendgrid|zendesk"
MAX_APOLLO_CLICKS="${MAX_APOLLO_CLICKS:-999}"  # Set to 1 for testing: MAX_APOLLO_CLICKS=1 ./pipeline.sh ...
APOLLO_CLICKS_USED=0

rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

log() {
    echo "$1"
    echo "$(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}

# Fetch existing contacts for a venue, sets KNOWN_EMAILS and KNOWN_NAMES
load_existing() {
    local venue_id="$1"
    local raw
    raw=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null)
    KNOWN_EMAILS=$(echo "$raw" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    emails = set()
    for c in d.get('contacts', []):
        if c.get('email'): emails.add(c['email'].lower())
    print('|||'.join(emails))
except: print('')
" 2>/dev/null)
    KNOWN_NAMES=$(echo "$raw" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    names = set()
    for c in d.get('contacts', []):
        if c.get('name'): names.add(c['name'].lower().strip())
    print('|||'.join(names))
except: print('')
" 2>/dev/null)
}

email_known() {
    local email_lower
    email_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -qi "^${email_lower}$" 2>/dev/null
}

name_known() {
    local name_lower
    name_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)
    echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -qi "^${name_lower}$" 2>/dev/null
}

verify_and_push() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5"
    if [ -z "$email" ]; then return; fi

    if email_known "$email"; then
        log "  [SKIP] $email — already in sheet"
        return
    fi

    local zb_status
    zb_status=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$email" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
    log "  $email → $zb_status"

    if [ "$zb_status" = "valid" ]; then
        local encoded
        encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$name''',
    'title': '''$title''',
    'email': '$email',
    'source': '$source',
    'verified': 'valid'
}))")
        curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
        log "  ✓ Added: ${name:-$email} <$email>"
        KNOWN_EMAILS="${KNOWN_EMAILS}|||$(echo "$email" | tr '[:upper:]' '[:lower:]')"
        if [ -n "$name" ]; then
            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$name" | tr '[:upper:]' '[:lower:]')"
        fi
    fi
    sleep 1
}

# =================================================================
# STEP 1: WEBSITE SCRAPE
# =================================================================
step1_website() {
    local venue="$1" venue_id="$2" website="$3"
    log ""
    log "========== STEP 1: Website Scrape =========="

    if [ -z "$website" ]; then
        log "  [SKIP] No website URL"
        return
    fi

    log "  URL: $website"

    SCRAPE_RESULT=$(python3 << PYEOF
import requests, re, json, sys

url = '''$website'''
if not url.startswith('http'): url = 'https://' + url

headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
junk = '''$JUNK_DOMAINS'''.split('|')

all_text = ''
try:
    all_text = requests.get(url, headers=headers, timeout=15).text
except Exception as e:
    print(json.dumps({'emails':[],'facebook':'','instagram':''}))
    sys.exit(0)

for path in ['/contact', '/contact-us', '/about', '/about-us']:
    try:
        r = requests.get(url.rstrip('/') + path, headers=headers, timeout=10)
        if r.status_code == 200: all_text += r.text
    except: pass

emails = set()
for e in re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', all_text):
    el = e.lower()
    if any(j in el for j in junk): continue
    if any(el.startswith(p) for p in ['info@','reservations@','noreply@','no-reply@','support@','admin@','webmaster@','sales@','contact@','hello@','office@']): continue
    if len(e) > 60: continue
    emails.add(e)

fb, ig = '', ''
for f in re.findall(r'https?://(?:www\.)?facebook\.com/[a-zA-Z0-9._/-]+', all_text):
    if 'sharer' not in f and 'share' not in f: fb = f.split('?')[0]; break
for i in re.findall(r'https?://(?:www\.)?instagram\.com/[a-zA-Z0-9._/-]+', all_text):
    if 'share' not in i: ig = i.split('?')[0]; break

print(json.dumps({'emails': sorted(emails), 'facebook': fb, 'instagram': ig}))
PYEOF
    )

    local email_count fb ig
    email_count=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())['emails']))")
    fb=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['facebook'])")
    ig=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['instagram'])")

    log "  Emails: $email_count | FB: ${fb:-none} | IG: ${ig:-none}"

    # Update social links
    if [ -n "$fb" ] && [ "$fb" != "None" ] && [ "$fb" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$fb'''))")" > /dev/null
    fi
    if [ -n "$ig" ] && [ "$ig" != "None" ] && [ "$ig" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$ig'''))")" > /dev/null
    fi

    # Verify + push emails
    echo "$SCRAPE_RESULT" | python3 -c "
import json, sys
for e in json.loads(sys.stdin.read())['emails']: print(e)
" | while read -r email; do
        verify_and_push "$email" "$venue_id" "" "" "website"
    done
}

# =================================================================
# STEP 2: SOCIAL MEDIA SCRAPE
# =================================================================
step2_social() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 2: Social Media Scrape =========="

    local venue_data fb ig
    venue_data=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}")
    fb=$(echo "$venue_data" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('venue',{}).get('facebook',''))" 2>/dev/null)
    ig=$(echo "$venue_data" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('venue',{}).get('instagram',''))" 2>/dev/null)

    log "  FB: ${fb:-none} | IG: ${ig:-none}"

    local SOCIAL_EMAILS
    SOCIAL_EMAILS=$(python3 << PYEOF
import requests, re

headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
junk = '''$JUNK_DOMAINS'''.split('|')
emails = set()

fb = '''$fb'''
if fb and fb != 'None' and len(fb) > 5:
    for path in ['', '/about', '/about_contact_and_basic_info']:
        try:
            r = requests.get(fb.rstrip('/') + path, headers=headers, timeout=10)
            for e in re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', r.text):
                if not any(j in e.lower() for j in junk) and len(e) < 60: emails.add(e)
        except: pass

ig = '''$ig'''
if ig and ig != 'None' and len(ig) > 5:
    try:
        r = requests.get(ig, headers=headers, timeout=10)
        for e in re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', r.text):
            if not any(j in e.lower() for j in junk) and len(e) < 60: emails.add(e)
    except: pass

for e in sorted(emails): print(e)
PYEOF
    )

    echo "$SOCIAL_EMAILS" | while read -r email; do
        [ -n "$email" ] && verify_and_push "$email" "$venue_id" "" "" "social"
    done
}

# =================================================================
# STEP 3: APOLLO SCRAPE (inline — no external script)
# =================================================================
step3_apollo() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 3: Apollo Scrape =========="

    # Navigate to Apollo home
    osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'
    sleep 5

    # Search for venue — single osascript block so terminal can't steal focus
    log "  Searching for: $venue"
    echo -n "$venue" | pbcopy
    osascript << 'SEARCHEOF'
tell application "Google Chrome" to activate
delay 1
tell application "System Events"
    keystroke "k" using command down
end tell
delay 2
tell application "System Events"
    keystroke "v" using command down
end tell
SEARCHEOF
    rand_delay 4 7

    # Click company in search results (ONLY companies, not people)
    local click_result
    click_result=$(osascript << CLICKEOF
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var m=document.querySelector('[data-testid=omni-search-modal]');
if(!m) return 'no modal';
/* Look for links that go to /accounts/ (company pages), not /contacts/ (people) */
var links=m.querySelectorAll('a[href*=\"/accounts/\"]');
var best=null, bestLen=99999;
for(var i=0;i<links.length;i++){
    var t=links[i].textContent;
    if(t.length>0 && t.length<bestLen){
        bestLen=t.length;
        best=links[i];
    }
}
/* Fallback: look for items with company indicators (employee count, industry) */
if(!best){
    var items=m.querySelectorAll('[role=option], [role=listitem]');
    for(var i=0;i<items.length;i++){
        var t=items[i].textContent;
        var hasCompanyHint=(/\\d+\\s*(employee|people)/i.test(t) || /Hospitality|Hotel|Restaurant|Winery|Museum|Country Club/i.test(t));
        if(hasCompanyHint && t.length<bestLen && t.length>0){
            bestLen=t.length;
            best=items[i];
        }
    }
}
if(best){best.click(); return 'CLICKED';}
return 'not found';
})()"
end tell
CLICKEOF
    )
    log "  Company click: $click_result"
    if [ "$click_result" = "CLICKED" ]; then
        rand_delay 2 5

        # Click People tab
        local people_result
        people_result=$(osascript << 'EOF'
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
        log "  People tab: $people_result"
        if [ "$people_result" != "CLICKED" ]; then
            log "  [ERROR] Could not find People tab. Skipping."
            return
        fi
        rand_delay 2 4
    else
        # No company page — fallback to people search
        log "  [FALLBACK] No company page — searching Apollo people directly"
        # Close the search modal
        osascript -e '
tell application "Google Chrome" to activate
delay 0.5
tell application "System Events" to key code 53'
        sleep 1
        # Note in sheet
        local note_encoded
        note_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.urlencode({'action':'update_venue','venue_id':'$venue_id','field':'notes','value':'No Apollo company page - used people search fallback'}))")
        curl -sL "${APPS_SCRIPT_URL}?${note_encoded}" > /dev/null
        # Navigate to Apollo people search with venue name
        local ENCODED_SEARCH
        ENCODED_SEARCH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$venue'))")
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://app.apollo.io/#/people?qKeywords=${ENCODED_SEARCH}\""
        rand_delay 5 8
    fi

    # Loop through pages
    local TOTAL_CLICKED=0 TOTAL_SKIPPED=0 PAGE=1 FIRST_CLICK=true

    while true; do
        log ""
        log "  --- Apollo Page $PAGE ---"
        rand_delay 2 4

        # Read all rows with Access email + colors
        local ROWS
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
            log "  No green Access email buttons on this page."
        else
            IFS='|||' read -ra GREEN_ENTRIES <<< "$ROWS"
            for ENTRY in "${GREEN_ENTRIES[@]}"; do
                if [ -z "$ENTRY" ]; then continue; fi
                GNAME=$(echo "$ENTRY" | awk -F':::' '{print $1}')
                GTITLE=$(echo "$ENTRY" | awk -F':::' '{print $2}')
                if [ -z "$GNAME" ]; then continue; fi

                # Dedup by name
                if name_known "$GNAME"; then
                    log "  [SKIP] $GNAME — already in sheet"
                    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                    continue
                fi

                # Check Apollo click limit
                if [ "$APOLLO_CLICKS_USED" -ge "$MAX_APOLLO_CLICKS" ]; then
                    log "  [LIMIT] Max Apollo clicks ($MAX_APOLLO_CLICKS) reached — skipping rest"
                    break 2
                fi

                # Wait 5-6 min between clicks (skip for first)
                if [ "$FIRST_CLICK" = true ]; then
                    FIRST_CLICK=false
                else
                    log "  Waiting 5-6 min before next click..."
                    rand_delay 300 360
                fi

                log "  Clicking Access email: $GNAME ($GTITLE)"
                osascript << ACLICKEOF
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
ACLICKEOF

                sleep 3

                # Read revealed email
                local EMAIL
                EMAIL=$(osascript << 'READEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var rows = document.querySelectorAll('[role=row]');
for (var i = 0; i < rows.length; i++) {
    var t = rows[i].textContent;
    var m = t.match(/[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}/);
    if (m) {
        var links = rows[i].querySelectorAll('a');
        var name = '';
        for (var j = 0; j < links.length; j++) {
            var lt = links[j].textContent.trim();
            if (lt.length > 2 && lt.length < 50 && lt.indexOf('@') === -1) { name = lt; break; }
        }
        return name + '|||' + m[0];
    }
}
return '';
})()"
end tell
READEOF
                )

                if [ -n "$EMAIL" ]; then
                    local EEMAIL
                    EEMAIL=$(echo "$EMAIL" | awk -F'|||' '{print $NF}')
                    log "  >>> $GNAME: $EEMAIL"
                    verify_and_push "$EEMAIL" "$venue_id" "$GNAME" "$GTITLE" "apollo"
                    TOTAL_CLICKED=$((TOTAL_CLICKED + 1))
                    APOLLO_CLICKS_USED=$((APOLLO_CLICKS_USED + 1))
                else
                    log "  [WARN] Could not read revealed email"
                fi
            done
        fi

        # Check for next page
        local HAS_NEXT
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
            log "  Next page..."
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
            log "  No more pages."
            break
        fi
    done

    log "  Apollo done: $TOTAL_CLICKED emails clicked | $TOTAL_SKIPPED skipped"

    # Navigate back to Apollo home
    osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'
    rand_delay 2 3
}

# =================================================================
# STEP 4: LINKEDIN + APOLLO ENRICHMENT (inline — no external script)
# =================================================================
step4_linkedin() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 4: LinkedIn Cleanup =========="

    local MAX_PAGES=3
    local ENCODED_VENUE
    ENCODED_VENUE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$venue'))")

    osascript -e 'tell application "Google Chrome" to activate'
    rand_delay 1 2

    local ALL_RESULTS="[]"

    for PAGE in $(seq 1 $MAX_PAGES); do
        local URL="https://www.linkedin.com/search/results/people/?keywords=${ENCODED_VENUE}&origin=GLOBAL_SEARCH_HEADER&page=${PAGE}"
        log "  LinkedIn page $PAGE..."
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${URL}\""
        rand_delay 4 7

        # Wait for results
        local COUNT=0
        for RETRY in 1 2 3 4 5; do
            COUNT=$(osascript -e '
tell application "Google Chrome"
    execute active tab of front window javascript "document.querySelectorAll(\"[data-view-name=search-entity-result-universal-template]\").length"
end tell' 2>/dev/null)
            if [ "$COUNT" -gt 0 ] 2>/dev/null; then break; fi
            sleep 2
        done

        if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
            log "  No results on page $PAGE — stopping."
            break
        fi
        log "  Found $COUNT results"

        # Extract people
        local PAGE_JSON
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

        if [ -z "$PAGE_JSON" ] || [ "$PAGE_JSON" = "[]" ]; then
            log "  No data extracted."
            break
        fi

        # Merge results
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

    # Filter to confirmed employees + find new people
    log ""
    log "  Filtering to confirmed employees..."

    local NEW_PEOPLE
    NEW_PEOPLE=$(python3 << PYEOF
import json

data = json.loads('''$ALL_RESULTS''')
venue = '''$venue'''.lower()

skip = {'the','at','in','of','and','for','a','an','by','on','to','&'}
venue_words = [w for w in venue.split() if w.lower() not in skip and len(w) > 2]

known_names_raw = '''$KNOWN_NAMES'''
known_names = set(n.strip() for n in known_names_raw.split('|||') if n.strip())

new_people = []
for p in data:
    if not p.get('current', True): continue
    title_lower = p['title'].lower()
    if not any(w in title_lower for w in venue_words): continue
    name_lower = p['name'].lower().strip()
    if name_lower in known_names or name_lower == '?': continue
    new_people.append(p)
    print(f"  NEW: {p['name']} — {p['title']}")

if not new_people:
    print("  No new people found.")

print(json.dumps(new_people))
PYEOF
    )

    # Extract the JSON (last line of output)
    local NEW_JSON
    NEW_JSON=$(echo "$NEW_PEOPLE" | tail -1)
    local NEW_COUNT
    NEW_COUNT=$(echo "$NEW_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")

    # Print the status lines (everything except last line)
    echo "$NEW_PEOPLE" | head -n -1

    if [ "$NEW_COUNT" = "0" ] || [ -z "$NEW_COUNT" ]; then
        log "  No new people to add from LinkedIn."
    else
        log "  Adding $NEW_COUNT new people to sheet..."

        # Add new people to sheet
        echo "$NEW_JSON" | python3 -c "
import json, sys
for p in json.loads(sys.stdin.read()):
    print(p['name'] + ':::' + p['title'])
" | while read -r line; do
            local PNAME PTITLE
            PNAME=$(echo "$line" | awk -F':::' '{print $1}')
            PTITLE=$(echo "$line" | awk -F':::' '{print $2}')
            local encoded
            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$PNAME''',
    'title': '''$PTITLE''',
    'source': 'linkedin',
    'verified': 'pending'
}))")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            log "  Added: $PNAME"
            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$PNAME" | tr '[:upper:]' '[:lower:]')"
        done

        # Enrich new people via Apollo
        log ""
        log "  --- Apollo enrichment for LinkedIn people ---"

        local ENRICH_FIRST=true

        echo "$NEW_JSON" | python3 -c "
import json, sys
for p in json.loads(sys.stdin.read()):
    print(p['name'] + ':::' + p['title'])
" | while read -r line; do
            local PNAME PTITLE
            PNAME=$(echo "$line" | awk -F':::' '{print $1}')
            PTITLE=$(echo "$line" | awk -F':::' '{print $2}')

            log "  Enriching: $PNAME"

            # Navigate to Apollo home
            osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://app.apollo.io/#/home"'
            sleep 5

            # Search by name — single osascript block so terminal can't steal focus
            echo -n "$PNAME" | pbcopy
            osascript << 'ESEARCHEOF'
tell application "Google Chrome" to activate
delay 1
tell application "System Events"
    keystroke "k" using command down
end tell
delay 2
tell application "System Events"
    keystroke "v" using command down
end tell
ESEARCHEOF
            rand_delay 4 7

            # Click first People result
            local CLICK_R
            CLICK_R=$(osascript << ECLICKEOF
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var m = document.querySelector('[data-testid=omni-search-modal]');
if(!m) return 'NO_MODAL';
var venue = '$venue'.toLowerCase();
var skip = ['the','at','in','of','and','for','a','an','by','on','to'];
var venueWords = venue.split(/\\s+/).filter(function(w){ return skip.indexOf(w) === -1 && w.length > 2; });
var items = m.querySelectorAll('[role=option], [role=listitem], a, div[class]');
var best = null, bestLen = 99999;
for(var i = 0; i < items.length; i++){
    var t = items[i].textContent;
    var tLower = t.toLowerCase();
    /* Must contain the person's name AND at least one venue keyword */
    var hasName = t.indexOf('$PNAME') > -1;
    var hasVenue = venueWords.some(function(w){ return tLower.indexOf(w) > -1; });
    if(hasName && hasVenue && t.length < bestLen && t.length > 0 && items[i].childElementCount > 0){
        bestLen = t.length;
        best = items[i];
    }
}
if(best){ best.click(); return 'CLICKED'; }
return 'NOT_FOUND';
})()"
end tell
ECLICKEOF
            )

            if [ "$CLICK_R" != "CLICKED" ]; then
                log "    [SKIP] Not found on Apollo"
                continue
            fi
            rand_delay 3 5

            # Check email color
            local EMAIL_STATUS
            EMAIL_STATUS=$(osascript << 'COLOREOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var allText = document.body.innerText;
var emailMatch = allText.match(/[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}/);
var btns = document.querySelectorAll('button');
var hasAccess = false;
for(var i=0;i<btns.length;i++){
    if(btns[i].textContent.trim()==='Access email'){ hasAccess=true; break; }
}
if(!hasAccess && emailMatch) return 'ALREADY_HAS:' + emailMatch[0];
if(hasAccess){
    var allPaths = document.querySelectorAll('svg path, svg circle');
    for(var i=0;i<allPaths.length;i++){
        var fill = allPaths[i].getAttribute('fill') || '';
        if(fill==='#3DCC85') return 'GREEN';
        if(fill==='#D93636') return 'RED';
    }
    return 'UNKNOWN';
}
if(emailMatch) return 'ALREADY_HAS:' + emailMatch[0];
return 'NO_BUTTON';
})()"
end tell
COLOREOF
            )

            log "    Email status: $EMAIL_STATUS"

            if echo "$EMAIL_STATUS" | grep -q "ALREADY_HAS:"; then
                local FOUND_EMAIL
                FOUND_EMAIL=$(echo "$EMAIL_STATUS" | cut -d: -f2)
                log "    Email visible: $FOUND_EMAIL"
                # Update contact with email
                local upd_encoded
                upd_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'update_contact_email',
    'venue_id': '$venue_id',
    'name': '''$PNAME''',
    'email': '$FOUND_EMAIL',
    'verified': 'pending',
    'source': 'apollo+linkedin'
}))")
                curl -sL "${APPS_SCRIPT_URL}?${upd_encoded}" > /dev/null
            elif [ "$EMAIL_STATUS" = "GREEN" ]; then
                # Check Apollo click limit
                if [ "$APOLLO_CLICKS_USED" -ge "$MAX_APOLLO_CLICKS" ]; then
                    log "    [LIMIT] Max Apollo clicks ($MAX_APOLLO_CLICKS) reached — skipping"
                    continue
                fi

                # Delay between clicks
                if [ "$ENRICH_FIRST" = true ]; then
                    ENRICH_FIRST=false
                else
                    log "    Waiting 5-6 min..."
                    rand_delay 300 360
                fi

                # Click Access email
                osascript << 'EACCESSEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var btns = document.querySelectorAll('button');
for(var i=0;i<btns.length;i++){
    if(btns[i].textContent.trim()==='Access email'){ btns[i].click(); return 'CLICKED'; }
}
return 'not found';
})()"
end tell
EACCESSEOF
                sleep 3

                local EEMAIL
                EEMAIL=$(osascript << 'EREADEOF'
tell application "Google Chrome"
    execute active tab of front window javascript "
(function(){
var t = document.body.innerText;
var m = t.match(/[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}/);
return m ? m[0] : '';
})()"
end tell
EREADEOF
                )

                if [ -n "$EEMAIL" ]; then
                    log "    Got: $EEMAIL"
                    # Verify and update contact
                    local zb_s
                    zb_s=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$EEMAIL" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
                    log "    ZeroBounce: $zb_s"
                    local upd_encoded2
                    upd_encoded2=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'update_contact_email',
    'venue_id': '$venue_id',
    'name': '''$PNAME''',
    'email': '$EEMAIL',
    'verified': '$zb_s',
    'source': 'apollo+linkedin'
}))")
                    curl -sL "${APPS_SCRIPT_URL}?${upd_encoded2}" > /dev/null
                    APOLLO_CLICKS_USED=$((APOLLO_CLICKS_USED + 1))
                fi
            elif [ "$EMAIL_STATUS" = "RED" ]; then
                log "    [SKIP] Red icon — bad email"
            else
                log "    [SKIP] No email available"
            fi
        done
    fi

    # Done — navigate to new tab
    osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "chrome://newtab"'
    log "  LinkedIn + enrichment done."
}

# =================================================================
# MAIN RUNNER
# =================================================================
run_venue() {
    local venue="$1" venue_id="$2" website="$3"
    local start_time
    start_time=$(date +%s)

    log ""
    log "============================================================"
    log " PIPELINE: $venue ($venue_id)"
    log " Website: $website"
    log " Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    # Load existing contacts once
    load_existing "$venue_id"
    log "  Known emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
    log "  Known names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"

    step1_website "$venue" "$venue_id" "$website"
    step2_social "$venue" "$venue_id"
    step3_apollo "$venue" "$venue_id"
    step4_linkedin "$venue" "$venue_id"

    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$(( (end_time - start_time) / 60 ))

    log ""
    log "============================================================"
    log " DONE: $venue | ${elapsed} min | $(date '+%H:%M:%S')"
    log "============================================================"
}

# =================================================================
# ENTRY POINT
# =================================================================
echo "" >> "$LOG_FILE"
log "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "$1" = "--batch" ]; then
    BATCH_FILE="${2:?Usage: $0 --batch venues.json}"
    if [ ! -f "$BATCH_FILE" ]; then echo "[ERROR] File not found: $BATCH_FILE"; exit 1; fi
    TOTAL=$(python3 -c "import json; print(len(json.load(open('$BATCH_FILE'))))")
    log "BATCH MODE: $TOTAL venues"

    for i in $(seq 0 $((TOTAL - 1))); do
        INFO=$(python3 -c "
import json
v = json.load(open('$BATCH_FILE'))[$i]
print(v.get('name',''))
print(v.get('venue_id',''))
print(v.get('website',''))
")
        NAME=$(echo "$INFO" | head -1)
        VID=$(echo "$INFO" | head -2 | tail -1)
        WEB=$(echo "$INFO" | tail -1)
        log ""
        log "########## VENUE [$((i+1))/$TOTAL]: $NAME ##########"
        run_venue "$NAME" "$VID" "$WEB"
        if [ "$i" -lt "$((TOTAL - 1))" ]; then sleep 30; fi
    done
    log "=== BATCH COMPLETE ==="
else
    VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\" \"https://website.com\"}"
    VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\" \"https://website.com\"}"
    WEBSITE="${3:-}"
    run_venue "$VENUE" "$VENUE_ID" "$WEBSITE"
fi
