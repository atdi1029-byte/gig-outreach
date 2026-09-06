#!/bin/bash
# =============================================================
# verify_run.sh — definition of done for a pipeline run
#
# Reads:
#   reports/runs/<RUN_ID>.jsonl   the ledger written by mark_step.sh
#   reports/runs/<RUN_ID>.log     stdout of pipeline.sh (nohup ... > this file)
#
# Checks, for every venue registered in the run:
#   automated steps (from the log): started, step1, step2, step3, step4, done
#       - a venue the pipeline skipped for a recorded reason counts as satisfied
#   manual steps (from the ledger):  web fb ig linkedin apollo status contacts
#       - "done" or "BLOCKED <reason>" both satisfy the gate;
#         BLOCKED is listed separately so it lands in the report
# and, for the run as a whole:
#   batch_complete (log), postcheck (log or ledger),
#   taste_review (ledger), report (ledger)
#
# Usage:
#   ./verify_run.sh            — current run (reports/runs/CURRENT or $RUN_ID)
#   ./verify_run.sh RUN_ID
#   ./verify_run.sh RUN_ID --json   — machine-readable summary
#
# Exit code 0 only when MISSING: 0. Anything else is not done.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="${SCRIPT_DIR}/reports/runs"
PIPELINE_LOG="${SCRIPT_DIR}/pipeline.log"

python3 - "$RUNS_DIR" "$PIPELINE_LOG" "$@" <<'PY'
import json, os, re, sys

runs_dir, pipeline_log = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
want_json = '--json' in args
args = [a for a in args if a != '--json']

MANUAL_STEPS = ['web', 'fb', 'ig', 'linkedin', 'apollo', 'status', 'contacts']
AUTO_STEPS = ['started', 'step1', 'step2', 'step3', 'step4', 'done']
RUN_STEPS = ['batch_complete', 'postcheck', 'taste_review', 'report']


