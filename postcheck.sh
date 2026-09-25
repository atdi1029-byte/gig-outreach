#!/bin/bash
# =============================================================
# Post-Pipeline Contact Verification (second pass)
#
# Runs AFTER pipeline.sh on the batch's venues that still have no
# valid/role/unverified contact on the sheet. Re-crawls the website (+ /contact
# /about /events ...), searches Apollo by the venue's own domain,
# searches LinkedIn, and tries to enrich named pending contacts.
#
# Usage:
#   ./postcheck.sh --venues ID1,ID2,... [--run-id RUN_ID]
#       check the listed venues that have 0 valid/role/unverified contacts
#   ./postcheck.sh [--run-id RUN_ID]
#       same, for every venue registered in reports/runs/<RUN_ID>.jsonl
#       (RUN_ID defaults to reports/runs/CURRENT)
#   ./postcheck.sh VA-REST-841 [...]
#       check specific venues even if they already have contacts
#
# Writes follow the pipeline's save policy:
#   - emails go through outreach_rules check-email. Role mailboxes are
#     saved only with a real person name (verified=role). Personal
#     mailboxes are saved when ZeroBounce says valid, or as
#     verified=unverified when it can't check them (deferred: budget, no
#     credits, outage; reverify.sh re-checks them later). invalid,
#     do_not_mail, catch-all and unknown are never saved. Everything not
#     saved is logged to reports/discovery-candidates.jsonl.
#   - pending (email-less) contacts need a real name + decision-maker title.
#   - facebook/instagram/contact_form: only EMPTY fields are filled,
#     never with force=true.
#   - never writes check_status or venue status.
#   - anything found but not saved (uncertain person, rejected social, ...)
#     goes to the candidate log with a disposition, never silently dropped.
# Prints one "[STEP] <venue_id> postcheck <ok|empty|failed|skipped|blocked>"
# line per venue. Python errors go to reports/runs/python-errors.log.
# Exit: 0 = every venue ran; 1 = no venues / bad arguments; 2 = at least
# one venue's postcheck failed, was degraded or was cut by the time budget.
# Env: POSTCHECK_LINKEDIN=0 skips the Chrome/LinkedIn step. While a live
#      pipeline.sh holds /tmp/pipeline.lock.d, Chrome is left alone ("blocked
#      reason=chrome_in_use_by_pipeline") unless PIPELINE_LOCK_PID (exported by
#      that pipeline when it calls postcheck) names it;
#      POSTCHECK_MAX_APOLLO (default 40) caps Apollo credits per run;
#      POSTCHECK_MAX_MINUTES (default 30, 0 = no limit) caps the whole run;
#        venues not reached are reported "skipped reason=time_budget";
#      POSTCHECK_WEB_SECONDS (default 180) / POSTCHECK_MAX_PAGES (default 40)
#        bound the per-venue page fetches (0 = no limit); POSTCHECK_CRAWL_SECONDS (150)
#        bounds the site crawler. The pipeline's own crawl
#        (reports/web-coverage/<id>.json) is reused when younger than
#        POSTCHECK_REUSE_CRAWL_HOURS (default 12).
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
LOG_FILE="${SCRIPT_DIR}/postcheck.log"
APOLLO_API_KEY="${APOLLO_API_KEY:-}"
APOLLO_API_BASE="${APOLLO_API_BASE:-https://api.apollo.io/api/v1}"
# Python reads the key from the environment, never from its source text.
export APOLLO_API_KEY APOLLO_API_BASE
ZB_GUARD="${SCRIPT_DIR}/zerobounce_guard.py"
# Inherit the pipeline's ZB run id when called from pipeline.sh so the per-run cap is shared.
ZB_RUN_ID="${ZB_RUN_ID:-postcheck-$(date +%Y%m%dT%H%M%S)-$$}"
export ZB_RUN_ID
MAX_ZB_PER_VENUE=${MAX_ZB_PER_VENUE:-40}
POSTCHECK_MAX_APOLLO=${POSTCHECK_MAX_APOLLO:-40}
POSTCHECK_LINKEDIN=${POSTCHECK_LINKEDIN:-1}
ENRICH_RETRY_DAYS=${ENRICH_RETRY_DAYS:-30}
POSTCHECK_MAX_MINUTES=${POSTCHECK_MAX_MINUTES:-30}
POSTCHECK_WEB_SECONDS=${POSTCHECK_WEB_SECONDS:-180}
POSTCHECK_CRAWL_SECONDS=${POSTCHECK_CRAWL_SECONDS:-150}
POSTCHECK_MAX_PAGES=${POSTCHECK_MAX_PAGES:-40}
POSTCHECK_REUSE_CRAWL_HOURS=${POSTCHECK_REUSE_CRAWL_HOURS:-12}
[[ "$MAX_ZB_PER_VENUE" =~ ^[0-9]+$ ]] || MAX_ZB_PER_VENUE=40
[[ "$POSTCHECK_MAX_APOLLO" =~ ^[0-9]+$ ]] || POSTCHECK_MAX_APOLLO=40
[[ "$ENRICH_RETRY_DAYS" =~ ^[0-9]+$ ]] || ENRICH_RETRY_DAYS=30
[[ "$POSTCHECK_MAX_MINUTES" =~ ^[0-9]+$ ]] || POSTCHECK_MAX_MINUTES=30
[[ "$POSTCHECK_WEB_SECONDS" =~ ^[0-9]+$ ]] || POSTCHECK_WEB_SECONDS=180
[[ "$POSTCHECK_CRAWL_SECONDS" =~ ^[0-9]+$ ]] || POSTCHECK_CRAWL_SECONDS=150
[[ "$POSTCHECK_MAX_PAGES" =~ ^[0-9]+$ ]] || POSTCHECK_MAX_PAGES=40
[[ "$POSTCHECK_REUSE_CRAWL_HOURS" =~ ^[0-9]+$ ]] || POSTCHECK_REUSE_CRAWL_HOURS=12
RUNS_DIR="${SCRIPT_DIR}/reports/runs"
ERR_LOG="${ERR_LOG:-${RUNS_DIR}/python-errors.log}"
CANDIDATE_LOG="${SCRIPT_DIR}/reports/discovery-candidates.jsonl"
COVERAGE_DIR="${SCRIPT_DIR}/reports/postcheck-web-coverage"
# Written by pipeline.sh's website step for the same venues minutes earlier.
PIPELINE_COVERAGE_DIR="${SCRIPT_DIR}/reports/web-coverage"
# Pending contacts already sent to Apollo people/match, so they aren't re-queried every run.
ENRICH_ATTEMPTS="${SCRIPT_DIR}/reports/postcheck-enrich-attempts.tsv"
OWN_EMAILS="atdi1029@gmail.com|alexbarnettclassical@gmail.com|abar89251@gmail.com|alex@alexbarnettclassical.com"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
# Field separator for python -> bash rows. Not a tab: bash's read collapses empty tab fields.
US=$'\x1f'
mkdir -p "$RUNS_DIR" "$COVERAGE_DIR" "$(dirname "$CANDIDATE_LOG")"
PC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/postcheck.XXXXXX") || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$PC_TMP"' EXIT
echo 0 > "$PC_TMP/apollo_credits"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Machine-readable per-venue result (one line per venue).
step_line() {
    local vid="$1" status="$2"; shift 2
    log "[STEP] $vid postcheck $status${*:+ $*}"
}

# Run a command and append its stderr to ERR_LOG when it failed or raised, so a
# crash is visible instead of reading as "found nothing". Returns its exit code.
run_py() {
    local tag="$1"; shift
    local errf rc
    errf=$(mktemp "$PC_TMP/err.XXXXXX")
    "$@" 2>"$errf"
    rc=$?
    if [ -s "$errf" ] && { [ "$rc" -ne 0 ] || grep -qE 'Traceback|Error|Exception' "$errf"; }; then
        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] postcheck ${VENUE_ID:--} ${tag} (exit ${rc}):"
          sed 's/^/    /' "$errf"; } >> "$ERR_LOG"
    fi
    rm -f "$errf"
    return $rc
}

# with_timeout SECS cmd... — macOS has no `timeout`. perl's alarm survives exec, so
# the command is killed by SIGALRM (exit 142) once SECS pass.
with_timeout() {
    local secs="$1"; shift
    if [ -x /usr/bin/perl ]; then
        /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
    else
        "$@"
    fi
}

# api_call OUTFILE key=value... — GET the Apps Script with every value URL-encoded.
api_call() {
    local out="$1"; shift
    local qs
    rm -f "$out"
    qs=$(run_py urlencode python3 - "$@" <<'PYEOF'
import sys, urllib.parse
print(urllib.parse.urlencode([tuple(a.split('=', 1)) for a in sys.argv[1:]]))
PYEOF
) || return 1
    curl -sL --max-time 90 "${APPS_SCRIPT_URL}?${qs}" -o "$out" 2>>"$ERR_LOG"
}

# Prints: status, verified, message, created, duplicate, updated (US-separated).
api_fields() {
    run_py api-parse python3 - "$1" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('\x1f'.join(['badjson', '', 'unparseable response', '', '', '']))
    sys.exit(0)
def b(k):
    v = d.get(k)
    return '' if v is None else ('true' if v is True else 'false' if v is False else str(v))
msg = str(d.get('message', '')).replace('\x1f', ' ').replace('\n', ' ')[:200]
print('\x1f'.join([str(d.get('status', '')), b('verified'), msg, b('created'), b('duplicate'), b('updated')]))
PYEOF
}

# record_candidate EMAIL VENUE_ID NAME TITLE SOURCE DISPOSITION [EVIDENCE_URL] [KIND] [VALUE]
# Same row shape as pipeline.sh, plus kind/value/run_id so a person without an
# email (kind=contact) or a social link (kind=social) can be logged too.
record_candidate() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5" disposition="$6" evidence_url="${7:-}"
    local kind="${8:-email}" value="${9:-$1}"
    [ -z "$email" ] && [ -z "$name" ] && [ -z "$value" ] && return
    CANDIDATE_LOG="$CANDIDATE_LOG" run_py record-candidate python3 - "$email" "$venue_id" "$name" "$title" "$source" "$disposition" "$evidence_url" "$kind" "$value" "${RUN_ID:-}" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
