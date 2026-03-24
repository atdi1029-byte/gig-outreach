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
LOG_FILE="${SCRIPT_DIR}/pipeline.log"
JUNK_DOMAINS="wix.com|wordpress|sentry.io|cloudflare|example.com|squarespace|shopify|mailchimp|googleapis|google.com|gstatic|facebook|instagram|twitter|hubspot|sendgrid|zendesk|fontawesome.io"

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
        if c.get('email'): emails.add(c['email'].lower())
    print('|||'.join(emails))
except: print('')
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

ZB_EXHAUSTED_FLAG="/tmp/pipeline_zb_exhausted"
APOLLO_EXHAUSTED_FLAG="/tmp/pipeline_apollo_exhausted"
MAX_APOLLO=${MAX_APOLLO:-300}  # Max Apollo credits per run (default 300, set MAX_APOLLO=N to override)
rm -f "$ZB_EXHAUSTED_FLAG" "$APOLLO_EXHAUSTED_FLAG"

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
    if [ -z "$ZEROBOUNCE_KEY" ]; then return 0; fi
    if [ -f "$ZB_EXHAUSTED_FLAG" ]; then return 1; fi
    local credits
    credits=$(curl -s --max-time 10 "https://api.zerobounce.net/v2/getcredits?api_key=$ZEROBOUNCE_KEY" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('Credits',-1))" 2>/dev/null)
    if [ "$credits" = "-1" ] || [ -z "$credits" ]; then
        log "  [WARN] Could not check ZeroBounce credits"
        return 0
    fi
    log "  [ZB] Credits remaining: $credits"
    if [ "$credits" -lt 5 ] 2>/dev/null; then
        log "  [STOP] ZeroBounce credits exhausted ($credits remaining). Stopping pipeline."
        echo "exhausted" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    return 0
}

