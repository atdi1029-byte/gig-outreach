#!/bin/bash
# Backfill missing venue websites without promoting unverified records.
#
# A found URL is VERIFIED only when venue_quality scores it as the venue's own
# domain (>= 6) AND the page mentions the venue's city. Anything weaker is printed
# as a CANDIDATE and nothing is written. Every result is appended to
# reports/backfill-candidates.jsonl. Rows parked in needs_review for a reason
# (closed, too far, junk, quarantine, 0 contacts, ...) are never promoted.
#
# Default is preview-only:
#   ./backfill_websites.sh --limit 25
# Apply verified matches:
#   ./backfill_websites.sh --limit 25 --apply
# Repair one venue:
#   ./backfill_websites.sh --venue VA-REST-123 --apply

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

LIMIT=${MAX_BACKFILL:-25}
APPLY=0
ONLY_VENUE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --limit)
            LIMIT="${2:-}"
            shift 2 || { echo "ERROR: --limit needs a number" >&2; exit 2; }
            ;;
        --venue)
            ONLY_VENUE="${2:-}"
            shift 2 || { echo "ERROR: --venue needs a venue_id" >&2; exit 2; }
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 100 ]; then
    echo "ERROR: --limit must be between 1 and 100." >&2
    exit 2
fi

EXTRACT_JS="$SCRIPT_DIR/js/extract_cite.js"
if [ ! -f "$EXTRACT_JS" ]; then
    echo "ERROR: missing $EXTRACT_JS" >&2
    exit 2
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/backfill.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK_DIR"' EXIT
VENUES_JSON="$WORK_DIR/venues.json"
LIST_TSV="$WORK_DIR/list.tsv"
CANDIDATE_LOG="$SCRIPT_DIR/reports/backfill-candidates.jsonl"
for action in venues dashboard; do
    curl -fsSL --max-time 180 "${APPS_SCRIPT_URL}?action=${action}" -o "$WORK_DIR/$action.json" &&
    python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('status') == 'ok' else 1)" "$WORK_DIR/$action.json" 2>/dev/null || {
        echo "ERROR: could not fetch ${action}." >&2
        exit 1
    }
done

api_update() {
    local vid="$1" field="$2" value="$3"
    local encoded response
    encoded=$(python3 - "$vid" "$field" "$value" <<'PY'
import sys, urllib.parse
print(urllib.parse.urlencode({
    'action': 'update_venue', 'venue_id': sys.argv[1],
    'field': sys.argv[2], 'value': sys.argv[3]
}))
PY
)
    response=$(curl -fsSL --max-time 20 "${APPS_SCRIPT_URL}?${encoded}" 2>/dev/null) || return 1
    echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get('status') == 'ok' else 1)" 2>/dev/null
}

verify_readback() {  # verify_readback VID WEBSITE STATUS
    local vid="$1" expected="$2" want_status="$3"
    curl -fsSL --max-time 20 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${vid}" 2>/dev/null |
        EXPECTED_WEBSITE="$expected" WANT_STATUS="$want_status" python3 -c "
import json, os, sys
d=json.load(sys.stdin); v=d.get('venue',{})
ok=(v.get('website','').rstrip('/') == os.environ['EXPECTED_WEBSITE'].rstrip('/')
    and v.get('status','') == os.environ['WANT_STATUS'])
raise SystemExit(0 if ok else 1)
"
}

log_candidate() {  # log_candidate VID NAME URL RESULT WHY
    mkdir -p "$(dirname "$CANDIDATE_LOG")"
    python3 - "$@" >> "$CANDIDATE_LOG" <<'PY'
import json, sys, datetime
vid, name, url, result, why = sys.argv[1:6]
print(json.dumps({'ts': datetime.datetime.now().isoformat(timespec='seconds'), 'venue_id': vid,
                  'name': name, 'url': url, 'result': result, 'why': why}))
PY
}

MODE="PREVIEW"
[ "$APPLY" -eq 1 ] && MODE="APPLY"
echo "Website backfill: $MODE mode, limit $LIMIT"

ONLY_VENUE="$ONLY_VENUE" LIMIT="$LIMIT" SCRIPT_DIR="$SCRIPT_DIR" python3 - "$VENUES_JSON" "$WORK_DIR/dashboard.json" > "$LIST_TSV" <<'PY' || { echo "ERROR: could not build the venue list." >&2; exit 1; }
import json, os, re, sys
sys.path.insert(0, os.environ['SCRIPT_DIR'])
import outreach_rules as R
from venue_classifier import classify, junk_reason, TARGET_CATEGORIES
with open(sys.argv[1]) as f:
    venues=json.load(f).get('venues',[])
