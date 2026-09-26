#!/bin/bash
# =============================================================
# Build Pipeline Batch — SAFE venue selection
#
# Usage:
#   ./build_batch.sh [COUNT] [--dry-run]     one batch of COUNT (default 8, max 8)
#                                            -> /tmp/pipeline_batch.json
#   ./build_batch.sh --total 50 [--dry-run]  a whole run: 50 venues split into
#                                            consecutive batches of <= 8, no repeats
#                                            -> reports/runs/plans/<stamp>/batch_NN.json
#                                               + plan.json (path also in plans/LATEST)
#   Options: --out-dir DIR (with --total), --exclude FILE (venue_ids to leave out:
#            a batch/plan JSON, a ledger .jsonl, or one id per line; repeatable)
#   ALLOW_LARGE_BATCH=1 lifts the 8-per-batch cap (P6) for a single batch.
#
# FILTERS (cannot be bypassed; --dry-run prints a count and examples of each):
#   - status=untouched only; thumbs-down votes excluded
#   - past gigs excluded by gig venue_id, normalized name ('The', punctuation,
#     city suffixes) and the gig venue's website domain
#   - no existing contacts, not in any report (manifest venue_ids) or --exclude
#   - website present, not a directory/social/news host, not a domain already
#     pipelined, and the site plausibly the venue's own (venue_quality score >= 6)
#   - DC/MD/VA only (P5), within ~2h drive (distance_miles/drive_minutes), and a
#     trustworthy city (see taste_score.location_info)
#   - junk gate (venue_classifier.junk_reason): motels, budget/extended-stay and
#     mainstream chains, vacation rentals, closed/flagged, adult/nightlife, fast
#     food, HOAs, badly rated places
#   - a real category (venue_classifier.TARGET_CATEGORIES, classifier confidence)
#
# RANKING: taste_score.py (the single source of truth), computed live.
# MIX: buckets per taste_score.BUCKET_SHARES (per 16: ~5 French/fine dining,
#   3 clubs, 3 luxury hotels/inns, 3 wineries/wine bars, 2 wild cards), applied
#   across the whole --total run; each batch gets a share of every bucket.
#   Within a bucket: better taste tier first, then closer venues first.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
BATCH_FILE="/tmp/pipeline_batch.json"
MAX_BATCH=8
MAX_TOTAL=80

usage() { sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'; }

COUNT=""
TOTAL=""
DRY_RUN=0
OUT_DIR=""
EXCLUDES=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --total) TOTAL="${2:-}"; shift 2 || { echo "ERROR: --total needs a number" >&2; exit 2; } ;;
        --total=*) TOTAL="${1#--total=}"; shift ;;
        --out-dir) OUT_DIR="${2:-}"; shift 2 || { echo "ERROR: --out-dir needs a path" >&2; exit 2; } ;;
        --exclude)
            [ -f "${2:-}" ] || { echo "ERROR: --exclude file not found: ${2:-}" >&2; exit 2; }
            EXCLUDES="${EXCLUDES}${EXCLUDES:+:}$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$COUNT" ]; then
                COUNT="$1"; shift
            else
                echo "ERROR: unknown argument: $1" >&2
                usage >&2
                exit 2
            fi ;;
    esac
done

if [ -n "$TOTAL" ]; then
    if [ -n "$COUNT" ]; then
        echo "ERROR: give either COUNT (one batch) or --total N (a run), not both." >&2
        exit 2
    fi
    if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [ "$TOTAL" -lt 1 ] || [ "$TOTAL" -gt "$MAX_TOTAL" ]; then
        echo "ERROR: --total must be 1-$MAX_TOTAL." >&2
        exit 2
    fi
else
    COUNT="${COUNT:-8}"
    if [ "$COUNT" -lt 1 ]; then
        echo "ERROR: COUNT must be at least 1." >&2
        exit 2
    fi
    if [ "$COUNT" -gt "$MAX_BATCH" ] && [ "${ALLOW_LARGE_BATCH:-0}" != "1" ]; then
        echo "ERROR: max $MAX_BATCH venues per batch (P6). For a bigger run use --total $COUNT" >&2
        echo "       (writes consecutive batches of <= $MAX_BATCH), or set ALLOW_LARGE_BATCH=1." >&2
        exit 2
    fi
