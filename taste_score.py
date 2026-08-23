#!/usr/bin/env python3
"""
Taste Score — single source of truth for venue quality ranking.
Scale: 0-100. Higher = better fit for classical guitar gigs.

Used by: build_batch.sh, sweep.sh, rescore_pool.sh

Weights:
  Venue-type fit:                 0-30
  Location / wealthy-area fit:    0-20
  Upscale / ambiance signals:     0-20
  Audience / cultural fit:        0-15
  Recurring-music / event fit:    0-10
  Google quality / popularity:     0-5
                            Total: 100
"""

# =========================================================
# VENUE-TYPE FIT (0-30)
# =========================================================
# Very high (25-30)
VENUE_TYPE_SCORES = {
    'private_club': 29,
    'country_club': 28,
    'yacht_club': 22,
    'wine_bar': 26,
    'winery': 24,
    'hotel': 25,
    'resort': 25,
    # Base scores for categories that need cuisine/name boost
    'restaurant': 10,      # boosted by cuisine keywords
    # Possible
    'event_venue': 12,
    'event': 12,
    'music_venue': 18,
    # Poor
    'art_gallery': 8,      # boosted if events evidence
    'museum': 8,           # boosted if events evidence
    'gallery': 5,
    'bar': 5,
    'brewery': 4,
    'distillery': 4,
    'spa': 2,
    'church': 2,
    'synagogue': 2,
    'library': 2,
    'tea_room': 5,
    'other': 3,
    'unknown': 3,
    # Disqualifying
    'recreation': 0,
    'senior_living': 0,
    'theater': 0,
    'farmers_market': 0,
    'shopping': 0,
}

# Cuisine keywords boost restaurant category score
CUISINE_TIER1 = {
    # French/European = strongest signal (+18 → restaurant becomes 28)
    'french': 18, 'bistro': 18, 'brasserie': 18, 'chez ': 18,
    'provenc': 18, 'lyon': 16,
    # Italian fine dining (+16 → 26)
    'trattoria': 16, 'osteria': 16, 'ristorante': 16,
    # Spanish/Latin (+16 → 26)
    'tapas': 16, 'bodega': 14, 'cantina': 12,
    # European broadly (+14 → 24)
    'european': 14, 'mediterranean': 14, 'portuguese': 14,
    'argentinian': 14,
}

CUISINE_TIER2 = {
    # Good but not top tier (+8-10 → restaurant becomes 18-20)
    'italian': 10, 'seafood': 8, 'oyster': 8,
    'farm to table': 10, 'prix fixe': 10,
    'tasting menu': 10, 'fine dining': 12,
    'steakhouse': 6, 'chophouse': 6,
    'wine bar': 12, 'wine lounge': 12,
    'cocktail': 6, 'speakeasy': 8, 'lounge': 4,
}

# =========================================================
# LOCATION FIT (0-20)
# =========================================================
LOCATION_SCORES = {
    # DC Tier 1 (20)
    'georgetown': 20, 'dupont circle': 20,
    # DC Tier 2 (16-18)
    'washington': 16, 'capitol hill': 16,
    'logan circle': 16, 'penn quarter': 16,
    'foggy bottom': 14, 'adams morgan': 14,
    'u street': 14, 'cleveland park': 14,
    'woodley park': 14, 'tenleytown': 12,
    # MD Tier 1 (18-20)
    'potomac': 18, 'chevy chase': 18, 'bethesda': 18,
    'st. michaels': 20, 'st michaels': 20,
    # MD Tier 2 (14-16)
    'roland park': 16, 'annapolis': 16,
    'easton': 16, 'gibson island': 18,
    'ellicott city': 14, 'oxford': 14,
    'chestertown': 14, 'towson': 12,
    'severna park': 12, 'havre de grace': 12,
    'frederick': 10, 'mt airy': 10, 'mount airy': 10,
    'edgewater': 10, 'crofton': 8,
    # VA Tier 1 (18-20)
    'great falls': 20, 'mclean': 18, 'alexandria': 18,
    'middleburg': 20,
    # VA Tier 2 (12-16)
    'vienna': 16, 'leesburg': 14, 'reston': 14,
    'falls church': 14, 'tysons': 14,
    'purcellville': 12, 'warrenton': 12,
    'flint hill': 12, 'delaplane': 12,
    # PA (10-14)
    'gladwyne': 14, 'bryn mawr': 14, 'malvern': 14,
    'kennett square': 14, 'west chester': 12,
    'wayne': 12, 'devon': 12, 'newtown square': 10,
    'chadds ford': 12, 'philadelphia': 10,
    'lancaster': 8,
    # DE (8-12)
    'wilmington': 10, 'greenville': 12,
    'hockessin': 10, 'rehoboth beach': 8,
    # WV (6-8)
    'shepherdstown': 8, 'charles town': 6,
}

