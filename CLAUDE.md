# Gig Outreach — Runbook

This file is the one source of truth for how a run works. The home CLAUDE.md and
memory notes point here; if they disagree with this file, this file wins.

A run = up to ~50 venues, split into batches of at most 8, under one RUN_ID.
Since Sep 29 2026 runs happen by themselves every night (see "Night runs" below):
no reports, no review gate. Contacts show in the app as soon as they're saved,
and the app's home screen shows an alert when a night stops for something Alex
has to fix (ZeroBounce or Apollo out of credits, Chrome) plus one line about the night.

## Rules that override everything else
- `python3` on PATH is broken on this Mac (Intel-only build). Scripts fix this
  themselves via `env_check.sh`; in your own commands use `/usr/bin/python3`.
- Never skip a step silently. If something can't run (Chrome closed, credits out,
  site down), the run reports it as `failed`/`blocked`, or you record it with
  `./mark_step.sh <venue_id> <step> BLOCKED "<reason>"`. Blocked is allowed;
  unrecorded is not.
- Never summarize from memory. Numbers come from the run log, the sheet and
  `night_zero.py --stats`; don't hand-write them.
- Never `cat` a log. `tail` and `grep` only.
- Don't edit `pipeline.sh` during a run. Don't run two scripts that drive Chrome
  at once (pipeline, discover, sweep --chrome refuse while the pipeline holds
  `/tmp/pipeline.lock.d`).
- Runs need Chrome to themselves (Alex, Sep 30 2026: "we need to run alone"). Never
  start another copy of the Chrome app — no puppeteer, headless or CDP browser from
  `/Applications/Google Chrome.app`, in any project. macOS sends AppleScript for "Google
  Chrome" to the NEWEST running copy, so a headless test copy takes every command of
  the run (navigations land in it, JavaScript "is turned off"): that stopped the Sep 30
  night at 01:09. Test browsers use Chrome for Testing (`~/.cache/puppeteer`, a separate
  app; `npx @puppeteer/browsers install chrome@stable --path ~/.cache/puppeteer`), as
  the recall benchmark and the Books tests do. `chrome_guard.sh` is the net: every
  Chrome-driving script waits for another copy to close, and at night closes a copy a
  program started.
