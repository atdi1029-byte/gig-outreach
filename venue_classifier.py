#!/usr/bin/env python3
"""
Venue Classifier — single source of truth for venue classification.

Used by: discover.sh, build_batch.sh, rescore_pool.sh, quarantine_pool.sh,
backfill_websites.sh, taste_score.py, taste_review.py

Produces: primary_category, venue_tags, classification_confidence,
classification_source. Also owns the batch junk gate (junk_reason) and the
list of categories a batch may contain (TARGET_CATEGORIES).

Rules:
  - The sheet's own category slugs (country_club, private_club, wine_bar, ...)
    are read as categories, not ignored. A specific slug is authoritative unless
    the NAME carries a stronger identity or a hard non-venue signal.
  - Strong identities in the name (country club, resort, winery, museum, ...)
    beat generic types and "soft" non-venue words (University Club is a club,
    Academy Art Museum is a museum, Salamander Resort & Spa is a hotel).
  - All name matching is whole-word, so 'Omnivore' is not Omni, 'Barnes' is not
    a bar and 'Shoal Creek' is not an HOA.
  - Unknown is 'other', never 'restaurant' (P8).
"""
import re
import unicodedata


def _norm(s):
    s = unicodedata.normalize('NFKD', str(s or ''))
    s = ''.join(c for c in s if not unicodedata.combining(c))
    s = s.lower().replace('’', "'").replace('‘', "'").replace('`', "'")
    return re.sub(r'\s+', ' ', s).strip()


def _rx(words):
    """Whole-word alternation. A trailing '*' allows any word ending."""
    parts = []
    for w in words:
        if w.endswith('*'):
            parts.append(re.escape(w[:-1]) + r"[a-z']*")
        else:
            parts.append(re.escape(w))
    return re.compile(r"(?<![a-z0-9])(?:" + '|'.join(parts) + r")(?![a-z0-9])")


def _first(rx, text):
    m = rx.search(text)
    return m.group(0) if m else ''


# =========================================================
# SHEET CATEGORY SLUGS
# =========================================================
# slug -> classifier category. Specific slugs are trusted; generic ones
# (restaurant, bar, cafe, unknown, other) only fill in when nothing else fits,
# because legacy discovery defaulted everything to 'restaurant' and the Aug 23
# rescore rewrote some real categories to bar/unknown.
SLUG_MAP = {
    'country_club': 'country_club', 'golf_club': 'country_club',
    'private_club': 'private_club', 'yacht_club': 'yacht_club',
    'wine_bar': 'wine_bar', 'winery': 'winery',
    'hotel': 'hotel', 'resort': 'hotel', 'inn': 'hotel', 'bed_and_breakfast': 'hotel',
    'museum': 'museum', 'art_gallery': 'art_gallery', 'gallery': 'art_gallery',
    'event_venue': 'event_venue', 'event': 'event_venue', 'event_space': 'event_venue',
    'wedding_venue': 'event_venue', 'music_venue': 'music_venue',
    'tea_room': 'tea_room', 'library': 'library', 'church': 'church',
    'synagogue': 'synagogue', 'brewery': 'brewery', 'distillery': 'distillery',
    'spa': 'spa', 'theater': 'theater', 'recreation': 'recreation',
    'senior_living': 'senior_living', 'luxury_apts': 'luxury_apts',
    'luxury_apartments': 'luxury_apts', 'event_planner': 'event_planner',
    'luxury_retail': 'shopping', 'mall': 'shopping', 'grocery_market': 'shopping',
    'farmers_market': 'farmers_market', 'community_center': 'other',
    'funeral_home': 'other', 'cigar_lounge': 'bar', 'agent': 'other',
    'restaurant': 'restaurant', 'bar': 'bar', 'cafe': 'cafe',
    'unknown': 'other', 'other': 'other',
}
GENERIC_SLUGS = {'restaurant', 'bar', 'cafe', 'unknown', 'other', 'spa', 'event'}
# The type code in a venue_id (MD-COUN-1324) records the category the venue was
# discovered as. It recovers rows whose category cell was later overwritten with
# a generic value (the Aug 23 rescore turned clubs into 'unknown', wine bars into
# 'bar', 'Hotel & Spa' rows into 'spa'). Only used when the cell is generic.
ID_CODE_MAP = {
    'COUN': 'country_club', 'GOLF': 'country_club', 'PRIV': 'private_club',
    'CLUB': 'private_club', 'YACH': 'yacht_club', 'WINE': 'wine_bar',
    'HOTE': 'hotel', 'BOUT': 'hotel', 'HIST': 'hotel', 'MUSE': 'museum',
    'GALL': 'art_gallery', 'MUSI': 'music_venue', 'EVEN': 'event_venue',
    'WEDD': 'event_venue', 'CHUR': 'church', 'SYNA': 'synagogue', 'LIBR': 'library',
    'SENI': 'senior_living', 'RETI': 'senior_living', 'THEA': 'theater',
}

# Categories a pipeline batch may contain (build_batch, quarantine_pool and
# backfill_websites all read this one list).
TARGET_CATEGORIES = {
    'restaurant', 'hotel', 'winery', 'wine_bar', 'country_club', 'private_club',
    'yacht_club', 'art_gallery', 'museum', 'event_venue', 'music_venue',
    'tea_room',
}

