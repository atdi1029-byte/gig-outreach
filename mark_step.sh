#!/bin/bash
# =============================================================
# mark_step.sh — write to the per-run ledger
#
# The ledger is reports/runs/<RUN_ID>.jsonl (one JSON line per event).
# verify_run.sh reads it, together with the run log, to decide
# whether a run is actually finished and clean.
#
# Usage:
#   ./mark_step.sh --batch /tmp/pipeline_batch.json [RUN_ID] [--append] [--new-run]
#       Register every venue in the batch (max 8 per batch, P6; set
#       ALLOW_LARGE_BATCH=1 to override). Creates the run and writes
#       reports/runs/CURRENT so later calls don't need the RUN_ID.
#       RUN_ID defaults to run-YYYYMMDD-HHMM.
#       --append   add the NEXT batch to an existing run (a run of 50 venues
#                  is ~7 batches under one RUN_ID, e.g. the batch_NN.json files
#                  of build_batch.sh --total 50). With an explicit RUN_ID it also
#                  starts the run. Venues already registered in the run are
#                  skipped, so re-registering a resumed batch is harmless.
#       --new-run  start a new run even though CURRENT points at a run that
#                  has no report mark yet (i.e. abandon it).
#
#   ./mark_step.sh VENUE_ID STEP [done|BLOCKED] "note"
#       Record a manual per-venue step. STEP is one of:
#         web fb ig linkedin apollo status contacts
#       plus `pipeline` (BLOCKED only): the automated run of this venue
#       cannot be completed (e.g. killed by the watchdog twice) — say why.
#       Default status is "done". EVERY mark needs a note that shows the
#       work happened — a count with what was counted ("3 emails",
#       "7 people, 2 relevant"), a URL, or a page path ("no email on
#       /contact /about /events"). Bare words like done / ok / checked /
#       none are rejected. Step-specific rules:
#         linkedin  must cite the LinkedIn people search (a count of people
#                   or a linkedin.com URL); Apollo counts are rejected.
#         contacts  done needs a non-zero count; if nothing was found the
#                   honest mark is BLOCKED with where you looked.
#         fb / ig   "no page" must say where you searched.
#       BLOCKED needs a reason of at least a few words.
#
#   ./mark_step.sh --run STEP [done|BLOCKED] "note"
#       Record a run-level step: taste_review report postcheck miss_audit
#       report     the note must name the report file (reports/....html);
#                  it has to exist.
#       miss_audit a count ("8 venues re-searched, 0 misses"); the misses
#                  themselves go in reports/runs/<RUN_ID>.misses.jsonl.
#
#   ./mark_step.sh --show
#       Print the current run's ledger.
#
#   ./mark_step.sh --audit-notes [RUN_ID]
#       Re-check every mark in a ledger against the current evidence rules
#       and print the failures as JSON (used by verify_run.sh).
#
# Every entry records when (ts) and who (by = $MARK_BY, else $USER).
# Set RUN_ID=... in the environment to target a run other than CURRENT.
# REPORTS_DIR=... relocates reports/ (tests).
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
REPORTS_DIR="${REPORTS_DIR:-${SCRIPT_DIR}/reports}"
RUNS_DIR="${REPORTS_DIR}/runs"
mkdir -p "$RUNS_DIR"

python3 - "$RUNS_DIR" "$REPORTS_DIR" "$SCRIPT_DIR" "$@" <<'PY'
import datetime
import getpass
import json
import os
import re
import sys

runs_dir, reports_dir, script_dir = sys.argv[1:4]
args = sys.argv[4:]

MANUAL_STEPS = ['web', 'fb', 'ig', 'linkedin', 'apollo', 'status', 'contacts', 'pipeline']
BLOCKED_ONLY = {'pipeline'}
RUN_STEPS = ['taste_review', 'report', 'postcheck', 'miss_audit']
STATUSES = ['done', 'BLOCKED']
MAX_BATCH = 8

candidate_log = os.path.join(reports_dir, 'discovery-candidates.jsonl')
err_log = os.environ.get('ERR_LOG') or os.path.join(runs_dir, 'python-errors.log')
current_file = os.path.join(runs_dir, 'CURRENT')

