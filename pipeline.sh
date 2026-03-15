#!/bin/bash
# =============================================================
# Gig Outreach Master Pipeline
# Runs the full 4-step outreach pipeline for a venue.
#
# Usage:
#   Single venue:  ./pipeline.sh "Venue Name" "VENUE_ID" "https://venue-website.com"
#   Batch mode:    ./pipeline.sh --batch venues.json
#
# Steps:
#   1. Website scrape — hit venue URL + /contact, grab emails + social links
#   2. Social media — check Instagram/Facebook for emails
#   3. Apollo scrape — search employees, click green Access email
#   4. LinkedIn cleanup — find missed people, enrich via Apollo
#
# Each step checks the sheet first, skips duplicates.
# Apollo steps have 5-6 min delays between clicks (anti-detection).
# Full run for one venue: ~30 min to 4+ hours depending on employee count.
#
# Requirements:
#   - Chrome open and logged into Apollo + LinkedIn
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
#   - Python 3 with requests, beautifulsoup4
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="7a47396026644791a236621ebe3d2584"
LOG_FILE="${SCRIPT_DIR}/pipeline.log"

# Email patterns to skip
JUNK_DOMAINS="wix.com|wordpress|sentry.io|cloudflare|example.com|squarespace|shopify|mailchimp|googleapis|google.com|gstatic|facebook|instagram|twitter|hubspot|sendgrid|zendesk"

# Random delay function
rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

# Log + print
log() {
    echo "$1"
    echo "$(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}

# ---------------------------------------------------------------
# STEP 1: Website Scrape
# Scrapes venue website + /contact page for emails + social links
# ---------------------------------------------------------------
step1_website_scrape() {
    local venue="$1" venue_id="$2" website="$3"
    log ""
    log "========== STEP 1: Website Scrape =========="
    log "  URL: $website"

    if [ -z "$website" ]; then
        log "  [SKIP] No website URL provided"
        return
    fi

    # Fetch existing contacts to skip duplicates
    local existing_emails
    existing_emails=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" | python3 -c "
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

    # Scrape website + /contact page for emails and social links
    SCRAPE_RESULT=$(python3 << PYEOF
import requests, re, sys, json, urllib.parse

url = '''$website'''
if not url.startswith('http'): url = 'https://' + url

headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
junk = '''$JUNK_DOMAINS'''.split('|')
junk_prefixes = ['info@']

all_text = ''
emails = set()
facebook = ''
instagram = ''

# Fetch main page
try:
    resp = requests.get(url, headers=headers, timeout=15)
    all_text += resp.text
except Exception as e:
    print(f"ERROR:Failed to fetch {url}: {e}")
    sys.exit(0)

# Try /contact and /contact-us pages
for path in ['/contact', '/contact-us', '/about', '/about-us']:
    try:
        r = requests.get(url.rstrip('/') + path, headers=headers, timeout=10)
        if r.status_code == 200:
            all_text += r.text
    except:
        pass

# Extract emails
raw_emails = set(re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', all_text))
for e in raw_emails:
    el = e.lower()
    if any(j in el for j in junk): continue
    if any(el.startswith(p) for p in junk_prefixes): continue
    if len(e) > 60: continue
    emails.add(e)

# Extract social links
fb_pattern = re.findall(r'https?://(?:www\.)?facebook\.com/[a-zA-Z0-9._/-]+', all_text)
ig_pattern = re.findall(r'https?://(?:www\.)?instagram\.com/[a-zA-Z0-9._/-]+', all_text)

for f in fb_pattern:
    if 'sharer' not in f and 'share' not in f:
        facebook = f.split('?')[0]
        break
for i in ig_pattern:
    if 'share' not in i:
        instagram = i.split('?')[0]
        break

result = {
    'emails': sorted(emails),
    'facebook': facebook,
    'instagram': instagram
}
print(json.dumps(result))
PYEOF
    )

    if echo "$SCRAPE_RESULT" | grep -q "^ERROR:"; then
        log "  $SCRAPE_RESULT"
        return
    fi

    # Parse results
    local email_count fb ig
    email_count=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())['emails']))")
    fb=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['facebook'])")
    ig=$(echo "$SCRAPE_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['instagram'])")

    log "  Emails found: $email_count"
    log "  Facebook: ${fb:-none}"
    log "  Instagram: ${ig:-none}"

    # Update venue with social links if found
    if [ -n "$fb" ] && [ "$fb" != "None" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$fb'))")" > /dev/null
        log "  Updated Facebook link in sheet"
    fi
    if [ -n "$ig" ] && [ "$ig" != "None" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ig'))")" > /dev/null
        log "  Updated Instagram link in sheet"
    fi

    # Verify + push each email
    echo "$SCRAPE_RESULT" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for e in data['emails']:
    print(e)
" | while read -r email; do
        if [ -z "$email" ]; then continue; fi

        # Skip if already in sheet
        email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]')
        if echo "$existing_emails" | tr '|||' '\n' | grep -qi "^${email_lower}$" 2>/dev/null; then
            log "  [SKIP] $email — already in sheet"
            continue
        fi

        # ZeroBounce verify
        local zb_status
        zb_status=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$email" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
        log "  $email → $zb_status"

        if [ "$zb_status" = "valid" ]; then
            local encoded
            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '''$venue_id''',
    'email': '''$email''',
    'source': 'website',
    'verified': 'valid'
}))
")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            log "  Added: $email"
        fi
        sleep 1
    done
}

