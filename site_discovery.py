#!/usr/bin/env python3
"""Reusable website-discovery helpers for the outreach pipeline.

This module is intentionally conservative about dependencies. It uses requests (already
required by this project) and falls back to regex parsing if BeautifulSoup/pypdf are not
installed.

CLI examples:
  python3 site_discovery.py seeds https://example.com --limit 80
  python3 site_discovery.py pdf https://example.com/private-events.pdf
  python3 site_discovery.py static-crawl https://example.com --max-pages 25 --max-depth 2
"""

from __future__ import annotations

import argparse
import html as html_lib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import deque
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Set, Tuple
from urllib.parse import parse_qsl, quote, unquote, urlencode, urljoin, urlparse, urlunparse

import requests

USER_AGENT = os.environ.get(
    "OUTREACH_USER_AGENT",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
)
HEADERS = {"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}

EMAIL_RE = re.compile(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)
CF_RE = re.compile(r'data-cfemail=["\']([a-fA-F0-9]+)["\']')
TRACKING_KEYS = {"fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "ref", "source"}
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
    # Common site-builder/template accounts are not venue evidence.
    "wix", "wixstudio", "squarespace", "wordpress", "shopify", "godaddy", "weebly",
    "webflow", "carrd", "linktree", "linktr",
}
IG_RESERVED = {
    "p", "reel", "reels", "explore", "stories", "accounts", "developer", "about",
    "legal", "privacy", "terms", "share", "embed", "direct", "tv",
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
    "private-event", "private_event", "private event", "events", "event", "wedding",
    "cater", "banquet", "group-dining", "group dining", "private-dining", "private dining",
    "meeting", "corporate", "sales", "book", "inquiry", "enquiry", "contact", "team",
    "staff", "people", "leadership", "about", "press", "media", "rental", "party",
    "celebration", "hospitality", "venue", "groups", "special-events", "special events",
]

# Good fallback paths. They are seeds only; callers still verify/fetch them.
KNOWN_PATHS = [
    "/contact", "/contact-us", "/get-in-touch", "/inquiry", "/enquiry",
    "/events", "/private-events", "/special-events", "/book-an-event", "/book-event",
    "/private-dining", "/group-dining", "/groups", "/catering", "/weddings", "/meetings",
    "/corporate-events", "/banquets", "/team", "/staff", "/leadership", "/about", "/press",
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


def classify_url(url: str) -> str:
    ext = path_extension(url)
    if ext in DOCUMENT_EXTENSIONS:
        return "pdf"
    if ext in ASSET_EXTENSIONS:
        return "asset"
    return "page"


def score_url(url: str, anchor_text: str = "") -> int:
    hay = (url + " " + (anchor_text or "")).lower().replace("_", "-")
    for idx, kw in enumerate(HIGH_VALUE_KEYWORDS):
        if kw in hay:
            return idx
    return len(HIGH_VALUE_KEYWORDS) + min(len(url) // 40, 10)


def clean_email(email: str) -> Optional[str]:
    e = email.strip().strip(".,;:()[]{}<>\"'").lower()
    if len(e) > 120 or "@" not in e:
        return None
    if any(s in e for s in JUNK_EMAIL_SUBSTRINGS):
        return None
    if any(e.startswith(p) for p in HARD_REJECT_PREFIXES):
        return None
    # Reject file-like false positives.
    if re.search(r"\.(png|jpe?g|gif|svg|webp|css|js|pdf|docx?|xlsx?|zip)$", e, re.I):
        return None
    return e


def decode_cf_email(encoded: str) -> Optional[str]:
    try:
        key = int(encoded[:2], 16)
        decoded = "".join(chr(int(encoded[i:i + 2], 16) ^ key) for i in range(2, len(encoded), 2))
        return clean_email(decoded)
    except Exception:
        return None


def deobfuscate_text(text: str) -> str:
    # Conservative patterns only. Avoid replacing ordinary English " at ".
    text = re.sub(r"\s*(?:\[at\]|\(at\)|\{at\})\s*", "@", text, flags=re.I)
    text = re.sub(r"\s*(?:\[dot\]|\(dot\)|\{dot\})\s*", ".", text, flags=re.I)
    # Handle "name at domain dot com" when it looks email-shaped.
    text = re.sub(
        r"\b([A-Z0-9._%+\-]+)\s+at\s+([A-Z0-9.\-]+)\s+dot\s+([A-Z]{2,})\b",
        r"\1@\2.\3",
        text,
        flags=re.I,
    )
    return text


def extract_emails(text: str) -> List[Dict[str, object]]:
    work = deobfuscate_text(text or "")
    found: Dict[str, Dict[str, object]] = {}
    for match in EMAIL_RE.findall(work):
        email = clean_email(match)
        if not email:
            continue
        found[email] = {"email": email, "generic": any(email.startswith(p) for p in GENERIC_PREFIXES)}
    for enc in CF_RE.findall(text or ""):
        email = decode_cf_email(enc)
        if email:
            found[email] = {"email": email, "generic": any(email.startswith(p) for p in GENERIC_PREFIXES)}
    return list(found.values())


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
    return links


def extract_links(html: str, base_url: str) -> List[Tuple[str, str]]:
    try:
        from bs4 import BeautifulSoup  # type: ignore

        soup = BeautifulSoup(html, "html.parser")
        out: List[Tuple[str, str]] = []
        for a in soup.find_all("a", href=True):
            url = normalize_url(a.get("href", ""), base_url, keep_fragment=True)
            if not url:
                continue
            text = " ".join(
                x for x in [a.get_text(" ", strip=True), a.get("aria-label", ""), a.get("title", "")] if x
            )
            out.append((url, text))
        return out
    except Exception:
        return _extract_links_regex(html, base_url)


def _fetch(session: requests.Session, url: str, timeout: int = 10) -> Optional[requests.Response]:
    try:
        resp = session.get(url, headers=HEADERS, timeout=timeout, allow_redirects=True)
        if resp.status_code >= 400:
            return None
        return resp
    except requests.RequestException:
        return None


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


def discover_seeds(base_url: str, limit: int = 80, timeout: int = 8) -> Dict[str, object]:
    normalized_base = normalize_url(base_url, base_url, keep_fragment=False) or base_url
    parsed = urlparse(normalized_base)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    session = requests.Session()

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

    for path in KNOWN_PATHS:
        add(origin + path, "known-path")

    sitemap_queue: deque[str] = deque([origin + "/sitemap.xml"])
    robots = _fetch(session, origin + "/robots.txt", timeout)
    if robots is not None:
        for line in robots.text.splitlines():
            if line.lower().startswith("sitemap:"):
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
            if s < len(HIGH_VALUE_KEYWORDS) or shallow or classify_url(norm) == "pdf":
                add(norm, "sitemap")

    ordered = sorted(candidates.values(), key=lambda x: (int(x["score"]), len(str(x["url"]))))
    pages = [x for x in ordered if x["kind"] == "page"][:limit]
    pdfs = [x for x in ordered if x["kind"] == "pdf"][: max(10, limit // 3)]
    return {"base": normalized_base, "pages": pages, "pdfs": pdfs, "sitemaps_checked": sitemaps_checked}


def _pdf_text_from_bytes(data: bytes) -> str:
    # pypdf if available.
    try:
        from pypdf import PdfReader  # type: ignore
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
            tmp.write(data)
            path = tmp.name
        try:
            reader = PdfReader(path)
            return "\n".join((page.extract_text() or "") for page in reader.pages)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
    except Exception:
        pass

    # pdftotext if installed.
    if shutil.which("pdftotext"):
        with tempfile.TemporaryDirectory() as td:
            pdf = os.path.join(td, "in.pdf")
            txt = os.path.join(td, "out.txt")
            with open(pdf, "wb") as f:
                f.write(data)
            try:
                subprocess.run(["pdftotext", "-layout", pdf, txt], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
                if os.path.exists(txt):
                    return open(txt, "r", encoding="utf-8", errors="ignore").read()
            except Exception:
                pass

    # Last-resort: emails sometimes appear literally in PDF object streams.
    return data.decode("latin-1", errors="ignore")


def extract_pdf(url: str, timeout: int = 15) -> Dict[str, object]:
    session = requests.Session()
    resp = _fetch(session, url, timeout)
    if resp is None:
        return {"url": url, "ok": False, "emails": [], "error": "fetch_failed"}
    text = _pdf_text_from_bytes(resp.content)
    emails = extract_emails(text)
    return {"url": resp.url, "ok": True, "emails": emails, "text_chars": len(text)}


@dataclass
class CrawlItem:
    url: str
    depth: int
    score: int


def static_crawl(base_url: str, max_pages: int = 25, max_depth: int = 2, timeout: int = 10) -> Dict[str, object]:
    base = normalize_url(base_url, base_url, keep_fragment=True) or base_url
    session = requests.Session()
    queue: List[CrawlItem] = [CrawlItem(base, 0, -1)]
    seen: Set[str] = set()
    pages: List[Dict[str, object]] = []
    contacts: Dict[str, Dict[str, object]] = {}
    pdf_urls: Set[str] = set()
    socials: Dict[str, Dict[str, object]] = {}
    discovered_pages: Set[str] = {base}
    fragment_states: Set[str] = set()

    seeds = discover_seeds(base, limit=max_pages * 2, timeout=min(timeout, 8))
    for item in seeds["pages"]:  # type: ignore[index]
        seed_url = str(item["url"])
        discovered_pages.add(seed_url)
        if urlparse(seed_url).fragment:
            fragment_states.add(seed_url)
        queue.append(CrawlItem(seed_url, 1, int(item["score"])))
    for item in seeds["pdfs"]:  # type: ignore[index]
        pdf_urls.add(str(item["url"]))

    attempts = 0
    successful_pages = 0
    max_attempts = max(max_pages * 4, max_pages + 20)
    while queue and successful_pages < max_pages and attempts < max_attempts:
        # Relevance first, then depth. A second-hop "private events" page should beat
        # dozens of guessed /about-/staff paths that may all be 404/soft-404 pages.
        queue.sort(key=lambda x: (x.score, x.depth, len(x.url)))
        item = queue.pop(0)
        # Fetch fragments only once at HTTP level; retain fragment in evidence elsewhere.
        fetch_url = item.url.split("#", 1)[0]
        key = normalize_url(fetch_url, base, keep_fragment=False) or fetch_url
        if key in seen or not same_origin(key, base):
            continue
        seen.add(key)
        if classify_url(key) != "page":
            continue
        attempts += 1
        resp = _fetch(session, key, timeout)
        if resp is None:
            pages.append({"url": key, "depth": item.depth, "ok": False, "emails": []})
            continue
        ctype = (resp.headers.get("content-type") or "").lower()
        if "pdf" in ctype:
            pdf_urls.add(resp.url)
            continue
        successful_pages += 1
        html = resp.text
        page_emails = extract_emails(html)
        page_socials = extract_socials(html)
        for platform, urls in page_socials.items():
            for social_url in urls:
                rec = socials.setdefault(social_url, {"url": social_url, "platform": platform, "sources": []})
                if resp.url not in rec["sources"]:
                    rec["sources"].append(resp.url)
        for c in page_emails:
            email = str(c["email"])
            existing = contacts.setdefault(email, {"email": email, "generic": bool(c.get("generic")), "sources": []})
            if resp.url not in existing["sources"]:  # type: ignore[index]
                existing["sources"].append(resp.url)  # type: ignore[index]
        pages.append({"url": resp.url, "depth": item.depth, "ok": True, "emails": [c["email"] for c in page_emails], "socials": page_socials})

        if item.depth >= max_depth:
            continue
        for child, text in extract_links(html, resp.url):
            if not same_origin(child, base):
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
            if normalize_url(fetch_child, base, keep_fragment=False) in seen:
                continue
            # Allow nav/shallow pages, prioritize relevant anchors/paths.
            queue.append(CrawlItem(child, item.depth + 1, score_url(child, text)))

    pdf_results: List[Dict[str, object]] = []
    for pdf in sorted(pdf_urls, key=score_url)[:10]:
        result = extract_pdf(pdf, timeout=timeout)
        pdf_results.append(result)
        for c in result.get("emails", []):
            email = str(c["email"])
            existing = contacts.setdefault(email, {"email": email, "generic": bool(c.get("generic")), "sources": []})
            if pdf not in existing["sources"]:  # type: ignore[index]
                existing["sources"].append(pdf)  # type: ignore[index]

    visited_fetch_urls = {
        normalize_url(str(p.get("url", "")).split("#", 1)[0], base, keep_fragment=False)
        for p in pages
        if p.get("url")
    }
    visited_fetch_urls.discard(None)
    unvisited_pages = []
    for candidate in sorted(discovered_pages, key=lambda u: (score_url(u), len(u), u)):
        fetch_candidate = normalize_url(candidate.split("#", 1)[0], base, keep_fragment=False)
        if fetch_candidate and fetch_candidate not in visited_fetch_urls:
            unvisited_pages.append(candidate)

    return {
        "base": base,
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
            "pdf_count": len(pdf_results),
            "sitemap_count": len(seeds.get("sitemaps_checked", [])),
            "fragment_state_count": len(fragment_states),
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

    args = parser.parse_args(argv)
    if args.command == "seeds":
        result = discover_seeds(args.url, limit=args.limit)
    elif args.command == "pdf":
        result = extract_pdf(args.url)
    else:
        result = static_crawl(args.url, max_pages=args.max_pages, max_depth=args.max_depth)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
