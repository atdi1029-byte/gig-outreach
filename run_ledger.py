#!/usr/bin/env python3
"""
run_ledger.py — JSON ledger for pipeline runs.

The ledger is reports/runs/<run_id>.json.  Structure:

{
  "run_id": "run-20260906-1430",
  "created": "2026-09-06T14:30:00Z",
  "venues": {
    "VA-REST-1234": {
      "name": "Bistro Soleil",
      "steps": {
        "website":        {"status": "done", "at": "...", "evidence": "from pipeline.log"},
        "contact_pages":  {"status": "done", "at": "...", "evidence": "homepage+/contact: events@..."},
        "fb_checked":     {"status": "skip", "at": "...", "evidence": "no page"},
        ...
      }
    }
  },
  "run_steps": {
    "batch_built":        {"status": "done", ...},
    "pipeline_complete":  {"status": "done", ...},
    "postcheck":          {"status": "done", ...},
    "taste_review":       {"status": "done", ...},
    "report_generated":   {"status": "done", ...}
  }
}

CLI:
  python3 run_ledger.py init   <run_id> <batch.json>
  python3 run_ledger.py mark   <run_id> <venue_id> <step> [--status done|skip|blocked] [--evidence "..."]
  python3 run_ledger.py run    <run_id> <step> [--status done|skip|blocked] [--evidence "..."]
  python3 run_ledger.py from-log <run_id> <pipeline.log>
  python3 run_ledger.py verify <run_id>
  python3 run_ledger.py show   <run_id>
"""

import json
import os
import re
import sys
from datetime import datetime, timezone

LEDGER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'reports', 'runs')
os.makedirs(LEDGER_DIR, exist_ok=True)

# Steps the pipeline.sh logs automatically (parsed from pipeline.log)
AUTO_STEPS = ['website', 'social', 'apollo', 'linkedin', 'status_set', 'pipeline_done']

# Steps a human/agent must mark manually
MANUAL_STEPS = ['contact_pages', 'fb_checked', 'ig_checked', 'linkedin_chrome',
                'apollo_enrich', 'open_status', 'verdict']

ALL_VENUE_STEPS = AUTO_STEPS + MANUAL_STEPS

# Run-level steps
RUN_STEPS = ['batch_built', 'pipeline_complete', 'postcheck', 'taste_review', 'report_generated']


def ledger_path(run_id):
    return os.path.join(LEDGER_DIR, f'{run_id}.json')


def load(run_id):
    p = ledger_path(run_id)
    if not os.path.exists(p):
        print(f'ERROR: no ledger at {p}', file=sys.stderr)
        sys.exit(1)
    with open(p) as f:
        return json.load(f)


def save(run_id, data):
    p = ledger_path(run_id)
    with open(p, 'w') as f:
        json.dump(data, f, indent=2)


def now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def cmd_init(run_id, batch_file):
    """Create a new ledger from a batch JSON file."""
    p = ledger_path(run_id)
    if os.path.exists(p):
        print(f'ERROR: ledger {p} already exists', file=sys.stderr)
        sys.exit(1)

    with open(batch_file) as f:
        batch = json.load(f)

    venues = {}
    if isinstance(batch, list):
        for v in batch:
            vid = v.get('venue_id') or v.get('id') or ''
            name = v.get('name') or v.get('venue_name') or ''
            if vid:
                venues[vid] = {'name': name, 'steps': {}}
    elif isinstance(batch, dict) and 'venues' in batch:
        for v in batch['venues']:
            vid = v.get('venue_id') or v.get('id') or ''
            name = v.get('name') or v.get('venue_name') or ''
            if vid:
                venues[vid] = {'name': name, 'steps': {}}

    if not venues:
        print('ERROR: no venues found in batch file', file=sys.stderr)
        sys.exit(1)

    data = {
        'run_id': run_id,
        'created': now(),
        'venues': venues,
        'run_steps': {}
    }
    save(run_id, data)
    # Auto-mark batch_built
    data['run_steps']['batch_built'] = {'status': 'done', 'at': now(),
                                         'evidence': f'{len(venues)} venues from {batch_file}'}
    save(run_id, data)
    print(f'Ledger created: {len(venues)} venues registered in {p}')


def cmd_mark(run_id, venue_id, step, status='done', evidence=''):
    """Mark a venue step."""
    data = load(run_id)

    if venue_id not in data['venues']:
        # Allow 'RUN' as alias for run-level steps
        if venue_id == 'RUN':
            return cmd_run(run_id, step, status, evidence)
        print(f'ERROR: venue {venue_id} not in this run', file=sys.stderr)
        sys.exit(1)

    if step not in ALL_VENUE_STEPS:
        print(f'ERROR: unknown step "{step}". Valid: {", ".join(ALL_VENUE_STEPS)}', file=sys.stderr)
        sys.exit(1)

    if status not in ('done', 'skip', 'blocked'):
        print(f'ERROR: status must be done/skip/blocked, got "{status}"', file=sys.stderr)
        sys.exit(1)

    entry = {'status': status, 'at': now()}
    if evidence:
        entry['evidence'] = evidence
    data['venues'][venue_id]['steps'][step] = entry
    save(run_id, data)
    name = data['venues'][venue_id].get('name', '')
    print(f'{status.upper()}  {venue_id} ({name}) / {step}')