email, venue_id, name, title, source, disposition, evidence_url, kind, value, run_id = sys.argv[1:11]
row = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "venue_id": venue_id,
    "email": email.lower().strip(),
    "name": name,
    "title": title,
    "source": source,
    "disposition": disposition,
    "evidence_url": evidence_url,
    "kind": kind,
    "value": value,
    "run_id": run_id,
}
with open(os.environ["CANDIDATE_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF
}

# field_for_key FILE KEY N — field N of the first row whose first field is exactly KEY.
field_for_key() { awk -F"$US" -v k="$2" -v n="$3" '$1 == k {print $n; exit}' "$1"; }
norm_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'; }
known_email() { grep -Fxq -- "$1" "$PC_TMP/known_emails" 2>/dev/null; }
known_name() { grep -Fxq -- "$(norm_name "$1")" "$PC_TMP/known_names" 2>/dev/null; }

# Remember an Apollo name lookup so enrich_pass doesn't repeat it for ENRICH_RETRY_DAYS.
enrich_attempted() {
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$VENUE_ID" "$(norm_name "$1")" "$2" >> "$ENRICH_ATTEMPTS"
}

apollo_budget() {
    local used
    used=$(cat "$PC_TMP/apollo_credits" 2>/dev/null)
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    echo $((POSTCHECK_MAX_APOLLO - used))
}
apollo_spent() {
    local n="$1" used
    [[ "$n" =~ ^[0-9]+$ ]] || return
    used=$(cat "$PC_TMP/apollo_credits" 2>/dev/null)
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    echo $((used + n)) > "$PC_TMP/apollo_credits"
}

# Fetch venue_detail and set VENUE_* globals, known_emails/known_names/pending_list files,
# and handled_people: first-name|last-initial keys of people the sheet or the candidate
# log already has for this venue, so Apollo credits aren't spent on them again.
load_venue() {
    local vid="$1" row tag
    : > "$PC_TMP/known_emails"; : > "$PC_TMP/known_names"; : > "$PC_TMP/pending_list"; : > "$PC_TMP/handled_people"
    if ! api_call "$PC_TMP/detail.json" action=venue_detail "venue_id=$vid"; then
        LOAD_ERROR="venue_detail_unreachable"
        return 1
    fi
    row=$(run_py venue-parse python3 - "$SCRIPT_DIR" "$PC_TMP/detail.json" "$PC_TMP" "$CANDIDATE_LOG" "$vid" "$ENRICH_RETRY_DAYS" <<'PYEOF'
import json, os, re, sys, time
from datetime import datetime
from urllib.parse import urlparse
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
detail, tmp, cand_log, vid, days = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
US = '\x1f'
try:
    d = json.load(open(detail, encoding='utf-8'))
except Exception as e:
    print('ERR' + US + 'bad_json'); sys.exit(0)
v = d.get('venue') if isinstance(d, dict) else None
if not isinstance(v, dict) or d.get('status') != 'ok':
    msg = str((d or {}).get('message', 'no venue')) if isinstance(d, dict) else 'no venue'
    print('ERR' + US + 'api:' + re.sub(r'\W+', '_', msg)[:60]); sys.exit(0)

def f(k):
    s = v.get(k)
    s = '' if s is None else str(s)
    s = s.replace(US, ' ').replace('\r', ' ').replace('\n', ' ').strip()
    return '' if s in ('None', 'undefined', 'null') else s

website = f('website').split('|')[0].strip()
if website and not re.match(r'^https?://', website, re.I):
    website = 'https://' + website
contacts = d.get('contacts') or []
known_e, known_n, pending, handled = set(), set(), [], set()

def person_key(n):
    t = [x for x in re.split(r'\s+', re.sub(r'[^a-z\s]', '', n.lower())) if x]
    return (t[0] + '|' + t[-1][0]) if len(t) >= 2 else ''

def one_line(x):
    return str(x or '').replace(US, ' ').replace('\r', ' ').replace('\n', ' ').strip()

valid = 0
for c in contacts:
    e = str(c.get('email') or '').strip().lower()
    n = re.sub(r'\s+', ' ', str(c.get('name') or '')).strip()
    ver = str(c.get('verified') or '').strip().lower()
    if e in ('none', 'undefined', 'null'):
        e = ''
    if e:
        known_e.add(e)
        if ver in ('valid', 'role', 'unverified'):
            valid += 1
    if n:
        known_n.add(n.lower())
        handled.add(person_key(n))
        if not e:
            pending.append(US.join([n, one_line(c.get('title')), one_line(c.get('source'))]))
# People the pipeline already looked up for this venue recently (saved, rejected or deferred).
if os.path.exists(cand_log):
    cut = time.time() - float(days) * 86400
    for line in open(cand_log, encoding='utf-8', errors='replace'):
        if vid not in line:
            continue
        try:
            r = json.loads(line)
            if r.get('venue_id') != vid or not r.get('name'):
                continue
            ts = datetime.fromisoformat(str(r.get('timestamp', ''))).timestamp()
        except Exception:
            continue
        if ts >= cut:
            handled.add(person_key(str(r['name'])))
handled.discard('')
with open(os.path.join(tmp, 'known_emails'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(x + '\n' for x in sorted(known_e)))
with open(os.path.join(tmp, 'known_names'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(x + '\n' for x in sorted(known_n)))
with open(os.path.join(tmp, 'pending_list'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(x + '\n' for x in pending))
with open(os.path.join(tmp, 'handled_people'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(x + '\n' for x in sorted(handled)))

vd, shared, non_venue, prefix, base = '', False, False, '', ''
if website:
    host = R.host_of(website)
    non_venue = R.is_non_venue_host(website)
    shared = R.is_shared_domain(website)
    vd = '' if non_venue else R.registrable_domain(website)
    u = urlparse(website)
    if shared:
        # On a brand domain only the property's own path counts as "the venue's site".
        path = (u.path or '').rstrip('/').lower()
        prefix = (host + path) if path else ''
        base = website.split('#')[0].split('?')[0].rstrip('/')
    else:
        prefix = host
        # Stored websites are often a deep page (/home, /menu); /contact etc. live at the root.
        base = '%s://%s' % (u.scheme or 'https', u.netloc)
print(US.join(['OK', f('name'), website, f('city'), f('state'), f('status'), f('facebook'),
               f('instagram'), f('contact_form'), str(len(contacts)), str(valid), vd,
               'true' if shared else 'false', prefix, 'true' if non_venue else 'false', base]))
PYEOF
)
    IFS="$US" read -r tag VENUE_NAME VENUE_WEBSITE VENUE_CITY VENUE_STATE VENUE_STATUS VENUE_FB VENUE_IG \
        VENUE_FORM N_CONTACTS N_VALID VENUE_DOMAIN VENUE_SHARED_DOMAIN VENUE_SITE_PREFIX VENUE_NON_VENUE_HOST \
        VENUE_BASE <<< "$row"
    if [ "$tag" != "OK" ]; then
        LOAD_ERROR="${VENUE_NAME:-venue_parse_crash}"
        return 1
    fi
    [[ "$N_CONTACTS" =~ ^[0-9]+$ ]] || N_CONTACTS=0
    [[ "$N_VALID" =~ ^[0-9]+$ ]] || N_VALID=0
    return 0
}

# Confirm an email is now on the venue (read-after-write).
readback_email() {
    local email="$1" f="$PC_TMP/readback.json"
    api_call "$f" action=venue_detail "venue_id=$VENUE_ID" || return 1
    run_py readback python3 - "$f" "$email" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
target = sys.argv[2].lower()
ok = any(str(c.get('email') or '').strip().lower() == target for c in d.get('contacts', []))
sys.exit(0 if ok else 1)
PYEOF
}

# Write an approved contact. VERIFIED is valid|role|unverified. UPDATE_NAME set = fill the email
# on that existing pending contact instead of adding a row.
pc_write_contact() {
    local email="$1" name="$2" title="$3" source="$4" verified="$5" is_generic="$6" update_name="$7" evidence_url="$8"
    local resp="$PC_TMP/write.json" st ver msg created dup updated is_new=1
    if [ -n "$update_name" ]; then
        api_call "$resp" action=update_contact_email "venue_id=$VENUE_ID" "name=$update_name" \
            "email=$email" "source=$source" "verified=$verified"
    else
        api_call "$resp" action=add_contact "venue_id=$VENUE_ID" "name=$name" "title=$title" \
            "email=$email" "source=$source" "verified=$verified" "is_generic=$is_generic"
    fi
    IFS="$US" read -r st ver msg created dup updated <<< "$(api_fields "$resp")"
    if [ "$st" != "ok" ]; then
        if [ -z "$name" ] && [ -z "$update_name" ] && echo "$msg" | grep -qi 'must have a name'; then
            # The deployed (old) Apps Script refuses nameless personal mailboxes; the new one accepts them (C5).
            log "  [CANDIDATE] $email — $verified but has no person name and the deployed backend requires one; not saved"
            record_candidate "$email" "$VENUE_ID" "" "$title" "$source" "not_saved:needs_name_old_backend" "$evidence_url"
            V_NEEDS_NAME=$((V_NEEDS_NAME + 1))
            return 1
        fi
        log "  [API ERROR] Contact was not saved: ${name:-(no name)} <$email>${msg:+ — $msg}"
        record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "api_save_failed" "$evidence_url"
        V_SAVE_ERR=$((V_SAVE_ERR + 1))
        return 1
    fi
    # New backend says created:false/duplicate:true; the old one only says so in the message.
    if [ "$created" = "false" ] || [ "$dup" = "true" ] || echo "$msg" | grep -qi 'duplicate'; then
        is_new=0
    fi
    if ! readback_email "$email"; then
        log "  [API ERROR] Contact write could not be verified: ${name:-(no name)} <$email>"
        record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "api_readback_failed" "$evidence_url"
        V_SAVE_ERR=$((V_SAVE_ERR + 1))
        return 1
    fi
    echo "$email" >> "$PC_TMP/known_emails"
    [ -n "$name" ] && printf '%s\n' "$(norm_name "$name")" >> "$PC_TMP/known_names"
    if [ -n "$update_name" ]; then
        log "  [ENRICH] Updated: $update_name <$email> ($verified)"
        V_UPDATED=$((V_UPDATED + 1))
    elif [ "$is_new" = 1 ]; then
        log "  ✓ Added and verified: ${name:-(no name)} <$email> ($verified)"
        V_SAVED=$((V_SAVED + 1))
    else
        log "  [SKIP] $email — already on the sheet (duplicate)"
    fi
    record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "saved_$verified" "$evidence_url"
    return 0
}

# pc_save_email EMAIL NAME TITLE SOURCE EVIDENCE [UPDATE_NAME] [EVIDENCE_URL]
# EVIDENCE: venue_mailto | venue_site | external. Same policy as pipeline.sh verify_and_push:
# junk/hard-reject/off-domain dropped before any paid check; role mailboxes never go to
# ZeroBounce and are saved only with a real name; personal mailboxes only when valid.
pc_save_email() {
    local raw="$1" name="$2" title="$3" source="$4" evidence="${5:-external}" update_name="${6:-}" evidence_url="${7:-}"
    [ -z "$raw" ] && return
    local res email action reason clean_name
    res=$(run_py check-email python3 - "$SCRIPT_DIR" "$raw" "$name" "$evidence" "$VENUE_DOMAIN" "$VENUE_NAME" "$VENUE_SHARED_DOMAIN" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
raw, name, evidence, vd, vn, shared = sys.argv[2:8]
r = R.check_email(raw, vd, vn,
                  found_on_venue_site=evidence in ('venue_site', 'venue_mailto'),
                  shared_domain=True if shared == 'true' else None,
                  venue_mailto=evidence == 'venue_mailto')
clean = R.clean_person_name(name) or R.name_from_email(r['email'])
prole = (r.get('person_role') or '') if evidence in ('venue_site', 'venue_mailto') else ''
print('\x1f'.join([r['email'], r['action'], r['reason'], clean, prole]))
PYEOF
)
    local person_role
    IFS="$US" read -r email action reason clean_name person_role <<< "$res"
    if [ -z "$action" ]; then
        log "  [ERROR] email check crashed for $raw — not saved"
        record_candidate "$(echo "$raw" | tr '[:upper:]' '[:lower:]')" "$VENUE_ID" "$name" "$title" "$source" "check_failed" "$evidence_url"
        V_CHECK_FAILED=$((V_CHECK_FAILED + 1))
        return
    fi
    [ -z "$email" ] && email=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "discovered" "$evidence_url"

    if known_email "$email"; then
        log "  [SKIP] $email — already in sheet"
        record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "already_known" "$evidence_url"
        return
    fi
    if echo "$OWN_EMAILS" | tr '|' '\n' | grep -Fxqi -- "$email"; then
        log "  [SKIP] $email — owner's own email"
        record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "owner_email" "$evidence_url"
        return
    fi

    case "$action" in
        reject)
            log "  [REJECT] $email — $reason"
            record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "reject:$reason" "$evidence_url"
            V_REJECTED=$((V_REJECTED + 1))
            return
            ;;
        role)
            if [ -z "$clean_name" ] && [ -n "$person_role" ]; then
                # chef@/owner@ at a small venue is that one person
                log "  PERSON ROLE: $email ($person_role) — saving without a name"
                pc_write_contact "$email" "" "${title:-$person_role}" "$source" role true "$update_name" "$evidence_url"
                return
            fi
            if [ -z "$clean_name" ]; then
                log "  CANDIDATE: $email (role mailbox, no person name — check staff page for person name)"
                record_candidate "$email" "$VENUE_ID" "$name" "$title" "$source" "role_no_name" "$evidence_url"
                V_ROLE_CAND=$((V_ROLE_CAND + 1))
                return
            fi
            pc_write_contact "$email" "$clean_name" "$title" "$source" role true "$update_name" "$evidence_url"
            return
            ;;
    esac

    local zb_status="" zb_reason="" zb_charged="" zb_cached="" zb_run_used="" zb_run_limit="" zb_json cnt
    cnt=$(cat "$PC_TMP/zb_venue_count" 2>/dev/null)
    [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
    if [ "$cnt" -ge "$MAX_ZB_PER_VENUE" ] 2>/dev/null; then
        zb_status="deferred"; zb_reason="venue_cap_reached"
    elif [ ! -f "$ZB_GUARD" ]; then
        zb_status="deferred"; zb_reason="guard_missing"
    else
        zb_json=$(run_py zb-verify python3 "$ZB_GUARD" verify "$email" --source "$source" --run-id "$ZB_RUN_ID")
        IFS="$US" read -r zb_status zb_reason zb_charged zb_cached zb_run_used zb_run_limit <<< "$(printf '%s' "$zb_json" | run_py zb-parse python3 -c 'import json,sys; d=json.load(sys.stdin); print("\x1f".join(str(d.get(k,"")) for k in ("status","reason","charged","cached","run_used","run_limit")))')"
        if [ -z "$zb_status" ]; then zb_status="deferred"; zb_reason="guard_error"; fi
        if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then
            cnt=$((cnt + 1)); echo "$cnt" > "$PC_TMP/zb_venue_count"
        fi
    fi
    log "  [ZB SAFE] $email → $zb_status (${zb_reason:-unknown}; charged=${zb_charged:-False}; cache=${zb_cached:-False}; venue ${cnt}/${MAX_ZB_PER_VENUE}; run ${zb_run_used:-0}/${zb_run_limit:-?})"

    case "$zb_status" in
        valid)
            pc_write_contact "$email" "$clean_name" "$title" "$source" valid false "$update_name" "$evidence_url"
            ;;
        deferred|pending)
            # Alex (Sep 25): ZeroBounce couldn't check it (budget, no credits, outage), but it
            # passed every free check: save as unverified; reverify.sh checks it later.
            log "  [DEFERRED] $email — ZeroBounce couldn't check it (${zb_reason:-unknown}); saving as unverified"
            record_candidate "$email" "$VENUE_ID" "$clean_name" "$title" "$source" "deferred:${zb_reason:-unknown}" "$evidence_url"
            V_DEFERRED=$((V_DEFERRED + 1))
            case "$zb_reason" in guard_missing|guard_error) V_ZB_ERR=$((V_ZB_ERR + 1)) ;; esac
            pc_write_contact "$email" "$clean_name" "$title" "$source" unverified false "$update_name" "$evidence_url"
            ;;
        *)
            log "  [CANDIDATE] $email — ZeroBounce status is $zb_status; not saved"
            record_candidate "$email" "$VENUE_ID" "$clean_name" "$title" "$source" "verification:$zb_status" "$evidence_url"
            ;;
    esac
}

