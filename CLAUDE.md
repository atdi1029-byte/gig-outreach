# Outreach Run — RUNBOOK

This is the contract for a "full run". `run_ledger.py` enforces it: a run
is done when `./verify_run.sh <run_id>` prints **VERIFY PASS**. Nothing
else counts — not a summary, not "looks complete", not memory of having
done it earlier.

## 0. Before anything

```bash
cd ~/email-outreach            # the project dir — build_batch.sh imports from it
./diag_chrome.sh               # once per session: Chrome must return 2 on Test 1
python3 taste_backtest.py      # only if taste_score.py / venue_classifier.py changed
```

## 1. Discovery (optional, only when the pool is thin)

```bash
./build_batch.sh 20 --dry-run  # look at "above 45: N". If N < 30, discover first:
./sweep.sh "Town ST"           # or ./discover.sh --taste
```
Manual sweeps (the `sweep_*.md` files) must put the Google type, price,
rating and review count into `notes` in the discover.sh format:
`Google Maps 'French restaurant'. Price: $$$. 4.6★ (450 reviews).`
Otherwise the scorer has nothing to rank on and the venue gets a
low-signal score.

## 2. Start the run (pipeline runs in the BACKGROUND)

```bash
./run.sh start 8               # builds batch → ledger → nohup pipeline.sh
./run.sh status                # poll every few minutes; never block on it
./run.sh wait                  # or block in a separate long-running call
```
`run.sh start` refuses to launch if a pipeline is already running or the
batch is empty. Batch of 8 ≈ 45–70 min.

## 3. When the pipeline finishes

```bash
./run.sh finish                # from-log + postcheck + prints what's still owed
```

## 4. Manual checks — EVERY venue in the batch, no exceptions

For each venue, in Chrome, then record it. A step you did not do is a
step you do not mark. A step you could not do is marked `--status skip`
with the reason.

| step | what it means | mark |
|---|---|---|
| `contact_pages` | Read homepage, /contact (or /about, /private-events), footer. Note emails, forms, names. | `./mark_step.sh RUN_ID VID contact_pages --evidence "homepage+/contact: events@…, form"` |
| `fb_checked` | Facebook About → Contact info. Email? Message button? | `… fb_checked --evidence "fb: info@… found"` or `--status skip --evidence "no page"` |
| `ig_checked` | Instagram bio / contact button. | `… ig_checked --evidence "@handle, no email"` |
| `linkedin_chrome` | LinkedIn People search for the venue name, first 3 pages, **Current** employees only. Count them. | `… linkedin_chrome --evidence "7 current employees seen; targets: Jane Doe (Events Mgr)"` |
| `apollo_enrich` | Apollo enrichment for the named people found above (API or MCP). | `… apollo_enrich --evidence "2 enriched, 1 verified"` or `"none to enrich"` |
| `open_status` | Is it open? Google/website/recent reviews. | `… open_status --evidence "open; reviews this month"` |
| `verdict` | LEGIT / JUNK / CLOSED / WASTED + one line. | `… verdict --evidence "LEGIT — French bistro, GM Eric Kole"` |

Run-level:
```bash
./mark_step.sh RUN_ID RUN taste_review --evidence "3 new votes processed → taste_notes.md"
./mark_step.sh RUN_ID RUN report_generated --evidence "reports/2026-09-06_…html + pipeline-report-….md"
```

## 5. The gate

```bash
./verify_run.sh RUN_ID
```
- **VERIFY FAIL** → it prints exactly which venue/step is missing, with
  the command to mark it. Do the work, mark it, run verify again.
- **VERIFY PASS** → now write the report. Paste the verify matrix into
  the report.

## Definition of done (what the ledger checks)

Per venue: `website social apollo linkedin status_set pipeline_done`
(automated, from pipeline.log) **and** `contact_pages fb_checked
ig_checked linkedin_chrome apollo_enrich open_status verdict` (manual).
Run: `batch_built pipeline_complete postcheck taste_review report_generated`.

If the pipeline itself skipped a venue (closed / DNS / status), the
automated steps are waived but `open_status` and `verdict` are still owed.

## Rules for the agent driving this

1. Never run `pipeline.sh` in a foreground tool call. Use `run.sh start`
   and poll. If a run died (`run.sh wait` says "exited WITHOUT a BATCH
   COMPLETE marker"), re-run the unfinished venues with
   `./pipeline.sh --batch <remaining.json>` (also backgrounded) — do not
   report them as done.
2. Never write a report before `verify_run.sh` passes.
3. Never mark a step you did not perform in this session. Evidence must
   be specific (a name, an email, a count, a URL) — "checked" is not evidence.
4. Never edit `taste_score.py` / `venue_classifier.py` without running
   `taste_backtest.py` and pasting the Spearman line into the commit/report.
5. Never add venues from a sweep without Google type / price / rating /
   reviews in `notes`.
6. Never `--smart-picks` (disabled) and never build a batch from anything
   but `build_batch.sh`.

## Files that matter

| file | role |
|---|---|
| `run.sh` | start / status / wait / finish a run |
| `run_ledger.py`, `mark_step.sh`, `verify_run.sh` | the ledger + gate |
| `build_batch.sh` | picks venues (taste v2) |
| `taste_score.py`, `venue_classifier.py` | the ranking model |
| `taste_backtest.py` | proves the model ranks your past gigs right |
| `pipeline.sh` | per-venue automation (website → social → Apollo → LinkedIn) |
| `postcheck.sh` | zero-contact venue audit |
| `diag_chrome.sh` | why Chrome scraping is failing |
| `reports/runs/<run_id>.json` | the ledger for one run |
