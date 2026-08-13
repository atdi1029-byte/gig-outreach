#!/bin/bash
# =============================================================
# Build Pipeline Batch — SAFE venue selection
#
# Usage:
#   ./build_batch.sh [COUNT]           — build batch (default 20)
#   ./build_batch.sh 8                 — build batch of 8
#   ./build_batch.sh 20 --dry-run      — preview only, don't save
#
# Output: /tmp/pipeline_batch.json
#
# FILTERS (cannot be bypassed):
#   - Only status=untouched venues
#   - Excludes past gigs (from get_gigs API)
#   - Excludes venues with existing contacts
#   - Only venues with a website
#   - Only venues in target states (MD/VA/DC/PA/DE/WV)
#   - Website-venue name matching (rejects mismatches)
#   - Malformed city field detection
#
# RANKING: data_confidence * upscale_score (best first)
#
# DIVERSIFICATION:
#   ~30% French/European restaurants
#   ~20% country clubs / private clubs
#   ~20% hotels / boutique inns
#   ~15% wineries / wine bars
#   ~15% wild cards (art galleries, museums, event venues)
# =============================================================

APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
COUNT=${1:-20}
DRY_RUN=0
if [[ "$2" == "--dry-run" ]] || [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=1
    if [[ "$1" == "--dry-run" ]]; then COUNT=20; fi
fi

echo "Building batch of $COUNT venues..."
if [ "$DRY_RUN" = "1" ]; then echo "[DRY RUN — will not save batch]"; fi
echo "Fetching venues + past gigs..."

curl -sL "${APPS_SCRIPT_URL}?action=venues" -o /tmp/bb_venues.json
curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o /tmp/bb_gigs.json
curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/bb_dashboard.json

python3 << PYEOF
import json, sys, re, unicodedata
from collections import defaultdict

COUNT = $COUNT
DRY_RUN = $DRY_RUN

with open('/tmp/bb_venues.json') as f:
    venues = json.load(f).get('venues', [])
with open('/tmp/bb_gigs.json') as f:
    gigs = json.load(f).get('gigs', [])
with open('/tmp/bb_dashboard.json') as f:
    dash = json.load(f)

# Load venue IDs from recent reports (manifest.json)
import os
script_dir = os.path.dirname(os.path.abspath(__file__)) \
    if '__file__' in dir() else os.getcwd()
manifest_path = os.path.join(script_dir, 'reports', 'manifest.json')
if not os.path.exists(manifest_path):
    manifest_path = 'reports/manifest.json'
already_reported = set()
try:
    with open(manifest_path) as f:
        manifest = json.load(f)
    for entry in manifest:
        for vid in entry.get('venue_ids', []):
            already_reported.add(vid)
except:
    pass

# Build set of website domains already pipelined
already_pipelined_domains = set()
for v in venues:
    if v.get('status', 'untouched') != 'untouched':
        w = v.get('website', '').lower()
        w = w.replace('https://','').replace('http://','').replace('www.','')
        domain = w.split('/')[0].strip()
        if domain and len(domain) > 3:
            already_pipelined_domains.add(domain)

past_gig_names = set()
for g in gigs:
    name = g.get('venue_name', '').lower().strip()
    if name and name != '(deleted)':
        past_gig_names.add(name)

venues_with_contacts = set()
for c in dash.get('contacts', []):
    vid = c.get('venue_id', '')
    if vid:
        venues_with_contacts.add(vid)

print(f"Total venues: {len(venues)}")
print(f"Past gigs: {len(past_gig_names)}")
print(f"Venues with existing contacts: {len(venues_with_contacts)}")
print(f"Already in reports: {len(already_reported)}")

target_states = {'MD', 'VA', 'DC', 'PA', 'DE', 'WV'}
target_cats = {
    'restaurant', 'hotel', 'winery', 'wine_bar',
    'country_club', 'private_club', 'art_gallery',
    'yacht_club', 'museum', 'event', 'event_venue',
    'music_venue', 'bar', 'club', 'gallery'
}

skip_names = [
    'elks lodge', 'moose lodge', 'vfw', 'american legion',
    'knights of columbus', 'peninsula sailors', 'sail ',
    'school', 'academy', 'seminary', 'university',
    'college', 'montessori', 'preschool',
    'mcdonalds', 'taco bell', 'subway', 'chipotle',
    'hookah', 'karaoke', 'strip club',
    'garden club', 'rotary club', 'citizens association',
    'community lodge', 'community center', 'community assn',
    'civic association', 'civic club', 'kiwanis',
    'lions club', 'wine and liquor', 'wine & liquor',
    'liquor store',
    'dance hall', 'dance studio', 'ballroom',
    'salsa', 'bachata', 'tango ',
    'theater', 'theatre', 'playhouse', 'comedy club',
    'golf course', 'golf club', 'golf simulator',
    'five iron', 'puttery', 'topgolf', 'mini golf',
    'driving range', 'recreation center',
    'wine store', 'wine shop',
    'spirits', 'bottle shop',
    'bowling', 'arcade', 'laser tag', 'escape room',
    'axe throwing', 'trampoline',
    'gym ', ' gym', 'crossfit', 'yoga studio',
    'pilates', 'boxing gym', 'martial art',
    'swim club', 'pool club', 'tennis club',
    'ice rink', 'skating',
    'rifle', 'pistol', 'gun club', 'shooting',
    'foundation', 'association'
]

chain_names = [
    'founding farmers', 'cava', 'sweetgreen', 'nandos',
    'cheesecake factory', 'capital grille', 'ruth chris',
    'mortons', 'flemings', 'sullivan steakhouse',
    'puttery', 'five iron golf', 'topgolf',
    'olive garden', 'red lobster', 'outback',
    'applebees', 'chilis', 'tgi friday',
    'panera', 'starbucks', 'dunkin', 'five guys',
    'shake shack', 'wingstop', 'buffalo wild wings',
    'paris baguette', 'kitchen + kocktails',
    'planta ', 'grocery', 'bakery', 'baking company',
    'shawarma', 'kebab', 'falafel', 'food truck',
    'ice cream', 'frozen yogurt', 'donut', 'doughnut',
    'pizza hut', 'dominos', 'papa john',
    'la madeleine', 'maggiano', 'patisserie',
    'chocolat', 'chocolate',
    'doubletree', 'hilton', 'marriott', 'hyatt',
    'holiday inn', 'best western', 'comfort inn',
    'hampton inn', 'courtyard by', 'fairfield inn',
    'residence inn', 'springhill suites', 'towneplace',
    'la quinta', 'super 8', 'days inn', 'motel 6',
    'red roof', 'quality inn', 'sleep inn',
    'wyndham', 'radisson', 'crowne plaza'
]

too_far_cities = [
    'charlottesville', 'richmond', 'williamsburg',
    'norfolk', 'virginia beach', 'hampton', 'newport news',
    'roanoke', 'lynchburg', 'blacksburg',
    'ocean city', 'salisbury', 'cumberland',
    'pittsburgh', 'harrisburg', 'state college',
    'dover', 'milford', 'georgetown de'
]

# Junk website domains — not real venue sites
# Includes news, TV, .edu, .gov, tourism directories,
# social media, site builders, and review sites
junk_websites = [
    'facebook.com', 'yelp.com', 'tripadvisor.com',
    'google.com', 'wikipedia.org', 'instagram.com',
    'twitter.com', 'youtube.com', 'wix.com',
    'squarespace.com', 'linkedin.com', 'tiktok.com',
    # News / TV stations
    'fox5dc.com', 'fox.com', 'foxtv.com',
    'nbcwashington.com', 'wusa9.com', 'wjla.com',
    'wtop.com', 'washingtonpost.com', 'washingtonian.com',
    'baltimoresun.com', 'cbs19news.com', 'wbal.com',
    'nbc.com', 'abc.com', 'cbs.com', 'cnn.com',
    'foxnews.com', 'msnbc.com',
    # Tourism / directories / preservation
    'dcpreservation.org', 'historicsites.dcpreservation.org',
    'visitmaryland.org', 'virginia.org', 'visitvirginia.com',
    'visitannapolis.org', 'baltimore.org',
    'eventbrite.com', 'meetup.com', 'groupon.com',
    'opentable.com', 'resy.com', 'doordash.com',
    'grubhub.com', 'ubereats.com', 'seamless.com',
    'zomato.com', 'alltrails.com',
    # Government
    'dc.gov', 'virginia.gov', 'maryland.gov',
    'state.gov', 'usa.gov',
    # Generic
    'shopify.com', 'wordpress.com', 'blogspot.com',
    'godaddy.com', 'weebly.com'
]

# Also reject entire TLDs that are never venue websites
junk_tlds = ['.edu', '.gov', '.mil']

# =========================================================
# WEBSITE-VENUE NAME MATCHING
# Reject venues where the website domain has ZERO relation
# to the venue name. This catches discover.sh errors like
# "Domestique Wine" → fox5dc.com
# =========================================================
def normalize_for_match(text):
    """Strip accents, lowercase, keep only alphanum."""
    text = unicodedata.normalize('NFKD', text)
    text = ''.join(c for c in text if not unicodedata.combining(c))
    return re.sub(r'[^a-z0-9]', '', text.lower())

def venue_website_match(name, domain):
    """Check if domain plausibly belongs to venue.
    Returns True if match, False if definite mismatch."""
    if not domain or not name:
        return True  # can't tell, let it through

    # Strip TLD from domain: "kafeleopold.com" → "kafeleopold"
    domain_base = domain.split('.')[0].lower()
    # Ignore very short domain bases (e.g. "dc" from dc.gov)
    if len(domain_base) < 3:
        return True

    name_norm = normalize_for_match(name)
    domain_norm = normalize_for_match(domain_base)

    # Direct containment: domain in name or name in domain
    if domain_norm in name_norm or name_norm in domain_norm:
        return True

    # Extract significant words from venue name (3+ chars)
    stop_words = {
        'the', 'and', 'bar', 'inn', 'club', 'farm',
        'restaurant', 'grille', 'grill', 'lounge',
        'bistro', 'cafe', 'hotel', 'wine', 'winery',
        'vineyard', 'country', 'yacht', 'art', 'gallery',
        'museum', 'event', 'private', 'inc', 'llc',
        'little', 'italy', 'old', 'new', 'great',
        'big', 'east', 'west', 'north', 'south',
        'port', 'washington', 'virginia', 'maryland',
        'delaware', 'pennsylvania'
    }
    name_words = [w for w in re.findall(r'[a-z]{3,}', name.lower())
                  if w not in stop_words]

    # Any significant name word appears in domain?
    for w in name_words:
        if w in domain_norm:
            return True

    # Any significant part of domain appears in name?
    # Split domain on common separators
    domain_parts = re.findall(r'[a-z]{3,}', domain_base)
    for part in domain_parts:
        if part in name_norm and part not in {
            'com', 'org', 'net', 'www', 'the'
        }:
            return True

    # Known legitimate domain patterns that won't match name:
    # hotel management companies, restaurant groups, etc.
    legit_mismatches = [
        'aramark', 'marriott', 'hilton', 'hyatt',
        'guestservices', 'compass', 'sodexo',
        'macsthospitality', 'rwrestaurantgroup',
        'titanhosp', 'clydescorp'
    ]
    if any(lm in domain_norm for lm in legit_mismatches):
        return True

    # No match found — this is suspicious
    return False


# =========================================================
# MALFORMED CITY FIELD DETECTION
# Catches garbage like "and prices in DC", broken scrapes
# =========================================================
def city_is_malformed(city):
    """Returns True if the city field looks broken."""
    if not city:
        return True
    cl = city.lower().strip()
    # Contains words that are never in real city names
    garbage_words = [
        'and ', 'prices', 'best ', 'top ', 'finest',
        'genuine', 'famous', 'historic ', 'restaurant',
        'review', 'rating', 'menu', 'hours', 'delivery',
        'near me', 'open now', 'reserv', 'book a',
        'order', 'http', 'www.', '.com', '@',
        'phone', 'email', 'contact'
    ]
    if any(g in cl for g in garbage_words):
        return True
    # Too long to be a real city
    if len(city) > 30:
        return True
    # Contains digits (addresses leaked in)
    if re.search(r'\d{3,}', city):
        return True
    # Contains quotes
    if '"' in city or "'" in city:
        return True
    return False


# =========================================================
# DATA CONFIDENCE SCORE
# Measures how trustworthy the venue record is (0.0-1.0)
# =========================================================
def data_confidence(v):
    """Score how clean/trustworthy this record looks."""
    score = 1.0
    name = v.get('name', '')
    website = v.get('website', '')
    city = v.get('city', '')
    state = v.get('state', '')

    domain = website.lower().replace('https://','') \
        .replace('http://','').replace('www.','') \
        .split('/')[0] if website else ''

    # Website-name mismatch is a big red flag
    if not venue_website_match(name, domain):
        score -= 0.5

    # City looks questionable but not outright garbage
    if city and city.lower() not in valid_cities:
        score -= 0.1

    # Very short or very long venue names are suspicious
    if len(name) < 4:
        score -= 0.2
    if len(name) > 60:
        score -= 0.1

    # No state
    if not state:
        score -= 0.3

    # Website is a deep path (not root domain) — less trustworthy
    path = website.lower().replace('https://','') \
        .replace('http://','').replace('www.','')
    if path.count('/') > 2:
        score -= 0.1

    return max(0.0, min(1.0, score))


# =========================================================
# MAIN FILTER LOOP
# =========================================================
pool = []
skipped_status = 0
skipped_gig = 0
skipped_has_contacts = 0
skipped_nosite = 0
skipped_state = 0
skipped_cat = 0
skipped_name = 0
skipped_chain = 0
skipped_radius = 0
skipped_blank_city = 0
skipped_junk_site = 0
skipped_already_reported = 0
skipped_dupe_site = 0
skipped_website_mismatch = 0
skipped_malformed_city = 0

seen_websites = set()

valid_cities = {
    'washington', 'georgetown', 'bethesda', 'potomac',
    'chevy chase', 'rockville', 'silver spring', 'columbia',
    'baltimore', 'annapolis', 'easton', 'st michaels',
    'st. michaels', 'ellicott city', 'towson', 'frederick',
    'hagerstown', 'havre de grace', 'cambridge',
    'alexandria', 'arlington', 'mclean', 'vienna',
    'reston', 'herndon', 'leesburg', 'middleburg',
    'fairfax', 'falls church', 'great falls', 'manassas',
    'lovettsville', 'purcellville', 'woodbridge',
    'stafford', 'warrenton', 'flint hill', 'front royal',
    'gladwyne', 'bryn mawr', 'gwynedd', 'kennett square',
    'west chester', 'media', 'philadelphia', 'lancaster',
    'wayne', 'devon', 'ardmore', 'radnor', 'newtown square',
    'chadds ford', 'malvern', 'paoli', 'king of prussia',
    'wilmington', 'greenville', 'hockessin', 'rehoboth beach',
    'lewes', 'shepherdstown', 'charles town',
    'martinsburg', 'harpers ferry',
    'roland park', 'pikesville', 'owings mills',
    'hunt valley', 'severna park', 'gibson island',
    'centreville', 'chestertown', 'oxford',
    'dupont circle', 'foggy bottom', 'penn quarter',
    'capitol hill', 'logan circle', 'adams morgan',
    'tenleytown', 'cleveland park', 'woodley park',
    'st michaels', 'tilghman island', 'kent island',
    'taneytown', 'mt airy', 'mount airy', 'dickerson',
    'boyds', 'clarksburg', 'gaithersburg', 'olney',
    'laurel', 'bowie', 'crofton', 'gambrills',
    'edgewater', 'arnold', 'glen echo',
    'ashburn', 'sterling', 'south riding',
    'delaplane', 'round hill', 'tysons',
    'hampden', 'mt washington', 'mount washington',
    'riva', 'kent island', 'grasonville'
}

for v in venues:
    status = v.get('status', 'untouched')
    if status != 'untouched':
        skipped_status += 1
        continue
    name = v.get('name', '')
    if name.lower().strip() in past_gig_names:
        skipped_gig += 1
        continue
    vid = v.get('venue_id', '')
    if vid in already_reported:
        skipped_already_reported += 1
        continue
    if vid in venues_with_contacts:
        skipped_has_contacts += 1
        continue
    website = v.get('website', '')
    if not website:
        skipped_nosite += 1
        continue

    # Parse domain once
    web_domain = website.lower().replace('https://','') \
        .replace('http://','').replace('www.','').split('/')[0]

    # Reject junk website domains
    if any(j in web_domain for j in junk_websites):
        skipped_junk_site += 1
        continue

    # Reject junk TLDs (.edu, .gov, .mil)
    if any(web_domain.endswith(tld) for tld in junk_tlds):
        skipped_junk_site += 1
        continue

    # Reject already-pipelined domains
    if web_domain in already_pipelined_domains:
        skipped_already_reported += 1
        continue

    # Reject duplicate websites
    web_key = web_domain.split('.')[0]
    if web_key in seen_websites:
        skipped_dupe_site += 1
        continue
    seen_websites.add(web_key)

    state = v.get('state', '')
    if state and state not in target_states:
        skipped_state += 1
        continue

    city = v.get('city', '').strip()
    if not city or not state:
        skipped_blank_city += 1
        continue

    # NEW: Reject malformed city fields
    if city_is_malformed(city):
        skipped_malformed_city += 1
        continue

    city_lc = city.lower()

    # Existing city validation (name leaks, etc.)
    name_words = [w for w in name.lower().split() if len(w) > 3
                  and w not in {'the','and','bar','inn','club','farm'}]
    name_in_city = any(w in city_lc for w in name_words)
    if city_lc not in valid_cities and (
        len(city) > 25 or '"' in city or
        city_lc == name.lower() or name_in_city):
        skipped_blank_city += 1
        continue

    if city.lower() in too_far_cities:
        skipped_radius += 1
        continue

    cat = v.get('category', '').lower().replace(' ', '_')
    if cat not in target_cats:
        skipped_cat += 1
        continue

    nl = name.lower()
    if any(s in nl for s in skip_names):
        skipped_name += 1
        continue

    if any(c in nl for c in chain_names):
        skipped_chain += 1
        continue

    # NEW: Website-venue name matching (hard reject)
    if not venue_website_match(name, web_domain):
        skipped_website_mismatch += 1
        continue

    # Reject junk venues hiding in notes
    notes_lc = (v.get('notes', '') or '').lower()
    junk_notes = ['liquor store', 'wine store', 'wine shop',
        'golf course', 'golf club', 'mini golf', 'golf simulator',
        'dance hall', 'dance studio', 'dance school', 'ballroom',
        'theater', 'theatre', 'comedy club', 'bowling',
        'recreation center', 'rec center', 'community center',
        'gym', 'fitness center', 'yoga studio', 'pilates',
        'ice cream', 'frozen yogurt', 'donut', 'bagel',
        'lingerie', 'clothing store', 'retail store',
        'gun range', 'shooting range', 'rifle', 'pistol']
    if any(j in notes_lc for j in junk_notes):
        skipped_name += 1
        continue

    pool.append(v)

print(f"Filtered pool: {len(pool)}")
print(f"  Skipped (status): {skipped_status}")
print(f"  Skipped (past gig): {skipped_gig}")
print(f"  Skipped (already reported): {skipped_already_reported}")
print(f"  Skipped (has contacts): {skipped_has_contacts}")
print(f"  Skipped (no website): {skipped_nosite}")
print(f"  Skipped (out of area): {skipped_state}")
print(f"  Skipped (wrong category): {skipped_cat}")
print(f"  Skipped (junk name): {skipped_name}")
print(f"  Skipped (chain): {skipped_chain}")
print(f"  Skipped (too far): {skipped_radius}")
print(f"  Skipped (blank city/state): {skipped_blank_city}")
print(f"  Skipped (malformed city): {skipped_malformed_city}")
print(f"  Skipped (junk website): {skipped_junk_site}")
print(f"  Skipped (duplicate site): {skipped_dupe_site}")
print(f"  Skipped (website mismatch): {skipped_website_mismatch}")

# =========================================================
# RANKING: confidence * upscale_score
# =========================================================
state_priority = {'DC': 0, 'VA': 1, 'MD': 2, 'DE': 3, 'WV': 4, 'PA': 5}

french_kw = [
    'french', 'bistro', 'brasserie', 'provenc', 'lyon',
    'paris', 'chez', 'la ', 'le ', 'les ', "l'", 'au ',
    'aux ', 'du ', 'des ', 'trattoria', 'osteria',
    'ristorante', 'enoteca', 'european', 'mediterranean',
    'portuguese'
]

def is_french(v):
    nl = v.get('name', '').lower()
    notes = v.get('notes', '') or ''
    return any(k in nl or k in notes.lower() for k in french_kw)

def category_key(v):
    return (v.get('category', '') or '').strip().lower() \
        .replace(' ', '_').replace('-', '_')

def safe_upscale_score(v):
    try:
        return float(v.get('upscale_score', 0) or 0)
    except (TypeError, ValueError):
        return 0.0

def composite_score(v):
    """Confidence-weighted quality score."""
    return data_confidence(v) * safe_upscale_score(v)

def quality_sort_key(v):
    return (
        -composite_score(v),
        -safe_upscale_score(v),
        state_priority.get(v.get('state', ''), 9),
        (v.get('name', '') or '').lower()
    )

# Group by normalized category
by_cat = defaultdict(list)
for v in pool:
    by_cat[category_key(v)].append(v)

batch = []
used = set()

def pick(cats, count, label, filter_fn=None):
    added = 0
    p = []
    for c in cats:
        p.extend(by_cat.get(c, []))
    if filter_fn:
        p = [v for v in p if filter_fn(v)]
    p.sort(key=quality_sort_key)
    for v in p:
        if added >= count:
            break
        vid = v.get('venue_id', '')
        if vid in used:
            continue
        used.add(vid)
        batch.append(v)
        added += 1
    print(f"  {label}: {added}/{count}")

# Diversified picks
fr_count = max(1, int(COUNT * 0.30))
cl_count = max(1, int(COUNT * 0.20))
ho_count = max(1, int(COUNT * 0.20))
wi_count = max(1, int(COUNT * 0.15))
wc_count = COUNT - fr_count - cl_count - ho_count - wi_count

pick(['restaurant'], fr_count,
     'French/European restaurants', is_french)
pick(['country_club', 'private_club', 'yacht_club',
      'golf_club'], cl_count, 'Clubs')
pick(['hotel', 'hotel_restaurant',
      'luxury_hotel_restaurant',
      'boutique_hotel_restaurant',
      'historic_inn_restaurant'], ho_count, 'Hotels')
pick(['winery', 'wine_bar'], wi_count, 'Wineries/Wine Bars')
pick(['art_gallery', 'museum', 'event',
      'event_venue'], wc_count, 'Wild Cards')

# Top up with best remaining
if len(batch) < COUNT:
    remaining = [v for v in pool
                 if v.get('venue_id') not in used]
    remaining.sort(key=quality_sort_key)
    for v in remaining:
        if len(batch) >= COUNT:
            break
        batch.append(v)
        used.add(v.get('venue_id'))
    topup_count = len(batch) - (fr_count + cl_count + ho_count + wi_count + wc_count)
    if topup_count < 0: topup_count = 0
    print(f"  Top-up: {topup_count}")

# =========================================================
# ENFORCE LOCAL-FIRST CAP: max 10% PA/DE/WV
# User lives in MD — DC/MD/VA are the core zone.
# PA/DE/WV are edge-of-radius filler only.
# =========================================================
core_states = {'DC', 'VA', 'MD'}
edge_max = max(2, int(COUNT * 0.10))  # ~10%, min 2
edge_venues = [v for v in batch
               if v.get('state', '') not in core_states]
if len(edge_venues) > edge_max:
    # Keep only the best edge venues, drop the rest
    edge_venues.sort(key=quality_sort_key)
    edge_to_drop = set(
        v.get('venue_id') for v in edge_venues[edge_max:]
    )
    batch = [v for v in batch
             if v.get('venue_id') not in edge_to_drop]
    used -= edge_to_drop
    # Backfill with core-state venues
    remaining = [v for v in pool
                 if v.get('venue_id') not in used
                 and v.get('state', '') in core_states]
    remaining.sort(key=quality_sort_key)
    for v in remaining:
        if len(batch) >= COUNT:
            break
        batch.append(v)
        used.add(v.get('venue_id'))
    dropped = len(edge_to_drop) - (COUNT - len(batch))
    print(f"  Local-first cap: dropped {len(edge_to_drop)} "
          f"edge-of-radius venues (PA/DE/WV), "
          f"kept {edge_max}")

# Final sort: best composite score first
batch.sort(key=quality_sort_key)

# =========================================================
# OUTPUT
# =========================================================
print(f"\n=== BATCH: {len(batch)} venues (best score first) ===")
flagged = []
for i, v in enumerate(batch):
    conf = data_confidence(v)
    comp = composite_score(v)
    flag = ""
    if conf < 0.8:
        flag = " *** SUSPICIOUS"
        flagged.append(v)
    print(f"{i+1}. [{v.get('venue_id','')}] "
          f"{v.get('name','')} | "
          f"{v.get('category','')} | "
          f"{v.get('city','')} {v.get('state','')} | "
          f"score={v.get('upscale_score','')} "
          f"conf={conf:.1f} comp={comp:.1f}{flag}")

if flagged:
    print(f"\n!!! {len(flagged)} SUSPICIOUS venues flagged "
          f"(low data confidence):")
    for v in flagged:
        domain = v.get('website','').lower() \
            .replace('https://','').replace('http://','') \
            .replace('www.','').split('/')[0]
        print(f"  - {v.get('name','')} → {domain} "
              f"(conf={data_confidence(v):.1f})")

if DRY_RUN:
    print(f"\n[DRY RUN] Batch NOT saved. "
          f"Review above, then run without --dry-run.")
else:
    with open('/tmp/pipeline_batch.json', 'w') as f:
        json.dump(batch, f, indent=2)
    print(f"\nSaved to /tmp/pipeline_batch.json")
PYEOF
