#!/bin/bash
# =============================================================
# Venue Discovery — Google Maps Scraper (Chrome + AppleScript)
#
# This is Chrome-based discovery. A city "sweep" (venue research Claude does with
# WebSearch/WebFetch in the terminal) is a different procedure and never runs this.
#
# Modes:
#   ./discover.sh           — crawl "People also search for" from past gigs
#   ./discover.sh --learn   — scrape Google Maps attributes from taste_venues.txt,
#                             build taste_keywords.json
#   ./discover.sh --taste   — use taste profile to search for new venues
#                             (venue types × locations, plus distinctive keywords)
#
# Env vars:
#   MAX_GIGS=N       — limit gigs processed (default mode + --learn)
#   MAX_QUERIES=N    — limit search queries (--taste mode, default 20)
#   CITY_FILTER=re   — only run the generated --taste queries matching this regex
#   SWEEP_CITIES     — newline-separated "City ST" list (set by sweep.sh): --taste
#                      generates every venue type for exactly those cities
#
# What it writes:
#   - New venues go in as needs_review, with the website included in the same
#     add_venue call. They are promoted to untouched only when the website matched
#     AND city/state came from the listing itself (or the Google knowledge panel
#     for the same business) AND the state is in DC/MD/VA (outreach_rules).
#   - Existing venues (normalized name + city, or the same website domain) and
#     past gigs are skipped before anything is added.
#   - A query or seed is only marked done when Chrome actually returned a page of
#     results. If Chrome/JavaScript stops responding the run stops with exit 3.
#   - Exit codes: 1 setup error, 3 Chrome unreachable, 4 some queries/seeds failed
#     (retried next run), 5 pipeline.sh is running and owns Chrome.
#   - Python errors go to reports/runs/python-errors.log.
#
# Requirements:
#   - Chrome open
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
source "$SCRIPT_DIR/.env" 2>/dev/null || true
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
JS_DIR="${SCRIPT_DIR}/js"
LOG_FILE="${SCRIPT_DIR}/discover.log"
DISCOVERED_FILE="${SCRIPT_DIR}/discovered_gigs.txt"
TASTE_KEYWORDS_FILE="${SCRIPT_DIR}/taste_keywords.json"
TASTE_QUERIES_FILE="${SCRIPT_DIR}/taste_queries.txt"
ERR_LOG="${SCRIPT_DIR}/reports/runs/python-errors.log"

# pipeline.sh holds /tmp/pipeline.lock.d (pid file) while it drives Chrome. Two
# scripts steering the same Chrome tab break each other, so wait for it (PD-16).
PIPELINE_LOCK_DIR="${PIPELINE_LOCK_DIR:-/tmp/pipeline.lock.d}"
PIPELINE_LOCK_FILE="${PIPELINE_LOCK_FILE:-/tmp/pipeline.lock}"
pipeline_holding_chrome() {
    local pid
    for pid in "$(cat "$PIPELINE_LOCK_DIR/pid" 2>/dev/null)" "$(cat "$PIPELINE_LOCK_FILE" 2>/dev/null)"; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "${PIPELINE_LOCK_PID:-}" ] && continue  # started by that pipeline itself
        if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -q 'pipeline\.sh'; then
            PIPELINE_HOLDER_PID=$pid
            return 0
        fi
    done
    return 1
}
if pipeline_holding_chrome; then
    echo "ERROR: pipeline.sh is running (PID $PIPELINE_HOLDER_PID) and is driving Chrome." >&2
    echo "       discover.sh drives the same Chrome window; run it after the pipeline finishes." >&2
    exit 5
fi

mkdir -p "$(dirname "$ERR_LOG")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/discover.XXXXXX")" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
MAX_CHROME_FAILS=3
LOOKUP_BLOCKED=0
touch "$DISCOVERED_FILE"
touch "$TASTE_QUERIES_FILE"

rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] ${delay}s..."
    sleep $delay
}

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Log every line of a command's output (python decisions belong in discover.log).
log_lines() { local line; while IFS= read -r line; do log "$line"; done; }

# Move a captured stderr file into ERR_LOG, tagged, so failures are traceable.
append_err() {
    [ -s "$2" ] && sed "s/^/[$(date '+%F %T')] [discover:$1] /" "$2" >> "$ERR_LOG"
    rm -f "$2"
}

# Shared python for both discovery modes. Data only ever arrives through argv,
# env or files (never spliced into the source). Subcommands: see the dispatch at
# the bottom of the heredoc.
disc_py() {
    local err rc
    err=$(mktemp "$WORK_DIR/py.XXXXXX")
    DISCOVER_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$@" 2>"$err" <<'PYLIB'
import json, os, re, sys, unicodedata, urllib.parse

SCRIPT_DIR = os.environ["DISCOVER_SCRIPT_DIR"]
sys.path.insert(0, SCRIPT_DIR)
import outreach_rules as R
from site_discovery import parse_location, looks_like_street_address

TARGET = set(R.TARGET_STATES)

try:
    from venue_classifier import classify as vc_classify
except Exception as e:  # classifier missing/broken: nothing is classifiable, so nothing is added
    vc_classify = None
    print(f"[discover] venue_classifier unavailable: {e}", file=sys.stderr)
try:
    from venue_classifier import junk_reason as vc_junk_reason
except Exception as e:
    vc_junk_reason = None
    print(f"[discover] venue_classifier.junk_reason unavailable: {e}", file=sys.stderr)
try:
    from taste_score import score as ts_score
except Exception as e:
    ts_score = None
    print(f"[discover] taste_score unavailable: {e}", file=sys.stderr)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    except FileNotFoundError:
        pass
    return rows


def one_line(s):
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


# Maps listing names carry brand and city tails the sheet row doesn't have:
# "Canal House of Georgetown, a Tribute Portfolio Hotel" = "Canal House Georgetown",
# "The Ritz-Carlton Georgetown, Washington, D.C." = "Ritz-Carlton Georgetown".
BRAND_TAIL_RE = re.compile(
    r"(,|\s-|\s\|)?\s*(an?\s+)?(tribute portfolio( hotel)?|tapestry collection( by hilton)?|"
    r"curio collection( by hilton)?|autograph collection( hotels?)?|luxury collection( hotel)?|"
    r"ascend hotel collection|destination by hyatt( hotel)?|jdv by hyatt|"
    r"by (ihg|hilton|marriott|hyatt|wyndham|choice hotels))\b.*$")
CITY_TAIL_RE = re.compile(r",\s*(washington(,?\s*d\.?\s*c\.?)?|d\.?\s*c\.?)\s*$")


def norm_name(name):
    """'The Inn at Little Washington' / 'Inn at Little Washington' -> same key."""
    s = unicodedata.normalize("NFKD", str(name or "")).encode("ascii", "ignore").decode().lower()
    s = BRAND_TAIL_RE.sub("", s)
    s = CITY_TAIL_RE.sub("", s.strip())
    s = re.sub(r"\bd\.\s*c\.?(?![a-z])", "dc", s)
    s = s.replace("&", " and ").replace("'", "")
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    s = re.sub(r" of ", " ", s)
    return re.sub(r"^the ", "", s)


HOST_RE = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}")
# Articles about a venue, listings and booking sites are not its website.
NEWS_HOSTS = {
    "baltimoresun.com", "washingtonpost.com", "washingtonian.com", "eater.com",
    "timeout.com", "patch.com", "wtop.com", "nbcwashington.com", "wusa9.com",
    "fox5dc.com", "dcist.com", "bizjournals.com", "washingtoncitypaper.com",
    "northernvirginiamag.com", "bethesdamagazine.com", "capitalgazette.com",
    "thrillist.com", "theinfatuation.com", "michelin.com", "zagat.com",
    "baltimoremagazine.com", "nytimes.com", "forbes.com", "cntraveler.com",
}
AGGREGATOR_HOSTS = {
    "airbnb.com", "vrbo.com", "booking.com", "expedia.com", "hotels.com", "kayak.com",
    "priceline.com", "trivago.com", "agoda.com", "homeaway.com", "eventbrite.com",
    "meetup.com", "partyslate.com", "zomato.com", "seamless.com", "bbb.org",
    "chamberofcommerce.com", "manta.com", "mapquest.com", "linktr.ee", "linktree.com",
}


def website_reject_reason(url):
    host = R.host_of(url)
    if not host or not HOST_RE.fullmatch(host):
        return "not_a_hostname"
    reg = R.registrable_domain(host)
    if R.is_non_venue_host(host):
        return "non_venue_host"
    if reg in NEWS_HOSTS:
        return "news_site"
    if reg in AGGREGATOR_HOSTS:
        return "aggregator"
    # Booking clones: canal-house-of-georgetown-a-tribute-portfolio.hotel-washington-dc.net
    bare = re.sub(r"^www\.", "", host)
    if bare != reg and re.match(r"[a-z0-9-]+\.hotels?-[a-z0-9-]+\.[a-z]+$", bare):
        return "aggregator"
    return ""


