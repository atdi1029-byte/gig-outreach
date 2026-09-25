# Website recall benchmark

Does `pipeline.sh`'s website step find what Alex finds by hand on a venue's own site?
This harness answers that with a number: found X of Y known items, per miss type, and every miss with
the page it sits on and whether the pipeline ever visited that page.

## Run it

```bash
cd ~/Documents/Code/Claude/Email
tests/website_recall/run_recall.sh --git-rev HEAD                 # baseline: HEAD pipeline.sh + HEAD site_discovery.py
tests/website_recall/run_recall.sh                                # working-tree pipeline.sh + site_discovery.py
tests/website_recall/run_recall.sh --pipeline /path/to/pipeline.sh [--support-dir DIR]
```

Options: `--modes chrome,curl,sd` (default all three), `--venues ID,ID`, `--workers N` (default 4),
`--page-level` (also run the Chrome scrape JS directly on each email item's own page), `--net replay|record`,
`--score-only RUN_DIR`, `--label NAME`, `--out DIR`.
A full run of 59 venues takes about 15-20 minutes with 4 workers; `--venues` for a quick check.

Output goes to `runs/<stamp>-<label>/`: `report.txt` (recall overall, per kind / priority / access / miss type,
per venue, then every miss), `results.json` (one record per item and mode), and per venue and mode the raw
harness output (`step1.log`, `vp.tsv` = what went to verify_and_push, `cand.tsv` = record_candidate,
`api.jsonl` = Apps Script calls such as update_venue contact_form, `trace.jsonl` = every page each path fetched).

Compare two runs item by item: `/usr/bin/python3 tests/website_recall/lib/compare.py RUN_A RUN_B`.

Needs node 22+ (built-in WebSocket), Google Chrome, and `/usr/bin/python3` with requests + bs4.

## What it runs

The REAL `step1_website()` from the pipeline.sh you point it at. `lib/extract_pipeline.py` pulls every function
definition out of the file (bash itself decides where each function ends, so heredocs with column-0 braces are
fine), rewrites `/tmp/pipeline_*` paths into a per-run work dir, and `lib/run_step1.sh` calls `step1_website`
with the C1 globals set. It works for the old inline scrape-JS heredoc and for `write_scrape_js()`.

The three paths, graded separately:

| mode | what happens |
|---|---|
| `chrome` | `osascript` calls go to a headless Chrome over CDP (`lib/chromectl.mjs`, its own temp profile), so the scrape JS really runs on the page |
| `curl` | Chrome JS is "off" (osascript execute fails, like production since June), so the curl fallbacks run |
| `sd` | `site_discovery.py static-crawl` on its own, same bounds as the pipeline (40 pages, depth 3), graded on contacts[], name_hint, people[], contact_forms[] |

Side effects are all stubbed: `lib/bin/osascript` and `lib/bin/curl` sit first on PATH, python `requests` is
patched by `lib/py/sitecustomize.py`, the Apps Script URL is fake (update_venue/add_contact are logged, never
sent), and `verify_and_push` / `record_candidate` / `log` only write files. It never drives Alex's Chrome,
never writes the sheet, never spends ZeroBounce or Apollo credits.

## Offline replay

Every web request is answered from `snapshots/<venue_id>/` (gzipped, content-addressed; ~540 MB, git-ignored).
Raw responses are stored per client (`curl` UA, python `requests` with a Chrome UA) and Chrome pages as the
rendered DOM after scripts ran (served back with page scripts disabled). A URL a new pipeline version asks for
that was never recorded answers 404 and is counted per venue as `uncaptured` in the report. To fill those,
run once with `--net record`: stored pages are reused, only missing ones are fetched, at most 1 request per
second per site. Use it sparingly: womansclubofbethesda.org started answering 403 after repeated recording.
`lib/store_health.py [--venues IDS] [--drop-errors]` shows per-venue status counts (flags sites that blocked
us) and can drop 403/429 entries so a later record run refetches them.

## The benchmark (`benchmark.json`)

59 venues, 151 items that sit on the venue's own website (105 emails, 34 contact forms, 12 named people with
no email on the site). Sources: sheet contacts Alex or a manual check found outside the pipeline, the last
three runs' venues whose website step found 0-1 contacts, and web-coverage files with no website contact.
Each site was crawled and rendered by hand-style inspection; every item carries:

- `kind` email | person | contact_form; `value` (email, or form URL); `name`/`title` for staff pairings
- `page` (where it appears, easiest form first) and `also_on` (other pages); `n_pages`
- `how` = the miss type used in the report: mailto, plain_text, cloudflare_attr (data-cfemail),
  cloudflare_href (`/cdn-cgi/l/email-protection#...` only), entity_encoded, script_json (only inside scripts or
  attributes), obfuscated_text (`name[at]domain`), js_rendered (only after scripts run), native_form,
  third_party_form (Tripleseat, HoneyBook, Wufoo, PerfectVenue ...), person_no_email; `all_hows` lists every form
- `priority` (high = a named person or an events/catering/rentals/owner mailbox), `off_domain`, venue `access`
  (`browser_only` = the site 403s curl and python)
- forms: `accept` (any of these pages counts) and `provider_host`

An item counts as found when the website step passes the email to verify_and_push or record_candidate
(before any save policy), passes the person's name, or saves a matching contact_form. Names attached to found
staff emails are reported separately.

Curation lives in the sprint dir (`Email-fix-sprint/UW/spec.json`, `UW/tools/build_benchmark.py`, and the
inspection data in `UW/inspect/`); `lib/capture.py` makes sure each item's own page is in the store.

## Results (Sep 25, replay)

| build | chrome | curl | sd (standalone) |
|---|---|---|---|
| HEAD pipeline.sh + HEAD site_discovery.py | 108/151 (72%) | 107/151 (71%) | 76/151 (50%) |
| U1/pipeline.sh (installed 07:39) + working-tree site_discovery.py | 148/151 (98%) | 142/151 (94%) | 134/151 (89%) |

See `Email-fix-sprint/UW/MISS_TYPES.md` for the miss types, examples and what is still missed.
