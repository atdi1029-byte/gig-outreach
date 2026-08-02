#!/bin/bash
# =============================================================
# Build Pipeline Batch — SAFE venue selection
#
# Usage:
#   ./build_batch.sh [COUNT]    — build diversified batch (default 20)
#   ./build_batch.sh 8          — build batch of 8
#
# Output: /tmp/pipeline_batch.json
#
# FILTERS (cannot be bypassed):
#   - Only status=untouched venues
#   - Excludes past gigs (from get_gigs API)
#   - Excludes venues with existing contacts
#   - Only venues with a website
#   - Only venues in target states (MD/VA/DC/PA/DE/WV)
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

echo "Building batch of $COUNT venues..."
echo "Fetching venues + past gigs..."

curl -sL "${APPS_SCRIPT_URL}?action=venues" -o /tmp/bb_venues.json
curl -sL "${APPS_SCRIPT_URL}?action=get_gigs" -o /tmp/bb_gigs.json
curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/bb_dashboard.json

python3 << PYEOF
import json, sys
from collections import defaultdict

COUNT = $COUNT

with open('/tmp/bb_venues.json') as f:
    venues = json.load(f).get('venues', [])
with open('/tmp/bb_gigs.json') as f:
    gigs = json.load(f).get('gigs', [])
with open('/tmp/bb_dashboard.json') as f:
    dash = json.load(f)

# Load venue IDs from recent reports (manifest.json)
# so we never re-pipeline a venue already in a report
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

# Build set of website domains already pipelined (any status != untouched)
# This catches duplicate venue entries with different IDs but same website
already_pipelined_domains = set()
for v in venues:
    if v.get('status', 'untouched') != 'untouched':
        w = v.get('website', '').lower()
        w = w.replace('https://','').replace('http://','').replace('www.','')
        domain = w.split('/')[0].strip()
        if domain and len(domain) > 3:
            already_pipelined_domains.add(domain)

# Past gig names (lowercase for matching)
past_gig_names = set()
for g in gigs:
    name = g.get('venue_name', '').lower().strip()
    if name and name != '(deleted)':
        past_gig_names.add(name)

# Venues that already have contacts (from dashboard)
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
# EXCLUDED: hotel_restaurant, luxury_hotel_restaurant,
# boutique_hotel_restaurant, historic_inn_restaurant
# These are restaurants INSIDE hotels that already have
# their own venue entry. Pipelining both = duplicate work.

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
    # Venues NOT suitable for classical guitar
    'dance hall', 'dance studio', 'ballroom',
    'salsa', 'bachata', 'tango ',
    'theater', 'theatre', 'playhouse', 'comedy club',
    'golf course', 'golf club', 'golf simulator',
    'five iron', 'puttery', 'topgolf', 'mini golf',
    'driving range', 'recreation center',
    'liquor store', 'wine store', 'wine shop',
    'spirits', 'bottle shop',
    'bowling', 'arcade', 'laser tag', 'escape room',
    'axe throwing', 'trampoline',
    'gym ', ' gym', 'crossfit', 'yoga studio',
    'pilates', 'boxing gym', 'martial art',
    'swim club', 'pool club', 'tennis club',
    'ice rink', 'skating'
]

# Chain restaurant names — skip corporate chains
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
    'chocolat', 'chocolate'
]

# Cities that are too far (>2hr from DC metro)
too_far_cities = [
    'charlottesville', 'richmond', 'williamsburg',
    'norfolk', 'virginia beach', 'hampton', 'newport news',
    'roanoke', 'lynchburg', 'blacksburg',
    'ocean city', 'salisbury', 'cumberland',
    'pittsburgh', 'harrisburg', 'state college',
    'dover', 'milford', 'georgetown de'
]

# Junk website domains — not real venue sites
junk_websites = [
    'cbs19news.com', 'facebook.com', 'yelp.com',
    'tripadvisor.com', 'google.com', 'wikipedia.org',
    'instagram.com', 'twitter.com', 'youtube.com',
    'wix.com', 'squarespace.com'
]

# FILTER: only untouched, with website, in target states,
# not a past gig, not a junk name, not a chain, not too far,
# not blank city/state, not junk website
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

