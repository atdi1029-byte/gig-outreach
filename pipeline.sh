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
#   3. Apollo API — search company, find people, enrich emails
#   4. LinkedIn + Apollo API — find missed people, enrich via API
#
# Requirements:
#   - Chrome open and logged into LinkedIn (for Step 4)
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
#   - Python 3 with requests
#   - Apollo API key (set APOLLO_API_KEY env var or edit below)
# =============================================================

APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="7a47396026644791a236621ebe3d2584"
APOLLO_API_KEY="${APOLLO_API_KEY:-E1s0N8cJDtWP-ZOxzcNhAQ}"
APOLLO_API_BASE="https://api.apollo.io/api/v1"
APOLLO_CREDITS_USED=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/pipeline.log"
JUNK_DOMAINS="wix.com|wordpress|sentry.io|cloudflare|example.com|squarespace|shopify|mailchimp|googleapis|google.com|gstatic|facebook|instagram|twitter|hubspot|sendgrid|zendesk"

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
        # Skip anyone already in the sheet regardless of email status
        if c.get('name'):
            names.add(c['name'].lower().strip())
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

    if [ "$zb_status" = "valid" ] || [ "$zb_status" = "invalid" ] || [ "$zb_status" = "catch-all" ]; then
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
    'verified': '$zb_status'
}))")
        curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
        if [ "$zb_status" = "valid" ]; then
            log "  ✓ Added: ${name:-$email} <$email>"
        else
            log "  ⚠ Added (${zb_status}): ${name:-$email} <$email>"
        fi
        echo "1" >> /tmp/pipeline_contacts_count
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
    homepage = requests.get(url, headers=headers, timeout=15)
    all_text = homepage.text
except Exception as e:
    print(json.dumps({'emails':[],'facebook':'','instagram':''}))
    sys.exit(0)

# Crawl all internal links from the homepage instead of guessing paths
from urllib.parse import urljoin, urlparse
base_domain = urlparse(url).netloc.replace('www.','')
visited = {url.rstrip('/')}
internal_links = set()
for href in re.findall(r'href=["\\x27]([^"\\x27]+)["\\x27]', all_text):
    full = urljoin(url, href).split('#')[0].split('?')[0].rstrip('/')
    domain = urlparse(full).netloc.replace('www.','')
    if domain == base_domain and full not in visited:
        internal_links.add(full)

for link in sorted(internal_links):
    try:
        r = requests.get(link, headers=headers, timeout=10)
        if r.status_code == 200:
            all_text += r.text
            visited.add(link)
    except: pass
    if len(visited) > 25: break  # cap at 25 pages to avoid huge sites

emails = set()
for e in re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', all_text):
    el = e.lower()
    if any(j in el for j in junk): continue
    if any(el.startswith(p) for p in ['info@','reservations@','noreply@','no-reply@','support@','admin@','webmaster@','sales@','contact@','hello@','office@']): continue
    if len(e) > 60: continue
    emails.add(e)

fb, ig, contact_form = '', '', ''
for f in re.findall(r'https?://(?:www\.)?facebook\.com/[a-zA-Z0-9._/-]+', all_text):
    fp = f.split('?')[0].rstrip('/')
    slug = fp.split('facebook.com/')[-1]
    if slug in ('tr','pixel','plugins','sharer','share','login','dialog'): continue
    if 'sharer' in f or 'share' in f: continue
    if len(slug) < 3: continue
    fb = fp; break
for i in re.findall(r'https?://(?:www\.)?instagram\.com/[a-zA-Z0-9._/-]+', all_text):
    if 'share' not in i: ig = i.split('?')[0]; break

# Detect contact form pages — look for "contact" in URL paths
contact_keywords = ['contact', 'get-in-touch', 'reach-us', 'inquiry', 'enquiry']
for page_url in sorted(visited | internal_links):
    path = urlparse(page_url).path.lower()
    if any(kw in path for kw in contact_keywords):
        contact_form = page_url
        break

