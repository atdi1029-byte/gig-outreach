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
    python3 outreach_rules.py search-query google|linkedin --name N [--tail T] [--detail FILE]

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
    "thened.com",   # Ned's Club: DC, NoMad NYC, London, Doha (Nov 11 2026: the DC crawl read the NYC pages)
    "radissonhotels.com", "fourseasons.com", "ritzcarlton.com", "aubergeresorts.com",
    "invitedclubs.com", "clubcorp.com", "maggianos.com", "aramark.com",
    "sodexo.com", "compass-usa.com", "hhmhospitality.com", "aimbridge.com",
    "highgate.com", "davidsonhospitality.com", "sagehospitality.com",
    "loewshotels.com", "omnihotels.com", "fairmont.com", "sofitel.com",
    "brookdale.com", "sunriseseniorliving.com", "erickson.com",
    # one domain, several venues (Nov 8 2026: Sagamore Pendry Baltimore was read as Pendry Wharf DC)
    "pendry.com", "lochbar.com", "jhu.edu",
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
    # Wedding / venue marketplaces and listing directories (Nov 11 2026: The Lake House's
    # sheet website was its herecomestheguide.com listing and the run saved 31 of the
    # listing company's own staff). Their staff are never a venue's contacts.
    "herecomestheguide.com", "partyslate.com", "weddingspot.com", "wedding-spot.com",
    "venuereport.com", "uniquevenues.com", "splacer.co", "giggster.com", "eventup.com",
    "cvent.com", "bizbash.com", "breezit.com", "bridebook.com", "junebugweddings.com",
    "stylemepretty.com", "brides.com", "withjoy.com", "weddingrule.com",
    "eventbrite.com", "meetup.com", "allevents.in", "patch.com", "nextdoor.com",
    "groupon.com", "zomato.com", "bbb.org", "chamberofcommerce.com", "manta.com",
    "booking.com", "expedia.com", "hotels.com", "travelocity.com", "kayak.com",
    "priceline.com", "airbnb.com", "vrbo.com", "visitmaryland.org", "visitvirginia.com",
    "virginia.org", "visitannapolis.org", "baltimore.org", "washington.org",
    "dcpreservation.org", "alltrails.com", "tiktok.com",
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
    "owners", "management", "mgmt", "hq", "corporate", "weddingsales", "food",
    "foodandbeverage", "fandb", "fnb",
    # club officers' mailboxes pass from one person to the next (commodore@, vice.commodore@,
    # fleet.captain@ were sent to ZeroBounce and saved nameless or as "Fleet Captain", Nov 10 2026)
    "commodore", "vicecommodore", "rearcommodore", "pastcommodore", "fleetcaptain",
    "harbormaster", "dockmaster", "treasurer", "secretary",
    "executivedirector", "execdirector",
    # private-party inboxes (party@muisupperclub.com went to ZeroBounce, Nov 11 2026)
    "party", "parties", "privateparties", "pdr", "privatedining",
}

# Department / program / institution words (Nov 11 2026). A mailbox made of one of these is
# a shared inbox, never a person: calendar@, creche@, gala@, rector@, fieldtrips@, glass@,
# ceramics@, minigolf@ were sent to ZeroBounce, came back valid and were saved with no name,
# and annapolis.admissions@ became "Annapolis Admissions" (first.last). Matched as a whole
# token anywhere in the local part, never as a prefix ("glassman@" is a person).
FUNCTION_TOKENS = {
    "calendar", "creche", "gala", "galas", "rectory", "ministry", "familyministry", "worship",
    "fieldtrip", "fieldtrips", "classroom", "classrooms", "chesapeakeclassrooms",
    "academy", "camps", "classes", "lessons", "learning", "workshops",
    "admissions", "gradadmissions", "admission", "bookstore", "registrar", "alumni", "deansoffice",
    "deans", "financialaid", "aid", "studentaccounts", "student", "students",
    "careerservices", "healthcenter", "health", "wellness", "counseling", "publicsafety",
    "safety", "police", "patrol", "helpdesk", "it", "usersupport", "support",
    "printshop", "archives", "exhibitions", "collections",
    "ceramics", "pottery", "minigolf", "studio", "studios", "development", "giving", "advancement",
    "philanthropy", "grants", "facilities", "facility", "maintenance", "housekeeping", "accounting",
    "finance", "payables", "receivables", "humanresources", "communications", "comms",
    "socialmedia", "newsletter", "webteam", "international",
    "classics", "visitsjc", "anvisit", "president", "provost", "chancellor",
    "clagettfarm", "nursery", "kennel",
}
# Function words that are also surnames or first names (John Rector, Dean Smith, Summer
# Lee): they make a shared inbox only as the whole local part (rector@, glass@, camp@).
FUNCTION_FIRST_TOKENS = {
    "rector", "deacon", "pastor", "parish", "church", "chapel", "choir", "school", "library",
    "glass", "camp", "dean", "summer", "garden", "gardens", "farm", "lab", "print", "news",
    "design", "editor", "tech", "help", "user", "web", "class", "career",
}

