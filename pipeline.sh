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

SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR_EARLY/.env" ] && source "$SCRIPT_DIR_EARLY/.env"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="${ZEROBOUNCE_KEY:-}"
APOLLO_API_KEY="${APOLLO_API_KEY:-}"
APOLLO_API_BASE="https://api.apollo.io/api/v1"
APOLLO_CREDITS_USED=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZB_GUARD="${SCRIPT_DIR}/zerobounce_guard.py"
ZB_RUN_ID="${ZB_RUN_ID:-pipeline-$(date +%Y%m%dT%H%M%S)-$$}"
export ZB_RUN_ID
ZB_VENUE_CREDITS=0
MAX_ZB_PER_VENUE=${MAX_ZB_PER_VENUE:-40}
LOG_FILE="${SCRIPT_DIR}/pipeline.log"
# Discovery evidence is append-only: candidates are retained even when verification
# later rejects them, so a "miss" can be audited instead of disappearing.
CANDIDATE_LOG="${SCRIPT_DIR}/reports/discovery-candidates.jsonl"
COVERAGE_DIR="${SCRIPT_DIR}/reports/web-coverage"
mkdir -p "$(dirname "$CANDIDATE_LOG")" "$COVERAGE_DIR"
JUNK_DOMAINS="wix.com|wixpress.com|wordpress|sentry.io|sentry-next|cloudflare|example.com|squarespace|shopify|mailchimp|googleapis|google.com|gstatic|facebook|instagram|twitter|hubspot|sendgrid|zendesk|fontawesome.io"
# Owner's own emails — never add these as venue contacts
OWN_EMAILS="atdi1029@gmail.com|alexbarnettclassical@gmail.com|abar89251@gmail.com|alex@alexbarnettclassical.com"

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
    local tmpf="/tmp/pipeline_venue_detail.json"
    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$tmpf" 2>/dev/null
    KNOWN_EMAILS=$(python3 -c "
import json
try:
    with open('$tmpf') as f: d = json.load(f)
    emails = set()
    for c in d.get('contacts', []):
        if c.get('email'):
            # Skip deferred contacts so they get re-verified when ZB is available
            if c.get('verified') == 'deferred':
                continue
            emails.add(c['email'].lower())
    print('|||'.join(emails))
except Exception as e: print('', file=__import__('sys').stderr); print('')
" 2>/dev/null)
    KNOWN_NAMES=$(python3 -c "
import json
try:
    with open('$tmpf') as f: d = json.load(f)
    names = set()
    for c in d.get('contacts', []):
        if c.get('name'):
            names.add(c['name'].lower().strip())
    print('|||'.join(names))
except Exception as e: print('', file=__import__('sys').stderr); print('')
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

ZB_EXHAUSTED_FLAG="/tmp/pipeline_zb_paused_$$"
APOLLO_EXHAUSTED_FLAG="/tmp/pipeline_apollo_exhausted_$$"
MAX_APOLLO=${MAX_APOLLO:-300}  # Max Apollo credits per run (default 300, set MAX_APOLLO=N to override)
VENUE_DOMAIN=""  # Set per-venue in run_venue() — used by verify_and_push to filter off-domain emails
rm -f "$ZB_EXHAUSTED_FLAG" "$APOLLO_EXHAUSTED_FLAG" /tmp/pipeline_step1_fb.txt /tmp/pipeline_step1_ig.txt /tmp/pipeline_seen_orgs
log "[ZB SAFE] Guard enabled — default caps: ${ZB_MAX_PER_RUN:-5}/run, ${ZB_MAX_PER_DAY:-10}/day, reserve ${ZB_MIN_BALANCE:-500} credits (paid verification is OFF unless .env sets ZB_ENABLED=1)"

check_apollo_credits() {
    if [ -z "$APOLLO_API_KEY" ]; then return 0; fi
    if [ -f "$APOLLO_EXHAUSTED_FLAG" ]; then return 1; fi
    if [ "$APOLLO_CREDITS_USED" -ge "$MAX_APOLLO" ] 2>/dev/null; then
        log "  [STOP] Apollo credit cap reached ($APOLLO_CREDITS_USED / $MAX_APOLLO used this run). Skipping Apollo."
        echo "exhausted" > "$APOLLO_EXHAUSTED_FLAG"
        return 1
    fi
    log "  [APOLLO] Credits used this run: $APOLLO_CREDITS_USED / $MAX_APOLLO"
    return 0
}

check_zb_credits() {
    # Cost guard: this is a no-charge budget/balance check. A failed check pauses
    # paid verification only; website/social discovery must continue.
    if [ ! -x "$ZB_GUARD" ]; then
        log "  [ZB SAFE] Guard missing — paid ZeroBounce verification disabled"
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    local info
    info=$(python3 "$ZB_GUARD" budget --run-id "$ZB_RUN_ID" 2>/dev/null || true)
    if [ -z "$info" ]; then
        log "  [ZB SAFE] Could not read ZeroBounce budget — paid verification disabled (fail closed)"
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    local parsed allowed reason run_used run_limit day_used day_limit credits reserve
    parsed=$(printf '%s' "$info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\t".join(str(d.get(k,"")) for k in ("allowed","reason","run_used","run_limit","day_used","day_limit","credits_remaining","reserve")))' 2>/dev/null || true)
    IFS=$'\t' read -r allowed reason run_used run_limit day_used day_limit credits reserve <<< "$parsed"
    log "  [ZB SAFE] run ${run_used:-0}/${run_limit:-?}, today ${day_used:-0}/${day_limit:-?}, balance ${credits:-unknown}, reserve ${reserve:-?}"
    if [ "$allowed" != "True" ] && [ "$allowed" != "true" ]; then
        log "  [ZB SAFE] Paid verification paused: ${reason:-guard_denied}. Discovery will continue."
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    rm -f "$ZB_EXHAUSTED_FLAG"
    return 0
}


record_candidate() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5" disposition="$6" evidence_url="${7:-}"
    [ -z "$email" ] && return
    CANDIDATE_LOG="$CANDIDATE_LOG" python3 - "$email" "$venue_id" "$name" "$title" "$source" "$disposition" "$evidence_url" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
email, venue_id, name, title, source, disposition, evidence_url = sys.argv[1:8]
row = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "venue_id": venue_id,
    "email": email.lower().strip(),
    "name": name,
    "title": title,
    "source": source,
    "disposition": disposition,
    "evidence_url": evidence_url,
}
with open(os.environ["CANDIDATE_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF
}

verify_and_push() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5"
    if [ -z "$email" ]; then return; fi

    local email_lower
    email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]' | xargs)
    record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "discovered"

    if email_known "$email_lower"; then
        log "  [SKIP] $email_lower — already in sheet"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "already_known"
        return
    fi

    # Block owner's own emails from being added as contacts.
    if echo "$OWN_EMAILS" | tr '|' '\n' | grep -qi "^${email_lower}$" 2>/dev/null; then
        log "  [SKIP] $email_lower — owner's own email"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "owner_email"
        return
    fi

    # Hard-reject only addresses that are operational/non-contact mailboxes.
    # Role mailboxes such as events@, catering@, reservations@, info@, etc. are
    # retained and can be saved as generic venue contacts when they validate.
    local hard_reject="noreply@ no-reply@ webmaster@ billing@ dataremoval@ privacy@ careers@ jobs@ hr@ mailer-daemon@ postmaster@"
    for gp in $hard_reject; do
        if echo "$email_lower" | grep -q "^${gp}"; then
            log "  [SKIP] $email_lower — hard-reject prefix ($gp)"
            record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "hard_reject_prefix:$gp"
            return
        fi
    done

    local is_generic="false"
    local generic_prefixes="info@ hello@ contact@ sales@ events@ event@ privateevents@ private-events@ reservations@ booking@ bookings@ enquiries@ inquiries@ office@ general@ frontdesk@ reception@ support@ admin@ catering@ groups@ weddings@ meetings@"
    for gp in $generic_prefixes; do
        if echo "$email_lower" | grep -q "^${gp}"; then
            is_generic="true"
            log "  [GENERIC] $email_lower — retaining role mailbox ($gp)"
            break
        fi
    done

    # Off-domain is evidence to review, not an automatic rejection. Hospitality
    # groups, hotels, management companies, caterers, and parent brands often own
    # the real mailbox used by a venue.
    if [ -n "$VENUE_DOMAIN" ] && echo "$email_lower" | grep -q '@'; then
        local email_domain
        email_domain=$(echo "$email_lower" | awk -F'@' '{print tolower($2)}')
        local generic_domains="gmail.com yahoo.com outlook.com hotmail.com aol.com icloud.com"
        if ! echo "$generic_domains" | grep -qw "$email_domain"; then
            local vbase ebase
            vbase=$(echo "$VENUE_DOMAIN" | sed 's/\..*//')
            ebase=$(echo "$email_domain" | sed 's/\..*//')
            if [ "$email_domain" != "$VENUE_DOMAIN" ] && [ "$ebase" != "$vbase" ] && \
               ! echo "$vbase" | grep -qi "$ebase" && ! echo "$ebase" | grep -qi "$vbase"; then
                log "  [REVIEW] $email_lower — off-domain (venue: $VENUE_DOMAIN, source: $source); keeping as candidate"
                echo "FLAG:Off-domain email retained for review: $email_lower (domain $email_domain vs venue $VENUE_DOMAIN, source: $source)" >> /tmp/pipeline_flags.txt
                record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "off_domain_retained"
            fi
        fi
    fi

    # Per-venue cap check
    if [ "$ZB_VENUE_CREDITS" -ge "$MAX_ZB_PER_VENUE" ] 2>/dev/null; then
        log "  [ZB SAFE] Venue cap reached ($ZB_VENUE_CREDITS/$MAX_ZB_PER_VENUE) — saving unverified"
        zb_status="deferred"
        zb_reason="venue_cap_reached"
    fi

    # Every paid lookup goes through the persistent cost guard. Cache hits cost
    # zero credits; new lookups are blocked by per-run/day caps and reserve floor.
    local zb_json zb_status zb_reason zb_charged zb_cached zb_run_used zb_run_limit zb_day_used zb_day_limit
    if [ "$zb_status" = "deferred" ] 2>/dev/null; then
        # Already hit venue cap — skip to save
        :
    elif [ ! -x "$ZB_GUARD" ]; then
        log "  [ZB SAFE] Guard missing — deferring $email_lower rather than spending"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "verification_deferred_guard_missing"
        return
    fi
    zb_json=$(python3 "$ZB_GUARD" verify "$email_lower" --source "$source" --run-id "$ZB_RUN_ID" 2>/dev/null || true)
    if [ -z "$zb_json" ]; then
        log "  [ZB SAFE] Guard failed — deferring $email_lower (no direct API fallback)"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "verification_deferred_guard_error"
        return
    fi
    local zb_parsed
    zb_parsed=$(printf '%s' "$zb_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\t".join(str(d.get(k,"")) for k in ("status","reason","charged","cached","run_used","run_limit","day_used","day_limit")))' 2>/dev/null || true)
    IFS=$'\t' read -r zb_status zb_reason zb_charged zb_cached zb_run_used zb_run_limit zb_day_used zb_day_limit <<< "$zb_parsed"
    [ -z "$zb_status" ] && zb_status="deferred"
    # Track per-venue credits
    if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then
        ZB_VENUE_CREDITS=$((ZB_VENUE_CREDITS + 1))
    fi
    log "  [ZB SAFE] $email_lower → $zb_status (${zb_reason:-unknown}; charged=${zb_charged:-False}; cache=${zb_cached:-False}; venue ${ZB_VENUE_CREDITS}/${MAX_ZB_PER_VENUE}; run ${zb_run_used:-0}/${zb_run_limit:-?})"

    if [ "$zb_status" = "deferred" ] || [ "$zb_status" = "pending" ]; then
        case "$zb_reason" in
            run_budget_reached|day_budget_reached|reserve_reached|credit_check_failed)
                echo "paused" > "$ZB_EXHAUSTED_FLAG"
                ;;
        esac
        # Save deferred contacts to the sheet as unverified — verify later when credits available
        local save_name="$name"
        if [ -z "$save_name" ] || [ "$save_name" = "None" ]; then
            save_name=$(python3 - "$email_lower" <<'PYEOF'
import re, sys
local = sys.argv[1].split('@',1)[0]
local = re.sub(r'[-_.]+', ' ', local).strip()
print(' '.join(w.capitalize() for w in local.split()) or sys.argv[1])
PYEOF
)
        fi
        local encoded
        encoded=$(python3 - "$venue_id" "$save_name" "$title" "$email_lower" "$source" "deferred" "$is_generic" <<'PYEOF'
import sys, urllib.parse
venue_id, name, title, email, source, verified, is_generic = sys.argv[1:8]
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': venue_id,
    'name': name,
    'title': title,
    'email': email,
    'source': source,
    'verified': verified,
    'is_generic': is_generic,
}))
PYEOF
)
        local api_response
        api_response=$(curl -sL "${APPS_SCRIPT_URL}?${encoded}")
        local api_ok
        api_ok=$(echo "$api_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('status') == 'ok' else 'no')" 2>/dev/null || echo "no")
        if [ "$api_ok" = "yes" ]; then
            log "  ✓ Saved (unverified): ${save_name:-$email_lower} <$email_lower>"
            KNOWN_EMAILS="${KNOWN_EMAILS}|||${email_lower}"
            echo "1" >> /tmp/pipeline_contacts_count
        else
            log "  [API ERROR] Could not save deferred contact: ${save_name:-$email_lower} <$email_lower>"
        fi
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "saved_deferred:${zb_reason:-unknown}"
        return
    fi


    if [ "$zb_status" = "valid" ]; then
        local save_name="$name"
        if [ -z "$save_name" ] || [ "$save_name" = "None" ]; then
            save_name=$(python3 - "$email_lower" <<'PYEOF'
import re, sys
local = sys.argv[1].split('@',1)[0]
local = re.sub(r'[-_.]+', ' ', local).strip()
print(' '.join(w.capitalize() for w in local.split()) or sys.argv[1])
PYEOF
)
        fi
        local encoded
        encoded=$(python3 - "$venue_id" "$save_name" "$title" "$email_lower" "$source" "$zb_status" "$is_generic" <<'PYEOF'
import sys, urllib.parse
venue_id, name, title, email, source, verified, is_generic = sys.argv[1:8]
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': venue_id,
    'name': name,
    'title': title,
    'email': email,
    'source': source,
    'verified': verified,
    'is_generic': is_generic,
}))
PYEOF
)
        local api_response
        api_response=$(curl -sL "${APPS_SCRIPT_URL}?${encoded}")
        local api_ok
        api_ok=$(echo "$api_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('status') == 'ok' else 'no')" 2>/dev/null || echo "no")
        if [ "$api_ok" != "yes" ]; then
            log "  [API ERROR] Contact was not saved: ${save_name:-$email_lower} <$email_lower>"
            record_candidate "$email_lower" "$venue_id" "$save_name" "$title" "$source" "api_save_failed"
            return
        fi

        local readback_ok
        readback_ok=$(curl -sL --max-time 10 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | \
            EMAIL_TO_CHECK="$email_lower" python3 -c "import json,os,sys; d=json.load(sys.stdin); target=os.environ['EMAIL_TO_CHECK']; print('yes' if any((c.get('email') or '').lower()==target for c in d.get('contacts',[])) else 'no')" 2>/dev/null || echo "no")
        if [ "$readback_ok" != "yes" ]; then
            log "  [API ERROR] Contact write could not be verified: ${save_name:-$email_lower} <$email_lower>"
            record_candidate "$email_lower" "$venue_id" "$save_name" "$title" "$source" "api_readback_failed"
            return
        fi

        log "  ✓ Added and verified: ${save_name:-$email_lower} <$email_lower>"
        record_candidate "$email_lower" "$venue_id" "$save_name" "$title" "$source" "saved_valid"
        echo "1" >> /tmp/pipeline_contacts_count
        KNOWN_EMAILS="${KNOWN_EMAILS}|||${email_lower}"
        if [ -n "$name" ]; then
            KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$name" | tr '[:upper:]' '[:lower:]')"
        fi
    else
        log "  [CANDIDATE] $email_lower — ZeroBounce status is $zb_status; retained for review"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "verification:$zb_status"
    fi
    if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then sleep 1; fi
}

