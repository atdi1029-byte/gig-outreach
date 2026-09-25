#!/usr/bin/env python3
"""Shared venue-quality and website-matching rules.

Keeps discovery conservative: an uncertain venue stays unclassified / needs review
instead of being silently treated as a restaurant, and Google results are only
accepted when the URL plausibly belongs to the venue.
"""
from __future__ import annotations

import argparse
import re
import unicodedata
from urllib.parse import urlparse

try:
    from outreach_rules import SHARED_BRAND_DOMAINS
except ImportError:
    SHARED_BRAND_DOMAINS = set()

BLOCKED_DOMAINS = {
    'facebook.com','instagram.com','x.com','twitter.com','linkedin.com','youtube.com','tiktok.com',
    'yelp.com','tripadvisor.com','opentable.com','resy.com','zomato.com','foursquare.com',
    'mapquest.com','yellowpages.com','bbb.org','chamberofcommerce.com','manta.com',
    'eventbrite.com','meetup.com','theknot.com','weddingwire.com','partyslate.com',
    'doordash.com','grubhub.com','ubereats.com','seamless.com','toasttab.com',
    'booking.com','expedia.com','hotels.com','travelocity.com','kayak.com','priceline.com',
    'airbnb.com','vrbo.com','google.com','wikipedia.org','patch.com',
    'visitmaryland.org','dcpreservation.org','washington.org',
}

OFFICIAL_PARENT_DOMAINS = {
    'marriott.com','hilton.com','hyatt.com','ihg.com','fourseasons.com','rosewoodhotels.com',
    'mandarinoriental.com','fairmont.com','accor.com','omnihotels.com','loewshotels.com',
    'kimptonhotels.com','ritzcarlton.com','preferredhotels.com','leadinghotels.com',
}

STOP_WORDS = {
    'the','a','an','and','of','at','in','by','on','for','to','from','with',
    'hotel','hotels','inn','resort','lodge','restaurant','restaurants','winery','vineyard','vineyards',
    'club','country','golf','bar','bistro','cafe','tavern','grill','grille','pub','lounge','spa','marina',
    'museum','gallery','event','events','venue','venues','fine','dining','kitchen','house','company','co',
}

TYPE_WORDS = {
    'hotel','inn','resort','lodge','restaurant','winery','vineyard','club','golf','bar','bistro',
    'spa','marina','museum','gallery','estate','manor','chateau','tavern','grill','grille'
}

WEAK_LOCATION_WORDS = {
    'washington','maryland','virginia','baltimore','annapolis','bethesda','alexandria','georgetown',
    'leesburg','middleburg','easton','wilmington','potomac','mclean','fairfax','arlington','reston',
}

# Words a venue's own domain often adds around its name ("eatbouboulina",
# "lediplomatedc", "rasikarestaurant"). Removing them must not be what makes a
# domain match: at least one real name word has to be in the label.
DOMAIN_FILLER = {
    'the','and','of','at','in','on','by','for','a','an','dc','va','md','de','pa','usa','us',
    'online','official','site','web','home','eat','dine','drink','go','get','my','our',
    'restaurant','restaurants','resto','bar','grill','grille','kitchen','cafe','bistro','tavern',
    'pub','lounge','hotel','hotels','inn','resort','club','cc','gc','yc','golf','country','winery',
    'wines','wine','vineyard','vineyards','cellars','events','event','group','co','company','llc',
    'inc','hospitality','dining','house','farm','farms','estate','gallery','museum','spa','marina',
    'old','town','oldtown','north','south','east','west','downtown','nw','ne','sw','se',
    'st','saint','mt','mount','washingtondc','nova','gcc','ycc','ccc','golfclub','countryclub',
    'experience','visitus','shop','stay','book','order','welcome','hello','love','try','taste',
    'pizza','pizzeria','tacos','taco','bbq','sushi','seafood','steak','steakhouse','oyster',
    'oysters','coffee','bakery','brewing','brewery','taproom','tap','cuisine','food','foods',
    'catering','events','weddings','venue','bmore','delaware','pennsylvania','philly',
    'vino','greek','italian','french','spanish','tapas','peru','peruvian','mexican','mtn',
    'delray','annapolis','stmarys','leesburgva','nightlife',
} | WEAK_LOCATION_WORDS | {
    'rockville','columbia','ellicottcity','ellicott','city','frederick','towson','herndon','vienna',
    'tysons','ashburn','purcellville','warrenton','oxford','stmichaels','michaels','chestertown',
    'severna','park','edgewater','arnold','crofton','hampden','rolandpark','roland','chevychase',
    'chevy','chase','greatfalls','great','falls','fallschurch','church','silverspring','silver',
    'spring','gaithersburg','olney','laurel','bowie','annearundel','talbot','loudoun','howard',
}
# Site builders: the venue's name lives in the subdomain (venue.wixsite.com).
PLATFORM_DOMAINS = {
    'wixsite.com','squarespace.com','business.site','square.site','toast.site','godaddysites.com',
    'webflow.io','weebly.com','wordpress.com','myshopify.com','carrd.co','netlify.app','github.io',
    'ueniweb.com','site123.me','jimdosite.com','blogspot.com','mystrikingly.com','wixstudio.com',
}
_STATE_ABBR = {'maryland': 'md', 'virginia': 'va', 'washington': 'dc', 'mount': 'mt', 'saint': 'st'}