- Do not send anything. Sending is manual, always, from the app.
- Save policy (enforced by the code and the backend):
  - An email is saved only if it's on the venue's own domain, or a free-mail/ISP
    address linked to the venue (mailto on its site, or venue words in it).
    Off-domain = rejected and kept in the candidate log, never saved.
  - Exception (Alex, Sep 26 2026): the venue's own mail domain counts as its
    domain even when it differs from the website's — a sibling TLD
    (rollingroadgc.com for .org), the club's own mail domain (@spcc1925.com), or
    the management company's domain when the venue's OWN site uses it for its
    contacts (The Lodge → titanhospitality.com, Osteria Mozza → STARR, CIRCA →
    eatmhg.com). Save those people (the pipeline passes allow_off_domain). A
    parent group the venue's site doesn't use (Popal Group for Maison) stays
    listed only. A booking inbox the venue's own site publishes on the owner
    group's domain (Flore Cafe -> events.catering@sistersgroupusa.com) counts
    as the venue's own: pair it with the owner/GM name found elsewhere (press,
    About page) and save it as `verified=role` (Alex, Sep 27 2026: "seems
    perfect"). Do not leave it as listed-only.
  - General inboxes (info@, contact@, hello@, office@, frontdesk@, reception@,
    stay@, guest@, admin@ ...) are NEVER saved, even with an owner's name
    attached (Alex, Sep 27 2026: "they always are a waste of time"). Function
    inboxes that reach a specific person or team (events@, catering@,
    privateevents@, banquets@, weddings@, sales@, chef@, owner@, gm@) are saved
    only with a real person's name attached (e.g. "Liz McQuay, Events Manager
    → events@"), as `verified=role`, and never cost a ZeroBounce credit.
  - Personal inboxes go through ZeroBounce: `valid` is saved. ZeroBounce
    running out (no credits, a budget cap, key or IP refused) STOPS the run
    (Alex, Sep 29 2026: "if we run out of apollo credits or zerobounce you
    stop and make an alert on the app"). The venue that hit it keeps those
    emails as `verified=unverified`; the next night re-checks them first
    (`./reverify.sh --unverified --limit 60`). `STOP_ON_ZB_OUT=0` restores the
    old keep-going behaviour for a manual run.
  - Names are never invented from email local parts (first.last is the only
    exception). Masked Apollo names (`Mc***y`) are enriched or skipped.
  - People found WITHOUT an email are never put on the sheet (Alex, Sep 27
    2026: he doesn't want them in the app). Pipeline, postcheck and the deep
    dive keep them in the run log / candidate file / findings files only, so the
    zero-contact deep dive can still use them.
    `SAVE_PENDING_PEOPLE=1` restores the old behaviour for a test.
  - Existing Facebook/Instagram/contact-form values on the sheet are never
    overwritten. Venue status is never demoted.
- Target area: DC, MD, VA; max ~2 hour drive from Pasadena, MD. Exception (Alex, Sep 29
  2026, on the 207 Pennsylvania/Delaware sweep finds: "fix these last"): sweep finds in
  PA/DE run too, whatever the distance, but only after every DC/MD/VA venue (build_batch
  fills a run with them only when the DC/MD/VA queue can't; `outreach_rules.LAST_STATES`).
  Other PA/DE discovery stays out.

## Night runs (automatic, since Sep 29 2026)
Alex: "run by yourself at night, runs of 50, push everything after each run, go
deeper on 0-contact venues and fix the code, and if Apollo or ZeroBounce run out,
stop and alert me in the app." Window: 1:00 to 8:00 (Alex picked "1am, stop by 8am").
- launchd (`~/Library/LaunchAgents/com.alexbarnett.outreach-night.plist`, installed
  by Alex) opens `night_run.command` in Terminal at 1:00, so Chrome automation runs
  with Terminal's permission. The Mac must be awake, plugged in, lid open, on the home
  network (ZeroBounce only accepts the home IP), Chrome open.
- `night_run.sh`: checks (kill switch `.night_off`, ZeroBounce, Apollo >= 100 credits)
  → `reverify.sh --unverified` → `import_sweep_files.py --apply` (every READY TO ADD
  row of every `sweep_*.md` on the sheet, marked as a sweep find) →
  `backfill_websites.sh --limit 30 --apply` (Chrome
  finds missing websites and replaces brand-homepage or listing pages, sweep finds first,
  14-day rotation) → `verify_pool.py --apply --limit 400` → `--vouch-sweep-sites`
  → runs of 50
  (`pipeline.sh --run 50`, or `--resume` of a run a stop/the cutoff left unfinished;
  a resumed run doesn't count toward the 2 new runs) with `RUN_DEADLINE` = 8:00, so no
  batch starts that can't end by then → after each run: commit + push, then a headless
  Claude session researches the run's zero-contact venues (`NIGHT_DEEPDIVE.md`, phase
  RESEARCH) while the next run goes, `night_save.py` saves what it found under the
  save policy, commit + push → after the last run, one Claude session (phase FIX)
  fixes the scraper for what the pipeline missed, proves it with the recall benchmark,
  commits; `night_run.sh` reverts anything that breaks `health_check` → final push.
- A stop (credits, Chrome, preflight) ends the night and sets the app alert in
  `night_status.json` with the real reason (preflight's own FAIL line, not its
  summary); the stopped run resumes first next night (dropped on its 3rd stop that
  isn't the cutoff or Chrome). A run that never started leaves nothing to resume and
  doesn't count toward the 2 runs. An empty pool raises a "needs a sweep" alert. A
  launch outside 00:30–03:30 (the Mac was asleep at 1:00) is skipped with an alert.
- Chrome stops are tried again first: `CHROME_RETRIES` (3) times, `CHROME_RETRY_WAIT_S`
  (600 s) apart, while an hour of the window is left (Google blocking searches is not
  retried). The night needs Chrome to itself (Sep 30 2026, "we need to run alone"):
  `CHROME_ALONE_KILL=1` makes the scripts close another copy of Chrome that a program
  started (headless/automation flags) once they've waited for it (preflight 5 min,
  between venues and backfill lookups 10 min, a page 5 min); a copy a person
  started is never closed, it stops the run with a "close the other copy" alert.
- Files: `reports/runs/night-YYYYMMDD.log` (the night), `reports/runs/<RUN_ID>.log`
  (the run), `reports/runs/night-state.json` (resume target, runs waiting for a fix
  session), `<RUN_ID>.zero.json` / `.deepdive.json` / `.deepdive-saved.json` /
  `.deepdive.done`, `night-YYYYMMDD.fix-summary.json`.
- `./night_run.sh --check` = the credit/setup checks only (safe any time).
  `./night_run.sh --force` = a night now (still stops at the 8:00 cutoff).
  Pause: `touch .night_off`; resume: `rm .night_off`.
- Manual runs still work as below; `PIPELINE_REPORTS=1` or `./pipeline.sh --report
  RUN_ID` builds the old HTML report on demand, but nothing gates the app any more.

## 0. Preflight
- `./preflight.sh` — free and read-only. Checks python, every script parses
  (including embedded python), classifier and rules self-tests, the Apps Script
  backend and its version, ZeroBounce budget, the Apollo key, and Chrome with
  "Allow JavaScript from Apple Events". Any `FAIL` = fix it before running.
- The pipeline runs preflight itself at start and `--quick` between batches, and
  stops the run (resumable) if it fails.

## 1. Discovery (only when the pool is thin, or Alex asks)
- Pool check: `./build_batch.sh --total 50 --dry-run` prints how many eligible
  venues exist per bucket (fine dining, clubs, hotels, wine, wild cards).
- `./discover.sh --taste` (Chrome, Google Maps) or the WebSearch sweep procedure
  in memory ("sweep [city]"). `./sweep.sh --chrome "City ST"` is the Chrome-based
  variant, not the sweep procedure.
- New venues land as `needs_review`. They become batch-eligible (`untouched`)
  only when the website matches, city/state come from the real listing and are
  in DC/MD/VA, and the category is confident. Unknown category = `other`.
  The Google knowledge panel supplies the address, the Google category and the
  website button, and Google's "permanently closed" skips a venue outright.
- Good finds must not wait in needs_review for a manual review (Alex, Sep 26:
  "if they are good finds just run them"). Before planning every run:
  `/usr/bin/python3 verify_pool.py --apply` — re-checks needs_review venues
  (not parked, no contacts, not in a report or run ledger) by reading each venue's own website
  over plain HTTP (schema.org address/type/cuisine, the address in the footer)
  and promotes the verified ones. It NEVER opens Chrome. Preview without `--apply`.
- Sweep finds are always usable (Alex, Sep 29 2026: "everything on the sweep should be
  able to be used for you on the pipeline"). A venue whose `source` contains "sweep"
  skips build_batch's taste gates: category, skip words, prime evidence, taste floor,
  soft junk (chains, apartments, casual food) and location trust (a known sweep city
  beats a bad geocode). It is still ranked, prime venues first, and the hard rules
  stay: DC/MD/VA only, 2-hour radius, closed, motels/budget chains, adult/nightlife,
  thumbs-down, past gigs, venues or sites already worked. PA/DE sweep finds queue last. `verify_pool.py` trusts a
  sweep find's city and category once its own site answers (or walls plain HTTP).
  Rules live in `outreach_rules.is_sweep_find` / `HARD_JUNK_RX`.
- Every row under READY TO ADD in a `sweep_*.md` write-up gets on the sheet:
  `import_sweep_files.py` (run each night) adds the missing ones with source
  `sweep:<file>`, tags older rows found by other discovery with the note "Sweep find
  (<file>)" (which `is_sweep_find` also honours) and promotes their needs_review rows
  that have a website. On Sep 29, 45 finds (mostly Georgetown: Tudor Place, Dumbarton
  House, Kreeger Museum, il Canale...) had never reached the sheet.
- A sweep find without its own website can't run. Save the website with the venue.
  `save_websites.py FINDINGS.json [--apply]` writes researched websites (high
  confidence adds "Website checked DATE" to the notes, which lets a property page
  pass the name-match check); the night run's backfill finds the rest.
- Never start anything that drives Alex's Chrome (discover.sh, pipeline.sh,
  backfill_websites.sh, sweep.sh --chrome) without asking him first — he may be
  using the browser (Sep 26: "stop opening my fucking browser"). The night run
  (1:00–8:00) is the standing exception he set up on Sep 29.
- discover.sh exit codes: 1 setup error, 3 Chrome unreachable, 4 some searches
  failed (they'll be retried next time), 5 a pipeline run is using Chrome.

## 2. Plan the run
- `./build_batch.sh --total 50 --dry-run` — read the list. Prime venues first
  (clubs, fine dining, luxury/boutique hotels, wineries, wine bars), junk gated
  out, past gigs and thumbs-down venues excluded. Flag anything obviously wrong
  in the sheet instead of running it.
- The run command below builds the real plan itself; `--dry-run` is the preview.
- How picks are made (Sep 26 changes): the taste score weights objective quality
  (prestige brands/awards, Google review volume) over adjectives in notes, and
  marks down B&Bs / tiny inns and golf-only clubs. A bucket (clubs, wild cards...)
  fills its share only with strong venues (score >= 50); slots it can't fill well
  go to buckets that still have strong venues. Every likely pick's website is
  checked first; dead, parked or "permanently closed" sites are dropped.

## 3. Run (background)
- `RUN_ID=run-$(date +%Y%m%d-%H%M)`
- `RUN_ID=$RUN_ID nohup caffeinate -i ./pipeline.sh --run 50 >> reports/runs/$RUN_ID.log 2>&1 &`
  - Builds the plan (`reports/runs/plans/...`), registers each batch in the
    ledger, and logs everything to `reports/runs/$RUN_ID.log`.
  - Other modes: `--plan LATEST` (run an existing plan), `--batch FILE` (one
    batch of ≤8), `--resume [RUN_ID]` (re-run only unfinished venues, then
    continue the plan), `--report [RUN_ID]` (an HTML report on demand),
    `./pipeline.sh "Exact Venue Name"` or `VENUE_ID` (one venue).
- Poll every few minutes: `tail -5 reports/runs/$RUN_ID.log`.
- The run STOPS itself (exit 3, resumable) when Chrome fails, ZeroBounce is out
  (no credits, a cap, key/IP refused), Apollo has fewer than `APOLLO_MIN_CREDITS`
  (100) credits at a batch start or fails two venues in a row, two venues in a row
  fall back to curl-only or get blocked, two venues in a row time out, the
  between-batch preflight fails, or `RUN_DEADLINE` leaves no time for another batch
  (`BATCH_EST_MIN`, 45). The reason is in `reports/runs/$RUN_ID.stopped`. Fix the
  cause, then `./pipeline.sh --resume $RUN_ID`.
- No report, no manifest entry (Sep 29): nothing is hidden in the app.
- Each finished batch writes `reports/runs/$RUN_ID.batchN.done` (its venue_ids).

## 4. Miss audit — the night deep dive does it for zero-contact venues
At night, `NIGHT_DEEPDIVE.md` covers this for every venue that ended with no
usable email, and turns each scraper miss into a tested fix. For a manual run, or
when Alex asks for a full audit, do it by hand as below.
- For each venue in the finished batch, independent agents re-search it a
  different way: WebFetch the site (home, contact, about, events/private events,
  team/staff, footer), WebSearch "<venue> email", Apollo MCP (domain AND name),
  and the venue's Facebook/Instagram.
- Don't flag or deprioritize a venue for having no events program or no live
  music (Alex, Sep 26 2026: "Bishop's House has no events. that shouldnt stop
  you"). Pitch it anyway; vibe flags are for the wrong crowd (sports bar, dive
  bar, theater, deli), not for a missing events page.
- Anything real the pipeline didn't have goes in
  `reports/runs/$RUN_ID.misses.jsonl`, one line per item:
  `{"venue_id":..., "kind":"email|contact|social|contact_form", "value":...,
  "source_url":..., "pipeline_had":false, "cause_guess":...}`. A venue with
  nothing missed gets `{"venue_id":..., "kind":"audited"}`.
- Save real misses through the API (same save policy as above; `night_save.py
  RUN_ID` does it from a `<RUN_ID>.deepdive.json` findings file), then
  `./mark_step.sh --run miss_audit "<N venues audited, M misses>"`.
- Every miss with a cause is a bug to fix in the scraper.

## 5. Taste review
- `/usr/bin/python3 taste_review.py` — lists votes/feedback not yet in
  `taste_notes.md`, with each venue's score and whether it would be picked.
- Append the useful ones to `taste_notes.md`; if a pattern changes the profile,
  update `taste_score.py`. Then `/usr/bin/python3 taste_review.py --mark`.
- `./mark_step.sh --run taste_review "<N reviewed>"` (or BLOCKED "no new votes").

## 6. Gate (optional since Sep 29 — nothing waits on it)
- `./verify_run.sh $RUN_ID` — judges the run from evidence: the `[STEP]` lines,
  web-coverage files, the sheet, and the misses file. Last line is the verdict:
  `RUN CLEAN` or `RUN NOT CLEAN: N items need review (...)`.
- `failed`/`blocked` steps need a manual mark with evidence
  (`./mark_step.sh <venue_id> <step> done|BLOCKED "<evidence>"`); nothing else
  needs manual marks. Re-run until `MISSING: 0`.

## 7. Report — removed (Alex, Sep 29 2026: "get rid of reports")
- No HTML report, no manifest entry, no review tick in the app. The app shows
  new contacts right away, and `night_status.json` carries the night's alert and
  one-line summary. `reports/manifest.json` and the old reports stay as history
  (build_batch.sh and verify_pool.py still skip venues listed there, and any venue
  a run ledger `reports/runs/*.jsonl` registered).
- On demand only: `./pipeline.sh --report $RUN_ID` (or `PIPELINE_REPORTS=1` for a run).

## Data repair (only with Alex's OK)
- `/usr/bin/python3 repair_data.py` builds a read-only plan
  (`reports/repair/plan-<date>.md`). `--apply PLAN --only CAT` executes it with
  backups and read-back. Never run `--apply` without Alex's go-ahead.

## Where things are
- `night_run.sh`       the night (launchd 1:00 → `night_run.command`); `night_status.py` = app status,
                       `night_zero.py` = zero-contact list, `night_save.py` = saves deep-dive finds,
                       `NIGHT_DEEPDIVE.md` = the Claude session's instructions
- `pipeline.sh`        the run: steps 1–5 per venue, batches, stop rules (report only on demand)
- `site_discovery.py`  static website crawl (emails, people, forms, PDFs)
- `postcheck.sh`       second pass on zero-contact venues (saves under the same policy)
- `build_batch.sh`     plans runs; `taste_score.py` + `venue_classifier.py` + `venue_quality.py`
- `outreach_rules.py`  the shared save rules (apps_script.gs mirrors them)
- `preflight.sh`       pre-run checks; `verify_run.sh` = the gate; `mark_step.sh` = the ledger
- `chrome_guard.sh`    sourced by every Chrome-driving script: waits until Alex's Chrome is the
                       only copy running (night runs then close a program-started copy)
- `reverify.sh`        re-check unverified contacts after a ZeroBounce top-up
- `save_websites.py`   write researched websites (sweep finds) with read-back
- `import_sweep_files.py` sweep write-ups -> sheet (add missing, tag, promote)
- `sweep_coverage.py`  where every sweep find stands (queue, worked, waiting, left out, why)
- `repair_data.py`     plan and apply sheet repairs
- `taste_review.py`    unprocessed votes → taste_notes.md
- `discover.sh`        Google Maps discovery; `sweep.sh --chrome` = Chrome sweep
- `tests/`             `website_recall/` (recall benchmark), gate/guard/reverify tests
- `reports/runs/`      per run: `.log`, `.jsonl` ledger, `.batchN.json/.done`,
                       `.misses.jsonl`, `.report-state.json`; keep them
- `learnings.md`       what a good venue looks like; `notes.md` = history
- Backend deploys: `../.clasp/gas_deploy.sh gigoutreach` (never paste by hand)