try:
    from venue_quality import OFFICIAL_PARENT_DOMAINS
except Exception:
    OFFICIAL_PARENT_DOMAINS = set()
# Brand domains host many properties, so they can't identify one venue.
MULTI_PROPERTY_DOMAINS = set(R.SHARED_BRAND_DOMAINS) | set(OFFICIAL_PARENT_DOMAINS)


def venue_domain(url):
    """Registrable domain that identifies ONE venue ('' for brand/aggregator hosts)."""
    if not url or website_reject_reason(url):
        return ""
    reg = R.registrable_domain(url)
    return "" if reg in MULTI_PROPERTY_DOMAINS else reg


# ---------- skip lists (shared by taste + crawl; whole words only) ----------
def _terms_re(terms):
    alt = "|".join(re.escape(t) for t in sorted(terms, key=len, reverse=True))
    return re.compile(r"(?<![a-z0-9])(?:" + alt + r")(?:e?s)?(?![a-z0-9])", re.I)


# Google category words for places that never book a classical guitarist.
# Churches, synagogues, community centers, spas and wine shops are NOT here: they are
# sweep targets (feedback_sweep_categories.md). "Spanish restaurant", "gastropub" and
# "Cafe Milano" no longer trip the list because matching is by whole word.
SKIP_CATEGORY_RE = _terms_re([
    "pub", "irish pub", "sports bar", "fast food", "pizza", "diner", "gas station",
    "grocery", "grocery store", "supermarket", "pharmacy", "convenience store", "deli",
    "food truck", "taco", "burger", "hamburger", "sandwich", "chicken", "chicken wings",
    "ramen", "noodle", "donut", "doughnut", "bagel", "juice", "juice bar", "bar & grill",
    "hookah", "hookah bar", "karaoke", "karaoke bar", "nightclub", "night club",
    "ice cream", "gelato", "frozen yogurt", "bakery", "pastry", "cafe", "coffee",
    "coffee shop", "dessert", "sweets", "candy", "confectionery", "liquor store",
    "beer store", "toast", "brunch", "breakfast", "clubhouse", "rec center",
    "recreation center", "gym", "fitness", "fitness center", "boxing", "martial arts",
    "yoga", "yoga studio", "swimming pool", "swim team", "swim club", "pool",
    "athletic", "crossfit", "pilates", "dance studio", "dance school", "music school",
    "school", "daycare", "preschool", "tutoring", "ymca", "community beach", "storage",
    "self-storage", "laundry", "laundromat", "car wash", "auto repair", "med spa",
    "medical spa", "nail salon", "hair salon", "barber", "barber shop", "massage",
    "dentist", "clothing store", "coworking",
])
# Name words for vacation rentals, room listings and obvious non-venues.
SKIP_NAME_RE = _terms_re([
    "cottage", "apartment", "vacation rental", "retreat", "bedroom", "airbnb", "vrbo",
    "walk to", "screened porch", "historic house", "king room", "queen room",
    "deluxe room", "one-bedroom", "fitness", "gym", "urgent care", "boxing",
    "swim team", "swim club", "pool", "ymca", "crossfit", "martial art", "karate",
    "taekwondo", "jiu jitsu", "community beach", "business association", "rotary club",
    "tennis", "pickleball", "basketball", "ice cream", "gelato", "frozen yogurt",
    "toastique", "sweets", "clubhouse and pool", "clubhouse & pool", "irish pub",
    "liquor", "wine & spirits", "wine and spirits", "bakery", "pastry", "patisserie",
    "slice", "cupcake", "donut", "bagel", "smoothie", "juice bar", "acai", "poke bowl",
    "bubble tea", "boba",
])

SKIP_CLASSES = {"recreation", "theater", "other", "unknown"}

# Sweep-target types the classifier doesn't know yet (it calls them other/unknown).
TARGET_RESCUE = [
    (re.compile(r"\b(church|cathedral|basilica|chapel|parish)\b", re.I), "church"),
    (re.compile(r"\b(synagogue|congregation)\b", re.I), "synagogue"),
    (re.compile(r"\b(senior living|assisted living|retirement (community|home)|independent living)\b", re.I), "senior_living"),
    (re.compile(r"\bfarmers'? ?markets?\b", re.I), "farmers_market"),
    (re.compile(r"\bfuneral (home|service|chapel)s?\b", re.I), "funeral_home"),
    (re.compile(r"\blibrar(y|ies)\b", re.I), "library"),
    (re.compile(r"\b(community|cultural|arts) cent(er|re)\b", re.I), "community_center"),
    (re.compile(r"\b(event|wedding) plann(er|ing)\b", re.I), "event_planner"),
    (re.compile(r"\bcigar (lounge|bar)\b", re.I), "bar"),
]

TIER1 = {"country_club", "private_club", "yacht_club"}
TIER2 = {"restaurant", "winery", "hotel", "wine_bar", "museum", "event", "event_venue",
         "event_space", "resort", "art_gallery", "brewery", "distillery", "music_venue",
         "library"}
TIER3 = {"golf_club", "senior_living", "wedding_venue", "corporate", "farmers_market",
         "tea_room", "bar", "synagogue", "church", "spa", "luxury_apts", "event_planner",
         "funeral_home", "community_center", "cafe"}

# DC / MD / VA only (P5).
SWEET_SPOTS = [
    "georgetown", "dupont circle", "kalorama", "cleveland park", "spring valley",
    "potomac", "chevy chase", "bethesda", "cabin john", "roland park", "guilford",
    "homeland", "ruxton", "st. michaels", "easton", "oxford", "tilghman island",
    "annapolis", "severna park", "great falls", "mclean", "alexandria", "reston",
    "vienna", "middleburg", "leesburg", "purcellville",
]


def classify(name, cat):
    if vc_classify is None:
        return "other", None
    cls = vc_classify(name, cat, "")
    our = cls.get("primary_category") or "other"
    if our == "unknown":  # unknown is 'other', never 'restaurant' (P8)
        our = "other"
    if our == "other":
        hay = f"{cat} {name}"
        for rx, slug in TARGET_RESCUE:
            if rx.search(hay):
                our = slug
                cls = dict(cls, primary_category=slug, classification_source="discover:target-type")
                break
    return our, cls


def upscale_of(price, rating):
    if len(price) >= 4:
        return 5
    if len(price) == 3:
        return 4
    if len(price) == 2:
        return 3
    if len(price) == 1:
        return 2
    try:
        r = float(rating or 0)
    except ValueError:
        r = 0
    return 4 if r >= 4.7 else 3 if r >= 4.4 else 2 if r else 3


def num(x, cast=float):
    try:
        return cast(str(x or 0).replace(",", ""))
    except ValueError:
        return cast(0)


def pre_score(v, our_cat, state, q_state, q_city):
    score = 30 if our_cat in TIER1 else 20 if our_cat in TIER2 else 10 if our_cat in TIER3 else -60
    # The query's state is a proximity hint for SCORING only; it is never stored.
    score += 10 if (state or q_state) in TARGET else -50
    loc_lower = (v.get("location") or q_city or "").lower()
    if any(c in loc_lower for c in SWEET_SPOTS):
        score += 10
    rating, reviews = num(v.get("rating")), num(v.get("reviews"), int)
    score += 20 if rating >= 4.7 else 15 if rating >= 4.4 else 10 if rating >= 4.0 else 5 if rating >= 3.5 else 0
    score += 5 if reviews > 1000 else 3 if reviews > 500 else 0
    price = str(v.get("price") or "").strip()
    score += 15 if len(price) >= 4 else 10 if len(price) == 3 else -5 if len(price) == 1 else 0
    return max(0, min(100, score))


def clean_address(text):
    t = one_line(text)
    if not (5 <= len(t) <= 120) or re.search(r"[★()$·•⋅|]|\d\.\d|reviews?|stars?", t, re.I):
        return ""
    return t


def name_dup(idx, norm, city, state):
    """venue_id / reason if this name is already a venue or a past gig."""
    if norm in idx["gig_names_set"]:
        return "past gig"
    if norm in idx["run_skipped"]:
        return "skipped earlier this run: " + idx["run_skipped"][norm]
    city = (city or "").lower()
    for ecity, estate, vid in idx["names"].get(norm, []):
        if state == "DC" and estate == "DC":
            # Every DC venue is in Washington; rows say "Georgetown", "Dupont Circle"...
            return vid or "existing"
        if city and ecity:
            if ecity == city:
                return vid or "existing"
        elif not state or not estate or state == estate:
            # One side has no city: the same name in the same (or unknown) state is
            # the same venue far more often than it is a namesake.
            return vid or "existing"
    return ""


