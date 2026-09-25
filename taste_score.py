#!/usr/bin/env python3
"""
Taste Score — single source of truth for venue quality ranking.
Scale: 0-100. Higher = better fit for classical guitar gigs.

Used by: build_batch.sh (batch ranking, computed live every build),
rescore_pool.sh (persists the same score to the sheet's taste_score column),
discover.sh (score at discovery time), taste_review.py.

Weights:
  Venue-type fit (incl. cuisine / luxury): 0-30
  Location / wealthy-area fit:             0-20  (only when the city is trustworthy)
  Upscale / ambiance signals:              0-20
  Audience / cultural fit:                 0-15
  Recurring-music / event fit:             0-10
  Google quality (rating, else price):      0-5
  Classifier tags: music fit +5/0/-5, chain -30
                                   Total: 0-100

0 means DISQUALIFIED (junk gate, non-venue, wrong vibe), not "unscored".
Unscored venues have an empty taste_score cell.

How the Apps Script scores differ (apps_script.gs, owned separately):
  - buildTopPicks_/buildActionNeeded_ ("top_pick_score") start from the stored
    taste_score (50 when unscored) and add their own regex bonuses (+15 club,
    +12 live music, +10 French, +10 luxury, +8 affluent city, ...). They are an
    app-side "who to email next" ranking, not a venue-quality score; treat
    taste_score as the quality gate (MIN_TASTE_SCORE below).
  - getRecommendations_ (Smart Picks) uses the Taste sheet's category tiers and
    never reads taste_score.
  - Neither sees the location-trust, junk-gate or venue_id-category rules here.
Batch selection (build_batch.sh) only ever uses THIS module.
"""
import re

try:
    from venue_classifier import (classify, junk_reason, clean_notes, google_rating,
                                  _rx, _norm, NON_EURO_CUISINE)
except ImportError:  # keep the module importable for callers that pass classification
    classify = junk_reason = NON_EURO_CUISINE = None

    def clean_notes(n):
        return str(n or '')

    def google_rating(n):
        return None, 0

    def _norm(s):
        return re.sub(r'\s+', ' ', str(s or '').lower()).strip()

    def _rx(words):
        return re.compile(r"(?<![a-z0-9])(?:" + '|'.join(
            re.escape(w[:-1]) + r"[a-z']*" if w.endswith('*') else re.escape(w)
            for w in words) + r")(?![a-z0-9])")

SCORE_VERSION = '2026-09-25'
TARGET_STATES = ('DC', 'MD', 'VA')   # P5; mirrors outreach_rules.TARGET_STATES

# Batch floor (Apps Script TOP_PICK_MIN_TASTE mirrors this).
MIN_TASTE_SCORE = 25

# =========================================================
# VENUE-TYPE FIT (0-30)
# =========================================================
VENUE_TYPE_SCORES = {
    'private_club': 29,
    'country_club': 28,
    'golf_club': 28,
    'yacht_club': 22,
    'wine_bar': 26,
    'winery': 24,
    'hotel': 20,           # +8 with luxury/boutique/historic evidence
    'resort': 20,
    'restaurant': 10,      # boosted by cuisine keywords
    'music_venue': 18,
    'event_venue': 12,
    'event': 12,
    'event_space': 12,
    'wedding_venue': 6,
    'art_gallery': 8,      # boosted if events evidence
    'museum': 8,           # boosted if events evidence
    'gallery': 5,
    'tea_room': 5,
    'bar': 5,
    'cafe': 3,
    'brewery': 4,
    'distillery': 4,
    'spa': 2,
    'church': 2,
    'synagogue': 2,
    'library': 2,
    'event_planner': 3,
    'other': 3,
    'unknown': 3,
    # Disqualifying for batches
    'recreation': 0,
    'senior_living': 0,
    'theater': 0,
    'farmers_market': 0,
    'shopping': 0,
    'luxury_apts': 0,
}
LUXURY_HOTEL_BONUS = 8

