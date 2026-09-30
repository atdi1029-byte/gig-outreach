# Night deep dive — zero-contact venues (unattended)

`night_run.sh` starts you after each night run with `RUN_ID=<run>`. Alex is asleep.
Nobody will answer a question, so never ask one: decide, do it, write it down.

Your job, in this order:
1. Research every venue in `reports/runs/$RUN_ID.zero.json` (the pipeline found no
   usable email for them) and write what you find to `reports/runs/$RUN_ID.deepdive.json`.
2. For every miss the pipeline should have caught, fix the scraper so the next run
   catches it, prove it with the tests, and commit the fix.
3. Taste review (small).
4. Write the summary file.

`night_run.sh` does everything else: it saves your findings to the sheet with
`night_save.py` (the save policy lives there), pushes, and updates the app. Budget:
about 90 minutes in total; the session is killed at 100.

## Hard rules
- Never use Chrome: no `osascript`, no Claude-in-Chrome tools, no `pipeline.sh`,
  `discover.sh`, `postcheck.sh`, `backfill_websites.sh` or `sweep.sh --chrome`.
  (The recall benchmark's own headless Chrome is fine; it never touches Alex's.)
- Never write to the sheet yourself (no `add_contact`/`update_venue` calls, no
  `repair_data.py --apply`). Findings go in the JSON file; `night_save.py` writes.
- Never send anything. Never push (night_run.sh pushes). Never touch `.env`,
  `night_run.sh`, `night_*.py`, `index.html`, `service-worker.js`, `apps_script.gs`,
  any CLAUDE.md, launchd files or `~/.claude`.
- `python3` on PATH is broken: use `/usr/bin/python3`. Never `cat` a log; use `tail`/`grep`.
- Don't flag a venue for having no events page or live music; that never disqualifies it.

## 1. Research (parallel)
Read `reports/runs/$RUN_ID.zero.json`. Each venue carries what the pipeline saw:
`pipeline_steps` ([STEP] lines: pages visited, emails seen and rejected, people),
`candidates` (every email/person it found and why it was not saved) and `coverage`
(crawl files: pages fetched, blocked, high-priority pages it never visited).