def load_index(path):
    idx = load_json(path)
    idx["gig_names_set"] = set(idx.get("gig_names", []))
    idx.setdefault("run_skipped", {})
    return idx


def save_index(idx, path):
    d = {k: v for k, v in idx.items() if k != "gig_names_set"}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f)


def query_location(query):
    """('Middleburg', 'VA') from 'French restaurant Middleburg VA' (scoring/search only)."""
    m = re.search(r"\s([A-Z]{2})\s*$", query or "")
    if not m:
        return "", ""
    words = query[:m.start()].split()
    type_words = {"luxury", "hotel", "fine", "dining", "restaurant", "french", "european",
                  "historic", "bistro", "private", "club", "wine", "bar", "country",
                  "winery", "yacht", "upscale", "italian", "boutique", "inn", "museum",
                  "event", "space", "art", "gallery"}
    return " ".join(w for w in words if w.lower() not in type_words).strip(), m.group(1)


# ---------------- subcommands ----------------
def cmd_index(venues_path, gigs_path, out_path):
    try:
        venues = load_json(venues_path).get("venues", [])
    except Exception as e:
        print(f"[discover] venues list unreadable: {e}", file=sys.stderr)
        print("ERROR venues list could not be read")
        return 2
    if not venues:
        print("ERROR venues list is empty")
        return 2
    try:
        gigs = load_json(gigs_path).get("gigs", [])
    except Exception as e:
        print(f"[discover] past gigs unreadable: {e}", file=sys.stderr)
        print("WARN past gigs could not be read; past-gig names are not excluded this run")
        gigs = []
    names, domains = {}, {}
    for v in venues:
        n = norm_name(v.get("name", ""))
        if n:
            names.setdefault(n, []).append([(v.get("city") or "").strip().lower(),
                                            (v.get("state") or "").strip().upper(),
                                            v.get("venue_id", "")])
        d = venue_domain(v.get("website") or "")
        if d:
            domains.setdefault(d, v.get("venue_id", ""))
    gig_names = sorted({norm_name(g.get("venue_name", "")) for g in gigs
                        if g.get("venue_name") not in (None, "", "(DELETED)")} - {""})
    save_index({"names": names, "gig_names": gig_names, "domains": domains}, out_path)
    print(f"COUNTS {len(set(names) | set(gig_names))} {len(venues)} {len(gigs)} {len(domains)}")
    return 0


DISTINCTIVE_KW = ("romantic", "live music", "live entertainment", "historic", "fine dining",
                  "upscale", "elegant", "intimate", "cozy", "waterfront", "rooftop",
                  "fireplace", "garden", "courtyard", "scenic", "views", "wine list",
                  "tasting menu", "prix fixe", "sommelier", "craft cocktails",
                  "private dining", "terrace", "jazz", "classical")


def distinctive(kw):
    """Maps attributes like 'has wheelchair accessible parking lot' or 'offers takeout'
    describe every venue; only atmosphere words narrow a search."""
    k = kw.strip().lower()
    for _ in range(2):
        k = re.sub(r"^(has|serves|offers|great|good for|popular for)\s+", "", k)
    return k if any(d in k for d in DISTINCTIVE_KW) else ""


def cmd_queries(taste_file, done_file, out_path):
    taste = load_json(taste_file)
    completed = set()
    try:
        with open(done_file, encoding="utf-8") as f:
            completed = {line.strip().lower() for line in f if line.strip()}
    except FileNotFoundError:
        pass

    tier1_types = ["luxury hotel", "fine dining restaurant", "historic fine dining restaurant",
                   "French restaurant", "European bistro", "private club", "wine bar",
                   "country club", "winery", "yacht club"]
    tier2_types = ["upscale restaurant", "Italian fine dining", "boutique hotel", "historic inn",
                   "museum event space", "art gallery", "fine art gallery"]
    tier1_locations = [("Georgetown", "DC"), ("Dupont Circle", "DC"), ("Potomac", "MD"),
                       ("Bethesda", "MD"), ("Chevy Chase", "MD"), ("Great Falls", "VA"),
                       ("McLean", "VA"), ("Alexandria", "VA"), ("Reston", "VA"),
                       ("Middleburg", "VA"), ("Leesburg", "VA"), ("St. Michaels", "MD"),
                       ("Easton", "MD"), ("Annapolis", "MD"), ("Roland Park Baltimore", "MD")]
    # Within a 2-hour drive of DC (Charlottesville is too far).
    tier2_locations = [("Ellicott City", "MD"), ("Severna Park", "MD"),
                       ("Vienna", "VA"), ("Herndon", "VA"), ("Oxford", "MD")]

    sweep = [l.strip() for l in os.environ.get("SWEEP_CITIES", "").splitlines() if l.strip()]
    queries = []
    if sweep:
        cities = []
        for raw in sweep:
            m = re.match(r"^(.+?)[,\s]+([A-Za-z]{2})$", raw)
            if not m:
                print(f"ERROR bad city '{raw}' (expected 'City ST')")
                return 2
            city, st = m.group(1).strip(), m.group(2).upper()
            if st not in TARGET:
                print(f"ERROR {raw}: {st} is outside the target states ({' '.join(R.TARGET_STATES)})")
                return 2
            cities.append((city, st))
        for vtype in tier1_types + tier2_types:
            for city, st in cities:
                queries.append(f"{vtype} {city} {st}")
    else:
        for vtype in tier1_types:
            for city, st in tier1_locations + tier2_locations:
                queries.append(f"{vtype} {city} {st}")
        for vtype in tier2_types:
            for city, st in tier1_locations:
                queries.append(f"{vtype} {city} {st}")
        kws = []
        for kw in taste.get("ranked_keywords", []):
            k = distinctive(kw)
            if k and k not in kws:
                kws.append(k)
        for kw in kws[:5]:
            for vtype in tier1_types[:4]:
                for city, st in tier1_locations[:8]:
                    queries.append(f"{kw} {vtype} {city} {st}")
    todo = []
    for q in queries:
        if q.lower() not in completed and q not in todo:
            todo.append(q)
    with open(out_path, "w", encoding="utf-8") as f:
        for q in todo:
            f.write(q + "\n")
    print(f"STATS generated={len(set(queries))} completed={len(set(queries)) - len(todo)} "
          f"remaining={len(todo)} profile={taste.get('generated', '?')} source_gigs={taste.get('source_gigs', '?')}")
    return 0


def cmd_count(path):
    try:
        d = load_json(path)
    except Exception as e:
        print(f"[discover] unparseable results {path}: {e}", file=sys.stderr)
        print("-1")
        return 1
    print(len(d) if isinstance(d, list) else -1)
    return 0 if isinstance(d, list) else 1


def cmd_merge(out_path, *paths):
    merged, seen = [], set()
    for p in paths:
        try:
            items = load_json(p)
        except Exception as e:
            print(f"[discover] skipping unparseable {os.path.basename(p)}: {e}", file=sys.stderr)
            items = []
        for item in items if isinstance(items, list) else []:
            n = (item or {}).get("name", "")
            if n and n not in seen:
                seen.add(n)
                merged.append(item)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(merged, f)
    print(len(merged))
    return 0