# Pending (email-less) contact: real unmasked first+last name and a decision-maker title only.
pc_add_pending() {
    local name="$1" title="$2" source="$3" res clean ok resp st ver msg created dup updated
    res=$(run_py pending-check python3 - "$SCRIPT_DIR" "$name" "$title" <<'PYEOF'
import re, sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
name, title = sys.argv[2], sys.argv[3]
DM = re.compile(r'owner|founder|president|partner|principal|director|manager|\bgm\b|\bceo\b|\bcoo\b|'
                r'event|entertainment|booking|operations|chef|proprietor|managing|beverage|catering|'
                r'sales|hospitality|membership|sommelier|winemaker|curator|coordinator', re.I)
BAD = re.compile(r'housekeep|security|loss prevention|accounting|accountant|finance|payroll|laundry|'
                 r'steward|engineer|maintenance|\bit\b|information technology|purchasing|procurement|'
                 r'human resource|\bhr\b|recruit|talent acquisition|\bspa\b|esthetician|massage|intern\b|student', re.I)
clean = R.clean_person_name(name)
if '*' in name:
    why = 'masked_name'
elif not clean:
    why = 'not_a_person_name'
elif not DM.search(title or '') or BAD.search(title or ''):
    why = 'not_decision_maker_title'
else:
    why = ''
print(clean + '\x1f' + ('0' if why else '1') + '\x1f' + why)
PYEOF
)
    IFS="$US" read -r clean ok why <<< "$res"
    if [ "$ok" != "1" ]; then
        log "  [PENDING] not saved: ${name:-?} (${title:-no title}) — ${why:-check crashed}"
        record_candidate "" "$VENUE_ID" "$name" "$title" "$source" "not_saved:${why:-check_failed}" "" contact "$name"
        return
    fi
    if known_name "$clean"; then
        log "  [PENDING] $clean already on the sheet"
        return
    fi
    resp="$PC_TMP/pending.json"
    api_call "$resp" action=add_contact "venue_id=$VENUE_ID" "name=$clean" "title=$title" \
        "source=$source" "verified=pending"
    IFS="$US" read -r st ver msg created dup updated <<< "$(api_fields "$resp")"
    if [ "$st" != "ok" ]; then
        log "  [API ERROR] Pending contact not saved: $clean ($title)${msg:+ — $msg}"
        record_candidate "" "$VENUE_ID" "$clean" "$title" "$source" "api_save_failed" "" contact "$clean"
        V_SAVE_ERR=$((V_SAVE_ERR + 1))
        return
    fi
    if [ "$created" = "false" ] || [ "$dup" = "true" ] || echo "$msg" | grep -qi 'duplicate'; then
        # The old backend treats every email-less contact at a venue as the same row.
        log "  [PENDING] $clean ($title) not added — backend reports a duplicate${msg:+ ($msg)}"
        record_candidate "" "$VENUE_ID" "$clean" "$title" "$source" "not_saved:backend_duplicate" "" contact "$clean"
        return
    fi
    printf '%s\n' "$(norm_name "$clean")" >> "$PC_TMP/known_names"
    log "  +++ $clean ($title): no email — added as pending"
    V_PENDING=$((V_PENDING + 1))
}

