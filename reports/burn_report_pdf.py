#!/usr/bin/python3
"""The end-of-burn report (Alex, Nov 13 2026: "make me a nice PDF report"): reads reports/burn_report_data.json
(written by reports/burn_report_data.py) and writes the report as one HTML page; burn_report_pdf.js prints it to PDF.
usage: /usr/bin/python3 reports/burn_report_pdf.py OUT.html"""
import json, os, sys, html, collections

HERE = os.path.dirname(os.path.abspath(__file__))
D = json.load(open(os.path.join(HERE, "burn_report_data.json")))
T, RUNS, VEN = D["totals"], D["runs"], D["venues"]
A, Z = D["credits"]["apollo"], D["credits"]["zerobounce"]
e = lambda s: html.escape(str(s if s is not None else ""))
n = lambda x: f"{x:,}" if isinstance(x, (int, float)) else "–"

SRC = T["contacts_by_source_detail_still_on_sheet"]
SAVED, KEPT, GONE = T["contacts_saved_during_burn"], T["contacts_still_on_sheet"], T["contacts_deleted_total"]
RUN_V, WITH = T["venues_run"], T["venues_with_at_least_one_contact_now"]
apollo_now, zb_now = A["now"]["live_read"], Z["now"]["live_read"]
apollo_start, zb_start = A["start_of_burn"]["balance"], Z["start_of_burn"]["balance"]
via_apollo = sum(v for k, v in SRC.items() if "apollo" in k)
via_site = sum(v for k, v in SRC.items() if "website" in k)
CC = A["counter_check"]; CQ = CC["of_which_with_no_audit_session_running"]
LOOK = Z["lookups_by_result_since_burn_began"]
byv = T["contacts_still_on_sheet_by_verified"]

