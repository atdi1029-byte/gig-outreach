#!/bin/bash
# Re-verify emails with "unknown" ZeroBounce status
# Usage: ./reverify.sh [--dry-run]
# Requires: ZEROBOUNCE_KEY in .env, Apps Script URL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ZEROBOUNCE_KEY="${ZEROBOUNCE_KEY:-}"
DRY_RUN=0
if [ "$1" = "--dry-run" ]; then DRY_RUN=1; fi

if [ -z "$ZEROBOUNCE_KEY" ]; then
    echo "ERROR: ZEROBOUNCE_KEY not set. Add it to .env"
    exit 1
fi

# Check credits first
CREDITS=$(curl -s --max-time 10 "https://api.zerobounce.net/v2/getcredits?api_key=$ZEROBOUNCE_KEY" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('Credits',-1))" 2>/dev/null)
echo "ZeroBounce credits available: $CREDITS"

if [ "$CREDITS" -lt 10 ] 2>/dev/null; then
    echo "ERROR: Not enough credits ($CREDITS). Need at least 10."
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

        # Check credits before each email
        if [ "$TOTAL_REVERIFIED" -gt 0 ] && [ $((TOTAL_REVERIFIED % 50)) -eq 0 ]; then
            CUR_CREDITS=$(curl -s --max-time 10 "https://api.zerobounce.net/v2/getcredits?api_key=$ZEROBOUNCE_KEY" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('Credits',-1))" 2>/dev/null)
            echo "  [ZB] Credits remaining: $CUR_CREDITS"
            if [ "$CUR_CREDITS" -lt 5 ] 2>/dev/null; then
                echo "  [STOP] Credits exhausted. Stopping."
                exit 1
            fi
        fi

        # Re-verify
        ZB_STATUS=$(curl -s --max-time 15 "https://api.zerobounce.net/v2/validate?api_key=$ZEROBOUNCE_KEY&email=$EMAIL" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','unknown'))" 2>/dev/null)
        if [ -z "$ZB_STATUS" ]; then ZB_STATUS="unknown"; fi

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

        sleep 1
    done
    echo ""
    sleep 0.3
done

echo ""
echo "=== RE-VERIFICATION COMPLETE ==="
echo "Re-verified: $TOTAL_REVERIFIED"
echo "Now valid: $TOTAL_VALID"
echo "Still unknown: $TOTAL_STILL_UNKNOWN"
