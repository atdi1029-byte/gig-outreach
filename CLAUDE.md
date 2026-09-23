# Gig Outreach — Runbook

Read this before doing anything in this repo. A "pipeline run" means ALL steps
below, in order, for EVERY venue in the batch. The run is not done until
`./verify_run.sh` prints `MISSING: 0`.

## First command of every session
`./verify_run.sh` — if it prints MISSING > 0, you are resuming that run, not
starting a new one. Finish it before building another batch.

## Rules that override everything else
- Never skip a step silently. If a step cannot run (Chrome closed, credits out,
  site down), record it with `./mark_step.sh <venue_id> <step> BLOCKED "<reason>"`
  and keep going. Blocked is allowed; unrecorded is not.
- Never summarize from memory. The report is written from `verify_run.sh` output
  and the run log, not from what you remember doing.
- Long commands run in the background (see step 3). Do not hold a tool call open
  for more than a few minutes.
- Never `cat` a log. `tail -20` and `grep` only. The ledger and `verify_run.sh`
  are the source of truth, not what you remember from earlier in the chat.
- Every `mark_step.sh` call needs a note with evidence: a count, a URL, or a
  finding ("no FB page", "closed 2025", "login wall"). The script rejects bare
  marks. If you didn't open the page, the honest mark is BLOCKED with why.
- A step the pipeline ran but that came back empty or degraded is NOT done.
  `verify_run.sh` shows these as `!` and in DEGRADED: LinkedIn empty page, Apollo
  matched a different company, website scraped by curl only. Each needs your
  manual pass (with a count) or a BLOCKED with the reason.
- Do not edit `pipeline.sh` during a run.
- Do not send anything. Sending is manual, always.

## 0. Preflight (every run)
- [ ] `cd` into this repo. Every script assumes it is run from here.
- [ ] Chrome is open, logged into LinkedIn, and View > Developer >
      "Allow JavaScript from Apple Events" is ON. Test:
      `osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.title"'`
      If this returns empty or "missing value", STOP and tell Alex.
- [ ] `python3 zerobounce_guard.py budget` — note credits. Note Apollo credits.
- [ ] `bash -n pipeline.sh build_batch.sh postcheck.sh` — all pass.
- [ ] `RUN_ID=run-$(date +%Y%m%d-%H%M)` — use this ID for the whole run.
- [ ] The pipeline probes Chrome itself and logs `[CHROME] WARNING` if JavaScript
      from Apple Events is off. If that line appears in the run log, stop and tell
      Alex before continuing — every website scrape will be curl-only until fixed.

## 1. Discovery (only when the untouched pool is thin, or Alex asks)
- `./discover.sh --taste` or `./sweep.sh "City ST"`.
- New venues land as `needs_review`. Verify each website is the venue's own site
  before promoting to `untouched`. Category must come from the classifier or the
  Google type, not a guess; unknown = `other`, never `restaurant`.

## 2. Build the batch
- `./build_batch.sh 8 --dry-run` — read the list. Anything that is obviously not
  a classical-guitar venue gets flagged in the sheet, not pipelined.
- `./build_batch.sh 8` — writes `/tmp/pipeline_batch.json`.
- `./mark_step.sh --batch /tmp/pipeline_batch.json $RUN_ID` — registers the
  venues in the run ledger (`reports/runs/$RUN_ID.jsonl`) and sets it as the
  current run, so later `mark_step.sh` calls don't need the ID.

## 3. Run the automated pipeline (background)
- `nohup caffeinate -i ./pipeline.sh --batch /tmp/pipeline_batch.json > reports/runs/$RUN_ID.log 2>&1 &`
- Poll every few minutes: `tail -5 reports/runs/$RUN_ID.log`
- Done when the log contains `=== BATCH COMPLETE ===` AND postcheck has finished.
  If the process died, note which venues have no `DONE:` line — they are not
  finished; re-run them with `./pipeline.sh "Venue Name"`.

## 4. Manual checks — every venue in the batch, no exceptions
For each venue, in Chrome, and mark each one with `./mark_step.sh`:
- `web`      homepage, /contact, /about, /events, footer — emails, names, contact form
- `fb`       Facebook page > About > Contact info
- `ig`       Instagram profile — bio email, contact button
- `linkedin` LinkedIn people search for the venue name, "Current" employees only,
             first 3 pages. Target events/catering/sales/GM/owner titles. The note
             must have a count ("7 people, 2 relevant"). If LinkedIn shows a login
             wall or the search limit, mark BLOCKED "login wall" — never done.
- `apollo`   Apollo enrich for any named person found with no email
- `status`   Confirm the venue is open (not closed, renovating, or renamed)
- `contacts` Every found email is added via the app/API and ZeroBounce-verified;
             named people without an email are added as pending contacts.

## 5. Taste review
- Pull new `venue_vote` / `venue_feedback` since the last run.
- Append each to `taste_notes.md` (quote, extracted signals, action taken).
- If a pattern changes the profile, update `taste_score.py` and re-run
  `./rescore_pool.sh --apply`.
- `./mark_step.sh --run taste_review` (or `BLOCKED "no new votes"` — still record it).

## 6. Gate — definition of done
- `./verify_run.sh $RUN_ID`
- It checks evidence, not marks: the run log, the web-coverage files, and the
  sheet's contact counts. It lists every venue x step that is missing or
  contradicted. Fix or mark BLOCKED, then re-run until it prints `MISSING: 0`.
  Do not proceed to step 7 before that.
- DEGRADED items don't block, but they go in the report word for word.

## 7. Report
- Generate the HTML report and update `reports/manifest.json`
  (include `venue_ids` for every venue in the batch).
- Write `pipeline-report-<date>.md` using the sections from previous reports:
  Overview table, per-venue results, key wins, wasted/flagged, data corrections,
  Apollo summary, taste review, running total.
- `./mark_step.sh --run report`, then paste the final `verify_run.sh` output at
  the bottom of the report.
- Tell Alex: venues processed, contacts found, anything BLOCKED, anything that
  looked wrong in the batch selection.

## Where things are
- `pipeline.sh`        automated per-venue steps 1–5; log in `pipeline.log`
- `build_batch.sh`     picks venues; uses `taste_score.py` + `venue_classifier.py`
- `postcheck.sh`       second pass on zero-contact venues
- `discover.sh`        Google Maps discovery; `sweep.sh` = one city, all types
- `rescore_pool.sh`    re-score all untouched venues in the sheet
- `learnings.md`       what a good venue looks like — read before judging a batch
- `mark_step.sh`       write to the run ledger; `verify_run.sh` = the gate
- `reports/runs/`      one `.jsonl` ledger + one `.log` per run; keep them
- `notes.md`           project history; not a checklist
