#!/usr/bin/env python3
"""Plan one-off repairs of the live outreach sheet. Read-only unless --apply is given.

    /usr/bin/python3 repair_data.py [--refresh] [--max-age-hours 24]
        (python3 on PATH is broken on this Mac; /usr/bin/python3 is Apple's 3.9)
        Reads the sheet through read-only GETs (the single `dashboard` call, cached
        under reports/repair/cache/), the ZeroBounce guard cache (opened read-only)
        and reports/discovery-candidates.jsonl. Writes reports/repair/plan-<date>.json
        (one entry per action: action, targets, field, old, new, reason, finding_id,
        confidence) and plan-<date>.md (counts, review-impact ranking, 5 examples per
        category). Nothing is written to the sheet.

    /usr/bin/python3 repair_data.py --apply reports/repair/plan-<date>.json
            [--only CATEGORY[,CATEGORY]] [--min-confidence high|medium] [--venues ID,ID] [--limit N]
        Separate, explicit mode. Re-reads the LIVE sheet, drops every action whose row
        changed since the plan or can't be targeted uniquely by the deployed backend
        (duplicate contact_ids), writes a backup of every row it will touch, then runs
        delete_contact / update_contact / update_venue and reads each write back with
        venue_detail. Rows already emailed are never deleted. `flag` and
        `needs_backend_fix` entries are never executed.
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import outreach_rules as R  # noqa: E402

DEFAULT_API = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
PLAN_VERSION = 1

READ_ACTIONS = {"", "dashboard", "venues", "venue_detail", "stats", "get_gigs", "config",
                "templates", "load_discovery", "get_reviewed_reports"}
WRITE_ACTIONS = {"update_contact", "delete_contact", "update_venue"}
EXEC_ACTIONS = WRITE_ACTIONS

# Alex (Sep 25): ZB-deferred addresses are saved as 'unverified', shown, sendable, and count
# toward 'pipelined' until reverify.sh checks them.
SENDABLE = {"valid", "catch-all", "unknown", "unverified"}   # what the PWA offers to send
USABLE = {"valid", "role", "unverified"}                     # P4: what makes a venue 'pipelined'
VOCAB = {"valid", "role", "unverified", "pending", "deferred", "catch-all", "unknown",
         "invalid", "do_not_mail"}
CONF_RANK = {"high": 3, "medium": 2, "low": 1}
HOST_RE = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$")
FAKE_EMAIL_STRINGS = {"none", "null", "undefined", "n/a", "na", "nan", "false"}
JUNK_NAMES = {"test", "user", "name", "none", "null", "undefined", "venue contact"}
# Hosts that are never the venue's own site. google.com / toasttab.com are left out:
# sites.google.com and Toast pages are sometimes the only site a venue has.
CLEAR_WEBSITE_HOSTS = R.NON_VENUE_HOSTS - {"google.com", "toasttab.com"}
STOP = {"the", "a", "an", "and", "of", "at", "in", "by", "on", "&"}
LABEL_SUFFIXES = ("restaurants", "restaurant", "hotels", "hotel", "resorts", "resort",
                  "group", "events", "inc", "llc", "usa", "us", "dc", "md", "va",
                  "online", "hq")
ABBREVS = (("gcc", "golfandcountryclub"), ("cc", "countryclub"), ("gc", "golfclub"),
           ("yc", "yachtclub"), ("ac", "athleticclub"))
RELEVANT_TITLE = re.compile(
    r"event|catering|banquet|food|beverage|f&b|f & b|general manager|\bgm\b|owner|"
    r"proprietor|founder|president|sales|entertainment|music|club manager|"
    r"private dining|wedding|hospitality|restaurant|dining|marketing|director of operations|"
    r"managing director|clubhouse|social|membership|concierge|guest", re.I)
IRRELEVANT_TITLE = re.compile(
    r"golf pro|golf professional|superintendent|\bserver\b|waiter|waitress|teacher|"
    r"\bcoach|\bcook\b|line cook|prep cook|bartender|barback|housekeep|dishwash|valet|"
    r"lifeguard|accountant|accounting|payroll|engineer|maintenance|grounds|caddie|"
    r"instructor|nurse|security|laundry|steward|\bit\b|information technology|"
    r"recruit|human resource|\bhr\b|esthetician|massage|tennis|aquatic|swim|"
    r"student|faculty|professor|principal|admissions|athletic", re.I)
SCHOOL_NAME = re.compile(r"\b(school|academy|university|college|montessori)\b", re.I)

CATEGORIES = {
    # key: (finding ids, one-line description, severity)
    # severity 3: can cause a wrong, duplicate or bouncing send; 2: hides/loses contacts or
    # wastes batch slots and review; 1: misleading display
    "junk_email": ("DATA-6", "Placeholder, junk-domain, image-filename or 'None' addresses; '%20'-prefixed addresses to normalize", 3),
    "hard_reject_email": ("DATA-6,PA-5,PD-10", "Operational mailboxes (optout, privacy, travelpass, media, ...) per outreach_rules hard-reject list", 3),
    "wrong_business": ("DATA-2,PB-4,PD-10,GS-7", "Contacts whose email domain belongs to a different organization than the venue", 3),
    "shared_brand_roster": ("PB-4,PD-10,DATA-3", "Corporate/other-property staff saved for a property whose website sits on a shared brand domain", 3),
    "duplicate_email": ("DATA-3", "Same address on several rows: already-emailed copies and cross-venue duplicates", 3),
    "zb_status": ("DATA-5", "Saved 'valid' although ZeroBounce never checked it or said otherwise; non-standard verified values", 3),
    "valid_no_email": ("DATA-5,DATA-6", "Rows marked valid/unknown with no usable email", 2),
    "fake_name": ("EVID-14,PA-5,DATA-16", "Names copied from the email local part, role labels or page boilerplate; masked Apollo names", 1),
    "pipe_title": ("CC-3,DATA-16", "Titles left by the old IFS='|||' split ('||||', '|Name|||Title', page text)", 1),
    "bad_website": ("DATA-7", "Website is a follower count ('https://3.8K+') or a directory/social/news site", 2),
    "status_flow": ("DATA-10", "Venue status disagrees with P4 (contacts under untouched, zero-contact pipelined, ...)", 2),
    "location": ("DATA-8", "Venue name stored as address, card text as city, impossible distances (flag only)", 1),
    "duplicate_venue": ("DATA-9", "Venues that look like the same business (flag only; merge by hand)", 2),
    "out_of_area": ("DATA-13", "PA/DE/WV/other-state venues still holding sendable contacts (flag only; never batched now)", 2),
    "apollo_roster": ("DATA-15", "Venues with >15 Apollo contacts, mostly irrelevant titles (flag only)", 2),
    "duplicate_id": ("DATA-4", "Duplicate contact_ids / venue_ids: renumbering needs the new backend", 3),
    "orphan": ("GS-7", "Contacts, outreach rows, gigs or report links pointing at venue_ids that don't exist", 1),
}
# Order in which competing contact proposals win (delete beats update, then this order).
CONTACT_CAT_ORDER = ["junk_email", "hard_reject_email", "valid_no_email", "wrong_business",
                     "shared_brand_roster", "duplicate_email", "zb_status", "pipe_title",
                     "fake_name"]


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def api_url():
    url = os.environ.get("APPS_SCRIPT_URL", "").strip()
    if not url:
        try:
            with open(os.path.join(SCRIPT_DIR, ".env")) as f:
                for line in f:
                    if line.startswith("APPS_SCRIPT_URL="):
                        url = line.split("=", 1)[1].strip().strip("\"'")
                        break
        except OSError:
            pass
    return url or DEFAULT_API


class Api:
    """GET-only Apps Script client. Mutating actions are refused unless allow_writes."""

    def __init__(self, url, allow_writes=False, detail_gap=1.0, timeout=90):
        self.url = url
        self.allow_writes = allow_writes
        self.detail_gap = detail_gap
        self.timeout = timeout
        self._last_detail = 0.0
        self.calls = Counter()

    def _fetch(self, full_url, timeout):
        req = urllib.request.Request(full_url, headers={"User-Agent": "repair_data.py"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8")

    def get(self, action, **params):
        if action not in READ_ACTIONS and not (self.allow_writes and action in WRITE_ACTIONS):
            raise RuntimeError(f"refusing Apps Script action {action!r} (read-only mode)")
        if action == "venue_detail":
            wait = self.detail_gap - (time.monotonic() - self._last_detail)
            if wait > 0:
                time.sleep(wait)
            self._last_detail = time.monotonic()
        q = {k: ("" if v is None else str(v)) for k, v in params.items()}
        if action:
            q = {"action": action, **q}
        full = self.url + ("?" + urllib.parse.urlencode(q) if q else "")
        self.calls[action or "health"] += 1
        text = self._fetch(full, self.timeout)
        try:
            return json.loads(text)
        except ValueError:
            raise RuntimeError(f"{action or 'health'}: non-JSON response: {text[:120]!r}")

    def backend_version(self):
        # The deployed (old) backend has no version field; treat any failure as old,
        # which only makes the ambiguity checks stricter.
        try:
            return str(self.get("").get("version") or "")
        except Exception:
            return ""


def fetch_dashboard(api):
    # full=1: the new backend's default dashboard is cached and drops venue address/source/
    # scraped_date; the old backend ignores the parameter.
    data = api.get("dashboard", full=1)
    if data.get("status") != "ok" or not isinstance(data.get("venues"), list) \
            or not isinstance(data.get("contacts"), list):
        raise RuntimeError("dashboard response has no venues/contacts: %s" % str(data)[:200])
    return data


def load_dashboard(api, cache_dir, refresh=False, max_age_hours=24.0):
    path = os.path.join(cache_dir, "dashboard.json")
    if not refresh and os.path.exists(path):
        age_h = (time.time() - os.path.getmtime(path)) / 3600
        if age_h <= max_age_hours:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            fetched = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
            return data, {"source": "cache", "path": path, "age_hours": round(age_h, 1),
                          "fetched_at": fetched.isoformat(timespec="seconds")}
    data = fetch_dashboard(api)
    os.makedirs(cache_dir, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)
    return data, {"source": "live", "path": path, "age_hours": 0.0, "fetched_at": now_iso()}


def load_zb_cache(path):
    """{email: {status, sub_status, verified_at}} from the guard DB, opened read-only."""
    if not os.path.exists(path):
        return {}, ""
    conn = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True)
    try:
        rows = conn.execute("SELECT email, status, sub_status, verified_at FROM cache").fetchall()
    finally:
        conn.close()
    out = {}
    for email, status, sub, at in rows:
        if (sub or "") == "request_error":   # no real answer from ZeroBounce
            continue
        e = R.normalize_email(email) or (email or "").strip().lower()
        out[e] = {"status": (status or "").lower(), "sub_status": sub or "", "verified_at": at or ""}
    start = min((r[3] or "" for r in rows), default="")[:10]
    return out, start


def load_candidates(path):
    idx = defaultdict(list)
    if not os.path.exists(path):
        return idx
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            e = R.normalize_email(d.get("email")) or str(d.get("email") or "").strip().lower()
            idx[(str(d.get("venue_id") or ""), e)].append(d)
    return idx


def load_manifest_ids(path):
    ids = defaultdict(list)
    try:
        with open(path, encoding="utf-8") as f:
            entries = json.load(f)
    except (OSError, ValueError):
        return ids
    for ent in entries if isinstance(entries, list) else []:
        for vid in ent.get("venue_ids") or []:
            ids[str(vid)].append(str(ent.get("file") or ent.get("date") or ""))
    return ids


# ---------------------------------------------------------------- matching helpers

def ascii_lower(s):
    return unicodedata.normalize("NFKD", str(s or "")).encode("ascii", "ignore").decode().lower()


def compact(s):
    return re.sub(r"[^a-z0-9]", "", ascii_lower(s))


def name_words(name):
    return [w for w in re.sub(r"[^a-z0-9\s]", " ", ascii_lower(name).replace("'", "")).split()
            if w not in STOP]


def name_compact(name):
    return "".join(name_words(name))


def acronym(name):
    return "".join(w[0] for w in name_words(name))


def domain_label(dom):
    reg = R.registrable_domain(dom)
    return compact(reg.split(".")[0]) if reg else ""


def label_variants(lab):
    out, todo = {lab}, [lab]
    while todo:
        x = todo.pop()
        new = []
        for s in LABEL_SUFFIXES:
            if x.endswith(s) and len(x) - len(s) >= 3:
                new.append(x[:-len(s)])
        for a, full in ABBREVS:
            if x.endswith(a) and len(x) > len(a) + 2:
                new.append(x[:-len(a)] + full)
        if x.startswith("the") and len(x) > 6:
            new.append(x[3:])
        for n in new:
            if n not in out:
                out.add(n)
                todo.append(n)
    return out


def venue_host(v):
    return R.host_of(str(v.get("website") or ""))


def venue_domain(v):
    """Registrable domain of the venue's own site ('' if none, junk or a directory host)."""
    host = venue_host(v)
    if not host or not HOST_RE.match(host) or R.is_non_venue_host(host):
        return ""
    return R.registrable_domain(host)