# ---------------------------------------------------------------- the big changes (reports/burn_changes_nov2026.md + Nov 12-13)
CHANGES = [
 ("How the bot runs", [
  ("The burn: outreach around the clock", "Nov 6",
   "One command runs the whole flow in rounds of 25 venues, day and night. After each round a Claude session checks every venue of it again, and every 4 rounds a session turns what the scraper missed into fixes. A file pauses it; it waits by itself when Claude is out of credits.",
   "You had spare credits and wanted them used in one go, then no outreach for a couple of months.",
   "No nightly babysitting. Next time the whole thing starts with the words \"run outreach 24/7\"."),
  ("The 1 am night bot is cancelled for good", "Nov 11",
   "Its launchd job is unloaded and its file moved to LaunchAgents.disabled.",
   "You asked: \"can we cancle the 1am bot for good?\"",
   "Nothing starts by itself at night any more. Chrome is yours at every hour. Outreach runs only when you start a burn or a run by hand."),
  ("Credits run to zero, with no alerts", "Nov 11",
   "Apollo was allowed to run down to 0 instead of stopping at 100. ZeroBounce's daily cap was raised to 5,000 for the burn. The low-credit phone alerts were turned off.",
   "You: start it when you go to sleep, run until Apollo is used up, no alerts.",
   f"Apollo is at {n(apollo_now)}: nothing that needs Apollo works until you top it up. ZeroBounce has {n(zb_now)} left, and its daily cap is back at 400 as of today."),
 ]),
 ("Which places run", [
  ("Best places first", "Nov 7",
   "Region-wide searches of best-of lists (Michelin, Washingtonian, magazines, Forbes, awards, wedding and club lists) added about 140 top venues, and the planner runs them before anything else.",
   "The pool of 5,000 came from town-by-town sweeps and past gigs, and had missed the region's best places. You: \"I want to make sure we are running on quality.\"",
   "The best venues were worked first, while credits were plentiful."),
  ("The 2-hour limit really holds", "Nov 7",
   "Distance is now the measured drive time from Pasadena, not a guess from the city name.",
   "Far places slipped in through a shortcut (Washington, Virginia was read as DC).",
   "No venue more than about two hours away is run."),
  ("No big-university websites", "Nov 10",
   "A venue that lives on a university's site is read on its own page only.",
   "The crawl roamed the whole umd.edu site and saved university staff as a golf course's contacts.",
   "135 such contacts were deleted (see Cleanups). It should not happen again."),
  ("Real stages first", "Nov 11",
   "Restaurants, hotels, clubs, wineries and event venues always run before galleries, museums, churches, senior living and apartments.",
   "Two daytime rounds on Nov 11 ran a college gallery, a nature foundation and senior homes, because a loose 1 to 5 rating ranked them above restaurants. You: \"focus on real shit.\"",
   "The four rounds after the fix were restaurants, hotels, clubs, wineries and wine bars, with one event venue."),
  ("Upscale but not European restaurants", "Nov 11",
   "Claude rated 392 restaurants the taste rules had skipped; the 45 rated 4 or 5 now run.",
   "The taste rules only knew European food, so places such as Old Ebbitt, The Dabney, Kingbird and Bazaar Meat never ran.",
   "Good American and other upscale rooms are in the pool now."),
  ("Pool repair", "Nov 11",
   "About 700 good venues stuck behind bad data were researched and fixed (website, city, address, drive time), and about 110 non-venues were dismissed (gyms, shops, parks, apartments, street numbers). It now runs by itself at every burn start and every 4 rounds; a row is rechecked at most every 30 days.",
   "The old Google Maps discovery had left search words as the city, chain homepages as websites and map points in other states, so real venues were never picked.",
   "The pool for the next burn is bigger and cleaner, and stuck rows fix themselves."),
 ]),
 ("Who gets saved", [
  ("Everyone at the venue is saved", "Nov 11",
   "No title filter and no cap per venue. The after-round check lists doubtful contacts and no longer deletes them.",
   "After the junk rounds I had cut saves to booking titles and 10 per venue. You: \"just add everyone and ill parse it\", \"the problem was you looking up colleges\".",
   f"You see more people per venue in the app and you do the sorting. Of the {n(KEPT)} contacts kept, {n(T['contacts_still_on_sheet_without_a_name'])} have no name and {n(T['contacts_still_on_sheet_flagged_by_audit'])} were marked doubtful by the check."),
  ("Apollo and LinkedIn: back to the old rule", "Nov 12",
   "Apollo looks up everyone except a short back-office and floor-staff list (accounting, HR, IT, maintenance, servers, cooks, bussers, valets), up to 60 people per venue.",
   "You: \"go back to this.\"",
   "More people per venue, and Apollo credits went faster at the end: one round took the balance from 240 to 71."),
  ("LinkedIn stays on", "Nov 8",
   "Its searches now use the exact venue name in quotes with the venue type and state, and results outside DC, Maryland and Virginia are dropped.",
   "I had turned it off after it found almost nothing. You: \"dont turn it off!!!!\", \"use it correctly\".",
   f"It still found little: {n(SRC.get('linkedin+apollo', 0))} contacts from {n(RUN_V)} venues."),
  ("Guards against the wrong organisation", "Nov 11",
   "A venue that is one page of a bigger site (college, chain, government) is read on its own page only. Wedding and listing sites never count as the venue. Head-office staff, staff of other locations and politicians on a links page are dropped. Apollo looks for the venue's own people in its city. A brand's city section counts as the venue (Ned's Club DC no longer reads the New York pages).",
   "This is where the junk came from: other organisations' people saved under a venue's name.",
   "These guards stay on even with \"save everyone\"."),
  ("Scraper fixes", "Nov 6 to 12",
   "The fix sessions made more than 30 fixes: names inside sentences, couples, officer mailboxes, contact forms, mail domains, director@ read as Executive Director, and more.",
   "Each one came from a real contact the after-round check found and the scraper had missed.",
   "The scraper finds more on a venue's own website than it did a week ago."),
 ]),
 ("Cleanups, the app and the rest", [
  ("Junk contacts deleted", "Nov 10 and 11",
   f"{n(GONE)} contacts were deleted: 135 university staff on Nov 10 (UMD golf course, Folger, Corcoran) and 233 on Nov 11 (St. John's College staff, a wedding-listing company's staff, a senior-living head office, Chesapeake Bay Foundation staff, state legislators, addresses with no name).",
   "They were not people who could book you.",
   "A few of the deleted were real Workhouse and Chesapeake Bay Foundation staff. They can be put back from reports/repair/cleanup-20261111-junk-contacts.json if you want them."),
  ("Venue rows fixed", "Nov 11",
   "997 venue rows carry the note \"Repair checked 2026-11-11\". The interrupted afternoon round with the old picks was closed so the night planned fresh.",
   "Part of the pool repair above.",
   "Nothing for you to do."),
  ("The app", "Nov 6 to 11",
   "Venues the bot has not run yet are hidden until it runs them. There is one Event Venues tile. Cream of the Crop skips senior living and other non-prime kinds.",
   "So the app shows what is ready for you, not the waiting pool.",
   "New contacts appear as soon as they are saved."),
  ("Search log and runbook", "Nov 6 to 12",
   "discovery_log.md records every discovery search so none is run twice. Email/CLAUDE.md and the home CLAUDE.md describe everything above.",
   "So the next burn starts from what this one learned.",
   "The next session can pick up from the files alone."),
 ]),
]