# =========================================================
# HARD NON-VENUE (beats every identity: "Belmont Country Club Maintenance")
# =========================================================
HARD_NON_VENUE = {
    'recreation': _rx([
        'boat club', 'dragon boat', 'rowing', 'crew club', 'canoe club', 'kayak*',
        'paddl*', 'swim club', 'swim & tennis', 'swim and tennis', 'pool club',
        'tennis club', 'tennis', 'racquet club', 'gym', 'crossfit', 'fitness', 'yoga studio',
        'yoga', 'pilates', 'martial art*', 'boxing', 'karate', 'ice rink', 'skating',
        'bowling', 'arcade', 'trampoline', 'laser tag', 'escape room',
        'go kart*', 'go-kart*', 'paintball', 'axe throwing', 'golf simulator',
        'mini golf', 'minigolf', 'topgolf', 'x-golf', 'recreation center',
        'rec center', 'athletic club', 'athletic association', 'sports club',
        'sportsplex', 'fit club', 'golf course', 'driving range', 'five iron',
        'puttery', 'batting cage*', 'rifle', 'pistol', 'gun club', 'shooting',
        'dance hall', 'dance studio', 'dance school',
        'archery', 'equestrian center', 'riding stable*',
    ]),
    'theater': _rx([
        'theater', 'theatre', 'cinema', 'cinemas', 'playhouse', 'movie*',
        'performing arts center', 'comedy club', 'improv',
    ]),
    'other': _rx([
        'bookshop', 'bookstore', 'book shop', 'book store', 'books',
        'barnes & noble', 'barnes and noble', 'maintenance', 'hoa', 'homeowner*',
        'property management', 'leasing office', 'condominium*', 'insurance',
        'dental', 'dentist*', 'medical', 'clinic', 'hospital', 'veterinar*',
        'animal hospital', 'auto repair', 'auto body', 'auto sales', 'car wash',
        'tire', 'tires', 'storage', 'plumb*', 'electrician*', 'landscap*',
        'roofing', 'hvac', 'pest control', 'grocery', 'supermarket',
        'convenience store', 'neighborhood market', 'dry clean*', 'laundr*',
        'laundromat', 'tailor*', 'nail salon', 'nails', 'hair salon', 'salon',
        'barber*', 'beauty', 'lash', 'lashes', 'brow bar', 'brows', 'brow studio',
        'brow lounge', 'drybar', 'blow dry',
        'blowout', 'waxing', 'lingerie', 'clothing', 'retail store', 'dollar',
        'thrift', 'pawn', 'daycare', 'day care', 'preschool', 'montessori',
        'tutoring', 'nursing home', 'assisted living', 'memory care',
        'funeral*', 'cemetery', 'photographer*', 'photography', 'florist*',
        'bridal shop', 'printing', 'real estate', 'realty', 'pharmacy',
        'food truck', 'food court', 'flea market', 'farm stand', 'liquor*',
        'wine & spirits', 'wine and spirits', 'wine shop', 'wine store',
        'bottle shop', 'beer store', 'beer & wine', 'beer and wine', 'wine & beer',
        'wine and beer', 'beer wine',
    ]),
}
# Fraternal lodges: not hotels ("Masonic Lodge"), not private dining clubs.
FRATERNAL = _rx(['masonic', 'masons', 'elks', 'moose lodge', 'odd fellows', 'vfw',
                 'american legion', 'knights of columbus', 'lions club', 'rotary',
                 'kiwanis', 'grange'])
# Soft non-venue: loses to a strong identity ('University Club', 'Academy Art Museum').
SOFT_NON_VENUE = _rx(['school', 'academy', 'university', 'college', 'seminary'])
# "X Social Club" is almost always a bar or nightlife (Tabu Social Club), not a
# members' club, even when discovery stamped it private_club.
SOCIAL_CLUB = _rx(['social club'])
SUPPER_CLUB = _rx(['supper club'])
# 'Szechuan Inn', 'Pizza House': a casual restaurant, not an inn.
CASUAL_CUISINE = _rx(['szechuan', 'sichuan', 'hunan', 'chinese', 'china', 'peking', 'wok',
                      'thai', 'sushi', 'ramen', 'pho', 'noodle*', 'dumpling*', 'pizza',
                      'pizzeria', 'taqueria', 'taco', 'tacos', 'burger*', 'bbq', 'barbecue',
                      'kabob', 'kebab', 'curry', 'crab house', 'crab shack', 'wings',
                      'hibachi', 'teriyaki', 'deli', 'diner', 'buffet'])
# A restaurant-slug row named 'Cafe Milano' or 'King Street Oyster Bar' is still a
# restaurant; only coffee/bakery words make it a cafe.
CAFE_STRICT = _rx(['coffee', 'coffeehouse', 'bakery', 'bakeshop', 'patisserie',
                   'roaster*', 'tea room', 'tea house', 'espresso'])
SENIOR = _rx(['senior living', 'retirement', 'retirement community', 'life plan community'])
SPA_WORD = _rx(['spa', 'day spa', 'med spa', 'medspa'])
# Place names that contain venue words.
FALSE_PLACE = _rx(['falls church', 'church hill', 'church creek', 'church point',
                   'chapel hill', 'churchill', 'spa creek', 'spa road', 'college park',
                   'university park', 'university blvd', 'academy street', 'school street',
                   'inn street'])