def domain_matches_venue(edom, v, vdom):
    """True when an email domain plausibly is the venue's own (alternate domain, group label,
    'xxcc' = 'xx country club', acronym). Errs toward True: a False here can lead to a delete."""
    lab = domain_label(edom)
    if not lab:
        return False
    targets = {name_compact(v.get("name"))}
    if vdom and vdom not in R.SHARED_BRAND_DOMAINS:
        targets.add(domain_label(vdom))
    targets = {t for t in targets if t}
    variants = label_variants(lab)
    for x in variants:
        for t in targets:
            if x == t or (len(x) >= 5 and x in t) or (len(t) >= 5 and t in x):
                return True
    words = name_words(v.get("name"))
    if len(words) >= 2 and any(len(x) >= 4 and prefix_cover(x, words) for x in variants):
        return True
    ac = acronym(v.get("name"))
    return len(ac) >= 3 and ac in variants


def prefix_cover(label, words):
    """'metroclub' = 'metro'+'club' of [metropolitan, club]; 'ancc' of [army, navy, country, club].
    Every word must give a non-empty prefix, in order, and the label must be used up."""
    memo = {}

    def go(i, j):
        if j == len(words):
            return i == len(label)
        if (i, j) not in memo:
            w = words[j]
            memo[(i, j)] = any(label[i:i + k] == w[:k] and go(i + k, j + 1)
                               for k in range(min(len(w), len(label) - i), 0, -1))
        return memo[(i, j)]
    return go(0, 0)


def same_business(a, b):
    na, nb = name_compact(a.get("name")), name_compact(b.get("name"))
    if len(na) >= 5 and len(nb) >= 5 and (na in nb or nb in na):
        return True
    return (R.org_name_matches(a.get("name"), b.get("name"))
            and (a.get("state") or "") == (b.get("state") or "")
            and (a.get("city") or "").strip().lower() == (b.get("city") or "").strip().lower())


def venue_tokens(v):
    brand_words = {domain_label(d) for d in R.SHARED_BRAND_DOMAINS}
    return {w for w in name_words(v.get("name"))
            if len(w) >= 4 and w not in R._GENERIC_VENUE_WORDS and w not in brand_words}


def names_other_property(title, v):
    """'General Manager - Diamond Run Golf Club' on a Norbeck row -> True."""
    m = re.search(r"\s[-–|@]\s+(.+)$|\bat\s+(.+)$", title or "")
    if not m:
        return False
    tail = (m.group(1) or m.group(2) or "").lower()
    toks = venue_tokens(v)
    if any(t in tail for t in toks):
        return False
    return bool(re.search(r"\b(club|hotel|inn|resort|golf|country|suites|restaurant)\b", tail))


def city_is_malformed(city):
    # Same rules as build_batch.sh city_is_malformed (empty city handled by the caller).
    cl = (city or "").lower().strip()
    garbage = ['and ', 'prices', 'best ', 'top ', 'finest', 'genuine', 'famous', 'historic ',
               'restaurant', 'review', 'rating', 'menu', 'hours', 'delivery', 'near me',
               'open now', 'reserv', 'book a', 'order', 'http', 'www.', '.com', '@',
               'phone', 'email', 'contact']
    return (any(g in cl for g in garbage) or len(city) > 30
            or bool(re.search(r"\d{3,}", city)) or '"' in city or "'" in city)


def clean_title(t):
    t = re.sub(r"\s+", " ", (t or "").replace("\xa0", " ")).strip(" |")
    if not t or len(t) > 60 or "|" in t or ":" in t or re.search(r"\d{3}", t) \
            or t.endswith((".", "!", "?")) or len(t.split()) > 8:
        return ""
    return t


def name_tied_to_email(name, local):
    """The mailbox is this person's: a first/last name (not a role word) or f+last is in it."""
    toks = [t for t in re.sub(r"[^a-z\s]", " ", ascii_lower(name)).split() if len(t) >= 2]
    if not toks or not local:
        return False
    if any(len(t) >= 4 and t not in R.ROLE_TOKENS and t in local for t in toks):
        return True
    return len(toks) >= 2 and (toks[0][0] + toks[-1]) in local


def sent_state(c):
    s = c.get("email_sent")
    return "" if s in (False, None, "false", "False") else str(s).lower()


def is_touched(c):
    return sent_state(c) == "true" or c.get("ig_dm_sent") in (True, "true") \
        or c.get("fb_msg_sent") in (True, "true")


def contact_old(c, field):
    if field == "email_sent":
        return sent_state(c)
    return str(c.get(field) if c.get(field) is not None else "")


# ---------------------------------------------------------------- planner