# ------------------------------------------------------------ evidence rules
# A note must show the work happened. These rules are also applied by
# verify_run.sh (through --audit-notes) to marks already in a ledger.
TRIVIAL = {
    'done', 'ok', 'okay', 'checked', 'check', 'yes', 'y', 'complete', 'completed',
    'finished', 'fine', 'good', 'na', 'n/a', 'none', 'nothing', 'no', 'x', 'verified',
    'reviewed', 'looked', 'searched', 'nope', 'skip', 'skipped', 'tbd', 'todo', 'same',
    'see above', 'as above', 'unknown', 'n.a.', 'nil', 'zero', '0', 'empty', 'blocked',
}
COUNT_NOUN = r'\b(\d+)\s*\+?\s*(?:[a-z-]+\s+)?'   # "3 emails", "21 pipeline contacts"
URLISH = r'https?://|www\.|\b[\w-]+\.(?:com|org|net|us|biz|info|co|club|events|restaurant|wine)\b'
PATH = r'(?:^|[\s,(])/[a-z][\w-]*'
SEARCHED = r'search|google|website|site|footer|header|link|checked|looked|bio|about'


def _n(note):
    return re.sub(r'\s+', ' ', (note or '').strip())


def _trivial(note):
    n = _n(note).lower().strip(' .!-–—:;,')
    if not n or n in TRIVIAL:
        return True
    return len(n) < 6 and not re.search(r'\d|https?://', n)


def _has(pat, note):
    return re.search(pat, note or '', re.I) is not None


def _counts(note, nouns):
    return [int(m.group(1)) for m in re.finditer(COUNT_NOUN + r'(?:' + nouns + r')\b', note or '', re.I)]


HINT = {
    'web':      'e.g. "2 emails, contact form https://x.com/contact" or "no email on /contact /about /events /team"',
    'fb':       'e.g. "facebook.com/VenuePage, email in About" or "no FB page (Google search + site footer)"',
    'ig':       'e.g. "instagram.com/venue, no email in bio" or "no IG account (Google search + site footer)"',
    'linkedin': 'e.g. "7 people, 2 relevant" or "linkedin.com/in/jane-doe" — or BLOCKED "login wall"',
    'apollo':   'e.g. "3 enriched" or "no named people without email" or "not in Apollo (domain + name search)"',
    'status':   'e.g. "open, hours on site" or "closed June 2026 per Google"',
    'contacts': 'e.g. "3 added, 1 pending" — if nothing was found mark BLOCKED with where you looked',
    'pipeline': 'BLOCKED "<why the automated run cannot finish>"',
    'taste_review': 'e.g. "2 new votes processed" or "no new votes since run-20260910-2302"',
    'report':   'e.g. "reports/2026-09-25_04-00.html"',
    'postcheck': 'e.g. "3 venues checked, 1 contact added"',
    'miss_audit': 'e.g. "8 venues re-searched, 1 miss logged"',
}


