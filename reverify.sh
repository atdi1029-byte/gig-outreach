#!/bin/bash
# Re-check contacts with ZeroBounce and write the real verdict back to the sheet
# (action=update_contact, field=verified — works with the old and new backend).
#
# Usage:
#   ./reverify.sh --unverified [--dry-run] [--limit N] [--venue VENUE_ID]
#       Every contact saved as verified=unverified (or legacy "deferred") while
#       ZeroBounce had no credits — on any venue. This is the one command to run
#       after topping up ZeroBounce. Without --limit it may pay for all of them.
#   ./reverify.sh [--dry-run] [--limit N] [--venue VENUE_ID]
#       Legacy mode: contacts marked "unknown" on pipelined venues (default cap 5).
#
# - Every lookup goes through zerobounce_guard.py and cached verdicts come first:
#   an email with a cached verdict is never paid for again (an "unknown" stays
#   cached for 30 days). --dry-run shows how many credits a real run would spend.
# - Paid lookups are capped per run: --limit N, else ZB_MAX_PER_RUN from the
#   caller's environment, else (unverified mode) everything that needs a check,
#   else ZB_REVERIFY_MAX_PER_RUN (default 5). .env's ZB_MAX_PER_RUN is not used.
# - Role mailboxes (info@, events@ ...) are never sent to ZeroBounce (policy P1):
#   one with a real person name is marked verified=role.
# - Junk / no-reply style addresses are not paid for; they are listed for removal.
# - invalid / do_not_mail results are written back AND listed for removal.
# - The first budget deferral stops the run. Every sheet write is checked and read back.
#
# Env: APPS_SCRIPT_URL (else .env, else built in), ZB_GUARD (tests).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1

CALLER_CAP="${ZB_MAX_PER_RUN-}"
CALLER_CAP_SET="${ZB_MAX_PER_RUN+x}"
if ! [ "${ZB_UNKNOWN_CACHE_DAYS:-30}" -ge 30 ] 2>/dev/null; then ZB_UNKNOWN_CACHE_DAYS=30; fi
export ZB_UNKNOWN_CACHE_DAYS="${ZB_UNKNOWN_CACHE_DAYS:-30}"
if [ -z "${APPS_SCRIPT_URL:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    APPS_SCRIPT_URL=$(grep -E '^(export )?APPS_SCRIPT_URL=' "$SCRIPT_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
ZB_GUARD="${ZB_GUARD:-$SCRIPT_DIR/zerobounce_guard.py}"
ZB_RUN_ID="${ZB_RUN_ID:-reverify-$(date +%Y%m%dT%H%M%S)-$$}"
export ZB_RUN_ID

DRY_RUN=0
MODE=unknown
LIMIT=""
ONLY_VENUE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --unverified) MODE=unverified ;;
        --limit) LIMIT="${2:-}"; shift ;;
        --venue) ONLY_VENUE="${2:-}"; shift ;;
        *) echo "Usage: $0 [--unverified] [--dry-run] [--limit N] [--venue VENUE_ID]"; exit 2 ;;
    esac
    shift
done
if [ -n "$LIMIT" ] && ! [ "$LIMIT" -ge 0 ] 2>/dev/null; then echo "ERROR: --limit needs a number"; exit 2; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/reverify.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

echo "Fetching dashboard..."
if ! curl -sL --max-time 120 "${APPS_SCRIPT_URL}?action=dashboard" -o "$TMP/dashboard.json"; then
    echo "ERROR: could not fetch the dashboard"; exit 1
fi

# One row per contact to re-check (US-separated):
#   contact_id venue_id email name current_verified action cached_status
# action: verify | role | skip:<reason> | remove:<reason>; cached_status is set when a
# fresh cached verdict exists (free).
US=$'\x1f'
python3 - "$TMP/dashboard.json" "$SCRIPT_DIR" "$MODE" "$ONLY_VENUE" "$ZB_GUARD" > "$TMP/work.tsv" 2>"$TMP/err" <<'PY'
import json, subprocess, sys
dash_file, script_dir, mode, only, guard = sys.argv[1:6]
sys.path.insert(0, script_dir)
import outreach_rules as R
d = json.load(open(dash_file))
if d.get('status') != 'ok':
    sys.exit(f"dashboard status {d.get('status')!r}: {d.get('message', '')}")