print(json.dumps({'emails': sorted(emails), 'facebook': fb, 'instagram': ig, 'contact_form': contact_form}))
PYEOF
    )

    local email_count fb ig contact_form
    email_count=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())['emails']))")
    fb=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['facebook'])")
    ig=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['instagram'])")
    contact_form=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('contact_form',''))")

    log "  Emails: $email_count | FB: ${fb:-none} | IG: ${ig:-none} | Contact Form: ${contact_form:-none}"

    # Update social links
    if [ -n "$fb" ] && [ "$fb" != "None" ] && [ "$fb" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$fb'''))")" > /dev/null
    fi
    if [ -n "$ig" ] && [ "$ig" != "None" ] && [ "$ig" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$ig'''))")" > /dev/null
    fi
    if [ -n "$contact_form" ] && [ "$contact_form" != "None" ] && [ "$contact_form" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=contact_form&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$contact_form'''))")" > /dev/null
        log "  ✓ Contact form URL saved"
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

    # Scrape emails by opening pages in Chrome (JS renders, emails visible)
    cat > /tmp/social_scrape_emails.js << 'JSEOF'
(function(){
var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk'];
var text = document.body.innerText || '';
var matches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
var emails = [];
for(var i=0;i<matches.length;i++){
    var e = matches[i].toLowerCase();
    var isJunk = false;
    for(var j=0;j<junk.length;j++){ if(e.indexOf(junk[j])>-1){isJunk=true;break;} }
    if(!isJunk && e.length<60) emails.push(e);
}
return emails.filter(function(v,i,a){return a.indexOf(v)===i;}).join('|');
})()
JSEOF

    local SOCIAL_EMAILS=""

    # Facebook — try main page and /about
    if [ -n "$fb" ] && [ "$fb" != "None" ] && [ ${#fb} -gt 5 ]; then
        for fb_path in "" "/about" "/directory_contact_info"; do
            local fb_url="${fb%/}${fb_path}"
            log "  Opening FB: $fb_url"
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${fb_url}\""
            sleep 5
            local fb_emails
            fb_emails=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/social_scrape_emails.js")')
            if [ -n "$fb_emails" ]; then
                log "  FB emails found: $fb_emails"
                SOCIAL_EMAILS="${SOCIAL_EMAILS}|${fb_emails}"
            fi
        done
    fi

    # Instagram
    if [ -n "$ig" ] && [ "$ig" != "None" ] && [ ${#ig} -gt 5 ]; then
        log "  Opening IG: $ig"
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${ig}\""
        sleep 5
        local ig_emails
        ig_emails=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/social_scrape_emails.js")')
        if [ -n "$ig_emails" ]; then
            log "  IG emails found: $ig_emails"
            SOCIAL_EMAILS="${SOCIAL_EMAILS}|${ig_emails}"
        fi
    fi

    # Dedupe and verify+push each email
    echo "$SOCIAL_EMAILS" | tr '|' '\n' | sort -u | while read -r email; do
        [ -n "$email" ] && verify_and_push "$email" "$venue_id" "" "" "social"
    done
}

# =================================================================
# STEP 3: APOLLO API (search company → find people → enrich emails)
# =================================================================
step3_apollo_api() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 3: Apollo API =========="

    if [ -z "$APOLLO_API_KEY" ]; then
        log "  [ERROR] APOLLO_API_KEY not set. Skipping."
        return
    fi

    # A. Search for company by name, fallback to domain
    log "  Searching Apollo for company: $venue"

    # Get website domain for fallback search
    local WEBSITE_DOMAIN=""
    WEBSITE_DOMAIN=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | python3 -c "
import json,sys,re
d = json.loads(sys.stdin.read())
w = d.get('venue',{}).get('website','')
m = re.search(r'https?://(?:www\.)?([^/]+)', w)
print(m.group(1) if m else '')
" 2>/dev/null)

    local COMPANY_JSON
    COMPANY_JSON=$(python3 << PYEOF
import requests, json, sys, re

headers = {"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"}
venue_name = "$venue"
website_domain = "$WEBSITE_DOMAIN"

def normalize(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())

def name_matches(result_name, target_name):
    """Check if Apollo result is a reasonable match for our venue"""
    rn = normalize(result_name)
    tn = normalize(target_name)
    # Exact or substring match
    if tn in rn or rn in tn:
        return True
    # Check word overlap (at least 60% of target words present)
    tw = set(re.sub(r'[^a-z\s]', '', target_name.lower()).split())
    tw -= {'the', 'a', 'an', 'and', 'of', 'at', 'in'}
    rw = set(re.sub(r'[^a-z\s]', '', result_name.lower()).split())
    if tw and len(tw & rw) / len(tw) >= 0.6:
        return True
    return False

best = None

# Try name search first
resp = requests.post("${APOLLO_API_BASE}/mixed_companies/search",
    headers=headers,
    json={"q_organization_name": venue_name, "per_page": 5})
data = resp.json()
accounts = data.get("accounts", []) + data.get("organizations", [])

# Only accept if the name actually matches
for a in accounts:
    if name_matches(a.get("name", ""), venue_name):
        best = a
        break

# Always try domain search too (may find better match)
if website_domain:
    resp2 = requests.post("${APOLLO_API_BASE}/mixed_companies/search",
        headers=headers,
        json={"q_organization_domains_list": [website_domain], "per_page": 5})
    data2 = resp2.json()
    domain_accounts = data2.get("accounts", []) + data2.get("organizations", [])
    if domain_accounts and not best:
        best = domain_accounts[0]

if not best:
    print(json.dumps({"found": False}))
else:
    print(json.dumps({
        "found": True,
        "org_id": best.get("organization_id") or best.get("id", ""),
        "domain": best.get("primary_domain") or best.get("domain", ""),
        "name": best.get("name", "")
    }))
PYEOF
    )

    local FOUND DOMAIN ORG_NAME
    FOUND=$(echo "$COMPANY_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['found'])")
    if [ "$FOUND" = "False" ]; then
        log "  [WARN] No company found in Apollo for '$venue' (tried name + domain)"
        # Still set domain from website for Step 4 LinkedIn enrichment
        APOLLO_DOMAIN="$WEBSITE_DOMAIN"
        log "  Using website domain for enrichment: $APOLLO_DOMAIN"
        return
    fi
    DOMAIN=$(echo "$COMPANY_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['domain'])")
    ORG_NAME=$(echo "$COMPANY_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
    log "  Found: $ORG_NAME (domain: $DOMAIN)"

    # Store domain for Step 4 LinkedIn enrichment
    APOLLO_DOMAIN="$DOMAIN"

    # B. Search for people at this company
    log "  Searching for people at $DOMAIN..."
    local PEOPLE_JSON
    PEOPLE_JSON=$(python3 << PYEOF
import requests, json
all_people = []
page = 1
while True:
    resp = requests.post("${APOLLO_API_BASE}/mixed_people/api_search",
        headers={"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"},
        json={"q_organization_domains_list": ["$DOMAIN"], "per_page": 100, "page": page})
    data = resp.json()
    people = data.get("people", [])
    if not people:
        break
    for p in people:
        all_people.append({
            "id": p.get("id", ""),
            "first_name": p.get("first_name", ""),
            "last_name_hint": p.get("last_name_obfuscated", ""),
            "title": p.get("title", ""),
            "has_email": p.get("has_email", False)
        })
    if len(people) < 100:
        break
    page += 1
    if page > 5:
        break
print(json.dumps(all_people))
PYEOF
    )

    local PEOPLE_COUNT
    PEOPLE_COUNT=$(echo "$PEOPLE_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
    if [ -z "$PEOPLE_COUNT" ]; then PEOPLE_COUNT=0; fi
    log "  Found $PEOPLE_COUNT people total"
    if [ "$PEOPLE_COUNT" = "0" ]; then
        log "  No people in Apollo for this company."
        return
    fi

    # C. Filter: only skip people whose full name is already known
    echo "$PEOPLE_JSON" > /tmp/pipeline_people.json
    local TO_ENRICH
    TO_ENRICH=$(KNAMES="$KNOWN_NAMES" KEMAILS="$KNOWN_EMAILS" python3 << 'PYEOF'
import json, os

with open('/tmp/pipeline_people.json') as f:
    people = json.load(f)
known_raw = os.environ.get('KNAMES', '')
known = set(n.strip().lower() for n in known_raw.split('|||') if n.strip())

to_enrich = []
for p in people:
    first = p.get('first_name', '').strip()
    if not first:
        continue
    to_enrich.append(p)

for p in to_enrich:
    print(f"{p['id']}:::{p['first_name']}:::{p['title']}")
PYEOF
    )

    if [ -z "$TO_ENRICH" ]; then
        log "  No new people to enrich."
        return
    fi

    local ENRICH_COUNT
    ENRICH_COUNT=$(echo "$TO_ENRICH" | wc -l | tr -d ' ')
    log "  $ENRICH_COUNT people to enrich (1 credit each)"

    # D. Bulk enrich in batches of 10
    local BATCH_IDS="" BATCH_COUNT=0 TOTAL_ENRICHED=0 TOTAL_EMAILS=0

    while IFS= read -r line; do
        local PID PFIRST PTITLE
        PID=$(echo "$line" | awk -F':::' '{print $1}')
        PFIRST=$(echo "$line" | awk -F':::' '{print $2}')
        PTITLE=$(echo "$line" | awk -F':::' '{print $3}')

        if [ -z "$PID" ]; then continue; fi

        if [ -n "$BATCH_IDS" ]; then
            BATCH_IDS="${BATCH_IDS},${PID}"
        else
            BATCH_IDS="$PID"
        fi
        BATCH_COUNT=$((BATCH_COUNT + 1))

        # Fire batch when we hit 10 or end of list
        if [ "$BATCH_COUNT" -ge 10 ]; then
            _enrich_batch "$BATCH_IDS" "$venue_id"
            BATCH_IDS=""
            BATCH_COUNT=0
            sleep 1
        fi
    done <<< "$TO_ENRICH"

    # Flush remaining batch
    if [ -n "$BATCH_IDS" ]; then
        _enrich_batch "$BATCH_IDS" "$venue_id"
    fi

    log "  Apollo API done: $APOLLO_CREDITS_USED credits used this run"
}

# Helper: enrich a batch of Apollo person IDs
_enrich_batch() {
    local ids_csv="$1" venue_id="$2"

    local RESULT
    RESULT=$(python3 << PYEOF
import requests, json

ids = "$ids_csv".split(",")
details = [{"id": pid.strip()} for pid in ids if pid.strip()]
resp = requests.post("${APOLLO_API_BASE}/people/bulk_match",
    headers={"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"},
    json={"details": details, "reveal_personal_emails": False})
data = resp.json()
matches = data.get("matches", [])
results = []
for m in matches:
    if not m:
        continue
    name = m.get("name", "") or (m.get("first_name","") + " " + m.get("last_name",""))
    email = m.get("email", "")
    title = m.get("title", "")
    status = m.get("email_status", "")
    results.append(f"{name}:::{title}:::{email}:::{status}")
credits = data.get("credits_consumed", len(details))
print(f"CREDITS:{credits}")
for r in results:
    print(r)
PYEOF
    )

    # Parse credits
    local CREDITS
    CREDITS=$(echo "$RESULT" | head -1 | sed 's/CREDITS://')
    APOLLO_CREDITS_USED=$((APOLLO_CREDITS_USED + CREDITS))

    # Process each result
    echo "$RESULT" | tail -n +2 | while IFS= read -r line; do
        local ENAME ETITLE EEMAIL ESTATUS
        ENAME=$(echo "$line" | awk -F':::' '{print $1}')
        ETITLE=$(echo "$line" | awk -F':::' '{print $2}')
        EEMAIL=$(echo "$line" | awk -F':::' '{print $3}')
        ESTATUS=$(echo "$line" | awk -F':::' '{print $4}')

        if [ -z "$ENAME" ]; then continue; fi

        # Mark name as known
        KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$ENAME" | tr '[:upper:]' '[:lower:]')"

        if [ -n "$EEMAIL" ] && [ "$ESTATUS" != "unavailable" ]; then
            log "  >>> $ENAME ($ETITLE): $EEMAIL [$ESTATUS]"
            verify_and_push "$EEMAIL" "$venue_id" "$ENAME" "$ETITLE" "apollo"
        else
            log "  --- $ENAME ($ETITLE): no email available"
            # Add contact without email
            local encoded
            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$ENAME''',
    'title': '''$ETITLE''',
    'source': 'apollo',
    'verified': 'pending'
}))")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
        fi
    done
}

