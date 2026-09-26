#!/usr/bin/env python3
"""verify_pool.py — promote good needs_review venues that were never verified.

Discovery parks a venue in needs_review when it can't confirm the website, the city or
the category on the spot. Nobody came back for them, so the best finds (The Occidental,
Barbouzard, Taberna del Alabardero, ...) never reached a batch.

NO BROWSER: this never opens or drives Chrome (Alex, Sep 26: "stop opening my
browser"). It reads the venue's own website over plain HTTP instead of Google:
schema.org data (address, business type, cuisine), the page title/description and the
"City, ST 12345" address on the home/contact/about pages.

For each candidate (needs_review, DC/MD/VA, has a website, not parked for a reason, no
contacts, not in any report, not junk, not a duplicate of a venue already worked), best
taste score first:
  1. The site is alive and the venue's own (venue_quality score >= 6), not closed/parked.
  2. Location: an address on the site in DC/MD/VA that agrees with the sheet's state.
  3. Category: schema.org type, or the classifier reading the page title/description,
     with confidence >= 0.7.
  All pass and the rescored venue has a batch bucket -> fill city/state/address where
  empty or wrong, add the business type/cuisine to the notes, status untouched.
A dead or "closed" site only gets a note (it stays needs_review). Venues without a
website stay needs_review (finding one needs a search engine).

  /usr/bin/python3 verify_pool.py                 # preview (writes nothing)
  /usr/bin/python3 verify_pool.py --apply         # write
  options: --limit N (default 200), --min-score S (default 25), --venue VENUE_ID
"""
import argparse
import html as html_lib
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import outreach_rules as R  # noqa: E402
import taste_score as T  # noqa: E402
from venue_classifier import classify, junk_reason  # noqa: E402
from venue_quality import website_match_score  # noqa: E402

API = os.environ.get("APPS_SCRIPT_URL") or (
    "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/124 Safari/537.36"}
# needs_review rows parked for a reason stay parked (same words backfill_websites.sh uses)
PARKED = re.compile(r"pipeline|0 contacts|zero contacts|closed|dead|not a venue|junk|motel|airbnb|"
                    r"vrbo|too far|out of area|quarantin|duplicate|wrong business|flag|verify_pool", re.I)
STATES = {"DC": "DC", "MD": "MD", "VA": "VA", "MARYLAND": "MD", "VIRGINIA": "VA",
          "DISTRICT OF COLUMBIA": "DC", "WASHINGTON DC": "DC", "D C": "DC"}
ADDR = re.compile(r"(\d{1,6}[^\n<>|]{2,60}?),?\s+([A-Z][A-Za-z .'-]{2,30}),\s*(DC|MD|VA|Maryland|Virginia|D\.C\.)\.?,?\s+(\d{5})")
CLOSED_TEXT = re.compile(r"permanently closed|closed permanently|closed for good|clos(?:ed|ing) (?:its|our) doors|"
                         r"we have (?:officially )?closed|no longer (?:open|in business|operating)", re.I)
PARKED_TEXT = re.compile(r"domain (?:name )?(?:is|may be) for sale|buy this domain|this domain has expired|"
                         r"parked free|hugedomains|afternic", re.I)
SCHEMA_TYPES = [  # schema.org @type -> a Google-style category the classifier knows
    (r"bedandbreakfast", "bed and breakfast"), (r"hotel|lodgingbusiness|resort|motel", "hotel"),
    (r"winery", "winery"), (r"barorpub|nightclub", "bar"), (r"brewery", "brewery"),
    (r"cafeorcoffeeshop", "cafe"), (r"restaurant|foodestablishment", "restaurant"),
    (r"golfcourse", "golf club"), (r"sportsclub|sportsorganization", "country club"),
    (r"museum", "museum"), (r"artgallery", "art gallery"), (r"eventvenue", "event venue"),
]


def api(params, tries=3):
    for i in range(tries):
        try:
            return requests.get(API, params=params, timeout=90).json()
        except Exception:
            time.sleep(3 * (i + 1))
    return {"status": "error", "message": "request failed"}


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def fetch(url):
    try:
        return requests.get(url, headers=UA, timeout=12, allow_redirects=True)
    except Exception:
        return None