# Mailboxes and titles nobody books a musician from (Nov 11 2026: the two burn runs saved
# accountants, attorneys, HR, IT, admissions, scientists, fundraisers and caregivers).
# A mailbox local part with one of these tokens is rejected outright, name or not.
BACK_OFFICE_LOCAL_TOKENS = {
    "accounting", "accountant", "accounts", "ap", "ar", "finance", "payables", "receivables",
    "treasurer", "controller", "cfo", "legal", "counsel", "hr", "humanresources", "people",
    "it", "helpdesk", "techsupport", "usersupport", "admissions", "gradadmissions", "admission",
    "registrar", "financialaid", "studentaccounts", "bookstore", "development", "giving",
    "advancement", "philanthropy", "donor", "grants", "publicsafety", "police", "patrol",
    "healthcenter", "counseling", "maintenance", "facilities", "housekeeping",
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
    # headings read as names beside a mailto (Nov 10 2026: "El Patio Rewards Program",
    # "Job Description", "Corporate Meetings")
    "program", "programs", "rewards", "reward", "loyalty", "description", "meetings", "meeting", "corporate",
    "placeholder", "template",
    "job", "jobs", "responsibilities", "summary", "overview", "opportunities",
}

# Role words that page text puts in front of a name ("Chef-owner Pierre Laurent",
# "Owner Marc Duval"): stripped before the name is judged.
NAME_ROLE_PREFIXES = {
    "chef", "owner", "owners", "coowner", "proprietor", "gm", "manager", "director",
    "executive", "sous", "pastry", "head", "general", "president", "founder",
    "cofounder", "partner", "managing", "contact", "email", "call", "meet", "by",
    "mr", "mrs", "ms", "dr", "sommelier", "innkeeper", "host", "hosts",
    # clergy and office holders ("Deacon Nancy" was saved as a person, Nov 11 2026)
    "deacon", "rector", "pastor", "reverend", "rev", "father", "fr", "msgr", "monsignor",
    "delegate", "senator", "councilman", "councilwoman", "councilmember", "rep", "hon",
    "honorable", "mayor", "judge",
}