if not any('notes' in v for v in venues[:50]):
    dv={v.get('venue_id'): v for v in json.load(open(sys.argv[2])).get('venues',[])}
    for v in venues:
        for k in ('notes','check_status'):
            if k not in v and k in (dv.get(v.get('venue_id')) or {}):
                v[k]=dv[v['venue_id']][k]
# needs_review rows parked for a reason must stay parked (same words the app uses).
parked=re.compile(r'pipeline|0 contacts|zero contacts|closed|dead|not a venue|junk|motel|airbnb|'
                  r'vrbo|too far|out of area|quarantin|duplicate|wrong business|flag', re.I)
rows=[]
for v in venues:
    if os.environ.get('ONLY_VENUE') and v.get('venue_id') != os.environ['ONLY_VENUE']:
        continue
    status=v.get('status','')
    if status not in ('untouched','needs_review'):
        continue
    if (v.get('website') or '').strip():
        continue
    name=(v.get('name') or '').strip(); city=(v.get('city') or '').strip()
    state=(v.get('state') or '').strip().upper()
    if not name or not city or state not in R.TARGET_STATES:
        continue
    if len(city)>30 or re.search(r'\d{3,}|https?://|\.com|prices|near me|open now',city.lower()):
        continue
    if status=='needs_review' and parked.search(str(v.get('check_status') or '')+' '+str(v.get('notes') or '')):
        continue
    if junk_reason(name, v.get('category',''), v.get('notes',''), '', v.get('check_status','')):
        continue
    c=classify(name, v.get('category',''), v.get('notes',''), '', v.get('venue_id',''))
    if c['primary_category'] not in TARGET_CATEGORIES:
        continue
    try: score=float(v.get('upscale_score',0) or 0)
    except (TypeError,ValueError): score=0
    rows.append((-score,name.lower(),len(rows),v))
for _,__,___,v in sorted(rows)[:int(os.environ['LIMIT'])]:
    vals=[v.get('venue_id',''),v.get('name',''),v.get('city',''),v.get('state',''),v.get('category',''),str(v.get('upscale_score','')),v.get('status','')]
    print('\t'.join(str(x).replace('\t',' ').replace('\n',' ') for x in vals))
PY

VENUE_COUNT=$(wc -l < "$LIST_TSV" | tr -d ' ')
echo "Found $VENUE_COUNT eligible venues"
if [ "$VENUE_COUNT" -eq 0 ]; then
    echo "No venues to process."
    exit 0
fi

processed=0
matched=0
candidates=0
failed=0
empty_streak=0

while IFS=$'\t' read -r VID NAME CITY STATE CATEGORY SCORE ORIG_STATUS; do
    [ -z "$VID" ] && continue
    processed=$((processed + 1))
    echo ""
    echo "[$processed/$LIMIT] $NAME — $CITY, $STATE ($VID)"

    # Existing missing-site records are not eligible for bulk outreach while
    # repair is in progress.
    if [ "$APPLY" -eq 1 ] && [ "$ORIG_STATUS" = "untouched" ]; then
        if ! api_update "$VID" status needs_review; then
            echo "  ERROR: could not quarantine record; skipping"
            failed=$((failed + 1))
            continue
        fi
    fi

    SEARCH_QUERY="\"$NAME\" \"$CITY\" $STATE official website"
    SEARCH_ENCODED=$(python3 - "$SEARCH_QUERY" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\"" 2>/dev/null || true
    sleep 6
    FOUND_RAW=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"$EXTRACT_JS"'" as «class utf8»)' 2>/dev/null)
    if [ -z "$FOUND_RAW" ] || [ "$FOUND_RAW" = "missing value" ]; then
        echo "  Chrome returned nothing (JS from Apple Events off, Google blocking, or no results)"
        failed=$((failed + 1))
        empty_streak=$((empty_streak + 1))
        if [ "$empty_streak" -ge 10 ]; then
            echo "STOP: ten consecutive misses; check Chrome/Apple Events or Google blocking."
            break
        fi
        continue
    fi

    # Prints "VERIFIED<TAB>url<TAB>why", "CANDIDATE<TAB>url<TAB>why" or nothing.
    FOUND=$(SCRIPT_DIR="$SCRIPT_DIR" python3 - "$NAME" "$CITY" "$FOUND_RAW" <<'PY'
import html, os, re, subprocess, sys, unicodedata
from urllib.parse import urlparse
sys.path.insert(0, os.environ['SCRIPT_DIR'])
from venue_quality import choose_website, website_match_score

name, city, raw = sys.argv[1:4]
junk = {
    'facebook.com','instagram.com','linkedin.com','yelp.com','tripadvisor.com',
    'google.com','wikipedia.org','eventbrite.com','opentable.com','resy.com',
    'fox5dc.com','washingtonpost.com','washingtonian.com','wtop.com',
    'visitmaryland.org','virginia.org','dcpreservation.org','yellowpages.com',
    'grubhub.com','doordash.com','ubereats.com','menuism.com','allmenus.com',
    'zomato.com','foursquare.com','mapquest.com','bbb.org','chamberofcommerce.com'
}
def norm(s):
    s=unicodedata.normalize('NFKD', s or '')
    s=''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'[^a-z0-9]', '', s.lower())
