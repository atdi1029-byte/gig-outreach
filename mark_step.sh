#!/bin/bash
# =============================================================
# mark_step.sh — write to the per-run ledger
#
# The ledger is reports/runs/<RUN_ID>.jsonl (one JSON line per event).
# verify_run.sh reads it, together with the run log, to decide
# whether a run is actually finished.
#
# Usage:
#   ./mark_step.sh --batch /tmp/pipeline_batch.json [RUN_ID]
#       Register every venue in the batch. Creates the run, writes
#       reports/runs/CURRENT so later calls don't need the RUN_ID.
#       RUN_ID defaults to run-YYYYMMDD-HHMM.
#
#   ./mark_step.sh VENUE_ID STEP [done|BLOCKED] "note"
#       Record a manual per-venue step. STEP is one of:
#         web fb ig linkedin apollo status contacts
#       Default status is "done". EVERY mark needs a note that shows the
#       work happened: a number ("3 emails", "0 people"), a URL, or a
#       finding word (none / not found / closed / open / wall / quota).
#       A bare "done" is rejected — that's the rubber-stamp this file exists
#       to prevent.
#
#   ./mark_step.sh --run STEP [done|BLOCKED] ["note"]
#       Record a run-level step: taste_review report postcheck
#
#   ./mark_step.sh --show
#       Print the current run's ledger.
#
# Set RUN_ID=... in the environment to target a run other than CURRENT.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="${SCRIPT_DIR}/reports/runs"
mkdir -p "$RUNS_DIR"

python3 - "$RUNS_DIR" "$@" <<'PY'
import json, os, sys, datetime

runs_dir = sys.argv[1]
args = sys.argv[2:]

MANUAL_STEPS = ['web', 'fb', 'ig', 'linkedin', 'apollo', 'status', 'contacts']
RUN_STEPS = ['taste_review', 'report', 'postcheck']
STATUSES = ['done', 'BLOCKED']

import re
# What counts as evidence in a note, per step. The note must match at least one.
EVIDENCE = {
    'web':      r'\d|https?://|none|not found|no email|no contact',
    'fb':       r'facebook\.com|fb\.com|none|not found|no\s+(fb|facebook|page)',
    'ig':       r'instagram\.com|@\w+|none|not found|no\s+(ig|insta|instagram|page)',
    'linkedin': r'\d|none|no employees|no people|wall|quota|login|rate limit|blocked',
    'apollo':   r'\d|none|no domain|no company|not in apollo|skipped|mismatch',
    'status':   r'\bopen\b|closed|renamed|moved|permanently|temporarily|reopen|unknown|for sale',
    'contacts': r'\d|none|zero|no email',
}
EVIDENCE_HINT = {
    'web':      'e.g. "2 emails, contact form /contact" or "none"',
    'fb':       r'facebook\.com|fb\.com|none|not found|no\s+(fb|facebook|page)',
    'ig':       r'instagram\.com|@\w+|none|not found|no\s+(ig|insta|instagram|page)',
    'linkedin': 'e.g. "6 people, 2 events staff" or BLOCKED "login wall"',
    'apollo':   'e.g. "3 enriched" or "none — no domain"',
    'status':   'e.g. "open, hours on site" or "closed June 2026"',
    'contacts': 'e.g. "3 added, 1 pending" or "none"',
}


def check_evidence(step, status, note):
    if status == 'BLOCKED':
        if len(note.strip()) < 4:
            die(f'BLOCKED needs a reason in words ({EVIDENCE_HINT.get(step, "")})')
        return
    pat = EVIDENCE.get(step)
    if pat and not re.search(pat, note or '', re.I):
        die(f"'{step}' marked done but the note shows no evidence "
            f"({EVIDENCE_HINT.get(step, '')}). If you didn't do it, mark BLOCKED with why.")

current_file = os.path.join(runs_dir, 'CURRENT')