verify_and_push() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5"
    if [ -z "$email" ]; then return; fi

    if email_known "$email"; then
        log "  [SKIP] $email — already in sheet"
        return
    fi

    if [ -f "$ZB_EXHAUSTED_FLAG" ]; then
        log "  [SKIP] $email — ZeroBounce credits exhausted"
        return
    fi

    local zb_status
    zb_status=$(curl -s --max-time 15 "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$email" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
    if [ -z "$zb_status" ]; then zb_status="unknown"; fi
    log "  $email → $zb_status"

    if [ "$zb_status" = "valid" ] || [ "$zb_status" = "invalid" ] || [ "$zb_status" = "catch-all" ] || [ "$zb_status" = "unknown" ]; then
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

    log "  URL: $website"

    # JS to extract emails with names/titles (from mailto hrefs + body text), social links, and internal page links
    cat > /tmp/pipeline_website_scrape.js << 'JSEOF'
(function(){
var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk','fontawesome.io'];
var generic = ['noreply@','no-reply@','support@','admin@','webmaster@','billing@','info@','hello@','contact@','sales@','events@','reservations@','booking@','enquiries@','inquiries@','office@','general@','frontdesk@','reception@'];
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
    for(var g=0;g<generic.length;g++){ if(e.indexOf(generic[g])===0) return true; }
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
var textMatches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
textMatches.forEach(function(e){
    var el = e.toLowerCase();
    if(!isJunk(el) && !contacts[el]) contacts[el] = {email:el, name:'', title:''};
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

// 5. Emails from schema.org structured data
var schemas = document.querySelectorAll('script[type="application/ld+json"]');
for(var i=0;i<schemas.length;i++){
    try {
        var sd = JSON.parse(schemas[i].textContent);
        var schemaEmail = (sd.email || '').toLowerCase().replace('mailto:','').trim();
        if(schemaEmail && schemaEmail.indexOf('@')>0 && !isJunk(schemaEmail) && !contacts[schemaEmail]){
            contacts[schemaEmail] = {email:schemaEmail, name:'', title:''};
        }
    } catch(e){}
}

var contactList = Object.keys(contacts).map(function(k){return contacts[k];});

// Facebook URL
var fb = '';
var fbLinks = document.querySelectorAll('a[href*="facebook.com"]');
for(var i=0;i<fbLinks.length;i++){
    var u = fbLinks[i].getAttribute('href').split('?')[0].replace(/\/$/,'');
    var slug = u.split('facebook.com/')[1] || '';
    if(['tr','pixel','plugins','sharer','share','login','dialog'].indexOf(slug) > -1) continue;
    if(u.indexOf('sharer') > -1 || u.indexOf('share') > -1) continue;
    if(slug.length >= 3){ fb = u; break; }
}

// Instagram URL
var ig = '';
var igLinks = document.querySelectorAll('a[href*="instagram.com"]');
for(var i=0;i<igLinks.length;i++){
    var u = igLinks[i].getAttribute('href').split('?')[0];
    if(u.indexOf('share') === -1){ ig = u; break; }
}

// Internal links with event/contact keywords for subpage crawling
var keywords = ['event','private','wedding','cater','contact','about','entertain','music','banquet','dining','party','book'];
var base = location.origin;
var subpages = [];
var seen = {};
var allAnchors = document.querySelectorAll('a[href]');
for(var i=0;i<allAnchors.length;i++){
    var h = allAnchors[i].getAttribute('href') || '';
    if(h.startsWith('mailto:') || h.startsWith('tel:')) continue;
    var full;
    try { full = new URL(h, base).href.split('#')[0].split('?')[0].replace(/\/$/,''); } catch(e){ continue; }
    if(full.indexOf(base) !== 0) continue;
    if(seen[full]) continue;
    seen[full] = true;
    var path = full.toLowerCase();
    for(var k=0;k<keywords.length;k++){
        if(path.indexOf(keywords[k]) > -1){ subpages.push(full); break; }
    }
}

// Contact form URL
var contactKw = ['contact','get-in-touch','reach-us','inquiry','enquiry'];
var contactForm = '';
Object.keys(seen).forEach(function(url){
    var p = url.toLowerCase();
    for(var c=0;c<contactKw.length;c++){
        if(p.indexOf(contactKw[c]) > -1){ contactForm = url; return; }
    }
});

return JSON.stringify({contacts:contactList, facebook:fb, instagram:ig, contact_form:contactForm, subpages:subpages});
})()
JSEOF

    # Open website in Chrome and scrape
    log "  Opening in Chrome: $website"
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${website}\""
    sleep 6

    local scrape_result
    scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)

    if [ -z "$scrape_result" ] || [ "$scrape_result" = "missing value" ]; then
        log "  [WARN] Chrome scrape returned empty — trying with longer wait"
        sleep 5
        scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
    fi

    if [ -z "$scrape_result" ] || [ "$scrape_result" = "missing value" ]; then
        log "  [ERROR] Chrome scrape failed. Skipping website."
        return
    fi

    echo "$scrape_result" > /tmp/pipeline_scrape.json

    # Save scrape result to file for reliable parsing
    echo "$scrape_result" > /tmp/pipeline_scrape.json

    # Parse main page results
    local email_count fb ig contact_form
    email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_scrape.json')); print(len(d.get('contacts',d.get('emails',[]))))" 2>/dev/null || echo "0")
    fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['facebook'])" 2>/dev/null)
    ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['instagram'])" 2>/dev/null)
    contact_form=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('contact_form',''))" 2>/dev/null)

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
            # Update venue website to location-specific URL
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=website&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$loc_found'''))")" > /dev/null
            website="$loc_found"

            # Re-scrape the location page
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${loc_found}\""
            sleep 6
            scrape_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
            if [ -n "$scrape_result" ] && [ "$scrape_result" != "missing value" ]; then
                echo "$scrape_result" > /tmp/pipeline_scrape.json
                email_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_scrape.json')); print(len(d.get('contacts',d.get('emails',[]))))" 2>/dev/null || echo "0")
                fb=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['facebook'])" 2>/dev/null)
                ig=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json'))['instagram'])" 2>/dev/null)
                contact_form=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_scrape.json')).get('contact_form',''))" 2>/dev/null)
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

    # Crawl subpages (event/contact/private dining pages) — cap at 10
    # If venue URL has a path (e.g. chezbillysud.com/le-bar-vin), also inject
    # root domain common pages so we don't miss emails on the parent site
    local subpages
    subpages=$(python3 -c "
import json
from urllib.parse import urlparse
d = json.load(open('/tmp/pipeline_scrape.json'))
subs = d.get('subpages', [])[:10]
url = '$website'
parsed = urlparse(url)
if parsed.path and parsed.path.rstrip('/') != '':
    root = parsed.scheme + '://' + parsed.netloc
    for p in ['/contact', '/about', '/events', '/private-events', '/entertainment']:
        candidate = root + p
        if candidate not in subs:
            subs.append(candidate)
print('\n'.join(subs[:15]))
" 2>/dev/null)

    if [ -n "$subpages" ]; then
        local page_count=0
        while IFS= read -r subpage; do
            [ -z "$subpage" ] && continue
            page_count=$((page_count + 1))
            log "  Crawling subpage ($page_count): $subpage"
            osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"${subpage}\""
            sleep 4
            local sub_result
            sub_result=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "/tmp/pipeline_website_scrape.js")' 2>/dev/null)
            if [ -n "$sub_result" ] && [ "$sub_result" != "missing value" ]; then
                echo "$sub_result" > /tmp/pipeline_sub_scrape.json
                local sub_count
                sub_count=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_sub_scrape.json')); print(len(d.get('contacts',[])))" 2>/dev/null || echo "0")
                if [ "$sub_count" != "0" ]; then
                    local sub_emails
                    sub_emails=$(python3 -c "import json; d=json.load(open('/tmp/pipeline_sub_scrape.json')); print(', '.join(c['email'] for c in d.get('contacts',[])))" 2>/dev/null)
                    log "  Found on subpage: $sub_emails"
                    python3 -c "
import json
d = json.load(open('/tmp/pipeline_sub_scrape.json'))
for c in d.get('contacts', []):
    print(c['email'] + '|||' + c.get('name','') + '|||' + c.get('title',''))
" 2>/dev/null >> /tmp/pipeline_all_contacts.txt
                fi
            fi
        done <<< "$subpages"
    fi

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

    # Check if IG already found (from Step 1 website scrape)
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
    SEARCH_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('\"$venue\" instagram'))")
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
    sleep 4

    # Extract first instagram.com profile URL from Google results
    local ig_url
    ig_url=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_ig.js"'")' 2>/dev/null)

    if [ -n "$ig_url" ] && [ "$ig_url" != "missing value" ] && [ "$ig_url" != "" ]; then
        log "  [IG SEARCH] Found: $ig_url"
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=instagram&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$ig_url'''))")" > /dev/null
        log "  ✓ Instagram URL saved"
    else
        log "  [IG SEARCH] No Instagram found via Google"
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

    log "  FB: ${fb:-none} | IG: ${ig:-none}"

    # Scrape emails by opening pages in Chrome (JS renders, emails visible)
    cat > /tmp/social_scrape_emails.js << 'JSEOF'