class Planner:
    def __init__(self, dash, zb=None, zb_start="", candidates=None, manifest_ids=None,
                 today=None):
        self.today = today or datetime.now().strftime("%Y-%m-%d")
        self.zb = zb or {}
        self.zb_start = zb_start
        self.cands = candidates or {}
        self.manifest_ids = manifest_ids or {}
        self.venue_rows = list(dash.get("venues") or [])
        self.V = {}
        self.dup_venue_ids = defaultdict(list)
        for v in self.venue_rows:
            vid = str(v.get("venue_id") or "")
            self.dup_venue_ids[vid].append(v)
            self.V.setdefault(vid, v)
        self.contacts = list(dash.get("contacts") or [])
        self.byv = defaultdict(list)
        for i, c in enumerate(self.contacts):
            c["_i"] = i
            c["_email"] = R.normalize_email(c.get("email"))
            self.byv[str(c.get("venue_id") or "")].append(c)
        self.id_count = Counter(str(c.get("contact_id")) for c in self.contacts)
        self.gigs = list(dash.get("gigs") or [])
        self.outreach = list(dash.get("recentOutreach") or [])
        self.props = defaultdict(list)
        self.actions = []
        self.post_deleted = set()
        self.post_verified = {}

    # -- helpers
    def in_queue(self, c):
        v = self.V.get(str(c.get("venue_id")))
        return bool(c["_email"]) and c.get("verified") in SENDABLE and not sent_state(c) \
            and bool(v) and v.get("status") not in ("contacted", "closed")

    def propose(self, c, cat, action, reason, conf, field=None, new=None, evidence=None,
                cosmetic=False):
        # cosmetic: harmless display noise; kept in the plan but not counted as review burden
        self.props[c["_i"]].append({"category": cat, "action": action, "field": field,
                                    "new": new, "reason": reason, "confidence": conf,
                                    "evidence": evidence or [], "cosmetic": cosmetic})

    def cand_evidence(self, c):
        recs = self.cands.get((str(c.get("venue_id")), c["_email"] or str(c.get("email")).lower()), [])
        return sorted({"%s %s" % (r.get("timestamp", "")[:10], r.get("disposition", "")) for r in recs})[:4]

    def contact_target(self, c):
        return {"contact_id": str(c.get("contact_id")), "venue_id": str(c.get("venue_id")),
                "email": str(c.get("email") if c.get("email") is not None else ""),
                "name": str(c.get("name") or "")}

    def add_action(self, category, action, targets, reason, confidence, field=None, old=None,
                   new=None, extra=None):
        a = {"id": "", "category": category, "action": action, "targets": targets,
             "field": field, "old": old, "new": new, "reason": reason,
             "finding_id": CATEGORIES[category][0], "confidence": confidence,
             "executable": action in EXEC_ACTIONS}
        if extra:
            a.update(extra)
        self.actions.append(a)
        return a

    # -- contact checks
    def check_emails(self):
        by_venue_email = defaultdict(list)
        for c in self.contacts:
            if c["_email"]:
                by_venue_email[(str(c.get("venue_id")), c["_email"])].append(c)
        for c in self.contacts:
            raw = str(c.get("email") if c.get("email") is not None else "").strip()
            if not raw:
                continue
            if raw.lower() in FAKE_EMAIL_STRINGS:
                continue    # handled by check_valid_no_email
            e = c["_email"]
            if not e:
                self.propose(c, "junk_email", "delete_contact",
                             "malformed address %r" % raw[:60], "high")
                continue
            jr = R.junk_reason(e)
            if jr:
                self.propose(c, "junk_email", "delete_contact", "junk address (%s)" % jr, "high")
                continue
            hr = R.hard_reject_reason(e)
            if hr:
                self.propose(c, "hard_reject_email", "delete_contact",
                             "operational mailbox (%s)" % hr, "high",
                             evidence=self.cand_evidence(c))
                continue
            if e != raw.lower():
                twins = [x for x in by_venue_email[(str(c.get("venue_id")), e)]
                         if x is not c and str(x.get("email")).strip().lower() == e]
                if twins:
                    self.propose(c, "junk_email", "delete_contact",
                                 "encoded copy of %s already on this venue (%s)"
                                 % (e, twins[0].get("contact_id")), "high")
                else:
                    self.propose(c, "junk_email", "update_contact",
                                 "normalize encoded/wrapped address", "high", field="email", new=e)

    def check_valid_no_email(self):
        for c in self.contacts:
            raw = str(c.get("email") if c.get("email") is not None else "").strip()
            if raw and raw.lower() not in FAKE_EMAIL_STRINGS:
                continue
            ver = str(c.get("verified") or "")
            name = str(c.get("name") or "").strip()
            real = R.clean_person_name(name)
            if name.lower() in JUNK_NAMES or (not real and not name):
                self.propose(c, "valid_no_email", "delete_contact",
                             "no email and no real name (%r)" % name[:30], "high")
                continue
            if raw:
                self.propose(c, "valid_no_email", "update_contact",
                             "email stored as the string %r" % raw, "high", field="email", new="")
            if ver not in ("pending", "") and real:
                self.propose(c, "valid_no_email", "update_contact",
                             "verified=%r but there is no email (P3: email-less = pending)" % ver,
                             "high", field="verified", new="pending")
            elif ver not in ("pending", "") and not real:
                self.propose(c, "valid_no_email", "update_contact",
                             "verified=%r but there is no email; name %r is not a full name"
                             % (ver, name[:30]), "medium", field="verified", new="pending")

    def check_wrong_business(self):
        dom_venues = defaultdict(list)
        for v in self.V.values():
            d = venue_domain(v)
            if d and d not in R.SHARED_BRAND_DOMAINS:
                dom_venues[d].append(v)
        email_venues = defaultdict(set)
        for c in self.contacts:
            if c["_email"]:
                email_venues[c["_email"]].add(str(c.get("venue_id")))
        for vid, cs in self.byv.items():
            v = self.V.get(vid)
            if not v:
                continue
            vdom = venue_domain(v)
            host = venue_host(v)
            web_nonvenue = bool(host) and R.is_non_venue_host(host)
            foreign = defaultdict(list)
            for c in cs:
                e = c["_email"]
                if not e or R.junk_reason(e) or R.hard_reject_reason(e):
                    continue
                edom = R.registrable_domain(e.split("@", 1)[1])
                if edom in R.FREEMAIL_DOMAINS or (vdom and edom == vdom):
                    continue
                if domain_matches_venue(edom, v, vdom):
                    continue
                foreign[edom].append(c)
            if not foreign:
                continue
            n_foreign = sum(len(x) for x in foreign.values())
            apollo_share = sum(1 for x in foreign.values() for c in x
                               if str(c.get("source", "")).startswith("apollo")) / n_foreign
            scatter = len(foreign) >= 5 and n_foreign >= 8 and apollo_share >= 0.8
            for edom, group in foreign.items():
                # Another venue owns this domain only if its name matches the domain too
                # (umd.edu / virginia.gov host many venues without being any of them).
                owners = [w for w in dom_venues.get(edom, [])
                          if str(w.get("venue_id")) != vid and not same_business(w, v)
                          and domain_matches_venue(edom, w, "")]
                where = "venue domain %s" % vdom if vdom else "venue has no own website domain"
                for c in group:
                    ev = self.cand_evidence(c)
                    if owners:
                        on_owner = [w for w in owners if str(w.get("venue_id")) in email_venues[c["_email"]]]
                        ow = owners[0]
                        base = "%s is the website of %s %s (%s)" % (edom, ow.get("venue_id"),
                                                                  ow.get("name"), where)
                        if on_owner:
                            self.propose(c, "wrong_business", "delete_contact",
                                         base + "; the address is already on that venue", "high", evidence=ev)
                        elif len({str(w.get("venue_id")) for w in owners}) == 1:
                            self.propose(c, "wrong_business", "update_contact",
                                         base + "; move the contact there", "high",
                                         field="venue_id", new=str(ow.get("venue_id")), evidence=ev)
                        else:
                            self.propose(c, "wrong_business", "flag",
                                         base + "; several venues use that domain", "medium", evidence=ev)
                    elif web_nonvenue and len(group) >= 3:
                        self.propose(c, "wrong_business", "delete_contact",
                                     "venue website %s is not the venue's own site; %d contacts at %s"
                                     % (host, len(group), edom), "high", evidence=ev)
                    elif scatter and len(group) <= 3:
                        self.propose(c, "wrong_business", "delete_contact",
                                     "Apollo roster from unrelated orgs: %d contacts across %d foreign domains (%s)"
                                     % (n_foreign, len(foreign), where), "high", evidence=ev)
                    elif len(group) >= 3 and (edom in R.SHARED_BRAND_DOMAINS
                                              or edom.rsplit(".", 1)[-1] in ("gov", "edu", "mil")):
                        self.propose(c, "wrong_business", "flag",
                                     "%d contacts at %s (%s): institution or management company that may run "
                                     "the venue; review" % (len(group), edom, where), "medium", evidence=ev)
                    elif len(group) >= 3:
                        self.propose(c, "wrong_business", "delete_contact",
                                     "%d contacts at %s, name/domain doesn't match the venue (%s); "
                                     "may be a parent/management company" % (len(group), edom, where),
                                     "medium", evidence=ev)
                    else:
                        self.propose(c, "wrong_business", "flag",
                                     "off-domain %s (%s)" % (edom, where), "low", evidence=ev)

    def check_shared_roster(self):
        brand_venues = defaultdict(set)   # (brand domain, email) -> venue ids on that brand
        for c in self.contacts:
            v = self.V.get(str(c.get("venue_id")))
            if v and c["_email"]:
                vd = venue_domain(v)
                if vd in R.SHARED_BRAND_DOMAINS:
                    brand_venues[(vd, c["_email"])].add(str(v.get("venue_id")))
        for vid, cs in self.byv.items():
            v = self.V.get(vid)
            vdom = venue_domain(v) if v else ""
            if not v or vdom not in R.SHARED_BRAND_DOMAINS:
                continue
            toks = venue_tokens(v)
            for c in cs:
                e = c["_email"]
                if not e or R.junk_reason(e) or R.hard_reject_reason(e):
                    continue
                if R.registrable_domain(e.split("@", 1)[1]) != vdom:
                    continue
                title = str(c.get("title") or "")
                local = e.split("@", 1)[0]
                if any(t in title.lower() or t in local for t in toks):
                    continue
                src = str(c.get("source") or "")
                n_venues = len(brand_venues[(vdom, e)])
                if n_venues >= 2:
                    self.propose(c, "shared_brand_roster", "delete_contact",
                                 "brand-domain person (%s) copied onto %d venues; title %r doesn't name this property"
                                 % (vdom, n_venues, title[:60]), "high")
                elif names_other_property(title, v):
                    self.propose(c, "shared_brand_roster", "delete_contact",
                                 "title %r names another property (%s)" % (title[:60], vdom), "high")
                elif "apollo" in src and not RELEVANT_TITLE.search(title):
                    self.propose(c, "shared_brand_roster", "delete_contact",
                                 "Apollo person at brand domain %s; title %r doesn't name this property"
                                 % (vdom, title[:60]), "medium")
                elif "apollo" in src:
                    self.propose(c, "shared_brand_roster", "flag",
                                 "Apollo person at brand domain %s with a relevant title %r; can't tell which "
                                 "property they work at" % (vdom, title[:60]), "medium")
                else:
                    self.propose(c, "shared_brand_roster", "flag",
                                 "address on shared brand domain %s (source %s); check it is the property's"
                                 % (vdom, src or "?"), "low")

    def check_duplicates(self):
        by_email = defaultdict(list)
        for c in self.contacts:
            if c["_email"]:
                by_email[c["_email"]].append(c)
        for e, rows in by_email.items():
            if len(rows) < 2:
                continue
            per_venue = defaultdict(list)
            for c in rows:
                per_venue[str(c.get("venue_id"))].append(c)
            keep = {}
            for vid, vr in per_venue.items():
                vr = sorted(vr, key=lambda c: (0 if is_touched(c) else 1, c["_i"]))
                keep[vid] = vr[0]
                for c in vr[1:]:
                    if not is_touched(c):
                        self.propose(c, "duplicate_email", "delete_contact",
                                     "same address twice on this venue (kept %s)" % vr[0].get("contact_id"),
                                     "high")
            if len(keep) < 2:
                continue
            sent = sorted([c for c in keep.values() if sent_state(c) == "true"],
                          key=lambda c: str(c.get("email_sent_date") or ""))
            if sent:
                first = sent[0]
                for c in keep.values():
                    if not sent_state(c):
                        self.propose(c, "duplicate_email", "update_contact",
                                     "already emailed from %s on %s; hide this copy"
                                     % (first.get("venue_id"), str(first.get("email_sent_date") or "")[:10]),
                                     "high", field="email_sent", new="skipped")
                continue
            edom = R.registrable_domain(e.split("@", 1)[1])
            home = [c for c in keep.values()
                    if venue_domain(self.V.get(str(c.get("venue_id")), {})) == edom
                    and edom not in R.SHARED_BRAND_DOMAINS]
            home = home[0] if len(home) == 1 else min(keep.values(), key=lambda c: c["_i"])
            for c in keep.values():
                if c is not home and not sent_state(c):
                    self.propose(c, "duplicate_email", "update_contact",
                                 "same address also on %s (%s); keep one copy in the send queue"
                                 % (home.get("venue_id"), home.get("contact_id")),
                                 "medium", field="email_sent", new="skipped")

    def check_zb(self):
        for c in self.contacts:
            ver = str(c.get("verified") or "")
            e = c["_email"]
            if not e:
                continue
            if ver and ver not in VOCAB and ver != "abuse":
                self.propose(c, "zb_status", "update_contact",
                             "non-standard verified value %r" % ver, "medium",
                             field="verified", new="unverified")
                continue
            if ver != "valid":
                continue
            z = self.zb.get(e)
            if z and z["status"] and z["status"] != "valid":
                new = z["status"] if z["status"] in VOCAB else "do_not_mail"
                self.propose(c, "zb_status", "update_contact",
                             "saved 'valid' but ZeroBounce said %s%s on %s"
                             % (z["status"], "/" + z["sub_status"] if z["sub_status"] else "",
                                z["verified_at"][:10]), "high", field="verified", new=new)
            elif not z and self.zb_start and str(c.get("verified_date") or "")[:10] >= self.zb_start:
                new = "role" if R.is_role_email(e) and R.clean_person_name(c.get("name")) else "unverified"
                self.propose(c, "zb_status", "update_contact",
                             "saved 'valid' on %s (source %s) but ZeroBounce never checked it"
                             % (str(c.get("verified_date"))[:10], c.get("source")),
                             "high", field="verified", new=new)

    def check_names_titles(self):
        for c in self.contacts:
            name = str(c.get("name") or "").strip()
            title = str(c.get("title") or "")
            e = c["_email"]
            local = e.split("@", 1)[0] if e else ""
            restored = False
            if title.startswith("|"):
                body = title[1:].replace("\xa0", " ")
                parts = body.split("|||", 1)
                cand = re.split(r"\s*\|\s*", parts[0].strip())[0]
                cn = R.clean_person_name(cand)
                # Only a staff-listing pair ('|Name|||Title') is trusted; table cells joined
                # by tabs or 'Theo's - St. Michaels' style labels are not names.
                staff_pair = len(parts) > 1 and parts[1].strip() and "\t" not in cand and " - " not in cand
                if cn and staff_pair and not R.clean_person_name(name) and name_tied_to_email(cn, local):
                    self.propose(c, "pipe_title", "update_contact",
                                 "restore scraped name from pipe-garbage title %r" % title[:60],
                                 "high", field="name", new=cn, evidence=self.cand_evidence(c))
                    new_title = clean_title(parts[1] if len(parts) > 1 else "")
                    restored = True
                else:
                    new_title = ""
                self.propose(c, "pipe_title", "update_contact",
                             "pipe-garbage title from the IFS='|||' bug", "high",
                             field="title", new=new_title, evidence=self.cand_evidence(c),
                             cosmetic=title.strip() == "||||")
            if restored or not name or R.clean_person_name(name):
                continue
            if "*" in name:
                self.propose(c, "fake_name", "flag",
                             "masked Apollo name %r: enrich by Apollo id or drop (P2)" % name, "low")
                continue
            if not e:
                self.propose(c, "fake_name", "flag",
                             "email-less row without a full name %r (P3)" % name, "low")
                continue
            salvage = R.clean_person_name(re.sub(r"\(.*?\)", " ", name))
            nfe = R.name_from_email(e)
            if salvage and salvage != name:
                self.propose(c, "fake_name", "update_contact",
                             "drop parenthetical from name %r" % name, "medium", field="name", new=salvage)
            elif re.fullmatch(r"[A-Z][a-z]+ [A-Z]\.?", name) and compact(name) != compact(local):
                self.propose(c, "fake_name", "flag",
                             "partial Apollo name %r (last initial only): enrich or drop (P2)" % name, "low")
            elif compact(name) == compact(local) or compact(name) in compact(local):
                # 'jennifer@' named 'Jennifer' is harmless; 'Wineclub', 'Swimoffice', 'Bbryson' are not.
                first_name_box = (re.fullmatch(r"[a-z]{3,10}", compact(name)) and compact(name) == compact(local)
                                  and not R.is_role_email(e) and compact(name) not in R.ROLE_TOKENS
                                  and not any(w in compact(name) for w in R.ROLE_TOKENS if len(w) >= 4))
                self.propose(c, "fake_name", "update_contact",
                             "name %r is the email local part (P2)" % name,
                             "medium" if first_name_box else "high", field="name", new=nfe,
                             cosmetic=bool(first_name_box))
            else:
                self.propose(c, "fake_name", "update_contact",
                             "name %r is a role/boilerplate label, not a person" % name, "high",
                             field="name", new=nfe)

    def resolve_contacts(self):
        order = {k: i for i, k in enumerate(CONTACT_CAT_ORDER)}
        for i in sorted(self.props):
            c = self.contacts[i]
            props = self.props[i]
            tgt = self.contact_target(c)
            dels = sorted([p for p in props if p["action"] == "delete_contact"],
                          key=lambda p: (-CONF_RANK[p["confidence"]], order[p["category"]]))
            touched = is_touched(c)
            deleted_high = False
            if dels:
                best = dels[0]
                also = sorted({"%s: %s" % (p["category"], p["reason"]) for p in props
                               if p is not best and p["action"] != "update_contact"})
                if touched:
                    self.add_action(best["category"], "flag", tgt,
                                    best["reason"] + " (already emailed: flagged, never deleted)",
                                    best["confidence"], extra={"evidence": best["evidence"], "also": also})
                else:
                    self.add_action(best["category"], "delete_contact", tgt, best["reason"],
                                    best["confidence"], extra={"evidence": best["evidence"], "also": also,
                                                               "sent_state": sent_state(c)})
                    deleted_high = best["confidence"] == "high"
                    if deleted_high:
                        self.post_deleted.add(i)
            if deleted_high:
                continue
            by_field = defaultdict(list)
            for p in props:
                if p["action"] == "update_contact":
                    by_field[p["field"]].append(p)
            for field, ps in by_field.items():
                if field == "venue_id" and touched:
                    p = ps[0]
                    self.add_action(p["category"], "flag", tgt,
                                    p["reason"] + " (already emailed: flagged, not moved)",
                                    p["confidence"], extra={"evidence": p["evidence"]})
                    continue
                p = sorted(ps, key=lambda p: (-CONF_RANK[p["confidence"]], order[p["category"]]))[0]
                old = contact_old(c, field)
                if (p["new"] or "") == old:
                    continue
                self.add_action(p["category"], "update_contact", tgt, p["reason"], p["confidence"],
                                field=field, old=old, new=p["new"],
                                extra={"evidence": p["evidence"], "cosmetic": p["cosmetic"]})
                if field == "verified" and p["confidence"] == "high":
                    self.post_verified[i] = p["new"]
                if field == "venue_id" and p["confidence"] == "high":
                    self.post_deleted.add(i)    # leaves this venue
            if not dels:
                seen = set()
                for p in props:
                    if p["action"] == "flag" and p["category"] not in seen:
                        seen.add(p["category"])
                        self.add_action(p["category"], "flag", tgt, p["reason"], p["confidence"],
                                        extra={"evidence": p["evidence"]})

    # -- venue checks
    def append_note(self, v, category, conf, reason, text):
        """One notes write per venue: a second marker extends the first action (both would
        otherwise be checked against the same old value and the later write would win)."""
        vid = str(v.get("venue_id"))
        marker = "repair %s: %s" % (self.today, text)
        for a in self.actions:
            if a["action"] == "update_venue" and a["field"] == "notes" and a["targets"]["venue_id"] == vid:
                a["new"] += "; " + text
                a["reason"] += "; " + reason
                return a
        notes = str(v.get("notes") or "")
        return self.add_action(category, "update_venue", {"venue_id": vid, "name": v.get("name")}, reason,
                               conf, field="notes", old=notes, new=(notes + " | " if notes else "") + marker)

    def check_bad_websites(self):
        for v in self.V.values():
            w = str(v.get("website") or "").strip()
            if not w:
                continue
            host = R.host_of(w)
            if not host or not HOST_RE.match(host):
                why, conf = "not a real host (follower count or card text parsed as a URL)", "high"
            elif R.registrable_domain(host) in CLEAR_WEBSITE_HOSTS:
                why, conf = "%s is a directory/social/news site, not the venue's own" % host, "high"
            else:
                continue
            vid = str(v.get("venue_id"))
            tgt = {"venue_id": vid, "name": v.get("name")}
            self.add_action("bad_website", "update_venue", tgt, "website %r: %s" % (w, why), conf,
                            field="website", old=w, new="")
            self.append_note(v, "bad_website", conf, "keep the old website value in notes",
                             "website '%s' cleared (%s)" % (w, "not a real host" if "real host" in why else host))
            if v.get("status") == "untouched":
                self.add_action("bad_website", "update_venue", tgt,
                                "untouched requires a verified website (P4)", conf,
                                field="status", old="untouched", new="needs_review")

    def check_status_flow(self):
        cleared_web = {a["targets"]["venue_id"] for a in self.actions
                       if a["category"] == "bad_website" and a["field"] == "status"}
        for vid, v in self.V.items():
            status = str(v.get("status") or "")
            cs = self.byv.get(vid, [])
            live = [c for c in cs if c["_i"] not in self.post_deleted]
            ver = lambda c: self.post_verified.get(c["_i"], str(c.get("verified") or ""))  # noqa: E731
            usable = [c for c in live if c["_email"] and ver(c) in USABLE]
            sendable = [c for c in live if c["_email"] and ver(c) in SENDABLE | {"role"}]
            sent = [c for c in cs if sent_state(c) == "true"]
            tgt = {"venue_id": vid, "name": v.get("name")}
            in_area = R.in_target_area(v.get("state"))
            if status == "untouched" and usable and vid not in cleared_web:
                if in_area:
                    self.add_action("status_flow", "update_venue", tgt,
                                    "untouched venue holds %d valid/role/unverified contacts (P4 -> pipelined); "
                                    "Action Needed and build_batch never surface it" % len(usable),
                                    "high", field="status", old=status, new="pipelined")
                else:
                    self.add_action("status_flow", "flag", tgt,
                                    "untouched out-of-area venue holds %d valid/role/unverified contacts (P5: not promoted)"
                                    % len(usable), "low")
            elif status == "pipelined" and not usable:
                conf = "high" if not sendable else "medium"
                why = "pipelined with 0 valid/role/unverified contacts after this plan%s" % (
                    "" if not sendable else " (%d catch-all/unknown remain)" % len(sendable))
                self.add_action("status_flow", "update_venue", tgt, why + " (P4 -> needs_review)", conf,
                                field="status", old=status, new="needs_review")
                self.append_note(v, "status_flow", conf, "P4 notes marker",
                                 "pipelined with 0 valid/role/unverified contacts")
            elif status == "needs_review" and sent:
                self.add_action("status_flow", "flag", tgt,
                                "needs_review venue already has %d emails sent" % len(sent), "medium")
            elif status == "contacted":
                outreach = any(sent_state(c) in ("true", "skipped") or is_touched(c) for c in cs) \
                    or v.get("ig_dm_sent") or v.get("fb_msg_sent") or v.get("contact_form_sent")
                if not outreach:
                    unsent = [c for c in live if c["_email"] and ver(c) in SENDABLE and not sent_state(c)]
                    self.add_action("status_flow", "flag", tgt,
                                    "'contacted' with no outreach recorded (Mark Done used as dismiss?); %d unsent "
                                    "sendable emails. Candidate for the new 'dismissed' status once the new backend "
                                    "and app are live" % len(unsent), "medium" if unsent else "low",
                                    extra={"unsent_sendable": len(unsent)})
            elif status == "closed":
                self.add_action("status_flow", "flag", tgt,
                                "status 'closed' is outside P4 (closed venues belong in needs_review with a notes flag)",
                                "low")

    def check_location(self):
        for vid, v in self.V.items():
            reasons = []
            name = str(v.get("name") or "").strip().lower()
            addr = str(v.get("address") or "").strip().lower()
            city = str(v.get("city") or "")
            if addr and addr == name:
                reasons.append("address_is_name")
            if city and city_is_malformed(city):
                reasons.append("malformed_city %r" % city[:50])
            dist = v.get("distance_miles")
            if R.in_target_area(v.get("state")) and isinstance(dist, (int, float)) and dist > 150:
                reasons.append("distance %.0f mi" % dist)
            if reasons:
                conf = "low" if reasons == ["address_is_name"] else "medium"
                self.add_action("location", "flag", {"venue_id": vid, "name": v.get("name"),
                                                     "city": city, "state": v.get("state")},
                                "; ".join(reasons), conf)

    def check_duplicate_venues(self):
        parent = {}

        def find(x):
            while parent.setdefault(x, x) != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x
        keys = defaultdict(list)
        for v in self.venue_rows:
            vid = str(v.get("venue_id"))
            nc = name_compact(v.get("name"))
            if len(nc) >= 4:
                keys["name:%s|%s" % (nc, v.get("state") or "")].append(vid)
            d = venue_domain(v)
            if d and d not in R.SHARED_BRAND_DOMAINS:
                keys["domain:" + d].append(vid)
        for k, ids in keys.items():
            for other in ids[1:]:
                parent[find(other)] = find(ids[0])
        groups = defaultdict(set)
        for k, ids in keys.items():
            if len(set(ids)) > 1:
                for vid in ids:
                    groups[find(vid)].add(vid)
        for root, ids in groups.items():
            members = []
            for vid in sorted(ids):
                v = self.V[vid]
                cs = self.byv.get(vid, [])
                members.append({"venue_id": vid, "name": v.get("name"), "city": v.get("city"),
                                "state": v.get("state"), "status": v.get("status"),
                                "website": v.get("website"), "contacts": len(cs),
                                "sent": sum(1 for c in cs if sent_state(c) == "true")})
            doms = {venue_domain(self.V[m["venue_id"]]) for m in members} - {""}
            cities = {str(m["city"]).strip().lower() for m in members}
            statuses = {m["status"] for m in members}
            # build_batch already blocks untouched rows whose site is pipelined/contacted and rows
            # without a website, so only a same-name, same-city copy on ANOTHER site slips through.
            done = [m for m in members if m["status"] in ("contacted", "pipelined")]
            done_doms = {venue_domain(self.V[m["venue_id"]]) for m in done}
            risky = [m for m in members if m["status"] == "untouched" and R.in_target_area(m["state"])
                     and venue_domain(self.V[m["venue_id"]])
                     and venue_domain(self.V[m["venue_id"]]) not in done_doms
                     and any(name_compact(m["name"]) == name_compact(d["name"])
                             and str(m["city"]).strip().lower() == str(d["city"]).strip().lower() for d in done)]
            for m in members:
                m["rebatch_risk"] = m in risky
            conf = "high" if len(doms) == 1 and all(venue_domain(self.V[m["venue_id"]]) for m in members) \
                or len(cities) == 1 else "medium"
            self.add_action("duplicate_venue", "flag", {"venue_ids": [m["venue_id"] for m in members]},
                            "%d rows look like one business (%s)%s" % (
                                len(members), ", ".join(sorted(statuses)),
                                "; untouched copy on another site can be re-pipelined: " +
                                ", ".join(m["venue_id"] for m in risky) if risky else ""),
                            conf, extra={"members": members, "rebatch_risk": bool(risky)})

    def check_out_of_area(self):
        for vid, v in self.V.items():
            if R.in_target_area(v.get("state")):
                continue
            q = [c for c in self.byv.get(vid, []) if self.in_queue(c) and c["_i"] not in self.post_deleted]
            if not q and v.get("status") != "pipelined":
                continue
            self.add_action("out_of_area", "flag", {"venue_id": vid, "name": v.get("name"),
                                                    "state": v.get("state")},
                            "state %r is outside DC/MD/VA; status %s; %d sendable unsent contacts"
                            % (v.get("state") or "", v.get("status"), len(q)), "high",
                            extra={"queue_contacts": [c.get("contact_id") for c in q]})

    def check_rosters(self):
        for vid, cs in self.byv.items():
            v = self.V.get(vid)
            if not v:
                continue
            ap = [c for c in cs if "apollo" in str(c.get("source") or "")]
            if len(ap) <= 15:
                continue
            irrel = [c for c in ap if IRRELEVANT_TITLE.search(str(c.get("title") or ""))]
            rel = [c for c in ap if RELEVANT_TITLE.search(str(c.get("title") or "")) and c not in irrel]
            school = bool(SCHOOL_NAME.search(str(v.get("name") or "")))
            if len(rel) >= 0.5 * len(ap) and not school:
                continue
            unsent_irrel = [c.get("contact_id") for c in irrel if not sent_state(c)]
            self.add_action("apollo_roster", "flag", {"venue_id": vid, "name": v.get("name")},
                            "%d Apollo contacts, %d with a relevant title, %d clearly irrelevant%s"
                            % (len(ap), len(rel), len(irrel), "; venue looks like a school" if school else ""),
                            "medium", extra={"irrelevant_unsent_contact_ids": unsent_irrel,
                                             "title_sample": sorted({str(c.get("title"))[:40] for c in irrel})[:10]})

    def check_duplicate_ids(self):
        groups = defaultdict(list)
        for c in self.contacts:
            groups[str(c.get("contact_id"))].append(c)
        for cid, rows in sorted(groups.items()):
            if len(rows) < 2:
                continue
            same_venue = len({str(c.get("venue_id")) for c in rows}) < len(rows)
            self.add_action("duplicate_id", "needs_backend_fix", {"contact_id": cid, "rows": [
                {"venue_id": c.get("venue_id"), "email": c.get("email"), "name": c.get("name"),
                 "email_sent": sent_state(c), "in_send_queue": self.in_queue(c)} for c in rows]},
                "contact_id used by %d rows%s. The deployed backend's delete_contact matches the id only "
                "(and update_contact the first id+venue row), so these rows can't be targeted; after deploying "
                "the new apps_script.gs run ?action=fix_contact_ids (dry run), then &confirm=yes"
                % (len(rows), " (same venue: sent flags land on the wrong person)" if same_venue else ""),
                "high" if same_venue else "medium")
        for vid, rows in sorted(self.dup_venue_ids.items()):
            if len(rows) < 2:
                continue
            self.add_action("duplicate_id", "needs_backend_fix", {"venue_id": vid, "rows": [
                {"name": v.get("name"), "city": v.get("city"), "scraped_date": v.get("scraped_date"),
                 "status": v.get("status")} for v in rows]},
                "venue_id used by %d venues; update_venue/venue_detail act on the first row only. After deploying "
                "the new apps_script.gs run ?action=fix_venue_ids (dry run), then &confirm=yes: it renumbers the "
                "later row and remaps contacts/outreach/gigs where the evidence is unambiguous" % len(rows),
                "high")

    def check_orphans(self):
        cids = {str(c.get("contact_id")) for c in self.contacts}
        for vid, cs in self.byv.items():
            if vid not in self.V:
                self.add_action("orphan", "flag", {"venue_id": vid,
                                                   "contact_ids": [c.get("contact_id") for c in cs]},
                                "%d contacts point at a venue_id that doesn't exist" % len(cs), "medium")
        for o in self.outreach:
            vid, cid = str(o.get("venue_id") or ""), str(o.get("contact_id") or "")
            if (vid and vid not in self.V) or (cid and cid not in cids):
                self.add_action("orphan", "flag", {"venue_id": vid, "contact_id": cid},
                                "recent outreach row %s points at a missing venue/contact" % o.get("timestamp"),
                                "low")
        for g in self.gigs:
            vid = str(g.get("venue_id") or "")
            if vid and vid not in self.V:
                self.add_action("orphan", "flag", {"venue_id": vid, "gig_id": g.get("gig_id")},
                                "past gig %s (%s) points at a missing venue" % (g.get("gig_id"), g.get("venue_name")),
                                "medium")
        for vid, files in sorted(self.manifest_ids.items()):
            if vid not in self.V:
                self.add_action("orphan", "flag", {"venue_id": vid, "reports": files[:5]},
                                "report manifest lists a venue_id that doesn't exist", "low")

    # -- impact + output
    def annotate(self):
        cidx = {}
        for c in self.contacts:
            cidx.setdefault((str(c.get("contact_id")), str(c.get("venue_id")), str(c.get("email"))), c)
        for n, a in enumerate(self.actions, 1):
            a["id"] = "R-%05d" % n
            t = a["targets"]
            vid = str(t.get("venue_id") or "")
            v = self.V.get(vid, {})
            a["venue_status"] = v.get("status", "")
            c = cidx.get((t.get("contact_id"), vid, t.get("email"))) if "contact_id" in t and "email" in t else None
            if c is not None:
                a["in_send_queue"] = self.in_queue(c)
                if self.id_count[str(c.get("contact_id"))] > 1:
                    a["duplicate_contact_id"] = True
            else:
                qs = [x for x in self.byv.get(vid, []) if self.in_queue(x)] if vid else []
                a["venue_queue_contacts"] = len(qs)
                a["batch_pool"] = v.get("status") == "untouched" and R.in_target_area(v.get("state"))
            if a.get("in_send_queue") and a["venue_status"] == "pipelined" or a.get("batch_pool"):
                a["priority"] = 1
            elif a.get("in_send_queue") or a.get("venue_queue_contacts"):
                a["priority"] = 2
            else:
                a["priority"] = 3

    def build(self):
        self.check_emails()
        self.check_valid_no_email()
        self.check_wrong_business()
        self.check_shared_roster()
        self.check_duplicates()
        self.check_zb()
        self.check_names_titles()
        self.resolve_contacts()
        self.check_bad_websites()
        self.check_status_flow()
        self.check_location()
        self.check_duplicate_venues()
        self.check_out_of_area()
        self.check_rosters()
        self.check_duplicate_ids()
        self.check_orphans()
        self.annotate()
        return self.actions

    def summary(self):
        cats = {}
        for key, (fid, desc, sev) in CATEGORIES.items():
            acts = [a for a in self.actions if a["category"] == key]
            q_contacts, q_pipe, pool = set(), set(), set()
            for a in acts:
                t = a["targets"]
                if a.get("cosmetic"):
                    continue
                if a.get("in_send_queue"):
                    q_contacts.add((t["contact_id"], t["venue_id"], t["email"]))
                    if a["venue_status"] == "pipelined":
                        q_pipe.add((t["contact_id"], t["venue_id"], t["email"]))
                if a.get("batch_pool") and a["action"] != "flag":
                    pool.add(t.get("venue_id"))
                for m in a.get("members") or []:
                    if m.get("rebatch_risk"):
                        pool.add(m["venue_id"])
                for row in t.get("rows") or []:
                    if row.get("in_send_queue"):
                        q_contacts.add((t.get("contact_id"), row.get("venue_id"), row.get("email")))
                for cid in a.get("queue_contacts", []) or []:
                    q_contacts.add((cid, t.get("venue_id"), ""))
                if key == "apollo_roster":
                    vid = t.get("venue_id")
                    irr = set(a.get("irrelevant_unsent_contact_ids") or [])
                    for c in self.byv.get(vid, []):
                        if c.get("contact_id") in irr and self.in_queue(c):
                            q_contacts.add((c.get("contact_id"), vid, c.get("email")))
                            if self.V[vid].get("status") == "pipelined":
                                q_pipe.add((c.get("contact_id"), vid, c.get("email")))
            by = Counter((a["action"], a["confidence"]) for a in acts)
            cats[key] = {
                "finding_id": fid, "description": desc, "total": len(acts),
                "cosmetic": sum(1 for a in acts if a.get("cosmetic")),
                "writes_high": sum(n for (ac, cf), n in by.items() if ac in EXEC_ACTIONS and cf == "high"),
                "writes_medium": sum(n for (ac, cf), n in by.items() if ac in EXEC_ACTIONS and cf == "medium"),
                "deletes": sum(n for (ac, _), n in by.items() if ac == "delete_contact"),
                "updates": sum(n for (ac, _), n in by.items() if ac in ("update_contact", "update_venue")),
                "flags": sum(n for (ac, _), n in by.items() if ac == "flag"),
                "needs_backend_fix": sum(n for (ac, _), n in by.items() if ac == "needs_backend_fix"),
                "send_queue_contacts": len(q_contacts),
                "pipelined_queue_contacts": len(q_pipe),
                "batch_pool_venues": len(pool),
            }
            cats[key]["severity"] = sev
            cats[key]["review_impact"] = sev * (3 * len(q_pipe) + (len(q_contacts) - len(q_pipe)) + 2 * len(pool))
        ranked = sorted(cats, key=lambda k: (-cats[k]["review_impact"], -cats[k]["total"]))
        for r, k in enumerate(ranked, 1):
            cats[k]["rank"] = r
        return cats, ranked