# =================================================================
# STEP 4: LINKEDIN + APOLLO API ENRICHMENT
# =================================================================
step4_linkedin() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 4: LinkedIn + Apollo API =========="

    if [ -z "$APOLLO_API_KEY" ]; then
        log "  [SKIP] No APOLLO_API_KEY — cannot enrich"
        return
    fi

    local MAX_PAGES=3
    local ENCODED_VENUE
    ENCODED_VENUE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$venue'))")

    # Use the domain found in Step 3, or fall back to website domain
    local DOMAIN="$APOLLO_DOMAIN"
    if [ -z "$DOMAIN" ]; then
        # Fall back to website domain from the sheet
        DOMAIN=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | python3 -c "
import json,sys,re
d = json.loads(sys.stdin.read())
w = d.get('venue',{}).get('website','')
m = re.search(r'https?://(?:www\.)?([^/]+)', w)
print(m.group(1) if m else '')
" 2>/dev/null)
    fi

    if [ -z "$DOMAIN" ]; then
        log "  [WARN] No domain found for '$venue' — LinkedIn names won't be enrichable"
    else
        log "  Using domain: $DOMAIN"
    fi

    osascript -e 'tell application "Google Chrome" to activate'
    rand_delay 1 2

    local ALL_LINKEDIN_PEOPLE=""

    for PAGE in $(seq 1 $MAX_PAGES); do
        local URL="https://www.linkedin.com/search/results/people/?keywords=${ENCODED_VENUE}&page=${PAGE}"
        log "  LinkedIn page $PAGE..."
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${URL}\""
        rand_delay 5 8

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

        # Extract people with names and titles
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
                var title = \"\";
                for (var j = 0; j < lines.length; j++) {
                    if (lines[j].match(/degree connection/)) {
                        if (j+1 < lines.length) title = lines[j+1];
                        break;
                    }
                }
                var isCurrent = !title.toLowerCase().includes(\"past:\") && !title.toLowerCase().startsWith(\"former\");
                results.push(JSON.stringify({name:name, title:title, current:isCurrent}));
            });
            return \"[\" + results.join(\",\") + \"]\";
        })()
    "