(function(){
var junk = ['wix.com','wordpress','sentry.io','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','instagram','twitter','hubspot','sendgrid','zendesk'];
var generic = ['noreply@','no-reply@','support@','admin@','webmaster@','billing@','info@','hello@','contact@','sales@','events@','reservations@','booking@','enquiries@','inquiries@','office@','general@','frontdesk@','reception@','dataremoval@','privacy@','careers@','jobs@','hr@','marketing@','press@','media@'];
var text = document.body.innerText || '';
var matches = text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g) || [];
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
    local domain_tmpf="/tmp/pipeline_domain_lookup.json"
    curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${venue_id}" -o "$domain_tmpf" 2>/dev/null
    WEBSITE_DOMAIN=$(python3 -c "
import json,re
with open('$domain_tmpf') as f: d = json.load(f)
w = d.get('venue',{}).get('website','')
m = re.search(r'https?://(?:www\.)?([^/]+)', w)
print(m.group(1) if m else '')
" 2>/dev/null)

    local apollo_co_tmpf="/tmp/pipeline_apollo_company.json"
    python3 << PYEOF > "$apollo_co_tmpf"
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
    log "  Found: $ORG_NAME (domain: $DOMAIN)"

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
    log "  Searching for people at $DOMAIN..."
    local people_tmpf="/tmp/pipeline_people.json"
    python3 << PYEOF > "$people_tmpf"
import requests, json
all_people = []
page = 1
while True:
    resp = requests.post("${APOLLO_API_BASE}/mixed_people/api_search",
        headers={"Content-Type": "application/json", "x-api-key": "${APOLLO_API_KEY}"},
        json={"q_organization_domains_list": ["$DOMAIN"], "per_page": 25, "page": page,
              "organization_locations": ["Maryland", "Virginia", "Washington, DC", "West Virginia", "Pennsylvania", "Delaware"]})
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
    if len(people) < 25:
        break
    page += 1
    if page > 2:
        break
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
    # Sanity check: venues are small — cap at 50 people max
    if [ "$PEOPLE_COUNT" -gt 50 ]; then
        log "  [WARN] $PEOPLE_COUNT people is suspicious for a venue — capping at 50"
        python3 -c "import json; json.dump(json.load(open('$people_tmpf'))[:50], open('$people_tmpf','w'))"
        PEOPLE_COUNT=50
    fi

    # C. Filter: only skip people whose full name is already known
    local TO_ENRICH
    TO_ENRICH=$(KNAMES="$KNOWN_NAMES" KEMAILS="$KNOWN_EMAILS" python3 << 'PYEOF'
import json, os

with open('/tmp/pipeline_people.json') as f:
    people = json.load(f)
known_raw = os.environ.get('KNAMES', '')
known = set(n.strip().lower() for n in known_raw.split('|||') if n.strip())

to_enrich = []
skipped_no_email = 0
for p in people:
    first = p.get('first_name', '').strip()
    if not first:
        continue
    # Only enrich people who actually have an email (green check on Apollo)
    if not p.get('has_email', False):
        skipped_no_email += 1
        continue
    to_enrich.append(p)

if skipped_no_email:
    print(f"SKIPPED_NO_EMAIL:{skipped_no_email}", flush=True)

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
    # Remove the SKIPPED line from TO_ENRICH
    TO_ENRICH=$(echo "$TO_ENRICH" | grep -v "SKIPPED_NO_EMAIL:")

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
    python3 << 'PYEOF' "$RUN_LOG" "$REPORT_FILE" "$REPORT_TITLE" "$REPORT_DATE" "$REPORT_TS" "$MANIFEST_FILE" "$REPORT_DIR"
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
    if m:
        if current_venue:
            venues.append(current_venue)
        current_venue = {
            'pick_num': int(m.group(1)),
            'score': int(m.group(2)),
            'name': m.group(3),
            'venue_id': m.group(4),
            'website': '',
            'facebook': '',
            'instagram': '',
            'contact_form': '',
            'contacts': [],
            'apollo_credits': 0,
            'elapsed_min': 0,
            'flags': [],
            'category': ''
        }
        # Derive category from venue_id (e.g. MD-WINE-020 -> winery)
        cat_map = {
            'WINE': 'winery', 'HOTE': 'hotel', 'COUN': 'country_club',
            'REST': 'restaurant', 'EVEN': 'event', 'MUSE': 'museum',
            'RESO': 'resort', 'SENI': 'senior_living', 'GOLF': 'golf_club',
            'YACH': 'yacht_club', 'ARTG': 'art_gallery', 'LUXU': 'luxury_apts',
            'WEDD': 'wedding_venue', 'CORP': 'corporate', 'SPAA': 'spa',
            'PRIV': 'private_club', 'CHUR': 'church', 'MALL': 'mall',
            'WINE': 'winery', 'GROC': 'grocery_market',
        }
        parts = current_venue['venue_id'].split('-')
        if len(parts) >= 2:
            current_venue['category'] = cat_map.get(parts[1], parts[1].lower())
        continue

    if not current_venue:
        continue

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
    if 'SMART PICK #' in t:
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

# --- Compute stats ---
total_venues = len(venues)
total_verified = sum(
    1 for v in venues for c in v['contacts'] if c['status'] == 'valid')
total_contacts = sum(len(v['contacts']) for v in venues)

# Compute runtime from first PIPELINE start to last DONE
run_start = None
run_end = None
for line in lines:
    m = re.search(r'(\d{2}:\d{2}:\d{2})\s+Pipeline started', line)
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
    except:
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

# Flags section
all_flags = []
for v in venues:
    for fl in v.get('flags', []):
        all_flags.append(f'{v["name"]}: {fl}')
for s in skipped:
    all_flags.append(
        f'Skipped: {s["name"]} ({s["venue_id"]}) &mdash; {s["reason"]}')

if all_flags:
    html += '<h2>Flagged for Review</h2>\n'
    for fl in all_flags:
        html += f'<div class="flag"><strong>Flag:</strong> {esc(fl)}</div>\n'

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

# Per-venue sections
html += '<h2>Pipeline Results</h2>\n'

for v in venues:
    cat_html = f' <span class="category-pill">{esc(v["category"])}</span>' if v['category'] else ''
    html += f'<h3>{v["pick_num"]}. {esc(v["name"])} <span class="score">Score: {v["score"]}</span>{cat_html}</h3>\n'

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
    except:
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
}

# =================================================================
# MAIN RUNNER
# =================================================================
run_venue() {
    local venue="$1" venue_id="$2" website="$3" city="$4"
    local start_time
    start_time=$(date +%s)

    # If no website, Google it via Chrome
    if [ -z "$website" ] || [ "$website" = "None" ]; then
        log "  [LOOKUP] No website — Googling '$venue'..."
        local SEARCH_ENCODED
        SEARCH_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$venue'))")
        osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\""
        sleep 3
        website=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"${SCRIPT_DIR}/js/extract_cite.js"'")' 2>/dev/null)
        if [ -n "$website" ] && [ "$website" != "None" ] && [ "$website" != "missing value" ] && [ "$website" != "" ]; then
            log "  [LOOKUP] Found: $website"
            curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=website&value=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$website'''))")" > /dev/null
        else
            log "  [LOOKUP] No website found via Google"
            website=""
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

    # Check ZeroBounce credits before spending time on this venue
    if ! check_zb_credits; then
        log "  [ABORT] Skipping $venue — ZeroBounce credits too low"
        return
    fi

    # Load existing contacts once
    load_existing "$venue_id"
    log "  Known emails: $(echo "$KNOWN_EMAILS" | tr '|||' '\n' | grep -c .)"
    log "  Known names: $(echo "$KNOWN_NAMES" | tr '|||' '\n' | grep -c .)"

    step1_website "$venue" "$venue_id" "$website" "$city"
    step1b_ig_search "$venue" "$venue_id"
    step2_social "$venue" "$venue_id"
    # Check Apollo credits before the expensive API step
    if ! check_apollo_credits; then
        log "  [SKIP] Apollo step — credits too low"
    else
        step3_apollo_api "$venue" "$venue_id"
    fi
    # LinkedIn quota resets in April 2026 — skip until then
    if [ "$(date +%Y%m)" -ge 202604 ] 2>/dev/null; then
        step4_linkedin "$venue" "$venue_id"
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=linkedin_pending&value=false" > /dev/null
    else
        log ""
        log "========== STEP 4: LinkedIn (SKIPPED — quota reset in April) =========="
        curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=linkedin_pending&value=true" > /dev/null
        log "  Marked linkedin_pending=true"
    fi

    # Always set status to pipelined when pipeline completes
    log "  Setting status → pipelined"
    curl -sL "${APPS_SCRIPT_URL}?action=update_venue&venue_id=${venue_id}&field=status&value=pipelined" > /dev/null

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
SKIPPED_VENUES_FILE="/tmp/pipeline_skipped_venues"
rm -f "$SKIPPED_VENUES_FILE"
echo "" >> "$LOG_FILE"
log "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "$1" = "--smart-picks" ]; then
    # Track start line for report generation
    RUN_START_LINE=$(wc -l < "$LOG_FILE")
    RUN_START_LINE=$((RUN_START_LINE + 1))

    # --- Phase 1: Process UNTOUCHED venues first ---
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
    MAX_UT=${MAX_UT:-0}  # 0 = unlimited; set MAX_UT=2 to limit
    if [ "$UT_COUNT" -gt 0 ]; then
        if [ "$MAX_UT" -gt 0 ]; then
            log "UNTOUCHED: $UT_COUNT found, LIMITED to $MAX_UT"
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
# Sort: actionable venues first (have instagram, website, contact_form, state/city)
def action_score(v):
    score = 0
    if v.get('instagram','') and len(v.get('instagram','')) > 5: score += 3
    if v.get('website','') and len(v.get('website','')) > 5: score += 2
    if v.get('contact_form','') and len(v.get('contact_form','')) > 5: score += 2
    if v.get('state','').strip(): score += 1
    if v.get('city','').strip(): score += 1
    return score
untouched.sort(key=action_score, reverse=True)
max_ut = int(os.environ.get('MAX_UT', '0'))
if max_ut > 0: untouched = untouched[:max_ut]
for i, venue in enumerate(untouched):
    vid = venue.get('venue_id', '')
    name = venue.get('name', '')
    web = venue.get('website', '')
    city = venue.get('city', '')
    print(f'{i}|{name}|{vid}|{web}|{city}')
" 2>/dev/null | while IFS='|' read -r IDX NAME VID WEB CITY; do
            if [ -f "$ZB_EXHAUSTED_FLAG" ] && [ -f "$APOLLO_EXHAUSTED_FLAG" ]; then
                log "[STOP] Both ZeroBounce and Apollo exhausted — skipping remaining untouched venues"
                break
            fi
            log ""
            log "########## UNTOUCHED #$((IDX+1)): $NAME ($VID) ##########"
            run_venue "$NAME" "$VID" "$WEB" "$CITY"
            sleep 30
        done
        log "=== UNTOUCHED PHASE COMPLETE ==="
        log ""
    else
        log "UNTOUCHED: none found — skipping"
    fi

    # --- Phase 2: Smart Picks ---
    # Pull Smart Picks from API in rank order (highest score first)
    log "SMART PICKS MODE: Fetching ranked venues..."
    SP_FILE="/tmp/pipeline_smart_picks.json"
    curl -sL "${APPS_SCRIPT_URL}?action=get_recommendations" -o "$SP_FILE"
    SP_COUNT=$(python3 -c "
import json
with open('$SP_FILE') as f:
    recs = json.load(f).get('recommendations', [])
filtered = [r for r in recs if r.get('status','') not in ('pipelined','contacted')]
print(len(filtered))
" 2>/dev/null)
    MAX_SP=${MAX_SP:-0}  # 0 = unlimited; set MAX_SP=2 to limit
    if [ "$MAX_SP" -gt 0 ]; then
        log "SMART PICKS: $SP_COUNT available, LIMITED to $MAX_SP"
    else
        log "SMART PICKS: $SP_COUNT venues to process"
    fi

    python3 -c "
import json, os
with open('$SP_FILE') as f:
    recs = json.load(f).get('recommendations', [])
filtered = [r for r in recs if r.get('status','') not in ('pipelined','contacted')]
max_sp = int(os.environ.get('MAX_SP', '0'))
if max_sp > 0: filtered = filtered[:max_sp]
for i, r in enumerate(filtered):
    print(f\"{i}|{r['name']}|{r['venue_id']}|{r.get('recommendation_score',0)}\")
" 2>/dev/null | while IFS='|' read -r IDX NAME VID SCORE; do
        if [ -f "$ZB_EXHAUSTED_FLAG" ] && [ -f "$APOLLO_EXHAUSTED_FLAG" ]; then
            log "[STOP] Both ZeroBounce and Apollo exhausted — skipping remaining smart picks"
            break
        fi
        log ""
        log "########## SMART PICK #$((IDX+1)) (score $SCORE): $NAME ($VID) ##########"
        # Fetch website + city from venue detail
        curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" -o /tmp/pipeline_sp_detail.json
        WEB=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sp_detail.json')).get('venue',{}).get('website',''))" 2>/dev/null)
        CITY=$(python3 -c "import json; print(json.load(open('/tmp/pipeline_sp_detail.json')).get('venue',{}).get('city',''))" 2>/dev/null)
        run_venue "$NAME" "$VID" "$WEB" "$CITY"
        if [ "$IDX" -lt "$((SP_COUNT - 1))" ]; then sleep 30; fi
    done
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

    # Generate HTML report
    generate_report "$RUN_START_LINE"

elif [ "$1" = "--linkedin-retry" ]; then
    # Re-run Step 4 (LinkedIn) on venues with linkedin_pending=true
    log "LINKEDIN RETRY MODE: Finding venues with linkedin_pending=true..."
    curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/pipeline_linkedin_retry.json 2>/dev/null
    python3 -c "
import json
with open('/tmp/pipeline_linkedin_retry.json') as f: data = json.load(f)
for v in data.get('venues', []):
    if v.get('linkedin_pending') == True or str(v.get('linkedin_pending','')).lower() == 'true':
        print(f\"{v['venue_id']}|||{v['name']}|||{v.get('website','')}\")
" 2>/dev/null | while IFS='|||' read -r VID NAME WEB; do
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

    # Generate HTML report
    generate_report "$RUN_START_LINE"

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
