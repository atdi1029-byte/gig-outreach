#!/usr/bin/env python3
"""Reusable website-discovery helpers for the outreach pipeline.

This module is intentionally conservative about dependencies. It uses requests (already
required by this project) and falls back to regex parsing if BeautifulSoup/pypdf are not
installed.

CLI examples:
  python3 site_discovery.py seeds https://example.com --limit 80
  python3 site_discovery.py pdf https://example.com/private-events.pdf
  python3 site_discovery.py static-crawl https://example.com --max-pages 25 --max-depth 2
  python3 site_discovery.py parse-location "1309 5th St NE, Washington, DC 20002"

stdout carries ONLY the JSON result (callers json.load it); diagnostics go to stderr.
The crawler honours path-specific robots.txt Disallow rules (a robots.txt that can't be
fetched is treated as allow-all; a blanket "Disallow: /" is recorded, not applied, unless
SITE_DISCOVERY_ROBOTS=strict), waits SITE_DISCOVERY_DELAY seconds (default 0.8) between
requests and stops after SITE_DISCOVERY_MAX_SECONDS (default 300).

static-crawl output, beyond pages/contacts/socials: contacts[] carry mailto, name_hint,
title_hint and contexts (text around the address; hints are unverified); contact_forms[];
page_kinds; coverage.{blocked, blocked_reason, home_status, throttled, time_budget_exceeded,
page_kinds_visited, page_kinds_missing, redirected, path_prefix, robots_*}.
"""

from __future__ import annotations

import argparse
import functools
import html as html_lib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.robotparser
import xml.etree.ElementTree as ET
import zlib
from collections import deque
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Set, Tuple
from urllib.parse import parse_qsl, quote, unquote, urlencode, urljoin, urlparse, urlunparse

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import outreach_rules as R  # shared junk/role rules; the crawler still works without it
except Exception:  # pragma: no cover
    R = None

