#!/usr/bin/env python3
"""Shared contact + venue rules for the outreach scripts.

One home for the lists that used to be copied (and drifted) across
pipeline.sh, postcheck.sh, build_batch.sh, discover.sh and apps_script.gs.
Python code imports this module; bash calls the CLI:

    python3 outreach_rules.py check-email EMAIL [--venue-domain D] [--venue-name N]
        [--found-on-venue-site] [--venue-mailto] [--shared-domain]
    python3 outreach_rules.py name-from-email EMAIL
    python3 outreach_rules.py clean-name "Some Name"
    python3 outreach_rules.py org-matches "Apollo Org Name" "Venue Name"
    python3 outreach_rules.py domain URL_OR_HOST
    python3 outreach_rules.py target-states

apps_script.gs can't import this. Its GENERIC_PREFIXES / hard-reject lists
must be kept in sync by hand (search for "outreach_rules.py" there).

Email policy (matches the runbook):
  - junk / placeholder / hash addresses are dropped before any paid check
  - operational mailboxes (noreply, privacy, careers, marketing, press, ...) are hard-rejected
  - off-domain addresses are hard-rejected; free-mail (gmail etc.) is only kept
    when it was found on the venue's own site AND the local part carries a venue-name token
  - on shared brand domains (sonesta.com, invitedclubs.com, ...) only addresses found
    on the property's own pages count
  - role mailboxes (info@, events@, ...) never go to ZeroBounce (it always answers
    role_based/do_not_mail); they are only saved when a real person name is attached
  - names are never invented from the email local part except first.last patterns
"""
import json
import re
import sys
import urllib.parse

TARGET_STATES = ("DC", "MD", "VA")

FREEMAIL_DOMAINS = {
    "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "outlook.com",
    "hotmail.com", "live.com", "msn.com", "aol.com", "icloud.com", "me.com",
    "mac.com", "comcast.net", "verizon.net", "att.net", "sbcglobal.net",
    "protonmail.com", "proton.me", "gmx.com", "zoho.com", "cox.net",
    # ISPs: small owner-run venues often still use these
    "earthlink.net", "mindspring.com", "zoominternet.net", "bellsouth.net",
    "charter.net", "optonline.net", "rcn.com", "erols.com", "starpower.net",
    "frontier.com", "frontiernet.net", "windstream.net", "centurylink.net",
    "juno.com", "netzero.net", "atlanticbb.net", "shentel.net", "ntelos.net",
    "md.metrocast.net", "metrocast.net", "aim.com", "mail.com", "fastmail.com",
    "pm.me", "rocketmail.com",
}

# Site builders host many unrelated sites under one domain: a venue on one has
# no domain of its own, so the off-domain gate can't apply (apps_script.gs keeps
# the same list).
SITE_BUILDER_HOSTS = {
    "wixsite.com", "weebly.com", "godaddysites.com", "business.site", "square.site",
    "toast.site", "wordpress.com", "blogspot.com", "webflow.io", "carrd.co",
    "myshopify.com", "site123.me", "jimdosite.com", "webnode.com", "mystrikingly.com",
    "yolasite.com",
}

# Brand / management-company domains that host many properties. A venue whose
# website lives on one of these does NOT own the domain, so domain-wide Apollo
# searches and domain-wide email matches pull in corporate + other-property staff.
SHARED_BRAND_DOMAINS = {
    "marriott.com", "hilton.com", "hiltonhotels.com", "conradhotels.com",
    "ihg.com", "kimptonhotels.com", "hyatt.com", "sonesta.com", "sonder.com",
    "wyndhamhotels.com", "choicehotels.com", "bestwestern.com", "accor.com",
    "radissonhotels.com", "fourseasons.com", "ritzcarlton.com", "aubergeresorts.com",
    "invitedclubs.com", "clubcorp.com", "maggianos.com", "aramark.com",
    "sodexo.com", "compass-usa.com", "hhmhospitality.com", "aimbridge.com",
    "highgate.com", "davidsonhospitality.com", "sagehospitality.com",
    "loewshotels.com", "omnihotels.com", "fairmont.com", "sofitel.com",
    "brookdale.com", "sunriseseniorliving.com", "erickson.com",
}

