#!/bin/bash
# =============================================================
# Re-score Pool — recompute taste_score for ALL untouched venues
#
# Usage:
#   ./rescore_pool.sh                 — preview only (default)
#   ./rescore_pool.sh --limit 50      — preview; list the top 50
#   ./rescore_pool.sh --apply         — write taste_score + taste_reasons for
#                                       every row whose score changed
#   ./rescore_pool.sh --apply --limit 50   — write at most 50 changed rows
#
# Steps:
#   1. Classify every untouched venue (venue_classifier.py)
#   2. Score it (taste_score.py — the same score build_batch ranks by)
#   3. Write taste_score / taste_reasons (and taste_score_version when the
#      sheet has that column). NEVER writes the category column: classifier
#      output is not a correction (Aug 23 rescore turned clubs into 'unknown').
#
# Before any write it saves every row it will change (old + new values) to
# reports/rescore-backups/rescore-<stamp>.json. Rows whose stored score already
# matches are skipped, so re-running after an interruption resumes.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

APPLY=0
LIMIT=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --limit)
            LIMIT="${2:-}"; shift 2 || { echo "ERROR: --limit needs a number" >&2; exit 2; }
            if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
                echo "ERROR: --limit must be a positive number." >&2; exit 2
            fi ;;
        *) echo "ERROR: unknown argument: $1 (use --apply, --limit N)" >&2; exit 2 ;;
    esac
done

if [ "$APPLY" = "0" ]; then
    echo "[DRY RUN] Preview only. Use --apply to update the sheet."
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rescore.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK_DIR"' EXIT

fetch() {  # fetch ACTION OUTFILE
    local try
    for try in 1 2 3; do
        if curl -fsSL --max-time 180 "${APPS_SCRIPT_URL}?action=$1" -o "$2" 2>/dev/null &&
           python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status') == 'ok' else 1)" "$2" 2>/dev/null; then
            return 0
        fi
        sleep $((try * 5))
    done
    echo "ERROR: could not fetch ?action=$1 ($(head -c 200 "$2" 2>/dev/null))" >&2
    return 1
}

echo "Fetching all venues..."
fetch venues "$WORK_DIR/venues.json" || exit 1
fetch dashboard "$WORK_DIR/dashboard.json" || exit 1

cd "$SCRIPT_DIR" || exit 1

APPLY="$APPLY" LIMIT="$LIMIT" SCRIPT_DIR="$SCRIPT_DIR" WORK_DIR="$WORK_DIR" \
APPS_SCRIPT_URL="$APPS_SCRIPT_URL" python3 - <<'PYEOF'
import json, os, sys, time
import urllib.parse, urllib.request
from collections import Counter
from datetime import datetime

SCRIPT_DIR = os.environ['SCRIPT_DIR']
sys.path.insert(0, SCRIPT_DIR)
APPLY = os.environ['APPLY'] == '1'
LIMIT = int(os.environ['LIMIT'] or 0)
API = os.environ['APPS_SCRIPT_URL']
WORK = os.environ['WORK_DIR']

from venue_classifier import classify, ID_CODE_MAP, GENERIC_SLUGS
from taste_score import score as taste_score, SCORE_VERSION

venues = json.load(open(os.path.join(WORK, 'venues.json'))).get('venues', [])
dash = json.load(open(os.path.join(WORK, 'dashboard.json')))
if not venues:
    print("ERROR: ?action=venues returned no venues", file=sys.stderr)
    sys.exit(3)
# Old backend: ?action=venues lacks notes/address/taste_score; the dashboard has them.
RICH = ('notes', 'address', 'distance_miles', 'drive_minutes', 'taste_score',
        'taste_reasons', 'taste_score_version', 'venue_vote', 'check_status')
if not any('notes' in v for v in venues[:50]):
    dv = {v.get('venue_id'): v for v in (dash.get('venues') or [])}
    print("WARN: ?action=venues has no notes/taste_score (old Apps Script backend); "
          "using the dashboard's copy until the backend is redeployed.")
    for v in venues:
        for k in RICH:
            if k not in v and k in (dv.get(v.get('venue_id')) or {}):
                v[k] = dv[v['venue_id']][k]