def _host(url: str) -> str:
    try:
        host = urlparse(url if '://' in url else 'https://' + url).netloc.lower().split('@')[-1].split(':')[0]
    except Exception:
        return ''
    return host[4:] if host.startswith('www.') else host


def is_blocked_domain(url: str) -> bool:
    host = _host(url)
    if not host or '.' not in host:
        return True
    if any(host == d or host.endswith('.' + d) for d in BLOCKED_DOMAINS):
        return True
    # Tourism boards / chambers / directories: visitmaryland, explorefairfax,
    # alexandriachamber. Not visitationhotel, discoverymansion or chamberlainwinery.
    first = host.split('.')[0].replace('-', '')
    if re.match(r'^(visit(?!ation)|tourism|explore|discover(?!y))', first):
        return True
    if first.endswith('chamber') or 'chamberofcommerce' in first or 'directory' in first:
        return True
    return False


def _fold(text: str) -> str:
    text = unicodedata.normalize('NFKD', str(text or ''))
    text = ''.join(c for c in text if not unicodedata.combining(c)).lower()
    return text.replace('\u2019', "'").replace("'", '')


def _words(text: str) -> list[str]:
    return re.findall(r'[a-z0-9]+', _fold(text))


def _site_label(host: str) -> str:
    """The part of the host that should carry the venue's name."""
    parts = [p for p in host.split('.') if p and p != 'www']
    if len(parts) >= 3 and '.'.join(parts[-2:]) in PLATFORM_DOMAINS:
        return parts[-3]
    if len(parts) >= 3 and len(parts[-1]) == 2 and parts[-2] in ('co', 'com', 'org', 'net'):
        return parts[-3]
    return parts[-2] if len(parts) >= 2 else (parts[0] if parts else '')


def _acronyms(name_words: list[str]) -> set[str]:
    small = {'the','a','an','and','of','at','in','by','on','for','to','n'}
    articles = {'the','a','an','and'}
    typeish = TYPE_WORDS | {'winery', 'vineyard', 'vineyards', 'cellars', 'country', 'yacht'}
    subsets = [
        [w for w in name_words if w not in small],
        [w for w in name_words if w not in articles],
        [w for w in name_words if w not in small and w not in typeish],
        [w for w in name_words if w not in articles and w not in typeish],
    ]
    out = set()
    for words in subsets:
        if len(words) >= 2:
            out.add(''.join(w[0] for w in words))
            out.add(''.join(_STATE_ABBR.get(w, w[0]) for w in words))
    return {a for a in out if len(a) >= 3}


