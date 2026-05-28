#!/bin/bash
# =============================================================
# Post-Pipeline Contact Verification
#
# Runs AFTER pipeline.sh. Checks every venue that came back with
# zero contacts. Fetches their website, checks /contact /about
# /events pages, extracts emails and contact forms.
#
# Usage:
#   ./postcheck.sh              — check all zero-contact venues from latest run
#   ./postcheck.sh VA-REST-841  — check specific venue
#
# This script catches what pipeline misses: contact forms, emails
# on subpages, correct social links.
# =============================================================

APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
LOG_FILE="${SCRIPT_DIR}/postcheck.log"
APOLLO_API_KEY="${APOLLO_API_KEY:-}"
APOLLO_API_BASE="https://api.apollo.io/api/v1"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Email regex for Python extraction
EMAIL_RE='[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}'

check_venue() {
    local VID="$1"
    local DETAIL_TMP="/tmp/postcheck_detail.json"

    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" -o "$DETAIL_TMP" 2>/dev/null

    local NAME WEBSITE CITY STATE
    NAME=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('name',''))" 2>/dev/null)
    WEBSITE=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('website',''))" 2>/dev/null)
    CITY=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('city',''))" 2>/dev/null)
    STATE=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('state',''))" 2>/dev/null)
    local CONTACT_COUNT
    CONTACT_COUNT=$(python3 -c "import json; print(len(json.load(open('$DETAIL_TMP')).get('contacts',[])))" 2>/dev/null)

    log ""
    log "=== $NAME ($VID) | $CITY, $STATE | Contacts: $CONTACT_COUNT ==="

    if [ "$CONTACT_COUNT" -gt 0 ]; then
        log "  Already has contacts — skipping"
        return
    fi

    if [ -z "$WEBSITE" ] || [ "$WEBSITE" = "None" ] || [ "$WEBSITE" = "" ]; then
        log "  No website on file — skipping web check"
        return
    fi

    # Clean website URL (take first if pipe-separated)
    WEBSITE=$(echo "$WEBSITE" | cut -d'|' -f1)

    log "  Website: $WEBSITE"

    # --- Check main page + common subpages + discovered links ---
    local PAGES=("$WEBSITE" "${WEBSITE}/contact" "${WEBSITE}/contact-us" "${WEBSITE}/about" "${WEBSITE}/events" "${WEBSITE}/private-events" "${WEBSITE}/event-contact")
    local ALL_EMAILS=""
    local CONTACT_FORM=""

    # Crawl homepage for links containing contact/reservation/booking/inquiry/event
    local HOMEPAGE_BODY
    HOMEPAGE_BODY=$(curl -sL --max-time 10 -A "Mozilla/5.0" "$WEBSITE" 2>/dev/null)
    if [ -n "$HOMEPAGE_BODY" ]; then
        local EXTRA_PAGES
        EXTRA_PAGES=$(echo "$HOMEPAGE_BODY" | python3 -c "
import re, sys
from urllib.parse import urljoin
html = sys.stdin.read()
base = '$WEBSITE'
hrefs = re.findall(r'href=[\"'\''](.*?)[\"'\'']', html)
seen = set()
keywords = ['contact', 'reservat', 'booking', 'inquiry', 'enquir', 'private-event', 'event-contact', 'get-in-touch', 'reach-us']
for h in hrefs:
    url = urljoin(base, h).split('?')[0].split('#')[0].rstrip('/')
    if url in seen: continue
    seen.add(url)
    if url.startswith(base) and any(k in url.lower() for k in keywords):
        print(url)
" 2>/dev/null)
        if [ -n "$EXTRA_PAGES" ]; then
            while IFS= read -r EXTRA; do
                PAGES+=("$EXTRA")
            done <<< "$EXTRA_PAGES"
        fi
    fi

    for PAGE in "${PAGES[@]}"; do
        local BODY
        BODY=$(curl -sL --max-time 10 -A "Mozilla/5.0" "$PAGE" 2>/dev/null)
        if [ -z "$BODY" ]; then continue; fi

        # Extract emails
        local PAGE_EMAILS
        PAGE_EMAILS=$(echo "$BODY" | python3 -c "
import re, sys
html = sys.stdin.read()
emails = set(re.findall(r'$EMAIL_RE', html))
# Filter junk
skip = ['wix.com','sentry.io','cloudflare','example.com','squarespace','shopify',
        'mailchimp','googleapis','google.com','facebook.com','instagram.com',
        'twitter.com','hubspot.com','sendgrid.net','wordpress','fontawesome',
        'jquery','bootstrap','schema.org','w3.org','apple.com','icloud.com',
        'atdi1029@gmail.com','alexbarnettclassical@gmail.com','abar89251@gmail.com',
        'alex@alexbarnettclassical.com','.png','.jpg','.gif','.svg','.css','.js',
        'latofonts.com','fonts.com','typekit.com','monotype.com','myfonts.com',
        'gstatic.com','jsdelivr.net','cdnjs.com','unpkg.com','github.com']
for e in sorted(emails):
    if not any(s in e.lower() for s in skip):
        print(e)
" 2>/dev/null)

        if [ -n "$PAGE_EMAILS" ]; then
            log "  Found emails on $PAGE:"
            while IFS= read -r EMAIL; do
                log "    $EMAIL"
                ALL_EMAILS="${ALL_EMAILS}${EMAIL}\n"
            done <<< "$PAGE_EMAILS"
        fi

        # Check for contact forms
        local HAS_FORM
        HAS_FORM=$(echo "$BODY" | python3 -c "
import re, sys
html = sys.stdin.read()
# Look for form tags or common form indicators
if re.search(r'<form[^>]*action', html, re.I):
    print('form')
elif re.search(r'contact.form|inquiry|book.*event|private.*event|request.*info', html, re.I):
    print('form')
else:
    print('')
" 2>/dev/null)

        if [ "$HAS_FORM" = "form" ] && [ -z "$CONTACT_FORM" ]; then
            CONTACT_FORM="$PAGE"
            log "  Contact form found: $PAGE"
        fi
    done

    # --- Save findings to sheet ---
    if [ -n "$CONTACT_FORM" ]; then
        local EXISTING_FORM
        EXISTING_FORM=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('contact_form',''))" 2>/dev/null)
        if [ -z "$EXISTING_FORM" ] || [ "$EXISTING_FORM" = "None" ]; then
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=contact_form&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$CONTACT_FORM'))")" > /dev/null
            log "  Saved contact form to sheet"
        fi
    fi

    # Add any new emails as contacts
    if [ -n "$ALL_EMAILS" ]; then
        echo -e "$ALL_EMAILS" | sort -u | while IFS= read -r EMAIL; do
            [ -z "$EMAIL" ] && continue
            curl -sL "${APPS_SCRIPT_URL}?action=add_contact&venue_id=${VID}&email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$EMAIL'))")&source=postcheck" > /dev/null
            log "  Added contact: $EMAIL"
        done
    fi

    # --- Check Instagram ---
    local CURRENT_IG
    CURRENT_IG=$(python3 -c "import json; print(json.load(open('$DETAIL_TMP')).get('venue',{}).get('instagram',''))" 2>/dev/null)
    if [ -z "$CURRENT_IG" ] || [ "$CURRENT_IG" = "None" ] || echo "$CURRENT_IG" | grep -q "accounts.google.com"; then
        # Try to find IG from website HTML
        local MAIN_BODY
        MAIN_BODY=$(curl -sL --max-time 10 -A "Mozilla/5.0" "$WEBSITE" 2>/dev/null)
        local FOUND_IG
        FOUND_IG=$(echo "$MAIN_BODY" | python3 -c "
import re, sys
html = sys.stdin.read()
igs = re.findall(r'https?://(?:www\.)?instagram\.com/([A-Za-z0-9._]+)', html)
for ig in igs:
    if ig not in ('p', 'reel', 'stories', 'explore', 'accounts', 'direct'):
        print('https://www.instagram.com/' + ig + '/')
        break
" 2>/dev/null)
        if [ -n "$FOUND_IG" ]; then
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=instagram&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FOUND_IG'))")" > /dev/null
            log "  Found & saved IG: $FOUND_IG"
        fi
    fi

    # --- Apollo API search ---
    if [ -n "$APOLLO_API_KEY" ]; then
        local DOMAIN=""
        if [ -n "$WEBSITE" ]; then
            DOMAIN=$(python3 -c "from urllib.parse import urlparse; print(urlparse('$WEBSITE').netloc.lower().replace('www.',''))" 2>/dev/null)
        fi

        local APOLLO_RESULTS=""
        if [ -n "$DOMAIN" ]; then
            log "  [Apollo] Searching by domain: $DOMAIN"
            APOLLO_RESULTS=$(curl -s --max-time 15 -H "Content-Type: application/json" \
                -H "X-Api-Key: $APOLLO_API_KEY" \
                -d "{\"q_organization_domains_list\":[\"$DOMAIN\"],\"per_page\":10}" \
                "${APOLLO_API_BASE}/mixed_people/search" 2>/dev/null)
        fi

        local APOLLO_TOTAL
        APOLLO_TOTAL=$(echo "$APOLLO_RESULTS" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('pagination',{}).get('total_entries',0))" 2>/dev/null || echo "0")

        if [ "$APOLLO_TOTAL" = "0" ] || [ -z "$APOLLO_TOTAL" ]; then
            # Try by company name
            log "  [Apollo] No results by domain — searching by name: $NAME"
            APOLLO_RESULTS=$(curl -s --max-time 15 -H "Content-Type: application/json" \
                -H "X-Api-Key: $APOLLO_API_KEY" \
                -d "{\"q_keywords\":\"$NAME\",\"per_page\":10}" \
                "${APOLLO_API_BASE}/mixed_people/search" 2>/dev/null)
            APOLLO_TOTAL=$(echo "$APOLLO_RESULTS" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('pagination',{}).get('total_entries',0))" 2>/dev/null || echo "0")
        fi

        log "  [Apollo] Found $APOLLO_TOTAL people"

        if [ "$APOLLO_TOTAL" -gt 0 ] 2>/dev/null; then
            echo "$APOLLO_RESULTS" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for p in data.get('people', []):
    name = (p.get('first_name','') + ' ' + p.get('last_name','')).strip()
    if not name or name == ' ':
        name = p.get('first_name','') + ' ' + (p.get('last_name','')[:2] + '***' if p.get('last_name') else '')
    title = p.get('title','')
    has_email = p.get('has_email', False)
    org = p.get('organization',{}).get('name','')
    email_flag = 'HAS EMAIL' if has_email else 'no email'
    print(f'  {name} | {title} | {org} | {email_flag}')
" 2>/dev/null | while IFS= read -r LINE; do
                log "  [Apollo]$LINE"
            done
        fi
    else
        log "  [Apollo] SKIPPED — no API key"
    fi

    # --- LinkedIn search via Chrome ---
    log "  Searching LinkedIn for: $NAME"
    local LI_SEARCH
    LI_SEARCH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$NAME'))")
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.linkedin.com/search/results/people/?keywords=${LI_SEARCH}&origin=SWITCH_SEARCH_VERTICAL\"" 2>/dev/null
    sleep 5

    local LI_RESULTS
    LI_RESULTS=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "
(function() {
    var results = [];
    var cards = document.querySelectorAll(\".reusable-search__result-container\");
    for (var i = 0; i < cards.length && i < 10; i++) {
        var nameEl = cards[i].querySelector(\".entity-result__title-text a span[aria-hidden=true]\");
        var titleEl = cards[i].querySelector(\".entity-result__primary-subtitle\");
        var locEl = cards[i].querySelector(\".entity-result__secondary-subtitle\");
        var name = nameEl ? nameEl.textContent.trim() : \"\";
        var title = titleEl ? titleEl.textContent.trim() : \"\";
        var loc = locEl ? locEl.textContent.trim() : \"\";
        if (name) results.push(name + \"|||\" + title + \"|||\" + loc);
    }
    return results.join(\"\\n\");
})()"' 2>/dev/null)

    if [ -n "$LI_RESULTS" ] && [ "$LI_RESULTS" != "missing value" ] && [ "$LI_RESULTS" != "" ]; then
        local VENUE_LOWER
        VENUE_LOWER=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
        local LI_ADDED=0

        while IFS='|||' read -r LI_NAME LI_TITLE LI_LOC; do
            [ -z "$LI_NAME" ] && continue
            # Only keep people whose title mentions this venue
            local TITLE_LOWER
            TITLE_LOWER=$(echo "$LI_TITLE" | tr '[:upper:]' '[:lower:]')
            if echo "$TITLE_LOWER" | grep -qi "$VENUE_LOWER" || echo "$TITLE_LOWER" | grep -qiE "$(echo "$NAME" | sed 's/ /.*/' | tr '[:upper:]' '[:lower:]')"; then
                log "  [LinkedIn] $LI_NAME — $LI_TITLE ($LI_LOC)"
                # Add to sheet as contact (name only, no email)
                local LI_NAME_ENC LI_TITLE_ENC
                LI_NAME_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$LI_NAME'))")
                LI_TITLE_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$LI_TITLE'))")
                curl -sL "${APPS_SCRIPT_URL}?action=add_contact&venue_id=${VID}&name=${LI_NAME_ENC}&title=${LI_TITLE_ENC}&source=linkedin-postcheck" > /dev/null
                LI_ADDED=$((LI_ADDED + 1))
            fi
        done <<< "$LI_RESULTS"

        if [ "$LI_ADDED" -eq 0 ]; then
            log "  [LinkedIn] No relevant people found (none with venue in title)"
        else
            log "  [LinkedIn] Added $LI_ADDED contacts"
        fi
    else
        log "  [LinkedIn] No results"
    fi

    if [ -z "$ALL_EMAILS" ] && [ -z "$CONTACT_FORM" ]; then
        log "  Nothing found on website"
    fi
}

# --- Main ---
echo "" >> "$LOG_FILE"
log "=== Post-Pipeline Check Started ==="

if [ -n "$1" ]; then
    # Check specific venue
    check_venue "$1"
else
    # Check all pipelined venues with zero contacts
    log "Fetching pipelined venues with zero contacts..."
    DASHBOARD_TMP="/tmp/postcheck_dashboard.json"
    curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o "$DASHBOARD_TMP" 2>/dev/null

    python3 -c "
import json
with open('$DASHBOARD_TMP') as f:
    data = json.load(f)
contacts_by_venue = {}
for c in data.get('contacts', []):
    vid = c.get('venue_id', '')
    if vid:
        contacts_by_venue[vid] = contacts_by_venue.get(vid, 0) + 1

for v in data.get('venues', []):
    venue = v.get('venue', v)
    vid = venue.get('venue_id', '')
    status = venue.get('status', '')
    if status == 'pipelined' and contacts_by_venue.get(vid, 0) == 0:
        print(vid)
" 2>/dev/null | while IFS= read -r VID; do
        check_venue "$VID"
    done
fi

log ""
log "=== Post-Pipeline Check Complete ==="