# Scan one fetched page: emails (with the person name printed next to them), socials,
# contact form, staff-directory people, and on the homepage the links worth fetching.
# Values come in via argv only.
scan_page() {
    local file="$1" eff="$2" mode="$3"
    run_py page-scan python3 - "$SCRIPT_DIR" "$file" "$eff" "$VENUE_DOMAIN" "$VENUE_SHARED_DOMAIN" "$VENUE_SITE_PREFIX" "$PC_TMP" "$mode" "$VENUE_NAME" "$VENUE_CITY" <<'PYEOF'
import html as H, os, re, sys
from urllib.parse import urljoin, urlparse
sd, page, eff, vd, shared, prefix, tmp, mode, vname, vcity = sys.argv[1:11]
sys.path.insert(0, sd)
import outreach_rules as R
try:
    from site_discovery import extract_emails, extract_socials, deobfuscate_text
except Exception as e:
    # Fall back to plain regexes, but say so: socials can't be read without it.
    print('site_discovery import failed, socials not scanned: Error %r' % e, file=sys.stderr)
    extract_emails = extract_socials = None
    deobfuscate_text = lambda t: t
US = '\x1f'
text = open(page, encoding='utf-8', errors='replace').read()

def own_site(u):
    host = R.host_of(u)
    if not host or not vd or R.registrable_domain(host) != vd:
        return False
    if shared != 'true':
        return True
    s = (host + (urlparse(u).path or '')).lower().rstrip('/')
    return bool(prefix) and (s == prefix or s.startswith(prefix + '/'))

own = own_site(eff)
head = ' '.join(re.findall(r'<(?:title|h1)\b[^>]*>(.*?)</(?:title|h1)>', text[:200000], re.I | re.S)[:2])
if re.search(r'\b404\b|page not found|not be found|doesn.t exist|no longer exists', re.sub(r'<[^>]+>', ' ', head), re.I):
    print('NOTFOUND')
found = {}  # address -> was it a mailto link
if extract_emails:
    for c in extract_emails(text):
        e = R.normalize_email(c.get('email'))
        if e:
            found[e] = found.get(e, False) or bool(c.get('mailto'))
else:
    for m in re.findall(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', text):
        e = R.normalize_email(m)
        if e:
            found.setdefault(e, False)
for m in re.finditer(r'<a\b[^>]*?href\s*=\s*["\']\s*mailto:([^"\'>]+)["\']', text, re.I):
    e = R.normalize_email(m.group(1))
    if e:
        found[e] = True

# Visible text as block lines; a mailto link keeps its address so "Liz McQuay, Events
# Manager <a href=mailto:events@x>Email</a>" still puts the name and address on one line.
t = re.sub(r'(?is)<(script|style|noscript|svg|template)\b.*?</\1>', ' ', text)
t = re.sub(r'(?is)<a\b[^>]*?href\s*=\s*["\']\s*mailto:([^"\'>?]+)[^>]*>(.*?)</a>', r' \2 (\1) ', t)
t = re.sub(r'(?i)<br\s*/?>', ' | ', t)
t = re.sub(r'(?i)</?(p|div|li|ul|ol|td|th|tr|table|h[1-6]|section|article|header|footer|address|dd|dt|dl|figure|figcaption|blockquote|main|aside|nav|form|label|button)\b[^>]*>', '\n', t)
t = H.unescape(re.sub(r'<[^>]+>', ' ', t))
lines = []
for ln in t.split('\n'):
    ln = re.sub(r'\s+', ' ', ln).strip(' |')
    if ln:
        lines.append(deobfuscate_text(ln))

NAME_RE = re.compile(r"\b[A-Z][a-zA-Z'’\-]+(?:\s+[A-Z]\.)?(?:\s+(?:[A-Z][a-zA-Z'’\-]+|Mc[A-Z][a-z]+|de|van|von|da|del)){1,3}\b")
STREET = re.compile(r'\b(street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|way|pike|parkway|pkwy|'
                    r'place|pl|court|ct|circle|square|highway|hwy|suite|floor|county|park|bridge)\b', re.I)
CREDIT = re.compile(r'(designed|developed|powered|website|site|photos?|photography|built)\s+by|©|copyright', re.I)
DM = re.compile(r'owner|founder|president|partner|principal|director|manager|\bgm\b|\bceo\b|\bcoo\b|'
                r'event|entertainment|booking|operations|chef|proprietor|managing|beverage|catering|'
                r'sales|hospitality|membership|sommelier|winemaker|curator|coordinator', re.I)
venue_words = set(re.findall(r'[a-z]+', vname.lower()))
city_l = vcity.strip().lower()

LEAD = {'chef', 'executive', 'sous', 'pastry', 'owner', 'proprietor', 'director', 'manager', 'mr', 'mrs',
        'ms', 'dr', 'sommelier', 'winemaker', 'gm', 'contact', 'email', 'call', 'ask', 'for', 'meet',
        'by', 'please', 'reach', 'write', 'questions', 'inquiries', 'attn', 'attention'}
# Link/button words that pass clean_person_name ("Send Message", "Opt Out", "Get Directions").
UI = {'send', 'message', 'opt', 'out', 'get', 'directions', 'learn', 'more', 'read', 'view', 'join',
      'apply', 'submit', 'inquire', 'request', 'quote', 'reserve', 'buy', 'download', 'find', 'see',
      'write', 'reach', 'ask', 'questions', 'inquiries', 'general', 'press', 'media', 'careers', 'jobs',
      'mail', 'e-mail', 'details', 'rsvp', 'tickets', 'ticket', 'rentals', 'private', 'parties', 'party',
      'happy', 'hour', 'brunch', 'lunch', 'dinner', 'menus', 'wine', 'list', 'gallery', 'photos',
      'reviews', 'hiring', 'employment', 'feedback', 'donate', 'support', 'faq', 'faqs', 'blog', 'news'}

def person(cand):
    ws = cand.split()
    while ws and ws[0].lower().strip('.:') in LEAD:
        ws = ws[1:]
    c = R.clean_person_name(' '.join(ws)) if len(ws) >= 2 else ''
    if not c or STREET.search(cand) or c.lower() == city_l:
        return ''
    words = set(re.findall(r"[a-z'’\-]+", c.lower()))
    if words & UI:
        return ''
    return '' if words and words <= venue_words else c

def names_in(s):
    out = []
    for m in NAME_RE.finditer(s):
        c = person(m.group(0))
        if c and c not in out:
            out.append(c)
    return out

def fits_local(name, email):
    # A personal mailbox only takes a nearby name that its local part agrees with.
    local = re.sub(r'[^a-z]', '', email.split('@', 1)[0])
    toks = [re.sub(r'[^a-z]', '', w) for w in name.lower().split()]
    toks = [w for w in toks if w]
    if len(toks) < 2:
        return False
    return any(len(w) >= 3 and w in local for w in toks) or (toks[0][0] + toks[-1]) in local

def title_after(line, name):
    rest = line.split(name, 1)[1] if name in line else ''
    m = re.match(r'\s*[,\-–—|:]\s*([^|,@()]{3,60})', rest)
    return m.group(1).strip() if m and DM.search(m.group(1)) else ''

name_for, title_for = {}, {}
for e in found:
    idx = [i for i, ln in enumerate(lines) if e in ln.lower()]
    role = R.is_role_email(e)
    picked = set()
    for i in idx:
        window = [i] if role else [j for j in (i, i - 1, i - 2) if j >= 0]
        for j in window:
            if j != i and '@' in lines[j]:
                break  # another card's address: stop before borrowing its name
            if CREDIT.search(lines[j]):
                continue
            for n in names_in(lines[j]):
                if role or fits_local(n, e):
                    picked.add(n)
                    if n not in title_for:
                        tt = title_after(lines[j], n)
                        if not tt and j + 1 < len(lines) and j + 1 != i and DM.search(lines[j + 1]) and len(lines[j + 1]) <= 60 and '@' not in lines[j + 1]:
                            tt = lines[j + 1]
                        title_for[n] = tt
            if picked:
                break
    if len(picked) == 1:
        name_for[e] = picked.pop()
    elif len(picked) > 1:
        print('AMBIG' + US + e + US + '; '.join(sorted(picked)))

with open(os.path.join(tmp, 'emails.tsv'), 'a', encoding='utf-8') as f:
    for e, mailto in sorted(found.items()):
        ev = ('venue_mailto' if mailto else 'venue_site') if own else 'external'
        n = name_for.get(e, '')
        f.write(US.join([e, ev, n, eff, title_for.get(n, '') if n else '']) + '\n')
        print('EMAIL' + US + e + US + n)
if extract_socials:
    with open(os.path.join(tmp, 'socials.tsv'), 'a', encoding='utf-8') as f:
        for platform, urls in extract_socials(text).items():
            for u in urls:
                f.write(US.join([platform, u, eff, '1' if own else '0']) + '\n')

# Staff directories: "Jane Doe" followed by "Director of Events", or "Jane Doe, Director of Events".
path_l = (urlparse(eff).path or '').lower()
STAFF_PATH = r'team|staff|leader|people|management|directory|who-we-are|meet-(?:the|our)|meettheteam'
if own and re.search(STAFF_PATH + r'|about|contact|our-story', path_l):
    staff_page = bool(re.search(STAFF_PATH, path_l))
    seen_p = set()
    for i, ln in enumerate(lines):
        if '@' in ln or CREDIT.search(ln) or len(ln) > 90:
            continue
        name, title = '', ''
        c = person(ln) if len(ln) <= 40 else ''
        if c and i + 1 < len(lines):
            nxt = lines[i + 1]
            if len(nxt) <= 60 and '@' not in nxt and DM.search(nxt) and not DM.search(ln):
                name, title = c, nxt
        if not name:
            m = re.match(r'^([^,|:\-–—]{4,40})\s*[,|\-–—]\s*([^|@]{3,60})$', ln)
            if m and DM.search(m.group(2)):
                c = person(m.group(1).strip())
                if c:
                    name, title = c, m.group(2).strip()
        if not name or name.lower() in seen_p:
            continue
        seen_p.add(name.lower())
        print('PERSON' + US + name + US + title + US + ('staff' if staff_page else 'other'))

# A contact form counts only if it is a real <form> on the venue's own pages, has a
# message box or says it is a contact/inquiry form, and is not search/login/newsletter/cart.
if own:
    SKIP = re.compile(r'search|login|log-in|signin|sign-in|password|newsletter|subscribe|mailchimp|'
                      r'mc-embedded|mc4wp|klaviyo|cart|checkout|coupon|comment|giftcard|gift-card|donat', re.I)
    MARK = re.compile(r'contact|inquir|enquir|get-in-touch|getintouch|rfp|book[^"\']*event', re.I)
    for attrs, body in re.findall(r'<form\b([^>]*)>(.*?)</form>', text, re.I | re.S):
        if SKIP.search(attrs) or re.search(r'type\s*=\s*["\']?(password|search)\b', body, re.I):
            continue
        if re.search(r'<textarea\b', body, re.I) or MARK.search(attrs):
            score = 0 if 'contact' in path_l else (1 if re.search(r'inquir|enquir|event|book|rfp|wedding|cater|private', path_l) else 2)
            print('FORM' + US + str(score))
            break

if mode == 'home':
    keywords = ['contact', 'reservat', 'booking', 'inquiry', 'enquir', 'event', 'private',
                'get-in-touch', 'reach-us', 'team', 'staff', 'leadership', 'about', 'our-story',
                'people', 'management', 'meet', 'wedding', 'cater', 'group', 'dining', 'rental',
                'banquet', 'meeting', 'directory']
    skip_ext = ('.css', '.js', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.pdf', '.zip',
                '.woff', '.woff2', '.ttf', '.ico', '.mp4')
    seen = set()
    for h in re.findall(r'href\s*=\s*["\']([^"\']+)["\']', text, re.I):
        url = urljoin(eff, H.unescape(h.strip())).split('#')[0].split('?')[0].rstrip('/')
        if not url.lower().startswith(('http://', 'https://')) or url in seen:
            continue
        seen.add(url)
        low = url.lower()
        if own_site(url) and any(k in urlparse(low).path for k in keywords) and not low.endswith(skip_ext):
            print('LINK' + US + url)
PYEOF
}

# Website pass: the site crawler (or the pipeline's fresh crawl of the same site), then
# curl fetches of the homepage, pages where the crawl saw addresses, homepage links and
# fixed contact/team/events paths, bounded by POSTCHECK_WEB_SECONDS / POSTCHECK_MAX_PAGES.
# Collects emails (with nearby person names), contact forms, socials and staff names.
web_pass() {
    WEB_ST="ok"; CRAWL_ST="ok"; CONTACT_FORM=""; PAGES_OK=0; CRAWL_PAGES=0; PAGES_CUT=0; VISITED=""; CRAWL_VIA="none"
    : > "$PC_TMP/emails.tsv"; : > "$PC_TMP/socials.tsv"; : > "$PC_TMP/forms.tsv"; : > "$PC_TMP/pages.txt"
    : > "$PC_TMP/people.tsv"; : > "$PC_TMP/ok_urls"; : > "$PC_TMP/ambig.tsv"; rm -f "$PC_TMP/home.html"
    local SAFE_VID base
    SAFE_VID=$(printf '%s' "$VENUE_ID" | tr -cd '[:alnum:]_.-')
    [ -z "$SAFE_VID" ] && SAFE_VID="venue"
    base="${VENUE_BASE:-${VENUE_WEBSITE%/}}"
    base="${base%/}"

    # Shared recursive discovery engine: sitemap + depth-3 links + PDFs + socials.
    # This keeps postcheck aligned with pipeline.sh instead of maintaining a second,
    # shallower definition of what counts as "website checked".
    if [ -f "${SCRIPT_DIR}/site_discovery.py" ]; then
        local raw="$PC_TMP/discovery_raw.json" cov="" rc pc_cov="${PIPELINE_COVERAGE_DIR}/${SAFE_VID}.json" try
        for try in reuse crawl; do
            if [ "$try" = "reuse" ]; then
                # The pipeline crawled this site minutes ago with the same settings: reuse it.
                [ "$POSTCHECK_REUSE_CRAWL_HOURS" -gt 0 ] && [ -s "$pc_cov" ] || continue
                find "$pc_cov" -mmin "-$((POSTCHECK_REUSE_CRAWL_HOURS * 60))" 2>/dev/null | grep -q . || continue
                cp "$pc_cov" "$raw" || continue
                CRAWL_VIA="pipeline_crawl"
            else
                CRAWL_VIA="crawl"; CRAWL_ST="ok"
                run_py static-crawl with_timeout "$POSTCHECK_CRAWL_SECONDS" python3 "${SCRIPT_DIR}/site_discovery.py" static-crawl "$VENUE_WEBSITE" --max-pages 40 --max-depth 3 > "$raw"
                rc=$?
                if [ "$rc" -eq 142 ]; then
                    CRAWL_ST="failed:timeout"; log "  [DISCOVERY] Site crawler stopped after ${POSTCHECK_CRAWL_SECONDS}s (POSTCHECK_CRAWL_SECONDS)"
                elif [ "$rc" -ne 0 ]; then
                    CRAWL_ST="failed:crash"
                fi
            fi
            cov=$(run_py discovery-parse python3 - "$SCRIPT_DIR" "$raw" "${COVERAGE_DIR}/${SAFE_VID}.json" "$PC_TMP" "$VENUE_ID" "$VENUE_DOMAIN" "$VENUE_SHARED_DOMAIN" "$VENUE_SITE_PREFIX" "$try" <<'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone
from urllib.parse import urlparse
sd, raw, cov_out, tmp, vid, vd, shared, prefix, mode = sys.argv[1:10]
sys.path.insert(0, sd)
import outreach_rules as R
US = '\x1f'
txt = open(raw, encoding='utf-8', errors='replace').read()
# Older site_discovery printed progress lines ([HIGH_PRIORITY_UNVISITED] ...) before its JSON.
m = re.search(r'^\{', txt, re.M)
if not m:
    if mode == 'reuse':
        print('STALE' + US + 'unreadable'); sys.exit(0)
    raise SystemExit('static-crawl produced no JSON')
d = json.loads(txt[m.start():])
c = d.get('coverage', {})
ok_pages = [p for p in d.get('pages', []) if p.get('ok')]
if mode == 'reuse':
    site = str(d.get('requested_website') or d.get('base') or '')
    # A crawl of another site (website corrected since) or one that fetched nothing isn't worth reusing.
    if not ok_pages or not vd or R.registrable_domain(site) != vd:
        print('STALE' + US + ('no_pages' if not ok_pages else 'other_site')); sys.exit(0)

def own_site(u):
    host = R.host_of(u)
    if not host or not vd or R.registrable_domain(host) != vd:
        return False
    if shared != 'true':
        return True
    s = (host + (urlparse(u).path or '')).lower().rstrip('/')
    return bool(prefix) and (s == prefix or s.startswith(prefix + '/'))

d['venue_id'] = vid
d['checked_by'] = 'postcheck'
d['checked_at'] = datetime.now(timezone.utc).isoformat()
with open(cov_out, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, sort_keys=True)
with open(os.path.join(tmp, 'ok_urls'), 'a', encoding='utf-8') as f:
    for p in ok_pages:
        f.write(str(p.get('url') or '').strip() + '\n')
# Refetch candidates: 1 = the crawl saw an address there (the curl pass reads the names
# printed next to it), 4 = other contact-ish pages.
KEY = re.compile(r'contact|about|team|staff|leader|people|management|directory|meet|event|private|'
                 r'wedding|cater|book|inquir|enquir|group|dining|rental|banquet|our-story', re.I)
with open(os.path.join(tmp, 'pages.txt'), 'a', encoding='utf-8') as f:
    for p in ok_pages:
        u = str(p.get('url') or '').strip()
        if not u or not own_site(u):
            continue
        if p.get('emails'):
            f.write('1\t' + u + '\n')
        elif KEY.search(urlparse(u).path or ''):
            f.write('4\t' + u + '\n')
with open(os.path.join(tmp, 'emails.tsv'), 'a', encoding='utf-8') as f:
    for ct in d.get('contacts', []):
        e = R.normalize_email(ct.get('email'))
        if not e:
            continue
        srcs = [str(s) for s in ct.get('sources', [])]
        own = [s for s in srcs if own_site(s)]
        ev = ('venue_mailto' if ct.get('mailto') else 'venue_site') if own else 'external'
        f.write(US.join([e, ev, '', (own or srcs or [''])[0], '']) + '\n')
with open(os.path.join(tmp, 'socials.tsv'), 'a', encoding='utf-8') as f:
    for s in d.get('socials', []):
        for src in s.get('sources', []):
            f.write(US.join([str(s.get('platform', '')), str(s.get('url', '')), str(src),
                             '1' if own_site(str(src)) else '0']) + '\n')
print('OK' + US + str(len(ok_pages)) + US + 'pages=%s ok=%s pdfs=%s sitemaps=%s fragments=%s unvisited=%s emails=%s' % (
    c.get('visited_page_count', 0), len(ok_pages), c.get('pdf_count', 0), c.get('sitemap_count', 0),
    c.get('fragment_state_count', 0), c.get('unvisited_page_count', 0), len(d.get('contacts', []))))
PYEOF
)
            rc=$?
            local ctag cn csum
            IFS="$US" read -r ctag cn csum <<< "$cov"
            if [ "$ctag" = "OK" ]; then
                CRAWL_PAGES="${cn:-0}"
                # The crawler ran but every fetch failed (site blocks python-requests, or down).
                [ "$try" = "crawl" ] && [ "${cn:-0}" = "0" ] && CRAWL_ST="failed:no_pages"
                [ "$try" = "reuse" ] && log "  [DISCOVERY] Reusing the pipeline's crawl of this site ($pc_cov)"
                log "  [DISCOVERY] $csum"
                break
            elif [ "$try" = "reuse" ]; then
                log "  [DISCOVERY] Pipeline crawl not reusable (${cn:-unreadable}) — crawling again"
                continue
            fi
            [ "$rc" -ne 0 ] && [ "$CRAWL_ST" = "ok" ] && CRAWL_ST="failed:parse"
            log "  [DISCOVERY] FAILED — site crawler returned no usable result (see $ERR_LOG)"
            [ "$CRAWL_ST" = "ok" ] && CRAWL_ST="failed:no_result"
        done
    else
        CRAWL_ST="failed:site_discovery_missing"
        log "  [DISCOVERY] FAILED — ${SCRIPT_DIR}/site_discovery.py is missing"
    fi

    # Homepage first: its links decide which extra pages to fetch.
    local page_file="$PC_TMP/page.html" meta code eff scan home_eff="" t0
    local PAGES=() PAGE p
    meta=$(curl -sL --compressed --max-time 15 -A "$UA" -o "$page_file" -w '%{http_code} %{url_effective}' "$VENUE_WEBSITE" 2>/dev/null)
    code=${meta%% *}; eff=${meta#* }
    if [[ "$code" == 2* ]] && [ -s "$page_file" ]; then
        home_eff="$eff"
        cp "$page_file" "$PC_TMP/home.html"
        scan=$(scan_page "$page_file" "$eff" home) || WEB_SCAN_ERR=$((WEB_SCAN_ERR + 1))
        pc_collect_scan "$scan" "$eff" "$VENUE_WEBSITE"
    else
        log "  [WARN] Homepage did not load (HTTP ${code:-000}): $VENUE_WEBSITE"
    fi
    echo "$home_eff" > "$PC_TMP/home_eff"
    for p in contact contact-us about about-us team our-team staff leadership meet-the-team people \
             events private-events event-contact private-dining private-event-space book-event \
             group-dining weddings catering; do
        printf '3\t%s\n' "$base/$p" >> "$PC_TMP/pages.txt"
    done

    # Priority order, one fetch per URL, never the homepage twice.
    while IFS= read -r PAGE; do
        [ -n "$PAGE" ] && PAGES+=("$PAGE")
    done < <(sort -s -t$'\t' -k1,1n "$PC_TMP/pages.txt" | cut -f2- | sed 's/#.*$//' \
        | awk -v h="${VENUE_WEBSITE%/}" -v e="${home_eff%/}" \
            '{u=$0; sub(/\/+$/, "", u)} NF && u != h && u != e && !seen[u]++')

    t0=$SECONDS
    local i=0 n=${#PAGES[@]}
    for PAGE in "${PAGES[@]}"; do
        if { [ "$POSTCHECK_MAX_PAGES" -gt 0 ] && [ "$i" -ge "$POSTCHECK_MAX_PAGES" ]; } ||
           { [ "$POSTCHECK_WEB_SECONDS" -gt 0 ] && [ $((SECONDS - t0)) -ge "$POSTCHECK_WEB_SECONDS" ]; }; then
            PAGES_CUT=$((n - i))
            log "  [WEB] Page budget reached (${POSTCHECK_MAX_PAGES} pages / ${POSTCHECK_WEB_SECONDS}s) — $PAGES_CUT lower-priority pages not fetched"
            break
        fi
        i=$((i + 1))
        meta=$(curl -sL --compressed --max-time 10 -A "$UA" -o "$page_file" -w '%{http_code} %{url_effective}' "$PAGE" 2>/dev/null)
        code=${meta%% *}; eff=${meta#* }
        # Skip 404s and errors: their bodies (and footer forms) aren't this page. Sites that
        # answer every unknown path with the homepage aren't showing a /team page either.
        [[ "$code" == 2* ]] || continue
        [ -s "$page_file" ] || continue
        cmp -s "$page_file" "$PC_TMP/home.html" 2>/dev/null && continue
        scan=$(scan_page "$page_file" "$eff" page) || WEB_SCAN_ERR=$((WEB_SCAN_ERR + 1))
        pc_collect_scan "$scan" "$eff" "$PAGE"
    done

    # Which kinds of page were actually read (crawler or curl), for the [STEP] line.
    VISITED=$(run_py visited python3 - "$PC_TMP/ok_urls" "$home_eff" <<'PYEOF'
import re, sys
from urllib.parse import urlparse
kinds = {'contact': r'contact|get-in-touch|reach-us|inquir|enquir',
         'about': r'about|our-story|who-we-are|history',
         'events': r'event|private|wedding|cater|banquet|group|book|rental|meeting|dining',
         'team': r'team|staff|leader|people|management|directory|meet-(?:the|our)|meettheteam'}
seen = ['home'] if sys.argv[2] else []
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    path = (urlparse(line.strip()).path or '').lower()
    if not path.strip('/') and 'home' not in seen:
        seen.append('home')
    for k, pat in kinds.items():
        if k not in seen and re.search(pat, path):
            seen.append(k)
print(','.join(k for k in ('home', 'contact', 'about', 'events', 'team') if k in seen) or 'none')
PYEOF
)
    [ -z "$VISITED" ] && VISITED="unknown"

    if [ "$PAGES_OK" -eq 0 ] && [ "$CRAWL_PAGES" -eq 0 ] 2>/dev/null; then
        WEB_ST="failed"
        log "  [WEB] FAILED — no page on $VENUE_WEBSITE returned HTTP 2xx (site down or blocking)"
    elif [ "$PAGES_OK" -eq 0 ]; then
        log "  [WEB] curl could not load any page (blocking?) — only the crawler's pages were read"
    fi
    [ -s "$PC_TMP/forms.tsv" ] && CONTACT_FORM=$(sort -t$'\t' -k1,1n "$PC_TMP/forms.tsv" | head -1 | cut -f2)

    # One row per address, strongest evidence first (mailto on own page > own page > elsewhere).
    # Two different names printed next to the same address = ambiguous: keep no name.
    run_py email-aggregate python3 - "$PC_TMP/emails.tsv" "$PC_TMP/ambig.tsv" > "$PC_TMP/emails_agg" <<'PYEOF'
import sys
US = '\x1f'
rank = {'venue_mailto': 3, 'venue_site': 2, 'external': 1}
agg = {}
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    e, ev, name, src, title = (line.rstrip('\n').split(US) + ['', '', '', '', ''])[:5]
    if not e:
        continue
    cur = agg.setdefault(e, {'ev': ev, 'src': src, 'names': {}, 'title': ''})
    if rank.get(ev, 0) > rank.get(cur['ev'], 0):
        cur['ev'], cur['src'] = ev, src
    if name:
        cur['names'].setdefault(name.lower(), (name, title))
for line in open(sys.argv[2], encoding='utf-8', errors='replace'):
    e = line.split(US, 1)[0]
    if e in agg:
        agg[e]['names']['?ambiguous'] = ('', '')
out = []
for e, r in agg.items():
    names = list(r['names'].values())
    name, title = names[0] if len(names) == 1 else ('', '')
    out.append((e, r['ev'], name, r['src'], title, 'ambiguous' if len(names) > 1 else ''))
for row in sorted(out, key=lambda x: (-bool(x[2]), -rank.get(x[1], 0), x[0])):
    print(US.join(row))
PYEOF
    V_EMAILS=$(grep -c . "$PC_TMP/emails_agg" 2>/dev/null)
    [[ "$V_EMAILS" =~ ^[0-9]+$ ]] || V_EMAILS=0
}

# Log what scan_page found on one page and file its forms, links, people and name conflicts.
# A "page not found" page served with HTTP 200 doesn't count as a page read.
pc_collect_scan() {
    local scan="$1" eff="$2" shown="$3" kind val v2 v3 had=0
    if printf '%s\n' "$scan" | grep -q "^NOTFOUND"; then
        log "  [WEB] $shown is a 'page not found' page (HTTP 200)"
    else
        PAGES_OK=$((PAGES_OK + 1))
        echo "$eff" >> "$PC_TMP/ok_urls"
    fi
    while IFS="$US" read -r kind val v2 v3; do
        case "$kind" in
            LINK) printf '2\t%s\n' "$val" >> "$PC_TMP/pages.txt" ;;
            FORM) printf '%s\t%s\n' "$val" "$eff" >> "$PC_TMP/forms.tsv"; log "  Contact form found: $eff" ;;
            EMAIL)
                [ "$had" = 0 ] && log "  Found emails on $shown:"
                had=1
                log "    $val${v2:+ ($v2)}" ;;
            AMBIG)
                printf '%s%s%s\n' "$val" "$US" "$v2" >> "$PC_TMP/ambig.tsv"
                log "    [NAME] $val sits next to several names ($v2) — no name attached" ;;
            PERSON) printf '%s%s%s%s%s%s%s\n' "$val" "$US" "$v2" "$US" "$v3" "$US" "$eff" >> "$PC_TMP/people.tsv" ;;
        esac
    done <<< "$scan"
}