def cmd_filter(mode, results_path, index_path, context, out_path, context_loc=""):
    try:
        results = load_json(results_path)
    except Exception as e:
        print(f"[discover] results unreadable: {e}", file=sys.stderr)
        print("ERROR results could not be parsed")
        return 2
    idx = load_index(index_path)
    q_city, q_state = query_location(context) if mode == "taste" else ("", "")
    n_cand = 0
    with open(out_path, "w", encoding="utf-8") as out:
        for i, v in enumerate(results):
            name = one_line((v or {}).get("name", ""))
            cat = one_line(v.get("category", ""))
            if not name or len(name) < 3:
                continue
            if SKIP_NAME_RE.search(name):
                print(f"  SKIP (name): {name}")
                continue
            if " - " in name and re.search(r"\b(room|suite|cottage|cabin)\b", name, re.I):
                print(f"  SKIP (room listing): {name}")
                continue
            location = one_line(v.get("location", ""))
            street = one_line(v.get("address", ""))
            city, state = parse_location(location)
            if not state and street:
                city, state = parse_location(street)
            if state and state not in TARGET:
                print(f"  SKIP (out of area): {name} -- {state}")
                continue
            norm = norm_name(name)
            dup = name_dup(idx, norm, city, state)
            if dup:
                print(f"  SKIP (exists: {dup}): {name}")
                continue
            if cat and SKIP_CATEGORY_RE.search(cat):
                print(f"  SKIP (type): {name} -- {cat}")
                continue
            rating, reviews = v.get("rating", ""), v.get("reviews", "")
            if mode == "crawl" and not rating and not reviews:
                print(f"  SKIP (no data): {name}")
                continue
            our_cat, cls = classify(name, cat)
            if our_cat in SKIP_CLASSES:
                print(f"  SKIP (classified {our_cat}): {name} -- {cat}")
                continue
            # Same gate build_batch uses: budget/extended-stay and mainstream chains,
            # rentals, adult/nightlife... would only ever be skipped at batch time.
            junk = vc_junk_reason(name, cat) if vc_junk_reason is not None else ""
            if junk:
                print(f"  SKIP (junk: {junk}): {name}")
                continue
            price = str(v.get("price", "") or "").strip()
            score = pre_score(v, our_cat, state, q_state, q_city) if mode == "taste" else None
            if score is not None and score < 40:
                print(f"  SKIP (score {score}): {name} -- {cat}")
                continue
            upscale = upscale_of(price, rating)
            coords = f" Maps coords: {v['lat']},{v['lng']}." if v.get("lat") and v.get("lng") else ""
            if mode == "taste":
                notes = (f"Google Maps '{cat}'. Price: {price or 'n/a'}. {rating}* ({reviews} reviews). "
                         f"Pre-score: {score}. Taste query: {context}.{coords}")
                source = f"taste:{context[:60]}"
            else:
                notes = (f"Google Maps '{cat}'. Price: {price or 'n/a'}. {rating}★ ({reviews} reviews). "
                         f"Discovered from: {context}.{coords}")
                source = f"gmaps:{context}"
            # Never the venue name: a bare name geocodes to anywhere in the country.
            address = ""
            if location and looks_like_street_address(location):
                address = clean_address(location)
            if not address and street:
                address = clean_address(street)
            if not address and location and (city or state):
                address = clean_address(location)
            ts, reasons = None, []
            if ts_score is not None and cls is not None:
                try:
                    ts, reasons = ts_score({"name": name, "category": our_cat, "city": city,
                                            "state": state, "notes": notes,
                                            "upscale_score": upscale}, cls)
                except Exception as e:
                    print(f"[discover] taste_score failed for {name}: {e}", file=sys.stderr)
            where = f"{city} {state}".strip() if (city or state) else (context_loc or f"{q_city} {q_state}".strip())
            cand = {
                "id": f"c{i}", "name": name, "norm": norm, "category": our_cat,
                "google_category": cat, "city": city, "state": state, "address": address,
                "rating": rating, "reviews": reviews, "price": price, "upscale": upscale,
                "taste_score": ts, "score": score, "source": source, "notes": notes,
                "search": one_line(f"{name} {where}"),
                "cat_conf": float((cls or {}).get("classification_confidence") or 0),
                "cat_source": (cls or {}).get("classification_source", ""),
            }
            out.write(json.dumps(cand) + "\n")
            n_cand += 1
    print(f"CANDIDATES:{n_cand}")
    return 0


def cmd_lookup_list(cands_path):
    for c in jsonl(cands_path):
        print(f"{c['id']}\t{one_line(c['search'])}\t{one_line(c['name'])}")
    return 0


def cmd_lookup_record(cid, rc, cite, kp_raw):
    try:
        kp = json.loads(kp_raw) if kp_raw and kp_raw != "missing value" else {}
    except ValueError:
        kp = {}
    ok = rc == "0" and cite != "missing value"
    print(json.dumps({"id": cid, "ok": ok, "rc": rc, "cite": cite if ok else "",
                      "kp": kp if isinstance(kp, dict) else {}}))
    return 0


def api_get(api, params):
    import requests
    try:
        r = requests.get(api, params=params, timeout=45)
        return r.json()
    except Exception as e:
        print(f"[discover] API {params.get('action')} failed: {e}", file=sys.stderr)
        return None


def promote(api, vid, website):
    """'' when the venue is confirmed untouched with this website, else what failed."""
    r = api_get(api, {"action": "update_venue", "venue_id": vid, "field": "status", "value": "untouched"})
    if not r or r.get("status") != "ok":
        return "status write rejected: " + str((r or {}).get("message", "no response"))
    d = api_get(api, {"action": "venue_detail", "venue_id": vid}) or {}
    v = d.get("venue") or {}
    if v.get("status") != "untouched":
        return f"read-back status is '{v.get('status', '?')}'"
    if (v.get("website") or "").rstrip("/") != website.rstrip("/"):
        return f"read-back website is '{v.get('website', '')}'"
    return ""


def cmd_add(cands_path, lookups_path, index_path, api):
    sys.path.insert(0, SCRIPT_DIR)
    from venue_quality import choose_website
    idx = load_index(index_path)
    lookups = {r["id"]: r for r in jsonl(lookups_path)}
    added = 0
    for c in jsonl(cands_path):
        name = c["name"]
        lk = lookups.get(c["id"], {})
        website = ""
        if lk.get("ok") and lk.get("cite"):
            website = choose_website(name, lk["cite"])
            why = website_reject_reason(website) if website else ""
            if why:
                print(f"  Website rejected for {name} ({why}): {website}")
                website = ""
        elif lk and not lk.get("ok"):
            print(f"  [WEBSITE] Lookup failed for {name} (Chrome rc={lk.get('rc')}) — added without a website")

        city, state, address = c["city"], c["state"], c["address"]
        conflict = ""
        kp = lk.get("kp") or {}
        kp_addr = one_line(kp.get("address", ""))
        same_kp = bool(kp.get("title")) and (norm_name(kp.get("title", "")) == c["norm"]
                                              or R.org_name_matches(kp.get("title", ""), name))
        if same_kp and kp.get("permanently_closed"):
            print(f"  SKIP (Google says permanently closed): {name}")
            idx["run_skipped"][c["norm"]] = "permanently closed"
            continue
        if same_kp and not website and kp.get("website"):
            kw = choose_website(name, kp["website"])
            if kw and not website_reject_reason(kw):
                website = kw
        # The Maps card rarely shows the Google category any more; the panel subtitle does
        # ("Restaurant", "French restaurant", "Art gallery"). It makes the category sure
        # enough to promote, and the scorer reads cuisine from the notes.
        kcat = one_line(kp.get("category", "")) if same_kp else ""
        if kcat:
            if "Google Maps ''" in c["notes"]:
                c["notes"] = c["notes"].replace("Google Maps ''", f"Google Maps '{kcat}'", 1)
            else:
                c["notes"] = f"{c['notes']} Google category: {kcat}."
            if c.get("cat_conf", 0) < 0.7:
                kc, kcls = classify(name, kcat)
                kconf = float((kcls or {}).get("classification_confidence") or 0)
                # A bare Google type ("Restaurant") reads like a sheet slug to the
                # classifier (0.6); from the panel it is Google's own assignment.
                if kc not in SKIP_CLASSES and kconf < 0.7 and \
                        kc.replace("_", " ") in kcat.lower():
                    kconf = 0.75
                if kc not in SKIP_CLASSES and kconf >= 0.7:
                    c["category"], c["cat_conf"] = kc, kconf
                    c["cat_source"] = (kcls or {}).get("classification_source", "")
        # Knowledge-panel address only when the panel is for this same business.
        if kp_addr and (norm_name(kp.get("title", "")) == c["norm"] or R.org_name_matches(kp.get("title", ""), name)):
            kcity, kstate = parse_location(kp_addr)
            if kstate and (not state or kstate == state):
                state = kstate
                city = city or kcity
                if not address or not looks_like_street_address(address) or not c["city"]:
                    address = clean_address(kp_addr) or address
            elif kstate and kstate != state:
                conflict = f"Maps listing says {state}, Google panel says {kstate}"
        # A bare street ("480 7th St NW") geocodes to the wrong city, so the address is
        # only sent when it names the state; otherwise the street is kept in the notes.
        notes = c["notes"]
        if address and not parse_location(address)[1]:
            if city and state:
                address = f"{address}, {city}, {state}"
            else:
                notes = f"{notes} Street from Maps: {address}."
                address = ""
        if state and state not in TARGET:
            print(f"  SKIP (out of area): {name} -- {state}")
            idx["run_skipped"][c["norm"]] = f"out of area {state}"
            continue
        dup = name_dup(idx, c["norm"], city, state)
        if dup:
            print(f"  SKIP (exists: {dup}): {name}")
            continue
        dom = venue_domain(website)
        if dom and dom in idx["domains"]:
            print(f"  SKIP (same website as {idx['domains'][dom]}): {name} -- {dom}")
            idx["run_skipped"][c["norm"]] = f"same website as {idx['domains'][dom]}"
            continue

        params = {
            "action": "add_venue", "name": name, "category": c["category"],
            "website": website, "city": city, "state": state, "address": address,
            "upscale_score": str(c["upscale"]), "source": c["source"], "notes": notes,
            "status": "needs_review",
        }
        if c.get("taste_score") is not None:
            params["taste_score"] = str(c["taste_score"])
        res = api_get(api, params)
        if res is None:
            print(f"  ERROR: {name} -- add_venue request failed")
            continue
        msg = str(res.get("message", ""))
        if res.get("status") != "ok":
            print(f"  ERROR: {name} -- add_venue: {msg or res}")
            idx["run_skipped"][c["norm"]] = "add_venue rejected"
            continue
        vid = str(res.get("venue_id", ""))
        if res.get("duplicate") or "duplicate" in msg.lower():
            # The existing row is left exactly as it is (never re-promoted or rewritten).
            print(f"  SKIP (server duplicate: {vid}): {name}")
            idx["run_skipped"][c["norm"]] = f"duplicate of {vid}"
            continue
        added += 1
        idx["names"].setdefault(c["norm"], []).append([city.lower(), state, vid])
        if dom:
            idx["domains"][dom] = vid
        label = f"ADDED (score {c['score']})" if c.get("score") is not None else "ADDED"
        where = ", ".join(x for x in (city, state) if x) or "location unknown"
        print(f"  {label}: {name} ({c['category']}, {c['rating']}*, {c['reviews']} reviews, {where}) -> {vid}")
        if not website:
            print("    No matching website found — remains needs_review")
            continue
        print(f"    Website: {website}")
        if not (city and state in TARGET):
            print("    Website saved; city/state not confirmed from the listing — remains needs_review")
            continue
        if conflict:
            print(f"    Location conflict ({conflict}) — remains needs_review")
            continue
        # Promotion needs a category the classifier is sure of (Google type or a specific
        # name pattern), not a name-only guess or a discovery rescue of 'other'.
        if c.get("cat_conf", 0) < 0.7:
            print(f"    Category '{c['category']}' is a guess ({c.get('cat_source') or 'no classifier'}) — remains needs_review")
            continue
        failed = promote(api, vid, website)
        if failed:
            print(f"    Promotion not confirmed ({failed}) — check {vid}; it may still be needs_review")
        else:
            print("    Promoted to untouched (website + location verified)")
    save_index(idx, index_path)
    print(f"ADDED_COUNT:{added}")
    return 0