end tell' 2>/dev/null)

        if [ -z "$PAGE_JSON" ] || [ "$PAGE_JSON" = "[]" ]; then
            log "  No data extracted."
            break
        fi

        # Filter to venue employees
        local PEOPLE_ON_PAGE
        PEOPLE_ON_PAGE=$(python3 << PYEOF
import json

data = json.loads('''$PAGE_JSON''')
venue = '''$venue'''.lower()

skip = {'the','at','in','of','and','for','a','an','by','on','to','&'}
venue_words = [w for w in venue.split() if w.lower() not in skip and len(w) > 2]

known_names_raw = '''$KNOWN_NAMES'''
known_names = set(n.strip() for n in known_names_raw.split('|||') if n.strip())

for p in data:
    if not p.get('current', True): continue
    title_lower = p['title'].lower()
    if not any(w in title_lower for w in venue_words): continue
    name = p['name'].strip()
    name_lower = name.lower()
    if name_lower in known_names or name_lower == '?': continue
    # Split name into first/last
    parts = name.split()
    if len(parts) < 2: continue
    first = parts[0]
    last = parts[-1]
    # Skip if last name looks truncated (e.g. "Sloan E.")
    if len(last) <= 2: continue
    print(f"{first}:::{last}:::{name}:::{p['title']}")
PYEOF
        )

        if [ -z "$PEOPLE_ON_PAGE" ]; then
            log "  No new venue employees on this page."
        else
            ALL_LINKEDIN_PEOPLE="${ALL_LINKEDIN_PEOPLE}