if not any('notes' in v for v in venues[:50]):
    print("ERROR: no source returns venue notes; scores would be name-only. Aborting.",
          file=sys.stderr)
    sys.exit(3)
HAS_REASONS = any('taste_reasons' in v for v in venues[:50])
HAS_VERSION = any('taste_score_version' in v for v in venues[:50])

untouched = [v for v in venues if v.get('status') == 'untouched']
print(f"Total venues: {len(venues)}")
print(f"Untouched: {len(untouched)}")


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


results = []
for v in untouched:
    c = classify(v.get('name', ''), v.get('category', ''), v.get('notes', ''),
                 v.get('website', ''), v.get('venue_id', ''))
    ts, reasons = taste_score(v, c)
    reasons_str = ' | '.join(reasons)
    old = num(v.get('taste_score'))
    changed = old is None or str(v.get('taste_score', '')).strip() == '' or abs(old - ts) > 0.05
    if not changed and HAS_REASONS and (v.get('taste_reasons') or '') != reasons_str:
        changed = True
    results.append({
        'venue_id': v['venue_id'], 'name': v.get('name', ''),
        'raw_category': v.get('category', ''),
        'classified_category': c['primary_category'],
        'source': c['classification_source'],
        'confidence': c['classification_confidence'],
        'tags': c['venue_tags'], 'taste_score': ts, 'reasons': reasons,
        'reasons_str': reasons_str, 'old_score': v.get('taste_score', ''),
        'old_reasons': v.get('taste_reasons', ''), 'changed': changed,
        'city': v.get('city', ''), 'state': v.get('state', ''),
    })
results.sort(key=lambda x: -x['taste_score'])

print(f"\nScore distribution (taste_score {SCORE_VERSION}):")
for lo, hi in [(60, 101), (50, 60), (40, 50), (30, 40), (25, 30), (1, 25), (0, 1)]:
    n = sum(1 for r in results if lo <= r['taste_score'] < hi)
    print(f"  {lo:3d}-{min(hi, 100):3d}: {n:4d} venues")

todo = [r for r in results if r['changed']]
print(f"\nScores that differ from the sheet: {len(todo)} / {len(results)}")

# The category column is never written; show disagreements for a human.
disagree = [r for r in results
            if (r['raw_category'] or '').lower().replace(' ', '_') != r['classified_category']]
print(f"Category disagreements (NOT written): {len(disagree)}")
for change, count in Counter(f"{r['raw_category']} -> {r['classified_category']}"
                             for r in disagree).most_common(12):
    print(f"  {change}: {count}")
# Rows whose generic category cell contradicts the type code in their venue_id:
# most likely overwritten by an earlier rescore. Listed for a manual data repair.
damaged = []
for r in results:
    code = r['venue_id'].split('-')[1].upper() if r['venue_id'].count('-') >= 2 else ''
    cell = (r['raw_category'] or '').lower()
    if code in ID_CODE_MAP and cell in GENERIC_SLUGS | {''} and ID_CODE_MAP[code] != cell:
        damaged.append(r)
if damaged:
    print(f"Possible earlier category overwrites (generic cell vs venue_id code): {len(damaged)}")
    for r in damaged[:15]:
        print(f"  {r['venue_id']:16s} {r['name'][:40]:40s} cell={r['raw_category'] or '(blank)'} "
              f"-> id suggests {ID_CODE_MAP[r['venue_id'].split('-')[1].upper()]}")

show_n = LIMIT if LIMIT > 0 else 30
print(f"\n=== TOP {show_n} by taste score ===")
for r in results[:show_n]:
    mark = " *CHANGED*" if r['changed'] else ""
    print(f"  {r['taste_score']:5.0f}  {r['venue_id']:20s}  {r['name'][:40]:40s}  "
          f"[{r['classified_category']}]  {r['city']} {r['state']}{mark}")
    for reason in r['reasons']:
        print(f"         {reason}")

