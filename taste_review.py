#!/usr/bin/env python3
"""List venue votes/feedback that haven't been reviewed yet (runbook step 5).

Read-only against the sheet. Prints a markdown block to paste into taste_notes.md,
with each venue's CURRENT taste score and whether the scorer agrees with Alex's
vote, so a review can say exactly which rule in taste_score.py to change.

    python3 taste_review.py            # list unreviewed votes (markdown)
    python3 taste_review.py --mark     # ...and record them as reviewed
    python3 taste_review.py --all      # list every vote, reviewed or not
    python3 taste_review.py --json     # machine-readable list

"Reviewed" = recorded in reports/taste_review_marker.json with the same vote and
feedback (a changed vote shows up again). On the first run, votes whose venue
already appears in taste_notes.md count as reviewed.
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import date, datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from venue_classifier import classify              # noqa: E402
from taste_score import score, bucket, BUCKET_MIN_SCORE, MIN_TASTE_SCORE  # noqa: E402

MARKER = os.path.join(SCRIPT_DIR, 'reports', 'taste_review_marker.json')
NOTES = os.path.join(SCRIPT_DIR, 'taste_notes.md')
DEFAULT_API = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"


def api_url():
    url = os.environ.get('APPS_SCRIPT_URL', '')
    env = os.path.join(SCRIPT_DIR, '.env')
    if not url and os.path.exists(env):
        for line in open(env):
            m = re.match(r'\s*(?:export\s+)?APPS_SCRIPT_URL=["\']?([^"\'\s]+)', line)
            if m:
                url = m.group(1)
    return url or DEFAULT_API


def norm(s):
    return re.sub(r'[^a-z0-9]', '', re.sub(r'^the\s+', '', str(s or '').lower()))


def load_marker():
    if not os.path.exists(MARKER):
        return None
    with open(MARKER) as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--mark', action='store_true', help='record the listed votes as reviewed')
    ap.add_argument('--all', action='store_true', help='list every vote')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--snapshot', help='read a saved ?action=dashboard JSON instead of the API')
    args = ap.parse_args()

    try:
        if args.snapshot:
            dash = json.load(open(args.snapshot))
        else:
            # full=1: the new backend's default (cached) dashboard drops venue address, which
            # taste_score needs for location trust; the old backend ignores the parameter.
            with urllib.request.urlopen(api_url() + '?action=dashboard&full=1', timeout=180) as r:
                dash = json.loads(r.read().decode('utf-8'))
    except Exception as e:
        print(f"ERROR: could not read the dashboard: {e}", file=sys.stderr)
        return 2
    venues = dash.get('venues') or []
    if not venues or 'venue_vote' not in venues[0]:
        print("ERROR: the dashboard returned no venue_vote field; cannot review votes.",
              file=sys.stderr)
        return 2

    voted = [v for v in venues if str(v.get('venue_vote', '')).strip()
             or str(v.get('venue_feedback', '')).strip()]
    marker = load_marker()
    first_run = marker is None
    processed = (marker or {}).get('processed', {})
    notes_text = norm(open(NOTES).read()) if os.path.exists(NOTES) else ''

    todo = []
    for v in voted:
        vid = v.get('venue_id', '')
        vote = str(v.get('venue_vote', '')).strip().lower()
        fb = str(v.get('venue_feedback', '')).strip()
        seen = processed.get(vid)
        if seen and seen.get('vote') == vote and seen.get('feedback') == fb and not args.all:
            continue
        if first_run and not args.all and len(norm(v.get('name'))) >= 5 and norm(v.get('name')) in notes_text:
            continue
        c = classify(v.get('name', ''), v.get('category', ''), v.get('notes', ''),
                     v.get('website', ''), vid)
        s, reasons = score(v, c)
        b = bucket(c, v)
        # Would build_batch pick a venue like this? (bucket + that bucket's floor)
        floor = max(MIN_TASTE_SCORE, BUCKET_MIN_SCORE.get(b, 999)) if b else None
        batchable = bool(b) and s >= floor
        if vote == 'up' and not batchable:
            check = (f"DISAGREES: thumbs up but score {s} / bucket '{b or 'none'}'"
                     f"{f' (floor {floor})' if floor else ''} — build_batch would never pick it")
        elif vote == 'down' and batchable:
            check = f"DISAGREES: thumbs down but score {s} passes bucket '{b}' (floor {floor})"
        else:
            check = f"agrees (score {s}, bucket '{b or 'none'}')"
        todo.append({'venue_id': vid, 'name': v.get('name', ''), 'category': v.get('category', ''),
                     'classified': c['primary_category'], 'city': v.get('city', ''),
                     'state': v.get('state', ''), 'status': v.get('status', ''),
                     'vote': vote, 'feedback': fb, 'taste_score': s, 'bucket': b,
                     'reasons': reasons, 'tags': c['venue_tags'], 'check': check})

    if args.json:
        print(json.dumps(todo, indent=1))
    else:
        label = {'up': 'POSITIVE', 'down': 'NEGATIVE', 'neutral': 'NEUTRAL'}
        print(f"<!-- taste_review.py: {len(voted)} venues have votes/feedback; "
              f"{len(todo)} {'listed' if args.all else 'not yet reviewed'}"
              f"{' (first run: venues already named in taste_notes.md count as reviewed)' if first_run else ''} -->")
        if not todo:
            print("No new votes since the last review.")
        else:
            print(f"\n## {date.today().strftime('%b %d, %Y').replace(' 0', ' ')} — Taste Review "
                  f"({len(todo)} new vote{'s' if len(todo) != 1 else ''})\n")
            for t in todo:
                where = f"{t['city']} {t['state']}".strip()
                tag = label.get(t['vote'], t['vote'].upper() or 'NOTE')
                extra = '' if t['feedback'] else f" (thumbs {t['vote'] or '?'}, no notes)"
                print(f"### {t['name']} ({t['category']}, {where}) — {tag}{extra}")
                if t['feedback']:
                    print(f"> \"{t['feedback']}\"")
                top = '; '.join(r for r in t['reasons'][:4])
                print(f"- **Score now:** {t['taste_score']} [{t['classified']}] — {top}")
                print(f"- **Scorer check:** {t['check']}")
                print("- **Extracted:** _(signals from the vote/feedback)_")
                print("- **Action:** _(taste_score.py / taste_venues.txt change, or 'none')_\n")

    if args.mark:
        os.makedirs(os.path.dirname(MARKER), exist_ok=True)
        m = marker or {'processed': {}}
        stamp = datetime.now().isoformat(timespec='seconds')
        # First run: also record the ones already in taste_notes.md, so the marker is complete.
        rows = voted if first_run else todo
        for v in rows:
            vid = v['venue_id']
            m['processed'][vid] = {'vote': str(v.get('venue_vote', v.get('vote', ''))).strip().lower(),
                                   'feedback': str(v.get('venue_feedback', v.get('feedback', ''))).strip(),
                                   'name': v.get('name', ''), 'marked': stamp}
        m['updated'] = stamp
        tmp = MARKER + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(m, f, indent=1, sort_keys=True)
        os.replace(tmp, MARKER)
        print(f"<!-- marked {len(rows)} vote(s) as reviewed in {os.path.relpath(MARKER, SCRIPT_DIR)} -->")
    return 0


if __name__ == '__main__':
    sys.exit(main())
