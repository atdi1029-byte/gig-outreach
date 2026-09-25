#!/bin/bash
# =============================================================
# verify_run.sh — definition of done AND of "clean" for a pipeline run
#
# A run (one RUN_ID) can hold several batches of <= 8 venues
# (mark_step.sh --batch ... --append). Reads:
#   reports/runs/<RUN_ID>.jsonl        ledger written by mark_step.sh
#   reports/runs/<RUN_ID>.log          stdout of pipeline.sh (+ postcheck); also
#   reports/runs/<RUN_ID>.*.log        per-batch / resume logs (<RUN_ID>.b2.log, ...)
#   reports/runs/<RUN_ID>.misses.jsonl the miss audit (see below)
#   reports/web-coverage/<id>.json     what the website crawl actually fetched
#   reports/discovery-candidates.jsonl found-but-not-saved addresses
#   reports/runs/python-errors.log     python stderr (ERR_LOG)
#   the sheet                          ?action=venue_detail (skip: --no-sheet)
#
# Evidence, not marks:
#   - Automated steps are judged from the C3 lines
#       [STEP] <venue_id> <web|social|apollo|linkedin|postcheck|final> <status> k=v...
#     ok/empty = done; skipped = done only with reason=...; failed/blocked are
#     not done: they need a manual mark (MISSING until then) and always need
#     review. Old logs without [STEP] lines fall back to outcome lines
#     (e.g. "Emails: N | FB: ..."); a step header alone is never evidence.
#     Tracebacks / python errors inside a venue's block are flagged.
#   - Coverage: every source must be proven attempted — website (home,
#     contact, about, events, team pages via the web-coverage file), contact
#     form, Facebook, Instagram, Apollo domain AND name search (counts),
#     LinkedIn people search (count), and the Google contact search when the
#     venue ends with no contact. Anything unproven is a COVERAGE GAP unless
#     the step was skipped for a legitimate reason (e.g. no_website).
#   - Manual marks are re-checked with mark_step.sh's evidence rules.
#   - The sheet: final status per P4, valid/role contact counts, and every
#     contact saved this run (on the sheet? venue's own domain? real name?).
#   - The miss audit file: one JSON line per item the pipeline missed
#     {venue_id, kind, value, source_url, pipeline_had:false, cause_guess}.
#     A line {venue_id, kind:"audited"} may mark a venue audited with no misses.
#     No file (and no `mark_step.sh --run miss_audit` mark) = "miss audit not run".
#
# The last line is the verdict:
#   RUN CLEAN: ...            nothing needs Alex's review
#   RUN NOT CLEAN: ...        counts of missing items, coverage gaps, misses and
#                             other review items (all listed above it)
# Exit: 0 = MISSING: 0 (the gate), 1 = MISSING > 0, 2 = error;
#       with --strict also 3 = gate passed but the run is not clean.
#
# Usage: ./verify_run.sh [RUN_ID] [--json] [--no-sheet] [--strict]
#                        [--embed-report [reports/<file>.html]]
#   --embed-report writes this output (and a JSON summary) into the run's HTML
#   report between <!-- verify_run:begin/end --> markers, replacing an older
#   block. The report step only counts once the report holds a current block.
#   Default report file: the one named in the `--run report` mark.
# Env: REPORTS_DIR relocates reports/ (tests); APPS_SCRIPT_URL overrides .env;
#      VERIFY_SHEET_FIXTURE_DIR=<dir of <venue_id>.json> replaces sheet GETs (tests).
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
REPORTS_DIR="${REPORTS_DIR:-${SCRIPT_DIR}/reports}"
if [ -z "${APPS_SCRIPT_URL:-}" ] && [ -f "${SCRIPT_DIR}/.env" ]; then
    APPS_SCRIPT_URL=$(grep -E '^(export )?APPS_SCRIPT_URL=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
export REPORTS_DIR APPS_SCRIPT_URL

python3 - "$SCRIPT_DIR" "$REPORTS_DIR" "$APPS_SCRIPT_URL" "$@" <<'PY'
import datetime
import glob
import html
import json
import os
import re
import subprocess
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

script_dir, reports_dir, apps_url = sys.argv[1:4]
argv = sys.argv[4:]
sys.path.insert(0, script_dir)
import outreach_rules as R  # noqa: E402

runs_dir = os.path.join(reports_dir, 'runs')
coverage_dir = os.path.join(reports_dir, 'web-coverage')
candidate_log = os.path.join(reports_dir, 'discovery-candidates.jsonl')
err_log = os.environ.get('ERR_LOG') or os.path.join(runs_dir, 'python-errors.log')
pipeline_log = os.path.join(script_dir, 'pipeline.log')
sheet_fixture = os.environ.get('VERIFY_SHEET_FIXTURE_DIR', '')

want_json = '--json' in argv
no_sheet = '--no-sheet' in argv
strict = '--strict' in argv
embed = '--embed-report' in argv
embed_file = ''
pos = []
i = 0
while i < len(argv):
    a = argv[i]
    if a == '--embed-report':
        if i + 1 < len(argv) and not argv[i + 1].startswith('--') and argv[i + 1].lower().endswith(('.html', '.htm')):
            embed_file = argv[i + 1]
            i += 1
    elif not a.startswith('--'):
        pos.append(a)
    i += 1

MANUAL_STEPS = ['web', 'fb', 'ig', 'linkedin', 'apollo', 'status', 'contacts']
AUTO_STEPS = ['web', 'social', 'apollo', 'linkedin', 'final']
OK_STATUSES = ('ok', 'empty')
POSTCHECK_OK_SKIPS = ('has_contacts', 'no_website', 'non_venue_website')
# which manual mark stands in for a failed/blocked automated step (gate only)
AUTO_TO_MANUAL = {'web': ['web'], 'social': ['fb', 'ig'], 'apollo': ['apollo'],
                  'linkedin': ['linkedin'], 'final': ['pipeline']}
# which automated step proves a manual step (a proved step needs no manual mark)
MANUAL_TO_AUTO = {'web': 'web', 'fb': 'social', 'ig': 'social', 'apollo': 'apollo',
                  'linkedin': 'linkedin', 'status': 'final', 'contacts': 'final'}
# a skip for one of these reasons means the source was NOT covered
DEGRADED_SKIP = re.compile(r'credit|quota|budget|disabled|exhaust|limit|wall|captcha|no_api_key|'
                           r'api_key|skip_linkedin|linkedin_off|chrome|timeout|error|down', re.I)
PAGE_CATEGORIES = {
    'contact': re.compile(r'contact|inquir|enquir|get-in-touch|reach-us|reservations?', re.I),
    'about':   re.compile(r'about|our-story|story|history|who-we-are', re.I),
    'events':  re.compile(r'event|private|wedding|catering|banquet|part(y|ies)|meeting|celebrat|function|groups?\b', re.I),
    'team':    re.compile(r'team|staff|leadership|people|management|meet-|our-people|directory|board', re.I),
}
STEP_RE = re.compile(r'\[STEP\]\s+(\S+)\s+([a-z_]+)\s+(ok|empty|failed|skipped|blocked)\b(.*)$')
KV_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')
TS_PREFIX = re.compile(r'^(\[\d{2}:\d{2}:\d{2}\]\s*|\d{2}:\d{2}:\d{2} |\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} )')
HDR_RE = re.compile(r'#{5,} VENUE \[\d+/\d+\]: (.+?) #{5,}')
PIPE_RE = re.compile(r'^\s*PIPELINE: (.+?) \(([^)]+)\)\s*$')
DONE_RE = re.compile(r'^\s*DONE: (.+?) \|.*\|\s*(\d{1,2}:\d{2}:\d{2})\s*$')
DONE_ANY = re.compile(r'^\s*DONE: (.+?) \|')
STARTED_RE = re.compile(r'=== Pipeline started (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ===')
EMAILS_RE = re.compile(r'Emails: (\d+) \| FB: (\S+) \| IG: (\S+) \| Contact Form: (\S+)')
SOCIAL_RE = re.compile(r'^\s*FB: (\S+) \| IG: (\S+)\s*$')
SAVED_RE = re.compile(r'✓ [^:<]*: (.*?) <([^<>@\s]+@[^<>\s]+)>')
STATUS_RE = re.compile(r'Setting status → (\w+)(?: \((\d+|no) )?')
PYERR_RE = re.compile(r'^\s*(?:[\w.]+\.)?[A-Z]\w*(?:Error|Exception): ')   # last line of a python crash
SHERR_RE = re.compile(r'\.sh: line \d+: (.*)$')
SECTION_RE = re.compile(r'={5,} STEP (\w+)')
SECTION_STEP = {'1': 'web', '1B': 'social', '1C': 'social', '2': 'social', '3': 'apollo', '3b': 'apollo',
                '3B': 'apollo', '4': 'linkedin', '5': 'google'}


def die(msg):
    print(f"[verify_run] ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def kvparse(rest):
    return {k: v.strip('"') for k, v in KV_RE.findall(rest or '')}


def local_dt(s):
    try:
        return datetime.datetime.strptime(s, '%Y-%m-%d %H:%M:%S')
    except (TypeError, ValueError):
        return None


def num(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- ledger
rid = pos[0] if pos else os.environ.get('RUN_ID', '').strip()
if not rid:
    cur = os.path.join(runs_dir, 'CURRENT')
    if os.path.exists(cur):
        rid = open(cur).read().strip()
if not rid:
    die("no run id. Pass one, set RUN_ID, or register a batch with mark_step.sh --batch")
ledger_file = os.path.join(runs_dir, f"{rid}.jsonl")
if not os.path.exists(ledger_file):
    die(f"no ledger for {rid} ({ledger_file})")

entries = []
for line in open(ledger_file):
    line = line.strip()
    if line:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass

venues, order, batches = {}, [], {}
for e in entries:
    if e.get('step') == 'registered' and e.get('venue_id'):
        vid = e['venue_id']
        if vid not in venues:
            order.append(vid)
        b = int(e.get('batch') or 1)
        batches.setdefault(b, {'venues': [], 'offsets': None, 'ts': e.get('ts', '')})
        if vid not in batches[b]['venues']:
            batches[b]['venues'].append(vid)
        venues[vid] = {'name': e.get('venue_name', ''), 'website': e.get('website', ''),
                       'state': e.get('state', ''), 'batch': b, 'manual': {}, 'steps': {},
                       'legacy': None, 'done_dt': None, 'skip': '', 'saved': {}, 'errors': {},
                       'sherrors': [], 'google_legacy': False, 'sheet': None, 'coverage': None}
    elif e.get('type') == 'run' and e.get('step') == 'batch':
        batches.setdefault(int(e.get('batch') or 1), {'venues': [], 'offsets': None, 'ts': e.get('ts', '')})
        batches[int(e.get('batch') or 1)]['offsets'] = (e.get('candidate_log_offset'), e.get('err_log_offset'))
if not venues:
    die(f"run {rid} has no registered venues")
run_start = min([local_dt(e.get('ts')) for e in entries if local_dt(e.get('ts'))] or [None]) if entries else None

bad_notes, warnings, audit_error = {}, [], ''
try:
    env = dict(os.environ, REPORTS_DIR=reports_dir)
    out = subprocess.run(['bash', os.path.join(script_dir, 'mark_step.sh'), '--audit-notes', rid],
                         capture_output=True, text=True, timeout=60, env=env)
    for p in json.loads(out.stdout or 'null'):
        bad_notes[p['index']] = p['problem']
except Exception as ex:
    audit_error = f'could not re-check mark notes with mark_step.sh --audit-notes: {ex}'

run_marks = {}
for idx, e in enumerate(entries):
    vid, step = e.get('venue_id'), e.get('step')
    if e.get('type') == 'venue' and vid in venues and step in MANUAL_STEPS + ['pipeline']:
        venues[vid]['manual'][step] = {'status': e.get('status', 'done'), 'note': e.get('note', ''),
                                      'ts': local_dt(e.get('ts')), 'problem': bad_notes.get(idx, '')}
    elif e.get('type') == 'run' and step in ('taste_review', 'report', 'postcheck', 'miss_audit'):
        run_marks[step] = {'status': e.get('status', 'done'), 'note': e.get('note', ''),
                           'problem': bad_notes.get(idx, '')}

# ---------------------------------------------------------------- logs
log_files = [os.path.join(runs_dir, f'{rid}.log')]
log_files += [p for p in glob.glob(os.path.join(runs_dir, f'{rid}.*.log')) if p not in log_files]
log_files = [p for p in log_files if os.path.isfile(p)]
log_files.sort(key=lambda p: os.path.getmtime(p))
log_sources = []
if log_files:
    for p in log_files:
        log_sources.append((p, open(p, errors='ignore').read().split('\n')))
elif os.path.exists(pipeline_log):
    all_lines = open(pipeline_log, errors='ignore').read().split('\n')
    starts = [i for i, l in enumerate(all_lines) if '=== Pipeline started' in l]
    log_sources.append((pipeline_log, all_lines[starts[-1]:] if starts else []))
    warnings.append(f"run log {rid}.log not found — using the LAST block of pipeline.log, which may "
                    f"belong to another run")
else:
    warnings.append("no run log and no pipeline.log — automated steps cannot be verified")

name_to_vid = {v['name'].strip().lower(): vid for vid, v in venues.items() if v['name']}
# pipeline swaps a stale batch id for the sheet's real one: "[ID FIX] 'X' not in sheet — using real ID 'Y'"
IDFIX_RE = re.compile(r"\[ID FIX\] '([^']*)' not in sheet — using real ID '([^']*)'")
alias, real_id = {}, {}
for _p, _lines in log_sources:
    for _l in _lines:
        _m = IDFIX_RE.search(_l)
        if _m and _m.group(1) in venues and _m.group(2):
            alias[_m.group(2)] = _m.group(1)
            real_id[_m.group(1)] = _m.group(2)
chrome_problem = ''
run_stopped = ''
batch_complete_count = 0
postcheck = {'banner': False, 'found_zero': False}
unattributed_py = 0


def new_attempt():
    return {'emails_line': None, 'web_method': '', 'social': None, 'apollo': '', 'linkedin': '',
            'li_people': None, 'final_status': '', 'final_count': None, 'done': False,
            'headers': set(), 'google': False}


for path, lines in log_sources:
    current, section = None, None
    cur_date, last_dt = None, None
    for raw in lines:
        text = TS_PREFIX.sub('', raw).rstrip()
        m = STARTED_RE.search(text)
        if m:
            cur_date = datetime.date.fromisoformat(m.group(1))
            last_dt = datetime.datetime.combine(cur_date, datetime.time.fromisoformat(m.group(2)))
        if '[CHROME] WARNING' in text or '[CHROME] FAIL' in text:
            chrome_problem = text.strip()
        # "[RUN] STOPPED: why" = the run halted (preflight failed, ...); a later start resumes it
        if '[RUN] STOPPED' in text:
            run_stopped = text.split('[RUN] STOPPED', 1)[1].lstrip(': ').strip() or 'no reason given'
        elif '=== Pipeline started' in text or re.match(r'\s*BATCH MODE', text):
            run_stopped = ''
        m = STEP_RE.search(text)
        if m:
            vid, step, status, rest = m.group(1), m.group(2), m.group(3), m.group(4)
            vid = alias.get(vid, vid)
            if vid in venues:
                venues[vid]['steps'][step] = {'status': status, 'kv': kvparse(rest), 'raw': text.strip()}
            continue
        m = HDR_RE.search(text)
        if m:
            vid = name_to_vid.get(m.group(1).strip().lower())
            if vid:
                current, section = vid, None
                venues[vid]['legacy'] = new_attempt()
            continue
        m = PIPE_RE.match(text)
        if m:
            vid = alias.get(m.group(2).strip(), m.group(2).strip())
            vid = vid if vid in venues else name_to_vid.get(m.group(1).strip().lower())
            if vid:
                if current != vid or venues[vid]['legacy'] is None:
                    venues[vid]['legacy'] = new_attempt()
                current, section = vid, None
            else:
                current = None
            continue
        if '=== BATCH COMPLETE ===' in text:
            batch_complete_count += 1
            current = None
            continue
        if 'AUTO-RUNNING POSTCHECK' in text or 'POST-PIPELINE VERIFICATION' in text or 'Post-Pipeline Check Started' in text:
            current = None
        if 'Post-Pipeline Check Complete' in text:
            postcheck['banner'] = True
        if re.search(r'Found 0 unchecked', text):
            postcheck['found_zero'] = True
        if not current:
            if PYERR_RE.search(text):
                unattributed_py += 1
            continue
        v = venues[current]
        a = v['legacy']
        m = SECTION_RE.search(text)
        if m:
            section = SECTION_STEP.get(m.group(1), 'venue')
            a['headers'].add(section)
            if section == 'google':
                a['google'] = True
            if section == 'linkedin' and 'SKIPPED' in text:
                a['linkedin'] = 'wall' if 'wall' in text.lower() else 'skipped'
            continue
        if PYERR_RE.search(text):
            key = section or 'venue'
            v['errors'][key] = v['errors'].get(key, 0) + 1
        m = SHERR_RE.search(text)
        if m and 'Broken pipe' not in text:
            v['sherrors'].append(m.group(1)[:120])
        m = SAVED_RE.search(text)
        if m:
            v['saved'][m.group(2).lower()] = {'name': m.group(1).strip(), 'how': 'log'}
        if '[CURL FALLBACK] Success' in text:
            a['web_method'] = 'curl'
        elif 'Both Chrome and curl' in text:
            a['web_method'] = 'failed'
        mm = EMAILS_RE.search(text)
        if mm and a['emails_line'] is None:
            a['emails_line'] = mm.groups()
        mm = SOCIAL_RE.match(text)
        if mm and section == 'social':
            a['social'] = mm.groups()
        if '[APOLLO MISMATCH]' in text:
            a['apollo'] = 'mismatch'
        elif 'No company found in Apollo' in text:
            a['apollo'] = a['apollo'] or 'none'
        elif re.search(r'Found: .+ \(domain: ', text) and section == 'apollo':
            a['apollo'] = a['apollo'] or 'ok'
        elif re.search(r'Found:\s+\(domain: ', text) and section == 'apollo':
            a['apollo'] = a['apollo'] or 'unknown'
        elif '[SKIP] Apollo step' in text:
            a['apollo'] = a['apollo'] or 'skipped'
        if '[LINKEDIN WALL]' in text:
            a['linkedin'] = 'wall'
        elif '[LINKEDIN EMPTY]' in text or 'No results on page 1' in text:
            a['linkedin'] = a['linkedin'] or 'empty'
        else:
            mm = re.search(r'LinkedIn found (\d+) new people', text)
            if mm:
                a['linkedin'] = a['linkedin'] or 'found'
                a['li_people'] = int(mm.group(1))
            elif re.search(r'^\s*Found (\d+) results', text) and section == 'linkedin':
                a['linkedin'] = a['linkedin'] or 'found'
        mm = STATUS_RE.search(text)
        if mm:
            a['final_status'] = mm.group(1)
            a['final_count'] = (0 if mm.group(2) == 'no' else int(mm.group(2))) if mm.group(2) else None
        if ('[SKIP] Already' in text or 'Venue status prevents' in text or 'closed and skipping' in text
                or '[ABORT] Skipping' in text or '[SKIP-VENUE]' in text):
            v['skip'] = text.strip()
        mm = DONE_RE.match(text) or DONE_ANY.match(text)
        if mm:
            a['done'] = True
            if cur_date and len(mm.groups()) > 1:
                t = datetime.time.fromisoformat(mm.group(2).zfill(8))
                dt = datetime.datetime.combine(cur_date, t)
                if last_dt and dt < last_dt - datetime.timedelta(hours=1):
                    cur_date += datetime.timedelta(days=1)
                    dt = datetime.datetime.combine(cur_date, t)
                last_dt = dt
                v['done_dt'] = dt

# ---------------------------------------------------------------- legacy -> C3 shape
def legacy_steps(v):
    a = v['legacy']
    out = {}
    if not a:
        return out
    if a['emails_line']:
        n, fb, ig, form = a['emails_line']
        via = 'curl' if a['web_method'] == 'curl' else ('none' if a['web_method'] == 'failed' else 'chrome')
        st = 'failed' if via != 'chrome' else ('ok' if int(n) > 0 else 'empty')
        out['web'] = {'status': st, 'kv': {'via': via, 'emails': n, 'form': form,
                                           **({'reason': 'curl_only'} if via == 'curl' else {})}, 'legacy': True}
    elif a['web_method'] == 'failed':
        out['web'] = {'status': 'failed', 'kv': {'reason': 'chrome_and_curl_failed'}, 'legacy': True}
    elif 'web' in a['headers']:
        out['web'] = {'status': 'failed', 'kv': {'reason': 'no_outcome_line'}, 'legacy': True}
    if a['social']:
        fb, ig = a['social']
        st = 'ok' if (fb != 'none' or ig != 'none') else 'empty'
        out['social'] = {'status': st, 'kv': {'fb': fb, 'ig': ig}, 'legacy': True}
    elif 'social' in a['headers']:
        out['social'] = {'status': 'failed', 'kv': {'reason': 'no_outcome_line'}, 'legacy': True}
    ap = a['apollo']
    if ap == 'mismatch':
        out['apollo'] = {'status': 'blocked', 'kv': {'reason': 'apollo_matched_other_company'}, 'legacy': True}
    elif ap == 'none':
        out['apollo'] = {'status': 'empty', 'kv': {}, 'legacy': True}
    elif ap == 'ok':
        out['apollo'] = {'status': 'ok', 'kv': {}, 'legacy': True}
    elif ap == 'unknown':
        out['apollo'] = {'status': 'failed', 'kv': {'reason': 'org_lookup_returned_nothing'}, 'legacy': True}
    elif ap == 'skipped':
        out['apollo'] = {'status': 'skipped', 'kv': {'reason': 'legacy_skip_unknown'}, 'legacy': True}
    elif 'apollo' in a['headers']:
        out['apollo'] = {'status': 'failed', 'kv': {'reason': 'no_outcome_line'}, 'legacy': True}
    li = a['linkedin']
    if li == 'wall':
        out['linkedin'] = {'status': 'blocked', 'kv': {'reason': 'login_wall'}, 'legacy': True}
    elif li == 'skipped':
        out['linkedin'] = {'status': 'skipped', 'kv': {'reason': 'skip_linkedin'}, 'legacy': True}
    elif li == 'empty':
        out['linkedin'] = {'status': 'failed', 'kv': {'reason': 'empty_page'}, 'legacy': True}
    elif li == 'found':
        out['linkedin'] = {'status': 'ok', 'kv': ({'people': str(a['li_people'])} if a['li_people'] is not None else {}),
                           'legacy': True}
    elif 'linkedin' in a['headers']:
        out['linkedin'] = {'status': 'failed', 'kv': {'reason': 'no_outcome_line'}, 'legacy': True}
    if a['done']:
        st = a['final_status'] or 'unknown'
        kv = {'status': st}
        if a['final_count'] is not None:
            kv['valid_contacts'] = str(a['final_count'])
        out['final'] = {'status': 'ok' if st == 'pipelined' else 'empty', 'kv': kv, 'legacy': True}
    if a['google']:
        out['google'] = {'status': 'ok', 'kv': {}, 'legacy': True}
    return out


for vid, v in venues.items():
    for step, res in legacy_steps(v).items():
        if step not in v['steps']:
            v['steps'][step] = res
    fin = v['steps'].get('final')
    if fin and fin['status'] == 'skipped' and not v['skip']:
        v['skip'] = f"final skipped ({fin['kv'].get('reason', 'no reason')})"

# ---------------------------------------------------------------- web-coverage files
for vid, v in venues.items():
    safe = re.sub(r'[^A-Za-z0-9_.-]', '', vid) or 'venue'
    p = os.path.join(coverage_dir, f'{safe}.json')
    if os.path.exists(p):
        try:
            v['coverage'] = json.load(open(p))
            v['coverage_mtime'] = datetime.datetime.fromtimestamp(os.path.getmtime(p))
        except Exception as ex:
            v['coverage'] = {'_error': str(ex)}

# ---------------------------------------------------------------- candidate log + ERR_LOG (this run only)
def read_from(path, offset):
    if not os.path.exists(path):
        return []
    with open(path, 'rb') as f:
        size = os.path.getsize(path)
        if offset and 0 < offset <= size:
            f.seek(offset)
        return f.read().decode('utf-8', errors='replace').split('\n')


offsets = [b['offsets'] for b in batches.values() if b.get('offsets')]
cand_off = min([o[0] for o in offsets if isinstance(o[0], int)] or [0])
err_off = min([o[1] for o in offsets if isinstance(o[1], int)] or [0])
start_utc = run_start.astimezone(datetime.timezone.utc) if run_start else None
candidates = {vid: [] for vid in venues}
for line in read_from(candidate_log, cand_off):
    line = line.strip()
    if not line:
        continue
    try:
        c = json.loads(line)
    except json.JSONDecodeError:
        continue
    c['venue_id'] = alias.get(c.get('venue_id'), c.get('venue_id'))
    if c.get('venue_id') not in venues:
        continue
    if c.get('run_id') and c['run_id'] != rid:
        continue
    if not cand_off and start_utc:
        try:
            t = datetime.datetime.fromisoformat(c.get('timestamp', ''))
            if t.tzinfo is None:
                t = t.replace(tzinfo=datetime.timezone.utc)
            if t < start_utc - datetime.timedelta(hours=12):
                continue
        except ValueError:
            continue
    candidates[c['venue_id']].append(c)
    disp = str(c.get('disposition', ''))
    if disp.startswith('saved_valid') or disp.startswith('saved_role') or disp == 'saved':
        venues[c['venue_id']]['saved'].setdefault(str(c.get('email', '')).lower(),
                                                  {'name': c.get('name', ''), 'how': 'candidate_log'})

py_errors = {vid: 0 for vid in venues}
entry_lines, entries_err = [], []
for line in read_from(err_log, err_off):
    if not line.strip():
        continue
    if line[:1] in (' ', '\t') and entry_lines:
        entry_lines.append(line)
    else:
        if entry_lines:
            entries_err.append('\n'.join(entry_lines))
        entry_lines = [line]
if entry_lines:
    entries_err.append('\n'.join(entry_lines))
for ent in entries_err:
    if not err_off and run_start:
        m = re.match(r'^\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})', ent)
        if not m or (local_dt(m.group(1).replace('T', ' ')) or run_start) < run_start:
            continue
    hit = [vid for vid in venues if vid in ent or (real_id.get(vid) and real_id[vid] in ent)]
    if hit:
        for vid in hit:
            py_errors[vid] += 1
    else:
        unattributed_py += 1

# ---------------------------------------------------------------- sheet
def fetch_detail(vid):
    if sheet_fixture:
        p = os.path.join(sheet_fixture, f'{real_id.get(vid, vid)}.json')
        return json.load(open(p)) if os.path.exists(p) else None
    url = f"{apps_url}?action=venue_detail&venue_id={urllib.parse.quote(real_id.get(vid, vid), safe='')}"
    for _ in range(2):
        try:
            out = subprocess.run(['curl', '-sL', '--max-time', '30', url], capture_output=True,
                                 text=True, timeout=40).stdout
            d = json.loads(out)
            if d.get('status') == 'ok':
                return d
            return {'_error': d.get('message', 'status not ok')}
        except Exception:
            continue
    return None


sheet_ok = False
if not no_sheet:
    with ThreadPoolExecutor(max_workers=6) as pool:
        details = dict(zip(order, pool.map(fetch_detail, order)))
    for vid, d in details.items():
        if d and not d.get('_error'):
            venues[vid]['sheet'] = d
    sheet_ok = all(venues[vid]['sheet'] is not None for vid in order)

# ---------------------------------------------------------------- miss audit
misses_file = os.path.join(runs_dir, f'{rid}.misses.jsonl')
misses, audited, miss_warn = [], set(), []
audit_ran = os.path.exists(misses_file) or (run_marks.get('miss_audit', {}).get('status') == 'done'
                                            and not run_marks['miss_audit'].get('problem'))
if os.path.exists(misses_file):
    for n, line in enumerate(open(misses_file, errors='replace'), 1):
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            miss_warn.append(f'misses line {n} is not JSON')
            continue
        vid = alias.get(m.get('venue_id', ''), m.get('venue_id', ''))
        m['venue_id'] = vid
        if vid not in venues:
            miss_warn.append(f'misses line {n}: venue {vid!r} is not in this run')
            continue
        if str(m.get('kind', '')).lower() in ('audited', 'audit_done'):
            audited.add(vid)
            continue
        audited.add(vid)
        if m.get('pipeline_had') is True:
            continue
        misses.append(m)
if audit_ran and not audited:
    audited = set(order)

# ---------------------------------------------------------------- evaluate
missing, blocked, review = [], [], []   # review: dicts {venue_id, name, kind, step, detail}


def add_review(vid, kind, step, detail):
    review.append({'venue_id': vid, 'name': venues[vid]['name'] if vid in venues else '', 'kind': kind,
                   'step': step, 'detail': detail})


def reason_of(res):
    kv = res.get('kv', {})
    return kv.get('reason') or kv.get('problems') or kv.get('via') or ''


def manual_ok(v, step):
    mk = v['manual'].get(step)
    return bool(mk and not mk['problem'])


def venue_valid_contacts(v):
    if v['sheet']:
        # unverified = saved while ZeroBounce had no credits (Alex's Sep 25 decision); counts for P4
        return sum(1 for c in v['sheet'].get('contacts', [])
                   if str(c.get('verified', '')).lower() in ('valid', 'role', 'unverified') and c.get('email'))
    fin = v['steps'].get('final')
    if fin and num(fin['kv'].get('valid_contacts')) is not None:
        return num(fin['kv'].get('valid_contacts'))
    return None


def page_category_gaps(v):
    cov = v['coverage']
    if cov is None:
        return ['no web-coverage file — the recursive crawl did not run or did not save its pages']
    if cov.get('_error'):
        return [f"web-coverage file unreadable: {cov['_error']}"]
    gaps = []
    c = cov.get('coverage', {})
    gen = cov.get('coverage_generated_at', '')
    if run_start and gen:
        try:
            t = datetime.datetime.fromisoformat(gen)
            if t.tzinfo:
                t = t.astimezone().replace(tzinfo=None)
            if t < run_start - datetime.timedelta(hours=12):
                gaps.append(f'web-coverage file is from {gen[:10]}, before this run — crawl not re-run')
        except ValueError:
            pass
    pages = cov.get('pages', []) or []
    # blocked / throttled / out of time: "no emails" means "not read", not "none there"
    if c.get('blocked'):
        gaps.append(f"site blocked the crawl ({c.get('blocked_reason') or 'bot wall'}) — pages not read")
    if c.get('throttled'):
        gaps.append(f"crawl throttled ({c.get('throttled_reason') or 'rate limited'})")
    if c.get('time_budget_exceeded'):
        gaps.append('crawl stopped at its time budget')
    if not c.get('successful_page_count') and not any(p.get('ok') for p in pages):
        return gaps + ['crawl fetched 0 pages']
    kinds_missing = c.get('page_kinds_missing')
    if kinds_missing is not None:
        v['kinds_missing'] = [k for k in kinds_missing if k != 'home']
        if 'home' in kinds_missing:
            gaps.append('home page was not read')
    elif pages and not any(p.get('ok') and p.get('depth', 1) == 0 for p in pages):
        gaps.append('home page was not fetched')
    hp = num(c.get('high_priority_unvisited_count'))
    if hp:
        ex = (cov.get('high_priority_unvisited') or [''])[0]
        gaps.append(f"{hp} high-priority page(s) found but not visited" + (f" (e.g. {ex})" if ex else ''))
    discovered = set(cov.get('discovered_pages', []) or [])
    for cat, rx in PAGE_CATEGORIES.items():
        tried = [p for p in pages if rx.search(urllib.parse.urlparse(p.get('url', '')).path or '')]
        if not tried or any(p.get('ok') for p in tried):
            continue
        real = [p for p in tried if p.get('url') in discovered and p.get('status') not in (404, 410, '404', '410')]
        if real:
            gaps.append(f"{cat} page linked on the site but not fetched ({real[0].get('url', '')})")
    return gaps


def coverage(vid, v):
    """[(source, detail)] for every source not proven attempted."""
    gaps = []
    st = v['steps']

    def status_gap(step, label):
        res = st.get(step)
        if not res:
            gaps.append((label, f'no {step} result in the run log'))
            return None
        if res['status'] in ('failed', 'blocked'):
            gaps.append((label, f"{step} {res['status']}" + (f" ({reason_of(res)})" if reason_of(res) else '')))
            return None
        if res['status'] == 'skipped':
            r = res['kv'].get('reason', '')
            if not r:
                gaps.append((label, f'{step} skipped without a reason'))
            elif DEGRADED_SKIP.search(r):
                gaps.append((label, f'{step} skipped: {r}'))
            return None
        return res

    web = st.get('web')
    web_skip_ok = web and web['status'] == 'skipped' and web['kv'].get('reason') and not DEGRADED_SKIP.search(web['kv']['reason'])
    if not web_skip_ok:
        res = status_gap('web', 'website')
        if res is not None:
            if res['kv'].get('via', 'chrome') == 'curl':
                gaps.append(('website', 'scraped by curl only (Chrome JavaScript failed)'))
            for g in page_category_gaps(v):
                gaps.append(('website_pages', g))
            form = res['kv'].get('form', res['kv'].get('contact_form', res['kv'].get('form_check')))
            if form is None or str(form).lower() in ('', 'failed', 'blocked', 'error', 'unknown'):
                gaps.append(('contact_form', 'contact-form check not recorded on the web line'))
    soc = status_gap('social', 'social')
    if soc is not None:
        for key, label in (('fb', 'facebook'), ('ig', 'instagram')):
            val = str(soc['kv'].get(key, soc['kv'].get(label, ''))).lower()
            search = str(soc['kv'].get(f'{key}_search', '')).lower()
            if not val:
                gaps.append((label, f'social line has no {key}= result'))
            elif val in ('failed', 'blocked', 'error', 'wall'):
                gaps.append((label, f'{key}={val}'))
            elif search.startswith(('failed', 'blocked')):
                gaps.append((label, f'{key} search {search}'))
            elif val == 'none' and search == 'not_run':
                gaps.append((label, f'no {label} found and the {label} search did not run'))
    ap = status_gap('apollo', 'apollo')
    if ap is not None:
        kv = ap['kv']
        dom = next((kv[k] for k in ('domain_results', 'domain_people', 'domain', 'by_domain') if k in kv), None)
        nam = next((kv[k] for k in ('name_results', 'name_orgs', 'org_results', 'company_results', 'name', 'by_name')
                    if k in kv), None)
        for label, val in (('apollo_domain', dom), ('apollo_name', nam)):
            if val is None:
                gaps.append((label, f'{label.replace("_", " ")} search count not recorded'))
            elif num(val) is None and not str(val).startswith('skipped') and str(val) not in ('none', 'no_domain'):
                gaps.append((label, f'{label.replace("_", " ")} search {val}'))
    li = status_gap('linkedin', 'linkedin')
    if li is not None:
        kv = li['kv']
        cnt = next((kv[k] for k in ('people', 'results', 'found', 'profiles') if k in kv), None)
        if num(cnt) is None:
            gaps.append(('linkedin', 'people search count not recorded'))
    valid = venue_valid_contacts(v)
    if valid == 0:
        g = st.get('google')
        gval = None
        for res in st.values():
            if 'google' in res.get('kv', {}):
                gval = res['kv']['google']
        if g is None and gval is None:
            gaps.append(('google', 'venue has no contact and no Google contact-email search is recorded'))
        elif g is not None and g['status'] in ('failed', 'blocked'):
            gaps.append(('google', f"google search {g['status']}"))
        elif gval is not None and str(gval).lower() in ('failed', 'blocked', 'error'):
            gaps.append(('google', f'google={gval}'))
    return gaps


gap_count = 0
rows = []
for vid in order:
    v = venues[vid]
    st = v['steps']
    auto_col = {}
    skipped_venue = bool(v['skip'])

    # -- automated steps (gate) --
    for step in AUTO_STEPS:
        res = st.get(step)
        if skipped_venue:
            auto_col[step] = 's'
            continue
        if not res:
            if step == 'final' and v['manual'].get('pipeline', {}).get('status') == 'BLOCKED' and manual_ok(v, 'pipeline'):
                auto_col[step] = 'B'
                continue
            auto_col[step] = '.'
            missing.append((vid, step, 'no result in the run log — re-run the venue (pipeline --resume)'))
            continue
        s = res['status']
        if step == 'apollo' and res['kv'].get('reason') in ('org_mismatch', 'apollo_matched_other_company') \
                and not manual_ok(v, 'apollo'):
            auto_col[step] = '!'
            missing.append((vid, 'apollo', 'Apollo only found other companies (org_mismatch) — check Apollo by hand '
                                           'and mark apollo, or BLOCK it with the reason'))
            continue
        if s in OK_STATUSES or (s == 'skipped' and res['kv'].get('reason')):
            auto_col[step] = 'x' if s != 'skipped' else 's'
            if s == 'skipped' and step != 'final' and DEGRADED_SKIP.search(res['kv']['reason']):
                auto_col[step] = '!'
            continue
        if s == 'skipped':
            auto_col[step] = '!'
            add_review(vid, 'skip_without_reason', step, f'{step} skipped without reason=')
            continue
        auto_col[step] = '!'
        stand_in = AUTO_TO_MANUAL[step]
        if not all(manual_ok(v, m) for m in stand_in):
            missing.append((vid, step, f"pipeline {step} {s}" + (f" ({reason_of(res)})" if reason_of(res) else '')
                            + f" — do it by hand and mark {'/'.join(stand_in)}, or mark it BLOCKED with the reason"))
        if step == 'final':
            add_review(vid, 'step_failed', step, f"final {s} ({reason_of(res) or 'no reason'})")

    # -- postcheck: required when the venue ended with no valid/role contact --
    valid = venue_valid_contacts(v)
    pc = st.get('postcheck')
    if not skipped_venue and valid == 0:
        if not pc:
            if not (run_marks.get('postcheck') and not run_marks['postcheck'].get('problem')):
                missing.append((vid, 'postcheck', 'venue has no contact and postcheck did not run for it'))
        elif pc['status'] in ('failed', 'blocked'):
            add_review(vid, 'step_failed', 'postcheck', f"postcheck {pc['status']} ({reason_of(pc) or 'no reason'})")
        elif pc['status'] == 'skipped' and pc['kv'].get('reason') not in POSTCHECK_OK_SKIPS:
            # e.g. reason=time_budget: the second pass never looked at this venue
            add_review(vid, 'coverage_gap', 'postcheck', f"postcheck skipped ({pc['kv'].get('reason') or 'no reason'})")
            gap_count += 1

    # -- coverage --
    if not skipped_venue:
        for source, detail in coverage(vid, v):
            add_review(vid, 'coverage_gap', source, detail)
            gap_count += 1
    else:
        add_review(vid, 'venue_skipped', 'final', v['skip'][:140])

    # -- manual steps (gate) --
    # A manual mark is only needed where there is no automated evidence at all (old
    # logs without [STEP] lines). A failed/blocked automated step already asks for
    # its stand-in mark above, so a venue the pipeline covered needs no marks.
    mcol = {}
    if skipped_venue:
        needed = ['status']
    else:
        needed = [s for s in MANUAL_STEPS if not st.get(MANUAL_TO_AUTO[s])]
    for s in MANUAL_STEPS:
        mk = v['manual'].get(s)
        if s not in needed and (mk is None or skipped_venue):
            mcol[s] = '-'
            continue
        if mk is None:
            mcol[s] = ' '
            missing.append((vid, s, 'no mark'))
        elif mk['problem']:
            mcol[s] = '!'
            missing.append((vid, s, f"mark note rejected: {mk['problem']}"))
        elif mk['status'] == 'BLOCKED':
            mcol[s] = 'B'
            blocked.append((vid, s, mk['note']))
            add_review(vid, 'blocked', s, mk['note'][:140])
        else:
            mcol[s] = 'x'
            if v['done_dt'] and mk['ts'] and mk['ts'] < v['done_dt']:
                mcol[s] = '!'
                missing.append((vid, s, f"marked {mk['ts']:%H:%M} before the pipeline finished this venue "
                                        f"({v['done_dt']:%H:%M}) — re-check and re-mark"))
    pm = v['manual'].get('pipeline')
    if pm and pm['status'] == 'BLOCKED' and not pm['problem']:
        blocked.append((vid, 'pipeline', pm['note']))

    # -- degraded signals --
    # ZeroBounce-deferred emails are saved as unverified while credits are out (Sep 25
    # decision): listed as "needs ZB check", not a cleanliness failure.
    kv_def = sum(num(res.get('kv', {}).get('deferred')) or 0 for step, res in st.items() if step != 'final')
    cand_deferred = {c.get('email') for c in candidates[vid] if c.get('email') and 'deferred' in str(c.get('disposition', ''))}
    v['needs_zb'] = max(kv_def, len(cand_deferred), num((st.get('final') or {}).get('kv', {}).get('deferred')) or 0)
    for key, n in v['errors'].items():
        add_review(vid, 'python_error', key, f'{n} python error(s) in the {key} step (see run log)')
    if py_errors[vid]:
        add_review(vid, 'python_error', 'err_log', f'{py_errors[vid]} entr(ies) in {os.path.basename(err_log)}')
    for e in sorted(set(v['sherrors']))[:3]:
        add_review(vid, 'script_error', 'venue', e)

    # -- candidates worth a look --
    vdom = R.registrable_domain(v['website'] or (v['sheet'] or {}).get('venue', {}).get('website', ''))
    saved_emails = set(v['saved'])
    flagged = set()
    for c in candidates[vid]:
        disp, email = str(c.get('disposition', '')), str(c.get('email', '')).lower()
        if not email or email in saved_emails or email in flagged:
            continue
        if re.match(r'(api_save_failed|api_readback_failed|save_failed|readback_failed|api_error|error)', disp):
            flagged.add(email)
            add_review(vid, 'save_failed', 'save', f'{email}: {disp}')
        elif disp.startswith('verification:') and disp.split(':', 1)[1] in ('catch-all', 'catch_all', 'unknown') \
                and vdom and R.registrable_domain(email.split('@')[-1]) == vdom and not R.is_role_email(email):
            flagged.add(email)
            add_review(vid, 'candidate', 'save', f"{email} ({c.get('name') or 'no name'}) at the venue's own domain "
                                                 f"not saved: ZeroBounce {disp.split(':', 1)[1]}")

    # -- sheet: P4 status, area, and what this run saved --
    sh = v['sheet']
    sheet_status = ''
    if sh:
        venue = sh.get('venue', {}) or {}
        sheet_status = str(venue.get('status') or '')
        fin = st.get('final')
        log_status = (fin or {}).get('kv', {}).get('status', '')
        if skipped_venue:
            if sheet_status in ('untouched', 'pipelined') and not re.search(r'already|status_', v['skip'], re.I):
                add_review(vid, 'status', 'final', f'skipped venue is still {sheet_status} on the sheet (P4: needs_review)')
        else:
            if sheet_status == 'needs_review':
                add_review(vid, 'needs_review', 'final', f"left needs_review ({valid or 0} valid/role contacts)")
            elif sheet_status == 'untouched':
                add_review(vid, 'status', 'final', 'still untouched on the sheet after the run'
                           + (f' (log says it set {log_status})' if log_status and log_status != 'unknown' else ''))
            if valid and sheet_status not in ('pipelined', 'contacted'):
                add_review(vid, 'status', 'final', f'{valid} valid/role contacts but status is {sheet_status} (P4)')
            if valid == 0 and sheet_status == 'pipelined':
                add_review(vid, 'status', 'final', 'pipelined with 0 valid/role contacts on the sheet (P4)')
            if log_status and log_status not in ('unknown',) and sheet_status and log_status != sheet_status \
                    and sheet_status not in ('contacted', 'untouched'):
                add_review(vid, 'status', 'final', f'log says {log_status}, sheet says {sheet_status}')
        state = str(venue.get('state') or v['state'] or '').strip().upper()
        if state and not R.in_target_area(state):
            add_review(vid, 'out_of_area', 'status', f'state {state} is outside {"/".join(R.TARGET_STATES)} (P5)')
        vdom = R.registrable_domain(venue.get('website') or v['website'])
        by_email = {str(c.get('email', '')).lower(): c for c in sh.get('contacts', []) if c.get('email')}
        lost, off, badn = [], [], []
        for email, info in sorted(v['saved'].items()):
            c = by_email.get(email)
            if not c:
                lost.append(email)
                continue
            edom = R.registrable_domain(email.split('@')[-1])
            if vdom and R.is_site_builder_host(vdom):
                # site-builder venue: same on-site-evidence rule the pipeline used
                if R.check_email(email, vdom, venue.get('name') or v.get('name', ''),
                                 found_on_venue_site=True)['reason'].startswith('site_builder_foreign'):
                    off.append(email)
            elif vdom and edom != vdom and edom not in R.FREEMAIL_DOMAINS and not R.is_non_venue_host(vdom):
                off.append(email)
            name = str(c.get('name') or '').strip()
            if name and not R.clean_person_name(name):
                badn.append(f'{name} <{email}>')
        # one item per venue and kind keeps the review list short
        if lost:
            add_review(vid, 'save_not_on_sheet', 'contacts', f'{len(lost)} logged as saved but not on the sheet: '
                                                             + ', '.join(lost[:4]) + (' …' if len(lost) > 4 else ''))
        if off:
            add_review(vid, 'off_domain_contact', 'contacts', f'{len(off)} saved from a domain other than the venue '
                                                              f'site {vdom}: ' + ', '.join(off[:4]) + (' …' if len(off) > 4 else ''))
        if badn:
            add_review(vid, 'bad_name', 'contacts', f'{len(badn)} saved with a name that is not a real first + last '
                                                    f'name: ' + ', '.join(badn[:4]) + (' …' if len(badn) > 4 else ''))
    if not sh and not skipped_venue:
        log_status = (st.get('final') or {}).get('kv', {}).get('status', '')
        if log_status == 'needs_review':
            add_review(vid, 'needs_review', 'final', 'left needs_review (per the final log line; sheet not checked)')
    rows.append((vid, auto_col, mcol, valid, sheet_status))

# ---------------------------------------------------------------- run level
run_ok = {}
all_final = all(venues[vid]['skip'] or venues[vid]['steps'].get('final') for vid in order)
run_ok['batch_complete'] = batch_complete_count >= len(batches) or (all_final and batch_complete_count > 0)
if not run_ok['batch_complete']:
    missing.append(('(run)', 'batch_complete', f'{batch_complete_count} of {len(batches)} batch(es) logged '
                                               f'"=== BATCH COMPLETE ===" — a batch died; resume it'))
if run_stopped:
    missing.append(('(run)', 'run_stopped', f'the run stopped ({run_stopped[:120]}) and was not resumed — '
                                            f'resume it (pipeline --resume / --run)'))
pc_lines = any(v['steps'].get('postcheck') for v in venues.values())
pc_mark = run_marks.get('postcheck')
run_ok['postcheck'] = pc_lines or postcheck['banner'] or bool(pc_mark and not pc_mark['problem'])
if not run_ok['postcheck']:
    missing.append(('(run)', 'postcheck', 'postcheck did not run (no [STEP] postcheck lines, no completion banner)'))
elif postcheck['found_zero'] and not pc_lines and any(venue_valid_contacts(v) == 0 for v in venues.values()):
    add_review('(run)', 'step_failed', 'postcheck', 'postcheck checked 0 venues although some venues have no contact')
for step in ('taste_review', 'report'):
    mk = run_marks.get(step)
    run_ok[step] = bool(mk and not mk['problem'])
    if not mk:
        missing.append(('(run)', step, 'not recorded'))
    elif mk['problem']:
        missing.append(('(run)', step, f"mark note rejected: {mk['problem']}"))
    elif mk['status'] == 'BLOCKED':
        blocked.append(('(run)', step, mk['note']))
        # the old runbook said to BLOCK taste_review when there were no new votes
        if not (step == 'taste_review' and re.search(r'no new (votes?|reviews?|feedback)', mk['note'], re.I)):
            add_review('(run)', 'blocked', step, mk['note'][:140])

report_file = ''
if run_marks.get('report') and run_marks['report']['status'] == 'done':
    for m in re.finditer(r'[\w./~-]+\.html?\b', run_marks['report']['note']):
        p = os.path.expanduser(m.group(0))
        for cand in (p, os.path.join(script_dir, p), os.path.join(reports_dir, p),
                     os.path.join(reports_dir, os.path.basename(p))):
            if os.path.isfile(cand):
                report_file = cand
                break
        if report_file:
            break
if embed:
    report_file = embed_file or report_file
    if embed_file and not os.path.isfile(embed_file):
        die(f"--embed-report: {embed_file} does not exist")
    if not report_file:
        die("--embed-report: no report file (name it, or mark it first: ./mark_step.sh --run report done reports/<file>.html)")

for b, info in sorted(batches.items()):
    if len(info['venues']) > 8:
        add_review('(run)', 'batch_size', 'batch', f'batch {b} has {len(info["venues"])} venues (limit 8, P6)')
if chrome_problem:
    add_review('(run)', 'chrome', 'web', chrome_problem[:160])
if unattributed_py:
    add_review('(run)', 'python_error', 'run', f'{unattributed_py} python error(s) not tied to a venue '
                                               f'(run log / {os.path.basename(err_log)})')
if audit_error:
    add_review('(run)', 'gate_error', 'marks', audit_error)
if not log_files:
    add_review('(run)', 'run_log', 'log', 'no reports/runs/<RUN_ID>.log — automated results unverified')
if no_sheet:
    add_review('(run)', 'sheet_unchecked', 'sheet', 'sheet not checked (--no-sheet): contacts, status and area unverified')
elif not sheet_ok:
    bad = [vid for vid in order if venues[vid]['sheet'] is None]
    missing.append(('(run)', 'sheet', f'could not read venue_detail for {len(bad)} venue(s) '
                                      f'({", ".join(bad[:4])}{"…" if len(bad) > 4 else ""}) — re-run verify_run'))
if not audit_ran:
    add_review('(run)', 'miss_audit', 'audit', 'miss audit not run (no reports/runs/<RUN_ID>.misses.jsonl)')
else:
    for vid in order:
        if vid not in audited and not venues[vid]['skip']:
            add_review(vid, 'miss_audit', 'audit', 'venue not covered by the miss audit')
for w in miss_warn:
    warnings.append(w)
for m in misses:
    add_review(m['venue_id'], 'miss', str(m.get('kind', 'item')),
               f"{m.get('value', '')} ({m.get('source_url', '') or 'no source'})"
               + (f" — cause: {m['cause_guess']}" if m.get('cause_guess') else ''))


# ---------------------------------------------------------------- report block
def summary_counts():
    n_miss = sum(1 for r in review if r['kind'] == 'miss')
    n_gap = sum(1 for r in review if r['kind'] == 'coverage_gap')
    return {'missing': len(missing), 'coverage_gaps': n_gap, 'misses': n_miss,
            'other_review': len(review) - n_miss - n_gap}


BLOCK_RE = re.compile(r'<!-- verify_run:begin -->.*?<!-- verify_run:end -->', re.S)
SUMMARY_RE = re.compile(r'<script type="application/json" id="verify-run-data">(.*?)</script>', re.S)
if run_ok.get('report') and not embed:
    text = open(report_file, errors='ignore').read() if report_file else ''
    blk = BLOCK_RE.search(text)
    if not report_file:
        run_ok['report'] = False
        missing.append(('(run)', 'report', 'report file named in the mark was not found'))
    elif not blk:
        run_ok['report'] = False
        missing.append(('(run)', 'report', f'{os.path.basename(report_file)} has no verify_run block — '
                                           f'run ./verify_run.sh {rid} --embed-report'))
    else:
        try:
            old = json.loads(SUMMARY_RE.search(blk.group(0)).group(1).replace('<\\/', '</'))
        except Exception:
            old = {}
        now = summary_counts()
        if old.get('counts') != now:
            run_ok['report'] = False
            missing.append(('(run)', 'report', f'verify_run block in {os.path.basename(report_file)} is stale '
                                               f'(then {old.get("counts")}, now {now}) — re-run --embed-report'))

def missing_kind(vid, step, why):
    for prefix, kind in (('no mark', 'no_mark'), ('not recorded', 'no_mark'), ('mark note rejected', 'bad_note'),
                         ('marked ', 'mark_before_done'), ('no result in the run log', 'auto_missing'),
                         ('pipeline ', 'auto_failed_unresolved'), ('Apollo only found', 'apollo_mismatch')):
        if why.startswith(prefix):
            return kind
    return {'postcheck': 'postcheck_missing', 'batch_complete': 'batch_incomplete', 'sheet': 'sheet_unreadable',
            'report': 'report_block', 'run_stopped': 'run_stopped'}.get(step, 'other')


MANUAL_KINDS = ('no_mark', 'bad_note', 'mark_before_done', 'auto_failed_unresolved', 'apollo_mismatch')
missing_items = []
for vid, step, why in missing:
    kind = missing_kind(vid, step, why)
    missing_items.append({'venue_id': vid, 'step': step, 'reason': why, 'kind': kind,
                          'needs_manual_mark': kind in MANUAL_KINDS})

counts = summary_counts()
n_venues = len(order)
n_miss_venues = len({m['venue_id'] for m in misses})
if audit_ran:
    denom = len(audited) or n_venues
    miss_part = f'miss rate {100.0 * n_miss_venues / denom:.1f}% ({n_miss_venues} of {denom} audited venues)'
else:
    miss_part = 'miss audit not run'
clean = counts['missing'] == 0 and not review
if clean:
    verdict = f'RUN CLEAN: {n_venues} venues, 0 coverage gaps, 0 misses | {miss_part}'
else:
    parts = []
    for key, label in (('missing', 'missing'), ('coverage_gaps', 'coverage gaps'), ('misses', 'misses'),
                       ('other_review', 'other review items')):
        if counts[key]:
            parts.append(f'{counts[key]} {label}')
    total = counts['missing'] + len(review)
    verdict = f'RUN NOT CLEAN: {total} items need review ({", ".join(parts)}) | {miss_part}'

degraded = [(r['venue_id'], f"{r['kind']} {r['step']}: {r['detail']}") for r in review if r['kind'] != 'miss']
needs_zb = {vid: venues[vid].get('needs_zb', 0) for vid in order if venues[vid].get('needs_zb')}
n_zb = sum(needs_zb.values())
if n_zb:
    verdict += f' | {n_zb} email(s) need a ZB check (saved unverified)'
result = {
    'run_id': rid, 'verdict': verdict, 'clean': clean, 'gate_ok': not missing, 'counts': counts,
    'miss_audit': {'ran': audit_ran, 'misses': len(misses), 'venues_with_misses': n_miss_venues,
                   'audited_venues': len(audited)},
    'missing': missing, 'missing_items': missing_items, 'blocked': blocked, 'degraded': degraded, 'review': review,
    'needs_zb_check': needs_zb, 'id_fixes': real_id,
    'run': run_ok, 'warnings': warnings, 'batches': {str(b): i['venues'] for b, i in sorted(batches.items())},
    'logs': [p for p, _ in log_sources], 'report_file': report_file,
    'venues': {vid: {'name': venues[vid]['name'], 'batch': venues[vid]['batch'], 'skipped': venues[vid]['skip'],
                     'steps': {s: venues[vid]['steps'][s]['status'] for s in venues[vid]['steps']},
                     'valid_contacts': r[3], 'sheet_status': r[4], 'page_kinds_missing': venues[vid].get('kinds_missing', []),
                     'manual': {s: (venues[vid]['manual'].get(s) or {}).get('status') for s in MANUAL_STEPS}}
               for vid, r in zip(order, rows)},
}

# ---------------------------------------------------------------- text output
out = []
out.append(f"RUN {rid}  ({n_venues} venues in {len(batches)} batch{'es' if len(batches) != 1 else ''})")
for p, _ in log_sources:
    out.append(f"  log: {os.path.relpath(p, script_dir) if p.startswith(script_dir) else p}")
for w in warnings:
    out.append(f"  WARNING: {w}")
out.append('')
hdr = f"{'venue':40s} | auto w s a l F | web fb ig li ap st ct | contacts/status"
out.append(hdr)
out.append('-' * len(hdr))
for vid, auto_col, mcol, valid, sheet_status in rows:
    v = venues[vid]
    label = f"{vid} {v['name']}"[:40]
    a = ' '.join(auto_col[s] for s in AUTO_STEPS)
    mc = '  '.join(mcol[s] for s in MANUAL_STEPS)
    info = f"{'?' if valid is None else valid}/{sheet_status or '?'}"
    out.append(f"{label:40s} |      {a} |  {mc}  | {info}")
    if v['skip']:
        out.append(f"{'':40s}   pipeline skipped: {v['skip'][:80]}")
    if v.get('kinds_missing'):
        out.append(f"{'':40s}   site pages not found: {', '.join(v['kinds_missing'])}")
out.append('')
out.append("Run-level: " + '  '.join(f"{s}={'x' if ok else '.'}" for s, ok in run_ok.items()))
out.append("Legend: x done  s skipped(reason)  . missing  B blocked  - n/a  ! failed/degraded or evidence contradicts it")
out.append('')
out.append(f"MISSING: {len(missing)}")
for vid, s, why in missing:
    out.append(f"  {vid:16s} {s:14s} {why}")
out.append(f"BLOCKED: {len(blocked)}")
for vid, s, note in blocked:
    out.append(f"  {vid:16s} {s:14s} {note}")
out.append(f"DEGRADED: {len(degraded)}  (coverage gaps + everything else that needs review)")
for r in review:
    if r['kind'] != 'miss':
        out.append(f"  {r['venue_id']:16s} {r['kind']:18s} {r['step']:14s} {r['detail']}")
out.append(f"NEEDS ZB CHECK: {n_zb}  (saved as unverified while ZeroBounce was unavailable; "
           f"not a cleanliness failure — run ./reverify.sh --unverified after topping up)")
for vid, n in needs_zb.items():
    out.append(f"  {vid:16s} {n} email(s)")
if audit_ran:
    out.append(f"MISSES: {len(misses)}  ({miss_part})")
    for r in review:
        if r['kind'] == 'miss':
            out.append(f"  {r['venue_id']:16s} {r['step']:14s} {r['detail']}")
else:
    out.append("MISSES: miss audit not run")
out.append('')
if missing:
    out.append("NOT DONE. Fix or BLOCK the missing items, then run verify_run.sh again.")
else:
    out.append("DONE (gate passed). Embed this output in the report: ./verify_run.sh " + rid + " --embed-report")
out.append(verdict)
text_out = '\n'.join(out)

if embed:
    summary = dict(result, counts=counts)
    summary = {k: summary[k] for k in ('run_id', 'verdict', 'clean', 'gate_ok', 'counts', 'miss_audit', 'review')}
    data = json.dumps(summary, ensure_ascii=False).replace('</', '<\\/')
    cls = 'clean' if clean else 'not-clean'
    block = ('<!-- verify_run:begin -->\n'
             f'<section id="verify-run" class="verify-run {cls}">\n'
             f'<h2>Run gate (verify_run.sh)</h2>\n'
             f'<p><strong>{html.escape(verdict)}</strong></p>\n'
             f'<pre style="white-space:pre-wrap;font-size:12px">{html.escape(text_out)}</pre>\n'
             f'<script type="application/json" id="verify-run-data">{data}</script>\n'
             '</section>\n'
             '<!-- verify_run:end -->')
    doc = open(report_file, errors='ignore').read()
    if BLOCK_RE.search(doc):
        doc = BLOCK_RE.sub(lambda _m: block, doc, count=1)
    elif re.search(r'</body>', doc, re.I):
        idx = [m.start() for m in re.finditer(r'</body>', doc, re.I)][-1]
        doc = doc[:idx] + block + '\n' + doc[idx:]
    else:
        doc = doc + '\n' + block + '\n'
    tmp = report_file + '.tmp'
    with open(tmp, 'w') as f:
        f.write(doc)
    os.replace(tmp, report_file)
    text_out += f"\n(embedded in {report_file})"

if want_json:
    print(json.dumps(result, indent=2, default=str))
else:
    print(text_out)
if missing:
    sys.exit(1)
if strict and not clean:
    sys.exit(3)
sys.exit(0)
PY