fi
if [ -n "$OUT_DIR" ] && [ -z "$TOTAL" ]; then
    echo "ERROR: --out-dir only applies with --total." >&2
    exit 2
fi

# Rewriting batch files under a running pipeline changes what it processes
# (pipeline.sh re-reads the batch file for every venue).
if [ "$DRY_RUN" = "0" ] && [ -f /tmp/pipeline.lock ]; then
    LOCK_PID=$(cat /tmp/pipeline.lock 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: pipeline.sh is running (PID $LOCK_PID). Build the next batch after it finishes, or use --dry-run." >&2
        exit 1
    fi
fi

# A failed build must never leave the previous batch behind for the runbook to pick up.
if [ "$DRY_RUN" = "0" ]; then
    rm -f "$BATCH_FILE"
fi

if [ -n "$TOTAL" ]; then
    echo "Building a run of $TOTAL venues (batches of <= $MAX_BATCH)..."
else
    echo "Building batch of $COUNT venues..."
fi
if [ "$DRY_RUN" = "1" ]; then echo "[DRY RUN — will not save batch]"; fi
echo "Fetching venues + past gigs..."

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/build_batch.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK_DIR"' EXIT

fetch() {  # fetch ACTION OUTFILE — up to 3 tries, must be JSON with status ok
    local action="$1" out="$2" try
    for try in 1 2 3; do
        if curl -fsSL --max-time 180 "${APPS_SCRIPT_URL}?action=${action}" -o "$out" 2>"$WORK_DIR/curl.err" &&
           python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and d.get('status') == 'ok' else 1)" "$out" 2>/dev/null; then
            return 0
        fi
        sleep $((try * 5))
    done
    echo "ERROR: could not fetch ?action=${action} (curl: $(head -c 200 "$WORK_DIR/curl.err" 2>/dev/null); body: $(head -c 200 "$out" 2>/dev/null))" >&2
    return 1
}

if [ -n "${BB_SNAPSHOT_DIR:-}" ]; then
    # Offline testing: read venues.json / get_gigs.json / dashboard.json from a directory.
    echo "  (offline: using snapshot files in $BB_SNAPSHOT_DIR)"
    cp "$BB_SNAPSHOT_DIR/venues.json" "$WORK_DIR/venues.json" &&
    cp "$BB_SNAPSHOT_DIR/get_gigs.json" "$WORK_DIR/gigs.json" &&
    cp "$BB_SNAPSHOT_DIR/dashboard.json" "$WORK_DIR/dashboard.json" || { echo "ERROR: snapshot files missing" >&2; exit 1; }
else
    fetch venues "$WORK_DIR/venues.json" || exit 1
    fetch get_gigs "$WORK_DIR/gigs.json" || exit 1
    fetch dashboard "$WORK_DIR/dashboard.json" || exit 1
fi

if [ -n "$TOTAL" ] && [ "$DRY_RUN" = "0" ] && [ -z "$OUT_DIR" ]; then
    OUT_DIR="$SCRIPT_DIR/reports/runs/plans/plan-$(date +%Y%m%d-%H%M%S)"
fi

SCRIPT_DIR="$SCRIPT_DIR" WORK_DIR="$WORK_DIR" COUNT="${COUNT:-0}" TOTAL="${TOTAL:-0}" \
DRY_RUN="$DRY_RUN" OUT_DIR="$OUT_DIR" EXCLUDES="$EXCLUDES" BATCH_FILE="$BATCH_FILE" \
MAX_BATCH="$MAX_BATCH" python3 - <<'PYEOF'
import json, os, re, sys, unicodedata
from collections import defaultdict, Counter
from datetime import datetime

SCRIPT_DIR = os.environ['SCRIPT_DIR']
WORK = os.environ['WORK_DIR']
DRY_RUN = os.environ['DRY_RUN'] == '1'
TOTAL = int(os.environ['TOTAL'] or 0)
COUNT = TOTAL if TOTAL else int(os.environ['COUNT'] or 8)
MAX_BATCH = int(os.environ['MAX_BATCH'])
sys.path.insert(0, SCRIPT_DIR)
# No silent fallback scorer: without these modules every venue would rank on
# upscale_score (1-5) and the batch would come out empty.
import outreach_rules as R
from venue_classifier import classify, junk_reason, TARGET_CATEGORIES
from taste_score import (score as ts_score, location_info, bucket as ts_bucket,
                         BUCKET_SHARES, BUCKET_ORDER, BUCKET_MIN_SCORE, MIN_TASTE_SCORE,
                         SCORE_VERSION)