# ---------------------------------------------------------------- markdown

def md_escape(s):
    return str(s if s is not None else "").replace("|", "\\|").replace("\n", " ")


def render_markdown(plan, planner):
    cats, ranked = plan["categories"], plan["ranking"]
    L = []
    L.append("# Sheet repair plan %s" % plan["date"])
    L.append("")
    d = plan["data"]
    L.append("Built %s from the %s dashboard (fetched %s, %d venues, %d contacts). "
             "ZeroBounce guard cache: %d answers since %s. Candidate log: %d records. "
             "Backend at plan time: %s."
             % (plan["generated_at"], d["dashboard"]["source"], d["dashboard"]["fetched_at"],
                d["venues"], d["contacts"], d["zb_answers"], d["zb_start"] or "?",
                d["candidate_records"], plan["backend_version_at_plan"] or "old (no version field)"))
    L.append("")
    L.append("Nothing has been written to the sheet. `flag` rows are report-only; `needs_backend_fix` rows "
             "wait for the new apps_script.gs deploy. Writes run only with `--apply` (default: high confidence only).")
    L.append("")
    L.append("## Ranked by how much manual review each category causes")
    L.append("")
    L.append("Review impact = severity x (3 x affected sendable unsent contacts on pipelined venues (emailed "
             "next) + 1 x other affected send-queue contacts + 2 x affected batch-pool venues (untouched, "
             "DC/MD/VA: the next 50-venue run draws from these)). Severity 3 = can cause a wrong, duplicate or "
             "bouncing send; 2 = hides/loses contacts or wastes batch slots and review time; 1 = misleading "
             "display. Cosmetic rows ('||||' titles, first-name mailboxes named after themselves) don't count.")
    L.append("")
    L.append("| # | Category | Findings | Sev | Impact | Queue contacts (pipelined) | Batch-pool venues | "
             "Writes high | Writes medium | Deletes | Flags | Backend fix |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k in ranked:
        c = cats[k]
        L.append("| %d | %s | %s | %d | %d | %d (%d) | %d | %d | %d | %d | %d | %d |" % (
            c["rank"], k, c["finding_id"], c["severity"], c["review_impact"], c["send_queue_contacts"],
            c["pipelined_queue_contacts"], c["batch_pool_venues"], c["writes_high"],
            c["writes_medium"], c["deletes"], c["flags"], c["needs_backend_fix"]))
    L.append("")
    ctx = plan["context"]
    L.append("## Context")
    L.append("")
    for k, v in ctx.items():
        L.append("- %s: %s" % (k.replace("_", " "), v))
    L.append("")
    for k in ranked:
        c = cats[k]
        acts = [a for a in plan["actions"] if a["category"] == k]
        L.append("## %d. %s (%s)" % (c["rank"], k, c["finding_id"]))
        L.append("")
        L.append(c["description"] + ".")
        L.append("")
        if not acts:
            L.append("Nothing found.")
            L.append("")
            continue
        by = Counter("%s/%s" % (a["action"], a["confidence"]) for a in acts)
        L.append("Actions: " + ", ".join("%s %d" % (x, n) for x, n in sorted(by.items())))
        L.append("")
        med = Counter(a["targets"].get("venue_id") for a in acts
                      if a["action"] == "delete_contact" and a["confidence"] == "medium")
        if med and k in ("wrong_business", "shared_brand_roster"):
            L.append("Medium-confidence deletes by venue (approve per venue with `--venues`):")
            L.append("")
            L.append("| venue | status | medium deletes | example reason |")
            L.append("|---|---|---|---|")
            for vid, n in med.most_common():
                ex = next(a for a in acts if a["targets"].get("venue_id") == vid
                          and a["action"] == "delete_contact" and a["confidence"] == "medium")
                L.append("| %s %s | %s | %d | %s |" % (vid, md_escape(planner.V.get(vid, {}).get("name", "")[:30]),
                                                      ex["venue_status"], n, md_escape(ex["reason"][:110])))
            L.append("")
        L.append("| id | action | conf | venue | contact | change | reason |")
        L.append("|---|---|---|---|---|---|---|")
        shown = sorted(acts, key=lambda a: (a["priority"], -CONF_RANK[a["confidence"]], a["id"]))[:5]
        for a in shown:
            t = a["targets"]
            who = "%s %s %s" % (t.get("contact_id", ""), t.get("name", "") if "contact_id" in t else "",
                                t.get("email", "")) if "contact_id" in t else ""
            venue = t.get("venue_id") or ",".join(t.get("venue_ids", [])[:4])
            vname = planner.V.get(t.get("venue_id") or "", {}).get("name", "")
            change = ""
            if a["field"]:
                change = "%s: %r -> %r" % (a["field"], str(a["old"])[:40], str(a["new"])[:40])
            L.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                a["id"], a["action"], a["confidence"], md_escape("%s %s" % (venue, vname[:30])),
                md_escape(who.strip()), md_escape(change), md_escape(a["reason"][:160])))
        L.append("")
    L.append("## Applying (Alex decides; never automatic)")
    L.append("")
    L.append("```")
    L.append("/usr/bin/python3 repair_data.py --apply %s --only junk_email,hard_reject_email --limit 5" % plan["plan_file"])
    L.append("/usr/bin/python3 repair_data.py --apply %s --only CATEGORY [--min-confidence medium] [--venues ID,ID]"
             % plan["plan_file"])
    L.append("```")
    L.append("")
    L.append("--apply re-reads the live sheet, skips rows that changed since this plan or that the deployed "
             "backend can't target uniquely (duplicate contact_ids), writes reports/repair/backup-*.json before "
             "the first write, and reads every write back with venue_detail. Emailed rows are never deleted.")
    L.append("")
    L.append("Suggested order: junk_email, hard_reject_email, valid_no_email, zb_status, wrong_business, "
             "shared_brand_roster, duplicate_email, pipe_title, fake_name, bad_website. Then rebuild the plan "
             "with --refresh and apply status_flow last: its P4 counts assume the high-confidence contact "
             "repairs are done. After the new apps_script.gs is deployed, run fix_contact_ids / fix_venue_ids "
             "(dry run, then confirm=yes) and rebuild: writes on duplicate-id rows are skipped until then.")
    L.append("")
    return "\n".join(L)