def ld_objects(text):
    out = []
    for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', text or "", re.S | re.I):
        try:
            d = json.loads(m.group(1).strip())
        except ValueError:
            continue
        stack = d if isinstance(d, list) else [d]
        while stack:
            o = stack.pop()
            if isinstance(o, dict):
                out.append(o)
                for k in ("@graph", "mainEntity", "location"):
                    v = o.get(k)
                    if isinstance(v, list):
                        stack += v
                    elif isinstance(v, dict):
                        stack.append(v)
            elif isinstance(o, list):
                stack += o
    return out


def evidence(site):
    """Read the venue's own site: alive?, closed?, address, schema type, cuisine, title."""
    base = site if re.match(r"^https?://", site, re.I) else "https://" + site
    home = fetch(base)
    if home is None:
        host = re.sub(r"^https?://", "", base).split("/")[0]
        alt = host[4:] if host.startswith("www.") else "www." + host
        home = fetch("https://" + alt) or fetch("http://" + host)
    if home is None:
        return {"unreachable": True}
    if home.status_code in (404, 410):
        return {"dead": f"home page HTTP {home.status_code}"}
    if R.registrable_domain(home.url) != R.registrable_domain(base) and home.status_code >= 400:
        return {"dead": f"redirects to {R.registrable_domain(home.url)} (HTTP {home.status_code})"}
    ev = {"final": home.url, "dead": "", "closed": "", "types": [], "cuisine": [], "addr": [],
          "title": "", "desc": "", "blocked": home.status_code >= 400}
    pages = [home.text or ""]
    root = re.match(r"^(https?://[^/]+)", home.url).group(1)
    for path in ("/contact", "/contact-us", "/about", "/about-us"):
        r = fetch(root + path)
        if r is not None and r.status_code == 200 and R.registrable_domain(r.url) == R.registrable_domain(home.url):
            pages.append(r.text or "")
    for t in pages:
        if PARKED_TEXT.search(t[:200000]):
            ev["dead"] = "parked / for-sale domain"
        plain = html_lib.unescape(re.sub(r"<[^>]+>", " ",
                                         re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", t, flags=re.S | re.I)))
        m = CLOSED_TEXT.search(plain)
        if m:
            ev["closed"] = m.group(0)
        for o in ld_objects(t):
            ty = o.get("@type")
            for x in (ty if isinstance(ty, list) else [ty]):
                if isinstance(x, str):
                    ev["types"].append(x)
            c = o.get("servesCuisine")
            ev["cuisine"] += [c] if isinstance(c, str) else [x for x in (c or []) if isinstance(x, str)]
            a = o.get("address")
            if isinstance(a, dict):
                ev["addr"].append((str(a.get("streetAddress") or ""), str(a.get("addressLocality") or ""),
                                   str(a.get("addressRegion") or "")))
        for m2 in ADDR.finditer(re.sub(r"\s+", " ", plain)):
            ev["addr"].append((m2.group(1).strip(), m2.group(2).strip(), m2.group(3)))
    t0 = pages[0]
    mt = re.search(r"<title[^>]*>(.*?)</title>", t0, re.S | re.I)
    ev["title"] = html_lib.unescape(re.sub(r"\s+", " ", mt.group(1))).strip()[:150] if mt else ""
    md = re.search(r'<meta[^>]+(?:name|property)=["\'](?:og:)?description["\'][^>]+content=["\']([^"\']+)', t0, re.I)
    ev["desc"] = html_lib.unescape(md.group(1)).strip()[:300] if md else ""
    return ev


STREET_WORDS = {"street", "st", "road", "rd", "avenue", "ave", "av", "drive", "dr", "lane", "ln", "way",
                "boulevard", "blvd", "pike", "court", "ct", "circle", "cir", "place", "pl", "parkway", "pkwy",
                "highway", "hwy", "terrace", "ter", "square", "sq", "northwest", "northeast", "southwest",
                "southeast", "nw", "ne", "sw", "se", "suite", "ste", "unit", "floor", "fl", "point", "pt",
                "club", "trail", "trl", "run", "row", "alley", "plaza", "center", "centre", "landing"}


def clean_city(locality, sheet_city=""):
    """'Club Drive Easton' -> 'Easton'; 'Ste MNO Columbia' -> 'Columbia'."""
    toks = [t for t in re.split(r"\s+", (locality or "").strip(" ,.")) if t]
    sc = norm(sheet_city)
    if sc and norm(" ".join(toks)).endswith(sc):
        return sheet_city.strip()
    cut = -1
    for i, t in enumerate(toks):
        tl = t.lower().strip(".,#")
        if tl in STREET_WORDS or (t.isupper() and len(t) <= 4 and i < len(toks) - 1) or re.search(r"\d", t):
            cut = i
    rest = toks[cut + 1:]
    return " ".join(rest) if rest else ""


def score_of(v, extra_notes=""):
    vv = dict(v)
    if extra_notes:
        vv["notes"] = f"{v.get('notes') or ''} {extra_notes}".strip()
    cls = classify(vv.get("name", ""), vv.get("category", ""), vv.get("notes", ""), vv.get("website", ""))
    s, _ = T.score(vv, cls)
    return s, T.bucket(cls, vv) or ""


def decide(v, ev):
    name, state = v.get("name", ""), str(v.get("state") or "").strip().upper()
    city = (v.get("city") or "").strip()
    if ev.get("unreachable"):
        return "keep", "site unreachable (timeout/bot wall)", {}
    if ev.get("dead"):
        return "park", ev["dead"], {}
    if ev.get("closed"):
        return "park", f'site says "{ev["closed"]}"', {}
    site = (v.get("website") or "").strip()
    if website_match_score(name, ev["final"]) < 6 and \
            website_match_score(name, site if "://" in site else "https://" + site) < 6:
        return "keep", "website isn't clearly the venue's own", {}
    loc = None
    for street, locality, region in ev["addr"]:
        reg = region.strip().upper().replace(".", "")
        st = STATES.get(reg)
        lc = clean_city(locality, city)
        if not st or (state and st != state) or not lc:
            continue
        loc = (street, lc, st)
        break
    if not loc:
        return "keep", "no DC/MD/VA address on the site matching the sheet", {}
    gcat = ""
    for ty in ev["types"]:
        for rx, cat in SCHEMA_TYPES:
            if re.search(rx, ty.lower()):
                gcat = cat
                break
        if gcat:
            break
    cuisine = ", ".join(dict.fromkeys(c.strip() for c in ev["cuisine"] if c.strip()))[:80]
    words = " ".join(x for x in (gcat, cuisine, ev["title"], ev["desc"]) if x)
    cls = classify(name, words, "")
    our = cls.get("primary_category") or "other"
    conf = float(cls.get("classification_confidence") or 0)
    if gcat and our not in ("other", "unknown") and conf < 0.7:
        conf = 0.75  # the venue's own schema.org type
    if conf < 0.7 or our in ("other", "unknown"):
        return "keep", f"category not sure ({our} {conf:.2f})", {}
    extra = []
    if gcat and gcat.lower() not in (v.get("notes") or "").lower():
        extra.append(f"Site type: {gcat}.")
    if cuisine and cuisine.lower() not in (v.get("notes") or "").lower():
        extra.append(f"Cuisine: {cuisine}.")
    if ev["desc"] and not extra:
        extra.append(f"Site: {ev['desc'][:140]}")
    extra_s = " ".join(extra)
    s1, b1 = score_of({**v, "city": loc[1] or city, "state": loc[2]}, extra_s)
    if not b1 or b1 == "none":
        return "keep", f"no batch bucket after rescoring (score {s1})", {}
    return "ok", f"{s1:.0f} {b1} | {gcat or our} {cuisine} | {loc[1]}, {loc[2]}", {"loc": loc, "extra": extra_s}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--limit", type=int, default=200)
    ap.add_argument("--min-score", type=float, default=25)
    ap.add_argument("--venue", default="")
    a = ap.parse_args()

    dash = api({"action": "dashboard"})
    venues = dash.get("venues") or []
    with_contacts = {c.get("venue_id") for c in dash.get("contacts") or []}
    reported = set()
    try:
        for e in json.load(open(os.path.join(HERE, "reports", "manifest.json"))):
            reported |= set(e.get("venue_ids") or [])
    except (OSError, ValueError):
        pass
    done = {}
    for v in venues:
        if v.get("status") in ("pipelined", "contacted", "dismissed", "closed", "researched", "sent"):
            done.setdefault((norm(re.sub(r"^the ", "", (v.get("name") or "").lower())),
                             str(v.get("state", "")).upper()), v.get("venue_id"))
    cands, no_site = [], 0
    for v in venues:
        vid = v.get("venue_id", "")
        if a.venue and vid != a.venue:
            continue
        if v.get("status") != "needs_review" or str(v.get("state", "")).upper() not in R.TARGET_STATES:
            continue
        if vid in with_contacts or vid in reported:
            continue
        if PARKED.search(f"{v.get('check_status') or ''} {v.get('notes') or ''}"):
            continue
        if done.get((norm(re.sub(r"^the ", "", (v.get("name") or "").lower())), str(v.get("state", "")).upper())):
            continue
        if junk_reason(v.get("name", ""), v.get("category", ""), v.get("notes", ""),
                       v.get("website", ""), v.get("check_status", "")):
            continue
        s, _b = score_of(v)
        if s < a.min_score:
            continue
        if not (v.get("website") or "").strip() or R.is_non_venue_host(v.get("website", "")):
            no_site += 1
            continue
        cands.append((s, v))
    cands.sort(key=lambda x: -x[0])
    cands = cands[:a.limit]
    print(f"{len(cands)} needs_review candidates with a website (score >= {a.min_score}); "
          f"{no_site} more have no website and stay needs_review{' — APPLY' if a.apply else ' — preview'}")

    with ThreadPoolExecutor(max_workers=8) as ex:
        evs = list(ex.map(lambda sv: evidence(sv[1]["website"]), cands))

    promoted = parked = kept = 0
    recalc = []
    for (s0, v), ev in zip(cands, evs):
        vid, name = v["venue_id"], v.get("name", "")
        verdict, why, info = decide(v, ev)
        if verdict == "park":
            print(f"PARK  {vid:<14} {name[:40]:<40} {why}")
            parked += 1
            if a.apply:
                api({"action": "update_venue", "venue_id": vid, "field": "notes",
                     "value": f"{v.get('notes') or ''} [verify_pool {time.strftime('%Y-%m-%d')}: "
                              f"site dead/closed? {why}]".strip()})
            continue
        if verdict == "keep":
            print(f"KEEP  {vid:<14} {name[:40]:<40} {why}")
            kept += 1
            continue
        print(f"OK    {vid:<14} {name[:40]:<40} {s0:.0f}->{why}")
        promoted += 1
        if not a.apply:
            continue
        street, lcity, lstate = info["loc"]
        city = (v.get("city") or "").strip()
        writes = []
        moved = bool(lcity) and norm(lcity) != norm(city)
        if not city or moved:
            writes.append(("city", lcity))
        if not (v.get("state") or "").strip():
            writes.append(("state", lstate))
        if street and (moved or not (v.get("address") or "").strip()):
            writes.append(("address", f"{street}, {lcity}, {lstate}"))
        if info["extra"]:
            writes.append(("notes", f"{v.get('notes') or ''} {info['extra']}".strip()))
        if moved:
            writes += [("distance_miles", ""), ("drive_minutes", "")]
            recalc.append(vid)
        ok = True
        for f, val in writes:
            r = api({"action": "update_venue", "venue_id": vid, "field": f, "value": val})
            if r.get("status") != "ok" and f not in ("distance_miles", "drive_minutes", "notes"):
                ok = False
                print(f"      write {f} failed: {r.get('message', r)}")
        if ok:
            api({"action": "update_venue", "venue_id": vid, "field": "status", "value": "untouched"})
            d = api({"action": "venue_detail", "venue_id": vid})
            if (d.get("venue") or {}).get("status") != "untouched":
                print("      promotion not confirmed")
                promoted -= 1
    if a.apply and recalc:
        r = api({"action": "calc_distances"})
        print(f"Distances recalculated for {len(recalc)} moved venue(s): {str(r)[:120]}")
    print(f"\n{'Promoted' if a.apply else 'Would promote'}: {promoted} | parked (site dead/closed?): {parked} | "
          f"kept needs_review: {kept} | no website: {no_site}")


if __name__ == "__main__":
    main()