from venue_quality import website_match_score, OFFICIAL_PARENT_DOMAINS, PLATFORM_DOMAINS


def die(msg, code=3):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def load(name, key):
    try:
        with open(os.path.join(WORK, name)) as f:
            d = json.load(f)
    except Exception as e:
        die(f"{name} is not valid JSON: {e}")
    if not isinstance(d.get(key), list):
        die(f"{name} has no '{key}' list (keys: {sorted(d)[:12]})")
    return d


venues = load('venues.json', 'venues')['venues']
gigs = load('gigs.json', 'gigs')['gigs']
dash = load('dashboard.json', 'contacts')
if not venues:
    die("?action=venues returned 0 venues")

# ?action=venues on the old backend lacks notes/votes/address/distance. The
# dashboard payload carries them, so merge by venue_id (status etc. stay from
# the fresher venues call).
RICH = ('notes', 'address', 'venue_vote', 'venue_feedback', 'distance_miles',
        'drive_minutes', 'taste_score', 'priority_override', 'source', 'check_status')
if not any('notes' in v for v in venues[:50]):
    dv = {v.get('venue_id'): v for v in (dash.get('venues') or [])}
    if dv and any('notes' in v for v in list(dv.values())[:50]):
        print("WARN: ?action=venues has no notes/venue_vote/address/distance (old Apps Script "
              "backend); using the dashboard's copy of those fields until the backend is redeployed.")
        for v in venues:
            src = dv.get(v.get('venue_id')) or {}
            for k in RICH:
                if k not in v and k in src:
                    v[k] = src[k]
    else:
        print("WARN: DEGRADED — neither ?action=venues nor the dashboard returns notes/venue_vote/"
              "distance. Thumbs-down, junk-notes and location checks cannot run; radius falls back "
              "to the city field.")
DEGRADED = not any('distance_miles' in v for v in venues[:200])