save_contact_form() {
    FORM_ST="none"
    [ -z "$CONTACT_FORM" ] && return
    FORM_ST="found"
    if [ -n "$VENUE_FORM" ]; then
        FORM_ST="kept"
        [ "$VENUE_FORM" != "$CONTACT_FORM" ] && log "  Contact form already on sheet ($VENUE_FORM) — not replaced with $CONTACT_FORM"
        return
    fi
    local resp="$PC_TMP/form.json" st ver msg rest
    api_call "$resp" action=update_venue "venue_id=$VENUE_ID" field=contact_form "value=$CONTACT_FORM"
    IFS="$US" read -r st ver msg rest <<< "$(api_fields "$resp")"
    if [ "$st" = "ok" ] && [ "$ver" != "false" ]; then
        log "  Saved contact form to sheet: $CONTACT_FORM"
        FORM_ST="saved"
    else
        log "  [API ERROR] Contact form did not persist: $CONTACT_FORM${msg:+ ($msg)}"
        record_candidate "" "$VENUE_ID" "" "" "postcheck_website" "form_not_saved:api_${st:-failed}" "" contact_form "$CONTACT_FORM"
        FORM_ST="failed"
        V_SAVE_ERR=$((V_SAVE_ERR + 1))
    fi
}

# Socials: fill only EMPTY fields, without force, and only with a link that plausibly
# belongs to this venue (handle carries the venue's distinctive name words, or it sits in
# the header/footer of several of the venue's own pages on a domain the venue owns).
# Brand/chain handles and non-page URLs are rejected; unsure links go to the candidate log.
save_socials() {
    SOCIAL_NOTE=""
    [ -s "$PC_TMP/socials.tsv" ] || return
    local picks kind platform url why current label resp st ver msg rest
    picks=$(run_py social-pick python3 - "$SCRIPT_DIR" "$PC_TMP/socials.tsv" "$VENUE_NAME" "$VENUE_DOMAIN" "$VENUE_SHARED_DOMAIN" "$(cat "$PC_TMP/home_eff" 2>/dev/null)" <<'PYEOF'
import math, re, sys
from urllib.parse import urlparse, parse_qsl
sd, path, vn, vd, shared, home = sys.argv[1:7]
sys.path.insert(0, sd)
import outreach_rules as R
US = '\x1f'
agg = {}
for line in open(path, encoding='utf-8', errors='replace'):
    parts = (line.rstrip('\n').split(US) + ['', '', '', ''])[:4]
    platform, url, src, own = parts
    if platform not in ('facebook', 'instagram') or not url:
        continue
    a = agg.setdefault((platform, url), {'own': set()})
    if own == '1':
        a['own'].add(src.rstrip('/'))
generic = getattr(R, '_GENERIC_VENUE_WORDS', set())
tokens = {t for t in R.venue_name_tokens(vn) if t not in generic}
brand = vd.split('.')[0] if shared == 'true' and vd else ''
BAD_FB = {'profile.php', 'sharer', 'sharer.php', 'share', 'share.php', 'groups', 'people', 'events',
          'hashtag', 'watch', 'photo.php', 'photos', 'story.php', 'permalink.php', 'dialog',
          'plugins', 'tr', 'login', 'home.php', 'media', 'gaming', 'public'}
BAD_IG = {'p', 'reel', 'reels', 'explore', 'stories', 'accounts', 'direct', 'tv', 'share', 'embed'}

def handle_of(platform, url):
    p = urlparse(url)
    parts = [x for x in (p.path or '').split('/') if x]
    if not parts:
        return None, 'bare_url'
    first = parts[0].lower()
    if platform == 'facebook':
        if first == 'profile.php':
            return ('', 'ok') if dict(parse_qsl(p.query)).get('id', '').isdigit() else (None, 'bare_profile_php')
        if first == 'pages' and len(parts) >= 2:
            return parts[1], 'ok'
        if first in BAD_FB:
            return None, 'not_a_page:' + first
        return parts[0], 'ok'
    if first in BAD_IG:
        return None, 'not_a_profile:' + first
    return parts[0], 'ok'

best, footer_only = {}, {}
for (platform, url), a in agg.items():
    if not a['own']:
        continue  # only links that appear on the venue's own pages
    h, why = handle_of(platform, url)
    if h is None:
        print(US.join(['REJECT', platform, url, why]))
        continue
    hl = re.sub(r'[^a-z0-9]', '', h.lower())
    other = [t for t in tokens if t != brand]
    if brand and hl.startswith(brand) and not any(t in hl for t in other):
        print(US.join(['REJECT', platform, url, 'brand_handle:' + brand]))
        continue
    # Most of the distinctive words, not just one: "clydesrestaurantgroup" is not "Clyde's of Georgetown".
    need = len(tokens) if len(tokens) <= 2 else math.ceil(len(tokens) * 2 / 3)
    hits = sum(1 for t in tokens if t in hl)
    name_match = bool(hl) and ((tokens and hits >= need) or R.org_name_matches(re.sub(r'[._\-]+', ' ', h), vn))
    # On several of the venue's own pages = site-wide header/footer link.
    header_footer = len(a['own']) >= 2
    if name_match:
        score, why = 2, 'handle_matches_name'
    elif header_footer and shared != 'true':
        score, why = 1, 'site_header_footer'
    else:
        print(US.join(['REJECT', platform, url, 'no_venue_evidence']))
        continue
    if score == 1:
        footer_only.setdefault(platform, []).append(url)
    key = (score, len(a['own']))
    if platform not in best or key > best[platform][0]:
        best[platform] = (key, url, why)
for platform, (key, url, why) in sorted(best.items()):
    # Two unrelated footer links (venue + web designer, say) and neither named: don't guess.
    if key[0] == 1 and len(footer_only.get(platform, [])) > 1:
        for u in footer_only[platform]:
            print(US.join(['REJECT', platform, u, 'ambiguous_footer_links']))
        continue
    print(US.join(['PICK', platform, url, why]))
PYEOF
) || { SOCIAL_NOTE="social_check_failed"; return; }
    while IFS="$US" read -r kind platform url why <&3; do
        [ -z "$kind" ] && continue
        if [ "$kind" = "REJECT" ]; then
            log "  [SOCIAL] rejected $platform $url — $why"
            case "$why" in
                no_venue_evidence|ambiguous_footer_links)
                    record_candidate "" "$VENUE_ID" "" "" "postcheck_website:$platform" "social_not_saved:$why" "" social "$url" ;;
            esac
            continue
        fi
        if [ "$platform" = "instagram" ]; then current="$VENUE_IG"; label="IG"; else current="$VENUE_FB"; label="Facebook"; fi
        if [ -n "$current" ] && ! echo "$current" | grep -q "accounts.google.com"; then
            if [ "${current%/}" != "${url%/}" ]; then
                log "  [SOCIAL] $label already set ($current) — website candidate not written: $url"
                record_candidate "" "$VENUE_ID" "" "" "postcheck_website:$platform" "social_not_saved:sheet_has_other" "" social "$url"
            fi
            continue
        fi
        resp="$PC_TMP/social.json"
        api_call "$resp" action=update_venue "venue_id=$VENUE_ID" "field=$platform" "value=$url"
        IFS="$US" read -r st ver msg rest <<< "$(api_fields "$resp")"
        if [ "$st" = "ok" ] && [ "$ver" != "false" ]; then
            log "  Found & saved $label from website evidence: $url"
            V_SOCIALS=$((V_SOCIALS + 1))
        elif [ "$st" = "error" ]; then
            # The backend's own name/slug check (no force) can refuse it: keep it as a candidate.
            log "  [SOCIAL] $label candidate not saved: $url${msg:+ ($msg)}"
            record_candidate "" "$VENUE_ID" "" "" "postcheck_website:$platform" "social_not_saved:backend_refused" "" social "$url"
        else
            log "  [API ERROR] $label write failed or unverified: $url${msg:+ ($msg)}"
            record_candidate "" "$VENUE_ID" "" "" "postcheck_website:$platform" "social_not_saved:api_failed" "" social "$url"
            V_SAVE_ERR=$((V_SAVE_ERR + 1))
        fi
    done 3<<< "$picks"
}

# People named on the venue's own pages without an email. On a staff/team/leadership page
# with a decision-maker title they become pending contacts (P3); elsewhere (about/contact
# pages) the pairing is less certain, so they only go to the candidate log.
save_people() {
    V_PEOPLE=0
    [ -s "$PC_TMP/people.tsv" ] || return
    local name title kind src total
    total=$(awk -F"$US" '!seen[tolower($1)]++' "$PC_TMP/people.tsv" | grep -c .)
    [ "${total:-0}" -gt 20 ] && log "  [WEB] $total named people on staff pages — only the first 20 are considered"
    while IFS="$US" read -r name title kind src <&3; do
        [ -z "$name" ] && continue
        known_name "$name" && continue
        V_PEOPLE=$((V_PEOPLE + 1))
        if [ "$kind" = "staff" ]; then
            log "  [WEB] Named on staff page: $name — $title ($src)"
            pc_add_pending "$name" "$title" "postcheck_website_staff"
        else
            log "  CANDIDATE: $name ($title) — named on $src with no email; not saved (not a staff page)"
            record_candidate "" "$VENUE_ID" "$name" "$title" "postcheck_website" "website_person_no_email" "$src" contact "$name"
        fi
    done 3< <(awk -F"$US" '!seen[tolower($1)]++' "$PC_TMP/people.tsv" | head -n 20)
}

