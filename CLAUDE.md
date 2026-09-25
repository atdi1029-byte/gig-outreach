# Gig Outreach — Runbook

This file is the one source of truth for how a run works. The home CLAUDE.md and
memory notes point here; if they disagree with this file, this file wins.

A run = up to ~50 venues, split into batches of at most 8, under one RUN_ID, with
one report. The goal is a run Alex can accept without reviewing it by hand: the
run proves what it searched, lists what it missed, and ends with a verdict.

## Rules that override everything else
- `python3` on PATH is broken on this Mac (Intel-only build). Scripts fix this
  themselves via `env_check.sh`; in your own commands use `/usr/bin/python3`.
- Never skip a step silently. If something can't run (Chrome closed, credits out,
  site down), the run reports it as `failed`/`blocked`, or you record it with
  `./mark_step.sh <venue_id> <step> BLOCKED "<reason>"`. Blocked is allowed;
  unrecorded is not.
- Never summarize from memory. The report is generated from the run log, the
  sheet and `verify_run.sh`; don't hand-write numbers.
- Never `cat` a log. `tail` and `grep` only.
- Don't edit `pipeline.sh` during a run. Don't run two scripts that drive Chrome
  at once (pipeline, discover, sweep --chrome refuse while the pipeline holds
  `/tmp/pipeline.lock.d`).
- Do not send anything. Sending is manual, always, from the app.
- Save policy (enforced by the code and the backend):
  - An email is saved only if it's on the venue's own domain, or a free-mail/ISP
    address linked to the venue (mailto on its site, or venue words in it).
    Off-domain = rejected and listed in the report, never saved.
  - Role inboxes (info@, events@, ...) are saved only with a real person's name
    attached (e.g. "Liz McQuay, Events Manager → events@"), as `verified=role`,
    and never cost a ZeroBounce credit.
  - Personal inboxes go through ZeroBounce: `valid` is saved. While ZeroBounce
    has no credits, they're saved as `verified=unverified` (shown in the app
    with a badge). After a top-up: `./reverify.sh --unverified --dry-run`, then
    `./reverify.sh --unverified --limit N`.
  - Names are never invented from email local parts (first.last is the only
    exception). Masked Apollo names (`Mc***y`) are enriched or skipped.
  - Existing Facebook/Instagram/contact-form values on the sheet are never
    overwritten. Venue status is never demoted.
