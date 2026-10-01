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
. "$SCRIPT_DIR/chrome_guard.sh" || exit 1
# Google's CAPTCHA is shared with the pipeline: a block here means no Google for it either
. "$SCRIPT_DIR/google_guard.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

LIMIT=${MAX_BACKFILL:-25}
# Seconds between two Google searches (random in the range). Oct 1 2026: one search every
# ~13 s got Google's CAPTCHA at the 20th, two nights running, and the block then stopped the
# pipeline's own searches. About one a minute is what the pipeline does without trouble.
GAP_MIN_S="${BACKFILL_GAP_MIN_S:-40}"
GAP_MAX_S="${BACKFILL_GAP_MAX_S:-70}"
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
# The results are read together with the page's address, so a search that never
# loaded can't hand over the previous venue's results (Sep 30: two venues got them)
READ_JS="$WORK_DIR/read_search.js"
{ printf 'location.href + "\\n" + '; cat "$EXTRACT_JS"; } > "$READ_JS"
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

is_search_for() {  # is_search_for PAGE_URL QUERY — 0 when Chrome shows Google's results for QUERY
    python3 - "$1" "$2" <<'PY'
import sys
from urllib.parse import urlsplit, parse_qs
u = urlsplit(sys.argv[1])
q = (parse_qs(u.query).get('q') or [''])[0]
norm = lambda s: ' '.join(s.split()).casefold()
ok = bool(u.hostname) and 'google.' in u.hostname and u.path == '/search' and norm(q) == norm(sys.argv[2])
sys.exit(0 if ok else 1)
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
# The night run calls this every night: a venue looked up in the last 14 days waits its turn,
# so a few that Google can't place don't take the same slots night after night.
recent=set()
try:
    import datetime
    cut=(datetime.datetime.now()-datetime.timedelta(days=14)).isoformat()
    for line in open(os.path.join(os.environ['SCRIPT_DIR'],'reports','backfill-candidates.jsonl')):
        try:
            r=json.loads(line)
        except ValueError:
            continue
        if str(r.get('ts',''))>=cut:
            recent.add(r.get('venue_id'))
except OSError:
    pass
# A sweep find whose "website" is a brand homepage (marriott.com), a tourism/news page or a
# listing gets looked up like a missing one; the result replaces it only when VERIFIED.
BRAND_HOMES={'marriott.com','hilton.com','hyatt.com','ihg.com','ritzcarlton.com','fourseasons.com',
             'citizenm.com','invitedclubs.com','sonesta.com','kimptonhotels.com','choicehotels.com',
             'wyndhamhotels.com','sunriseseniorliving.com','brightviewseniorliving.com'}
LISTING_PARTS=('visitannapolis.org','visitmaryland.org','virginia.org','visitvirginia.com','baltimore.org',
               'eventbrite.com','meetup.com','dcpreservation.org','nextdoor.com','groupon.com')
def replaceable_site(site):
    reg=R.registrable_domain(site)
    path=re.sub(r'^https?://[^/]+','',site.strip(),flags=re.I).strip('/')
    host=R.host_of(site)
    return ((reg in BRAND_HOMES or reg in R.SHARED_BRAND_DOMAINS) and not path) or \
        R.is_non_venue_host(site) or any(p in host for p in LISTING_PARTS)
rows=[]
for v in venues:
    if os.environ.get('ONLY_VENUE') and v.get('venue_id') != os.environ['ONLY_VENUE']:
        continue
    if not os.environ.get('ONLY_VENUE') and v.get('venue_id') in recent:
        continue
    status=v.get('status','')
    if status not in ('untouched','needs_review'):
        continue
    site=(v.get('website') or '').strip()
    if site and not (R.is_sweep_find(v) and replaceable_site(site)):
        continue
    name=(v.get('name') or '').strip(); city=(v.get('city') or '').strip()
    state=(v.get('state') or '').strip().upper()
    if not name or not city or not R.sweep_state_ok(state, R.is_sweep_find(v)):
        continue
    if len(city)>30 or re.search(r'\d{3,}|https?://|\.com|prices|near me|open now',city.lower()):
        continue
    if status=='needs_review' and parked.search(str(v.get('check_status') or '')+' '+str(v.get('notes') or '')):
        continue
    # Sweep finds only skip hard junk (Alex, Sep 29: everything on the sweep is usable)
    sweep=R.is_sweep_find(v)
    jr=junk_reason(name, v.get('category',''), v.get('notes',''), '', v.get('check_status',''))
    if jr and not (sweep and not R.HARD_JUNK_RX.search(jr)):
        continue
    c=classify(name, v.get('category',''), v.get('notes',''), '', v.get('venue_id',''))
    if c['primary_category'] not in TARGET_CATEGORIES and not sweep:
        continue
    try: score=float(v.get('upscale_score',0) or 0)
    except (TypeError,ValueError): score=0
    # sweep finds in DC/MD/VA first, then other DC/MD/VA rows, PA/DE sweep finds last
    rows.append((2 if state in R.LAST_STATES else 0 if sweep else 1,-score,name.lower(),len(rows),v))
for *_,v in sorted(rows, key=lambda r: r[:4])[:int(os.environ['LIMIT'])]:
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

    # Google is waited out, never searched through: the rest wait for the next night
    # (nothing was looked up, so they keep their place in the rotation)
    if google_cooling; then
        echo "STOP: Google is blocking searches (CAPTCHA) until $GOOGLE_RETRY_AT — the rest wait for the next night."
        processed=$((processed - 1))
        break
    fi

    # Another copy of Chrome would take every command (chrome_guard.sh): wait it out
    if ! chrome_wait_alone; then
        echo "STOP: $CHROME_ALONE_DETAIL"
        processed=$((processed - 1))
        break
    fi

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
    google_pace "$GAP_MIN_S" "$GAP_MAX_S"
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"https://www.google.com/search?q=${SEARCH_ENCODED}\"" 2>/dev/null || true
    # Only results from THIS search count: the page's address must be it
    FOUND_RAW=""; PAGE_URL=""; ON_SEARCH=0
    for WAIT_S in 6 4 4; do
        sleep "$WAIT_S"
        PAGE_OUT=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript (read POSIX file "'"$READ_JS"'" as «class utf8»)' 2>/dev/null)
        PAGE_URL="${PAGE_OUT%%$'\n'*}"
        if is_search_for "$PAGE_URL" "$SEARCH_QUERY"; then
            ON_SEARCH=1
            google_mark_ok
            case "$PAGE_OUT" in *$'\n'*) FOUND_RAW="${PAGE_OUT#*$'\n'}" ;; esac
            break
        fi
        case "$PAGE_URL" in *google.*/sorry/*|*google.*/recaptcha/*) break ;; esac
    done
    if [ -z "$FOUND_RAW" ] || [ "$FOUND_RAW" = "missing value" ]; then
        failed=$((failed + 1))
        if [ "$ON_SEARCH" = 1 ]; then
            # A real results page without a usable link says nothing about Chrome
            echo "  Google's results page had no usable links"
            empty_streak=0
            [ "$APPLY" -eq 1 ] && log_candidate "$VID" "$NAME" "" none "no usable links on Google"
            continue
        fi
        case "$PAGE_URL" in
            *google.*/sorry/*|*google.*/recaptcha/*)
                google_mark_blocked
                echo "  Google showed its CAPTCHA (unusual traffic) instead of results"
                echo "STOP: Google is blocking searches until $GOOGLE_RETRY_AT — stopping here so the block ends sooner; the rest wait for the next night."
                break ;;
        esac
        SHOWN="${PAGE_URL:-nothing}"
        echo "  Chrome didn't show this search (it showed: ${SHOWN:0:90}) — JS from Apple Events off, Google blocking, or the page never loaded"
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
            [ "$APPLY" -eq 1 ] && log_candidate "$VID" "$NAME" "" none "no website match"
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