# ---------------------------------------------------------------- pieces
def changes_html():
    out = []
    for group, items in CHANGES:
        out.append(f'<h3>{e(group)}</h3>')
        for title, when, what, why, means in items:
            out.append(f'<div class="chg"><div class="chg-h"><span>{e(title)}</span><em>{e(when)}</em></div>'
                       f'<dl><dt>What</dt><dd>{e(what)}</dd><dt>Why</dt><dd>{e(why)}</dd><dt>For you</dt><dd>{e(means)}</dd></dl></div>')
    return "\n".join(out)

def tiles():
    days = "6½"
    t = [(n(RUN_V), "venues run", f"{T['rounds_that_ran_at_least_one_venue']} rounds in {days} days"),
         (n(WITH), "venues with someone to write to", f"{round(100 * WITH / RUN_V)}% of the venues run"),
         (n(KEPT), "contacts in the app from the burn", f"{n(SAVED)} saved, {n(GONE)} junk deleted"),
         (f"{n(apollo_start)} → {n(apollo_now)}", "Apollo credits", "used up: this ended the burn"),
         (f"{n(zb_start)} → {n(zb_now)}", "ZeroBounce credits", f"{n(zb_start - zb_now)} used")]
    return '<div class="tiles">' + "".join(f'<div class="tile"><b>{e(a)}</b><span>{e(b)}</span><i>{e(c)}</i></div>' for a, b, c in t) + "</div>"

def source_table():
    sv, kp = T["contacts_by_source_saved_during_burn"], T["contacts_by_source_still_on_sheet"]
    rows = [("The venue's own website", "website", "The scraper reading the venue's pages"),
            ("Apollo", "apollo", "People Apollo lists as working there, each looked up for an email"),
            ("The after-round check", "audit (deep dive)", f"A Claude session re-searching every venue: {SRC.get('night_apollo', 0)} through Apollo, {SRC.get('night_website', 0)} from websites, {SRC.get('night_press', 0)} from press, {SRC.get('night_websearch', 0)} from a web search"),
            ("Second pass on empty venues", "postcheck", "A second crawl of venues that ended with nobody"),
            ("Facebook and Instagram", "social", "Addresses on the venue's social pages"),
            ("LinkedIn", "linkedin", "People found on LinkedIn, then looked up in Apollo"),
            ("Google", "google", "The last-resort search when nothing else found an email")]
    mx = max(sv.values())
    h = '<table class="t"><thead><tr><th>Where the contact came from</th><th class="r">Saved</th><th class="r">Kept</th><th></th><th>What it is</th></tr></thead><tbody>'
    for label, k, what in rows:
        s, kpt = sv.get(k, 0), kp.get(k, 0)
        h += f'<tr><td><b>{e(label)}</b></td><td class="r">{n(s)}</td><td class="r">{n(kpt)}</td><td class="barc"><span class="bar" style="width:{max(1, round(100 * kpt / mx))}%"></span></td><td class="dim">{e(what)}</td></tr>'
    h += f'<tr class="tot"><td>All</td><td class="r">{n(SAVED)}</td><td class="r">{n(KEPT)}</td><td></td><td class="dim">{n(GONE)} deleted in the cleanups</td></tr></tbody></table>'
    return h

def kind_table():
    K = T["venues_by_kind"]
    order = sorted([k for k in K if K[k]["venues_finished"]], key=lambda k: -K[k]["venues_finished"])
    mx = max(K[k]["contacts_still_on_sheet"] for k in order)
    h = '<table class="t"><thead><tr><th>Kind of venue</th><th class="r">Run</th><th class="r">With a contact</th><th class="r">Contacts kept</th><th></th><th class="r">Per venue</th><th class="r">Deleted</th></tr></thead><tbody>'
    for k in order:
        v = K[k]; f = v["venues_finished"]
        h += (f'<tr><td><b>{e(k.capitalize())}</b></td><td class="r">{n(f)}</td><td class="r">{n(v["venues_with_contacts_now"])} <span class="dim">({round(100 * v["venues_with_contacts_now"] / f)}%)</span></td>'
              f'<td class="r">{n(v["contacts_still_on_sheet"])}</td><td class="barc"><span class="bar" style="width:{max(1, round(100 * v["contacts_still_on_sheet"] / mx))}%"></span></td>'
              f'<td class="r">{v["contacts_still_on_sheet"] / f:.1f}</td><td class="r">{n(v["contacts_deleted"]) if v["contacts_deleted"] else ""}</td></tr>')
    return h + "</tbody></table>"

def nice_date(s):  # "2026-11-06" -> "Nov 6"
    return f"Nov {int(s[8:10])}"