# Cuisine keywords boost restaurant category score (whole words; '*' = prefix)
CUISINE_TIER1 = {
    # French/European = strongest signal (+18 -> restaurant becomes 28)
    'french': 18, 'bistro': 18, 'bistrot': 18, 'brasserie': 18, 'chez': 18,
    'provenc*': 18, 'lyonnais*': 16, 'auberge': 18, 'boucherie': 16,
    # Spanish ("any Spanish stuff is a huge win")
    'spanish': 18, 'tapas': 18, 'paella*': 16, 'basque': 16, 'catalan': 16,
    # Italian fine dining (+16 -> 26)
    'trattoria': 16, 'osteria': 16, 'ristorante': 16, 'enoteca': 14,
    # European broadly / upscale Latin
    'european': 14, 'mediterranean': 12, 'portuguese': 14,
    'argentin*': 16, 'churrascaria': 12, 'peruvian': 12, 'latin': 12,
    'cocina': 12, 'brazilian': 10, 'greek': 10, 'belgian': 12, 'austrian': 12,
}

CUISINE_TIER2 = {
    'italian': 10, 'seafood': 8, 'oyster*': 8,
    'farm to table': 10, 'farm-to-table': 10, 'prix fixe': 10,
    'tasting menu': 10, 'fine dining': 12,
    'steakhouse': 6, 'chophouse': 6,
    'wine bar': 12, 'wine lounge': 12,
    'cocktail*': 6, 'speakeasy': 8, 'lounge': 4,
}

# =========================================================
# LOCATION FIT (0-20)
# =========================================================
# Sweet spots from alex_taste.md / learnings.md. Only DC/MD/VA score (P5).
LOCATION_SCORES = {
    # DC Tier 1 (20)
    'georgetown': 20, 'dupont circle': 20, 'kalorama': 20, 'embassy row': 20,
    # DC Tier 2
    'washington': 16, 'washington dc': 16, 'capitol hill': 16,
    'logan circle': 16, 'penn quarter': 16, 'spring valley': 18,
    'foggy bottom': 14, 'adams morgan': 14,
    'u street': 14, 'cleveland park': 14,
    'woodley park': 14, 'tenleytown': 12,
    # MD - DC suburbs
    'potomac': 18, 'chevy chase': 18, 'bethesda': 18, 'north bethesda': 14,
    'glen echo': 16, 'cabin john': 16, 'rockville': 12, 'kensington': 12,
    # MD - Eastern Shore
    'st. michaels': 20, 'st michaels': 20, 'easton': 16, 'oxford': 14,
    'chestertown': 14, 'tilghman island': 12, 'kent island': 10, 'centreville': 10,
    # MD - Baltimore area / Howard County
    'roland park': 16, 'ruxton': 16, 'guilford': 14, 'homeland': 14,
    'mt washington': 12, 'mount washington': 12, 'hampden': 12, 'lutherville': 12,
    'towson': 12, 'baltimore': 10, 'ellicott city': 14, 'clarksville': 14,
    'columbia': 12,
    # MD - Annapolis area
    'annapolis': 16, 'gibson island': 18, 'severna park': 12, 'arnold': 10,
    'edgewater': 10, 'crofton': 8, 'gambrills': 8,
    # MD - other
    'havre de grace': 12, 'frederick': 10, 'mt airy': 10, 'mount airy': 10,
    # VA - Northern Virginia
    'great falls': 20, 'mclean': 18, 'alexandria': 18, 'del ray': 16,
    'vienna': 16, 'reston': 14, 'falls church': 14, 'tysons': 14, 'herndon': 10,
    'arlington': 3,   # "hit or miss despite being wealthy"
    # VA - Loudoun / hunt country
    'middleburg': 20, 'leesburg': 14, 'purcellville': 12, 'ashburn': 10,
    'south riding': 8, 'warrenton': 12, 'flint hill': 12, 'delaplane': 12,
}

