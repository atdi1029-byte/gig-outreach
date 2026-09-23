#!/bin/bash
# Audit the existing untouched pool and move deterministic failures to
# needs_review. No records are deleted. Default is preview-only.
#
#   ./quarantine_pool.sh --limit 250
#   ./quarantine_pool.sh --limit 250 --apply

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"

LIMIT=250
APPLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --limit) LIMIT="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 500 ]; then
    echo "ERROR: --limit must be between 1 and 500." >&2
    exit 2
fi

VENUES_JSON="/tmp/outreach_quarantine_venues.json"
FLAGGED_TSV="/tmp/outreach_quarantine_flagged.tsv"

curl -fsSL --max-time 30 "${APPS_SCRIPT_URL}?action=venues" -o "$VENUES_JSON" || {
    echo "ERROR: could not fetch venues." >&2
    exit 1
}

MODE="PREVIEW"
[ "$APPLY" -eq 1 ] && MODE="APPLY"
echo "Pool quarantine: $MODE mode, limit $LIMIT"

# Run Python to produce flagged venues as TSV
LIMIT="$LIMIT" python3 - "$VENUES_JSON" > "$FLAGGED_TSV" <<'PY'
import json, os, re, sys
from urllib.parse import urlparse
with open(sys.argv[1]) as f:
    venues=json.load(f).get('venues',[])
target_states={'MD','VA','DC','PA','DE','WV'}
target_cats={'restaurant','hotel','winery','wine_bar','country_club','private_club','art_gallery','yacht_club','museum','event_venue','music_venue'}
wrong_names=[
    'assisted living','senior living','nursing home','antique','gift shop','gifts',
    'brewery','brewing','golf course','college','university','school','academy',
    'community center','civic association','liquor store','wine store','wine shop',
    'dance studio','recreation center','booking agent','entertainment agency','caterer'
]
junk_domains=[
    'facebook.com','instagram.com','yelp.com','tripadvisor.com','google.com',
    'fox5dc.com','washingtonpost.com','wtop.com','dcpreservation.org',
    'visitmaryland.org','virginia.org','eventbrite.com','opentable.com'
]
bad=[]
for v in venues:
    if v.get('status','untouched') != 'untouched':
        continue
    name=(v.get('name') or '').strip(); city=(v.get('city') or '').strip()
    state=(v.get('state') or '').strip().upper()
    cat=(v.get('category') or '').strip().lower().replace(' ','_')
    website=(v.get('website') or '').strip()
    hay=(name+' '+str(v.get('notes') or '')).lower()
    reason=''
    if not website:
        reason='missing website'
    elif state not in target_states or not city:
        reason='missing/out-of-area city or state'
    elif len(city)>30 or re.search(r'\d{3,}|https?://|\.com|prices|near me|open now|review|rating',city.lower()):
        reason='malformed city'
    elif cat not in target_cats:
        reason='non-target category: '+cat
    elif any(x in hay for x in wrong_names):
        reason='wrong-business keyword'
    else:
        domain=urlparse(website if '://' in website else 'https://'+website).netloc.lower().removeprefix('www.')
        if any(domain == j or domain.endswith('.'+j) for j in junk_domains) or domain.endswith(('.edu','.gov','.mil')):
            reason='junk/non-venue website'
    if reason:
        bad.append((name.lower(),v.get('venue_id',''),name,reason))
for _,vid,name,reason in sorted(bad)[:int(os.environ['LIMIT'])]:
    vals=[vid,name,reason]
    print('\t'.join(str(x).replace('\t',' ').replace('\n',' ') for x in vals))
PY

flagged=0
changed=0
failed=0
while IFS=$'\t' read -r VID NAME REASON; do
    [ -z "$VID" ] && continue
    flagged=$((flagged + 1))
    echo "$VID | $NAME | $REASON"
    if [ "$APPLY" -eq 0 ]; then
        continue
    fi
    encoded=$(python3 -c "
import sys, urllib.parse
print(urllib.parse.urlencode({
    'action':'update_venue','venue_id':'$VID',
    'field':'status','value':'needs_review'
}))
")
    response=$(curl -fsSL --max-time 20 "${APPS_SCRIPT_URL}?${encoded}" 2>/dev/null)
    ok=$(echo "$response" | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('status')=='ok' else 'no')" 2>/dev/null)
    if [ "$ok" != "yes" ]; then
        echo "  ERROR: status update failed"
        failed=$((failed + 1))
        continue
    fi
    readback=$(curl -fsSL --max-time 20 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${VID}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('venue',{}).get('status',''))" 2>/dev/null)
    if [ "$readback" = "needs_review" ]; then
        changed=$((changed + 1))
    else
        echo "  ERROR: readback did not confirm needs_review"
        failed=$((failed + 1))
    fi
done < "$FLAGGED_TSV"

rm -f "$VENUES_JSON" "$FLAGGED_TSV"
echo "Complete: flagged=$flagged changed=$changed failed=$failed mode=$MODE"