Split the venues over general-purpose subagents (2-3 venues each, up to 5 at a time).
Give each agent the venue records and these instructions:
- WebFetch the venue's own site: home, contact, about, events, private events,
  catering, weddings, team/staff/our-team/leadership, the footer, `sitemap.xml`, and
  PDFs (event menus and packets often carry the events manager's email). Try the
  `high_priority_unvisited` pages from coverage first.
- WebSearch: `"<name>" <city> email`, `"<name>" events manager`, `"<name>" owner`,
  `"<name>" general manager`, `"@<domain>"`, `site:<domain> email`.
- Apollo MCP: organization by domain AND by name (reject any org whose name is not
  clearly this venue: "La Lou Bistro" is not "Petit Louis Bistro"), then people at
  that org. Enrich (`apollo_people_match` / `apollo_people_bulk_match`) only people
  with a decision-maker title (owner, GM, events/catering/sales/F&B director or
  manager, private dining, banquets), at most 5 per venue, and only if
  `apollo_users_api_profile(include_credit_usage=true)` shows 150+ credits left.
- Facebook / Instagram "About" (via WebSearch snippets if the page is walled).
- Return, per venue: every email with the person's name, title, the URL it came
  from, whether it was on the venue's own site, whether it was a `mailto:` there;
  Facebook/Instagram/contact-form URLs the sheet doesn't have; and for anything the
  pipeline missed, where it was and a guess why the pipeline missed it.

Save policy (night_save.py enforces it, but don't hand it junk):
- Every contact needs a real first + last name. Never invent a name from an email
  (first.last@ is the only exception).
- General inboxes (info@, contact@, hello@, office@, frontdesk@, reception@, stay@,
  guest@, admin@...) are never saved, even with a name. Function inboxes (events@,
  catering@, privateevents@, banquets@, weddings@, sales@, chef@, owner@, gm@) are
  saved only with the real person who runs them.
- The venue's own domain only. A management/owner-group domain counts only when the
  venue's OWN site publishes it for its contacts: set `"allow_off_domain": true`.
- People with no email are useful context (put them in, with `"email": ""`), but
  they are never saved.

Write `reports/runs/$RUN_ID.deepdive.json` as results come in (rewrite the whole file
each time, valid JSON), one entry for EVERY venue you researched, even with nothing
found:
```json
{"run_id": "RUN_ID", "venues": [
  {"venue_id": "MD-REST-1234", "researched": true,
   "contacts": [{"name": "Liz McQuay", "title": "Events Manager", "email": "events@x.com",
                 "source": "website|apollo|websearch|facebook|press",
                 "source_url": "https://x.com/private-events", "found_on_venue_site": true,
                 "venue_mailto": true, "allow_off_domain": false}],
   "facebook": "", "instagram": "", "contact_form": "",
   "summary": "one line: what you found or why there is nothing"}]}
```
Append every real miss to `reports/runs/$RUN_ID.misses.jsonl`, one line each:
`{"venue_id":..., "kind":"email|contact|social|contact_form", "value":...,
"source_url":..., "pipeline_had":false, "cause_guess":..., "on_venue_site":true|false,
"how":"mailto|plain_text|cloudflare_attr|entity_encoded|script_json|obfuscated_text|js_rendered|pdf|third_party_form|apollo|press|other"}`.
A venue with nothing missed gets `{"venue_id":..., "kind":"audited"}`.

## 2. Fix what the pipeline missed
A miss on the venue's own website that the website step should have seen (the page
was visited, reachable in a few clicks, or in the sitemap) is a scraper bug. For each
distinct cause (group misses that share one), and only after step 1 is written:

1. Reproduce it with the recall benchmark (`tests/website_recall/README.md`):
   add the venue and the item to `tests/website_recall/benchmark.json` (same format as
   the existing entries: `kind`, `value`, `name`/`title`, `page`, `how`, `priority`),
   record its pages once with
   `tests/website_recall/run_recall.sh --net record --venues <ID> --label night-<ID>`,
   and confirm the current code misses it.
2. Fix the cause in `site_discovery.py` (static crawl) and/or the website step in
   `pipeline.sh` (`write_scrape_js`, `web_parse_html`, the `_web_py_*` helpers).
   Keep the fix general (a pattern, not the venue's name) and small.
3. Prove it: `run_recall.sh --venues <ID>` now finds it; then the whole benchmark in
   replay mode, `tests/website_recall/run_recall.sh --label night-after-<sha>`, compared
   with a baseline of the committed code using
   `/usr/bin/python3 tests/website_recall/lib/compare.py RUN_A RUN_B`: nothing that was
   found before may be lost. The baseline is
   `run_recall.sh --git-rev HEAD --label night-before-<short HEAD sha>`; if a run with
   that label for the same sha already exists under `tests/website_recall/runs/`, reuse
   it (a full run takes 15-20 minutes). Also: `bash tests/site_discovery_tests.sh`,
   `/usr/bin/python3 tests/check_heredocs.py pipeline.sh postcheck.sh`, `bash -n` on
   every changed `.sh`, and `/usr/bin/python3 -m py_compile` on every changed `.py`.
4. All green: `git add` exactly the files you changed plus `benchmark.json`, then
   `git commit -m "Night fix ($RUN_ID): <cause> — now finds <value> on <venue>"`.
   Not green after two attempts: `git checkout -- <those files>` so the tree is back to
   HEAD, and list it under `reverted` in the summary. Never leave a failing change
   uncommitted in the tree, and never commit one.

Misses that were not on the venue's site (Apollo found them another way, a press
article, Facebook) are fixed only when the cause is plain in the code and a test covers
it; otherwise just give the cause in the misses file. Stop starting new fixes 60
minutes into the session.

## 3. Taste review
`/usr/bin/python3 taste_review.py` lists votes/feedback not yet in `taste_notes.md`.
Append the useful ones to `taste_notes.md` in its existing style, then
`/usr/bin/python3 taste_review.py --mark`. Change `taste_score.py` only for a clear,
repeated pattern, with its self-test passing, and commit it on its own
(`git commit -m "Night taste: <pattern>"`); anything left uncommitted in `.py` files is
thrown away after the session. Nothing new = skip.

## 4. Summary
Write `reports/runs/$RUN_ID.deepdive-summary.json`:
```json
{"run_id": "RUN_ID", "venues_researched": 0, "venues_with_finds": 0, "contacts_found": 0,
 "misses": 0, "fixes": [{"commit": "abc1234", "what": "cloudflare-protected mailto in footers"}],
 "reverted": [], "taste_reviewed": 0,
 "note": "one plain sentence for Alex about the night's deep dive"}
```
End your reply with that one sentence.