name_n=norm(name)
city_n=norm(city)
words=[w for w in re.findall(r'[a-z0-9]+', name.lower()) if len(w)>=3
       and w not in {'the','and','of','at','in','by','for','a','an'}]

# Collect clean non-junk candidates
candidates=[]
for c in raw.split('|'):
    c=c.strip()
    if not c.startswith(('http://','https://')):
        continue
    p=urlparse(c)
    domain=p.netloc.lower().removeprefix('www.')
    if not domain or any(domain == j or domain.endswith('.'+j) for j in junk):
        continue
    if domain.endswith(('.edu','.gov','.mil')):
        continue
    clean=p._replace(query='',fragment='').geturl().rstrip('/')
    candidates.append(clean)

def page_text(url):
    try:
        body=subprocess.run(['curl','-fsSL','--max-time','8','-A','Mozilla/5.0',url],
                            capture_output=True,text=True,timeout=10).stdout[:300000]
    except Exception:
        return ''
    return norm(html.unescape(re.sub(r'<[^>]+>',' ',body)))

# Only a URL whose domain is the venue's own (venue_quality >= 6) can be
# VERIFIED, and only when the page also names the venue's city.
best=choose_website(name, '|'.join(candidates[:5]))
if best:
    text_n=page_text(best)
    if city_n and city_n in text_n:
        print(f"VERIFIED\t{best}\tdomain match {website_match_score(name, best)}, city on page")
    elif not text_n:
        print(f"CANDIDATE\t{best}\tdomain matches but page could not be fetched")
    else:
        print(f"CANDIDATE\t{best}\tdomain matches but page does not mention {city}")
else:
    for url in candidates[:3]:
        text_n=page_text(url)
        hits=sum(1 for w in set(words) if norm(w) in text_n)
        if text_n and (name_n in text_n or hits >= max(1, len(set(words))//2)):
            print(f"CANDIDATE\t{url}\tpage mentions the name but the domain is not the venue's")
            break
PY
)
    RESULT=$(printf '%s' "$FOUND" | cut -f1)
    FOUND_WEB=$(printf '%s' "$FOUND" | cut -f2)
    WHY=$(printf '%s' "$FOUND" | cut -f3)
    empty_streak=0

    if [ "$RESULT" != "VERIFIED" ]; then
        if [ -n "$FOUND_WEB" ]; then
            echo "  CANDIDATE (not saved): $FOUND_WEB — $WHY"
            log_candidate "$VID" "$NAME" "$FOUND_WEB" candidate "$WHY"
            candidates=$((candidates + 1))
        else
            echo "  No website match; remains needs_review"
            failed=$((failed + 1))
        fi
        continue
    fi

    echo "  VERIFIED: $FOUND_WEB ($WHY)"
    log_candidate "$VID" "$NAME" "$FOUND_WEB" verified "$WHY"
    if [ "$APPLY" -eq 1 ]; then
        if api_update "$VID" website "$FOUND_WEB" && \
           api_update "$VID" status untouched && \
           verify_readback "$VID" "$FOUND_WEB" untouched; then
            echo "  SAVED + READ BACK"
            matched=$((matched + 1))
        else
            echo "  ERROR: write/readback failed; returning to needs_review"
            api_update "$VID" status needs_review || true
            failed=$((failed + 1))
        fi
    else
        echo "  WOULD SAVE (rerun with --apply)"
        matched=$((matched + 1))
    fi
    sleep 1
done < "$LIST_TSV"

echo ""
echo "Complete: processed=$processed verified=$matched candidates=$candidates unresolved=$failed mode=$MODE"
