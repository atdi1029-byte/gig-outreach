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

    # Don't skip venues with contacts — they may have only generic info@ emails
    # and be missing named contacts, catering emails, event emails, etc.
    if [ "$CONTACT_COUNT" -gt 0 ]; then
        log "  Has $CONTACT_COUNT existing contacts — checking for more"
    fi

    if [ -z "$WEBSITE" ] || [ "$WEBSITE" = "None" ] || [ "$WEBSITE" = "" ]; then
        log "  No website on file — skipping web check"
        return
    fi

    # Clean website URL (take first if pipe-separated)
    WEBSITE=$(echo "$WEBSITE" | cut -d'|' -f1)

    log "  Website: $WEBSITE"

    # --- Check main page + common subpages + discovered links ---
    local PAGES=("$WEBSITE" "${WEBSITE}/contact" "${WEBSITE}/contact-us" "${WEBSITE}/about" "${WEBSITE}/events" "${WEBSITE}/private-events" "${WEBSITE}/event-contact" "${WEBSITE}/catering" "${WEBSITE}/private-dining" "${WEBSITE}/private-event-space" "${WEBSITE}/book-event" "${WEBSITE}/group-dining" "${WEBSITE}/weddings")
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

    # Add any new emails as contacts (skip generic prefixes)
    local GENERIC_PREFIXES="info@ hello@ contact@ sales@ events@ reservations@ booking@ enquiries@ inquiries@ office@ general@ frontdesk@ reception@ noreply@ no-reply@ support@ admin@ webmaster@ billing@ dataremoval@ privacy@ careers@ jobs@ hr@ marketing@ press@ media@ eat@ dine@ wine@ music@ art@ mail@"
    if [ -n "$ALL_EMAILS" ]; then
        echo -e "$ALL_EMAILS" | sort -u | while IFS= read -r EMAIL; do
            [ -z "$EMAIL" ] && continue
            local EMAIL_LOWER
            EMAIL_LOWER=$(echo "$EMAIL" | tr '[:upper:]' '[:lower:]')
            local IS_GENERIC=false
            for gp in $GENERIC_PREFIXES; do
                if echo "$EMAIL_LOWER" | grep -q "^${gp}"; then
                    IS_GENERIC=true
                    break
                fi
            done
            if [ "$IS_GENERIC" = true ]; then
                log "  [SKIP] $EMAIL — generic prefix"
                continue
            fi
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
            # Find people with emails and enrich them
            local ENRICH_LIST
            ENRICH_LIST=$(echo "$APOLLO_RESULTS" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for p in data.get('people', []):
    pid = p.get('id','')
    first = p.get('first_name','')
    last = p.get('last_name','') or ''
    title = p.get('title','')
    has_email = p.get('has_email', False)
    org = p.get('organization',{}).get('name','')
    # Skip low-value roles
    skip_titles = ['server','waiter','waitress','hostess','host','busser',
                   'bartender','dishwasher','line cook','prep cook','barback']
    if title.lower() in skip_titles:
        print(f'SKIP|{first} {last}|{title}|no email - low value role')
        continue
    if has_email:
        print(f'ENRICH|{pid}|{first} {last}|{title}|{org}')
    else:
        print(f'LOG|{first} {last}|{title}|no email')
" 2>/dev/null)

            echo "$ENRICH_LIST" | while IFS='|' read -r ACTION REST; do
                case "$ACTION" in
                    ENRICH)
                        IFS='|' read -r PID PNAME PTITLE PORG <<< "$REST"
                        log "  [Apollo] Enriching: $PNAME ($PTITLE)"
                        local ENRICH_RESP
                        ENRICH_RESP=$(curl -s --max-time 15 -H "Content-Type: application/json" \
                            -H "X-Api-Key: $APOLLO_API_KEY" \
                            -d "{\"id\":\"$PID\"}" \
                            "${APOLLO_API_BASE}/people/match" 2>/dev/null)
                        local ENRICH_EMAIL ENRICH_STATUS
                        ENRICH_EMAIL=$(echo "$ENRICH_RESP" | python3 -c "import json,sys; p=json.loads(sys.stdin.read()).get('person',{}); print(p.get('email',''))" 2>/dev/null)
                        ENRICH_STATUS=$(echo "$ENRICH_RESP" | python3 -c "import json,sys; p=json.loads(sys.stdin.read()).get('person',{}); print(p.get('email_status',''))" 2>/dev/null)
                        if [ -n "$ENRICH_EMAIL" ] && [ "$ENRICH_EMAIL" != "None" ] && [ "$ENRICH_EMAIL" != "" ]; then
                            log "  [Apollo] Got email: $ENRICH_EMAIL ($ENRICH_STATUS)"
                            curl -sL "${APPS_SCRIPT_URL}?action=add_contact&venue_id=${VID}&name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PNAME'))")&email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ENRICH_EMAIL'))")&title=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PTITLE'))")&source=postcheck_apollo" > /dev/null
                            log "  [Apollo] Saved: $PNAME <$ENRICH_EMAIL>"
                        else
                            log "  [Apollo] No email returned for $PNAME"
                        fi
                        sleep 1
                        ;;
                    SKIP|LOG)
                        IFS='|' read -r PNAME PTITLE REASON <<< "$REST"
                        log "  [Apollo] $PNAME ($PTITLE) — $REASON"
                        ;;
                esac
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

    # --- Build evidence string and save check status ---
    local WEB_STATUS="web:ok"
    if [ -z "$WEBSITE" ] || [ "$WEBSITE" = "None" ]; then WEB_STATUS="web:none"; fi

    local APOLLO_STATUS="apollo:${APOLLO_TOTAL:-0}"
    local LI_STATUS="li:0"
    if [ -n "$LI_RESULTS" ] && [ "$LI_RESULTS" != "missing value" ]; then
        local LI_COUNT
        LI_COUNT=$(echo "$LI_RESULTS" | grep -c '|||' 2>/dev/null || echo "0")
        LI_STATUS="li:${LI_COUNT}"
    fi

    local FORM_STATUS="form:no"
    if [ -n "$CONTACT_FORM" ]; then FORM_STATUS="form:yes"; fi

    local EMAIL_COUNT=0
    if [ -n "$ALL_EMAILS" ]; then
        EMAIL_COUNT=$(echo -e "$ALL_EMAILS" | sort -u | grep -c '@' 2>/dev/null || echo "0")
    fi

    local EVIDENCE="${WEB_STATUS}|${APOLLO_STATUS}|${LI_STATUS}|emails:${EMAIL_COUNT}|${FORM_STATUS}"
    local EVIDENCE_ENC
    EVIDENCE_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$EVIDENCE'))" 2>/dev/null)
    curl -sL "${APPS_SCRIPT_URL}?action=save_check&venue_id=${VID}&evidence=${EVIDENCE_ENC}" > /dev/null
    log "  [CHECK] Saved: $EVIDENCE"
}

