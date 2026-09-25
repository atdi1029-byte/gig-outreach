#!/bin/bash
# Audit the existing untouched pool and move deterministic failures to
# needs_review. No records are deleted. Default is preview-only.
#
#   ./quarantine_pool.sh --limit 250
#   ./quarantine_pool.sh --limit 250 --apply
#
# Uses the same rules build_batch.sh selects with: venue_classifier.TARGET_CATEGORIES
# (classified, not the raw cell) and venue_classifier.junk_reason. Out-of-area rows
# in PA/DE/WV are left alone (P5: kept in the sheet, never batched).
# With --apply each row is re-read first (only still-untouched rows are changed)
# and the reason is appended to check_status ("quarantine <date>: <reason>"),
# which the app treats as a review flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

LIMIT=250
APPLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --limit) LIMIT="${2:-}"; shift 2 || { echo "ERROR: --limit needs a number" >&2; exit 2; } ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 500 ]; then
    echo "ERROR: --limit must be between 1 and 500." >&2
    exit 2
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/quarantine.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK_DIR"' EXIT

for action in venues dashboard; do
    curl -fsSL --max-time 180 "${APPS_SCRIPT_URL}?action=${action}" -o "$WORK_DIR/$action.json" &&
    python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('status') == 'ok' else 1)" "$WORK_DIR/$action.json" 2>/dev/null || {
        echo "ERROR: could not fetch ${action}." >&2
        exit 1
    }
done

MODE="PREVIEW"
[ "$APPLY" -eq 1 ] && MODE="APPLY"
echo "Pool quarantine: $MODE mode, limit $LIMIT"

APPLY="$APPLY" LIMIT="$LIMIT" SCRIPT_DIR="$SCRIPT_DIR" WORK_DIR="$WORK_DIR" \
APPS_SCRIPT_URL="$APPS_SCRIPT_URL" python3 - <<'PY'
import json, os, re, sys, time
import urllib.parse, urllib.request
from datetime import date

sys.path.insert(0, os.environ['SCRIPT_DIR'])
import outreach_rules as R
from venue_classifier import classify, junk_reason, TARGET_CATEGORIES

WORK = os.environ['WORK_DIR']
API = os.environ['APPS_SCRIPT_URL']
APPLY = os.environ['APPLY'] == '1'
LIMIT = int(os.environ['LIMIT'])

venues = json.load(open(os.path.join(WORK, 'venues.json'))).get('venues', [])
if not any('notes' in v for v in venues[:50]):
    dv = {v.get('venue_id'): v for v in json.load(open(os.path.join(WORK, 'dashboard.json'))).get('venues', [])}
    print("WARN: ?action=venues has no notes (old Apps Script backend); using the dashboard's copy.")
    for v in venues:
        for k in ('notes', 'check_status', 'address'):
            if k not in v and k in (dv.get(v.get('venue_id')) or {}):
                v[k] = dv[v['venue_id']][k]

# P5 keeps PA/DE/WV rows in the sheet (never batched); only flag states outside the region.
REGION = set(R.TARGET_STATES) | {'PA', 'DE', 'WV'}
JUNK_HOSTS = ('fox5dc.com', 'washingtonpost.com', 'wtop.com', 'dcpreservation.org',
              'visitmaryland.org', 'virginia.org', 'eventbrite.com')
bad = []
for v in venues:
    if v.get('status', '') != 'untouched':
        continue
    name = (v.get('name') or '').strip()
    city = (v.get('city') or '').strip()
    state = (v.get('state') or '').strip().upper()
    website = (v.get('website') or '').strip()
    reason = ''
    if not website:
        reason = 'missing website'
    elif state not in REGION or not city:
        reason = 'missing/out-of-area city or state'
    elif len(city) > 30 or re.search(r'\d{3,}|https?://|\.com|prices|near me|open now|review|rating', city.lower()):
        reason = 'malformed city'
    else:
        why = junk_reason(name, v.get('category', ''), v.get('notes', ''), website,
                          v.get('check_status', ''))
        c = classify(name, v.get('category', ''), v.get('notes', ''), website, v.get('venue_id', ''))
        host = R.host_of(website)
        if why:
            reason = 'junk: ' + why
        elif c['primary_category'] not in TARGET_CATEGORIES:
            reason = f"non-target category: {c['primary_category']} ({c['classification_source']})"
        elif (R.is_non_venue_host(website) or any(host == j or host.endswith('.' + j) for j in JUNK_HOSTS)
              or host.endswith(('.edu', '.gov', '.mil'))):
            reason = 'junk/non-venue website'
    if reason:
        bad.append((name.lower(), v.get('venue_id', ''), name, reason))
bad = sorted(bad)[:LIMIT]


def get(params):
    with urllib.request.urlopen(API + '?' + urllib.parse.urlencode(params), timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def update(vid, field, value):
    for attempt in (1, 2):
        try:
            if get({'action': 'update_venue', 'venue_id': vid, 'field': field,
                    'value': value}).get('status') == 'ok':
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


flagged = changed = failed = skipped = 0
stamp = date.today().isoformat()
for _, vid, name, reason in bad:
    flagged += 1
    print(f"{vid} | {name} | {reason}")
    if not APPLY:
        continue
    try:
        cur = get({'action': 'venue_detail', 'venue_id': vid}).get('venue') or {}
    except Exception as e:
        print(f"  ERROR: could not re-read venue ({e})")
        failed += 1
        continue
    if cur.get('status') != 'untouched':
        print(f"  SKIP: status is now '{cur.get('status')}', not untouched")
        skipped += 1
        continue
    existing = str(cur.get('check_status') or '').strip()
    note = f"quarantine {stamp}: {reason}".replace('|', '/')
    if not update(vid, 'check_status', f"{existing}|{note}" if existing else note):
        print("  ERROR: could not record the reason; status not changed")
        failed += 1
        continue
    if not update(vid, 'status', 'needs_review'):
        print("  ERROR: status update failed (reason recorded in check_status)")
        failed += 1
        continue
    try:
        back = get({'action': 'venue_detail', 'venue_id': vid}).get('venue') or {}
    except Exception:
        back = {}
    if back.get('status') == 'needs_review':
        changed += 1
    else:
        print("  ERROR: readback did not confirm needs_review")
        failed += 1

mode = 'APPLY' if APPLY else 'PREVIEW'
extra = f" skipped={skipped}" if skipped else ''
print(f"Complete: flagged={flagged} changed={changed} failed={failed}{extra} mode={mode}")
sys.exit(1 if failed else 0)
PY