def cmd_urlq(text):
    print(urllib.parse.quote(text))
    return 0


def cmd_gig_seeds(gigs_path):
    try:
        gigs = load_json(gigs_path).get("gigs", [])
    except Exception as e:
        print(f"[discover] past gigs unreadable: {e}", file=sys.stderr)
        return 2
    st = "|".join(R.TARGET_STATES)
    for g in gigs:
        name = one_line(g.get("venue_name", ""))
        if not name or name == "(DELETED)":
            continue
        m = re.search(r"(?:in |at )?([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),?\s*(?:" + st + r")\b", g.get("notes", "") or "")
        loc = re.sub(r"^(in|at) ", "", m.group(0).strip()) if m else ""
        print(name + "\t" + one_line(loc))
    return 0


def cmd_cleanup(disc_file, venues_path, gigs_path):
    """Drop discovered_gigs.txt entries that are now venues (past gigs stay: they are seeds)."""
    names, gig_names = set(), set()
    try:
        names = {v.get("name", "").lower().strip() for v in load_json(venues_path).get("venues", [])}
    except Exception as e:
        print(f"[discover] cleanup: venues unreadable ({e}); nothing removed", file=sys.stderr)
        print("  Cleanup skipped: venues list could not be read")
        return 0
    try:
        gig_names = {g.get("venue_name", "").lower().strip() for g in load_json(gigs_path).get("gigs", [])}
    except Exception as e:
        print(f"[discover] cleanup: gigs unreadable ({e}); nothing removed", file=sys.stderr)
        print("  Cleanup skipped: past gigs could not be read")
        return 0
    kept, removed = [], 0
    with open(disc_file, encoding="utf-8") as f:
        for line in f:
            name = line.strip()
            if not name:
                continue
            low = name.lower()
            if low not in gig_names and low in names:
                print(f"  CLEANUP: removed '{name}'")
                removed += 1
            else:
                kept.append(name)
    with open(disc_file, "w", encoding="utf-8") as f:
        for name in kept:
            f.write(name + "\n")
    print(f"  Cleanup done: removed {removed}, kept {len(kept)}")
    return 0


COMMANDS = {
    "index": cmd_index, "queries": cmd_queries, "count": cmd_count, "merge": cmd_merge,
    "filter": cmd_filter, "lookup-list": cmd_lookup_list, "lookup-record": cmd_lookup_record,
    "add": cmd_add, "urlq": cmd_urlq, "gig-seeds": cmd_gig_seeds, "cleanup": cmd_cleanup,
}
if __name__ == "__main__":
    sys.exit(COMMANDS[sys.argv[1]](*sys.argv[2:]))
PYLIB
    rc=$?
    append_err "$1" "$err"
    return $rc
}

# Run a JS file in Chrome's active tab. The path goes in as an argument and the
# file is read as UTF-8 (AppleScript's default is MacRoman). Prints the result;
# returns non-zero when osascript itself failed (Chrome closed, JS disabled).
run_js_file() {
    local js_file="$1" out rc err
    err=$(mktemp "$WORK_DIR/osa.XXXXXX")
    out=$(osascript -e 'on run argv' \
                    -e 'set jsCode to read (POSIX file (item 1 of argv)) as «class utf8»' \
                    -e 'tell application "Google Chrome" to execute active tab of front window javascript jsCode' \
                    -e 'end run' "$js_file" </dev/null 2>"$err")
    rc=$?
    append_err "osascript $(basename "$js_file")" "$err"
    printf '%s' "$out"
    return $rc
}

# Point Chrome's active tab at a URL (passed as an argument, never spliced into
# the AppleScript source). --activate brings Chrome to the front first.
chrome_open() {
    local err
    err=$(mktemp "$WORK_DIR/osa.XXXXXX")
    if [ "$1" = "--activate" ]; then
        shift
        osascript -e 'tell application "Google Chrome" to activate' -e 'delay 0.5' </dev/null >/dev/null 2>>"$err"
    fi
    osascript -e 'on run argv' \
              -e 'tell application "Google Chrome" to set URL of active tab of front window to (item 1 of argv)' \
              -e 'end run' "$1" </dev/null >/dev/null 2>>"$err"
    append_err "osascript open" "$err"
}

# Chrome must be open and "Allow JavaScript from Apple Events" on, otherwise every
# extraction comes back empty and would read as "no results".
chrome_probe() {
    local out err
    err=$(mktemp "$WORK_DIR/osa.XXXXXX")
    out=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "\"ok:\" + document.readyState"' </dev/null 2>"$err")
    append_err "chrome probe" "$err"
    case "$out" in
        ok:*) return 0 ;;
    esac
    log "ERROR: Chrome JavaScript is not reachable (got '${out:-nothing}')."
    log "       Open Chrome and turn on View > Developer > Allow JavaScript from Apple Events."
    return 1
}

# Fetch venues + past gigs and build the dedupe index. Aborts the run when the
# venue list can't be read: discovering blind re-adds venues we already have.
build_index() {
    local index="$1" line
    curl -sL --max-time 120 "${APPS_SCRIPT_URL}?action=venues" -o "$WORK_DIR/venues.json" 2>>"$ERR_LOG"
    curl -sL --max-time 60 "${APPS_SCRIPT_URL}?action=get_gigs" -o "$WORK_DIR/gigs.json" 2>>"$ERR_LOG"
    INDEX_COUNTS=""
    while IFS= read -r line; do
        case "$line" in
            COUNTS*) INDEX_COUNTS="${line#COUNTS }" ;;
            *) log "  $line" ;;
        esac
    done < <(disc_py index "$WORK_DIR/venues.json" "$WORK_DIR/gigs.json" "$index")
    if [ -z "$INDEX_COUNTS" ]; then
        log "ERROR: could not load existing venues for dedup (see $ERR_LOG) — stopping."
        return 1
    fi
    return 0
}

# Google each candidate to find its website + knowledge-panel address.
website_lookups() {
    local cands="$1" lookups="$2" cid csearch cname sq cite kp rc
    : > "$lookups"
    while IFS=$'\t' read -r cid csearch cname; do
        [ -z "$cid" ] && continue
        if [ "$LOOKUP_BLOCKED" = "1" ]; then
            disc_py lookup-record "$cid" 9 "" "" >> "$lookups"
            continue
        fi
        log "  [WEBSITE] Looking up: $cname"
        sq=$(disc_py urlq "$csearch")
        chrome_open "https://www.google.com/search?q=${sq}"
        sleep 3
        cite=$(run_js_file "${JS_DIR}/extract_cite.js"); rc=$?
        kp=$(run_js_file "${JS_DIR}/extract_kp_address.js")
        disc_py lookup-record "$cid" "$rc" "$cite" "$kp" >> "$lookups"
        case "$kp" in
            *'"blocked":true'*)
                LOOKUP_BLOCKED=1
                log "    [BLOCKED] Google is showing its unusual-traffic page — no more website lookups this run (venues stay needs_review)"
                ;;
        esac
        sleep 1
    done < <(disc_py lookup-list "$cands")
}