# =========================================================
# UPSCALE / AMBIANCE SIGNALS (0-20)
# =========================================================
UPSCALE_KEYWORDS = {
    # Strong signals (+5 each, capped at 20)
    'historic': 5, 'upscale': 5, 'elegant': 5,
    'luxury': 5, 'fine dining': 5,
    'intimate': 4, 'cozy': 4, 'boutique': 4,
    'manor': 4, 'estate': 4, 'mansion': 4,
    'colonial': 3, 'victorian': 3, 'antique': 3,
    'charming': 3, 'waterfront': 3,
    'harbor': 3, 'wharf': 3,
    # Moderate signals (+2)
    'garden': 2, 'terrace': 2, 'courtyard': 2,
    'vineyard': 2, 'cellar': 2, 'sommelier': 2,
    'white tablecloth': 4, 'prix fixe': 3,
    'tasting room': 2, 'private dining': 3,
}

# =========================================================
# AUDIENCE / CULTURAL FIT (0-15)
# =========================================================
AUDIENCE_KEYWORDS = {
    # Strong audience match (+5 each, capped at 15)
    'classical': 5, 'jazz': 4, 'acoustic': 4,
    'live music': 4, 'concert': 4,
    'wine dinner': 5, 'wine tasting': 3,
    'private event': 3, 'reception': 3,
    'gala': 4, 'fundraiser': 3,
    'cultured': 5, 'educated': 5,
    'sophisticated': 4,
}

# =========================================================
# EVENT SUITABILITY (0-10)
# =========================================================
EVENT_KEYWORDS = {
    'event space': 4, 'private event': 4,
    'event rental': 4, 'event venue': 3,
    'private dining': 4, 'banquet': 3,
    'reception': 3, 'wedding': 2,
    'live music': 5, 'live entertainment': 4,
    'concert series': 5, 'music program': 5,
    'booking': 3, 'entertainment': 3,
}

# =========================================================
# HARD PENALTIES
# =========================================================
CHAIN_INDICATORS = [
    'founding farmers', 'cava ', 'sweetgreen', 'nandos',
    'cheesecake factory', 'capital grille', "ruth's chris",
    'mortons', 'flemings', 'sullivan steakhouse',
    'olive garden', 'red lobster', 'outback',
    'applebees', 'chilis', 'tgi friday',
    'panera', 'starbucks', 'dunkin', 'five guys',
    'shake shack', 'buffalo wild wings',
    'paris baguette', 'la madeleine', 'maggiano',
    'doubletree', 'holiday inn', 'best western',
    'comfort inn', 'hampton inn', 'courtyard by',
    'fairfield inn', 'residence inn', 'springhill',
    'la quinta', 'super 8', 'days inn', 'motel 6',
    'red roof', 'quality inn', 'sleep inn',
    'embassy suites', 'homewood suites', 'home2 suites',
    'crowne plaza', 'radisson',
]

