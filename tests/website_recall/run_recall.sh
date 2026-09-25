#!/bin/bash
# Website recall benchmark: does pipeline.sh's website step find what Alex finds by hand?
#
# Runs the REAL step1_website() from a pipeline.sh against the venues in benchmark.json, with
# every side effect stubbed (no real Chrome, no Apps Script writes, no ZeroBounce/Apollo) and
# every web request answered from saved snapshots (snapshots/<venue_id>/), then reports recall:
# found X of Y expected items, per miss type, plus each miss and whether its page was visited.
#
# Both website paths are exercised:
#   sd      site_discovery.py static-crawl on its own (same bounds as the pipeline), to grade the
#           crawler separately from how pipeline.sh consumes it (HEAD vs working tree: --git-rev HEAD).
#   chrome  osascript calls go to a HEADLESS Chrome (own temp profile, CDP), so the scrape JS
#           really runs on the page (rendered-DOM snapshot, page scripts off);
#   curl    Chrome JS unavailable (the production failure mode), so the curl fallbacks run.
#
# usage:
#   tests/website_recall/run_recall.sh                         # working-tree pipeline.sh, offline
#   tests/website_recall/run_recall.sh --git-rev HEAD          # baseline: HEAD pipeline.sh + site_discovery.py
#   tests/website_recall/run_recall.sh --pipeline /path/to/pipeline.sh [--support-dir DIR]
# options:
#   --modes chrome,curl,sd  which paths to run (default all three)
#   --venues ID,ID          subset of benchmark venues
#   --net replay            offline from snapshots (default). A URL the pipeline asks for that was never
#                           captured answers 404 and is counted per venue as "uncaptured".
#   --net record            like replay, but fetch + save anything missing (polite: <=1 req/s per site)
#   --page-level            also run the scrape JS directly on each item's own page (extractor only)
#   --workers N             parallel venue runs (default 4)
#   --score-only RUN_DIR    re-score an existing run
# output: tests/website_recall/runs/<stamp>-<label>/{report.txt,results.json,<venue>/<mode>/...}
#   report.txt: recall per mode, per kind/priority/type, per venue (js_err = scrape-JS exceptions,
#   uncaptured = URLs this pipeline asked for that the store doesn't have; re-run with --net record
#   to fetch them), and every miss with its type and which paths visited its page.
# other tools (lib/):
#   compare.py RUN_A RUN_B          item-level diff of two runs (gained / lost)
#   capture.py                      make sure every benchmark item's own page is in the store
#   store_health.py                 per-venue status counts in the store (spots sites that blocked us)
# benchmark.json items: kind email|person|contact_form, value, page, also_on, how (miss type), all_hows,
#   priority, name/title (staff pairing), off_domain, accept/providers (forms).
# Needs: node (>=22, built-in WebSocket), Google Chrome, /usr/bin/python3 with requests + bs4.
# Never touches the real Chrome profile, the sheet, or any paid API.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 "$HERE/lib/runner.py" "$@"