# Filter one page of results, look up websites, add. Prints nothing; logs; sets BATCH_ADDED.
process_results() {
    local mode="$1" results="$2" context="$3" context_loc="$4"
    local cands="$WORK_DIR/cands.jsonl" lookups="$WORK_DIR/lookups.jsonl" out line
    BATCH_ADDED=0
    rm -f "$cands" "$lookups"
    out=$(disc_py filter "$mode" "$results" "$INDEX_FILE" "$context" "$cands" "$context_loc")
    [ -n "$out" ] && printf '%s\n' "$out" | grep -v '^CANDIDATES:' | log_lines
    case "$out" in
        *CANDIDATES:*) ;;
        *) log "  [ERROR] filtering results failed (see $ERR_LOG)"; return 1 ;;
    esac
    [ -s "$cands" ] || return 0
    website_lookups "$cands" "$lookups"
    out=$(disc_py add "$cands" "$lookups" "$INDEX_FILE" "$APPS_SCRIPT_URL")
    [ -n "$out" ] && printf '%s\n' "$out" | grep -v '^ADDED_COUNT:' | log_lines
    line=$(printf '%s\n' "$out" | grep '^ADDED_COUNT:' | sed 's/ADDED_COUNT://')
    if [ -z "$line" ]; then
        log "  [ERROR] adding venues failed part-way (see $ERR_LOG)"
        return 1
    fi
    BATCH_ADDED=$line
    return 0
}

echo "" >> "$LOG_FILE"

# =============================================================
# MODE: --learn
# Scrape Google Maps attributes from taste_venues.txt to build
# a keyword profile (taste_keywords.json)
# =============================================================
if [ "$1" = "--learn" ]; then
    log "=== Taste Learn Mode Started ==="
    TASTE_VENUES_FILE="${SCRIPT_DIR}/taste_venues.txt"

    if [ ! -f "$TASTE_VENUES_FILE" ]; then
        log "ERROR: taste_venues.txt not found!"
        exit 1
    fi
    chrome_probe || exit 3

    # Read venue list and match against past gigs for location/score
    log "Fetching past gigs for location data..."
    GIGS_TMP="$WORK_DIR/taste_learn_gigs.json"
    curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o "$GIGS_TMP"

    DREAM_GIGS=$(python3 - "$TASTE_VENUES_FILE" "$GIGS_TMP" 2>>"$ERR_LOG" << 'PYEOF'
import json, sys, re

venues_file = sys.argv[1]
gigs_file = sys.argv[2]

with open(gigs_file) as f:
    gigs_data = json.loads(f.read())

# Load venue whitelist
whitelist = set()
with open(venues_file) as f:
    for line in f:
        name = line.strip()
        if name:
            whitelist.add(name.lower())

# Match against past gigs for location + score
for g in gigs_data.get('gigs', []):
    name = g.get('venue_name', '')
    if name.lower() not in whitelist:
        continue
    score = g.get('overall_score', 0)
    notes = g.get('notes', '')
    loc = '_'
    m = re.search(r'(?:in |at )?([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),?\s*(?:VA|MD|DC|PA)', notes)
    if m:
        loc = m.group(0).strip().lstrip('in ').lstrip('at ')
    print(name + '\t' + loc + '\t' + str(score))

# Also add venues from whitelist not in gigs (no score/location)
gig_names = set(g.get('venue_name', '').lower() for g in gigs_data.get('gigs', []))
for v in whitelist:
    if v not in gig_names:
        with open(venues_file) as f:
            for line in f:
                if line.strip().lower() == v:
                    print(line.strip() + '\t_\t0')
                    break
PYEOF
    )

    DREAM_COUNT=$(echo "$DREAM_GIGS" | grep -c '[a-zA-Z]')
    if [ "$DREAM_COUNT" = "0" ]; then
        log "No venues found in taste_venues.txt (or past gigs could not be read — see $ERR_LOG)!"
        exit 1
    fi
    log "Found $DREAM_COUNT taste venues"

    # For each dream gig, visit Google Maps and extract attributes
    ALL_ATTRS_FILE="$WORK_DIR/taste_learn_attrs.json"
    echo "[]" > "$ALL_ATTRS_FILE"
    GIGS_PROCESSED=0
    MAX_GIGS=${MAX_GIGS:-0}

    while IFS=$'\t' read -r VENUE_NAME VENUE_LOC VENUE_SCORE; do
        [ -z "$VENUE_NAME" ] && continue
        if [ "$MAX_GIGS" -gt 0 ] && [ "$GIGS_PROCESSED" -ge "$MAX_GIGS" ]; then
            log "  MAX_GIGS=$MAX_GIGS reached — stopping."
            break
        fi

        log ""
        log "=== Learning from: $VENUE_NAME ($VENUE_SCORE) ==="

        SEARCH_QUERY="$VENUE_NAME"
        [ -n "$VENUE_LOC" ] && [ "$VENUE_LOC" != "_" ] && SEARCH_QUERY="$VENUE_NAME $VENUE_LOC"
        ENCODED=$(disc_py urlq "$SEARCH_QUERY")
        MAPS_URL="https://www.google.com/maps/search/${ENCODED}"

        chrome_open --activate "$MAPS_URL"
        rand_delay 4 6

        # Click first result if on search results page
        CLICK_RESULT=$(run_js_file "${JS_DIR}/click_first_result.js")
        if [ "$CLICK_RESULT" = "clicked" ]; then
            log "  Clicked first search result..."
            rand_delay 3 5
        fi

        # Try clicking About tab to reveal attributes
        ABOUT_RESULT=$(run_js_file "${JS_DIR}/click_about_tab.js")
        if [ "$ABOUT_RESULT" = "clicked" ]; then
            log "  Opened About tab"
            rand_delay 2 3
        fi

        # Scroll to load all content
        run_js_file "${JS_DIR}/scroll_panel.js" >/dev/null
        rand_delay 3 5

        # Extract venue attributes
        ATTRS_JSON=$(run_js_file "${JS_DIR}/extract_venue_attributes.js")
        if [ -z "$ATTRS_JSON" ] || [ "$ATTRS_JSON" = "missing value" ]; then
            ATTRS_JSON='{"category":"","price":"","attributes":[]}'
            log "  No attributes extracted"
        else
            ATTR_COUNT=$(echo "$ATTRS_JSON" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('attributes',[])))" 2>>"$ERR_LOG" || echo "0")
            log "  Extracted $ATTR_COUNT attributes"
        fi

        # Append to collected data
        ATTRS_TMP="$WORK_DIR/taste_learn_single.json"
        echo "$ATTRS_JSON" > "$ATTRS_TMP"
        python3 - "$ATTRS_TMP" "$VENUE_NAME" "$VENUE_SCORE" "$ALL_ATTRS_FILE" 2>>"$ERR_LOG" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    attrs = json.loads(f.read())
attrs['venue'] = sys.argv[2]
attrs['score'] = float(sys.argv[3])
out_file = sys.argv[4]

with open(out_file, 'r') as f:
    all_data = json.loads(f.read())
all_data.append(attrs)
with open(out_file, 'w') as f:
    json.dump(all_data, f, indent=2)
PYEOF

        GIGS_PROCESSED=$((GIGS_PROCESSED + 1))
        rand_delay 3 5
    done <<< "$DREAM_GIGS"

    # Aggregate keywords and build taste_keywords.json
    log ""
    log "Aggregating keywords..."
    python3 - "$ALL_ATTRS_FILE" "$TASTE_KEYWORDS_FILE" 2>>"$ERR_LOG" << 'PYEOF' | log_lines
import json, sys
from collections import Counter
from datetime import datetime

attrs_file, keywords_file = sys.argv[1], sys.argv[2]
with open(attrs_file, 'r') as f:
    all_data = json.loads(f.read())

keyword_counts = Counter()
keyword_gigs = {}
price_counts = Counter()
categories = Counter()

for venue in all_data:
    vname = venue.get('venue', '')
    cat = venue.get('category', '')
    price = venue.get('price', '')
    attrs = venue.get('attributes', [])

    if cat:
        categories[cat] += 1
    if price:
        price_counts[price] += 1
    for attr in attrs:
        keyword_counts[attr] += 1
        if attr not in keyword_gigs:
            keyword_gigs[attr] = []
        keyword_gigs[attr].append(vname)