def round_table():
    h = ('<table class="t small rounds"><thead><tr><th>#</th><th>Started</th><th class="r">Venues</th><th class="r">With contact</th><th class="r">Saved</th><th class="r">Kept</th>'
         '<th class="r">Apollo left</th><th class="r">Apollo used</th><th class="r">ZB used</th><th class="nt">Note</th></tr></thead><tbody>')
    for i, r in enumerate(RUNS, 1):
        a0, a1, z0, z1 = r["apollo_balance_at_start"], r["apollo_balance_at_end"], r["zerobounce_balance_at_start"], r["zerobounce_balance_at_end"]
        note = ""
        if r["contacts_deleted_total"]: note = f'{r["contacts_deleted_total"]} deleted later as junk'
        sr = r["stopped_reason"] or ""
        if "paused by Alex" in sr: note = "Paused by you before any venue ran"
        elif "Chrome stopped" in sr: note = (note + "; " if note else "") + "Chrome stopped answering"
        elif "Apollo step failed" in sr: note = "Apollo ran out: the end"
        saved = r["contacts_saved_total"] if r["contacts_saved_total"] is not None else 0
        h += (f'<tr><td>{i}</td><td class="nw">{nice_date(r["started_date"])}, {e(r["started_time"])}</td><td class="r">{r["venues_finished"]} of {r["venues_planned"]}</td><td class="r">{r["venues_with_contacts_now"]}</td>'
              f'<td class="r">{n(saved)}</td><td class="r">{n(r["contacts_still_on_sheet"])}</td><td class="r">{n(a1) if a1 is not None else "–"}</td>'
              f'<td class="r">{n(a0 - a1) if a0 is not None and a1 is not None else "–"}</td><td class="r">{n(z0 - z1) if z0 is not None and z1 is not None else "–"}</td><td class="dim">{e(note)}</td></tr>')
    return h + "</tbody></table>"

SRC_LABEL = collections.OrderedDict([("website", "Website"), ("apollo", "Apollo"), ("audit (deep dive)", "After-round check"), ("postcheck", "Second pass"), ("social", "Social"), ("linkedin", "LinkedIn"), ("google", "Google"), ("other", "Other")])
CLEAN = {"cleanup-20261110-edu-contacts": "Nov 10 (university staff)", "cleanup-20261111-junk-contacts": "Nov 11 (junk)", "cleanup-20261111-junk-contacts-2": "Nov 11 (junk)"}

def people_cell(v):
    if v.get("outcome") == "skipped":
        return '<span class="dim">Skipped: the sheet marks it as closed</span>'
    if not v["finished"]:
        return'<span class="dim">Not reached' + (" (the round stopped first)" if v["in_a_started_batch"] else "") + "</span>"
    ps = v["people"] or []
    if not ps:
        return '<span class="none">Nobody found</span>'
    kept = [p for p in ps if p["still_on_sheet"]]; gone = [p for p in ps if not p["still_on_sheet"]]
    parts = []
    by = collections.OrderedDict()
    for p in kept: by.setdefault(p["source"] if p["source"] in SRC_LABEL else "other", []).append(p)
    for s in SRC_LABEL:
        if s not in by: continue
        named = [p for p in by[s] if (p.get("name") or "").strip()]; bare = len(by[s]) - len(named)
        bits = []
        for p in named:
            t = (p.get("title") or "").strip()
            bits.append(f'<span class="p">{e(p["name"].strip())}{("<i>, " + e(t) + "</i>") if t else ""}{"<sup>?</sup>" if p.get("flagged_by_audit") else ""}</span>')
        if bare: bits.append(f'<span class="dim">{bare} address{"es" if bare != 1 else ""} with no name</span>')
        parts.append(f'<div class="src"><b>{SRC_LABEL[s]}:</b> ' + "; ".join(bits) + "</div>")
    if gone:
        c = collections.Counter(CLEAN.get(p.get("deleted_in"), "a cleanup") for p in gone)
        parts.append('<div class="gone">' + "; ".join(f"{k} deleted in the cleanup of {w}" for w, k in c.items()) + "</div>")
    return "".join(parts)

def venues_html():
    out = []
    by = collections.OrderedDict()
    for v in VEN: by.setdefault(v["run_id"], []).append(v)
    for i, r in enumerate(RUNS, 1):
        vs = by.get(r["run_id"], [])
        if not r["venues_finished"]:
            out.append(f'<h3 class="rh">Round {i} <span>{nice_date(r["started_date"])}, {e(r["started_time"])} · paused by you before any venue ran; its venues stayed in the pool</span></h3>'); continue
        out.append(f'<h3 class="rh">Round {i} <span>{nice_date(r["started_date"])}, {e(r["started_time"])} · {r["venues_finished"]} venues run, {r["venues_with_contacts_now"]} with a contact, {n(r["contacts_still_on_sheet"])} contacts kept</span></h3>')
        out.append('<table class="v"><thead><tr><th>Venue</th><th>Kind</th><th>Who was found</th></tr></thead><tbody>')
        for v in vs:
            where = ", ".join(x for x in [(v.get("city") or "").strip(), (v.get("state") or "").strip()] if x)
            out.append(f'<tr><td class="vn"><b>{e(v["name"])}</b><br><span class="dim">{e(where)}</span></td><td class="vk">{e((v["kind"] or "").capitalize())}</td><td>{people_cell(v)}</td></tr>')
        out.append("</tbody></table>")
    return "\n".join(out)