# Approximate driving miles from home (Pasadena MD, the origin the sheet's
# distance_miles is measured from). A sweet-spot city only earns points when
# the venue's geocoded distance agrees with it; discovery used to stamp the
# search query's city onto venues (Dahlgren Yacht Club as 'Great Falls').
CITY_REF_MILES = {
    'georgetown': 45, 'dupont circle': 39, 'kalorama': 41, 'embassy row': 41,
    'washington': 39, 'washington dc': 39, 'capitol hill': 37, 'logan circle': 39,
    'penn quarter': 38, 'spring valley': 44, 'foggy bottom': 40, 'adams morgan': 41,
    'u street': 40, 'cleveland park': 42, 'woodley park': 41, 'tenleytown': 43,
    'potomac': 47, 'chevy chase': 40, 'bethesda': 40, 'north bethesda': 42,
    'glen echo': 46, 'cabin john': 46, 'rockville': 42, 'kensington': 41,
    'st. michaels': 57, 'st michaels': 57, 'easton': 48, 'oxford': 58,
    'chestertown': 54, 'tilghman island': 70, 'kent island': 21, 'centreville': 40,
    'roland park': 23, 'ruxton': 27, 'guilford': 22, 'homeland': 23,
    'mt washington': 24, 'mount washington': 24, 'hampden': 21, 'lutherville': 27,
    'towson': 25, 'baltimore': 23, 'ellicott city': 21, 'clarksville': 28,
    'columbia': 22, 'annapolis': 14, 'gibson island': 12, 'severna park': 5,
    'arnold': 8, 'edgewater': 17, 'crofton': 15, 'gambrills': 12,
    'havre de grace': 55, 'frederick': 56, 'mt airy': 43, 'mount airy': 43,
    'great falls': 53, 'mclean': 49, 'alexandria': 46, 'del ray': 45,
    'vienna': 53, 'reston': 58, 'falls church': 54, 'tysons': 51, 'herndon': 62,
    'arlington': 43, 'middleburg': 82, 'leesburg': 76, 'purcellville': 86,
    'ashburn': 68, 'south riding': 70, 'warrenton': 85, 'flint hill': 100,
    'delaplane': 95,
}

# Places that show up in venue names ('Baltimore Yacht Club', 'Wheaton Winery').
# A name naming a different place than the city field means the city is wrong.
# (Washington, Potomac, Chesapeake, Severn are left out: rivers/bays/the state.)
NAME_PLACES = (set(CITY_REF_MILES) - {'washington', 'washington dc', 'potomac'}) | {
    'westminster', 'wheaton', 'silver spring', 'fairfax', 'dundalk', 'essex', 'glen burnie',
    'pasadena', 'cambridge', 'solomons', 'manassas', 'culpeper', 'fredericksburg',
    'richmond', 'charlottesville', 'norfolk', 'hampton', 'williamsburg', 'occoquan',
    'lorton', 'woodbridge', 'springfield', 'burke', 'centreville', 'chantilly', 'sterling',
    'lovettsville', 'hagerstown', 'cumberland', 'bel air', 'aberdeen', 'elkton',
    'rock hall', 'st leonard', 'lusby', 'leonardtown', 'lexington park', 'la plata',
    'waldorf', 'bowie', 'laurel', 'college park', 'hyattsville', 'greenbelt',
    'upper marlboro', 'national harbor', 'gaithersburg', 'germantown', 'olney',
    'damascus', 'poolesville', 'urbana', 'new market', 'sykesville', 'eldersburg',
    'hampstead', 'thurmont', 'middletown', 'catonsville', 'owings mills', 'pikesville',
    'hunt valley', 'cockeysville', 'mount vernon', 'fort washington', 'oxon hill',
    'wilmington', 'lancaster', 'philadelphia', 'rehoboth', 'lewes', 'dahlgren',
    'lake anna', 'solomons island', 'north beach', 'deale', 'shady side', 'galesville',
    'davidsonville', 'crownsville', 'millersville', 'odenton', 'glen echo',
}
_NAME_PLACE_RX = re.compile(r"(?<![a-z])(" + '|'.join(
    re.escape(p) for p in sorted(NAME_PLACES, key=len, reverse=True)) + r")(?![a-z])")