- Target area: DC, MD, VA only; max ~2 hour drive from Pasadena, MD.

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
- discover.sh exit codes: 1 setup error, 3 Chrome unreachable, 4 some searches
  failed (they'll be retried next time), 5 a pipeline run is using Chrome.

## 2. Plan the run
- `./build_batch.sh --total 50 --dry-run` — read the list. Prime venues first
  (clubs, fine dining, luxury/boutique hotels, wineries, wine bars), junk gated
  out, past gigs and thumbs-down venues excluded. Flag anything obviously wrong
  in the sheet instead of running it.
- The run command below builds the real plan itself; `--dry-run` is the preview.

## 3. Run (background)
- `RUN_ID=run-$(date +%Y%m%d-%H%M)`
- `RUN_ID=$RUN_ID nohup caffeinate -i ./pipeline.sh --run 50 >> reports/runs/$RUN_ID.log 2>&1 &`
  - Builds the plan (`reports/runs/plans/...`), registers each batch in the
    ledger, and logs everything to `reports/runs/$RUN_ID.log`.
  - Other modes: `--plan LATEST` (run an existing plan), `--batch FILE` (one
    batch of ≤8), `--resume [RUN_ID]` (re-run only unfinished venues, then
    continue the plan), `--report [RUN_ID]` (regenerate the report),
    `./pipeline.sh "Exact Venue Name"` or `VENUE_ID` (one venue).
- Poll every few minutes: `tail -5 reports/runs/$RUN_ID.log`.
- The run STOPS itself (exit 3, resumable) when Chrome fails, Apollo credits run
  out, two venues in a row fall back to curl-only or get blocked, two venues in
  a row time out, or the between-batch preflight fails. Fix the cause, then
  `./pipeline.sh --resume $RUN_ID`. ZeroBounce running out does NOT stop it.
- At each batch start the pipeline writes the report stub + manifest entry
  (`status: running`) so the app hides those venues. The app only sees what's
  on GitHub: commit and push `reports/manifest.json` and the stub report right
  after each batch starts.
- Each finished batch writes `reports/runs/$RUN_ID.batchN.done` (its venue_ids).

## 4. Miss audit — after each batch
The pipeline proves what it searched; the miss audit checks what it missed.
- For each venue in the finished batch, independent agents re-search it a
  different way: WebFetch the site (home, contact, about, events/private events,
  team/staff, footer), WebSearch "<venue> email", Apollo MCP (domain AND name),
  and the venue's Facebook/Instagram.
- Anything real the pipeline didn't have goes in
  `reports/runs/$RUN_ID.misses.jsonl`, one line per item:
  `{"venue_id":..., "kind":"email|contact|social|contact_form", "value":...,
  "source_url":..., "pipeline_had":false, "cause_guess":...}`. A venue with
  nothing missed gets `{"venue_id":..., "kind":"audited"}`.
- Save real misses through the API (same save policy as above), then
  `./mark_step.sh --run miss_audit "<N venues audited, M misses>"`.
- Every miss with a cause is a bug to fix in the scraper. The miss rate per run
  is how we know when Alex can stop reviewing.

## 5. Taste review
- `/usr/bin/python3 taste_review.py` — lists votes/feedback not yet in
  `taste_notes.md`, with each venue's score and whether it would be picked.
- Append the useful ones to `taste_notes.md`; if a pattern changes the profile,
  update `taste_score.py`. Then `/usr/bin/python3 taste_review.py --mark`.
- `./mark_step.sh --run taste_review "<N reviewed>"` (or BLOCKED "no new votes").

## 6. Gate
- `./verify_run.sh $RUN_ID` — judges the run from evidence: the `[STEP]` lines,
  web-coverage files, the sheet, and the misses file. Last line is the verdict:
  `RUN CLEAN` or `RUN NOT CLEAN: N items need review (...)`.
- `failed`/`blocked` steps need a manual mark with evidence
  (`./mark_step.sh <venue_id> <step> done|BLOCKED "<evidence>"`); nothing else
  needs manual marks. Re-run until `MISSING: 0`.

## 7. Report
- The pipeline generates `reports/<date>.html` and the manifest entry
  automatically after each batch (with `venue_ids`, verdict, coverage, misses).
- After the miss audit and manual marks: `./pipeline.sh --report $RUN_ID`.
- Write the taste review between `<!-- TASTE_REVIEW:BEGIN -->` and
  `<!-- TASTE_REVIEW:END -->`, and any session notes between the SESSION_NOTES
  markers; both survive regeneration.
- `./mark_step.sh --run report "reports/<file>.html"`, then
  `./verify_run.sh $RUN_ID --embed-report reports/<file>.html`.
- Commit and push the report, `reports/manifest.json` and
  `reports/runs/$RUN_ID.report-state.json`.
- Tell Alex: venues processed, contacts found, the verdict line, and anything
  that looked wrong in the plan.

## Data repair (only with Alex's OK)
- `/usr/bin/python3 repair_data.py` builds a read-only plan
  (`reports/repair/plan-<date>.md`). `--apply PLAN --only CAT` executes it with
  backups and read-back. Never run `--apply` without Alex's go-ahead.

## Where things are
- `pipeline.sh`        the run: steps 1–5 per venue, batches, stop rules, report
- `site_discovery.py`  static website crawl (emails, people, forms, PDFs)
- `postcheck.sh`       second pass on zero-contact venues (saves under the same policy)
- `build_batch.sh`     plans runs; `taste_score.py` + `venue_classifier.py` + `venue_quality.py`
- `outreach_rules.py`  the shared save rules (apps_script.gs mirrors them)
- `preflight.sh`       pre-run checks; `verify_run.sh` = the gate; `mark_step.sh` = the ledger
- `reverify.sh`        re-check unverified contacts after a ZeroBounce top-up
- `repair_data.py`     plan and apply sheet repairs
- `taste_review.py`    unprocessed votes → taste_notes.md
- `discover.sh`        Google Maps discovery; `sweep.sh --chrome` = Chrome sweep
- `tests/`             `website_recall/` (recall benchmark), gate/guard/reverify tests
- `reports/runs/`      per run: `.log`, `.jsonl` ledger, `.batchN.json/.done`,
                       `.misses.jsonl`, `.report-state.json`; keep them
- `learnings.md`       what a good venue looks like; `notes.md` = history
- Backend deploys: `../.clasp/gas_deploy.sh gigoutreach` (never paste by hand)