# Hosts that are never a venue's own website.
NON_VENUE_HOSTS = {
    "facebook.com", "instagram.com", "twitter.com", "x.com", "linkedin.com",
    "yelp.com", "tripadvisor.com", "opentable.com", "resy.com", "google.com",
    "youtube.com", "wikipedia.org", "theknot.com", "weddingwire.com",
    "zola.com", "eventective.com", "peerspace.com", "tagvenue.com",
    "fox5dc.com", "washingtonpost.com", "washingtonian.com", "eater.com",
    "timeout.com", "yellowpages.com", "mapquest.com", "foursquare.com",
    "doordash.com", "ubereats.com", "grubhub.com", "toasttab.com",
    "menupages.com", "seamless.com", "singleplatform.com", "allmenus.com",
}

PLACEHOLDER_EMAILS = {
    "user@domain.com", "your@email.com", "name@email.com", "email@email.com",
    "info@mysite.com", "example@mysite.com", "you@example.com", "test@test.com",
    "john@doe.com", "johndoe@example.com", "email@domain.com", "name@domain.com",
    "your@domain.com", "yourname@domain.com", "youremail@domain.com",
    "info@example.com", "someone@example.com", "hello@example.com",
}

JUNK_EMAIL_DOMAINS = {
    "example.com", "example.org", "domain.com", "email.com", "mysite.com",
    "yoursite.com", "yourdomain.com", "website.com", "sentry.io",
    "sentry-next.wixpress.com", "sentry.wixpress.com", "wixpress.com",
    "wix.com", "squarespace.com", "godaddy.com", "shopify.com",
    "mailchimp.com", "sendgrid.net", "hubspot.com", "zendesk.com",
    "cloudflare.com", "googleapis.com", "gstatic.com", "fontawesome.io",
    "sentry.zendesk.com", "latofonts.com", "typekit.net",
}

# File extensions that show up as fake TLDs when regexes grab "x@2x.png" etc.
BAD_TLDS = {
    "png", "jpg", "jpeg", "gif", "webp", "svg", "css", "js", "read", "html",
    "htm", "php", "asp", "aspx", "pdf", "ico", "mp4", "json", "xml", "txt",
}

# Operational mailboxes nobody books gigs from.
# Prefix match: long, unambiguous words ("privacyinquiries@", "noreply-events@").
HARD_REJECT_PREFIXES = (
    "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "webmaster",
    "billing", "privacy", "careers", "recruiting", "recruitment", "humanresources",
    "marketing", "mailer-daemon", "postmaster", "dataremoval", "unsubscribe",
    "optout", "emailoptout", "accountspayable", "accountsreceivable", "payroll",
    "invoice", "travelpass", "giftcard", "sponsorship", "compliance",
)
# Whole-word match only (first token or the whole local part), so a person
# called "Pressley" or "Hrach" isn't rejected.
HARD_REJECT_TOKENS = {
    "hr", "pr", "ap", "ar", "jobs", "job", "career", "press", "media", "abuse",
    "legal", "security", "accounting", "donations", "donate", "volunteer",
    "volunteers", "giftcards",
}
# Anywhere in the local part.
HARD_REJECT_SUBSTRINGS = (
    "optout", "opt-out", "unsubscribe", "privacy", "noreply", "no-reply",
    "donotreply", "mailer-daemon", "dataremoval", "gdpr",
)

# Role mailbox words. A local part whose first token (or whole string) is one of
# these is a shared inbox, not a person. Keep apps_script.gs GENERIC_PREFIXES in sync.
ROLE_TOKENS = {
    "info", "information", "hello", "contact", "contactus", "sales", "events",
    "event", "privateevents", "private", "specialevents", "reservations",
    "reservation", "reserve", "booking", "bookings", "book", "enquiries",
    "enquiry", "inquiries", "inquiry", "office", "general", "frontdesk", "front",
    "reception", "support", "admin", "catering", "groups", "group", "groupsales",
    "weddings", "wedding", "meetings", "meeting", "manager", "gm",
    "generalmanager", "eat", "dine", "dining", "host", "hostess", "mail", "team",
    "staff", "concierge", "banquets", "banquet", "venue", "rentals", "rental",
    "tastingroom", "tasting", "wine", "wineclub", "club", "members", "member",
    "membership", "clubhouse", "proshop", "golf", "tennis", "spa", "swim",
    "pool", "fitness", "kitchen", "chef", "bar", "restaurant", "cafe", "shop",
    "store", "orders", "order", "tickets", "ticket", "boxoffice", "music",
    "entertainment", "hr", "guest", "guests", "guestservices", "service",
    "customerservice", "feedback", "social", "community", "programs",
    "education", "tours", "tour", "visit", "visitors", "farm", "hotel", "inn",
    "desk", "operations", "ops", "director", "gallery", "museum", "partners",
    "partnerships", "hospitality", "accounts", "account", "billing", "owner",
    "owners", "management", "mgmt", "hq", "corporate", "weddingsales",
}