# Discovery stamped query cities onto boating clubs ('yacht club Potomac MD').
INLAND_CITIES = {'bethesda', 'chevy chase', 'north bethesda', 'rockville', 'potomac',
                 'great falls', 'mclean', 'vienna', 'reston', 'herndon', 'tysons',
                 'falls church', 'ellicott city', 'columbia', 'clarksville', 'leesburg',
                 'middleburg', 'purcellville', 'ashburn', 'south riding', 'frederick',
                 'mt airy', 'mount airy', 'kensington', 'warrenton', 'flint hill',
                 'delaplane', 'towson', 'lutherville', 'ruxton', 'roland park'}
_BOATING = re.compile(r'(?<![a-z])(yacht|sailing|boat club|marina|yc)(?![a-z])')

# Batch radius: ~2 hours' drive from home (feedback_venue_radius).
MAX_DRIVE_MINUTES = 120
MAX_DISTANCE_MILES = 100

# =========================================================
# UPSCALE / AMBIANCE SIGNALS (0-20)
# =========================================================
UPSCALE_KEYWORDS = {
    'historic': 5, 'upscale': 5, 'elegant': 5,
    'luxury': 5, 'luxurious': 5, 'fine dining': 5,
    'intimate': 4, 'cozy': 4, 'boutique': 4,
    'manor': 4, 'estate': 4, 'mansion': 4,
    'colonial': 3, 'victorian': 3, 'antique': 3,
    'charming': 3, 'waterfront': 3,
    'harbor': 3, 'harbour': 3, 'wharf': 3,
    'garden*': 2, 'terrace': 2, 'courtyard': 2,
    'vineyard*': 2, 'cellar*': 2, 'sommelier': 2,
    'white tablecloth': 4, 'prix fixe': 3,
    'tasting room': 2, 'private dining': 3,
}

# =========================================================
# AUDIENCE / CULTURAL FIT (0-15)
# =========================================================
AUDIENCE_KEYWORDS = {
    'classical': 5, 'jazz': 4, 'acoustic': 4,
    'live music': 4, 'concert*': 4, 'chamber music': 5,
    'wine dinner*': 5, 'wine tasting*': 3,
    'private event*': 3, 'reception*': 3,
    'gala': 4, 'fundraiser*': 3,
    'cultured': 5, 'educated': 5,
    'sophisticated': 4,
}

# =========================================================
# EVENT SUITABILITY (0-10)
# =========================================================
EVENT_KEYWORDS = {
    'event space': 4, 'private event*': 4,
    'event rental*': 4, 'event venue': 3,
    'private dining': 4, 'banquet*': 3,
    'reception*': 3, 'wedding*': 2,
    'live music': 5, 'live entertainment': 4,
    'concert series': 5, 'music program': 5,
    'booking*': 3, 'entertainment': 3,
}

# =========================================================
# HARD PENALTIES (whole words)
# =========================================================
NON_VENUE_INDICATORS = [
    'maintenance', 'hoa', 'homeowner*', 'property management',
    'leasing', 'real estate', 'insurance', 'dental', 'dentist*',
    'medical', 'clinic', 'hospital', 'veterinar*',
    'auto repair', 'auto body', 'car wash', 'gas station', 'tire', 'tires',
    'storage', 'movers', 'moving company', 'plumb*', 'electrician*',
    'landscap*', 'roofing', 'hvac', 'pest control',
    'daycare', 'preschool', 'tutoring',
    'grocery', 'supermarket', 'convenience store',
    'dollar', 'walmart', 'target store', 'costco',
    'bookshop', 'bookstore', 'book shop',
    'dry clean*', 'laundr*', 'tailor*',
    'nail salon', 'hair salon', 'barber*',
    'lingerie', 'clothing', 'retail store',
]
# Only when the name has no strong venue identity ('University Club', 'Academy Art Museum').
SOFT_NON_VENUE = ['school', 'academy', 'university', 'college']

WRONG_VIBE_INDICATORS = [
    'sports bar', 'sports grill', 'buffalo wild',
    'hookah', 'karaoke', 'strip club', 'nightclub',
    'bowling', 'arcade', 'laser tag', 'escape room',
    'axe throwing', 'trampoline', 'mini golf',
    'go kart*', 'paintball',
    'gym', 'crossfit', 'pilates', 'boxing',
    'martial art*', 'yoga studio',
    'dragon boat', 'rowing club', 'canoe club',
    'swim club', 'pool club', 'tennis club',
    'ice rink', 'skating',
    'gun club', 'shooting range', 'rifle',
    'farmers market', 'flea market',
    'food truck', 'food court',
]