${PEOPLE_ON_PAGE}"
            echo "$PEOPLE_ON_PAGE" | while read -r line; do
                local PNAME
                PNAME=$(echo "$line" | awk -F':::' '{print $3}')
                log "  Found: $PNAME"
            done
        fi

        if [ "$PAGE" -lt "$MAX_PAGES" ]; then
            rand_delay 3 5
        fi
    done

    # Remove leading blank line
    ALL_LINKEDIN_PEOPLE=$(echo "$ALL_LINKEDIN_PEOPLE" | sed '/^$/d')

    if [ -z "$ALL_LINKEDIN_PEOPLE" ]; then
        log "  No new people found on LinkedIn."
        return
    fi

    local TOTAL_FOUND
    TOTAL_FOUND=$(echo "$ALL_LINKEDIN_PEOPLE" | wc -l | tr -d ' ')
    log ""
    log "  LinkedIn found $TOTAL_FOUND new people. Enriching via Apollo API..."

    if [ -z "$DOMAIN" ]; then
        log "  [SKIP] No domain — adding contacts without emails"
        echo "$ALL_LINKEDIN_PEOPLE" | while IFS= read -r line; do
            local PFULL PTITLE
            PFULL=$(echo "$line" | awk -F':::' '{print $3}')
            PTITLE=$(echo "$line" | awk -F':::' '{print $4}')
            local encoded
            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$PFULL''',
    'title': '''$PTITLE''',
    'source': 'linkedin',
    'verified': 'pending'
}))")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$PFULL" | tr '[:upper:]' '[:lower:]')"
        done
        return
    fi

    # Enrich via Apollo API — bulk match by name + domain
    local ENRICH_RESULT
    ENRICH_RESULT=$(echo "$ALL_LINKEDIN_PEOPLE" | python3 << PYEOF
import requests, json, sys

lines = [l.strip() for l in sys.stdin.readlines() if l.strip()]
details = []
name_map = {}
for line in lines:
    parts = line.split(':::')
    if len(parts) < 4: continue
    first, last, full, title = parts[0], parts[1], parts[2], parts[3]
    details.append({"first_name": first, "last_name": last, "domain": "$DOMAIN"})
    name_map[f"{first.lower()}_{last.lower()}"] = {"full": full, "title": title}

if not details:
    sys.exit(0)

# Batch in groups of 10
for i in range(0, len(details), 10):
    batch = details[i:i+10]
    resp = requests.post("${APOLLO_API_BASE}/people/bulk_match",
        headers={"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"},
        json={"details": batch, "reveal_personal_emails": False})
    data = resp.json()
    credits = data.get("credits_consumed", len(batch))
    print(f"CREDITS:{credits}")
    for m in data.get("matches", []):
        if not m:
            # No match found
            idx = data["matches"].index(m)
            if idx < len(batch):
                key = f"{batch[idx]['first_name'].lower()}_{batch[idx]['last_name'].lower()}"
                info = name_map.get(key, {})
                print(f"NOMATCH:::{info.get('full','')}:::{info.get('title','')}")
            continue
        name = m.get("name", "") or (m.get("first_name","") + " " + m.get("last_name",""))
        email = m.get("email", "")
        title = m.get("title", "")
        status = m.get("email_status", "")
        print(f"MATCH:::{name}:::{title}:::{email}:::{status}")
PYEOF
    )

    # Process results
    echo "$ENRICH_RESULT" | while IFS= read -r line; do
        if [[ "$line" == CREDITS:* ]]; then
            local C="${line#CREDITS:}"
            APOLLO_CREDITS_USED=$((APOLLO_CREDITS_USED + C))
            continue
        fi

        if [[ "$line" == MATCH:::* ]]; then
            local REST="${line#MATCH:::}"
            local ENAME ETITLE EEMAIL ESTATUS
            ENAME=$(echo "$REST" | awk -F':::' '{print $1}')
            ETITLE=$(echo "$REST" | awk -F':::' '{print $2}')
            EEMAIL=$(echo "$REST" | awk -F':::' '{print $3}')
            ESTATUS=$(echo "$REST" | awk -F':::' '{print $4}')

            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$ENAME" | tr '[:upper:]' '[:lower:]')"

            if [ -n "$EEMAIL" ] && [ "$ESTATUS" != "unavailable" ]; then
                log "  >>> $ENAME ($ETITLE): $EEMAIL [$ESTATUS]"
                verify_and_push "$EEMAIL" "$venue_id" "$ENAME" "$ETITLE" "linkedin+apollo"
            else
                log "  --- $ENAME ($ETITLE): no email"
                local encoded
                encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$ENAME''',
    'title': '''$ETITLE''',
    'source': 'linkedin',
    'verified': 'pending'
}))")
                curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            fi
        fi

        if [[ "$line" == NOMATCH:::* ]]; then
            local REST="${line#NOMATCH:::}"
            local NNAME NTITLE
            NNAME=$(echo "$REST" | awk -F':::' '{print $1}')
            NTITLE=$(echo "$REST" | awk -F':::' '{print $2}')
            log "  --- $NNAME ($NTITLE): not in Apollo"
            local encoded
            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '$venue_id',
    'name': '''$NNAME''',
    'title': '''$NTITLE''',
    'source': 'linkedin',
    'verified': 'pending'
}))")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$NNAME" | tr '[:upper:]' '[:lower:]')"
        fi
    done

    log "  LinkedIn + Apollo API done. Credits used: $APOLLO_CREDITS_USED"
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

    # Track how many new contacts we find (file-based to survive subshells)
    rm -f /tmp/pipeline_contacts_count

    # Load existing contacts once
    load_existing "$venue_id"
    log "  Known emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
    log "  Known names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"

    step1_website "$venue" "$venue_id" "$website"
    step2_social "$venue" "$venue_id"
    step3_apollo_api "$venue" "$venue_id"
    # LinkedIn quota resets in April — skip until then
    if [ "$(date +%m)" -ge 4 ] 2>/dev/null; then
        step4_linkedin "$venue" "$venue_id"
    else
        log ""
        log "========== STEP 4: LinkedIn (SKIPPED — quota reset in April) =========="
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=notes&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('LinkedIn pending'))")" > /dev/null
        log "  Marked as LinkedIn pending"
    fi

    # Only mark as contacted if we actually found new contacts
    local PIPELINE_CONTACTS_FOUND=0
    if [ -f /tmp/pipeline_contacts_count ]; then
        PIPELINE_CONTACTS_FOUND=$(wc -l < /tmp/pipeline_contacts_count | tr -d ' ')
    fi
    if [ "$PIPELINE_CONTACTS_FOUND" -gt 0 ]; then
        log "  Found $PIPELINE_CONTACTS_FOUND new contact(s) — marking as contacted"
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=status&value=contacted" > /dev/null
    else
        log "  No new contacts found — leaving venue as untouched"
    fi

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