USER_AGENT = os.environ.get(
    "OUTREACH_USER_AGENT",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
)
HEADERS = {"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}

try:
    # 0.3s got a small winery site to start refusing us (444/timeouts) after ~25 requests.
    CRAWL_DELAY = max(0.0, float(os.environ.get("SITE_DISCOVERY_DELAY", "0.8")))
except ValueError:
    CRAWL_DELAY = 0.8
_LAST_REQUEST = [0.0]
# Wall-clock budget for one static crawl, so one slow site can't stall a batch.
try:
    CRAWL_MAX_SECONDS = max(30.0, float(os.environ.get("SITE_DISCOVERY_MAX_SECONDS", "300")))
except ValueError:
    CRAWL_MAX_SECONDS = 300.0

EMAIL_RE = re.compile(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)
CF_RE = re.compile(r'data-cfemail=["\']([a-fA-F0-9]+)["\']')
# Cloudflare also rewrites mailto links to an href-only form.
CF_HREF_RE = re.compile(r"/cdn-cgi/l/email-protection#([a-fA-F0-9]{4,})")
MAILTO_RE = re.compile(r"mailto:\s*([^\"'<>\s?&]+)", re.I)
# JS string escapes in inline JSON/scripts (">info@x.com", "\x40").
_JS_ESCAPE_RE = re.compile(r"\\u([0-9a-fA-F]{4})|\\x([0-9a-fA-F]{2})")
# What is left of such an escape once the backslash was already eaten ("u003einfo@", "u00a0events@").
_ESCAPE_REMNANT_RE = re.compile(r"^(?:u00[0-9a-f]{2})+(?=[a-z0-9])")
_OBFUSCATION_TLDS = {
    "com", "org", "net", "edu", "gov", "us", "biz", "info", "co", "io", "club",
    "wine", "restaurant", "events", "email", "me", "mil",
}
# "Join us at Clyde dot com" must not become us@clyde.com.
_AT_DOT_STOPWORDS = {
    "us", "me", "you", "him", "her", "them", "it", "we", "join", "find", "visit",
    "meet", "see", "here", "there", "home", "online", "open", "dine", "eat",
    "stay", "book", "reserve", "call", "text", "email", "or", "and", "the",
    "dinner", "lunch", "brunch", "noon", "night", "today", "follow", "tag",
}
TRACKING_KEYS = {"fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "ref", "source",
                 # calendar/comment variants of the same page ("?occurrence=2026-09-06&time=...")
                 "occurrence", "time", "ical", "outlook-ical", "tribe-bar-date",
                 "eventdisplay", "instance_id", "replytocom", "share"}
ASSET_EXTENSIONS = {
    ".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp",
    ".woff", ".woff2", ".ttf", ".eot", ".map", ".zip", ".mp3", ".mp4", ".mov",
    ".avi", ".json", ".xml", ".txt",
}
DOCUMENT_EXTENSIONS = {".pdf"}
JUNK_EMAIL_SUBSTRINGS = {
    "example.com", "yourdomain", "sentry.io", "wixpress.com", "mailchimp.com",
    "sendgrid.net", "googleapis.com", "gstatic.com", "schema.org", "w3.org",
}
HARD_REJECT_PREFIXES = {
    "noreply@", "no-reply@", "mailer-daemon@", "postmaster@", "webmaster@",
}
GENERIC_PREFIXES = {
    "info@", "hello@", "contact@", "sales@", "reservations@", "booking@",
    "enquiries@", "inquiries@", "office@", "general@", "frontdesk@", "reception@",
    "support@", "admin@", "events@", "event@", "catering@", "privateevents@",
}



SOCIAL_URL_RE = re.compile(r"(?:https?:)?//(?:www\.|m\.|web\.)?(?:facebook|instagram)\.com/[^\s\"\'<>]+", re.I)
FB_RESERVED = {
    "tr", "pixel", "plugins", "sharer", "share", "login", "dialog", "policy.php",
    "policy", "terms", "terms.php", "about", "legal", "cookies", "r.php", "recover",
    "help", "privacy", "settings", "ads", "business", "watch", "marketplace", "events",
    # Not pages: groups, posts/photos, bare /people/ and /p/ prefixes (handled below).
    "groups", "people", "p", "pg", "photo", "photo.php", "photos", "story.php",
    "permalink.php", "hashtag", "reel", "reels", "videos", "home.php", "l.php",
    "sharer.php", "share.php", "login.php", "gaming", "search", "media", "stories",
    # Common site-builder/template accounts are not venue evidence.
    "wix", "wixstudio", "squarespace", "wordpress", "shopify", "godaddy", "weebly",
    "webflow", "carrd", "linktree", "linktr",
}
IG_RESERVED = {
    "p", "reel", "reels", "explore", "stories", "accounts", "developer", "about",
    "legal", "privacy", "terms", "share", "embed", "direct", "tv", "web", "directory",
    "wix", "wixstudio", "squarespace", "wordpress", "shopify", "godaddy", "weebly",
    "webflow", "carrd", "linktree", "linktr",
}


def _social_text_variants(text: str) -> List[str]:
    """Return common encoded forms decoded enough to expose social URLs."""
    raw = html_lib.unescape(text or "")
    variants = [raw]
    # JSON/script escaped URLs: https:\/\/instagram.com\/handle
    deescaped = re.sub(r"\\u002[fF]", "/", raw)
    deescaped = re.sub(r"\\u003[aA]", ":", deescaped)
    deescaped = deescaped.replace(r"\/", "/")
    variants.append(deescaped)
    # Redirect wrappers often percent-encode the real social URL. Decode twice at most.
    cur = deescaped
    for _ in range(2):
        try:
            nxt = unquote(cur)
        except Exception:
            break
        if nxt == cur:
            break
        variants.append(nxt)
        cur = nxt
    # Preserve order while deduping.
    return list(dict.fromkeys(variants))


def _canonical_social(url: str) -> Optional[Tuple[str, str]]:
    u = html_lib.unescape((url or "").strip()).rstrip(".,;:)]}\"'")
    if u.startswith("//"):
        u = "https:" + u
    try:
        parsed = urlparse(u)
    except Exception:
        return None
    host = (parsed.hostname or "").lower()
    path = parsed.path or "/"

    if host.endswith("facebook.com"):
        parts = [p for p in path.split("/") if p]
        if not parts:
            return None
        first = parts[0].lower()
        # profile.php?id=... is still a legitimate page link when the venue itself links it.
        if first == "profile.php":
            qs = dict(parse_qsl(parsed.query))
            if str(qs.get("id", "")).isdigit():
                return ("facebook", f"https://www.facebook.com/profile.php?id={qs['id']}")
            return None
        # Legacy /pages/Name/123456 business-page URLs are legitimate too.
        if first == "pages" and len(parts) >= 3 and parts[-1].isdigit():
            return ("facebook", "https://www.facebook.com/" + "/".join(parts[:3]))
        # New-style pages: /people/Venue-Name/1000123/ and /p/Venue-Name-1000123/.
        if first == "people" and len(parts) >= 3 and re.fullmatch(r"\d{6,}", parts[2]):
            return ("facebook", f"https://www.facebook.com/people/{parts[1]}/{parts[2]}/")
        if first == "p" and len(parts) >= 2 and re.search(r"-\d{6,}$", parts[1]):
            return ("facebook", f"https://www.facebook.com/p/{parts[1]}/")
        if first == "pg" and len(parts) >= 2:
            first, parts = parts[1].lower(), parts[1:]
        if first in FB_RESERVED or first.isdigit() or len(first) < 2:
            return None
        return ("facebook", f"https://www.facebook.com/{parts[0]}/")

    if host.endswith("instagram.com"):
        parts = [p for p in path.split("/") if p]
        if not parts:
            return None
        handle = parts[0]
        if handle.lower() in IG_RESERVED or handle.isdigit() or len(handle) < 2:
            return None
        if not re.fullmatch(r"[A-Za-z0-9._]+", handle):
            return None
        return ("instagram", f"https://www.instagram.com/{handle}/")
    return None


def extract_socials(text: str) -> Dict[str, List[str]]:
    """Extract Facebook/Instagram profile links from HTML, scripts, data attrs, redirects."""
    found: Dict[str, List[str]] = {"facebook": [], "instagram": []}
    seen = {"facebook": set(), "instagram": set()}
    for variant in _social_text_variants(text or ""):
        for raw in SOCIAL_URL_RE.findall(variant):
            item = _canonical_social(raw)
            if not item:
                continue
            platform, canonical = item
            if canonical not in seen[platform]:
                seen[platform].add(canonical)
                found[platform].append(canonical)
    return found

HIGH_VALUE_KEYWORDS = [
    # Tier 1: Pages most likely to have named contacts / booking info
    "contact", "contact-us", "get-in-touch", "inquiry", "inquire", "enquiry", "enquire",
    "team", "staff", "people", "leadership", "board", "directory", "our-team", "about",
    # Tier 2: Event/booking overview pages
    "private-event", "private_event", "private event", "private-dining", "private dining",
    "special-events", "special events", "group-dining", "group dining",
    "cater", "banquet", "rental", "wedding", "booking", "book-an", "book-a-", "book-your",
    "book-event", "request-a-quote", "rfp", "proposal",
    # Tier 3: General pages (lower priority than contacts)
    "events", "event", "meeting", "corporate", "sales",
    "press", "media", "party", "parties", "celebration", "hospitality", "venue", "groups",
]
# Unvisited pages scoring below this (contact/team/about/private-events...) are reported
# as high-priority misses.
HIGH_PRIORITY_THRESHOLD = HIGH_VALUE_KEYWORDS.index("special-events")
# Individual items under a listing (/events/fall-wine-dinner, /blog/some-post) come after
# every overview page unless their slug names something we want.
_LISTING_CHILD_RE = re.compile(
    r"^/(?:events?|calendar|blog|posts?|news|articles?|stories|press|happenings|whats-on|"
    r"recipes?|products?|shop|store|menus?|gallery|galleries|photos?|portfolio|tag|category|"
    r"author)/[^/]+", re.I)
_DETAIL_PENALTY = 20

# Good fallback paths. They are seeds only; callers still verify/fetch them.
KNOWN_PATHS = [
    "/contact", "/contact-us", "/get-in-touch", "/inquiry", "/enquiry", "/event-inquiry",
    "/events", "/private-events", "/special-events", "/book-an-event", "/book-event",
    "/private-dining", "/group-dining", "/groups", "/catering", "/weddings", "/meetings",
    "/corporate-events", "/banquets", "/private-parties", "/rentals", "/team", "/our-team",
    "/meet-the-team", "/staff", "/leadership", "/about", "/about-us", "/press",
]


def canonical_host(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def same_origin(a: str, b: str) -> bool:
    return canonical_host(a) == canonical_host(b) and bool(canonical_host(a))


def normalize_url(href: str, base: str, keep_fragment: bool = True) -> Optional[str]:
    if not href:
        return None
    href = html_lib.unescape(href.strip())
    if href.lower().startswith(("mailto:", "tel:", "javascript:", "data:")):
        return None
    try:
        parsed = urlparse(urljoin(base, href))
    except Exception:
        return None
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return None

    # Keep semantic query parameters, drop obvious tracking only.
    pairs = []
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        lk = key.lower()
        if lk.startswith("utm_") or lk in TRACKING_KEYS:
            continue
        pairs.append((key, value))
    query = urlencode(pairs, doseq=True)
    fragment = parsed.fragment if keep_fragment else ""
    path = parsed.path or "/"
    if path != "/":
        path = path.rstrip("/") or "/"
    return urlunparse((parsed.scheme.lower(), parsed.netloc.lower(), path, "", query, fragment))


def path_extension(url: str) -> str:
    path = urlparse(url).path.lower()
    name = path.rsplit("/", 1)[-1]
    if "." not in name:
        return ""
    return "." + name.rsplit(".", 1)[-1]


# Page-builder template parts and layout libraries (Themify, Elementor, Divi, Beaver
# Builder, Oxygen, Brizy, reusable blocks) hold theme demo content such as "Sophia
# Reynolds, Event Coordinator", not the venue's real pages.
TEMPLATE_URL_RE = re.compile(
    r"/(?:tbuilder[-_]layout[-_]part|tbuilder[-_]layout|elementor[-_]library|et_pb_layout|"
    r"fl-builder-template|ct_template|brizy_template|wp-block|oceanwp_library|jet-theme-core)/"
    r"|[?&](?:elementor_library|et_pb_layout|fl-builder-template|tbuilder_layout_part)=", re.I)


def classify_url(url: str) -> str:
    if TEMPLATE_URL_RE.search(url or ""):
        return "asset"
    ext = path_extension(url)
    if ext in DOCUMENT_EXTENSIONS:
        return "pdf"
    if ext in ASSET_EXTENSIONS:
        return "asset"
    return "page"


# Patterns that indicate a detail/listing page (blog post, event, news article, etc.)
# These are individual items, not overview/navigation pages.
_DETAIL_PATTERN = re.compile(
    r"/(?:event|blog|post|news|article|listing|recipe|product|item|gallery|photo|menu-item)"
    r"[s]?[/-]\d",
    re.I,
)


def _route_family(url: str) -> Optional[str]:
    """Return a route-family key for detail-page URLs, or None for unique pages.

    Groups URLs like /event-6788310, /event-6505231 into family "/event-", and
    /events/fall-wine-dinner, /events/jazz-night into "/events/*".
    This lets the crawler cap how many pages from one family it visits.
    """
    path = urlparse(url).path
    lm = _LISTING_CHILD_RE.match(path)
    if lm:
        return "/" + path.strip("/").split("/", 1)[0].lower() + "/*"
    m = _DETAIL_PATTERN.search(path)
    if not m:
        return None
    # Extract the prefix up to and including the separator before digits
    prefix = m.group(0)
    # Strip the trailing digit(s) to get the family key
    return re.sub(r"\d+$", "", prefix)


# Keywords match whole words of the page's own slug (plus query values, hash route and
# link text), never the host or a substring of an unrelated word: "/we-the-people/<art>",
# "/event/...-staff-show-talk" and "steamboat.com" must not outrank /rentals or /events.
# score = tier * len(HIGH_VALUE_KEYWORDS) + keyword index, tiers:
#   0 the slug/link text IS the keyword ("/contact-us", "/our-team", "/privateevents", "Rentals")
#   1 the keyword is a whole word in it ("/private-dining-room"), or the parent is a
#     contact/team/staff/about/private-events page ("/about/staff/jane-doe")
#   2 only inside a longer word ("/eventinquiry", "/5th-avenue")
#   3 no keyword (shorter URLs first)
_WORD_SPLIT_RE = re.compile(r"[^a-z0-9]+")
_FILLER_WORDS = {"our", "the", "meet", "us", "a", "an", "and", "of", "your", "page"}
_FILLER_PREFIXES = ("meetthe", "meetour", "our", "the")
_KW_CORE = [tuple(w for w in _WORD_SPLIT_RE.split(kw) if w and w not in _FILLER_WORDS)
            for kw in HIGH_VALUE_KEYWORDS]
_KW_COUNT = len(HIGH_VALUE_KEYWORDS)
_WEAK_KEYWORD_IDX = HIGH_VALUE_KEYWORDS.index("events")
_PAGE_EXT_RE = re.compile(r"\.(?:html?|php\d?|aspx?|shtml|cfm|jsp)$")


def _kw_word_eq(word: str, kw: str, last: bool) -> bool:
    if word == kw or word == kw + "s":
        return True
    if not last:
        return False
    if kw.endswith("y") and word == kw[:-1] + "ies":
        return True
    return word in (kw + "es", kw + "ing", kw + "ings", kw + "er", kw + "ers")


def _core_words(text: str) -> List[str]:
    return [w for w in _WORD_SPLIT_RE.split(text.lower()) if w and w not in _FILLER_WORDS]


def _match_tier(core: List[str], kw_core: Tuple[str, ...]) -> Optional[int]:
    if not core:
        return None
    n = len(kw_core)
    if len(core) == n and all(_kw_word_eq(core[j], kw_core[j], j == n - 1) for j in range(n)):
        return 0
    compact_kw = "".join(kw_core)
    if len(core) == 1:
        c = core[0]
        for p in _FILLER_PREFIXES:
            if c.startswith(p) and len(c) > len(p) + 2:
                c = c[len(p):]
                break
        if _kw_word_eq(c, compact_kw, True) or c == compact_kw + "us":   # privateevents, contactus
            return 0
    for i in range(len(core) - n + 1):
        if all(_kw_word_eq(core[i + j], kw_core[j], j == n - 1) for j in range(n)):
            return 1
    return 2 if compact_kw in "".join(core) else None


def _keyword_score(texts: List[str], parent: str = "") -> Optional[int]:
    cores = [c for c in (_core_words(t) for t in texts if t) if c]
    parent_core = _core_words(parent) if parent else []
    best: Optional[int] = None
    for idx, kw_core in enumerate(_KW_CORE):
        for core in cores:
            tier = _match_tier(core, kw_core)
            if tier is not None and (best is None or tier * _KW_COUNT + idx < best):
                best = tier * _KW_COUNT + idx
        if (parent_core and idx < HIGH_PRIORITY_THRESHOLD and _match_tier(parent_core, kw_core) == 0
                and (best is None or _KW_COUNT + idx < best)):
            best = _KW_COUNT + idx
    return best


def score_url(url: str, anchor_text: str = "") -> int:
    return _score_url_cached(url, anchor_text or "")


@functools.lru_cache(maxsize=50000)
def _score_url_cached(url: str, anchor_text: str) -> int:
    p = urlparse(url)
    segs = [s for s in unquote(p.path or "").split("/") if s]
    leaf = _PAGE_EXT_RE.sub("", segs[-1].lower()) if segs else ""
    parent = segs[-2] if len(segs) >= 2 else ""
    if leaf in ("index", "default") and parent:
        leaf, parent = parent, (segs[-3] if len(segs) >= 3 else "")
    texts = [leaf, anchor_text] + [unquote(v) for _, v in parse_qsl(p.query)] + [unquote(p.fragment)]
    score = _keyword_score(texts, parent)
    if ((score is None or score % _KW_COUNT >= _WEAK_KEYWORD_IDX)
            and (_LISTING_CHILD_RE.match(p.path) or _DETAIL_PATTERN.search(p.path))):
        # "/events/jazz-night-party" or "/tag/wine" is one item, not an overview page; only
        # a slug that itself says contact/private/wedding/rentals keeps its rank.
        return 3 * _KW_COUNT + min(len(url) // 40, 10) + _DETAIL_PENALTY
    return score if score is not None else 3 * _KW_COUNT + min(len(url) // 40, 10)


def _visit_key(url: str) -> str:
    """Scheme- and www-insensitive identity: http://www.x.com/contact and
    https://x.com/contact/ are one page."""
    p = urlparse(url)
    path = (p.path or "/").rstrip("/") or "/"
    return canonical_host(url) + path + ("?" + p.query if p.query else "")


def clean_email(email: str) -> Optional[str]:
    e = email.strip().strip(".,;:()[]{}<>\"'").lower()
    e = _ESCAPE_REMNANT_RE.sub("", e)
    if len(e) > 120 or "@" not in e:
        return None
    if any(s in e for s in JUNK_EMAIL_SUBSTRINGS):
        return None
    if any(e.startswith(p) for p in HARD_REJECT_PREFIXES):
        return None
    # Reject file-like false positives.
    if re.search(r"\.(png|jpe?g|gif|svg|webp|css|js|pdf|docx?|xlsx?|zip)$", e, re.I):
        return None
    if R is not None:
        # Placeholders, platform domains, hash/long-digit local parts, fake TLDs.
        e = R.normalize_email(e)
        if not e or R.junk_reason(e):
            return None
    return e


def _is_generic(email: str) -> bool:
    if R is not None:
        return bool(R.is_role_email(email))
    return any(email.startswith(p) for p in GENERIC_PREFIXES)


def decode_cf_email(encoded: str) -> Optional[str]:
    try:
        key = int(encoded[:2], 16)
        decoded = "".join(chr(int(encoded[i:i + 2], 16) ^ key) for i in range(2, len(encoded), 2))
        return clean_email(decoded)
    except Exception:
        return None


def _decode_for_emails(text: str) -> str:
    """Undo the encodings sites wrap addresses in: JS escapes, HTML entities
    (WordPress antispambot), and percent-encoding (mailto:%20x@ / x%40y.com)."""
    t = _JS_ESCAPE_RE.sub(lambda m: chr(int(m.group(1) or m.group(2), 16)), text or "")
    t = html_lib.unescape(t)
    if "%" in t:
        t = unquote(t)
    return t


def _at_dot_repl(m: "re.Match[str]") -> str:
    local, dom, tld = m.group(1), m.group(2), m.group(3)
    # Obfuscated addresses are written lower-case; "Meet Sarah at Clyde dot com" is prose.
    if (local.lower() in _AT_DOT_STOPWORDS or tld.lower() not in _OBFUSCATION_TLDS
            or local != local.lower() or dom != dom.lower()):
        return m.group(0)
    return f"{local}@{dom}.{tld}"


def _spaced_at_repl(m: "re.Match[str]") -> str:
    local, dom = m.group(1), m.group(2)
    if local.lower() in _AT_DOT_STOPWORDS or local != local.lower() or dom != dom.lower():
        return m.group(0)
    return f"{local}@{dom}"


def deobfuscate_text(text: str) -> str:
    # Conservative patterns only. Avoid replacing ordinary English " at ".
    text = re.sub(r"\s*(?:\[\s*at\s*\]|\(\s*at\s*\)|\{\s*at\s*\}|\(@\)|\[@\])\s*", "@", text, flags=re.I)
    text = re.sub(r"\s*(?:\[\s*dot\s*\]|\(\s*dot\s*\)|\{\s*dot\s*\})\s*", ".", text, flags=re.I)
    # "name at domain dot com" / "name AT domain DOT com", only when every token looks
    # like part of an address.
    text = re.sub(
        r"(?<![\w@.])([A-Za-z0-9][A-Za-z0-9._%+\-]{1,63})\s+(?:at|AT)\s+([A-Za-z0-9][A-Za-z0-9\-]{1,62})\s+(?:dot|DOT)\s+([A-Za-z]{2,10})\b",
        _at_dot_repl,
        text,
    )
    # "info @ venue.com": spaces around a real @ between address-shaped tokens.
    text = re.sub(r"(?<![\w@.])([A-Za-z0-9][A-Za-z0-9._%+\-]{0,63})\s+@\s+([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,10})\b",
                  _spaced_at_repl, text)
    return text


# Tags wrapped around the pieces of an address ("info<span>@</span>venue<b>.</b>com")
# hide it from the regex. Only tags touching the @, and dots on the domain side of it,
# are dropped: a tag after a sentence's full stop must not glue "details." to "lynne@".
# One or more tags with optional whitespace before each and after the last. Written
# so each whitespace run can only be matched one way: the nested (\s*<..>\s*)+ form
# backtracked exponentially on a real club homepage and hung the crawl.
_TAGS = r"\s*<[^<>]{0,200}>(?:\s*<[^<>]{0,200}>)*\s*"
_TAG_AT_RE = re.compile(r"([A-Za-z0-9._%+\-])" + _TAGS + r"@(?:" + _TAGS + r")?(?=[A-Za-z0-9])|"
                        r"([A-Za-z0-9._%+\-])@" + _TAGS + r"(?=[A-Za-z0-9])")
_TAG_DOMAIN_DOT_RE = re.compile(r"(@[A-Za-z0-9\-]{1,63}(?:\.[A-Za-z0-9\-]{1,63}){0,5})(?:" + _TAGS + r")?\.(?:" + _TAGS + r")?(?=[A-Za-z]{2,})")


def _join_split_addresses(work: str) -> str:
    joined = _TAG_AT_RE.sub(lambda m: (m.group(1) or m.group(2)) + "@", work)
    for _ in range(3):
        nxt = _TAG_DOMAIN_DOT_RE.sub(lambda m: m.group(1) + ".", joined)
        if nxt == joined:
            break
        joined = nxt
    return joined


def extract_emails(text: str) -> List[Dict[str, object]]:
    decoded = _decode_for_emails(text or "")
    work = deobfuscate_text(decoded)
    mailtos: Set[str] = set()
    for raw in MAILTO_RE.findall(decoded):
        for part in re.split(r"[,;]", raw):  # mailto:a@x.com,b@x.com
            email = clean_email(part)
            if email:
                mailtos.add(email)
    found: Dict[str, Dict[str, object]] = {}

    def keep(email: Optional[str], mailto: bool = False) -> None:
        if not email:
            return
        rec = found.setdefault(email, {"email": email, "generic": _is_generic(email), "mailto": False})
        rec["mailto"] = bool(rec["mailto"] or mailto or email in mailtos)

    matches = EMAIL_RE.findall(work)
    if "<" in work and "@" in work:
        joined = _join_split_addresses(work)
        if joined != work:
            matches += [m for m in EMAIL_RE.findall(joined) if m not in matches]
    for match in matches:
        head, _, last = match.rpartition(".")
        dom = head.split("@", 1)[-1]
        # "info@x.com.Read more" / "events@venue.com.Our team": the next sentence ran
        # into the domain. A capitalised last label after a lower-case domain is text.
        if ("." in dom and last.isalpha() and dom == dom.lower()
                and (last[:1].isupper() or last.lower() in {"read", "more", "see", "view", "call", "visit"})):
            email = clean_email(head)
        else:
            email = clean_email(match)
        keep(email)
    for enc in CF_RE.findall(text or "") + CF_HREF_RE.findall(text or ""):
        keep(decode_cf_email(enc), mailto=True)
    for email in mailtos:
        keep(email, mailto=True)
    return list(found.values())


# ---------------------------------------------------------------------------
# Location parsing for Google listing text / stored addresses (discover.sh and
# repair_locations.sh import this). DC quadrants ("5th St NE") are not Nebraska.
# ---------------------------------------------------------------------------
US_STATES = (
    "AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|"
    "NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC"
)
_STATE_TOKEN_RE = re.compile(r"\b(" + US_STATES + r")\b")
_STREET_SUFFIX = (
    r"(?:st|street|ave|avenue|rd|road|blvd|boulevard|pl|place|dr|drive|ct|court|ter|terrace|"
    r"way|ln|lane|pkwy|parkway|cir|circle|sq|square|hwy|highway|pike|row|walk|plaza|alley|mall)"
)
_QUADRANT_AFTER_STREET_RE = re.compile(r"\b" + _STREET_SUFFIX + r"\.?\s*$", re.I)
_STREET_LINE_RE = re.compile(r"^\s*\d+[A-Za-z]?(?:-\d+)?\s+\S+", re.I)
_CITY_JUNK_RE = re.compile(r"https?:|www\.|\.com|@|phone|email|[·•⋅()★|$]|\d", re.I)


def _valid_state_matches(text: str) -> List["re.Match[str]"]:
    out = []
    for m in _STATE_TOKEN_RE.finditer(text):
        before = text[:m.start()]
        # A token right after a street word ("5th St NE", "Maine Ave SW") is a DC quadrant.
        if _QUADRANT_AFTER_STREET_RE.search(before):
            continue
        # Nebraska is only a state when written like one: ", NE" (optionally + ZIP).
        if m.group(1) == "NE" and not re.search(r",\s*$", before):
            continue
        out.append(m)
    return out


def parse_location(text: str) -> Tuple[str, str]:
    """(city, state) from a listing/address line; '' for anything not clearly present.

    '1309 5th St NE, Washington, DC 20002' -> ('Washington', 'DC')
    '1309 5th St NE'                        -> ('', '')
    'Omaha, NE 68102'                       -> ('Omaha', 'NE')
    """
    t = re.sub(r"\s+", " ", (text or "")).strip()
    if not t:
        return "", ""
    t = re.sub(r",?\s*(?:USA|United States)\.?$", "", t, flags=re.I)
    matches = _valid_state_matches(t)
    if not matches:
        return "", ""
    zip_matches = [m for m in matches if re.match(r"\s+\d{5}(?:-\d{4})?\b", t[m.end():])]
    m = (zip_matches or matches)[-1]
    state = m.group(1)
    before = t[:m.start()].rstrip(" ,")
    parts = [p.strip() for p in before.split(",")]
    city = parts[-1] if parts else ""
    if (not city or _STREET_LINE_RE.match(city) or _CITY_JUNK_RE.search(city)
            or len(city) > 40 or len(city) < 2 or _QUADRANT_AFTER_STREET_RE.search(city)):
        city = ""
    return city, state


def looks_like_street_address(text: str) -> bool:
    t = (text or "").strip()
    return bool(t) and len(t) <= 120 and bool(_STREET_LINE_RE.match(t)) and not re.search(r"[★()]|reviews?", t, re.I)


def _extract_links_regex(html: str, base_url: str) -> List[Tuple[str, str]]:
    links: List[Tuple[str, str]] = []
    # Loose fallback: captures href and nearby anchor text when possible.
    for m in re.finditer(r"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", html, re.I | re.S):
        href, body = m.group(1), re.sub(r"<[^>]+>", " ", m.group(2))
        url = normalize_url(href, base_url, keep_fragment=True)
        if url:
            links.append((url, html_lib.unescape(re.sub(r"\s+", " ", body)).strip()))
    # Also catch hrefs where closing anchor isn't available in the sample.
    for href in re.findall(r"href=[\"']([^\"']+)[\"']", html, re.I):
        url = normalize_url(href, base_url, keep_fragment=True)
        if url:
            links.append((url, ""))
    return links + _extra_page_links(html, base_url)


_FRAME_SRC_RE = re.compile(r"<(?:i?frame)\b[^>]*\bsrc=[\"']([^\"']+)[\"']", re.I)
_META_REFRESH_RE = re.compile(
    r"<meta\b[^>]*http-equiv=[\"']?refresh[\"']?[^>]*content=[\"'][^\"']*?url\s*=\s*['\"]?([^\"'>\s;]+)", re.I)


def _extra_page_links(html: str, base_url: str) -> List[Tuple[str, str]]:
    """Pages reached without an <a>: old frameset sites, same-site iframes and
    <meta refresh> landing pages would otherwise be dead ends."""
    out: List[Tuple[str, str]] = []
    for raw in _FRAME_SRC_RE.findall(html or "") + _META_REFRESH_RE.findall(html or ""):
        url = normalize_url(raw, base_url, keep_fragment=True)
        if url:
            out.append((url, "frame"))
    return out


def extract_links(html: str, base_url: str) -> List[Tuple[str, str]]:
    try:
        from bs4 import BeautifulSoup  # type: ignore

        soup = BeautifulSoup(html, "html.parser")
        out: List[Tuple[str, str]] = []
        for a in soup.find_all(["a", "area"], href=True):
            url = normalize_url(a.get("href", ""), base_url, keep_fragment=True)
            if not url:
                continue
            text = " ".join(
                x for x in [a.get_text(" ", strip=True), a.get("aria-label", ""), a.get("title", ""),
                            a.get("alt", "")] if x
            )
            out.append((url, text))
        return out + _extra_page_links(html, base_url)
    except Exception:
        return _extract_links_regex(html, base_url)


def _polite_wait() -> None:
    if CRAWL_DELAY <= 0:
        return
    wait = _LAST_REQUEST[0] + CRAWL_DELAY - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _LAST_REQUEST[0] = time.monotonic()


# Last outcome per requested URL ("200", "403", "timeout", ...), so a crawl that got
# nothing can say whether the site blocked us or simply had nothing.
FETCH_STATUS: Dict[str, str] = {}


def _fetch(session: requests.Session, url: str, timeout: int = 10) -> Optional[requests.Response]:
    _polite_wait()
    try:
        resp = session.get(url, headers=HEADERS, timeout=timeout, allow_redirects=True)
        FETCH_STATUS[url] = str(resp.status_code)
        if resp.status_code >= 400:
            return None
        return resp
    except requests.Timeout:
        FETCH_STATUS[url] = "timeout"
        return None
    except requests.RequestException as e:
        FETCH_STATUS[url] = "error:" + type(e).__name__
        return None


# ---------------------------------------------------------------------------
# Page analysis: contact forms, page kinds, bot walls, names next to emails.
# ---------------------------------------------------------------------------
# Booking / inquiry form services venues embed or link for event leads.
FORM_PROVIDERS = {
    "tripleseat.com": "tripleseat", "perfectvenue.com": "perfectvenue",
    "eventtemple.com": "eventtemple", "sevenrooms.com": "sevenrooms",
    "jotform.com": "jotform", "typeform.com": "typeform", "wufoo.com": "wufoo",
    "formstack.com": "formstack", "cognitoforms.com": "cognitoforms",
    "hsforms.com": "hubspot", "hsforms.net": "hubspot", "forms.gle": "google_forms",
    "123formbuilder.com": "123formbuilder", "formsite.com": "formsite",
    "honeybook.com": "honeybook", "dubsado.com": "dubsado", "zohopublic.com": "zoho_forms",
    "planningpod.com": "planningpod", "gatherhere.com": "gather", "caterzen.com": "caterzen",
}
_PROVIDER_URL_RE = re.compile(
    r"""(?:src|href|action)=["']((?:https?:)?//[^"'\s<>]*?(?:%s)[^"'\s<>]*)["']"""
    % "|".join(re.escape(d) for d in list(FORM_PROVIDERS) + ["docs.google.com/forms"]), re.I)
_FORM_BLOCK_RE = re.compile(r"<form\b([^>]*)>(.*?)</form>", re.I | re.S)
# Site-builder form widgets that render client-side (no <form> in the static HTML).
_FORM_WIDGET_RE = re.compile(
    r"wpcf7|gform_wrapper|wpforms-form|nf-form-cont|frm_forms|sqs-block-form|"
    r"form-block|caldera_forms|fluentform|wixui-form|data-hs-forms", re.I)
_NOT_CONTACT_FORM_RE = re.compile(
    r"search|newsletter|subscribe|mailchimp|list-manage|signup|sign-up|login|log-in|"
    r"password|cart|checkout|coupon|giftcard|gift-card|donat", re.I)


def detect_contact_forms(html: str, page_url: str) -> List[Dict[str, str]]:
    found: Dict[str, Dict[str, str]] = {}
    for raw in _PROVIDER_URL_RE.findall(html or ""):
        url = html_lib.unescape(raw)
        if url.startswith("//"):
            url = "https:" + url
        host = canonical_host(url)
        kind = next((v for k, v in FORM_PROVIDERS.items() if host == k or host.endswith("." + k)), "")
        if not kind and "docs.google.com/forms" in url:
            kind = "google_forms"
        if kind and url not in found:
            # A provider's script include means the form is on this page.
            target = page_url if re.search(r"\.js(?:[?#]|$)", url) else url
            found.setdefault(target, {"url": target, "page": page_url, "kind": kind})
    for attrs, body in _FORM_BLOCK_RE.findall(html or ""):
        if _NOT_CONTACT_FORM_RE.search(attrs):
            continue
        has_message = re.search(r"<textarea\b", body, re.I)
        has_email = re.search(r"type=[\"']?email|name=[\"'][^\"']*e-?mail", body, re.I)
        n_fields = len(re.findall(r"<(?:input|select|textarea)\b(?![^>]*type=[\"']?(?:hidden|submit|button))", body, re.I))
        if has_message or (has_email and n_fields >= 3 and not _NOT_CONTACT_FORM_RE.search(body[:2000])):
            found.setdefault(page_url, {"url": page_url, "page": page_url, "kind": "html_form"})
            break
    if page_url not in found and _FORM_WIDGET_RE.search(html or ""):
        found[page_url] = {"url": page_url, "page": page_url, "kind": "form_widget"}
    return list(found.values())


PAGE_KIND_RULES = (
    ("contact", re.compile(r"contact|get-?in-?touch|inquir|enquir|reach-?us|connect|find-?us|location", re.I)),
    ("team", re.compile(r"team|staff|people|leadership|directory|management|who-?we-?are|meet-|board|our-?story", re.I)),
    ("events", re.compile(r"event|private|wedding|banquet|cater|group|part(?:y|ies)|celebrat|meeting|rental|venue|book", re.I)),
    ("about", re.compile(r"about|history|story", re.I)),
)


def page_kind(url: str) -> str:
    path = urlparse(url).path or "/"
    if path in ("", "/") or re.fullmatch(r"/(?:index|home|default)(?:\.\w+)?", path, re.I):
        return "home"
    for kind, rx in PAGE_KIND_RULES:
        if rx.search(path):
            return kind
    return "other"


_BOT_WALL_RE = re.compile(
    r"cf-browser-verification|challenge-platform|cf_chl_|Attention Required! \| Cloudflare|"
    r"<title>\s*Just a moment|captcha-delivery|px-captcha|Incapsula incident|"
    r"Sucuri WebSite Firewall|<title>\s*Access Denied|Request unsuccessful\. Incapsula", re.I)


def bot_wall(resp: Optional[requests.Response], status: str) -> str:
    """Reason the site refused a scripted visitor ('' if it didn't)."""
    if status in ("401", "403", "406", "429", "503"):
        return "http_" + status
    if resp is not None and len(resp.text or "") < 60000 and _BOT_WALL_RE.search(resp.text or ""):
        return "challenge_page"
    return ""


_BLOCK_TAGS_RE = re.compile(r"<(script|style|noscript|svg|template)\b.*?</\1\s*>", re.I | re.S)
_BREAK_TAGS_RE = re.compile(r"<(?:br|/p|/div|/li|/h[1-6]|/tr|/td|/th|/dt|/dd|/section|/article|hr)\b[^>]*>", re.I)


def visible_text(html: str) -> str:
    t = _BLOCK_TAGS_RE.sub(" ", html or "")
    t = _BREAK_TAGS_RE.sub("\n", t)
    t = re.sub(r"<[^>]+>", " ", t)
    t = html_lib.unescape(t)
    t = re.sub(r"[ \t\r\f\v\u00a0]+", " ", t)
    return re.sub(r"\s*\n\s*", "\n", t).strip()


_TITLE_WORDS = {
    "director", "manager", "coordinator", "planner", "specialist", "owner", "co-owner",
    "proprietor", "founder", "co-founder", "president", "partner", "chef", "sommelier",
    "curator", "administrator", "supervisor", "captain", "concierge", "assistant",
    "associate", "executive", "senior", "general", "private", "special", "sales",
    "events", "event", "catering", "banquet", "banquets", "wedding", "weddings",
    "marketing", "membership", "beverage", "food", "hospitality", "operations",
    "office", "guest", "services", "head", "lead", "chief", "vice", "vp", "gm", "host",
}
_NOT_NAME_WORDS = {
    "please", "email", "e-mail", "contact", "inquiries", "inquiry", "questions", "call",
    "write", "reach", "send", "for", "dining", "reservations", "booking", "bookings",
    "media", "press", "hours", "location", "directions", "phone", "tel", "fax", "street",
    "avenue", "road", "suite", "floor", "north", "south", "east", "west", "washington",
    "virginia", "maryland", "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december", "welcome",
    "thank", "thanks", "follow", "join", "visit", "learn", "more", "read", "view",
    "by", "appointment", "only", "open", "closed", "reservation", "details", "ask",
    "tasting", "wine", "club", "room", "tours", "tour", "gift", "shop", "order",
}
_NAME_SEQ_RE = re.compile(r"[A-Z][a-zA-Z'\u2019\-]+(?:[ \t]+(?:[A-Z]\.|[A-Z][a-zA-Z'\u2019\-]+)){1,3}")
_TITLE_RE = re.compile(
    r"\b((?:(?:Senior|Sr\.?|Assistant|Asst\.?|Associate|Executive|General|Private|Special|Group|"
    r"Wedding|Weddings|Catering|Banquet|Banquets|Event|Events|Sales|Marketing|Membership|"
    r"Food (?:&|and) Beverage|F&B|Beverage|Hospitality|Operations|Club|Front Office|Guest Services|"
    r"Managing|Gallery|Music|Program|Programs|Programming|Creative|Artistic|Venue|Restaurant|Wine|"
    r"Tasting Room|Business|Development|Community|Social|Clubhouse|Floor|Dining Room|Bar|"
    r"Director of|Manager of)[ \t]+){0,3}"
    r"(?:Director|Manager|Coordinator|Planner|Specialist|Co-Owner|Owner|Proprietor|Co-Founder|"
    r"Founder|President|Partner|Chef|Sommelier|Curator|Administrator|Supervisor|Concierge|GM)"
    r"(?:[ \t]+(?:of|for)[ \t]+(?:[A-Z][A-Za-z&]+[ \t]?){1,4})?)")


def _generic_venue_word(w: str) -> bool:
    return R is not None and w in getattr(R, "_GENERIC_VENUE_WORDS", set())


def _name_before(before: str) -> str:
    if R is None:
        return ""
    for m in reversed(list(_NAME_SEQ_RE.finditer(before))):
        toks = m.group(0).split()
        for k in (3, 2):
            if len(toks) < k:
                continue
            cand = toks[-k:]
            low = [t.lower().strip(".,") for t in cand]
            if any(w in _TITLE_WORDS or w in _NOT_NAME_WORDS or _generic_venue_word(w) for w in low):
                continue
            name = R.clean_person_name(" ".join(cand))
            if name:
                return name
    return ""


def _strict_name(text: str) -> str:
    """The whole segment is a person's name ('Eric Kole'), else ''."""
    t = re.sub(r"\s+", " ", text or "").strip(" \t,;:|-\u2013\u2014")
    if R is None or not t or len(t) > 40 or not _NAME_SEQ_RE.fullmatch(t):
        return ""
    low = [w.lower().strip(".,") for w in t.split()]
    if any(w in _TITLE_WORDS or w in _NOT_NAME_WORDS or _generic_venue_word(w) for w in low):
        return ""
    return R.clean_person_name(t)


_TITLE_SEG_RE = re.compile(_TITLE_RE.pattern, re.I)


def _title_segment(text: str) -> str:
    """The segment is (mostly) a job title ('General Manager & Partner'), else ''."""
    t = re.sub(r"\s+", " ", text or "").strip(" \t,;:|-\u2013\u2014")
    if not t or len(t) > 60:
        return ""
    m = _TITLE_SEG_RE.search(t)
    return t if m and len(m.group(1)) >= 0.5 * len(t) else ""


_PEOPLE_SPLIT_RE = re.compile(r"\s*(?:,|\||:|\s[-\u2013\u2014]\s|\u2013|\u2014)\s*")


def extract_people(text: str) -> List[Dict[str, str]]:
    """Named people with a job title on a page ('Eric Kole, General Manager & Partner',
    'Tony Hardy - Gallery Director', or a name line followed by a title line), whether
    or not an email is next to them. Candidates for the caller's P3 checks."""
    out: Dict[str, Dict[str, str]] = {}
    lines = [ln.strip() for ln in (text or "").split("\n") if ln.strip()]

    def keep(name: str, title: str) -> None:
        if name and title and name.lower() not in out and len(out) < 60:
            out[name.lower()] = {"name": name, "title": title}

    for i, line in enumerate(lines):
        line = EMAIL_RE.sub(" ", line).strip()  # "Devika Strother, Founder devika@..."
        if line and len(line) <= 160:
            segs = [x for x in _PEOPLE_SPLIT_RE.split(line) if x]
            for a, b in zip(segs, segs[1:]):
                n, t = _strict_name(a), _title_segment(b)
                if n and t:
                    keep(n, t)
                    continue
                t, n = _title_segment(a), _strict_name(b)
                if n and t:
                    keep(n, t)
        if line and i + 1 < len(lines):
            n, t = _strict_name(line), _title_segment(lines[i + 1])
            if n and t:
                keep(n, t)
            t2, n2 = _title_segment(line), _strict_name(lines[i + 1])
            if n2 and t2:
                keep(n2, t2)
    return list(out.values())


_CF_ELEMENT_RE = re.compile(
    r"<(a|span)\b[^>]*?(?:data-cfemail=[\"']([0-9a-fA-F]{4,})[\"']|/cdn-cgi/l/email-protection#([0-9a-fA-F]{4,}))"
    r"[^>]*>(.{0,400}?)</\1\s*>", re.I | re.S)


def decode_cf_html(html: str) -> str:
    """Put Cloudflare-protected addresses back into the markup ("[email protected]" ->
    the address) so the text around them, e.g. a staff name, can be read."""
    def repl(m: "re.Match[str]") -> str:
        email = decode_cf_email(m.group(2) or m.group(3) or "") or ""
        inner = m.group(4) or ""
        if "protected" in inner.lower() or not re.sub(r"<[^>]+>|\s", "", inner):
            return " " + email + " "
        return inner + " " + email + " "
    return _CF_ELEMENT_RE.sub(repl, html or "")


def page_text(html: str) -> str:
    """Visible text with Cloudflare and [at]/(dot) obfuscation undone."""
    return deobfuscate_text(visible_text(decode_cf_html(html)))


def _name_fits_email(name: str, email: str) -> bool:
    """A name next to a personal address must be that person's ("Lynne Basignani" is
    not bert@). A role mailbox (events@) can carry whoever is named beside it."""
    if R is None or R.is_role_email(email):
        return True
    local = re.sub(r"[^a-z]", "", email.split("@", 1)[0].lower())
    toks = [t for t in (re.sub(r"[^a-z]", "", w.lower()) for w in name.split()) if len(t) >= 2]
    if not local or not toks:
        return False
    first, last = toks[0], toks[-1]
    return (first in local or last in local or local in (first[0] + last, first + last[0])
            or local.startswith(first[0] + last[:3]))


def email_contexts(text: str, emails: Iterable[str]) -> Dict[str, Dict[str, str]]:
    """Visible text around each email plus a conservative person-name / title hint
    ("Liz McQuay, Events Manager - events@venue.com"). Hints are evidence for the
    caller to check (clean-name, venue-name clash), never a verified contact."""
    out: Dict[str, Dict[str, str]] = {}
    low = text.lower()
    for email in emails:
        e_low = email.lower()
        i = low.find(e_low)
        seen_at = 0
        while i >= 0 and seen_at < 5:
            seen_at += 1
            start = max(0, i - 160)
            prev = low.rfind("@", start, i)  # don't borrow the name of the previous address
            if prev >= 0:
                nl = text.find("\n", prev)
                sp = text.find(" ", prev)
                cut = min(x for x in (nl, sp, i) if x >= 0)
                start = max(start, cut)
            # A name/title sits on the same line or the two lines above ("Liz McQuay /
            # Events Manager / events@..."), or after the address on the same line.
            before = "\n".join(text[start:i].split("\n")[-3:])
            after = text[i + len(email): i + len(email) + 80].split("\n")[0].split("@")[0]
            name = _name_before(before)
            if name and not _name_fits_email(name, email):
                name = ""
            tm = _TITLE_RE.search(before[-100:]) or _TITLE_RE.search(after)
            rec = {
                "context": re.sub(r"\s+", " ", (before[-100:] + email + after[:60])).strip(),
                "name_hint": name,
                "title_hint": tm.group(1).strip() if tm else "",
            }
            if email not in out or (name and not out[email]["name_hint"]):
                out[email] = rec
            if name:
                break  # the first occurrence that names someone wins
            i = low.find(e_low, i + len(e_low))
    return out


class RobotsGate:
    """robots.txt Disallow rules per origin. Anything that goes wrong fetching or
    parsing robots.txt is treated as allow-all, so a flaky robots file never costs
    a venue its crawl."""

    def __init__(self, session: requests.Session, timeout: int = 8):
        self.session = session
        self.timeout = timeout
        self._parsers: Dict[str, Optional[urllib.robotparser.RobotFileParser]] = {}
        self._texts: Dict[str, str] = {}

    @staticmethod
    def _origin(url: str) -> str:
        p = urlparse(url)
        return f"{p.scheme}://{p.netloc}"

    def _load(self, origin: str) -> Optional[urllib.robotparser.RobotFileParser]:
        if origin in self._parsers:
            return self._parsers[origin]
        parser = None
        text = ""
        resp = _fetch(self.session, origin + "/robots.txt", self.timeout)
        if resp is not None and "html" not in (resp.headers.get("content-type") or "").lower():
            text = resp.text or ""
            try:
                parser = urllib.robotparser.RobotFileParser()
                parser.parse(text.splitlines())
            except Exception:
                parser = None
        self._parsers[origin] = parser
        self._texts[origin] = text
        return parser

    def text(self, url: str) -> str:
        origin = self._origin(url)
        self._load(origin)
        return self._texts.get(origin, "")

    def allowed(self, url: str) -> bool:
        parser = self._load(self._origin(url))
        if parser is None:
            return True
        try:
            return bool(parser.can_fetch(USER_AGENT, url))
        except Exception:
            return True


def _parse_sitemap_xml(text: str) -> Tuple[List[str], List[str]]:
    urls: List[str] = []
    sitemaps: List[str] = []
    try:
        root = ET.fromstring(text)
        tag = root.tag.lower()
        locs = [el.text.strip() for el in root.iter() if el.tag.lower().endswith("loc") and el.text]
        if tag.endswith("sitemapindex"):
            sitemaps.extend(locs)
        else:
            urls.extend(locs)
    except ET.ParseError:
        locs = re.findall(r"<loc>\s*(.*?)\s*</loc>", text, flags=re.I | re.S)
        # Guess based on extension.
        for loc in locs:
            if "sitemap" in loc.lower() and loc.lower().split("?")[0].endswith(".xml"):
                sitemaps.append(html_lib.unescape(loc.strip()))
            else:
                urls.append(html_lib.unescape(loc.strip()))
    return urls, sitemaps


def discover_seeds(base_url: str, limit: int = 80, timeout: int = 8,
                   robots: Optional[RobotsGate] = None) -> Dict[str, object]:
    normalized_base = normalize_url(base_url, base_url, keep_fragment=False) or base_url
    parsed = urlparse(normalized_base)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    session = requests.Session()
    if robots is None:
        robots = RobotsGate(session, timeout)

    candidates: Dict[str, Dict[str, object]] = {}
    sitemaps_checked: List[str] = []

    def add(url: str, source: str, text: str = "") -> None:
        norm = normalize_url(url, normalized_base, keep_fragment=True)
        if not norm or not same_origin(norm, normalized_base):
            return
        kind = classify_url(norm)
        if kind == "asset":
            return
        item = candidates.get(norm)
        score = score_url(norm, text)
        if not item or score < int(item["score"]):
            candidates[norm] = {"url": norm, "kind": kind, "score": score, "source": source}
        elif item["source"] == "known-path" and source != "known-path":
            item["source"] = source  # the guessed path really exists (sitemap lists it)

    for path in KNOWN_PATHS:
        add(origin + path, "known-path")

    sitemap_queue: deque[str] = deque([origin + "/sitemap.xml"])
    for line in robots.text(origin + "/").splitlines():
        if line.strip().lower().startswith("sitemap:"):
            loc = line.split(":", 1)[1].strip()
            if loc:
                sitemap_queue.append(loc)

    seen_sitemaps: Set[str] = set()
    while sitemap_queue and len(seen_sitemaps) < 12:
        sm = normalize_url(sitemap_queue.popleft(), normalized_base, keep_fragment=False)
        if not sm or sm in seen_sitemaps or not same_origin(sm, normalized_base):
            continue
        seen_sitemaps.add(sm)
        resp = _fetch(session, sm, timeout)
        if resp is None:
            continue
        sitemaps_checked.append(sm)
        urls, nested = _parse_sitemap_xml(resp.text)
        for n in nested[:50]:
            sitemap_queue.append(n)
        for url in urls[:5000]:
            norm = normalize_url(url, normalized_base, keep_fragment=True)
            if not norm or not same_origin(norm, normalized_base):
                continue
            # Sitemap can be huge: include all high-value pages/PDFs, plus shallow pages.
            s = score_url(norm)
            shallow = len([p for p in urlparse(norm).path.split("/") if p]) <= 2
            if s < 2 * _KW_COUNT or shallow or classify_url(norm) == "pdf":
                add(norm, "sitemap")

    ordered = sorted(candidates.values(), key=lambda x: (int(x["score"]), len(str(x["url"]))))
    pages = [x for x in ordered if x["kind"] == "page"][:limit]
    pdfs = [x for x in ordered if x["kind"] == "pdf"][: max(10, limit // 3)]
    return {"base": normalized_base, "pages": pages, "pdfs": pdfs, "sitemaps_checked": sitemaps_checked}


def _pdf_text_and_method(data: bytes) -> Tuple[str, str]:
    """Text of a PDF plus which extractor produced it. Link annotations (mailto: URIs)
    are appended, since event-packet PDFs often carry the address only as a link."""
    # PyMuPDF / PyPDF2 ship with the interpreter env_check.sh selects; pypdf and
    # pdftotext often aren't usable here (the Homebrew pdftotext is Intel-only).
    try:
        import fitz  # type: ignore
        doc = fitz.open(stream=data, filetype="pdf")
        parts = []
        for page in doc:
            parts.append(page.get_text() or "")
            for link in page.get_links() or []:
                if link.get("uri"):
                    parts.append(" " + str(link["uri"]) + " ")
        return "\n".join(parts), "pymupdf"
    except Exception:
        pass
    for mod in ("pypdf", "PyPDF2"):
        try:
            PdfReader = __import__(mod, fromlist=["PdfReader"]).PdfReader
            import io
            reader = PdfReader(io.BytesIO(data))
            parts = []
            for page in reader.pages:
                parts.append(page.extract_text() or "")
                for annot in page.get("/Annots") or []:
                    try:
                        uri = annot.get_object().get("/A", {}).get("/URI")
                        if uri:
                            parts.append(" " + str(uri) + " ")
                    except Exception:
                        pass
            return "\n".join(parts), mod.lower()
        except Exception:
            pass

    # pdftotext if installed (and runnable).
    if shutil.which("pdftotext"):
        with tempfile.TemporaryDirectory() as td:
            pdf = os.path.join(td, "in.pdf")
            txt = os.path.join(td, "out.txt")
            with open(pdf, "wb") as f:
                f.write(data)
            try:
                subprocess.run(["pdftotext", "-layout", pdf, txt], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
                if os.path.exists(txt):
                    return open(txt, "r", encoding="utf-8", errors="ignore").read(), "pdftotext"
            except Exception:
                pass

    # Last resort: emails sometimes appear literally in PDF objects (link URIs), and
    # FlateDecode content streams can be inflated and scanned.
    parts = [data.decode("latin-1", errors="ignore")]
    for m in re.finditer(rb"stream\r?\n(.*?)\r?\nendstream", data, re.S):
        try:
            parts.append(zlib.decompress(m.group(1)).decode("latin-1", errors="ignore"))
        except Exception:
            pass
    return "\n".join(parts), "raw_bytes"


def _pdf_text_from_bytes(data: bytes) -> str:
    return _pdf_text_and_method(data)[0]


# Real TLDs seen on venue sites. Only used to screen addresses scraped out of raw PDF
# bytes, where binary noise produces things like "6@u.ijw".
_RAW_SCAN_TLDS = {
    "com", "org", "net", "edu", "gov", "us", "biz", "info", "co", "io", "me", "club",
    "wine", "restaurant", "events", "email", "mil", "int", "uk", "ca", "de", "fr", "it",
    "es", "ie", "au", "nz", "art", "studio", "farm", "vin", "bar", "gallery", "golf",
    "yachts", "boats", "museum", "church", "hotel", "inn", "cafe", "life", "live",
    "music", "com.au", "co.uk",
}


def extract_pdf(url: str, timeout: int = 15) -> Dict[str, object]:
    session = requests.Session()
    resp = _fetch(session, url, timeout)
    if resp is None:
        return {"url": url, "ok": False, "emails": [], "error": "fetch_failed",
                "status": FETCH_STATUS.get(url, "")}
    text, method = _pdf_text_and_method(resp.content)
    emails = extract_emails(text)
    if method == "raw_bytes":
        emails = [e for e in emails
                  if str(e["email"]).rsplit(".", 1)[-1] in _RAW_SCAN_TLDS
                  and len(str(e["email"]).split("@", 1)[0]) >= 2
                  and all(len(lbl) >= 2 and not lbl.startswith("-") and not lbl.endswith("-")
                          for lbl in str(e["email"]).split("@", 1)[1].split("."))]
    return {"url": resp.url, "ok": True, "emails": emails, "text_chars": len(text), "method": method}


@dataclass
class CrawlItem:
    url: str
    depth: int
    score: int
    guess: bool = False  # a KNOWN_PATHS guess, not a link or sitemap entry


# Guessed paths that 404 look like a scanner to a WAF; stop guessing after this many.
MAX_GUESS_MISSES = 8
# This many failures in a row that look like rate limiting end the crawl (and say so).
MAX_THROTTLE_STREAK = 3
_THROTTLE_STATUSES = {"429", "444", "503", "520", "521", "522", "524", "timeout",
                      "error:ConnectionError", "error:ReadTimeout", "error:ChunkedEncodingError"}


# Website builders host many unrelated sites under one registrable domain.
PLATFORM_DOMAINS = {
    "wixsite.com", "wix.com", "squarespace.com", "wordpress.com", "weebly.com",
    "godaddysites.com", "business.site", "square.site", "webflow.io", "github.io",
    "blogspot.com", "myshopify.com", "carrd.co", "netlify.app", "vercel.app",
    "herokuapp.com", "site123.me", "jimdosite.com", "strikingly.com", "mystrikingly.com",
    "yolasite.com", "webs.com", "ueniweb.com", "tripod.com",
}
_GENERIC_LAST_SEGMENTS = {
    "overview", "home", "index", "index.html", "index.htm", "index.php", "default.aspx",
    "default.asp", "hotel-overview", "about", "about-us", "contact", "contact-us",
}


def _registrable(url: str) -> str:
    return R.registrable_domain(url) if R is not None else canonical_host(url)


def property_path_prefix(url: str) -> str:
    """'/sonesta-simply-suites/va/falls-church' for a property page on a shared brand
    domain (marriott.com, sonesta.com, ...), '' for a venue that owns its domain."""
    if R is None or not R.is_shared_domain(url):
        return ""
    segs = [p for p in urlparse(url).path.split("/") if p]
    while segs and segs[-1].lower() in _GENERIC_LAST_SEGMENTS:
        segs.pop()
    return ("/" + "/".join(segs)) if segs else ""


def static_crawl(base_url: str, max_pages: int = 25, max_depth: int = 2, timeout: int = 10,
                 path_prefix: str = "") -> Dict[str, object]:
    base = normalize_url(base_url, base_url, keep_fragment=True) or base_url
    session = requests.Session()
    robots = RobotsGate(session, min(timeout, 8))
    robots_disallowed: List[str] = []
    prefetched: Dict[str, requests.Response] = {}
    fetched_keys: Set[str] = set()

    # A stored website often redirects to another host (rebrand, apex -> brand site).
    # Crawl the host it lands on, while still accepting links back to the original.
    crawl_base = base
    redirected_to = ""
    base_key = normalize_url(base.split("#", 1)[0], base, keep_fragment=False) or base
    # A blanket "Disallow: /" would leave the venue's public contact pages unread (the
    # Chrome step and Alex visit them anyway), so it is recorded and not applied.
    # Path-specific Disallow rules are honoured. SITE_DISCOVERY_ROBOTS=strict honours all.
    robots_blanket = not robots.allowed(base_key)
    honor_robots = not robots_blanket or os.environ.get("SITE_DISCOVERY_ROBOTS", "") == "strict"

    def robots_ok(url: str) -> bool:
        return robots.allowed(url) if honor_robots else True

    first = _fetch(session, base_key, timeout) if robots_ok(base_key) else None
    home_status = FETCH_STATUS.get(base_key, "not_fetched")
    blocked = bot_wall(first, home_status)
    if first is not None and not blocked:
        prefetched[base_key] = first
        if canonical_host(first.url) and canonical_host(first.url) != canonical_host(base):
            crawl_base = normalize_url(first.url, first.url, keep_fragment=False) or first.url
            redirected_to = crawl_base
    scope_hosts = {h for h in (canonical_host(base), canonical_host(crawl_base)) if h}
    contact_forms: Dict[str, Dict[str, str]] = {}
    page_kinds: Dict[str, List[str]] = {}
    people: Dict[str, Dict[str, str]] = {}
    # On a shared brand domain only the property's own section is the venue's site;
    # crawling the brand site spends the budget on other properties' pages.
    prefix_src = first.url if (first is not None and not blocked) else base
    path_prefix = ("/" + path_prefix.strip("/")) if path_prefix.strip("/") else property_path_prefix(prefix_src)
    # A venue that owns its domain often links subdomains (events.venue.com,
    # weddings.venue.com); builder/brand domains stay host-exact.
    scope_regs: Set[str] = set()
    if not path_prefix:
        for u in (base, crawl_base):
            reg = _registrable(u)
            if (reg and reg not in PLATFORM_DOMAINS and "." in reg
                    and not (R is not None and (R.is_shared_domain(u) or R.is_non_venue_host(u)))):
                scope_regs.add(reg)

    def in_scope(url: str) -> bool:
        if url == base_key:
            return True
        if canonical_host(url) not in scope_hosts and _registrable(url) not in scope_regs:
            return False
        if path_prefix:
            p = (urlparse(url).path or "/").rstrip("/").lower()
            pre = path_prefix.lower()
            return p == pre or p.startswith(pre + "/")
        return True

    queue: List[CrawlItem] = [CrawlItem(base, 0, -1)]
    seen: Set[str] = set()
    pages: List[Dict[str, object]] = []
    contacts: Dict[str, Dict[str, object]] = {}
    pdf_urls: Set[str] = set()
    socials: Dict[str, Dict[str, object]] = {}
    discovered_pages: Set[str] = {base}
    fragment_states: Set[str] = set()

    seeds = discover_seeds(crawl_base, limit=max_pages * 2, timeout=min(timeout, 8), robots=robots)
    for item in seeds["pages"]:  # type: ignore[index]
        seed_url = str(item["url"])
        guess = item.get("source") == "known-path"
        if not guess:  # a guess is only a real page once it answers
            discovered_pages.add(seed_url)
        if urlparse(seed_url).fragment:
            fragment_states.add(seed_url)
        # Real links/sitemap pages of the same kind go before guesses.
        queue.append(CrawlItem(seed_url, 1, int(item["score"]) + (3 if guess else 0), guess))
    for item in seeds["pdfs"]:  # type: ignore[index]
        pdf_urls.add(str(item["url"]))

    attempts = 0
    successful_pages = 0
    max_attempts = max(max_pages * 4, max_pages + 20)
    if blocked:
        # Every further request would hit the same wall; confirm on a few pages and stop.
        max_attempts = min(max_attempts, 4)
    guess_misses = 0
    throttle_streak = 0
    throttled = ""
    route_family_counts: Dict[str, int] = {}  # e.g. "/event-" → how many visited
    ROUTE_FAMILY_CAP = 3  # max pages per URL pattern family

    deadline = time.monotonic() + CRAWL_MAX_SECONDS
    out_of_time = False
    while queue and successful_pages < max_pages and attempts < max_attempts:
        if time.monotonic() > deadline:
            out_of_time = True
            break
        # Relevance first, then depth. A second-hop "private events" page should beat
        # dozens of guessed /about-/staff paths that may all be 404/soft-404 pages.
        queue.sort(key=lambda x: (x.score, x.depth, len(x.url)))
        item = queue.pop(0)
        # Fetch fragments only once at HTTP level; retain fragment in evidence elsewhere.
        fetch_url = item.url.split("#", 1)[0]
        key = normalize_url(fetch_url, base, keep_fragment=False) or fetch_url
        vkey = _visit_key(key)
        if vkey in seen or not in_scope(key):
            continue
        seen.add(vkey)
        if classify_url(key) != "page":
            continue
        # Route-family dedup: skip detail pages (e.g. /event-NNN) once we've
        # visited enough from that family. This prevents 30+ event/blog/news
        # detail pages from consuming the entire crawl budget.
        family = _route_family(key)
        if (family and route_family_counts.get(family, 0) >= ROUTE_FAMILY_CAP
                and score_url(key) >= HIGH_PRIORITY_THRESHOLD):
            continue
        if item.guess and guess_misses >= MAX_GUESS_MISSES:
            continue
        if not robots_ok(key):
            robots_disallowed.append(key)
            continue
        attempts += 1
        fetched_keys.add(key)
        resp = prefetched.pop(key, None) or _fetch(session, key, timeout)
        if resp is None:
            status = FETCH_STATUS.get(key, "")
            pages.append({"url": key, "depth": item.depth, "ok": False, "emails": [],
                          "status": status})
            if item.guess:
                guess_misses += 1
            throttle_streak = throttle_streak + 1 if status in _THROTTLE_STATUSES else 0
            if throttle_streak >= MAX_THROTTLE_STREAK:
                throttled = f"{throttle_streak} requests in a row failed ({status}) - the site started refusing us"
                break
            continue
        throttle_streak = 0
        seen.add(_visit_key(resp.url))  # a redirect target is the same page
        ctype = (resp.headers.get("content-type") or "").lower()
        if "pdf" in ctype:
            pdf_urls.add(resp.url)
            continue
        successful_pages += 1
        if family:
            route_family_counts[family] = route_family_counts.get(family, 0) + 1
        html = resp.text
        page_emails = extract_emails(html)
        page_socials = extract_socials(html)
        # The start page is the venue's own landing page even when the stored website is a
        # deep link (a property page on a shared brand domain, /en/, /restaurant/...).
        kind = "home" if item.depth == 0 else page_kind(resp.url)
        page_kinds.setdefault(kind, [])
        if resp.url not in page_kinds[kind]:
            page_kinds[kind].append(resp.url)
        for form in detect_contact_forms(html, resp.url):
            contact_forms.setdefault(form["url"], form)
        text = page_text(html)
        contexts = email_contexts(text, [str(c["email"]) for c in page_emails]) if page_emails else {}
        for person in extract_people(text):
            key = person["name"].lower()
            if key not in people and len(people) < 100:
                people[key] = dict(person, page=resp.url)
        for platform, urls in page_socials.items():
            for social_url in urls:
                rec = socials.setdefault(social_url, {"url": social_url, "platform": platform, "sources": []})
                if resp.url not in rec["sources"]:
                    rec["sources"].append(resp.url)
        for c in page_emails:
            email = str(c["email"])
            existing = contacts.setdefault(email, {"email": email, "generic": bool(c.get("generic")), "mailto": False,
                                                   "sources": [], "name_hint": "", "title_hint": "", "contexts": []})
            existing["mailto"] = bool(existing.get("mailto") or c.get("mailto"))
            if resp.url not in existing["sources"]:  # type: ignore[index]
                existing["sources"].append(resp.url)  # type: ignore[index]
            ctx = contexts.get(email)
            if ctx:
                if len(existing["contexts"]) < 3:  # type: ignore[arg-type]
                    existing["contexts"].append({"page": resp.url, "text": ctx["context"]})  # type: ignore[union-attr]
                for k in ("name_hint", "title_hint"):
                    if ctx[k] and not existing[k]:
                        existing[k] = ctx[k]
        pages.append({"url": resp.url, "depth": item.depth, "ok": True, "kind": kind,
                      "emails": [c["email"] for c in page_emails], "socials": page_socials})

        if item.depth >= max_depth:
            continue
        for child, text in extract_links(html, resp.url):
            if not in_scope(child):
                continue
            kind = classify_url(child)
            if kind == "pdf":
                pdf_urls.add(child)
                continue
            if kind != "page":
                continue
            discovered_pages.add(child)
            if urlparse(child).fragment:
                fragment_states.add(child)
            fetch_child = child.split("#", 1)[0]
            if _visit_key(fetch_child) in seen:
                continue
            # Allow nav/shallow pages, prioritize relevant anchors/paths.
            queue.append(CrawlItem(child, item.depth + 1, score_url(child, text)))

    pdf_results: List[Dict[str, object]] = []
    for pdf in sorted(pdf_urls, key=score_url)[:10]:
        if time.monotonic() > deadline:
            out_of_time = True
            break
        if not robots_ok(pdf):
            robots_disallowed.append(pdf)
            continue
        result = extract_pdf(pdf, timeout=timeout)
        pdf_results.append(result)
        for c in result.get("emails", []):
            email = str(c["email"])
            existing = contacts.setdefault(email, {"email": email, "generic": bool(c.get("generic")), "mailto": False,
                                                   "sources": [], "name_hint": "", "title_hint": "", "contexts": []})
            if pdf not in existing["sources"]:  # type: ignore[index]
                existing["sources"].append(pdf)  # type: ignore[index]

    # A path-preserving redirect (old host /contact -> new host /contact) was still
    # visited, so count what we requested as well as where it landed.
    visited_fetch_urls = {
        _visit_key(str(p.get("url", "")).split("#", 1)[0])
        for p in pages
        if p.get("url")
    } | {_visit_key(k) for k in fetched_keys}
    unvisited_pages = []
    high_priority_unvisited = []
    for candidate in sorted(discovered_pages, key=lambda u: (score_url(u), len(u), u)):
        fetch_candidate = _visit_key(candidate.split("#", 1)[0])
        if not in_scope(candidate.split("#", 1)[0]):
            continue
        if fetch_candidate and fetch_candidate not in visited_fetch_urls:
            unvisited_pages.append(candidate)
            if score_url(candidate) < HIGH_PRIORITY_THRESHOLD:
                high_priority_unvisited.append(candidate)

    # stdout is reserved for the JSON result; callers json.load it.
    for hp in high_priority_unvisited:
        print(f"  [HIGH_PRIORITY_UNVISITED] {hp} (score={score_url(hp)})", file=sys.stderr)

    status_counts: Dict[str, int] = {}
    for key in fetched_keys:
        st = FETCH_STATUS.get(key, "prefetched" if key == base_key else "")
        status_counts[st] = status_counts.get(st, 0) + 1
    kinds_seen = {k for k in page_kinds}
    return {
        "base": base,
        "final_base": crawl_base,
        "redirected_to": redirected_to,
        "robots_disallowed": robots_disallowed[:50],
        # Evidence for "was every kind of page read?" and "is there a contact form?".
        "page_kinds": page_kinds,
        # Named people with a title (email or not): candidates for pending contacts.
        "people": list(people.values()),
        "contact_forms": sorted(contact_forms.values(), key=lambda f: (f["kind"] != "html_form", f["url"])),
        "pages": pages,
        "pdfs": pdf_results,
        "contacts": sorted(contacts.values(), key=lambda x: str(x["email"])),
        # Footer/header profile links usually repeat across pages. Prefer the profile
        # with the most independent website sources rather than alphabetic URL order.
        "socials": sorted(
            socials.values(),
            key=lambda x: (str(x["platform"]), -len(x.get("sources", [])), str(x["url"])),
        ),
        "sitemaps_checked": seeds.get("sitemaps_checked", []),
        "discovered_pages": sorted(discovered_pages, key=lambda u: (score_url(u), len(u), u)),
        "fragment_states": sorted(fragment_states, key=lambda u: (score_url(u), len(u), u)),
        "unvisited_pages": unvisited_pages,
        "high_priority_unvisited": high_priority_unvisited,
        "route_families_capped": {k: v for k, v in route_family_counts.items() if v >= ROUTE_FAMILY_CAP},
        "coverage": {
            "max_pages": max_pages,
            "max_depth": max_depth,
            "discovered_page_count": len(discovered_pages),
            "visited_page_count": len(pages),
            "attempt_count": attempts,
            "successful_page_count": sum(1 for p in pages if p.get("ok")),
            "failed_page_count": sum(1 for p in pages if not p.get("ok")),
            "max_attempts": max_attempts,
            "unvisited_page_count": len(unvisited_pages),
            "high_priority_unvisited_count": len(high_priority_unvisited),
            "pdf_count": len(pdf_results),
            "sitemap_count": len(seeds.get("sitemaps_checked", [])),
            "fragment_state_count": len(fragment_states),
            "robots_disallowed_count": len(robots_disallowed),
            "robots_blanket_disallow": robots_blanket,
            "time_budget_exceeded": out_of_time,
            "throttled": bool(throttled),
            "throttled_reason": throttled,
            "guess_misses": guess_misses,
            "path_prefix": path_prefix,
            "scope_domains": sorted(scope_regs),
            "robots_honored": honor_robots,
            "redirected": bool(redirected_to),
            "delay_seconds": CRAWL_DELAY,
            # blocked: the site refused the scripted fetch (403/429/503 or a bot-wall
            # page), so "no emails" means "not read", not "none there".
            "home_status": home_status,
            "blocked": bool(blocked),
            "blocked_reason": blocked,
            "status_counts": status_counts,
            "page_kinds_visited": sorted(kinds_seen),
            "page_kinds_missing": [k for k in ("home", "contact", "about", "events", "team") if k not in kinds_seen],
            "contact_form_count": len(contact_forms),
            "people_count": len(people),
        },
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p_seeds = sub.add_parser("seeds")
    p_seeds.add_argument("url")
    p_seeds.add_argument("--limit", type=int, default=80)

    p_pdf = sub.add_parser("pdf")
    p_pdf.add_argument("url")

    p_crawl = sub.add_parser("static-crawl")
    p_crawl.add_argument("url")
    p_crawl.add_argument("--max-pages", type=int, default=25)
    p_crawl.add_argument("--max-depth", type=int, default=2)
    p_crawl.add_argument("--path-prefix", default="",
                         help="only crawl URLs under this path (property pages on a brand domain); "
                              "auto-detected for shared brand domains")

    p_loc = sub.add_parser("parse-location")
    p_loc.add_argument("text")

    args = parser.parse_args(argv)
    if args.command == "seeds":
        result = discover_seeds(args.url, limit=args.limit)
    elif args.command == "pdf":
        result = extract_pdf(args.url)
    elif args.command == "parse-location":
        city, state = parse_location(args.text)
        result = {"city": city, "state": state}
    else:
        result = static_crawl(args.url, max_pages=args.max_pages, max_depth=args.max_depth,
                              path_prefix=args.path_prefix)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