NON_VENUE_INDICATORS = [
    'maintenance', 'hoa', 'homeowner', 'property management',
    'leasing', 'real estate', 'insurance', 'dental',
    'medical', 'clinic', 'hospital', 'veterinar',
    'auto ', 'car wash', 'gas station', 'tire ',
    'storage', 'moving', 'plumb', 'electric',
    'landscap', 'roofing', 'hvac', 'pest control',
    'school', 'academy', 'university', 'college',
    'daycare', 'preschool', 'tutoring',
    'grocery', 'supermarket', 'convenience store',
    'dollar', 'walmart', 'target', 'costco',
    'bookshop', 'bookstore', 'book shop',
    'dry cleaner', 'laundry', 'tailor',
    'nail salon', 'hair salon', 'barber',
    'lingerie', 'clothing', 'retail',
]

WRONG_VIBE_INDICATORS = [
    'sports bar', 'sports grill', 'buffalo wild',
    'hookah', 'karaoke', 'strip club', 'nightclub',
    'bowling', 'arcade', 'laser tag', 'escape room',
    'axe throwing', 'trampoline', 'mini golf',
    'go kart', 'paintball',
    'gym', 'crossfit', 'pilates', 'boxing',
    'martial art', 'yoga studio',
    'dragon boat', 'rowing club', 'canoe club',
    'swim club', 'pool club', 'tennis club',
    'ice rink', 'skating',
    'gun club', 'shooting range', 'rifle',
    'farmers market', 'flea market',
    'food truck', 'food court',
]


