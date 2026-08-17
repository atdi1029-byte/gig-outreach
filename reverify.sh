#!/bin/bash
# Re-verify emails with "unknown" ZeroBounce status
# Usage: ./reverify.sh [--dry-run]
# Requires: ZEROBOUNCE_KEY in .env, Apps Script URL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="${ZEROBOUNCE_KEY:-}"
ZB_GUARD="$SCRIPT_DIR/zerobounce_guard.py"
ZB_RUN_ID="${ZB_RUN_ID:-reverify-$(date +%Y%m%dT%H%M%S)-$$}"
export ZB_RUN_ID
# Reverification is intentionally extra-conservative unless the caller sets a cap.
if [ -z "${ZB_MAX_PER_RUN+x}" ]; then export ZB_MAX_PER_RUN="${ZB_REVERIFY_MAX_PER_RUN:-5}"; fi
DRY_RUN=0
if [ "$1" = "--dry-run" ]; then DRY_RUN=1; fi

if [ -z "$ZEROBOUNCE_KEY" ]; then
    echo "ERROR: ZEROBOUNCE_KEY not set. Add it to .env"
    exit 1
fi

# Check the shared ZeroBounce cost guard first (no paid validation here).
BUDGET_JSON=$(python3 "$ZB_GUARD" budget --run-id "$ZB_RUN_ID" 2>/dev/null || true)
if [ -z "$BUDGET_JSON" ]; then
    echo "ERROR: ZeroBounce guard unavailable. Refusing to spend credits."
    exit 1
fi
BUDGET_ALLOWED=$(printf '%s' "$BUDGET_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('allowed',False))" 2>/dev/null || echo False)
BUDGET_SUMMARY=$(printf '%s' "$BUDGET_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("run {}/{}; today {}/{}; balance {}; reserve {}".format(d.get("run_used",0),d.get("run_limit","?"),d.get("day_used",0),d.get("day_limit","?"),d.get("credits_remaining","unknown"),d.get("reserve","?")))' 2>/dev/null || echo unknown)
echo "ZeroBounce safe budget: $BUDGET_SUMMARY"
if [ "$BUDGET_ALLOWED" != "True" ] && [ "$BUDGET_ALLOWED" != "true" ]; then
    echo "ERROR: Paid verification is currently blocked by the cost guard."
    exit 1
fi

# Fetch dashboard and find all unknown contacts
echo "Fetching dashboard..."
curl -sL "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/reverify_dashboard.json

echo "Finding pipelined venues..."
PIPELINED=$(python3 -c "
import json
with open('/tmp/reverify_dashboard.json') as f:
    data = json.load(f)
venues = data.get('venues', [])
pipelined = [v for v in venues if v.get('status') == 'pipelined']
for v in pipelined:
    print(v['venue_id'])
" 2>/dev/null)

TOTAL_UNKNOWN=0
TOTAL_REVERIFIED=0
TOTAL_VALID=0
TOTAL_STILL_UNKNOWN=0

echo "Checking each venue for unknown contacts..."
echo ""

for VID in $PIPELINED; do
    DETAIL=$(curl -sL "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" 2>/dev/null)
    UNKNOWNS=$(echo "$DETAIL" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
venue_name = d.get('venue', {}).get('name', 'Unknown')
contacts = d.get('contacts', [])
unknowns = [c for c in contacts if c.get('verified') == 'unknown']
if unknowns:
    print(f'VENUE:{venue_name}')
    for c in unknowns:
        print(f'{c[\"contact_id\"]}|{c[\"email\"]}|{c.get(\"name\",\"\")}')
" 2>/dev/null)

    if [ -z "$UNKNOWNS" ]; then
        sleep 0.2
        continue
    fi

    VENUE_NAME=$(echo "$UNKNOWNS" | head -1 | sed 's/^VENUE://')
    echo "=== $VENUE_NAME ($VID) ==="

    echo "$UNKNOWNS" | tail -n +2 | while IFS='|' read -r CID EMAIL NAME; do
        if [ -z "$EMAIL" ]; then continue; fi
        TOTAL_UNKNOWN=$((TOTAL_UNKNOWN + 1))

        if [ "$DRY_RUN" = "1" ]; then
            echo "  [DRY] Would re-verify: $EMAIL ($NAME)"
            continue
        fi

        # Re-verify through the shared guard. This script may retry cached unknowns,
        # but is still capped (default 5 paid reverifications per run).
        ZB_JSON=$(python3 "$ZB_GUARD" verify "$EMAIL" --source "reverify" --run-id "$ZB_RUN_ID" --retry-unknown 2>/dev/null || true)
        ZB_STATUS=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','deferred'))" 2>/dev/null || echo deferred)
        ZB_REASON=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo guard_error)
        ZB_CHARGED=$(printf '%s' "$ZB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('charged',False))" 2>/dev/null || echo False)
        echo "  [ZB SAFE] $EMAIL → $ZB_STATUS ($ZB_REASON; charged=$ZB_CHARGED)"
        if [ "$ZB_STATUS" = "deferred" ]; then
            echo "  [STOP] Verification deferred by cost guard. Leaving remaining unknowns untouched."
            break
        fi


        TOTAL_REVERIFIED=$((TOTAL_REVERIFIED + 1))

        if [ "$ZB_STATUS" != "unknown" ]; then
            # Update in sheet
            ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.urlencode({'action':'update_contact_email','contact_id':'$CID','field':'verified','value':'$ZB_STATUS'}))" 2>/dev/null)
            curl -sL "${APPS_SCRIPT_URL}?${ENCODED}" > /dev/null
            echo "  ✓ $EMAIL → $ZB_STATUS ($NAME)"
            if [ "$ZB_STATUS" = "valid" ]; then
                TOTAL_VALID=$((TOTAL_VALID + 1))
            fi
        else
            echo "  ⚠ $EMAIL → still unknown ($NAME)"
            TOTAL_STILL_UNKNOWN=$((TOTAL_STILL_UNKNOWN + 1))
        fi

        if [ "$ZB_CHARGED" = "True" ] || [ "$ZB_CHARGED" = "true" ]; then sleep 1; fi
    done
    echo ""
    sleep 0.3
done

echo ""
echo "=== RE-VERIFICATION COMPLETE ==="
echo "Re-verified: $TOTAL_REVERIFIED"
echo "Now valid: $TOTAL_VALID"
echo "Still unknown: $TOTAL_STILL_UNKNOWN"