# =========================================================
# STRONG NAME IDENTITIES (first match wins; order matters)
# =========================================================
NAME_IDENTITY = [
    ('country_club', _rx(['country club', 'golf & country', 'golf and country',
                          'golf club', 'hunt club', 'field club', 'cricket club'])),
    ('yacht_club', _rx(['yacht club', 'yacht', 'sailing club'])),
    ('private_club', _rx(['city club', 'town club', 'cosmos club', 'university club',
                          'army navy club', 'army and navy club', 'metropolitan club',
                          'sulgrave club',
                          'athenaeum', 'democratic club',
                          'republican club', 'circle club', 'tower club',
                          'union league', 'arts club', 'the maryland club',
                          'faculty club', 'capitol hill club'])),
    ('winery', _rx(['winery', 'wineries', 'vineyard', 'vineyards', 'vintner*',
                    'cellars', 'winecellars', 'viticulture', 'wine estate'])),
    ('wine_bar', _rx(['wine bar', 'wine lounge', 'wine room', 'wine garden',
                      'winegarden', 'wine cellar', 'wine kitchen', 'enoteca',
                      'vinoteca', 'bar a vin', 'bar a vins', 'wine & tapas',
                      'wine and tapas'])),
    ('hotel', _rx(['hotel', 'hotels', 'inn', 'resort', 'resorts', 'lodge', 'suites',
                   'bed & breakfast', 'bed and breakfast', 'b&b', 'b & b',
                   'guest house', 'guesthouse', 'motel', 'waldorf', 'conrad',
                   'sofitel', 'pendry', 'salamander', 'rosewood', 'ritz-carlton',
                   'ritz carlton', 'four seasons', 'fairmont', 'mandarin oriental',
                   'st. regis', 'st regis', 'westin', 'hyatt', 'marriott', 'hilton',
                   'intercontinental', 'kimpton', 'the peninsula', 'langham', 'omni',
                   'loews', 'crowne plaza', 'radisson', 'doubletree', 'sonesta',
                   'the line dc', 'the line hotel', 'the jefferson', 'the lyle',
                   'hay-adams', 'hay adams', 'watergate', 'willard'])),
    ('museum', _rx(['museum', 'museums'])),
    ('art_gallery', _rx(['gallery', 'galleries', 'arts center', 'art center',
                         'arts council', 'arts commission', 'arts foundation',
                         'arts alliance', 'arts district', 'arts association',
                         'art institute', 'art association', 'art league', 'atelier',
                         'working artists'])),
    ('music_venue', _rx(['music hall', 'jazz club', 'concert hall', 'music venue',
                         'listening room', 'music center'])),
    ('brewery', _rx(['brewery', 'breweries', 'brewing', 'brewpub', 'brew pub',
                     'brewhouse', 'taproom'])),
    ('distillery', _rx(['distillery', 'distilling', 'distiller*', 'cidery'])),
    # Women's/civic clubs rent their clubhouse for events; not members' dining clubs.
    ('event_venue', _rx(["women's club", "woman's club", 'womans club', 'womens club',
                         'mansion', 'manor', 'pavilion', 'ballroom', 'banquet hall',
                         'event space', 'event center', 'event venue', 'events venue',
                         'conference center', 'estate'])),
]

# Google Maps types (from the category cell when it isn't a slug, or from
# "Google Maps '<type>'" in notes).
GOOGLE_IDENTITY = [
    ('country_club', _rx(['country club', 'golf club'])),
    ('private_club', _rx(['private club'])),
    ('yacht_club', _rx(['yacht club', 'yacht', 'sailing club'])),
    ('hotel', _rx(['hotel', 'inn', 'resort', 'resort hotel', 'lodge', 'motel',
                   'bed & breakfast', 'bed and breakfast', 'guest house', 'hostel'])),
    ('winery', _rx(['winery', 'vineyard'])),
    ('wine_bar', _rx(['wine bar'])),
    ('brewery', _rx(['brewery', 'brewpub'])),
    ('distillery', _rx(['distillery', 'cidery'])),
    ('museum', _rx(['museum'])),
    ('art_gallery', _rx(['art gallery', 'gallery', 'art center'])),
    ('music_venue', _rx(['live music venue', 'music venue', 'jazz club', 'concert hall'])),
    ('event_venue', _rx(['event venue', 'banquet hall', 'wedding venue', 'event space',
                         'function room facility', 'conference center'])),
    ('tea_room', _rx(['tea room', 'tea house'])),
]

HOSPITALITY = [
    ('restaurant', _rx(['restaurant', 'restaurants', 'fine dining', 'steakhouse',
                        'steak house', 'brasserie', 'bistro', 'bistrot', 'trattoria',
                        'osteria', 'ristorante', 'chophouse', 'tavern', 'grill', 'grille',
                        'kitchen', 'eatery', 'dining', 'cuisine', 'creperie',
                        'taverna', 'cocina', 'tapas', 'churrascaria', 'oyster house',
                        'crab house', 'seafood', 'diner'])),
    ('bar', _rx(['bar', 'pub', 'gastropub', 'lounge', 'saloon', 'speakeasy',
                 'cocktail*'])),
    ('cafe', _rx(['cafe', 'coffee', 'coffeehouse', 'tea room', 'tea house',
                  'patisserie', 'bakery', 'bakeshop'])),
]