# ---------------------------------------------------------------- exclusions
already_reported = set()
manifest_path = os.path.join(SCRIPT_DIR, 'reports', 'manifest.json')
if os.path.exists(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except Exception as e:
        die(f"reports/manifest.json is unreadable ({e}); refusing to build a batch that "
            "could repeat reported venues.")
    for entry in manifest if isinstance(manifest, list) else []:
        for vid in entry.get('venue_ids', []) or []:
            already_reported.add(str(vid))


def ids_from_file(path):
    ids = set()
    try:
        text = open(path).read()
    except Exception as e:
        die(f"cannot read --exclude file {path}: {e}", 2)
    try:
        d = json.loads(text)
        items = d.get('venue_ids') if isinstance(d, dict) else d
        for x in items or []:
            ids.add(str(x.get('venue_id') if isinstance(x, dict) else x))
        return ids
    except ValueError:
        pass
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            x = json.loads(line)
            if isinstance(x, dict) and x.get('venue_id'):
                ids.add(str(x['venue_id']))
            continue
        except ValueError:
            ids.add(line.split()[0])
    return ids


excluded_ids = set()
for p in filter(None, os.environ.get('EXCLUDES', '').split(':')):
    excluded_ids |= ids_from_file(p)
# Venues registered in the current run's ledger (a run in progress).
cur = os.path.join(SCRIPT_DIR, 'reports', 'runs', 'CURRENT')
if os.path.exists(cur):
    rid = open(cur).read().strip()
    led = os.path.join(SCRIPT_DIR, 'reports', 'runs', f'{rid}.jsonl')
    if rid and os.path.exists(led):
        excluded_ids |= ids_from_file(led)


def site_key(url):
    """Registrable domain; the full host on site builders (x.wixsite.com); host +
    path on multi-property brand domains (sonesta.com/...)."""
    reg = R.registrable_domain(url or '')
    if not reg:
        return ''
    if reg in PLATFORM_DOMAINS:
        return R.host_of(url)
    if reg in R.SHARED_BRAND_DOMAINS or reg in OFFICIAL_PARENT_DOMAINS:
        u = re.sub(r'^[a-z]+://', '', (url or '').strip().lower()).split('?')[0].split('#')[0]
        u = re.sub(r'^www\.', '', u).rstrip('/')
        return u if '/' in u else ''    # bare brand homepage identifies nothing
    return reg


LOC_WORDS = {'dc', 'va', 'md', 'washington', 'georgetown', 'bethesda', 'alexandria',
             'annapolis', 'baltimore', 'arlington', 'mclean', 'potomac', 'reston',
             'vienna', 'leesburg', 'middleburg', 'easton', 'rockville', 'columbia',
             'frederick', 'tysons', 'fairfax', 'herndon', 'ashburn', 'chevy', 'chase',
             'old', 'town', 'downtown', 'maryland', 'virginia'}
GENERIC_WORDS = {'restaurant', 'bar', 'grill', 'grille', 'bistro', 'cafe', 'club',
                 'country', 'golf', 'yacht', 'inn', 'hotel', 'winery', 'vineyard',
                 'vineyards', 'wine', 'and', 'at', 'of', 'kitchen', 'tavern', 'house',
                 'lounge', 'resort', 'spa', 'the', 'co', 'llc'}


def name_tokens(s):
    s = unicodedata.normalize('NFKD', str(s or ''))
    s = ''.join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace('’', "'").replace('&', ' and ').replace("'", '')
    toks = re.sub(r'[^a-z0-9 ]', ' ', s).split()
    while toks and toks[0] == 'the':
        toks = toks[1:]
    return toks


def strip_loc(toks):
    t = list(toks)
    while t and t[-1] in LOC_WORDS:
        t.pop()
    return t


def same_venue_name(a, b):
    if not a or not b:
        return False
    if a == b or (strip_loc(a) and strip_loc(a) == strip_loc(b)):
        return True
    s, l = (a, b) if len(a) <= len(b) else (b, a)
    if len(s) >= 2 and len(''.join(s)) >= 8 and l[:len(s)] == s:
        return True
    da = {t for t in a if t not in GENERIC_WORDS and t not in LOC_WORDS}
    db = {t for t in b if t not in GENERIC_WORDS and t not in LOC_WORDS}
    return bool(da) and da == db and (len(da) >= 2 or len(next(iter(da))) >= 6)


# Past gigs: venue_id when set (rarely), else the name; then the gig venue's domain.
gig_ids, gig_names = set(), []
for g in gigs:
    nm = str(g.get('venue_name', '') or '').strip()
    if nm.lower() in ('', '(deleted)'):
        continue
    if g.get('venue_id'):
        gig_ids.add(str(g['venue_id']))
    gig_names.append((nm, name_tokens(nm)))
gig_domains = {}
for v in venues:
    vt = name_tokens(v.get('name', ''))
    hit = next((nm for nm, gt in gig_names if same_venue_name(gt, vt)), None)
    if v.get('venue_id') in gig_ids or hit:
        k = site_key(v.get('website', ''))
        if k and not R.is_shared_domain(v.get('website', '')):
            gig_domains[k] = hit or v.get('name', '')

pipelined_keys = set()
for v in venues:
    if v.get('status', '') != 'untouched':
        k = site_key(v.get('website', ''))
        if k:
            pipelined_keys.add(k)

TYPE_WORDS = {'club', 'country', 'golf', 'yacht', 'inn', 'hotel', 'grill', 'grille', 'winery',
              'vineyard', 'vineyards', 'tavern', 'resort', 'spa', 'museum', 'gallery'}


def twin_names(a, b):
    """same_venue_name, minus namesakes of another kind ('Capital Yacht Club' vs
    'Capital Hotel') or another branch ('Archer Hotel Tysons' vs '... Alexandria')."""
    if not same_venue_name(a, b):
        return False
    ta, tb = {t for t in a if t in TYPE_WORDS}, {t for t in b if t in TYPE_WORDS}
    if ta and tb and not (ta <= tb or tb <= ta):
        return False
    la, lb = a[len(strip_loc(a)):], b[len(strip_loc(b)):]
    return not (la and lb and la != lb)


# Name twins of venues already worked (a discovery duplicate on a different brand URL:
# "The Ritz-Carlton Georgetown, Washington, D.C." vs the contacted "Ritz-Carlton Georgetown").
DONE_STATUSES = {'pipelined', 'contacted', 'dismissed', 'closed', 'researched', 'sent'}
done_names = defaultdict(list)
for v in venues:
    if v.get('status', '') in DONE_STATUSES:
        st = str(v.get('state', '') or '').strip().upper()
        done_names[st].append((name_tokens(v.get('name', '')), v.get('venue_id', ''), v.get('name', '')))

venues_with_contacts = {c.get('venue_id') for c in dash.get('contacts', []) if c.get('venue_id')}

print(f"Total venues: {len(venues)}")
print(f"Past gigs: {len(gig_names)} (by id {len(gig_ids)}, gig-venue domains {len(gig_domains)})")
print(f"Venues with existing contacts: {len(venues_with_contacts)}")
print(f"Already in reports: {len(already_reported)}   excluded by --exclude/current run: {len(excluded_ids)}")
print(f"Target states: {' '.join(R.TARGET_STATES)}   scorer: taste_score {SCORE_VERSION}")

JUNK_SITE_PARTS = ['fox5dc.com', 'fox.com', 'foxtv.com', 'nbcwashington.com', 'wusa9.com',
                   'wjla.com', 'wtop.com', 'baltimoresun.com', 'cbs19news.com', 'wbal.com',
                   'nbc.com', 'abc.com', 'cbs.com', 'cnn.com', 'foxnews.com', 'msnbc.com',
                   'dcpreservation.org', 'visitmaryland.org', 'virginia.org',
                   'visitvirginia.com', 'visitannapolis.org', 'baltimore.org', 'eventbrite.com',
                   'meetup.com', 'groupon.com', 'seamless.com', 'zomato.com', 'alltrails.com',
                   'wix.com', 'squarespace.com', 'shopify.com', 'wordpress.com',
                   'blogspot.com', 'godaddy.com', 'weebly.com', 'tiktok.com', 'airbnb.',
                   'vrbo.com', 'booking.com', 'expedia.com', 'hotels.com']
JUNK_TLDS = ('.edu', '.gov', '.mil')
TOO_FAR_CITIES = {'charlottesville', 'richmond', 'williamsburg', 'norfolk', 'virginia beach',
                  'hampton', 'newport news', 'roanoke', 'lynchburg', 'blacksburg',
                  'ocean city', 'salisbury', 'cumberland', 'staunton', 'harrisonburg'}
# Kept from the old list: wrong-cuisine and non-venue words the classifier
# doesn't cover. Whole words only.
SKIP_WORDS = re.compile(r"(?<![a-z0-9])(" + '|'.join(map(re.escape, [
    'peninsula sailors', 'sail', 'sailing school', 'foundation', 'association',
    'civic club', 'garden club', 'citizens association', 'community center',
    'dance hall', 'dance studio', 'salsa', 'bachata', 'tango',
    'thai', 'sushi', 'ramen', 'pho', 'dim sum', 'dumpling', 'dumplings',
    'noodle house', 'korean bbq', 'korean fried', 'bibimbap', 'teppanyaki',
    'hibachi', 'teriyaki', 'shawarma', 'kebab', 'kabob', 'falafel', 'poke', 'acai',
    'szechuan', 'sichuan', 'hunan', 'wok', 'pizza', 'pizzeria', 'taqueria', 'taco', 'tacos',
    'burger', 'burgers', 'bbq', 'barbecue', 'wings', 'crab house', 'crab shack', 'deli',
    'diner', 'buffet', 'steakhouse', 'steak house', 'chophouse', 'market', 'gourmet shop',
    'grocery', 'bakery', 'baking company', 'chocolate', 'chocolatier',
    'wine store', 'wine shop', 'spirits', 'bottle shop', 'liquor store'])) + r")(?![a-z0-9])")


def city_is_malformed(city):
    cl = city.lower().strip()
    if not cl or len(city) > 30 or re.search(r'\d{3,}', city) or '"' in city or "'" in city:
        return True
    return any(g in cl for g in ('and ', 'prices', 'best ', 'top ', 'finest', 'genuine',
                                 'famous', 'historic ', 'restaurant', 'review', 'rating', 'menu',
                                 'hours', 'delivery', 'near me', 'open now', 'reserv',
                                 'book a', 'order', 'http', 'www.', '.com', '@', 'phone',
                                 'email', 'contact', '·', '(', ')'))


skips = defaultdict(list)


def skip(reason, v, detail=''):
    skips[reason].append(f"{v.get('name', '')} [{v.get('venue_id', '')}]" + (f" — {detail}" if detail else ''))


candidates = []
for v in venues:
    vid = str(v.get('venue_id', ''))
    name = str(v.get('name', '') or '')
    if v.get('status', '') != 'untouched':
        skips['status (not untouched)'].append(vid)
        continue
    if str(v.get('venue_vote', '')).strip().lower() == 'down':
        skip('thumbs-down vote', v, str(v.get('venue_feedback', ''))[:60])
        continue
    vt = name_tokens(name)
    gig = next((nm for nm, gt in gig_names if same_venue_name(gt, vt)), None)
    if vid in gig_ids or gig:
        skip('past gig', v, f"gig '{gig or vid}'")
        continue
    if vid in already_reported:
        skips['already in a report'].append(vid)
        continue
    if vid in excluded_ids:
        skip('excluded (--exclude / current run)', v)
        continue
    if vid in venues_with_contacts:
        skip('has contacts', v)
        continue
    website = str(v.get('website', '') or '').strip()
    if not website:
        skips['no website'].append(vid)
        continue
    host = R.host_of(website)
    if (not re.fullmatch(r'[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}', host or '')
            or R.is_non_venue_host(website) or any(j in host for j in JUNK_SITE_PARTS)
            or host.endswith(JUNK_TLDS)):
        skip('junk website', v, host)
        continue
    key = site_key(website)
    if not key:
        skip('bare brand homepage as website', v, host)
        continue
    if key in gig_domains:
        skip('past gig', v, f"same site as gig venue '{gig_domains[key]}'")
        continue
    if key in pipelined_keys:
        skip('site already pipelined/contacted', v, key)
        continue
    twin = next((dn for dt, dv, dn in done_names.get(str(v.get('state', '') or '').strip().upper(), [])
                 if dv != vid and twin_names(dt, vt)), None)
    if twin:
        skip('same name as a venue already worked', v, f"'{twin}'")
        continue
    state = str(v.get('state', '') or '').strip().upper()
    city = str(v.get('city', '') or '').strip()
    if state not in R.TARGET_STATES:
        skips['out of area (not DC/MD/VA)'].append(vid)
        continue
    if not city or city_is_malformed(city):
        skip('blank/malformed city', v, city[:40])
        continue
    if city.lower() in TOO_FAR_CITIES:
        skip('too far', v, city)
        continue
    loc = location_info(v)
    if loc['in_radius'] is False:
        dist = f"{loc['minutes']:.0f} min" if loc['minutes'] else f"{loc['miles']:.0f} mi"
        skip('too far', v, f"{dist} from home")
        continue
    if loc['in_radius'] is None and not DEGRADED:
        skip('no distance on record (location unverifiable)', v)
        continue
    if not loc['trusted'] and not DEGRADED:
        skip('location not trustworthy', v, loc['why'])
        continue
    why = junk_reason(name, v.get('category', ''), v.get('notes', ''), website,
                      v.get('check_status', ''))
    if why:
        skip('junk gate', v, why)
        continue
    if re.search(r'(?i)\bflag\b|flagged|needs review|quarantin', str(v.get('check_status', '') or '')):
        skip('flagged by a manual check', v, str(v.get('check_status', ''))[:60])
        continue
    c = classify(name, v.get('category', ''), v.get('notes', ''), website, vid)
    cat = c['primary_category']
    if cat not in TARGET_CATEGORIES or c['classification_confidence'] < 0.6:
        skip('not a target category', v, f"{cat} ({c['classification_source']})")
        continue
    m = SKIP_WORDS.search(' ' + ' '.join(vt) + ' ')
    if m:
        skip('skip word', v, m.group(0))
        continue
    wscore = website_match_score(name, website)
    if wscore < 6:
        skip('website not verified as the venue\'s own', v, f"{host} (match {wscore})")
        continue
    ts, reasons = ts_score(v, c)
    b = ts_bucket(c, v)
    if not b:
        skip('no prime evidence (generic restaurant, chain or non-European cuisine)', v, cat)
        continue
    floor = max(MIN_TASTE_SCORE, BUCKET_MIN_SCORE.get(b, MIN_TASTE_SCORE))
    if ts < floor:
        skips[f'below taste floor'].append(vid)
        continue
    candidates.append({'venue': v, 'taste_score': ts, 'reasons': reasons, 'bucket': b,
                       'classified_cat': cat, 'tags': c['venue_tags'], 'site_key': key,
                       'miles': loc['miles'], 'loc_why': loc['why']})

# Duplicate rows of one venue (same site): keep the best-scoring row.
best_by_site = {}
for e in candidates:
    k = e['site_key']
    if k not in best_by_site or e['taste_score'] > best_by_site[k]['taste_score']:
        best_by_site[k] = e
dupes = [e for e in candidates if best_by_site[e['site_key']] is not e]
for e in dupes:
    skip('duplicate site (kept the best row)', e['venue'], e['site_key'])
pool = [e for e in candidates if best_by_site[e['site_key']] is e]

print(f"\nEligible pool: {len(pool)}")
order = ['status (not untouched)', 'already in a report', 'no website', 'out of area (not DC/MD/VA)']
for reason in order + sorted(r for r in skips if r not in order):
    items = skips.get(reason, [])
    if not items:
        continue
    print(f"  Skipped ({reason}): {len(items)}")
    if DRY_RUN and reason not in order and reason != 'below taste floor':
        for ex in items[:4]:
            print(f"      e.g. {ex}")

by_bucket = defaultdict(list)
for e in pool:
    by_bucket[e['bucket']].append(e)


def rank_key(e):
    s = e['taste_score']
    tier = 0 if s >= 50 else 1 if s >= 40 else 2
    mi = e['miles']
    band = 1 if mi is None else (0 if mi <= 60 else 1 if mi <= 90 else 2)
    return (tier, band, -s, mi if mi is not None else 999, (e['venue'].get('name') or '').lower())


for b in by_bucket:
    by_bucket[b].sort(key=rank_key)
print("  By bucket: " + ', '.join(f"{b} {len(by_bucket.get(b, []))}" for b in BUCKET_ORDER))

# ---------------------------------------------------------------- quotas
share_total = sum(BUCKET_SHARES.values())
raw = {b: COUNT * BUCKET_SHARES[b] / share_total for b in BUCKET_ORDER}
quota = {b: int(raw[b]) for b in BUCKET_ORDER}
for b in sorted(BUCKET_ORDER, key=lambda b: (-(raw[b] - quota[b]), BUCKET_ORDER.index(b))):
    if sum(quota.values()) >= COUNT:
        break
    quota[b] += 1
take = {b: min(quota[b], len(by_bucket.get(b, []))) for b in BUCKET_ORDER}
short = COUNT - sum(take.values())
# Refill shortfalls from the prime buckets first, the wild card last.
while short > 0:
    spare = [b for b in BUCKET_ORDER if take[b] < len(by_bucket.get(b, []))]
    if not spare:
        break
    b = min(spare, key=lambda b: (take[b] / max(BUCKET_SHARES[b], 1), BUCKET_ORDER.index(b)))
    take[b] += 1
    short -= 1

# Interleave so every batch of 8 carries a share of each bucket.
seq, used = [], {b: 0 for b in BUCKET_ORDER}
while len(seq) < sum(take.values()):
    b = min((b for b in BUCKET_ORDER if used[b] < take[b]),
            key=lambda b: ((used[b] + 0.5) / take[b], BUCKET_ORDER.index(b)))
    seq.append(by_bucket[b][used[b]])
    used[b] += 1

batches = [seq[i:i + MAX_BATCH] for i in range(0, len(seq), MAX_BATCH)] if TOTAL else [seq]

mix = Counter(e['bucket'] for e in seq)
print(f"\nSelected {len(seq)} of {COUNT} requested: " +
      ', '.join(f"{b} {mix.get(b, 0)}/{quota[b]}" for b in BUCKET_ORDER))
if len(seq) < COUNT:
    print(f"NOTE: only {len(seq)} venues pass every filter and taste floor "
          f"(requested {COUNT}). Not filling with junk. Run discovery or repair "
          f"locations/websites to grow the pool.")
elif any(take[b] < quota[b] for b in BUCKET_ORDER):
    thin = [b for b in BUCKET_ORDER if take[b] < quota[b]]
    print(f"NOTE: bucket(s) {', '.join(thin)} ran short; filled from the other buckets.")

# ---------------------------------------------------------------- output
BATCH_KEYS = ('venue_id', 'name', 'category', 'website', 'city', 'county', 'state',
              'facebook', 'instagram', 'upscale_score', 'zone_priority', 'status',
              'contact_form', 'linkedin_pending', 'check_status', 'address',
              'distance_miles', 'drive_minutes')


def out_venue(e):
    v = {k: e['venue'].get(k) for k in BATCH_KEYS if k in e['venue']}
    v.update({'taste_score': e['taste_score'], 'classified_category': e['classified_cat'],
              'batch_bucket': e['bucket']})
    return v


for bi, batch in enumerate(batches, 1):
    title = f"BATCH {bi}/{len(batches)}" if TOTAL else "BATCH"
    print(f"\n=== {title}: {len(batch)} venues (taste floor {MIN_TASTE_SCORE}, "
          f"bucket floors {BUCKET_MIN_SCORE}) ===" if bi == 1 else f"\n=== {title}: {len(batch)} venues ===")
    for i, e in enumerate(batch, 1):
        v = e['venue']
        mi = f"{e['miles']:.0f} mi" if e['miles'] is not None else "? mi"
        print(f"{i}. [{v.get('venue_id','')}] {v.get('name','')} | {e['bucket']} / "
              f"{e['classified_cat']} | {v.get('city','')} {v.get('state','')} ({mi}) | "
              f"taste={e['taste_score']}")
        if DRY_RUN:
            for r in e['reasons']:
                print(f"     {r}")
            tags = ', '.join(t for t in e['tags'] if t not in ('independent',))[:80]
            if tags:
                print(f"     tags: {tags}")


def write_json(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


if DRY_RUN:
    print(f"\n[DRY RUN] Batch NOT saved. Review above, then run without --dry-run.")
    sys.exit(0)
if not seq:
    die("no eligible venues; nothing written.", 4)
if not TOTAL:
    write_json(os.environ['BATCH_FILE'], [out_venue(e) for e in seq])
    print(f"\nSaved to {os.environ['BATCH_FILE']}")
    sys.exit(0)

out_dir = os.environ['OUT_DIR']
os.makedirs(out_dir, exist_ok=True)
plan = {'created': datetime.now().strftime('%Y-%m-%d %H:%M:%S'), 'requested': TOTAL,
        'selected': len(seq), 'batch_size': MAX_BATCH, 'score_version': SCORE_VERSION,
        'mix': dict(mix), 'batches': [], 'venue_ids': [e['venue']['venue_id'] for e in seq]}
for bi, batch in enumerate(batches, 1):
    path = os.path.join(out_dir, f'batch_{bi:02d}.json')
    write_json(path, [out_venue(e) for e in batch])
    plan['batches'].append({'index': bi, 'file': path,
                            'venue_ids': [e['venue']['venue_id'] for e in batch]})
write_json(os.path.join(out_dir, 'plan.json'), plan)
latest = os.path.join(SCRIPT_DIR, 'reports', 'runs', 'plans', 'LATEST')
os.makedirs(os.path.dirname(latest), exist_ok=True)
with open(latest + '.tmp', 'w') as f:
    f.write(out_dir + '\n')
os.replace(latest + '.tmp', latest)
print(f"\nSaved {len(batches)} batch files + plan.json to {out_dir}")
for b in plan['batches']:
    print(f"  {b['file']}  ({len(b['venue_ids'])} venues)")
print(f"  (path also in {latest})")
PYEOF