# Apollo people search on the venue's own domain (same endpoints as pipeline.sh), with a
# name-gated fallback, then bulk enrichment of people Apollo says have an email.
apollo_pass() {
    APOLLO_ST="empty"
    if [ -z "$APOLLO_API_KEY" ]; then
        APOLLO_ST="skipped:no_api_key"; log "  [Apollo] SKIPPED — no API key"; return
    fi
    if [ "$VENUE_SHARED_DOMAIN" = "true" ]; then
        APOLLO_ST="skipped:shared_domain"; log "  [Apollo] SKIPPED — $VENUE_DOMAIN is a shared brand domain (no domain-wide people search)"; return
    fi
    if [ -z "$VENUE_DOMAIN" ]; then
        APOLLO_ST="skipped:no_domain"; log "  [Apollo] SKIPPED — no venue domain"; return
    fi
    local budget; budget=$(apollo_budget)
    if [ "$budget" -le 0 ]; then
        APOLLO_ST="skipped:credit_cap"; log "  [Apollo] SKIPPED — postcheck Apollo cap reached ($POSTCHECK_MAX_APOLLO)"; return
    fi
    log "  [Apollo] Searching by domain: $VENUE_DOMAIN"
    local out="$PC_TMP/apollo_out" kind a b c d e hits=0
    if ! run_py apollo-search python3 - "$SCRIPT_DIR" "$VENUE_DOMAIN" "$VENUE_NAME" "$budget" "$PC_TMP/handled_people" > "$out" <<'PYEOF'
import os, re, sys, unicodedata
import requests
sd, vd, vn, budget, handled_f = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
sys.path.insert(0, sd)
import outreach_rules as R
US = '\x1f'
base = os.environ.get('APOLLO_API_BASE', 'https://api.apollo.io/api/v1').rstrip('/')
HDR = {'Content-Type': 'application/json', 'Cache-Control': 'no-cache', 'x-api-key': os.environ['APOLLO_API_KEY']}

def out(*a):
    print(US.join(str(x).replace(US, ' ').replace('\n', ' ') for x in a), flush=True)

def post(path, body):
    r = requests.post(base + path, headers=HDR, json=body, timeout=30)
    if r.status_code != 200:
        raise RuntimeError('http_%d' % r.status_code)
    return r.json()

BAD = re.compile(r'housekeep|security|loss prevention|accounting|accountant|finance|payroll|laundry|'
                 r'steward|engineer|maintenance|\bit\b|information technology|purchasing|procurement|'
                 r'human resource|\bhr\b|recruit|talent acquisition|\bspa\b|esthetician|massage|'
                 r'server|waiter|waitress|busser|bartender|dishwasher|line cook|prep cook|barback', re.I)
DM = re.compile(r'owner|founder|president|partner|principal|director|manager|\bgm\b|\bceo\b|\bcoo\b|'
                r'event|entertainment|booking|operations|chef|proprietor|managing|beverage|catering|'
                r'sales|hospitality|membership|sommelier|winemaker|curator|coordinator', re.I)
LOCS = ['Maryland', 'Virginia', 'Washington, DC', 'District of Columbia']
try:
    people = post('/mixed_people/api_search',
                  {'q_organization_domains_list': [vd], 'per_page': 25, 'page': 1}).get('people') or []
    via = 'domain'
    if not people:
        # Name fallback: only people whose Apollo org is this venue by name AND not on another domain.
        via = 'name'
        cand = post('/mixed_people/api_search',
                    {'q_keywords': vn, 'person_locations': LOCS, 'per_page': 25, 'page': 1}).get('people') or []
        for p in cand:
            org = p.get('organization') or {}
            oname = org.get('name') or p.get('organization_name') or ''
            odom = org.get('primary_domain') or org.get('website_url') or ''
            if R.org_name_matches(oname, vn) and (not odom or R.registrable_domain(odom) == vd):
                people.append(p)
except Exception as e:
    out('FAILED', 'search_' + re.sub(r'\W+', '_', str(e))[:40])
    sys.exit(0)
out('FOUND', len(people), via)
handled = set(l.strip() for l in open(handled_f, encoding='utf-8', errors='replace') if l.strip())
chosen, already = [], 0

def fold(s):
    return unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode()

def org_is_venue(o):
    # Apollo name-match gate, as in pipeline.sh step 3 for an org on the venue's own
    # domain: a wrong website on the sheet must not bring in another business's staff.
    norm = lambda s: re.sub(r'^the', '', re.sub(r'[^a-z0-9]', '', fold(s).lower().replace('&', 'and')))
    return norm(o) == norm(vn) or any(R.org_name_matches(a, b) for a, b in
                                      ((o, vn), (vn, o), (fold(o), fold(vn)), (fold(vn), fold(o))))

for p in people:
    title = p.get('title') or ''
    label = ((p.get('first_name') or '') + ' ' + (p.get('last_name_obfuscated') or p.get('last_name') or '')).strip()
    oname = (p.get('organization') or {}).get('name') or p.get('organization_name') or ''
    if via == 'domain' and oname and not org_is_venue(oname):
        out('ORGSKIP', label, title, oname)
        continue
    if title and BAD.search(title):
        out('SKIP', label, title, 'low-value role')
        continue
    if not p.get('has_email'):
        if DM.search(title):
            out('SKIP', label, title, 'no email in Apollo')
        continue
    key = re.sub(r'[^a-z]', '', (p.get('first_name') or '').lower()) + '|' + \
        re.sub(r'[^a-z]', '', (p.get('last_name_obfuscated') or p.get('last_name') or '').lower())[:1]
    if key in handled:
        already += 1  # the pipeline already enriched/saved/rejected this person for this venue
        continue
    if p.get('id'):
        chosen.append(p)
if already:
    out('SKIP', '%d people' % already, 'already on the sheet or in the candidate log', 'not re-enriched')
# Decision-makers first so the credit cap is spent on people who can book.
chosen.sort(key=lambda p: 0 if DM.search(p.get('title') or '') else 1)
chosen = chosen[:max(0, min(10, budget))]
if chosen:
    for p in chosen:
        out('ENRICH', ((p.get('first_name') or '') + ' ' + (p.get('last_name_obfuscated') or '')).strip(), p.get('title') or '')
    try:
        m = post('/people/bulk_match', {'details': [{'id': p['id']} for p in chosen], 'reveal_personal_emails': False})
    except Exception as e:
        out('FAILED', 'match_' + re.sub(r'\W+', '_', str(e))[:40])
        sys.exit(0)
    out('CREDITS', m.get('credits_consumed') if m.get('credits_consumed') is not None else len(chosen))
    for x in m.get('matches') or []:
        if not x:
            continue
        name = x.get('name') or ('%s %s' % (x.get('first_name') or '', x.get('last_name') or '')).strip()
        odom = (x.get('organization') or {}).get('primary_domain') or ''
        if via == 'name' and odom and R.registrable_domain(odom) != vd:
            out('SKIP', name, x.get('title') or '', 'Apollo org domain %s is not %s' % (odom, vd))
            continue
        # A name-search hit whose org has no domain is only matched by name: its email is still
        # domain-checked on save, but it can't become a pending contact on its own.
        dom_ok = via == 'domain' or bool(odom)
        out('MATCH', name, x.get('title') or '', x.get('email') or '', x.get('email_status') or '', '1' if dom_ok else '0')
PYEOF
    then
        APOLLO_ST="failed:crash"; log "  [Apollo] FAILED — search step crashed (see $ERR_LOG)"; return
    fi
    while IFS="$US" read -r kind a b c d e <&3; do
        case "$kind" in
            FAILED) APOLLO_ST="failed:$a"; log "  [Apollo] FAILED — $a" ;;
            FOUND) APOLLO_FOUND="$a"; APOLLO_VIA="$b"; log "  [Apollo] Found $a people (by $b)" ;;
            ENRICH) log "  [Apollo] Enriching: $a ($b)" ;;
            SKIP) log "  [Apollo] $a ($b) — $c" ;;
            ORGSKIP)
                log "  [Apollo] $a ($b) — Apollo org '$c' is not this venue by name; not enriched"
                record_candidate "" "$VENUE_ID" "$a" "$b" "postcheck_apollo" "not_saved:apollo_org_mismatch" "" contact "$a" ;;
            CREDITS) apollo_spent "$a" ;;
            MATCH)
                if [ -n "$c" ] && [ "$d" != "unavailable" ]; then
                    log "  [Apollo] Got email: $c ($d)"
                    hits=$((hits + 1))
                    pc_save_email "$c" "$a" "$b" "postcheck_apollo" external
                elif [ "$e" = "1" ]; then
                    log "  [Apollo] No email returned for $a"
                    pc_add_pending "$a" "$b" "postcheck_apollo"
                else
                    log "  CANDIDATE: $a ($b) — Apollo name match only (org has no domain); not saved"
                    record_candidate "" "$VENUE_ID" "$a" "$b" "postcheck_apollo" "not_saved:name_match_only" "" contact "$a"
                fi
                ;;
        esac
    done 3< "$out"
    [ "${APOLLO_ST%%:*}" != "failed" ] && [ "$(grep -c "^FOUND${US}" "$out")" = "0" ] && APOLLO_ST="failed:no_result"
    if [ "${APOLLO_ST%%:*}" != "failed" ] && [ "$hits" -gt 0 ]; then APOLLO_ST="ok"; fi
}

# Apollo bulk_match by name + venue domain. INFILE rows: key, first, last, title.
# Prints CREDITS / MATCH key name title email status / NOMATCH key / NOBUDGET key / FAILED reason.
apollo_match_names() {
    local infile="$1" with_org="$2"
    run_py apollo-match python3 - "$VENUE_DOMAIN" "$VENUE_NAME" "$infile" "$(apollo_budget)" "$with_org" <<'PYEOF'
import os, re, sys
import requests
vd, vn, infile, budget, with_org = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
US = '\x1f'
base = os.environ.get('APOLLO_API_BASE', 'https://api.apollo.io/api/v1').rstrip('/')
HDR = {'Content-Type': 'application/json', 'Cache-Control': 'no-cache', 'x-api-key': os.environ['APOLLO_API_KEY']}

def out(*a):
    print(US.join(str(x).replace(US, ' ').replace('\n', ' ') for x in a), flush=True)

rows = []
for line in open(infile, encoding='utf-8', errors='replace'):
    parts = (line.rstrip('\n').split(US) + ['', '', '', ''])[:4]
    if parts[0] and parts[1] and parts[2]:
        rows.append(parts)
for r in rows[max(0, budget):]:
    out('NOBUDGET', r[0])
rows = rows[:max(0, budget)]
for i in range(0, len(rows), 10):
    batch = rows[i:i + 10]
    details = []
    for key, first, last, title in batch:
        det = {'first_name': first, 'last_name': last, 'domain': vd}
        if with_org == '1':
            det['organization_name'] = vn
        details.append(det)
    try:
        r = requests.post(base + '/people/bulk_match', headers=HDR, timeout=30,
                          json={'details': details, 'reveal_personal_emails': False})
        if r.status_code != 200:
            raise RuntimeError('http_%d' % r.status_code)
        data = r.json()
    except Exception as e:
        out('FAILED', 'match_' + re.sub(r'\W+', '_', str(e))[:40])
        sys.exit(0)
    out('CREDITS', data.get('credits_consumed') if data.get('credits_consumed') is not None else len(batch))
    matches = data.get('matches') or []
    for j, (key, first, last, title) in enumerate(batch):
        m = matches[j] if j < len(matches) else None
        if not m:
            out('NOMATCH', key)
            continue
        name = m.get('name') or ('%s %s' % (m.get('first_name') or '', m.get('last_name') or '')).strip()
        out('MATCH', key, name, m.get('title') or title, m.get('email') or '', m.get('email_status') or '')
PYEOF
}

# LinkedIn people search in Chrome. Text-based parsing (same approach as pipeline.sh step 4,
# because LinkedIn obfuscates its CSS classes). An empty page is "blocked", not "empty",
# unless LinkedIn itself says "No results found".
LI_JS=$(cat <<'JSEOF'
(function() {
  var href = String(location.href);
  var main = document.querySelector("main");
  if (!main) return JSON.stringify({ok: false, url: href, n: 0, people: [], noresults: false});
  var text = main.innerText || "";
  var lines = text.split("\n").map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
  var people = [], n = 0;
  for (var i = 0; i < lines.length; i++) {
    if (/^\s*[•·]\s*(1st|2nd|3rd|\d+th)/.test(lines[i])) {
      n++;
      var name = i > 0 ? lines[i - 1] : "";
      var title = i + 1 < lines.length ? lines[i + 1] : "";
      var loc = i + 2 < lines.length ? lines[i + 2] : "";
      if (name && name.indexOf("Results for") !== 0) {
        name = name.replace(/,\s*(CCM|PGA|SHRM|CPA|MBA|PHR|SPHR|CEC|CMC|CEBS).*/i, "").trim();
        var tl = title.toLowerCase();
        people.push({name: name, title: title.substring(0, 160), loc: loc.substring(0, 80), current: tl.indexOf("past:") === -1 && tl.indexOf("former") !== 0});
      }
    } else if (lines[i] === "LinkedIn Member") {
      n++;
    }
  }
  return JSON.stringify({ok: true, url: href, n: n, people: people, noresults: /No results found/i.test(text)});
})()
JSEOF
)

# pipeline.sh holds /tmp/pipeline.lock.d (pid file) while it runs and drives the active
# Chrome tab. Driving it too would scrape one venue's page into another's results, so
# Chrome is off-limits unless that pipeline is the one that called us (PIPELINE_LOCK_PID).
PIPELINE_LOCK_DIR="${PIPELINE_LOCK_DIR:-/tmp/pipeline.lock.d}"
chrome_in_use_by_pipeline() {
    local pid
    pid=$(tr -cd '0-9' < "$PIPELINE_LOCK_DIR/pid" 2>/dev/null)
    [ -n "$pid" ] || return 1
    [ "$pid" = "${PIPELINE_LOCK_PID:-}" ] && return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o command= 2>/dev/null | grep -q 'pipeline\.sh' || return 1
    CHROME_LOCK_PID="$pid"
    return 0
}