# Words that mean a scraped "name" is page boilerplate, not a person.
NAME_BOILERPLATE = {
    "hours", "visit", "us", "contact", "rights", "reserved", "copyright", "llc",
    "inc", "menu", "reservations", "reservation", "events", "event", "team",
    "staff", "email", "phone", "fax", "address", "directions", "info",
    "information", "privacy", "policy", "terms", "home", "about", "careers",
    "gift", "cards", "shop", "order", "online", "book", "now", "click", "here",
    "follow", "subscribe", "newsletter", "sign", "up", "login", "account",
    "sales", "office", "catering", "private", "dining", "wedding", "weddings",
    "club", "hotel", "restaurant", "winery", "vineyard", "vineyards", "bar",
    "grill", "cafe", "kitchen", "general", "manager", "department", "desk",
    "front", "guest", "services", "service", "group", "groups", "the", "and",
    "of", "at", "for", "our", "your", "with", "tasting", "room", "wine",
    "open", "closed", "daily", "monday", "tuesday", "wednesday", "thursday",
    "friday", "saturday", "sunday", "am", "pm", "map", "location", "locations",
    # button and link text that scrapes pick up as person names
    "send", "message", "opt", "get", "learn", "view", "inquire", "inquiry",
    "inquiries", "rsvp", "tickets", "request", "quote", "outing", "outings",
    "rate", "rates", "basic", "golf",
    # page text seen as names (Sep 26 run: "Tournament Registration", "First Served
    # Basis.", "Magdalena Buyout")
    "registration", "tournament", "basis", "served", "buyout", "buyouts",
    # businesses that show up next to addresses (designer credits, agencies)
    "studio", "studios", "design", "designs", "designer", "media", "creative",
    "agency", "photography",
}

# Role words that page text puts in front of a name ("Chef-owner Pierre Laurent",
# "Owner Marc Duval"): stripped before the name is judged.
NAME_ROLE_PREFIXES = {
    "chef", "owner", "owners", "coowner", "proprietor", "gm", "manager", "director",
    "executive", "sous", "pastry", "head", "general", "president", "founder",
    "cofounder", "partner", "managing", "contact", "email", "call", "meet", "by",
    "mr", "mrs", "ms", "dr", "sommelier", "innkeeper", "host", "hosts",
}

_EMAIL_RE = re.compile(r"^[a-z0-9][a-z0-9._%+'-]*@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,24}$")
_MULTI_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
    "co.nz", "com.br", "com.mx", "co.jp", "co.za", "com.sg", "co.in",
}


def normalize_email(raw):
    """Lowercase + strip wrappers. Returns '' if it isn't a plausible address."""
    if not raw:
        return ""
    e = urllib.parse.unquote(str(raw)).strip().lower()
    e = re.sub(r"^mailto:", "", e)
    e = e.split("?")[0]
    e = re.sub(r"\s+", "", e)
    e = e.strip(".,;:()[]<>\"'`")
    if not _EMAIL_RE.match(e):
        return ""
    tld = e.rsplit(".", 1)[-1]
    if tld in BAD_TLDS:
        return ""
    return e


def host_of(url_or_host):
    s = (url_or_host or "").strip().lower()
    if not s:
        return ""
    if "://" not in s:
        s = "http://" + s
    try:
        host = urllib.parse.urlparse(s).hostname or ""
    except ValueError:
        return ""
    return host[4:] if host.startswith("www.") else host


def registrable_domain(url_or_host):
    """example.co.uk / sub.example.com -> example.co.uk / example.com (no PSL download)."""
    host = host_of(url_or_host)
    if not host or re.match(r"^\d+(\.\d+){3}$", host):
        return host
    parts = host.split(".")
    # venue.wixsite.com is its own site, not wixsite.com's
    if len(parts) >= 3 and ".".join(parts[-2:]) in SITE_BUILDER_HOSTS:
        return ".".join(parts[-3:])
    if len(parts) >= 3 and ".".join(parts[-2:]) in _MULTI_SUFFIXES:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def is_shared_domain(url_or_host):
    return registrable_domain(url_or_host) in SHARED_BRAND_DOMAINS