# ---------------------------------------------------------------
# STEP 2: Social Media Scrape
# Checks Instagram + Facebook pages for additional emails
# ---------------------------------------------------------------
step2_social_scrape() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 2: Social Media Scrape =========="

    # Fetch venue details to get social links
    local venue_data
    venue_data=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}")

    local fb ig existing_emails
    fb=$(echo "$venue_data" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('venue',{}).get('facebook',''))" 2>/dev/null)
    ig=$(echo "$venue_data" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('venue',{}).get('instagram',''))" 2>/dev/null)
    existing_emails=$(echo "$venue_data" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
emails = set()
for c in d.get('contacts', []):
    if c.get('email'): emails.add(c['email'].lower())
print('|||'.join(emails))
" 2>/dev/null)

    log "  Facebook: ${fb:-none}"
    log "  Instagram: ${ig:-none}"

    SOCIAL_EMAILS=$(python3 << PYEOF
import requests, re, json

headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
junk = '''$JUNK_DOMAINS'''.split('|')
emails = set()

# Facebook About page
fb = '''$fb'''
if fb and fb != 'None' and len(fb) > 5:
    for path in ['', '/about', '/about_contact_and_basic_info']:
        try:
            r = requests.get(fb.rstrip('/') + path, headers=headers, timeout=10)
            found = re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', r.text)
            for e in found:
                if not any(j in e.lower() for j in junk) and len(e) < 60:
                    emails.add(e)
        except:
            pass

# Instagram profile
ig = '''$ig'''
if ig and ig != 'None' and len(ig) > 5:
    try:
        r = requests.get(ig, headers=headers, timeout=10)
        found = re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', r.text)
        for e in found:
            if not any(j in e.lower() for j in junk) and len(e) < 60:
                emails.add(e)
    except:
        pass

for e in sorted(emails):
    print(e)
PYEOF
    )

    if [ -z "$SOCIAL_EMAILS" ]; then
        log "  No new emails from social media"
        return
    fi

    echo "$SOCIAL_EMAILS" | while read -r email; do
        if [ -z "$email" ]; then continue; fi

        email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]')
        if echo "$existing_emails" | tr '|||' '\n' | grep -qi "^${email_lower}$" 2>/dev/null; then
            log "  [SKIP] $email — already in sheet"
            continue
        fi

        # ZeroBounce verify
        local zb_status
        zb_status=$(curl -s "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$email" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
        log "  $email → $zb_status (source: social)"

        if [ "$zb_status" = "valid" ]; then
            local encoded source
            source="facebook"
            echo "$ig" | grep -qi "instagram" && echo "$email" | grep -qi "" && source="instagram"

            encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': '''$venue_id''',
    'email': '''$email''',
    'source': 'social',
    'verified': 'valid'
}))
")
            curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
            log "  Added: $email"
        fi
        sleep 1
    done
}

# ---------------------------------------------------------------
# STEP 3: Apollo Scrape
# Search company on Apollo, access green emails
# ---------------------------------------------------------------
step3_apollo_scrape() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 3: Apollo Scrape =========="
    log "  Running: apollo_scrape.sh \"$venue\" \"$venue_id\""

    "${SCRIPT_DIR}/apollo_scrape.sh" "$venue" "$venue_id"
}

# ---------------------------------------------------------------
# STEP 4: LinkedIn Cleanup + Apollo Enrichment
# Find people Apollo missed, enrich via Apollo
# ---------------------------------------------------------------
step4_linkedin_scrape() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 4: LinkedIn Cleanup =========="
    log "  Running: linkedin_scrape.sh \"$venue\" \"$venue_id\""

    "${SCRIPT_DIR}/linkedin_scrape.sh" "$venue" "$venue_id"
}

# ---------------------------------------------------------------
# BATCH MODE: Process multiple venues from JSON file
# ---------------------------------------------------------------
run_batch() {
    local batch_file="$1"
    if [ ! -f "$batch_file" ]; then
        echo "[ERROR] Batch file not found: $batch_file"
        exit 1
    fi

    local total
    total=$(python3 -c "import json; print(len(json.load(open('$batch_file'))))")
    log "=== BATCH MODE: $total venues ==="

    for i in $(seq 0 $((total - 1))); do
        local venue_info
        venue_info=$(python3 -c "
import json
venues = json.load(open('$batch_file'))
v = venues[$i]
print(v.get('name', ''))
print(v.get('venue_id', ''))
print(v.get('website', ''))
")
        local name venue_id website
        name=$(echo "$venue_info" | sed -n '1p')
        venue_id=$(echo "$venue_info" | sed -n '2p')
        website=$(echo "$venue_info" | sed -n '3p')

        log ""
        log "############################################################"
        log "# VENUE [$((i+1))/$total]: $name"
        log "############################################################"

        run_single_venue "$name" "$venue_id" "$website"

        if [ "$i" -lt "$((total - 1))" ]; then
            log ""
            log "--- Moving to next venue in 30s ---"
            sleep 30
        fi
    done

    log ""
    log "=== BATCH COMPLETE: $total venues processed ==="
}

# ---------------------------------------------------------------
# SINGLE VENUE: Run all 4 steps
# ---------------------------------------------------------------
run_single_venue() {
    local venue="$1" venue_id="$2" website="$3"

    local start_time
    start_time=$(date +%s)

    log ""
    log "============================================================"
    log " PIPELINE: $venue ($venue_id)"
    log " Website: $website"
    log " Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    step1_website_scrape "$venue" "$venue_id" "$website"
    step2_social_scrape "$venue" "$venue_id"
    step3_apollo_scrape "$venue" "$venue_id"
    step4_linkedin_scrape "$venue" "$venue_id"

    # Navigate Chrome to new tab when done
    osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "chrome://newtab"' 2>/dev/null

    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$(( (end_time - start_time) / 60 ))

    log ""
    log "============================================================"
    log " PIPELINE COMPLETE: $venue"
    log " Duration: ${elapsed} minutes"
    log " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
echo "" >> "$LOG_FILE"
echo "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"

if [ "$1" = "--batch" ]; then
    BATCH_FILE="${2:?Usage: $0 --batch venues.json}"
    run_batch "$BATCH_FILE"
else
    VENUE="${1:?Usage: $0 \"Venue Name\" \"VENUE_ID\" \"https://website.com\"  OR  $0 --batch venues.json}"
    VENUE_ID="${2:?Usage: $0 \"Venue Name\" \"VENUE_ID\" \"https://website.com\"}"
    WEBSITE="${3:-}"
    run_single_venue "$VENUE" "$VENUE_ID" "$WEBSITE"
fi
