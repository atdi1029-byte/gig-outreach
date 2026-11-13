#!/usr/bin/env python3
"""Offline tests for the contact rules added on Nov 11 2026.

That day's two burn runs saved ~300 contacts, ~80% junk: a college's whole directory for the
gallery inside it (Mitchell Gallery, sjc.edu), a foundation's attorneys and scientists
(venue.cbf.org), a chain's head office (cogirusa.com), a wedding-listing company's staff
(herecomestheguide.com), Maryland legislators from a neighbourhood association's links page,
and nameless program inboxes (calendar@, gala@, glass@, minigolf@ ...).

Covers outreach_rules (host organisations, listing hosts, back office, the booking-title
scorer, the contact gate), the REAL pipeline.sh heredocs (site classification, the website
decide step, the email check + gate) and night_save.py's flagged-contact deletion with a fake
backend. Nothing touches Chrome, the sheet, ZeroBounce, Apollo or the network.

    /usr/bin/python3 tests/contact_rules_tests.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import outreach_rules as R  # noqa: E402

PIPELINE = open(os.path.join(ROOT, "pipeline.sh"), encoding="utf-8").read()
US = "\x1f"


def heredoc(src, marker):
    i = src.index(marker)
    start = src.index("<<'PYEOF'\n", i) + len("<<'PYEOF'\n")
    return src[start:src.index("\nPYEOF\n", start)]


def run_py(code, argv=(), env=None):
    e = dict(os.environ, SCRIPT_DIR=ROOT)
    for k in ("VENUE_HOST_ORG", "CONTACT_STRICT", "VENUE_SITE_PREFIX", "VENUE_CITY_GATE", "SAVE_NAMELESS"):
        e.pop(k, None)
    e.update(env or {})
    p = subprocess.run([sys.executable, "-", *argv], input=code, capture_output=True, text=True, env=e, cwd=ROOT)
    if p.returncode != 0:
        raise AssertionError(p.stderr)
    return p.stdout


class Domains(unittest.TestCase):
    def test_us_locality_domains_are_not_md_us(self):
        self.assertEqual(R.registrable_domain("house.state.md.us"), "state.md.us")
        self.assertEqual(R.registrable_domain("senate.state.md.us"), "state.md.us")
        self.assertTrue(R.is_institution_domain("house.state.md.us"))
        self.assertTrue(R.is_institution_domain("baltimorecity.gov"))
        self.assertTrue(R.is_institution_domain("www.sjc.edu"))
        self.assertFalse(R.is_institution_domain("guilfordassociation.org"))

    def test_host_org_kind(self):
        cases = [
            ("https://www.sjc.edu/mitchell", "Mitchell Gallery", "institution"),
            ("https://www.sjc.edu", "Mitchell Gallery", "institution"),
            ("https://cogirusa.com/communities/cogir-of-potomac/", "Cogir of Potomac", "property"),
            ("https://venue.cbf.org/", "Chesapeake Bay Foundation Philip Merrill Center", "subsite"),
            ("https://www.workhousearts.org/", "Workhouse Arts Center", ""),
            ("https://www.folger.edu", "Folger Shakespeare Library", ""),        # the venue's own .edu
            ("https://events.greatoakmanor.com", "Great Oak Manor", ""),
            ("https://www.theprimeribs.com/baltimore", "The Prime Rib", ""),
            ("https://www.marriott.com/hotels/x", "Some Marriott", ""),          # brand: handled as shared
            ("https://www.spcc1925.com", "Sparrows Point Country Club", ""),
        ]
        for url, name, want in cases:
            self.assertEqual(R.host_org_kind(url, name), want, url)

    def test_listing_sites_are_never_the_venue(self):
        self.assertTrue(R.is_non_venue_host("https://www.herecomestheguide.com/wedding-venues/virginia/the-lake-house"))
        r = R.check_email("abaker@herecomestheguide.com", "herecomestheguide.com", "The Lake House",
                          found_on_venue_site=True)
        self.assertEqual(r["action"], "reject")
        self.assertTrue(r["reason"].startswith("listing_domain"))


class Mailboxes(unittest.TestCase):
    def test_program_inboxes_are_role_mailboxes(self):
        for e in ("calendar@stfrancisgreatfalls.org", "creche@x.org", "gala@x.org", "rector@x.org",
                  "fieldtrips@cbf.org", "chesapeakeclassrooms@cbf.org", "clagettfarm@cbf.org",
                  "glass@workhousearts.org", "ceramics@workhousearts.org", "minigolf@workhousearts.org",
                  "summer.academy@sjc.edu", "party@muisupperclub.com", "pdr.washingtondc@fourseasons.com"):
            self.assertTrue(R.is_role_email(e), e)
            self.assertEqual(R.name_from_email(e), "", e)

    def test_business_in_a_dotted_mailbox_is_not_a_surname(self):
        for e in ("mark.forgerestaurantgroup@gmail.com", "cheftom.forgerestaurantgroup@gmail.com"):
            self.assertEqual(R.name_from_email(e, "Forge Southern Comfort"), "", e)
        self.assertEqual(R.name_from_email("tom.barringtonpub@gmail.com", "Barrington Tap & Table"), "")
        for e, n in (("jane.doe@x.com", "Jane Doe"), ("kate.mcginn@x.com", "Kate Mcginn"),
                     ("luis.escobar@x.com", "Luis Escobar"), ("amy.farmer@x.com", "Amy Farmer")):
            self.assertEqual(R.name_from_email(e, "Forge Southern Comfort"), n, e)

    def test_people_named_like_words_stay_people(self):
        for e in ("dean.smith@v.com", "summer.lee@v.com", "john.rector@v.com", "glassman@v.com"):
            self.assertFalse(R.is_role_email(e), e)

    def test_back_office_mailboxes_rejected_with_a_name(self):
        for e in ("treasurer@stfrancisgreatfalls.org", "annapolis.admissions@sjc.edu", "helpdesk@sjc.edu",
                  "studentaccounts@sjc.edu", "user.support@sjc.edu"):
            r = R.check_email(e, e.split("@")[1], "Venue")
            self.assertTrue(r["reason"].startswith("back_office_mailbox"), (e, r))

    def test_office_names_are_not_people(self):
        for n in ("Annapolis Bookstore", "Financial Aid", "Human Resources", "Summer Academy", "Public Safety",
                  "Academic Leadership", "Faculty Committee", "Deacon Nancy", "Graduate Admissions"):
            self.assertEqual(R.clean_person_name(n), "", n)
        self.assertEqual(R.clean_person_name("Summer Lee"), "Summer Lee")
        self.assertEqual(R.clean_person_name("Delegate Elizabeth M. Embry"), "Elizabeth M. Embry")


class Titles(unittest.TestCase):
    BOOKING = ["WEDDING & EVENTS MANAGER", "Director of Stewardship & Events", "Events & Promotions Manager",
               "Senior Manager of Campus Events", "Events Manager, Buisness Office Associate",
               "Manager, Performing Arts", "Marketing and Events Coordinator", "Resident Lifestyle Director",
               "Association Manager", "General Manager", "Owner", "Hospitality Manager", "Restaurant Manager",
               "Director of Events", "Director of Banquets", "Director of Sales & Marketing",
               "Director of Food & Beverage", "Private Dining Manager", "Catering Sales Manager",
               "Music Director", "Activities Director", "Life Enrichment Coordinator"]
    BACK_OFFICE = ["Senior Paralegal", "Chief Financial Officer", "Senior Accountant", "Development Associate",
                   "Vice President for People", "Pennsylvania Science Policy and Advocacy Director",
                   "Chief Philanthropy Officer (CDO)", "Director of Regional Major Giving", "Maryland Staff Attorney",
                   "Web Manager", "Front-End Web Developer", "Director of Planned Giving", "Caregiver",
                   "Memory Care Director", "President of Finance", "Associate Dean for Graduate Programs",
                   "Assistant Director of Admissions", "Maryland Coastal Resource Scientist", "Head of Finance",
                   "Director of Human Resources", "Director of Information Technology", "Music Library"]

    def test_booking_titles_score_high(self):
        for t in self.BOOKING:
            self.assertGreaterEqual(R.title_relevance(t)[0], R.BOOKING_SCORE, t)

    def test_back_office_titles_are_vetoed(self):
        for t in self.BACK_OFFICE:
            self.assertTrue(R.title_relevance(t)[1].startswith("veto"), (t, R.title_relevance(t)))

    def test_neutral_titles_are_not_booking(self):
        for t in ("Director", "Curator", "Glass Studio Manager", "Director of Marketing", "Operations Manager",
                  "Visitor Associate", "Environmental Educator", "Graphic Designer x", "Program Coordinator"):
            self.assertLess(R.title_relevance(t)[0], R.BOOKING_SCORE, t)


class Gate(unittest.TestCase):
    def test_nameless_is_never_saved_except_one_person_mailboxes(self):
        self.assertEqual(R.contact_gate("calendar@x.org", "", "", "role")["reason"], "no_person_name")
        self.assertEqual(R.contact_gate("james@theprimeribs.com", "", "", "verify")["reason"], "no_person_name")
        self.assertTrue(R.contact_gate("owner@x.com", "", "", "role", person_role="Owner")["ok"])
        with mock.patch.dict(os.environ, {"SAVE_NAMELESS": "1"}):
            self.assertTrue(R.contact_gate("james@theprimeribs.com", "", "", "verify")["ok"])

    def test_back_office_never(self):
        g = R.contact_gate("liz@theprimeribs.com", "Elizabeth Pretzinger", "Senior Paralegal")
        self.assertFalse(g["ok"])
        self.assertTrue(g["reason"].startswith("back_office_title"))

    def test_strict_needs_a_booking_title(self):
        self.assertFalse(R.contact_gate("a@w.org", "Sarah Berry", "Curator", strict=True)["ok"])
        self.assertTrue(R.contact_gate("a@w.org", "Sarah Berry", "Curator", strict=False)["ok"])
        self.assertTrue(R.contact_gate("a@w.org", "Liz Colandene", "Manager, Performing Arts", strict=True)["ok"])

    def test_multi_site_rejects_org_level_and_other_properties(self):
        kw = dict(strict=True, multi_site=True, venue_name="Cogir of Potomac", venue_city="Potomac")
        self.assertTrue(R.contact_gate("e@c.com", "Emily Hoovler", "Resident Lifestyle Director", **kw)["ok"])
        for t in ("Senior Sales Director - The Virginian", "Community Relations Director (Atrium Village)",
                  "Regional VP, Operations", "Area Business Development Director"):
            self.assertFalse(R.contact_gate("e@c.com", "Ann Lee", t, **kw)["ok"], t)
        kw = dict(strict=True, multi_site=True, venue_name="Chesapeake Bay Foundation Philip Merrill Center",
                  venue_city="Annapolis")
        self.assertFalse(R.contact_gate("c@cbf.org", "Chris Moore", "Virginia Executive Director", **kw)["ok"])
        self.assertTrue(R.contact_gate("t@cbf.org", "Taryn Dwan", "Director of Stewardship & Events", **kw)["ok"])

    def test_program_inbox_needs_a_booking_person(self):
        self.assertFalse(R.contact_gate("creche@x.org", "Cristi Leslie", "Creche PreSchool Director", "role")["ok"])
        self.assertTrue(R.contact_gate("events@cbf.org", "Shannon Wright", "Wedding & Events Manager", "role")["ok"])


class PipelineHeredocs(unittest.TestCase):
    SITE = heredoc(PIPELINE, "runner_site_info() {")
    CHECK = heredoc(PIPELINE, "_py_check_email() {")
    DECIDE = heredoc(PIPELINE, "_web_py_web_decide() {")

    def site(self, url, name):
        return run_py(self.SITE, [ROOT, url, name]).strip().split(US)

    def test_site_info_scopes_host_organisations(self):
        v = self.site("https://www.sjc.edu/mitchell", "Mitchell Gallery")
        self.assertEqual((v[0], v[3], v[4]), ("ok", "true", "sjc.edu/mitchell"))
        v = self.site("https://venue.cbf.org/", "Chesapeake Bay Foundation Philip Merrill Center")
        self.assertEqual((v[0], v[3], v[4]), ("ok", "true", "venue.cbf.org"))
        v = self.site("https://cogirusa.com/communities/cogir-of-potomac/", "Cogir of Potomac")
        self.assertEqual((v[0], v[3], v[4]), ("ok", "true", "cogirusa.com/communities/cogir-of-potomac"))
        self.assertEqual(self.site("https://www.herecomestheguide.com/wedding-venues/virginia/the-lake-house",
                                   "The Lake House")[0], "non_venue")
        v = self.site("https://www.workhousearts.org/", "Workhouse Arts Center")
        self.assertEqual((v[0], v[3]), ("ok", "false"))

    def check(self, email, name="", title="", evidence="venue_site", vdom="workhousearts.org",
              venue="Workhouse Arts Center", shared="false", env=None):
        out = run_py(self.CHECK, [ROOT, email, name, title, evidence, vdom, venue, shared, "a@b.c", "chicago"], env)
        f = (out.rstrip("\n").split(US) + [""] * 10)[:10]
        return {"action": f[1], "reason": f[2], "name": f[4], "tier": f[9]}

    def test_check_email_gate(self):
        self.assertEqual(self.check("amehaworkineh@workhousearts.org", "Ameha Workineh", "Accountant")["action"], "reject")
        self.assertEqual(self.check("minigolf@workhousearts.org")["action"], "role")   # role, no name: candidate
        self.assertEqual(self.check("faithriegal@workhousearts.org")["reason"], "no_person_name")
        ok = self.check("lizcolandene@workhousearts.org", "Liz Colandene", "Manager, Performing Arts", "external",
                        env={"CONTACT_STRICT": "1"})
        self.assertEqual((ok["action"], ok["tier"]), ("verify", "booking"))
        self.assertEqual(self.check("sarahberry@workhousearts.org", "Sarah Berry", "Curator",
                                    env={"CONTACT_STRICT": "1"})["action"], "reject")

    def test_short_first_name_mailbox_keeps_its_person(self):
        kw = dict(evidence="venue_mailto", vdom="guilfordassociation.org", venue="Guilford Association")
        self.assertEqual(self.check("beth@guilfordassociation.org", "Elizabeth Nguyen",
                                    "Financial Lead / Assistant Manager", **kw)["name"], "Elizabeth Nguyen")
        self.assertEqual(self.check("alex@guilfordassociation.org", "Alexander Smith", "Manager", **kw)["name"],
                         "Alexander Smith")
        # another person's card is still not this mailbox's
        self.assertEqual(self.check("bert@guilfordassociation.org", "Lynne Basignani", "Owner", **kw)["name"], "")
        self.assertEqual(self.check("ann@guilfordassociation.org", "Hannah Smith", "Manager", **kw)["name"], "")

    def test_venue_freemail_box_keeps_the_owner_at_the_save_step(self):
        kw = dict(evidence="venue_mailto", vdom="3creekswinery.com", venue="Three Creeks Winery")
        got = self.check("3creekswinery@gmail.com", "P-J Lawrence", "Owner", **kw)
        self.assertEqual((got["action"], got["name"]), ("verify", "P-J Lawrence"))
        # a neighbour's name with another job, or a private free-mail address, still has to fit
        self.assertEqual(self.check("3creekswinery@gmail.com", "Gordon Carlson", "Executive Chef", **kw)["name"], "")
        self.assertEqual(self.check("sunnydays77@gmail.com", "P-J Lawrence", "Owner", **kw)["name"], "")

    def test_apollo_local_on_a_host_organisation(self):
        env = {"VENUE_HOST_ORG": "property", "VENUE_SITE_PREFIX": "cogirusa.com/communities/cogir-of-potomac",
               "VENUE_CITY_GATE": "Potomac"}
        kw = dict(vdom="cogirusa.com", venue="Cogir of Potomac", shared="true", env=env)
        self.assertEqual(self.check("ehoovler@cogirusa.com", "Emily Hoovler", "Resident Lifestyle Director",
                                    "apollo_local", **kw)["action"], "verify")
        self.assertEqual(self.check("donte.lloyd@cogirusa.com", "Donte Lloyd", "Caregiver", "apollo_local", **kw)["action"], "reject")
        # an org-wide Apollo find (not verified local) on the operator's domain stays out
        self.assertEqual(self.check("ehoovler@cogirusa.com", "Emily Hoovler", "Resident Lifestyle Director",
                                    "external", **kw)["action"], "reject")

    def decide(self, pages, reg, home, venue, prefix=None, shared="false"):
        d = tempfile.mkdtemp()
        pf, cf, df = (os.path.join(d, n) for n in ("pages.jsonl", "crawl.json", "pdfs.jsonl"))
        with open(pf, "w") as f:
            for url, contacts, people in pages:
                f.write(json.dumps({"url": url, "kind": "home" if url == home else "sub",
                                    "result": {"url": url, "contacts": contacts, "people": people}}) + "\n")
        open(df, "w").close()
        out = run_py(self.DECIDE, [ROOT, pf, cf, df, prefix or reg, shared, reg, home, "", venue])
        return [l.split(US) for l in out.splitlines()]

    def test_directory_page_never_makes_a_mail_alias(self):
        mt = lambda e: {"email": e, "mailto": True}
        legis = ["elizabeth.embry@house.state.md.us", "malcolm.ruff@house.state.md.us",
                 "regina.boyce@house.state.md.us", "samuel.rosenberg@house.state.md.us",
                 "mary.washington@senate.state.md.us", "mark.conway@baltimorecity.gov",
                 "guilfordpatrol@wolfsecurityinc.com"]
        rows = self.decide([
            ("https://guilfordassociation.org/", [mt("officemanager@guilfordassociation.org")], []),
            ("https://guilfordassociation.org/association/boardcontacts", [mt("beth@guilfordassociation.org")], []),
            ("https://guilfordassociation.org/links", [mt(e) for e in legis], []),
        ], "guilfordassociation.org", "https://guilfordassociation.org/", "Guilford Association")
        self.assertFalse([r for r in rows if r[0] == "ALIAS"], rows)

    def test_owner_domain_booking_inbox_is_paired(self):
        rows = self.decide([
            ("https://www.bourbonsteakdc.com/", [], []),
            ("https://www.bourbonsteakdc.com/contact/", [{"email": "pdr.washingtondc@fourseasons.com", "mailto": True}], []),
            ("https://www.bourbonsteakdc.com/about/", [], [{"name": "ANDRES SWEEK", "title": "General Manager"},
                                                          {"name": "QUENTIN WELCH", "title": "Executive Chef"}]),
        ], "bourbonsteakdc.com", "https://www.bourbonsteakdc.com/", "BOURBON STEAK")
        c = [r for r in rows if r[0] == "CONTACT"]
        self.assertEqual(c[0][1:3] + [c[0][4]], ["pdr.washingtondc@fourseasons.com", "ANDRES SWEEK", "owner_inbox"])
        self.assertIn(["PARENT", "fourseasons.com"], rows)

    def named(self, rows):
        return {r[1]: r[2] for r in rows if r[0] == "CONTACT"}

    def test_owning_family_gets_the_events_inbox(self):
        # "Owned and operated by Ben, Jake and Amy Lefenfeld" on an About page called /us
        fam = [{"name": n + " Lefenfeld", "title": "Owner"} for n in ("Ben", "Jake", "Amy")]
        ev = [{"email": "events@lacucharabaltimore.com", "mailto": True}]
        home = "https://www.lacucharabaltimore.com/"
        rows = self.decide([(home, ev, []), (home + "us", [], fam)],
                           "lacucharabaltimore.com", home, "La Cuchara")
        self.assertEqual(self.named(rows), {"events@lacucharabaltimore.com": "Ben Lefenfeld"})
        self.assertIn("about", [r for r in rows if r[0] == "VISITED"][0][1])
        # two unrelated owners: still no guess; the owner who is also the General Manager: theirs
        two = [{"name": "Ben Lefenfeld", "title": "Owner"}, {"name": "Maria Ortiz", "title": "Co-Owner"}]
        rows = self.decide([(home, ev, []), (home + "about", [], two)], "lacucharabaltimore.com", home, "La Cuchara")
        self.assertEqual(self.named(rows), {"events@lacucharabaltimore.com": ""})
        two[1]["title"] = "Co-Owner & General Manager"
        rows = self.decide([(home, ev, []), (home + "about", [], two)], "lacucharabaltimore.com", home, "La Cuchara")
        self.assertEqual(self.named(rows), {"events@lacucharabaltimore.com": "Maria Ortiz"})

    def test_venue_freemail_box_gets_the_owner(self):
        own = [{"name": "P-J Lawrence", "title": "Owner"}, {"name": "John Lawrence", "title": "Owner"}]
        home = "https://www.3creekswinery.com/"
        rows = self.decide([(home, [{"email": "3creekswinery@gmail.com", "mailto": True}], []),
                            (home + "about", [], own)], "3creekswinery.com", home, "3 Creeks Winery")
        self.assertEqual(self.named(rows), {"3creekswinery@gmail.com": "P-J Lawrence"})
        # a general inbox on the venue's domain never gets one this way
        rows = self.decide([(home, [{"email": "info@3creekswinery.com", "mailto": True}], []),
                            (home + "about", [], own)], "3creekswinery.com", home, "3 Creeks Winery")
        self.assertEqual(self.named(rows), {"info@3creekswinery.com": ""})

    def test_inn_owner_reads_the_reservations_inbox(self):
        home = "https://antietamoverlook.com/"
        box = [{"email": "reservations@antietamoverlook.com", "mailto": True, "name": "Horizon Ln"}]
        own = [{"name": "Lee Lee", "title": "Critter Control Officer"}, {"name": "Mark Svrcek", "title": "Owner"}]
        rows = self.decide([(home, box, own)], "antietamoverlook.com", home, "Antietam Overlook Farm")
        self.assertEqual(self.named(rows), {"reservations@antietamoverlook.com": "Mark Svrcek"})
        # a place with a staff: the reservations desk is not the owner
        own += [{"name": "Ann Lee", "title": "Events Manager"}, {"name": "Tom Roe", "title": "Front Office Manager"}]
        rows = self.decide([(home, box, own)], "antietamoverlook.com", home, "Antietam Overlook Farm")
        self.assertEqual(self.named(rows), {"reservations@antietamoverlook.com": ""})
        for junk in ("Horizon Ln", "Force Majeure", "Maple Ct"):
            self.assertEqual(R.clean_person_name(junk), "", junk)
        self.assertEqual(R.clean_person_name("Diane Lane"), "Diane Lane")

    def test_venue_initials_mailbox_is_not_glue(self):
        home = "https://www.ebbitt.com/"
        rows = self.decide([(home, [{"email": "events@ebbitt.com", "mailto": False},
                                    {"email": "oegevents@ebbitt.com", "mailto": False},
                                    {"email": "xyzevents@ebbitt.com", "mailto": False}], [])],
                           "ebbitt.com", home, "Old Ebbitt Grill")
        self.assertIn("oegevents@ebbitt.com", self.named(rows))
        self.assertIn(["DROP", "xyzevents@ebbitt.com", "page_text_glued_to_address", home], rows)

    def test_vendor_social_account_is_not_the_venues(self):
        d = tempfile.mkdtemp()
        pf, cf, df = (os.path.join(d, n) for n in ("pages.jsonl", "crawl.json", "pdfs.jsonl"))
        home = "https://www.penderbrookgolfclub.com/"
        socs = [{"platform": "instagram", "url": "https://www.instagram.com/lightspeedhq", "zone": "header"},
                {"platform": "facebook", "url": "https://www.facebook.com/PenderbrookGolfClub", "zone": "footer"}]
        with open(pf, "w") as f:
            f.write(json.dumps({"url": home, "kind": "home", "result": {"url": home, "contacts": [], "people": [],
                                                                        "socials": socs}}) + "\n")
        open(df, "w").close()
        out = run_py(self.DECIDE, [ROOT, pf, cf, df, "penderbrookgolfclub.com", "false", "penderbrookgolfclub.com",
                                   home, "", "Penderbrook Golf Club"])
        rows = [l.split(US) for l in out.splitlines()]
        self.assertIn(["SOCIAL_REJECT", "instagram", "https://www.instagram.com/lightspeedhq", "vendor_handle"], rows)
        self.assertEqual([r[1] for r in rows if r[0] == "SOCIAL"], ["facebook"])

    def test_contacts_come_out_booking_first(self):
        rows = self.decide([
            ("https://www.workhousearts.org/", [], []),
            ("https://www.workhousearts.org/staff", [
                {"email": "amehaworkineh@workhousearts.org", "mailto": True, "name": "Ameha Workineh", "title": "Accountant"},
                {"email": "sarahberry@workhousearts.org", "mailto": True, "name": "Sarah Berry", "title": "Curator"},
                {"email": "alenanorman@workhousearts.org", "mailto": True, "name": "Alena Norman",
                 "title": "Marketing and Events Coordinator"}], []),
        ], "workhousearts.org", "https://www.workhousearts.org/", "Workhouse Arts Center")
        self.assertEqual([r for r in rows if r[0] == "CONTACT"][0][1], "alenanorman@workhousearts.org")


class NightSaveDeletes(unittest.TestCase):
    def test_flagged_contacts_backed_up_then_deleted_and_read_back(self):
        import night_save as N
        rows = [{"contact_id": "C-1", "venue_id": "V-1", "email": "abaker@herecomestheguide.com", "name": "Ashley Baker"},
                {"contact_id": "C-2", "venue_id": "V-1", "email": "sent@herecomestheguide.com", "name": "Sent Person",
                 "email_sent": True},
                {"contact_id": "C-3", "venue_id": "V-1", "email": "owner@lakehouse.com", "name": "Real Owner"}]
        state = {"rows": list(rows)}
        calls = []

        def fake_api(params, timeout=60):
            calls.append(dict(params))
            if params["action"] == "delete_contact":
                backup = json.load(open(deleter.backup_path))
                assert any(c["contact_id"] == params["contact_id"] for c in backup["contacts"]), "backup first"
                state["rows"] = [r for r in state["rows"] if r["contact_id"] != params["contact_id"]]
                return {"status": "ok"}
            return {"status": "ok", "venue": {"name": "The Lake House"}, "contacts": list(state["rows"])}

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(N, "api", fake_api), \
                mock.patch.object(N, "HERE", tmp):
            deleter = N.FlagDeleter("run-test", dry=False)
            out = deleter.run("V-1", {"contacts": rows}, [
                {"email": "abaker@herecomestheguide.com", "reason": "listing site staff"},
                {"email": "sent@herecomestheguide.com", "reason": "listing site staff"},
                {"email": "nobody@x.com", "reason": "gone already"}], keep_emails=set())
            self.assertEqual([o["outcome"] for o in out], ["deleted", "skipped:already_contacted", "not_on_sheet"])
            self.assertEqual([c["contact_id"] for c in json.load(open(deleter.backup_path))["contacts"]], ["C-1"])
        self.assertEqual(sum(1 for c in calls if c["action"] == "delete_contact"), 1)

    def test_dry_run_deletes_nothing(self):
        import night_save as N
        with mock.patch.object(N, "api", side_effect=AssertionError("no writes in a dry run")):
            d = N.FlagDeleter("run-test", dry=True)
            out = d.run("V-1", {"contacts": [{"contact_id": "C-1", "email": "a@b.com"}]},
                        [{"email": "a@b.com", "reason": "x"}], set())
        self.assertEqual(out[0]["outcome"], "would_delete")


if __name__ == "__main__":
    unittest.main(verbosity=1)