def die(msg):
    print(f"[mark_step] ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def now():
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def current_run():
    rid = os.environ.get('RUN_ID', '').strip()
    if rid:
        return rid
    if os.path.exists(current_file):
        rid = open(current_file).read().strip()
        if rid:
            return rid
    die("no current run. Register a batch first: ./mark_step.sh --batch /tmp/pipeline_batch.json")


def ledger_path(rid):
    return os.path.join(runs_dir, f"{rid}.jsonl")


def append(rid, entry):
    entry = dict(entry)
    entry['ts'] = now()
    entry['run_id'] = rid
    with open(ledger_path(rid), 'a') as f:
        f.write(json.dumps(entry) + '\n')


def load(rid):
    p = ledger_path(rid)
    if not os.path.exists(p):
        return []
    out = []
    for line in open(p):
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


if not args or args[0] in ('-h', '--help'):
    print(open(sys.argv[0]).read() if os.path.exists(sys.argv[0]) else __doc__ or '')
    print("See header comment in mark_step.sh for usage.")
    sys.exit(0)

# ---------------------------------------------------------------- --batch
if args[0] == '--batch':
    if len(args) < 2:
        die("usage: --batch /tmp/pipeline_batch.json [RUN_ID]")
    batch_file = args[1]
    rid = args[2] if len(args) > 2 else os.environ.get('RUN_ID', '').strip() \
        or 'run-' + datetime.datetime.now().strftime('%Y%m%d-%H%M')
    try:
        batch = json.load(open(batch_file))
    except Exception as e:
        die(f"cannot read {batch_file}: {e}")
    if not isinstance(batch, list) or not batch:
        die("batch file is empty or not a list")
    if os.path.exists(ledger_path(rid)):
        die(f"run {rid} already exists ({ledger_path(rid)}). Pick another RUN_ID.")
    append(rid, {'type': 'run', 'step': 'start', 'status': 'done',
                 'note': f'batch file {batch_file}', 'count': len(batch)})
    for v in batch:
        append(rid, {
            'type': 'venue', 'step': 'registered', 'status': 'done',
            'venue_id': v.get('venue_id', ''), 'venue_name': v.get('name', ''),
            'website': v.get('website', ''), 'city': v.get('city', ''),
            'state': v.get('state', ''),
        })
    with open(current_file, 'w') as f:
        f.write(rid + '\n')
    print(f"[mark_step] run {rid}: registered {len(batch)} venues")
    print(f"[mark_step] ledger: {ledger_path(rid)}")
    print(f"[mark_step] run log should be: {os.path.join(runs_dir, rid + '.log')}")
    print(f"export RUN_ID={rid}")
    sys.exit(0)

# ---------------------------------------------------------------- --show
if args[0] == '--show':
    rid = current_run()
    rows = load(rid)
    print(f"run {rid}: {len(rows)} entries")
    for r in rows:
        who = r.get('venue_id') or '(run)'
        print(f"  {r.get('ts','')}  {who:16s} {r.get('step',''):12s} "
              f"{r.get('status',''):8s} {r.get('note','')}")
    sys.exit(0)

# ---------------------------------------------------------------- --run
if args[0] == '--run':
    if len(args) < 2:
        die("usage: --run STEP [done|BLOCKED] [note]")
    step = args[1]
    if step not in RUN_STEPS:
        die(f"unknown run step '{step}'. Allowed: {', '.join(RUN_STEPS)}")
    status = args[2] if len(args) > 2 else 'done'
    note = args[3] if len(args) > 3 else ''
    if status not in STATUSES:
        die(f"status must be one of {STATUSES}")
    if status == 'BLOCKED' and not note:
        die("BLOCKED needs a reason: ./mark_step.sh --run STEP BLOCKED \"why\"")
    rid = current_run()
    append(rid, {'type': 'run', 'step': step, 'status': status, 'note': note})
    print(f"[mark_step] {rid}: run step {step} = {status} {note}")
    sys.exit(0)

# ---------------------------------------------------------------- venue step
if len(args) < 2:
    die("usage: VENUE_ID STEP [done|BLOCKED] [note]")
venue_id, step = args[0], args[1]
status = args[2] if len(args) > 2 else 'done'
note = args[3] if len(args) > 3 else ''
if step not in MANUAL_STEPS:
    die(f"unknown step '{step}'. Allowed: {', '.join(MANUAL_STEPS)}")
if status not in STATUSES:
    die(f"status must be one of {STATUSES}")
if status == 'BLOCKED' and not note:
    die("BLOCKED needs a reason: ./mark_step.sh VENUE_ID STEP BLOCKED \"why\"")
check_evidence(step, status, note)
rid = current_run()
registered = {r.get('venue_id') for r in load(rid) if r.get('step') == 'registered'}
if venue_id not in registered:
    die(f"{venue_id} is not registered in run {rid}. "
        f"Registered: {', '.join(sorted(v for v in registered if v)) or 'none'}")
append(rid, {'type': 'venue', 'venue_id': venue_id, 'step': step,
             'status': status, 'note': note})
print(f"[mark_step] {rid}: {venue_id} {step} = {status} {note}")
PY