# =========================================================
# VENUE TAGS
# =========================================================
TAG_SIGNALS = {
    'french': _rx(['french', 'bistro', 'bistrot', 'brasserie', 'provenc*', 'lyonnais*',
                   'parisian', 'creperie', 'normandy', 'bordeaux', 'burgundy']),
    'italian': _rx(['italian', 'italia', 'trattoria', 'osteria', 'ristorante', 'enoteca',
                    'tuscan', 'toscana', 'sicilian', 'piedmont*']),
    'spanish': _rx(['spanish', 'spain', 'tapas', 'barcelona', 'paella*', 'basque',
                    'catalan', 'andalu*', 'sevilla', 'seville', 'madrid', 'jaleo',
                    'taberna']),
    'european': _rx(['european', 'mediterranean', 'portuguese', 'greek', 'belgian',
                     'austrian', 'viennese', 'swiss', 'german', 'bavarian']),
    'latin_american': _rx(['argentin*', 'brazilian', 'peruvian', 'latin', 'latino',
                           'churrascaria', 'cocina', 'colombian', 'chilean']),
    'fine_dining': _rx(['fine dining', 'prix fixe', 'tasting menu', 'white tablecloth',
                        'michelin', 'chef-driven', 'chef driven']),
    'upscale': _rx(['upscale', 'luxury', 'luxurious', 'elegant', 'refined',
                    'sophisticated', 'five-star', 'five star', '5-star', 'forbes']),
    'historic': _rx(['historic', 'colonial', 'victorian', 'antique', 'heritage',
                     'circa 1*', 'since 1*', 'founded 1*', 'est. 1*', 'est 1*', '18th century',
                     '19th century']),
    'intimate': _rx(['intimate', 'cozy', 'charming', 'boutique', 'quaint', 'romantic']),
    'waterfront': _rx(['waterfront', 'harbor', 'harbour', 'wharf', 'marina', 'seaside',
                       'bayfront', 'lakefront', 'riverfront']),
    'dining': _rx(['restaurant', 'dining', 'dinner', 'brunch', 'lunch']),
    'events': _rx(['event', 'events', 'private event*', 'reception*', 'gala', 'banquet*',
                   'wedding*', 'catering', 'venue rental']),
    'live_music': _rx(['live music', 'live entertainment', 'concert*', 'music program',
                       'music series', 'acoustic', 'jazz', 'classical', 'chamber music']),
    'chain': _rx(['founding farmers', 'cava', 'sweetgreen', 'nandos', "nando's",
                  'cheesecake factory', 'capital grille', "ruth's chris", 'ruths chris',
                  "morton's", 'mortons', "fleming's", 'flemings', 'olive garden',
                  'red lobster', 'outback', "applebee's", 'applebees', "chili's", 'chilis',
                  'tgi friday*', 'panera', 'starbucks', 'dunkin', 'five guys',
                  'shake shack', 'buffalo wild wings', 'paris baguette', 'la madeleine',
                  "maggiano's", 'maggianos', "mccormick & schmick's", 'mccormick and schmick',
                  'seasons 52', "del frisco's", "sullivan's steakhouse", 'silver diner',
                  'ihop', "denny's", 'cracker barrel', 'texas roadhouse', 'longhorn',
                  'ruby tuesday', 'red robin', 'hooters', 'twin peaks', 'yard house',
                  'bonefish grill', "carrabba's", "p.f. chang's", 'pf changs',
                  'fogo de chao', 'travinia', 'kona grill', "eddie v's", 'ocean prime',
                  "bj's restaurant", 'chart house', "ted's montana", 'cheddars',
                  "o'charley's", 'mission bbq', 'dog haus', 'glory days grill',
                  'lebanese taverna', 'chima steakhouse', "clyde's", "ted's bulletin",
                  'matchbox', 'busboys and poets', "carmine's", 'rosa mexicano',
                  'il fornaio', 'true food kitchen', 'cooper\'s hawk', 'coopers hawk',
                  'first watch', 'le pain quotidien', 'paul bakery', "bonchon",
                  '801 chophouse', 'capital grille', 'chart house',
                  'silver new american', "guapo's", 'guapos']),
    'chain_hotel': _rx([
        'doubletree', 'holiday inn', 'best western', 'comfort inn', 'comfort suites',
        'hampton inn', 'courtyard by', 'courtyard marriott', 'fairfield inn',
        'residence inn', 'springhill', 'la quinta', 'super 8', 'days inn', 'motel 6',
        'red roof', 'quality inn', 'sleep inn', 'embassy suites', 'homewood suites',
        'home2 suites', 'crowne plaza', 'radisson', 'wyndham', 'extended stay',
        'sonesta simply', 'sonesta es', 'simply suites', 'woodspring', 'candlewood',
        'staybridge', 'towneplace', 'hyatt place', 'hyatt house', 'hilton garden',
        'tru by hilton', 'aloft', 'element by westin', 'studio 6', 'intown suites',
        'homestead studio', 'econo lodge', 'rodeway', 'travelodge', 'knights inn',
        "america's best value", 'americas best value', 'baymont', 'microtel',
        'howard johnson', 'ramada', 'budget inn', 'motor inn', 'motor lodge',
        'red carpet inn', 'super 8', 'cambria hotel', 'avid hotel', 'my place hotel',
        'mainstay suites', 'suburban studios', 'wingate', 'country inn & suites',
        'country inn and suites', 'four points', 'ac hotel', 'moxy', 'even hotel',
        'holiday inn express', 'sonesta select']),
    'independent': None,
}
# Mainstream brands are chains ("no decision-maker, corporate booking"), but
# their luxury sub-brands are exactly what Alex hunts for.
MAINSTREAM_HOTEL = _rx(['marriott', 'hilton', 'hyatt', 'sheraton', 'westin', 'renaissance',
                        'omni', 'loews', 'le meridien', 'hotel indigo', 'wyndham',
                        'best western', 'sonesta', 'hotel harrington', 'club quarters',
                        'graduate hotel', 'canopy by hilton', 'tapestry collection', 'gaylord'])
LUXURY_BRAND = _rx(['ritz-carlton', 'ritz carlton', 'st. regis', 'st regis', 'park hyatt',
                    'conrad', 'waldorf', 'four seasons', 'rosewood', 'fairmont',
                    'mandarin oriental', 'kimpton', 'pendry', 'sofitel', 'intercontinental',
                    'jw marriott', 'edition', 'the luxury collection', 'salamander'])


def _is_chain_hotel(nl):
    if TAG_SIGNALS['chain_hotel'].search(nl):
        return True
    return bool(MAINSTREAM_HOTEL.search(nl)) and not LUXURY_BRAND.search(nl)


def _name_identity(nl):
    for cat, rx in NAME_IDENTITY:
        if rx.search(nl):
            return cat
    return ''

LUXURY_HOTEL = _rx(['waldorf', 'conrad', 'sofitel', 'pendry', 'salamander', 'rosewood',
                    'ritz-carlton', 'ritz carlton', 'four seasons', 'fairmont',
                    'mandarin oriental', 'st. regis', 'st regis', 'the peninsula',
                    'langham', 'kimpton', 'intercontinental', 'park hyatt', 'hay-adams',
                    'hay adams', 'willard', 'the jefferson', 'watergate', 'resort',
                    'inn at', 'manor', 'boutique', 'historic', 'bed & breakfast',
                    'bed and breakfast', 'b&b', 'relais', 'chateau', 'estate', 'spa',
                    'the georgetown inn', 'morrison-clark', 'perry cabin', 'tidewater inn',
                    'the inn', 'house hotel', 'country inn', 'farm'])
# 'Bollywood Bistro', 'Royal Nepal Bistro': 'bistro' alone isn't French.
NON_EURO_CUISINE = _rx(['indian', 'bollywood', 'nepal*', 'himalayan', 'tandoor*', 'curry',
                        'thai', 'asian', 'chinese', 'szechuan', 'japanese', 'sushi', 'ramen',
                        'korean', 'vietnamese', 'pho', 'mexican', 'tex-mex', 'taco*', 'cajun',
                        'caribbean', 'jamaican', 'ethiopian', 'soul food', 'bbq', 'burger*',
                        'pizza', 'hibachi', 'teriyaki', 'filipino', 'pakistani', 'afghan', 'persian',
                        'kabob*', 'kebab*'])