def score(venue, classification=None):
    """Score a venue dict against the taste profile.

    Args:
        venue: dict with keys: name, category, city, state,
               notes, upscale_score (all optional)
        classification: optional dict from venue_classifier.classify()
               If provided, uses tags for better scoring.

    Returns:
        tuple: (score: float 0-100, reasons: list of strings)
    """
    # If no classification provided, classify now
    if classification is None:
        try:
            from venue_classifier import classify
            classification = classify(
                venue.get('name', ''),
                venue.get('category', ''),
                venue.get('notes', ''))
        except ImportError:
            classification = None

    reasons = []
    name = (venue.get('name', '') or '').lower()
    # Use classifier's category if available, else raw category
    if classification:
        cat = classification.get('primary_category', 'unknown')
        tags = classification.get('venue_tags', [])
    else:
        cat = (venue.get('category', '') or '').strip().lower() \
            .replace(' ', '_').replace('-', '_')
        tags = []
    city = (venue.get('city', '') or '').lower().strip()
    notes = (venue.get('notes', '') or '').lower()
    text = name + ' ' + notes
    google_rating = 0
    try:
        google_rating = float(venue.get('upscale_score', 0) or 0)
    except (TypeError, ValueError):
        pass

    # --- HARD PENALTIES (instant disqualify) ---
    nl = ' ' + name + ' '
    if any(c in nl for c in NON_VENUE_INDICATORS):
        reasons.append('-100 non-venue (maintenance/retail/school/etc)')
        return (0, reasons)
    if any(c in nl for c in WRONG_VIBE_INDICATORS):
        reasons.append('-100 wrong vibe (sports/recreation/nightlife)')
        return (0, reasons)
    if any(c in nl for c in CHAIN_INDICATORS):
        reasons.append('-40 chain restaurant/hotel')
        return (max(0, 10), reasons)  # chains get 10 max

    # --- 1. VENUE-TYPE FIT (0-30) ---
    type_base = VENUE_TYPE_SCORES.get(cat, 3)

    # Boost restaurants by cuisine keywords
    cuisine_boost = 0
    if cat == 'restaurant':
        best_t1 = 0
        best_t1_name = ''
        for kw, pts in CUISINE_TIER1.items():
            if kw in text and pts > best_t1:
                best_t1 = pts
                best_t1_name = kw
        best_t2 = 0
        best_t2_name = ''
        for kw, pts in CUISINE_TIER2.items():
            if kw in text and pts > best_t2:
                best_t2 = pts
                best_t2_name = kw
        cuisine_boost = max(best_t1, best_t2)
        if best_t1_name:
            reasons.append(f'+{best_t1} cuisine: {best_t1_name}')
        elif best_t2_name:
            reasons.append(f'+{best_t2} cuisine: {best_t2_name}')

    type_score = min(30, type_base + cuisine_boost)
    reasons.append(f'+{type_base} venue type: {cat}')

    # Boost galleries/museums with event evidence
    if cat in ('art_gallery', 'museum', 'gallery'):
        event_evidence = any(k in text for k in [
            'event', 'concert', 'music', 'reception',
            'rental', 'private', 'performance'])
        if event_evidence:
            type_score = min(30, type_score + 10)
            reasons.append('+10 gallery/museum with events')
        else:
            reasons.append('+0 no event evidence for gallery/museum')

    # --- 2. LOCATION FIT (0-20) ---
    loc_score = LOCATION_SCORES.get(city, 0)
    if loc_score:
        reasons.append(f'+{loc_score} location: {city}')
    else:
        # Unknown city gets 3 (might be fine, just unknown)
        loc_score = 3
        reasons.append(f'+3 location: {city} (unknown area)')

    # --- 3. UPSCALE / AMBIANCE (0-20) ---
    upscale_pts = 0
    upscale_hits = []
    for kw, pts in UPSCALE_KEYWORDS.items():
        if kw in text:
            upscale_pts += pts
            upscale_hits.append(kw)
    upscale_score = min(20, upscale_pts)
    if upscale_hits:
        reasons.append(f'+{upscale_score} upscale signals: '
                      f'{", ".join(upscale_hits[:4])}')

    # --- 4. AUDIENCE / CULTURAL FIT (0-15) ---
    audience_pts = 0
    audience_hits = []
    for kw, pts in AUDIENCE_KEYWORDS.items():
        if kw in text:
            audience_pts += pts
            audience_hits.append(kw)
    audience_score = min(15, audience_pts)
    if audience_hits:
        reasons.append(f'+{audience_score} audience fit: '
                      f'{", ".join(audience_hits[:3])}')

    # --- 5. EVENT SUITABILITY (0-10) ---
    event_pts = 0
    event_hits = []
    for kw, pts in EVENT_KEYWORDS.items():
        if kw in text:
            event_pts += pts
            event_hits.append(kw)
    event_score = min(10, event_pts)
    if event_hits:
        reasons.append(f'+{event_score} event fit: '
                      f'{", ".join(event_hits[:3])}')

    # --- 6. GOOGLE QUALITY (0-5) ---
    # Google rating contributes max 5 points
    google_score = 0
    if google_rating >= 4.7:
        google_score = 5
    elif google_rating >= 4.4:
        google_score = 4
    elif google_rating >= 4.0:
        google_score = 3
    elif google_rating >= 3.5:
        google_score = 2
    elif google_rating > 0:
        google_score = 1
    if google_score:
        reasons.append(f'+{google_score} google rating: {google_rating}')

    # --- TAG-BASED BOOSTS (from classifier) ---
    tag_boost = 0
    if tags:
        # Music fit from classifier
        if 'music_fit_high' in tags:
            tag_boost += 5
            reasons.append('+5 music_fit_high tag')
        elif 'music_fit_low' in tags:
            tag_boost -= 5
            reasons.append('-5 music_fit_low tag')

        # Chain penalty
        if 'chain' in tags or 'chain_hotel' in tags:
            tag_boost -= 30
            reasons.append('-30 chain tag')

    total = type_score + loc_score + upscale_score + \
            audience_score + event_score + google_score + tag_boost

    return (round(min(100, max(0, total)), 1), reasons)


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
        if isinstance(data, list):
            venues = data
        else:
            venues = [data]
    except json.JSONDecodeError:
        # Try line-by-line
        venues = []
        for line in input_text.split('\n'):
            try:
                venues.append(json.loads(line.strip()))
            except:
                pass

    for v in venues:
        s, reasons = score(v)
        print(f"{s:5.0f}  {v.get('venue_id',''):20s}  "
              f"{v.get('name',''):40s}  {v.get('category',''):15s}  "
              f"{v.get('city','')} {v.get('state','')}")
        for r in reasons:
            print(f"       {r}")
        print()