def done_problem(step, note):
    """'' if a done-note is acceptable evidence for this step, else why not."""
    note = _n(note)
    if _trivial(note):
        return 'note is empty or a bare word — say what you found (a count, a URL, or a page)'
    if step == 'web':
        if _counts(note, r'e-?mails?|contacts?|addresses|names?|people|persons|pages?|forms?|staff|mailtos?') \
                or _has(URLISH, note) or _has(PATH, note) or _has(r'contact form|[\w.+-]+@[\w-]+\.\w', note):
            return ''
        return 'web note needs a count, a URL, an address found, or the pages you checked'
    if step == 'fb':
        if _has(r'(?:facebook\.com|fb\.com|fb\.me)/\S+', note):
            return ''
        if _has(r'\bno\b.*\b(?:fb|facebook)\b|\b(?:fb|facebook)\b.*\b(?:none|not found|deleted|unavailable)\b', note) \
                and _has(SEARCHED, note):
            return ''
        return 'fb note needs the page URL, or "no FB page" plus where you searched'
    if step == 'ig':
        if _has(r'instagram\.com/\S+|(?:^|\s)@[\w.]{2,}', note):
            return ''
        if _has(r'\bno\b.*\b(?:ig|insta|instagram)\b|\b(?:ig|insta|instagram)\b.*\b(?:none|not found|deleted|unavailable)\b', note) \
                and _has(SEARCHED, note):
            return ''
        return 'ig note needs the profile URL/@handle, or "no IG account" plus where you searched'
    if step == 'linkedin':
        if _has(r'apollo', note) and not _has(r'linkedin', note):
            return 'that is an Apollo note — the linkedin step is the LinkedIn people search'
        if _counts(note, r'people|persons|employees|profiles|results|staff|members|relevant|matches') \
                or _has(r'linkedin\.com/', note):
            return ''
        return 'linkedin note needs a people count or a linkedin.com URL'
    if step == 'apollo':
        if _counts(note, r'enriched|people|persons|contacts?|results?|credits?|matches|e-?mails?|revealed|found|searches') \
                or _has(r'no (?:named )?(?:people|person|one)|nothing to enrich|no domain|no company|not in apollo|'
                        r'mismatch|wrong (?:company|org)|no match', note):
            return ''
        return 'apollo note needs a count or a specific result ("not in Apollo", "no named people without email")'
    if step == 'status':
        if _has(r'\bopen\b|closed|renamed|moved|permanent|temporar|reopen|for sale|operating|renovat', note) \
                and len(note.split()) >= 2:
            return ''
        return 'status note needs open/closed/renamed... plus the source ("open, hours on site")'
    if step == 'contacts':
        counts = _counts(note, r'added|contacts?|e-?mails?|pending|saved|verified|people|persons|new|names?')
        if any(c > 0 for c in counts):
            return ''
        if counts or _has(r'\bnone\b|\bzero\b|no contacts?|no e-?mails?|nothing', note):
            return 'contacts done with 0 contacts — mark BLOCKED with where you looked instead'
        return 'contacts note needs the number added ("3 added, 1 pending")'
    if step == 'pipeline':
        return 'pipeline can only be marked BLOCKED (with why the automated run cannot finish)'
    if step == 'taste_review':
        if _counts(note, r'votes?|reviews?|feedback|notes?|venues?|comments?') \
                or _has(r'no new (?:votes?|reviews?|feedback)', note):
            return ''
        return 'taste_review note needs a count or "no new votes since ..."'
    if step == 'report':
        if _has(r'[\w./-]+\.html?\b', note):
            return ''
        return 'report note must name the report file (reports/<date>.html)'
    if step == 'postcheck':
        if _counts(note, r'venues?|checked|contacts?|added'):
            return ''
        return 'postcheck note needs a count ("3 venues checked")'
    if step == 'miss_audit':
        if _counts(note, r'venues?|misses|missed|items?|re-?searched'):
            return ''
        return 'miss_audit note needs counts ("8 venues re-searched, 0 misses")'
    return ''


def blocked_problem(note):
    n = _n(note)
    if _trivial(n) or len(n.split()) < 2 or len(n) < 8:
        return 'BLOCKED needs a real reason ("login wall", "site down (DNS fails)", "no website")'
    return ''


def note_problem(step, status, note):
    if status == 'BLOCKED':
        return blocked_problem(note)
    return done_problem(step, note)