EURO_TAGS = ('french', 'italian', 'spanish', 'european', 'latin_american')
PRIME_RESTAURANT_TAGS = ('french', 'italian', 'spanish', 'european', 'latin_american',
                         'fine_dining', 'upscale', 'intimate', 'historic')

# =========================================================
# BATCH JUNK GATE
# =========================================================
_JUNK = [
    ('motel/budget/extended-stay chain', TAG_SIGNALS['chain_hotel']),
    ('motel', _rx(['motel', 'motels', 'motor inn', 'motor lodge', 'economy inn',
                   'budget inn'])),
    ('vacation rental', _rx(['airbnb', 'vrbo', 'kasa', 'sonder', 'self check-in',
                             'self check in', 'vacation rental*', 'short-term rental*',
                             'short term rental*', 'rental home', 'cottage rental*',
                             'guest suite', 'homestay'])),
    ('adult/nightlife', _rx(['swinger*', 'sex club', 'lifestyle club', 'adult club',
                             'adult entertainment', "gentlemen's club", 'gentlemens club',
                             'strip club', 'erotic', 'nightclub', 'night club',
                             'dance club', 'hookah', 'karaoke', 'sports bar',
                             'sports grill', 'sports pub', 'go-go', 'cabaret'])),
    ('fast food / chain', _rx([
        "mcdonald's", 'mcdonalds', 'burger king', "wendy's", 'taco bell', 'kfc',
        'popeyes', 'chick-fil-a', 'subway', "jersey mike's", "jimmy john's",
        'chipotle', 'qdoba', "domino's", 'dominos', 'pizza hut', "papa john's",
        'little caesars', 'wingstop', "arby's", 'dairy queen', 'sonic drive',
        '7-eleven', 'wawa', 'sheetz', 'fast food', 'drive-thru', 'drive thru',
        'food truck', 'food court', 'hot dog*', 'fried chicken', 'wings',
        'pizza delivery', 'sub shop', 'deli & market', 'bagel*', 'donut*',
        'doughnut*', 'ice cream', 'frozen yogurt', 'froyo', 'boba', 'bubble tea',
        'smoothie*', 'juice bar'])),
    ('boating business', _rx(['yacht management', 'boat rental*', 'yacht rental*',
                              'yacht charter*', 'boat charter*', 'charters', 'yacht sales',
                              'yacht brokerage', 'boat sales', 'cruises', 'boat tours',
                              'marine services', 'boatyard', 'boat yard'])),
    ('residential/HOA', _rx(['hoa', 'homeowners', 'homeowner association',
                             'community association', 'civic association',
                             'condominium*', 'apartments', 'apartment homes',
                             'residents club', 'clubhouse rental'])),
]
_CLOSED = re.compile(r"permanently closed|closed permanently|temporarily closed|"
                     r"no longer open|out of business|closed in 20\d\d|closed \(20\d\d|"
                     r"pipeline_flag|\bclosed\b[^.]{0,20}\b20[12]\d\b|site dead|dead website")
# Casual/fast-casual food in the site's own domain (rabbittaco.com).
_CASUAL_HOST = re.compile(r"taco|burger|wings|pizza|subs$|hotdog|chicken|bbq|smokehouse|"
                          r"noodle|ramen|sushi|bagel|donut|creamery")
_RATING = re.compile(r"(\d(?:\.\d)?)\s*[*\u2605]\s*\((\d+)\s*reviews?\)")
_JUNK_HOSTS = re.compile(r"(^|\.)(airbnb\.[a-z.]+|vrbo\.com|booking\.com|expedia\.com|"
                         r"hotels\.com|tripadvisor\.[a-z.]+|yelp\.com|facebook\.com|"
                         r"instagram\.com)$")


def clean_notes(notes):
    """Notes minus provenance text, so a discovery query ('Taste query: luxury
    hotel McLean VA') can't add keywords or tags the venue never showed."""
    t = str(notes or '')
    t = re.sub(r"(?i)\b(taste query|discovered from|pre-score|maps coords|source)\s*:[^.\n]*\.?", ' ', t)
    t = re.sub(r"(?i)google maps\s*'([^']*)'\.?", r" \1 ", t)
    t = re.sub(r"(?i)\bprice:\s*(n/a)?", ' ', t)
    return re.sub(r'\s+', ' ', t).strip()


def google_types(google_category='', notes=''):
    """Google Maps type text from the category cell (if it isn't a bare slug)
    and from "Google Maps '<type>'" in notes."""
    out = []
    cl = _norm(google_category)
    if cl:
        out.append(cl.replace('_', ' '))
    for m in re.finditer(r"google maps\s*'([^']+)'", _norm(notes)):
        out.append(m.group(1))
    return ' | '.join(out)


def _host(website):
    w = _norm(website)
    w = re.sub(r'^[a-z]+://', '', w).split('/')[0].split(':')[0]
    return w[4:] if w.startswith('www.') else w


def google_rating(notes=''):
    """(rating, reviews) from discovery notes ("4.6* (223 reviews)"), else (None, 0)."""
    m = _RATING.search(str(notes or ''))
    if not m:
        return None, 0
    try:
        r = float(m.group(1))
    except ValueError:
        return None, 0
    return (r if 0 < r <= 5 else None), int(m.group(2))