if [ "$1" = "--smart-picks" ]; then
    # Pull Smart Picks from API in rank order (highest score first)
    log "SMART PICKS MODE: Fetching ranked venues..."
    SP_JSON=$(curl -sL "${APPS_SCRIPT_URL}?action=get_recommendations")
    SP_COUNT=$(echo "$SP_JSON" | python3 -c "
import sys, json
recs = json.load(sys.stdin).get('recommendations', [])
# Skip venues already contacted or already pipeline'd
filtered = [r for r in recs if r.get('status','') != 'contacted']
print(len(filtered))
" 2>/dev/null)
    log "SMART PICKS: $SP_COUNT venues to process"

    echo "$SP_JSON" | python3 -c "
import sys, json
recs = json.load(sys.stdin).get('recommendations', [])
filtered = [r for r in recs if r.get('status','') != 'contacted']
for i, r in enumerate(filtered):
    print(f\"{i}|{r['name']}|{r['venue_id']}|{r.get('recommendation_score',0)}\")
" 2>/dev/null | while IFS='|' read -r IDX NAME VID SCORE; do
        log ""
        log "########## SMART PICK #$((IDX+1)) (score $SCORE): $NAME ($VID) ##########"
        # Fetch website from venue detail
        WEB=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" | python3 -c "
import sys, json
v = json.load(sys.stdin).get('venue', {})
print(v.get('website', ''))
" 2>/dev/null)
        run_venue "$NAME" "$VID" "$WEB"
        if [ "$IDX" -lt "$((SP_COUNT - 1))" ]; then sleep 30; fi
    done
    log "=== SMART PICKS COMPLETE ==="

elif [ "$1" = "--linkedin-retry" ]; then
    # Re-run Step 4 (LinkedIn) on venues marked "LinkedIn pending"
    log "LINKEDIN RETRY MODE: Finding venues with LinkedIn pending..."
    LR_JSON=$(curl -sL "${APPS_SCRIPT_URL}?action=dashboard" 2>/dev/null)
    echo "$LR_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for v in data.get('venues', []):
    notes = v.get('notes', '')
    if 'LinkedIn pending' in notes:
        print(f\"{v['venue_id']}|||{v['name']}|||{v.get('website','')}\")
" 2>/dev/null | while IFS='|||' read -r VID NAME WEB; do
        log ""
        log "########## LINKEDIN RETRY: $NAME ($VID) ##########"
        load_existing "$VID"
        # Get domain from website
        APOLLO_DOMAIN=$(echo "$WEB" | python3 -c "import sys,re; m=re.search(r'https?://(?:www\.)?([^/]+)',sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null)
        step4_linkedin "$NAME" "$VID"
        # Clear the pending note
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=notes&value=" > /dev/null
        log "  Cleared LinkedIn pending note"
        sleep 10
    done
    log "=== LINKEDIN RETRY COMPLETE ==="

elif [ "$1" = "--batch" ]; then
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
    VENUE="${1:?Usage: $0 \"Venue Name\"}"

    # If venue_id not provided, look it up by name from the dashboard
    if [ -z "${2:-}" ]; then
        log "Looking up venue ID for: $VENUE"
        VENUE_LOOKUP=$(curl -sL "${APPS_SCRIPT_URL}?action=dashboard" 2>/dev/null | python3 -c "
import json, sys
raw = sys.stdin.read()
data = json.loads(raw)
target = '''$VENUE'''.lower().strip()
for v in data.get('venues', []):
    venue = v.get('venue', v)
    name = venue.get('name', '').lower().strip()
    if name == target:
        vid = venue.get('venue_id', '')
        web = venue.get('website', '')
        print(f'{vid}|||{web}')
        sys.exit(0)
# Fuzzy: check if all words match
target_words = set(w for w in target.split() if len(w) > 2 and w not in {'the','at','in','of','and','for'})
for v in data.get('venues', []):
    venue = v.get('venue', v)
    name = venue.get('name', '').lower().strip()
    if all(w in name for w in target_words):
        vid = venue.get('venue_id', '')
        web = venue.get('website', '')
        print(f'{vid}|||{web}')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)

        if [ "$VENUE_LOOKUP" = "NOT_FOUND" ] || [ -z "$VENUE_LOOKUP" ]; then
            echo "[ERROR] Could not find venue '$VENUE' in the sheet."
            exit 1
        fi

        VENUE_ID=$(echo "$VENUE_LOOKUP" | awk -F'|||' '{print $1}')
        WEBSITE=$(echo "$VENUE_LOOKUP" | awk -F'|||' '{print $2}')
        log "  Found: $VENUE_ID (website: ${WEBSITE:-none})"
    else
        VENUE_ID="$2"
        WEBSITE="${3:-}"
    fi

    run_venue "$VENUE" "$VENUE_ID" "$WEBSITE"
fi