def build_plan(api, args):
    cache_dir = os.path.join(args.out_dir, "cache")
    dash, meta = load_dashboard(api, cache_dir, args.refresh, args.max_age_hours)
    zb, zb_start = load_zb_cache(args.zb_db)
    cands = load_candidates(args.candidates)
    manifest = load_manifest_ids(os.path.join(SCRIPT_DIR, "reports", "manifest.json"))
    backend = api.backend_version()
    today = datetime.now().strftime("%Y-%m-%d")
    p = Planner(dash, zb, zb_start, cands, manifest, today)
    actions = p.build()
    cats, ranked = p.summary()
    contacts = p.contacts
    ctx = {
        "sheet_verified_counts": dict(Counter(str(c.get("verified")) for c in contacts).most_common()),
        "send_queue_contacts_now": sum(1 for c in contacts if p.in_queue(c)),
        "send_queue_unknown_or_catch_all": sum(1 for c in contacts if p.in_queue(c)
                                               and c.get("verified") in ("unknown", "catch-all")),
        "venues_by_status": dict(Counter(str(v.get("status")) for v in p.V.values()).most_common()),
        "out_of_area_venues_by_state": dict(Counter(str(v.get("state") or "?") for v in p.V.values()
                                                    if not R.in_target_area(v.get("state"))).most_common()),
        "out_of_area_untouched": sum(1 for v in p.V.values() if not R.in_target_area(v.get("state"))
                                     and v.get("status") == "untouched"),
        "venues_address_equals_name": sum(1 for a in actions if a["category"] == "location"
                                          and "address_is_name" in a["reason"]),
        "untouched_dc_md_va_venues_hidden_from_batches_by_bad_city_or_distance": sum(
            1 for a in actions if a["category"] == "location" and a["confidence"] == "medium"
            and a.get("batch_pool")),
        "rows_with_duplicate_contact_id": sum(n for n in p.id_count.values() if n > 1),
        "contact_writes_blocked_on_old_backend_by_duplicate_ids": sum(
            1 for a in actions if a.get("duplicate_contact_id") and a["action"] in EXEC_ACTIONS),
    }
    base = os.path.join(args.out_dir, "plan-%s" % today)
    plan = {
        "plan_version": PLAN_VERSION, "generated_at": now_iso(), "date": today,
        "plan_file": base + ".json", "api": "APPS_SCRIPT_URL",
        "backend_version_at_plan": backend,
        "data": {"dashboard": meta, "venues": len(p.V), "contacts": len(contacts),
                 "zb_answers": len(zb), "zb_start": zb_start, "zb_db": args.zb_db,
                 "candidate_records": sum(len(x) for x in cands.values())},
        "categories": cats, "ranking": ranked, "context": ctx, "actions": actions,
    }
    os.makedirs(args.out_dir, exist_ok=True)
    with open(base + ".json.tmp", "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=1, default=str)
    os.replace(base + ".json.tmp", base + ".json")
    with open(base + ".md", "w", encoding="utf-8") as f:
        f.write(render_markdown(plan, p))
    return plan, base


# ---------------------------------------------------------------- apply

def _norm(s):
    return str(s if s is not None else "").strip().lower()


def _live_value(c, field):
    return contact_old(c, field)


def apply_plan(api, plan_path, only=None, min_conf="high", limit=None, out_dir=None, log=print,
               venues=None):
    with open(plan_path, encoding="utf-8") as f:
        plan = json.load(f)
    if plan.get("plan_version") != PLAN_VERSION:
        raise RuntimeError("plan_version %r not supported" % plan.get("plan_version"))
    out_dir = out_dir or os.path.dirname(os.path.abspath(plan_path))
    if only:
        unknown = set(only) - set(CATEGORIES)
        if unknown:
            raise RuntimeError("unknown categories: %s" % ", ".join(sorted(unknown)))
    sel = [a for a in plan["actions"]
           if a["action"] in EXEC_ACTIONS and a.get("executable")
           and CONF_RANK.get(a["confidence"], 0) >= CONF_RANK[min_conf]
           and (not only or a["category"] in only)
           and (not venues or a["targets"].get("venue_id") in venues)]
    if limit:
        sel = sel[:limit]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    results = {a["id"]: {"status": "pending"} for a in sel}
    if not sel:
        log("Nothing to apply (filters: only=%s min_confidence=%s)." % (only, min_conf))
        return {"applied": 0, "results": {}}

    version = api.backend_version()
    new_backend = bool(version)
    dash = fetch_dashboard(api)
    live_c = dash["contacts"]
    live_v = defaultdict(list)
    for v in dash["venues"]:
        live_v[str(v.get("venue_id"))].append(v)
    by_id = defaultdict(list)
    for c in live_c:
        by_id[str(c.get("contact_id"))].append(c)

    todo, backup_c, backup_v = [], {}, {}
    for a in sel:
        t = a["targets"]
        if a["action"] == "update_venue":
            rows = live_v.get(t["venue_id"], [])
            if len(rows) != 1:
                results[a["id"]] = {"status": "skipped", "why": "venue_id matches %d rows" % len(rows)}
                continue
            live = str(rows[0].get(a["field"]) if rows[0].get(a["field"]) is not None else "")
            if live != str(a["old"] or ""):
                results[a["id"]] = {"status": "skipped", "why": "stale: live %s=%r, plan expected %r"
                                    % (a["field"], live[:60], str(a["old"])[:60])}
                continue
            backup_v[t["venue_id"]] = rows[0]
            todo.append(a)
            continue
        cid, vid, email = t["contact_id"], t["venue_id"], t["email"]
        same = [c for c in by_id.get(cid, []) if str(c.get("venue_id")) == vid]
        exact = [c for c in same if _norm(c.get("email")) == _norm(email)]
        if len(exact) != 1:
            results[a["id"]] = {"status": "skipped", "why": "row not found or not unique (%d matches)" % len(exact)}
            continue
        row = exact[0]
        if new_backend:
            addressable = len(same) == 1 or len(exact) == 1
        elif a["action"] == "delete_contact":
            addressable = len(by_id[cid]) == 1       # old delete_contact matches the id only
        else:
            addressable = len(same) == 1             # old update_contact takes the first id+venue row
        if not addressable:
            results[a["id"]] = {"status": "skipped",
                                "why": "ambiguous duplicate contact_id on the %s backend" % (version or "old")}
            continue
        if a["action"] == "delete_contact":
            if is_touched(row):
                results[a["id"]] = {"status": "skipped", "why": "row has been emailed since the plan; never delete"}
                continue
            if _norm(row.get("name")) != _norm(t.get("name")):
                results[a["id"]] = {"status": "skipped", "why": "stale: name changed since the plan"}
                continue
        else:
            live = _live_value(row, a["field"])
            if live != str(a["old"] if a["old"] is not None else ""):
                results[a["id"]] = {"status": "skipped", "why": "stale: live %s=%r, plan expected %r"
                                    % (a["field"], live[:60], str(a["old"])[:60])}
                continue
        backup_c[(cid, vid, str(row.get("email")))] = row
        todo.append(a)

    os.makedirs(out_dir, exist_ok=True)
    backup_path = os.path.join(out_dir, "backup-%s.json" % stamp)
    with open(backup_path, "w", encoding="utf-8") as f:
        json.dump({"taken_at": now_iso(), "plan": os.path.abspath(plan_path), "backend_version": version,
                   "actions": [a["id"] for a in todo], "contacts": list(backup_c.values()),
                   "venues": list(backup_v.values())}, f, indent=1, default=str)
        f.flush()
        os.fsync(f.fileno())
    log("Backup of %d contact rows and %d venue rows: %s" % (len(backup_c), len(backup_v), backup_path))

    groups = defaultdict(list)
    for a in todo:
        groups[a["targets"]["venue_id"]].append(a)
    rank = {"delete_contact": 0, "update_contact": 1, "update_venue": 2}
    for vid, acts in groups.items():
        # Email fixes go first: the new backend turns verified=pending into 'unverified'
        # while a row still has an email (even the string 'None').
        acts.sort(key=lambda a: (rank[a["action"]], a.get("field") != "email", a["id"]))
        deleted, email_now, done = set(), {}, []
        for a in acts:
            t = a["targets"]
            rowkey = (t.get("contact_id"), t.get("email"))
            if a["action"] != "update_venue" and rowkey in deleted:
                results[a["id"]] = {"status": "superseded", "why": "row deleted in this run"}
                continue
            try:
                if a["action"] == "delete_contact":
                    resp = api.get("delete_contact", contact_id=t["contact_id"], venue_id=vid, email=t["email"])
                elif a["action"] == "update_contact":
                    resp = api.get("update_contact", contact_id=t["contact_id"], venue_id=vid,
                                   email=email_now.get(rowkey, t["email"]), field=a["field"],
                                   value=a["new"] if a["new"] is not None else "")
                else:
                    extra = {"force": "true"} if a["field"] == "status" else {}   # new backend: demotions
                    resp = api.get("update_venue", venue_id=vid, field=a["field"],
                                   value=a["new"] if a["new"] is not None else "", **extra)
            except Exception as exc:
                results[a["id"]] = {"status": "error", "why": str(exc)[:200]}
                continue
            if str(resp.get("status")) != "ok":
                results[a["id"]] = {"status": "error", "why": str(resp.get("message") or resp)[:200]}
                continue
            results[a["id"]] = {"status": "written"}
            if a["action"] == "delete_contact":
                deleted.add(rowkey)
            if a["action"] == "update_contact" and a["field"] == "email":
                email_now[rowkey] = a["new"]
            done.append(a)
        if not done:
            continue
        readback_vids = {vid} | {a["new"] for a in done if a.get("field") == "venue_id"}
        details = {}
        for rv in sorted(readback_vids):
            try:
                details[rv] = api.get("venue_detail", venue_id=rv)
            except Exception as exc:
                details[rv] = {"status": "error", "message": str(exc)[:200]}
        for a in done:
            results[a["id"]] = verify_write(a, details, email_now)

    counts = Counter(r["status"] for r in results.values())
    result_path = os.path.join(out_dir, "apply-%s.json" % stamp)
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump({"finished_at": now_iso(), "plan": os.path.abspath(plan_path), "backup": backup_path,
                   "backend_version": version, "filters": {"only": only, "min_confidence": min_conf,
                                                           "limit": limit,
                                                           "venues": sorted(venues) if venues else None},
                   "counts": counts, "results": results}, f, indent=1)
    log("Apply finished: %s. Details: %s" % (", ".join("%s %d" % kv for kv in sorted(counts.items())),
                                             result_path))
    return {"applied": counts.get("verified", 0), "counts": counts, "results": results,
            "backup": backup_path, "result_file": result_path}


def verify_write(a, details, email_now):
    t = a["targets"]
    vid = t["venue_id"]
    det = details.get(vid) or {}
    if det.get("status") != "ok":
        return {"status": "unverified", "why": "venue_detail failed: %s" % str(det.get("message"))[:120]}
    if a["action"] == "update_venue":
        got = str((det.get("venue") or {}).get(a["field"], ""))
        ok = got == str(a["new"] or "")
        return {"status": "verified" if ok else "readback_mismatch", "got": got[:120]}
    email = email_now.get((t["contact_id"], t["email"]), t["email"])

    def find(d):
        return [c for c in (d.get("contacts") or []) if str(c.get("contact_id")) == t["contact_id"]
                and _norm(c.get("email")) == _norm(email)]
    if a["action"] == "delete_contact":
        left = find(det)
        return {"status": "verified" if not left else "readback_mismatch",
                "got": "row still present" if left else "gone"}
    if a["field"] == "venue_id":
        moved = find(details.get(a["new"]) or {})
        still = find(det)
        ok = bool(moved) and not still
        return {"status": "verified" if ok else "readback_mismatch",
                "got": "moved" if ok else "present on old venue=%s, new venue=%s" % (bool(still), bool(moved))}
    rows = find(det)
    if len(rows) != 1:
        return {"status": "readback_mismatch", "got": "%d matching rows" % len(rows)}
    got = contact_old(rows[0], a["field"])
    return {"status": "verified" if _norm(got) == _norm(a["new"]) else "readback_mismatch", "got": got[:120]}


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out-dir", default=os.path.join(SCRIPT_DIR, "reports", "repair"))
    ap.add_argument("--refresh", action="store_true", help="re-fetch the dashboard instead of using the cache")
    ap.add_argument("--max-age-hours", type=float, default=24.0, help="max cache age before re-fetching")
    ap.add_argument("--zb-db", default=os.environ.get("ZB_DB_PATH") or
                    os.path.join(os.path.expanduser("~"), ".outreach", "zerobounce_guard.sqlite3"))
    ap.add_argument("--candidates", default=os.path.join(SCRIPT_DIR, "reports", "discovery-candidates.jsonl"))
    ap.add_argument("--apply", metavar="PLAN.json", help="execute a plan's writes against the live sheet")
    ap.add_argument("--only", help="comma-separated categories to apply")
    ap.add_argument("--min-confidence", choices=["high", "medium"], default="high")
    ap.add_argument("--limit", type=int, help="apply at most N actions")
    ap.add_argument("--venues", help="comma-separated venue_ids: apply only actions on these venues")
    args = ap.parse_args(argv)

    if args.apply:
        api = Api(api_url(), allow_writes=True)
        only = [x.strip() for x in args.only.split(",") if x.strip()] if args.only else None
        venues = {x.strip() for x in args.venues.split(",") if x.strip()} if args.venues else None
        res = apply_plan(api, args.apply, only, args.min_confidence, args.limit, venues=venues)
        bad = sum(n for k, n in res.get("counts", {}).items() if k in ("error", "readback_mismatch", "unverified"))
        return 1 if bad else 0

    if args.only or args.limit or args.venues or args.min_confidence != "high":
        ap.error("--only/--limit/--venues/--min-confidence only apply with --apply")
    api = Api(api_url(), allow_writes=False)
    plan, base = build_plan(api, args)
    print("Plan: %s.json / .md (dashboard: %s, %s)" % (base, plan["data"]["dashboard"]["source"],
                                                     plan["data"]["dashboard"]["fetched_at"]))
    print("%-4s %-20s %7s %6s %6s %6s %6s %7s" % ("rank", "category", "impact", "queue", "w-high", "w-med",
                                                   "flags", "backend"))
    for k in plan["ranking"]:
        c = plan["categories"][k]
        print("%-4d %-20s %7d %6d %6d %6d %6d %7d" % (c["rank"], k, c["review_impact"], c["send_queue_contacts"],
                                                      c["writes_high"], c["writes_medium"], c["flags"],
                                                      c["needs_backend_fix"]))
    print("No writes made. To apply: /usr/bin/python3 repair_data.py --apply %s.json --only CATEGORY" % base)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:     # fail loudly (P9)
        print("repair_data.py: FAILED: %s" % exc, file=sys.stderr)
        sys.exit(2)