# ------------------------------------------------------------ ledger helpers
def die(msg, code=2):
    print(f"[mark_step] ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def who():
    by = os.environ.get('MARK_BY', '').strip()
    if by:
        return by
    try:
        return getpass.getuser()
    except Exception:
        return 'unknown'


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
    entry['by'] = who()
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


def fsize(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def run_finished(rows):
    return any(r.get('type') == 'run' and r.get('step') == 'report' and r.get('status') in STATUSES
               for r in rows)


def resolve_report(note):
    for m in re.finditer(r'[\w./~-]+\.html?\b', note or ''):
        p = os.path.expanduser(m.group(0))
        for cand in (p, os.path.join(script_dir, p), os.path.join(reports_dir, p),
                     os.path.join(reports_dir, os.path.basename(p))):
            if os.path.isfile(cand):
                return cand
    return ''


if not args or args[0] in ('-h', '--help'):
    src = open(os.path.join(script_dir, 'mark_step.sh')).read().split('\n')
    print('\n'.join(l for l in src[1:60] if l.startswith('#')))
    sys.exit(0)

# ---------------------------------------------------------------- --batch
if args[0] == '--batch':
    flags = {a for a in args[1:] if a.startswith('--')}
    pos = [a for a in args[1:] if not a.startswith('--')]
    unknown = flags - {'--append', '--new-run'}
    if unknown or not pos:
        die("usage: --batch /tmp/pipeline_batch.json [RUN_ID] [--append] [--new-run]")
    batch_file = pos[0]
    appending = '--append' in flags
    rid = (pos[1] if len(pos) > 1 else '') or os.environ.get('RUN_ID', '').strip()
    if not rid and appending and os.path.exists(current_file):
        rid = open(current_file).read().strip()
    rid = rid or 'run-' + datetime.datetime.now().strftime('%Y%m%d-%H%M')
    try:
        batch = json.load(open(batch_file))
    except Exception as e:
        die(f"cannot read {batch_file}: {e}")
    if not isinstance(batch, list) or not batch:
        die("batch file is empty or not a list")
    bad = [i for i, v in enumerate(batch) if not isinstance(v, dict) or not str(v.get('venue_id', '')).strip()]
    if bad:
        die(f"batch entries without a venue_id: positions {bad}")
    if len(batch) > MAX_BATCH and os.environ.get('ALLOW_LARGE_BATCH') != '1':
        die(f"batch has {len(batch)} venues; the limit is {MAX_BATCH} per batch (P6). "
            f"Split it and register the rest with --append, or set ALLOW_LARGE_BATCH=1.")
    rows = load(rid)
    exists = bool(rows)
    if exists and not appending:
        die(f"run {rid} already exists ({ledger_path(rid)}). To add the next batch of this run "
            f"use --append; for a new run pick another RUN_ID.")
    if appending and not exists and len(pos) < 2:
        die(f"--append: run {rid} has no ledger ({ledger_path(rid)}). Check the RUN_ID.")
    # --append with an explicit new RUN_ID starts the run (plan batches are all registered the same way)
    if not exists and os.path.exists(current_file) and '--new-run' not in flags:
        cur = open(current_file).read().strip()
        if cur and cur != rid and os.path.exists(ledger_path(cur)) and not run_finished(load(cur)):
            die(f"CURRENT run {cur} is not finished (no report mark). Finish it (./verify_run.sh {cur}), "
                f"add this batch to it with --append, or pass --new-run to abandon it.")
    registered = {r.get('venue_id') for r in rows if r.get('step') == 'registered'}
    batch_no = 1 + max([int(r.get('batch') or 1) for r in rows if r.get('step') == 'registered'] or [0])
    new = [v for v in batch if str(v['venue_id']).strip() not in registered]
    skipped = [str(v['venue_id']).strip() for v in batch if str(v['venue_id']).strip() in registered]
    if not new:
        print(f"[mark_step] run {rid}: all {len(batch)} venues already registered — nothing to add")
        sys.exit(0)
    if not exists:
        append(rid, {'type': 'run', 'step': 'start', 'status': 'done',
                     'note': f'batch file {batch_file}', 'count': len(new)})
    append(rid, {'type': 'run', 'step': 'batch', 'status': 'done', 'batch': batch_no,
                 'note': f'batch file {batch_file}', 'count': len(new),
                 'candidate_log_offset': fsize(candidate_log), 'err_log_offset': fsize(err_log)})
    for v in new:
        append(rid, {
            'type': 'venue', 'step': 'registered', 'status': 'done', 'batch': batch_no,
            'venue_id': str(v.get('venue_id', '')).strip(), 'venue_name': v.get('name', ''),
            'website': v.get('website', ''), 'city': v.get('city', ''),
            'state': v.get('state', ''),
        })
    with open(current_file, 'w') as f:
        f.write(rid + '\n')
    print(f"[mark_step] run {rid}: batch {batch_no} registered {len(new)} venues"
          + (f" (skipped {len(skipped)} already registered: {', '.join(skipped)})" if skipped else ''))
    print(f"[mark_step] ledger: {ledger_path(rid)}")
    print(f"[mark_step] run log should be: {os.path.join(runs_dir, rid + '.log')}"
          + (f" (append with >>, or use {rid}.b{batch_no}.log)" if batch_no > 1 else ''))
    print(f"export RUN_ID={rid}")
    sys.exit(0)

# ---------------------------------------------------------------- --show
if args[0] == '--show':
    rid = current_run()
    rows = load(rid)
    print(f"run {rid}: {len(rows)} entries")
    for r in rows:
        whoid = r.get('venue_id') or '(run)'
        b = f"b{r['batch']}" if r.get('batch') else '  '
        print(f"  {r.get('ts','')}  {r.get('by',''):10s} {b:3s} {whoid:16s} {r.get('step',''):12s} "
              f"{r.get('status',''):8s} {r.get('note','')}")
    sys.exit(0)

# ---------------------------------------------------------------- --audit-notes
if args[0] == '--audit-notes':
    rid = args[1] if len(args) > 1 else current_run()
    problems = []
    for i, r in enumerate(load(rid)):
        step, status = r.get('step', ''), r.get('status', 'done')
        if r.get('type') == 'venue' and step in MANUAL_STEPS:
            if step in BLOCKED_ONLY and status != 'BLOCKED':
                why = 'pipeline can only be marked BLOCKED'
            else:
                why = note_problem(step, status, r.get('note', ''))
        elif r.get('type') == 'run' and step in RUN_STEPS:
            why = note_problem(step, status, r.get('note', ''))
            if not why and step == 'report' and status == 'done' and not resolve_report(r.get('note', '')):
                why = 'report file named in the note does not exist'
        else:
            continue
        if why:
            problems.append({'index': i, 'venue_id': r.get('venue_id', ''), 'step': step,
                             'status': status, 'ts': r.get('ts', ''), 'problem': why})
    print(json.dumps(problems))
    sys.exit(0)

# ---------------------------------------------------------------- --run
if args[0] == '--run':
    if len(args) < 2:
        die("usage: --run STEP [done|BLOCKED] \"note\"")
    step = args[1]
    if step not in RUN_STEPS:
        die(f"unknown run step '{step}'. Allowed: {', '.join(RUN_STEPS)}")
    status = args[2] if len(args) > 2 else 'done'
    note = args[3] if len(args) > 3 else ''
    # The status is optional (runbook: --run report "reports/<file>.html"): a lone
    # third argument that isn't a status is the note of a 'done' mark.
    if len(args) == 3 and status not in STATUSES:
        status, note = 'done', args[2]
    if status not in STATUSES:
        die(f"status must be one of {STATUSES}")
    why = note_problem(step, status, note)
    if why:
        die(f"--run {step} {status}: {why} ({HINT.get(step, '')})")
    if step == 'report' and status == 'done' and not resolve_report(note):
        die(f"report file named in the note was not found: {note}")
    rid = current_run()
    append(rid, {'type': 'run', 'step': step, 'status': status, 'note': note})
    print(f"[mark_step] {rid}: run step {step} = {status} {note}")
    sys.exit(0)

# ---------------------------------------------------------------- venue step
if len(args) < 2:
    die("usage: VENUE_ID STEP [done|BLOCKED] \"note\"")
venue_id, step = args[0], args[1]
status = args[2] if len(args) > 2 else 'done'
note = args[3] if len(args) > 3 else ''
if step not in MANUAL_STEPS:
    die(f"unknown step '{step}'. Allowed: {', '.join(MANUAL_STEPS)}")
if status not in STATUSES:
    die(f"status must be one of {STATUSES}")
if step in BLOCKED_ONLY and status != 'BLOCKED':
    die(f"'{step}' can only be marked BLOCKED: ./mark_step.sh {venue_id} {step} BLOCKED \"why\"")
why = note_problem(step, status, note)
if why:
    die(f"{venue_id} {step} {status}: {why} ({HINT.get(step, '')}). "
        f"If you didn't do it, mark BLOCKED with why.")
rid = current_run()
registered = {r.get('venue_id') for r in load(rid) if r.get('step') == 'registered'}
if venue_id not in registered:
    die(f"{venue_id} is not registered in run {rid}. "
        f"Registered: {', '.join(sorted(v for v in registered if v)) or 'none'}")
append(rid, {'type': 'venue', 'venue_id': venue_id, 'step': step,
             'status': status, 'note': note})
print(f"[mark_step] {rid}: {venue_id} {step} = {status} {note}")
PY