_RX_NON_VENUE = _rx(NON_VENUE_INDICATORS)
_RX_SOFT = _rx(SOFT_NON_VENUE)
_RX_WRONG_VIBE = _rx(WRONG_VIBE_INDICATORS)
_RX_CACHE = {}


def _kw_rx(kw):
    rx = _RX_CACHE.get(kw)
    if rx is None:
        rx = _RX_CACHE[kw] = _rx([kw])
    return rx


def _hits(table, text):
    return [(kw, pts) for kw, pts in table.items() if _kw_rx(kw).search(text)]


def _city_key(city):
    c = _norm(city).replace('.', '')
    c = re.sub(r'^(ne|nw|se|sw)\s+', '', c)
    c = re.sub(r',?\s+(dc|md|va)$', '', c) if c not in ('washington dc',) else c
    c = re.sub(r'^saint\s+', 'st ', c)
    return {'washington dc': 'washington', 'mt washington': 'mount washington'}.get(c, c)


def _price_level(notes):
    m = re.search(r'price:\s*(\$+)', str(notes or ''), re.I)
    return len(m.group(1)) if m else 0


# Cuisine credit from classifier tags when no keyword names it ("Le Chat Noir").
TAG_CUISINE = {'french': 16, 'spanish': 16, 'latin_american': 12, 'european': 12,
               'italian': 10}


def _cuisine_bonus(text, tags):
    hits1 = _hits(CUISINE_TIER1, text)
    if NON_EURO_CUISINE is not None and NON_EURO_CUISINE.search(text) and \
            not _kw_rx('french').search(text):
        hits1 = [h for h in hits1 if h[0] not in ('bistro', 'bistrot', 'brasserie')]
    t1 = max(hits1, key=lambda h: h[1], default=None)
    t2 = max(_hits(CUISINE_TIER2, text), key=lambda h: h[1], default=None)
    best = max([h for h in (t1, t2) if h], key=lambda h: h[1], default=None)
    if best:
        return best[1], best[0].rstrip('*')
    tag = max((t for t in tags if t in TAG_CUISINE), key=lambda t: TAG_CUISINE[t], default='')
    return (TAG_CUISINE[tag], f'{tag} (name)') if tag else (0, '')


def _hotel_luxury(venue, tags):
    """Luxury/boutique evidence for an independent hotel."""
    if 'chain_hotel' in tags:
        return False
    if 'luxury_hotel' in tags or 'waterfront' in tags:
        return True
    if _price_level(venue.get('notes', '')) >= 3:
        return True
    rating, reviews = google_rating(venue.get('notes', ''))
    return rating is not None and rating >= 4.5 and reviews >= 100


def _restaurant_prime(venue, tags, text=None):
    """French/European/Spanish/fine-dining evidence for a restaurant."""
    if text is None:
        text = ' ' + _norm(venue.get('name', '')) + ' ' + _norm(clean_notes(venue.get('notes', ''))) + ' '
    euro = any(t in tags for t in ('french', 'italian', 'spanish', 'european', 'latin_american'))
    if not euro and NON_EURO_CUISINE is not None and NON_EURO_CUISINE.search(text):
        return False    # 'Upscale Indian fusion': good restaurant, not the prime target
    if any(t in tags for t in PRIME_RESTAURANT_TAGS):
        return True
    if _cuisine_bonus(text, tags)[0] >= 10:
        return True
    return _price_level(venue.get('notes', '')) >= 3


def _num(x):
    try:
        f = float(x)
        return f if f == f else None
    except (TypeError, ValueError):
        return None