def label_coverage(name: str, label: str) -> dict:
    """How much of the domain label is the venue's own name.

    Greedily removes name words, name acronyms and DOMAIN_FILLER from the label.
    Returns {'leftover': chars left, 'name_chars': chars matched by name words,
    'distinct': distinctive name tokens matched, 'acronym': bool, 'label_len'}.
    """
    lab = re.sub(r'[^a-z0-9]', '', _fold(label))
    name_words = _words(name)
    if not re.search(r'\d', name):
        lab = re.sub(r'\d+', '|', lab)    # street numbers / years: skratch1709, logcabin1933
    distinctive = set(_distinctive_tokens(name))
    acrs = _acronyms(name_words)
    variants = set()
    for w in name_words:
        if len(w) >= 4:
            variants.update({w + 's', w + 'es'} | ({w[:-1] + 'ies'} if w.endswith('y') else set())
                            | ({w[:-1]} if w.endswith('s') and len(w) >= 5 else set()))
    core = {w for w in name_words
            if w not in STOP_WORDS and w not in DOMAIN_FILLER and w not in TYPE_WORDS}

    def greedy(use_variants):
        pieces = sorted({w for w in name_words if len(w) >= 2} | (variants if use_variants else set())
                        | acrs | DOMAIN_FILLER, key=len, reverse=True)
        rest, name_chars, core_chars, distinct, acr = lab, 0, 0, set(), False
        changed = True
        while changed and rest.replace('|', ''):
            changed = False
            for p in pieces:
                if len(p) <= 2 and p not in name_words and p not in acrs:
                    # Short filler ('of', 'at', 'dc') only as a whole segment, so
                    # 'capitalone' can't lose 'on' and pass as 'capital'.
                    segs = rest.split('|')
                    if p not in segs:
                        continue
                    segs[segs.index(p)] = ''
                    rest = '|'.join(segs) if len(segs) > 1 else '|'
                    changed = True
                    break
                i = rest.find(p)
                if i < 0:
                    continue
                rest = rest[:i] + '|' + rest[i + len(p):]
                if p in acrs and p not in name_words:
                    acr = True
                    name_chars += len(p)
                elif p in name_words or p in variants:
                    base = p if p in name_words else next(
                        (w for w in name_words if p in (w + 's', w + 'es', w[:-1] + 'ies', w[:-1])), p)
                    name_chars += len(p)
                    if base in core:
                        core_chars += len(base)
                    if base in distinctive:
                        distinct.add(base)
                changed = True
                break
        return (len(rest.replace('|', '')), -name_chars), (name_chars, core_chars, distinct, acr)

    (left, _), (name_chars, core_chars, distinct, acr) = min(greedy(True), greedy(False),
                                                              key=lambda r: r[0])
    namecat = ''.join(w for w in name_words if w not in {'the', 'a', 'an', 'and', 'of', 'at'})
    corecat = ''.join(core)
    return {'leftover': left, 'name_chars': name_chars,
            'core_chars': core_chars, 'core_len': len(corecat), 'name_len': len(namecat),
            'distinct': distinct, 'acronym': acr, 'label_len': len(lab.replace('|', ''))}


def _distinctive_tokens(name: str) -> list[str]:
    tokens = []
    for w in _words(name):
        if len(w) < 4 or w in STOP_WORDS or w in WEAK_LOCATION_WORDS:
            continue
        if w not in tokens:
            tokens.append(w)
    return tokens


def website_match_score(name: str, url: str) -> int:
    """>= 6 means the URL plausibly is the venue's own site.

    A single common word shared with a longer domain is not enough ('The Capital
    Grille' vs capitalone.com, 'Rappahannock River Yacht Club' vs
    virginiasriverrealm.com): the label must be essentially the venue's name
    (plus filler such as 'eat', 'dc', 'restaurant'), or share two distinctive
    words, or match the name's acronym. A bare multi-property brand homepage
    (hyatt.com, sonesta.com) never identifies one property.
    """
    if not name or not url or is_blocked_domain(url):
        return -100
    parsed = urlparse(url if '://' in url else 'https://' + url)
    host = (parsed.netloc or '').lower().split('@')[-1].split(':')[0]
    host = host[4:] if host.startswith('www.') else host
    if not host:
        return -100
    label = _site_label(host)
    hay = re.sub(r'[^a-z0-9]', '', host + (parsed.path or '').lower())
    domain_hay = re.sub(r'[^a-z0-9]', '', host)
    name_words = _words(name)
    distinctive = _distinctive_tokens(name)
    score = 0

    matches_domain = [t for t in distinctive if t in domain_hay]
    matches_anywhere = [t for t in distinctive if t in hay]
    score += 5 * len(matches_domain)
    score += 2 * max(0, len(matches_anywhere) - len(matches_domain))

    joined = ''.join(distinctive)
    if len(distinctive) >= 2 and len(joined) >= 7 and (joined in hay or hay.find(joined[:8]) >= 0):
        score += 7

    name_types = {w for w in name_words if w in TYPE_WORDS}
    url_types = {w for w in TYPE_WORDS if w in hay}
    if name_types & url_types:
        score += 2

    cov = label_coverage(name, label)
    whole_name = cov['leftover'] <= 2 and cov['name_chars'] >= 3 and (
        cov['distinct'] or cov['acronym'] or
        (cov['core_len'] and cov['core_chars'] >= 0.6 * cov['core_len']) or
        (not cov['core_len'] and cov['name_chars'] >= 0.8 * cov['name_len']))
    two_distinct = len(set(matches_domain)) >= 2
    if whole_name:
        score = max(score, 8)
    elif two_distinct:
        score = max(score, 7)
    elif matches_domain:
        # One shared word: only when it is nearly the whole label.
        longest = max(len(t) for t in matches_domain)
        if longest >= 6 and cov['leftover'] <= 3 and cov['leftover'] <= 0.2 * cov['label_len']:
            score = max(score, 6)
        else:
            score = min(score, 5)
    elif cov['acronym'] and cov['leftover'] <= 2:
        score = max(score, 8)
    ws = [w for w in name_words if w not in {'the', 'a', 'an', 'and'}]
    if len(ws) >= 3 and ws[-1] == 'club' and label in {
            ''.join(w[0] for w in ws[:-1]) + suf for suf in ('club', 'cc')}:
        score = max(score, 8)    # Congressional Country Club -> ccclub.org

    reg = '.'.join(host.split('.')[-2:])
    parent = any(host == d or host.endswith('.' + d) for d in OFFICIAL_PARENT_DOMAINS) or \
        reg in SHARED_BRAND_DOMAINS
    if parent:
        path_norm = re.sub(r'[^a-z0-9]', '', parsed.path.lower())
        path_words = {w for w in name_words if len(w) >= 4 and w not in STOP_WORDS}
        path_matches = sum(1 for t in path_words if t in path_norm and t not in label)
        if not path_norm:
            return min(score, 0)    # bare chain homepage
        if path_matches >= 1:
            score = max(score, 7 + path_matches)
        elif not matches_domain or all(t in label for t in matches_domain):
            score = min(score, 5) - 4

    return score


