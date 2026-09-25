#!/usr/bin/env python3
"""Add agencies from agent_discovery.json to the outreach sheet as category=agent.

    python3 add_agencies.py            # dry run: show what would be added
    python3 add_agencies.py --apply    # write to the sheet

- Venues are created as needs_review: like every discovered venue, an agency
  needs its website/location checked before build_batch.sh may pick it.
- Only DC/MD/VA agencies are added (P5); the rest are listed as skipped.
- The file's "contacts" are bare names (no email, no title). A pending contact
  needs a real name AND a decision-maker title (P3), so they are not saved;
  they go to reports/discovery-candidates.jsonl instead of being dropped.
- No batch file is written: batches come from build_batch.sh.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import outreach_rules as R  # noqa: E402


def apps_script_url():
    url = os.environ.get('APPS_SCRIPT_URL', '').strip()
    env = os.path.join(SCRIPT_DIR, '.env')
    if not url and os.path.exists(env):
        for line in open(env):
            if line.strip().startswith(('APPS_SCRIPT_URL=', 'export APPS_SCRIPT_URL=')):
                url = line.split('=', 1)[1].strip().strip('"').strip("'")
    return url or "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"


API = apps_script_url()
CANDIDATE_LOG = os.path.join(SCRIPT_DIR, 'reports', 'discovery-candidates.jsonl')


def get(params):
    url = API + '?' + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError:
        # python.org builds on this Mac can't verify TLS; curl can
        out = subprocess.run(['curl', '-sL', '--max-time', '60', url], capture_output=True, text=True).stdout
        return json.loads(out)


def log_candidate(venue_id, name, disposition):
    row = {'timestamp': datetime.now(timezone.utc).isoformat(), 'venue_id': venue_id, 'email': '',
           'name': name, 'title': '', 'source': 'agent_discovery', 'kind': 'person',
           'disposition': disposition, 'evidence_url': ''}
    os.makedirs(os.path.dirname(CANDIDATE_LOG), exist_ok=True)
    with open(CANDIDATE_LOG, 'a', encoding='utf-8') as f:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')


def main(argv):
    apply = '--apply' in argv
    agencies = json.load(open(os.path.join(SCRIPT_DIR, 'agent_discovery.json')))
    print(f"{'Adding' if apply else 'DRY RUN — would add'} agencies from agent_discovery.json "
          f"(category=agent, status=needs_review)")
    added, dup, failed, out_of_area, people = [], [], [], [], 0
    for i, a in enumerate(agencies, 1):
        tag = f"  [{i}/{len(agencies)}] {a['name']:<40}"
        if not R.in_target_area(a.get('state', '')):
            out_of_area.append(f"{a['name']} ({a.get('state') or '?'})")
            print(f"{tag} skipped: {a.get('state') or 'no state'} is outside {'/'.join(R.TARGET_STATES)}")
            continue
        if not apply:
            print(f"{tag} would add ({a.get('city', '')}, {a.get('state', '')}); "
                  f"{len(a.get('contacts', []))} name(s) -> candidate log")
            continue
        params = {
            'action': 'add_venue', 'name': a['name'], 'category': 'agent', 'status': 'needs_review',
            'website': a.get('website', ''), 'city': a.get('city', ''), 'state': a.get('state', ''),
            'source': 'agent_discovery', 'notes': a.get('description', ''),
        }
        try:
            data = get(params)
        except Exception as e:
            print(f"{tag} ERROR: {e}")
            failed.append(a['name'])
            continue
        vid = data.get('venue_id', '')
        if data.get('status') != 'ok' or not vid:
            print(f"{tag} FAILED: {data}")
            failed.append(a['name'])
            continue
        is_dup = data.get('duplicate') or 'Duplicate' in str(data.get('message', ''))
        (dup if is_dup else added).append(vid)
        print(f"{tag} -> {vid} ({'duplicate, left as is' if is_dup else 'added as needs_review'})")
        for name in a.get('contacts', []):
            clean = R.clean_person_name(name)
            log_candidate(vid, clean or name, 'candidate:agency_name_without_title_or_email'
                          if clean else 'reject:not_a_person_name')
            people += 1
        time.sleep(0.3)

    print()
    if apply:
        print(f"Added: {len(added)}  Duplicates: {len(dup)}  Failed: {len(failed)}  Out of area: {len(out_of_area)}")
        print(f"Agency staff names logged as candidates (no email/title, not saved): {people}")
        if failed:
            print(f"FAILED: {failed}")
        print("Next: verify each agency's website/location, promote to untouched, then ./build_batch.sh")
    else:
        print(f"Out of area (not added): {len(out_of_area)}. Run with --apply to write.")
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