def location_info(venue):
    """Can the venue's city/state be trusted, and is it within the batch radius?

    Returns dict: trusted (bool), why (str), miles, minutes, in_radius
    (True/False, or None when the sheet has no distance).
    """
    city = _city_key(venue.get('city', ''))
    state = str(venue.get('state', '') or '').strip().upper()
    address = _norm(venue.get('address', ''))
    notes = _norm(venue.get('notes', ''))
    miles = _num(venue.get('distance_miles'))
    minutes = _num(venue.get('drive_minutes'))
    if miles is not None and miles <= 0:
        miles = None
    if minutes is not None and minutes <= 0:
        minutes = None
    if minutes is not None:
        in_radius = minutes <= MAX_DRIVE_MINUTES
    elif miles is not None:
        in_radius = miles <= MAX_DISTANCE_MILES
    else:
        in_radius = None
    out = {'trusted': False, 'why': '', 'miles': miles, 'minutes': minutes,
           'in_radius': in_radius}
    if not city or not state:
        out['why'] = 'no city/state'
        return out
    # A real street address naming the city is the strongest evidence.
    if address and re.search(r'\d', address) and city in address:
        out.update(trusted=True, why='address')
        return out
    name = _norm(venue.get('name', '')).replace('.', '')
    named = {m.group(1) for m in _NAME_PLACE_RX.finditer(name)}
    named = {p for p in named if p not in city and city not in p and not (
        p in CITY_REF_MILES and city in CITY_REF_MILES and
        abs(CITY_REF_MILES[p] - CITY_REF_MILES[city]) <= 6)}   # neighbours: Cabin John/Potomac
    if named:
        out['why'] = f"name says {sorted(named)[0]}, city field says {city}"
        return out
    if city in INLAND_CITIES and _BOATING.search(name):
        out['why'] = f'boating club listed in inland {city}'
        return out
    m = re.search(r'(taste query|discovered from)\s*:([^.]*)', notes)
    stamped = bool(m and city in _city_key(m.group(2)) or (m and city in m.group(2)))
    # The sheet geocodes distance from the address cell (usually the venue
    # name) when there is one, so the distance is independent evidence;
    # without an address it was computed FROM the city and proves nothing.
    ref = CITY_REF_MILES.get(city)
    if address and miles is not None:
        # A city copied from the search query needs a closer match.
        tol = max(6.0, 0.15 * ref) if (stamped and ref) else max(12.0, 0.3 * (ref or 0))
        if ref is None:
            if stamped:
                out['why'] = f"city '{city}' came from the discovery query"
            else:
                out.update(trusted=True, why='geocoded (city not checkable)')
        elif abs(miles - ref) <= tol:
            out.update(trusted=True, why=f'geocoded {miles:.0f} mi ~ {city}')
        else:
            out['why'] = f'geocoded {miles:.0f} mi, but {city} is ~{ref} mi'
        return out
    if stamped:
        out['why'] = f"city '{city}' came from the discovery query"
        return out
    out.update(trusted=True, why='listing city')
    return out


def _google_quality(venue, notes):
    rating, reviews = google_rating(venue.get('notes', ''))
    if rating is not None and reviews >= 5:
        if rating >= 4.7 and reviews >= 50:
            return 5, f'google {rating} ({reviews})'
        if rating >= 4.5:
            return 4, f'google {rating} ({reviews})'
        if rating >= 4.2:
            return 3, f'google {rating} ({reviews})'
        if rating >= 4.0:
            return 2, f'google {rating} ({reviews})'
        return 1, f'google {rating} ({reviews})'
    # upscale_score: discovery's price tier when Maps showed a price, otherwise
    # derived from the rating (4.7+ -> 4, 4.4+ -> 3). Same 0-5 scale as before.
    tier = _num(venue.get('upscale_score'))
    if tier is not None and 0 < tier <= 5:
        pts = {5: 5, 4: 4, 3: 2, 2: 1}.get(int(round(tier)), 0)
        if pts:
            return pts, f'upscale_score {int(round(tier))}'
    return 0, ''