def junk_reason(name='', google_category='', notes='', website='', check_status=''):
    """Why this venue must never be batched ('' = not junk). Motels and
    budget/extended-stay chains, vacation rentals, closed venues, adult/nightlife,
    fast food and chains, HOAs/residential, badly rated places."""
    nl = ' ' + _norm(name) + ' '
    gt = google_types(google_category, notes)
    hay = nl + ' | ' + gt
    ident = _name_identity(' ' + FALSE_PLACE.sub(' ', nl) + ' ')
    for why, rx in _JUNK:
        if rx is TAG_SIGNALS['chain_hotel'] and ident not in ('hotel', ''):
            continue    # 'Hilton Farm Winery' is a winery
        hit = _first(rx, hay)
        if hit:
            return f'{why} ({hit})'
    if ident in ('hotel', '') and MAINSTREAM_HOTEL.search(nl) and not LUXURY_BRAND.search(nl):
        return f'chain hotel ({_first(MAINSTREAM_HOTEL, nl)})'
    hit = _first(TAG_SIGNALS['chain'], nl)
    if hit:
        return f'chain ({hit})'
    # Free-text notes (manual checks, sweeps) only gate on unambiguous words.
    nc = ' ' + _norm(clean_notes(notes)) + ' '
    for why, rx in _JUNK:
        if why in ('adult/nightlife', 'vacation rental'):
            hit = _first(rx, nc)
            if hit:
                return f'{why} (notes: {hit})'
    m = _CLOSED.search(_norm(notes) + ' ' + _norm(check_status))
    if m:
        return f'closed/flagged ({m.group(0)[:30]})'
    host = _host(website)
    if host and _JUNK_HOSTS.search(host):
        return f'non-venue website ({host})'
    label = host.split('.')[-2] if host.count('.') >= 1 else host
    m = _CASUAL_HOST.search(label or '')
    if m:
        return f'casual food ({host})'
    rating, reviews = google_rating(notes)
    if rating is not None and rating < 3.8 and reviews >= 20:
        return f'low Google rating ({rating}, {reviews} reviews)'
    return ''


_PLAIN_HOTEL = _rx(['hotel', 'motel', 'suites', 'lodge', 'express', 'extended'])


def _luxury_hotel(nl, text, tags):
    if LUXURY_HOTEL.search(nl) or any(
            t in tags for t in ('upscale', 'historic', 'intimate', 'fine_dining')):
        return True
    # Independent inns here are nearly all historic/boutique (chains and motels
    # are caught by chain_hotel / the junk gate); 'Moon Inn Hotel' is not.
    return bool(re.search(r'(?<![a-z])inn(?![a-z])', nl)) and not _PLAIN_HOTEL.search(nl)


def classify(name='', google_category='', notes='', website='', venue_id=''):
    """Classify a venue.

    Args:
        name: venue name
        google_category: the sheet's category slug or a Google Maps type string
        notes: notes (discovery provenance is ignored)
        website: website URL (unused for now; kept for callers)
        venue_id: optional; its type code backs up a generic category cell

    Returns dict: primary_category, venue_tags, classification_confidence,
    classification_source.
    """
    nl = ' ' + _norm(name) + ' '
    nl_id = ' ' + FALSE_PLACE.sub(' ', nl) + ' '
    raw_cat = _norm(google_category)
    slug = raw_cat.replace(' ', '_').replace('-', '_') if re.fullmatch(r'[a-z_ -]+', raw_cat or '-') else ''
    if slug not in SLUG_MAP:
        slug = ''
    gt = google_types('' if slug else google_category, notes)
    notes_c = _norm(clean_notes(notes))
    text = nl + ' ' + notes_c

    primary, confidence, source = None, 0.0, ''

    # 1. Hard non-venue in the name or Google type.
    for cat, rx in HARD_NON_VENUE.items():
        hit = _first(rx, nl_id) or _first(rx, gt)
        if hit:
            primary, confidence, source = cat, 0.9, f'nonvenue:{hit}'
            break
    if not primary:
        hit = _first(FRATERNAL, nl_id) or _first(_rx(['fraternal']), gt)
        if hit:
            primary, confidence, source = 'other', 0.9, f'fraternal:{hit}'

    # 2. Strong identity in the name.
    if not primary:
        hit = _first(CASUAL_CUISINE, nl_id)
        if hit and not _first(NAME_IDENTITY[3][1], nl_id):   # a winery named 'Pizza..' stays a winery
            primary, confidence, source = 'restaurant', 0.8, f'name:{hit}'
    if not primary:
        for cat, rx in NAME_IDENTITY:
            hit = _first(rx, nl_id)
            if hit:
                primary, confidence, source = cat, 0.95, f'name:{hit}'
                break

    # 3. Soft non-venue words (only when the name has no strong identity).
    if not primary:
        hit = _first(SOFT_NON_VENUE, nl_id)
        if hit:
            primary, confidence, source = 'other', 0.85, f'nonvenue:{hit}'
        elif _first(SOCIAL_CLUB, nl_id):
            primary, confidence, source = 'bar', 0.6, 'name:social club'
        elif _first(SUPPER_CLUB, nl_id):
            primary, confidence, source = 'restaurant', 0.7, 'name:supper club'
        elif _first(SENIOR, nl_id):
            primary, confidence, source = 'senior_living', 0.85, 'name:senior'
        elif _first(SPA_WORD, nl_id) and slug not in ('hotel', 'resort'):
            primary, confidence, source = 'spa', 0.85, 'name:spa'

    # 4. The sheet's own specific slug.
    if not primary and slug and slug not in GENERIC_SLUGS:
        primary, confidence, source = SLUG_MAP[slug], 0.9, f'sheet:{slug}'
    if not primary and (not slug or slug in GENERIC_SLUGS):
        m = re.match(r'^[A-Za-z]{2}-([A-Za-z]+)-\d+$', str(venue_id or '').strip())
        code = m.group(1).upper() if m else ''
        if code in ID_CODE_MAP and not (code == 'HOTE' and slug == 'restaurant'):
            primary, confidence, source = ID_CODE_MAP[code], 0.8, f'id:{code}'

    # 5. Google type text.
    if not primary and gt:
        for cat, rx in GOOGLE_IDENTITY:
            hit = _first(rx, gt)
            if hit:
                primary, confidence, source = cat, 0.85, f'google:{hit}'
                break

    # 6. Hospitality: Google type, then name, then the generic sheet slug.
    if not primary:
        for cat, rx in HOSPITALITY:
            hit = _first(rx, gt)
            if hit:
                primary, confidence, source = cat, 0.7, f'google:{hit}'
                break
    if not primary:
        for cat, rx in HOSPITALITY:
            hit = _first(rx, nl_id)
            if hit:
                if slug == 'restaurant' and cat != 'restaurant' and not _first(CAFE_STRICT, nl_id):
                    primary, confidence, source = 'restaurant', 0.65, 'sheet:restaurant'
                else:
                    primary, confidence, source = cat, 0.6, f'name:{hit}'
                break
    if not primary and slug in ('restaurant', 'bar', 'cafe', 'spa'):
        primary, confidence, source = SLUG_MAP[slug], 0.6, f'sheet:{slug}'
    if not primary and slug == 'event':
        primary, confidence, source = 'event_venue', 0.6, 'sheet:event'

    # 7. Unknown is 'other' (P8).
    if not primary:
        primary, confidence, source = 'other', 0.3, 'fallback'

    # --- Tags ---
    tags = []
    for tag, rx in TAG_SIGNALS.items():
        if rx is None or tag == 'chain_hotel':
            continue
        hay = nl if tag == 'chain' else text + ' ' + gt
        if rx.search(hay):
            tags.append(tag)
    if primary == 'hotel' and _is_chain_hotel(nl):
        tags.append('chain_hotel')
    # French articles only count in the venue's own name.
    if 'french' in tags and NON_EURO_CUISINE.search(nl) and \
            not re.search(r'(?<![a-z])french(?![a-z])', text):
        tags.remove('french')
    if primary in ('restaurant', 'wine_bar', 'bar', 'cafe', 'hotel'):
        if 'french' not in tags and re.search(r"(?<![a-z])(?:(?:chez|le|les|aux|du)\s+|l')[a-z]", nl):
            tags.append('french')
        elif not any(t in tags for t in ('french', 'italian', 'spanish', 'european')) and \
                re.match(r"\s*(the\s+)?(la|il)\s+[a-z]", nl):
            tags.append('european')
    if 'chain' not in tags and 'chain_hotel' not in tags:
        tags.append('independent')
    if primary == 'hotel' and 'chain_hotel' not in tags and _luxury_hotel(nl, text, tags):
        tags.append('luxury_hotel')

    # Music fit
    if primary in ('private_club', 'country_club', 'yacht_club', 'wine_bar', 'winery'):
        tags.append('music_fit_high')
    elif primary == 'hotel':
        if 'luxury_hotel' in tags:
            tags.append('music_fit_high')
        elif 'chain_hotel' in tags:
            tags.append('music_fit_low')
        else:
            tags.append('music_fit_medium')
    elif primary == 'restaurant' and any(t in tags for t in PRIME_RESTAURANT_TAGS) and (
            any(t in tags for t in EURO_TAGS) or not NON_EURO_CUISINE.search(text)):
        # 'Upscale Indian fusion' is a nice restaurant, not Alex's French/European target.
        tags.append('music_fit_high')
    elif primary == 'restaurant' and 'independent' in tags:
        tags.append('music_fit_medium')
    elif primary in ('art_gallery', 'museum', 'event_venue', 'music_venue', 'tea_room'):
        if 'events' in tags or 'live_music' in tags or primary == 'music_venue':
            tags.append('music_fit_medium')
        else:
            tags.append('music_fit_low')
    else:
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