linkedin_pass() {
    LI_ST="empty"
    if [ "$POSTCHECK_LINKEDIN" = "0" ]; then
        LI_ST="skipped:disabled"; log "  [LinkedIn] SKIPPED — POSTCHECK_LINKEDIN=0"; return
    fi
    if chrome_in_use_by_pipeline; then
        LI_ST="blocked:chrome_in_use_by_pipeline"
        log "  [LinkedIn] BLOCKED — pipeline.sh (pid $CHROME_LOCK_PID) is using Chrome; not driving it (website/Apollo checks still run)"
        return
    fi
    local running q url js_out="" try res state n kept li_url key first last title kind a b c d e
    running=$(with_timeout 20 osascript -e 'application "Google Chrome" is running' 2>>"$ERR_LOG")
    if [ "$running" != "true" ]; then
        LI_ST="failed:chrome_not_running"; log "  [LinkedIn] FAILED — Google Chrome is not running"; return
    fi
    log "  Searching LinkedIn for: $VENUE_NAME"
    q=$(run_py li-quote python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$VENUE_NAME") || { LI_ST="failed:encode"; return; }
    url="https://www.linkedin.com/search/results/people/?keywords=${q}&origin=SWITCH_SEARCH_VERTICAL"
    if ! with_timeout 30 osascript -e 'on run argv' -e 'tell application "Google Chrome" to set URL of active tab of front window to (item 1 of argv)' -e 'end run' "$url" >/dev/null 2>>"$ERR_LOG"; then
        LI_ST="failed:chrome_navigate"; log "  [LinkedIn] FAILED — Chrome could not open the search (no window?)"; return
    fi
    sleep 5
    for try in 1 2 3 4; do
        js_out=$(with_timeout 30 osascript -e 'on run argv' -e 'tell application "Google Chrome" to execute active tab of front window javascript (item 1 of argv)' -e 'end run' "$LI_JS" 2>>"$ERR_LOG")
        case "$js_out" in ''|'missing value') break ;; esac
        echo "$js_out" | grep -q '"n":0,' || break
        echo "$js_out" | grep -q '"noresults":true' && break
        sleep 3
    done
    if [ -z "$js_out" ] || [ "$js_out" = "missing value" ]; then
        LI_ST="failed:chrome_js"
        log "  [LinkedIn] FAILED — Chrome returned nothing (View > Developer > Allow JavaScript from Apple Events must be on)"
        return
    fi
    printf '%s' "$js_out" > "$PC_TMP/li.json"
    : > "$PC_TMP/li_people"
    res=$(run_py li-filter python3 - "$SCRIPT_DIR" "$PC_TMP/li.json" "$VENUE_NAME" "$PC_TMP/known_names" "$PC_TMP/li_people" <<'PYEOF'
import json, re, sys
sd, jf, vn, known_f, out_f = sys.argv[1:6]
sys.path.insert(0, sd)
import outreach_rules as R
US = '\x1f'
try:
    d = json.loads(open(jf, encoding='utf-8', errors='replace').read())
except Exception:
    print(US.join(['STATE', 'badjson', '0', '0', '']))
    sys.exit(0)
url = str(d.get('url') or '')
n = int(d.get('n') or 0)
if re.search(r'/(login|authwall|checkpoint|uas/)|signup', url, re.I):
    state = 'wall'
elif n == 0:
    state = 'noresults' if d.get('noresults') else 'zero'
else:
    state = 'found'
known = set(l.strip() for l in open(known_f, encoding='utf-8', errors='replace') if l.strip())
KEEP = re.compile(r'owner|founder|president|partner|principal|director|manager|coordinator|executive|'
                  r'officer|\bceo\b|\bcoo\b|\bgm\b|event|entertainment|booking|hospitality|operations|'
                  r'membership|food|beverage|catering|sales|curator|artistic|program|sommelier|'
                  r'winemaker|head|chef|proprietor|managing', re.I)
SKIP = re.compile(r'intern|student|volunteer|accountant|attorney|lawyer|developer|engineer|software|'
                  r'designer|\bit\b|data|analyst|junior|busser|server|\bhost\b|bartender|cook', re.I)
vnorm = ''.join(re.findall(r'[a-z0-9]', vn.lower()))
# LinkedIn search isn't location-filtered: "Sales Manager at The Capital Grille" can be any city.
DMV = re.compile(r'\b(MD|VA|DC|D\.C\.)\b|Maryland|Virginia|District of Columbia|Washington,? D\.?C|'
                 r'Washington DC-Baltimore|Baltimore|Annapolis|Arlington|Alexandria|Bethesda|Rockville|'
                 r'Frederick|Leesburg|Fairfax|Richmond|Charlottesville|Middleburg', re.I)
kept = []
for p in d.get('people') or []:
    if not p.get('current', True):
        continue
    title = str(p.get('title') or '')
    parts = re.split(r'\s+(?:at|@)\s+', title, flags=re.I)
    org_part = parts[-1] if len(parts) > 1 else ''
    tnorm = ''.join(re.findall(r'[a-z0-9]', title.lower()))
    # The headline has to name this venue, not just share a word with it.
    if not ((len(vnorm) >= 5 and vnorm in tnorm) or (org_part and R.org_name_matches(org_part, vn))):
        continue
    if SKIP.search(title) or not KEEP.search(title):
        continue
    name = R.clean_person_name(str(p.get('name') or ''))
    if not name or re.sub(r'\s+', ' ', name.lower()) in known:
        continue
    toks = name.split()
    if len(toks[-1].strip('.')) <= 2:
        continue
    loc = str(p.get('loc') or '').replace(US, ' ')
    kept.append(US.join([name, toks[0], toks[-1], title[:160], loc[:80], '1' if DMV.search(loc) else '0']))
with open(out_f, 'w', encoding='utf-8') as f:
    f.write(''.join(k + '\n' for k in kept))
print(US.join(['STATE', state, str(n), str(len(kept)), url]))
PYEOF
) || { LI_ST="failed:parse"; log "  [LinkedIn] FAILED — could not parse the results page (see $ERR_LOG)"; return; }
    IFS="$US" read -r _ state n kept li_url <<< "$res"
    LI_RESULTS="${n:-0}"; LI_RELEVANT="${kept:-0}"
    case "$state" in
        wall)
            LI_ST="blocked:login_wall"; log "  [LinkedIn] BLOCKED — login wall / checkpoint ($li_url)"; return ;;
        zero)
            LI_ST="blocked:no_results_unverified"
            log "  [LinkedIn] No results — LinkedIn did not say 'No results found' (login wall, search limit or page not rendered); not counted as empty"
            return ;;
        noresults)
            LI_ST="empty"; log "  [LinkedIn] No results"; return ;;
        found) ;;
        *)
            LI_ST="failed:parse"; log "  [LinkedIn] FAILED — unreadable results page"; return ;;
    esac
    log "  [LinkedIn] $n results on page 1, $kept at this venue with a relevant title"
    if [ "${kept:-0}" -eq 0 ] 2>/dev/null; then
        log "  [LinkedIn] No relevant people found (none with venue in title)"
        return
    fi
    while IFS="$US" read -r key first last title a b <&3; do
        [ -n "$key" ] && log "  [LinkedIn] $key — $title${a:+ ($a)}"
    done 3< "$PC_TMP/li_people"
    local before=$((V_SAVED + V_PENDING))
    if [ -n "$APOLLO_API_KEY" ] && [ -n "$VENUE_DOMAIN" ] && [ "$VENUE_SHARED_DOMAIN" != "true" ] && [ "$(apollo_budget)" -gt 0 ]; then
        apollo_match_names "$PC_TMP/li_people" 0 > "$PC_TMP/li_match" || echo "FAILED${US}crash" >> "$PC_TMP/li_match"
        while IFS="$US" read -r kind a b c d e <&3; do
            case "$kind" in
                CREDITS) apollo_spent "$a" ;;
                FAILED) log "  [LinkedIn] Apollo enrichment failed ($a) — saving names as pending"
                        while IFS="$US" read -r key first last title _ _ <&4; do
                            [ -n "$key" ] && li_pending "$key" "$title"
                        done 4< "$PC_TMP/li_people" ;;
                MATCH)
                    enrich_attempted "$a" MATCH
                    title=$(field_for_key "$PC_TMP/li_people" "$a" 4)
                    if [ -n "$d" ] && [ "$e" != "unavailable" ]; then
                        log "  >>> $a ($c): $d [$e]"
                        pc_save_email "$d" "$a" "${title:-$c}" "postcheck_linkedin+apollo" external
                    else
                        li_pending "$a" "${title:-$c}"
                    fi
                    ;;
                NOMATCH|NOBUDGET)
                    [ "$kind" = "NOMATCH" ] && enrich_attempted "$a" NOMATCH
                    title=$(field_for_key "$PC_TMP/li_people" "$a" 4)
                    li_pending "$a" "$title"
                    ;;
            esac
        done 3< "$PC_TMP/li_match"
    else
        while IFS="$US" read -r key first last title _ _ <&3; do
            [ -n "$key" ] && li_pending "$key" "$title"
        done 3< "$PC_TMP/li_people"
    fi
    [ $((V_SAVED + V_PENDING)) -gt "$before" ] && LI_ST="ok"
}

# A LinkedIn person with no email becomes a pending contact only when their profile location
# is in the DC/MD/VA area; otherwise the same-named business elsewhere is as likely.
li_pending() {
    local key="$1" title="$2" loc dmv
    loc=$(field_for_key "$PC_TMP/li_people" "$key" 5)
    dmv=$(field_for_key "$PC_TMP/li_people" "$key" 6)
    if [ "$dmv" = "1" ]; then
        pc_add_pending "$key" "$title" "postcheck_linkedin"
    else
        log "  CANDIDATE: $key ($title) — LinkedIn location '${loc:-unknown}' isn't DC/MD/VA; not saved"
        record_candidate "" "$VENUE_ID" "$key" "$title" "postcheck_linkedin" "not_saved:location_unverified" "" contact "$key"
    fi
}

# Named pending contacts at this venue (no email yet): one Apollo people/match each,
# never for masked names (Apollo "Sm***h") and never twice within ENRICH_RETRY_DAYS.
enrich_pass() {
    ENRICH_ST="empty"
    if [ ! -s "$PC_TMP/pending_list" ]; then ENRICH_ST="skipped:no_pending"; return; fi
    if [ -z "$APOLLO_API_KEY" ]; then ENRICH_ST="skipped:no_api_key"; return; fi
    if [ "$VENUE_SHARED_DOMAIN" = "true" ]; then ENRICH_ST="skipped:shared_domain"; return; fi
    if [ -z "$VENUE_DOMAIN" ]; then ENRICH_ST="skipped:no_domain"; return; fi
    if [ "$(apollo_budget)" -le 0 ]; then ENRICH_ST="skipped:credit_cap"; return; fi
    log "  === Enriching Pending Contacts (name, no email) ==="
    local counts tag total masked bad recent selected from_apollo kind a b c d e title before
    counts=$(run_py enrich-select python3 - "$SCRIPT_DIR" "$PC_TMP/pending_list" "$ENRICH_ATTEMPTS" "$VENUE_ID" "$ENRICH_RETRY_DAYS" "$(apollo_budget)" "$PC_TMP/enrich_people" <<'PYEOF'
import os, re, sys, time
sd, pend_f, att_f, vid, days, budget, out_f = sys.argv[1:8]
sys.path.insert(0, sd)
import outreach_rules as R
US = '\x1f'
cut = time.time() - float(days) * 86400
recent = set()
if os.path.exists(att_f):
    for line in open(att_f, encoding='utf-8', errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 3 and p[1] == vid:
            try:
                if float(p[0]) >= cut:
                    recent.add(p[2])
            except ValueError:
                pass
total = masked = bad = skipped = from_apollo = 0
rows = []
for line in open(pend_f, encoding='utf-8', errors='replace'):
    name, title, source = (line.rstrip('\n').split(US) + ['', '', ''])[:3]
    name = name.strip()
    if not name:
        continue
    total += 1
    if '*' in name:
        masked += 1
        continue
    if 'apollo' in source.lower():
        from_apollo += 1  # Apollo itself said it has no email for this person
        continue
    clean = R.clean_person_name(name)
    if not clean:
        bad += 1
        continue
    if re.sub(r'\s+', ' ', name.lower()) in recent:
        skipped += 1
        continue
    t = clean.split()
    rows.append(US.join([name, t[0], t[-1], title]))
rows = rows[:max(0, int(budget))]
with open(out_f, 'w', encoding='utf-8') as f:
    f.write(''.join(r + '\n' for r in rows))
print(US.join(str(x) for x in ['COUNTS', total, masked, bad, skipped, len(rows), from_apollo]))
PYEOF
) || { ENRICH_ST="failed:crash"; log "  [ENRICH] FAILED — could not read pending contacts (see $ERR_LOG)"; return; }
    IFS="$US" read -r tag total masked bad recent selected from_apollo <<< "$counts"
    log "  [ENRICH] $total pending: $masked masked (skipped), ${from_apollo:-0} added from Apollo without email (skipped), $bad not a person name, $recent tried in the last ${ENRICH_RETRY_DAYS}d, $selected to try"
    if [ "${selected:-0}" -eq 0 ] 2>/dev/null; then ENRICH_ST="skipped:nothing_to_try"; return; fi
    while IFS="$US" read -r a b c title <&3; do
        [ -n "$a" ] && log "  [ENRICH] $a (${title}) at $VENUE_ID"
    done 3< "$PC_TMP/enrich_people"
    before=$((V_UPDATED + V_SAVED))
    apollo_match_names "$PC_TMP/enrich_people" 1 > "$PC_TMP/enrich_match" || echo "FAILED${US}crash" >> "$PC_TMP/enrich_match"
    while IFS="$US" read -r kind a b c d e <&3; do
        case "$kind" in
            CREDITS) apollo_spent "$a" ;;
            FAILED) ENRICH_ST="failed:$a"; log "  [ENRICH] FAILED — Apollo people/match: $a" ;;
            MATCH|NOMATCH)
                enrich_attempted "$a" "$kind"
                title=$(field_for_key "$PC_TMP/enrich_people" "$a" 4)
                if [ "$kind" = "MATCH" ] && [ -n "$d" ] && [ "$e" != "unavailable" ]; then
                    log "  [ENRICH] Got: $d ($e)"
                    pc_save_email "$d" "$a" "$title" "postcheck_enrich" external "$a"
                else
                    log "  [ENRICH] No email found for $a"
                fi
                ;;
        esac
    done 3< "$PC_TMP/enrich_match"
    if [ "${ENRICH_ST%%:*}" != "failed" ] && [ $((V_UPDATED + V_SAVED)) -gt "$before" ]; then ENRICH_ST="ok"; fi
}

