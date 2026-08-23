#!/usr/bin/env python3
"""
Venue Classifier — single source of truth for venue classification.

Used by: discover.sh, sweep.sh, rescore_pool.sh, build_batch.sh

Replaces duplicated map_category() functions.
Produces: primary_category, venue_tags, classification_confidence.

Key principle: SPECIFIC business types always beat GENERIC types.
  country_club + restaurant → country_club (with dining tag)
  bookstore + cafe → bookstore
  museum + restaurant → museum
  unknown → 'unknown', NEVER 'restaurant'
"""
import re


# =========================================================
# SPECIFICITY HIERARCHY
# Specific types override generic hospitality types.
# First match wins — order matters.
# =========================================================

# Level 1: Private / Specialized (always override restaurant)
SPECIFIC_TYPES = {
    'country_club': {
        'google': ['country club', 'golf club'],
        'name': ['country club', 'golf & country', 'golf and country',
                 'hunt club', 'field club'],
    },
    'private_club': {
        'google': ['private club', 'social club', "women's club",
                   "woman's club", 'civic club', 'fraternal'],
        'name': ['city club', 'town club', 'cosmos club',
                 'university club', 'army navy club',
                 'metropolitan club', 'social club',
                 'democratic club', 'republican club',
                 'supper club', 'circle club'],
    },
    'yacht_club': {
        'google': ['yacht', 'sailing club'],
        'name': ['yacht club', 'yacht '],
    },
    'hotel': {
        'google': ['hotel', 'inn', 'resort', 'lodge',
                   'motel', 'hostel', 'guest house'],
        'name': ['hotel ', ' inn ', ' inn,', ' resort ', ' lodge ',
                 ' suites ', 'bed & breakfast', 'bed and breakfast',
                 'b&b', 'waldorf', 'conrad', 'sofitel', 'pendry',
                 'salamander', 'lyle ', 'the line ', 'the jefferson',
                 'ritz-carlton', 'four seasons', 'fairmont',
                 'mandarin', 'st. regis', 'westin', 'hyatt',
                 'marriott', 'hilton', 'intercontinental',
                 'kimpton', 'rosewood', 'peninsula', 'langham',
                 'omni', 'loews', 'crowne plaza', 'radisson',
                 'hampton inn', 'holiday inn', 'comfort inn',
                 'best western', 'doubletree', 'embassy suites',
                 'courtyard by', 'fairfield inn', 'residence inn',
                 'springhill', 'homewood', 'home2'],
    },
    'winery': {
        'google': ['winery', 'vineyard'],
        'name': ['winery', 'winer', 'vineyard', 'vintner',
                 'cellars', 'viticulture'],
    },
    'wine_bar': {
        'google': ['wine bar'],
        'name': ['wine bar', 'wine lounge', 'wine room',
                 'wine garden', 'wine cellar'],
    },
    'brewery': {
        'google': ['brewery', 'brewpub'],
        'name': ['brewery', 'brewing', 'brewpub', 'brew pub',
                 'brewhouse'],
    },
    'distillery': {
        'google': ['distillery', 'cidery'],
        'name': ['distillery', 'cidery', 'distiller'],
    },
    'museum': {
        'google': ['museum'],
        'name': ['museum'],
    },
    'art_gallery': {
        'google': ['art gallery', 'gallery'],
        'name': ['gallery', 'galleries', 'arts center',
                 'arts council', 'arts commission',
                 'arts foundation', 'arts alliance',
                 'arts district', 'arts association',
                 'art center', 'art institute',
                 'art association', 'art league',
                 'atelier', 'working artists'],
    },
    'event_venue': {
        'google': ['event', 'banquet', 'wedding', 'catering',
                   'booking agent', 'entertainment agency'],
        'name': ['mansion ', 'manor ', 'pavilion ',
                 'ballroom ', 'banquet hall', 'event space',
                 'event center', 'event venue'],
    },
}

# Level 2: Non-venue types (disqualify as gig venue)
NON_VENUE_INDICATORS = {
    'recreation': [
        'boat club', 'dragon boat', 'rowing', 'canoe club',
        'kayak club', 'paddl', 'swim club', 'pool club',
        'tennis club', 'gym ', ' gym', 'crossfit', 'fitness',
        'yoga studio', 'pilates', 'martial art', 'boxing gym',
        'ice rink', 'skating', 'bowling', 'arcade',
        'trampoline', 'laser tag', 'escape room',
        'go kart', 'paintball', 'axe throwing',
        'golf simulator', 'mini golf', 'topgolf', 'x-golf',
        'recreation center', 'rec center',
        'athletic club', 'sports club', 'fit club',
        'golf course', 'golf club', 'driving range',
        'five iron', 'puttery',
    ],
    'theater': [
        'theater', 'theatre', 'cinema', 'playhouse',
        'performing arts center', 'comedy club',
    ],
    'other': [
        'bookshop', 'bookstore', 'book shop', 'book store',
        'maintenance', ' hoa ', 'homeowner',
        'property management', 'leasing office',
        'insurance', 'dental', 'medical', 'clinic',
        'hospital', 'veterinar',
        'auto ', 'car wash', 'tire ', 'storage',
        'plumb', 'electric', 'landscap', 'roofing',
        'grocery', 'supermarket', 'convenience store',
        'dry cleaner', 'laundry', 'tailor',
        'nail salon', 'hair salon', 'barber',
        'lingerie', 'clothing store', 'retail store',
        'dollar store', 'thrift', 'pawn',
        'school', 'academy', 'university', 'college',
        'daycare', 'preschool', 'tutoring',
        'senior living', 'assisted living', 'retirement',
        'elder care', 'nursing home',
        'farmers market', 'flea market', 'farm stand',
        'food truck', 'food court',
    ],
    'spa': ['spa '],  # handled separately to avoid 'spanish'
}