# Track websites to detect duplicate venues (same website = same venue)
seen_websites = set()

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
    # Reject junk websites
    web_domain = website.lower().replace('https://','').replace('http://','').replace('www.','').split('/')[0]
    if any(j in web_domain for j in junk_websites):
        skipped_junk_site += 1
        continue
    # Reject if this domain was already pipelined (catches duplicate
    # venue entries with different IDs but same business)
    if web_domain in already_pipelined_domains:
        skipped_already_reported += 1
        continue
    # Reject duplicate websites (same venue listed multiple times)
    web_key = web_domain.split('.')[0]  # e.g. "cbmm" from "cbmm.org"
    if web_key in seen_websites:
        skipped_dupe_site += 1
        continue
    seen_websites.add(web_key)
    state = v.get('state', '')
    if state and state not in target_states:
        skipped_state += 1
        continue
    # Reject blank city or state
    city = v.get('city', '').strip()
    if not city or not state:
        skipped_blank_city += 1
        continue
    # Reject broken city fields (venue name leaked into city)
    # Valid cities are short (e.g. "Washington", "Bethesda", "Kennett Square")
    # Broken cities contain venue names, adjectives, or quotes
    city_lc = city.lower()
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
        'delaplane', 'round hill'
    }
    # Check if venue name words leaked into city field
    name_words = [w for w in name.lower().split() if len(w) > 3
                  and w not in {'the','and','bar','inn','club','farm'}]
    name_in_city = any(w in city_lc for w in name_words)
    if city_lc not in valid_cities and (
        len(city) > 25 or '"' in city or
        city_lc == name.lower() or name_in_city or
        any(w in city_lc for w in ['restaurant', 'best ', 'historic',
            'genuine', 'famous', 'great ', 'top ', 'finest'])):
        skipped_blank_city += 1
        continue
    # Reject cities outside radius
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
    # Reject chain restaurants
    if any(c in nl for c in chain_names):
        skipped_chain += 1
        continue
    # Reject junk venues hiding in notes (Google Maps category)
    notes_lc = (v.get('notes', '') or '').lower()
    junk_notes = ['liquor store', 'wine store', 'wine shop',
        'golf course', 'golf club', 'mini golf', 'golf simulator',
        'dance hall', 'dance studio', 'dance school', 'ballroom',
        'theater', 'theatre', 'comedy club', 'bowling',
        'recreation center', 'rec center', 'community center',
        'gym', 'fitness center', 'yoga studio', 'pilates',
        'ice cream', 'frozen yogurt', 'donut', 'bagel',
        'lingerie', 'clothing store', 'retail store']
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
print(f"  Skipped (junk website): {skipped_junk_site}")
print(f"  Skipped (duplicate site): {skipped_dupe_site}")

# Sort by upscale score desc, then state priority
state_priority = {'DC': 0, 'VA': 1, 'MD': 2, 'DE': 3, 'WV': 4, 'PA': 5}

# French/European keywords
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

# Normalize category names once so values like "country club" and
# "country_club" land in the same bucket.
def category_key(v):
    return (v.get('category', '') or '').strip().lower() \
        .replace(' ', '_').replace('-', '_')

# Parse score safely and use it as the PRIMARY ranking signal.
def quality_score(v):
    try:
        return float(v.get('upscale_score', 0) or 0)
    except (TypeError, ValueError):
        return 0.0

def quality_sort_key(v):
    return (
        -quality_score(v),
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
    # Best-scoring venues first; geography only breaks ties.
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

# If we didn't fill the batch, top up with best remaining
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

# Category quotas decide WHICH venues make the batch, but the final
# execution order is always best score first across every category.
batch.sort(key=quality_sort_key)

print(f"\n=== BATCH: {len(batch)} venues (best score first) ===")
for i, v in enumerate(batch):
    print(f"{i+1}. [{v.get('venue_id','')}] "
          f"{v.get('name','')} | "
          f"{v.get('category','')} | "
          f"{v.get('city','')} {v.get('state','')} | "
          f"score={v.get('upscale_score','')}")

with open('/tmp/pipeline_batch.json', 'w') as f:
    json.dump(batch, f, indent=2)

print(f"\nSaved to /tmp/pipeline_batch.json")
PYEOF