# Build output
ranked = [kw for kw, _ in keyword_counts.most_common(30)]
keywords = {}
for kw in ranked:
    keywords[kw] = {
        'count': keyword_counts[kw],
        'gigs': keyword_gigs[kw]
    }

result = {
    'generated': datetime.now().isoformat(),
    'source_gigs': len(all_data),
    'min_score': 8.5,
    'keywords': keywords,
    'ranked_keywords': ranked,
    'price_levels': dict(price_counts),
    'common_categories': [c for c, _ in categories.most_common(10)]
}

with open(keywords_file, 'w') as f:
    json.dump(result, f, indent=2)

print(f"Saved taste_keywords.json: {len(ranked)} keywords from {len(all_data)} gigs")
print(f"Top keywords: {', '.join(ranked[:10])}")
PYEOF

    log "=== Taste Learn Complete ==="
    exit 0
fi

# =============================================================
# MODE: --taste
# Use taste profile to generate search queries and find new venues
# =============================================================
if [ "$1" = "--taste" ]; then
    log "=== Taste Discovery Mode Started ==="

    # Check that taste_keywords.json exists
    if [ ! -f "$TASTE_KEYWORDS_FILE" ]; then
        log "ERROR: taste_keywords.json not found. Run --learn first!"
        echo "Run './discover.sh --learn' first to build your taste profile."
        exit 1
    fi
    if [ -f "${SCRIPT_DIR}/taste_venues.txt" ] && [ "${SCRIPT_DIR}/taste_venues.txt" -nt "$TASTE_KEYWORDS_FILE" ]; then
        log "WARNING: taste_venues.txt changed after taste_keywords.json was built — run './discover.sh --learn' to refresh the profile."
    fi

    MAX_QUERIES=${MAX_QUERIES:-20}
    log "MAX_QUERIES=$MAX_QUERIES"

    # Generate prioritized search queries
    log "Generating search queries from taste profile..."
    QUERIES_FILE="$WORK_DIR/taste_generated_queries.txt"
    GEN_OUT=$(disc_py queries "$TASTE_KEYWORDS_FILE" "$TASTE_QUERIES_FILE" "$QUERIES_FILE")
    case "$GEN_OUT" in
        STATS*) log "  ${GEN_OUT#STATS }" ;;
        *) log "ERROR: query generation failed: ${GEN_OUT:-see $ERR_LOG}"; exit 1 ;;
    esac
    GENERATED=$(printf '%s' "$GEN_OUT" | sed -n 's/.*generated=\([0-9]*\).*/\1/p')

    TOTAL_QUERIES=$(wc -l < "$QUERIES_FILE" | tr -d ' ')

    # Apply city filter if set (regex, e.g. CITY_FILTER="Annapolis|Severna Park")
    if [ -n "${CITY_FILTER:-}" ]; then
        grep -iE -- "$CITY_FILTER" "$QUERIES_FILE" > "${QUERIES_FILE}.filtered"
        mv "${QUERIES_FILE}.filtered" "$QUERIES_FILE"
        TOTAL_QUERIES=$(wc -l < "$QUERIES_FILE" | tr -d ' ')
        log "CITY_FILTER='$CITY_FILTER': filtered to $TOTAL_QUERIES matching queries"
        if [ "$TOTAL_QUERIES" -eq 0 ]; then
            log "ERROR: CITY_FILTER matched none of the remaining queries. Only the built-in"
            log "       location lists are generated; for another city use SWEEP_CITIES (./sweep.sh)."
            exit 1
        fi
    fi
    if [ "$TOTAL_QUERIES" -eq 0 ]; then
        if [ "${GENERATED:-0}" -gt 0 ]; then
            log "Nothing to do: all $GENERATED queries are already in taste_queries.txt."
            exit 0
        fi
        log "ERROR: no queries were generated."
        exit 1
    fi

    log "Generated $TOTAL_QUERIES queries ($MAX_QUERIES will run this session)"

    chrome_probe || exit 3

    # Fetch existing venues + past gigs for dedup
    log "Fetching existing venues + past gigs for dedup..."
    INDEX_FILE="$WORK_DIR/existing_index.json"
    build_index "$INDEX_FILE" || exit 1
    read -r EXISTING_COUNT _V _G _D <<< "$INDEX_COUNTS"
    log "Existing venues + past gigs: $EXISTING_COUNT (venues=$_V gigs=$_G websites=$_D)"

    # Process queries
    TOTAL_ADDED=0
    QUERIES_RUN=0
    QUERIES_FAILED=0
    CHROME_FAILS=0

    while IFS= read -r QUERY; do
        [ -z "$QUERY" ] && continue
        if [ "$QUERIES_RUN" -ge "$MAX_QUERIES" ]; then
            log "  MAX_QUERIES=$MAX_QUERIES reached — stopping."
            break
        fi

        log ""
        log "=== Taste Query [$((QUERIES_RUN + 1))/$MAX_QUERIES]: $QUERY ==="
        QUERIES_RUN=$((QUERIES_RUN + 1))

        ENCODED=$(disc_py urlq "$QUERY")
        MAPS_URL="https://www.google.com/maps/search/${ENCODED}"
        chrome_open --activate "$MAPS_URL"
        rand_delay 4 6

        # Scroll to load all search results
        log "  Scrolling search results..."
        run_js_file "${JS_DIR}/scroll_search_results.js" >/dev/null
        rand_delay 6 8

        # Extract search results
        log "  Extracting results..."
        RESULTS_JSON=$(run_js_file "${JS_DIR}/extract_search_results.js")
        JS_RC=$?

        if [ "$JS_RC" -ne 0 ] || [ -z "$RESULTS_JSON" ] || [ "$RESULTS_JSON" = "missing value" ] || [ "$RESULTS_JSON" = "NO_PANEL" ]; then
            # Not the same as "no results": the page or Chrome never answered.
            # Leave the query undone so the next run retries it.
            QUERIES_FAILED=$((QUERIES_FAILED + 1))
            CHROME_FAILS=$((CHROME_FAILS + 1))
            log "  FAILED: Chrome returned ${RESULTS_JSON:-nothing} (rc=$JS_RC) — query NOT marked done"
            if [ "$CHROME_FAILS" -ge "$MAX_CHROME_FAILS" ]; then
                log "ERROR: $CHROME_FAILS queries in a row got no answer from Chrome — stopping."
                log "       Check Chrome is open with JavaScript from Apple Events allowed, then re-run."
                exit 3
            fi
            rand_delay 3 5
            continue
        fi
        CHROME_FAILS=0

        if [ "$RESULTS_JSON" = "[]" ]; then
            log "  No results found"
            echo "$QUERY" >> "$TASTE_QUERIES_FILE"
            rand_delay 3 5
            continue
        fi

        RESULTS_TMP="$WORK_DIR/taste_search_results.json"
        printf '%s' "$RESULTS_JSON" > "$RESULTS_TMP"
        RESULT_COUNT=$(disc_py count "$RESULTS_TMP")
        if [ "${RESULT_COUNT:--1}" -lt 0 ]; then
            QUERIES_FAILED=$((QUERIES_FAILED + 1))
            log "  FAILED: results were not valid JSON — query NOT marked done"
            continue
        fi
        log "  Found $RESULT_COUNT results"

        # Pre-score, filter, look up websites, add
        if ! process_results taste "$RESULTS_TMP" "$QUERY" ""; then
            QUERIES_FAILED=$((QUERIES_FAILED + 1))
            TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
            log "  Query NOT marked done (processing failed)"
            continue
        fi
        TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
        log "  Added $BATCH_ADDED new venues from query"

        # Mark query as completed
        echo "$QUERY" >> "$TASTE_QUERIES_FILE"
        rand_delay 5 8
    done < "$QUERIES_FILE"

    # Calculate distances for new venues
    if [ "$TOTAL_ADDED" -gt 0 ]; then
        log "Calculating distances for new venues..."
        curl -sL "${APPS_SCRIPT_URL}?action=calc_distances" -o "$WORK_DIR/taste_distances.json"
        DIST_COUNT=$(python3 - "$WORK_DIR/taste_distances.json" 2>>"$ERR_LOG" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('calculated', 0))