zero_now = T["venues_zero_now"]
not_reached_last = [r for r in RUNS if "Apollo step failed" in (r["stopped_reason"] or "")][0]
left_last = not_reached_last["venues_planned"] - not_reached_last["venues_finished"]
junk = {r["run_id"]: r for r in RUNS}
j1, j2, j0 = junk["run-20261111-1108"], junk["run-20261111-1336"], junk["run-20261110-0254"]
zb_def = sum(int(x["what"].split(": ")[1].split(" ")[0]) for x in D["incidents"] if x["kind"] == "zerobounce_deferred")
ST = T["step_results_all_rounds"]

HTML = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Gig outreach: the November 2026 burn</title>
<style>
@page {{ size: Letter; margin: 16mm 15mm 17mm 15mm; }}
* {{ box-sizing: border-box; }}
html {{ font: 10.2pt/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d2430; }}
body {{ margin: 0; }}
h1 {{ font: 700 25pt/1.15 "Iowan Old Style", Georgia, serif; margin: 0 0 3pt; letter-spacing: -.01em; }}
.sub {{ color: #5b6675; font-size: 11pt; margin-bottom: 14pt; }}
h2 {{ font: 700 15.5pt/1.2 "Iowan Old Style", Georgia, serif; margin: 22pt 0 7pt; padding-top: 9pt; border-top: 2pt solid #1d2430; break-after: avoid; }}
h2.page {{ break-before: page; margin-top: 0; }}
h3 {{ font-size: 9pt; letter-spacing: .09em; text-transform: uppercase; color: #9a4a1c; margin: 15pt 0 6pt; break-after: avoid; }}
p {{ margin: 0 0 7pt; }}
.lead {{ font-size: 11.2pt; line-height: 1.5; }}
.dim {{ color: #6b7685; }}
.tiles {{ display: grid; grid-template-columns: repeat(5, 1fr); gap: 7pt; margin: 12pt 0 13pt; }}
.tile {{ border: .8pt solid #cfd6df; border-radius: 5pt; padding: 8pt 8pt 7pt; background: #f6f8fa; }}
.tile b {{ display: block; font: 700 15.5pt/1.1 "Iowan Old Style", Georgia, serif; white-space: nowrap; }}
.tile span {{ display: block; font-size: 8.6pt; font-weight: 600; margin-top: 4pt; line-height: 1.25; }}
.tile i {{ display: block; font-style: normal; font-size: 8pt; color: #6b7685; margin-top: 2pt; line-height: 1.25; }}
.chg {{ border: .8pt solid #d5dbe3; border-left: 3pt solid #9a4a1c; border-radius: 0 5pt 5pt 0; padding: 6pt 10pt 5pt; margin: 0 0 6pt; break-inside: avoid; }}
.chg-h {{ display: flex; justify-content: space-between; gap: 10pt; font-weight: 700; font-size: 10.6pt; margin-bottom: 2pt; }}
.chg-h em {{ font-style: normal; font-weight: 500; color: #6b7685; font-size: 8.8pt; white-space: nowrap; }}
dl {{ display: grid; grid-template-columns: 44pt 1fr; gap: 1.5pt 6pt; margin: 0; font-size: 9.5pt; line-height: 1.42; }}
dt {{ color: #9a4a1c; font-weight: 600; font-size: 8.6pt; padding-top: .8pt; }}
dd {{ margin: 0; }}
table {{ border-collapse: collapse; width: 100%; }}
.t {{ margin: 5pt 0 9pt; font-size: 9.5pt; }}
.t th {{ text-align: left; font-size: 8pt; letter-spacing: .04em; text-transform: uppercase; color: #5b6675; border-bottom: 1pt solid #1d2430; padding: 3pt 6pt 3pt 0; vertical-align: bottom; }}
.t td {{ border-bottom: .5pt solid #dfe4ea; padding: 3.2pt 6pt 3.2pt 0; vertical-align: top; }}
.t .r {{ text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }}
.t .tot td {{ font-weight: 700; border-bottom: none; border-top: 1pt solid #1d2430; }}
.t.small {{ font-size: 8.4pt; }} .t.small td {{ padding: 2.3pt 5pt 2.3pt 0; }}
.nw {{ white-space: nowrap; }} .rounds .nt {{ width: 34%; padding-left: 8pt; }} .rounds td:last-child {{ padding-left: 8pt; }}
.barc {{ width: 62pt; vertical-align: middle !important; }}
.bar {{ display: block; height: 6.5pt; background: #b9622f; border-radius: 1.5pt; }}
ul {{ margin: 3pt 0 8pt; padding-left: 14pt; }} li {{ margin-bottom: 4pt; }}
ol {{ margin: 3pt 0 8pt; padding-left: 16pt; }}
.box {{ background: #f6f8fa; border: .8pt solid #cfd6df; border-radius: 5pt; padding: 8pt 11pt 3pt; margin: 8pt 0; break-inside: avoid; }}
code {{ font: 8.6pt ui-monospace, Menlo, monospace; background: #eef1f4; padding: 0 2.5pt; border-radius: 2pt; }}
.rh {{ font-size: 10.5pt; letter-spacing: 0; text-transform: none; color: #1d2430; margin: 13pt 0 3pt; border-bottom: 1pt solid #1d2430; padding-bottom: 2pt; }}
.rh span {{ font-weight: 400; color: #5b6675; font-size: 8.6pt; margin-left: 5pt; }}
.v {{ font-size: 7.9pt; line-height: 1.36; }}
.v th {{ text-align: left; font-size: 6.8pt; letter-spacing: .05em; text-transform: uppercase; color: #6b7685; padding: 1.5pt 5pt 1.5pt 0; }}
.v td {{ border-top: .5pt solid #dfe4ea; padding: 2.6pt 6pt 2.6pt 0; vertical-align: top; }}
.v tr {{ break-inside: avoid; }}
.vn {{ width: 27%; }} .vk {{ width: 11%; color: #47505d; }}
.v .src b {{ color: #9a4a1c; font-weight: 600; }}
.v .p i {{ color: #5b6675; font-style: normal; }}
.v sup {{ color: #b3261e; font-weight: 700; }}
.none {{ color: #9aa3ae; }}
.gone {{ color: #b3261e; }}
.key {{ font-size: 8.6pt; color: #47505d; margin: 2pt 0 4pt; }}
</style></head><body>

<h1>Gig outreach: the November burn</h1>
<div class="sub">Nov 6 to Nov 13, 2026 · written Nov 13 · every number is read from the run logs and the live sheet</div>

<p class="lead">The burn ran from 11:08 pm on Friday Nov 6 until 11:27 am on Friday Nov 13, when Apollo reached zero. It worked {n(RUN_V)} venues and left {n(KEPT)} contacts in the app at {n(WITH)} of them. Outreach is now off and saved; you said you will look at it again in January 2027. Nothing was sent: sending stays by hand, from the app.</p>
{tiles()}
<p class="dim">In this report: 1 The big changes · 2 Totals by source and by kind of venue · 3 Credits · 4 What broke · 5 What's next · 6 Every venue run and who was found (the long list, at the end so the rest stays easy to reach).</p>

<h2>1 · The big changes</h2>
<p>Everything that changed in how outreach works between Nov 6 and Nov 13, in the order of the change list kept during the burn.</p>
{changes_html()}

<h2 class="page">2 · Totals</h2>
<p>{n(SAVED)} contacts were saved during the burn. {n(GONE)} were deleted as junk in the cleanups of Nov 10 and 11, which leaves {n(KEPT)}. "Kept" below means still on the sheet today.</p>
<h3>By source</h3>
{source_table()}
<p>The venue's own website is the main source: counting the after-round check and the second pass, {n(via_site)} of the {n(KEPT)} kept contacts came from a website. Apollo gave {n(via_apollo)}, counting the ones the after-round check and LinkedIn found through it. LinkedIn and Google together added almost nothing.</p>
<h3>By kind of venue</h3>
{kind_table()}
<p>Clubs gave the most per venue and almost every club had someone. Galleries and museums look rich, but most of what they gave was other organisations' staff and was deleted. That is the reason for "real stages first".</p>
<h3>What the {n(KEPT)} kept contacts are</h3>
<ul>
<li><b>{n(byv.get("valid", 0))}</b> have an email ZeroBounce called valid. <b>{n(byv.get("role", 0))}</b> are shared inboxes such as events@ (not checked by ZeroBounce). {n(byv.get("catch-all", 0) + byv.get("unverified", 0))} are unchecked.</li>
<li><b>{n(T["contacts_still_on_sheet_without_a_name"])}</b> have no person's name: with "save everyone", an address is kept even when no name is printed beside it.</li>
<li><b>{n(T["contacts_still_on_sheet_flagged_by_audit"])}</b> were marked doubtful by the after-round check (wrong organisation, back office, another location). They are listed, not deleted, and carry a red <b style="color:#b3261e">?</b> in the venue list at the end.</li>
<li><b>{n(T["contacts_still_on_sheet_already_emailed"])}</b> have already been emailed by you.</li>
<li><b>{n(zero_now)}</b> of the {n(RUN_V)} venues ended with nobody and went back to "needs review".</li>
</ul>

<h2>3 · Credits</h2>
<div class="box">
<p><b>Apollo: {n(apollo_start)} at the start, {n(apollo_now)} now.</b> It is used up. Lookups through Apollo will not work until it is topped up.</p>
<p><b>ZeroBounce: {n(zb_start)} at the start, {n(zb_now)} now</b> ({n(zb_start - zb_now)} used). Of {n(sum(LOOK.values()))} addresses checked, {n(LOOK.get("valid", 0))} were valid, {n(LOOK.get("invalid", 0))} invalid, {n(LOOK.get("catch-all", 0))} catch-all, {n(LOOK.get("do_not_mail", 0))} do-not-mail, {n(LOOK.get("unknown", 0))} unknown and {n(LOOK.get("abuse", 0))} abuse. Only valid ones were saved. The daily cap is back at 400.</p>
</div>
<p><b>Where the Apollo credits went is not fully explained.</b> The pipeline counts a credit each time it looks a person up. Across the {CC["batches"]} batches where both numbers can be compared, the account fell by {n(CC["account_balance_drop"])} credits while the pipeline counted {n(CC["pipeline_step_credits"])}. Part of the gap is the after-round check, which also uses Apollo. But in the {CQ["batches"]} batches where no check was running, the account still fell by {n(CQ["account_balance_drop"])} against {n(CQ["pipeline_step_credits"])} counted. So about half of the credits went to something the pipeline does not count, most likely the searches themselves. This is a guess until it is tested, and it is the first thing to settle before buying more: if searches cost credits, fewer or smarter searches could nearly double the venues per credit.</p>
<p>In round numbers, Apollo cost about {apollo_start / via_apollo:.0f} credits for each contact kept through it, and ZeroBounce about {(zb_start - zb_now) / byv.get("valid", 1):.1f} checks for each valid address kept.</p>
<h3>Round by round</h3>
{round_table()}
<p class="key">"Apollo used" is the fall in the account between the start of a round and the next reading, so it includes the after-round check running beside it. Rounds 13, 16 and 21 were followed by a long stop, so their figure also covers anything done by hand before the next round.</p>

<h2 class="page">4 · What broke</h2>
<ul>
<li><b>Three rounds ran junk venues.</b> Round 14 (Nov 10) saved {n(j0["contacts_saved_total"])} contacts and {n(j0["contacts_deleted_total"])} were university staff. Rounds 17 and 18 (Nov 11, daytime) saved {n(j1["contacts_saved_total"] + j2["contacts_saved_total"])} and {n(j1["contacts_deleted_total"] + j2["contacts_deleted_total"])} were deleted: a college's directory for the gallery inside it, a foundation's scientists, a chain's head office, a wedding-listing company. Those two rounds cost {n(j1["apollo_balance_at_start"] - j2["apollo_balance_at_end"])} Apollo credits and {n(j1["zerobounce_balance_at_start"] - j2["zerobounce_balance_at_end"])} ZeroBounce checks. Fixed the same day by the planner order, the wrong-organisation guards and the pool repair.</li>
<li><b>Claude ran out of its weekly limit twice.</b> Nov 7, 5:47 to 9:48 am (4 hours) and Nov 12, 4:41 to 11:43 am (7 hours). The burn waited as built, so no credits went to rounds nobody checked. The scraper-fix session for the last rounds could not run until the burn had ended (see the fix sessions below).</li>
<li><b>The burn was down three times for long stretches.</b> Nov 8, 10:40 am to Nov 9, 11:45 pm (37 hours; the round in progress was stopped from outside, and the runbook says you had it stopped that day). Nov 10, 10:31 am to Nov 11, 11:05 am (24½ hours; the log does not say why). Nov 11, 3:45 pm to 9:36 pm (6 hours, for the junk cleanup and the fixes). You also paused it from Nov 12, 11:57 am to Nov 13, 10:38 am.</li>
<li><b>Chrome.</b> On the night of Nov 9 Chrome had no open window: the round failed its start check 7 times in 66 minutes and the run gave up after 6 stops in a row. On Nov 11 at 3:36 pm Chrome stopped answering and round 18 ended four venues early.</li>
<li><b>ZeroBounce's per-venue cap.</b> {n(zb_def)} addresses were saved unchecked because one venue hit the cap of checks, nearly all in the three junk rounds. They were checked later; {n(byv.get("unverified", 0))} unchecked address is left. ZeroBounce also refused the Mac's internet address once, for a minute, on Nov 8.</li>
<li><b>The fix session's changes were undone three times.</b> On Nov 10 (1:22 am and 10:31 am) the session was cut off with unfinished code, and the safety net put the code back; those fixes were lost. The last session, after the burn ended on Nov 13, finished its fixes for the last six rounds (owners named in sentences, staff cards, email links shown as icons, owner-run inboxes), but one of the scraper's own tests failed afterwards, so the safety net undid them at 12:46 pm. That work is not lost: it is in the history as commit <code>b878540</code>, to be put back once the failing test is sorted out. The scraper is as it was before that session.</li>
<li><b>Small write errors.</b> Seven rounds had one failed write to the sheet each, and five venues' status was not written at the end of their run. Every contact counted here was read back from the live sheet.</li>
<li><b>LinkedIn and Google found almost nothing.</b> LinkedIn: {ST.get("linkedin:ok", 0)} venues with a result, {ST.get("linkedin:empty", 0)} empty, {ST.get("linkedin:failed", 0)} failed, {ST.get("linkedin:blocked", 0)} blocked, and a rate limit on Nov 12. Google: {ST.get("google:ok", 0)} of {ST.get("google:ok", 0) + ST.get("google:empty", 0)} tries found an email. Google never showed a CAPTCHA.</li>
<li><b>The Apollo count is wrong</b> (section 3): the pipeline's own tally showed 0 to 2 credits for batches in which the account fell by 13 to 20.</li>
<li><b>Left in the pool with bad data.</b> In the last round two venues have their own name in the city field (Le Bistro VA, The Gathering Spot DC) and one has the chain's all-locations page as its website (Maggiano's Bethesda, never reached). {left_last} venues of that round never ran because Apollo ran out.</li>
</ul>

<h2>5 · What's next</h2>
<h3>For you, now</h3>
<ul>
<li>The {n(KEPT)} contacts are in the app, ready to be sent by hand. The {n(T["contacts_still_on_sheet_flagged_by_audit"])} doubtful ones and the {n(T["contacts_still_on_sheet_without_a_name"])} with no name are the ones to sort first.</li>
<li>If you want the real Workhouse and Chesapeake Bay Foundation staff back, say so: they are in the Nov 11 backup.</li>
<li>Outreach stays off. The 1 am bot is cancelled, the night switch is off, and Chrome is free at all hours.</li>
</ul>
<h3>Before the next burn (you look again in January 2027; the plan of Nov 7 was a burn about every three months)</h3>
<ol>
<li><b>Look at what this burn earned:</b> emails sent, replies and gigs from these {n(KEPT)} contacts, by kind of venue. That decides what the next one should chase.</li>
<li><b>Settle the Apollo question first</b> (section 3), then top up. This burn used {n(apollo_start)} Apollo credits and {n(zb_start - zb_now)} ZeroBounce checks for {n(RUN_V)} venues. ZeroBounce has {n(zb_now)} left, enough for about {round((zb_now - 100) / ((zb_start - zb_now) / RUN_V))} venues at this burn's rate.</li>
<li><b>Fill the pool with the best first:</b> the region-wide best-of sweeps again, then a few sweeps of thin towns, then a pool check (<code>./build_batch.sh --total 50 --dry-run</code>).</li>
<li><b>Put back the last fixes:</b> commit <code>b878540</code> (undone on Nov 13 because <code>site_discovery_tests</code> failed) and the small taste note in <code>2b8f8b2</code> that was undone with it.</li>
<li><b>Fix before starting:</b> Apollo is asked twice about the same person (the main step, then the second pass on empty venues, each time for a credit, even when the first answer was "no email"); the LinkedIn step ({SRC.get("linkedin+apollo", 0)} contacts from {n(RUN_V)} venues; it stays on by your rule, so its searches need work), the Google fallback, venue rows with a name as the city, and chain location pages saved as a venue's website.</li>
<li><b>Read round 1 before letting it go on.</b> The Nov 11 junk would have been caught after one round, not three.</li>
<li><b>Start it:</b> raise <code>ZB_MAX_PER_DAY</code> for the burn, <code>rm Email/.burn_done</code>, then say "run outreach 24/7". The settings you chose stay as they are: best places first, real stages first, save everyone, Apollo for everyone but back office, LinkedIn on, no phone alerts.</li>
</ol>

<h2 class="page">6 · Every venue run</h2>
<p>All {n(RUN_V)} venues, round by round, with the people kept on the sheet today grouped by where they were found. A red <b style="color:#b3261e">?</b> marks a contact the after-round check called doubtful. Deleted junk is given as a count. Email addresses are left out; they are in the app.</p>
{venues_html()}
</body></html>"""

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "burn_report_nov2026.html")
open(out, "w", encoding="utf8").write(HTML)
print("wrote", out, len(HTML), "bytes")