def die(msg):
    print(f"[verify_run] ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------- run id
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

venues = {}          # venue_id -> info
order = []
for e in entries:
    if e.get('step') == 'registered' and e.get('venue_id'):
        vid = e['venue_id']
        if vid not in venues:
            order.append(vid)
        venues[vid] = {'name': e.get('venue_name', ''), 'manual': {}, 'auto': {},
                       'skipped': ''}
if not venues:
    die(f"run {rid} has no registered venues")

run_steps = {}       # step -> (status, note)
for e in entries:
    if e.get('type') == 'venue' and e.get('venue_id') in venues \
            and e.get('step') in MANUAL_STEPS:
        venues[e['venue_id']]['manual'][e['step']] = (e.get('status', 'done'), e.get('note', ''))
    elif e.get('type') == 'run' and e.get('step') in RUN_STEPS:
        run_steps[e['step']] = (e.get('status', 'done'), e.get('note', ''))

# ---------------------------------------------------------------- log
warnings = []
log_lines = []
if os.path.exists(run_log):
    log_lines = open(run_log, errors='ignore').read().split('\n')
elif os.path.exists(pipeline_log):
    # Fallback: last run block of pipeline.log. May be a different run —
    # say so loudly rather than silently passing.
    all_lines = open(pipeline_log, errors='ignore').read().split('\n')
    starts = [i for i, l in enumerate(all_lines) if '=== Pipeline started' in l]
    if starts:
        log_lines = all_lines[starts[-1]:]
    warnings.append(f"run log {run_log} not found — using the LAST block of pipeline.log, "
                    f"which may belong to another run. Treat automated results as unverified.")
else:
    warnings.append("no run log and no pipeline.log — automated steps cannot be verified")

name_to_vid = {v['name'].strip().lower(): vid for vid, v in venues.items() if v['name']}

# strip optional "HH:MM:SS " prefix (pipeline.log has it, nohup stdout does not)
ts_re = re.compile(r'^\d{2}:\d{2}:\d{2} ')
hdr_re = re.compile(r'#{5,} VENUE \[\d+/\d+\]: (.+?) #{5,}')
pipe_re = re.compile(r'^\s*PIPELINE: (.+?) \(([^)]+)\)\s*$')
done_re = re.compile(r'^\s*DONE: (.+?) \|')

current = None         # venue_id currently being processed in the log
batch_complete = False
postcheck_started = False
postcheck_done = False

for raw in log_lines:
    text = ts_re.sub('', raw).rstrip()
    m = hdr_re.search(text)
    if m:
        current = name_to_vid.get(m.group(1).strip().lower())
        if current:
            venues[current]['auto']['started'] = True
        continue
    m = pipe_re.match(text)
    if m:
        vid = m.group(2).strip()
        if vid in venues:
            current = vid
        else:
            # pipeline may have resolved a different real ID by domain
            current = name_to_vid.get(m.group(1).strip().lower(), current)
        if current:
            venues[current]['auto']['started'] = True
        continue
    if current:
        v = venues[current]
        if 'STEP 1: Website Scrape' in text:
            v['auto']['step1'] = True
        elif 'STEP 2: Social Media Scrape' in text:
            v['auto']['step2'] = True
        elif 'STEP 3: Apollo API' in text or '[SKIP] Apollo step' in text:
            v['auto']['step3'] = True
        elif 'STEP 4: LinkedIn' in text:
            v['auto']['step4'] = True
        elif done_re.match(text):
            v['auto']['done'] = True
        elif '[SKIP] Already' in text or 'Venue status prevents' in text \
                or 'possibly closed and skipping' in text or '[ABORT] Skipping' in text:
            v['skipped'] = text.strip()
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

# ---------------------------------------------------------------- evaluate
missing = []      # (vid, step)
blocked = []      # (vid, step, note)
rows = []

for vid in order:
    v = venues[vid]
    auto_ok = {}
    for s in AUTO_STEPS:
        auto_ok[s] = bool(v['auto'].get(s)) or bool(v['skipped'])
        if not auto_ok[s]:
            missing.append((vid, s))
    manual_ok = {}
    for s in MANUAL_STEPS:
        st = v['manual'].get(s)
        if st is None:
            manual_ok[s] = ' '
            missing.append((vid, s))
        elif st[0] == 'BLOCKED':
            manual_ok[s] = 'B'
            blocked.append((vid, s, st[1]))
        else:
            manual_ok[s] = 'x'
    rows.append((vid, v['name'], v['skipped'], auto_ok, manual_ok))

run_ok = {
    'batch_complete': batch_complete,
    'postcheck': postcheck_done,
    'taste_review': run_steps.get('taste_review', ('',))[0] in ('done', 'BLOCKED'),
    'report': run_steps.get('report', ('',))[0] in ('done', 'BLOCKED'),
}
for s, ok in run_ok.items():
    if not ok:
        missing.append(('(run)', s))
    elif run_steps.get(s, ('',))[0] == 'BLOCKED':
        blocked.append(('(run)', s, run_steps[s][1]))

# ---------------------------------------------------------------- output
if want_json:
    print(json.dumps({
        'run_id': rid,
        'venues': {vid: {'name': v['name'], 'skipped': v['skipped'],
                         'auto': {s: bool(v['auto'].get(s)) for s in AUTO_STEPS},
                         'manual': {s: v['manual'].get(s, [None, ''])[0] for s in MANUAL_STEPS}}
                   for vid, v in venues.items()},
        'run': run_ok,
        'missing': missing, 'blocked': blocked, 'warnings': warnings,
    }, indent=2))
    sys.exit(0 if not missing else 1)

print(f"RUN {rid}  ({len(venues)} venues)")
if not os.path.exists(run_log):
    print(f"  run log: (missing) expected {run_log}")
for w in warnings:
    print(f"  WARNING: {w}")
print()
hdr = f"{'venue':46s} | started 1 2 3 4 done | web fb ig li ap st ct"
print(hdr)
print('-' * len(hdr))
for vid, name, skipped, auto_ok, manual_ok in rows:
    label = f"{vid} {name}"[:46]
    a = ' '.join(('x' if auto_ok[s] else ' ') for s in AUTO_STEPS)
    # pad so columns line up under "started 1 2 3 4 done"
    a = f"   {a[0]}     {a[2]} {a[4]} {a[6]} {a[8]}  {a[10]}  "
    mcols = '  '.join(manual_ok[s] for s in MANUAL_STEPS)
    print(f"{label:46s} | {a} |  {mcols}")
    if skipped:
        print(f"{'':46s}   pipeline skipped: {skipped[:90]}")
print()
print("Run-level: " + '  '.join(f"{s}={'x' if ok else ' '}" for s, ok in run_ok.items()))
print()
print(f"MISSING: {len(missing)}")
by_vid = {}
for vid, s in missing:
    by_vid.setdefault(vid, []).append(s)
for vid, steps in by_vid.items():
    print(f"  {vid:16s} {', '.join(steps)}")
print(f"BLOCKED: {len(blocked)}")
for vid, s, note in blocked:
    print(f"  {vid:16s} {s} — {note}")
print()
if missing:
    print("NOT DONE. Complete or BLOCK the missing steps, then run verify_run.sh again.")
    sys.exit(1)
print("DONE. Paste this output at the bottom of the run report.")
PY