# =================================================================
# STEP 1: WEBSITE SCRAPE (Chrome-based for JS-rendered sites)
# =================================================================
step1_website() {
    local venue="$1" venue_id="$2" website="$3" city="$4"
    log ""
    log "========== STEP 1: Website Scrape =========="

    if [ -z "$website" ]; then
        log "  [SKIP] No website URL"
        return
    fi

    # Corporate hotel/property pages are still valuable website evidence. They often
    # expose property-specific Facebook/Instagram, weddings, meetings, and catering
    # contacts even when Apollo has corporate people. Never skip the web crawl here.
    local corp_hotels="hilton.com marriott.com hyatt.com ihg.com fourseasons.com ritzcarlton.com starwoodhotels.com wyndhamhotels.com choicehotels.com bestwestern.com radissonhotels.com omnihotels.com loewshotels.com"
    local site_domain=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${website}').netloc.replace('www.',''))" 2>/dev/null)
    for corp in $corp_hotels; do
        if [ "$site_domain" = "$corp" ]; then
            log "  [WEB] Corporate hotel domain ($corp) — crawling property page instead of skipping"
            break
        fi
    done

    log "  URL: $website"

    # JS to extract emails with names/titles (from mailto hrefs + body text), social links, and internal page links
    cat > /tmp/pipeline_website_scrape.js << 'JSEOF'
(function(){
var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk','fontawesome.io'];
var contacts = {};

function titleCase(s){
    return s.toLowerCase().replace(/(?:^|\s)\S/g, function(a){return a.toUpperCase();});
}

// Extract name+title from context text around a mailto link
function parseContext(ctx, email){
    var lines = ctx.split('\n').map(function(l){return l.trim();}).filter(function(l){return l.length > 0;});
    var name = '', title = '';
    for(var i=0;i<lines.length;i++){
        var line = lines[i];
        if(line.toLowerCase().indexOf('@') > -1) continue;
        if(line.match(/^\d/) || line.match(/^[\(\+]/)) continue;
        if(line.match(/^(CONTACT|MAIN PHONE|RECIPROCAL|CLUB MANAGEMENT|PLEASE)/i)) continue;
        if(!name){
            if(line.length > 2 && line.length < 50) name = titleCase(line);
        } else if(!title){
            if(line.length > 2 && line.length < 80) title = titleCase(line);
            break;
        }
    }
    return {name:name, title:title};
}

function isJunk(e){
    for(var j=0;j<junk.length;j++){ if(e.indexOf(junk[j])>-1) return true; }
    return e.length > 60;
}

// 1. Emails from mailto: hrefs — with name/title from surrounding context
var mailtoLinks = document.querySelectorAll('a[href^="mailto:"]');
for(var i=0;i<mailtoLinks.length;i++){
    var a = mailtoLinks[i];
    var href = a.getAttribute('href') || '';
    var addr = href.replace('mailto:','').split('?')[0].trim().toLowerCase();
    if(addr.indexOf('@') < 1 || isJunk(addr)) continue;
    if(!contacts[addr]){
        var parent = a.closest('tr') || a.closest('li') || a.closest('div') || a.parentElement;
        var ctx = parent ? parent.innerText.trim().substring(0,300) : '';
        var parsed = parseContext(ctx, addr);
        contacts[addr] = {email:addr, name:parsed.name, title:parsed.title};
    }
}

// 2. Cloudflare email-protected addresses (XOR cipher decode)
var cfProtected = document.querySelectorAll('[data-cfemail]');
for(var i=0;i<cfProtected.length;i++){
    var enc = cfProtected[i].getAttribute('data-cfemail');
    if(!enc) continue;
    var key = parseInt(enc.substr(0,2),16);
    var decoded = '';
    for(var j=2;j<enc.length;j+=2){
        decoded += String.fromCharCode(parseInt(enc.substr(j,2),16)^key);
    }
    decoded = decoded.toLowerCase().trim();
    if(decoded.indexOf('@')>0 && !isJunk(decoded) && !contacts[decoded]){
        var parent = cfProtected[i].closest('tr') || cfProtected[i].closest('li') || cfProtected[i].closest('div') || cfProtected[i].parentElement;
        var ctx = parent ? parent.innerText.trim().substring(0,300) : '';
        var parsed = parseContext(ctx, decoded);
        contacts[decoded] = {email:decoded, name:parsed.name, title:parsed.title};
    }
}

// 3. Emails from visible text (no name/title available)
var text = document.body.innerText || '';
var imgExts = /\.(png|jpg|jpeg|gif|svg|webp|bmp|ico|pdf|doc|docx|xls|xlsx|csv|zip|mp3|mp4|mov|avi)$/i;
var textMatches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
textMatches.forEach(function(e){
    var el = e.toLowerCase();
    if(!isJunk(el) && !imgExts.test(el) && !contacts[el]) contacts[el] = {email:el, name:'', title:''};
});

// 4. Emails from all href attributes
var allLinks = document.querySelectorAll('a[href]');
for(var i=0;i<allLinks.length;i++){
    var h = allLinks[i].getAttribute('href') || '';
    var m = h.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/);
    if(m){
        var el = m[0].toLowerCase();
        if(!isJunk(el) && !contacts[el]) contacts[el] = {email:el, name:'', title:''};
    }
}

// 5. Emails from schema.org structured data — recurse through @graph,
// contactPoint arrays, nested organizations/people, and arbitrary string values.
function walkStructured(node){
    if(node === null || node === undefined) return;
    if(typeof node === 'string'){
        var matches = node.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
        for(var j=0;j<matches.length;j++){
            var se = matches[j].toLowerCase().replace('mailto:','').trim();
            if(se.indexOf('@')>0 && !isJunk(se) && !contacts[se]) contacts[se] = {email:se, name:'', title:''};
        }
        return;
    }
    if(Array.isArray(node)){ for(var j=0;j<node.length;j++) walkStructured(node[j]); return; }
    if(typeof node === 'object'){ for(var k in node){ if(Object.prototype.hasOwnProperty.call(node,k)) walkStructured(node[k]); } }
}
var schemas = document.querySelectorAll('script[type="application/ld+json"]');
for(var i=0;i<schemas.length;i++){
    try { walkStructured(JSON.parse(schemas[i].textContent)); } catch(e){}
}

// 6. Search hidden DOM / hydration / data attributes too. innerText misses
// accordion content, modal bodies, and client-side data present in the DOM.
var rawDom = document.documentElement ? (document.documentElement.textContent + '\n' + document.documentElement.outerHTML) : '';
var rawMatches = rawDom.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
rawMatches.forEach(function(e){
    var el = e.toLowerCase();
    if(!isJunk(el) && !imgExts.test(el) && !contacts[el]) contacts[el] = {email:el, name:'', title:''};
});

var contactList = Object.keys(contacts).map(function(k){return contacts[k];});

// Helper: extract social link from a set of elements
function extractFb(links){
    var SKIP = ['tr','pixel','plugins','sharer','share','login','dialog','policy.php','policy','terms','terms.php','about','legal','cookies','r.php','recover','profile.php','help','privacy','settings','pages','ads','business'];
    for(var i=0;i<links.length;i++){
        var u = links[i].getAttribute('href').split('?')[0].replace(/\/$/,'');
        if(u.startsWith('//')) u = 'https:' + u;
        var slug = u.split('facebook.com/')[1] || '';
        if(SKIP.indexOf(slug) > -1) continue;
        if(u.indexOf('sharer') > -1 || u.indexOf('share') > -1) continue;
        if(/^\d+$/.test(slug)) continue;
        if(slug.length >= 3) return u;
    }
    return '';
}
function extractIg(links){
    var IG_SKIP = ['p','reel','reels','explore','stories','accounts','developer','about','legal','privacy','terms','share','embed',
                   'squarespace','wix','wordpress','shopify','godaddy','weebly','webflow','carrd','linktree','linktr'];
    for(var i=0;i<links.length;i++){
        var u = links[i].getAttribute('href').split('?')[0].replace(/\/$/,'');
        if(u.startsWith('//')) u = 'https:' + u;
        var igSlug = u.split('instagram.com/')[1] || '';
        if(igSlug.length < 2) continue;
        if(IG_SKIP.indexOf(igSlug) > -1) continue;
        if(/^\d+$/.test(igSlug)) continue;
        if(u.indexOf('share') === -1) return u;
    }
    return '';
}

// Facebook + Instagram URLs — search header/footer/nav FIRST, then full page
var priorityZones = 'header, footer, nav, [role=banner], [role=contentinfo], .footer, .header, .site-footer, .site-header, #footer, #header';
var fb = extractFb(document.querySelectorAll(priorityZones + ' a[href*="facebook.com"]'));
var ig = extractIg(document.querySelectorAll(priorityZones + ' a[href*="instagram.com"]'));
// Fallback to full page only if priority zones found nothing
if(!fb) fb = extractFb(document.querySelectorAll('a[href*="facebook.com"]'));
if(!ig) ig = extractIg(document.querySelectorAll('a[href*="instagram.com"]'));

// Fallback: scan raw HTML for facebook/instagram URLs (catches Wix/JS-rendered links
// where href is a redirect URL or set via data attributes / onclick handlers)
var SKIP_FB_SLUGS = ['tr','pixel','plugins','sharer','share','login','dialog',
    'policy.php','policy','terms','terms.php','about','legal','cookies',
    'r.php','recover','profile.php','help','privacy','settings','pages','ads','business'];
if(!fb){
    var rawHtml = document.documentElement.outerHTML;
    var fbRaw = rawHtml.match(/https?:\/\/(?:www\.)?facebook\.com\/[A-Za-z0-9._\-]+/g) || [];
    for(var i=0;i<fbRaw.length;i++){
        var u = fbRaw[i].split('?')[0].replace(/\/$/,'');
        var slug = u.split('facebook.com/')[1] || '';
        if(SKIP_FB_SLUGS.indexOf(slug) > -1) continue;
        if(u.indexOf('sharer') > -1 || u.indexOf('share') > -1) continue;
        if(/^\d+$/.test(slug)) continue;
        if(slug.length >= 3){ fb = u; break; }
    }
}
if(!ig){
    var rawHtml2 = document.documentElement.outerHTML;
    var igRaw = rawHtml2.match(/https?:\/\/(?:www\.)?instagram\.com\/[A-Za-z0-9._\-]+/g) || [];
    for(var i=0;i<igRaw.length;i++){
        var u = igRaw[i].split('?')[0].replace(/\/$/,'');
        var igSlug2 = u.split('instagram.com/')[1] || '';
        if(igSlug2.length < 2) continue;
        if(/^\d+$/.test(igSlug2)) continue;
        if(['p','reel','reels','explore','stories','accounts','developer','about','legal','privacy','terms','embed'].indexOf(igSlug2) > -1) continue;
        if(u.indexOf('share') === -1){ ig = u; break; }
    }
}

// Internal links — preserve meaningful query strings and hash states. A hash can
// open a tab/accordion on JS sites, so /events#events-cta is not discarded.
var base = location.origin;
var subpages = [];
var seen = {};
function normalizeInternal(h){
    try {
        var u = new URL(h, location.href);
        if(u.origin !== base) return '';
        ['utm_source','utm_medium','utm_campaign','utm_term','utm_content','fbclid','gclid'].forEach(function(k){u.searchParams.delete(k);});
        var out = u.href;
        if(!u.hash && u.pathname !== '/') out = out.replace(/\/$/,'');
        return out;
    } catch(e){ return ''; }
}
seen[normalizeInternal(location.href)] = true;

// 1. All internal links from navigation surfaces.
var navLinks = document.querySelectorAll('nav a[href], header a[href], footer a[href], [role="navigation"] a[href], .menu a[href], .nav a[href], #menu a[href], #nav a[href]');
for(var i=0;i<navLinks.length;i++){
    var h = navLinks[i].getAttribute('href') || '';
    if(h.startsWith('mailto:') || h.startsWith('tel:') || h === '#') continue;
    var full = normalizeInternal(h);
    if(!full || seen[full]) continue;
    seen[full] = true;
    subpages.push(full);
}

// 2. Keyword-matched links anywhere on the page. Match URL + anchor text so a
// generic href such as /page/123 with text "Private Events" still wins.
var keywords = ['event','private','wedding','cater','contact','about','entertain','music','banquet','dining','party','book','ticket','team','staff','press','news','media','rental','meeting','corporate','wine-club','wine_club','live-music','reserv','hire','inquiry','enquiry','group','sales'];
var allAnchors = document.querySelectorAll('a[href]');
for(var i=0;i<allAnchors.length;i++){
    var h = allAnchors[i].getAttribute('href') || '';
    if(h.startsWith('mailto:') || h.startsWith('tel:')) continue;
    var full = normalizeInternal(h);
    if(!full || seen[full]) continue;
    var hay = (full + ' ' + (allAnchors[i].textContent||'') + ' ' + (allAnchors[i].getAttribute('aria-label')||'')).toLowerCase();
    for(var k=0;k<keywords.length;k++){
        if(hay.indexOf(keywords[k]) > -1){ seen[full] = true; subpages.push(full); break; }
    }
}

// Contact form URL — check discovered links AND buttons/anchors with contact text
var contactKw = ['contact','get-in-touch','reach-us','inquiry','enquiry'];
var assetExt = ['.css','.js','.png','.jpg','.jpeg','.gif','.svg','.ico','.woff','.woff2','.ttf','.eot','.map','.xml','.pdf'];
var contactForm = '';
Object.keys(seen).forEach(function(url){
    var p = url.toLowerCase().split('?')[0];
    // Skip static assets (CSS, JS, images, fonts)
    for(var a=0;a<assetExt.length;a++){ if(p.endsWith(assetExt[a])) return; }
    for(var c=0;c<contactKw.length;c++){
        if(p.indexOf(contactKw[c]) > -1){ contactForm = url; return; }
    }
});
// Also check all links/buttons on page for contact text (catches JS-rendered buttons)
if(!contactForm){
    var allClickable = document.querySelectorAll('a[href], button');
    for(var i=0;i<allClickable.length;i++){
        var el = allClickable[i];
        var txt = (el.textContent||'').trim().toLowerCase();
        var href = (el.getAttribute('href')||'').toLowerCase();
        if(txt.match(/^contact\s*(us)?$/) || href.indexOf('contact') > -1){
            var full = el.getAttribute('href')||'';
            if(full && full !== '#'){
                try { contactForm = new URL(full, base).href; } catch(e){ contactForm = full; }
            } else {
                contactForm = location.href + '#contact';
            }
            break;
        }
    }
}

return JSON.stringify({contacts:contactList, facebook:fb, instagram:ig, contact_form:contactForm, subpages:subpages});
})()
JSEOF

    # Clean up stale temp files from any previous venue
    rm -f /tmp/pipeline_contact_page_scrape.json

    # Open website in Chrome and scrape
    log "  Opening in Chrome: $website"
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${website}\""
    sleep 10

    local scrape_result
    scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)

    if [ -z "$scrape_result" ] || [ "$scrape_result" = "missing value" ]; then
        log "  [WARN] Chrome scrape returned empty — trying with longer wait (18s for JS-heavy sites)"
        sleep 18
        scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
    fi

    if [ -z "$scrape_result" ] || [ "$scrape_result" = "missing value" ]; then
        log "  [WARN] Chrome scrape failed — trying curl fallback..."
        local curl_html
        curl_html=$(curl -sL --compressed --max-time 10 "$website" 2>/dev/null)
        if [ -n "$curl_html" ]; then
            # Extract emails, social links, and subpages from raw HTML via Python
            scrape_result=$(python3 -c "
import re, json, sys
from urllib.parse import urljoin, urlparse

html = sys.stdin.read()
base = '${website}'
base_origin = urlparse(base).scheme + '://' + urlparse(base).netloc

# Emails — from mailto: hrefs and visible text
emails = set()
# Mailto links
for m in re.findall(r'mailto:([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})', html):
    emails.add(m.lower())
# Cloudflare encoded emails
for enc in re.findall(r'data-cfemail=\"([a-f0-9]+)\"', html):
    key = int(enc[:2], 16)
    decoded = ''.join(chr(int(enc[i:i+2], 16) ^ key) for i in range(2, len(enc), 2))
    if '@' in decoded:
        emails.add(decoded.lower())
# Plain text emails (strip HTML tags first)
text = re.sub(r'<[^>]+>', ' ', html)
for m in re.findall(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', text):
    e = m.lower()
    if not re.search(r'\.(png|jpg|jpeg|gif|svg|webp|ico|pdf|css|js)$', e):
        emails.add(e)

# Junk filter
junk_kw = ['noreply','no-reply','mailer-daemon','postmaster','webmaster','sentry','info@','hello@','contact@','enquiries@','inquiries@','reservations@',
           'wix.com','squarespace','mailchimp','sendgrid','amazonaws']
contacts = []
for e in emails:
    if not any(j in e for j in junk_kw) and len(e) < 60:
        contacts.append({'email': e, 'name': '', 'title': ''})

# Facebook + Instagram
fb = ''
ig = ''
FB_SKIP = {'tr','pixel','plugins','sharer','share','login','dialog','pages','ads','business','policy','terms','about','legal','privacy','settings','help','recover','cookies'}
for m in re.findall(r'https?://(?:www\.)?facebook\.com/[a-zA-Z0-9._\-]+', html):
    clean = m.split('?')[0].rstrip('/')
    slug = clean.split('facebook.com/')[-1] if 'facebook.com/' in clean else ''
    if slug in FB_SKIP: continue
    if slug.isdigit(): continue
    if '/sharer' in m: continue
    if len(slug) >= 3:
        fb = clean
        break
IG_SKIP = {'p','reel','reels','explore','stories','accounts','developer','about','legal','privacy','terms','embed',
           'squarespace','wix','wordpress','shopify','godaddy','weebly','webflow','carrd','linktree','linktr'}
for m in re.findall(r'https?://(?:www\.)?instagram\.com/[a-zA-Z0-9._]+', html):
    clean = m.split('?')[0].rstrip('/')
    slug = clean.split('instagram.com/')[-1] if 'instagram.com/' in clean else ''
    if slug in IG_SKIP: continue
    if slug.isdigit(): continue
    if '/share' in m: continue
    if len(slug) >= 2:
        ig = clean
        break

# Subpages — internal links
seen = set()
subpages = []
for href in re.findall(r'href=[\"\\']([^\"\\']+)[\"\\']', html):
    try:
        full = urljoin(base, href).rstrip('/')
    except:
        continue
    if full.startswith(base_origin) and full not in seen and full != base.rstrip('/'):
        seen.add(full)
        subpages.append(full)

# Contact form — check URLs first, then inline <form> tags
contact_form = ''
ASSET_EXT = ('.css', '.js', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.ico',
             '.woff', '.woff2', '.ttf', '.eot', '.map', '.xml', '.pdf')
for url in seen:
    url_lower = url.lower().split('?')[0]  # strip query params
    if url_lower.endswith(ASSET_EXT):
        continue
    if any(kw in url_lower for kw in ['contact','get-in-touch','reach-us','inquiry','enquiry']):
        contact_form = url
        break
# If no contact URL found, check for inline modal/embedded contact forms
if not contact_form:
    # Match forms with contact-related ids, classes, names, or actions
    form_patterns = [
        r'<form[^>]*(?:id|class|name)=[\"\\'][^\"\\']*contact[^\"\\']*[\"\\']',
        r'<form[^>]*action=[\"\\'][^\"\\']*contact[^\"\\']*[\"\\']',
        r'<form[^>]*(?:id|class|name)=[\"\\'][^\"\\']*inquir[^\"\\']*[\"\\']',
        r'<form[^>]*(?:id|class|name)=[\"\\'][^\"\\']*get-in-touch[^\"\\']*[\"\\']',
    ]
    for pat in form_patterns:
        if re.search(pat, html, re.I):
            contact_form = base + '#contact-form'
            break

print(json.dumps({'contacts': contacts, 'facebook': fb, 'instagram': ig, 'contact_form': contact_form, 'subpages': subpages}))
" <<< "$curl_html" 2>/dev/null)
            if [ -n "$scrape_result" ] && [ "$scrape_result" != "null" ]; then
                log "  [CURL FALLBACK] Success — parsed HTML directly"
            else
                log "  [ERROR] Both Chrome and curl fallback failed. Skipping website."
                return
            fi
        else
            log "  [ERROR] Both Chrome and curl failed. Skipping website."
            return
        fi
    fi

    echo "$scrape_result" > /tmp/pipeline_scrape.json

    # Parse main page results
    local email_count fb ig contact_form
    email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_scrape.json')); print(len(d.get('contacts',d.get('emails',[]))))" 2>/dev/null || echo "0")
    fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['facebook'])" 2>/dev/null)
    ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['instagram'])" 2>/dev/null)
    contact_form=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('contact_form',''))" 2>/dev/null)

    # If page returned nothing useful, likely didn't render — retry with longer wait
    if [ "$email_count" = "0" ] && [ -z "$fb" -o "$fb" = "None" -o "$fb" = "" ] && [ -z "$ig" -o "$ig" = "None" -o "$ig" = "" ]; then
        log "  [WARN] Page returned 0 emails + 0 social — likely didn't render. Retrying with 12s wait..."
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${website}\""
        sleep 12
        scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
        if [ -n "$scrape_result" ] && [ "$scrape_result" != "missing value" ]; then
            echo "$scrape_result" > /tmp/pipeline_scrape.json
            email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_scrape.json')); print(len(d.get('contacts',d.get('emails',[]))))" 2>/dev/null || echo "0")
            fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['facebook'])" 2>/dev/null)
            ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['instagram'])" 2>/dev/null)
            contact_form=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('contact_form',''))" 2>/dev/null)
        fi
    fi

    # Validate contact form — actually visit the page and check for a real <form> with <textarea> or message input
    if [ -n "$contact_form" ] && [ "$contact_form" != "None" ] && [ "$contact_form" != "" ]; then
        log "  Validating contact form URL: $contact_form"
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${contact_form}\"" 2>/dev/null
        sleep 4
        local has_form
        has_form=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "
(function(){
  // 1. Look for any form with a textarea or email/text input (CF7, Formidable, Gravity, WPForms etc.)
  var forms = document.querySelectorAll(\"form\");
  for(var i=0;i<forms.length;i++){
    var f=forms[i];
    if(f.querySelector(\"textarea\") ||
       f.querySelector(\"input[type=email]\") ||
       f.querySelector(\"input[type=text]\") ||
       f.querySelector(\"input[type=tel]\")) return \"yes\";
  }
  // 2. Detect WordPress form plugin signatures in the DOM even if form not yet rendered
  var src = document.documentElement.innerHTML;
  if(src.indexOf(\"wpcf7\") > -1 ||
     src.indexOf(\"formidable\") > -1 ||
     src.indexOf(\"gform_\") > -1 ||
     src.indexOf(\"wpforms\") > -1 ||
     src.indexOf(\"ninja-forms\") > -1 ||
     src.indexOf(\"fluentform\") > -1) return \"yes\";
  return \"no\";
})()"' 2>/dev/null)
        # Always scrape the contact page for emails (even if no form found)
        local cf_result
        cf_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
        if [ -n "$cf_result" ] && [ "$cf_result" != "missing value" ]; then
            echo "$cf_result" > /tmp/pipeline_contact_page_scrape.json
            local cf_email_count
            cf_email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_contact_page_scrape.json')); print(len(d.get('contacts',[])))" 2>/dev/null || echo "0")
            if [ "$cf_email_count" != "0" ]; then
                local cf_emails
                cf_emails=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_contact_page_scrape.json')); print(', '.join(c['email'] for c in d.get('contacts',[])))" 2>/dev/null)
                log "  Found on contact page: $cf_emails"
            fi
            # Social icons are often only on /contact or in a contact-page footer.
            # Do not throw those away just because the homepage had none.
            local cf_fb cf_ig
            cf_fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_contact_page_scrape.json')).get('facebook',''))" 2>/dev/null)
            cf_ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_contact_page_scrape.json')).get('instagram',''))" 2>/dev/null)
            if ([ -z "$fb" ] || [ "$fb" = "None" ]) && echo "$cf_fb" | grep -qi 'facebook\.com'; then
                fb="$cf_fb"
                log "  [SOCIAL] Facebook recovered from contact page: $fb"
            fi
            if ([ -z "$ig" ] || [ "$ig" = "None" ]) && echo "$cf_ig" | grep -qi 'instagram\.com'; then
                ig="$cf_ig"
                log "  [SOCIAL] Instagram recovered from contact page: $ig"
            fi
        fi
        if [ "$has_form" != "yes" ]; then
            # Keep the URL if it looks like a contact page — Wix/JS sites
            # won't render forms for the validator but the URL is still useful
            if echo "$contact_form" | grep -qiE '/contact|/inquir|/book|/event'; then
                log "  ⚠ No rendered form found — keeping URL (likely JS/Wix site)"
            else
                log "  ✗ No submittable form found — clearing contact_form"
                contact_form=""
            fi
        else
            log "  ✓ Real contact form confirmed"
        fi
    fi

    log "  Emails: $email_count | FB: ${fb:-none} | IG: ${ig:-none} | Contact Form: ${contact_form:-none}"

    # --- Location-page detection for multi-location/chain venues ---
    # If we got 0 emails and the venue has a city, try to find the location-specific page
    if [ "$email_count" = "0" ] && [ -n "$city" ] && [ "$city" != "None" ]; then
        log "  [LOCATION] Checking for location-specific page (city: $city)..."
        local city_slug
        city_slug=$(python3 -c "print('${city}'.lower().replace(' ','-').replace('.',''))" 2>/dev/null)
        local base_domain
        base_domain=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${website}').scheme + '://' + urlparse('${website}').netloc)" 2>/dev/null)

        # Try common location URL patterns
        local loc_found=""
        for pattern in "/${city_slug}/" "/locations/${city_slug}/" "/locations/${city_slug}" "/${city_slug}"; do
            local try_url="${base_domain}${pattern}"
            local http_code
            http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 5 "$try_url" 2>/dev/null)
            if [ "$http_code" = "200" ]; then
                log "  [LOCATION] Found: $try_url"
                loc_found="$try_url"
                break
            fi
        done

        # If URL patterns didn't work, scan page links for city name
        if [ -z "$loc_found" ]; then
            loc_found=$(python3 -c "
import json
city = '${city}'.lower()
d = json.load(open('/tmp/pipeline_scrape.json'))
for url in d.get('subpages', []):
    if city.replace(' ','-') in url.lower() or city.replace(' ','') in url.lower():
        print(url)
        break
# Also check all links on the page
import re
for url in list(set(re.findall(r'https?://[^\s\"<>]+', json.dumps(d)))):
    if city.replace(' ','-') in url.lower() and url.startswith('${base_domain}'):
        print(url)
        break
" 2>/dev/null | head -1)
        fi

        if [ -n "$loc_found" ]; then
            log "  [LOCATION] Re-scraping location page: $loc_found"
            # NOTE: Do NOT update venue website — keep the original root URL.
            # Only use the location page for additional scraping.

            # Re-scrape the location page
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${loc_found}\""
            sleep 6
            scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
            if [ -n "$scrape_result" ] && [ "$scrape_result" != "missing value" ]; then
                echo "$scrape_result" > /tmp/pipeline_scrape.json
                email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_scrape.json')); print(len(d.get('contacts',d.get('emails',[]))))" 2>/dev/null || echo "0")
                local loc_fb loc_ig loc_contact_form
                loc_fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('facebook',''))" 2>/dev/null)
                loc_ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('instagram',''))" 2>/dev/null)
                loc_contact_form=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('contact_form',''))" 2>/dev/null)
                if ([ -z "$fb" ] || [ "$fb" = "None" ]) && echo "$loc_fb" | grep -qi 'facebook\.com'; then fb="$loc_fb"; fi
                if ([ -z "$ig" ] || [ "$ig" = "None" ]) && echo "$loc_ig" | grep -qi 'instagram\.com'; then ig="$loc_ig"; fi
                if [ -n "$loc_contact_form" ] && [ "$loc_contact_form" != "None" ]; then contact_form="$loc_contact_form"; fi
                log "  [LOCATION] Re-scraped: Emails: $email_count | FB: ${fb:-none} | IG: ${ig:-none} | Contact Form: ${contact_form:-none}"
            fi
        else
            log "  [LOCATION] No location-specific page found"
        fi
    fi

    # Collect all contacts (email|name|title) from main page + subpages
    # Format: email|||name|||title per line
    python3 -c "
import json
d = json.load(open('/tmp/pipeline_scrape.json'))
for c in d.get('contacts', []):
    print(c['email'] + '|||' + c.get('name','') + '|||' + c.get('title',''))
" 2>/dev/null > /tmp/pipeline_all_contacts.txt

    # Append contact page emails (scraped during form validation)
    if [ -f /tmp/pipeline_contact_page_scrape.json ]; then
        python3 -c "
import json
d = json.load(open('/tmp/pipeline_contact_page_scrape.json'))
for c in d.get('contacts', []):
    print(c['email'] + '|||' + c.get('name','') + '|||' + c.get('title',''))
" 2>/dev/null >> /tmp/pipeline_all_contacts.txt
        rm -f /tmp/pipeline_contact_page_scrape.json
    fi

    # --- Website-wide recursive discovery audit ---
    # The browser homepage crawl is intentionally supplemented by a deterministic,
    # bounded recursive crawl. This catches second/third-hop pages, sitemap-only URLs,
    # PDFs, plain-text/obfuscated emails, and social links that are not on the homepage.
    local safe_venue_id static_crawl_json coverage_file
    safe_venue_id=$(echo "$venue_id" | tr -cd '[:alnum:]_.-')
    [ -z "$safe_venue_id" ] && safe_venue_id="venue"
    static_crawl_json="/tmp/pipeline_static_crawl_${safe_venue_id}.json"
    coverage_file="${COVERAGE_DIR}/${safe_venue_id}.json"
    rm -f "$static_crawl_json"

    if [ -f "${SCRIPT_DIR}/site_discovery.py" ]; then
        log "  [DISCOVERY] Recursive crawl + sitemap/PDF audit (max 40 pages, depth 3)..."
        python3 "${SCRIPT_DIR}/site_discovery.py" static-crawl "$website" --max-pages 40 --max-depth 3 > "$static_crawl_json" 2>/dev/null || true
        if python3 - "$static_crawl_json" >/dev/null 2>&1 <<'PYEOF'
import json, sys
json.load(open(sys.argv[1]))
PYEOF
        then
            # Persist an auditable coverage artifact for this venue.
            python3 - "$static_crawl_json" "$coverage_file" "$venue_id" "$venue" "$website" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
src, dst, venue_id, venue, website = sys.argv[1:6]
d = json.load(open(src))
d["venue_id"] = venue_id
d["venue_name"] = venue
d["requested_website"] = website
d["coverage_generated_at"] = datetime.now(timezone.utc).isoformat()
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False, sort_keys=True)
PYEOF

            local crawl_pages crawl_pdfs crawl_emails crawl_sitemaps crawl_unvisited crawl_fragments
            read -r crawl_pages crawl_pdfs crawl_emails crawl_sitemaps crawl_unvisited crawl_fragments < <(python3 - "$static_crawl_json" <<'PYEOF'
import json, sys
d=json.load(open(sys.argv[1])); c=d.get('coverage',{})
print(c.get('visited_page_count',0), c.get('pdf_count',0), len(d.get('contacts',[])), c.get('sitemap_count',0), c.get('unvisited_page_count',0), c.get('fragment_state_count',0))
PYEOF
)
            log "  [COVERAGE] pages=$crawl_pages pdfs=$crawl_pdfs emails=$crawl_emails sitemaps=$crawl_sitemaps fragments=$crawl_fragments unvisited=$crawl_unvisited"
            log "  [COVERAGE] Saved: $coverage_file"

            # Candidate retention: append every discovered email. Verification happens
            # later; discovery itself never deletes unknown/catch-all/generic candidates.
            python3 - "$static_crawl_json" <<'PYEOF' >> /tmp/pipeline_all_contacts.txt
import json, sys
d=json.load(open(sys.argv[1]))
for c in d.get('contacts', []):
    email=(c.get('email') or '').strip()
    if email:
        print(email + '||||||')
PYEOF

            # Recover socials from ANY crawled page, including scripts/data attributes.
            if [ -z "$fb" ] || [ "$fb" = "None" ]; then
                local crawl_fb
                crawl_fb=$(python3 - "$static_crawl_json" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
for s in d.get('socials',[]):
    if s.get('platform')=='facebook': print(s.get('url','')); break
PYEOF
)
                if echo "$crawl_fb" | grep -qi 'facebook\.com'; then fb="$crawl_fb"; log "  [SOCIAL] Facebook recovered by recursive website crawl: $fb"; fi
            fi
            if [ -z "$ig" ] || [ "$ig" = "None" ]; then
                local crawl_ig
                crawl_ig=$(python3 - "$static_crawl_json" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
for s in d.get('socials',[]):
    if s.get('platform')=='instagram': print(s.get('url','')); break
PYEOF
)
                if echo "$crawl_ig" | grep -qi 'instagram\.com'; then ig="$crawl_ig"; log "  [SOCIAL] Instagram recovered by recursive website crawl: $ig"; fi
            fi
        else
            log "  [WARN] Recursive discovery audit failed; browser crawl will continue"
            rm -f "$static_crawl_json"
        fi
    fi

    # Crawl all subpages found by JS (nav/header links + keyword body links)
    local subpages
    subpages=$(python3 -c "
import json
d = json.load(open('/tmp/pipeline_scrape.json'))
subs = d.get('subpages', [])
# Sort: high-value pages first (contact, staff, wedding, event, banquet, team, about)
priority = ['contact','staff','team','wedding','event','banquet','cater','entertain','music','party','book','rental','meeting','corporate','about','press','media']
def page_score(url):
    u = url.lower()
    for i, kw in enumerate(priority):
        if kw in u:
            return i
    return len(priority)
subs.sort(key=page_score)
print('\n'.join(subs))
" 2>/dev/null)

    # Add recursively discovered pages and preserved hash states to the browser queue.
    # This is what turns the old homepage+one-hop scan into a bounded recursive render.
    if [ -s "$static_crawl_json" ]; then
        local recursive_subpages
        recursive_subpages=$(python3 - "$static_crawl_json" "$website" <<'PYEOF'
import json, sys
from urllib.parse import urlsplit, urlunsplit
d=json.load(open(sys.argv[1])); home=sys.argv[2].rstrip('/')
urls=[]
# Render every page the static crawler actually reached (these can contain JS-only data).
for p in d.get('pages',[]):
    u=(p.get('url') or '').strip()
    if u and u.rstrip('/') != home: urls.append(u)
# Fragment states (#sub-nav-1, #content, etc.) are the same HTTP page — skip them.
# They bloat the crawl queue and waste time re-fetching identical HTML.
seen=set()
for u in urls:
    if not u: continue
    # Strip fragment before dedup — page.com/events#nav1 == page.com/events#nav2
    defragged = urlunsplit(urlsplit(u)._replace(fragment=''))
    if defragged and defragged not in seen:
        seen.add(defragged); print(defragged)
PYEOF
)
        subpages=$(printf '%s\n%s\n' "$subpages" "$recursive_subpages" | awk 'NF && !seen[$0]++')
    fi

    # Determine city slug from the venue's location URL (e.g. /st-michaels-md → st-michaels)
    # Used to skip subpages that belong to other locations of a chain
    local location_slug
    location_slug=$(python3 -c "
from urllib.parse import urlparse
import re, sys
path = urlparse('${website}').path.lower()
# Extract city-like slug from path (e.g. /st-michaels-md, /cambridge-md)
m = re.search(r'/([a-z][a-z\-]+(?:-[a-z]{2})?)/?$', path)
print(m.group(1) if m else '')
" 2>/dev/null)

    # Known location path patterns to skip when we know our target location
    # These slugs appear in multi-location chain URLs
    local US_STATE_SLUGS="-md|-va|-dc|-pa|-de|-wv|-ny|-ca|-fl|-tx|-nc|-sc|-ga|-oh|-il|-ma|-nj|-ct|-ri|-nh|-vt|-me|-mi|-wi|-mn|-ia|-mo|-ks|-ne|-sd|-nd|-mt|-wy|-co|-ut|-nv|-id|-or|-wa|-ak|-hi|-al|-ms|-tn|-ky|-in|-ar|-la|-ok|-nm|-az"

    # --- Probe common subpaths that may not be linked from homepage ---
    local base_url
    base_url=$(python3 -c "from urllib.parse import urlparse; u=urlparse('${website}'); print(u.scheme+'://'+u.netloc)" 2>/dev/null)
    if [ -n "$base_url" ] && [ "$base_url" != "None" ]; then
        local probe_paths="/contact /contact.html /contact-us /contactus /about /about.html /about-us /aboutus /events /private-events /live-music /wine-club /entertainment /catering /team /staff /press /private-dining /book-event /reservations /inquiry /enquiry"
        for probe in $probe_paths; do
            local probe_url="${base_url}${probe}"
            # Skip if already in discovered subpages
            if echo "$subpages" | grep -qi "$(echo $probe | sed 's|/||')"; then
                continue
            fi
            local http_code
            http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 4 "$probe_url" 2>/dev/null)
            if [ "$http_code" = "200" ]; then
                subpages="${probe_url}
${subpages}"
                log "  [PROBE] Found: $probe_url"
            fi
        done
    fi

    if [ -n "$subpages" ]; then
        local page_count=0
        local last_emails=""
        local dupe_streak=0
        while IFS= read -r subpage; do
            [ -z "$subpage" ] && continue

            # Skip subpages that look like other city/location pages of a chain
            if [ -n "$location_slug" ]; then
                local sub_slug
                sub_slug=$(python3 -c "
from urllib.parse import urlparse
import re
path = urlparse('${subpage}').path.lower()
m = re.search(r'/([a-z][a-z\-]+(?:-[a-z]{2})?)/?$', path)
print(m.group(1) if m else '')
" 2>/dev/null)
                if [ -n "$sub_slug" ] && [ "$sub_slug" != "$location_slug" ]; then
                    # Sub page has a different city slug — skip if it looks like a location page
                    local is_other_location
                    is_other_location=$(python3 -c "
import re
slug = '${sub_slug}'
# Has a US state suffix = city-state slug = other location
if re.search(r'-(md|va|dc|pa|de|wv|ny|ca|fl|tx|nc|sc|ga|oh|il|ma|nj|ct|ri|nh|vt|me|mi|wi|mn|ia|mo|ks|ne|sd|nd|mt|wy|co|ut|nv|id|or|wa|ak|hi|al|ms|tn|ky|in|ar|la|ok|nm|az)$', slug):
    print('yes')
else:
    print('no')
" 2>/dev/null)
                    if [ "$is_other_location" = "yes" ]; then
                        log "  SKIP (other location: $sub_slug ≠ $location_slug): $subpage"
                        continue
                    fi
                fi
            fi

            # Skip non-HTML resources (images, CSS, JS, fonts, favicons, manifests)
            if echo "$subpage" | grep -qiE '\.(css|js|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|pdf|zip|mp3|mp4|json|xml|txt|map)(\?|$)'; then
                continue
            fi
            # Skip wp-content asset paths
            if echo "$subpage" | grep -qiE '/wp-content/(plugins|themes)/.*\.(css|js|png|jpg|ico|json)'; then
                continue
            fi

            page_count=$((page_count + 1))
            log "  Crawling subpage ($page_count): $subpage"
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${subpage}\""
            sleep 4
            local sub_result
            sub_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
            # Curl fallback for subpages (Wix/Squarespace render empty in Chrome)
            if [ -z "$sub_result" ] || [ "$sub_result" = "missing value" ]; then
                local sub_html
                sub_html=$(curl -sL --compressed --max-time 8 "$subpage" 2>/dev/null)
                if [ -n "$sub_html" ]; then
                    sub_result=$(python3 -c "
import re, json, sys
html = sys.stdin.read()
emails = set()
for m in re.findall(r'mailto:([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})', html):
    emails.add(m.lower())
for enc in re.findall(r'data-cfemail=\"([a-f0-9]+)\"', html):
    key = int(enc[:2], 16)
    decoded = ''.join(chr(int(enc[i:i+2], 16) ^ key) for i in range(2, len(enc), 2))
    if '@' in decoded: emails.add(decoded.lower())
text = re.sub(r'<[^>]+>', ' ', html)
for m in re.findall(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', text):
    e = m.lower()
    if not re.search(r'\.(png|jpg|gif|svg|css|js)$', e): emails.add(e)
junk = ['noreply','no-reply','mailer-daemon','postmaster','webmaster','sentry','wix.com','squarespace']
contacts = [{'email':e,'name':'','title':''} for e in emails if not any(j in e for j in junk) and len(e)<60]
# Social fallback: inspect raw/JSON-escaped/percent-encoded HTML too.
from urllib.parse import unquote, urlparse, parse_qs
work = html.replace('\\u002F','/').replace('\\u002f','/').replace('\\/','/')
try: work = work + '\n' + unquote(work) + '\n' + unquote(unquote(work))
except Exception: pass
fb = ''
ig = ''
fb_skip = {'tr','pixel','plugins','sharer','share','login','dialog','policy.php','policy','terms','about','legal','cookies','recover','help','privacy','settings','ads','business'}
for m in re.findall(r'https?://(?:www\.|m\.|web\.)?facebook\.com/[^\s\"\x27<>]+', work, re.I):
    u=m.rstrip('.,;:)]}')
    p=urlparse(u); parts=[x for x in p.path.split('/') if x]
    if not parts: continue
    first=parts[0].lower()
    if first == 'profile.php' and parse_qs(p.query).get('id'):
        fb='https://www.facebook.com/profile.php?id=' + parse_qs(p.query)['id'][0]; break
    if first == 'pages' and len(parts)>=3 and parts[-1].isdigit():
        fb='https://www.facebook.com/' + '/'.join(parts[:3]); break
    if first in fb_skip or first.isdigit() or len(first)<2: continue
    fb='https://www.facebook.com/' + parts[0] + '/'; break
ig_skip = {'p','reel','reels','explore','stories','accounts','developer','about','legal','privacy','terms','share','embed','direct','tv'}
for m in re.findall(r'https?://(?:www\.)?instagram\.com/[^\s\"\x27<>]+', work, re.I):
    p=urlparse(m.rstrip('.,;:)]}')); parts=[x for x in p.path.split('/') if x]
    if not parts: continue
    h=parts[0]
    if h.lower() in ig_skip or h.isdigit() or len(h)<2 or not re.fullmatch(r'[A-Za-z0-9._]+',h): continue
    ig='https://www.instagram.com/' + h + '/'; break
has_form = bool(re.search(r'<form[^>]*>.*?(<textarea|<input[^>]*type=[\"\x27]email|<input[^>]*name=[\"\x27][^\"\x27]*(?:email|message))', html, re.IGNORECASE | re.DOTALL))
print(json.dumps({'contacts':contacts, 'facebook':fb, 'instagram':ig, 'has_form': has_form}))
" <<< "$sub_html" 2>/dev/null)
                    if [ -n "$sub_result" ] && [ "$sub_result" != "null" ]; then
                        log "  [CURL FALLBACK] Subpage parsed via curl"
                        # Check for contact form in curl fallback — only on contact-related pages
                        if [ -z "$contact_form" ] || [ "$contact_form" = "None" ] || [ "$contact_form" = "" ]; then
                            if echo "$subpage" | grep -qiE '/contact|/inquir|/get-in-touch|/reach-us|/book.*event|/private.*event|/private.*dining'; then
                                local curl_has_form
                                curl_has_form=$(python3 -c "import json; print('yes' if json.loads('$sub_result').get('has_form') else 'no')" 2>/dev/null)
                                if [ "$curl_has_form" = "yes" ]; then
                                    contact_form="$subpage"
                                    log "  [CONTACT FORM] Found on subpage (curl): $subpage"
                                fi
                            fi
                        fi
                    fi
                fi
            fi
            if [ -n "$sub_result" ] && [ "$sub_result" != "missing value" ] && [ "$sub_result" != "null" ]; then
                echo "$sub_result" > /tmp/pipeline_sub_scrape.json
                local sub_count sub_fb sub_ig
                sub_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_sub_scrape.json')); print(len(d.get('contacts',[])))" 2>/dev/null || echo "0")
                sub_fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sub_scrape.json')).get('facebook',''))" 2>/dev/null)
                sub_ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sub_scrape.json')).get('instagram',''))" 2>/dev/null)
                if ([ -z "$fb" ] || [ "$fb" = "None" ]) && echo "$sub_fb" | grep -qi 'facebook\.com'; then
                    fb="$sub_fb"
                    log "  [SOCIAL] Facebook recovered from subpage: $subpage -> $fb"
                fi
                if ([ -z "$ig" ] || [ "$ig" = "None" ]) && echo "$sub_ig" | grep -qi 'instagram\.com'; then
                    ig="$sub_ig"
                    log "  [SOCIAL] Instagram recovered from subpage: $subpage -> $ig"
                fi
                if [ "$sub_count" != "0" ]; then
                    local sub_emails
                    sub_emails=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_sub_scrape.json')); print(', '.join(sorted(c['email'] for c in d.get('contacts',[]))))" 2>/dev/null)
                    # Repeated footer emails are not a completion signal. A later page can
                    # still contain a unique event contact or the only social links. Track the
                    # repetition for diagnostics, but never terminate discovery because of it.
                    if [ "$sub_emails" = "$last_emails" ]; then
                        dupe_streak=$((dupe_streak + 1))
                        if [ "$dupe_streak" -eq 3 ]; then
                            log "  [COVERAGE] Same emails repeated across 3 pages — continuing crawl"
                        fi
                    else
                        dupe_streak=0
                        last_emails="$sub_emails"
                    fi
                    log "  Found on subpage: $sub_emails"
                    python3 -c "
import json
d = json.load(open('/tmp/pipeline_sub_scrape.json'))
for c in d.get('contacts', []):
    print(c['email'] + '|||' + c.get('name','') + '|||' + c.get('title',''))
" 2>/dev/null >> /tmp/pipeline_all_contacts.txt
                fi
            fi

            # Check subpage for contact form if we haven't found one yet
            # Only check pages whose URL contains contact-related keywords to avoid
            # false positives from newsletter signups, login forms, reservation widgets, etc.
            if [ -z "$contact_form" ] || [ "$contact_form" = "None" ] || [ "$contact_form" = "" ]; then
                if echo "$subpage" | grep -qiE '/contact|/inquir|/get-in-touch|/reach-us|/book.*event|/private.*event|/private.*dining'; then
                    local sub_has_form
                    sub_has_form=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "
(function(){
  var forms = document.querySelectorAll(\"form\");
  for(var i=0;i<forms.length;i++){
    var f = forms[i];
    if(f.querySelector(\"textarea\") ||
       f.querySelector(\"input[type=email]\") ||
       f.querySelector(\"input[name*=email]\") ||
       f.querySelector(\"input[name*=message]\")){
      return \"yes\";
    }
  }
  return \"no\";
})()"' 2>/dev/null)
                    if [ "$sub_has_form" = "yes" ]; then
                        contact_form="$subpage"
                        log "  [CONTACT FORM] Found on subpage: $subpage"
                    fi
                fi
            fi

        done <<< "$subpages"
    fi

    # Proactive contact page check — for Wix/JS sites where nav links aren't real <a href>
    # tags, the contact page never appears in subpages. Try common URL patterns explicitly.
    local base_url
    base_url=$(python3 -c "from urllib.parse import urlparse; u=urlparse('${website}'); print(u.scheme+'://'+u.netloc)" 2>/dev/null)
    if [ -n "$base_url" ]; then
        for contact_path in "/contact" "/contact-us" "/contact_us" "/get-in-touch" "/reach-us" "/inquiry" "/enquiry"; do
            local try_contact="${base_url}${contact_path}"
            local http_code
            http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 5 "$try_contact" 2>/dev/null)
            if [ "$http_code" = "200" ]; then
                log "  [CONTACT] Probing $try_contact"
                osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${try_contact}\"" 2>/dev/null
                sleep 5
                local pc_result
                pc_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
                if [ -n "$pc_result" ] && [ "$pc_result" != "missing value" ]; then
                    echo "$pc_result" > /tmp/pipeline_contact_probe.json
                    local pc_count
                    pc_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_contact_probe.json')); print(len(d.get('contacts',[])))" 2>/dev/null || echo "0")
                    if [ "$pc_count" != "0" ]; then
                        log "  [CONTACT] Found emails on $try_contact"
                        python3 -c "
import json
d = json.load(open('/tmp/pipeline_contact_probe.json'))
for c in d.get('contacts', []):
    print(c['email'] + '|||' + c.get('name','') + '|||' + c.get('title',''))
" 2>/dev/null >> /tmp/pipeline_all_contacts.txt
                    fi
                    # Also grab social links if not found yet
                    local pc_fb pc_ig
                    pc_fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_contact_probe.json')).get('facebook',''))" 2>/dev/null)
                    pc_ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_contact_probe.json')).get('instagram',''))" 2>/dev/null)
                    if ([ -z "$fb" ] || [ "$fb" = "None" ]) && echo "$pc_fb" | grep -qi 'facebook\.com'; then fb="$pc_fb"; fi
                    if ([ -z "$ig" ] || [ "$ig" = "None" ]) && echo "$pc_ig" | grep -qi 'instagram\.com'; then ig="$pc_ig"; fi
                    rm -f /tmp/pipeline_contact_probe.json
                fi
                # Do not break on the first HTTP 200. Many sites return soft-404 pages
                # with status 200; continue probing the remaining known contact paths.
            fi
        done
    fi

    # Final website-wide social recovery pass. The browser crawler can miss links
    # embedded in scripts/data attributes, encoded redirect URLs, sitemaps, or pages
    # it did not render. site_discovery.py statically crawls the same-origin site and
    # retains provenance for every Facebook/Instagram candidate it sees.
    if ([ -z "$fb" ] || [ "$fb" = "None" ] || [ -z "$ig" ] || [ "$ig" = "None" ]) && [ -f "${SCRIPT_DIR}/site_discovery.py" ]; then
        local social_crawl_json="/tmp/pipeline_social_crawl_${venue_id}.json"
        python3 "${SCRIPT_DIR}/site_discovery.py" static-crawl "$website" --max-pages 30 --max-depth 2 > "$social_crawl_json" 2>/dev/null || true
        if [ -s "$social_crawl_json" ]; then
            local crawl_fb crawl_ig
            crawl_fb=$(python3 - "$social_crawl_json" <<'PYEOF'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(''); raise SystemExit
for s in d.get('socials', []):
    if s.get('platform') == 'facebook':
        print(s.get('url','')); break
PYEOF
)
            crawl_ig=$(python3 - "$social_crawl_json" <<'PYEOF'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(''); raise SystemExit
for s in d.get('socials', []):
    if s.get('platform') == 'instagram':
        print(s.get('url','')); break
PYEOF
)
            if ([ -z "$fb" ] || [ "$fb" = "None" ]) && echo "$crawl_fb" | grep -qi 'facebook\.com'; then
                fb="$crawl_fb"
                log "  [SOCIAL RECOVERY] Facebook found by website-wide crawl: $fb"
            fi
            if ([ -z "$ig" ] || [ "$ig" = "None" ]) && echo "$crawl_ig" | grep -qi 'instagram\.com'; then
                ig="$crawl_ig"
                log "  [SOCIAL RECOVERY] Instagram found by website-wide crawl: $ig"
            fi
        fi
    fi

    # Track whether socials came from the venue's own website (trusted source)
    local fb_from_website="yes"
    local ig_from_website="yes"

    # Update social links — also write to temp files so step1b/1c don't re-query the sheet
    # Validate: only save if URL actually belongs to the right platform
    if [ -n "$fb" ] && [ "$fb" != "None" ] && [ "$fb" != "" ]; then
        # Reject bare facebook.com with no page slug
        if echo "$fb" | grep -qiE '^https?://(www\.)?facebook\.com/?$'; then
            log "  [WARN] Rejecting bare Facebook URL (no page): $fb"
            fb=""
        elif echo "$fb" | grep -qiE 'facebook\.com/(tr|pages|sharer|dialog|plugins|ads|business)/?$'; then
            log "  [WARN] Rejecting junk Facebook URL: $fb"
            fb=""
        elif echo "$fb" | grep -qiE 'facebook\.com/(WixStudio|wix)/?'; then
            log "  [WARN] Rejecting Wix template Facebook link: $fb"
            fb=""
        elif echo "$fb" | grep -qiE 'facebook\.com/[0-9]+/?$'; then
            log "  [WARN] Rejecting numeric-only Facebook slug: $fb"
            fb=""
        elif echo "$fb" | grep -qi 'facebook\.com'; then
            if [ "$fb_from_website" = "yes" ]; then
                # Found on venue's own website — trust it, skip name-matching
                log "  ✓ Facebook from venue website (trusted): $fb"
                local fb_save_response fb_save_ok
                fb_save_response=$(curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&force=true&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$fb")")
                fb_save_ok=$(echo "$fb_save_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('status')=='ok' and d.get('verified',True) else 'no')" 2>/dev/null || echo no)
                if [ "$fb_save_ok" = "yes" ]; then
                    echo "$fb" > /tmp/pipeline_step1_fb.txt
                else
                    log "  [API ERROR] Facebook was found on website but did not persist: $fb | $fb_save_response"
                fi
            else
                # From external source — validate slug matches venue name
                local fb_slug fb_name_match
                fb_slug=$(echo "$fb" | sed 's|.*/\([^/]*\)/\?$|\1|' | tr '[:upper:]' '[:lower:]')
                fb_name_match=$(python3 -c "
import re, sys
venue = sys.argv[1]; handle = sys.argv[2]
words = re.sub(r'[^a-z\s]','',venue.lower()).split()
stop = {'the','a','an','and','of','at','in','by','on','for','to',
        'hotel','inn','resort','lodge','restaurant','winery','vineyard',
        'club','country','golf','bar','bistro','cafe','tavern','grill',
        'pub','lounge','spa','marina','museum','gallery'}
words = [w for w in words if w not in stop and len(w) > 2]
print('match' if any(w in handle for w in words) else 'no')
" "$venue" "$fb_slug" 2>/dev/null)
                if [ "$fb_name_match" = "no" ]; then
                    log "  [REJECT] Facebook slug '$fb_slug' doesn't match venue name '$venue' — discarding"
                    echo "FLAG:Off-venue Facebook rejected: $fb (slug '$fb_slug' vs venue '$venue')" >> /tmp/pipeline_flags.txt
                    fb=""
                else
                    curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$fb")" > /dev/null
                    echo "$fb" > /tmp/pipeline_step1_fb.txt
                fi
            fi
        else
            log "  [WARN] Rejecting non-Facebook URL in fb field: $fb"
            fb=""
        fi
    fi
    if [ -n "$ig" ] && [ "$ig" != "None" ] && [ "$ig" != "" ]; then
        # Reject bare instagram.com with no profile slug
        if echo "$ig" | grep -qiE '^https?://(www\.)?instagram\.com/?$'; then
            log "  [WARN] Rejecting bare Instagram URL (no profile): $ig"
            ig=""
        elif echo "$ig" | grep -qiE 'instagram\.com/(p|reel|reels|explore|stories|accounts|developer|embed)/?$'; then
            log "  [WARN] Rejecting junk Instagram URL: $ig"
            ig=""
        elif echo "$ig" | grep -qiE 'instagram\.com/[0-9]+/?$'; then
            log "  [WARN] Rejecting numeric-only Instagram slug: $ig"
            ig=""
        elif echo "$ig" | grep -qi 'instagram\.com'; then
            if [ "$ig_from_website" = "yes" ]; then
                # Found on venue's own website — trust it, skip name-matching
                log "  ✓ Instagram from venue website (trusted): $ig"
                local ig_save_response ig_save_ok
                ig_save_response=$(curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&force=true&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ig")")
                ig_save_ok=$(echo "$ig_save_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('status')=='ok' and d.get('verified',True) else 'no')" 2>/dev/null || echo no)
                if [ "$ig_save_ok" = "yes" ]; then
                    echo "$ig" > /tmp/pipeline_step1_ig.txt
                else
                    log "  [API ERROR] Instagram was found on website but did not persist: $ig | $ig_save_response"
                fi
            else
                # From external source — validate handle matches venue name
                local ig_slug ig_name_match
                ig_slug=$(echo "$ig" | sed 's|.*/\([^/]*\)/\?$|\1|' | tr '[:upper:]' '[:lower:]')
                ig_name_match=$(python3 -c "
import re, sys
venue = sys.argv[1]; handle = sys.argv[2]
words = re.sub(r'[^a-z\s]','',venue.lower()).split()
stop = {'the','a','an','and','of','at','in','by','on','for','to',
        'hotel','inn','resort','lodge','restaurant','winery','vineyard',
        'club','country','golf','bar','bistro','cafe','tavern','grill',
        'pub','lounge','spa','marina','museum','gallery'}
words = [w for w in words if w not in stop and len(w) > 2]
print('match' if any(w in handle for w in words) else 'no')
" "$venue" "$ig_slug" 2>/dev/null)
                if [ "$ig_name_match" = "no" ]; then
                    log "  [REJECT] Instagram handle '$ig_slug' doesn't match venue name '$venue' — discarding"
                    echo "FLAG:Off-venue Instagram rejected: $ig (handle '$ig_slug' vs venue '$venue')" >> /tmp/pipeline_flags.txt
                    ig=""
                else
                    curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ig")" > /dev/null
                    echo "$ig" > /tmp/pipeline_step1_ig.txt
                fi
            fi
        else
            log "  [WARN] Rejecting non-Instagram URL in ig field: $ig"
            ig=""
        fi
    fi
    if [ -n "$contact_form" ] && [ "$contact_form" != "None" ] && [ "$contact_form" != "" ]; then
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=contact_form&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$contact_form")" > /dev/null
        log "  ✓ Contact form URL saved"
    fi

    # Dedupe by email and verify+push each contact with name/title
    python3 -c "
seen = set()
results = []
for line in open('/tmp/pipeline_all_contacts.txt'):
    parts = line.strip().split('|||')
    if len(parts) < 3: continue
    email, name, title = parts[0], parts[1], parts[2]
    if email not in seen:
        seen.add(email)
        # Prefer entries with name over those without
        results.append((email, name, title))
    elif name and not any(r[1] for r in results if r[0] == email):
        results = [(e,n,t) if e != email else (email,name,title) for e,n,t in results]
for email, name, title in sorted(results):
    print(f'{email}|||{name}|||{title}')
" 2>/dev/null | while IFS='|||' read -r email name title; do
        [ -n "$email" ] && verify_and_push "$email" "$venue_id" "$name" "$title" "website"
    done
}

# =================================================================
# STEP 1B: INSTAGRAM GOOGLE SEARCH FALLBACK
# If Step 1 didn't find an Instagram URL on the website, try Google.
# =================================================================
step1b_ig_search() {
    local venue="$1" venue_id="$2"

    # Check temp file first (written by step1 when it finds IG directly)
    if [ -f /tmp/pipeline_step1_ig.txt ]; then
        local cached_ig
        cached_ig=$(cat /tmp/pipeline_step1_ig.txt)
        if [ -n "$cached_ig" ] && [ ${#cached_ig} -gt 5 ]; then
            return  # Already found in step1
        fi
    fi

    # Check if IG already found (from Step 1 website scrape saved to sheet)
    local current_ig
    local ig_tmpf="/tmp/pipeline_ig_check.json"
    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$ig_tmpf" 2>/dev/null
    current_ig=$(python3 -c "import json; print(json.load(open('$ig_tmpf')).get('venue',{}).get('instagram',''))" 2>/dev/null)

    if [ -n "$current_ig" ] && [ "$current_ig" != "None" ] && [ ${#current_ig} -gt 5 ]; then
        return  # Already has IG
    fi

    log ""
    log "========== STEP 1B: Instagram Google Search =========="
    log "  No Instagram found on website — Googling..."

    local SEARCH_ENCODED
    SEARCH_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote('\"' + sys.argv[1] + '\" instagram'))" "$venue")
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
    sleep 4

    # Extract instagram.com profile URLs from Google results (pipe-separated)
    local ig_all
    ig_all=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_ig.js"'")' 2>/dev/null)

    if [ -n "$ig_all" ] && [ "$ig_all" != "missing value" ] && [ "$ig_all" != "" ]; then
        # Pick the best match — check if IG handle relates to venue name
        local best_ig=""
        IFS='|' read -ra IG_LIST <<< "$ig_all"
        for ig_candidate in "${IG_LIST[@]}"; do
            [ -z "$ig_candidate" ] && continue
            local handle
            handle=$(echo "$ig_candidate" | sed 's|.*/\([^/]*\)/\?$|\1|' | tr '[:upper:]' '[:lower:]')
            # Check if any venue name word appears in the handle
            local ig_match
            ig_match=$(python3 -c "
import re, sys
venue = sys.argv[1]
handle = sys.argv[2]
words = re.sub(r'[^a-z\s]','',venue.lower()).split()
stop = {'the','a','an','and','of','at','in','by','on','for','to',
        'hotel','inn','resort','lodge','restaurant','winery','vineyard',
        'club','country','golf','bar','bistro','cafe','tavern','grill',
        'pub','lounge','spa','marina','museum','gallery'}
words = [w for w in words if w not in stop and len(w) > 2]
if any(w in handle for w in words):
    print('match')
else:
    print('no')
" "$venue" "$handle" 2>/dev/null)
            if [ "$ig_match" = "match" ]; then
                best_ig="$ig_candidate"
                break
            else
                log "  [IG SEARCH] Skipping $ig_candidate — handle '$handle' doesn't match venue"
            fi
        done
        # If no match found, reject — don't use unmatched handles
        if [ -z "$best_ig" ] && [ ${#IG_LIST[@]} -gt 0 ]; then
            log "  [IG SEARCH] No handle matched venue name — rejecting all candidates"
        fi
        if [ -n "$best_ig" ]; then
            log "  [IG SEARCH] Found: $best_ig"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$best_ig")" > /dev/null
            log "  ✓ Instagram URL saved"
        fi
    else
        log "  [IG SEARCH] No Instagram found via Google"
    fi
}

# =================================================================
# STEP 1C: FACEBOOK GOOGLE SEARCH FALLBACK
# If Step 1 didn't find a Facebook URL on the website, try Google.
# =================================================================
step1c_fb_search() {
    local venue="$1" venue_id="$2"

    # Check temp file first (written by step1 when it finds FB directly)
    if [ -f /tmp/pipeline_step1_fb.txt ]; then
        local cached_fb
        cached_fb=$(cat /tmp/pipeline_step1_fb.txt)
        if [ -n "$cached_fb" ] && [ ${#cached_fb} -gt 5 ]; then
            return  # Already found in step1
        fi
    fi

    # Check if FB already found (from Step 1 website scrape saved to sheet)
    local current_fb
    local fb_tmpf="/tmp/pipeline_fb_check.json"
    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$fb_tmpf" 2>/dev/null
    current_fb=$(python3 -c "import json; print(json.load(open('$fb_tmpf')).get('venue',{}).get('facebook',''))" 2>/dev/null)

    if [ -n "$current_fb" ] && [ "$current_fb" != "None" ] && [ ${#current_fb} -gt 5 ]; then
        return  # Already has FB
    fi

    log ""
    log "========== STEP 1C: Facebook Google Search =========="
    log "  No Facebook found on website — Googling..."

    local SEARCH_ENCODED
    SEARCH_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote('\"' + sys.argv[1] + '\" facebook'))" "$venue")
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
    sleep 4

    local fb_all
    fb_all=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_fb.js"'")' 2>/dev/null)

    if [ -n "$fb_all" ] && [ "$fb_all" != "missing value" ] && [ "$fb_all" != "" ]; then
        local best_fb=""
        IFS='|' read -ra FB_LIST <<< "$fb_all"
        for fb_candidate in "${FB_LIST[@]}"; do
            [ -z "$fb_candidate" ] && continue
            local fb_handle
            fb_handle=$(echo "$fb_candidate" | sed 's|.*/\([^/]*\)/\?$|\1|' | tr '[:upper:]' '[:lower:]')
            local fb_match
            fb_match=$(python3 -c "
import re, sys
venue = sys.argv[1]
handle = sys.argv[2]
words = re.sub(r'[^a-z\s]','',venue.lower()).split()
stop = {'the','a','an','and','of','at','in','by','on','for','to',
        'hotel','inn','resort','lodge','restaurant','winery','vineyard',
        'club','country','golf','bar','bistro','cafe','tavern','grill',
        'pub','lounge','spa','marina','museum','gallery'}
words = [w for w in words if w not in stop and len(w) > 2]
if any(w in handle for w in words):
    print('match')
else:
    print('no')
" "$venue" "$fb_handle" 2>/dev/null)
            if [ "$fb_match" = "match" ]; then
                best_fb="$fb_candidate"
                break
            else
                log "  [FB SEARCH] Skipping $fb_candidate — handle '$fb_handle' doesn't match venue"
            fi
        done
        if [ -z "$best_fb" ] && [ ${#FB_LIST[@]} -gt 0 ]; then
            log "  [FB SEARCH] No handle matched venue name — rejecting all candidates"
        fi
        if [ -n "$best_fb" ]; then
            log "  [FB SEARCH] Found: $best_fb"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$best_fb")" > /dev/null
            log "  ✓ Facebook URL saved"
        fi
    else
        log "  [FB SEARCH] No Facebook found via Google"
    fi

    # Last resort: try common Facebook URL patterns directly
    if [ -z "$best_fb" ]; then
        local fb_slugs
        fb_slugs=$(python3 -c "
import re, sys
venue = sys.argv[1]
# Generate slug candidates: 'Echelon Wine Bar' -> echelonwinebar, echelon-wine-bar, echelon.wine.bar
# Never use single first-word slug — too likely to match wrong business (e.g. 'balla' -> 'GA BALLA')
clean = re.sub(r'[^a-zA-Z0-9\s]','',venue).strip()
words = clean.lower().split()
print('\n'.join([
    ''.join(words),
    '-'.join(words),
    '.'.join(words),
]))
" "$venue" 2>/dev/null)
        while IFS= read -r slug; do
            [ -z "$slug" ] && continue
            local try_url="https://www.facebook.com/${slug}"
            local http_code
            local fb_body
            fb_body=$(curl -sL --compressed --max-time 8 "$try_url" 2>/dev/null)
            http_code=$(echo "$fb_body" | head -c 1 | wc -c)  # non-empty check
            if [ "$http_code" -gt 0 ]; then
                # Verify the page title actually matches the venue name
                local fb_title
                fb_title=$(echo "$fb_body" | python3 -c "
import sys, re, html
content = sys.stdin.read()
m = re.search(r'<title[^>]*>(.*?)</title>', content, re.IGNORECASE|re.DOTALL)
if m:
    print(html.unescape(m.group(1)).strip())
else:
    print('')
" 2>/dev/null)
                local venue_lower slug_match
                venue_lower=$(echo "$venue" | tr '[:upper:]' '[:lower:]' | sed "s/^the //")
                slug_match=$(python3 -c "
import sys
title = sys.argv[1].lower()
venue = sys.argv[2].lower()
# Check if venue's main word(s) appear in the FB page title
words = [w for w in venue.split() if len(w) > 3]
matched = sum(1 for w in words if w in title)
# Need at least half the significant words to match
print('yes' if words and matched >= max(1, len(words)//2) else 'no')
" "$fb_title" "$venue_lower" 2>/dev/null)
                if [ "$slug_match" = "yes" ]; then
                    log "  [FB PROBE] Found: $try_url (title: $fb_title)"
                    curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=facebook&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$try_url")" > /dev/null
                    log "  ✓ Facebook URL saved"
                    break
                else
                    log "  [FB PROBE] Rejected $try_url — page title '$fb_title' doesn't match venue"
                fi
            fi
        done <<< "$fb_slugs"
    fi
}

# =================================================================
# STEP 2: SOCIAL MEDIA SCRAPE
# =================================================================
step2_social() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 2: Social Media Scrape =========="

    local fb ig
    local social_tmpf="/tmp/pipeline_social_venue.json"
    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$social_tmpf"
    fb=$(python3 -c "import json; print(json.load(open('$social_tmpf')).get('venue',{}).get('facebook',''))" 2>/dev/null)
    ig=$(python3 -c "import json; print(json.load(open('$social_tmpf')).get('venue',{}).get('instagram',''))" 2>/dev/null)
    # Fall back to temp files written by step1 (catches case where update_venue failed)
    if [ -z "$fb" ] || [ "$fb" = "None" ] || [ ${#fb} -le 5 ]; then
        [ -f /tmp/pipeline_step1_fb.txt ] && fb=$(cat /tmp/pipeline_step1_fb.txt)
    fi
    if [ -z "$ig" ] || [ "$ig" = "None" ] || [ ${#ig} -le 5 ]; then
        [ -f /tmp/pipeline_step1_ig.txt ] && ig=$(cat /tmp/pipeline_step1_ig.txt)
    fi

    log "  FB: ${fb:-none} | IG: ${ig:-none}"

    # Scrape emails by opening pages in Chrome (JS renders, emails visible)
    cat > /tmp/social_scrape_emails.js << 'JSEOF'
(function(){
var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk'];
var generic = ['noreply@','no-reply@','support@','admin@','webmaster@','billing@','dataremoval@','privacy@','careers@','jobs@','hr@','info@','sales@','hello@','contact@','enquiries@','inquiries@','reservations@'];
var text = document.body.innerText || '';
var matches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
var links = document.querySelectorAll('a[href^="mailto:"]');
for(var k=0;k<links.length;k++){
    var m = links[k].href.replace('mailto:','').split('?')[0].trim();
    if(m && matches.indexOf(m)===-1) matches.push(m);
}
var emails = [];
for(var i=0;i<matches.length;i++){
    var e = matches[i].toLowerCase();
    var isJunk = false;
    for(var j=0;j<junk.length;j++){ if(e.indexOf(junk[j])>-1){isJunk=true;break;} }
    if(!isJunk){for(var g=0;g<generic.length;g++){ if(e.indexOf(generic[g])===0){isJunk=true;break;} }}
    if(!isJunk && e.length<60) emails.push(e);
}
return emails.filter(function(v,i,a){return a.indexOf(v)===i;}).join('|');
})()
JSEOF

    local SOCIAL_EMAILS=""

    # Facebook — try main page and /about
    local fb_found_email=0
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
                fb_found_email=1
            fi
        done
        if [ "$fb_found_email" = "0" ]; then
            # Facebook DOM may not render email — fall back to Google snippet
            log "  [FB] No email on page — trying Google snippet..."
            local fb_search_encoded
            fb_search_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote('\"' + sys.argv[1] + '\" facebook'))" "$venue")
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${fb_search_encoded}\""
            sleep 4
            local fb_snippet_emails
            fb_snippet_emails=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_email_from_snippet.js"'")')
            if [ -n "$fb_snippet_emails" ] && [ "$fb_snippet_emails" != "missing value" ]; then
                log "  [FB SNIPPET] Found: $fb_snippet_emails"
                SOCIAL_EMAILS="${SOCIAL_EMAILS}|${fb_snippet_emails}"
            else
                log "  [FB SNIPPET] No email in Google snippet"
            fi
        fi
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
        else
            # Instagram DOM doesn't render bio emails — fall back to Google snippet
            log "  [IG] No email on page — trying Google snippet..."
            local ig_search_encoded
            ig_search_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote('\"' + sys.argv[1] + '\" instagram'))" "$venue")
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${ig_search_encoded}\""
            sleep 4
            local ig_snippet_emails
            ig_snippet_emails=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_email_from_snippet.js"'")')
            if [ -n "$ig_snippet_emails" ] && [ "$ig_snippet_emails" != "missing value" ]; then
                log "  [IG SNIPPET] Found: $ig_snippet_emails"
                SOCIAL_EMAILS="${SOCIAL_EMAILS}|${ig_snippet_emails}"
            else
                log "  [IG SNIPPET] No email in Google snippet"
            fi
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
    local venue="$1" venue_id="$2" website_url="$3" city="$4"
    log ""
    log "========== STEP 3: Apollo API =========="

    if [ -z "$APOLLO_API_KEY" ]; then
        log "  [ERROR] APOLLO_API_KEY not set. Skipping."
        return
    fi

    # A. Search for company by name, fallback to domain
    log "  Searching Apollo for company: $venue"

    # Get website domain — first from passed URL, then fallback to sheet
    local WEBSITE_DOMAIN=""
    if [ -n "$website_url" ]; then
        WEBSITE_DOMAIN=$(echo "$website_url" | python3 -c "import sys,re; m=re.search(r'https?://(?:www\.)?([^/]+)',sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null)
    fi
    if [ -z "$WEBSITE_DOMAIN" ]; then
        local domain_tmpf="/tmp/pipeline_domain_lookup.json"
        curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$domain_tmpf" 2>/dev/null
        WEBSITE_DOMAIN=$(python3 -c "
import json,re
with open('$domain_tmpf') as f: d = json.load(f)
w = d.get('venue',{}).get('website','')
m = re.search(r'https?://(?:www\.)?([^/]+)', w)
print(m.group(1) if m else '')
" 2>/dev/null)
    fi

    local apollo_co_tmpf="/tmp/pipeline_apollo_company.json"
    python3 << PYEOF > "$apollo_co_tmpf"
import requests, json, sys, re

headers = {"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"}
venue_name = "$venue"
website_domain = "$WEBSITE_DOMAIN"
venue_city = "$city"

# Build location filter from city (e.g. "Washington" -> "Washington, DC")
org_locations = []
if venue_city and venue_city != "None":
    org_locations = [venue_city]

def normalize(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())

# Strip hotel brand suffixes that confuse Apollo search
brand_suffixes = [
    r'\s*-?\s*by\s+(ihg|hilton|marriott|hyatt|wyndham|accor|choice|best western|radisson)\b',
    r'\s*-?\s*(vignette|curio|tapestry|tribute|autograph)\s+collection\b',
    r'\s*-?\s*,?\s*(a|an)\s+(ihg|hilton|marriott|hyatt)\s+hotel\b',
]

def strip_brand(name):
    """Remove hotel brand suffixes to get the core venue name"""
    cleaned = name
    for pat in brand_suffixes:
        cleaned = re.sub(pat, '', cleaned, flags=re.IGNORECASE)
    return cleaned.strip(' -,')

def name_matches(result_name, target_name):
    """Check if Apollo result is a reasonable match for our venue"""
    rn = normalize(result_name)
    tn = normalize(target_name)
    # Exact or substring match
    if tn in rn or rn in tn:
        return True
    # Also try with brand suffixes stripped
    tn_stripped = normalize(strip_brand(target_name))
    rn_stripped = normalize(strip_brand(result_name))
    if tn_stripped and rn_stripped and (tn_stripped in rn_stripped or rn_stripped in tn_stripped):
        return True
    # Check word overlap — require 50% AND at least 2 shared words
    # (prevents "Bistro" alone from matching "La Lou Bistro" to "Petit Louis Bistro")
    stopwords = {'the', 'a', 'an', 'and', 'of', 'at', 'in', 'by', 'hotel', 'collection'}
    common_venue_words = {'bar', 'grill', 'bistro', 'cafe', 'restaurant', 'kitchen',
                          'tavern', 'pub', 'lounge', 'house', 'club', 'wine', 'brewing',
                          'inn', 'suites', 'resort', 'lodge', 'manor', 'estate'}
    tw = set(re.sub(r'[^a-z\s]', '', target_name.lower()).split()) - stopwords
    rw = set(re.sub(r'[^a-z\s]', '', result_name.lower()).split()) - stopwords
    shared = tw & rw
    # Shared words that are just generic venue types don't count as real matches
    meaningful_shared = shared - common_venue_words
    if tw and len(shared) / len(tw) >= 0.5 and len(meaningful_shared) >= 1:
        return True
    return False

all_candidates = []

# Strip brand suffix for a cleaner search query
clean_name = strip_brand(venue_name)

chain_keywords = ['intercontinental', 'ihg', 'hilton worldwide', 'marriott international',
                  'hyatt hotels', 'wyndham', 'accor', 'choice hotels', 'best western',
                  'radisson', 'aimbridge hospitality', 'highgate hotels']

def is_chain(name):
    return any(kw in name.lower() for kw in chain_keywords)

def score_candidate(c):
    """Higher score = better match. Domain match is strongest signal."""
    s = 0
    if c.get("organization_id"): s += 10
    if c.get("primary_domain") or c.get("domain"): s += 5
    if is_chain(c.get("name", "")): s -= 20
    # Exact domain match is the strongest signal — trumps everything
    c_domain = (c.get("primary_domain") or c.get("domain") or "").lower().replace("www.", "")
    if website_domain and c_domain == website_domain.lower().replace("www.", ""):
        s += 50
    return s

# Helper: enrich organization by domain (primary method — mixed_companies/search is deprecated)
def enrich_org_by_domain(domain):
    """Use organizations/enrich endpoint which still works reliably."""
    if not domain:
        return []
    resp = requests.get("${APOLLO_API_BASE}/organizations/enrich",
        headers=headers, params={"domain": domain})
    if resp.status_code == 200:
        org = resp.json().get("organization")
        if org:
            return [org]
    return []

# Helper: search companies with optional location filter
def search_companies(params):
    """Search with location filter first, fall back without if no matches."""
    # Try with location filter
    if org_locations:
        loc_params = {**params, "organization_locations": org_locations}
        resp = requests.post("${APOLLO_API_BASE}/mixed_companies/search",
            headers=headers, json=loc_params)
        results = resp.json()
        hits = results.get("accounts", []) + results.get("organizations", [])
        if hits:
            return hits
    # Fall back: no location filter
    resp = requests.post("${APOLLO_API_BASE}/mixed_companies/search",
        headers=headers, json=params)
    data = resp.json()
    return data.get("accounts", []) + data.get("organizations", [])

# PRIMARY: Try organizations/enrich by domain first (most reliable endpoint)
if website_domain:
    for org in enrich_org_by_domain(website_domain):
        if not is_chain(org.get("name", "")):
            all_candidates.append(org)

# FALLBACK: If enrich didn't find anything, try mixed_companies/search
if not all_candidates:
    # 1. Search full venue name
    for a in search_companies({"q_organization_name": venue_name, "per_page": 5}):
        if name_matches(a.get("name", ""), venue_name):
            all_candidates.append(a)

    # 2. Search cleaned name (brand suffixes stripped)
    if clean_name != venue_name and not all_candidates:
        seen_ids = {c.get("id") for c in all_candidates}
        for a in search_companies({"q_organization_name": clean_name, "per_page": 5}):
            if a.get("id") not in seen_ids and name_matches(a.get("name", ""), venue_name):
                all_candidates.append(a)

    # 3. Domain search via mixed_companies (may return empty on new API)
    if website_domain and not all_candidates:
        resp2 = requests.post("${APOLLO_API_BASE}/mixed_companies/search",
            headers=headers,
            json={"q_organization_domains_list": [website_domain], "per_page": 5})
        data2 = resp2.json()
        seen_ids = {c.get("id") for c in all_candidates}
        for a in (data2.get("accounts", []) + data2.get("organizations", [])):
            if a.get("id") not in seen_ids and not is_chain(a.get("name", "")):
                all_candidates.append(a)

    # 4. Short name fallback (first 3 distinctive words)
    if not all_candidates:
        words = [w for w in re.sub(r'[^a-z\s]', '', venue_name.lower()).split()
                 if w not in {'the', 'a', 'an', 'and', 'of', 'at', 'in', 'by', 'hotel'}]
        if len(words) >= 2:
            short_name = ' '.join(words[:3])
            seen_ids = {c.get("id") for c in all_candidates}
            for a in search_companies({"q_organization_name": short_name, "per_page": 5}):
        if a.get("id") not in seen_ids and name_matches(a.get("name", ""), venue_name):
            all_candidates.append(a)

# Pick the best candidate by score
best = None
if all_candidates:
    all_candidates.sort(key=score_candidate, reverse=True)
    # Skip chains
    for c in all_candidates:
        if not is_chain(c.get("name", "")):
            best = c
            break
    if not best:
        best = all_candidates[0]  # last resort

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

    local FOUND DOMAIN ORG_NAME
    FOUND=$(python3 -c "import json; print(json.load(open('$apollo_co_tmpf'))['found'])")
    if [ "$FOUND" = "False" ]; then
        log "  [WARN] No company found in Apollo for '$venue' (tried name + domain)"
        # Still set domain from website for Step 4 LinkedIn enrichment
        APOLLO_DOMAIN="$WEBSITE_DOMAIN"
        log "  Using website domain for enrichment: $APOLLO_DOMAIN"
        return
    fi
    DOMAIN=$(python3 -c "import json; print(json.load(open('$apollo_co_tmpf'))['domain'])")
    ORG_NAME=$(python3 -c "import json; print(json.load(open('$apollo_co_tmpf'))['name'])")
    local ORG_ID=$(python3 -c "import json; print(json.load(open('$apollo_co_tmpf'))['org_id'])")
    log "  Found: $ORG_NAME (domain: $DOMAIN, org_id: $ORG_ID)"

    # Skip if this org was already processed this run (prevents duplicate contacts across venues)
    local SEEN_ORGS_FILE="/tmp/pipeline_seen_orgs"
    if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "None" ] && [ -f "$SEEN_ORGS_FILE" ] && grep -qF "$ORG_ID" "$SEEN_ORGS_FILE" 2>/dev/null; then
        log "  [SKIP] Org $ORG_ID already processed this run — skipping to avoid duplicates"
        APOLLO_DOMAIN="$DOMAIN"
        return
    fi
    if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "None" ]; then
        echo "$ORG_ID" >> "$SEEN_ORGS_FILE"
    fi

    # CRITICAL: If Apollo returned empty domain, fall back to website domain
    if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "None" ]; then
        if [ -n "$WEBSITE_DOMAIN" ]; then
            DOMAIN="$WEBSITE_DOMAIN"
            log "  [WARN] Apollo returned empty domain — using website domain: $DOMAIN"
        else
            log "  [ERROR] No domain from Apollo or website — skipping people search"
            echo "$venue|$venue_id|no domain found" >> "$SKIPPED_VENUES_FILE"
            APOLLO_DOMAIN=""
            return
        fi
    fi

    # Store domain for Step 4 LinkedIn enrichment
    APOLLO_DOMAIN="$DOMAIN"

    # B. Search for people at this company
    log "  Searching for people at $ORG_NAME (org_id: $ORG_ID)..."
    local people_tmpf="/tmp/pipeline_people.json"
    python3 << PYEOF > "$people_tmpf"
import requests, json
all_people = []
org_id = "$ORG_ID"
locations_list = ["Maryland", "Virginia", "Washington, DC", "District of Columbia",
                  "West Virginia", "Pennsylvania", "Delaware"]

def search_people(use_locations=True):
    results = []
    page = 1
    while True:
        search_params = {"per_page": 25, "page": page}
        if use_locations:
            search_params["person_locations"] = locations_list
        if org_id and org_id != "None":
            search_params["organization_ids"] = [org_id]
        else:
            search_params["q_organization_domains_list"] = ["$DOMAIN"]
        resp = requests.post("${APOLLO_API_BASE}/mixed_people/api_search",
            headers={"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"},
            json=search_params)
        data = resp.json()
        people = data.get("people", [])
        if not people:
            break
        for p in people:
            results.append({
                "id": p.get("id", ""),
                "first_name": p.get("first_name", ""),
                "last_name_hint": p.get("last_name_obfuscated", ""),
                "title": p.get("title", ""),
                "has_email": p.get("has_email", False)
            })
        if len(people) < 25:
            break
        page += 1
        if page > 2:
            break
    return results

# Try with location filter first, fall back to no filter
all_people = search_people(use_locations=True)
if not all_people:
    all_people = search_people(use_locations=False)
print(json.dumps(all_people))
PYEOF

    local PEOPLE_COUNT
    PEOPLE_COUNT=$(python3 -c "import json; print(len(json.load(open('$people_tmpf'))))" 2>/dev/null || echo "0")
    if [ -z "$PEOPLE_COUNT" ]; then PEOPLE_COUNT=0; fi
    log "  Found $PEOPLE_COUNT people total"
    if [ "$PEOPLE_COUNT" = "0" ]; then
        log "  No people in Apollo for this company."
        return
    fi
    # Cap at 100 people max (hotels can have large staff)
    if [ "$PEOPLE_COUNT" -gt 100 ]; then
        log "  [WARN] $PEOPLE_COUNT people — capping at 100"
        python3 -c "import json; json.dump(json.load(open('$people_tmpf'))[:100], open('$people_tmpf','w'))"
        PEOPLE_COUNT=100
    fi

    # C. Filter: only skip people whose full name is already known
    local TO_ENRICH
    TO_ENRICH=$(KNAMES="$KNOWN_NAMES" KEMAILS="$KNOWN_EMAILS" APPS_SCRIPT_URL="$APPS_SCRIPT_URL" python3 << 'PYEOF'
import json, os

with open('/tmp/pipeline_people.json') as f:
    people = json.load(f)
known_raw = os.environ.get('KNAMES', '')
known = set(n.strip().lower() for n in known_raw.split('|||') if n.strip())

to_enrich = []
skipped_no_email = 0
skipped_bad_title = 0

# Titles that will never book live music — skip to save Apollo credits
bad_titles = ['housekeep', 'security', 'loss prevention', 'accounting', 'accountant',
    'finance', 'payroll', 'laundry', 'steward', 'engineer', 'maintenance',
    'it ', 'information technology', 'purchasing', 'procurement',
    'human resource', ' hr ', 'recruiter', 'recruitment', 'talent acquisition',
    'spa ', 'spa manager', 'spa director', 'esthetician', 'massage']

# Merge user's skip words from the app (synced to sheet)
import urllib.request
try:
    resp = urllib.request.urlopen(os.environ.get('APPS_SCRIPT_URL','') + '?action=get_skip_words', timeout=10)
    user_skip = json.loads(resp.read()).get('words', [])
    bad_titles.extend(w for w in user_skip if w not in bad_titles)
except Exception as e:
    import sys; print(f'WARN: skip_words fetch failed: {e}', file=sys.stderr)

def title_is_relevant(title):
    t = title.lower()
    for bad in bad_titles:
        if bad in t:
            return False
    return True

for p in people:
    first = p.get('first_name', '').strip()
    if not first:
        continue
    # Skip irrelevant job titles (housekeeping, IT, security, etc.)
    title = p.get('title', '') or ''
    if title and not title_is_relevant(title):
        skipped_bad_title += 1
        continue
    if not p.get('has_email', False):
        # Still add decision-makers as pending contacts (reachable via other channels)
        decision_words = {'owner','founder','president','partner','director','manager',
            'general manager','gm','ceo','coo','events','entertainment','booking',
            'operations','chef','proprietor','managing','beverage'}
        t = title.lower()
        if any(w in t for w in decision_words):
            print(f"PENDING:::{first}:::{p.get('last_name_hint','')}:::{title}")
        skipped_no_email += 1
        continue
    to_enrich.append(p)

if skipped_no_email:
    print(f"SKIPPED_NO_EMAIL:{skipped_no_email}", flush=True)
if skipped_bad_title:
    print(f"SKIPPED_BAD_TITLE:{skipped_bad_title}", flush=True)

for p in to_enrich:
    print(f"{p['id']}:::{p['first_name']}:::{p['title']}")
PYEOF
    )

    # Log skipped people with no email
    local SKIP_COUNT
    SKIP_COUNT=$(echo "$TO_ENRICH" | grep "SKIPPED_NO_EMAIL:" | sed 's/SKIPPED_NO_EMAIL://')
    if [ -n "$SKIP_COUNT" ] && [ "$SKIP_COUNT" -gt 0 ] 2>/dev/null; then
        log "  Skipped $SKIP_COUNT people with no email (red ? on Apollo)"
    fi
    # Log skipped bad titles
    local SKIP_TITLE_COUNT
    SKIP_TITLE_COUNT=$(echo "$TO_ENRICH" | grep "SKIPPED_BAD_TITLE:" | sed 's/SKIPPED_BAD_TITLE://')
    if [ -n "$SKIP_TITLE_COUNT" ] && [ "$SKIP_TITLE_COUNT" -gt 0 ] 2>/dev/null; then
        log "  Skipped $SKIP_TITLE_COUNT people with irrelevant titles (housekeeping, IT, security, etc.)"
    fi
    # Process PENDING contacts (decision-makers without email — add as pending)
    echo "$TO_ENRICH" | grep "^PENDING:::" | while IFS= read -r line; do
        local PFIRST PLAST PTITLE PNAME
        PFIRST=$(echo "$line" | awk -F':::' '{print $2}')
        PLAST=$(echo "$line" | awk -F':::' '{print $3}')
        PTITLE=$(echo "$line" | awk -F':::' '{print $4}')
        PNAME="$PFIRST"
        if [ -n "$PLAST" ] && [ "$PLAST" != "None" ]; then
            PNAME="$PFIRST $PLAST"
        fi
        log "  +++ $PNAME ($PTITLE): no email — added as pending"
        local encoded
        encoded=$(python3 -c "
import urllib.parse, sys
print(urllib.parse.urlencode({
    'action': 'add_contact',
    'venue_id': sys.argv[1],
    'name': sys.argv[2],
    'title': sys.argv[3],
    'source': 'apollo',
    'verified': 'pending'
}))" "$venue_id" "$PNAME" "$PTITLE")
        curl -sL "${APPS_SCRIPT_URL}?${encoded}" > /dev/null
        KNOWN_NAMES="${KNOWN_NAMES}|||$(echo "$PNAME" | tr '[:upper:]' '[:lower:]')"
    done

    # Remove the SKIPPED and PENDING lines from TO_ENRICH
    TO_ENRICH=$(echo "$TO_ENRICH" | grep -v "SKIPPED_NO_EMAIL:" | grep -v "SKIPPED_BAD_TITLE:" | grep -v "^PENDING:::")

    if [ -z "$TO_ENRICH" ]; then
        log "  No new people to enrich (but pending contacts may have been added above)."
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
    ENCODED_VENUE=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$venue")

    # Use the domain found in Step 3, or fall back to website domain
    local DOMAIN="$APOLLO_DOMAIN"
    if [ -z "$DOMAIN" ]; then
        # Fall back to website domain from the sheet
        local li_domain_tmpf="/tmp/pipeline_li_domain.json"
        curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$li_domain_tmpf" 2>/dev/null
        DOMAIN=$(python3 -c "
import json, re
with open('$li_domain_tmpf') as f: d = json.load(f)
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

        # Wait for results (text-based detection — LinkedIn obfuscates DOM selectors)
        local COUNT=0
        for RETRY in 1 2 3 4 5; do
            COUNT=$(osascript -e '
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var main = document.querySelector(\"main\");
            if (!main) return 0;
            var text = main.innerText;
            var lines = text.split(\"\\n\").map(function(l){return l.trim()}).filter(function(l){return l.length > 0});
            var count = 0;
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].match(/^\\s*[•·]\\s*(1st|2nd|3rd|\\d+th)/) || lines[i] === \"LinkedIn Member\") count++;
            }
            return count;
        })()
    "
end tell' 2>/dev/null)
            if [ "$COUNT" -gt 0 ] 2>/dev/null; then break; fi
            sleep 2
        done

        if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
            log "  No results on page $PAGE — stopping."
            break
        fi
        log "  Found $COUNT results"

        # Extract people with names and titles (text-based parsing)
        local PAGE_JSON
        PAGE_JSON=$(osascript -e '
tell application "Google Chrome"
    execute active tab of front window javascript "
        (function() {
            var main = document.querySelector(\"main\");
            if (!main) return \"[]\";
            var text = main.innerText;
            var lines = text.split(\"\\n\").map(function(l){return l.trim()}).filter(function(l){return l.length > 0});
            var results = [];
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].match(/^\\s*[•·]\\s*(1st|2nd|3rd|\\d+th)/)) {
                    var name = (i > 0) ? lines[i-1] : \"\";
                    var title = (i+1 < lines.length) ? lines[i+1] : \"\";
                    if (name && !name.startsWith(\"Results for\")) {
                        name = name.replace(/,\\s*(CCM|PGA|SHRM|CPA|MBA|PHR|SPHR|CEC|CMC|CEBS).*/i, \"\").trim();
                        var isCurrent = !title.toLowerCase().includes(\"past:\") && !title.toLowerCase().startsWith(\"former\");
                        results.push(JSON.stringify({name:name, title:title.substring(0,120), current:isCurrent}));
                    }
                }
                if (lines[i] === \"LinkedIn Member\" && i+1 < lines.length) {
                    var title2 = lines[i+1] || \"\";
                    var isCurrent2 = !title2.toLowerCase().includes(\"past:\") && !title2.toLowerCase().startsWith(\"former\");
                    results.push(JSON.stringify({name:\"LinkedIn Member\", title:title2.substring(0,120), current:isCurrent2}));
                }
            }
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

known_names_raw = '''$KNOWN_NAMES'''
known_names = set(n.strip() for n in known_names_raw.split('|||') if n.strip())

# Keep people with decision-making or booking-relevant titles
keep_words = {'owner','founder','president','partner','principal','director',
    'manager','coordinator','executive','officer','ceo','coo','cfo','gm',
    'general manager','events','event','entertainment','booking','hospitality',
    'marketing','operations','membership','food','beverage','catering',
    'sales','development','curator','artistic','program','sommelier',
    'winemaker','viticulturist','head','chef','proprietor','managing'}
# Skip roles that are clearly not relevant
skip_words = {'intern','student','volunteer','accountant','attorney','lawyer',
    'developer','engineer','software','designer','it ','data','analyst',
    'junior','assistant brewer','busser','server','host','bartender','cook'}

for p in data:
    if not p.get('current', True): continue
    title_lower = p['title'].lower()
    if any(s in title_lower for s in skip_words): continue
    if not any(k in title_lower for k in keep_words): continue
    name = p['name'].strip()
    name_lower = name.lower()
    if name_lower in known_names or name_lower == '?': continue
    # Reject masked/obfuscated names (e.g. "General Ma***r", "LinkedIn Member")
    if '***' in name or name_lower == 'linkedin member': continue
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
        echo "0" > /tmp/pipeline_li_found_count
        return
    fi

    local TOTAL_FOUND
    TOTAL_FOUND=$(echo "$ALL_LINKEDIN_PEOPLE" | wc -l | tr -d ' ')
    echo "$TOTAL_FOUND" > /tmp/pipeline_li_found_count
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
# REPORT GENERATION — produces HTML report from pipeline.log
# =================================================================
generate_report() {
    local RUN_START_LINE="$1"  # Line number in log where this run started
    local REPORT_DIR="${SCRIPT_DIR}/reports"
    local REPORT_TS=$(date '+%Y-%m-%d_%H-%M')
    local REPORT_DATE=$(date '+%Y-%m-%d')
    local REPORT_TITLE=$(date '+%B %d, %Y at %H:%M')
    local REPORT_FILE="${REPORT_DIR}/${REPORT_TS}.html"
    local MANIFEST_FILE="${REPORT_DIR}/manifest.json"

    mkdir -p "$REPORT_DIR"

    log ""
    log "Generating report: $REPORT_FILE"

    # Extract this run's log section (from RUN_START_LINE to end)
    local RUN_LOG="/tmp/pipeline_run_log.txt"
    tail -n "+${RUN_START_LINE}" "$LOG_FILE" > "$RUN_LOG"

    # Parse log data with Python
    python3 - "$RUN_LOG" "$REPORT_FILE" "$REPORT_TITLE" "$REPORT_DATE" "$REPORT_TS" "$MANIFEST_FILE" "$REPORT_DIR" << 'PYEOF'
import sys, re, os, json, glob
from datetime import datetime

run_log_path = sys.argv[1]
report_file = sys.argv[2]
report_title = sys.argv[3]
report_date = sys.argv[4]
report_ts = sys.argv[5]
manifest_file = sys.argv[6]
report_dir = sys.argv[7]

with open(run_log_path) as f:
    lines = f.readlines()

# --- Parse venues from log ---
venues = []
current_venue = None
total_credits = 0
flags = []

for line in lines:
    line = line.rstrip('\n')
    text = line[9:] if len(line) > 9 else line  # strip timestamp

    # Smart Pick header
    m = re.search(r'SMART PICK #(\d+) \(score (\d+)\): (.+?) \(([^)]+)\)', text)
    # Untouched venue header
    m2 = re.search(r'UNTOUCHED #(\d+): (.+?) \(([^)]+)\)', text) if not m else None
    # Batch venue header: "VENUE [1/11]: Name"
    m_batch = re.search(r'VENUE \[\d+/\d+\]: (.+?)$', text) if not m and not m2 else None
    # Batch/single venue header: " PIPELINE: Name (venue_id)"
    m3 = re.search(r'PIPELINE: (.+?) \(([^)]+)\)', text) if not m and not m2 and not m_batch and not current_venue else None
    if m or m2 or m_batch or m3:
        if current_venue:
            venues.append(current_venue)
        if m:
            current_venue = {
                'pick_num': 0,  # renumbered globally after parsing
                'score': int(m.group(2)),
                'name': m.group(3),
                'venue_id': m.group(4),
                'phase': 'smart_pick',
            }
        elif m2:
            current_venue = {
                'pick_num': 0,  # renumbered globally after parsing
                'score': 0,
                'name': m2.group(2),
                'venue_id': m2.group(3),
                'phase': 'untouched',
            }
        elif m_batch:
            current_venue = {
                'pick_num': 0,  # renumbered globally after parsing
                'score': 0,
                'name': m_batch.group(1).strip(),
                'venue_id': '',  # filled in by PIPELINE: line
                'phase': 'batch',
            }
        else:
            current_venue = {
                'pick_num': 0,  # renumbered globally after parsing
                'score': 0,
                'name': m3.group(1),
                'venue_id': m3.group(2),
                'phase': 'batch',
            }
        current_venue.update({
            'website': '',
            'facebook': '',
            'instagram': '',
            'contact_form': '',
            'contacts': [],
            'apollo_credits': 0,
            'elapsed_min': 0,
            'flags': [],
            'category': ''
        })
        # Derive category from venue_id (e.g. MD-WINE-020 -> winery)
        cat_map = {
            'WINE': 'winery', 'HOTE': 'hotel', 'COUN': 'country_club',
            'REST': 'restaurant', 'EVEN': 'event', 'MUSE': 'museum',
            'RESO': 'resort', 'SENI': 'senior_living', 'GOLF': 'golf_club',
            'YACH': 'yacht_club', 'ARTG': 'art_gallery', 'ART_': 'art_gallery',
            'LUXU': 'luxury_apts', 'WEDD': 'wedding_venue', 'CORP': 'corporate',
            'SPAA': 'spa', 'PRIV': 'private_club', 'CHUR': 'church',
            'MALL': 'mall', 'GROC': 'grocery_market', 'BREW': 'brewery',
            'DIST': 'distillery', 'LIBR': 'library', 'TEAR': 'tea_room',
            'SYNA': 'synagogue', 'BARR': 'bar', 'MUSI': 'music_venue',
            'FARM': 'farmers_market', 'THEA': 'theater',
        }
        parts = current_venue['venue_id'].split('-')
        if len(parts) >= 2:
            current_venue['category'] = cat_map.get(parts[1], parts[1].lower())
        # Name-based override: catch hotels misclassified as restaurants
        if current_venue['category'] == 'restaurant':
            nl = current_venue['name'].lower()
            hotel_names = ['hotel', 'inn ', ' inn', 'resort', 'lodge', 'waldorf',
                           'conrad', 'sofitel', 'pendry', 'salamander', 'lyle',
                           'the line ', 'the jefferson', 'yours truly',
                           'ritz-carlton', 'four seasons', 'fairmont', 'mandarin',
                           'st. regis', 'w hotel', 'westin', 'hyatt', 'marriott',
                           'hilton', 'intercontinental', 'kimpton', 'rosewood',
                           'peninsula', 'langham', 'omni', 'loews']
            if any(t in nl for t in hotel_names):
                current_venue['category'] = 'hotel'
        continue

    if not current_venue:
        continue

    # Fill in venue_id from PIPELINE: line for batch-mode venues
    if not current_venue['venue_id']:
        m_pid = re.search(r'PIPELINE: .+? \(([^)]+)\)', text)
        if m_pid:
            current_venue['venue_id'] = m_pid.group(1)
            # Derive category from venue_id
            parts = current_venue['venue_id'].split('-')
            if len(parts) >= 2:
                cat_map = {
                    'WINE': 'winery', 'HOTE': 'hotel', 'COUN': 'country_club',
                    'REST': 'restaurant', 'EVEN': 'event', 'MUSE': 'museum',
                    'PRIV': 'private_club', 'GOLF': 'golf_club', 'YACH': 'yacht_club',
                    'ARTG': 'art_gallery', 'ART_': 'art_gallery', 'RESO': 'resort',
                    'SENI': 'senior_living', 'LUXU': 'luxury_apts', 'SPAA': 'spa',
                    'CHUR': 'church', 'BREW': 'brewery', 'DIST': 'distillery',
                    'LIBR': 'library', 'SYNA': 'synagogue', 'BARR': 'bar',
                    'MUSI': 'music_venue', 'FARM': 'farmers_market', 'THEA': 'theater',
                }
                current_venue['category'] = cat_map.get(parts[1], parts[1].lower())

    # Website
    m = re.match(r'\s*Website:\s*(.+)', text)
    if m:
        current_venue['website'] = m.group(1).strip()

    # Emails/FB/IG from Step 1
    m = re.search(r'Emails: \d+ \| FB: (\S+) \| IG: (\S+)', text)
    if m:
        fb_val = m.group(1)
        ig_val = m.group(2)
        if fb_val != 'none' and not current_venue['facebook']:
            current_venue['facebook'] = fb_val
        if ig_val != 'none' and not current_venue['instagram']:
            current_venue['instagram'] = ig_val

    # Contact form
    m = re.search(r'Contact Form: (\S+)', text)
    if m and m.group(1) != 'none':
        current_venue['contact_form'] = m.group(1)

    # IG search result
    m = re.search(r'\[IG SEARCH\] Found: (\S+)', text)
    if m and not current_venue['instagram']:
        current_venue['instagram'] = m.group(1)

    # FB/IG from Step 2 (format: "  FB: URL | IG: URL")
    m = re.match(r'\s*FB: (\S+) \| IG: (\S+)', text)
    if m:
        if m.group(1) != 'none' and not current_venue['facebook']:
            current_venue['facebook'] = m.group(1)
        if m.group(2) != 'none' and not current_venue['instagram']:
            current_venue['instagram'] = m.group(2)

    # Contact added with valid status: "Added: Name <email>"
    m = re.search(r'Added(?:\s+\([^)]+\))?: (.+?) <(.+?)>', text)
    if m:
        cname = m.group(1).strip()
        cemail = m.group(2).strip()
        # Determine status from context
        cstatus = 'valid'
        if 'invalid' in text:
            cstatus = 'invalid'
        elif 'catch-all' in text:
            cstatus = 'catch-all'
        elif 'unknown' in text:
            cstatus = 'unknown'
        elif 'do_not_mail' in text:
            cstatus = 'do_not_mail'
        # Find title from preceding >>> line
        ctitle = ''
        current_venue['contacts'].append({
            'name': cname,
            'email': cemail,
            'status': cstatus,
            'title': ctitle
        })

    # Apollo enriched contact with title: ">>> Name (Title): email [status]"
    m = re.search(r'>>> (.+?) \((.+?)\): (\S+@\S+) \[(\w+)\]', text)
    if m:
        aname = m.group(1).strip()
        atitle = m.group(2).strip()
        if atitle == 'None':
            atitle = ''
        aemail = m.group(3).strip()
        astatus = m.group(4).strip()
        # Store title for the contact that will be added next
        for c in reversed(current_venue['contacts']):
            if c['email'] == aemail:
                c['title'] = atitle
                break
        else:
            # Not yet added (will be on next line), store for lookup
            current_venue['_pending_title'] = {aemail: atitle}

    # Contact with no email: "--- Name (Title): no email"
    m = re.search(r'--- (.+?) \((.+?)\): no email', text)
    if m:
        current_venue['contacts'].append({
            'name': m.group(1).strip(),
            'email': '',
            'status': 'no_email',
            'title': m.group(2).strip() if m.group(2) != 'None' else ''
        })

    # Apollo credits
    m = re.search(r'Apollo API done: (\d+) credits', text)
    if m:
        current_venue['apollo_credits'] = int(m.group(1))
        total_credits += int(m.group(1))

    # Done line with elapsed time
    m = re.search(r'DONE: .+ \| (\d+) min \|', text)
    if m:
        current_venue['elapsed_min'] = int(m.group(1))

    # Bad lookup
    m = re.search(r'\[LOOKUP\] Found: (.+)', text)
    if m:
        url = m.group(1).strip()
        # Flag suspicious lookups
        bad_domains = ['dictionary.com', 'fandom', 'wikipedia', 'yelp.com', 'tripadvisor']
        for bd in bad_domains:
            if bd in url.lower():
                current_venue['flags'].append(
                    f'Bad Website Lookup: Google found {url}')

    # Apollo mismatch warnings
    m = re.search(r'\[WARN\] .+', text)
    if m:
        warn_text = m.group(0)
        if 'empty domain' in warn_text or 'suspicious' in warn_text:
            current_venue['flags'].append(warn_text)

    # No website found
    if '[LOOKUP] No website found via Google' in text:
        current_venue['flags'].append('No website found via Google search')

    # Skipped venues
    if 'SKIPPED VENUES' in text:
        pass  # Handled separately

    # SKIP already in sheet
    m = re.search(r'\[SKIP\] (.+?) — already in sheet', text)
    if m:
        pass  # Known duplicate, not a flag

# Backfill titles from >>> lines into contacts
for v in venues + ([current_venue] if current_venue else []):
    if not v:
        continue
    pending = v.pop('_pending_title', {})
    for email, title in pending.items():
        for c in v['contacts']:
            if c['email'] == email and not c['title']:
                c['title'] = title

if current_venue:
    venues.append(current_venue)

# Also do a second pass to attach titles from >>> lines
# Re-read log and build email->title map per venue
venue_idx = -1
title_map = {}
for line in lines:
    text = line.rstrip('\n')
    t = text[9:] if len(text) > 9 else text
    if 'SMART PICK #' in t or 'UNTOUCHED #' in t or re.search(r'PIPELINE: .+ \([^)]+\)', t):
        venue_idx += 1
        title_map = {}
    if venue_idx < 0 or venue_idx >= len(venues):
        continue
    m = re.search(r'>>> (.+?) \((.+?)\): (\S+@\S+)', t)
    if m:
        title_map[m.group(3).strip()] = m.group(2).strip()
    # Apply to contacts
    for c in venues[venue_idx]['contacts']:
        if c['email'] in title_map and not c['title']:
            ttl = title_map[c['email']]
            c['title'] = '' if ttl == 'None' else ttl

# --- Override social links from sheet (log data is often stale/wrong) ---
import subprocess as _sp
import urllib.parse as _up
_API = os.environ.get('APPS_SCRIPT_URL', '')
if not _API:
    # Try to read from script
    try:
        with open(os.path.join(os.path.dirname(run_log_path), 'discover.sh')) as _f:
            for _line in _f:
                if 'APPS_SCRIPT_URL=' in _line and 'http' in _line:
                    _API = _line.split('"')[1]
                    break
    except Exception as e:
        import sys; print(f'WARN: discover.sh API parse failed: {e}', file=sys.stderr)
if _API:
    for v in venues:
        vid = v.get('venue_id', '')
        if not vid:
            continue
        try:
            _r = _sp.run(['curl', '-sL', '--max-time', '10', f'{_API}?action=venue_detail&venue_id={vid}'],
                         capture_output=True, text=True, timeout=15)
            _d = json.loads(_r.stdout).get('venue', {})
            if _d.get('facebook'):
                v['facebook'] = _d['facebook']
            if _d.get('instagram'):
                v['instagram'] = _d['instagram']
            if _d.get('website'):
                v['website'] = _d['website']
            if _d.get('contact_form') and not v.get('contact_form'):
                v['contact_form'] = _d['contact_form']
        except Exception as e:
            import sys; print(f'WARN: venue_detail fetch failed for {vid}: {e}', file=sys.stderr)

# --- Post-parse smart flags ---
for v in venues:
    # No contacts at all
    if not v['contacts']:
        v['flags'].append('No contacts found')
    else:
        # All emails are catch-all or worse (no verified)
        statuses = [c['status'] for c in v['contacts']]
        if 'valid' not in statuses:
            v['flags'].append('No verified emails — only ' + ', '.join(set(statuses)))
        # Email from a different domain (PR firm, generic platform)
        vdomain = ''
        if v['website']:
            try:
                vdomain = v['website'].split('//')[1].split('/')[0].replace('www.', '').lower()
            except Exception:
                vdomain = ''
        if vdomain:
            # Strip TLD for fuzzy matching (winelair.us == winelair.com)
            vbase = vdomain.rsplit('.', 1)[0] if '.' in vdomain else vdomain
            for c in v['contacts']:
                edomain = c['email'].split('@')[1].lower() if '@' in c['email'] else ''
                if edomain and edomain != vdomain:
                    ebase = edomain.rsplit('.', 1)[0] if '.' in edomain else edomain
                    # Skip if base domains match (same company, different TLD)
                    if ebase == vbase:
                        continue
                    # Skip common email providers
                    generic = ['gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com', 'aol.com']
                    if edomain not in generic:
                        v['flags'].append(f'Off-domain email: {c["email"]} (venue: {vdomain})')

# --- Compute stats ---
total_venues = len(venues)
total_verified = sum(
    1 for v in venues for c in v['contacts'] if c['status'] == 'valid')
total_contacts = sum(len(v['contacts']) for v in venues)

# Compute runtime from first PIPELINE start to last DONE
run_start = None
run_end = None
for line in lines:
    m = re.search(r'(\d{2}:\d{2}:\d{2})\s+.*Pipeline started', line)
    if m and not run_start:
        run_start = m.group(1)
    m = re.search(r'(\d{2}:\d{2}:\d{2})\s+DONE:', line)
    if m:
        run_end = m.group(1)
    m = re.search(r'(\d{2}:\d{2}:\d{2})\s+=== SMART PICKS COMPLETE', line)
    if m:
        run_end = m.group(1)

if run_start and run_end:
    try:
        t1 = datetime.strptime(run_start, '%H:%M:%S')
        t2 = datetime.strptime(run_end, '%H:%M:%S')
        diff = (t2 - t1).total_seconds() / 60
        runtime_str = f'~{int(diff)} minutes'
    except Exception as e:
        import sys; print(f'WARN: runtime parse failed: {e}', file=sys.stderr)
        runtime_str = 'unknown'
else:
    runtime_str = 'unknown'

# Parse skipped venues from log
skipped = []
in_skipped = False
for line in lines:
    text = line.rstrip('\n')
    t = text[9:] if len(text) > 9 else text
    if 'SKIPPED VENUES' in t:
        in_skipped = True
        continue
    if in_skipped and '=====' in t:
        in_skipped = False
        continue
    if in_skipped:
        m = re.search(r'(.+?) \(([^)]+)\) — (.+)', t.strip())
        if m:
            skipped.append({
                'name': m.group(1).replace('✗ ', ''),
                'venue_id': m.group(2),
                'reason': m.group(3)
            })

# --- Build HTML ---
def esc(s):
    return (s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def status_html(s):
    if s == 'valid':
        return '<span class="valid">&#10003; valid</span>'
    elif s == 'invalid':
        return '<span style="color:#e85050">&#10007; invalid</span>'
    elif s == 'catch-all':
        return '<span class="unknown">&#8776; catch-all</span>'
    elif s == 'unknown':
        return '<span class="unknown">? unknown</span>'
    elif s == 'do_not_mail':
        return '<span style="color:#e85050">&#10007; do_not_mail</span>'
    elif s == 'no_email':
        return '<span style="color:#666">no email</span>'
    else:
        return f'<span style="color:#999">{esc(s)}</span>'

html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Outreach Run Report &mdash; {esc(report_title)}</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: 'Georgia', serif;
    background: #0c1a22;
    color: #e0e0e0;
    padding: 40px;
    max-width: 900px;
    margin: 0 auto;
    line-height: 1.6;
  }}
  h1 {{
    color: #6ecfcf;
    font-size: 1.8rem;
    margin-bottom: 5px;
    border-bottom: 2px solid #6ecfcf;
    padding-bottom: 10px;
  }}
  .date {{ color: #999; margin-bottom: 30px; font-size: 0.95rem; }}
  h2 {{
    color: #e8944c;
    font-size: 1.3rem;
    margin: 30px 0 15px;
    border-left: 4px solid #e8944c;
    padding-left: 12px;
  }}
  h3 {{
    color: #6ecfcf;
    font-size: 1.1rem;
    margin: 20px 0 10px;
  }}
  table {{
    width: 100%;
    border-collapse: collapse;
    margin: 15px 0;
    font-size: 0.9rem;
  }}
  th {{
    background: #1a2e3a;
    color: #6ecfcf;
    padding: 10px 12px;
    text-align: left;
    font-weight: 600;
  }}
  td {{
    padding: 8px 12px;
    border-bottom: 1px solid #1a2e3a;
  }}
  tr:hover {{ background: rgba(110, 207, 207, 0.05); }}
  .stat-grid {{
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 15px;
    margin: 15px 0;
  }}
  .stat-box {{
    background: #1a2e3a;
    border-radius: 8px;
    padding: 15px;
    text-align: center;
  }}
  .stat-box .num {{
    font-size: 2rem;
    font-weight: bold;
    color: #6ecfcf;
  }}
  .stat-box .label {{
    font-size: 0.85rem;
    color: #999;
    margin-top: 4px;
  }}
  .flag-list {{
    list-style: none;
    padding: 0;
    margin: 10px 0;
  }}
  .flag-list li {{
    background: #2a1a1a;
    border-left: 4px solid #e85050;
    padding: 10px 14px;
    margin: 6px 0;
    border-radius: 0 6px 6px 0;
    font-size: 0.9rem;
  }}
  .flag {{
    background: #2a1a1a;
    border-left: 4px solid #e85050;
    padding: 10px 14px;
    margin: 8px 0;
    border-radius: 0 6px 6px 0;
    font-size: 0.9rem;
  }}
  .flag strong {{ color: #e85050; }}
  .contact-name {{ color: #6ecfcf; }}
  .valid {{ color: #4caf50; }}
  .unknown {{ color: #ff9800; }}
  .score {{
    display: inline-block;
    background: #e8944c;
    color: #0c1a22;
    font-weight: bold;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 0.85rem;
  }}
  .category-pill {{
    display: inline-block;
    background: #1a2e3a;
    color: #6ecfcf;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 0.8rem;
  }}
  .social-links {{
    font-size: 0.85rem;
    color: #999;
    margin: 5px 0 10px;
  }}
  .social-links a {{
    color: #6ecfcf;
    text-decoration: none;
  }}
  .social-links a:hover {{
    text-decoration: underline;
  }}
  @media print {{
    body {{ background: #fff; color: #222; padding: 20px; }}
    h1 {{ color: #1a5c5c; border-color: #1a5c5c; }}
    h2 {{ color: #b06a2a; border-color: #b06a2a; }}
    h3 {{ color: #1a5c5c; }}
    th {{ background: #eee; color: #333; }}
    td {{ border-color: #ddd; }}
    .stat-box {{ background: #f5f5f5; border: 1px solid #ddd; }}
    .stat-box .num {{ color: #1a5c5c; }}
    .flag {{ background: #fff0f0; border-color: #cc3333; }}
    .flag strong {{ color: #cc3333; }}
    .flag-list li {{ background: #fff0f0; border-color: #cc3333; }}
    .contact-name {{ color: #1a5c5c; }}
    .score {{ background: #e8944c; }}
    .category-pill {{ background: #eee; color: #333; }}
    tr:hover {{ background: none; }}
  }}
</style>
</head>
<body>

<h1>Outreach Run Report</h1>
<div class="date">{esc(report_title)} &bull; Runtime: {runtime_str}</div>
'''

# Flags section — grouped by venue
from collections import OrderedDict
flag_groups = OrderedDict()
for v in venues:
    vflags = v.get('flags', [])
    if vflags:
        flag_groups[v['name']] = [esc(fl) for fl in vflags]
for s in skipped:
    sname = f'{s["name"]} ({s["venue_id"]})'
    flag_groups.setdefault(sname, []).append(f'Skipped &mdash; {esc(s["reason"])}')

if flag_groups:
    html += '<h2>Flagged for Review</h2>\n'
    html += '<ul class="flag-list">\n'
    for venue_name, flags in flag_groups.items():
        reasons = '; '.join(flags)
        html += f'  <li><strong>{esc(venue_name)}</strong> &mdash; {reasons}</li>\n'
    html += '</ul>\n'

# Stat boxes
html += f'''
<div class="stat-grid">
  <div class="stat-box">
    <div class="num">{total_venues}</div>
    <div class="label">Venues Pipelined</div>
  </div>
  <div class="stat-box">
    <div class="num">{total_verified}</div>
    <div class="label">Verified Emails</div>
  </div>
  <div class="stat-box">
    <div class="num">{total_credits}</div>
    <div class="label">Apollo Credits Used</div>
  </div>
</div>
'''

# Renumber venues globally across all phases
for i, v in enumerate(venues):
    v['pick_num'] = i + 1

# Per-venue sections
html += '<h2>Pipeline Results</h2>\n'

for v in venues:
    cat_html = f' <span class="category-pill">{esc(v["category"])}</span>' if v['category'] else ''
    phase = v.get('phase', 'smart_pick')
    if phase == 'untouched':
        score_html = '<span class="score" style="background:#6ecfcf">Untouched</span>'
    else:
        score_html = f'<span class="score">Score: {v["score"]}</span>'
    app_url = f'https://atdi1029-byte.github.io/gig-outreach/?venue={v["venue_id"]}'
    html += f'<h3>{v["pick_num"]}. <a href="{app_url}" style="color:#6ecfcf;text-decoration:none">{esc(v["name"])}</a> {score_html}{cat_html}</h3>\n'

    # Social/website links
    links = []
    if v['website']:
        links.append(f'<a href="{esc(v["website"])}">Website</a>')
    if v['facebook']:
        links.append(f'<a href="{esc(v["facebook"])}">Facebook</a>')
    if v['instagram']:
        links.append(f'<a href="{esc(v["instagram"])}">Instagram</a>')
    if v['contact_form']:
        links.append(f'<a href="{esc(v["contact_form"])}">Contact Form</a>')
    if links:
        html += f'<div class="social-links">{" &bull; ".join(links)}</div>\n'

    if not v['contacts']:
        html += '<div style="color:#999;font-size:0.9rem;margin:10px 0">No contacts found.</div>\n'
    else:
        # Determine if contacts have titles (Apollo) or just emails (website)
        has_titles = any(c['title'] for c in v['contacts'])
        if has_titles:
            html += '<table>\n<thead><tr><th>Contact</th><th>Title</th><th>Email</th><th>Status</th></tr></thead>\n<tbody>\n'
            for c in v['contacts']:
                name_display = esc(c['name']) if c['name'] else '(no name)'
                email_display = esc(c['email']) if c['email'] else '&mdash;'
                html += f'<tr><td class="contact-name">{name_display}</td><td>{esc(c["title"])}</td><td>{email_display}</td><td>{status_html(c["status"])}</td></tr>\n'
        else:
            html += '<table>\n<thead><tr><th>Contact</th><th>Email</th><th>Status</th></tr></thead>\n<tbody>\n'
            for c in v['contacts']:
                name_display = esc(c['name']) if c['name'] else '(no name)'
                email_display = esc(c['email']) if c['email'] else '&mdash;'
                html += f'<tr><td class="contact-name">{name_display}</td><td>{email_display}</td><td>{status_html(c["status"])}</td></tr>\n'
        html += '</tbody>\n</table>\n'

    # Venue stats
    elapsed_str = f'{v["elapsed_min"]} min' if v['elapsed_min'] else '<1 min'
    credits_str = f'{v["apollo_credits"]} credits' if v['apollo_credits'] else 'none'
    html += f'<div style="font-size:0.8rem;color:#666;margin-top:5px">Runtime: {elapsed_str} | Apollo credits: {credits_str}</div>\n'

html += '''
</body>
</html>
'''

# Write report
with open(report_file, 'w') as f:
    f.write(html)

# Build summary for manifest
summary_parts = []
summary_parts.append(f'{total_venues} venues pipelined')
summary_parts.append(f'{total_verified} verified emails')
if total_credits:
    summary_parts.append(f'{total_credits} Apollo credits')
summary_text = ', '.join(summary_parts)

# Update manifest.json — read existing, prepend new entry, write back
manifest = []
if os.path.exists(manifest_file):
    try:
        with open(manifest_file) as f:
            manifest = json.load(f)
    except Exception as e:
        import sys; print(f'WARN: manifest.json parse failed: {e}', file=sys.stderr)
        manifest = []

# Add new report entry (prepend so newest is first)
new_entry = {
    'file': f'{report_ts}.html',
    'date': report_date,
    'title': report_title,
    'summary': summary_text,
    'venues': total_venues,
    'verified_emails': total_verified,
    'apollo_credits': total_credits
}
manifest.insert(0, new_entry)

with open(manifest_file, 'w') as f:
    json.dump(manifest, f, indent=2)

print(f'Report generated: {report_file}')
print(f'Manifest updated: {len(manifest)} reports')
PYEOF

    log "Report saved: $REPORT_FILE"

    # Auto-cleanup: remove reports older than 30 days
    local CUTOFF_DATE=$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null)
    if [ -n "$CUTOFF_DATE" ]; then
        local CLEANED=0
        python3 - "$MANIFEST_FILE" "$CUTOFF_DATE" "$REPORT_DIR" << 'CLEANPY'
import json, sys, os

manifest_file = sys.argv[1]
cutoff = sys.argv[2]
report_dir = sys.argv[3]

with open(manifest_file, 'r') as f:
    manifest = json.load(f)

keep = []
removed = 0
for entry in manifest:
    if entry.get('date', '9999') < cutoff:
        fpath = os.path.join(report_dir, entry['file'])
        if os.path.exists(fpath):
            os.remove(fpath)
            removed += 1
    else:
        keep.append(entry)

if removed > 0:
    with open(manifest_file, 'w') as f:
        json.dump(keep, f, indent=2)
    print(f"Cleaned up {removed} old reports (before {cutoff})")
else:
    print("No old reports to clean up")
CLEANPY
    fi
}

# =================================================================
# STEP 5: GOOGLE FALLBACK (when all other steps found no email)
# Searches Google for the venue website and scrapes it for emails.
# Also re-tries Instagram search with city appended (catches cases
# where the IG handle doesn't match the venue name, e.g. a parent
# farm name like @tranquilityfarmvirginia for "Otium Cellars").
# =================================================================
step5_google_fallback() {
    local venue="$1" venue_id="$2" city="$3"

    local email_count
    email_count=$(wc -l < /tmp/pipeline_contacts_count 2>/dev/null || echo 0)
    if [ "$email_count" -gt 0 ] || [ "$(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)" -gt 0 ]; then
        return  # Already have emails — skip
    fi

    log ""
    log "========== STEP 5: Google Fallback (no email found yet) =========="

    # --- 5A: Find real website via Google and scrape for email ---
    local SEARCH_ENCODED
    SEARCH_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote('\"' + sys.argv[1] + '\" contact' + (' ' + sys.argv[2] if sys.argv[2] else '')))" "$venue" "$city")
    log "  Googling: \"$venue\" contact $city"
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
    sleep 4

    local found_site
    found_site=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_cite.js"'")' 2>/dev/null)

    if [ -n "$found_site" ] && [ "$found_site" != "missing value" ] && [ "$found_site" != "" ]; then
        # Google can return directories/tourism pages first. Choose only a URL that
        # plausibly belongs to this exact venue.
        found_site=$(python3 "${SCRIPT_DIR}/venue_quality.py" choose-website "$venue" "$found_site" 2>/dev/null)
        if [ -z "$found_site" ]; then
            log "  [FALLBACK] Search results did not contain a trustworthy venue website"
        fi
        local found_domain
        found_domain=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${found_site}').netloc.lower().replace('www.',''))" 2>/dev/null)
        if [ -n "$found_domain" ] && [ "$found_domain" != "$VENUE_DOMAIN" ]; then
            # SAFETY: never overwrite an existing venue website with a fallback result
            # and never change VENUE_DOMAIN — the fallback site may be a directory/tourism
            # page (e.g. visitloudoun.org) not the actual venue website
            if [ -z "$VENUE_DOMAIN" ] || [ "$VENUE_DOMAIN" = "none" ]; then
                log "  [FALLBACK] Found site (no existing website): $found_site (domain: $found_domain)"
                VENUE_DOMAIN="$found_domain"
                curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=website&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$found_site")" > /dev/null
                step1_website "$venue" "$venue_id" "$found_site" "$city"
            else
                log "  [FALLBACK] Found site $found_site but venue already has domain $VENUE_DOMAIN — skipping (won't overwrite)"
            fi
        else
            log "  [FALLBACK] No new site found (or same domain as before)"
        fi
    else
        log "  [FALLBACK] Google returned no site"
    fi

    # --- 5B: Re-try Instagram with city to catch parent-brand handles ---
    local current_ig
    current_ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_ig_check.json')).get('venue',{}).get('instagram',''))" 2>/dev/null)
    if [ -z "$current_ig" ] || [ "$current_ig" = "None" ] || [ ${#current_ig} -le 5 ]; then
        local IG_SEARCH
        IG_SEARCH=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1] + ' ' + sys.argv[2] + ' site:instagram.com'))" "$venue" "$city")
        log "  [FALLBACK] Re-trying Instagram: $venue $city site:instagram.com"
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${IG_SEARCH}\""
        sleep 4
        local ig_url
        ig_url=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_ig.js"'")' 2>/dev/null)
        if [ -n "$ig_url" ] && [ "$ig_url" != "missing value" ] && [ "$ig_url" != "" ]; then
            # Validate fallback IG handle matches venue name
            local fb_ig_slug fb_ig_match
            fb_ig_slug=$(echo "$ig_url" | sed 's|.*/\([^/]*\)/\?$|\1|' | tr '[:upper:]' '[:lower:]')
            fb_ig_match=$(python3 -c "
import re, sys
venue = sys.argv[1]; handle = sys.argv[2]
words = re.sub(r'[^a-z\s]','',venue.lower()).split()
stop = {'the','a','an','and','of','at','in','by','on','for','to',
        'hotel','inn','resort','lodge','restaurant','winery','vineyard',
        'club','country','golf','bar','bistro','cafe','tavern','grill',
        'pub','lounge','spa','marina','museum','gallery'}
words = [w for w in words if w not in stop and len(w) > 2]
print('match' if any(w in handle for w in words) else 'no')
" "$venue" "$fb_ig_slug" 2>/dev/null)
            if [ "$fb_ig_match" = "no" ]; then
                log "  [FALLBACK] Instagram handle '$fb_ig_slug' doesn't match venue name '$venue' — rejecting"
            else
                log "  [FALLBACK] Found Instagram: $ig_url"
                curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ig_url")" > /dev/null
                echo "$ig_url" > /tmp/pipeline_step1_ig.txt
                # Try scraping the IG profile for email via step2
                step2_social "$venue" "$venue_id"
            fi
        else
            log "  [FALLBACK] No Instagram found with city search"
        fi
    fi
}

# =================================================================
# MAIN RUNNER
# =================================================================
run_venue() {
    local venue="$1" venue_id="$2" website="$3" city="$4"
    local start_time
    start_time=$(date +%s)

    # Clear per-venue temp files so previous venue's data doesn't bleed in
    rm -f /tmp/pipeline_step1_fb.txt /tmp/pipeline_step1_ig.txt
    rm -f /tmp/pipeline_ig_check.json /tmp/pipeline_contacts_count
    rm -f /tmp/pipeline_apollo_company.json /tmp/pipeline_people.json
    rm -f /tmp/pipeline_domain_lookup.json /tmp/pipeline_li_domain.json
    rm -f /tmp/pipeline_sp_detail.json

    # Resolve real venue ID — if the passed ID doesn't exist in the sheet,
    # look it up by domain. Catches the case where discover.sh assigned a
    # different ID than what was passed manually.
    local id_check
    id_check=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [ "$id_check" = "error" ] && [ -n "$website" ] && [ "$website" != "None" ]; then
        local domain
        domain=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${website}').netloc.replace('www.',''))" 2>/dev/null)
        if [ -n "$domain" ]; then
            local lookup_resp
            lookup_resp=$(curl -sL "${APPS_SCRIPT_URL}?action=find_by_domain&domain=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$domain'))")" 2>/dev/null)
            local real_id
            real_id=$(echo "$lookup_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('venue_id','')) if d.get('status')=='ok' else print('')" 2>/dev/null)
            if [ -n "$real_id" ] && [ "$real_id" != "$venue_id" ]; then
                log "  [ID FIX] '$venue_id' not in sheet — using real ID '$real_id' (matched by domain: $domain)"
                venue_id="$real_id"
            fi
        fi
    fi

    # --- EXISTING DATA CHECK ---
    # Existing contacts are NOT a completion signal. A prior run may have found an
    # owner/founder while missing events, catering, sales, social links, PDFs, etc.
    # Only venues that are explicitly contacted/closed are skipped here.
    local existing_contacts
    existing_contacts=$(curl -sL --max-time 10 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    contacts = d.get('contacts', [])
    status = d.get('venue', {}).get('status', '')
    if status in ('contacted', 'closed'):
        print('SKIP:' + status)
    elif len(contacts) > 0:
        emails = [c.get('email','') for c in contacts if c.get('email','')]
        print('CONTINUE:has_contacts:' + ','.join(emails[:3]))
    else:
        print('CONTINUE:no_contacts')
except Exception as e:
    print(f'WARN: existing contact check failed: {e}', file=sys.stderr)
    print('CONTINUE:check_failed')
" 2>/dev/null)
    if [[ "$existing_contacts" == SKIP:* ]]; then
        log "  [SKIP] Venue status prevents new outreach research: $existing_contacts"
        echo "${venue}|${venue_id}|Status: ${existing_contacts}" >> "${SKIPPED_VENUES_FILE:-/tmp/pipeline_skipped.txt}"
        return
    elif [[ "$existing_contacts" == CONTINUE:has_contacts:* ]]; then
        log "  [RESEARCH AGAIN] Existing contacts found, but web discovery will still run: ${existing_contacts#CONTINUE:has_contacts:}"
    fi

    # If no website, Google it via Chrome
    if [ -z "$website" ] || [ "$website" = "None" ]; then
        log "  [LOOKUP] No website — Googling '$venue'..."
        local SEARCH_ENCODED
        SEARCH_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$venue")
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
        sleep 3
        local ALL_SITES
        ALL_SITES=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_cite.js"'")' 2>/dev/null)
        if [ -n "$ALL_SITES" ] && [ "$ALL_SITES" != "None" ] && [ "$ALL_SITES" != "missing value" ] && [ "$ALL_SITES" != "" ]; then
            # Require a plausible official-site match. The old matcher accepted weak
            # token overlaps and could attach an unrelated Google result to a venue.
            local FOUND_SITE
            FOUND_SITE=$(python3 "${SCRIPT_DIR}/venue_quality.py" choose-website "$venue" "$ALL_SITES" 2>/dev/null)


            if [ -n "$FOUND_SITE" ]; then
                website="$FOUND_SITE"
                log "  [LOOKUP] Found: $website"
                curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=website&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$website")" > /dev/null
            else
                log "  [WARN] Google returned ${#SITE_LIST[@]} results but none matched venue '$venue': $ALL_SITES"
                website=""
            fi
        else
            log "  [LOOKUP] No website found via Google"
            website=""
        fi
    fi

    # Normalize URL scheme — prepend https:// if missing
    if [ -n "$website" ] && [ "$website" != "None" ]; then
        if ! echo "$website" | grep -qE '^https?://'; then
            website="https://$website"
            log "  [URL FIX] Added https:// scheme: $website"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=website&value=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$website")" > /dev/null
        fi
    fi

    # Set VENUE_DOMAIN for off-domain email filter in verify_and_push
    if [ -n "$website" ] && [ "$website" != "None" ]; then
        VENUE_DOMAIN=$(python3 -c "from urllib.parse import urlparse; d=urlparse('${website}').netloc.lower(); print(d.replace('www.',''))" 2>/dev/null)
    else
        VENUE_DOMAIN=""
    fi
    log "  [DOMAIN] Venue domain: ${VENUE_DOMAIN:-none}"

    # Re-check category by venue name — ONLY if current category is generic 'restaurant'
    # Never overwrite intentional categories (art_gallery, museum, etc.)
    local CURRENT_CAT
    CURRENT_CAT=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('category',''))" 2>/dev/null)
    if [ "$CURRENT_CAT" = "restaurant" ]; then
        local CORRECT_CAT
        CORRECT_CAT=$(python3 "${SCRIPT_DIR}/venue_quality.py" category "restaurant" "$venue" 2>/dev/null)
        [ "$CORRECT_CAT" = "restaurant" ] && CORRECT_CAT=""
        if [ -n "$CORRECT_CAT" ]; then
            log "  [FIX] Name-based category: $CORRECT_CAT (was restaurant) — updating sheet"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=category&value=${CORRECT_CAT}" > /dev/null
        fi
    fi

    log ""
    log "============================================================"
    log " PIPELINE: $venue ($venue_id)"
    log " Website: $website"
    log " Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    # Track how many new contacts we find (file-based to survive subshells)
    rm -f /tmp/pipeline_contacts_count

    # Freshness check: ping the website to catch dead/closed venues early
    if [ -n "$website" ] && [ "$website" != "null" ]; then
        local HTTP_CODE
        HTTP_CODE=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 10 "$website" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "000" ]; then
            log "  [WARN] Website DNS failure ($website) — venue may be closed"
            log "  Flagging as potentially closed and skipping"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=notes&value=PIPELINE_FLAG:+DNS+failure,+possibly+closed" > /dev/null
            echo "${venue}|${venue_id}|DNS failure — possibly closed" >> "${SKIPPED_VENUES_FILE:-/tmp/pipeline_skipped.txt}"
            return
        elif [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "410" ]; then
            log "  [WARN] Website returned $HTTP_CODE ($website) — venue may be closed"
            log "  Flagging as potentially closed and skipping"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=notes&value=PIPELINE_FLAG:+HTTP+${HTTP_CODE},+possibly+closed" > /dev/null
            echo "${venue}|${venue_id}|HTTP $HTTP_CODE — possibly closed" >> "${SKIPPED_VENUES_FILE:-/tmp/pipeline_skipped.txt}"
            return
        fi
        log "  Website check: HTTP $HTTP_CODE ✓"
    fi

    # Check ZeroBounce budget, but NEVER skip discovery because verification is paused.
    if ! check_zb_credits; then
        log "  [ZB SAFE] Continuing venue discovery with paid verification paused"
    fi

    # Load existing contacts once
    load_existing "$venue_id"
    ZB_VENUE_CREDITS=0  # Reset per-venue ZB counter
    log "  Known emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
    log "  Known names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"

    step1_website "$venue" "$venue_id" "$website" "$city"
    step1b_ig_search "$venue" "$venue_id"
    step1c_fb_search "$venue" "$venue_id"
    step2_social "$venue" "$venue_id"
    # Check Apollo credits before the expensive API step
    if ! check_apollo_credits; then
        log "  [SKIP] Apollo step — credits too low"
    else
        step3_apollo_api "$venue" "$venue_id" "$website" "$city"
    fi

    # Step 3b: Scrape alternate domain if Apollo returned a different one
    if [ -n "$APOLLO_DOMAIN" ] && [ "$APOLLO_DOMAIN" != "None" ]; then
        local alt_domain="$APOLLO_DOMAIN"
        local site_domain
        site_domain=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${website}').netloc.replace('www.',''))" 2>/dev/null)
        if [ -n "$alt_domain" ] && [ "$alt_domain" != "$site_domain" ]; then
            log ""
            log "========== STEP 3b: Alternate Domain Scrape ($alt_domain) =========="
            local alt_urls=("https://$alt_domain" "https://$alt_domain/contact" "https://$alt_domain/contact-us" "https://www.$alt_domain" "https://www.$alt_domain/contact")
            for alt_url in "${alt_urls[@]}"; do
                local alt_html
                alt_html=$(curl -sL --compressed --max-time 10 "$alt_url" 2>/dev/null)
                if [ -z "$alt_html" ]; then
                    continue
                fi
                local alt_emails
                alt_emails=$(echo "$alt_html" | python3 -c "
import re, sys
html = sys.stdin.read()
junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk','fontawesome.io']
generic = ['noreply@','no-reply@','support@','admin@','webmaster@','billing@']
img_exts = re.compile(r'\.(png|jpg|jpeg|gif|svg|webp|bmp|ico|pdf|doc|docx|xls|xlsx|csv|zip|mp3|mp4|mov|avi)$', re.I)
emails = set()
for m in re.findall(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', html):
    e = m.lower()
    if any(j in e for j in junk): continue
    if any(e.startswith(g) for g in generic): continue
    if img_exts.search(e): continue
    if len(e) > 60: continue
    emails.add(e)
for e in sorted(emails):
    print(e)
" 2>/dev/null)
                if [ -n "$alt_emails" ]; then
                    log "  Found on $alt_url:"
                    while IFS= read -r alt_email; do
                        if [ -z "$alt_email" ]; then continue; fi
                        log "    $alt_email"
                        # Add to collection if not already known
                        if ! echo "$KNOWN_EMAILS" | grep -qiF "$alt_email"; then
                            # Validate with ZeroBounce
                            # Temporarily set VENUE_DOMAIN to alt domain so off-domain check passes
                            local orig_venue_domain="$VENUE_DOMAIN"
                            VENUE_DOMAIN="$alt_domain"
                            verify_and_push "$alt_email" "$venue_id" "" "" "apollo"
                            VENUE_DOMAIN="$orig_venue_domain"
                        else
                            log "    [SKIP] $alt_email — already known"
                        fi
                    done <<< "$alt_emails"
                fi
            done
        fi
    fi

    # LinkedIn — skip only if SKIP_LINKEDIN=1
    if [ "${SKIP_LINKEDIN:-0}" != "1" ]; then
        step4_linkedin "$venue" "$venue_id"
        # LinkedIn ran — clear pending regardless of result count
        local LI_FOUND_FILE="/tmp/pipeline_li_found_count"
        local LI_FOUND_COUNT=$(cat "$LI_FOUND_FILE" 2>/dev/null || echo "0")
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=linkedin_pending&value=false" > /dev/null
        if [ "$LI_FOUND_COUNT" -eq 0 ]; then
            log "  LinkedIn found 0 — cleared pending (scrape already ran)"
        fi
    else
        log ""
        log "========== STEP 4: LinkedIn (SKIPPED — SKIP_LINKEDIN=1) =========="
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=linkedin_pending&value=true" > /dev/null
        log "  Marked linkedin_pending=true"
    fi

    # Step 5: Google fallback if nothing found yet
    step5_google_fallback "$venue" "$venue_id" "$city"

    # Status reflects outcome — zero verified contacts = needs_review
    local saved_count
    saved_count=$(wc -l < /tmp/pipeline_contacts_count 2>/dev/null || echo 0)
    saved_count=$(echo "$saved_count" | tr -d ' ')
    if [ "$saved_count" -gt 0 ] 2>/dev/null; then
        log "  Setting status → pipelined ($saved_count verified contacts saved)"
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=status&value=pipelined" > /dev/null
    else
        log "  Setting status → needs_review (no verified contacts saved)"
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=status&value=needs_review" > /dev/null
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
LOCK_FILE="/tmp/pipeline.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Pipeline already running (PID $LOCK_PID). Wait for it to finish."
        exit 1
    else
        echo "WARNING: Stale lock file found (PID $LOCK_PID not running). Removing."
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

SKIPPED_VENUES_FILE="/tmp/pipeline_skipped_venues"
rm -f "$SKIPPED_VENUES_FILE"
echo "" >> "$LOG_FILE"
log "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "$1" = "--smart-picks" ]; then
    log "ERROR: --smart-picks is disabled because it bypasses build_batch.sh validation."
    log "Run: ./build_batch.sh 8 --dry-run"
    log "Then: ./build_batch.sh 8 && ./pipeline.sh --batch /tmp/pipeline_batch.json"
    exit 2
    # Track start line for report generation
    RUN_START_LINE=$(wc -l < "$LOG_FILE")
    RUN_START_LINE=$((RUN_START_LINE + 1))

    # --- Shared budget: MAX_SP controls total venues across both phases ---
    MAX_SP=${MAX_SP:-0}  # 0 = unlimited
    SHARED_COUNT_FILE="/tmp/pipeline_shared_count"
    echo "0" > "$SHARED_COUNT_FILE"

    # --- Phase 1: Smart Picks (runs first to use budget on best venues) ---
    # Pull Smart Picks from API in rank order (highest score first)
    CURRENT=$(cat "$SHARED_COUNT_FILE")
    if [ "$MAX_SP" -gt 0 ] && [ "$CURRENT" -ge "$MAX_SP" ]; then
        log "SMART PICKS: Skipping — shared budget of $MAX_SP already reached ($CURRENT processed)"
    else
    REMAINING=""
    if [ "$MAX_SP" -gt 0 ]; then
        REMAINING=$((MAX_SP - CURRENT))
    fi
    log "SMART PICKS MODE: Fetching ranked venues..."
    SP_FILE="/tmp/pipeline_smart_picks.json"
    curl -sL "${APPS_SCRIPT_URL}?action=get_recommendations" -o "$SP_FILE"
    SP_COUNT=$(python3 -c "
import json
with open('$SP_FILE') as f:
    recs = json.load(f).get('recommendations', [])
filtered = [r for r in recs if r.get('status','') not in ('pipelined','contacted','needs_review')]
print(len(filtered))
" 2>/dev/null)
    if [ -n "$REMAINING" ]; then
        log "SMART PICKS: $SP_COUNT available, budget remaining: $REMAINING"
    else
        log "SMART PICKS: $SP_COUNT venues to process"
    fi

    python3 -c "
import json, os, re
with open('$SP_FILE') as f:
    recs = json.load(f).get('recommendations', [])

# Junk name filter — skip non-venue businesses
JUNK = ['bakery','coffee','koffee','mall','westfield','lingerie','bustiere',
    'grocery','specialty food','sushi','pizza','taco','burger','kebab','gyro',
    'brewing','brewery','hookah','karaoke','nightclub','swim club','tennis club',
    'boxing','athletic','nail salon','hair salon','senior living','assisted living',
    'nursing','cornucopia','deli','sandwich','hilton garden','hampton inn',
    'comfort inn','residence inn','courtyard by','fairfield inn','holiday inn',
    'days inn','la quinta','moose lodge','elks lodge','strip mall','shopping center',
    'food court','rooftop bar','sports bar',
    'ice cream','gelato','frozen yogurt','toastique','toast ',
    'sweets','candy','dessert','confection',
    'clubhouse','liquor','wine shop','wine store','wine & spirits',
    'wine and spirits',' pub','irish pub','pastry',
    ' cafe','cafe ','slice','cupcake','smoothie','juice bar',
    'acai','poke bowl','bubble tea','boba',
    'swimming','swim team','swim school','fins swimming',
    'tennis academy','tennis central','golf institute','golf academy',
    'recreation club','rec club','canoe club','kayak','paddle club',
    'marina','boat club','peak golf',
    'pickleball','tutoring','learning center','karate','taekwondo',
    'jiu jitsu','martial art','dance studio','yoga studio',
    'pilates','crossfit','personal training','physical therapy',
    'veterinar','dental','medical','urgent care','pharmacy',
    'dry cleaner','laundry','storage','auto repair','car wash',
    'real estate','insurance','law firm','accounting firm',
    'church','mosque','synagogue','temple']

# Luxury-fit gate — Smart Picks should look like a private concierge list,
# not a generic local-business ranking.
FINE_DINING = ['fine dining','michelin','tasting menu','prix fixe','white tablecloth',
    'french','brasserie','boucherie','auberge','ristorante','trattoria','osteria',
    'italian','spanish','argentinian','steakhouse','chophouse','prime','sommelier','wine pairing']
LUXURY_HOTEL = ['five star','5-star','5 star','luxury','boutique','historic','ritz-carlton',
    'four seasons','rosewood','mandarin oriental','st. regis','waldorf','fairmont','pendry',
    'salamander','peninsula','langham','conrad','sofitel']
WINE_SIGNALS = ['wine bar','enoteca','vinoteca','sommelier','wine lounge','wine cellar','wine program']
ESTATE_SIGNALS = ['estate','chateau','vineyard','tasting room','reserve','winery']
CLUB_CATS = {'private_club','country_club','yacht_club'}
ALLOWED_CATS = CLUB_CATS | {'hotel','resort','wine_bar','restaurant','rest','fine_dining','winery'}

def has_any(text, words):
    return any(w in text for w in words)

def luxury_fit(r):
    cat = str(r.get('category','')).lower()
    if cat not in ALLOWED_CATS: return False
    if str(r.get('status','')).lower() == 'needs_review': return False
    if r.get('venue_vote','') == 'down': return False
    name = str(r.get('name','')).lower()
    notes = str(r.get('notes','')).lower() if r.get('notes') else ''
    text = name + ' ' + notes
    try: upscale = int(float(r.get('upscale_score',0) or 0))
    except: upscale = 0
    if r.get('venue_vote','') == 'up': return True
    if cat in CLUB_CATS: return True
    if cat in ('restaurant','rest','fine_dining'):
        return upscale >= 4 and has_any(text, FINE_DINING)
    if cat in ('hotel','resort'):
        return upscale >= 4 and (upscale >= 5 or has_any(text, LUXURY_HOTEL))
    if cat == 'wine_bar':
        return upscale >= 4 or has_any(text, WINE_SIGNALS)
    if cat == 'winery':
        return upscale >= 4 and has_any(text, ESTATE_SIGNALS)
    return False

def taste_rank(r):
    """Lower = better, after passing the luxury-fit gate."""
    cat = str(r.get('category','')).lower()
    text = (str(r.get('name','')) + ' ' + str(r.get('notes','') or '')).lower()
    if r.get('venue_vote','') == 'up': return 0
    if cat in CLUB_CATS: return 1
    if cat in ('hotel','resort') and has_any(text, LUXURY_HOTEL): return 2
    if cat == 'wine_bar': return 2
    if cat in ('restaurant','rest','fine_dining') and has_any(text, FINE_DINING): return 3
    if cat == 'winery': return 4
    return 9

filtered = []
for r in recs:
    if r.get('status','') in ('pipelined','contacted','needs_review'): continue
    name_lower = r.get('name','').lower()
    if any(j in name_lower for j in JUNK):
        continue
    # Skip thumbs down and anything that is not genuinely high-end.
    if r.get('venue_vote','') == 'down': continue
    if not luxury_fit(r): continue
    filtered.append(r)

# Sort by taste rank FIRST, then recommendation_score as tiebreaker
filtered.sort(key=lambda r: (taste_rank(r), -r.get('recommendation_score', 0)))

for i, r in enumerate(filtered):
    print(f\"{i}|{r['name']}|{r['venue_id']}|{r.get('recommendation_score',0)}\")
" 2>/dev/null | while IFS='|' read -r IDX NAME VID SCORE; do
        CURRENT=$(cat "$SHARED_COUNT_FILE")
        if [ "$MAX_SP" -gt 0 ] && [ "$CURRENT" -ge "$MAX_SP" ]; then
            log "[BUDGET] Shared limit of $MAX_SP reached — stopping smart picks"
            break
        fi
        log ""
        log "########## SMART PICK #$((IDX+1)) (score $SCORE): $NAME ($VID) ##########"
        # Fetch website + city from venue detail
        curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" -o /tmp/pipeline_sp_detail.json
        WEB=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sp_detail.json')).get('venue',{}).get('website',''))" 2>/dev/null)
        CITY=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sp_detail.json')).get('venue',{}).get('city',''))" 2>/dev/null)
        run_venue "$NAME" "$VID" "$WEB" "$CITY"
        # Only count toward budget if venue was actually processed (not skipped)
        if ! grep -q "^${NAME}|${VID}|" "$SKIPPED_VENUES_FILE" 2>/dev/null; then
            CURRENT=$(cat "$SHARED_COUNT_FILE")
            echo "$((CURRENT + 1))" > "$SHARED_COUNT_FILE"
        else
            log "  [BUDGET] $NAME was skipped — not counting toward $MAX_SP limit"
        fi
        if [ "$IDX" -lt "$((SP_COUNT - 1))" ]; then sleep 30; fi
    done
    fi  # end shared budget else block
    log "=== SMART PICKS COMPLETE ==="
    log ""

    # --- Phase 2: Process UNTOUCHED venues with remaining budget ---
    log "UNTOUCHED PHASE: Fetching all venues..."
    UT_FILE="/tmp/pipeline_untouched.json"
    curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o "$UT_FILE"
    UT_COUNT=$(python3 -c "
import json
with open('$UT_FILE') as f: data = json.load(f)
untouched = [v for v in data.get('venues', [])
             if (v.get('venue', v)).get('status','') == 'untouched']
print(len(untouched))
" 2>/dev/null)
    if [ "$UT_COUNT" -gt 0 ]; then
        if [ "$MAX_SP" -gt 0 ]; then
            log "UNTOUCHED: $UT_COUNT found (shared budget: $MAX_SP total)"
        else
            log "UNTOUCHED: $UT_COUNT venues to process"
        fi
        python3 -c "
import json, os
with open('$UT_FILE') as f: data = json.load(f)
untouched = []
for v in data.get('venues', []):
    venue = v.get('venue', v)
    if venue.get('status','') == 'untouched':
        untouched.append(venue)
# Sort: venue quality first, then actionability (contact data available)
def action_score(v):
    score = 0
    # --- Quality tier (weighted heavily) ---
    cat = v.get('category','').lower()
    upscale = int(v.get('upscale_score', 0) or 0)
    # Category tier
    if cat in ('private_club', 'yacht_club'): score += 40
    elif cat == 'country_club': score += 35
    elif cat in ('wine_bar',): score += 20
    elif cat in ('hotel', 'restaurant', 'winery', 'museum'): score += 15
    # Upscale score
    score += upscale * 8
    # Sweet spot locations (DC, NoVA, Bethesda, etc.)
    city = v.get('city','').lower()
    state = v.get('state','').upper()
    sweet = ['washington', 'georgetown', 'dupont', 'alexandria', 'mclean',
             'great falls', 'bethesda', 'chevy chase', 'potomac', 'annapolis',
             'easton', 'st. michaels', 'st michaels', 'charlottesville',
             'middleburg', 'leesburg', 'wilmington', 'greenville']
    if any(s in city for s in sweet): score += 10
    if state == 'DC': score += 10
    # --- Actionability (contact data already on file) ---
    if v.get('instagram','') and len(v.get('instagram','')) > 5: score += 3
    if v.get('website','') and len(v.get('website','')) > 5: score += 2
    if v.get('contact_form','') and len(v.get('contact_form','')) > 5: score += 2
    if v.get('state','').strip(): score += 1
    if v.get('city','').strip(): score += 1
    return score
# Junk name filter
JUNK = ['bakery','coffee','koffee','mall','westfield','lingerie','bustiere',
    'grocery','specialty food','sushi','pizza','taco','burger','kebab','gyro',
    'brewing','brewery','hookah','karaoke','nightclub','swim club','tennis club',
    'boxing','athletic','nail salon','hair salon','senior living','assisted living',
    'nursing','cornucopia','deli','sandwich','hilton garden','hampton inn',
    'comfort inn','residence inn','courtyard by','fairfield inn','holiday inn',
    'days inn','la quinta','moose lodge','elks lodge','strip mall','shopping center',
    'food court','rooftop bar','sports bar',
    'ice cream','gelato','frozen yogurt','toastique','toast ',
    'sweets','candy','dessert','confection',
    'clubhouse','liquor','wine shop','wine store','wine & spirits',
    'wine and spirits',' pub','irish pub','pastry',
    ' cafe','cafe ','slice','cupcake','smoothie','juice bar',
    'acai','poke bowl','bubble tea','boba']
untouched = [v for v in untouched if not any(j in v.get('name','').lower() for j in JUNK)]
# Shared-budget untouched phase follows the same high-end standard as Smart Picks.
def luxury_untouched(v):
    cat = str(v.get('category','')).lower()
    if cat not in {'private_club','country_club','yacht_club','hotel','resort','wine_bar','restaurant','fine_dining','winery'}:
        return False
    if str(v.get('status','')).lower() == 'needs_review' or v.get('venue_vote','') == 'down':
        return False
    text = (str(v.get('name','')) + ' ' + str(v.get('notes','') or '')).lower()
    try: upscale = int(float(v.get('upscale_score',0) or 0))
    except: upscale = 0
    if v.get('venue_vote','') == 'up': return True
    if cat in {'private_club','country_club','yacht_club'}: return True
    fine = ['fine dining','michelin','tasting menu','french','brasserie','boucherie','auberge',
            'ristorante','trattoria','osteria','italian','spanish','argentinian','steakhouse','chophouse','prime']
    luxury_hotel = ['five star','5-star','5 star','luxury','boutique','historic','ritz-carlton','four seasons',
                    'rosewood','mandarin oriental','st. regis','waldorf','fairmont','pendry','salamander','peninsula','langham']
    if cat in {'restaurant','fine_dining'}: return upscale >= 4 and any(x in text for x in fine)
    if cat in {'hotel','resort'}: return upscale >= 4 and (upscale >= 5 or any(x in text for x in luxury_hotel))
    if cat == 'wine_bar': return upscale >= 4
    if cat == 'winery': return upscale >= 4 and any(x in text for x in ['estate','chateau','vineyard','tasting room','reserve','winery'])
    return False
untouched = [v for v in untouched if luxury_untouched(v)]
untouched.sort(key=action_score, reverse=True)
for i, venue in enumerate(untouched):
    vid = venue.get('venue_id', '')
    name = venue.get('name', '')
    web = venue.get('website', '')
    city = venue.get('city', '')
    print(f'{i}|{name}|{vid}|{web}|{city}')
" 2>/dev/null | while IFS='|' read -r IDX NAME VID WEB CITY; do
            CURRENT=$(cat "$SHARED_COUNT_FILE")
            if [ "$MAX_SP" -gt 0 ] && [ "$CURRENT" -ge "$MAX_SP" ]; then
                log "[BUDGET] Shared limit of $MAX_SP reached — stopping untouched phase"
                break
            fi
            log ""
            log "########## UNTOUCHED #$((IDX+1)): $NAME ($VID) ##########"
            run_venue "$NAME" "$VID" "$WEB" "$CITY"
            # Only count toward budget if venue was actually processed (not skipped)
            if ! grep -q "^${NAME}|${VID}|" "$SKIPPED_VENUES_FILE" 2>/dev/null; then
                echo "$((CURRENT + 1))" > "$SHARED_COUNT_FILE"
            else
                log "  [BUDGET] $NAME was skipped — not counting toward $MAX_SP limit"
            fi
            sleep 30
        done
        log "=== UNTOUCHED PHASE COMPLETE ==="
        log ""
    else
        log "UNTOUCHED: none found — skipping"
    fi

    # End-of-run report: skipped venues
    if [ -f "$SKIPPED_VENUES_FILE" ] && [ -s "$SKIPPED_VENUES_FILE" ]; then
        log ""
        log "============================================================"
        log " SKIPPED VENUES (need manual lookup):"
        log "============================================================"
        while IFS='|' read -r SNAME SVID SREASON; do
            log "  ✗ $SNAME ($SVID) — $SREASON"
        done < "$SKIPPED_VENUES_FILE"
        log "============================================================"
    fi
    log "=== SMART PICKS COMPLETE ==="

    # Post-pipeline: check every zero-contact venue's website, Apollo, LinkedIn
    log ""
    log "=== POST-PIPELINE VERIFICATION ==="
    POSTCHECK_LOG="${SCRIPT_DIR}/postcheck.log"
    POSTCHECK_START=""
    if [ -x "${SCRIPT_DIR}/postcheck.sh" ]; then
        POSTCHECK_START=$(wc -l < "$POSTCHECK_LOG" 2>/dev/null || echo "0")
        POSTCHECK_START=$((POSTCHECK_START + 1))
        "${SCRIPT_DIR}/postcheck.sh"
        # Append postcheck results to pipeline log so they appear in the report
        if [ -n "$POSTCHECK_START" ]; then
            log ""
            log "--- Postcheck Results ---"
            tail -n "+${POSTCHECK_START}" "$POSTCHECK_LOG" 2>/dev/null | while IFS= read -r PCLINE; do
                log "  $PCLINE"
            done
            log "--- End Postcheck ---"
        fi
    else
        log "WARNING: postcheck.sh not found or not executable"
    fi

    # Report generated manually after full run (not per-batch)
    # generate_report "$RUN_START_LINE"

elif [ "$1" = "--linkedin-retry" ]; then
    # Re-run Step 4 (LinkedIn) on venues with linkedin_pending=true
    log "LINKEDIN RETRY MODE: Finding venues with linkedin_pending=true..."
    curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/pipeline_linkedin_retry.json 2>/dev/null
    python3 -c "
import json, os
with open('/tmp/pipeline_linkedin_retry.json') as f: data = json.load(f)
SKIP = set(filter(None, os.environ.get('SKIP_VENUES','').split(',')))
# Build set of venue_ids that already have email contacts
venues_with_email = set(
    c['venue_id'] for c in data.get('contacts', [])
    if c.get('email') and c.get('venue_id')
)
for v in data.get('venues', []):
    if v.get('linkedin_pending') == True or str(v.get('linkedin_pending','')).lower() == 'true':
        if v['venue_id'] not in SKIP:
            if v['venue_id'] in venues_with_email:
                import sys; print(f\"CLEAR|||{v['venue_id']}|||{v['name']}\", file=sys.stderr)
            else:
                print(f\"{v['venue_id']}|||{v['name']}|||{v.get('website','')}\")
" 2>&1 1>/tmp/pipeline_linkedin_queue.txt | while IFS='|||' read -r ACTION VID NAME; do
        if [ "$ACTION" = "CLEAR" ]; then
            log "  [SKIP] $NAME already has emails — clearing linkedin_pending"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=linkedin_pending&value=false" > /dev/null
        fi
    done
    cat /tmp/pipeline_linkedin_queue.txt | while IFS='|||' read -r VID NAME WEB; do
        log ""
        log "########## LINKEDIN RETRY: $NAME ($VID) ##########"
        load_existing "$VID"
        # Get domain from website
        APOLLO_DOMAIN=$(echo "$WEB" | python3 -c "import sys,re; m=re.search(r'https?://(?:www\.)?([^/]+)',sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null)
        step4_linkedin "$NAME" "$VID"
        # Clear linkedin_pending — status stays pipelined
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${VID}&field=linkedin_pending&value=false" > /dev/null
        log "  Cleared linkedin_pending"
        sleep 10
    done
    log "=== LINKEDIN RETRY COMPLETE ==="

elif [ "$1" = "--batch" ]; then
    RUN_START_LINE=$(wc -l < "$LOG_FILE")
    RUN_START_LINE=$((RUN_START_LINE + 1))

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
print(v.get('city',''))
")
        NAME=$(echo "$INFO" | sed -n '1p')
        VID=$(echo "$INFO" | sed -n '2p')
        WEB=$(echo "$INFO" | sed -n '3p')
        CITY=$(echo "$INFO" | sed -n '4p')
        log ""
        log "########## VENUE [$((i+1))/$TOTAL]: $NAME ##########"
        # Skip venues already pipelined or contacted
        local VSTATUS
        VSTATUS=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        if [ "$VSTATUS" = "pipelined" ] || [ "$VSTATUS" = "contacted" ]; then
            log "  [SKIP] Already $VSTATUS — skipping"
            continue
        fi
        run_venue "$NAME" "$VID" "$WEB" "$CITY"
        if [ "$i" -lt "$((TOTAL - 1))" ]; then sleep 30; fi
    done
    if [ -f "$SKIPPED_VENUES_FILE" ] && [ -s "$SKIPPED_VENUES_FILE" ]; then
        log ""
        log "============================================================"
        log " SKIPPED VENUES (need manual lookup):"
        log "============================================================"
        while IFS='|' read -r SNAME SVID SREASON; do
            log "  ✗ $SNAME ($SVID) — $SREASON"
        done < "$SKIPPED_VENUES_FILE"
        log "============================================================"
    fi
    log "=== BATCH COMPLETE ==="

    # Report generated manually after full run (not per-batch)
    # generate_report "$RUN_START_LINE"

    # Auto-run postcheck on ALL pipelined venues (not just this batch)
    log ""
    log "=== AUTO-RUNNING POSTCHECK ON ALL PIPELINED VENUES ==="
    if [ -x "${SCRIPT_DIR}/postcheck.sh" ]; then
        "${SCRIPT_DIR}/postcheck.sh"
    else
        log "[WARN] postcheck.sh not found or not executable at ${SCRIPT_DIR}/postcheck.sh"
    fi

else
    VENUE="${1:?Usage: $0 \"Venue Name\"}"

    # If venue_id not provided, look it up by name from the dashboard
    if [ -z "${2:-}" ]; then
        log "Looking up venue ID for: $VENUE"
        curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/pipeline_venue_lookup.json 2>/dev/null
        VENUE_LOOKUP=$(python3 -c "
import json, sys
with open('/tmp/pipeline_venue_lookup.json') as f: data = json.load(f)
target = '''$VENUE'''.lower().strip()
for v in data.get('venues', []):
    venue = v.get('venue', v)
    name = venue.get('name', '').lower().strip()
    if name == target:
        vid = venue.get('venue_id', '')
        web = venue.get('website', '')
        cty = venue.get('city', '')
        print(f'{vid}|||{web}|||{cty}')
        sys.exit(0)
# Fuzzy: check if all words match
target_words = set(w for w in target.split() if len(w) > 2 and w not in {'the','at','in','of','and','for'})
for v in data.get('venues', []):
    venue = v.get('venue', v)
    name = venue.get('name', '').lower().strip()
    if all(w in name for w in target_words):
        vid = venue.get('venue_id', '')
        web = venue.get('website', '')
        cty = venue.get('city', '')
        print(f'{vid}|||{web}|||{cty}')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)

        if [ "$VENUE_LOOKUP" = "NOT_FOUND" ] || [ -z "$VENUE_LOOKUP" ]; then
            echo "[ERROR] Could not find venue '$VENUE' in the sheet."
            exit 1
        fi

        VENUE_ID=$(echo "$VENUE_LOOKUP" | awk -F'|||' '{print $1}')
        WEBSITE=$(echo "$VENUE_LOOKUP" | awk -F'|||' '{print $2}')
        CITY=$(echo "$VENUE_LOOKUP" | awk -F'|||' '{print $3}')
        log "  Found: $VENUE_ID (website: ${WEBSITE:-none}, city: ${CITY:-unknown})"
    else
        VENUE_ID="$2"
        WEBSITE="${3:-}"
        CITY="${4:-}"
    fi

    run_venue "$VENUE" "$VENUE_ID" "$WEBSITE" "$CITY"
fi

# Clean up .ics files auto-downloaded by Squarespace venue sites
rm -f ~/Downloads/*.ics 2>/dev/null