check_venue() {
    local VID="$1" FORCE="${2:-0}"
    VENUE_ID="$VID"
    V_EMAILS=0; V_SAVED=0; V_UPDATED=0; V_PENDING=0; V_DEFERRED=0; V_REJECTED=0; V_ROLE_CAND=0
    V_SOCIALS=0; V_CHECK_FAILED=0; V_SAVE_ERR=0; FORM_ST="none"; SOCIAL_NOTE=""; LOAD_ERROR=""; PAGES_OK=0; CONTACT_FORM=""
    V_NEEDS_NAME=0; V_PEOPLE=0; WEB_SCAN_ERR=0; V_ZB_ERR=0; CRAWL_PAGES=0; PAGES_CUT=0; VISITED="none"; CRAWL_VIA="none"
    WEB_ST="skipped"; CRAWL_ST="ok"; APOLLO_ST="skipped"; LI_ST="skipped"; ENRICH_ST="skipped"
    APOLLO_FOUND="-"; APOLLO_VIA="-"; LI_RESULTS="-"; LI_RELEVANT="-"; VENUE_BASE=""
    echo 0 > "$PC_TMP/zb_venue_count"

    if ! load_venue "$VID"; then
        log ""
        log "=== ? ($VID) ==="
        log "  [ERROR] Could not load venue from the sheet: $LOAD_ERROR"
        step_line "$VID" failed "reason=$(printf '%s' "${LOAD_ERROR:-venue_detail}" | tr ':' '_')"
        return 2
    fi
    log ""
    log "=== $VENUE_NAME ($VID) | $VENUE_CITY, $VENUE_STATE | Contacts: $N_CONTACTS ==="

    if [ "$N_VALID" -gt 0 ] && [ "$FORCE" != "1" ]; then
        log "  Has $N_VALID valid/role/unverified contacts — second pass not needed"
        step_line "$VID" skipped "reason=has_contacts valid=$N_VALID"
        return 1
    fi
    if [ "$N_CONTACTS" -gt 0 ]; then
        log "  Has $N_CONTACTS existing contacts ($N_VALID valid/role/unverified) — checking for more"
    fi
    if [ -z "$VENUE_WEBSITE" ]; then
        log "  No website on file — skipping web check"
        step_line "$VID" skipped "reason=no_website"
        return 1
    fi
    if [ "$VENUE_NON_VENUE_HOST" = "true" ]; then
        log "  Website is a listing/social page, not the venue's own site ($VENUE_WEBSITE) — skipping"
        step_line "$VID" skipped "reason=non_venue_website"
        return 1
    fi
    log "  Website: $VENUE_WEBSITE"
    if [ "$VENUE_SHARED_DOMAIN" = "true" ]; then
        if [ -n "$VENUE_SITE_PREFIX" ]; then
            log "  Shared brand domain — only pages under $VENUE_SITE_PREFIX count as the venue's own"
        else
            log "  [WARN] Website is a shared brand homepage ($VENUE_DOMAIN) with no property path — nothing on it counts as this venue's own"
        fi
    fi

    web_pass
    save_contact_form
    if [ "$V_EMAILS" -gt 0 ]; then
        local em ev nm src ttl amb
        while IFS="$US" read -r em ev nm src ttl amb <&3; do
            [ -n "$em" ] && pc_save_email "$em" "$nm" "$ttl" "postcheck_website" "$ev" "" "$src"
        done 3< "$PC_TMP/emails_agg"
    fi
    save_people
    save_socials
    apollo_pass
    linkedin_pass
    enrich_pass

    if [ "$V_EMAILS" -eq 0 ] && [ -z "$CONTACT_FORM" ] && [ "$V_PEOPLE" -eq 0 ]; then
        log "  Nothing found on website"
    fi
    if [ "$WEB_ST" != "failed" ]; then
        if [ "$V_EMAILS" -gt 0 ] || [ -n "$CONTACT_FORM" ] || [ "$V_SOCIALS" -gt 0 ] || [ "$V_PEOPLE" -gt 0 ]; then WEB_ST="ok"; else WEB_ST="empty"; fi
    fi

    # failed = something crashed, errored or was degraded (C3); the first cause is the reason.
    local status reason="" usable s
    usable=$((V_SAVED + V_UPDATED + V_PENDING + V_SOCIALS))
    [ "$FORM_ST" = "saved" ] && usable=$((usable + 1))
    for s in "web:$WEB_ST" "crawl:$CRAWL_ST" "apollo:$APOLLO_ST" "linkedin:$LI_ST" "enrich:$ENRICH_ST"; do
        case "${s#*:}" in failed*) [ -z "$reason" ] && reason="${s%%:*}_${s#*:}" ;; esac
    done
    [ -z "$reason" ] && [ "$WEB_SCAN_ERR" -gt 0 ] && reason="page_scan_crash"
    [ -z "$reason" ] && [ "$V_CHECK_FAILED" -gt 0 ] && reason="email_check_crash"
    [ -z "$reason" ] && [ "$V_SAVE_ERR" -gt 0 ] && reason="sheet_write_failed"
    [ -z "$reason" ] && [ -n "$SOCIAL_NOTE" ] && reason="$SOCIAL_NOTE"
    # A deferral (saved as unverified) is not a failure; a missing/crashing ZB guard is.
    [ -z "$reason" ] && [ "$V_ZB_ERR" -gt 0 ] && reason="zb_guard_error"
    [ -z "$reason" ] && [ "$V_NEEDS_NAME" -gt 0 ] && reason="valid_email_unsaved_needs_name"
    if [ -n "$reason" ]; then
        status="failed"
    elif [ "$LI_ST" = "blocked:chrome_in_use_by_pipeline" ]; then
        # Chrome steps were not run at all, so this pass is incomplete even if it saved things.
        status="blocked"; reason="chrome_in_use_by_pipeline"
    elif [ "$usable" -gt 0 ]; then
        status="ok"
    elif [ "${LI_ST%%:*}" = "blocked" ]; then
        status="blocked"; reason="linkedin_${LI_ST#*:}"
    else
        status="empty"
    fi
    reason=$(printf '%s' "$reason" | tr ':' '_')
    step_line "$VID" "$status" "web=$WEB_ST via=$CRAWL_VIA crawl=$CRAWL_ST crawl_pages=$CRAWL_PAGES pages=$PAGES_OK pages_cut=$PAGES_CUT visited=$VISITED emails=$V_EMAILS saved=$V_SAVED enriched=$V_UPDATED pending=$V_PENDING people=$V_PEOPLE deferred=$V_DEFERRED rejected=$V_REJECTED role_candidates=$V_ROLE_CAND unsaved_valid=$V_NEEDS_NAME save_errors=$V_SAVE_ERR form=$FORM_ST socials=$V_SOCIALS apollo=$APOLLO_ST apollo_found=$APOLLO_FOUND apollo_via=$APOLLO_VIA linkedin=$LI_ST li_results=$LI_RESULTS li_relevant=$LI_RELEVANT enrich=$ENRICH_ST${reason:+ reason=$reason}"
    T_SAVED=$((T_SAVED + V_SAVED + V_UPDATED)); T_PENDING=$((T_PENDING + V_PENDING))
    T_DEFERRED=$((T_DEFERRED + V_DEFERRED)); T_REJECTED=$((T_REJECTED + V_REJECTED))
    [ "$status" = "failed" ] && return 2
    return 0
}

# --- Main ---
VENUES_CSV=""; RUN_ID_ARG=""; EXPLICIT=()
while [ $# -gt 0 ]; do
    case "$1" in
        --venues)
            [ $# -ge 2 ] || { echo "Usage: $0 --venues ID1,ID2,... [--run-id RUN_ID]" >&2; exit 1; }
            VENUES_CSV="$2"; shift 2 ;;
        --venues=*) VENUES_CSV="${1#*=}"; shift ;;
        --run-id)
            [ $# -ge 2 ] || { echo "Usage: $0 [--venues ID1,ID2,...] --run-id RUN_ID" >&2; exit 1; }
            RUN_ID_ARG="$2"; shift 2 ;;
        --run-id=*) RUN_ID_ARG="${1#*=}"; shift ;;
        -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 0 ;;
        -*) echo "Unknown option: $1 (see $0 --help)" >&2; exit 1 ;;
        *) EXPLICIT+=("$1"); shift ;;
    esac
done

echo "" >> "$LOG_FILE"
log "=== Post-Pipeline Check Started ==="

FORCE=0
VENUE_LIST=()
RUN_ID="$RUN_ID_ARG"
if [ ${#EXPLICIT[@]} -gt 0 ] || [ -n "$VENUES_CSV" ]; then
    [ ${#EXPLICIT[@]} -gt 0 ] && FORCE=1
    CSV_IDS=()
    [ -n "$VENUES_CSV" ] && IFS=', ' read -r -a CSV_IDS <<< "$VENUES_CSV"
    for v in "${EXPLICIT[@]}" "${CSV_IDS[@]}"; do
        [ -n "$v" ] && VENUE_LIST+=("$v")
    done
    MODE="explicit"
    [ ${#EXPLICIT[@]} -eq 0 ] && MODE="venues"
else
    # Default: the current run's registered venues (mark_step.sh --batch writes the ledger).
    MODE="run"
    if [ -z "$RUN_ID" ]; then
        RUN_ID=$(head -1 "$RUNS_DIR/CURRENT" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$RUN_ID" ]; then
        log "[ERROR] No --venues given and no current run in reports/runs/CURRENT — nothing to check."
        log "        Use: ./postcheck.sh --venues ID1,ID2,... or register the batch with mark_step.sh --batch"
        log "=== Post-Pipeline Check FAILED ==="
        exit 1
    fi
    LEDGER="$RUNS_DIR/${RUN_ID}.jsonl"
    if [ ! -s "$LEDGER" ]; then
        log "[ERROR] Run ledger not found or empty: $LEDGER"
        log "=== Post-Pipeline Check FAILED ==="
        exit 1
    fi
    LEDGER_ROWS=$(run_py ledger python3 - "$LEDGER" <<'PYEOF'
import json, sys, time
from datetime import datetime
seen, started = [], ''
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get('type') == 'run' and r.get('step') == 'start' and not started:
        started = str(r.get('ts', ''))
    if r.get('step') == 'registered':
        v = str(r.get('venue_id') or '').strip()
        if v and v not in seen:
            seen.append(v)
try:
    age = int((time.time() - datetime.strptime(started, '%Y-%m-%d %H:%M:%S').timestamp()) // 3600)
except ValueError:
    age = -1
print('STARTED\x1f' + started + '\x1f' + str(age))
for v in seen:
    print('VID\x1f' + v)
PYEOF
)
    LEDGER_AGE=-1
    while IFS="$US" read -r kind val age; do
        case "$kind" in
            STARTED) log "Run $RUN_ID (ledger started ${val:-?})"; LEDGER_AGE="${age:--1}" ;;
            VID) VENUE_LIST+=("$val") ;;
        esac
    done <<< "$LEDGER_ROWS"
    # CURRENT is only moved by mark_step.sh --batch. A stale one means this batch was never
    # registered, and re-checking an old run's venues would waste the run's time and credits.
    if [ -z "$RUN_ID_ARG" ] && [ "$LEDGER_AGE" -ge 24 ] 2>/dev/null; then
        log "[ERROR] reports/runs/CURRENT points at $RUN_ID, started ${LEDGER_AGE}h ago — not this batch."
        log "        Use: ./postcheck.sh --venues ID1,ID2,... (or --run-id $RUN_ID to re-check that run on purpose)"
        log "=== Post-Pipeline Check FAILED ==="
        exit 1
    fi
fi

GOOD_LIST=()
for v in "${VENUE_LIST[@]}"; do
    if [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        case " ${GOOD_LIST[*]} " in *" $v "*) continue ;; esac
        GOOD_LIST+=("$v")
    elif [ -n "$v" ]; then
        log "[ERROR] Ignoring malformed venue id: $v"
    fi
done
if [ ${#GOOD_LIST[@]} -eq 0 ]; then
    log "[ERROR] No venues to check (mode: $MODE${RUN_ID:+, run $RUN_ID})"
    log "=== Post-Pipeline Check FAILED ==="
    exit 1
fi
log "Checking ${#GOOD_LIST[@]} venues (mode: $MODE${RUN_ID:+, run $RUN_ID}) — venues with a valid/role/unverified contact are skipped"
[ "$FORCE" = "1" ] && log "Explicit venue ids: checking even if they already have contacts"

CHECKED=0; SKIPPED=0; FAILED_N=0; TIMED_OUT=0
T_SAVED=0; T_PENDING=0; T_DEFERRED=0; T_REJECTED=0
RUN_T0=$SECONDS
for VID in "${GOOD_LIST[@]}"; do
    # Bounded for unattended runs: venues not reached are reported, never silently dropped.
    if [ "$POSTCHECK_MAX_MINUTES" -gt 0 ] && [ $((SECONDS - RUN_T0)) -ge $((POSTCHECK_MAX_MINUTES * 60)) ]; then
        [ "$TIMED_OUT" -eq 0 ] && log "" && log "[WARN] POSTCHECK_MAX_MINUTES=$POSTCHECK_MAX_MINUTES reached — remaining venues not checked"
        step_line "$VID" skipped "reason=time_budget"
        TIMED_OUT=$((TIMED_OUT + 1))
        continue
    fi
    check_venue "$VID" "$FORCE"
    case $? in
        0) CHECKED=$((CHECKED + 1)) ;;
        1) SKIPPED=$((SKIPPED + 1)) ;;
        *) CHECKED=$((CHECKED + 1)); FAILED_N=$((FAILED_N + 1)) ;;
    esac
done

log ""
log "=== Final Audit ==="
log "Venues: ${#GOOD_LIST[@]} | Checked: $CHECKED | Skipped: $SKIPPED | Failed/degraded: $FAILED_N | Not reached (time budget): $TIMED_OUT | Contacts saved: $T_SAVED | Pending added: $T_PENDING | Deferred (saved unverified, needs ZB check): $T_DEFERRED | Rejected: $T_REJECTED | Apollo credits: $(cat "$PC_TMP/apollo_credits") | Minutes: $(( (SECONDS - RUN_T0) / 60 ))"
[ "$CHECKED" -eq 0 ] && [ "$TIMED_OUT" -eq 0 ] && log "All ${#GOOD_LIST[@]} venues already have a valid/role/unverified contact or no usable website — nothing needed a second pass"
[ "$FAILED_N" -gt 0 ] && log "WARNING: $FAILED_N venue(s) failed or degraded — see the [STEP] lines above and $ERR_LOG"
[ "$TIMED_OUT" -gt 0 ] && log "WARNING: $TIMED_OUT venue(s) not checked because of the time budget — re-run: ./postcheck.sh --venues <ids>"

log ""
log "=== Post-Pipeline Check Complete ==="
[ "$FAILED_N" -gt 0 ] || [ "$TIMED_OUT" -gt 0 ] && exit 2
exit 0