# --- Enrich pending contacts (name but no email) ---
enrich_pending() {
    if [ -z "$APOLLO_API_KEY" ]; then
        log "[ENRICH] No Apollo API key — skipping pending enrichments"
        return
    fi

    log ""
    log "=== Enriching Pending Contacts (name, no email) ==="

    local AUDIT_TMP="/tmp/postcheck_audit.json"
    curl -sL "${APPS_SCRIPT_URL}?action=audit_pipeline" -o "$AUDIT_TMP" 2>/dev/null

    local PENDING_COUNT
    PENDING_COUNT=$(python3 -c "
import json
with open('$AUDIT_TMP') as f:
    data = json.load(f)
pending = data.get('pending_enrichments', [])
print(len(pending))
" 2>/dev/null || echo "0")

    if [ "$PENDING_COUNT" = "0" ]; then
        log "  No pending contacts to enrich"
        return
    fi

    log "  Found $PENDING_COUNT contacts needing enrichment"

    python3 -c "
import json
with open('$AUDIT_TMP') as f:
    data = json.load(f)
for p in data.get('pending_enrichments', []):
    print(p['contact_id'] + '|||' + p['venue_id'] + '|||' + p['name'] + '|||' + p.get('title',''))
" 2>/dev/null | while IFS='|||' read -r CID PVID PNAME PTITLE; do
        [ -z "$CID" ] && continue
        log "  [ENRICH] $PNAME ($PTITLE) at $PVID"

        # Get venue name + domain for enrichment
        local VDETAIL_TMP="/tmp/postcheck_enrich_detail.json"
        curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${PVID}" -o "$VDETAIL_TMP" 2>/dev/null
        local VNAME VDOMAIN
        VNAME=$(python3 -c "import json; print(json.load(open('$VDETAIL_TMP')).get('venue',{}).get('name',''))" 2>/dev/null)
        VDOMAIN=$(python3 -c "
import json
from urllib.parse import urlparse
v = json.load(open('$VDETAIL_TMP')).get('venue',{})
w = v.get('website','')
if w:
    print(urlparse(w).netloc.lower().replace('www.',''))
else:
    print('')
" 2>/dev/null)

        # Split first/last name
        local FIRST_NAME LAST_NAME
        FIRST_NAME=$(echo "$PNAME" | awk '{print $1}')
        LAST_NAME=$(echo "$PNAME" | awk '{$1=""; print}' | xargs)

        # Apollo people/match enrichment
        local MATCH_RESP
        MATCH_RESP=$(curl -s --max-time 15 -H "Content-Type: application/json" \
            -H "X-Api-Key: $APOLLO_API_KEY" \
            -d "{\"first_name\":\"$FIRST_NAME\",\"last_name\":\"$LAST_NAME\",\"organization_name\":\"$VNAME\",\"domain\":\"$VDOMAIN\"}" \
            "${APOLLO_API_BASE}/people/match" 2>/dev/null)

        local MATCH_EMAIL MATCH_STATUS
        MATCH_EMAIL=$(echo "$MATCH_RESP" | python3 -c "import json,sys; p=json.loads(sys.stdin.read()).get('person',{}); print(p.get('email','') or '')" 2>/dev/null)
        MATCH_STATUS=$(echo "$MATCH_RESP" | python3 -c "import json,sys; p=json.loads(sys.stdin.read()).get('person',{}); print(p.get('email_status','') or '')" 2>/dev/null)

        if [ -n "$MATCH_EMAIL" ] && [ "$MATCH_EMAIL" != "None" ] && [ "$MATCH_EMAIL" != "" ]; then
            log "  [ENRICH] Got: $MATCH_EMAIL ($MATCH_STATUS)"
            # Update existing contact with email
            local NAME_ENC EMAIL_ENC
            NAME_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PNAME'))")
            EMAIL_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$MATCH_EMAIL'))")
            curl -sL "${APPS_SCRIPT_URL}?action=update_contact_email&venue_id=${PVID}&name=${NAME_ENC}&email=${EMAIL_ENC}&source=postcheck_enrich&verified=${MATCH_STATUS}" > /dev/null
            log "  [ENRICH] Updated: $PNAME <$MATCH_EMAIL>"
        else
            log "  [ENRICH] No email found for $PNAME"
        fi
        sleep 1
    done
}

# --- Main ---
echo "" >> "$LOG_FILE"
log "=== Post-Pipeline Check Started ==="

if [ -n "$1" ]; then
    # Check specific venue
    check_venue "$1"
else
    # Check ALL pipelined venues — not just zero-contact ones
    # The old code only checked zero-contact venues, which is why
    # venues with 1-2 bad pipeline contacts never got manual verification.
    log "Fetching ALL pipelined venues for manual check..."
    AUDIT_TMP="/tmp/postcheck_audit.json"
    curl -sL "${APPS_SCRIPT_URL}?action=audit_pipeline" -o "$AUDIT_TMP" 2>/dev/null

    TOTAL_UNCHECKED=$(python3 -c "
import json
with open('$AUDIT_TMP') as f:
    data = json.load(f)
print(data.get('summary',{}).get('unchecked',0))
" 2>/dev/null || echo "0")

    log "Found $TOTAL_UNCHECKED unchecked pipelined venues"

    python3 -c "
import json
with open('$AUDIT_TMP') as f:
    data = json.load(f)
for v in data.get('unchecked_venues', []):
    print(v['venue_id'])
" 2>/dev/null | while IFS= read -r VID; do
        check_venue "$VID"
    done

    # After checking all venues, enrich any pending contacts
    enrich_pending

    # Final audit — show what's left
    log ""
    log "=== Final Audit ==="
    curl -sL "${APPS_SCRIPT_URL}?action=audit_pipeline" -o "$AUDIT_TMP" 2>/dev/null
    python3 -c "
import json
with open('$AUDIT_TMP') as f:
    data = json.load(f)
s = data.get('summary', {})
print(f\"Pipelined: {s.get('total_pipelined',0)} | Checked: {s.get('checked',0)} | Unchecked: {s.get('unchecked',0)} | Pending enrichments: {s.get('pending_enrichments',0)}\")
if s.get('unchecked', 0) > 0:
    print('WARNING: Still have unchecked venues!')
    for v in data.get('unchecked_venues', []):
        print(f\"  {v['venue_id']} — {v['name']} ({v['city']}, {v['state']})\")
if s.get('pending_enrichments', 0) > 0:
    print('WARNING: Still have contacts needing enrichment!')
    for p in data.get('pending_enrichments', []):
        print(f\"  {p['contact_id']} — {p['name']} at {p['venue_id']}\")
" 2>/dev/null
fi

log ""
log "=== Post-Pipeline Check Complete ==="