# Level 3: Hospitality (only if nothing more specific matched)
HOSPITALITY_TYPES = {
    'restaurant': ['restaurant', 'fine dining', 'steakhouse',
                   'brasserie', 'bistro', 'trattoria',
                   'osteria', 'ristorante', 'chophouse',
                   'tavern', 'grill'],
    'bar': ['bar', 'pub', 'tavern', 'lounge', 'taproom'],
    'cafe': ['cafe', 'coffee', 'tea room', 'tea house',
             'patisserie', 'bakery'],
}

# =========================================================
# VENUE TAGS
# =========================================================
TAG_SIGNALS = {
    # Cuisine tags
    'french': ['french', 'bistro', 'brasserie', 'chez ',
               'provenc', 'lyon', 'paris', 'la ', 'le ',
               'les ', "l'", 'au ', 'aux ', 'du ', 'des '],
    'italian': ['italian', 'trattoria', 'osteria', 'ristorante',
                'enoteca', 'pizzeria'],
    'spanish': ['spanish', 'tapas', 'barcelona', 'bodega',
                'cantina'],
    'european': ['european', 'mediterranean', 'portuguese',
                 'greek'],
    'latin_american': ['argentinian', 'brazilian', 'peruvian',
                       'mexican', 'latin'],
    # Quality tags
    'fine_dining': ['fine dining', 'prix fixe', 'tasting menu',
                    'white tablecloth', 'michelin'],
    'upscale': ['upscale', 'luxury', 'elegant', 'refined',
                'sophisticated'],
    'historic': ['historic', 'colonial', 'victorian', 'antique',
                 'heritage', 'est. 1', 'since 1', 'founded 1'],
    'intimate': ['intimate', 'cozy', 'charming', 'boutique',
                 'quaint', 'romantic'],
    'waterfront': ['waterfront', 'harbor', 'wharf', 'marina',
                   'seaside', 'bayfront', 'lakefront'],
    # Function tags
    'dining': ['restaurant', 'dining', 'dinner', 'brunch',
               'lunch'],
    'events': ['event', 'private event', 'reception', 'gala',
               'banquet', 'wedding', 'catering', 'venue rental'],
    'live_music': ['live music', 'live entertainment',
                   'concert', 'music program', 'music series',
                   'acoustic', 'jazz', 'classical'],
    # Business tags
    'chain': ['founding farmers', 'cava ', 'sweetgreen',
              'nandos', 'cheesecake factory', 'capital grille',
              "ruth's chris", 'mortons', 'flemings',
              'olive garden', 'red lobster', 'outback',
              'applebees', 'chilis', 'tgi friday',
              'panera', 'starbucks', 'dunkin', 'five guys',
              'shake shack', 'buffalo wild wings',
              'paris baguette', 'la madeleine', 'maggiano'],
    'chain_hotel': ['doubletree', 'holiday inn', 'best western',
                    'comfort inn', 'hampton inn', 'courtyard by',
                    'fairfield inn', 'residence inn', 'springhill',
                    'la quinta', 'super 8', 'days inn', 'motel 6',
                    'red roof', 'quality inn', 'sleep inn',
                    'embassy suites', 'homewood suites',
                    'home2 suites', 'crowne plaza', 'radisson',
                    'wyndham'],
    'independent': [],  # set if no chain tag
}