# Words that make a scraped "name" an office, program or institution ("Annapolis Bookstore",
# "Financial Aid", "Human Resources", "Summer Academy", "Public Safety", "Academic
# Leadership", "Faculty Committee" were saved or offered as people, Nov 11 2026).
NON_PERSON_NAME_WORDS = {
    "admissions", "bookstore", "registrar", "academy", "financial", "aid", "resources", "safety",
    "health", "healthcenter", "wellness", "counseling", "helpdesk", "support", "alumni",
    "development", "deansoffice", "deans", "careerservices", "printshop", "graduate",
    "undergraduate", "student", "students", "international", "classics", "calendar", "creche",
    "gala", "ministry", "parish", "foundation", "association", "society", "college", "university",
    "school", "library", "museum", "gallery", "institute", "department", "committee", "council",
    "faculty", "leadership", "academic", "president", "fieldtrips", "classrooms", "ceramics",
    "minigolf", "accounts", "business", "operations", "administration", "secretariat",
    "majeure",   # "Force Majeure" in an event contract PDF (Old Ebbitt Grill, Nov 12 2026)
    "studies", "services", "programs",   # departments ("Byzantine Studies" beside byzantine@doaks.org)
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
    # US locality domains: "md.us" is a public suffix, not one organisation. house.state.md.us
    # was read as "md.us", so five legislators on a neighbourhood association's links page
    # made "@md.us" the venue's own mail domain (Guilford Association, Nov 11 2026).
    if len(parts) >= 3 and parts[-1] == "us" and len(parts[-2]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def is_institution_domain(url_or_host):
    """A university, school or government domain (.edu, .gov, .mil, *.xx.us). Such a domain
    hosts a whole institution's staff: a venue inside it never gets the institution's directory."""
    reg = registrable_domain(url_or_host)
    if not reg:
        return False
    return reg.endswith((".edu", ".gov", ".mil")) or bool(re.search(r"\.[a-z]{2}\.us$", reg)) \
        or reg.endswith((".gov.uk", ".ac.uk"))


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


# General inboxes nobody books gigs from (Alex, Sep 27 2026: "they always are a waste of
# time"). Rejected outright, even when the site names the owner. Function inboxes such as
# events@/catering@/chef@ stay in ROLE_TOKENS and are saved with a real person's name.
GENERAL_INBOX_TOKENS = {
    "info", "information", "contact", "contactus", "hello", "hi", "mail", "email",
    "office", "general", "admin", "administrator", "enquiries", "enquiry", "inquiries",
    "inquiry", "frontdesk", "front", "reception", "welcome", "help", "support",
    "questions", "stay", "guest", "guests", "guestservices", "sayhello", "sayhi",
}


def is_general_inbox(email):
    e = normalize_email(email)
    if not e:
        return False
    local = e.split("@", 1)[0]
    stripped = re.sub(r"[\d._\-+]", "", local)
    if stripped in GENERAL_INBOX_TOKENS:
        return True
    toks = _local_tokens(local)
    return len(toks) == 1 and toks[0] in GENERAL_INBOX_TOKENS


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
    if stripped in FUNCTION_TOKENS or any(t in FUNCTION_TOKENS for t in toks):
        return True
    if stripped in FUNCTION_FIRST_TOKENS:
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
    # site-template demo pages (template.placeholder@gmail.com on Squarespace's sample pages)
    if "placeholder" in local or set(_local_tokens(local)) & {"template", "example", "yourname", "youremail", "lorem"}:
        return "placeholder"
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


_BUSINESS_LOCAL_RE = re.compile(
    r".{3,}(?:restaurantgroup|restaurants?|hospitality|group|catering|events|llc|bistro|tavern|"
    r"cafe|winery|vineyards?|brewery|brewing|farms?|club|hotel|kitchen)$")


def name_from_email(email, venue_name=""):
    """'jane.doe@x.com' -> 'Jane Doe'. Anything else -> '' (never invent names).

    A free-mail address whose second part is a word of the venue's name is the venue's
    mailbox, not first.last: arlene.cork@gmail.com at County Cork Wine Pub is Arlene
    Stecher, not "Arlene Cork" (Nov 8 2026)."""
    e = normalize_email(email)
    if not e or is_role_email(e):
        return ""
    local, dom = e.split("@", 1)
    m = re.fullmatch(r"([a-z]{2,20})[._-]([a-z]{2,25})", local)
    if not m:
        return ""
    first, last = m.group(1), m.group(2)
    if first in ROLE_TOKENS or last in ROLE_TOKENS:
        return ""
    # the second part is a business, not a surname: mark.forgerestaurantgroup@gmail.com is not
    # "Mark Forgerestaurantgroup" (Forge Southern Comfort, Nov 12 2026)
    if _BUSINESS_LOCAL_RE.search(last) or _BUSINESS_LOCAL_RE.search(first):
        return ""
    if venue_name:
        vdist = [w for w in _words(venue_name) if len(w) >= 5 and w not in _GENERIC_VENUE_WORDS]
        if any(len(last) > len(w) and last.startswith(w) for w in vdist):
            return ""
    if venue_name and (dom in FREEMAIL_DOMAINS or registrable_domain(dom) in FREEMAIL_DOMAINS):
        vwords = {w for w in _words(venue_name) if len(w) >= 3}
        if first in vwords or last in vwords:
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
    if any(w in NAME_BOILERPLATE or w in NON_PERSON_NAME_WORDS for w in words if len(w) >= 2):
        return ""
    # a place read as a name ("New Orleans" on Orleans Bistro's pages, Nov 10 2026)
    if words[0] in {"new", "north", "south", "east", "west", "fort", "mount", "port", "lake", "saint", "old"}:
        return ""
    # an address line read as a name ("Smith Ave" on the Dye House site, Nov 8 2026)
    # ("Crystal Drive" beside hello@altitude-va.com)
    if words[-1] in {"ave", "avenue", "st", "rd", "road", "blvd", "boulevard", "pkwy", "parkway", "hwy", "highway",
                     "drive", "terrace", "circle", "turnpike", "ln", "ct", "pl", "trl", "cir", "sq"}:
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


# A club writes from its initials (Nov 8 2026): eycbookingagent@gmail.com on Eastern
# Yacht Club's officials page, eyc_treasurer@aol.com, cryc.org@gmail.com for Corsica
# River Yacht Club. The initials (3+ letters, every word) count only as a whole token of
# the local part or followed by a club job, so ervin@ never ties to Elk Run Vineyards.
_INITIALS_JOB = re.compile(r"(?:booking\w*|events?|rentals?|hall\w*|social|treasurer|secretary|sec|"
                           r"(?:vice|rear)?commodore|fleetcaptain|manager|mgr|gm|office|catering|weddings?)$")


def venue_initials_in_local(local, venue_name):
    words = [w for w in _words(venue_name) if w not in {"inc", "llc", "co"}]
    ini = "".join(w[0] for w in words if w[0].isalpha())
    if len(words) < 3 or len(ini) < 3:
        return False
    for tok in re.split(r"[^a-z]+", (local or "").lower()):
        if tok == ini or (tok.startswith(ini) and _INITIALS_JOB.match(tok[len(ini):])):
            return True
    return False


def freemail_linked_to_venue(local, venue_name):
    local = (local or "").lower()
    if any(t in local for t in venue_name_tokens(venue_name)):
        return True
    if venue_initials_in_local(local, venue_name):
        return True
    compact = "".join(_words(venue_name))
    return len(compact) >= 5 and compact[:5] in local


def check_email(email, venue_domain="", venue_name="", found_on_venue_site=False,
                shared_domain=None, venue_mailto=False, local_verified=False):
    """Decide what to do with a scraped/enriched address before paying for it.

    Returns dict: {email, action, reason, is_role, name_hint}
    found_on_venue_site: the address was seen on the venue's own website pages
    venue_mailto: it was an explicit mailto: link on the venue's own contact/about/
                  events page (strongest evidence; lets a free-mail address through)
    local_verified: an Apollo person at the property's own org, located in the venue's
                  city, with a booking title: counts like on-site evidence on a shared
                  brand / host-organisation domain (Nov 11 2026)

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
    if is_general_inbox(e):
        out["reason"] = "general_inbox"
        out["is_role"] = True
        return out
    bo = back_office_mailbox(e)
    if bo:
        out["reason"] = "back_office_mailbox:" + bo
        return out
    dom = e.split("@", 1)[1]
    if registrable_domain(dom) in NON_VENUE_HOSTS:
        # a listing site's / marketplace's own staff (herecomestheguide.com), never the venue's
        out["reason"] = "listing_domain:" + registrable_domain(dom)
        return out
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
    if vreg and shared_domain and not (found_on_venue_site or local_verified):
        out["reason"] = f"shared_brand_domain:{vreg}"
        return out
    out["is_role"] = is_role_email(e)
    out["name_hint"] = name_from_email(e, venue_name)
    if out["is_role"] and not shared_domain:
        out["person_role"] = person_role_title(e)
    out["action"] = "role" if out["is_role"] else "verify"
    out["reason"] = "ok"
    return out


def back_office_mailbox(email):
    """The back-office token of a mailbox (accounting@, admissions@, hr@ ...), else ''."""
    e = normalize_email(email)
    if not e:
        return ""
    local = e.split("@", 1)[0]
    stripped = re.sub(r"[\d._\-+]", "", local)
    if stripped in BACK_OFFICE_LOCAL_TOKENS:
        return stripped
    for t in _local_tokens(local):
        if t in BACK_OFFICE_LOCAL_TOKENS:
            return t
    return ""


# ---------------------------------------------------------------------------
# Who can book a classical guitarist (Nov 11 2026). Alex wants contacts only for people
# who could book him: owner, GM, events / private dining / catering / F&B, music or
# performing-arts programming, resident lifestyle / activities directors. The two burn runs
# of Nov 11 saved ~300 contacts, ~80% of them junk (accountants, attorneys, HR, IT,
# admissions, scientists, fundraisers, caregivers, a college's whole directory). One scorer
# for every step: pipeline.sh (web, Apollo, LinkedIn), postcheck.sh and night_save.py.
# ---------------------------------------------------------------------------
_TITLE_VETO = re.compile(
    r"\b(intern|interns|internship|student|students|volunteer|housekeeping|housekeeper|laundry|security|"
    r"public safety|loss prevention|accountant|accounting|finance|financial|payroll|budget|steward|engineer|"
    r"engineering|maintenance|it|information technology|technology|helpdesk|help desk|systems|network|"
    r"web|webmaster|developer|software|data|database|purchasing|procurement|human resources?|hr|"
    r"for people|people (and|&) culture|people operations|recruiter|recruiting|recruitment|talent acquisition|"
    r"spa|esthetician|massage|server|servers|dishwasher|line cook|prep cook|busser|barback|valet|caddie|"
    r"caddies|legal|attorney|lawyer|counsel|paralegal|compliance|controller|comptroller|cfo|"
    r"chief financial|bookkeeper|bookkeeping|treasurer|accounts payable|accounts receivable|billing|"
    r"admissions?|registrar|financial aid|dean|deans|provost|faculty|professor|lecturer|tutor|academic|"
    r"scientist|science|research|researcher|policy|advocacy|restoration|conservation|fundraising|"
    r"fundraiser|(?<!business )development (officer|director|associate|manager|coordinator|assistant|operations)|"
    r"director of development|vp of development|philanthropy|philanthropic|major gifts?|major giving|"
    r"planned giving|annual giving|giving|donor|grants?|advancement|caregiver|caregivers|cna|nurse|"
    r"nursing|memory care|medical|clinical|physician|health services|counselor|counseling|therapist|"
    r"dietary|dietitian|pharmacist|graphic designer|graphic design|library|librarian|archivist)\b")
_TITLE_NON_BOOKING = re.compile(
    r"\b(teacher|coach|athletics?|superintendent|groundskeeper|grounds|landscape|golf professional|"
    r"golf pro|assistant golf|tennis|racquets?|pickleball|squash|fitness|personal trainer|lifeguard|"
    r"aquatics|salon|bartender|cook|bellman|bell attendant|doorman|driver|retired|former|"
    r"guest service agent|front desk agent|night auditor|reservations agent|architect|architecture|"
    r"construction|education|educator|educational|learning|camps?|field trips?|curriculum|"
    r"communications|media relations|public relations|social media|digital|content|writer|"
    r"editor|designer|creative director|photographer|videographer|curator|exhibitions?|collections|"
    r"studio|glass|ceramics|pottery|facility manager|facilities|office manager|receptionist|"
    r"administrative|admin|clerk|analyst|wellness|chaplain|outreach|engagement|membership|"
    r"community relations|board member|trustee|docent)\b")
# Booking words strong enough to keep a title that also names a back-office word
# ("Events Manager, Business Office Associate", "Director of Stewardship & Events").
_TITLE_BOOKING_STRONG = re.compile(
    r"\b(events?|special events|private events|private dining|banquets?|catering|weddings?|"
    r"music|musical|entertainment|booking|bookings|talent buyer|programming|public programs|performing arts|"
    r"concerts?|lifestyle|life enrichment|resident engagement|resident life|activities director|activity director|"
    r"food (and|&) beverage|f ?& ?b|general manager|owner|co owner|coowner|proprietor|innkeeper)\b")
_TITLE_SENIOR = (r"(manager|director|coordinator|head|lead|chief|vp|vice president|executive|specialist|"
                 r"planner|supervisor|producer|administrator|officer|consultant)")
_TITLE_RULES = [
    (5, r"\b(events?|special events|private events|private dining|banquets?|catering|weddings?|meetings)\b", True),
    (5, r"\b(entertainment|music|musical|booking|bookings|talent buyer|programming|performing arts|concerts?)\b", False),
    (4, r"\b(owner|co owner|coowner|founder|co founder|cofounder|proprietor|general manager|gm|"
        r"managing director|managing partner|innkeeper)\b", False),
    (4, r"\b(food (and|&) beverage|f ?& ?b|fnb|beverage director|director of beverage|restaurant manager|"
        r"dining room manager|outlet manager|maitre d)\b", False),
    (4, r"\b(lifestyle|life enrichment|resident engagement|resident life|activities|activity|recreation)\b", True),
    (3, r"\b(sales|business development)\b", True),
    (3, r"\b(club manager|clubhouse manager|venue manager|house manager|tasting room|winery manager|"
        r"estate manager|artistic director|music director|public programs|association manager|"
        r"executive director)\b", False),
    (3, r"\b(rentals?|hospitality|guest experience)\b", True),
    (2, r"\bprograms?\b", True),
    (2, r"\b(president|ceo|chief executive|coo|chief operating|partner)\b", False),
    (2, r"\boperations\b", True),
]
BOOKING_SCORE = 3   # a title scoring at least this is "booking-relevant"


def _norm_title(title):
    return " " + re.sub(r"\s+", " ", re.sub(r"[^a-z0-9& ]+", " ", str(title or "").lower())) + " "


def title_relevance(title, skip_words=()):
    """(score, why) for a job title. why: 'veto:<word>' (back office or floor staff: never
    saved), 'non_booking:<word>' (score 0), 'rule' (booking-relevant), 'not_relevant',
    'no_title'. skip_words = the app's own title skip words (whole words)."""
    t = _norm_title(title)
    if not t.strip():
        return 0, "no_title"
    for w in skip_words or ():
        w = str(w or "").strip().lower()
        if w and re.search(r"(^|[^a-z0-9])" + re.escape(w) + r"($|[^a-z0-9])", t):
            return 0, "veto:skip_word:" + w
    strong = _TITLE_BOOKING_STRONG.search(t)
    m = _TITLE_VETO.search(t)
    if m and not (strong and m.group(1) not in ("intern", "interns", "internship", "student", "students",
                                                "volunteer", "server", "servers", "library", "librarian")):
        return 0, "veto:" + m.group(1)
    m = _TITLE_NON_BOOKING.search(t)
    if m and not strong:
        return 0, "non_booking:" + m.group(1)
    senior = re.search(r"\b" + _TITLE_SENIOR + r"\b", t) is not None
    best = 0
    for pts, pat, need_senior in _TITLE_RULES:
        if re.search(pat, t) and (senior or not need_senior):
            best = max(best, pts)
    if not best:
        return 0, "not_relevant"
    if re.search(r"\bassistant\b", t):
        best -= 1
    elif re.search(r"\b(director|head|vp|vice president|chief)\b", t):
        best += 1
    return max(best, 1), "rule"


# At a multi-site operator or a host organisation (a chain's head office, a foundation with
# offices in three states, a college), these titles belong to the organisation, not the venue.
_ORG_LEVEL_TITLE = re.compile(r"\b(regional|region|area|district|divisional|division|corporate|national|"
                              r"vice president|vp|svp|evp|chief|president|ceo|cfo|coo|founder|board|trustee|"
                              r"federal|statewide)\b")
_US_STATE_WORDS = re.compile(r"\b(alabama|alaska|arizona|arkansas|california|colorado|connecticut|delaware|"
                             r"florida|georgia|hawaii|idaho|illinois|indiana|iowa|kansas|kentucky|louisiana|"
                             r"maine|maryland|massachusetts|michigan|minnesota|mississippi|missouri|montana|"
                             r"nebraska|nevada|new hampshire|new jersey|new mexico|new york|north carolina|"
                             r"north dakota|ohio|oklahoma|oregon|pennsylvania|rhode island|south carolina|"
                             r"south dakota|tennessee|texas|utah|vermont|virginia|washington|west virginia|"
                             r"wisconsin|wyoming|hampton roads|central virginia|pa|va|md)\b")


_JOB_VOCAB = re.compile(
    r"^(manager|director|coordinator|head|lead|chief|vp|vice|president|executive|specialist|planner|"
    r"supervisor|producer|administrator|officer|consultant|assistant|associate|senior|junior|sr|jr|"
    r"sales|marketing|operations|relations|community|services|service|guest|guests|culinary|beverage|"
    r"food|dining|room|business|buisness|office|resident|residents|programs?|special|private|groups?|"
    r"conference|meetings?|partnerships?|events?|catering|banquets?|weddings?|music|entertainment|"
    r"hospitality|engagement|lifestyle|activities|membership|development|finance|accounting|human|"
    r"resources|education|learning|communications|media|digital|social|interim|acting|deputy|general|"
    r"staff|team|department|campus|national|regional|area|district|corporate|global|international)$")


def _other_place_in_title(title, venue_name, venue_city):
    """The place a title names that is not this venue ('Senior Sales Director - The Virginian',
    'Community Relations Director (Atrium Village)', 'Virginia Executive Director'), else ''."""
    raw = str(title or "")
    own = set(_words(venue_name)) | set(_words(venue_city))
    parts = re.findall(r"\(([^)]{3,60})\)", raw) + re.split(r"\s[-\u2013\u2014|]\s|,\s*|\s(?:at|@)\s", re.sub(r"\([^)]*\)", " ", raw))[1:]
    for seg in parts:
        words = [w for w in _words(seg) if len(w) >= 3]
        if not words or not re.search(r"\b[A-Z][a-z]{3,}", seg):
            continue
        if any(_JOB_VOCAB.match(w) for w in words):
            continue   # "Director, Events", "Sales Marketing": a job, not a place
        if not (set(words) & own):
            return seg.strip()
    m = _US_STATE_WORDS.search(_norm_title(raw))
    if m and not (set(_words(m.group(1))) & own):
        return m.group(1)
    return ""


def _function_inbox_word(email):
    e = normalize_email(email)
    if not e:
        return ""
    local = e.split("@", 1)[0]
    stripped = re.sub(r"[\d._\-+]", "", local)
    if stripped in FUNCTION_TOKENS or stripped in FUNCTION_FIRST_TOKENS:
        return stripped
    return next((t for t in _local_tokens(local) if t in FUNCTION_TOKENS), "")


def contact_gate(email, name="", title="", action="verify", person_role="", strict=False,
                 multi_site=False, venue_name="", venue_city="", skip_words=()):
    """Second gate after check_email: is this a person who could book Alex?

    Returns {"ok", "reason", "score", "tier"}; tier = 'booking' | 'neutral'.
      - back-office mailbox or title (accounting, legal, HR, IT, admissions, science,
        fundraising, caregivers ...) -> never saved, whatever else is true
      - no real person name -> not saved (function inboxes AND personal-looking mailboxes:
        calendar@, gala@, james@ with nothing printed beside it); the one exception is a
        one-person mailbox on the venue's own site (chef@, owner@, gm@: person_role)
      - strict (a big staff directory, a host organisation, an Apollo org-wide list) ->
        only booking-relevant titles (score >= BOOKING_SCORE)
      - multi_site (a chain / host organisation) -> org-level titles (regional VP, CEO,
        "Virginia Executive Director") and titles naming another property are rejected
    SAVE_NAMELESS=1 in the environment restores saving nameless personal mailboxes.
    CONTACT_SAVE_ALL=1 (.env, Alex Nov 11 2026: "just add everyone and ill parse it"; the junk came from
    running colleges, not from saving too many people): everyone at the venue is saved, whatever the
    title; only the guards against other organisations / other properties stay."""
    import os as _os
    out = {"ok": False, "reason": "", "score": 0, "tier": "neutral"}
    save_all = _os.environ.get("CONTACT_SAVE_ALL") == "1"
    bo = back_office_mailbox(email)
    if bo and not save_all:
        out["reason"] = "back_office_mailbox:" + bo
        return out
    score, why = title_relevance(title, skip_words)
    if why.startswith("veto") and not save_all:
        out["reason"] = "back_office_title:" + why.split(":", 1)[1]
        return out
    if not str(name or "").strip() and not person_role:
        if action == "role" or (_os.environ.get("SAVE_NAMELESS") != "1" and not save_all):
            out["reason"] = "no_person_name"
            return out
    if multi_site:
        t = _norm_title(title)
        if _ORG_LEVEL_TITLE.search(t) and not re.search(r"\b(general manager|owner)\b", t):
            out["reason"] = "org_level_title:" + _ORG_LEVEL_TITLE.search(t).group(1)
            return out
        place = _other_place_in_title(title, venue_name, venue_city)
        if place:
            out["reason"] = "other_property_title:" + place[:40]
            return out
    if person_role and not str(title or "").strip():
        score, why = title_relevance(person_role)
    out["score"] = score
    out["tier"] = "booking" if score >= BOOKING_SCORE else "neutral"
    if action == "role" and out["tier"] != "booking" and _function_inbox_word(email) and not save_all:
        # creche@ with the preschool director's name, glass@ with the studio manager's: a
        # program's inbox, not a booking channel, unless the person attached books events.
        out["reason"] = "program_inbox:" + _function_inbox_word(email)
        return out
    if strict and out["tier"] != "booking" and not save_all:
        out["reason"] = "not_a_booking_title:" + (why if why != "rule" else "low_score")
        return out
    out["ok"] = True
    out["reason"] = "ok"
    return out


# Collection segments a multi-property operator puts its properties under
# (cogirusa.com/communities/cogir-of-potomac/).
_COLLECTION_SEGS = {
    "communities", "community", "locations", "location", "properties", "property", "venues",
    "hotels", "resorts", "clubs", "residences", "campus", "campuses", "centers", "centres",
    "galleries", "museums", "sites", "parks", "our-communities", "senior-living",
    "find-a-community", "destinations", "restaurants", "estates", "branches", "facilities",
}
_LOCATION_SEGS = {"dc", "nyc", "ny", "la", "sf", "ldn", "phl", "phila", "bmore", "nova", "dmv", "va", "md", "atl", "chi",
                  "bos", "mia", "washington", "washington-dc", "washingtondc", "dc-area", "baltimore", "bethesda", "arlington",
                  "alexandria", "annapolis", "georgetown", "reston", "tysons", "mclean", "chevy-chase", "silver-spring",
                  "rockville", "frederick", "columbia", "towson", "fairfax", "leesburg", "middleburg", "richmond",
                  "philadelphia", "new-york", "newyork", "nomad", "london", "doha", "miami", "chicago", "boston"}
_GENERIC_PAGE_SEGS = {"overview", "home", "index", "default", "main", "about", "about-us", "contact",
                      "contact-us", "en", "en-us", "us", "welcome"}


def host_org_kind(url, venue_name=""):
    """How the venue's website sits inside a larger organisation's domain (Nov 11 2026):
      'institution' - a .edu/.gov/.mil (or *.xx.us) domain that is not the venue's own name
                      (Mitchell Gallery at sjc.edu/mitchell: the run saved 92 St. John's
                      College addresses: admissions, bookstore, helpdesk, every dean)
      'property'    - one property's section of an operator's site
                      (cogirusa.com/communities/cogir-of-potomac: 18 head-office and other-
                      community staff came in through Apollo's domain search)
      'subsite'     - a subdomain of an organisation whose domain is not the venue's name
                      (venue.cbf.org for the Philip Merrill Center: 47 Chesapeake Bay
                      Foundation attorneys, scientists and fundraisers)
      ''            - the venue's own site (or a shared brand domain / listing, handled elsewhere).
    For all three the pipeline reads only the venue's own section (host / path prefix) and
    saves only booking-relevant people from the organisation's lists."""
    host, reg = host_of(url), registrable_domain(url)
    if not host or not reg or reg in SHARED_BRAND_DOMAINS or is_non_venue_host(url) or is_site_builder_host(url):
        return ""
    label = re.sub(r"[^a-z0-9]", "", reg.split(".")[0])
    vw = [w for w in _words(venue_name) if len(w) >= 4 and w not in _GENERIC_VENUE_WORDS]
    owns = bool(vw) and any(w in label for w in vw)
    try:
        path = urllib.parse.unquote(urllib.parse.urlparse(url if "://" in url else "http://" + url).path or "")
    except ValueError:
        path = ""
    segs = [s for s in path.lower().split("/") if s and s not in _GENERIC_PAGE_SEGS]
    if len(segs) >= 2 and segs[0] in _COLLECTION_SEGS:
        return "property"
    if owns:
        return ""
    # A location section of a multi-city brand not named for the venue (thened.com/dc, brand.com/washington-dc): only that
    # section is the venue (Nov 11 2026: Ned's Club DC was crawled through its NoMad NYC pages).
    if segs and segs[0] in _LOCATION_SEGS:
        return "property"
    if is_institution_domain(reg):
        return "institution"
    sub = host[:-len(reg)].rstrip(".") if host != reg else ""
    if re.fullmatch(r"(www\d*|m)", sub or ""):
        sub = ""
    if sub and vw:
        return "subsite"
    return ""


def in_target_area(state):
    return (state or "").strip().upper() in TARGET_STATES


# ---------------------------------------------------------------------------
# Search text for the Google and LinkedIn steps, and "is this result in DC/MD/VA".
# Alex, Nov 8 2026: the wine bar "Altitude" (Arlington VA) was searched as
# "Altitude" Arlington and the run opened Altitude Trampoline Park, Arlington, Texas.
# The state and the venue type always go in a Google query; a LinkedIn person or a
# search result that names a place outside DC/MD/VA is not this venue's.
# ---------------------------------------------------------------------------
_STATE_NAMES = {"DC": "DC", "MD": "Maryland", "VA": "Virginia", "PA": "Pennsylvania", "DE": "Delaware"}
_OTHER_STATES = (
    "Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|Florida|Georgia|"
    "Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Massachusetts|Michigan|"
    "Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|New Hampshire|New Jersey|New Mexico|"
    "New York|North Carolina|North Dakota|Ohio|Oklahoma|Oregon|Pennsylvania|Rhode Island|"
    "South Carolina|South Dakota|Tennessee|Texas|Utah|Vermont|West Virginia|Wisconsin|Wyoming")
_OTHER_STATE_RX = re.compile(r"\b(%s)\b" % _OTHER_STATES, re.I)
_OTHER_CODE_RX = re.compile(r",\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MA|MI|MN|MS|MO|MT|NE|NV|"
                            r"NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|WA|WV|WI|WY)\b(?!\.\w)")
_AREA_RX = re.compile(r"District of Columbia|Washington,? D\.?C\b|\bD\.C\.|(?<!West )\bVirginia\b|\bMaryland\b|"
                      r"\b(?-i:MD|VA|DC|DMV)\b|\bBaltimore\b|Greater Richmond|Hampton Roads", re.I)
_NOT_A_PLACE_RX = re.compile(r"^(current|past|connect|message|follow|pending|view|\d+)\b|mutual connection|followers?$", re.I)


def venue_type_words(category, name=""):
    """'wine_bar' -> 'wine bar'; '' for no/unknown category or when the name already says it."""
    cat = re.sub(r"[_\-]+", " ", str(category or "")).strip().lower()
    if not cat or cat in ("other", "unknown", "none", "venue"):
        return ""
    have = set(_words(name))
    return "" if all(w in have for w in cat.split()) else cat


def search_place(city="", state=""):
    """'Arlington', 'VA' -> 'Arlington VA'. The state is never left out when known."""
    return " ".join(x for x in ((city or "").strip(), (state or "").strip().upper()) if x and x != "NONE")


def google_query(name, tail="", city="", state="", category=""):
    """"Altitude" wine bar Arlington VA contact"""
    parts = ['"%s"' % (name or "").strip().replace('"', ""), venue_type_words(category, name),
             search_place(city, state), (tail or "").strip()]
    return " ".join(p for p in parts if p)


def one_word_name(name):
    """True when the venue's name is a single word ("Altitude", "The Ivy"): on its own it
    matches many other businesses."""
    core = re.sub(r"^the\s+", "", (name or "").strip(), flags=re.I)
    return len(re.findall(r"[A-Za-z0-9&]+", core)) <= 1


def linkedin_query(name, city="", state=""):
    """The LinkedIn people-search keywords: the exact venue name in quotes (the method
    that worked on Apr 2 2026), plus the town for a one-word name."""
    q = '"%s"' % (name or "").strip().replace('"', "")
    if one_word_name(name) and (city or "").strip():
        q += " " + city.strip()
    return q


def _own_state_named(s, venue_state):
    """A Pennsylvania/Delaware sweep find's own state counts as its area."""
    st = (venue_state or "").strip().upper()
    if not st or st in TARGET_STATES:
        return False
    full = _STATE_NAMES.get(st, "")
    return bool(re.search(r"\b%s\b" % re.escape(st), s) or (full and re.search(r"\b%s\b" % re.escape(full), s, re.I)))


def linkedin_location_in_area(loc, venue_state=""):
    """True = the LinkedIn location is in DC/MD/VA (or the venue's own state); False =
    somewhere else ("Arlington, Texas, United States", "Serbia"); None = no location."""
    s = re.sub(r"\s+", " ", str(loc or "")).strip()
    if not s or _NOT_A_PLACE_RX.search(s) or re.fullmatch(r"(the )?(united states|usa|u\.s\.a?\.?)", s, re.I):
        return None
    if _own_state_named(s, venue_state):
        return True
    if _OTHER_STATE_RX.search(s) or _OTHER_CODE_RX.search(s):
        return False
    return bool(_AREA_RX.search(s))


def place_outside_area(text, venue_state=""):
    """The other state a search result names ("Arlington, TX", "Texas") when it names no
    DC/MD/VA place; '' otherwise. Used to drop results about a same-name business elsewhere."""
    s = re.sub(r"\s+", " ", str(text or ""))
    if not s or _AREA_RX.search(s) or _own_state_named(s, venue_state):
        return ""
    m = _OTHER_CODE_RX.search(s) or _OTHER_STATE_RX.search(s)
    return m.group(1) if m else ""


# Alex, Sep 29 2026: "everything on the sweep should be able to be used for you on the
# pipeline". A sweep find was already hand-picked for fit, so planning skips the taste
# gates for it (it is still ranked, prime venues first) and verify_pool trusts its city.
# Hard rules (PA, closed, motels, thumbs-down, past gigs, worked venues) still apply.
HARD_JUNK_RX = re.compile(r"closed|motel|budget|extended.?stay|adult|nightlife|fast food|"
                          r"vacation|rental|airbnb|vrbo", re.I)


# Alex, Sep 29 2026, on the Pennsylvania/Delaware sweep finds: "fix these last". They run,
# but only after every DC/MD/VA venue: planning fills a run with them only when the
# DC/MD/VA queue can't. Other discovery outside DC/MD/VA stays out.
LAST_STATES = ("PA", "DE")


def sweep_state_ok(state, sweep):
    st = (state or "").strip().upper()
    return st in TARGET_STATES or (sweep and st in LAST_STATES)


SWEEP_NOTE_RX = re.compile(r"\bsweep find\b", re.I)


def is_sweep_find(venue_or_source):
    """A venue a sweep found: `source` says sweep, or import_sweep_files.py tagged an older
    row (found earlier by other discovery) with the note "Sweep find (<sweep>)"."""
    if isinstance(venue_or_source, dict):
        return ("sweep" in str(venue_or_source.get("source") or "").lower()
                or bool(SWEEP_NOTE_RX.search(str(venue_or_source.get("notes") or ""))))
    return "sweep" in str(venue_or_source or "").lower()


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
    sq = sub.add_parser("search-query")
    sq.add_argument("kind", choices=("google", "linkedin"))
    sq.add_argument("--name", required=True)
    sq.add_argument("--tail", default="")
    sq.add_argument("--city", default="")
    sq.add_argument("--state", default="")
    sq.add_argument("--category", default="")
    sq.add_argument("--detail", default="", help="venue_detail JSON file: city/state/category come from it")
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
    elif a.cmd == "search-query":
        city, state, cat = a.city, a.state, a.category
        if a.detail:
            try:
                v = json.load(open(a.detail)).get("venue") or {}
            except (OSError, ValueError, AttributeError):
                v = {}
            city, state, cat = city or str(v.get("city") or ""), state or str(v.get("state") or ""), cat or str(v.get("category") or "")
        if a.kind == "linkedin":
            print(linkedin_query(a.name, city, state))
        else:
            print(google_query(a.name, a.tail, city, state, cat))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
