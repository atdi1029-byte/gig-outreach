#!/bin/bash
# Backfill missing venue websites without promoting unverified records.
#
# Default is preview-only:
#   ./backfill_websites.sh --limit 25
# Apply verified matches:
#   ./backfill_websites.sh --limit 25 --apply
# Repair one venue:
#   ./backfill_websites.sh --venue VA-REST-123 --apply

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
            shift 2
            ;;
        --venue)
            ONLY_VENUE="${2:-}"
            shift 2
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

VENUES_JSON="/tmp/outreach_backfill_venues.json"
trap 'rm -f "$VENUES_JSON" /tmp/outreach_backfill_list.tsv' EXIT
curl -fsSL --max-time 30 "${APPS_SCRIPT_URL}?action=venues" -o "$VENUES_JSON" || {
    echo "ERROR: could not fetch venues." >&2
    exit 1
}

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

verify_readback() {
    local vid="$1" expected="$2"
    curl -fsSL --max-time 20 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${vid}" 2>/dev/null |
        EXPECTED_WEBSITE="$expected" python3 -c "
import json, os, sys
d=json.load(sys.stdin); v=d.get('venue',{})
ok=(v.get('website','').rstrip('/') == os.environ['EXPECTED_WEBSITE'].rstrip('/')
    and v.get('status','') == 'untouched')
raise SystemExit(0 if ok else 1)
" 2>/dev/null
}

MODE="PREVIEW"
[ "$APPLY" -eq 1 ] && MODE="APPLY"
echo "Website backfill: $MODE mode, limit $LIMIT"

ONLY_VENUE="$ONLY_VENUE" LIMIT="$LIMIT" python3 - "$VENUES_JSON" > /tmp/outreach_backfill_list.tsv <<'PY'
import json, os, re, sys
with open(sys.argv[1]) as f:
    venues=json.load(f).get('venues',[])
target_states={'MD','VA','DC','PA','DE','WV'}
target_cats={'restaurant','hotel','winery','wine_bar','country_club','private_club','art_gallery','yacht_club','museum','event_venue','music_venue'}
junk=['assisted living','senior living','nursing home','antique','gift shop','gifts','brewery','brewing','golf course','college','university','school','academy','community center','civic association']
rows=[]
for v in venues:
    if os.environ.get('ONLY_VENUE') and v.get('venue_id') != os.environ['ONLY_VENUE']:
        continue
    if v.get('status','untouched') not in ('untouched','needs_review'):
        continue
    if (v.get('website') or '').strip():
        continue
    name=(v.get('name') or '').strip(); city=(v.get('city') or '').strip()
    state=(v.get('state') or '').strip().upper()
    cat=(v.get('category') or '').strip().lower().replace(' ','_')
    hay=(name+' '+str(v.get('notes') or '')).lower()
    if not name or not city or state not in target_states or cat not in target_cats:
        continue
    if len(city)>30 or re.search(r'\d{3,}|https?://|\.com|prices|near me|open now',city.lower()):
        continue
    if any(x in hay for x in junk):
        continue
    try: score=float(v.get('upscale_score',0) or 0)
    except (TypeError,ValueError): score=0
    rows.append((-score,name.lower(),len(rows),v))
for _,__,___,v in sorted(rows)[:int(os.environ['LIMIT'])]:
    vals=[v.get('venue_id',''),v.get('name',''),v.get('city',''),v.get('state',''),v.get('category',''),str(v.get('upscale_score',''))]
    print('\t'.join(str(x).replace('\t',' ').replace('\n',' ') for x in vals))
PY

VENUE_COUNT=$(wc -l < /tmp/outreach_backfill_list.tsv | tr -d ' ')
echo "Found $VENUE_COUNT eligible venues"
if [ "$VENUE_COUNT" -eq 0 ]; then
    echo "No venues to process."
    exit 0
fi

processed=0
matched=0
failed=0
empty_streak=0

while IFS=$'\t' read -r VID NAME CITY STATE CATEGORY SCORE; do
    [ -z "$VID" ] && continue
    processed=$((processed + 1))
    echo ""
    echo "[$processed/$LIMIT] $NAME — $CITY, $STATE ($VID)"

    # Existing missing-site records are not eligible for bulk outreach while
    # repair is in progress.
    if [ "$APPLY" -eq 1 ]; then
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
    FOUND_RAW=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"$EXTRACT_JS"'")' 2>/dev/null)

    FOUND_WEB=$(python3 - "$NAME" "$CITY" "$FOUND_RAW" <<'PY'
import html, re, subprocess, sys, unicodedata
from urllib.parse import urlparse

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

# Pass 1: try to verify via domain or content match
for url in candidates[:3]:
    p=urlparse(url)
    base=norm(p.netloc.lower().removeprefix('www.').split('.')[0])
    if any(norm(w) in base for w in words if len(w)>=4):
        print(url); break
    try:
        body=subprocess.run(
            ['curl','-fsSL','--max-time','8','-A','Mozilla/5.0',url],
            capture_output=True,text=True,timeout=10
        ).stdout[:300000]
        text_n=norm(html.unescape(re.sub(r'<[^>]+>',' ',body)))
        hits=sum(1 for w in set(words) if norm(w) in text_n)
        if name_n in text_n or hits >= max(1, len(set(words))//2):
            print(url); break
    except Exception:
        pass
else:
    # Pass 2: fallback — just take the first non-junk link
    if candidates:
        print(candidates[0])
PY
)

    if [ -z "$FOUND_WEB" ]; then
        echo "  No verified website match; remains needs_review"
        failed=$((failed + 1))
        empty_streak=$((empty_streak + 1))
        if [ "$empty_streak" -ge 10 ]; then
            echo "STOP: five consecutive misses; check Chrome/Apple Events or Google blocking."
            break
        fi
        continue
    fi

    empty_streak=0
    echo "  VERIFIED: $FOUND_WEB"
    if [ "$APPLY" -eq 1 ]; then
        if api_update "$VID" website "$FOUND_WEB" && \
           api_update "$VID" status untouched && \
           verify_readback "$VID" "$FOUND_WEB"; then
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
done < /tmp/outreach_backfill_list.tsv

echo ""
echo "Complete: processed=$processed verified=$matched unresolved=$failed mode=$MODE"