def is_non_venue_host(url_or_host):
    return registrable_domain(url_or_host) in NON_VENUE_HOSTS


def is_site_builder_host(url_or_host):
    host = host_of(url_or_host)
    return any(host == b or host.endswith("." + b) for b in SITE_BUILDER_HOSTS)


def _local_tokens(local):
    return [t for t in re.split(r"[._\-+]+", re.sub(r"\d+", "", local)) if t]


# One-person mailboxes: at a small venue chef@ is the chef and owner@ the owner, so
# they're saved as contacts (title from the mailbox) even when no name is printed.
PERSON_ROLE_TITLES = {
    "owner": "Owner", "owners": "Owner", "chef": "Chef", "executivechef": "Executive Chef",
    "headchef": "Head Chef", "gm": "General Manager", "generalmanager": "General Manager",
    "proprietor": "Proprietor", "founder": "Founder", "cofounder": "Co-Founder",
    "president": "President",
}


def person_role_title(email):
    e = normalize_email(email)
    if not e:
        return ""
    return PERSON_ROLE_TITLES.get(re.sub(r"[^a-z]", "", e.split("@", 1)[0]), "")


def is_role_email(email):
    e = normalize_email(email)
    if not e:
        return False
    local = e.split("@", 1)[0]
    stripped = re.sub(r"[\d._\-+]", "", local)
    if stripped in ROLE_TOKENS:
        return True
    toks = _local_tokens(local)
    if not toks:
        return True
    if toks[0] in ROLE_TOKENS:
        return True
    # e.g. "privateevents", "eventsdc", "weddingsales": starts with a role word of 5+ letters
    return any(stripped.startswith(w) and len(w) >= 5 for w in ROLE_TOKENS)


def junk_reason(email):
    """Reason string if the address is junk that must never reach ZeroBounce."""
    e = normalize_email(email)
    if not e:
        return "malformed"
    if e in PLACEHOLDER_EMAILS:
        return "placeholder"
    local, dom = e.split("@", 1)
    reg = registrable_domain(dom)
    if dom in JUNK_EMAIL_DOMAINS or reg in JUNK_EMAIL_DOMAINS:
        return "junk_domain:" + reg
    if re.fullmatch(r"[0-9a-f]{16,}", local):
        return "hash_localpart"
    if re.search(r"\d{7,}", local):
        return "long_digits"
    if re.search(r"@\dx\.", e) or local.endswith(("2x", "3x")) and "." in dom and dom.split(".")[-1] in BAD_TLDS:
        return "image_filename"
    if len(local) > 64:
        return "too_long"
    return ""


def hard_reject_reason(email):
    e = normalize_email(email)
    if not e:
        return "malformed"
    local = e.split("@", 1)[0]
    for sub in HARD_REJECT_SUBSTRINGS:
        if sub in local:
            return "hard_reject:" + sub
    for p in HARD_REJECT_PREFIXES:
        if local.startswith(p):
            return "hard_reject:" + p
    toks = _local_tokens(local)
    whole = re.sub(r"[\d._\-+]", "", local)
    if whole in HARD_REJECT_TOKENS or (toks and toks[0] in HARD_REJECT_TOKENS):
        return "hard_reject:" + (whole if whole in HARD_REJECT_TOKENS else toks[0])
    return ""


def name_from_email(email):
    """'jane.doe@x.com' -> 'Jane Doe'. Anything else -> '' (never invent names)."""
    e = normalize_email(email)
    if not e or is_role_email(e):
        return ""
    local = e.split("@", 1)[0]
    m = re.fullmatch(r"([a-z]{2,20})[._-]([a-z]{2,25})", local)
    if not m:
        return ""
    first, last = m.group(1), m.group(2)
    if first in ROLE_TOKENS or last in ROLE_TOKENS:
        return ""
    return f"{first.capitalize()} {last.capitalize()}"