def score(venue, classification=None):
    """Score a venue dict against the taste profile.

    Args:
        venue: dict with keys: name, category, city, state, notes, address,
               distance_miles, upscale_score, venue_id, website (all optional)
        classification: optional dict from venue_classifier.classify()

    Returns:
        tuple: (score: float 0-100, reasons: list of strings)
    """
    if classification is None and classify is not None:
        classification = classify(venue.get('name', ''), venue.get('category', ''),
                                  venue.get('notes', ''), venue.get('website', ''),
                                  venue.get('venue_id', ''))

    reasons = []
    name = _norm(venue.get('name', ''))
    if classification:
        cat = classification.get('primary_category', 'other')
        tags = classification.get('venue_tags', [])
        strong_identity = str(classification.get('classification_source', '')).startswith('name:')
    else:
        cat = _norm(venue.get('category', '')).replace(' ', '_').replace('-', '_') or 'other'
        tags = []
        strong_identity = False
    notes = _norm(clean_notes(venue.get('notes', '')))
    text = ' ' + name + ' ' + notes + ' '
    nl = ' ' + name + ' '

    # --- HARD PENALTIES (instant disqualify) ---
    if junk_reason is not None:
        why = junk_reason(venue.get('name', ''), venue.get('category', ''),
                          venue.get('notes', ''), venue.get('website', ''),
                          venue.get('check_status', ''))
        if why:
            reasons.append(f'-100 junk: {why}')
            return (0, reasons)
    hit = _RX_NON_VENUE.search(nl)
    if hit:
        reasons.append(f'-100 non-venue ({hit.group(0)})')
        return (0, reasons)
    hit = _RX_SOFT.search(nl)
    if hit and not strong_identity:
        reasons.append(f'-100 non-venue ({hit.group(0)})')
        return (0, reasons)
    hit = _RX_WRONG_VIBE.search(nl)
    if hit:
        reasons.append(f'-100 wrong vibe ({hit.group(0)})')
        return (0, reasons)

    # --- 1. VENUE-TYPE FIT (0-30) ---
    type_base = VENUE_TYPE_SCORES.get(cat, 3)
    reasons.append(f'+{type_base} venue type: {cat}')
    bonus = 0
    luxury = cat in ('hotel', 'resort') and _hotel_luxury(venue, tags)
    if cat == 'restaurant':
        bonus, what = _cuisine_bonus(text, tags)
        if bonus:
            reasons.append(f'+{bonus} cuisine: {what}')
    elif luxury:
        bonus = LUXURY_HOTEL_BONUS
        reasons.append(f'+{bonus} luxury/boutique/historic hotel')
    type_score = min(30, type_base + bonus)

    if cat in ('art_gallery', 'museum', 'gallery'):
        if re.search(r'(?<![a-z])(event|concert|music|reception|rental|private|performance)', text):
            type_score = min(30, type_score + 10)
            reasons.append('+10 gallery/museum with events')
        else:
            reasons.append('+0 no event evidence for gallery/museum')

    # --- 2. LOCATION FIT (0-20) ---
    city = _city_key(venue.get('city', ''))
    state = str(venue.get('state', '') or '').strip().upper()
    loc = location_info(venue)
    if state and state not in TARGET_STATES:
        loc_score = 0
        reasons.append(f'+0 location: {state} is outside DC/MD/VA')
    elif city in LOCATION_SCORES and loc['trusted']:
        loc_score = LOCATION_SCORES[city]
        reasons.append(f'+{loc_score} location: {city}')
    elif city in LOCATION_SCORES:
        loc_score = 3
        reasons.append(f'+3 location: {city} unverified ({loc["why"]})')
    else:
        loc_score = 3
        reasons.append(f'+3 location: {city} (unknown area)')

    # --- 3. UPSCALE / AMBIANCE (0-20) ---
    up = _hits(UPSCALE_KEYWORDS, text)
    upscale_score = min(20, sum(p for _, p in up))
    if up:
        reasons.append(f'+{upscale_score} upscale signals: '
                       f'{", ".join(k.rstrip("*") for k, _ in up[:4])}')

    # --- 4. AUDIENCE / CULTURAL FIT (0-15) ---
    au = _hits(AUDIENCE_KEYWORDS, text)
    audience_score = min(15, sum(p for _, p in au))
    if au:
        reasons.append(f'+{audience_score} audience fit: '
                       f'{", ".join(k.rstrip("*") for k, _ in au[:3])}')

    # --- 5. EVENT SUITABILITY (0-10) ---
    ev = _hits(EVENT_KEYWORDS, text)
    event_score = min(10, sum(p for _, p in ev))
    if ev:
        reasons.append(f'+{event_score} event fit: '
                       f'{", ".join(k.rstrip("*") for k, _ in ev[:3])}')

    # --- 6. GOOGLE QUALITY (0-5) ---
    google_score, gwhy = _google_quality(venue, notes)
    if google_score:
        reasons.append(f'+{google_score} {gwhy}')

    # --- TAG-BASED BOOSTS (from classifier) ---
    tag_boost = 0
    if 'music_fit_high' in tags or (luxury and 'music_fit_medium' in tags):
        tag_boost += 5
        reasons.append('+5 music_fit_high tag')
    elif 'music_fit_low' in tags:
        tag_boost -= 5
        reasons.append('-5 music_fit_low tag')
    if 'chain' in tags or 'chain_hotel' in tags:
        tag_boost -= 30
        reasons.append('-30 chain tag')

    total = type_score + loc_score + upscale_score + \
        audience_score + event_score + google_score + tag_boost
    return (round(min(100, max(0, total)), 1), reasons)