PY
)
        log "  Distances calculated: ${DIST_COUNT:-failed (see $ERR_LOG)}"
    fi

    REMAINING=$((TOTAL_QUERIES - QUERIES_RUN + QUERIES_FAILED))
    log ""
    log "=== Taste Discovery Complete ==="
    log "  Queries run: $QUERIES_RUN"
    log "  Queries failed (will retry): $QUERIES_FAILED"
    log "  Venues added: $TOTAL_ADDED"
    log "  Queries remaining: $REMAINING"
    echo ""
    echo "Next steps:"
    echo "  1. Review the new needs_review venues in the app (website + location)"
    echo "  2. ./build_batch.sh 8 --dry-run, then ./build_batch.sh 8 and ./pipeline.sh --batch /tmp/pipeline_batch.json"
    echo "  3. Run './discover.sh --taste' again to continue with more queries"
    [ "$QUERIES_FAILED" -gt 0 ] && exit 4
    exit 0
fi

# =============================================================
# DEFAULT MODE: crawl "People also search for" from past gigs
# =============================================================
log "=== Venue Discovery Started ==="

# --- Step 1: Fetch past gigs ---
log "Fetching past gigs..."
curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o "$WORK_DIR/seed_gigs.json"
GIG_LIST=$(disc_py gig-seeds "$WORK_DIR/seed_gigs.json")

GIG_COUNT=$(echo "$GIG_LIST" | grep -c '[a-zA-Z]')

if [ "$GIG_COUNT" = "0" ]; then
    log "No past gigs found (or they could not be read — see $ERR_LOG). Add some gigs first!"
    exit 1
fi
log "Found $GIG_COUNT past gigs"

chrome_probe || exit 3

# --- Step 2: Fetch existing venue names (for dedup) ---
log "Fetching existing venues for dedup..."
INDEX_FILE="$WORK_DIR/existing_index.json"
build_index "$INDEX_FILE" || exit 1
read -r EXISTING_COUNT _V _G _D <<< "$INDEX_COUNTS"
log "Existing venues: $_V (unique names incl. past gigs: $EXISTING_COUNT, websites: $_D)"

# --- Step 3: For each past gig, scrape Google Maps ---
TOTAL_ADDED=0
MAX_GIGS=${MAX_GIGS:-0}  # 0 = unlimited; set MAX_GIGS=2 to limit
GIGS_PROCESSED=0
SEEDS_FAILED=0
CHROME_FAILS=0

while IFS=$'\t' read -r VENUE_NAME VENUE_LOC; do
    [ -z "$VENUE_NAME" ] && continue

    # Limit check (0 = unlimited)
    if [ "$MAX_GIGS" -gt 0 ] && [ "$GIGS_PROCESSED" -ge "$MAX_GIGS" ]; then
        log "  MAX_GIGS=$MAX_GIGS reached — stopping."
        break
    fi

    # Skip gigs already discovered
    if grep -qFx -- "$VENUE_NAME" "$DISCOVERED_FILE" 2>/dev/null; then
        log "  SKIP (already discovered): $VENUE_NAME"
        continue
    fi

    log ""
    log "=== Discovering from: $VENUE_NAME ==="
    GIGS_PROCESSED=$((GIGS_PROCESSED + 1))

    # Build search query with location for specificity
    SEARCH_QUERY="$VENUE_NAME"
    if [ -n "$VENUE_LOC" ]; then
        SEARCH_QUERY="$VENUE_NAME $VENUE_LOC"
        log "  (searching: $SEARCH_QUERY)"
    fi

    ENCODED=$(disc_py urlq "$SEARCH_QUERY")
    MAPS_URL="https://www.google.com/maps/search/${ENCODED}"
    chrome_open --activate "$MAPS_URL"
    rand_delay 4 6

    # If we landed on search results instead of venue page, click first result
    CLICK_RESULT=$(run_js_file "${JS_DIR}/click_first_result.js")
    if [ "$CLICK_RESULT" = "clicked" ]; then
        log "  Clicked first search result..."
        rand_delay 3 5
    fi

    # Scroll down to load "People also search for" section
    log "  Scrolling to find recommendations..."
    run_js_file "${JS_DIR}/scroll_panel.js" >/dev/null
    rand_delay 5 7

    # Extract "People also search for" cards
    log "  Extracting cards..."
    CARDS_JSON=$(run_js_file "${JS_DIR}/extract_cards.js")
    JS_RC=$?

    if [ "$JS_RC" -ne 0 ] || [ -z "$CARDS_JSON" ] || [ "$CARDS_JSON" = "missing value" ]; then
        SEEDS_FAILED=$((SEEDS_FAILED + 1))
        CHROME_FAILS=$((CHROME_FAILS + 1))
        log "  FAILED: Chrome returned ${CARDS_JSON:-nothing} (rc=$JS_RC) — seed NOT marked discovered"
        if [ "$CHROME_FAILS" -ge "$MAX_CHROME_FAILS" ]; then
            log "ERROR: $CHROME_FAILS seeds in a row got no answer from Chrome — stopping."
            exit 3
        fi
        rand_delay 3 5
        continue
    fi
    CHROME_FAILS=0
    printf '%s' "$CARDS_JSON" > "$WORK_DIR/cards.json"
    if [ "$CARDS_JSON" = "[]" ]; then
        log "  No 'People also search for' found"
    else
        log "  Found $(disc_py count "$WORK_DIR/cards.json") 'People also search for' results"
    fi

    # Also try to get "Similar hotels/places nearby" if present
    SIMILAR_JSON=$(run_js_file "${JS_DIR}/extract_similar.js")
    case "$SIMILAR_JSON" in \[*) ;; *) SIMILAR_JSON="[]" ;; esac
    printf '%s' "$SIMILAR_JSON" > "$WORK_DIR/similar.json"

    # Try clicking "View more hotels / places nearby" to get the expanded list
    echo "[]" > "$WORK_DIR/expanded.json"
    VIEW_MORE_CLICKED=$(run_js_file "${JS_DIR}/click_view_more.js")
    if [ "$VIEW_MORE_CLICKED" = "clicked" ]; then
        log "  Clicked 'View more' — loading expanded list..."
        rand_delay 4 6
        EXPANDED_JSON=$(run_js_file "${JS_DIR}/extract_expanded.js")
        case "$EXPANDED_JSON" in \[*) printf '%s' "$EXPANDED_JSON" > "$WORK_DIR/expanded.json" ;; esac
        log "  Expanded list: found $(disc_py count "$WORK_DIR/expanded.json") venues"

        # Navigate back to the venue page
        chrome_open "$MAPS_URL"
        sleep 3
    fi

    # Merge all results (People also search + Similar nearby + Expanded view more)
    FOUND_COUNT=$(disc_py merge "$WORK_DIR/merged.json" "$WORK_DIR/cards.json" "$WORK_DIR/similar.json" "$WORK_DIR/expanded.json")
    log "  Found ${FOUND_COUNT:-0} total recommendations"

    # Filter, look up websites, add to sheet
    if ! process_results crawl "$WORK_DIR/merged.json" "$VENUE_NAME" "$VENUE_LOC"; then
        SEEDS_FAILED=$((SEEDS_FAILED + 1))
        TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
        log "  Seed NOT marked discovered (processing failed)"
        continue
    fi
    TOTAL_ADDED=$((TOTAL_ADDED + BATCH_ADDED))
    log "  Added $BATCH_ADDED new venues from $VENUE_NAME"

    # Mark this gig as discovered so we skip it next time
    echo "$VENUE_NAME" >> "$DISCOVERED_FILE"

    rand_delay 3 5
done <<< "$GIG_LIST"

# --- Cleanup: remove discovered entries already in the app ---
log "Cleaning up discovered_gigs.txt..."
curl -sL "${APPS_SCRIPT_URL}?action=venues" -o "$WORK_DIR/cleanup_venues.json"
curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o "$WORK_DIR/cleanup_gigs.json"
disc_py cleanup "$DISCOVERED_FILE" "$WORK_DIR/cleanup_venues.json" "$WORK_DIR/cleanup_gigs.json" | log_lines

if [ "$TOTAL_ADDED" -gt 0 ]; then
    log "Calculating distances for new venues..."
    curl -sL "${APPS_SCRIPT_URL}?action=calc_distances" -o "$WORK_DIR/discover_distances.json"
    DIST_COUNT=$(python3 - "$WORK_DIR/discover_distances.json" 2>>"$ERR_LOG" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('calculated', 0))
PY
)
    log "  Distances calculated: ${DIST_COUNT:-failed (see $ERR_LOG)}"
fi

log ""
log "=== Discovery Complete — Total new venues: $TOTAL_ADDED ==="
[ "$SEEDS_FAILED" -gt 0 ] && log "  Seeds that failed and will be retried next run: $SEEDS_FAILED"

echo ""
echo "Next steps:"
echo "  1. Review the new needs_review venues in the app (website + location)"
echo "  2. ./build_batch.sh 8 --dry-run, then ./build_batch.sh 8 and ./pipeline.sh --batch /tmp/pipeline_batch.json"
[ "$SEEDS_FAILED" -gt 0 ] && exit 4
exit 0