def clean_person_name(name):
    """Return a tidy 'First Last' if the text is a plausible person name, else ''."""
    if not name:
        return ""
    n = re.sub(r"\s+", " ", str(name)).strip(" \t\r\n,;:-|")
    if not n or "*" in n or "@" in n or re.search(r"\d", n) or len(n) > 60:
        return ""
    toks = n.split(" ")
    while len(toks) > 2 and all(re.sub(r"[^a-z]", "", p.lower()) in NAME_ROLE_PREFIXES
                                for p in re.split(r"[-/&]", toks[0]) if p):
        toks = toks[1:]
    n = " ".join(toks).strip(" ,;:-|")
    toks = n.split(" ")
    if all(re.sub(r"[^a-z]", "", p.lower()) in NAME_ROLE_PREFIXES for p in re.split(r"[-/&]", toks[0]) if p):
        return ""  # "Chef John", "Dr Smith": no first + last name left
    if len(toks) < 2 or len(toks) > 5:
        return ""
    alpha = [t for t in toks if re.fullmatch(r"[A-Za-zÀ-ÿ'’.\-]+", t) and re.search(r"[A-Za-zÀ-ÿ]", t)]
    if len(alpha) != len(toks):
        return ""
    # possessives are place names ("Theo's - Rehoboth Beach"), not people
    if any(re.search(r"['’]s$", t, re.I) for t in toks):
        return ""
    words = [re.sub(r"[^a-zà-ÿ]", "", t.lower()) for t in toks]
    if sum(1 for w in words if len(w) >= 2) < 2:
        return ""
    if any(w in NAME_BOILERPLATE for w in words if len(w) >= 2):
        return ""
    if n.isupper() or n.islower():
        n = " ".join(t.capitalize() for t in toks)
    return n


def is_real_person_name(name):
    return bool(clean_person_name(name))


_STOP = {"the", "a", "an", "and", "of", "at", "in", "by", "on", "&"}
_GENERIC_VENUE_WORDS = {
    "bar", "grill", "bistro", "cafe", "restaurant", "kitchen", "tavern", "pub",
    "lounge", "house", "club", "wine", "winery", "vineyard", "vineyards",
    "brewing", "inn", "suites", "resort", "lodge", "manor", "estate", "hotel",
    "country", "golf", "yacht", "city", "national", "collection", "spa",
    "farm", "cellars", "events", "event", "center", "centre", "group",
    "hospitality", "company", "co", "llc", "inc", "dc", "va", "md",
    "washington", "virginia", "maryland",
}


def _fold(s):
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFKD", s or "") if not unicodedata.combining(c))


def _words(s):
    return [w for w in re.sub(r"[^a-z0-9\s]", " ", _fold(s).lower()).split() if w not in _STOP]


def org_name_matches(org_name, venue_name):
    """Strict-ish NAME gate for 'is this Apollo/website org the same business as the venue'.

    Names alone can't separate 'Mount Vernon Club' (Baltimore) from 'Mount Vernon
    Country Club' (Alexandria): callers must ALSO require the org's domain to equal
    the venue's own domain, or the org's city/state to match the venue.

    Requires a shared distinctive word (not a generic venue word). 'La Lou Bistro'
    vs 'Petit Louis Bistro' -> False; 'Gvino' vs 'Gvino Wine Bar' -> True.
    Empty / generic org names never match.
    """
    ow, vw = _words(org_name), _words(venue_name)
    od = [w for w in ow if w not in _GENERIC_VENUE_WORDS and len(w) >= 3]
    vd = [w for w in vw if w not in _GENERIC_VENUE_WORDS and len(w) >= 3]
    if not od or not vd:
        return False
    on, vn = "".join(ow), "".join(vw)
    if len(on) >= 5 and len(vn) >= 5 and (on == vn or (on in vn and len(on) >= 0.6 * len(vn)) or (vn in on and len(vn) >= 0.6 * len(on))):
        return True
    shared = set(od) & set(vd)
    return len(shared) >= 1 and len(shared) >= 0.5 * len(set(vd))


_FREEMAIL_TOKEN_IGNORE = {"hotel", "restaurant", "events", "event", "country",
                          "club", "winery", "vineyard", "vineyards", "house", "the"}


def venue_name_tokens(venue_name):
    """Words from the venue name that can tie a free-mail address to the venue."""
    return {w for w in _words(venue_name) if len(w) >= 4 and w not in _FREEMAIL_TOKEN_IGNORE}


def freemail_linked_to_venue(local, venue_name):
    local = (local or "").lower()
    if any(t in local for t in venue_name_tokens(venue_name)):
        return True
    compact = "".join(_words(venue_name))
    return len(compact) >= 5 and compact[:5] in local