# =========================================================
# BATCH BUCKETS (the diversified mix; see feedback_diversify_pipeline)
# =========================================================
# Shares per 16 venues: ~5 French/fine dining, 3 clubs, 3 hotels, 3 wine, 2 wild.
BUCKET_SHARES = {'fine_dining': 5, 'club': 3, 'hotel': 3, 'wine': 3, 'wild': 2}
BUCKET_ORDER = ('fine_dining', 'club', 'hotel', 'wine', 'wild')
# Minimum taste score to enter each bucket (prime buckets need prime evidence,
# which the bucket rule itself checks; the wild card must score well on its own).
# Wild cards: galleries/museums/event spaces/music venues and independent hotels
# without luxury evidence; never a generic restaurant.
BUCKET_MIN_SCORE = {'fine_dining': 30, 'club': 30, 'hotel': 30, 'wine': 30, 'wild': 40}
PRIME_RESTAURANT_TAGS = ('french', 'italian', 'spanish', 'european', 'latin_american',
                         'fine_dining', 'upscale', 'intimate', 'historic')


def bucket(classification, venue=None):
    """Batch bucket for a classified venue, or '' if it doesn't belong in a batch."""
    if not classification:
        return ''
    venue = venue or {}
    cat = classification.get('primary_category', '')
    tags = classification.get('venue_tags', [])
    if cat in ('country_club', 'private_club', 'yacht_club'):
        return 'club'
    if cat in ('winery', 'wine_bar'):
        return 'wine'
    if cat == 'hotel':
        if 'chain_hotel' in tags:
            return ''
        return 'hotel' if _hotel_luxury(venue, tags) else 'wild'
    if cat == 'restaurant':
        # A restaurant with no French/European/fine-dining evidence is not a
        # wild card; wild cards are galleries, museums, event spaces, inns.
        return 'fine_dining' if _restaurant_prime(venue, tags) else ''
    if cat in ('art_gallery', 'museum', 'event_venue', 'music_venue', 'tea_room'):
        return 'wild'
    return ''


def score_simple(venue):
    """Return just the numeric score."""
    return score(venue)[0]


if __name__ == '__main__':
    import json, sys
    # CLI: accepts JSON venue dicts on stdin (one per line or array)
    input_text = sys.stdin.read().strip()
    if not input_text:
        sys.exit(0)

    try:
        data = json.loads(input_text)
        venues = data if isinstance(data, list) else [data]
    except json.JSONDecodeError:
        venues = []
        for line in input_text.split('\n'):
            try:
                venues.append(json.loads(line.strip()))
            except ValueError:
                pass

    for v in venues:
        s, reasons = score(v)
        print(f"{s:5.0f}  {v.get('venue_id',''):20s}  "
              f"{v.get('name',''):40s}  {v.get('category',''):15s}  "
              f"{v.get('city','')} {v.get('state','')}")
        for r in reasons:
            print(f"       {r}")
        print()
