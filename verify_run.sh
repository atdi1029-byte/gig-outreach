#!/bin/bash
# =============================================================
# verify_run.sh — definition of done for a pipeline run
#
# Reads:
#   reports/runs/<RUN_ID>.jsonl   ledger written by mark_step.sh
#   reports/runs/<RUN_ID>.log     stdout of pipeline.sh (the nohup target)
#   reports/web-coverage/<id>.json crawl coverage the pipeline writes per venue
#   the sheet (contact counts)     via ?action=venue_detail (skip: --no-sheet)
#
# For every registered venue it checks EVIDENCE, not marks:
#   automated steps (log): started, step1, step2, step3, step4, done
#     - step1 records the scrape method (chrome / curl-only)
#     - step3 fails on "[APOLLO MISMATCH]" (wrong company)
#     - step4 fails on an empty/walled LinkedIn page — that is not "no staff"
#   manual steps (ledger): web fb ig linkedin apollo status contacts
#     - every mark already carries a note with evidence (mark_step enforces it)
#     - a failed automated step is satisfied only by a manual mark that
#       addresses it: linkedin BLOCKED mentioning wall/quota/login, or a
#       manual linkedin search done with a count; apollo done/BLOCKED with a note
#   contacts: if the sheet shows 0 contacts, "contacts: done" is rejected
#
# Exit 0 only when MISSING: 0. DEGRADED items don't block but go in the report.
#
# Usage: ./verify_run.sh [RUN_ID] [--json] [--no-sheet]
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="${SCRIPT_DIR}/reports/runs"
PIPELINE_LOG="${SCRIPT_DIR}/pipeline.log"
COVERAGE_DIR="${SCRIPT_DIR}/reports/web-coverage"
APPS_URL=""
[ -f "${SCRIPT_DIR}/.env" ] && APPS_URL=$(grep -E '^APPS_SCRIPT_URL=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")

python3 - "$RUNS_DIR" "$PIPELINE_LOG" "$COVERAGE_DIR" "$APPS_URL" "$@" <<'PY'
import json, os, re, sys, subprocess

runs_dir, pipeline_log, coverage_dir, apps_url = sys.argv[1:5]
args = sys.argv[5:]
want_json = '--json' in args
no_sheet = '--no-sheet' in args
args = [a for a in args if not a.startswith('--')]

MANUAL_STEPS = ['web', 'fb', 'ig', 'linkedin', 'apollo', 'status', 'contacts']
AUTO_STEPS = ['started', 'step1', 'step2', 'step3', 'step4', 'done']
RUN_STEPS = ['batch_complete', 'postcheck', 'taste_review', 'report']


def die(msg):
    print(f"[verify_run] ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


rid = args[0] if args else os.environ.get('RUN_ID', '').strip()
if not rid:
    cur = os.path.join(runs_dir, 'CURRENT')
    if os.path.exists(cur):
        rid = open(cur).read().strip()
if not rid:
    die("no run id. Pass one, set RUN_ID, or register a batch with mark_step.sh --batch")

ledger_file = os.path.join(runs_dir, f"{rid}.jsonl")
run_log = os.path.join(runs_dir, f"{rid}.log")
if not os.path.exists(ledger_file):
    die(f"no ledger for {rid} ({ledger_file})")

# ---------------------------------------------------------------- ledger
entries = []
for line in open(ledger_file):
    line = line.strip()
    if line:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass

venues, order = {}, []
for e in entries:
    if e.get('step') == 'registered' and e.get('venue_id'):
        vid = e['venue_id']
        if vid not in venues:
            order.append(vid)
        venues[vid] = {'name': e.get('venue_name', ''), 'manual': {}, 'auto': {},
                       'skipped': '', 'web_method': '', 'apollo': '', 'linkedin': '',
                       'emails_line': '', 'coverage': False, 'sheet_contacts': None}
if not venues:
    die(f"run {rid} has no registered venues")

run_steps = {}
for e in entries:
    if e.get('type') == 'venue' and e.get('venue_id') in venues and e.get('step') in MANUAL_STEPS:
        venues[e['venue_id']]['manual'][e['step']] = (e.get('status', 'done'), e.get('note', ''))
    elif e.get('type') == 'run' and e.get('step') in RUN_STEPS:
        run_steps[e['step']] = (e.get('status', 'done'), e.get('note', ''))

# ---------------------------------------------------------------- log
warnings, log_lines = [], []
if os.path.exists(run_log):
    log_lines = open(run_log, errors='ignore').read().split('\n')
elif os.path.exists(pipeline_log):
    all_lines = open(pipeline_log, errors='ignore').read().split('\n')
    starts = [i for i, l in enumerate(all_lines) if '=== Pipeline started' in l]
    if starts:
        log_lines = all_lines[starts[-1]:]
    warnings.append(f"run log {run_log} not found — using the LAST block of pipeline.log, "
                    f"which may belong to another run. Automated results are unverified.")
else:
    warnings.append("no run log and no pipeline.log — automated steps cannot be verified")

name_to_vid = {v['name'].strip().lower(): vid for vid, v in venues.items() if v['name']}
ts_re = re.compile(r'^\d{2}:\d{2}:\d{2} ')
hdr_re = re.compile(r'#{5,} VENUE \[\d+/\d+\]: (.+?) #{5,}')
pipe_re = re.compile(r'^\s*PIPELINE: (.+?) \(([^)]+)\)\s*$')
done_re = re.compile(r'^\s*DONE: (.+?) \|')
emails_re = re.compile(r'Emails: (\d+) \| FB: (\S+) \| IG: (\S+) \| Contact Form: (\S+)')

current = None
chrome_warning = False
batch_complete = postcheck_started = postcheck_done = False

for raw in log_lines:
    text = ts_re.sub('', raw).rstrip()
    if '[CHROME] WARNING' in text:
        chrome_warning = True
    m = hdr_re.search(text)
    if m:
        current = name_to_vid.get(m.group(1).strip().lower())
        if current:
            venues[current]['auto']['started'] = True
        continue
    m = pipe_re.match(text)
    if m:
        vid = m.group(2).strip()
        current = vid if vid in venues else name_to_vid.get(m.group(1).strip().lower(), current)
        if current:
            venues[current]['auto']['started'] = True
        continue
    if current:
        v = venues[current]
        if 'STEP 1: Website Scrape' in text:
            v['auto']['step1'] = True
        elif '[CURL FALLBACK] Success' in text:
            v['web_method'] = 'curl'
        elif 'Both Chrome and curl' in text:
            v['web_method'] = 'failed'
        elif 'STEP 2: Social Media Scrape' in text:
            v['auto']['step2'] = True
        elif 'STEP 3: Apollo API' in text or '[SKIP] Apollo step' in text:
            v['auto']['step3'] = True
        elif '[APOLLO MISMATCH]' in text:
            v['apollo'] = 'mismatch'
        elif 'No company found in Apollo' in text:
            v['apollo'] = v['apollo'] or 'none'
        elif re.search(r'Found: .+ \(domain: ', text):
            v['apollo'] = v['apollo'] or 'ok'
        elif 'STEP 4: LinkedIn' in text:
            v['auto']['step4'] = True
            if 'SKIPPED' in text:
                v['linkedin'] = 'wall' if 'wall' in text.lower() else 'skipped'
        elif '[LINKEDIN WALL]' in text:
            v['linkedin'] = 'wall'
        elif '[LINKEDIN EMPTY]' in text or 'No results on page 1' in text:
            v['linkedin'] = v['linkedin'] or 'empty'
        elif re.search(r'LinkedIn page 1\.\.\.', text):
            pass
        elif re.search(r'^\s*Found (\d+) results', text) and not v['linkedin']:
            v['linkedin'] = 'found'
        elif done_re.match(text):
            v['auto']['done'] = True
        elif '[SKIP] Already' in text or 'Venue status prevents' in text \
                or 'possibly closed and skipping' in text or '[ABORT] Skipping' in text:
            v['skipped'] = text.strip()
        mm = emails_re.search(text)
        if mm and not v['emails_line']:
            v['emails_line'] = f"{mm.group(1)} emails, FB {mm.group(2)}, IG {mm.group(3)}, form {mm.group(4)}"
    if '=== BATCH COMPLETE ===' in text:
        batch_complete = True
        current = None
    if 'AUTO-RUNNING POSTCHECK' in text or 'POST-PIPELINE VERIFICATION' in text:
        postcheck_started = True
        current = None
    if 'Post-Pipeline Check Complete' in text:
        postcheck_done = True

if run_steps.get('postcheck', ('',))[0] in ('done', 'BLOCKED'):
    postcheck_done = True

# ---------------------------------------------------------------- coverage files
for vid, v in venues.items():
    safe = re.sub(r'[^A-Za-z0-9_.-]', '', vid) or 'venue'
    v['coverage'] = os.path.exists(os.path.join(coverage_dir, f"{safe}.json"))

# ---------------------------------------------------------------- sheet contact counts
if apps_url and not no_sheet:
    for vid, v in venues.items():
        try:
            out = subprocess.run(['curl', '-sL', '--max-time', '20',
                                  f"{apps_url}?action=venue_detail&venue_id={vid}"],
                                 capture_output=True, text=True, timeout=30).stdout
            d = json.loads(out)
            if d.get('status') == 'ok':
                v['sheet_contacts'] = len(d.get('contacts', []))
        except Exception:
            pass
    if all(v['sheet_contacts'] is None for v in venues.values()):
        warnings.append("could not read contact counts from the sheet (API unreachable?) — contacts step verified from ledger only")
elif not apps_url and not no_sheet:
    warnings.append("APPS_SCRIPT_URL not found in .env — contacts step verified from ledger only")

# ---------------------------------------------------------------- evaluate
missing, blocked, degraded, rows = [], [], [], []

for vid in order:
    v = venues[vid]
    auto_ok = {}
    for s in AUTO_STEPS:
        ok = bool(v['auto'].get(s)) or bool(v['skipped'])
        auto_ok[s] = ok
        if not ok:
            missing.append((vid, s, 'not in log — re-run the venue'))

    manual_ok = {}
    for s in MANUAL_STEPS:
        st = v['manual'].get(s)
        if st is None:
            manual_ok[s] = ' '
            missing.append((vid, s, 'no mark'))
        elif st[0] == 'BLOCKED':
            manual_ok[s] = 'B'
            blocked.append((vid, s, st[1]))
        else:
            manual_ok[s] = 'x'

    # -- degraded automated results need a manual answer, not just a mark --
    if v['web_method'] == 'curl':
        degraded.append((vid, 'website scraped by curl only (Chrome down) — no JS, no names; '
                              'manual web check is the only real coverage'))
    elif v['web_method'] == 'failed':
        degraded.append((vid, 'website scrape failed entirely'))
    if v['auto'].get('step1') and not v['coverage'] and not v['skipped']:
        degraded.append((vid, 'no web-coverage file — recursive crawl did not run'))

    if v['apollo'] == 'mismatch':
        st = v['manual'].get('apollo')
        if not st or (st[0] == 'done' and not re.search(r'mismatch|wrong|skipped|manual|none|\d', st[1], re.I)):
            missing.append((vid, 'apollo', 'Apollo matched a different company — mark apollo BLOCKED "mismatch" or note what you did instead'))
            manual_ok['apollo'] = '!'
        degraded.append((vid, 'Apollo matched a different company; people not enriched'))

    if v['linkedin'] in ('wall', 'empty', 'skipped'):
        st = v['manual'].get('linkedin')
        good = False
        if st:
            if st[0] == 'BLOCKED' and re.search(r'wall|quota|login|rate|limit|blocked|empty', st[1], re.I):
                good = True
            elif st[0] == 'done' and re.search(r'\d', st[1]):
                good = True   # a manual Chrome search that actually returned people
        if not good:
            missing.append((vid, 'linkedin', f'pipeline LinkedIn was {v["linkedin"]} — do the search by hand (note the count) or BLOCK it with the reason'))
            manual_ok['linkedin'] = '!'
        degraded.append((vid, f'pipeline LinkedIn {v["linkedin"]} — venue kept linkedin_pending'))

    st = v['manual'].get('contacts')
    if st and st[0] == 'done' and v['sheet_contacts'] == 0:
        missing.append((vid, 'contacts', 'marked done but the sheet has 0 contacts — mark BLOCKED with why, or add them'))
        manual_ok['contacts'] = '!'

    rows.append((vid, v['name'], v['skipped'], auto_ok, manual_ok, v))

run_ok = {
    'batch_complete': batch_complete,
    'postcheck': postcheck_done,
    'taste_review': run_steps.get('taste_review', ('',))[0] in ('done', 'BLOCKED'),
    'report': run_steps.get('report', ('',))[0] in ('done', 'BLOCKED'),
}
for s, ok in run_ok.items():
    if not ok:
        missing.append(('(run)', s, 'not recorded'))
    elif run_steps.get(s, ('',))[0] == 'BLOCKED':
        blocked.append(('(run)', s, run_steps[s][1]))
if chrome_warning:
    degraded.append(('(run)', 'Chrome JavaScript was OFF for this whole run — every website scrape fell back to curl'))

# ---------------------------------------------------------------- output
if want_json:
    print(json.dumps({'run_id': rid, 'missing': missing, 'blocked': blocked, 'degraded': degraded,
                      'run': run_ok, 'warnings': warnings,
                      'venues': {vid: {'name': v['name'], 'skipped': v['skipped'], 'web_method': v['web_method'],
                                       'apollo': v['apollo'], 'linkedin': v['linkedin'], 'emails': v['emails_line'],
                                       'sheet_contacts': v['sheet_contacts'],
                                       'auto': {s: bool(v['auto'].get(s)) for s in AUTO_STEPS},
                                       'manual': {s: v['manual'].get(s, [None, ''])[0] for s in MANUAL_STEPS}}
                                 for vid, v in venues.items()}}, indent=2))
    sys.exit(0 if not missing else 1)

print(f"RUN {rid}  ({len(venues)} venues)")
if not os.path.exists(run_log):
    print(f"  run log: (missing) expected {run_log}")
for w in warnings:
    print(f"  WARNING: {w}")
print()
hdr = f"{'venue':44s} | auto  s 1 2 3 4 D | web fb ig li ap st ct | web/apollo/linkedin/contacts"
print(hdr)
print('-' * len(hdr))
for vid, name, skipped, auto_ok, manual_ok, v in rows:
    label = f"{vid} {name}"[:44]
    a = ' '.join(('x' if auto_ok[s] else '.') for s in AUTO_STEPS)
    mcols = '  '.join(manual_ok[s] for s in MANUAL_STEPS)
    info = f"{v['web_method'] or '-'}/{v['apollo'] or '-'}/{v['linkedin'] or '-'}/" \
           f"{'?' if v['sheet_contacts'] is None else v['sheet_contacts']}"
    print(f"{label:44s} |       {a} |  {mcols}  | {info}")
    if v['emails_line']:
        print(f"{'':44s}   step1: {v['emails_line']}")
    if skipped:
        print(f"{'':44s}   pipeline skipped: {skipped[:80]}")
print()
print("Run-level: " + '  '.join(f"{s}={'x' if ok else '.'}" for s, ok in run_ok.items()))
print("Legend: x done  . missing  B blocked  ! marked but evidence contradicts it")
print()
print(f"MISSING: {len(missing)}")
for vid, s, why in missing:
    print(f"  {vid:16s} {s:10s} {why}")
print(f"BLOCKED: {len(blocked)}")
for vid, s, note in blocked:
    print(f"  {vid:16s} {s:10s} {note}")
print(f"DEGRADED: {len(degraded)}  (does not block; goes in the report)")
for vid, why in degraded:
    print(f"  {vid:16s} {why}")
print()
if missing:
    print("NOT DONE. Fix or BLOCK the missing items, then run verify_run.sh again.")
    sys.exit(1)
print("DONE. Paste this output at the bottom of the run report.")
PY