statuses = {'unverified', 'deferred'} if mode == 'unverified' else {'unknown'}
pipelined = {v['venue_id'] for v in d.get('venues', []) if v.get('status') == 'pipelined'}
rows = []
for c in d.get('contacts', []):
    vid = str(c.get('venue_id', ''))
    cur = str(c.get('verified', '')).lower()
    if cur not in statuses or not c.get('email'):
        continue
    if only and vid != only:
        continue
    if not only and mode == 'unknown' and vid not in pipelined:
        continue
    chk = R.check_email(c['email'])          # no venue domain: junk / hard-reject / role only
    if chk['action'] == 'reject':
        action = ('remove:' if mode == 'unverified' else 'skip:') + chk['reason']
    elif chk['is_role']:
        action = 'role' if R.clean_person_name(c.get('name', '')) else 'skip:role_mailbox_without_person_name'
    else:
        action = 'verify'
    rows.append([str(c.get('contact_id', '')), vid, chk['email'] or str(c['email']).strip().lower(),
                 str(c.get('name', '')).replace('\x1f', ' '), cur, action])
emails = [r[2] for r in rows if r[5] == 'verify']
cached = {}
if emails:
    out = subprocess.run([sys.executable, guard, 'lookup'], input='\n'.join(emails), capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit('guard lookup failed: ' + out.stderr.strip()[-200:])
    cached = json.loads(out.stdout or '{}')
# free (cached) checks first, so a budget stop never leaves them undone
rows.sort(key=lambda r: 0 if r[5] != 'verify' or (cached.get(r[2]) or {}).get('fresh') else 1)
for r in rows:
    hit = cached.get(r[2]) or {}
    r.append(hit.get('status', '') if hit.get('fresh') else '')
    print('\x1f'.join(r))
PY
if [ $? -ne 0 ]; then
    echo "ERROR: could not build the list: $(tail -1 "$TMP/err")"; exit 1
fi

N_ROWS=$(grep -c . "$TMP/work.tsv" | tr -d ' ')
N_PAY=$(awk -F"$US" '$6 == "verify" && $7 == ""' "$TMP/work.tsv" | grep -c . | tr -d ' ')
N_CACHED=$(awk -F"$US" '$6 == "verify" && $7 != ""' "$TMP/work.tsv" | grep -c . | tr -d ' ')

# The cap must come from the caller (flag or environment), never from .env.
if [ -n "$LIMIT" ]; then
    export ZB_MAX_PER_RUN="$LIMIT"
elif [ -n "$CALLER_CAP_SET" ]; then
    export ZB_MAX_PER_RUN="$CALLER_CAP"
elif [ "$MODE" = unverified ]; then
    export ZB_MAX_PER_RUN=$(( N_PAY > 0 ? N_PAY : 1 ))
else
    export ZB_MAX_PER_RUN="${ZB_REVERIFY_MAX_PER_RUN:-5}"
fi

BUDGET_JSON=$(python3 "$ZB_GUARD" budget --run-id "$ZB_RUN_ID" 2>"$TMP/err")
if [ -z "$BUDGET_JSON" ]; then
    echo "ERROR: ZeroBounce guard unavailable ($(head -1 "$TMP/err")). Refusing to spend credits."
    exit 1
fi
read -r BUDGET_ALLOWED BUDGET_SUMMARY < <(printf '%s' "$BUDGET_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("allowed", False), "run {}/{}; today {}/{}; balance {}; reserve {}; reason {}".format(d.get("run_used",0), d.get("run_limit","?"), d.get("day_used",0), d.get("day_limit","?"), d.get("credits_remaining","unknown"), d.get("reserve","?"), d.get("reason","?")))')
echo "ZeroBounce safe budget: ${BUDGET_SUMMARY:-unreadable}"
WOULD_PAY=$(( N_PAY < ZB_MAX_PER_RUN ? N_PAY : ZB_MAX_PER_RUN ))
echo "Contacts to re-check ($MODE): $N_ROWS — cached verdicts (free): $N_CACHED, need a paid check: $N_PAY, cap this run: $ZB_MAX_PER_RUN"
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY RUN: a real run would spend up to $WOULD_PAY ZeroBounce credit(s)."
elif [ "$N_PAY" -gt 0 ] && [ "$BUDGET_ALLOWED" != "True" ]; then
    echo "WARNING: paid verification is blocked by the cost guard — only cached verdicts will be applied."
fi
echo ""

# update_verified CONTACT_ID VENUE_ID EMAIL STATUS -> 0 only if the sheet now shows STATUS
update_verified() {
    local cid="$1" vid="$2" email="$3" status="$4" qs resp got
    qs=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode({"action": "update_contact", "contact_id": sys.argv[1], "venue_id": sys.argv[2], "email": sys.argv[3], "field": "verified", "value": sys.argv[4]}))' "$cid" "$vid" "$email" "$status")
    resp=$(curl -sL --max-time 60 "${APPS_SCRIPT_URL}?${qs}")
    if ! printf '%s' "$resp" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status")=="ok" else 1)' 2>/dev/null; then
        echo "    [API ERROR] update_contact: $(printf '%s' "$resp" | head -c 160)"
        return 1
    fi
    qs=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode({"action": "venue_detail", "venue_id": sys.argv[1]}))' "$vid")
    got=$(curl -sL --max-time 60 "${APPS_SCRIPT_URL}?${qs}" | python3 -c '
import json, sys
cid, email = sys.argv[1], sys.argv[2].lower()
d = json.load(sys.stdin)
for c in d.get("contacts", []):
    if str(c.get("contact_id")) == cid and str(c.get("email", "")).lower() == email:
        print(c.get("verified", ""))
        break' "$cid" "$email" 2>/dev/null)
    if [ "$got" != "$status" ]; then
        echo "    [READBACK] sheet shows verified='${got:-?}' after the update (expected $status)"
        return 1
    fi
    return 0
}

TOTAL=0; PAID=0; UPDATED=0; VALID=0; STILL_UNKNOWN=0; SKIPPED=0; FAILED=0; STOPPED=""
: > "$TMP/remove.txt"; : > "$TMP/review.txt"
while IFS="$US" read -r CID VID EMAIL NAME CUR ACTION CACHED_STATUS; do
    [ -z "$EMAIL" ] && continue
    TOTAL=$((TOTAL + 1))
    case "$ACTION" in
        skip:*)
            SKIPPED=$((SKIPPED + 1))
            echo "  - $EMAIL ($VID) skipped: ${ACTION#skip:}"
            [ "$ACTION" = "skip:role_mailbox_without_person_name" ] && echo "$CID  $VID  $EMAIL  role mailbox, no person name" >> "$TMP/review.txt"
            continue ;;
        remove:*)
            SKIPPED=$((SKIPPED + 1))
            echo "  - $EMAIL ($VID) not checked: ${ACTION#remove:}"
            echo "$CID  $VID  $EMAIL  ${ACTION#remove:}" >> "$TMP/remove.txt"
            continue ;;
        role)
            if [ "$DRY_RUN" = 1 ]; then echo "  [DRY] $EMAIL ($NAME, $VID) → role (no ZeroBounce call)"; continue; fi
            if update_verified "$CID" "$VID" "$EMAIL" role; then
                UPDATED=$((UPDATED + 1)); echo "  ✓ $EMAIL → role ($NAME)"
            else
                FAILED=$((FAILED + 1))
            fi
            continue ;;
    esac
    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$CACHED_STATUS" ]; then echo "  [DRY] $EMAIL ($NAME, $VID) → cached $CACHED_STATUS (free)"
        else echo "  [DRY] $EMAIL ($NAME, $VID) → needs a paid check"; fi
        continue
    fi
    ZB_JSON=$(python3 "$ZB_GUARD" verify "$EMAIL" --source "reverify" --run-id "$ZB_RUN_ID" 2>>"$TMP/guard_err")
    IFS=$'\t' read -r ZB_STATUS ZB_REASON ZB_CHARGED ZB_CACHED < <(printf '%s' "$ZB_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\t".join(str(d.get(k, "")) for k in ("status", "reason", "charged", "cached")))' 2>/dev/null)
    ZB_STATUS="${ZB_STATUS:-deferred}"
    echo "  [ZB SAFE] $EMAIL → $ZB_STATUS (${ZB_REASON:-guard_error}; charged=${ZB_CHARGED:-?}; cache=${ZB_CACHED:-?})"
    [ "$ZB_CHARGED" = "True" ] && PAID=$((PAID + 1))
    if [ "$ZB_STATUS" = "deferred" ] || [ "$ZB_STATUS" = "pending" ]; then
        STOPPED="${ZB_REASON:-guard_error}"
        echo "  [STOP] Verification deferred by the cost guard ($STOPPED). Leaving the remaining contacts untouched."
        break
    fi
    case "$ZB_STATUS" in
        spamtrap) NEW=invalid ;;
        abuse) NEW=do_not_mail ;;
        catch_all) NEW=catch-all ;;
        *) NEW="$ZB_STATUS" ;;
    esac
    case "$NEW" in
        invalid|do_not_mail) echo "$CID  $VID  $EMAIL  zerobounce $ZB_STATUS" >> "$TMP/remove.txt" ;;
        catch-all|unknown) echo "$CID  $VID  $EMAIL  zerobounce $NEW (policy: not sendable-verified)" >> "$TMP/review.txt" ;;
    esac
    if [ "$NEW" = "$CUR" ]; then
        [ "$NEW" = "unknown" ] && STILL_UNKNOWN=$((STILL_UNKNOWN + 1))
        echo "  = $EMAIL still $NEW ($NAME)"
    elif update_verified "$CID" "$VID" "$EMAIL" "$NEW"; then
        UPDATED=$((UPDATED + 1))
        [ "$NEW" = "valid" ] && VALID=$((VALID + 1))
        [ "$NEW" = "unknown" ] && STILL_UNKNOWN=$((STILL_UNKNOWN + 1))
        echo "  ✓ $EMAIL → $NEW ($NAME)"
    else
        FAILED=$((FAILED + 1))
    fi
    [ "$ZB_CHARGED" = "True" ] && sleep 1