def cmd_run(run_id, step, status='done', evidence=''):
    """Mark a run-level step."""
    data = load(run_id)

    if step not in RUN_STEPS:
        print(f'ERROR: unknown run step "{step}". Valid: {", ".join(RUN_STEPS)}', file=sys.stderr)
        sys.exit(1)

    entry = {'status': status, 'at': now()}
    if evidence:
        entry['evidence'] = evidence
    data['run_steps'][step] = entry
    save(run_id, data)
    print(f'{status.upper()}  RUN / {step}')


def cmd_from_log(run_id, log_file):
    """Parse pipeline.log and mark automated steps that completed."""
    data = load(run_id)
    venue_ids = set(data['venues'].keys())

    with open(log_file) as f:
        lines = f.readlines()

    # Patterns pipeline.sh logs (look at the actual log format)
    # Common patterns: "=== Venue Name (VID) ===" for start,
    # "DONE: VID" or "Step N complete" or section markers
    marked = 0
    current_vid = None

    for line in lines:
        line = line.strip()

        # Match venue start: "=== Some Venue (VA-REST-123) ==="
        m = re.search(r'\(([A-Z]{2}-[A-Z]+-\d+)\)', line)
        if m and m.group(1) in venue_ids:
            current_vid = m.group(1)

        if not current_vid or current_vid not in venue_ids:
            continue

        steps = data['venues'][current_vid]['steps']

        # Website step markers
        if any(kw in line.lower() for kw in ['website scrape', 'step 1', 'fetching website']):
            if 'website' not in steps:
                steps['website'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                marked += 1

        # Social step markers
        if any(kw in line.lower() for kw in ['facebook', 'instagram', 'social', 'step 2']):
            if 'social' not in steps:
                steps['social'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                marked += 1

        # Apollo step markers
        if any(kw in line.lower() for kw in ['apollo', 'step 3']):
            if 'apollo' not in steps:
                steps['apollo'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                marked += 1

        # LinkedIn step markers
        if any(kw in line.lower() for kw in ['linkedin', 'step 4']):
            if 'linkedin' not in steps:
                steps['linkedin'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                marked += 1

        # Status set markers
        if any(kw in line.lower() for kw in ['status_set', 'status → pipelined', 'updating status']):
            if 'status_set' not in steps:
                steps['status_set'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                marked += 1

        # Pipeline done markers
        if any(kw in line.lower() for kw in ['done:', 'complete', '✓']):
            if re.search(r'DONE:\s*' + re.escape(current_vid), line, re.IGNORECASE):
                if 'pipeline_done' not in steps:
                    steps['pipeline_done'] = {'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'}
                    marked += 1

    # Check for batch complete
    full_text = '\n'.join(lines)
    if '=== BATCH COMPLETE ===' in full_text:
        if 'pipeline_complete' not in data['run_steps']:
            data['run_steps']['pipeline_complete'] = {
                'status': 'done', 'at': now(), 'evidence': 'from pipeline.log'
            }

    save(run_id, data)
    print(f'Parsed {log_file}: marked {marked} automated steps')


def cmd_verify(run_id):
    """Check completeness. Exit 0 = pass, exit 1 = fail."""
    data = load(run_id)

    print(f'=== Verifying run: {run_id} ===')
    print()

    missing = []
    blocked = []
    done = 0
    skipped = 0
    total = 0

    # Check each venue
    for vid, vdata in data['venues'].items():
        name = vdata.get('name', '')
        steps = vdata.get('steps', {})

        # Check if pipeline skipped this venue (closed/DNS)
        pipeline_skipped = False
        pd = steps.get('pipeline_done', {})
        if pd.get('status') == 'skip':
            pipeline_skipped = True

        for step in ALL_VENUE_STEPS:
            # If pipeline skipped this venue, auto steps are waived
            if pipeline_skipped and step in AUTO_STEPS:
                continue

            total += 1
            s = steps.get(step, {})
            status = s.get('status', '')

            if status == 'done':
                done += 1
            elif status == 'skip':
                skipped += 1
            elif status == 'blocked':
                blocked.append((vid, name, step, s.get('evidence', '')))
            else:
                missing.append((vid, name, step))

    # Check run-level steps
    for step in RUN_STEPS:
        total += 1
        s = data['run_steps'].get(step, {})
        status = s.get('status', '')
        if status == 'done':
            done += 1
        elif status == 'skip':
            skipped += 1
        elif status == 'blocked':
            blocked.append(('RUN', '', step, s.get('evidence', '')))
        else:
            missing.append(('RUN', '', step))

    # Print blocked
    for vid, name, step, ev in blocked:
        label = f'{vid} ({name})' if name else vid
        print(f'  BLOCKED  {label} / {step}  ({ev})')

    # Print missing with the command to fix
    if missing:
        print()
        for vid, name, step in missing:
            label = f'{vid} ({name})' if name else vid
            print(f'  MISSING  {label} / {step}')
            if vid == 'RUN':
                print(f'           ./mark_step.sh {run_id} RUN {step} --evidence "..."')
            else:
                print(f'           ./mark_step.sh {run_id} {vid} {step} --evidence "..."')

    print()
    print(f'TOTAL: {total}  DONE: {done}  SKIP: {skipped}  BLOCKED: {len(blocked)}  MISSING: {len(missing)}')

    if not missing:
        print()
        print('VERIFY PASS')
        return 0
    else:
        print()
        print(f'VERIFY FAIL — {len(missing)} steps remaining')
        return 1


def cmd_show(run_id):
    """Print a compact matrix of the run."""
    data = load(run_id)
    print(f'Run: {run_id}  Created: {data["created"]}')
    print(f'Venues: {len(data["venues"])}')
    print()

    # Header
    short = {
        'website': 'web', 'social': 'soc', 'apollo': 'apo', 'linkedin': 'li',
        'status_set': 'sts', 'pipeline_done': 'pip',
        'contact_pages': 'cPg', 'fb_checked': 'fb', 'ig_checked': 'ig',
        'linkedin_chrome': 'liC', 'apollo_enrich': 'apE',
        'open_status': 'opn', 'verdict': 'vrd'
    }
    header = f'{"Venue":<20} ' + ' '.join(f'{short.get(s, s[:3]):>3}' for s in ALL_VENUE_STEPS)
    print(header)
    print('-' * len(header))

    for vid, vdata in data['venues'].items():
        name = vdata.get('name', '')[:18]
        steps = vdata.get('steps', {})
        row = f'{name:<20} '
        for step in ALL_VENUE_STEPS:
            s = steps.get(step, {}).get('status', '')
            if s == 'done':
                row += '  +' if step in AUTO_STEPS else '  *'
            elif s == 'skip':
                row += '  -'
            elif s == 'blocked':
                row += '  !'
            else:
                row += '  .'
        print(row)

    print()
    print('Run steps:')
    for step in RUN_STEPS:
        s = data['run_steps'].get(step, {})
        status = s.get('status', 'missing')
        ev = s.get('evidence', '')
        print(f'  {step:<20} {status:>8}  {ev}')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == 'init':
        if len(sys.argv) < 4:
            print('Usage: run_ledger.py init <run_id> <batch.json>', file=sys.stderr)
            sys.exit(1)
        cmd_init(sys.argv[2], sys.argv[3])

    elif cmd == 'mark':
        if len(sys.argv) < 5:
            print('Usage: run_ledger.py mark <run_id> <venue_id> <step> [--status X] [--evidence "..."]',
                  file=sys.stderr)
            sys.exit(1)
        run_id, vid, step = sys.argv[2], sys.argv[3], sys.argv[4]
        status = 'done'
        evidence = ''
        i = 5
        while i < len(sys.argv):
            if sys.argv[i] == '--status' and i + 1 < len(sys.argv):
                status = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == '--evidence' and i + 1 < len(sys.argv):
                evidence = sys.argv[i + 1]
                i += 2
            else:
                i += 1
        cmd_mark(run_id, vid, step, status, evidence)

    elif cmd == 'run':
        if len(sys.argv) < 4:
            print('Usage: run_ledger.py run <run_id> <step> [--status X] [--evidence "..."]',
                  file=sys.stderr)
            sys.exit(1)
        run_id, step = sys.argv[2], sys.argv[3]
        status = 'done'
        evidence = ''
        i = 4
        while i < len(sys.argv):
            if sys.argv[i] == '--status' and i + 1 < len(sys.argv):
                status = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == '--evidence' and i + 1 < len(sys.argv):
                evidence = sys.argv[i + 1]
                i += 2
            else:
                i += 1
        cmd_run(run_id, step, status, evidence)

    elif cmd == 'from-log':
        if len(sys.argv) < 4:
            print('Usage: run_ledger.py from-log <run_id> <pipeline.log>', file=sys.stderr)
            sys.exit(1)
        cmd_from_log(sys.argv[2], sys.argv[3])

    elif cmd == 'verify':
        if len(sys.argv) < 3:
            print('Usage: run_ledger.py verify <run_id>', file=sys.stderr)
            sys.exit(1)
        rc = cmd_verify(sys.argv[2])
        sys.exit(rc)

    elif cmd == 'show':
        if len(sys.argv) < 3:
            print('Usage: run_ledger.py show <run_id>', file=sys.stderr)
            sys.exit(1)
        cmd_show(sys.argv[2])

    else:
        print(f'Unknown command: {cmd}', file=sys.stderr)
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