def website_matches(name: str, url: str) -> bool:
    return website_match_score(name, url) >= 6


def choose_website(name: str, raw_candidates: str) -> str:
    best_url = ''
    best_score = -100
    for raw in (raw_candidates or '').split('|'):
        url = raw.strip()
        if not url:
            continue
        if '://' not in url:
            url = 'https://' + url
        parsed = urlparse(url)
        if not parsed.netloc:
            continue
        clean = parsed._replace(query='', fragment='').geturl().rstrip('/')
        score = website_match_score(name, clean)
        if score > best_score:
            best_url, best_score = clean, score
    return best_url if best_score >= 6 else ''


def canonical_category(raw_category: str, name: str = '') -> str:
    """Conservative mapping. Unknown is `other`, never `restaurant`.
    Accepts Google types and the sheet's own slugs (P8: 'private_club')."""
    cl = (raw_category or '').lower().replace('_', ' ')
    nl = ' ' + (name or '').lower() + ' '
    nl_clean = nl
    for false_city in ('falls church','church hill','church creek','church point','chapel hill','churchill'):
        nl_clean = nl_clean.replace(false_city, ' ')

    # Strong identity in the venue name beats a generic Google type such as
    # "Restaurant" (common for dining rooms inside clubs/hotels).
    if re.search(r'\b(masonic|elks|moose lodge|odd fellows|vfw|american legion|knights of columbus)\b', nl):
        return 'other'    # fraternal lodge, not a hotel
    if any(t in nl for t in ('country club','golf club','golf & country','golf and country','hunt club','field club')): return 'country_club'
    if any(t in nl for t in (' city club',' town club','cosmos club','university club','army navy club','metropolitan club')): return 'private_club'
    if 'yacht club' in nl or ' yacht ' in nl: return 'yacht_club'
    if re.search(r'\bwine\s*bar\b', nl): return 'wine_bar'
    if re.search(r'\bwiner(?:y|ies)\b|\bvineyards?\b', nl): return 'winery'   # 'Hilton Farm Winery'
    hotel_identity = (' hotel ',' inn ',' resort ',' lodge ','waldorf','conrad','sofitel','pendry','salamander',
                      'ritz-carlton','four seasons','fairmont','mandarin','st. regis','westin','hyatt','marriott',
                      'hilton','intercontinental','kimpton','rosewood','peninsula','langham','omni','loews')
    if any(re.search(r'(?<![a-z])' + re.escape(t.strip()) + r'(?![a-z])', nl) for t in hotel_identity): return 'hotel'

    if any(t in cl for t in ('country club','golf club')): return 'country_club'
    if 'fraternal' in cl: return 'other'
    if any(t in cl for t in ('private club',)): return 'private_club'
    if any(t in cl for t in ('yacht','sailing')): return 'yacht_club'
    if 'wine bar' in cl: return 'wine_bar'
    if any(t in cl for t in ('hotel','inn','resort','lodge')): return 'hotel'
    if any(t in cl for t in ('winery','vineyard')): return 'winery'
    if any(t in cl for t in ('restaurant','fine dining','steakhouse','brasserie','bistro')): return 'restaurant'
    if any(t in cl for t in ('brewery','brewpub')): return 'brewery'
    if any(t in cl for t in ('distillery','cidery')): return 'distillery'
    if 'art gallery' in cl: return 'art_gallery'
    if any(t in cl for t in ('museum','gallery')): return 'museum'
    if any(t in cl for t in ('event','banquet','wedding','booking agent','entertainment agency','party','catering')): return 'event'
    if 'spa' in cl and 'spanish' not in cl: return 'spa'
    if any(t in cl for t in ('farmers market','farm stand','farmer')): return 'farmers_market'
    if any(t in cl for t in ('senior living','assisted living','retirement')): return 'senior_living'
    if any(t in cl for t in ('swim','pool','tennis','recreation','athletic','fitness','gym','canoe','kayak','paddle','marina')): return 'recreation'
    if any(t in cl for t in ('theater','theatre','cinema','performing arts')): return 'theater'
    if 'library' in cl: return 'library'

    hotel_names = (' hotel ',' inn ',' resort ',' lodge ',' suites ','waldorf','conrad','sofitel','pendry','salamander',
                   'ritz-carlton','four seasons','fairmont','mandarin','st. regis','westin','hyatt','marriott','hilton',
                   'intercontinental','kimpton','rosewood','peninsula','langham','omni','loews','bed & breakfast','b&b')
    if any(t in nl for t in hotel_names): return 'hotel'
    if any(t in nl for t in ('country club','golf club','golf & country','golf and country','hunt club','field club')): return 'country_club'
    if any(t in nl for t in (' city club',' town club','cosmos club','university club','army navy club','metropolitan club')): return 'private_club'
    if 'yacht club' in nl or ' yacht ' in nl: return 'yacht_club'
    if re.search(r'\bwine\s*bar\b', nl): return 'wine_bar'
    if re.search(r'\bwiner(?:y|ies)\b|\bvineyards?\b', nl): return 'winery'
    if re.search(r'\bbrewer(?:y|ies)\b|\bbrewing\b', nl): return 'brewery'
    if re.search(r'\bgaller(?:y|ies)\b', nl): return 'art_gallery'
    if re.search(r'\bmuseum\b', nl): return 'museum'
    if re.search(r'\btheat(?:er|re)\b|\bcinema\b', nl): return 'theater'
    if any(t in nl_clean for t in (' church ',' cathedral ',' basilica ')): return 'church'
    if any(t in nl_clean for t in (' synagogue ',' congregation ')): return 'synagogue'
    if re.search(r'\blibrar(?:y|ies)\b', nl) and not any(t in nl for t in ('bar','pub','lounge','tavern')): return 'library'
    if re.search(r'\bfarmers?\s*market\b', nl): return 'farmers_market'
    if re.search(r'\bspa\b', nl) and 'spanish' not in nl: return 'spa'

    # Only call it a restaurant when there is actual restaurant evidence.
    restaurant_names = (' restaurant ',' ristorante ',' trattoria ',' brasserie ',' bistro ',' steakhouse ',' chophouse ')
    if any(t in nl for t in restaurant_names): return 'restaurant'
    return 'other'


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('choose-website')
    p.add_argument('name'); p.add_argument('candidates')
    p = sub.add_parser('website-match')
    p.add_argument('name'); p.add_argument('url')
    p = sub.add_parser('website-score')
    p.add_argument('name'); p.add_argument('url')
    p = sub.add_parser('category')
    p.add_argument('raw'); p.add_argument('name', nargs='?', default='')
    args = ap.parse_args()
    if args.cmd == 'choose-website': print(choose_website(args.name, args.candidates))
    elif args.cmd == 'website-match': print('yes' if website_matches(args.name, args.url) else 'no')
    elif args.cmd == 'website-score': print(website_match_score(args.name, args.url))
    elif args.cmd == 'category': print(canonical_category(args.raw, args.name))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