done < "$TMP/work.tsv"

echo ""
[ "$DRY_RUN" = 1 ] && MODE_LABEL="$MODE, dry run" || MODE_LABEL="$MODE"
echo "=== RE-VERIFICATION COMPLETE ($MODE_LABEL) ==="
echo "Contacts seen: $TOTAL"
if [ "$DRY_RUN" = 1 ]; then
    echo "Would spend up to: $WOULD_PAY credit(s) ($N_CACHED cached verdicts are free)"
else
    echo "Paid lookups: $PAID (cap ${ZB_MAX_PER_RUN}/run)"
    echo "Sheet updated (read back): $UPDATED"
    echo "Now valid: $VALID"
    echo "Still unknown: $STILL_UNKNOWN"
    echo "Update failures: $FAILED"
fi
echo "Skipped (junk / role without name): $SKIPPED"
[ -n "$STOPPED" ] && echo "Stopped early: $STOPPED"
if [ -s "$TMP/remove.txt" ]; then
    echo ""
    echo "FLAGGED FOR REMOVAL ($(grep -c . "$TMP/remove.txt" | tr -d ' ')) — contact_id  venue_id  email  why:"
    sed 's/^/  /' "$TMP/remove.txt"
fi
if [ -s "$TMP/review.txt" ]; then
    echo ""
    echo "NEEDS A LOOK ($(grep -c . "$TMP/review.txt" | tr -d ' ')):"
    sed 's/^/  /' "$TMP/review.txt"
fi
[ -s "$TMP/guard_err" ] && { echo "Guard errors:"; sed 's/^/  /' "$TMP/guard_err" | tail -5; }
[ "$FAILED" -eq 0 ] || exit 1
exit 0