def check_email(email, venue_domain="", venue_name="", found_on_venue_site=False,
                shared_domain=None, venue_mailto=False):
    """Decide what to do with a scraped/enriched address before paying for it.

    Returns dict: {email, action, reason, is_role, name_hint}
    found_on_venue_site: the address was seen on the venue's own website pages
    venue_mailto: it was an explicit mailto: link on the venue's own contact/about/
                  events page (strongest evidence; lets a free-mail address through)

      action: 'verify'  -> send to ZeroBounce, save if valid
              'role'    -> role mailbox: don't pay; save only with a real person name
              'reject'  -> drop (log as candidate)
    """
    e = normalize_email(email)
    out = {"email": e, "action": "reject", "reason": "", "is_role": False, "name_hint": "",
           "person_role": ""}
    if not e:
        out["reason"] = "malformed"
        return out
    r = junk_reason(e) or hard_reject_reason(e)
    if r:
        out["reason"] = r
        return out
    dom = e.split("@", 1)[1]
    vreg = registrable_domain(venue_domain) if venue_domain else ""
    site_builder = bool(vreg and is_site_builder_host(vreg))
    if site_builder:
        vreg = ""
    ereg = registrable_domain(dom)
    if shared_domain is None:
        shared_domain = vreg in SHARED_BRAND_DOMAINS
    if vreg and ereg != vreg:
        if ereg in FREEMAIL_DOMAINS or dom in FREEMAIL_DOMAINS:
            local = e.split("@", 1)[0]
            linked = venue_mailto or (found_on_venue_site and freemail_linked_to_venue(local, venue_name))
            if not linked:
                out["reason"] = "freemail_unlinked"
                return out
        else:
            out["reason"] = f"off_domain:{ereg}!={vreg}"
            return out
    if site_builder:
        # No domain of its own to compare against: a foreign address needs on-site
        # evidence (designer credits like studio@pixelworks.com sit in the footer).
        local = e.split("@", 1)[0]
        if ereg in FREEMAIL_DOMAINS or dom in FREEMAIL_DOMAINS:
            if not (venue_mailto or (found_on_venue_site and freemail_linked_to_venue(local, venue_name))):
                out["reason"] = "freemail_unlinked"
                return out
        else:
            label = re.sub(r"[^a-z0-9]", "", ereg.split(".")[0])
            toks = [w for w in _words(venue_name) if w not in _GENERIC_VENUE_WORDS and len(w) >= 4]
            if not (venue_mailto or any(t in label for t in toks)):
                out["reason"] = f"site_builder_foreign:{ereg}"
                return out
    if vreg and shared_domain and not found_on_venue_site:
        out["reason"] = f"shared_brand_domain:{vreg}"
        return out
    out["is_role"] = is_role_email(e)
    out["name_hint"] = name_from_email(e)
    if out["is_role"] and not shared_domain:
        out["person_role"] = person_role_title(e)
    out["action"] = "role" if out["is_role"] else "verify"
    out["reason"] = "ok"
    return out


def in_target_area(state):
    return (state or "").strip().upper() in TARGET_STATES


def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check-email")
    c.add_argument("email")
    c.add_argument("--venue-domain", default="")
    c.add_argument("--venue-name", default="")
    c.add_argument("--found-on-venue-site", action="store_true")
    c.add_argument("--shared-domain", action="store_true", default=None)
    c.add_argument("--venue-mailto", action="store_true")
    n = sub.add_parser("name-from-email")
    n.add_argument("email")
    cn = sub.add_parser("clean-name")
    cn.add_argument("name")
    om = sub.add_parser("org-matches")
    om.add_argument("org_name")
    om.add_argument("venue_name")
    d = sub.add_parser("domain")
    d.add_argument("url")
    sub.add_parser("target-states")
    a = ap.parse_args(argv)
    if a.cmd == "check-email":
        print(json.dumps(check_email(a.email, a.venue_domain, a.venue_name,
                                     a.found_on_venue_site, a.shared_domain,
                                     a.venue_mailto)))
    elif a.cmd == "name-from-email":
        print(name_from_email(a.email))
    elif a.cmd == "clean-name":
        print(clean_person_name(a.name))
    elif a.cmd == "org-matches":
        ok = org_name_matches(a.org_name, a.venue_name)
        print("yes" if ok else "no")
        return 0 if ok else 1
    elif a.cmd == "domain":
        print(json.dumps({"host": host_of(a.url), "registrable": registrable_domain(a.url),
                          "shared": is_shared_domain(a.url), "non_venue": is_non_venue_host(a.url),
                          "site_builder": is_site_builder_host(a.url)}))
    elif a.cmd == "target-states":
        print(" ".join(TARGET_STATES))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