# (name, category/google type, notes, expected primary, required tag or '')
REGRESSION_CASES = [
    ('Landini Brothers', 'restaurant', 'Italian fine dining', 'restaurant', 'music_fit_high'),
    ('Bistro Provence', 'restaurant', 'French bistro', 'restaurant', 'french'),
    ('Chevy Chase Country Club', 'country club, restaurant', '', 'country_club', ''),
    ('Chevy Chase Club', 'country_club', '', 'country_club', 'music_fit_high'),
    ('Sulgrave Club', 'private_club', '', 'private_club', ''),
    ('The Army and Navy Club', 'private_club', '', 'private_club', ''),
    ('Vinoteca', 'wine_bar', '', 'wine_bar', ''),
    ('Strathmore', 'music_venue', '', 'music_venue', ''),
    ('University Club', 'private_club', '', 'private_club', 'music_fit_high'),
    ('Academy Art Museum', 'museum', '', 'museum', ''),
    ('Old Schoolhouse Restaurant', 'restaurant', '', 'restaurant', ''),
    ('Hospitality House', 'hotel', '', 'hotel', ''),
    ('Salamander Resort & Spa', 'hotel', '', 'hotel', 'luxury_hotel'),
    ('Lansdowne Resort and Spa', 'spa', '', 'hotel', ''),
    ('Caves Valley Golf Club', 'country_club', '', 'country_club', ''),
    ('Growing Roots Farm Winery', 'winery', '', 'winery', ''),
    ('Shoal Creek Wine', 'wine_bar', '', 'wine_bar', ''),
    ('Bards Alley Bookshop', 'restaurant, cafe', '', 'other', ''),
    ('Barnes & Noble', 'bar', '', 'other', ''),
    ('Drybar', 'bar', '', 'other', ''),
    ('Brow Bar', 'bar', '', 'other', ''),
    ('The Lash Lounge', 'bar', '', 'other', ''),
    ('Dragon Boat Club', 'private club', '', 'recreation', ''),
    ('DC Dragon Boat Club', 'private_club', '', 'recreation', ''),
    ('Belmont Country Club Maintenance', 'country club', '', 'other', ''),
    ('Alexandria Masonic Lodge', 'private_club', '', 'other', ''),
    ('Omnivore', 'restaurant', '', 'restaurant', ''),
    ('Carlyle House', 'museum', '', 'museum', ''),
    ('Tabu Social Club', 'private_club', '', 'bar', ''),
    ('The Milton Inn', 'restaurant', '', 'hotel', 'luxury_hotel'),
    ('Moon Inn Hotel', 'hotel', '', 'hotel', 'music_fit_medium'),
    ('Elkridge Club', 'unknown', '', 'other', ''),
    ('Vin Sur Vingt', 'bar', '', 'bar', ''),
    ('Cafe du Parc', 'restaurant', '', 'restaurant', 'french'),
    ('King Street Oyster Bar', 'restaurant', '', 'restaurant', ''),
    ('Blue Heron Coffee', 'restaurant', '', 'cafe', ''),
    ('Mason Social', 'restaurant', '', 'restaurant', ''),
    ('Hunter\'s Head Tavern', 'restaurant', 'Historic English pub', 'restaurant', 'historic'),
    ('Inn at Perry Cabin', 'hotel, restaurant', 'Luxury resort', 'hotel', 'music_fit_high'),
    ('Comfort Inn Alexandria', 'hotel', '', 'hotel', 'chain_hotel'),
    ('Grand Hyatt Washington', 'hotel', '', 'hotel', 'chain_hotel'),
    ('Park Hyatt Washington', 'hotel', '', 'hotel', 'luxury_hotel'),
    ('The Ritz-Carlton, Tysons Corner', 'hotel', '', 'hotel', 'luxury_hotel'),
    ('Hilton Farm Winery', 'winery', '', 'winery', 'music_fit_high'),
    ('Budget Inn Falls Church', 'hotel', '', 'hotel', 'chain_hotel'),
    ('Sonesta Simply Suites Falls Church', 'hotel', '', 'hotel', 'chain_hotel'),
    ('El Pollo Rico', 'restaurant', "Google Maps 'Chicken restaurant'", 'restaurant', ''),
    ('Le Diplomate', 'restaurant', '', 'restaurant', 'french'),
    ('Maison Bar a Vins', 'bar', '', 'wine_bar', ''),
    ('Some Place', 'restaurant', "Google Maps 'French restaurant'", 'restaurant', 'french'),
    ('Wedding photographer', 'wedding venue', '', 'other', ''),
    ('St. Albans School', 'event_venue', '', 'other', ''),
    ('Phillips Collection', 'museum, restaurant', 'Concert series', 'museum', 'live_music'),
    ('Big Cork Vineyards', 'winery', '', 'winery', 'music_fit_high'),
    ('Mystery Venue', '', '', 'other', ''),
    ("Lance's Beer & Wine", 'bar', '', 'other', ''),
    ('La Chaumiere', 'restaurant', '', 'restaurant', 'european'),
    ('El Pollo Rico', 'restaurant', '', 'restaurant', 'music_fit_medium'),
    ('Szechuan Inn', 'hotel', '', 'restaurant', ''),
    ('Bollywood Bistro', 'restaurant', '', 'restaurant', 'music_fit_medium'),
    ('Royal Nepal Bistro', 'restaurant', '', 'restaurant', 'music_fit_medium'),
    ('Bollywood Bistro', 'restaurant', 'Upscale Indian fusion', 'restaurant', 'music_fit_medium'),
    ('Kazan Restaurant', 'restaurant', 'Turkish fine dining since 1980', 'restaurant', 'music_fit_high'),
    ('Cliff Drysdale Tennis at Inn at Perry Cabin', 'hotel', '', 'recreation', ''),
    ('MUI Supper Club', 'private_club', '', 'restaurant', ''),
    ('Level A Small Plates Lounge', 'bar', '', 'bar', 'music_fit_low'),
]
# (name, category, notes, website, junk expected?)
JUNK_CASES = [
    ('Budget Inn Falls Church', 'hotel', '', '', True),
    ('Moon Inn Motel', 'hotel', '', '', True),
    ('Sonesta Simply Suites', 'hotel', '', '', True),
    ('Tabu Social Club', 'private_club', 'swingers club', '', True),
    ('801 Chophouse', 'restaurant', '', 'https://801chophouse.com', True),
    ('Black Cow Chophouse', 'restaurant', '', 'https://blackcowchophouse.com', False),
    ('Moon Inn Hotel', 'hotel', "Google Maps ''. 3.1* (251 reviews).", '', True),
    ('Governor House Inn', 'hotel', "Google Maps ''. 3.6* (424 reviews).", '', True),
    ("Rabbit's Cantina & Wine Bar", 'wine_bar', '', 'https://rabbittaco.com', True),
    ('The Bodega Neighborhood Market', 'restaurant', '', '', False),
    ('Tabu Lifestyle Club', 'private_club', '', '', True),
    ('Cozy Cottage Airbnb', 'hotel', '', '', True),
    ('Riverside Inn', 'hotel', '', 'https://www.airbnb.com/rooms/1', True),
    ('The Carlyle Club', 'private_club', 'PERMANENTLY CLOSED 2025', '', True),
    ('Chipotle Mexican Grill', 'restaurant', '', '', True),
    ("Ruth’s Chris Steak House", 'restaurant', '', '', True),
    ('Le Diplomate', 'restaurant', '', 'https://lediplomatedc.com', False),
    ('CAPITAL YACHT MANAGEMENT', 'yacht_club', '', '', True),
    ('Nauti Buoy Yacht Club Boat Rental', 'yacht_club', '', '', True),
    ('Annapolis Yacht Club', 'yacht_club', '', '', False),
    ('Hilton Farm Winery', 'winery', '', '', False),
    ('Bethesda Marriott', 'hotel', '', '', True),
    ('Conrad Washington DC', 'hotel', '', '', False),
    ('Congressional Country Club', 'country_club', '', 'https://ccclub.org', False),
    ('The Inn at Little Washington', 'hotel', 'Historic inn', '', False),
]


def _self_test():
    bad = 0
    for name, gcat, notes, want, tag in REGRESSION_CASES:
        r = classify(name, gcat, notes)
        ok = r['primary_category'] == want and (not tag or tag in r['venue_tags'])
        if not ok:
            bad += 1
            print(f"FAIL classify({name!r}, {gcat!r}) -> {r['primary_category']} "
                  f"{r['classification_source']} {r['venue_tags']} (want {want} {tag})")
    for name, gcat, notes, web, want in JUNK_CASES:
        got = bool(junk_reason(name, gcat, notes, web))
        if got != want:
            bad += 1
            print(f"FAIL junk_reason({name!r}) -> {junk_reason(name, gcat, notes, web)!r} (want {want})")
    print(f"{len(REGRESSION_CASES) + len(JUNK_CASES) - bad} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        sys.exit(_self_test())
    for name, gcat, notes, _, _ in REGRESSION_CASES:
        r = classify(name, gcat, notes)
        print(f"{name:40s} {r['primary_category']:14s} {r['classification_confidence']:4.2f}  "
              f"{r['classification_source']:24s} {', '.join(r['venue_tags'][:6])}")
