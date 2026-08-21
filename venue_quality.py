#!/usr/bin/env python3
"""Shared venue-quality and website-matching rules.

Keeps discovery conservative: an uncertain venue stays unclassified / needs review
instead of being silently treated as a restaurant, and Google results are only
accepted when the URL plausibly belongs to the venue.
"""
from __future__ import annotations

import argparse
import re
from urllib.parse import urlparse

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


def _host(url: str) -> str:
    try:
        host = urlparse(url if '://' in url else 'https://' + url).netloc.lower().split('@')[-1].split(':')[0]
    except Exception:
        return ''
    return host[4:] if host.startswith('www.') else host


def is_blocked_domain(url: str) -> bool:
    host = _host(url)
    if not host:
        return True
    if any(host == d or host.endswith('.' + d) for d in BLOCKED_DOMAINS):
        return True
    # Tourism/directories commonly use these host prefixes and are not official venue sites.
    first = host.split('.')[0]
    if first.startswith(('visit','tourism','discover','explore')):
        return True
    if 'chamber' in first or 'directory' in first:
        return True
    return False


def _words(text: str) -> list[str]:
    return re.findall(r'[a-z0-9]+', (text or '').lower())


def _distinctive_tokens(name: str) -> list[str]:
    tokens = []
    for w in _words(name):
        if len(w) < 4 or w in STOP_WORDS or w in WEAK_LOCATION_WORDS:
            continue
        if w not in tokens:
            tokens.append(w)
    return tokens


def website_match_score(name: str, url: str) -> int:
    if not name or not url or is_blocked_domain(url):
        return -100
    parsed = urlparse(url if '://' in url else 'https://' + url)
    host = (parsed.netloc or '').lower().replace('www.','')
    if not host:
        return -100
    base = host.split('.')[0]
    hay = re.sub(r'[^a-z0-9]', '', host + (parsed.path or ''))
    domain_hay = re.sub(r'[^a-z0-9]', '', host)
    name_words = _words(name)
    distinctive = _distinctive_tokens(name)
    score = 0

    # Strong multi-token / brand matches.
    matches_domain = [t for t in distinctive if t in domain_hay]
    matches_anywhere = [t for t in distinctive if t in hay]
    score += 5 * len(matches_domain)
    score += 2 * max(0, len(matches_anywhere) - len(matches_domain))

    joined = ''.join(distinctive)
    if len(joined) >= 7 and (joined in hay or hay.find(joined[:8]) >= 0):
        score += 7

    acronym = ''.join(w[0] for w in name_words if w not in {'the','a','an','and','of','at','in','by','on','for','to'})
    if len(acronym) >= 3 and base in {acronym, acronym + 'club', acronym + 'cc'}:
        score += 8

    # If the venue name itself says what kind of place it is, a matching type word
    # on the candidate URL adds confidence (useful for clubs/hotels with short brands).
    name_types = {w for w in name_words if w in TYPE_WORDS}
    url_types = {w for w in TYPE_WORDS if w in hay}
    if name_types & url_types:
        score += 2

    # A single distinctive brand token in the domain is usually enough.
    # Five characters covers brands such as La Ferme without accepting generic 3-4 char noise.
    if any(len(t) >= 5 and t in domain_hay for t in distinctive):
        score = max(score, 6 if max((len(t) for t in distinctive if t in domain_hay), default=0) < 7 else 7)

    # Corporate luxury-hotel domains are acceptable only when the property/brand appears
    # in the URL path too; otherwise we may have landed on a generic chain homepage.
    if any(host == d or host.endswith('.' + d) for d in OFFICIAL_PARENT_DOMAINS):
        path_norm = re.sub(r'[^a-z0-9]', '', parsed.path.lower())
        path_matches = sum(1 for t in distinctive if t in path_norm)
        if path_matches >= 1:
            score = max(score, 7 + path_matches)
        elif not matches_domain:
            score -= 4

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
    """Conservative mapping. Unknown is `other`, never `restaurant`."""
    cl = (raw_category or '').lower()
    nl = ' ' + (name or '').lower() + ' '
    nl_clean = nl
    for false_city in ('falls church','church hill','church creek','church point','chapel hill','churchill'):
        nl_clean = nl_clean.replace(false_city, ' ')

    # Strong identity in the venue name beats a generic Google type such as
    # "Restaurant" (common for dining rooms inside clubs/hotels).
    if any(t in nl for t in ('country club','golf club','golf & country','golf and country','hunt club','field club')): return 'country_club'
    if any(t in nl for t in (' city club',' town club','cosmos club','university club','army navy club','metropolitan club','social club')): return 'private_club'
    if 'yacht club' in nl or ' yacht ' in nl: return 'yacht_club'
    if re.search(r'\bwine\s*bar\b', nl): return 'wine_bar'
    hotel_identity = (' hotel ',' inn ',' resort ',' lodge ','waldorf','conrad','sofitel','pendry','salamander',
                      'ritz-carlton','four seasons','fairmont','mandarin','st. regis','westin','hyatt','marriott',
                      'hilton','intercontinental','kimpton','rosewood','peninsula','langham','omni','loews')
    if any(t in nl for t in hotel_identity): return 'hotel'

    if any(t in cl for t in ('country club','golf club')): return 'country_club'
    if any(t in cl for t in ('private club','social club',"women's club","woman's club",'civic club','fraternal')): return 'private_club'
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
    if any(t in nl for t in (' city club',' town club','cosmos club','university club','army navy club','metropolitan club','social club')): return 'private_club'
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