print(f"\n=== BOTTOM 10 ===")
for r in results[-10:]:
    print(f"  {r['taste_score']:5.0f}  {r['venue_id']:20s}  {r['name'][:40]:40s}  "
          f"[{r['classified_category']}]  {r['city']} {r['state']}")

if not APPLY:
    n = min(len(todo), LIMIT) if LIMIT else len(todo)
    print(f"\n[DRY RUN] Would update {n} venues. Run with --apply to execute.")
    sys.exit(0)

todo = todo[:LIMIT] if LIMIT else todo
if not todo:
    print("\nNothing to update.")
    sys.exit(0)

backup_dir = os.path.join(SCRIPT_DIR, 'reports', 'rescore-backups')
os.makedirs(backup_dir, exist_ok=True)
backup = os.path.join(backup_dir, f"rescore-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json")
with open(backup, 'w') as f:
    json.dump({'score_version': SCORE_VERSION, 'rows': [
        {'venue_id': r['venue_id'], 'name': r['name'], 'old_taste_score': r['old_score'],
         'old_taste_reasons': r['old_reasons'], 'new_taste_score': r['taste_score'],
         'new_taste_reasons': r['reasons_str']} for r in todo]}, f, indent=1)
print(f"\nBackup of {len(todo)} rows (old + new values): {backup}")


def update(vid, field, value):
    q = urllib.parse.urlencode({'action': 'update_venue', 'venue_id': vid,
                                'field': field, 'value': value})
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(f"{API}?{q}", timeout=30) as resp:
                d = json.loads(resp.read().decode('utf-8'))
            if d.get('status') == 'ok':
                return True, ''
            err = str(d.get('message') or d)[:120]
        except Exception as e:
            err = f"{type(e).__name__}: {e}"[:120]
        if attempt == 1:
            time.sleep(3)
    return False, err


print(f"\nApplying {len(todo)} score updates to sheet...")
print("(Writing taste_score + taste_reasons; category is never written)")
done, errors = 0, 0
written = {}
for i, r in enumerate(todo, 1):
    fields = [('taste_score', str(r['taste_score'])), ('taste_reasons', r['reasons_str'])]
    if HAS_VERSION:
        fields.append(('taste_score_version', SCORE_VERSION))
    ok_all = True
    for field, value in fields:
        ok, err = update(r['venue_id'], field, value)
        if not ok:
            print(f"  FAIL: {r['venue_id']} {field} ({err})")
            ok_all = False
            break
    if ok_all:
        done += 1
        written[r['venue_id']] = r['taste_score']
    else:
        errors += 1
        if errors >= 20:
            print("  ABORTING: 20+ errors")
            break
    if i % 100 == 0:
        print(f"  ... {i} / {len(todo)} processed")

# Read back once: a fresh snapshot must show the new scores.
mismatch = []
try:
    with urllib.request.urlopen(f"{API}?action=dashboard", timeout=180) as resp:
        fresh = {v.get('venue_id'): v for v in json.loads(resp.read().decode('utf-8')).get('venues', [])}
    for vid, want in written.items():
        got = num((fresh.get(vid) or {}).get('taste_score'))
        if got is None or abs(got - want) > 0.05:
            mismatch.append(vid)
    print(f"Read-back: {len(written) - len(mismatch)} / {len(written)} confirmed")
    for vid in mismatch[:20]:
        print(f"  NOT CONFIRMED: {vid}")
except Exception as e:
    print(f"WARN: read-back failed ({e}); re-run the preview to confirm.")

print("")
print("=== RESCORE COMPLETE ===")
print(f"Updated: {done - len(mismatch)} / {len(todo)}")
if errors or mismatch:
    print(f"Errors: {errors + len(mismatch)}")
sys.exit(1 if (errors or mismatch) else 0)
PYEOF