def classify(name='', google_category='', notes='', website=''):
    """Classify a venue and return structured result.

    Args:
        name: venue name
        google_category: raw Google Maps category/type string
        notes: any notes/description
        website: website URL

    Returns:
        dict with:
            primary_category: str
            venue_tags: list of str
            classification_confidence: float 0-1
            classification_source: str
    """
    cl = (google_category or '').lower()
    nl = ' ' + (name or '').lower() + ' '
    text = nl + ' ' + (notes or '').lower()

    # Strip city names that cause false positives
    nl_clean = nl
    for fc in ['falls church', 'church hill', 'church creek',
               'church point', 'chapel hill', 'churchill']:
        nl_clean = nl_clean.replace(fc, ' ')

    primary = None
    confidence = 0.0
    source = ''
    tags = []

    # --- Phase 1: Name-based non-venue detection ---
    # These override everything — if the name says bookshop/gym/etc,
    # it's not a gig venue regardless of Google type.
    for cat, indicators in NON_VENUE_INDICATORS.items():
        if cat == 'spa':
            if re.search(r'\bspa\b', nl) and 'spanish' not in nl:
                primary = 'spa'
                confidence = 0.9
                source = 'name'
                break
            continue
        for ind in indicators:
            if ind in nl:
                primary = cat
                confidence = 0.9
                source = f'name:{ind}'
                break
        if primary:
            break

    # --- Phase 2: Specific types (name first, then Google type) ---
    if not primary:
        # Name-based detection (highest confidence)
        for cat, rules in SPECIFIC_TYPES.items():
            for pattern in rules.get('name', []):
                if pattern in nl:
                    primary = cat
                    confidence = 0.95
                    source = f'name:{pattern}'
                    break
            if primary:
                break

    if not primary:
        # Google category detection
        for cat, rules in SPECIFIC_TYPES.items():
            for pattern in rules.get('google', []):
                if pattern in cl:
                    primary = cat
                    confidence = 0.85
                    source = f'google:{pattern}'
                    break
            if primary:
                break

    # --- Phase 3: Hospitality types (only if nothing specific) ---
    if not primary:
        for cat, patterns in HOSPITALITY_TYPES.items():
            # Check Google type first
            for p in patterns:
                if p in cl:
                    primary = cat
                    confidence = 0.7
                    source = f'google:{p}'
                    break
            if primary:
                break
            # Then name
            for p in patterns:
                if p in nl:
                    primary = cat
                    confidence = 0.6
                    source = f'name:{p}'
                    break
            if primary:
                break

    # --- Phase 4: Unknown ---
    if not primary:
        primary = 'unknown'
        confidence = 0.3
        source = 'fallback'

    # --- Generate tags ---
    for tag, signals in TAG_SIGNALS.items():
        if tag == 'independent':
            continue
        for signal in signals:
            if signal in text:
                tags.append(tag)
                break

    # Independent tag: set if no chain/chain_hotel tag
    if 'chain' not in tags and 'chain_hotel' not in tags:
        tags.append('independent')

    # Music fit tag
    if primary in ('private_club', 'country_club', 'yacht_club'):
        tags.append('music_fit_high')
    elif primary in ('wine_bar', 'winery', 'hotel') and \
            'chain_hotel' not in tags:
        tags.append('music_fit_high')
    elif primary == 'restaurant' and any(
            t in tags for t in ['french', 'italian', 'spanish',
                                'european', 'fine_dining', 'upscale',
                                'intimate', 'historic']):
        tags.append('music_fit_high')
    elif primary == 'restaurant' and 'independent' in tags:
        tags.append('music_fit_medium')
    elif primary in ('art_gallery', 'museum', 'event_venue'):
        if 'events' in tags or 'live_music' in tags:
            tags.append('music_fit_medium')
        else:
            tags.append('music_fit_low')
    elif primary in ('recreation', 'theater', 'other', 'unknown',
                     'spa', 'bar', 'cafe'):
        tags.append('music_fit_low')

    return {
        'primary_category': primary,
        'venue_tags': tags,
        'classification_confidence': round(confidence, 2),
        'classification_source': source,
    }


def classify_simple(name='', google_category='', notes=''):
    """Return just the primary category string."""
    return classify(name, google_category, notes)['primary_category']


if __name__ == '__main__':
    import json, sys

    # Test cases
    tests = [
        ('Landini Brothers', 'restaurant', 'Italian fine dining'),
        ('Bistro Provence', 'restaurant', 'French bistro'),
        ('Chevy Chase Country Club', 'country club, restaurant', ''),
        ('Bards Alley Bookshop', 'restaurant, cafe', ''),
        ('Artists Atelier Working Studios', 'restaurant', ''),
        ('Arts Herndon', 'restaurant', ''),
        ('Dragon Boat Club', 'private club', ''),
        ('Belmont Country Club Maintenance', 'country club', ''),
        ('Mansion House Yacht Club', 'restaurant', ''),
        ("Hunter's Head Tavern", 'restaurant', 'Historic English pub'),
        ('Inn at Perry Cabin', 'hotel, restaurant', 'Luxury resort'),
        ('ENTYSE Wine Bar & Lounge', 'wine bar', ''),
        ('Stone Tower Winery', 'winery', 'vineyard tasting room'),
        ('Comfort Inn Alexandria', 'hotel', ''),
        ('246 Thai Street', 'restaurant', ''),
        ('801 Chophouse', 'restaurant', ''),
        ('X-Golf Annapolis', 'restaurant', ''),
        ('Fit Club Potomac', 'restaurant', ''),
        ('Phillips Collection', 'museum, restaurant', 'Concert series'),
        ('Dumbarton Oaks', 'museum', 'Music program'),
    ]

    print(f"{'Name':45s} {'Category':15s} {'Conf':5s} "
          f"{'Source':25s} Tags")
    print('-' * 130)
    for name, gcat, notes in tests:
        r = classify(name, gcat, notes)
        tag_str = ', '.join(r['venue_tags'][:6])
        print(f"{name:45s} {r['primary_category']:15s} "
              f"{r['classification_confidence']:4.2f}  "
              f"{r['classification_source']:25s} {tag_str}")
