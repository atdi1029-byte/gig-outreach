#!/bin/bash
# =============================================================
# Gig Outreach Master Pipeline — FULLY SELF-CONTAINED
# One script does everything. No external dependencies.
#
# Runbook: CLAUDE.md in this folder. Usage:
#   RUN_ID=run-YYYYMMDD-HHMM ./pipeline.sh --run 50   plan ~50 venues (build_batch.sh
#                                   --total) and run them as batches of <=8, one report
#   ./pipeline.sh --plan [PLAN|LATEST]    run an existing plan
#   ./pipeline.sh --batch venues.json     one batch (max 8)
#   ./pipeline.sh --resume [RUN_ID|LOG]   re-run unfinished venues, then continue the plan
#   ./pipeline.sh --report [RUN_ID]       regenerate the run's report
#   ./pipeline.sh "Exact Venue Name" | VENUE_ID [website]   one venue
#   ./pipeline.sh --linkedin-retry        LinkedIn pass for venues still pending
# Exit: 0 ok, 1 refused/error before start, 2 bad usage/batch, 3 STOPPED (resumable).
#
# Steps per venue: 1 website (Chrome + curl + static crawl: emails, people, forms,
# socials) · 1B/1C Google IG/FB · 2 social pages · 3 Apollo (org gate, domain + name
# search) · 4 LinkedIn → Apollo · 5 Google fallback · postcheck · final status (P4).
# Every step ends with one `[STEP] <venue_id> <step> <status> k=v...` line.
#
# Requirements:
#   - Chrome open and logged into LinkedIn (for Step 4)
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
#   - Python 3 with requests
#   - Apollo API key (set APOLLO_API_KEY env var or edit below)
# =============================================================

SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR_EARLY/.env" ] && source "$SCRIPT_DIR_EARLY/.env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# python3 on PATH can be an Intel-only build that dies with "Bad CPU type"; every
# `python3 ... 2>/dev/null` would then read as "found nothing".
. "$SCRIPT_DIR/env_check.sh" || exit 1
APPS_SCRIPT_URL="${APPS_SCRIPT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
ZEROBOUNCE_KEY="${ZEROBOUNCE_KEY:-}"
APOLLO_API_KEY="${APOLLO_API_KEY:-}"
APOLLO_API_BASE="https://api.apollo.io/api/v1"
APOLLO_CREDITS_USED=0
ZB_GUARD="${SCRIPT_DIR}/zerobounce_guard.py"
# One ZeroBounce run budget for the whole run (all batches/processes) when RUN_ID is
# given. reports/runs/CURRENT is not read here: at startup it can still name the
# previous run, whose spend would then count against this one.
ZB_RUN_ID="${ZB_RUN_ID:-${RUN_ID:-pipeline-$(date +%Y%m%dT%H%M%S)-$$}}"
export ZB_RUN_ID
ZB_VENUE_CREDITS=0
MAX_ZB_PER_VENUE=${MAX_ZB_PER_VENUE:-40}
LOG_FILE="${SCRIPT_DIR}/pipeline.log"
# Discovery evidence is append-only: candidates are retained even when verification
# later rejects them, so a "miss" can be audited instead of disappearing.
CANDIDATE_LOG="${SCRIPT_DIR}/reports/discovery-candidates.jsonl"
COVERAGE_DIR="${SCRIPT_DIR}/reports/web-coverage"
# stderr of python/osascript helpers (P9), prefixed with venue and step.
ERR_LOG="${SCRIPT_DIR}/reports/runs/python-errors.log"
mkdir -p "$(dirname "$CANDIDATE_LOG")" "$COVERAGE_DIR" "$(dirname "$ERR_LOG")"
touch "$ERR_LOG" 2>/dev/null
# Owner's own emails — never add these as venue contacts
OWN_EMAILS="atdi1029@gmail.com|alexbarnettclassical@gmail.com|abar89251@gmail.com|alex@alexbarnettclassical.com"

# Per-venue globals (C1). run_venue sets them at the start of every venue.
VENUE_NAME=""
VENUE_ID=""
VENUE_WEBSITE=""
VENUE_DOMAIN=""            # registrable domain of the venue website ('' if none / non-venue host)
VENUE_SHARED_DOMAIN="false" # "true" when VENUE_DOMAIN is a shared brand domain (sonesta.com, ...)
VENUE_SITE_PREFIX=""       # host+path prefix of the property's own pages
APOLLO_DOMAIN=""

# Per-venue state files, so values survive the subshells some callers run in.
KNOWN_EMAILS_FILE="/tmp/pipeline_known_emails.txt"
KNOWN_NAMES_FILE="/tmp/pipeline_known_names.txt"
KNOWN_DEFERRED_FILE="/tmp/pipeline_known_deferred.tsv"
DEFERRED_COUNT_FILE="/tmp/pipeline_deferred_count"
SCRAPE_JS="/tmp/pipeline_website_scrape.js"
MAX_WEB_PAGES=${MAX_WEB_PAGES:-30}   # Chrome renders per venue, highest-value pages first
KNOWN_EMAILS=""
KNOWN_NAMES=""
VENUE_EXISTING_FB=""       # set by load_existing: what the sheet already holds
VENUE_EXISTING_IG=""
VENUE_EXISTING_FORM=""
LOAD_EXISTING_OK="no"
VAP_OUTCOMES_FILE=""
WEB_DIR=""

rand_delay() {
    local min=$1 max=$2
    local delay=$(( RANDOM % (max - min + 1) + min ))
    echo "  [delay] Waiting ${delay}s..."
    sleep $delay
}

log() {
    echo "$1"
    echo "$(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}

# Machine-readable step result (C3): [STEP] <venue_id> <step> <status> <key=value ...>
step_result() {
    log "[STEP] $*"
}

# Append a stderr capture to ERR_LOG with a venue/step prefix. Apple's python
# warns about LibreSSL on every requests import; that line is noise, not a failure.
errlog_append() {
    local tag="$1" f="$2"
    [ -s "$f" ] || return 0
    grep -v -e 'NotOpenSSLWarning' -e 'warnings.warn(' -e '^$' "$f" | \
        awk -v p="$(date '+%Y-%m-%d %H:%M:%S') ${VENUE_ID:-${3:-?}} ${tag}: " '{print p $0}' >> "$ERR_LOG"
}

# pyrun TAG cmd... — run a command, keep stdout, send stderr to ERR_LOG (P9).
pyrun() {
    local tag="$1"; shift
    local errf rc
    errf=$(mktemp "${TMPDIR:-/tmp}/pipeline_err.XXXXXX")
    "$@" 2>"$errf"
    rc=$?
    errlog_append "$tag" "$errf"
    rm -f "$errf"
    return $rc
}

urlenc() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# api_get QUERY [MAX_TIME] — Apps Script GET with a timeout and one retry on a
# transport failure. Writes are safe to retry: add_contact dedupes, update_venue is idempotent.
api_get() {
    local query="$1" max_time="${2:-45}" out
    out=$(curl -sL --max-time "$max_time" "${APPS_SCRIPT_URL}?${query}" 2>/dev/null)
    if [ -z "$out" ]; then
        sleep 3
        out=$(curl -sL --max-time "$max_time" "${APPS_SCRIPT_URL}?${query}" 2>/dev/null)
    fi
    printf '%s' "$out"
}

# Parses a venue_detail response: writes the known-email/name/deferred files and
# prints OK<US>emails<US>names<US>facebook<US>instagram<US>contact_form (US = \x1f).
# Heredocs live in their own functions: bash 3.2 mis-parses a heredoc inside $().
_py_load_existing() {
    pyrun load_existing python3 - "$@" <<'PYEOF'
import json, sys
src, ef, nf, df = sys.argv[1:5]
US = "\x1f"
try:
    d = json.load(open(src))
except Exception as e:
    print("ERR" + US + "venue_detail unreadable: %s" % e)
    sys.exit(0)
if not isinstance(d, dict) or d.get("status") == "error":
    print("ERR" + US + "venue_detail error: %s" % (d.get("message", "") if isinstance(d, dict) else "bad shape"))
    sys.exit(0)
emails, names, deferred = [], [], []
for c in d.get("contacts", []) or []:
    e = str(c.get("email") or "").strip().lower()
    if e:
        # Deferred/unverified rows are re-checked when seen again and upgraded in place.
        if str(c.get("verified") or "") in ("deferred", "unverified"):
            deferred.append((e, str(c.get("contact_id") or "")))
        elif e not in emails:
            emails.append(e)
    n = str(c.get("name") or "").strip().lower()
    if n and n not in names:
        names.append(n)
open(ef, "w").write("".join(e + "\n" for e in emails))
open(nf, "w").write("".join(n + "\n" for n in names))
open(df, "w").write("".join("%s\t%s\n" % x for x in deferred))
v = d.get("venue") or {}
clean = lambda s: str(s or "").replace(US, " ").replace("\n", " ").strip()
print(US.join(["OK", "|||".join(emails), "|||".join(names),
               clean(v.get("facebook")), clean(v.get("instagram")), clean(v.get("contact_form"))]))
PYEOF
}

# Fetch existing contacts for a venue: sets KNOWN_EMAILS / KNOWN_NAMES ('|||'-joined,
# as other steps expect), rewrites the per-venue known-email files, and records the
# venue's current facebook/instagram/contact_form so step 1 never overwrites them.
load_existing() {
    local venue_id="$1"
    local tmpf="/tmp/pipeline_venue_detail.json"
    rm -f "$tmpf"
    : > "$KNOWN_EMAILS_FILE"; : > "$KNOWN_NAMES_FILE"; : > "$KNOWN_DEFERRED_FILE"
    KNOWN_EMAILS=""; KNOWN_NAMES=""
    VENUE_EXISTING_FB=""; VENUE_EXISTING_IG=""; VENUE_EXISTING_FORM=""
    LOAD_EXISTING_OK="no"
    api_get "action=venue_detail&venue_id=$(urlenc "$venue_id")" 45 > "$tmpf"
    local parsed
    parsed=$(_py_load_existing "$tmpf" "$KNOWN_EMAILS_FILE" "$KNOWN_NAMES_FILE" "$KNOWN_DEFERRED_FILE")
    local tag rest
    tag="${parsed%%$'\x1f'*}"
    if [ "$tag" = "OK" ]; then
        IFS=$'\x1f' read -r tag KNOWN_EMAILS KNOWN_NAMES VENUE_EXISTING_FB VENUE_EXISTING_IG VENUE_EXISTING_FORM <<< "$parsed"
        [ "$VENUE_EXISTING_FB" = "None" ] && VENUE_EXISTING_FB=""
        [ "$VENUE_EXISTING_IG" = "None" ] && VENUE_EXISTING_IG=""
        [ "$VENUE_EXISTING_FORM" = "None" ] && VENUE_EXISTING_FORM=""
        LOAD_EXISTING_OK="yes"
    else
        rest="${parsed#*$'\x1f'}"
        log "  [WARN] Could not load existing contacts for $venue_id (${rest:-no response}) — dedupe falls back to the server"
    fi
}

email_known() {
    local email_lower
    email_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [ -z "$email_lower" ] && return 1
    printf '%s\n' "$KNOWN_EMAILS" | tr '|' '\n' | grep -Fxq -- "$email_lower" && return 0
    [ -f "$KNOWN_EMAILS_FILE" ] && grep -Fxq -- "$email_lower" "$KNOWN_EMAILS_FILE" && return 0
    return 1
}

name_known() {
    local name_lower
    name_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$name_lower" ] && return 1
    printf '%s\n' "$KNOWN_NAMES" | tr '|' '\n' | grep -Fxq -- "$name_lower" && return 0
    [ -f "$KNOWN_NAMES_FILE" ] && grep -Fxq -- "$name_lower" "$KNOWN_NAMES_FILE" && return 0
    return 1
}

remember_email() {
    local e="$1"
    KNOWN_EMAILS="${KNOWN_EMAILS:+${KNOWN_EMAILS}|||}${e}"
    printf '%s\n' "$e" >> "$KNOWN_EMAILS_FILE"
}

ZB_EXHAUSTED_FLAG="/tmp/pipeline_zb_paused_$$"
APOLLO_EXHAUSTED_FLAG="/tmp/pipeline_apollo_exhausted_$$"
MAX_APOLLO=${MAX_APOLLO:-300}  # Max Apollo credits per run (default 300, set MAX_APOLLO=N to override)
ZB_BANNER=$(python3 "$ZB_GUARD" budget --no-balance --run-id "$ZB_RUN_ID" 2>>"$ERR_LOG" | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s — run %s/%s, today %s/%s, reserve %s credits (%s)" % ("enabled" if d.get("enabled") else "DISABLED (unverified emails are saved as unverified)", d.get("run_used"), d.get("run_limit"), d.get("day_used"), d.get("day_limit"), d.get("reserve"), d.get("reason")))' 2>>"$ERR_LOG")
log "[ZB SAFE] Guard ${ZB_BANNER:-budget unreadable (see $ERR_LOG)}; run id $ZB_RUN_ID"

check_apollo_credits() {
    # Region B keeps the credit counter in a file so it survives per-venue subshells.
    type _rb_apollo_credits_sync >/dev/null 2>&1 && _rb_apollo_credits_sync
    if [ -z "$APOLLO_API_KEY" ]; then return 0; fi
    if [ -f "$APOLLO_EXHAUSTED_FLAG" ]; then return 1; fi
    if [ "$APOLLO_CREDITS_USED" -ge "$MAX_APOLLO" ] 2>/dev/null; then
        log "  [STOP] Apollo credit cap reached ($APOLLO_CREDITS_USED / $MAX_APOLLO used this run). Skipping Apollo."
        echo "exhausted" > "$APOLLO_EXHAUSTED_FLAG"
        return 1
    fi
    log "  [APOLLO] Credits used this run: $APOLLO_CREDITS_USED / $MAX_APOLLO"
    return 0
}

check_zb_credits() {
    # Cost guard: this is a no-charge budget/balance check. A failed check pauses
    # paid verification only; website/social discovery must continue.
    if [ ! -x "$ZB_GUARD" ]; then
        log "  [ZB SAFE] Guard missing — paid ZeroBounce verification disabled"
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    local info
    info=$(pyrun zb_budget python3 "$ZB_GUARD" budget --run-id "$ZB_RUN_ID" || true)
    if [ -z "$info" ]; then
        log "  [ZB SAFE] Could not read ZeroBounce budget — paid verification disabled (fail closed)"
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    local parsed allowed reason run_used run_limit day_used day_limit credits reserve
    parsed=$(printf '%s' "$info" | pyrun zb_budget python3 -c 'import json,sys; d=json.load(sys.stdin); print("\x1f".join(str(d.get(k,"")) for k in ("allowed","reason","run_used","run_limit","day_used","day_limit","credits_remaining","reserve")))' || true)
    IFS=$'\x1f' read -r allowed reason run_used run_limit day_used day_limit credits reserve <<< "$parsed"
    log "  [ZB SAFE] run ${run_used:-0}/${run_limit:-?}, today ${day_used:-0}/${day_limit:-?}, balance ${credits:-unknown}, reserve ${reserve:-?}"
    if [ "$allowed" != "True" ] && [ "$allowed" != "true" ]; then
        log "  [ZB SAFE] Paid verification paused: ${reason:-guard_denied}. Discovery will continue."
        echo "paused" > "$ZB_EXHAUSTED_FLAG"
        return 1
    fi
    rm -f "$ZB_EXHAUSTED_FLAG"
    return 0
}


record_candidate() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5" disposition="$6" evidence_url="${7:-}"
    [ -z "$email" ] && return
    CANDIDATE_LOG="$CANDIDATE_LOG" pyrun record_candidate python3 - "$email" "$venue_id" "$name" "$title" "$source" "$disposition" "$evidence_url" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
email, venue_id, name, title, source, disposition, evidence_url = sys.argv[1:8]
row = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "venue_id": venue_id,
    "email": email.lower().strip(),
    "name": name,
    "title": title,
    "source": source,
    "disposition": disposition,
    "evidence_url": evidence_url,
    "run_id": os.environ.get("RUN_ID", ""),
}
with open(os.environ["CANDIDATE_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF
}

# Outcome tally for the caller's [STEP] line (saved|role|known|reject|deferred|candidate|error).
vap_outcome() {
    [ -n "$VAP_OUTCOMES_FILE" ] && echo "$1" >> "$VAP_OUTCOMES_FILE"
    return 0
}

_py_encode_contact() {
    pyrun add_contact_encode python3 - "$@" <<'PYEOF'
import os, sys, urllib.parse
venue_id, name, title, email, source, verified, is_generic = sys.argv[1:8]
params = {
    'action': 'add_contact',
    'venue_id': venue_id,
    'name': name,
    'title': title,
    'email': email,
    'source': source,
    'verified': verified,
    'is_generic': is_generic,
}
# The venue's site redirects to another domain (ameliedc.com -> ameliewinebar.com):
# the backend only knows the sheet's website, so vouch for that domain explicitly.
if os.environ.get('PUSH_ALLOW_OFF_DOMAIN') == 'true':
    params['allow_off_domain'] = 'true'
print(urllib.parse.urlencode(params))
PYEOF
}

# _push_contact VENUE_ID NAME TITLE EMAIL SOURCE VERIFIED IS_GENERIC
# Echoes one of: created[:<name_rejected>] | duplicate:<existing_venue_id> |
# error:<reason>:<message>. Handles both backends: the new one answers
# created/duplicate/reason/existing_venue_id; the old one has no `created`, so its
# own read-after-write (`verified`, `persisted_email`) is used, then a readback.
_push_contact() {
    local venue_id="$1" name="$2" title="$3" email="$4" source="$5" verified="$6" is_generic="$7"
    local encoded resp verdict
    encoded=$(_py_encode_contact "$venue_id" "$name" "$title" "$email" "$source" "$verified" "$is_generic")
    if [ -z "$encoded" ]; then echo "error:encode_failed:"; return; fi
    resp=$(api_get "$encoded" 45)
    verdict=$(printf '%s' "$resp" | EMAIL="$email" VID="$venue_id" pyrun add_contact_parse python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("error:no_json_response:" + raw[:120].replace("\n", " ")); sys.exit(0)
msg = str(d.get("message") or "").replace("\n", " ")[:160]
dup = d.get("duplicate") is True or "uplicate" in msg
if d.get("status") != "ok" and not dup:
    print("error:%s:%s" % (d.get("reason") or "api_error", msg)); sys.exit(0)
if dup or ("created" in d and str(d.get("created")).lower() != "true"):
    print("duplicate:" + str(d.get("existing_venue_id") or os.environ["VID"])); sys.exit(0)
if str(d.get("created")).lower() == "true" or d.get("verified") is True or \
   str(d.get("persisted_email") or "").lower() == os.environ["EMAIL"]:
    print("created:" + str(d.get("name_rejected") or ""))
else:
    print("unconfirmed")
')
    if [ "$verdict" = "unconfirmed" ]; then
        # Old backend could not confirm its own write (another row landed after it): read back.
        local rb="" i
        for i in 1 2; do
            rb=$(api_get "action=venue_detail&venue_id=$(urlenc "$venue_id")" 45 | EMAIL="$email" pyrun readback python3 -c 'import json,os,sys; d=json.load(sys.stdin); t=os.environ["EMAIL"]; print("yes" if any((c.get("email") or "").lower()==t for c in d.get("contacts",[])) else "no")')
            [ "$rb" = "yes" ] && break
            sleep 3
        done
        if [ "$rb" = "yes" ]; then verdict="created:"; else verdict="error:readback_failed:add_contact answered ok but the row was not found"; fi
    fi
    echo "${verdict:-error:empty_response:}"
}

# Cities outside the target area that show up in chain mailboxes (contact_chicago@,
# 801chophousedenver@). Ambiguous or person-like names (Austin, Charlotte, Columbia,
# Arlington, Richmond, ...) are left out on purpose.
OTHER_CITY_TOKENS="chicago denver boston atlanta houston seattle nashville philadelphia philly pittsburgh detroit cleveland cincinnati indianapolis minneapolis stlouis kansascity neworleans sanantonio lasvegas scottsdale sandiego losangeles sanfrancisco newyork brooklyn manhattan raleigh louisville milwaukee omaha tucson albuquerque sacramento honolulu hoboken desmoines"

# Free checks for one address (P1/P2): prints email, action, reason, is_role,
# clean name, clean title, name hint — separated by \x1f.
_py_check_email() {
    pyrun check_email python3 - "$@" <<'PYEOF'
import re, sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
raw, name, title, evidence, vdom, vname, shared, own, cities = sys.argv[2:11]
email = R.normalize_email(raw)
out = lambda *f: print("\x1f".join(str(x).replace("\x1f", " ").replace("\n", " ") for x in f))
if not email:
    out(raw.strip().lower()[:120], "reject", "malformed", "0", "", "", "", ""); sys.exit(0)
if any(email == o or email.endswith(o) for o in {x.strip().lower() for x in own.split("|") if x.strip()}):
    out(email, "reject", "owner_email", "0", "", "", "", ""); sys.exit(0)
res = R.check_email(email, vdom, vname,
                    found_on_venue_site=evidence in ("venue_site", "venue_mailto"),
                    shared_domain=(True if shared == "true" else None),
                    venue_mailto=(evidence == "venue_mailto"))
action, reason = res["action"], res["reason"]
local = email.split("@", 1)[0]
compact = re.sub(r"[^a-z]", "", local)
if action != "reject":
    for c in cities.split():
        toks = re.split(r"[._\-+0-9]+", local)
        if c in toks or (len(c) >= 6 and c in compact):
            action, reason = "reject", "other_location:" + c
            break
clean = R.clean_person_name(name) if name and name != "None" else ""
if clean and evidence in ("venue_site", "venue_mailto") and action == "role" and not title.strip():
    # A role mailbox is saved only with a person attached; from page text that
    # needs a name AND a title beside it ("Liz McQuay, Events Manager").
    clean = ""
if clean and evidence in ("venue_site", "venue_mailto") and action == "verify":
    # A scraped name must match the mailbox (jsmith@ -> John Smith); otherwise it is
    # probably a neighbouring line of page text or another person's card.
    parts = [re.sub(r"[^a-z]", "", p.lower()) for p in clean.split()]
    first, last = parts[0], parts[-1]
    if not (first in compact or (len(last) >= 3 and last in compact) or compact.startswith(first[:1] + last) or compact == first[:1] + last):
        clean = ""
if clean:
    # a "name" made only of the venue's own name words is the venue, not a person
    vwords = set(re.findall(r"[a-z]+", R._fold(vname).lower()))
    if all(w in vwords for w in re.findall(r"[a-z]+", R._fold(clean).lower())):
        clean = ""
if not clean and action == "verify":
    clean = res.get("name_hint") or ""
t = re.sub(r"\s+", " ", (title or "").replace("|", " ")).strip(" ,;:-")
# Page text around the address, not a job title: "Contact Sarah Kim, Catering
# Director, at" -> "Catering Director"; "Book events" -> ''.
raw_name = R.clean_person_name(name) if name and name != "None" else ""
for nm in {x for x in (clean, raw_name, (name or "").strip()) if x}:
    t = re.sub(re.escape(nm), " ", t, flags=re.I)
t = re.sub(r"\s+", " ", t).strip(" ,;:-—–|")
t = re.sub(r"(?i)[\s,;:\-—–]+(at|email|e-mail|by)$", "", t).strip(" ,;:-—–|")
m = re.match(r"(?i)(contact|email|e-mail|call|book|reserve|visit|meet|ask|reach|text|join|click|learn|view)\b[\s,:]*(.*)$", t)
if m:
    rest = m.group(2).strip(" ,;:-—–|")
    job = re.search(r"(?i)\b(director|manager|coordinator|chef|owner|proprietor|planner|specialist|supervisor|president|founder|partner|gm|captain|sommelier|assistant|executive|officer|administrator|curator|principal|vp|concierge|innkeeper|host)\b", rest)
    t = rest if job else ""
if not clean and action in ("verify", "role") and t:
    # the name sometimes arrives inside the title text: "Owner Marc Duval — email"
    tn = R.clean_person_name(re.sub(r"[—–].*$", "", t))
    if tn:
        tp = [re.sub(r"[^a-z]", "", p.lower()) for p in tn.split()]
        if action == "role" or tp[0] in compact or (len(tp[-1]) >= 3 and tp[-1] in compact):
            clean = tn
            t = re.sub(r"\s+", " ", re.sub(re.escape(tn), " ", t, flags=re.I)).strip(" ,;:-—–|")
            t = re.sub(r"(?i)[\s,;:\-—–]+(at|email|e-mail|by)$", "", t).strip(" ,;:-—–|")
if t.lower() == "none" or "@" in t or len(t) > 90 or not re.search(r"[A-Za-z]{2}", t):
    t = ""
# chef@/owner@ at a small venue go to that one person: keep them (title from the
# mailbox) when found on the venue's own site, even with no name printed.
prole = res.get("person_role") or "" if (action == "role" and evidence in ("venue_site", "venue_mailto")) else ""
if prole and not t:
    t = prole
out(email, action, reason, "1" if res.get("is_role") else "0", clean, t, res.get("name_hint") or "", prole)
PYEOF
}

# verify_and_push EMAIL VENUE_ID NAME TITLE SOURCE [EVIDENCE]   (contract C2)
# EVIDENCE: venue_mailto (explicit mailto on the venue's own contact/about/events
# page) | venue_site (seen on the venue's own pages) | external (default).
# Policy P1/P2: junk and hard-reject lists and off-domain addresses are dropped
# before any paid check; role mailboxes are never sent to ZeroBounce and are saved
# only with a real person name; personal mailboxes are saved when ZeroBounce says
# valid, or as `unverified` when ZeroBounce could not check them (deferred: no
# credits, budget, outage). Only newly created rows are counted.
verify_and_push() {
    local email="$1" venue_id="$2" name="$3" title="$4" source="$5" evidence="${6:-external}"
    [ -z "$email" ] && return

    # The venue's own mail domain can differ from its website's: the alias the web step
    # found (@spcc1925.com for sparrowspointcc.com), or the same name under another TLD
    # (rollingroadgc.com for rollingroadgc.org). Check against it and vouch for it on save.
    local mail_dom="" edom
    edom=$(printf '%s' "${email##*@}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ -n "$VENUE_DOMAIN" ] && [ "$VENUE_SHARED_DOMAIN" != "true" ] && [ "$edom" != "$VENUE_DOMAIN" ] \
            && [ "${edom%.$VENUE_DOMAIN}" = "$edom" ]; then
        if [ -n "${VENUE_MAIL_ALIAS:-}" ] && { [ "$edom" = "$VENUE_MAIL_ALIAS" ] || [ "${edom%.$VENUE_MAIL_ALIAS}" != "$edom" ]; }; then
            mail_dom="$VENUE_MAIL_ALIAS"
        else
            local e_label="${edom%.*}" v_label="${VENUE_DOMAIN%.*}"
            e_label="${e_label##*.}"; v_label="${v_label##*.}"
            [ "${#v_label}" -ge 5 ] && [ "$e_label" = "$v_label" ] && [ "${edom##*.}" != "${VENUE_DOMAIN##*.}" ] && mail_dom="$edom"
        fi
    fi

    local checked
    checked=$(_py_check_email "$SCRIPT_DIR" "$email" "$name" "$title" "$evidence" \
        "${mail_dom:-$VENUE_DOMAIN}" "$VENUE_NAME" "$VENUE_SHARED_DOMAIN" "$OWN_EMAILS" "$OTHER_CITY_TOKENS")
    local email_lower action reason is_role clean_name clean_title name_hint person_role
    IFS=$'\x1f' read -r email_lower action reason is_role clean_name clean_title name_hint person_role <<< "$checked"
    if [ -z "$action" ]; then
        email_lower=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        log "  [ERROR] Email check crashed for $email_lower — not saved (see $ERR_LOG)"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "error:check_failed"
        vap_outcome error
        return
    fi
    record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "discovered:$evidence"

    local deferred_cid=""
    if email_known "$email_lower"; then
        log "  [SKIP] $email_lower — already in sheet"
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "already_known"
        vap_outcome known
        return
    fi
    if [ -s "$KNOWN_DEFERRED_FILE" ]; then
        deferred_cid=$(awk -F'\t' -v e="$email_lower" '$1==e {print ($2=="" ? "-" : $2); exit}' "$KNOWN_DEFERRED_FILE")
    fi

    if [ "$action" = "reject" ]; then
        log "  [REJECT] $email_lower — $reason (source: $source, evidence: $evidence)"
        case "$reason" in
            off_domain*|freemail_unlinked|shared_brand_domain*|other_location*)
                echo "FLAG:Rejected email ($reason): $email_lower (venue domain ${VENUE_DOMAIN:-none}, source: $source)" >> /tmp/pipeline_flags.txt ;;
        esac
        record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "reject:$reason"
        vap_outcome reject
        return
    fi

    local verified is_generic="false" zb_charged=""
    if [ "$action" = "role" ]; then
        # ZeroBounce always answers role_based/do_not_mail for these: never pay.
        if [ -z "$clean_name" ] && [ -n "$person_role" ]; then
            log "  [PERSON ROLE] $email_lower — one-person mailbox ($person_role) on the venue's own site; saving without a name"
        elif [ -z "$clean_name" ]; then
            log "  [CANDIDATE] $email_lower — role mailbox with no person name attached; not saved"
            record_candidate "$email_lower" "$venue_id" "$name" "$title" "$source" "role_no_name"
            vap_outcome candidate
            return
        fi
        [ -n "$deferred_cid" ] && { log "  [SKIP] $email_lower — already in sheet (deferred row)"; vap_outcome known; return; }
        verified="role"
        is_generic="true"
    else
        local zb_status="" zb_reason="" zb_cached="" zb_run_used="" zb_run_limit="" zb_json=""
        local venue_zb_file="/tmp/pipeline_zb_${ZB_RUN_ID}_$(printf '%s' "$venue_id" | tr -cd '[:alnum:]_.-')"
        local venue_zb=0
        # The file exists only after a paid check: a redirect from a missing file would
        # print a shell error into the run log, which verify_run flags as a script error.
        [ -s "$venue_zb_file" ] && venue_zb=$(wc -l < "$venue_zb_file" | tr -d ' ')
        venue_zb=${venue_zb:-0}
        ZB_VENUE_CREDITS=$venue_zb
        # Every paid lookup goes through the persistent cost guard. Cache hits cost
        # zero credits; new lookups are blocked by per-run/day caps and reserve floor.
        if [ "$venue_zb" -ge "$MAX_ZB_PER_VENUE" ] 2>/dev/null; then
            zb_status="deferred"; zb_reason="venue_cap_reached"
            log "  [ZB SAFE] Venue cap reached ($venue_zb/$MAX_ZB_PER_VENUE) — not paying for $email_lower"
        elif [ -f "$ZB_EXHAUSTED_FLAG" ]; then
            zb_status="deferred"; zb_reason="zb_paused"
        elif [ ! -x "$ZB_GUARD" ]; then
            zb_status="deferred"; zb_reason="guard_missing"
        else
            zb_json=$(pyrun zb_verify python3 "$ZB_GUARD" verify "$email_lower" --source "$source" --run-id "$ZB_RUN_ID" || true)
            if [ -z "$zb_json" ]; then
                zb_status="deferred"; zb_reason="guard_error"
            else
                local zb_parsed
                zb_parsed=$(printf '%s' "$zb_json" | pyrun zb_verify python3 -c 'import json,sys; d=json.load(sys.stdin); print("\x1f".join(str(d.get(k,"")) for k in ("status","reason","charged","cached","run_used","run_limit")))' || true)
                IFS=$'\x1f' read -r zb_status zb_reason zb_charged zb_cached zb_run_used zb_run_limit <<< "$zb_parsed"
                [ -z "$zb_status" ] && { zb_status="deferred"; zb_reason="${zb_reason:-guard_unparseable}"; }
                if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then
                    echo "$email_lower" >> "$venue_zb_file"
                    venue_zb=$((venue_zb + 1))
                    ZB_VENUE_CREDITS=$venue_zb
                fi
            fi
        fi
        log "  [ZB SAFE] $email_lower → $zb_status (${zb_reason:-unknown}; charged=${zb_charged:-False}; cache=${zb_cached:-False}; venue ${venue_zb}/${MAX_ZB_PER_VENUE}; run ${zb_run_used:-0}/${zb_run_limit:-?})"
        if [ "$zb_status" = "deferred" ] || [ "$zb_status" = "pending" ]; then
            case "$zb_reason" in
                run_budget_reached|day_budget_reached|reserve_reached|credit_check_failed)
                    echo "paused" > "$ZB_EXHAUSTED_FLAG" ;;
            esac
            # Alex (Sep 25): an address that passed every free check but could not be
            # checked by ZeroBounce is saved as `unverified`; reverify.sh re-checks it later.
            echo "$email_lower" >> "$DEFERRED_COUNT_FILE"
            record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "deferred:${zb_reason:-unknown}"
            if [ -n "$deferred_cid" ]; then
                log "  [SKIP] $email_lower — already in sheet (unverified row; ZeroBounce ${zb_reason:-deferred})"
                remember_email "$email_lower"
                vap_outcome known
                return
            fi
            log "  [DEFERRED] $email_lower — ZeroBounce ${zb_reason:-deferred}; saving as unverified"
            verified="unverified"
        elif [ "$zb_status" != "valid" ]; then
            log "  [CANDIDATE] $email_lower — ZeroBounce status is $zb_status; retained for review"
            record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "verification:$zb_status"
            vap_outcome candidate
            if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then sleep 1; fi
            return
        else
            verified="valid"
        fi
        if [ "$verified" = "valid" ] && [ -n "$deferred_cid" ]; then
            # Previously saved as deferred: upgrade that row instead of adding a duplicate.
            local up_ok
            up_ok=$(api_get "action=update_contact&contact_id=$(urlenc "${deferred_cid#-}")&venue_id=$(urlenc "$venue_id")&email=$(urlenc "$email_lower")&field=verified&value=valid" 45 | \
                pyrun update_contact python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("status")=="ok" else "no")')
            if [ "$up_ok" = "yes" ]; then
                log "  ✓ Re-verified previously deferred contact: $email_lower (valid)"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "upgraded_deferred_valid"
            else
                log "  [API ERROR] Could not upgrade deferred row for $email_lower"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "api_upgrade_failed"
            fi
            remember_email "$email_lower"
            vap_outcome known
            return
        fi
    fi

    local verdict
    verdict=$(PUSH_ALLOW_OFF_DOMAIN="${PUSH_ALLOW_OFF_DOMAIN:-${mail_dom:+true}}" \
        _push_contact "$venue_id" "$clean_name" "$clean_title" "$email_lower" "$source" "$verified" "$is_generic")
    case "$verdict" in
        created*)
            local name_note="${verdict#created}"; name_note="${name_note#:}"
            [ -n "$name_note" ] && { log "  [NAME] Server dropped the name '$clean_name' for $email_lower ($name_note)"; clean_name=""; }
            if [ "$verified" = "role" ]; then
                log "  ✓ Added role mailbox: ${clean_name:-(no name)} <$email_lower> (role)"
            elif [ "$verified" = "unverified" ]; then
                log "  ✓ Added (unverified — needs ZeroBounce check): ${clean_name:-(no name)} <$email_lower>"
            else
                log "  ✓ Added and verified: ${clean_name:-(no name)} <$email_lower>"
            fi
            record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "saved_$verified"
            echo "1" >> /tmp/pipeline_contacts_count
            remember_email "$email_lower"
            if [ -n "$clean_name" ]; then
                KNOWN_NAMES="${KNOWN_NAMES:+${KNOWN_NAMES}|||}$(printf '%s' "$clean_name" | tr '[:upper:]' '[:lower:]')"
                printf '%s\n' "$clean_name" | tr '[:upper:]' '[:lower:]' >> "$KNOWN_NAMES_FILE"
            fi
            case "$verified" in role) vap_outcome role ;; unverified) vap_outcome unverified ;; *) vap_outcome saved ;; esac
            ;;
        duplicate:*)
            local other_vid="${verdict#duplicate:}"
            if [ -n "$other_vid" ] && [ "$other_vid" != "$venue_id" ]; then
                log "  [SKIP] $email_lower — already saved on venue $other_vid; not copied here"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "duplicate_other_venue:$other_vid"
            else
                log "  [SKIP] $email_lower — already in sheet (server duplicate)"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "already_known_server"
            fi
            remember_email "$email_lower"
            vap_outcome known
            ;;
        *)
            local rest="${verdict#error:}" reason msg
            reason="${rest%%:*}"; msg="${rest#*:}"
            if printf '%s' "$msg" | grep -qi 'must have a name'; then
                # The deployed (old) backend refuses unnamed contacts; P2 forbids inventing one.
                log "  [BACKEND] $email_lower is $verified but unnamed; the deployed Apps Script refuses unnamed contacts — kept as a candidate (deploy the new backend)"
                record_candidate "$email_lower" "$venue_id" "" "$clean_title" "$source" "unsaved_backend_requires_name"
                vap_outcome candidate
            elif [ "$reason" != "api_error" ] && [ "$reason" != "no_json_response" ] && [ "$reason" != "readback_failed" ] && [ "$reason" != "encode_failed" ] && [ "$reason" != "empty_response" ]; then
                log "  [REJECT] $email_lower — refused by the server: $reason ($msg)"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "reject_server:$reason"
                vap_outcome reject
            else
                log "  [API ERROR] Contact was not saved: ${clean_name:-(no name)} <$email_lower> ($reason: $msg)"
                record_candidate "$email_lower" "$venue_id" "$clean_name" "$clean_title" "$source" "api_save_failed:$reason"
                vap_outcome error
            fi
            ;;
    esac
    if [ "$zb_charged" = "True" ] || [ "$zb_charged" = "true" ]; then sleep 1; fi
}

# Writes the page-scrape JS used for every Chrome render (homepage, contact page,
# subpages, probes). U4's startup probe calls this and runs the file on a real
# page. Each extractor is isolated in try/catch and the result carries errors[],
# so one odd element yields partial data instead of an empty scrape.
write_scrape_js() {
    local out="${1:-${SCRAPE_JS:-/tmp/pipeline_website_scrape.js}}"
    cat > "$out" << 'JSEOF'
(function(){
// Every section is isolated: one bad element must never kill the whole scrape
// (a single throw here turned Chrome extraction off for three months).
var errors = [];
function safe(label, fn){
    try { return fn(); } catch(e){ errors.push(label + ': ' + ((e && e.message) || String(e))); }
}
function attr(el, name){
    try { return (el && el.getAttribute && el.getAttribute(name)) || ''; } catch(e){ return ''; }
}
function textOf(el, max){
    try { var t = (el && (el.innerText || el.textContent)) || ''; return max ? t.substring(0, max) : t; } catch(e){ return ''; }
}

var EMAIL_RE = /[a-zA-Z0-9._%+\-']+@[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.[a-zA-Z]{2,24}/g;
var HAS_EMAIL = /[a-zA-Z0-9._%+\-']+@[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.[a-zA-Z]{2,24}/;
var JUNK_DOMAINS = ['wix.com','wixpress.com','wordpress.com','wordpress.org','sentry.io','sentry-next','cloudflare.com','example.com','example.org',
    'squarespace.com','shopify.com','mailchimp.com','googleapis.com','google.com','gstatic.com','facebook.com','instagram.com','twitter.com',
    'hubspot.com','sendgrid.net','zendesk.com','fontawesome.io','domain.com','email.com','mysite.com','mystore.com','website.com','yoursite.com','yourdomain.com','godaddy.com','weebly.com'];
var BAD_TLD = /\.(png|jpe?g|gif|svg|webp|bmp|ico|pdf|docx?|xlsx?|csv|zip|mp3|mp4|mov|avi|css|js|json|xml|txt|html?|php|aspx?)$/i;
var contacts = {};
var order = [];

function cleanEmail(raw){
    var e = String(raw || '');
    if(/%[0-9a-fA-F]{2}/.test(e)){ try { e = decodeURIComponent(e); } catch(x){ e = e.replace(/%20/g, ''); } }
    e = e.replace(/^\s*mailto:/i, '').split('?')[0].replace(/\s+/g, '').toLowerCase();
    // Leftovers of JSON escapes whose backslash was eaten ("u003einfo@", "u00a0events@").
    e = e.replace(/^(?:u00[0-9a-f]{2})+(?=[a-z0-9])/, '');
    e = e.replace(/^[.,;:()\[\]<>"'`]+|[.,;:()\[\]<>"'`]+$/g, '');
    // CSS/markup glued onto the domain: "info@venue.com.navbar-fixed-bottom.nav" -> "info@venue.com"
    e = e.replace(/(@[a-z0-9\-.]*?\.(?:com|org|net|edu|gov|biz|info|us))\.(?![a-z]{2}$)[a-z0-9\-.]+$/, '$1');
    if(!/^[a-z0-9][a-z0-9._%+'\-]*@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,24}$/.test(e)) return '';
    if(BAD_TLD.test(e) || e.length > 80) return '';
    var dom = e.split('@')[1];
    for(var j=0;j<JUNK_DOMAINS.length;j++){
        var jd = JUNK_DOMAINS[j];
        if(dom === jd || dom.slice(-(jd.length + 1)) === '.' + jd || (jd.indexOf('.') < 0 && dom.indexOf(jd) > -1)) return '';
    }
    return e;
}

function zoneOf(el){
    try {
        if(!el || !el.closest) return 'body';
        if(el.closest('footer, [role=contentinfo], .footer, .site-footer, #footer, #colophon')) return 'footer';
        if(el.closest('header, [role=banner], .header, .site-header, #header, #masthead')) return 'header';
        if(el.closest('nav, [role=navigation]')) return 'nav';
    } catch(e){}
    return 'body';
}

// ---- name/title context (staff directories, "Name, Title" lines, tables) ----
var TITLE_RE = /\b(manager|director|coordinator|owner|co-?owner|founder|co-?founder|president|ceo|coo|cfo|chef|sommelier|events?|catering|sales|marketing|general manager|gm|partner|proprietor|host|hostess|planner|curator|executive|vp|vice president|head|lead|supervisor|administrator|assistant|associate|specialist|concierge|membership|operations|winemaker|brewer|captain|commodore|chair|chairman|secretary|treasurer|principal|booking|bookings|talent|entertainment|music|programming|hospitality|banquets?|beverage|f&b|food|dining|clubhouse|superintendent|registrar|development|communications|relations|innkeeper|steward|maitre|ma\u00eetre|publicist|producer|officer|board|trustee|reservations|wedding|weddings|private)\b/i;
// Role words that make a line a real job title (not just an events/dining heading).
var TITLE_STRONG = /\b(manager|director|coordinator|owner|co-?owner|founder|co-?founder|president|ceo|coo|cfo|chef|sommelier|general manager|gm|partner|proprietor|planner|curator|executive|vp|vice president|head|lead|supervisor|administrator|assistant|specialist|concierge|winemaker|captain|commodore|chair|chairman|secretary|treasurer|principal|innkeeper|steward|officer|trustee|publicist|producer|host|hostess)\b/i;
var NAME_STOP = /\b(washington|maryland|virginia|georgetown|bethesda|annapolis|baltimore|potomac|chesapeake|delaware|pennsylvania|america|american|national|capitol|capital|district|county|city|downtown|uptown|upper|lower|side|village|main|content|skip|navigation|toggle|close|search|section|page|sidebar|widget|button|link|image|logo|slide|slider|carousel|modal|popup|form|submit|send|reply|comments?|posts?|author|admin|user|professional|pro|coach|school|high|lessons|instructor|group|company|associates|accountancy|consulting|productions|studio|studios|design|photography|hours|visit|contact|email|e-mail|phone|tel|fax|call|text|address|directions|menu|reserv|book|order|gift|shop|subscribe|newsletter|follow|privacy|policy|terms|rights|reserved|copyright|llc|inc|click|here|more|learn|view|read|open|closed|daily|monday|tuesday|wednesday|thursday|friday|saturday|sunday|am|pm|location|map|home|about|team|staff|us|our|the|welcome|events?|inquir|enquir|info|information|office|department|general|sales|catering|private|dining|club|hotel|restaurant|winery|vineyards?|bar|grill|cafe|kitchen|room|tasting|wine|press|media|careers|jobs|get|touch|social|refund|package|packages|let's|lets|connect|join|stay|sign|learn|discover|explore|now|today|news|blog|awards|gallery|photos|video|apply|donate|support|sponsor|rentals|amenities|specials|happy|hour|brunch|lunch|dinner|menus?|drinks|cocktails|beer|spirits|wines|tastings?|tours?|farm|market|store|cart|checkout|log|register|policies|accessibility|sitemap|powered|website|design|questions|faq|subscribe|welcome|thank|thanks|hello|hi|dear|guests?|members?|golf|tennis|pool|swim|fitness|spa|weddings?|celebrations?|parties|party|venue|venues|spaces|reviews?|story|history|mission|vision|values|culture|community|partners|friends|family|kids|children|pets|dogs|parking|shuttle|rooms?|suites?|lodging|inn|resort|marina|yacht|country|room|street|avenue|road|suite|floor|building|center|centre)\b/i;

function looksLikeName(s){
    s = (s || '').replace(/\s+/g, ' ').replace(/^[\s,;:|\-\u2013\u2014]+|[\s,;:|\-\u2013\u2014]+$/g, '');
    if(s.length < 4 || s.length > 45) return '';
    if(/[@\d\/\\<>{}()\[\]=+_#$%*!?]/.test(s)) return '';
    var toks = s.split(' ');
    if(toks.length < 2 || toks.length > 5) return '';
    var caps = 0;
    for(var i=0;i<toks.length;i++){
        var t = toks[i];
        if(!/^[A-Za-z\u00c0-\u00ff'\u2019.\-]+$/.test(t) || /^([A-Za-z]\.){2,}$/.test(t)) return '';
        if(/^[A-Z\u00c0-\u00de]/.test(t)) caps++;
        else if(!/^(de|da|di|del|della|van|von|der|den|la|le|du|dos|das|bin|al|y)$/.test(t)) return '';
    }
    if(caps < 2) return '';
    if(NAME_STOP.test(s) || TITLE_RE.test(s)) return '';
    return s;
}
function looksLikeTitle(s){
    s = (s || '').replace(/\s+/g, ' ').replace(/^[\s,;:|\-\u2013\u2014]+|[\s,;:|\-\u2013\u2014]+$/g, '');
    if(s.length < 2 || s.length > 80 || s.indexOf('@') > -1) return '';
    if(/\d{3}/.test(s) || s.split(' ').length > 7 || /[.!?]\s|[.!?]$/.test(s.replace(/\b(sr|jr|asst|mgr|dir|exec|st)\./ig, ''))) return '';
    return TITLE_RE.test(s) ? s : '';
}
// "Liz McQuay, Events Manager" / "Events Manager: Liz McQuay" / "Liz McQuay - Owner"
function splitNameTitle(line){
    var parts = line.split(/\s*(?:,|:|\||\s[-\u2013\u2014]\s|\t)\s*/);
    if(parts.length < 2) return null;
    // A name taken from a split line needs a title beside it; otherwise
    // "123 Main St, Bel Air, MD" would yield the person "Bel Air".
    for(var i=0;i<parts.length;i++){
        var n = looksLikeName(parts[i]);
        if(!n) continue;
        var after = parts.slice(i + 1).concat(parts.slice(0, i).reverse());
        for(var j=0;j<after.length;j++){
            var t = looksLikeTitle(after[j]);
            if(t) return {name:n, title:t};
        }
    }
    return null;
}
function linesOf(el){
    return textOf(el, 1500).split(/\n|\t/).map(function(l){ return l.replace(/\s+/g, ' ').trim(); })
        .filter(function(l){ return l.length > 0; });
}
// Parse name/title from the lines nearest the email: same line first, then up to
// four lines before it (and one after), stopping at another person's email.
function deob(t){
    return t.replace(/\s*[\[\(\{]\s*at\s*[\]\)\}]\s*/gi, '@').replace(/\s*[\[\(\{]\s*dot\s*[\]\)\}]\s*/gi, '.');
}
function parseLines(lines, email, inCard){
    var idx = -1;
    for(var i=0;i<lines.length;i++){ if(deob(lines[i]).toLowerCase().indexOf(email) > -1){ idx = i; break; } }
    var name = '', title = '';
    function take(line){
        if(!line) return false;
        var nt = splitNameTitle(line);
        if(nt && !name){ name = nt.name; if(!title && nt.title) title = nt.title; return true; }
        if(!name && !/\d/.test(line)){ var n = looksLikeName(line); if(n){ name = n; return true; } }
        if(!title){ var t = looksLikeTitle(line); if(t){ title = t; return true; } }
        return false;
    }
    var order2 = [];
    if(idx > -1){
        var same = deob(lines[idx]).replace(new RegExp(email.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'), ' ').replace(/\b(e-?mail|email me|contact)\b\s*:?/ig, ' ');
        order2.push(same);
        for(var k=idx-1;k>=0 && k>=idx-4;k--){ if(HAS_EMAIL.test(lines[k])) break; order2.push(lines[k]); }
        if(idx+1 < lines.length && !/@/.test(lines[idx+1])) order2.push(lines[idx+1]);
    } else if(inCard){
        order2 = lines.slice(0, 6);
    }
    for(var m=0;m<order2.length;m++){ take(order2[m]); if(name && title) break; }
    return {name:name, title:title};
}
// Smallest ancestor that holds this address and no other one (a staff "card").
function cardFor(el, email){
    var node = el, best = null;
    for(var depth=0; node && depth<7; depth++){
        node = node.parentElement;
        if(!node || node === document.body || node === document.documentElement) break;
        var tc = (node.textContent || '');
        if(tc.length > 1200) break;
        var found = (tc.toLowerCase().match(EMAIL_RE) || []);
        var others = 0;
        for(var i=0;i<found.length;i++){
            // textContent glues cells together ("Coordinatorklee@..."), so a suffix match is the same address.
            var f = cleanEmail(found[i]);
            if(f && f !== email && f.slice(-email.length) !== email) others++;
        }
        var mailtos = node.querySelectorAll ? node.querySelectorAll('a[href], [data-cfemail]') : [];
        for(var j=0;j<mailtos.length && j<60;j++){
            var h = attr(mailtos[j], 'href'), cfm = h.match(/email-protection#([0-9a-fA-F]{4,})/), cfe = attr(mailtos[j], 'data-cfemail');
            var oe = /^\s*mailto:/i.test(h) ? cleanEmail(h) : (cfm ? cleanEmail(cfDecode(cfm[1])) : (cfe ? cleanEmail(cfDecode(cfe)) : ''));
            if(oe && oe !== email) others++;
        }
        if(others > 0) break;
        best = node;
    }
    return best;
}
function contextFor(el, email){
    var res = {name:'', title:''};
    safe('context', function(){
        // Link text / aria-label often IS the person ("Email Jane Doe").
        var lt = (attr(el, 'aria-label') + ' ' + attr(el, 'title') + ' ' + textOf(el, 120)).replace(/\b(e-?mail|contact|send|message|write to)\b/ig, ' ');
        var ln = looksLikeName(lt.replace(/\s+/g, ' ').trim());
        var card = cardFor(el, email);
        if(card){
            // Headings/strong text inside the card are the most reliable name source.
            var heads = card.querySelectorAll('h1,h2,h3,h4,h5,h6,strong,b,[class*=name],[class*=Name]');
            for(var i=0;i<heads.length && !res.name;i++){
                var hn = looksLikeName(textOf(heads[i], 80));
                if(hn) res.name = hn; else { var ht = splitNameTitle(textOf(heads[i], 120)); if(ht){ res.name = ht.name; res.title = ht.title; } }
            }
            var tnodes = card.querySelectorAll('[class*=title],[class*=Title],[class*=position],[class*=role],[class*=job],em,i');
            for(var t=0;t<tnodes.length && !TITLE_STRONG.test(res.title);t++){
                var tt = looksLikeTitle(textOf(tnodes[t], 100));
                if(tt && (!res.title || TITLE_STRONG.test(tt))) res.title = tt;
            }
            var p = parseLines(linesOf(card), email, true);
            if(!res.name) res.name = p.name;
            // A heading such as "Community Events" loses to a real role line ("Club President").
            if(!res.title || (p.title && TITLE_STRONG.test(p.title) && !TITLE_STRONG.test(res.title))) res.title = p.title || res.title;
        } else {
            // Several people share one block ("Name<br>Title<br>email<br><br>Name..."):
            // read the lines right around this address only.
            var parent = el.nodeType === 1 && !/^(A|SPAN|STRONG|B|EM|I|U|FONT|SMALL)$/.test(el.tagName) ? el : el.parentElement;
            if(parent){ var q = parseLines(linesOf(parent), email, false); res.name = q.name; res.title = q.title; }
        }
        if(!res.name && ln) res.name = ln;
    });
    return res;
}

function addContact(raw, info){
    var e = cleanEmail(raw);
    if(!e) return '';
    var c = contacts[e];
    if(!c){ c = contacts[e] = {email:e, name:'', title:'', mailto:false, zone:'', how:[]}; order.push(e); }
    info = info || {};
    if(info.mailto) c.mailto = true;
    if(info.name && !c.name){ c.name = info.name; if(info.title) c.title = info.title; }
    else if(info.title && !c.title) c.title = info.title;
    if(info.zone && (!c.zone || c.zone === 'body')) c.zone = info.zone;
    if(info.how && c.how.indexOf(info.how) < 0) c.how.push(info.how);
    return e;
}
function cfDecode(enc){
    try {
        var key = parseInt(enc.substr(0, 2), 16), out = '';
        for(var j=2;j<enc.length;j+=2) out += String.fromCharCode(parseInt(enc.substr(j, 2), 16) ^ key);
        return out;
    } catch(e){ return ''; }
}

// Documents to scan: the page, same-origin iframes and open shadow roots.
var roots = [document];
var iframeSrcs = [];
safe('iframes', function(){
    var frames = document.querySelectorAll('iframe');
    for(var i=0;i<frames.length && i<30;i++){
        var src = attr(frames[i], 'src') || attr(frames[i], 'data-src');
        var doc = null;
        try { doc = frames[i].contentDocument; } catch(e){ doc = null; }
        if(doc && doc.body) roots.push(doc);
        if(src && !/^(about:|javascript:|data:)/i.test(src)){
            try { iframeSrcs.push(new URL(src, location.href).href); } catch(e){ iframeSrcs.push(src); }
        }
    }
});
safe('shadow', function(){
    var all = document.querySelectorAll('*');
    for(var i=0;i<all.length && i<20000;i++){ if(all[i].shadowRoot) roots.push(all[i].shadowRoot); }
});

// 1. mailto links (any case, percent-encoded, several addresses in one link)
safe('mailto', function(){
    for(var r=0;r<roots.length;r++){
        var links = roots[r].querySelectorAll('a[href], area[href]');
        var n = 0;
        for(var i=0;i<links.length && n<300;i++){
            var href = attr(links[i], 'href');
            if(!/^\s*mailto:/i.test(href)) continue;
            n++;
            var body = href.replace(/^\s*mailto:/i, '').split('?')[0];
            try { body = decodeURIComponent(body); } catch(e){}
            var addrs = body.split(/[,;]/);
            for(var k=0;k<addrs.length;k++){
                var e = cleanEmail(addrs[k]);
                if(!e) continue;
                var ctx = contacts[e] && contacts[e].name ? {name:'', title:''} : contextFor(links[i], e);
                var z = zoneOf(links[i]);
                if(z !== 'body' && !ctx.title) ctx.name = '';
                addContact(e, {mailto:true, name:ctx.name, title:ctx.title, zone:z, how:'mailto'});
            }
        }
    }
});

// 2. Cloudflare email protection (data-cfemail spans and /cdn-cgi/l/email-protection#hex links)
safe('cloudflare', function(){
    for(var r=0;r<roots.length;r++){
        var cf = roots[r].querySelectorAll('[data-cfemail], a[href*="email-protection"]');
        for(var i=0;i<cf.length && i<200;i++){
            var enc = attr(cf[i], 'data-cfemail');
            if(!enc){ var m = attr(cf[i], 'href').match(/email-protection#([0-9a-fA-F]{4,})/); enc = m ? m[1] : ''; }
            if(!enc) continue;
            var e = cleanEmail(cfDecode(enc));
            if(!e) continue;
            var ctx = contextFor(cf[i], e);
            var z = zoneOf(cf[i]);
            if(z !== 'body' && !ctx.title) ctx.name = '';
            addContact(e, {mailto: cf[i].tagName === 'A', name:ctx.name, title:ctx.title, zone:z, how:'cloudflare'});
        }
    }
});

// 3. Addresses in visible text, with name/title from the surrounding card
safe('text', function(){
    for(var r=0;r<roots.length;r++){
        var rootNode = roots[r].body || roots[r];
        var walker = document.createTreeWalker(rootNode, NodeFilter.SHOW_TEXT, null);
        var node, seenNodes = 0;
        while((node = walker.nextNode()) && seenNodes < 400){
            var v = node.nodeValue;
            if(!v || v.indexOf('@') < 0) continue;
            var pe = node.parentElement;
            if(pe && /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(pe.tagName)) continue;
            var found = v.match(EMAIL_RE) || [];
            if(!found.length) continue;
            seenNodes++;
            for(var i=0;i<found.length;i++){
                var e = cleanEmail(found[i]);
                if(!e) continue;
                var ctx = contacts[e] && contacts[e].name ? {name:'', title:''} : contextFor(pe || rootNode, e);
                var z = zoneOf(pe);
                if(z !== 'body' && !ctx.title) ctx.name = '';
                addContact(e, {name:ctx.name, title:ctx.title, zone:z, how:'text'});
            }
        }
    }
});

// 4. Obfuscated addresses: "name [at] venue [dot] com", "name (at) venue.com", "name at venue dot com"
safe('obfuscated', function(){
    var STOP = {us:1, me:1, you:1, him:1, her:1, them:1, it:1, we:1, join:1, find:1, visit:1, meet:1, see:1, here:1, there:1, home:1,
        online:1, open:1, dine:1, eat:1, stay:1, book:1, reserve:1, call:1, text:1, email:1, or:1, and:1, the:1, events:1, event:1};
    var TLDS = {com:1, org:1, net:1, edu:1, gov:1, us:1, biz:1, info:1, co:1, io:1, club:1, wine:1, restaurant:1, events:1, email:1, me:1};
    for(var r=0;r<roots.length;r++){
        var root = roots[r].body || roots[r];
        var t = textOf(root) || '';
        if(!/\bat\b|\[at\]|\(at\)|\{at\}/i.test(t)) continue;
        t = t.replace(/\s*[\[\(\{]\s*at\s*[\]\)\}]\s*/gi, '@').replace(/\s*[\[\(\{]\s*dot\s*[\]\)\}]\s*/gi, '.');
        t = t.replace(/([A-Za-z0-9][A-Za-z0-9._%+\-]{1,63})\s+(?:at|AT)\s+([A-Za-z0-9][A-Za-z0-9\-]{1,62})\s+(?:dot|DOT)\s+([A-Za-z]{2,10})\b/g,
            function(all, local, dom, tld){
                if(STOP[local.toLowerCase()] || !TLDS[tld.toLowerCase()]) return all;
                return local + '@' + dom + '.' + tld;
            });
        var found = t.match(EMAIL_RE) || [];
        for(var i=0;i<found.length && i<100;i++){
            var e = cleanEmail(found[i]);
            if(!e || contacts[e]) continue;
            // Find the element that carries the obfuscated text, for name/title context.
            var local = e.split('@')[0], holder = null;
            var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), tn;
            while((tn = w.nextNode())){
                if(tn.nodeValue && tn.nodeValue.toLowerCase().indexOf(local) > -1 && tn.parentElement &&
                   deob(tn.parentElement.textContent || '').toLowerCase().indexOf(local + '@') > -1){ holder = tn.parentElement; break; }
            }
            var ctx = holder ? contextFor(holder, e) : {name:'', title:''};
            addContact(e, {name:ctx.name, title:ctx.title, zone:holder ? zoneOf(holder) : '', how:'obfuscated'});
        }
    }
});

// 5. Addresses inside any href (tracking redirects, forms, "mailto" wrapped by plugins)
safe('hrefs', function(){
    for(var r=0;r<roots.length;r++){
        var links = roots[r].querySelectorAll('a[href]');
        for(var i=0;i<links.length && i<3000;i++){
            var h = attr(links[i], 'href');
            if(h.indexOf('@') < 0 && h.indexOf('%40') < 0) continue;
            try { h = decodeURIComponent(h); } catch(e){}
            var m = h.match(EMAIL_RE) || [];
            for(var k=0;k<m.length;k++){ var e = cleanEmail(m[k]); if(e && !contacts[e]) addContact(e, {zone:zoneOf(links[i]), how:'href'}); }
        }
    }
});

// 6. schema.org structured data (recurse through @graph, contactPoint, employees)
safe('schema', function(){
    function walk(node, person){
        if(node === null || node === undefined) return;
        if(typeof node === 'string'){
            var m = node.match(EMAIL_RE) || [];
            for(var j=0;j<m.length;j++) addContact(m[j], {name: person ? person.name : '', title: person ? person.title : '', how:'schema'});
            return;
        }
        if(Array.isArray(node)){ for(var j2=0;j2<node.length;j2++) walk(node[j2], person); return; }
        if(typeof node === 'object'){
            var p = person;
            var typ = String(node['@type'] || '');
            if(/Person/i.test(typ) && typeof node.name === 'string'){
                p = {name: looksLikeName(node.name), title: typeof node.jobTitle === 'string' ? node.jobTitle.substring(0, 80) : ''};
            }
            for(var k in node){ if(Object.prototype.hasOwnProperty.call(node, k)) walk(node[k], p); }
        }
    }
    var schemas = document.querySelectorAll('script[type="application/ld+json"]');
    for(var i=0;i<schemas.length;i++){
        try { walk(JSON.parse(schemas[i].textContent), null); } catch(e){}
    }
});

// 7. Hidden DOM, hydration data and attributes: undo JS/HTML escapes before matching
safe('rawdom', function(){
    var raw = document.documentElement ? document.documentElement.outerHTML : '';
    if(raw.length > 3000000) raw = raw.substring(0, 3000000);
    raw = raw.replace(/\\u0040|\\x40|&#0*64;|&#x0*40;|\[at\]/gi, '@').replace(/\\u002[eE]|&#0*46;|&#x0*2e;/gi, '.')
             .replace(/\\u00[0-9a-fA-F]{2}/g, ' ').replace(/\\\//g, '/');
    var m = raw.match(EMAIL_RE) || [];
    for(var i=0;i<m.length && i<500;i++){ var e = cleanEmail(m[i]); if(e && !contacts[e]) addContact(e, {how:'raw'}); }
});

var contactList = order.map(function(k){ return contacts[k]; });

// ---- Social links ----
var FB_SKIP = {'tr':1,'pixel':1,'plugins':1,'sharer':1,'sharer.php':1,'share':1,'share.php':1,'login':1,'login.php':1,'dialog':1,'policy.php':1,'policy':1,
    'policies':1,'terms':1,'terms.php':1,'about':1,'legal':1,'cookies':1,'r.php':1,'l.php':1,'recover':1,'help':1,'privacy':1,'settings':1,'ads':1,
    'business':1,'groups':1,'events':1,'people':1,'media':1,'watch':1,'photo':1,'photo.php':1,'photos':1,'story.php':1,'hashtag':1,'home.php':1,
    'marketplace':1,'gaming':1,'fundraisers':1,'notes':1,'places':1,'search':1,'wixstudio':1,'wix':1,'squarespace':1,'wordpresscom':1,'shopify':1,'godaddy':1};
var IG_SKIP = {'p':1,'reel':1,'reels':1,'explore':1,'stories':1,'accounts':1,'developer':1,'about':1,'legal':1,'privacy':1,'terms':1,'share':1,
    'embed':1,'direct':1,'tv':1,'squarespace':1,'wix':1,'wordpress':1,'shopify':1,'godaddy':1,'weebly':1,'webflow':1,'carrd':1,'linktree':1,'linktr':1};
function normFb(href){
    var u;
    try { u = new URL(href, location.href); } catch(e){ return ''; }
    if(!/(^|\.)facebook\.com$/i.test(u.hostname) && !/(^|\.)fb\.com$/i.test(u.hostname)) return '';
    var parts = u.pathname.split('/').filter(function(x){ return x; });
    if(!parts.length) return '';
    var first = parts[0].toLowerCase();
    if(first === 'profile.php'){ var id = u.searchParams.get('id'); return id && /^\d+$/.test(id) ? 'https://www.facebook.com/profile.php?id=' + id : ''; }
    if(first === 'pages'){ return (parts.length >= 3 && /^\d+$/.test(parts[parts.length-1])) ? 'https://www.facebook.com/' + parts.slice(0, 3).join('/') : ''; }
    if(first === 'pg' && parts.length >= 2) first = parts[1].toLowerCase(), parts = parts.slice(1);
    if(FB_SKIP[first] || /^\d+$/.test(first) || first.length < 3 || /\.php$/.test(first)) return '';
    return 'https://www.facebook.com/' + parts[0];
}
function normIg(href){
    var u;
    try { u = new URL(href, location.href); } catch(e){ return ''; }
    if(!/(^|\.)instagram\.com$/i.test(u.hostname)) return '';
    var parts = u.pathname.split('/').filter(function(x){ return x; });
    if(!parts.length) return '';
    var h = parts[0];
    if(IG_SKIP[h.toLowerCase()] || /^\d+$/.test(h) || h.length < 2 || !/^[A-Za-z0-9._]+$/.test(h)) return '';
    return 'https://www.instagram.com/' + h;
}
var socials = [];
var socialSeen = {};
function addSocial(platform, url, zone){
    if(!url) return;
    var key = platform + '|' + url.toLowerCase();
    if(socialSeen[key]){ var s = socials[socialSeen[key] - 1]; if(zone !== 'raw' && (s.zone === 'body' || s.zone === 'raw')) s.zone = zone; return; }
    socials.push({platform:platform, url:url, zone:zone});
    socialSeen[key] = socials.length;
}
safe('socials', function(){
    for(var r=0;r<roots.length;r++){
        var links = roots[r].querySelectorAll('a[href*="facebook.com"], a[href*="fb.com"], a[href*="instagram.com"]');
        for(var i=0;i<links.length && i<400;i++){
            var h = attr(links[i], 'href');
            var z = zoneOf(links[i]);
            if(/instagram\.com/i.test(h)) addSocial('instagram', normIg(h), z);
            else addSocial('facebook', normFb(h), z);
        }
    }
});
safe('socials_raw', function(){
    var raw = (document.documentElement ? document.documentElement.outerHTML : '').replace(/\\\//g, '/').replace(/\\u002[fF]/g, '/');
    if(raw.length > 3000000) raw = raw.substring(0, 3000000);
    var fbRaw = raw.match(/https?:\/\/(?:www\.|m\.|web\.)?facebook\.com\/[A-Za-z0-9._\-\/?=&;]+/g) || [];
    for(var i=0;i<fbRaw.length && i<200;i++) addSocial('facebook', normFb(fbRaw[i].replace(/&amp;/g, '&')), 'raw');
    var igRaw = raw.match(/https?:\/\/(?:www\.)?instagram\.com\/[A-Za-z0-9._\-]+/g) || [];
    for(var j=0;j<igRaw.length && j<200;j++) addSocial('instagram', normIg(igRaw[j]), 'raw');
});
function pickSocial(platform){
    var rank = {header:0, footer:0, nav:1, body:2, raw:3};
    var best = '', bestRank = 9;
    for(var i=0;i<socials.length;i++){
        var s = socials[i];
        if(s.platform !== platform) continue;
        var rk = rank[s.zone] === undefined ? 3 : rank[s.zone];
        if(rk < bestRank){ best = s.url; bestRank = rk; }
    }
    return best;
}
var fb = pickSocial('facebook');
var ig = pickSocial('instagram');

// ---- Internal links (subpages), PDFs, forms ----
var base = location.origin;
var subpages = [];
var navpages = [];
var seen = {};
var pdfs = [];
var pdfSeen = {};
var baseDomain = location.hostname.replace(/^www\./, '').split('.').slice(-2).join('.');
function normalizeInternal(h){
    try {
        var u = new URL(h, location.href);
        if(!/^https?:$/.test(u.protocol)) return '';
        // Same site = same host, or a subdomain of the venue's domain (catering.venue.com).
        if(u.origin !== base && !(u.hostname === baseDomain || u.hostname.slice(-(baseDomain.length + 1)) === '.' + baseDomain)) return '';
        ['utm_source','utm_medium','utm_campaign','utm_term','utm_content','fbclid','gclid','msclkid'].forEach(function(k){ u.searchParams.delete(k); });
        var out = u.href;
        if(!u.hash && u.pathname !== '/') out = out.replace(/\/$/, '');
        return out;
    } catch(e){ return ''; }
}
safe('seen_self', function(){ seen[normalizeInternal(location.href)] = true; });
var PDF_RE = /\.pdf(\?|#|$)/i;
safe('pdfs', function(){
    var links = document.querySelectorAll('a[href]');
    for(var i=0;i<links.length && pdfs.length<25;i++){
        var h = attr(links[i], 'href');
        if(!PDF_RE.test(h)) continue;
        var full;
        try { full = new URL(h, location.href).href; } catch(e){ continue; }
        if(!/^https?:/i.test(full) || pdfSeen[full]) continue;
        pdfSeen[full] = true;
        pdfs.push({url: full, text: textOf(links[i], 80).replace(/\s+/g, ' ').trim()});
    }
});
safe('nav_links', function(){
    var navLinks = document.querySelectorAll('nav a[href], header a[href], footer a[href], [role="navigation"] a[href], .menu a[href], .nav a[href], #menu a[href], #nav a[href]');
    for(var i=0;i<navLinks.length;i++){
        var h = attr(navLinks[i], 'href');
        if(/^\s*(mailto:|tel:|javascript:|#$)/i.test(h) || h === '#' || PDF_RE.test(h)) continue;
        var full = normalizeInternal(h);
        if(!full || full.indexOf('/cdn-cgi/') > -1) continue;
        if(navpages.indexOf(full) < 0) navpages.push(full);
        if(seen[full]) continue;
        seen[full] = true;
        subpages.push(full);
    }
});
var KEYWORDS = ['event','private','wedding','cater','contact','about','entertain','music','banquet','dining','party','book','ticket','team','staff',
    'people','leadership','management','directory','who-we-are','our-story','meet','press','news','media','rental','meeting','corporate','wine-club',
    'wine_club','live-music','reserv','hire','inquir','enquir','group','sales','celebrat','venue','spaces','host','faq','visit','location','membership'];
safe('keyword_links', function(){
    var allAnchors = document.querySelectorAll('a[href]');
    for(var i=0;i<allAnchors.length;i++){
        var h = attr(allAnchors[i], 'href');
        if(/^\s*(mailto:|tel:|javascript:)/i.test(h) || PDF_RE.test(h)) continue;
        var full = normalizeInternal(h);
        if(!full || seen[full] || full.indexOf('/cdn-cgi/') > -1) continue;
        var hay = (full + ' ' + textOf(allAnchors[i], 100) + ' ' + attr(allAnchors[i], 'aria-label')).toLowerCase();
        for(var k=0;k<KEYWORDS.length;k++){
            if(hay.indexOf(KEYWORDS[k]) > -1){ seen[full] = true; subpages.push(full); break; }
        }
    }
});

// Real contact/inquiry forms: a textarea or message field, or several fields
// including email. A lone email box is a newsletter signup, not a contact form.
var FORM_HOSTS = /(^|\.)(tripleseat\.com|perfectvenue\.com|eventtemple\.com|jotform\.com|jotform\.us|typeform\.com|wufoo\.com|cognitoforms\.com|123formbuilder\.com|formstack\.com|hsforms\.com|hsforms\.net|hubspot\.com|honeybook\.com|dubsado\.com|17hats\.com|planningpod\.com|gatherhq\.com|formsite\.com|zohopublic\.com|forms\.office\.com|forms\.gle|form\.jotform\.com)$/i;
var pageHasForm = false;
var pageHasMessageForm = false;
var formProviders = [];
// Guest surveys, feedback, poll and review forms (often an embedded Google Form) are not
// inquiry channels (mainandmarket.com/guestsurvey2025 beat its real /contact-us/ form).
var SURVEY = /survey|feedback|(^|[^a-z])(polls?|reviews?)([^a-z]|$)/i;
safe('forms', function(){
    if(SURVEY.test(location.pathname)) return;
    for(var r=0;r<roots.length && !pageHasForm;r++){
        var forms = roots[r].querySelectorAll('form');
        for(var i=0;i<forms.length;i++){
            var f = forms[i];
            if(attr(f, 'role') === 'search' || f.querySelector('input[type=search]')) continue;
            // Blog comment boxes, newsletter signups, logins and carts are not contact forms.
            var fsig = (attr(f, 'id') + ' ' + attr(f, 'class') + ' ' + attr(f, 'action') + ' ' + attr(f, 'name')).toLowerCase();
            if(/comment|newsletter|subscribe|mailchimp|mc-embedded|login|signin|sign-in|register|cart|checkout|search|password|coupon/.test(fsig) || SURVEY.test(fsig)) continue;
            if(f.querySelector('textarea[name=comment], #comment')) continue;
            var texts = f.querySelectorAll('input[type=text], input:not([type]), input[type=tel], input[type=email]').length;
            var msg = f.querySelector('textarea') || f.querySelector('[name*=message i], [name*=comment i], [name*=inquiry i], [name*=details i]');
            if(msg) pageHasMessageForm = true;
            if(msg || (f.querySelector('input[type=email], [name*=email i]') && texts >= 3)){ pageHasForm = true; }
        }
    }
    // Inquiry widgets injected by script (HoneyBook, Tripleseat, PerfectVenue, HubSpot):
    // the form is the page itself.
    var scripts = document.querySelectorAll('script[src]');
    for(var s2=0;s2<scripts.length;s2++){
        var ss = attr(scripts[s2], 'src'), sh = '';
        try { sh = new URL(ss, location.href).hostname; } catch(e){}
        if(FORM_HOSTS.test(sh) && !/hubspot\.com$/i.test(sh.replace(/^js\./, '')) || /(^|\.)hsforms\.(net|com)$/i.test(sh)){
            pageHasForm = true; pageHasMessageForm = true; formProviders.push(location.href.split('#')[0]);
            break;
        }
    }
    for(var j=0;j<iframeSrcs.length;j++){
        var host = '';
        try { host = new URL(iframeSrcs[j]).hostname; } catch(e){}
        if((FORM_HOSTS.test(host) || /docs\.google\.com\/forms/i.test(iframeSrcs[j])) && !SURVEY.test(iframeSrcs[j])){ pageHasForm = true; formProviders.push(iframeSrcs[j]); }
    }
});
var contactForm = '';
safe('contact_form', function(){
    var contactKw = /contact|get-in-touch|reach-us|inquir|enquir|request-info|request-a-quote|plan-your-event|book-your-event|book-an-event|event-request/;
    var assetExt = /\.(css|js|png|jpe?g|gif|svg|ico|woff2?|ttf|eot|map|xml|pdf)$/;
    var keys = Object.keys(seen);
    for(var i=0;i<keys.length && !contactForm;i++){
        var p = keys[i].toLowerCase().split('?')[0].split('#')[0];
        if(assetExt.test(p) || p.replace(/\/$/, '') === base.toLowerCase()) continue;
        if(contactKw.test(p.replace(base.toLowerCase(), ''))) contactForm = keys[i].split('#')[0];
    }
    if(!contactForm){
        // Buttons/links by text: same-site pages, or a known event-inquiry form host.
        var els = document.querySelectorAll('a[href], button[data-href], [role=button][data-href]');
        for(var j=0;j<els.length && !contactForm;j++){
            var txt = textOf(els[j], 60).trim().toLowerCase();
            if(!/^(contact( us)?|get in touch|inquire( now)?|enquire( now)?|event inquiry|private event inquiry|request (info|information|a quote)|plan your event|book (your|an) event)$/.test(txt)) continue;
            var h = attr(els[j], 'href') || attr(els[j], 'data-href');
            if(!h || /^\s*(mailto:|tel:|javascript:)/i.test(h)) continue;
            var u;
            try { u = new URL(h, location.href); } catch(e){ continue; }
            if(!/^https?:$/.test(u.protocol)) continue;
            if(u.origin === base){ if(u.pathname !== '/' || u.search) contactForm = u.href.split('#')[0]; else if(pageHasForm) contactForm = location.href.split('#')[0]; }
            else if(FORM_HOSTS.test(u.hostname) || /docs\.google\.com\/forms/i.test(u.href)) contactForm = u.href;
        }
    }
    if(!contactForm && formProviders.length) contactForm = formProviders[0];
});

// ---- Named people with no email on the page (team/about/staff pages) ----
var people = [];
safe('people', function(){
    var seenP = {};
    for(var k in contacts){ if(contacts[k].name) seenP[contacts[k].name.toLowerCase()] = true; }
    function addP(n, t){
        if(!n || !t || !TITLE_STRONG.test(t) || seenP[n.toLowerCase()] || people.length >= 40) return;
        seenP[n.toLowerCase()] = true;
        people.push({name:n, title:t});
    }
    var lines = (document.body ? (document.body.innerText || '') : '').substring(0, 60000).split('\n')
        .map(function(l){ return l.replace(/\s+/g, ' ').trim(); }).filter(function(l){ return l.length > 0; });
    for(var i=0;i<lines.length;i++){
        var l = lines[i];
        if(l.length > 120 || /@/.test(l)) continue;
        var nt = splitNameTitle(l);
        if(nt){ addP(nt.name, nt.title); continue; }
        var n = /\d/.test(l) ? '' : looksLikeName(l);
        if(!n) continue;
        var t = (i + 1 < lines.length) ? looksLikeTitle(lines[i + 1]) : '';
        if(!t && i > 0 && !looksLikeName(lines[i - 1])) t = looksLikeTitle(lines[i - 1]);
        if(t) addP(n, t);
    }
    // Owners named in prose: "the culinary belief of proprietor Enzo Livia", "Jane Doe, owner".
    var ROLE = '(owner|co-owner|proprietor|founder|co-founder|general manager|managing partner|executive chef|chef[- ]owner|events? (?:manager|director|coordinator)|catering (?:manager|director)|private (?:events|dining) (?:manager|director|coordinator))';
    var NM = "([A-Z][a-z\u00e0-\u00ff'\u2019\\-]+(?: (?:de|di|da|van|von|del|la|le))? [A-Z][A-Za-z\u00e0-\u00ff'\u2019\\-]+)";
    var text = lines.join('\n');
    var reA = new RegExp('\\b' + ROLE + ',? ' + NM, 'gi'), reB = new RegExp(NM + ', (?:(?:the|our|and) )*' + ROLE + '\\b', 'g'), m;
    while((m = reA.exec(text)) && people.length < 40){ var nA = looksLikeName(m[2]); if(nA && /^[A-Z]/.test(m[2])) addP(nA, m[1].replace(/\b\w/g, function(c){ return c.toUpperCase(); })); }
    while((m = reB.exec(text)) && people.length < 40){ var nB = looksLikeName(m[1]); if(nB) addP(nB, m[2].replace(/\b\w/g, function(c){ return c.toUpperCase(); })); }
});

// An address with no name next to it, whose mailbox matches a named person on the
// same page (tmead@ / traci.mead@ / traci@ -> Traci Mead), gets that person's name.
safe('match_people', function(){
    for(var k in contacts){
        var c = contacts[k];
        if(c.name) continue;
        var local = c.email.split('@')[0].replace(/[^a-z]/g, '');
        var hits = [];
        for(var i=0;i<people.length;i++){
            var parts = people[i].name.toLowerCase().replace(/[^a-z ]/g, '').split(' ').filter(function(x){ return x; });
            if(parts.length < 2) continue;
            var f = parts[0], l = parts[parts.length - 1];
            if(local === f + l || local === f.charAt(0) + l || local === f + l.charAt(0) || local === l + f.charAt(0) ||
               local === l + f || (local === f && f.length >= 3)) hits.push(people[i]);
        }
        if(hits.length === 1){ c.name = hits[0].name; c.title = c.title || hits[0].title; if(c.how.indexOf('people') < 0) c.how.push('people'); }
    }
});

// Bot walls and error pages must not read as "this page has no contacts".
var pageState = 'ok';
safe('state', function(){
    var t = (document.title || '').toLowerCase();
    var b = (document.body ? (document.body.innerText || '') : '').substring(0, 2000).toLowerCase();
    if(/attention required|just a moment|access denied|forbidden|request blocked|security check|captcha|are you a robot|verify you are human|ddos/.test(t) ||
       (b.length < 1500 && /you have been blocked|request cannot be proceeded|access denied|verify you are human|checking your browser|enable javascript and cookies to continue/.test(b))) pageState = 'blocked';
    else if(/\b(404|page not found|not found|page cannot be found|no longer available)\b/.test(t) || (b.length < 400 && /\b(404|page not found)\b/.test(b))) pageState = 'not_found';
});

var out = {contacts:contactList, page_state:pageState, facebook:fb, instagram:ig, socials:socials.slice(0, 40), contact_form:contactForm, subpages:subpages, navpages:navpages.slice(0, 80),
    page_has_form:pageHasForm, page_has_message_form:pageHasMessageForm, form_providers:formProviders, people:people, pdfs:pdfs, iframes:iframeSrcs.slice(0, 15),
    url:location.href, title:(document.title || '').substring(0, 150), text_length:(document.body ? (document.body.innerText || '').length : 0), errors:errors};
try { return JSON.stringify(out); } catch(e){ return JSON.stringify({contacts:[], facebook:'', instagram:'', contact_form:'', subpages:[], errors:errors.concat(['stringify: ' + e.message])}); }
})()
JSEOF
}

# chrome_open URL — navigate the active tab. The URL goes in as argv, never into
# AppleScript source, so a quote or ampersand in a crawled link can't break out.
chrome_open() {
    local errf
    errf=$(mktemp "${TMPDIR:-/tmp}/pipeline_err.XXXXXX")
    osascript - "$1" >/dev/null 2>"$errf" <<'OSA'
on run argv
    with timeout of 30 seconds
        tell application "Google Chrome" to set URL of active tab of front window to (item 1 of argv)
    end timeout
end run
OSA
    local rc=$?
    errlog_append chrome_open "$errf"
    rm -f "$errf"
    return $rc
}

# chrome_wait_ready MAX_SECONDS SETTLE_SECONDS — poll document.readyState instead of
# a fixed long sleep, then give client-side rendering a moment.
chrome_wait_ready() {
    local max="${1:-15}" settle="${2:-2}" i=0 st
    sleep 2
    while [ "$i" -lt "$max" ]; do
        st=$(osascript -e 'with timeout of 10 seconds' \
            -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.readyState"' \
            -e 'end timeout' 2>/dev/null)
        [ "$st" = "complete" ] && break
        sleep 1
        i=$((i + 1))
    done
    sleep "$settle"
}

# chrome_scrape — run the scrape JS in the active tab; prints its JSON or nothing.
# The file is read as UTF-8 (plain `read` decodes MacRoman).
CHROME_JS_OFF=""
chrome_scrape() {
    [ -s "$SCRAPE_JS" ] || write_scrape_js
    local errf out
    errf=$(mktemp "${TMPDIR:-/tmp}/pipeline_err.XXXXXX")
    out=$(osascript - "$SCRAPE_JS" 2>"$errf" <<'OSA'
on run argv
    set js to read POSIX file (item 1 of argv) as «class utf8»
    with timeout of 60 seconds
        tell application "Google Chrome" to set r to execute active tab of front window javascript js
    end timeout
    if r is missing value then return ""
    return r
end run
OSA
)
    if grep -qiE 'turned off|Allow JavaScript|not allowed' "$errf" 2>/dev/null; then
        CHROME_JS_OFF="yes"
    fi
    errlog_append chrome_scrape "$errf"
    rm -f "$errf"
    [ "$out" = "missing value" ] && out=""
    printf '%s' "$out"
}

# web_parse_html PAGE_URL HTML_FILE — curl-fallback parser. Emits the same JSON
# shape as the Chrome scrape (contacts with name/title, socials with zone, forms,
# PDFs, subpages, page_state) so a Chrome failure loses JS rendering, not fields.
web_parse_html() {
    pyrun web_parse python3 - "$SCRIPT_DIR" "$1" "$2" <<'PYEOF'
import html as H, json, re, sys
from urllib.parse import urljoin, urlparse, unquote, parse_qs
sys.path.insert(0, sys.argv[1])
page_url, html_file = sys.argv[2], sys.argv[3]
raw = open(html_file, encoding="utf-8", errors="replace").read()
errors = []
try:
    import site_discovery as SD
except Exception as e:
    SD = None; errors.append("site_discovery import: %s" % e)
soup = None
try:
    from bs4 import BeautifulSoup
    try:
        soup = BeautifulSoup(raw, "lxml")
    except Exception:
        soup = BeautifulSoup(raw, "html.parser")  # Apple's python has no lxml
except Exception as e:
    errors.append("bs4: %s" % e)

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+'\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,24}")
TITLE_RE = re.compile(r"\b(manager|director|coordinator|owner|co-?owner|founder|co-?founder|president|ceo|coo|cfo|chef|sommelier|events?|catering|sales|marketing|general manager|gm|partner|proprietor|host|hostess|planner|curator|executive|vp|vice president|head|lead|supervisor|administrator|assistant|associate|specialist|concierge|membership|operations|winemaker|brewer|captain|commodore|chair|chairman|secretary|treasurer|principal|booking|bookings|talent|entertainment|music|programming|hospitality|banquets?|beverage|f&b|food|dining|clubhouse|superintendent|registrar|development|communications|relations|innkeeper|steward|maitre|publicist|producer|officer|board|trustee|reservations|wedding|weddings|private)\b", re.I)
TITLE_STRONG = re.compile(r"\b(manager|director|coordinator|owner|co-?owner|founder|co-?founder|president|ceo|coo|cfo|chef|sommelier|general manager|gm|partner|proprietor|planner|curator|executive|vp|vice president|head|lead|supervisor|administrator|assistant|specialist|concierge|winemaker|captain|commodore|chair|chairman|secretary|treasurer|principal|innkeeper|steward|officer|trustee|publicist|producer|host|hostess)\b", re.I)
NAME_STOP = re.compile(r"\b(washington|maryland|virginia|georgetown|bethesda|annapolis|baltimore|potomac|chesapeake|delaware|pennsylvania|america|american|national|capitol|capital|district|county|city|downtown|uptown|upper|lower|side|village|main|content|skip|navigation|toggle|close|search|section|page|sidebar|widget|button|link|image|logo|slide|slider|carousel|modal|popup|form|submit|send|reply|comments?|posts?|author|admin|user|professional|pro|coach|school|high|lessons|instructor|group|company|associates|accountancy|consulting|productions|studio|studios|design|photography|hours|visit|contact|email|e-mail|phone|tel|fax|call|text|address|directions|menu|reserv\w*|book|order|gift|shop|subscribe|newsletter|follow|privacy|policy|terms|rights|reserved|copyright|llc|inc|click|here|more|learn|view|read|open|closed|daily|monday|tuesday|wednesday|thursday|friday|saturday|sunday|am|pm|location|map|home|about|team|staff|us|our|the|welcome|events?|inquir\w*|enquir\w*|info|information|office|department|general|sales|catering|private|dining|club|hotel|restaurant|winery|vineyards?|bar|grill|cafe|kitchen|room|tasting|wine|press|media|careers|jobs|get|touch|social|refund|package|packages|let's|lets|connect|join|stay|sign|learn|discover|explore|now|today|news|blog|awards|gallery|photos|video|apply|donate|support|sponsor|rentals|amenities|specials|happy|hour|brunch|lunch|dinner|menus?|drinks|cocktails|beer|spirits|wines|tastings?|tours?|farm|market|store|cart|checkout|log|register|policies|accessibility|sitemap|powered|website|design|questions|faq|welcome|thank|thanks|hello|hi|dear|guests?|members?|golf|tennis|pool|swim|fitness|spa|weddings?|celebrations?|parties|party|venue|venues|spaces|reviews?|story|history|mission|vision|values|culture|community|partners|friends|family|kids|children|pets|dogs|parking|shuttle|rooms?|suites?|lodging|inn|resort|marina|yacht|country|street|avenue|road|suite|floor|building|center|centre)\b", re.I)
PARTICLES = {"de", "da", "di", "del", "della", "van", "von", "der", "den", "la", "le", "du", "dos", "das", "bin", "al", "y"}
JUNK_DOMAINS = ("wix.com", "wixpress.com", "wordpress.com", "wordpress.org", "sentry.io", "sentry-next", "cloudflare.com",
                "example.com", "example.org", "squarespace.com", "shopify.com", "mailchimp.com", "googleapis.com", "google.com",
                "gstatic.com", "facebook.com", "instagram.com", "twitter.com", "hubspot.com", "sendgrid.net", "zendesk.com",
                "fontawesome.io", "domain.com", "email.com", "mysite.com", "mystore.com", "website.com", "yoursite.com",
                "yourdomain.com", "godaddy.com", "weebly.com")
BAD_TLD = re.compile(r"\.(png|jpe?g|gif|svg|webp|bmp|ico|pdf|docx?|xlsx?|csv|zip|mp3|mp4|mov|avi|css|js|json|xml|txt|html?|php|aspx?)$", re.I)

def clean_email(e):
    e = str(e or "")
    if "%" in e:
        try: e = unquote(e)
        except Exception: pass
    e = re.sub(r"^\s*mailto:", "", e, flags=re.I).split("?")[0]
    e = re.sub(r"\s+", "", e).lower()
    e = re.sub(r"^(?:u00[0-9a-f]{2})+(?=[a-z0-9])", "", e)
    e = e.strip(".,;:()[]<>\"'`")
    # CSS/markup glued onto the domain: "info@venue.com.navbar-fixed-bottom.nav" -> "info@venue.com"
    e = re.sub(r"(@[a-z0-9\-.]*?\.(?:com|org|net|edu|gov|biz|info|us))\.(?![a-z]{2}$)[a-z0-9\-.]+$", r"\1", e)
    if not re.fullmatch(r"[a-z0-9][a-z0-9._%+'\-]*@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,24}", e): return ""
    if BAD_TLD.search(e) or len(e) > 80: return ""
    dom = e.split("@")[1]
    for jd in JUNK_DOMAINS:
        if dom == jd or dom.endswith("." + jd) or ("." not in jd and jd in dom): return ""
    return e

def deob(t):
    t = re.sub(r"\s*[\[\(\{]\s*at\s*[\]\)\}]\s*", "@", t, flags=re.I)
    return re.sub(r"\s*[\[\(\{]\s*dot\s*[\]\)\}]\s*", ".", t, flags=re.I)

def norm_space(s):
    return re.sub(r"\s+", " ", s or "").strip(" \t,;:|-\u2013\u2014")

def looks_like_name(s):
    s = norm_space(s)
    if len(s) < 4 or len(s) > 45 or re.search(r"[@\d/\\<>{}()\[\]=+_#$%*!?]", s): return ""
    toks = s.split(" ")
    if len(toks) < 2 or len(toks) > 5: return ""
    caps = 0
    for t in toks:
        if not re.fullmatch(r"[A-Za-z\u00c0-\u00ff'\u2019.\-]+", t) or re.fullmatch(r"(?:[A-Za-z]\.){2,}", t): return ""
        if t[:1].isupper(): caps += 1
        elif t not in PARTICLES: return ""
    if caps < 2 or NAME_STOP.search(s) or TITLE_RE.search(s): return ""
    return s

def looks_like_title(s):
    s = norm_space(s)
    if len(s) < 2 or len(s) > 80 or "@" in s or re.search(r"\d{3}", s) or len(s.split(" ")) > 7: return ""
    if re.search(r"[.!?]\s|[.!?]$", re.sub(r"\b(sr|jr|asst|mgr|dir|exec|st)\.", "", s, flags=re.I)): return ""
    return s if TITLE_RE.search(s) else ""

def split_name_title(line):
    parts = re.split(r"\s*(?:,|:|\||\s[-\u2013\u2014]\s|\t)\s*", line)
    if len(parts) < 2: return None
    for i, p in enumerate(parts):
        n = looks_like_name(p)
        if not n: continue
        for q in parts[i + 1:] + list(reversed(parts[:i])):
            t = looks_like_title(q)
            if t: return (n, t)
    return None

def parse_lines(lines, email, in_card):
    idx = next((i for i, l in enumerate(lines) if email in deob(l).lower()), -1)
    name = title = ""
    order = []
    if idx > -1:
        same = re.sub(re.escape(email), " ", deob(lines[idx]), flags=re.I)
        order.append(re.sub(r"\b(e-?mail|email me|contact)\b\s*:?", " ", same, flags=re.I))
        for k in range(idx - 1, max(idx - 5, -1), -1):
            if EMAIL_RE.search(lines[k]): break
            order.append(lines[k])
        if idx + 1 < len(lines) and "@" not in lines[idx + 1]: order.append(lines[idx + 1])
    elif in_card:
        order = lines[:6]
    for line in order:
        if not line: continue
        nt = split_name_title(line)
        if nt and not name:
            name = nt[0]; title = title or nt[1]
        elif not name and not re.search(r"\d", line) and looks_like_name(line):
            name = looks_like_name(line)
        elif not title and looks_like_title(line):
            title = looks_like_title(line)
        if name and title: break
    return name, title

def lines_of(el):
    txt = el.get_text("\n") if hasattr(el, "get_text") else str(el)
    return [norm_space(l) for l in re.split(r"[\n\t]", txt[:1500]) if norm_space(l)]

def zone_of(el):
    # Same rules as the Chrome scrape's zoneOf (tag, role, id, exact class names).
    for p in ([el] + list(el.parents)) if el is not None else []:
        n = getattr(p, "name", None)
        if not n or not hasattr(p, "get"): continue
        cls = {c.lower() for c in (p.get("class") or [])}
        pid, role = str(p.get("id") or "").lower(), str(p.get("role") or "").lower()
        if n == "footer" or role == "contentinfo" or cls & {"footer", "site-footer"} or pid in ("footer", "colophon"): return "footer"
        if n == "header" or role == "banner" or cls & {"header", "site-header"} or pid in ("header", "masthead"): return "header"
        if n == "nav" or role == "navigation": return "nav"
    return "body"

def card_for(el, email):
    best, node = None, el
    for _ in range(7):
        node = node.parent if node is not None else None
        if node is None or getattr(node, "name", None) in (None, "body", "html", "[document]"): break
        tc = node.get_text("") or ""
        if len(tc) > 1200: break
        others = 0
        for f in EMAIL_RE.findall(tc.lower()):
            f = clean_email(f)
            if f and f != email and not f.endswith(email): others += 1
        for a in node.find_all("a", href=True, limit=40):
            h = a.get("href") or ""
            m = re.search(r"email-protection#([0-9a-fA-F]{4,})", h)
            f = clean_email(h) if re.match(r"\s*mailto:", h, re.I) else (clean_email(SD.decode_cf_email(m.group(1)) or "") if (m and SD) else "")
            if f and f != email: others += 1
        for x in node.select("[data-cfemail]")[:40]:
            f = clean_email(SD.decode_cf_email(x.get("data-cfemail") or "") or "") if SD else ""
            if f and f != email: others += 1
        if others: break
        best = node
    return best

def context_for(el, email):
    name = title = ""
    try:
        lt = " ".join([str(el.get("aria-label") or ""), str(el.get("title") or ""), el.get_text(" ")[:120]]) if hasattr(el, "get") else ""
        ln = looks_like_name(re.sub(r"\b(e-?mail|contact|send|message|write to)\b", " ", lt, flags=re.I))
        card = card_for(el, email)
        if card is not None:
            for h in card.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "strong", "b"]) + card.select("[class*=name], [class*=Name]"):
                t = h.get_text(" ")[:120]
                n = looks_like_name(t)
                if n: name = n; break
                nt = split_name_title(t)
                if nt: name, title = nt; break
            for h in card.select("[class*=title], [class*=Title], [class*=position], [class*=role], [class*=job], em, i"):
                if TITLE_STRONG.search(title): break
                t = looks_like_title(h.get_text(" ")[:100])
                if t and (not title or TITLE_STRONG.search(t)): title = t
            n2, t2 = parse_lines(lines_of(card), email, True)
            name = name or n2
            # A heading such as "Community Events" loses to a real role line ("Club President").
            if not title or (t2 and TITLE_STRONG.search(t2) and not TITLE_STRONG.search(title)): title = t2 or title
        else:
            parent = el if getattr(el, "name", "") not in ("a", "span", "strong", "b", "em", "i", "u", "font", "small") else el.parent
            if parent is not None:
                name, title = parse_lines(lines_of(parent), email, False)
        name = name or ln
    except Exception as e:
        errors.append("context: %s" % e)
    return name, title

contacts, order = {}, []
def add(email, mailto=False, name="", title="", zone="", how=""):
    e = clean_email(email)
    if not e: return
    c = contacts.get(e)
    if not c:
        c = contacts[e] = {"email": e, "name": "", "title": "", "mailto": False, "zone": "", "how": []}
        order.append(e)
    if mailto: c["mailto"] = True
    if name and not c["name"]:
        c["name"] = name
        if title: c["title"] = title
    elif title and not c["title"]: c["title"] = title
    if zone and c["zone"] in ("", "body"): c["zone"] = zone
    if how and how not in c["how"]: c["how"].append(how)

def with_context(el, e, mailto, how):
    e = clean_email(e)
    if not e: return
    name, title = ("", "") if contacts.get(e, {}).get("name") else context_for(el, e)
    z = zone_of(el)
    if z != "body" and not title: name = ""
    add(e, mailto=mailto, name=name, title=title, zone=z, how=how)

if soup is not None:
    try:
        for a in soup.find_all(["a", "area"], href=True):
            h = a.get("href") or ""
            if re.match(r"\s*mailto:", h, re.I):
                body = unquote(re.sub(r"^\s*mailto:", "", h, flags=re.I).split("?")[0])
                for part in re.split(r"[,;]", body):
                    with_context(a, part, True, "mailto")
            m = re.search(r"email-protection#([0-9a-fA-F]{4,})", h)
            if m and SD is not None:
                with_context(a, SD.decode_cf_email(m.group(1)) or "", True, "cloudflare")
        for el in soup.select("[data-cfemail]"):
            if SD is not None:
                with_context(el, SD.decode_cf_email(el.get("data-cfemail") or "") or "", False, "cloudflare")
        for s in soup(["script", "style", "noscript", "template"]):
            s.extract()
        n = 0
        for t in soup.find_all(string=True):
            if n > 400: break
            v = str(t)
            if "@" not in v and not re.search(r"[\[\(\{]\s*at\s*[\]\)\}]", v, re.I): continue
            found = EMAIL_RE.findall(deob(v))
            if not found: continue
            n += 1
            for f in found:
                with_context(t.parent, f, False, "text")
    except Exception as e:
        errors.append("soup: %s" % e)
# Everything else the shared extractor sees (JS escapes, entities, split/obfuscated
# addresses, "at/dot" text) — no context, but nothing is lost.
try:
    if SD is not None:
        for c in SD.extract_emails(raw):
            e = clean_email(c.get("email"))
            if e and e not in contacts: add(e, mailto=bool(c.get("mailto")), how="raw")
    else:
        for f in EMAIL_RE.findall(re.sub(r"\\u0040|&#0*64;", "@", raw)):
            e = clean_email(f)
            if e and e not in contacts: add(e, how="raw")
except Exception as e:
    errors.append("extract_emails: %s" % e)

FB_SKIP = {"tr", "pixel", "plugins", "sharer", "sharer.php", "share", "share.php", "login", "login.php", "dialog", "policy.php", "policy",
           "policies", "terms", "terms.php", "about", "legal", "cookies", "r.php", "l.php", "recover", "help", "privacy", "settings", "ads",
           "business", "groups", "events", "people", "media", "watch", "photo", "photo.php", "photos", "story.php", "hashtag", "home.php",
           "marketplace", "gaming", "fundraisers", "notes", "places", "search", "wixstudio", "wix", "squarespace", "wordpresscom", "shopify", "godaddy"}
IG_SKIP = {"p", "reel", "reels", "explore", "stories", "accounts", "developer", "about", "legal", "privacy", "terms", "share", "embed",
           "direct", "tv", "squarespace", "wix", "wordpress", "shopify", "godaddy", "weebly", "webflow", "carrd", "linktree", "linktr"}
def norm_fb(href):
    try: u = urlparse(urljoin(page_url, H.unescape(href)))
    except Exception: return ""
    host = (u.hostname or "").lower()
    if not (host == "facebook.com" or host.endswith(".facebook.com") or host == "fb.com" or host.endswith(".fb.com")): return ""
    parts = [p for p in u.path.split("/") if p]
    if not parts: return ""
    first = parts[0].lower()
    if first == "profile.php":
        i = (parse_qs(u.query).get("id") or [""])[0]
        return "https://www.facebook.com/profile.php?id=" + i if i.isdigit() else ""
    if first == "pages":
        return "https://www.facebook.com/" + "/".join(parts[:3]) if len(parts) >= 3 and parts[-1].isdigit() else ""
    if first == "pg" and len(parts) >= 2: parts = parts[1:]; first = parts[0].lower()
    if first in FB_SKIP or first.isdigit() or len(first) < 3 or first.endswith(".php"): return ""
    return "https://www.facebook.com/" + parts[0]
def norm_ig(href):
    try: u = urlparse(urljoin(page_url, H.unescape(href)))
    except Exception: return ""
    host = (u.hostname or "").lower()
    if not (host == "instagram.com" or host.endswith(".instagram.com")): return ""
    parts = [p for p in u.path.split("/") if p]
    if not parts: return ""
    h = parts[0]
    if h.lower() in IG_SKIP or h.isdigit() or len(h) < 2 or not re.fullmatch(r"[A-Za-z0-9._]+", h): return ""
    return "https://www.instagram.com/" + h
socials, sseen = [], {}
def add_social(platform, url, zone):
    if not url: return
    k = platform + "|" + url.lower()
    if k in sseen:
        s = socials[sseen[k]]
        if zone != "raw" and s["zone"] in ("body", "raw"): s["zone"] = zone
        return
    sseen[k] = len(socials)
    socials.append({"platform": platform, "url": url, "zone": zone})
try:
    if soup is not None:
        for a in soup.find_all("a", href=True):
            h = a.get("href") or ""
            if "instagram.com" in h.lower(): add_social("instagram", norm_ig(h), zone_of(a))
            elif "facebook.com" in h.lower() or "fb.com" in h.lower(): add_social("facebook", norm_fb(h), zone_of(a))
    work = raw.replace("\\/", "/").replace("\\u002F", "/").replace("\\u002f", "/")
    for m in re.findall(r"https?://(?:www\.|m\.|web\.)?facebook\.com/[A-Za-z0-9._\-/?=&;]+", work)[:200]:
        add_social("facebook", norm_fb(m.replace("&amp;", "&")), "raw")
    for m in re.findall(r"https?://(?:www\.)?instagram\.com/[A-Za-z0-9._\-]+", work)[:200]:
        add_social("instagram", norm_ig(m), "raw")
except Exception as e:
    errors.append("socials: %s" % e)
def pick(platform):
    rank = {"header": 0, "footer": 0, "nav": 1, "body": 2, "raw": 3}
    best = sorted([s for s in socials if s["platform"] == platform], key=lambda s: rank.get(s["zone"], 3))
    return best[0]["url"] if best else ""

base = urlparse(page_url)
origin = "%s://%s" % (base.scheme, base.netloc)
KEYWORDS = ["event", "private", "wedding", "cater", "contact", "about", "entertain", "music", "banquet", "dining", "party", "book", "ticket",
            "team", "staff", "people", "leadership", "management", "directory", "who-we-are", "our-story", "meet", "press", "news", "media",
            "rental", "meeting", "corporate", "wine-club", "wine_club", "live-music", "reserv", "hire", "inquir", "enquir", "group", "sales",
            "celebrat", "venue", "spaces", "host", "faq", "visit", "location", "membership"]
subpages, navpages, seen, pdfs = [], [], {}, []
base_domain = ".".join((base.hostname or "").lower().replace("www.", "", 1).split(".")[-2:])
def norm_internal(h):
    try: u = urlparse(urljoin(page_url, H.unescape(h.strip())))
    except Exception: return ""
    hn = (u.hostname or "").lower()
    # Same site = same host, or a subdomain of the venue's domain (catering.venue.com).
    if u.scheme not in ("http", "https") or ("%s://%s" % (u.scheme, u.netloc) != origin and not (hn == base_domain or hn.endswith("." + base_domain))): return ""
    q = "&".join(p for p in u.query.split("&") if p and not re.match(r"(utm_\w+|fbclid|gclid|msclkid)=", p))
    out = "%s://%s%s" % (u.scheme, u.netloc, u.path or "/") + ("?" + q if q else "") + ("#" + u.fragment if u.fragment else "")
    if not u.fragment and (u.path or "/") != "/": out = out.rstrip("/")
    return out
FORM_HOSTS = re.compile(r"(^|\.)(tripleseat\.com|perfectvenue\.com|eventtemple\.com|jotform\.com|jotform\.us|typeform\.com|wufoo\.com|cognitoforms\.com|123formbuilder\.com|formstack\.com|hsforms\.com|hsforms\.net|hubspot\.com|honeybook\.com|dubsado\.com|17hats\.com|planningpod\.com|gatherhq\.com|formsite\.com|zohopublic\.com|forms\.office\.com|forms\.gle)$", re.I)
page_has_form, message_form, providers, iframes, contact_form = False, False, [], [], ""
# Guest surveys, feedback, poll and review forms are not inquiry channels (same rule as the Chrome scrape).
SURVEY = re.compile(r"survey|feedback|(^|[^a-z])(polls?|reviews?)([^a-z]|$)", re.I)
survey_page = bool(SURVEY.search(urlparse(page_url).path or ""))
try:
    if soup is not None:
        seen[norm_internal(page_url)] = True
        for a in soup.find_all("a", href=True):
            h = a.get("href") or ""
            if re.search(r"\.pdf(\?|#|$)", h, re.I):
                full = urljoin(page_url, H.unescape(h))
                if full.startswith("http") and full not in [p["url"] for p in pdfs] and len(pdfs) < 25:
                    pdfs.append({"url": full, "text": norm_space(a.get_text(" "))[:80]})
                continue
            if re.match(r"\s*(mailto:|tel:|javascript:)", h, re.I) or h.strip() == "#": continue
            full = norm_internal(h)
            if not full or full in seen or "/cdn-cgi/" in full: continue
            hay = (full + " " + a.get_text(" ")[:100] + " " + str(a.get("aria-label") or "")).lower()
            in_nav = zone_of(a) in ("header", "footer", "nav")
            if in_nav and full not in navpages: navpages.append(full)
            if in_nav or any(k in hay for k in KEYWORDS):
                seen[full] = True
                subpages.append(full)
        for f in soup.find_all("iframe"):
            src = f.get("src") or f.get("data-src") or ""
            if not src or re.match(r"(about:|javascript:|data:)", src, re.I): continue
            full = urljoin(page_url, src)
            iframes.append(full)
            host = (urlparse(full).hostname or "")
            if (FORM_HOSTS.search(host) or "docs.google.com/forms" in full) and not survey_page and not SURVEY.search(full):
                page_has_form = True; providers.append(full)
        for f in ([] if survey_page else soup.find_all("form")):
            if (f.get("role") or "") == "search" or f.find("input", attrs={"type": "search"}): continue
            # Blog comment boxes, newsletter signups, logins and carts are not contact forms.
            fsig = " ".join([str(f.get("id") or ""), " ".join(f.get("class") or []), str(f.get("action") or ""), str(f.get("name") or "")]).lower()
            if re.search(r"comment|newsletter|subscribe|mailchimp|mc-embedded|login|signin|sign-in|register|cart|checkout|search|password|coupon", fsig) or SURVEY.search(fsig): continue
            if f.find("textarea", attrs={"name": "comment"}) or f.find(id="comment"): continue
            texts = len([i for i in f.find_all("input") if (i.get("type") or "text").lower() in ("text", "tel", "email")])
            named = lambda pat: f.find(attrs={"name": re.compile(pat, re.I)})
            msg = f.find("textarea") or named(r"message|comment|inquiry|details")
            if msg: message_form = True
            if msg or ((f.find("input", attrs={"type": "email"}) or named("email")) and texts >= 3):
                page_has_form = True
        # Inquiry widgets injected by script (HoneyBook, Tripleseat, PerfectVenue, HubSpot forms).
        for sc in ([] if survey_page else soup.find_all("script", src=True)):
            sh = (urlparse(urljoin(page_url, sc.get("src"))).hostname or "").lower()
            if (FORM_HOSTS.search(sh) and not sh.endswith("hubspot.com")) or re.search(r"(^|\.)hsforms\.(net|com)$", sh):
                page_has_form = message_form = True; providers.append(page_url.split("#")[0]); break
        ckw = re.compile(r"contact|get-in-touch|reach-us|inquir|enquir|request-info|request-a-quote|plan-your-event|book-your-event|book-an-event|event-request")
        for k in list(seen):
            p = k.lower().split("?")[0].split("#")[0]
            if not k or p.rstrip("/") == origin.lower() or re.search(r"\.(css|js|png|jpe?g|gif|svg|ico|woff2?|ttf|eot|map|xml|pdf)$", p): continue
            if ckw.search(p[len(origin):]): contact_form = k.split("#")[0]; break
        if not contact_form:
            for a in soup.find_all("a", href=True):
                txt = norm_space(a.get_text(" ")).lower()
                if not re.fullmatch(r"contact( us)?|get in touch|inquire( now)?|enquire( now)?|event inquiry|private event inquiry|request (info|information|a quote)|plan your event|book (your|an) event", txt): continue
                u = urlparse(urljoin(page_url, a.get("href")))
                if u.scheme not in ("http", "https"): continue
                if "%s://%s" % (u.scheme, u.netloc) == origin:
                    if u.path not in ("", "/") or u.query: contact_form = u.geturl().split("#")[0]; break
                    if page_has_form: contact_form = page_url.split("#")[0]; break
                elif FORM_HOSTS.search(u.hostname or "") or "docs.google.com/forms" in u.geturl():
                    contact_form = u.geturl(); break
        if not contact_form and providers: contact_form = providers[0]
except Exception as e:
    errors.append("links: %s" % e)

people = []
try:
    if soup is not None:
        seenp = {c["name"].lower() for c in contacts.values() if c["name"]}
        lines = [norm_space(l) for l in soup.get_text("\n")[:60000].split("\n") if norm_space(l)]
        for i, l in enumerate(lines):
            if len(l) > 120 or "@" in l or len(people) >= 40: continue
            nt = split_name_title(l)
            n, t = (nt if nt else ((looks_like_name(l) if not re.search(r"\d", l) else ""), ""))
            if n and not t:
                t = looks_like_title(lines[i + 1]) if i + 1 < len(lines) else ""
                if not t and i > 0 and not looks_like_name(lines[i - 1]): t = looks_like_title(lines[i - 1])
            if n and t and TITLE_STRONG.search(t) and n.lower() not in seenp:
                seenp.add(n.lower()); people.append({"name": n, "title": t})
        # Owners named in prose: "the culinary belief of proprietor Enzo Livia", "Jane Doe, owner".
        ROLE = r"(owner|co-owner|proprietor|founder|co-founder|general manager|managing partner|executive chef|chef[- ]owner|events? (?:manager|director|coordinator)|catering (?:manager|director)|private (?:events|dining) (?:manager|director|coordinator))"
        NM = r"([A-Z][a-z\u00e0-\u00ff'\u2019\-]+(?: (?:de|di|da|van|von|del|la|le))? [A-Z][A-Za-z\u00e0-\u00ff'\u2019\-]+)"
        text = "\n".join(lines)
        found = [(m.group(2), m.group(1)) for m in re.finditer(r"(?i:\b" + ROLE + r"),? " + NM, text)]
        found += [(m.group(1), m.group(2)) for m in re.finditer(NM + r", (?:(?:the|our|and) )*(?i:" + ROLE + r")\b", text)]
        for raw_n, role in found:
            n = looks_like_name(raw_n)
            if n and n.lower() not in seenp and len(people) < 40:
                seenp.add(n.lower()); people.append({"name": n, "title": role.title()})
        # tmead@ / traci.mead@ / traci@ -> Traci Mead, when exactly one person on the page fits.
        for c in contacts.values():
            if c["name"]: continue
            local = re.sub(r"[^a-z]", "", c["email"].split("@")[0])
            hits = []
            for p in people:
                parts = [x for x in re.sub(r"[^a-z ]", "", p["name"].lower()).split() if x]
                if len(parts) < 2: continue
                f, l = parts[0], parts[-1]
                if local in (f + l, f[:1] + l, f + l[:1], l + f[:1], l + f) or (local == f and len(f) >= 3): hits.append(p)
            if len(hits) == 1:
                c["name"] = hits[0]["name"]; c["title"] = c["title"] or hits[0]["title"]; c["how"].append("people")
except Exception as e:
    errors.append("people: %s" % e)

state = "ok"
try:
    title = (soup.title.get_text(" ") if soup is not None and soup.title else "").lower()
    body = (soup.get_text(" ") if soup is not None else re.sub(r"<[^>]+>", " ", raw))
    body = re.sub(r"\s+", " ", body).strip().lower()[:2000]
    if re.search(r"attention required|just a moment|access denied|forbidden|request blocked|security check|captcha|are you a robot|verify you are human|ddos", title) or \
       (len(body) < 1500 and re.search(r"you have been blocked|request cannot be proceeded|access denied|verify you are human|checking your browser|enable javascript and cookies to continue", body)):
        state = "blocked"
    elif re.search(r"\b(404|page not found|not found|page cannot be found|no longer available)\b", title) or (len(body) < 400 and re.search(r"\b(404|page not found)\b", body)):
        state = "not_found"
    text_len = len(body)
except Exception as e:
    errors.append("state: %s" % e); text_len = 0

print(json.dumps({"contacts": [contacts[k] for k in order], "facebook": pick("facebook"), "instagram": pick("instagram"),
                  "socials": socials[:40], "contact_form": contact_form, "subpages": subpages, "navpages": navpages[:80], "page_has_form": page_has_form,
                  "page_has_message_form": message_form, "people": people,
                  "form_providers": providers, "pdfs": pdfs, "iframes": iframes[:15], "url": page_url, "page_state": state,
                  "text_length": text_len, "errors": errors}))
PYEOF
}

# web_fetch URL OUT_FILE — curl a page; prints "<http_code> <final_url>".
web_fetch() {
    local r
    rm -f "$2"
    r=$(curl -sL --compressed --max-time "${3:-12}" -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
        -o "$2" -w '%{http_code} %{url_effective}' "$1" 2>/dev/null)
    [ -z "$r" ] && r="000 $1"
    echo "$r"
}

# web_add_page KIND VIA URL PAGE_JSON — append one scraped page to the venue's page
# log and print a summary (\x1f-separated): contacts fb ig contact_form
# page_has_form page_state text_length n_errors errors emails. The JSON goes in as a
# temp file: the heredoc is python's stdin, so a pipe would never reach it.
web_add_page() {
    printf '%s' "$4" > "$WEB_DIR/page.json"
    pyrun web_add_page python3 - "$WEB_DIR/pages.jsonl" "$1" "$2" "$3" "$WEB_DIR/page.json" <<'PYEOF'
import json, sys
dst, kind, via, url, src = sys.argv[1:6]
raw = open(src, encoding="utf-8", errors="replace").read().strip()
try:
    d = json.loads(raw)
    assert isinstance(d, dict)
except Exception as e:
    print("unparseable page JSON from %s: %s" % (url, e), file=sys.stderr)
    print("\x1f".join(["0", "", "", "", "no", "error", "0", "1", "unparseable page JSON", ""]))
    sys.exit(0)
with open(dst, "a", encoding="utf-8") as f:
    f.write(json.dumps({"kind": kind, "via": via, "url": url, "result": d}, ensure_ascii=False) + "\n")
errs = d.get("errors") or []
clean = lambda s: str(s or "").replace("\x1f", " ").replace("\n", " ")
print("\x1f".join([str(len(d.get("contacts") or [])), clean(d.get("facebook")), clean(d.get("instagram")),
                 clean(d.get("contact_form")), "yes" if d.get("page_has_form") else "no", clean(d.get("page_state") or "ok"),
                 str(d.get("text_length") or 0), str(len(errs)), clean("; ".join(errs))[:300],
                 clean(", ".join(sorted(c.get("email", "") for c in d.get("contacts") or [])))[:400]]))
PYEOF
}

# web_scrape_page KIND URL [WAIT] — render URL in Chrome (unless Chrome JS is off) and
# fall back to curl; records the page and prints "<via>\x1f<web_add_page summary>".
# Returns 1 when neither path produced a result.
web_scrape_page() {
    local kind="$1" url="$2" wait="${3:-10}" res="" via="chrome" f
    if [ "$CHROME_JS_OFF" != "yes" ]; then
        chrome_open "$url"
        chrome_wait_ready "$wait" 1
        res=$(chrome_scrape)
    fi
    if [[ "$res" != '{"contacts"'* ]]; then
        f=$(web_fetch "$url" "$WEB_DIR/page.html" 12)
        res=""
        [ -s "$WEB_DIR/page.html" ] && res=$(web_parse_html "${f#* }" "$WEB_DIR/page.html")
        via="curl"
    fi
    [[ "$res" == '{"contacts"'* ]] || return 1
    printf '%s\x1f%s' "$via" "$(web_add_page "$kind" "$via" "$url" "$res")"
}

# Python helpers for step 1. Each heredoc sits in its own function because bash 3.2
# mis-parses a heredoc inside $() (an apostrophe in it breaks the whole script).
_web_py_web_scope() {
    pyrun web_scope python3 - "$@" <<'PYEOF'
import re, sys
from urllib.parse import urlparse, unquote
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
website, vdom, vshared, vprefix = sys.argv[2:6]
host = R.host_of(website)
reg = R.registrable_domain(website)
shared = "true" if (vshared == "true" or R.is_shared_domain(website)) else "false"
path = unquote(urlparse(website if "://" in website else "http://" + website).path).strip("/")
if vprefix:
    prefix = vprefix.lower().replace("https://", "").replace("http://", "").replace("www.", "", 1).rstrip("/")
elif shared == "true" and path:
    segs = path.split("/")
    prefix = host + "/" + "/".join(segs[:-1] if len(segs) >= 3 else segs)
else:
    prefix = host
m = re.search(r"/([a-z][a-z\-]+(?:-[a-z]{2})?)/?$", "/" + path.lower())
slug = m.group(1) if (m and path) else ""
print("\x1f".join([host, reg, shared, prefix.lower(), "true" if R.is_non_venue_host(website) else "false", slug]))
PYEOF
}

_web_py_web_form_kind() {
    pyrun web_form_kind python3 - "$@" <<'PYEOF'
import re, sys
from urllib.parse import urlparse, unquote
url, prefix, reg, shared, home = sys.argv[1:6]
u = urlparse(url)
host = (u.hostname or "").lower()
host = host[4:] if host.startswith("www.") else host
if u.scheme not in ("http", "https"):
    print("invalid"); sys.exit(0)
if re.search(r"(^|\.)(tripleseat\.com|perfectvenue\.com|eventtemple\.com|jotform\.com|jotform\.us|typeform\.com|wufoo\.com|cognitoforms\.com|123formbuilder\.com|formstack\.com|hsforms\.com|hubspot\.com|honeybook\.com|dubsado\.com|17hats\.com|planningpod\.com|gatherhq\.com|formsite\.com|zohopublic\.com|forms\.office\.com|forms\.gle)$", host) or "docs.google.com/forms" in url:
    print("provider"); sys.exit(0)
hh = (urlparse(home).hostname or "").lower().replace("www.", "", 1)
hp = (host + unquote(u.path)).lower()
if shared == "true":
    print("site" if hp.startswith(prefix) else "offsite")
elif host == hh or host.endswith("." + reg) or host == reg or hp.startswith(prefix):
    print("site")
else:
    print("offsite")
PYEOF
}

_web_py_web_location() {
    pyrun web_location python3 - "$@" <<'PYEOF'
import json, re, sys
from urllib.parse import urlparse
pages, city, home, slug = sys.argv[1:5]
c1 = city.lower().strip().replace(".", "").replace("'", "")
keys = {c1.replace(" ", "-"), c1.replace(" ", "")}
links = []
for line in open(pages):
    d = json.loads(line)
    links += d["result"].get("subpages") or []
# Probe /<city>/ only for multi-location sites, or when the homepage gave us too few
# links to tell (a JS-only homepage such as corsicawinebar.com -> /reston/contact).
multi = bool(slug) or len(links) < 3 or any(re.search(r"/locations?(/|$)", urlparse(u).path.lower()) for u in links)
home_path = urlparse(home).path.rstrip("/").lower()
hit = next((u for u in links if urlparse(u).path.rstrip("/").lower() != home_path
            and any(k and k in urlparse(u).path.lower() for k in keys)), "")
if hit:
    print("LINK\x1f" + hit)
elif multi:
    print("PROBE\x1f" + c1.replace(" ", "-"))
PYEOF
}

_web_py_web_known() {
    pyrun web_known python3 - "$@" <<'PYEOF'
import json, os, sys
urls = set()
for line in open(sys.argv[1]):
    d = json.loads(line)
    urls.add(d["url"]); urls.update(d["result"].get("subpages") or [])
if os.path.exists(sys.argv[2]):
    try:
        d = json.load(open(sys.argv[2]))
        urls.update(p.get("url", "") for p in d.get("pages", []))
        urls.update(d.get("discovered_pages", []))
    except Exception:
        pass
print("\n".join(u.lower() for u in urls if u))
PYEOF
}

_web_py_web_queue() {
    pyrun web_queue python3 - "$@" <<'PYEOF'
import json, os, re, sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl, unquote
pages_f, crawl_f, probes_f, rendered_f, prefix, shared, reg, home, slug, cap, out_f = sys.argv[1:12]
cap = int(cap)
def hostpath(u):
    s = urlsplit(u)
    h = (s.hostname or "").lower()
    return (h[4:] if h.startswith("www.") else h) + unquote(s.path or "/")
home_host = hostpath(home).split("/")[0]
home_reg = ".".join(home_host.split(".")[-2:])
def in_scope(u):
    s = urlsplit(u)
    if s.scheme not in ("http", "https"): return False
    hp = hostpath(u).lower()
    if shared == "true": return hp.startswith(prefix)
    h = hp.split("/")[0]
    return (h == home_host or h == reg or h.endswith("." + reg) or hp.startswith(prefix)
            or h == home_reg or h.endswith("." + home_reg))
SKIP = re.compile(r"\.(css|js|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|eot|pdf|zip|mp3|mp4|mov|json|xml|txt|map|rss|ics)(\?|$)|/wp-content/|/wp-json|/wp-admin|/tbuilder[-_]layout|/elementor[-_]library|/et_pb_layout|/fl-builder-template|/wp-block/|/wp-login|/feed/?$|/cdn-cgi/|/cart|/checkout|/my-account|/account|/login|/signin|/register|[?&](add-to-cart|replytocom|share|sort|orderby|filter|products?|variant|currency|lang|format|print|amp|ical|outlook-ical)=|/tag/|/category/|/author/|/page/\d+|/@@|[?&]ajax", re.I)
STATE = re.compile(r"-(md|va|dc|pa|de|wv|ny|ca|fl|tx|nc|sc|ga|oh|il|ma|nj|ct|ri|nh|vt|me|mi|wi|mn|ia|mo|ks|ne|sd|nd|mt|wy|co|ut|nv|id|or|wa|ak|hi|al|ms|tn|ky|in|ar|la|ok|nm|az)$")
# Music/entertainment pages rank high: that is where a venue names who books performers.
PRIORITY = ["contact", "staff", "team", "people", "leadership", "directory", "management", "about", "music", "entertain",
            "private", "rental", "event", "wedding", "banquet", "cater", "dining", "group", "meeting", "party", "celebrat", "book",
            "inquir", "enquir", "venue", "corporate", "press", "media", "membership", "visit", "location", "faq"]
# Booking-related keyword pages first, then the homepage's own menu, then the rest.
NAV_SCORE = PRIORITY.index("cater") + 0.5
STAFFSEG = re.compile(r"^(our-|the-|meet-(the-|our-)?)?(people|team|staff)(-directory|-members|-bios|-and-board)?$")
def score(u):
    # Keywords count in short section names (/contact-us, /our-team, /private-events), not
    # in long content titles (/people-and-the-planet, /closing-reception-for-...) or dated
    # archive posts (/events/2023/8/27/...).
    p = urlsplit(u).path.lower()
    generic = len(PRIORITY) + min(p.count("/"), 5)
    segs = [x for x in p.split("/") if x]
    def kw_score(seg):
        toks = [t for t in re.split(r"[-_.]+", seg) if t]
        if len(toks) > 4: return generic
        return min([i for i, kw in enumerate(PRIORITY)
                    if kw in seg and (kw not in ("people", "team", "staff") or STAFFSEG.match(seg))] or [generic])
    best = kw_score(segs[-1]) if segs else generic
    # Pages below a keyword section (/about/people/<each scholar>) come after the menu.
    if len(segs) > 1:
        best = min(best, max(min(kw_score(x) for x in segs[:-1]), NAV_SCORE + 0.25))
    if re.search(r"/\d{4}/\d{1,2}(/|$)", p): best += 20
    # The homepage's own menu comes right after contact/staff/about/music/private pages
    # and before deeper keyword matches (/events/music is a menu item on doaks.org).
    if u.rstrip("/").lower() in home_nav and p.count("/") <= 2:
        best = min(best, NAV_SCORE)
    return best
cands = []
home_nav = set()
for line in open(pages_f):
    d = json.loads(line)
    cands += d["result"].get("subpages") or []
    if d.get("kind") == "home":
        home_nav.update(u.rstrip("/").lower() for u in (d["result"].get("navpages") or []))
    cf = d["result"].get("contact_form")
    if cf: cands.append(cf)
cands += [l.strip() for l in open(probes_f) if l.strip()]
static_ok = 0
if os.path.exists(crawl_f):
    try:
        d = json.load(open(crawl_f))
        for p in d.get("pages", []):
            if p.get("ok") is False: continue  # 404s and failed fetches are not worth a Chrome render
            static_ok += 1
            cands.append(p.get("url") or "")
    except Exception:
        pass
rendered = {l.strip().rstrip("/").lower() for l in open(rendered_f) if l.strip()}
seen, per_path, queue = set(), {}, []
for r in rendered:  # a rendered page's ?query variants are duplicates too
    rs = urlsplit(r)
    rq = [(k, v) for k, v in parse_qsl(rs.query) if k.lower() in ("page_id", "p", "pageid", "id")]
    per_path[(rs.path.rstrip("/").lower(), tuple(rq))] = 1
off = other = variants = junk = 0
for u in cands:
    u = (u or "").strip()
    if not u: continue
    u = urlunsplit(urlsplit(u)._replace(fragment=""))
    key = u.rstrip("/").lower()
    if key in seen or key in rendered: continue
    seen.add(key)
    if not in_scope(u): off += 1; continue
    if SKIP.search(u): junk += 1; continue
    m = re.search(r"/([a-z][a-z\-]+(?:-[a-z]{2})?)/?$", urlsplit(u).path.lower())
    sub = m.group(1) if m else ""
    if slug and sub and sub != slug and STATE.search(sub): other += 1; continue
    s = urlsplit(u)
    q = [(k, v) for k, v in parse_qsl(s.query) if k.lower() in ("page_id", "p", "pageid", "id")]
    pk = (s.path.rstrip("/").lower(), tuple(q))
    per_path[pk] = per_path.get(pk, 0) + 1
    if per_path[pk] > 1: variants += 1; continue
    queue.append(u)
queue.sort(key=score)
# At most 4 pages per section (/events/a, /events/b, ...) so event listings can't use
# up the budget; contact/staff pages are never limited.
def family(u):
    # /events/a, /events/b -> "events"; /wedding-50-people, /wedding-80-people -> "wedding-*"
    segs = [x for x in urlsplit(u).path.lower().split("/") if x]
    if len(segs) >= 2: return segs[0]
    m = re.match(r"([a-z]+)[-_]", segs[0]) if segs else None
    return (m.group(1) + "-*") if m else ""
# ...and at most 8 pages under one parent (/about/people/leadership-specialists/<each>),
# even staff bios, so one long directory can't use up the whole budget.
def parent(u):
    segs = [x for x in urlsplit(u).path.lower().split("/") if x]
    return "/".join(segs[:-1]) if len(segs) >= 3 else ""
fam, pfam = {}, {}
for r in rendered:
    f, pf = family(r), parent(r)
    if f: fam[f] = fam.get(f, 0) + 1
    if pf: pfam[pf] = pfam.get(pf, 0) + 1
picked = []
for u in queue:
    f, pf = family(u), parent(u)
    if pf:
        if pfam.get(pf, 0) >= 8: continue
        pfam[pf] = pfam.get(pf, 0) + 1
    if f and score(u) > PRIORITY.index("private") and u.rstrip("/").lower() not in home_nav:
        if fam.get(f, 0) >= 4: continue
        fam[f] = fam.get(f, 0) + 1
    picked.append(u)
if out_f == "-next":
    # Called before each render: links found on pages rendered so far are in the pool too.
    print(picked[0] if picked else "")
else:
    with open(out_f, "w") as f:
        f.write("".join(u + "\n" for u in picked[:cap]))
    print("%d %d %d %d %d %d %d" % (len(queue), min(len(picked), cap), off, other, variants, junk, static_ok))
PYEOF
}

_web_py_web_pdfs() {
    pyrun web_pdfs python3 - "$@" <<'PYEOF'
import json, os, re, sys
pages_f, crawl_f, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
done = set()
if os.path.exists(crawl_f):
    try:
        done = {str(p.get("url", "")).lower() for p in json.load(open(crawl_f)).get("pdfs", [])}
    except Exception:
        pass
KW = re.compile(r"event|wedding|private|banquet|cater|package|menu|contact|staff|team|group|party|meeting|brochure|kit|info|pricing|rental|venue|dining|holiday|celebrat", re.I)
found = {}
for line in open(pages_f):
    d = json.loads(line)
    for p in d["result"].get("pdfs") or []:
        u = str(p.get("url") or "")
        if not u or u.lower() in done or u in found: continue
        found[u] = (0 if KW.search(u + " " + str(p.get("text") or "")) else 1, d["url"])
for u, (rank, src) in sorted(found.items(), key=lambda x: x[1][0])[:cap]:
    print(u + "\x1f" + src)
PYEOF
}

_web_py_web_decide() {
    pyrun web_decide python3 - "$@" <<'PYEOF'
import json, os, re, sys
from urllib.parse import urlsplit, unquote
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
pages_f, crawl_f, pdfs_f, prefix, shared, reg, home, slug, venue = sys.argv[2:11]
def hostpath(u):
    s = urlsplit(u)
    h = (s.hostname or "").lower()
    return (h[4:] if h.startswith("www.") else h) + unquote(s.path or "/")
home_host = hostpath(home).split("/")[0]
# Sites the stored website redirects to are the venue's own site too.
alias_regs = {R.registrable_domain(home)} - {""}
def in_scope(u):
    hp = hostpath(u).lower()
    if shared == "true": return hp.startswith(prefix)
    h = hp.split("/")[0]
    return (h == home_host or h == reg or h.endswith("." + reg) or hp.startswith(prefix)
            or any(h == a or h.endswith("." + a) for a in alias_regs))
CDN = re.compile(r"(^|\.)(wixstatic\.com|filesusr\.com|squarespace-cdn\.com|squarespace\.com|wp\.com|weebly\.com|editmysite\.com|godaddysites\.com|img1\.wsimg\.com|wsimg\.com|shopify\.com|cloudfront\.net|amazonaws\.com|googleusercontent\.com)$", re.I)
CONTACTISH = re.compile(r"contact|get-in-touch|reach|inquir|enquir|about|our-story|who-we-are|team|staff|people|leadership|directory|management|meet|event|private|wedding|banquet|cater|dining|group|meeting|part(y|ies)|celebrat|rental|book", re.I)
STATE = re.compile(r"-(md|va|dc|pa|de|wv|ny|ca|fl|tx|nc|sc|ga|oh|il|ma|nj|ct|ri|nh|vt|me|mi|wi|mn|ia|mo|ks|ne|sd|nd|mt|wy|co|ut|nv|id|or|wa|ak|hi|al|ms|tn|ky|in|ar|la|ok|nm|az)$")
def other_location(u):
    if not slug: return False
    m = re.search(r"/([a-z][a-z\-]+(?:-[a-z]{2})?)/?$", urlsplit(u).path.lower())
    sub = m.group(1) if m else ""
    return bool(sub and sub != slug and STATE.search(sub))
def is_home(u):
    return urlsplit(u).path.strip("/") == "" or u.rstrip("/").lower() == home.rstrip("/").lower()

emails = {}   # email -> {"name","title","hits":[(url, mailto, kind)]}
def hit(e, url, mailto, kind, name="", title=""):
    e = (e or "").strip().lower()
    e = re.sub(r"(@[a-z0-9\-.]*?\.(?:com|org|net|edu|gov|biz|info|us))\.(?![a-z]{2}$)[a-z0-9\-.]+$", r"\1", e)
    if not e: return
    r = emails.setdefault(e, {"name": "", "title": "", "hits": []})
    r["hits"].append((url, bool(mailto), kind))
    if name and (not r["name"] or (title and not r["title"])):
        r["name"], r["title"] = name, title or r["title"]
    elif title and not r["title"] and not r["name"]:
        r["title"] = title
social = []   # (platform, url, zone, page_url)
people = {}   # lower name -> (name, title, page)
PEOPLEISH = re.compile(r"team|staff|people|leadership|about|our-story|who-we-are|management|directory|board|governance|meet|contact|private|event|wedding|owner|founder|chef|history", re.I)
kinds = set()
KINDS = (("contact", re.compile(r"contact|get-in-touch|reach|inquir|enquir", re.I)),
         ("about", re.compile(r"about|our-story|who-we-are|history", re.I)),
         ("events", re.compile(r"event|private|wedding|banquet|cater|dining|group|meeting|part(y|ies)|celebrat|rental|book", re.I)),
         ("team", re.compile(r"team|staff|people|leadership|directory|management|board|meet", re.I)))
forms = []    # (rank, url)
# An event/private-dining inquiry form (the channel that books events) ranks above a
# general contact form, which ranks above a form on any other page.
INQUIRY = re.compile(r"inquir|enquir|rfp|request|plan-your|book-(?:an|your)-event|event-request|lead", re.I)
EVENTFORM = re.compile(r"private|wedding|rental|occasion|banquet|cater|special-events|group-(?:dining|events|sales)|celebrat|meetings?-events|host-(?:an|your)", re.I)
LISTING = {"event", "events", "mc-events", "calendar", "blog", "news", "post", "posts", "faq", "faq-items", "product", "products", "shop", "menu", "menus", "tag", "category"}
NOTFORM = re.compile(r"/(cart|checkout|my-account|account|login|signin|register|shop|store|product|products|gift-?cards?|donate)(/|$)", re.I)
# Guest surveys / feedback / polls / reviews (e.g. a Google Form on /guestsurvey2025) are not inquiry channels.
SURVEY = re.compile(r"survey|feedback|(^|[^a-z])(polls?|reviews?)([^a-z]|$)", re.I)
def form_rank(page_url, form_url=""):
    # A form hosted by an inquiry service (Tripleseat, HoneyBook, ...) linked or framed
    # from the page is a real inquiry channel; a site-wide widget script is not.
    provider = bool(form_url) and (urlsplit(form_url).hostname or "") != (urlsplit(page_url).hostname or "")
    segs = [x for x in urlsplit(page_url).path.lower().split("/") if x]
    if NOTFORM.search(urlsplit(page_url).path) or SURVEY.search(urlsplit(page_url).path) or SURVEY.search(form_url or ""):
        return 9
    if "questionnaire" in (urlsplit(page_url).path + " " + (form_url or "")).lower():
        return 4                     # can be a wedding inquiry, but never beats a contact page
    if len(segs) >= 2 and segs[0] in LISTING:
        return 4                     # a form on one event/blog post is not the venue's inquiry channel
    p = "/" + "/".join(segs)
    if provider or INQUIRY.search(p):
        return 0
    if EVENTFORM.search(p):
        return 1
    return 2 if KINDS[0][1].search(p) or is_home(page_url) else 3
for line in open(pages_f):
    d = json.loads(line)
    res, url = d["result"], d["url"]
    page = res.get("url") or url
    path = urlsplit(page).path
    if in_scope(page):
        if d.get("kind") == "home" or is_home(page): kinds.add("home")
        for kname, krx in KINDS:
            if krx.search(path): kinds.add(kname)
    if in_scope(page) and (is_home(page) or PEOPLEISH.search(path)):
        for p in res.get("people") or []:
            n, t = str(p.get("name") or "").strip(), str(p.get("title") or "").strip()
            if n and t and n.lower() not in people: people[n.lower()] = (n, t, page)
    if in_scope(page) and res.get("page_has_message_form"):
        forms.append((form_rank(page), page.split("#")[0]))
    for fp in res.get("form_providers") or []:
        forms.append((form_rank(page, fp), fp))
    for c in res.get("contacts") or []:
        hit(c.get("email"), page, c.get("mailto"), "page", c.get("name") or "", c.get("title") or "")
    socs = res.get("socials")
    if socs is None:
        socs = [{"platform": p, "url": res.get(p) or "", "zone": "body"} for p in ("facebook", "instagram")]
    for s in socs:
        if s.get("url"): social.append((s.get("platform"), s["url"], s.get("zone") or "body", page))
crawl_socials = []
if os.path.exists(crawl_f):
    try:
        cd = json.load(open(crawl_f))
        rt = str(cd.get("redirected_to") or "")
        if rt and shared != "true" and not (R.is_shared_domain(rt) or R.is_non_venue_host(rt)):
            rreg = R.registrable_domain(rt)
            if rreg and rreg != reg:
                alias_regs.add(rreg)
                print("\x1f".join(["ALIAS", rreg]))
        for c in cd.get("contacts", []):
            srcs = c.get("sources") or []
            for src in srcs or [home]:
                is_pdf = src.lower().split("?")[0].endswith(".pdf")
                hit(c.get("email"), src, c.get("mailto") and not is_pdf, "pdf" if is_pdf else "crawl",
                    str(c.get("name_hint") or ""), str(c.get("title_hint") or ""))
        for s in cd.get("socials", []):
            crawl_socials.append((s.get("platform"), s.get("url") or "", s.get("sources") or []))
        for p in cd.get("people", []) or []:
            n, t, pg = str(p.get("name") or "").strip(), str(p.get("title") or "").strip(), str(p.get("page") or home)
            if n and t and n.lower() not in people and in_scope(pg) and (is_home(pg) or PEOPLEISH.search(urlsplit(pg).path)):
                people[n.lower()] = (n, t, pg)
        for f in cd.get("contact_forms", []) or []:
            fu, fp = str(f.get("url") or ""), str(f.get("page") or f.get("url") or "")
            if not fu or not (in_scope(fp) or f.get("kind") != "html_form"): continue
            forms.append((form_rank(fp, fu), fu))
        cov = cd.get("coverage") or {}
        kinds.update(cov.get("page_kinds_visited") or [])
        flags = [k for k in ("blocked", "throttled", "time_budget_exceeded") if cov.get(k)]
        if flags:
            print("\x1f".join(["CRAWL", ",".join(flags), str(cov.get("blocked_reason") or cov.get("throttled_reason") or "")[:120]]))
    except Exception as e:
        print("WARN\x1fstatic crawl unreadable: %s" % e)
for line in open(pdfs_f):
    try:
        d = json.loads(line)
    except Exception:
        continue
    for c in d.get("emails") or []:
        hit(c.get("email"), d.get("url") or "", False, "pdf")

def person_for(email):
    local = re.sub(r"[^a-z]", "", email.split("@")[0])
    hits = []
    for n, t, _ in people.values():
        parts = [x for x in re.sub(r"[^a-z ]", "", n.lower()).split() if x]
        if len(parts) < 2: continue
        f, l = parts[0], parts[-1]
        if local in (f + l, f[:1] + l, f + l[:1], l + f[:1], l + f) or (local == f and len(f) >= 3): hits.append((n, t))
    return hits[0] if len(hits) == 1 else None

# The venue's own mail domain can differ from its website domain: the club at
# sparrowspointcc.com writes from @spcc1925.com, rollingroadgc.org from @rollingroadgc.com,
# imperialchestertown.com from @thekitchenattheimperial.com. A domain counts when the
# venue's own pages show at least 2 of its addresses (one a mailto) and more of them than
# of the website domain, or when it is the website's name under another TLD. One-off
# vendor, PR, designer and parent-group inboxes never reach 2.
AGENCY_LABEL = re.compile(r"(pr|media|marketing|agency|communications|comms|creative|design|digital|studios?|photo\w*|events?|coordinators|productions?)$")
if shared != "true" and reg and not any(a != reg for a in alias_regs):
    site_label = reg.rsplit(".", 1)[0]
    on_site, per_dom, mailto_dom = 0, {}, {}
    for e, r in emails.items():
        dom = e.split("@", 1)[1] if "@" in e else ""
        dreg = R.registrable_domain(dom) if dom else ""
        own_hits = [(u, m) for u, m, k in r["hits"] if in_scope(u)]
        if not dreg or not own_hits:
            continue
        if dreg == reg:
            on_site += 1
            continue
        if dreg in R.FREEMAIL_DOMAINS or R.is_shared_domain(dreg) or R.is_non_venue_host(dreg):
            continue
        if AGENCY_LABEL.search(dreg.rsplit(".", 1)[0]):
            continue
        per_dom[dreg] = per_dom.get(dreg, 0) + 1
        if any(m and (is_home(u) or CONTACTISH.search(urlsplit(u).path)) for u, m in own_hits):
            mailto_dom[dreg] = mailto_dom.get(dreg, 0) + 1
    mail_alias = ""
    for dreg, n in sorted(per_dom.items(), key=lambda x: -x[1]):
        if dreg.rsplit(".", 1)[0] == site_label and len(site_label) >= 5:
            mail_alias = dreg
            break
        if n >= 2 and mailto_dom.get(dreg, 0) >= 1 and n > on_site:
            mail_alias = dreg
            break
    if mail_alias:
        print("\x1f".join(["ALIAS", mail_alias]))

named = set()
for e, r in sorted(emails.items()):
    hits = r["hits"]
    if not r["name"]:
        # tmead@ on the contact page + "Traci Mead, Executive Director" on the staff page.
        pm = person_for(e)
        if pm: r["name"], r["title"] = pm[0], r["title"] or pm[1]
    scoped = []
    for url, mailto, kind in hits:
        h = (urlsplit(url).hostname or "").lower()
        if kind == "pdf" and not in_scope(url):
            # A PDF on the site builder's CDN is the venue's own file; elsewhere it's external.
            scoped.append((url, mailto, kind, "venue_site" if CDN.search(h) else "external"))
        elif in_scope(url):
            scoped.append((url, mailto, kind, "venue_site"))
    if not scoped:
        print("DROP\x1f%s\x1f%s\x1f%s" % (e, "shared_offprefix" if shared == "true" else "off_site_page", hits[0][0]))
        continue
    if all(other_location(u) for u, _, _, _ in scoped):
        print("DROP\x1f%s\x1fother_location_page\x1f%s" % (e, scoped[0][0]))
        continue
    ev = "external"
    if any(ev2 == "venue_site" for _, _, _, ev2 in scoped): ev = "venue_site"
    if any(m and ev2 == "venue_site" and (is_home(u) or CONTACTISH.search(urlsplit(u).path)) for u, m, _, ev2 in scoped): ev = "venue_mailto"
    src = next((u for u, m, _, _ in scoped if m), scoped[0][0])
    print("\x1f".join(["CONTACT", e, r["name"].replace("\x1f", " "), r["title"].replace("\x1f", " "), ev, src]))
    if r["name"]: named.add(r["name"].lower())
# Named decision-makers with no email on the site -> pending-contact candidates (P3 filters them).
for key, (n, t, page) in people.items():
    if key not in named:
        print("\x1f".join(["PERSON", n, t, page]))
forms = [f for f in forms if f[0] < 9]
if forms:
    ranked = sorted(set(forms))
    print("\x1f".join(["FORM", ranked[0][1], str(ranked[0][0])]))
    for r, u in ranked[1:4]:
        print("\x1f".join(["FORMALT", u, str(r)]))
print("\x1f".join(["VISITED", ",".join(k for k in ("home", "contact", "about", "events", "team") if k in kinds)]))

# ---- Socials (P7) ----
def handle_of(u):
    p = [x for x in urlsplit(u).path.split("/") if x]
    if not p: return ""
    if p[0].lower() == "profile.php": return ""
    if p[0].lower() == "pages" and len(p) >= 2: return p[1]
    return p[0]
def words(h):
    h = re.sub(r"([a-z])([A-Z])", r"\1 \2", h)
    return re.sub(r"[._\-]+", " ", h).strip()
brand = (reg.split(".")[0] if reg else "").lower()
best = {}
cands = {}
for platform, url, zone, page in social:
    if platform not in ("facebook", "instagram") or not in_scope(page): continue
    k = (platform, url.rstrip("/").lower())
    c = cands.setdefault(k, {"platform": platform, "url": url.rstrip("/"), "hf": False, "pages": set(), "crawl": 0})
    c["pages"].add(page)
    if zone in ("header", "footer"): c["hf"] = True
for platform, url, srcs in crawl_socials:
    if platform not in ("facebook", "instagram") or not url: continue
    srcs = [s for s in srcs if in_scope(s)]
    if not srcs: continue
    k = (platform, url.rstrip("/").lower())
    c = cands.setdefault(k, {"platform": platform, "url": url.rstrip("/"), "hf": False, "pages": set(), "crawl": 0})
    c["crawl"] = max(c["crawl"], len(srcs))
for (platform, _), c in cands.items():
    h = handle_of(c["url"])
    hw = words(h)
    name_ok = bool(h) and (R.org_name_matches(hw, venue) or R.org_name_matches(h, venue))
    site_ok = shared != "true"
    template = c["crawl"] >= 2 or len(c["pages"]) >= 2
    reason = ""
    if re.search(r"\.(com|net|org|biz|us)$", h.lower()) and not name_ok:
        reason = "domain_like_handle"
    elif shared == "true" and brand and h.lower().startswith(brand) and not name_ok:
        reason = "brand_handle"
    elif name_ok:
        reason = "name_match"
    elif site_ok and c["hf"]:
        reason = "header_footer"
    elif site_ok and template and "profile.php" in c["url"]:
        reason = "sitewide_profile"
    elif site_ok and c["crawl"] >= 2:
        reason = "sitewide_link"
    else:
        reason = "no_evidence" if site_ok else "shared_domain_no_name_match"
    ok = reason in ("name_match", "header_footer", "sitewide_profile", "sitewide_link")
    score = (4 if reason == "name_match" else 0) + (2 if c["hf"] else 0) + min(len(c["pages"]) + c["crawl"], 20) / 100.0
    if ok and (platform not in best or score > best[platform][0]):
        best[platform] = (score, c["url"], reason)
    if not ok:
        print("SOCIAL_REJECT\x1f%s\x1f%s\x1f%s" % (platform, c["url"], reason))
for platform, (score, url, reason) in best.items():
    print("SOCIAL\x1f%s\x1f%s\x1f%s" % (platform, url, reason))
print("STATS\x1f%d\x1f%d" % (len(emails), len(cands)))
PYEOF
}

_web_py_coverage_counts() {
    pyrun coverage python3 - "$@" <<'PYEOF'
import json, sys
d=json.load(open(sys.argv[1])); c=d.get('coverage',{})
print(c.get('visited_page_count',0), c.get('pdf_count',0), len(d.get('contacts',[])), c.get('sitemap_count',0), c.get('unvisited_page_count',0), c.get('fragment_state_count',0))
PYEOF
}

# =================================================================
# STEP 1: WEBSITE SCRAPE (Chrome-based for JS-rendered sites)
# =================================================================
step1_website() {
    local venue="$1" venue_id="$2" website="$3" city="$4"
    log ""
    log "========== STEP 1: Website Scrape =========="

    # C1 globals are set by run_venue; fall back to the arguments if they belong to another venue.
    if [ "$VENUE_ID" != "$venue_id" ]; then
        VENUE_ID="$venue_id"; VENUE_NAME="$venue"; VENUE_WEBSITE="$website"
        VENUE_DOMAIN=""; VENUE_SHARED_DOMAIN="false"; VENUE_SITE_PREFIX=""
    fi
    [ -z "$VENUE_NAME" ] && VENUE_NAME="$venue"

    if [ -z "$website" ] || [ "$website" = "None" ]; then
        log "  [SKIP] No website URL"
        step_result "$venue_id" web skipped reason=no_website via=none form=no
        return
    fi

    local safe_venue_id
    safe_venue_id=$(printf '%s' "$venue_id" | tr -cd '[:alnum:]_.-')
    [ -z "$safe_venue_id" ] && safe_venue_id="venue"
    WEB_DIR="/tmp/pipeline_web_${safe_venue_id}"
    rm -rf "$WEB_DIR"
    mkdir -p "$WEB_DIR"
    : > "$WEB_DIR/pages.jsonl"
    : > "$WEB_DIR/pdfs.jsonl"
    : > "$WEB_DIR/probes.txt"
    : > "$WEB_DIR/rendered.txt"
    rm -f /tmp/pipeline_contact_page_scrape.json /tmp/pipeline_web_method /tmp/pipeline_scrape.json /tmp/pipeline_all_contacts.txt

    # Site scope. On a shared brand domain (sonesta.com, invitedclubs.com, ...) only the
    # property's own pages count; elsewhere the whole site (plus a redirect host) does.
    local scope site_host site_reg site_shared site_prefix site_nonvenue location_slug
    scope=$(_web_py_web_scope "$SCRIPT_DIR" "$website" "$VENUE_DOMAIN" "$VENUE_SHARED_DOMAIN" "$VENUE_SITE_PREFIX")
    IFS=$'\x1f' read -r site_host site_reg site_shared site_prefix site_nonvenue location_slug <<< "$scope"
    if [ -z "$site_host" ]; then
        log "  [ERROR] Could not parse website URL: $website"
        step_result "$venue_id" web failed reason=bad_website_url via=none form=no
        return
    fi
    if [ "$site_nonvenue" = "true" ]; then
        log "  [SKIP] Website is a directory/social host ($site_host), not the venue's own site"
        step_result "$venue_id" web skipped reason=non_venue_host host=$site_host via=none form=no
        return
    fi
    if [ "$site_shared" = "true" ]; then
        log "  [WEB] Shared brand domain ($site_reg) — only pages under $site_prefix count for this property"
    fi

    log "  URL: $website"
    write_scrape_js

    # A curl copy of the homepage: the fallback parser's input and the soft-404 reference.
    local home_fetch home_code home_final
    home_fetch=$(web_fetch "$website" "$WEB_DIR/home.html" 15)
    home_code="${home_fetch%% *}"; home_final="${home_fetch#* }"

    log "  Opening in Chrome: $website"
    chrome_open "$website"
    chrome_wait_ready 15 3

    local scrape_result home_via="chrome" home_state="ok" chrome_walled="no"
    scrape_result=$(chrome_scrape)
    if [[ "$scrape_result" != '{"contacts"'* ]] && [ "$CHROME_JS_OFF" != "yes" ]; then
        log "  [WARN] Chrome scrape returned empty — trying with longer wait (8s for JS-heavy sites)"
        sleep 8
        scrape_result=$(chrome_scrape)
    fi
    if [[ "$scrape_result" != '{"contacts"'* ]]; then
        [ "$CHROME_JS_OFF" = "yes" ] && log "  [CHROME] WARNING: JavaScript from Apple Events is off — website is being scraped by curl only"
        log "  [WARN] Chrome scrape failed — trying curl fallback..."
        scrape_result=""
        [ -s "$WEB_DIR/home.html" ] && scrape_result=$(web_parse_html "${home_final:-$website}" "$WEB_DIR/home.html")
        if [[ "$scrape_result" == '{"contacts"'* ]]; then
            log "  [CURL FALLBACK] Success — parsed HTML directly"
            home_via="curl"
        else
            # The static crawl (python requests) can still get through; it decides below.
            log "  [ERROR] Both Chrome and curl fallback failed on the homepage (HTTP $home_code) — trying the static crawl only"
            home_via="static"
        fi
    fi

    local summary="" n_contacts=0 fb="" ig="" contact_form="" has_form="" page_state="" text_len=0 n_err=0 err_text="" page_emails=""
    if [ "$home_via" != "static" ]; then
        summary=$(web_add_page home "$home_via" "$website" "$scrape_result")
        IFS=$'\x1f' read -r n_contacts fb ig contact_form has_form page_state text_len n_err err_text page_emails <<< "$summary"
    fi

    # Blank render (JS-heavy site still drawing) — retry once with a longer wait.
    if [ "$home_via" = "chrome" ] && [ "${n_contacts:-0}" = "0" ] && [ -z "$fb" ] && [ -z "$ig" ] && [ "${text_len:-0}" -lt 300 ] 2>/dev/null; then
        log "  [WARN] Page returned 0 emails + 0 social — likely didn't render. Retrying with 12s wait..."
        chrome_open "$website"
        sleep 12
        local retry_result
        retry_result=$(chrome_scrape)
        if [[ "$retry_result" == '{"contacts"'* ]]; then
            scrape_result="$retry_result"
            summary=$(web_add_page home "$home_via" "$website" "$scrape_result")
            IFS=$'\x1f' read -r n_contacts fb ig contact_form has_form page_state text_len n_err err_text page_emails <<< "$summary"
        fi
    fi
    # A bot wall in Chrome is not "no contacts": try the plain HTML as well.
    if [ "$page_state" = "blocked" ]; then
        log "  [BLOCKED] Homepage shows a bot wall/CAPTCHA in Chrome — trying the plain HTML"
        home_state="blocked"
        if [ -s "$WEB_DIR/home.html" ]; then
            local curl_home
            curl_home=$(web_parse_html "${home_final:-$website}" "$WEB_DIR/home.html")
            if [[ "$curl_home" == '{"contacts"'* ]]; then
                summary=$(web_add_page home curl "$website" "$curl_home")
                IFS=$'\x1f' read -r n_contacts fb ig contact_form has_form page_state text_len n_err err_text page_emails <<< "$summary"
                # Chrome itself worked (the site walled it), so this is not a Chrome failure.
                if [ "$page_state" != "blocked" ]; then home_state="ok"; home_via="chrome"; chrome_walled="yes"; scrape_result="$curl_home"; fi
            fi
        fi
    fi
    # The stored page is gone (moved location page, old path) but the site is up:
    # read the site root too, instead of reporting an empty website.
    if { [ "$page_state" = "not_found" ] || [ "$home_code" = "404" ] || [ "$home_code" = "410" ]; } && \
       [ "${website#*://*/}" != "$website" ] && [ -n "${website#*://*/}" ]; then
        local root_url root_summary root_via root_n
        root_url=$(printf '%s' "${home_final:-$website}" | sed -E 's#^(https?://[^/]+).*#\1/#')
        log "  [WEB] Stored page looks like a not-found page — also reading the site root: $root_url"
        if root_summary=$(web_scrape_page home "$root_url" 15); then
            IFS=$'\x1f' read -r root_via root_n _ <<< "$root_summary"
            printf '%s\n' "$root_url" >> "$WEB_DIR/rendered.txt"
            n_contacts=$(( ${n_contacts:-0} + ${root_n:-0} ))
        fi
    fi
    [ "${n_err:-0}" != "0" ] && log "  [WARN] Scrape JS reported $n_err error(s) on the homepage (partial data kept): $err_text"
    printf '%s\n' "$scrape_result" > /tmp/pipeline_scrape.json
    echo "$home_via" > /tmp/pipeline_web_method
    [ -n "$page_emails" ] && log "  Found on homepage: $page_emails"

    local email_count="${n_contacts:-0}" cf_confirmed="no"
    local rendered_list="$WEB_DIR/rendered.txt"
    printf '%s\n' "$website" "${home_final:-$website}" >> "$rendered_list"

    # Contact form: visit it, check for a real form, and scrape it for emails either way.
    if [ -n "$contact_form" ] && [ "$contact_form" != "None" ]; then
        log "  Validating contact form URL: $contact_form"
        local cf_kind
        cf_kind=$(_web_py_web_form_kind "$contact_form" "$site_prefix" "$site_reg" "$site_shared" "${home_final:-$website}")
        if [ "$cf_kind" = "provider" ]; then
            cf_confirmed="yes"
            log "  ✓ Event inquiry form (third-party form service): $contact_form"
        elif [ "$cf_kind" != "site" ]; then
            log "  ✗ Contact form link is not a page on the venue's site ($cf_kind) — clearing contact_form"
            contact_form=""
        else
            local cf_summary cf_via cf_n cf_fb cf_ig cf_cf cf_has="" cf_state="" cf_len cf_nerr cf_err cf_emails
            if cf_summary=$(web_scrape_page contact "$contact_form" 10); then
                IFS=$'\x1f' read -r cf_via cf_n cf_fb cf_ig cf_cf cf_has cf_state cf_len cf_nerr cf_err cf_emails <<< "$cf_summary"
                printf '%s\n' "$contact_form" >> "$rendered_list"
                [ -n "$cf_emails" ] && log "  Found on contact page: $cf_emails"
                [ -z "$fb" ] && [ -n "$cf_fb" ] && log "  [SOCIAL] Facebook link on contact page: $cf_fb"
                [ -z "$ig" ] && [ -n "$cf_ig" ] && log "  [SOCIAL] Instagram link on contact page: $cf_ig"
            fi
            if [ "$cf_has" = "yes" ]; then
                cf_confirmed="yes"
                log "  ✓ Real contact form confirmed"
            elif [ "$cf_state" = "not_found" ]; then
                log "  ✗ Contact form URL is a not-found page — clearing contact_form"
                contact_form=""
            elif printf '%s' "$contact_form" | grep -qiE 'contact|inquir|enquir|get-in-touch|rfp'; then
                # Some builders draw the form late or inside a widget the check can't see.
                log "  ⚠ No rendered form found — keeping URL (likely JS/Wix site)"
            else
                log "  ✗ No submittable form found — clearing contact_form"
                contact_form=""
            fi
        fi
    fi

    log "  Emails: $email_count | FB: ${fb:-none} | IG: ${ig:-none} | Contact Form: ${contact_form:-none}"

    # --- Website-wide recursive discovery audit ---
    # The browser homepage crawl is intentionally supplemented by a deterministic,
    # bounded recursive crawl. This catches second/third-hop pages, sitemap-only URLs,
    # PDFs, plain-text/obfuscated emails, and social links that are not on the homepage.
    local static_crawl_json coverage_file crawl_ok="no"
    static_crawl_json="/tmp/pipeline_static_crawl_${safe_venue_id}.json"
    coverage_file="${COVERAGE_DIR}/${safe_venue_id}.json"
    rm -f "$static_crawl_json"

    if [ -f "${SCRIPT_DIR}/site_discovery.py" ]; then
        log "  [DISCOVERY] Recursive crawl + sitemap/PDF audit (max 40 pages, depth 3)..."
        local crawl_err="$WEB_DIR/static_crawl.err"
        # On a shared brand domain only the property's own section is crawled.
        local crawl_prefix=""
        [ "$site_shared" = "true" ] && [ "${site_prefix#*/}" != "$site_prefix" ] && crawl_prefix="/${site_prefix#*/}"
        python3 "${SCRIPT_DIR}/site_discovery.py" static-crawl "$website" --max-pages 40 --max-depth 3 \
            ${crawl_prefix:+--path-prefix "$crawl_prefix"} > "$static_crawl_json" 2> "$crawl_err"
        # Older site_discovery.py printed debug lines before the JSON; keep the JSON part.
        if python3 - "$static_crawl_json" >/dev/null 2>&1 <<'PYEOF'
import json, sys
p = sys.argv[1]
raw = open(p, encoding="utf-8", errors="replace").read()
try:
    json.loads(raw)
except ValueError:
    i = raw.find("\n{")
    d = json.loads(raw[i + 1:] if i >= 0 else raw[raw.index("{"):])
    open(p, "w", encoding="utf-8").write(json.dumps(d))
PYEOF
        then
            crawl_ok="yes"
            # Persist an auditable coverage artifact for this venue.
            pyrun coverage python3 - "$static_crawl_json" "$coverage_file" "$venue_id" "$venue" "$website" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
src, dst, venue_id, venue, website = sys.argv[1:6]
d = json.load(open(src))
d["venue_id"] = venue_id
d["venue_name"] = venue
d["requested_website"] = website
d["coverage_generated_at"] = datetime.now(timezone.utc).isoformat()
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False, sort_keys=True)
PYEOF

            local crawl_pages crawl_pdfs crawl_emails crawl_sitemaps crawl_unvisited crawl_fragments
            read -r crawl_pages crawl_pdfs crawl_emails crawl_sitemaps crawl_unvisited crawl_fragments < <(_web_py_coverage_counts "$static_crawl_json")
            log "  [COVERAGE] pages=$crawl_pages pdfs=$crawl_pdfs emails=$crawl_emails sitemaps=$crawl_sitemaps fragments=$crawl_fragments unvisited=$crawl_unvisited"
            log "  [COVERAGE] Saved: $coverage_file"
        else
            local crawl_why
            crawl_why=$(grep -v -e 'NotOpenSSLWarning' -e 'warnings.warn' -e '^\s*$' "$crawl_err" 2>/dev/null | tail -1 | cut -c1-200)
            log "  [WARN] Recursive discovery audit failed${crawl_why:+ ($crawl_why)}; browser crawl will continue"
            errlog_append static_crawl "$crawl_err"
            rm -f "$static_crawl_json"
        fi
        # Keep real errors from a crawl that still produced JSON (not its progress notes).
        if [ "$crawl_ok" = "yes" ] && grep -qE 'Traceback|Error|Exception' "$crawl_err" 2>/dev/null; then
            grep -E 'Traceback|Error|Exception|^  File' "$crawl_err" > "$crawl_err.x"
            errlog_append static_crawl "$crawl_err.x"
            rm -f "$crawl_err.x"
        fi
        rm -f "$crawl_err"
    fi

    # --- Location page for multi-location sites (PA-18) ---
    # Only when the homepage found nothing and the site plausibly has per-location
    # pages; a probe counts only if it is a real page (not a redirect home or a soft 404).
    local loc_found=""
    if [ "$email_count" = "0" ] && [ -n "$city" ] && [ "$city" != "None" ]; then
        loc_found=$(_web_py_web_location "$WEB_DIR/pages.jsonl" "$city" "${home_final:-$website}" "$location_slug")
        if [ -n "$loc_found" ]; then
            log "  [LOCATION] Checking for location-specific page (city: $city)..."
            local loc_mode="${loc_found%%$'\x1f'*}" loc_val="${loc_found#*$'\x1f'}"
            loc_found=""
            if [ "$loc_mode" = "LINK" ]; then
                loc_found="$loc_val"
            else
                local base_origin pattern
                base_origin=$(printf '%s' "${home_final:-$website}" | sed -E 's#^(https?://[^/]+).*#\1#')
                for pattern in "/${loc_val}/" "/locations/${loc_val}/" "/locations/${loc_val}" "/${loc_val}"; do
                    local lf
                    lf=$(web_fetch "${base_origin}${pattern}" "$WEB_DIR/loc.html" 6)
                    if web_real_page "${base_origin}${pattern}" "$lf" "$WEB_DIR/loc.html" "$loc_val"; then
                        loc_found="${lf#* }"
                        break
                    fi
                done
            fi
            if [ -n "$loc_found" ]; then
                log "  [LOCATION] Found: $loc_found"
                log "  [LOCATION] Re-scraping location page: $loc_found"
                # NOTE: Do NOT update venue website — keep the original root URL.
                local loc_summary loc_via loc_n loc_rest
                if loc_summary=$(web_scrape_page location "$loc_found" 10); then
                    IFS=$'\x1f' read -r loc_via loc_n loc_rest <<< "$loc_summary"
                    printf '%s\n' "$loc_found" >> "$rendered_list"
                    log "  [LOCATION] Re-scraped: Emails: ${loc_n:-0}"
                fi
            else
                log "  [LOCATION] No location-specific page found"
            fi
        fi
    fi

    # --- Probe common subpaths that may not be linked from the homepage ---
    local base_url
    base_url=$(printf '%s' "${home_final:-$website}" | sed -E 's#^(https?://[^/]+).*#\1#')
    if [ "$site_shared" != "true" ] && [[ "$base_url" == http* ]]; then
        local known_urls probe probe_fetch probe_dead=0
        known_urls=$(_web_py_web_known "$WEB_DIR/pages.jsonl" "$static_crawl_json")
        for probe in /contact /contact-us /contactus /contact_us /contact.html /get-in-touch /about /about-us /aboutus /about.html /events /private-events /private-dining /weddings /catering /team /our-team /staff /press /book-event /inquiry /enquiry /live-music /wine-club /entertainment; do
            # Skip if already linked or crawled
            if printf '%s\n' "$known_urls" | grep -qF -- "$probe"; then
                continue
            fi
            probe_fetch=$(web_fetch "${base_url}${probe}" "$WEB_DIR/probe.html" 5)
            # A site that stops answering (timeouts, 000) is not worth 25 more requests.
            if [ "${probe_fetch%% *}" = "000" ]; then
                probe_dead=$((probe_dead + 1))
                [ "$probe_dead" -ge 3 ] && { log "  [PROBE] Site stopped answering probes — skipping the rest"; break; }
                continue
            fi
            probe_dead=0
            if web_real_page "${base_url}${probe}" "$probe_fetch" "$WEB_DIR/probe.html" "${probe#/}"; then
                printf '%s\n' "${probe_fetch#* }" >> "$WEB_DIR/probes.txt"
                log "  [PROBE] Found: ${probe_fetch#* }"
                case "$probe" in /contact*|/get-in-touch|/inquiry|/enquiry) log "  [CONTACT] Probing ${probe_fetch#* }" ;; esac
            fi
        done
    fi

    # --- Render queue (PA-9): in-scope pages only, other-location pages skipped,
    # query-string variants collapsed, highest-value pages first, capped. ---
    local queue_stats
    queue_stats=$(_web_py_web_queue "$WEB_DIR/pages.jsonl" "$static_crawl_json" "$WEB_DIR/probes.txt" "$rendered_list" \
        "$site_prefix" "$site_shared" "$site_reg" "${home_final:-$website}" "$location_slug" "$MAX_WEB_PAGES" "$WEB_DIR/queue.txt")
    local q_total q_render q_off q_other q_variants q_junk q_static
    read -r q_total q_render q_off q_other q_variants q_junk q_static <<< "$queue_stats"
    log "  [COVERAGE] Subpage queue: ${q_total:-0} in scope, rendering ${q_render:-0} (cap $MAX_WEB_PAGES); skipped off-scope=${q_off:-0} other-location=${q_other:-0} variants=${q_variants:-0} non-page=${q_junk:-0}"

    # Crawl all queued subpages (nav/header links, keyword links, static-crawl pages, probes)
    local page_count=0 curl_pages=0 chrome_pages=1 blocked_pages=0 subpage sub_via sub_summary
    [ "$home_via" = "curl" ] && chrome_pages=0
    if [ -s "$WEB_DIR/queue.txt" ]; then
        # Highest-value page first, re-ranked after every render so a staff/contact page
        # linked only from a subpage (/about/people -> /about/people/contact) is reached.
        while [ "$page_count" -lt "$MAX_WEB_PAGES" ]; do
            subpage=$(_web_py_web_queue "$WEB_DIR/pages.jsonl" "$static_crawl_json" "$WEB_DIR/probes.txt" "$rendered_list" \
                "$site_prefix" "$site_shared" "$site_reg" "${home_final:-$website}" "$location_slug" "$MAX_WEB_PAGES" -next)
            [ -z "$subpage" ] && break
            printf '%s\n' "$subpage" >> "$rendered_list"
            page_count=$((page_count + 1))
            log "  Crawling subpage ($page_count): $subpage"
            # Chrome render, curl fallback (Wix/Squarespace can render empty in Chrome)
            sub_summary=$(web_scrape_page sub "$subpage" 10) || continue
            local s_n s_fb s_ig s_cf s_has s_state s_len s_nerr s_err s_emails
            IFS=$'\x1f' read -r sub_via s_n s_fb s_ig s_cf s_has s_state s_len s_nerr s_err s_emails <<< "$sub_summary"
            if [ "$sub_via" = "curl" ]; then
                curl_pages=$((curl_pages + 1))
                log "  [CURL FALLBACK] Subpage parsed via curl"
            else
                chrome_pages=$((chrome_pages + 1))
            fi
            [ "$s_state" = "blocked" ] && blocked_pages=$((blocked_pages + 1))
            [ -n "$s_emails" ] && log "  Found on subpage: $s_emails"
            [ "${s_nerr:-0}" != "0" ] && printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $venue_id scrape_js: $subpage: $s_err" >> "$ERR_LOG"
            if [ -z "$fb" ] && [ -n "$s_fb" ]; then fb="$s_fb"; log "  [SOCIAL] Facebook link on subpage: $subpage -> $s_fb"; fi
            if [ -z "$ig" ] && [ -n "$s_ig" ]; then ig="$s_ig"; log "  [SOCIAL] Instagram link on subpage: $subpage -> $s_ig"; fi
            # Contact form: only on contact-type pages, and only a real form.
            if [ -z "$contact_form" ] && [ "$s_has" = "yes" ] && \
               printf '%s' "$subpage" | grep -qiE '/contact|/inquir|/enquir|/get-in-touch|/reach-us|/book.*event|/private.*event|/private.*dining|/plan-your|/request'; then
                contact_form="$subpage"
                cf_confirmed="yes"
                log "  [CONTACT FORM] Found on subpage: $subpage"
            fi
        done
    fi

    # --- PDFs linked from rendered pages (event packets, wedding guides, staff lists) ---
    local pdf_list pdf_url pdf_n=0
    pdf_list=$(_web_py_web_pdfs "$WEB_DIR/pages.jsonl" "$static_crawl_json" "${MAX_WEB_PDFS:-6}")
    if [ -n "$pdf_list" ]; then
        local pdf_src pdf_json
        while IFS=$'\x1f' read -r pdf_url pdf_src <&3; do
            [ -z "$pdf_url" ] && continue
            pdf_json=$(pyrun pdf python3 "${SCRIPT_DIR}/site_discovery.py" pdf "$pdf_url")
            if [ -n "$pdf_json" ]; then
                printf '%s' "$pdf_json" | pyrun pdf python3 -c 'import json,sys; d=json.load(sys.stdin); d["linked_from"]=sys.argv[1]; print(json.dumps(d))' "$pdf_src" >> "$WEB_DIR/pdfs.jsonl"
                pdf_n=$((pdf_n + 1))
                log "  [PDF] $pdf_url → $(printf '%s' "$pdf_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(e.get("email","") for e in d.get("emails",[])) or "no emails")' 2>/dev/null)"
            fi
        done 3<<< "$pdf_list"
    fi

    # --- Decide contacts, socials and contact form from everything seen (P1/P7) ---
    local decisions
    decisions=$(_web_py_web_decide "$SCRIPT_DIR" "$WEB_DIR/pages.jsonl" "$static_crawl_json" "$WEB_DIR/pdfs.jsonl" \
        "$site_prefix" "$site_shared" "$site_reg" "${home_final:-$website}" "$location_slug" "$venue")
    if [ -z "$decisions" ]; then
        log "  [ERROR] Website decision step crashed — contacts from this site were not processed (see $ERR_LOG)"
    fi

    # Socials: never overwrite a different link already on the sheet (P7).
    local save_fb="" save_ig="" fb_reason="" ig_reason="" rej_count=0 kind platform url reason visited="" form_found="" form_rank="" alias_reg="" crawl_flags=""
    while IFS=$'\x1f' read -r kind platform url reason; do
        case "$kind" in
            VISITED) visited="$platform" ;;
            ALIAS) alias_reg="$platform" ;;
            CRAWL) crawl_flags="$platform"; log "  [WARN] Static crawl incomplete: $platform${url:+ ($url)}" ;;
            FORM) form_found="$platform"; form_rank="$url" ;;
            FORMALT) log "  [CONTACT FORM] Also found: $platform" ;;
            SOCIAL)
                if [ "$platform" = "facebook" ]; then save_fb="$url"; fb_reason="$reason"; else save_ig="$url"; ig_reason="$reason"; fi ;;
            SOCIAL_REJECT)
                rej_count=$((rej_count + 1))
                if [ "$rej_count" -le 4 ]; then
                    log "  [REJECT] ${platform} link $url — $reason"
                    echo "FLAG:Website ${platform} link not saved ($reason): $url" >> /tmp/pipeline_flags.txt
                fi ;;
        esac
    done <<< "$decisions"

    local social_saved=0 p_url p_label p_existing p_file resp p_status
    for platform in facebook instagram; do
        if [ "$platform" = "facebook" ]; then
            p_url="$save_fb"; p_label="Facebook"; p_existing="$VENUE_EXISTING_FB"; p_file=/tmp/pipeline_step1_fb.txt; reason="$fb_reason"
        else
            p_url="$save_ig"; p_label="Instagram"; p_existing="$VENUE_EXISTING_IG"; p_file=/tmp/pipeline_step1_ig.txt; reason="$ig_reason"
        fi
        [ -z "$p_url" ] && continue
        if [ -n "$p_existing" ]; then
            if [ "$(printf '%s' "$p_existing" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://(www\.|m\.)?##; s#/+$##')" = \
                 "$(printf '%s' "$p_url" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://(www\.|m\.)?##; s#/+$##')" ]; then
                log "  ✓ $p_label from venue website matches the sheet: $p_url"
                echo "$p_existing" > "$p_file"
                social_saved=$((social_saved + 1))
            else
                log "  [SOCIAL] Sheet already has $p_label $p_existing — website link $p_url not saved (existing links are never overwritten)"
                echo "FLAG:$p_label on sheet ($p_existing) differs from website link ($p_url)" >> /tmp/pipeline_flags.txt
            fi
            continue
        fi
        if [ "$LOAD_EXISTING_OK" != "yes" ]; then
            # Empty only because venue_detail failed: the deployed backend's force=true
            # would overwrite whatever the sheet holds (P7). Step 1B/1C re-read the sheet.
            log "  [SOCIAL] $p_label $p_url not saved — the sheet's current value is unknown (venue_detail failed)"
            echo "FLAG:$p_label found on website but not saved (sheet unreadable): $p_url" >> /tmp/pipeline_flags.txt
            continue
        fi
        # The field is empty, so force only skips the server's name check; our own
        # evidence check (name match, or header/footer on the venue's own site) passed.
        log "  ✓ $p_label from venue website (trusted: $reason): $p_url"
        resp=$(api_get "action=update_venue&venue_id=$(urlenc "$venue_id")&field=${platform}&force=true&value=$(urlenc "$p_url")" 45)
        p_status=$(printf '%s' "$resp" | pyrun update_venue python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("status")=="ok" and d.get("verified",True) else "err:" + str(d.get("reason") or d.get("message") or "")[:120])')
        if [ "$p_status" = "ok" ]; then
            echo "$p_url" > "$p_file"
            social_saved=$((social_saved + 1))
        elif [[ "$p_status" == err:social_exists* ]]; then
            log "  [SOCIAL] Sheet already had a different $p_label — not overwritten"
        else
            log "  [API ERROR] $p_label was found on website but did not persist: $p_url | ${p_status:-no response}"
        fi
    done
    fb="$save_fb"; ig="$save_ig"

    # A real message form / inquiry widget found during the crawl replaces an empty or
    # unconfirmed contact_form; an inquiry form (rank 0: inquiry/RFP page or an inquiry
    # service such as Tripleseat) also beats a general contact form.
    local cf_inquiry="no"
    printf '%s' "$contact_form" | grep -qiE 'inquir|enquir|rfp|tripleseat|perfectvenue|honeybook|eventtemple|jotform|typeform' && cf_inquiry="yes"
    if [ -n "$form_found" ] && [ "$form_found" != "$contact_form" ] && \
       { [ -z "$contact_form" ] || { [ "$cf_confirmed" != "yes" ] && [ "$cf_inquiry" != "yes" ]; } || \
         { [ "$form_rank" = "0" ] && [ "$cf_inquiry" != "yes" ]; }; }; then
        [ -n "$contact_form" ] && log "  [CONTACT FORM] Also found: $contact_form"
        contact_form="$form_found"
        log "  [CONTACT FORM] Found: $contact_form"
    fi
    if [ -n "$contact_form" ] && [ "$contact_form" != "None" ]; then
        if [ -n "$VENUE_EXISTING_FORM" ] && [ "$VENUE_EXISTING_FORM" != "$contact_form" ]; then
            log "  Contact form already on sheet ($VENUE_EXISTING_FORM) — not replaced with $contact_form"
        elif [ "$LOAD_EXISTING_OK" != "yes" ]; then
            log "  Contact form $contact_form not saved — the sheet's current value is unknown (venue_detail failed)"
            echo "FLAG:Contact form found but not saved (sheet unreadable): $contact_form" >> /tmp/pipeline_flags.txt
        elif [ -z "$VENUE_EXISTING_FORM" ]; then
            resp=$(api_get "action=update_venue&venue_id=$(urlenc "$venue_id")&field=contact_form&value=$(urlenc "$contact_form")" 45)
            if printf '%s' "$resp" | grep -q '"status" *: *"ok"'; then
                log "  ✓ Contact form URL saved"
            else
                log "  [API ERROR] Contact form did not persist: $contact_form"
            fi
        fi
    fi

    # The stored website may redirect to another domain (ameliedc.com -> ameliewinebar.com):
    # that domain is the venue's own site, so its addresses are on-domain.
    local final_reg=""
    if [ -n "$home_final" ] && [ "$site_shared" != "true" ]; then
        final_reg=$(pyrun web_final_reg python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import outreach_rules as R; d = R.registrable_domain(sys.argv[2]); print("" if (R.is_shared_domain(d) or R.is_non_venue_host(d)) else d)' "$SCRIPT_DIR" "$home_final")
        [ "$final_reg" = "$site_reg" ] && final_reg=""
        [ -n "$final_reg" ] && log "  [WEB] Website redirects to $final_reg — its addresses count as the venue's own domain"
    fi
    if [ -z "$final_reg" ] && [ -n "$alias_reg" ] && [ "$site_shared" != "true" ]; then
        final_reg="$alias_reg"
        log "  [WEB] The venue's own pages use @$final_reg for its staff — those addresses count as the venue's own domain"
    fi
    # Apollo, LinkedIn and social finds on that domain count too (verify_and_push).
    VENUE_MAIL_ALIAS="$final_reg"
    export VENUE_MAIL_ALIAS

    # Dedupe by email and verify+push each contact with name/title and evidence (C2).
    local drop_n=0 cand_n=0 d_email d_name d_title d_ev d_src saved_domain
    VAP_OUTCOMES_FILE="$WEB_DIR/outcomes.txt"
    : > "$VAP_OUTCOMES_FILE"
    while IFS=$'\x1f' read -r kind d_email d_name d_title d_ev d_src <&3; do
        case "$kind" in
            CONTACT)
                cand_n=$((cand_n + 1))
                if [ -n "$final_reg" ] && [ "${d_email##*@}" = "$final_reg" -o "${d_email##*.$final_reg}" != "$d_email" ]; then
                    saved_domain="$VENUE_DOMAIN"; VENUE_DOMAIN="$final_reg"
                    PUSH_ALLOW_OFF_DOMAIN=true
                    export PUSH_ALLOW_OFF_DOMAIN
                    verify_and_push "$d_email" "$venue_id" "$d_name" "$d_title" "website" "$d_ev"
                    unset PUSH_ALLOW_OFF_DOMAIN
                    VENUE_DOMAIN="$saved_domain"
                else
                    verify_and_push "$d_email" "$venue_id" "$d_name" "$d_title" "website" "$d_ev"
                fi ;;
            DROP)
                # DROP lines: email, reason, page
                drop_n=$((drop_n + 1))
                log "  [REJECT] $d_email — $d_name (found only on $d_title)"
                record_candidate "$d_email" "$venue_id" "" "" "website" "reject:$d_name" "$d_title"
                echo "reject" >> "$VAP_OUTCOMES_FILE" ;;
            WARN)
                log "  [WARN] $d_email" ;;
        esac
    done 3<<< "$decisions"
    local n_saved n_role n_rej n_def n_known n_err n_cand
    n_saved=$(grep -cx saved "$VAP_OUTCOMES_FILE" 2>/dev/null); n_role=$(grep -cx role "$VAP_OUTCOMES_FILE" 2>/dev/null)
    n_rej=$(grep -cx reject "$VAP_OUTCOMES_FILE" 2>/dev/null); n_def=$(grep -cx unverified "$VAP_OUTCOMES_FILE" 2>/dev/null)
    n_known=$(grep -cx known "$VAP_OUTCOMES_FILE" 2>/dev/null); n_err=$(grep -cx error "$VAP_OUTCOMES_FILE" 2>/dev/null)
    n_cand=$(grep -cx candidate "$VAP_OUTCOMES_FILE" 2>/dev/null)
    VAP_OUTCOMES_FILE=""

    # Named decision-makers with no email on the site -> pending contacts (P3: real
    # first + last name and a decision-maker title; region B's saver applies both).
    local p_name p_title p_page pending_n=0 person_n=0
    while IFS=$'\x1f' read -r kind p_name p_title p_page <&3; do
        [ "$kind" = "PERSON" ] || continue
        person_n=$((person_n + 1))
        [ "$person_n" -gt 8 ] && break
        if type _rb_save_pending >/dev/null 2>&1; then
            _rb_save_pending "$venue_id" "$p_name" "$p_title" "website" && pending_n=$((pending_n + 1))
        else
            log "  [CANDIDATE] $p_name ($p_title) named on $p_page — no email; not saved (pending saver unavailable)"
            record_candidate "person:$p_name" "$venue_id" "$p_name" "$p_title" "website" "person_no_email" "$p_page"
        fi
    done 3<<< "$decisions"

    # C3 step result. Curl-only homepage = degraded = failed (Chrome extraction did not run).
    local web_status="empty" found_items=$((cand_n + drop_n + social_saved + person_n))
    [ -n "$contact_form" ] && found_items=$((found_items + 1))
    [ "$found_items" -gt 0 ] && web_status="ok"
    if [ "$home_via" = "static" ] && [ "$crawl_ok" != "yes" ]; then
        step_result "$venue_id" web failed via=none reason=chrome_and_curl_failed http=$home_code form=no visited=none
        return
    fi
    if [ -z "$decisions" ]; then
        web_status="failed"
    elif [ "$home_via" = "static" ]; then
        web_status="failed"
    elif [ "$home_state" = "blocked" ] && { [ "$found_items" -eq 0 ] || [[ "$crawl_flags" == *blocked* ]]; }; then
        web_status="blocked"
    elif [ "$home_via" = "curl" ]; then
        web_status="failed"
    fi
    local missing="" k crawl_note=""
    for k in home contact about events team; do
        case ",${visited}," in *",$k,"*) ;; *) missing="${missing:+$missing,}$k" ;; esac
    done
    if [ "$crawl_ok" != "yes" ]; then crawl_note=" static_crawl=failed"; elif [ -n "$crawl_flags" ]; then crawl_note=" static_crawl=$crawl_flags"; fi
    step_result "$venue_id" web "$web_status" via="$home_via" pages=$((page_count + 1)) visited="${visited:-home}" \
        form=$([ -n "$contact_form" ] && echo yes || echo no) chrome_pages=$chrome_pages curl_pages=$curl_pages \
        static_pages=${q_static:-0} pdfs=$pdf_n emails=$((cand_n + drop_n)) saved=$((n_saved + n_role + n_def)) role=$n_role \
        unverified=$n_def deferred=$n_def rejected=$n_rej candidates=$n_cand known=$n_known errors=$n_err people=$person_n pending=$pending_n \
        fb=$([ -n "$fb" ] && echo 1 || echo 0) ig=$([ -n "$ig" ] && echo 1 || echo 0) blocked_pages=$blocked_pages \
        missing="${missing:-none}"$crawl_note$([ "$chrome_walled" = "yes" ] && echo " chrome_blocked=1 home_via=curl")
}

# web_real_page REQUESTED_URL "CODE FINAL_URL" HTML_FILE KEYWORD — true when a probe
# is a real page: HTTP 200, not redirected home or to a not-found page, keyword
# still in the path, and not byte-identical to the homepage (soft 404).
web_real_page() {
    local req="$1" fetched="$2" file="$3" kw="$4"
    [ "${fetched%% *}" = "200" ] || return 1
    [ -s "$file" ] || return 1
    python3 - "$req" "${fetched#* }" "$file" "$WEB_DIR/home.html" "$kw" 2>>"$ERR_LOG" <<'PYEOF'
import hashlib, re, sys
from urllib.parse import urlsplit
req, final, f, home, kw = sys.argv[1:6]
p = urlsplit(final).path.lower()
if p.strip("/") == "" or re.search(r"notfound|not-found|404|error", final.lower()):
    sys.exit(1)
k = kw.lower().strip("/").split(".")[0].replace("_", "-")
if k and k.split("-")[0] not in p.replace("_", "-"):
    sys.exit(1)
body = open(f, "rb").read()
try:
    if hashlib.md5(body).digest() == hashlib.md5(open(home, "rb").read()).digest():
        sys.exit(1)
except OSError:
    pass
text = body[:200000].decode("utf-8", "replace").lower()
t = re.search(r"<title[^>]*>(.*?)</title>", text, re.S)
if t and re.search(r"\b(404|not found|page not found|cannot be found)\b", t.group(1)):
    sys.exit(1)
sys.exit(0)
PYEOF
}

# =================================================================
# STEP 1B: INSTAGRAM GOOGLE SEARCH FALLBACK
# If Step 1 didn't find an Instagram URL on the website, try Google.
# =================================================================
step1b_ig_search() {
    local venue="$1" venue_id="$2"
    _rb_social_reset "$venue_id"
    # Step 5B reads this file to see which Instagram this run already has, so it
    # is written on every path out of this function (PB-11).
    local ig_check="/tmp/pipeline_ig_check.json" detail="/tmp/pipeline_ig_detail.json"
    rm -f "$ig_check" "$detail"

    # Check temp file first (written by step1 when it finds IG directly)
    local cached_ig=""
    [ -s /tmp/pipeline_step1_ig.txt ] && cached_ig=$(head -1 /tmp/pipeline_step1_ig.txt)
    if [ ${#cached_ig} -gt 5 ]; then
        _rb_write_check "$ig_check" instagram "$cached_ig" "" website
        RB_IG_STATE="website"
        return  # Already found in step1
    fi

    # Check if IG already found (from Step 1 website scrape saved to sheet)
    local current_ig=""
    if _rb_fetch_detail "$venue_id" "$detail"; then
        current_ig=$(_rb_detail_get "$detail" instagram)
    else
        # Without the sheet value a save could overwrite an existing Instagram (P7).
        log "  [API ERROR] venue_detail failed — Instagram search skipped (sheet value unknown)"
        _rb_social_note instagram failed venue_detail
        _rb_write_check "$ig_check" instagram "" "" ""
        return
    fi
    [ "$current_ig" = "None" ] && current_ig=""
    if [ ${#current_ig} -gt 5 ]; then
        _rb_write_check "$ig_check" instagram "$current_ig" "$detail" sheet
        RB_IG_STATE="sheet"
        return  # Already has IG
    fi

    log ""
    log "========== STEP 1B: Instagram Google Search =========="
    log "  No Instagram found on website — Googling..."
    local ig_city
    ig_city=$(_rb_detail_get "$detail" city)
    # City in the query keeps same-name businesses elsewhere off the first results.
    _rb_social_search instagram "$venue" "$venue_id" "$detail" "\"$venue\" ${ig_city:+$ig_city }instagram" "${SCRIPT_DIR}/js/extract_ig.js"
    _rb_write_check "$ig_check" instagram "$RB_PICKED" "$detail" "${RB_PICKED:+google}"
}

# -----------------------------------------------------------------
# Helpers for steps 1B-4 (social, Apollo, LinkedIn)
# -----------------------------------------------------------------
_rb_errlog() {
    local f="${ERR_LOG:-${SCRIPT_DIR}/reports/runs/python-errors.log}"
    [ -d "${f%/*}" ] || mkdir -p "${f%/*}" 2>/dev/null
    printf '%s' "$f"
}

# Run a command with stderr captured; anything it printed goes to ERR_LOG with a
# venue/step prefix (P9), so a crash never reads as "found nothing". Keeps rc.
_rb_py() {
    local tag="$1"; shift
    local errf rc
    errf=$(mktemp "${TMPDIR:-/tmp}/pipeline_rb_err.XXXXXX") || { "$@"; return $?; }
    "$@" 2>"$errf"
    rc=$?
    if [ -s "$errf" ]; then
        awk -v p="$(date '+%Y-%m-%d %H:%M:%S') [${tag}] " '{print p $0}' "$errf" >> "$(_rb_errlog)" 2>/dev/null
    fi
    rm -f "$errf"
    return $rc
}

# C3: one machine-readable result line per venue per step. Args after the
# status are key value pairs; values are squeezed to one token.
_rb_emit_step() {
    local vid="$1" step="$2" status="$3"; shift 3
    local kv="" k v
    while [ $# -ge 2 ]; do
        k="$1"; v=$(printf '%s' "$2" | tr -s ' \t\r\n=' '_'); shift 2
        kv="$kv $k=${v:--}"
    done
    log "[STEP] $vid $step $status$kv"
}

_rb_count_lines() {
    local n=0
    [ -f "$1" ] && n=$(wc -l < "$1" | tr -d ' ')
    printf '%s' "${n:-0}"
}

# URLs and file paths reach AppleScript as arguments, never as source (P10).
_rb_chrome_nav() {
    osascript -e 'on run argv' \
        -e 'tell application "Google Chrome" to set URL of active tab of front window to (item 1 of argv)' \
        -e 'end run' "$1" >/dev/null 2>>"$(_rb_errlog)"
}

# Prints the script's result. Returns 1 when Chrome/JS failed, which is not the
# same as the script finding nothing (empty output, rc 0).
_rb_chrome_js() {
    local out
    out=$(osascript -e 'on run argv' \
        -e 'set js to read (POSIX file (item 1 of argv)) as «class utf8»' \
        -e 'tell application "Google Chrome" to execute active tab of front window javascript js' \
        -e 'end run' "$1" 2>>"$(_rb_errlog)") || return 1
    [ "$out" = "missing value" ] && return 1
    printf '%s' "$out"
}

_rb_active_url() {
    osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null
}

# 0 = the active tab is Google's CAPTCHA ("unusual traffic") or consent page.
_rb_google_blocked() {
    local url title
    url=$(_rb_active_url)
    case "$url" in
        *google.*/sorry/*|*consent.google.*|*google.*/recaptcha/*) return 0 ;;
    esac
    title=$(osascript -e 'tell application "Google Chrome" to get title of active tab of front window' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$title" in
        *"unusual traffic"*|*"before you continue"*|*captcha*) return 0 ;;
    esac
    return 1
}

# Returns 0 ok, 1 Chrome failed, 2 Google blocked the search.
_rb_google_search() {
    local query="$1" enc
    enc=$(_rb_py "google-search" python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$query") || return 1
    _rb_chrome_nav "https://www.google.com/search?q=${enc}" || return 1
    sleep 4
    if _rb_google_blocked; then
        log "  [GOOGLE BLOCKED] CAPTCHA/consent page instead of results for: $query"
        GOOGLE_BLOCKED_HITS=$(( ${GOOGLE_BLOCKED_HITS:-0} + 1 ))
        return 2
    fi
    return 0
}

# venue_detail into FILE; 0 only if it is JSON with status ok.
_rb_fetch_detail() {
    local vid="$1" out="$2"
    curl -sL --max-time 30 -G --data-urlencode "action=venue_detail" --data-urlencode "venue_id=$vid" \
        "$APPS_SCRIPT_URL" -o "$out" 2>>"$(_rb_errlog)" || return 1
    _rb_py "$vid venue_detail" python3 - "$out" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("status") == "ok" and isinstance(d.get("venue"), dict) else 1)
PYEOF
}

# Print venue.<field> from a venue_detail file, one line per field.
_rb_detail_get() {
    local f="$1"; shift
    _rb_py "venue_detail" python3 - "$f" "$@" <<'PYEOF'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("venue") or {}
except (OSError, ValueError):
    v = {}
for k in sys.argv[2:]:
    print(str(v.get(k) or "").replace("\n", " ").strip())
PYEOF
}

# Check file in venue_detail shape ({"venue": {field: value}}) so older readers work.
_rb_write_check() {
    local out="$1" field="$2" value="$3" src="$4" how="$5"
    _rb_py "social-check" python3 - "$out" "$field" "$value" "$src" "$how" <<'PYEOF'
import json, sys
out, field, value, src, how = sys.argv[1:6]
d = {}
if src:
    try:
        d = json.load(open(src))
    except (OSError, ValueError):
        d = {}
if not isinstance(d, dict):
    d = {}
venue = d.get("venue") if isinstance(d.get("venue"), dict) else {}
venue[field] = value
d["venue"] = venue
d["found_this_run"] = bool(value)
d["found_via"] = how or ""
with open(out, "w") as f:
    json.dump(d, f)
PYEOF
}

# update_venue for a social field. No force/overwrite: an existing value is never
# replaced (P7). Returns 0 saved, 2 the sheet already has one (social_exists),
# 3 the server's own evidence check refused it, 1 API failure.
_rb_save_social() {
    local vid="$1" field="$2" url="$3" resp ok
    resp=$(curl -sL --max-time 30 -G \
        --data-urlencode "action=update_venue" --data-urlencode "venue_id=$vid" \
        --data-urlencode "field=$field" --data-urlencode "value=$url" \
        "$APPS_SCRIPT_URL" 2>>"$(_rb_errlog)")
    ok=$(printf '%s' "$resp" | _rb_py "$vid save-$field" python3 -c 'import json, sys
d = json.load(sys.stdin)
r = str(d.get("reason") or "")
if d.get("status") == "ok" and d.get("verified", True) is not False:
    print("yes")
elif r == "social_exists":
    print("exists")
elif r in ("social_mismatch", "social_invalid") or "does not match" in str(d.get("message") or ""):
    print("refused")
else:
    print("no")')
    case "$ok" in
        yes) return 0 ;;
        exists)
            log "  [SOCIAL EXISTS] Sheet already has a different $field — not replaced ($url kept as candidate)"
            _rb_record_social_candidate "$vid" "$field" "$url" "reject:social_exists"
            return 2 ;;
        refused)
            log "  [SOCIAL REJECTED] Server refused $url: $(printf '%s' "$resp" | head -c 200)"
            _rb_record_social_candidate "$vid" "$field" "$url" "reject:server_social_check"
            return 3 ;;
    esac
    log "  [API ERROR] $field URL did not persist: $url | $(printf '%s' "$resp" | head -c 200)"
    echo "FLAG:$field found but not saved to sheet: $url ($(printf '%s' "$resp" | head -c 120))" >> /tmp/pipeline_flags.txt
    return 1
}

# Candidate-log rows for non-email finds (same file and keys as record_candidate,
# plus kind/value), so the report can list what was found but not saved.
_rb_record_candidate_row() {   # venue_id kind value name title source disposition
    [ -n "${CANDIDATE_LOG:-}" ] || return 0
    CANDIDATE_LOG="$CANDIDATE_LOG" _rb_py "$1 candidate" python3 - "$@" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
vid, kind, value, name, title, source, disposition = sys.argv[1:8]
row = {"timestamp": datetime.now(timezone.utc).isoformat(), "venue_id": vid, "kind": kind,
       "value": value, "email": "", "name": name, "title": title, "source": source,
       "disposition": disposition, "evidence_url": value if kind in ("facebook", "instagram") else ""}
with open(os.environ["CANDIDATE_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF
}
_rb_record_social_candidate() {
    local src="ig_search"; [ "$2" = "facebook" ] && src="fb_search"
    _rb_record_candidate_row "$1" "$2" "$3" "" "" "$src" "$4"
}

# Per-venue social state, reported in one [STEP] social line by step2_social.
_rb_social_reset() {
    RB_SOCIAL_VID="$1"
    RB_SOCIAL_EMITTED=""
    RB_SOCIAL_NOTES=""
    RB_IG_STATE="not_run"
    RB_FB_STATE="not_run"
    RB_PICKED=""
}

_rb_social_note() {   # part status detail
    RB_SOCIAL_NOTES="${RB_SOCIAL_NOTES} $1=$2:$3"
    case "$1" in
        instagram) RB_IG_STATE="$2:$3" ;;
        facebook) RB_FB_STATE="$2:$3" ;;
    esac
}

# Pick the Google candidate that is this venue's own account (P7). The
# extractors return a JSON array (new) or one / pipe-joined URL (old).
# Prints COUNT/BEST/REJECT lines separated by \x1f.
_rb_pick_social() {
    local kind="$1" venue="$2" detail="$3" raw="$4" venue_id="$5"
    SCRIPT_DIR="$SCRIPT_DIR" RB_VENUE_DOMAIN="${VENUE_DOMAIN:-}" RB_CANDIDATE_LOG="${CANDIDATE_LOG:-}" RB_VENUE_ID="$venue_id" \
    _rb_py "$venue_id pick-$kind" python3 - "$kind" "$venue" "$detail" "$raw" <<'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import outreach_rules as R

kind, venue, detail_path, raw = sys.argv[1:5]
US = "\x1f"
city = state = ""
try:
    v = json.load(open(detail_path)).get("venue") or {}
    city, state = v.get("city") or "", v.get("state") or ""
except (OSError, ValueError, AttributeError):
    pass

raw = (raw or "").strip()
cands = []
if raw.startswith("["):
    try:
        cands = [str(x).strip() for x in json.loads(raw) if str(x).strip()]
    except ValueError:
        cands = []
elif raw and raw != "missing value":
    cands = [p.strip() for p in raw.split("|") if p.strip()]

site = "facebook" if kind == "facebook" else "instagram"
NON_PAGE = {"p", "pg", "pages", "people", "groups", "group", "events", "event", "sharer",
            "share", "dialog", "plugins", "login", "help", "watch", "marketplace", "hashtag",
            "search", "photo", "photos", "videos", "reel", "reels", "stories", "explore",
            "accounts", "about", "directory", "developer", "legal", "tv", "embed", "direct",
            "privacy", "terms", "policies", "settings", "business", "ads", "tr", "home",
            "gaming", "story", "permalink", "notifications", "messages", "l", "r", "web"}

def handle_of(url):
    m = re.match(r"^https?://(?:[a-z0-9-]+\.)?(facebook|instagram)\.com/([^?#]*)", url, re.I)
    if not m or m.group(1).lower() != site:
        return None, "not a %s.com URL" % site
    parts = [p for p in m.group(2).split("/") if p]
    if site == "facebook" and parts and parts[0].lower() == "pg":
        parts = parts[1:]
    if not parts:
        return None, "no page handle"
    h = parts[0]
    if h.lower() in NON_PAGE or h.lower().endswith(".php"):
        return None, "not a venue page (%s)" % h
    if not re.fullmatch(r"[A-Za-z0-9._-]{2,80}", h) or re.fullmatch(r"[\d._-]+", h):
        return None, "not a venue page (%s)" % h
    return h, ""

STOP = {"the", "a", "an", "and", "of", "at", "in", "by", "on", "for", "to"}
GENERIC = set(getattr(R, "_GENERIC_VENUE_WORDS", set())) | {
    "official", "hq", "usa", "us", "restaurants", "hotels", "resorts", "bars", "group",
    "co", "llc", "inc", "page", "events", "dc", "va", "md"}
STATES = {"dc", "va", "md", "virginia", "maryland", "districtofcolumbia", "nova", "dmv"}
ABBREV = {"cc", "gc", "yc", "hq"}  # country / golf / yacht club

def words(s):
    s = (s or "").lower().replace("&", " and ")
    s = re.sub(r"[\x27\u2019\x60]", "", s)
    return re.findall(r"[a-z0-9]+", s)

vwords = words(venue)
vd = [w for w in vwords if w not in STOP and w not in GENERIC and len(w) >= 3]
brand = ""
vdom = os.environ.get("RB_VENUE_DOMAIN", "")
if vdom and R.is_shared_domain(vdom):
    brand = R.registrable_domain(vdom).split(".")[0]
vocab = {w for w in set(vwords) | set(words(city)) | set(words(state)) | STATES | ABBREV | GENERIC | STOP
         if len(w) >= 2 and not w.isdigit()}

def segment(h):
    """Cover the handle with venue/location/generic words; return (words used, uncovered chars)."""
    n = len(h)
    best = [None] * (n + 1)
    best[0] = (0, [])
    for i in range(n):
        if best[i] is None:
            continue
        cov, used = best[i]
        if best[i + 1] is None or best[i + 1][0] < cov:
            best[i + 1] = (cov, used)
        for w in vocab:
            if h.startswith(w, i):
                j = i + len(w)
                if best[j] is None or best[j][0] < cov + len(w):
                    best[j] = (cov + len(w), used + [w])
    cov, used = best[n]
    return used, n - cov

def judge(h):
    hs = re.sub(r"[^a-z]", "", h.lower())
    if len(hs) < 3:
        return False, 0.0, "handle too short", False
    used, left = segment(hs)
    covered = {w for w in used if w in vd}
    partial = bool(covered)
    if left > 1:
        return False, 0.0, "handle has %d chars that are not the venue name" % left, partial
    if brand and covered and covered <= {brand}:
        return False, 0.0, "chain/brand account (%s), not this property" % brand, partial
    if vd:
        if not R.org_name_matches(" ".join(used), " ".join(vwords)):
            return False, 0.0, "handle doesn't match venue name", partial
        score = len(covered) / len(vd)
    else:
        need = {w for w in vwords if w not in STOP}
        if not need or not need <= set(used):
            return False, 0.0, "handle doesn't match venue name", partial
        score = 1.0
    return True, score - 0.1 * left, "ok", partial

def record(url, reason):
    path = os.environ.get("RB_CANDIDATE_LOG")
    if not path:
        return
    row = {"timestamp": datetime.now(timezone.utc).isoformat(), "venue_id": os.environ.get("RB_VENUE_ID", ""),
           "kind": site, "value": url, "email": "", "name": "", "title": "",
           "source": ("fb" if site == "facebook" else "ig") + "_search", "disposition": "reject:" + reason, "evidence_url": ""}
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

best, best_score, seen = "", -1.0, set()
print("COUNT" + US + str(len(cands)))
for url in cands:
    h, why = handle_of(url)
    if not h:
        print(US.join(["REJECT", url, why]))
        continue
    canon = "https://www.%s.com/%s/" % (site, h)
    if canon.lower() in seen:
        continue
    seen.add(canon.lower())
    ok, score, why, partial = judge(h)
    if not ok:
        print(US.join(["REJECT", canon, "handle '%s': %s" % (h.lower(), why)]))
        if partial:
            record(canon, why)
        continue
    if score > best_score:
        best, best_score = canon, score
if best:
    print(US.join(["BEST", best, "%.2f" % best_score]))
PYEOF
}

# Google "<venue> instagram|facebook", pick the venue's own account, save it.
# Sets RB_PICKED to the chosen URL ('' when none).
_rb_social_search() {
    local kind="$1" venue="$2" venue_id="$3" detail="$4" query="$5" jsfile="$6"
    local tag label short
    if [ "$kind" = "instagram" ]; then tag="IG SEARCH"; label="Instagram"; short="ig"; else tag="FB SEARCH"; label="Facebook"; short="fb"; fi
    RB_PICKED=""
    local rc raw picked
    _rb_google_search "$query"; rc=$?
    if [ $rc -eq 2 ]; then
        log "  [$tag] Google blocked the search — $label NOT searched"
        _rb_social_note "$kind" blocked google_captcha
        return
    elif [ $rc -ne 0 ]; then
        log "  [$tag] Chrome could not open the Google search — $label NOT searched"
        _rb_social_note "$kind" failed chrome
        return
    fi
    if ! raw=$(_rb_chrome_js "$jsfile"); then
        log "  [$tag] Chrome JavaScript failed on the results page — $label NOT searched"
        _rb_social_note "$kind" failed chrome_js
        return
    fi
    if ! picked=$(_rb_pick_social "$kind" "$venue" "$detail" "$raw" "$venue_id"); then
        log "  [$tag] Candidate check crashed (see python-errors.log) — $label not saved"
        _rb_social_note "$kind" failed pick_crash
        return
    fi
    local n=0 best="" tagl url why
    while IFS=$'\x1f' read -r tagl url why; do
        case "$tagl" in
            COUNT) n="$url" ;;
            BEST) best="$url" ;;
            REJECT) log "  [$tag] Skipping $url — $why" ;;
        esac
    done < <(printf '%s\n' "$picked")
    if [ -n "$best" ]; then
        log "  [$tag] Found: $best"
        _rb_save_social "$venue_id" "$kind" "$best"; rc=$?
        if [ $rc -eq 0 ]; then
            log "  ✓ $label URL saved"
            _rb_social_note "$kind" ok "found_of_$n"
        elif [ $rc -eq 1 ]; then
            _rb_social_note "$kind" failed save_error
        else
            _rb_social_note "$kind" empty "server_refused_$rc"
        fi
        # Remember it for step 2 and step 5B unless the server said it isn't ours
        # (a plain API failure still counts: the account passed our own check).
        if [ $rc -le 1 ]; then
            echo "$best" > "/tmp/pipeline_step1_${short}.txt"
            RB_PICKED="$best"
        fi
    elif [ "${n:-0}" -gt 0 ] 2>/dev/null; then
        log "  [$tag] No handle matched venue name — rejecting all candidates ($n)"
        _rb_social_note "$kind" empty "rejected_$n"
    else
        log "  [$tag] No $label found via Google"
        _rb_social_note "$kind" empty none
    fi
}

# Google "<query>", read emails from the result snippets into RB_SNIPPET_OUT.
# Returns 0 ok (maybe empty), 1 Chrome failed, 2 Google blocked.
_rb_snippet_search() {
    local tag="$1" query="$2" rc out dom js="/tmp/pipeline_snippet_run.js"
    RB_SNIPPET_OUT=""
    _rb_google_search "$query"; rc=$?
    if [ $rc -eq 2 ]; then log "  [$tag] Google blocked the search — snippet NOT checked"; return 2; fi
    if [ $rc -ne 0 ]; then log "  [$tag] Chrome could not open the Google search"; return 1; fi
    # The extractor keeps only addresses on this domain (or free-mail) when the
    # global is set, so other businesses in the results can't leak in (PB-13).
    # The value is embedded only after it matched a strict hostname pattern.
    dom=$(printf '%s' "${VENUE_DOMAIN:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
    printf '%s' "$dom" | grep -qE '^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' || dom=""
    { printf "window.__outreachVenueDomain = '%s';\n" "$dom"; cat "${SCRIPT_DIR}/js/extract_email_from_snippet.js"; } > "$js"
    if ! out=$(_rb_chrome_js "$js"); then log "  [$tag] Chrome JavaScript failed on the results page"; return 1; fi
    RB_SNIPPET_OUT="$out"
    if [ -n "$out" ]; then log "  [$tag] Found: $out"; else log "  [$tag] No email in Google snippet"; fi
    return 0
}

# 0 = Facebook bounced us to a login/checkpoint page.
_rb_facebook_walled() {
    case "$(_rb_active_url)" in
        *facebook.com/login*|*facebook.com/checkpoint*|*/login.php*|*facebook.com/r.php*) return 0 ;;
    esac
    return 1
}

# =================================================================
# STEP 1C: FACEBOOK GOOGLE SEARCH FALLBACK
# If Step 1 didn't find a Facebook URL on the website, try Google.
# =================================================================
step1c_fb_search() {
    local venue="$1" venue_id="$2"
    [ "${RB_SOCIAL_VID:-}" = "$venue_id" ] || _rb_social_reset "$venue_id"
    local fb_check="/tmp/pipeline_fb_check.json" detail="/tmp/pipeline_fb_detail.json"
    rm -f "$fb_check" "$detail"

    # Check temp file first (written by step1 when it finds FB directly)
    local cached_fb=""
    [ -s /tmp/pipeline_step1_fb.txt ] && cached_fb=$(head -1 /tmp/pipeline_step1_fb.txt)
    if [ ${#cached_fb} -gt 5 ]; then
        _rb_write_check "$fb_check" facebook "$cached_fb" "" website
        RB_FB_STATE="website"
        return  # Already found in step1
    fi

    # Check if FB already found (from Step 1 website scrape saved to sheet)
    local current_fb=""
    if _rb_fetch_detail "$venue_id" "$detail"; then
        current_fb=$(_rb_detail_get "$detail" facebook)
    else
        # Without the sheet value a save could overwrite an existing Facebook (P7).
        log "  [API ERROR] venue_detail failed — Facebook search skipped (sheet value unknown)"
        _rb_social_note facebook failed venue_detail
        _rb_write_check "$fb_check" facebook "" "" ""
        return
    fi
    [ "$current_fb" = "None" ] && current_fb=""
    if [ ${#current_fb} -gt 5 ]; then
        _rb_write_check "$fb_check" facebook "$current_fb" "$detail" sheet
        RB_FB_STATE="sheet"
        return  # Already has FB
    fi

    log ""
    log "========== STEP 1C: Facebook Google Search =========="
    log "  No Facebook found on website — Googling..."
    local fb_city
    fb_city=$(_rb_detail_get "$detail" city)
    _rb_social_search facebook "$venue" "$venue_id" "$detail" "\"$venue\" ${fb_city:+$fb_city }facebook" "${SCRIPT_DIR}/js/extract_fb.js"
    _rb_write_check "$fb_check" facebook "$RB_PICKED" "$detail" "${RB_PICKED:+google}"
    # The old curl slug probe (facebook.com/<venue-slug>) is gone: it always hit the
    # login wall and the few "matches" were same-name businesses abroad (EVID-19/PB-9).
}

# =================================================================
# STEP 2: SOCIAL MEDIA SCRAPE
# =================================================================
step2_social() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 2: Social Media Scrape =========="
    [ "${RB_SOCIAL_VID:-}" = "$venue_id" ] || _rb_social_reset "$venue_id"
    local count_before deferred_before
    count_before=$(_rb_count_lines /tmp/pipeline_contacts_count)
    deferred_before=$(_rb_count_lines /tmp/pipeline_deferred_count)

    local fb="" ig="" parsed
    local social_tmpf="/tmp/pipeline_social_venue.json"
    rm -f "$social_tmpf"
    if _rb_fetch_detail "$venue_id" "$social_tmpf"; then
        parsed=$(_rb_detail_get "$social_tmpf" facebook instagram)
        fb=$(printf '%s\n' "$parsed" | sed -n 1p)
        ig=$(printf '%s\n' "$parsed" | sed -n 2p)
    else
        log "  [API ERROR] venue_detail failed — using this run's temp files for FB/IG"
        _rb_social_note venue_detail failed api
    fi
    [ "$fb" = "None" ] && fb=""
    [ "$ig" = "None" ] && ig=""
    # Fall back to temp files written by step1/1B/1C (catches case where update_venue failed)
    if [ ${#fb} -le 5 ] && [ -s /tmp/pipeline_step1_fb.txt ]; then fb=$(head -1 /tmp/pipeline_step1_fb.txt); fi
    if [ ${#ig} -le 5 ] && [ -s /tmp/pipeline_step1_ig.txt ]; then ig=$(head -1 /tmp/pipeline_step1_ig.txt); fi
    if [ -n "$fb" ] && ! printf '%s' "$fb" | grep -qiE '^https?://([a-z0-9-]+\.)?facebook\.com/[^[:space:]]+$'; then
        log "  [WARN] Ignoring facebook value that is not a facebook.com page URL: $fb"
        fb=""
    fi
    if [ -n "$ig" ] && ! printf '%s' "$ig" | grep -qiE '^https?://([a-z0-9-]+\.)?instagram\.com/[A-Za-z0-9._]+/?([?#].*)?$'; then
        log "  [WARN] Ignoring instagram value that is not an instagram.com profile URL: $ig"
        ig=""
    fi
    case "$fb" in *profile.php*) ;; *) fb="${fb%%[?#]*}" ;; esac

    log "  FB: ${fb:-none} | IG: ${ig:-none}"

    # Scrape emails by opening pages in Chrome (JS renders, emails visible).
    # Only operational mailboxes are dropped here; role inboxes (info@, events@...)
    # go on to verify_and_push, which applies P1 and logs them as candidates.
    cat > /tmp/social_scrape_emails.js << 'JSEOF'
(function(){
var junk = ['wix.com','wixpress','wordpress','sentry','cloudflare','example.com','squarespace','shopify','mailchimp','googleapis','google.com','gstatic','facebook','fbcdn','instagram','twitter','hubspot','sendgrid','zendesk'];
var hardReject = /^((noreply|no-reply|no_reply|donotreply|do-not-reply|webmaster|billing|dataremoval|privacy|careers|mailer-daemon|postmaster|unsubscribe|optout|emailoptout)[a-z0-9._-]*|jobs|hr)@/;
var badTld = {png:1, jpg:1, jpeg:1, gif:1, webp:1, svg:1, css:1, js:1, read:1, html:1, htm:1, php:1, pdf:1, json:1, xml:1, txt:1};
var trailing = {read:1, more:1, see:1, view:1, call:1, visit:1, book:1, open:1, menu:1, hours:1, learn:1, click:1, follow:1, contact:1, email:1, phone:1, tel:1, website:1, message:1, send:1};
var text = (document.body && document.body.innerText) || '';
var re = /[A-Za-z0-9][A-Za-z0-9._%+\-]*@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,24}(?![A-Za-z0-9])/g;
var raw = text.match(re) || [];
var links = document.querySelectorAll('a[href^="mailto:"]');
for (var k = 0; k < links.length; k++) {
    var m = (links[k].getAttribute('href') || '').replace(/^mailto:/i, '').split('?')[0].trim();
    try { m = decodeURIComponent(m); } catch (e) {}
    if (m) raw.push(m);
}
var out = [];
for (var i = 0; i < raw.length; i++) {
    var at = raw[i].indexOf('@');
    if (at < 1) continue;
    var local = raw[i].slice(0, at), labels = raw[i].slice(at + 1).split('.');
    // "info@x.com.Read more" is info@x.com, not info@x.com.read
    while (labels.length > 2) {
        var last = labels[labels.length - 1], rest = labels.slice(0, -1).join('.');
        if (trailing[last.toLowerCase()] || (/^[A-Z]/.test(last) && rest === rest.toLowerCase())) labels.pop(); else break;
    }
    var e = (local + '@' + labels.join('.')).toLowerCase();
    var dom = labels.join('.').toLowerCase();
    if (e.length >= 60 || hardReject.test(e) || badTld[labels[labels.length - 1].toLowerCase()]) continue;
    var bad = false;
    for (var j = 0; j < junk.length; j++) { if (dom.indexOf(junk[j]) > -1) { bad = true; break; } }
    if (!bad && out.indexOf(e) === -1) out.push(e);
}
return out.join('|');
})()
JSEOF

    local SOCIAL_EMAILS="" SNIPPET_EMAILS="" fb_pages=0 ig_pages=0 snippets=0 out rc

    # Facebook — try main page and /about
    local fb_found_email=0 fb_path fb_url
    if [ -n "$fb" ]; then
        for fb_path in "" "/about" "/directory_contact_info"; do
            case "$fb" in *profile.php*) [ -n "$fb_path" ] && continue ;; esac
            fb_url="${fb%/}${fb_path}"
            log "  Opening FB: $fb_url"
            if ! _rb_chrome_nav "$fb_url"; then
                log "  [FB] Chrome could not open $fb_url"
                _rb_social_note fb_page failed chrome
                break
            fi
            sleep 5
            if _rb_facebook_walled; then
                log "  [FB] Login wall on $fb_url — page not readable"
                _rb_social_note fb_page blocked login_wall
                break
            fi
            if ! out=$(_rb_chrome_js /tmp/social_scrape_emails.js); then
                log "  [FB] Chrome JavaScript failed on $fb_url"
                _rb_social_note fb_page failed chrome_js
                break
            fi
            fb_pages=$((fb_pages + 1))
            if [ -n "$out" ]; then
                log "  FB emails found: $out"
                SOCIAL_EMAILS="${SOCIAL_EMAILS}|${out}"
                fb_found_email=1
            fi
        done
        if [ "$fb_found_email" = "0" ]; then
            # Facebook DOM may not render email — fall back to Google snippet
            log "  [FB] No email on page — trying Google snippet..."
            _rb_snippet_search "FB SNIPPET" "\"$venue\" facebook"; rc=$?
            [ $rc -eq 0 ] && snippets=$((snippets + 1))
            case $rc in
                0) SNIPPET_EMAILS="${SNIPPET_EMAILS}|${RB_SNIPPET_OUT}" ;;
                2) _rb_social_note fb_snippet blocked google_captcha ;;
                *) _rb_social_note fb_snippet failed chrome ;;
            esac
        fi
    fi

    # Instagram
    if [ -n "$ig" ]; then
        log "  Opening IG: $ig"
        if ! _rb_chrome_nav "$ig"; then
            log "  [IG] Chrome could not open $ig"
            _rb_social_note ig_page failed chrome
        else
            sleep 5
            if ! out=$(_rb_chrome_js /tmp/social_scrape_emails.js); then
                log "  [IG] Chrome JavaScript failed on $ig"
                _rb_social_note ig_page failed chrome_js
                out=""
            else
                ig_pages=1
            fi
            if [ -n "$out" ]; then
                log "  IG emails found: $out"
                SOCIAL_EMAILS="${SOCIAL_EMAILS}|${out}"
            else
                # Instagram DOM doesn't render bio emails — fall back to Google snippet
                log "  [IG] No email on page — trying Google snippet..."
                _rb_snippet_search "IG SNIPPET" "\"$venue\" instagram"; rc=$?
                [ $rc -eq 0 ] && snippets=$((snippets + 1))
                case $rc in
                    0) SNIPPET_EMAILS="${SNIPPET_EMAILS}|${RB_SNIPPET_OUT}" ;;
                    2) _rb_social_note ig_snippet blocked google_captcha ;;
                    *) _rb_social_note ig_snippet failed chrome ;;
                esac
            fi
        fi
    fi

    # Dedupe and verify+push each email. Social pages are not the venue's own
    # site, so the evidence is 'external' (C2).
    local email n_emails=0 page_list
    page_list=$(printf '%s\n' "$SOCIAL_EMAILS" | tr '|' '\n' | sort -u)
    while read -r email <&7; do
        [ -n "$email" ] || continue
        n_emails=$((n_emails + 1))
        verify_and_push "$email" "$venue_id" "" "" "social" "external"
    done 7< <(printf '%s\n' "$page_list")
    # Without a venue domain nothing ties a snippet address to this venue.
    while read -r email <&7; do
        [ -n "$email" ] || continue
        printf '%s\n' "$page_list" | grep -qxF "$email" && continue
        n_emails=$((n_emails + 1))
        if [ -n "${VENUE_DOMAIN:-}" ]; then
            verify_and_push "$email" "$venue_id" "" "" "social" "external"
        else
            log "  [CANDIDATE] $email — Google snippet, venue has no domain to match; not saved"
            record_candidate "$email" "$venue_id" "" "" "social" "reject:snippet_no_venue_domain"
        fi
    done 7< <(printf '%s\n' "$SNIPPET_EMAILS" | tr '|' '\n' | sort -u)

    # One [STEP] social line per venue; a re-run from step 5B doesn't add another.
    [ "${RB_SOCIAL_EMITTED:-}" = "$venue_id" ] && return
    RB_SOCIAL_EMITTED="$venue_id"
    local saved deferred status
    saved=$(( $(_rb_count_lines /tmp/pipeline_contacts_count) - count_before ))
    deferred=$(( $(_rb_count_lines /tmp/pipeline_deferred_count) - deferred_before ))
    case "$RB_SOCIAL_NOTES" in
        *=blocked:*) status="blocked" ;;
        *=failed:*) status="failed" ;;
        *) if [ -n "$fb$ig" ] || [ $((saved + deferred)) -gt 0 ]; then status="ok"; else status="empty"; fi ;;
    esac
    local problems
    problems=$(printf '%s' "$RB_SOCIAL_NOTES" | tr ' ' '\n' | grep -E '=(blocked|failed):' | tr '=\n' ':,' | sed 's/,$//')
    _rb_emit_step "$venue_id" social "$status" \
        fb "$([ -n "$fb" ] && echo found || echo none)" ig "$([ -n "$ig" ] && echo found || echo none)" \
        fb_search "$RB_FB_STATE" ig_search "$RB_IG_STATE" fb_pages "$fb_pages" ig_pages "$ig_pages" snippets "$snippets" \
        emails "$n_emails" saved "$saved" deferred "$deferred" ${problems:+problems "$problems"}
}

# =================================================================
# STEP 3: APOLLO API (search company → find people → enrich emails)
# =================================================================
step3_apollo_api() {
    local venue="$1" venue_id="$2" website_url="$3" city="$4"
    log ""
    log "========== STEP 3: Apollo API =========="
    # Never let the previous venue's domain leak into Step 3b / Step 4 (PB-17).
    APOLLO_DOMAIN=""
    rm -f /tmp/pipeline_apollo_verdict /tmp/pipeline_apollo_company.json /tmp/pipeline_people.json
    _rb_apollo_credits_sync

    if [ -z "$APOLLO_API_KEY" ]; then
        log "  [ERROR] APOLLO_API_KEY not set. Skipping."
        echo "skipped:no_api_key" > /tmp/pipeline_apollo_verdict
        _rb_emit_step "$venue_id" apollo skipped reason no_api_key
        return
    fi
    [ "$website_url" = "None" ] && website_url=""
    [ "$city" = "None" ] && city=""

    local count_before deferred_before credits_before
    count_before=$(_rb_count_lines /tmp/pipeline_contacts_count)
    deferred_before=$(_rb_count_lines /tmp/pipeline_deferred_count)
    credits_before="$APOLLO_CREDITS_USED"
    RB_APOLLO_ENRICHED=0
    RB_APOLLO_PENDING=0

    # A. Find the company: domain lookup AND name search, then the org gate
    #    (org-matches on the name AND same registrable domain or same city).
    log "  Searching Apollo for company: $venue"
    local detail="/tmp/pipeline_domain_lookup.json"
    rm -f "$detail"
    _rb_fetch_detail "$venue_id" "$detail" || log "  [WARN] venue_detail failed — org gate uses the passed website/city only"

    local apollo_co_tmpf="/tmp/pipeline_apollo_company.json" rc
    RB_VENUE_NAME="$venue" RB_VENUE_ID="$venue_id" RB_WEBSITE="${website_url:-${VENUE_WEBSITE:-}}" RB_CITY="$city" \
    RB_DETAIL="$detail" RB_SHARED="${VENUE_SHARED_DOMAIN:-}" SCRIPT_DIR="$SCRIPT_DIR" \
    APOLLO_API_KEY="$APOLLO_API_KEY" APOLLO_API_BASE="$APOLLO_API_BASE" \
        _rb_py "$venue_id apollo-org" python3 - > "$apollo_co_tmpf" <<'PYEOF'
import json, os, re, sys, unicodedata
import requests
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import outreach_rules as R

API = os.environ["APOLLO_API_BASE"]
HEADERS = {"Content-Type": "application/json", "x-api-key": os.environ["APOLLO_API_KEY"]}
venue_name = os.environ.get("RB_VENUE_NAME", "").strip()
website = os.environ.get("RB_WEBSITE", "").strip()
venue_city = os.environ.get("RB_CITY", "").strip()
try:
    v = json.load(open(os.environ.get("RB_DETAIL", ""))).get("venue") or {}
except (OSError, ValueError, AttributeError):
    v = {}
website = website or (v.get("website") or "").strip()
venue_city = venue_city or (v.get("city") or "").strip()
venue_state = (v.get("state") or "").strip()
if not venue_state:
    m = re.match(r"^([A-Z]{2})-", os.environ.get("RB_VENUE_ID", ""))
    venue_state = m.group(1) if m else ""

vreg = ""
if website and website != "None" and not R.is_non_venue_host(website):
    vreg = R.registrable_domain(website)
shared = bool(vreg) and (vreg in R.SHARED_BRAND_DOMAINS or os.environ.get("RB_SHARED") == "true")
# The venue's own mail domain when it differs from the website's (found by the web step).
mail_alias = os.environ.get("VENUE_MAIL_ALIAS", "").strip().lower()
if not vreg or shared or mail_alias == vreg:
    mail_alias = ""


class ApolloError(Exception):
    pass


def call(method, path, missing_ok=(), **kw):
    try:
        r = requests.request(method, API + path, headers=HEADERS, timeout=25, **kw)
    except requests.RequestException as e:
        raise ApolloError("network_" + type(e).__name__)
    if r.status_code in missing_ok:
        return {}
    if r.status_code != 200:
        print("%s %s -> HTTP %s: %s" % (method, path, r.status_code, r.text[:300]), file=sys.stderr)
        raise ApolloError("http_%s" % r.status_code)
    try:
        return r.json()
    except ValueError:
        raise ApolloError("bad_json")


# Strip hotel brand suffixes that confuse Apollo search
brand_suffixes = [
    r'\s*-?\s*by\s+(ihg|hilton|marriott|hyatt|wyndham|accor|choice|best western|radisson)\b',
    r'\s*-?\s*(vignette|curio|tapestry|tribute|autograph)\s+collection\b',
    r'\s*-?\s*,?\s*(a|an)\s+(ihg|hilton|marriott|hyatt)\s+hotel\b',
]


def strip_brand(name):
    cleaned = name
    for pat in brand_suffixes:
        cleaned = re.sub(pat, '', cleaned, flags=re.IGNORECASE)
    return cleaned.strip(' -,')


clean_name = strip_brand(venue_name)

chain_keywords = ['intercontinental', 'ihg', 'hilton worldwide', 'marriott international',
                  'hyatt hotels', 'wyndham', 'accor', 'choice hotels', 'best western',
                  'radisson', 'aimbridge hospitality', 'highgate hotels', 'sonesta international',
                  'clubcorp', 'davidson hospitality', 'sage hospitality', 'hhm hospitality']
chain_names = {'invited', 'invited clubs', 'sonesta', 'marriott', 'hilton', 'hyatt', 'aramark',
               'sodexo', 'compass group', "maggiano's little italy", 'maggianos little italy'}


def is_chain(name):
    n = (name or "").lower().strip()
    return n in chain_names or any(kw in n for kw in chain_keywords)


STATE_ABBR = {"district of columbia": "DC", "washington dc": "DC", "maryland": "MD",
              "virginia": "VA", "west virginia": "WV", "pennsylvania": "PA", "delaware": "DE"}


def norm_state(s):
    s = re.sub(r"[^a-z ]", "", (s or "").lower()).strip()
    return s.upper() if len(s) == 2 else STATE_ABBR.get(s, s.upper())


def norm_city(s):
    s = re.sub(r"[^a-z ]", "", (s or "").lower()).strip()
    return re.sub(r"^(city|town) of ", "", s)


def loc_match(org):
    oc, vc = norm_city(org.get("city")), norm_city(venue_city)
    if not oc or not vc or oc != vc:
        return False
    os_, vs = norm_state(org.get("state")), norm_state(venue_state)
    return not (os_ and vs and os_ != vs)


def fold(s):
    # "Lutèce" and "Lutece" are the same name.
    return unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()


def norm_name(s):
    return re.sub(r"^the", "", re.sub(r"[^a-z0-9]", "", fold(s).lower().replace("&", "and")))


def org_domain(org):
    d = org.get("primary_domain") or org.get("domain") or org.get("website_url") or ""
    return R.registrable_domain(d) if d else ""


def org_id_of(org):
    return org.get("organization_id") or org.get("id") or ""


def gate(org):
    """Same business? Name must match AND (same registrable domain, or same city)."""
    name = (org.get("name") or "").strip()
    if not name:
        return False, "empty org name"
    if is_chain(name):
        return False, "chain/management company"
    # An exact name also counts: all-generic names ("Maryland Club") never pass org-matches.
    exact = norm_name(name) and norm_name(name) in (norm_name(venue_name), norm_name(clean_name))
    odom = org_domain(org)
    named = exact or R.org_name_matches(name, venue_name) or \
        (clean_name != venue_name and R.org_name_matches(name, clean_name))
    if not named and not shared and vreg and odom in (vreg, mail_alias):
        # The org is on the venue's own domain: a short brand name ("Ambar" for "AMBAR
        # Restaurant, Capitol Hill", "Hambleton Inn" for "... Bed & Breakfast") may match
        # the other way round. Different businesses on a wrong sheet website still fail.
        named = R.org_name_matches(venue_name, name) or R.org_name_matches(fold(venue_name), fold(name)) \
            or R.org_name_matches(fold(name), fold(venue_name))
    if not named:
        return False, "name doesn't match venue"
    if shared:
        # The brand domain proves nothing about the property; only its city does.
        return (True, "name+location") if loc_match(org) else (False, "shared brand domain, city doesn't match")
    if vreg and odom:
        return (True, "name+domain") if odom in (vreg, mail_alias) else (False, "different domain %s (venue %s)" % (odom, vreg))
    if loc_match(org):
        return True, "name+location"
    return False, "no domain or city evidence"


accepted, rejected, seen = [], [], set()
status = {"domain": "skipped", "name": "skipped"}
counts = {"domain": 0, "name": 0}


def consider(hits, via):
    n_ok = 0
    for org in hits:
        oid = org_id_of(org)
        key = oid or (org.get("name") or "") + "|" + org_domain(org)
        if key in seen:
            continue
        seen.add(key)
        ok, why = gate(org)
        if ok and not oid:
            ok, why = False, "no Apollo org id"
        if ok:
            accepted.append((org, via, why))
            n_ok += 1
        else:
            rejected.append({"name": org.get("name") or "", "domain": org_domain(org), "reason": why, "via": via})
    return n_ok


def companies(params):
    data = call("POST", "/mixed_companies/search", json=params)
    return (data.get("accounts") or []) + (data.get("organizations") or [])


def search_by_name(q):
    hits = []
    if venue_city:
        hits = companies({"q_organization_name": q, "per_page": 5, "organization_locations": [venue_city]})
    if not hits:
        hits = companies({"q_organization_name": q, "per_page": 5})
    return hits


# Domain lookup (never on a shared brand domain: it returns the brand, not the property)
if vreg and not shared:
    try:
        org = call("GET", "/organizations/enrich", missing_ok=(404, 422), params={"domain": vreg}).get("organization")
        hits = [org] if org else []
        if not hits:
            hits = companies({"q_organization_domains_list": [vreg] + ([mail_alias] if mail_alias else []), "per_page": 5})
        if not hits and mail_alias:
            org = call("GET", "/organizations/enrich", missing_ok=(404, 422), params={"domain": mail_alias}).get("organization")
            hits = [org] if org else []
        counts["domain"] = len(hits)
        status["domain"] = "ok"
        consider(hits, "domain")
    except ApolloError as e:
        status["domain"] = "error:" + str(e)
elif shared:
    status["domain"] = "skipped:shared_domain"
else:
    status["domain"] = "skipped:no_website"

# Name search, always (full name, then brand-stripped, then first distinctive words)
try:
    queries = [venue_name]
    if clean_name and clean_name != venue_name:
        queries.append(clean_name)
    words = [w for w in re.sub(r'[^a-z\s]', '', venue_name.lower()).split()
             if w not in {'the', 'a', 'an', 'and', 'of', 'at', 'in', 'by', 'hotel'}]
    if len(words) >= 2 and ' '.join(words[:3]) not in (q.lower() for q in queries):
        queries.append(' '.join(words[:3]))
    for q in queries:
        hits = search_by_name(q)
        counts["name"] += len(hits)
        if consider(hits, "name"):
            break
    status["name"] = "ok"
except ApolloError as e:
    status["name"] = "error:" + str(e)


def score(item):
    org, via, why = item
    s = 50 if "domain" in why else 20
    if via == "domain":
        s += 5
    return s


best = max(accepted, key=score) if accepted else None
errors = [s for s in status.values() if s.startswith("error:")]
out = {
    "found": bool(best), "org_id": "", "domain": "", "name": "", "gate": "",
    "venue_domain": vreg, "shared": shared, "single_site": False,
    "domain_search": status["domain"], "name_search": status["name"],
    "domain_results": counts["domain"], "name_results": counts["name"],
    "rejected": rejected[:5],
    # A failed lookup with no accepted org is an outage, not "no company".
    "error": errors[0][6:] if errors and not best else "",
}
if best:
    org, via, why = best
    emp = org.get("estimated_num_employees")
    ost, vst = norm_state(org.get("state")), norm_state(venue_state)
    out.update({
        "org_id": org_id_of(org), "domain": org_domain(org), "name": org.get("name") or "", "gate": why,
        # Only a small, local org may fall back to a people search without a location filter.
        "single_site": bool(isinstance(emp, int) and emp <= 150 and ost and ost == vst),
    })
print(json.dumps(out))
PYEOF
    rc=$?

    local info=""
    if [ $rc -eq 0 ]; then
        info=$(_rb_py "$venue_id apollo-org" python3 - "$apollo_co_tmpf" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
def f(k):
    v = d.get(k)
    return "" if v is None else str(v).replace("\x1f", " ").replace("\n", " ")
print("\x1f".join(f(k) for k in ("found", "org_id", "domain", "name", "gate", "error", "venue_domain",
                                 "shared", "single_site", "domain_search", "domain_results",
                                 "name_search", "name_results")))
for r in d.get("rejected") or []:
    print("REJECT\x1f" + "\x1f".join(str(r.get(k, "")).replace("\x1f", " ") for k in ("name", "domain", "reason", "via")))
PYEOF
        )
    fi
    if [ $rc -ne 0 ] || [ -z "$info" ]; then
        log "  [APOLLO ERROR] Company lookup crashed (see $(_rb_errlog)) — people search skipped"
        echo "error:org_lookup_crash" > /tmp/pipeline_apollo_verdict
        _rb_emit_step "$venue_id" apollo failed reason org_lookup_crash
        return
    fi

    local FOUND ORG_ID DOMAIN ORG_NAME GATE AERR VREG SHARED SINGLE DSEARCH DRES NSEARCH NRES
    IFS=$'\x1f' read -r FOUND ORG_ID DOMAIN ORG_NAME GATE AERR VREG SHARED SINGLE DSEARCH DRES NSEARCH NRES <<< "$(printf '%s\n' "$info" | head -1)"
    log "  [APOLLO] Domain lookup: ${DSEARCH} (${DRES} results) | name search: ${NSEARCH} (${NRES} results)"
    local rj_name rj_dom rj_why rj_via n_rej=0 first_rej=""
    while IFS=$'\x1f' read -r _ rj_name rj_dom rj_why rj_via; do
        [ -z "$rj_name$rj_dom" ] && continue
        n_rej=$((n_rej + 1))
        [ -z "$first_rej" ] && first_rej="$rj_name (${rj_dom:-no domain})"
        if [ "$FOUND" = "True" ]; then
            log "  [APOLLO REJECT] '$rj_name' (${rj_dom:-no domain}) — $rj_why"
        else
            log "  [APOLLO MISMATCH] '$rj_name' (${rj_dom:-no domain}) is not this venue — $rj_why"
        fi
    done < <(printf '%s\n' "$info" | grep '^REJECT')
    local skv=(domain_search "$DSEARCH" domain_results "$DRES" name_search "$NSEARCH" name_results "$NRES")

    if [ -n "$AERR" ]; then
        log "  [APOLLO ERROR] Company lookup failed ($AERR) — people search skipped"
        echo "error:$AERR" > /tmp/pipeline_apollo_verdict
        _rb_emit_step "$venue_id" apollo failed reason "$AERR" "${skv[@]}"
        return
    fi

    if [ "$FOUND" != "True" ]; then
        # Uncertain = save nothing. Step 4 may still match LinkedIn names on the
        # venue's own domain, never on a shared brand domain.
        [ "$SHARED" = "True" ] || APOLLO_DOMAIN="$VREG"
        if [ "$SHARED" = "True" ]; then
            log "  [APOLLO SKIP] Website is on shared brand domain $VREG and no org for this property matched — no domain-wide people search"
            echo "FLAG:Apollo skipped — website on shared brand domain $VREG; no property-specific org found" >> /tmp/pipeline_flags.txt
            echo "skipped:shared_domain" > /tmp/pipeline_apollo_verdict
            _rb_emit_step "$venue_id" apollo skipped reason shared_domain "${skv[@]}"
        elif [ "$n_rej" -gt 0 ]; then
            echo "FLAG:Apollo returned only other businesses for this venue (e.g. $first_rej) — people search skipped" >> /tmp/pipeline_flags.txt
            echo "mismatch:$first_rej" > /tmp/pipeline_apollo_verdict
            _rb_emit_step "$venue_id" apollo empty reason org_mismatch rejected_orgs "$n_rej" "${skv[@]}"
        else
            log "  [WARN] No company found in Apollo for '$venue' (tried name + domain)"
            echo "none" > /tmp/pipeline_apollo_verdict
            _rb_emit_step "$venue_id" apollo empty reason no_org "${skv[@]}"
        fi
        if [ -n "$APOLLO_DOMAIN" ]; then log "  Using website domain for enrichment: $APOLLO_DOMAIN"; fi
        return 0
    fi
    log "  Found: $ORG_NAME (domain: $DOMAIN, org_id: $ORG_ID)"
    log "  [APOLLO GATE] Accepted on $GATE"
    skv+=(org "$ORG_NAME" gate "$GATE")

    # Skip if this org was already processed this run (prevents duplicate contacts across venues)
    local SEEN_ORGS_FILE="/tmp/pipeline_seen_orgs"
    if [ -f "$SEEN_ORGS_FILE" ] && grep -qxF "$ORG_ID" "$SEEN_ORGS_FILE" 2>/dev/null; then
        log "  [SKIP] Org $ORG_ID already processed this run — skipping to avoid duplicates"
        [ "$SHARED" = "True" ] || APOLLO_DOMAIN="${VREG:-$DOMAIN}"
        echo "skipped:org_seen" > /tmp/pipeline_apollo_verdict
        _rb_emit_step "$venue_id" apollo skipped reason org_seen_this_run "${skv[@]}"
        return
    fi
    echo "$ORG_ID" >> "$SEEN_ORGS_FILE"

    # Store domain for Step 3b / Step 4. Emails on a shared brand domain can never
    # be saved from Apollo (P1), so Step 4 gets no domain there.
    if [ "$SHARED" = "True" ]; then
        APOLLO_DOMAIN=""
    else
        APOLLO_DOMAIN="${VREG:-$DOMAIN}"
    fi
    echo "ok:${APOLLO_DOMAIN}" > /tmp/pipeline_apollo_verdict

    # B. Search for people at this company (free search; no domain-wide search)
    log "  Searching for people at $ORG_NAME (org_id: $ORG_ID)..."
    local people_tmpf="/tmp/pipeline_people.json"
    RB_ORG_ID="$ORG_ID" RB_NATIONWIDE="$([ "$SINGLE" = "True" ] && echo 1 || echo 0)" \
    APOLLO_API_KEY="$APOLLO_API_KEY" APOLLO_API_BASE="$APOLLO_API_BASE" \
        _rb_py "$venue_id apollo-people" python3 - > "$people_tmpf" <<'PYEOF'
import json, os, sys
import requests

API = os.environ["APOLLO_API_BASE"]
HEADERS = {"Content-Type": "application/json", "x-api-key": os.environ["APOLLO_API_KEY"]}
org_id = os.environ["RB_ORG_ID"]
locations_list = ["Maryland", "Virginia", "Washington, DC", "District of Columbia",
                  "West Virginia", "Pennsylvania", "Delaware"]


class ApolloError(Exception):
    pass


def search_people(use_locations):
    results = []
    for page in (1, 2):
        params = {"per_page": 25, "page": page, "organization_ids": [org_id]}
        if use_locations:
            params["person_locations"] = locations_list
        try:
            r = requests.post(API + "/mixed_people/api_search", headers=HEADERS, json=params, timeout=30)
        except requests.RequestException as e:
            raise ApolloError("network_" + type(e).__name__)
        if r.status_code != 200:
            print("people search HTTP %s: %s" % (r.status_code, r.text[:300]), file=sys.stderr)
            raise ApolloError("http_%s" % r.status_code)
        people = r.json().get("people") or []
        for p in people:
            results.append({
                "id": p.get("id") or "",
                "first_name": (p.get("first_name") or "").strip(),
                "last_name_hint": p.get("last_name_obfuscated") or "",
                "title": p.get("title") or "",
                "has_email": bool(p.get("has_email")),
                "org": (p.get("organization") or {}).get("name") or "",
            })
        if len(people) < 25:
            break
    return results


out = {"people": [], "nationwide": False, "error": ""}
try:
    out["people"] = search_people(True)
    # Nationwide fallback only for a small local org: for chains and multi-site
    # orgs it returns staff of other properties.
    if not out["people"] and os.environ.get("RB_NATIONWIDE") == "1":
        out["people"] = search_people(False)
        out["nationwide"] = True
except ApolloError as e:
    out["error"] = str(e)
print(json.dumps(out))
PYEOF
    rc=$?

    local pinfo PEOPLE_COUNT PERR PNATION
    pinfo=""
    [ $rc -eq 0 ] && pinfo=$(_rb_py "$venue_id apollo-people" python3 - "$people_tmpf" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("%d\x1f%s\x1f%s" % (len(d.get("people") or []), d.get("error") or "", d.get("nationwide")))
PYEOF
    )
    IFS=$'\x1f' read -r PEOPLE_COUNT PERR PNATION <<< "$pinfo"
    if [ $rc -ne 0 ] || [ -z "$pinfo" ] || [ -n "$PERR" ]; then
        log "  [APOLLO ERROR] People search failed (${PERR:-crash}) — no people enriched"
        echo "error:people_${PERR:-crash}" > /tmp/pipeline_apollo_verdict
        _rb_emit_step "$venue_id" apollo failed reason "people_search_${PERR:-crash}" "${skv[@]}"
        return
    fi
    [ "$PNATION" = "True" ] && log "  [APOLLO] No people in DC/MD/VA — used the no-location search (small local org)"
    log "  Found $PEOPLE_COUNT people total"
    skv+=(people "$PEOPLE_COUNT")
    if [ "$PEOPLE_COUNT" = "0" ]; then
        log "  No people in Apollo for this company."
        _rb_emit_step "$venue_id" apollo empty reason no_people "${skv[@]}"
        return
    fi

    # C. Title filter + known-contact filter + per-venue cap
    _rb_load_skip_words
    local scored="/tmp/pipeline_people_scored.json"
    if ! _rb_score_titles "$people_tmpf" "$scored"; then
        log "  [APOLLO ERROR] Title filter crashed (see $(_rb_errlog)) — no people enriched"
        _rb_emit_step "$venue_id" apollo failed reason title_filter_crash "${skv[@]}"
        return
    fi

    if [ "$SHARED" = "True" ]; then
        # People at a property org on a brand domain: their Apollo emails are on the
        # brand domain and can't be saved (P1), so list them for review, don't pay.
        local n_cand=0 cl
        while IFS=$'\x1f' read -r cl; do
            [ -z "$cl" ] && continue
            n_cand=$((n_cand + 1))
            log "  [APOLLO CANDIDATE] $cl — shared brand domain $VREG, not enriched"
        done < <(_rb_py "$venue_id apollo" python3 - "$scored" <<'PYEOF'
import json, sys
for p in json.load(open(sys.argv[1])):
    if not str(p.get("why", "")).startswith("veto"):
        print(("%s %s (%s)" % (p.get("first_name", ""), p.get("last_name_hint", ""), p.get("title", ""))).replace("\x1f", " "))
PYEOF
        )
        _rb_emit_step "$venue_id" apollo skipped reason shared_domain candidates "$n_cand" "${skv[@]}"
        return
    fi

    local SELECTION
    SELECTION=$(KNAMES="$KNOWN_NAMES" RB_CAP="${MAX_APOLLO_PER_VENUE:-60}" RB_DM_ONLY="${APOLLO_DECISION_MAKERS_ONLY:-0}" \
        _rb_py "$venue_id apollo-select" python3 - "$scored" <<'PYEOF'
import json, os, sys

US = "\x1f"
people = json.load(open(sys.argv[1]))
known = [n.strip().lower() for n in os.environ.get("KNAMES", "").split("|||") if n.strip()]
cap = int(os.environ.get("RB_CAP") or 60)
dm_only = os.environ.get("RB_DM_ONLY") == "1"


def is_known(first, hint):
    """Apollo search masks last names ('Mc***y'); match first name + mask against the sheet."""
    first, h = (first or "").strip().lower(), (hint or "").strip().lower()
    if not first or not h:
        return False
    pre, post = (h.split("*")[0], h.split("*")[-1]) if "*" in h else (h, h)
    for k in known:
        parts = k.split()
        if len(parts) >= 2 and parts[0] == first:
            last = parts[-1]
            if last == h or ("*" in h and last.startswith(pre) and last.endswith(post)
                             and len(last) >= len(pre) + len(post)):
                return True
    return False


picked, skipped_title, n_known, n_noemail = [], [], 0, 0
for p in people:
    first = (p.get("first_name") or "").strip()
    if not first or not p.get("id"):
        continue
    sc, why = p.get("score", 0), p.get("why", "")
    # Alex's rule: enrich everyone at the venue's own org except skip words and the
    # hard veto; decision-makers only is opt-in.
    if why.startswith("veto") or (dm_only and sc <= 0):
        skipped_title.append(p.get("title") or "(no title)")
        continue
    if is_known(first, p.get("last_name_hint")):
        n_known += 1
        continue
    # No email: only decision-makers are worth a credit to unmask their real name (P2/P3).
    if not p.get("has_email") and sc < 4:
        n_noemail += 1
        continue
    picked.append(p)
picked.sort(key=lambda p: (-p.get("score", 0), not p.get("has_email")))
over, picked = picked[cap:], picked[:cap]
print(US.join(["COUNTS", str(len(skipped_title)), str(n_known), str(n_noemail), str(len(over))]))
if skipped_title:
    print(US.join(["SKIPT", "; ".join(sorted(set(skipped_title))[:10])]))
if over:
    print(US.join(["OVER", "; ".join((p.get("title") or "?") for p in over[:10])]))
for p in picked:
    print(US.join(["E", p["id"], p["first_name"], (p.get("title") or "").replace(US, " "),
                   "1" if p.get("has_email") else "0", str(p.get("score", 0))]))
PYEOF
    )
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$SELECTION" ]; then
        log "  [APOLLO ERROR] Selection crashed (see $(_rb_errlog)) — no people enriched"
        _rb_emit_step "$venue_id" apollo failed reason selection_crash "${skv[@]}"
        return
    fi
    local n_skip_title n_known n_noemail n_over
    IFS=$'\x1f' read -r _ n_skip_title n_known n_noemail n_over <<< "$(printf '%s\n' "$SELECTION" | grep '^COUNTS')"
    if [ "${n_skip_title:-0}" -gt 0 ] 2>/dev/null; then
        log "  Skipped $n_skip_title people by title (app skip words / non-booking staff$([ "${APOLLO_DECISION_MAKERS_ONLY:-0}" = "1" ] && echo " / not decision-makers")): $(printf '%s\n' "$SELECTION" | awk -F$'\x1f' '$1=="SKIPT"{print $2}')"
    fi
    [ "${n_known:-0}" -gt 0 ] 2>/dev/null && log "  Skipped $n_known people already in the sheet (name match)"
    [ "${n_noemail:-0}" -gt 0 ] 2>/dev/null && log "  Skipped $n_noemail people with no email (red ? on Apollo) and no decision-maker title"
    if [ "${n_over:-0}" -gt 0 ] 2>/dev/null; then
        log "  [CAP] $n_over more people not enriched (MAX_APOLLO_PER_VENUE=${MAX_APOLLO_PER_VENUE:-60}; most relevant were enriched first): $(printf '%s\n' "$SELECTION" | awk -F$'\x1f' '$1=="OVER"{print $2}')"
    fi

    local ENRICH_COUNT
    ENRICH_COUNT=$(printf '%s\n' "$SELECTION" | grep -c '^E')
    skv+=(relevant "$ENRICH_COUNT" skipped_titles "${n_skip_title:-0}" over_cap "${n_over:-0}")
    if [ "$ENRICH_COUNT" -eq 0 ]; then
        log "  No new people to enrich."
        _rb_emit_step "$venue_id" apollo empty reason no_relevant_people "${skv[@]}"
        return
    fi
    log "  $ENRICH_COUNT people to enrich (1 credit each)"

    # D. Bulk enrich in batches of 10 (fd 7 so nothing inside can eat the list)
    local BATCH_IDS="" BATCH_COUNT=0 enrich_err="" stopped="" tagl pid pfirst ptitle phas pscore
    while IFS=$'\x1f' read -r tagl pid pfirst ptitle phas pscore <&7; do
        [ "$tagl" = "E" ] && [ -n "$pid" ] || continue
        BATCH_IDS="${BATCH_IDS:+${BATCH_IDS},}${pid}"
        BATCH_COUNT=$((BATCH_COUNT + 1))
        if [ "$BATCH_COUNT" -ge 10 ]; then
            if ! check_apollo_credits; then stopped="credit_cap"; BATCH_IDS=""; break; fi
            _enrich_batch "$BATCH_IDS" "$venue_id" || enrich_err="bulk_match"
            BATCH_IDS=""
            BATCH_COUNT=0
            sleep 1
        fi
    done 7< <(printf '%s\n' "$SELECTION")
    # Flush remaining batch
    if [ -n "$BATCH_IDS" ]; then
        if check_apollo_credits; then
            _enrich_batch "$BATCH_IDS" "$venue_id" || enrich_err="bulk_match"
        else
            stopped="credit_cap"
        fi
    fi

    log "  Apollo API done: $APOLLO_CREDITS_USED credits used this run"
    local saved deferred status
    saved=$(( $(_rb_count_lines /tmp/pipeline_contacts_count) - count_before ))
    deferred=$(( $(_rb_count_lines /tmp/pipeline_deferred_count) - deferred_before ))
    skv+=(enriched "$RB_APOLLO_ENRICHED" saved "$saved" pending "$RB_APOLLO_PENDING" deferred "$deferred" credits "$((APOLLO_CREDITS_USED - credits_before))")
    if [ -n "$enrich_err" ]; then
        status="failed"; skv+=(reason "$enrich_err")
    elif [ -n "$stopped" ]; then
        status="skipped"; skv+=(reason "$stopped")
    elif [ $((saved + deferred + RB_APOLLO_PENDING)) -gt 0 ]; then
        status="ok"
    else
        status="empty"
    fi
    _rb_emit_step "$venue_id" apollo "$status" "${skv[@]}"
}

# Helper: enrich a batch of Apollo person IDs (people/bulk_match).
# Returns 1 when the API call failed. Runs in the caller's shell, so KNOWN_NAMES,
# credits and verify_and_push's counters persist (PB-6).
_enrich_batch() {
    local ids_csv="$1" venue_id="$2" src="${3:-apollo}"
    local RESULT rc
    RESULT=$(RB_IDS="$ids_csv" APOLLO_API_KEY="$APOLLO_API_KEY" APOLLO_API_BASE="$APOLLO_API_BASE" \
        _rb_py "$venue_id apollo-enrich" python3 - <<'PYEOF'
import os, re, sys
import requests

US = "\x1f"
ids = [i.strip() for i in os.environ.get("RB_IDS", "").split(",") if i.strip()]
if not ids:
    sys.exit(0)
try:
    r = requests.post(os.environ["APOLLO_API_BASE"] + "/people/bulk_match",
                      headers={"Content-Type": "application/json", "x-api-key": os.environ["APOLLO_API_KEY"]},
                      json={"details": [{"id": i} for i in ids], "reveal_personal_emails": False}, timeout=60)
except requests.RequestException as e:
    print("ERROR" + US + "network_" + type(e).__name__)
    sys.exit(3)
if r.status_code != 200:
    print("bulk_match HTTP %s: %s" % (r.status_code, r.text[:300]), file=sys.stderr)
    print("ERROR" + US + "http_%s" % r.status_code)
    sys.exit(3)
data = r.json()
matches = data.get("matches") or []
credits = data.get("credits_consumed")
if not isinstance(credits, int):
    credits = sum(1 for m in matches if m)
print("CREDITS" + US + str(credits))


def clean(s):
    return re.sub(r"[\x1f\t\r\n]+", " ", str(s or "")).strip()


for idx, m in enumerate(matches):
    if not m:
        print("NOMATCH" + US + (ids[idx] if idx < len(ids) else ""))
        continue
    email = clean(m.get("email")).lower()
    # Locked addresses come back as placeholders (email_not_unlocked@domain.com)
    if "@" not in email or email.startswith("email_not_unlocked"):
        email = ""
    name = clean(m.get("name")) or clean("%s %s" % (m.get("first_name") or "", m.get("last_name") or ""))
    print(US.join(["MATCH", name, clean(m.get("title")), email, clean(m.get("email_status"))]))
PYEOF
    )
    rc=$?
    local credits
    credits=$(printf '%s\n' "$RESULT" | awk -F$'\x1f' '$1=="CREDITS"{print $2; exit}')
    _rb_apollo_credits_add "${credits:-0}"
    if [ $rc -ne 0 ]; then
        log "  [APOLLO ERROR] people/bulk_match failed ($(printf '%s\n' "$RESULT" | awk -F$'\x1f' '$1=="ERROR"{print $2; exit}')) — batch not enriched"
        return 1
    fi

    local kind ename etitle eemail estatus cname
    while IFS=$'\x1f' read -r kind ename etitle eemail estatus <&7; do
        [ "$kind" = "MATCH" ] && [ -n "$ename" ] || continue
        RB_APOLLO_ENRICHED=$(( ${RB_APOLLO_ENRICHED:-0} + 1 ))
        if [ -n "$eemail" ] && [ "$estatus" != "unavailable" ]; then
            log "  >>> $ename ($etitle): $eemail [$estatus]"
            cname=$(_rb_py "$venue_id apollo" python3 "$SCRIPT_DIR/outreach_rules.py" clean-name "$ename")
            verify_and_push "$eemail" "$venue_id" "$cname" "$etitle" "$src" "external"
            # Mark name as known (after saving, so Step 4 doesn't pay for them again)
            KNOWN_NAMES="${KNOWN_NAMES}|||$(printf '%s' "$ename" | tr '[:upper:]' '[:lower:]')"
        else
            log "  --- $ename ($etitle): no email available"
            if _rb_save_pending "$venue_id" "$ename" "$etitle" "$src"; then
                RB_APOLLO_PENDING=$(( ${RB_APOLLO_PENDING:-0} + 1 ))
            fi
        fi
    done 7< <(printf '%s\n' "$RESULT")
    return 0
}

# P3: an email-less contact needs a real, unmasked first + last name and a
# decision-maker title. The add_contact response is read, never discarded.
_rb_save_pending() {
    local vid="$1" raw_name="$2" title="$3" src="$4" name sc resp verdict
    name=$(_rb_py "$vid pending" python3 "$SCRIPT_DIR/outreach_rules.py" clean-name "$raw_name")
    if [ -z "$name" ]; then
        log "  [SKIP] '$raw_name' ($title): not a real first + last name — pending contact not saved"
        return 1
    fi
    sc=$(_rb_score_titles --title "$title")
    if [ "${sc:-0}" -lt 2 ] 2>/dev/null || [ -z "$sc" ]; then
        log "  [SKIP] $name ($title): not a booking decision-maker title — pending contact not saved"
        return 1
    fi
    if name_known "$name"; then
        log "  [SKIP] $name — already in sheet"
        return 1
    fi
    resp=$(curl -sL --max-time 30 -G \
        --data-urlencode "action=add_contact" --data-urlencode "venue_id=$vid" \
        --data-urlencode "name=$name" --data-urlencode "title=$title" \
        --data-urlencode "source=$src" --data-urlencode "verified=pending" \
        "$APPS_SCRIPT_URL" 2>>"$(_rb_errlog)")
    verdict=$(printf '%s' "$resp" | _rb_py "$vid pending" python3 -c 'import json, sys
d = json.load(sys.stdin)
msg = str(d.get("message") or "")
reason = str(d.get("reason") or d.get("name_rejected") or "")
if d.get("status") != "ok":
    print("error:" + (reason + ": " if reason else "") + (msg or "status " + str(d.get("status")))[:150])
elif d.get("duplicate") or d.get("created") is False or "uplicate" in msg:
    print("duplicate")
else:
    print("created")')
    case "$verdict" in
        created)
            log "  +++ $name ($title): no email — added as pending"
            KNOWN_NAMES="${KNOWN_NAMES}|||$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
            return 0 ;;
        duplicate)
            # The old backend dedupes email-less rows per venue on the empty email,
            # so a second pending person is refused until apps_script is redeployed.
            log "  [PENDING DUP] $name ($title): server reported a duplicate — not added"
            return 1 ;;
        error:*)
            log "  [CANDIDATE] Pending contact refused by the sheet: $name ($title) — ${verdict#error:}"
            _rb_record_candidate_row "$vid" person "$name" "$name" "$title" "$src" "reject:${verdict#error:}"
            return 1 ;;
        *)
            log "  [API ERROR] Pending contact not saved (no response): $name ($title)"
            _rb_record_candidate_row "$vid" person "$name" "$name" "$title" "$src" "api_save_failed"
            return 1 ;;
    esac
}

_rb_load_skip_words() {
    [ -n "${RB_SKIP_WORDS_OK:-}" ] && return 0
    local resp words
    # curl, not urllib: the python.org build had no CA certificates (PB-20).
    resp=$(curl -sL --max-time 20 -G --data-urlencode "action=get_skip_words" "$APPS_SCRIPT_URL" 2>>"$(_rb_errlog)")
    words=$(printf '%s' "$resp" | _rb_py "skip_words" python3 -c 'import json, sys
d = json.load(sys.stdin)
w = d.get("words")
assert d.get("status") == "ok" and isinstance(w, list), "bad get_skip_words response"
print(json.dumps([str(x).strip().lower() for x in w if str(x).strip()]))')
    if [ -n "$words" ]; then
        RB_SKIP_WORDS="$words"
        RB_SKIP_WORDS_OK=1
        log "  [APOLLO] App title skip words loaded: $(printf '%s' "$words" | tr -d '[]"')"
    else
        RB_SKIP_WORDS="[]"
        log "  [WARN] Could not load the app's title skip words (get_skip_words failed) — built-in title filter only"
        echo "FLAG:App title skip words could not be loaded — built-in title filter only" >> /tmp/pipeline_flags.txt
    fi
}

# Booking-relevance score for job titles (0 = not a decision-maker, vetoed = 0
# with why=veto:...). Used by Step 3 (Apollo) and Step 4 (LinkedIn).
#   _rb_score_titles IN.json OUT.json   (list of objects with "title"; adds score/why)
#   _rb_score_titles --title "Title"    (prints the score)
_rb_score_titles() {
    RB_SKIP_WORDS="${RB_SKIP_WORDS:-[]}" _rb_py "title-score" python3 - "$@" <<'PYEOF'
import json, os, re, sys

# Always skipped (with the app's skip words): the old bad_titles list plus floor
# staff that never book music. Everything else at an accepted org is enriched.
HARD_VETO = re.compile(
    r"\b(intern|interns|internship|student|volunteer|housekeeping|housekeeper|laundry|security|"
    r"loss prevention|accountant|accounting|finance|payroll|steward|engineer|engineering|maintenance|"
    r"it|information technology|purchasing|procurement|human resources?|hr|recruiter|recruiting|"
    r"recruitment|talent acquisition|spa|esthetician|massage|server|servers|dishwasher|line cook|"
    r"prep cook|busser|barback|valet|caddie|caddies)\b")
# Not booking roles: score 0, so they are left out only in decision-maker mode
# (APOLLO_DECISION_MAKERS_ONLY=1) and never become email-less pending contacts (P3).
NON_BOOKING = re.compile(
    r"\b(teacher|faculty|professor|coach|athletics?|accounts payable|accounts receivable|bookkeeper|"
    r"controller|comptroller|financial|superintendent|groundskeeper|grounds|landscape|golf professional|"
    r"golf pro|assistant golf|tennis|racquets?|pickleball|squash|fitness|personal trainer|lifeguard|"
    r"aquatics|therapist|salon|bartender|cook|bellman|bell attendant|doorman|driver|software|developer|"
    r"data analyst|data scientist|retired|former|guest service agent|front desk agent|night auditor|"
    r"reservations agent|attorney|lawyer|counsel|architect|architecture|construction|nurse|physician)\b")
SENIOR = r"(manager|director|coordinator|head|lead|chief|vp|vice president|executive|specialist|planner|supervisor|producer|administrator|officer|consultant)"
RULES = [
    (5, r"\b(events?|special events|private events|private dining|banquets?|catering|weddings?|meetings)\b", True),
    (5, r"\b(entertainment|music|booking|bookings|talent buyer|programming)\b", False),
    (4, r"\b(owner|co owner|coowner|founder|co founder|cofounder|proprietor|general manager|gm|managing director|managing partner)\b", False),
    (4, r"\b(food (and|&) beverage|f ?& ?b|fnb|beverage director|director of beverage|restaurant manager|dining room manager|outlet manager)\b", False),
    (3, r"\bsales\b", True),
    (3, r"\b(club manager|clubhouse manager|venue manager|house manager|tasting room|winery manager|estate manager|artistic director|music director|curator|public programs)\b", False),
    (3, r"\b(hospitality|guest experience|programs?)\b", True),
    (2, r"\b(president|ceo|chief executive|coo|chief operating|partner)\b", False),
    (2, r"\boperations\b", True),
]
try:
    user_skip = [w for w in json.loads(os.environ.get("RB_SKIP_WORDS") or "[]") if w]
except ValueError:
    user_skip = []


def score(title):
    t = " " + re.sub(r"\s+", " ", re.sub(r"[^a-z0-9& ]+", " ", (title or "").lower())) + " "
    if not t.strip():
        return 0, "no_title"
    for w in user_skip:
        # Whole-word, like the app's filter (UI-9)
        if re.search(r"(^|[^a-z0-9])" + re.escape(w) + r"($|[^a-z0-9])", t):
            return 0, "veto:skip_word:" + w
    m = HARD_VETO.search(t)
    if m:
        return 0, "veto:" + m.group(1)
    m = NON_BOOKING.search(t)
    if m:
        return 0, "non_booking:" + m.group(1)
    senior = re.search(r"\b" + SENIOR + r"\b", t) is not None
    best = 0
    for pts, pat, need_senior in RULES:
        if re.search(pat, t) and (senior or not need_senior):
            best = max(best, pts)
    if not best:
        return 0, "not_relevant"
    if re.search(r"\bassistant\b", t):
        best -= 1
    elif re.search(r"\b(director|head|vp|vice president|chief)\b", t):
        best += 1
    return max(best, 1), "rule"


if len(sys.argv) >= 3 and sys.argv[1] == "--title":
    print(score(sys.argv[2])[0])
    sys.exit(0)
src, dst = sys.argv[1:3]
people = json.load(open(src))
if isinstance(people, dict):
    people = people.get("people") or []
for p in people:
    p["score"], p["why"] = score(p.get("title") or "")
with open(dst, "w") as f:
    json.dump(people, f)
PYEOF
}

# Apollo credits also live in a file, so the MAX_APOLLO cap still holds when a
# venue runs in a subshell (watchdog) and the counter would otherwise reset.
_rb_apollo_credits_file() { printf '/tmp/pipeline_apollo_credits_%s' "$$"; }
_rb_apollo_credits_sync() {
    local v
    v=$(cat "$(_rb_apollo_credits_file)" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    case "$APOLLO_CREDITS_USED" in ''|*[!0-9]*) APOLLO_CREDITS_USED=0 ;; esac
    [ "$v" -gt "$APOLLO_CREDITS_USED" ] && APOLLO_CREDITS_USED=$v
    return 0
}
_rb_apollo_credits_add() {
    local n="$1"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    _rb_apollo_credits_sync
    APOLLO_CREDITS_USED=$((APOLLO_CREDITS_USED + n))
    echo "$APOLLO_CREDITS_USED" > "$(_rb_apollo_credits_file)"
}

# =================================================================
# STEP 4: LINKEDIN + APOLLO API ENRICHMENT
# =================================================================
step4_linkedin() {
    local venue="$1" venue_id="$2"
    log ""
    log "========== STEP 4: LinkedIn + Apollo API =========="
    rm -f /tmp/pipeline_li_found_count /tmp/pipeline_li_people.jsonl /tmp/pipeline_li_selected.json
    _rb_apollo_credits_sync
    # Wall state is also kept in a file so it survives a per-venue subshell.
    [ -f "/tmp/pipeline_li_walled_$$" ] && LINKEDIN_WALLED=1
    if [ "${LINKEDIN_WALLED:-0}" = "1" ]; then
        log "  [LINKEDIN WALL] Wall hit earlier this run — search not attempted"
        echo "wall" > /tmp/pipeline_li_verdict
        _rb_emit_step "$venue_id" linkedin blocked reason login_wall_earlier_in_run
        return 0
    fi

    if [ -z "$APOLLO_API_KEY" ]; then
        log "  [SKIP] No APOLLO_API_KEY — cannot enrich"
        _rb_emit_step "$venue_id" linkedin skipped reason no_api_key
        return 0
    fi

    local count_before deferred_before credits_before
    count_before=$(_rb_count_lines /tmp/pipeline_contacts_count)
    deferred_before=$(_rb_count_lines /tmp/pipeline_deferred_count)
    credits_before="$APOLLO_CREDITS_USED"

    local MAX_PAGES=3
    local ENCODED_VENUE
    ENCODED_VENUE=$(_rb_py "$venue_id linkedin" python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$venue")

    # Use the domain found in Step 3, or fall back to the venue website's
    # registrable domain. Never a shared brand domain: a name match there would
    # be any employee of the chain.
    local li_detail="/tmp/pipeline_li_domain.json" dinfo DOMAIN="" li_shared="false" li_city="" li_state=""
    rm -f "$li_detail"
    _rb_fetch_detail "$venue_id" "$li_detail" || log "  [WARN] venue_detail failed — using this run's website/domain only"
    dinfo=$(RB_APOLLO_DOMAIN="${APOLLO_DOMAIN:-}" RB_WEBSITE="${VENUE_WEBSITE:-}" SCRIPT_DIR="$SCRIPT_DIR" \
        _rb_py "$venue_id linkedin" python3 - "$li_detail" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import outreach_rules as R
try:
    v = json.load(open(sys.argv[1])).get("venue") or {}
except (OSError, ValueError, AttributeError):
    v = {}
web = os.environ.get("RB_WEBSITE") or v.get("website") or ""
if web == "None":
    web = ""
dom = os.environ.get("RB_APOLLO_DOMAIN") or ""
if not dom and web and not R.is_non_venue_host(web):
    dom = R.registrable_domain(web)
shared = bool(dom and R.is_shared_domain(dom)) or bool(web and R.is_shared_domain(web))
print("\x1f".join([dom, "true" if shared else "false", v.get("city") or "", v.get("state") or ""]))
PYEOF
    )
    IFS=$'\x1f' read -r DOMAIN li_shared li_city li_state <<< "$dinfo"
    if [ "$li_shared" = "true" ]; then
        log "  [LINKEDIN] Website is on shared brand domain ${DOMAIN:-?} — people will be saved as pending, not enriched by domain"
        DOMAIN=""
    elif [ -z "$DOMAIN" ]; then
        log "  [WARN] No domain found for '$venue' — LinkedIn names won't be enrichable"
    else
        log "  Using domain: $DOMAIN"
    fi

    # Text-based extraction (LinkedIn obfuscates DOM selectors). Each card gives
    # name, headline, location and the "Current:"/"Past:" snippet lines.
    cat > /tmp/pipeline_li_extract.js << 'JSEOF'
(function() {
    var main = document.querySelector("main");
    if (!main) return JSON.stringify({ok: false, reason: "no_main", people: []});
    var lines = main.innerText.split("\n").map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
    var marker = /^\s*[\u2022\u00b7]\s*(1st|2nd|3rd|\d+th)/;
    var people = [];
    for (var i = 0; i < lines.length; i++) {
        var member = lines[i] === "LinkedIn Member";
        if (!member && !marker.test(lines[i])) continue;
        var name = member ? "LinkedIn Member" : (i > 0 ? lines[i - 1] : "");
        if (!name || name.indexOf("Results for") === 0) continue;
        name = name.replace(/,\s*(CCM|PGA|SHRM|CPA|MBA|PHR|SPHR|CEC|CMC|CEBS).*/i, "").trim();
        var current = "", past = "";
        for (var k = i + 1; k < Math.min(lines.length, i + 9); k++) {
            if (lines[k] === "LinkedIn Member" || marker.test(lines[k])) break;
            var low = lines[k].toLowerCase();
            if (low.indexOf("current:") === 0) current = lines[k].slice(8).trim();
            else if (low.indexOf("past:") === 0) past = lines[k].slice(5).trim();
        }
        people.push({name: name.substring(0, 100), title: (lines[i + 1] || "").substring(0, 160),
                     location: (lines[i + 2] || "").substring(0, 80),
                     current: current.substring(0, 160), past: past.substring(0, 160)});
    }
    return JSON.stringify({ok: true, people: people});
})()
JSEOF

    osascript -e 'tell application "Google Chrome" to activate' 2>>"$(_rb_errlog)"
    rand_delay 1 2

    local PAGE URL COUNT PAGE_JSON RETRY js_ok pages_read=0 results_total=0 li_fail="" li_block="" n_rej=0
    for PAGE in $(seq 1 $MAX_PAGES); do
        URL="https://www.linkedin.com/search/results/people/?keywords=${ENCODED_VENUE}&page=${PAGE}"
        log "  LinkedIn page $PAGE..."
        if ! _rb_chrome_nav "$URL"; then
            log "  [LINKEDIN ERROR] Chrome could not open the search page"
            li_fail="chrome"
            break
        fi
        rand_delay 5 8

        # Wait for results
        COUNT=0; PAGE_JSON=""; js_ok=0
        for RETRY in 1 2 3 4 5; do
            if PAGE_JSON=$(_rb_chrome_js /tmp/pipeline_li_extract.js); then
                js_ok=1
                COUNT=$(printf '%s' "$PAGE_JSON" | _rb_py "$venue_id linkedin" python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("people") or []))')
                [ "${COUNT:-0}" -gt 0 ] 2>/dev/null && break
            fi
            sleep 2
        done
        [ -z "$COUNT" ] && COUNT=0

        if [ "$COUNT" = "0" ]; then
            if [ "$js_ok" = "0" ]; then
                log "  [LINKEDIN ERROR] Chrome JavaScript failed on the results page"
                li_fail="chrome_js"
                [ "$PAGE" = "1" ] && echo "error:chrome_js" > /tmp/pipeline_li_verdict
            elif [ "$PAGE" = "1" ]; then
                # Empty first page is almost never "no staff" — it's a login wall,
                # the commercial-use limit, or Chrome not rendering. Record it so
                # the venue stays linkedin_pending instead of looking finished.
                local _li_url
                _li_url=$(_rb_active_url)
                if echo "$_li_url" | grep -qiE 'login|authwall|checkpoint|uas/'; then
                    log "  [LINKEDIN WALL] Redirected to $_li_url — not logged in / rate limited"
                    echo "wall" > /tmp/pipeline_li_verdict
                    LINKEDIN_WALLED=1
                    : > "/tmp/pipeline_li_walled_$$"
                    li_block="login_wall"
                else
                    log "  [LINKEDIN EMPTY] Page 1 returned 0 results — treating as unverified, venue stays pending"
                    echo "empty" > /tmp/pipeline_li_verdict
                    local streak
                    streak=$(cat "/tmp/pipeline_li_empty_streak_$$" 2>/dev/null)
                    case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
                    [ "${LINKEDIN_EMPTY_STREAK:-0}" -gt "$streak" ] 2>/dev/null && streak=$LINKEDIN_EMPTY_STREAK
                    LINKEDIN_EMPTY_STREAK=$((streak + 1))
                    echo "$LINKEDIN_EMPTY_STREAK" > "/tmp/pipeline_li_empty_streak_$$"
                    li_fail="empty_page1"
                    if [ "$LINKEDIN_EMPTY_STREAK" -ge 3 ]; then
                        log "  [LINKEDIN WALL] 3 venues in a row with empty page 1 — assuming rate limit for the rest of this run"
                        LINKEDIN_WALLED=1
                        : > "/tmp/pipeline_li_walled_$$"
                    fi
                fi
            else
                log "  No results on page $PAGE — stopping."
            fi
            break
        fi
        if [ "$PAGE" = "1" ]; then
            echo "found:$COUNT" > /tmp/pipeline_li_verdict
            LINKEDIN_EMPTY_STREAK=0
            echo 0 > "/tmp/pipeline_li_empty_streak_$$"
        fi
        log "  Found $COUNT results"
        pages_read=$((pages_read + 1))
        results_total=$((results_total + COUNT))

        # Keep only confirmed current employees of THIS venue: the "Current:" line
        # or the headline must name the venue (org-matches, no extra org words).
        local FILTERED
        FILTERED=$(LI_PAGE_JSON="$PAGE_JSON" KNAMES="$KNOWN_NAMES" RB_VENUE_NAME="$venue" RB_CITY="$li_city" \
            RB_STATE="$li_state" SCRIPT_DIR="$SCRIPT_DIR" \
            _rb_py "$venue_id linkedin-filter" python3 - <<'PYEOF'
import json, os, re, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import outreach_rules as R

US = "\x1f"
data = json.loads(os.environ["LI_PAGE_JSON"])
known = {n.strip().lower() for n in os.environ.get("KNAMES", "").split("|||") if n.strip()}
venue = os.environ["RB_VENUE_NAME"]
GENERIC = set(getattr(R, "_GENERIC_VENUE_WORDS", set())) | {"hotels", "resorts", "clubs", "restaurants", "group"}


def words(s):
    return re.findall(r"[a-z0-9]+", re.sub(r"[\x27\u2019\x60]", "", (s or "").lower().replace("&", " and ")))


vwords = set(words(venue))
place = set(words(os.environ.get("RB_CITY"))) | set(words(os.environ.get("RB_STATE"))) | {"dc", "va", "md", "virginia", "maryland", "washington"}
STOP = {"the", "a", "an", "and", "of", "at", "in", "by", "on"}


vw_list = words(venue)
if vw_list and vw_list[0] == "the":
    vw_list = vw_list[1:]
VENUE_RE = re.compile(r"(?:\bthe\W+)?\b" + r"\W+".join(map(re.escape, vw_list)) + r"\b", re.I) if vw_list else None


def names_venue(text):
    """(role, True) when the text names this venue: its full name as a phrase, or a
    segment that is this venue and nothing else (org-matches, no extra org words)."""
    if not text:
        return "", False
    t = re.sub(r"[\x27\u2019\x60]", "", text)
    m = VENUE_RE.search(t) if VENUE_RE else None
    if m:
        return re.sub(r"(\s+(at|@|with)|[|@,\u00b7\u2022\u2013\u2014-])\s*$", "", t[:m.start()].strip()).strip(), True
    parts = re.split(r"\s+(?:at|@|with)\s+|\s*[|@\u00b7\u2022,\u2013\u2014]\s*|\s+-\s+", text)
    for i, seg in enumerate(parts):
        segw = [w for w in words(seg) if w not in STOP]
        if not segw:
            continue
        exact = "".join(segw) == "".join(w for w in words(venue) if w not in STOP)
        extra = [w for w in segw if w not in vwords and w not in GENERIC and w not in place and len(w) >= 3]
        if exact or (R.org_name_matches(seg, venue) and not extra):
            return " ".join(p for p in parts[:i] if p).strip(" -|,"), True
    return "", False


for p in data.get("people") or []:
    raw = (p.get("name") or "").strip()
    head = (p.get("title") or "").strip()
    cur = (p.get("current") or "").strip()
    past = (p.get("past") or "").strip()
    if raw.lower() == "linkedin member" or "***" in raw:
        print(US.join(["REJ", raw, head, "masked name"]))
        continue
    name = R.clean_person_name(raw)
    if not name:
        print(US.join(["REJ", raw, head, "not a person name"]))
        continue
    if name.lower() in known:
        print(US.join(["REJ", name, head, "already in sheet"]))
        continue
    if re.match(r"^(former|ex-|retired)", head.lower()):
        print(US.join(["REJ", name, head, "former employee"]))
        continue
    if cur:
        role, ok = names_venue(cur)
        why = "current job is elsewhere"
    else:
        role, ok = names_venue(head)
        why = "past employee" if names_venue(past)[1] else "headline doesn't name the venue"
    if not ok:
        print(US.join(["REJ", name, head, why]))
        continue
    parts = name.split()
    print(US.join(["OK", json.dumps({"first": parts[0], "last": parts[-1], "full": name,
                                      "title": role or head, "headline": head}), name]))
PYEOF
        )
        if [ $? -ne 0 ]; then
            log "  [LINKEDIN ERROR] Result filter crashed (see $(_rb_errlog)) — page $PAGE dropped"
            li_fail="filter_crash"
            break
        fi
        local tagl a b c
        while IFS=$'\x1f' read -r tagl a b c; do
            if [ "$tagl" = "OK" ]; then
                printf '%s\n' "$a" >> /tmp/pipeline_li_people.jsonl
                log "  Found: $b"
            elif [ "$tagl" = "REJ" ]; then
                n_rej=$((n_rej + 1))
                log "  [LINKEDIN SKIP] $a ($b) — $c"
            fi
        done < <(printf '%s\n' "$FILTERED")

        if [ "$PAGE" -lt "$MAX_PAGES" ]; then
            rand_delay 3 5
        fi
    done

    # Title relevance + dedupe (P3: decision-makers only)
    local TOTAL_FOUND=0 employees=0 relevant_json="/tmp/pipeline_li_relevant.json"
    rm -f "$relevant_json"
    if [ -s /tmp/pipeline_li_people.jsonl ]; then
        employees=$(sort -u /tmp/pipeline_li_people.jsonl | wc -l | tr -d ' ')
        _rb_load_skip_words
        if ! _rb_py "$venue_id linkedin" python3 - /tmp/pipeline_li_people.jsonl "$relevant_json.in" <<'PYEOF'
import json, sys
seen, out = set(), []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    p = json.loads(line)
    if p["full"].lower() in seen:
        continue
    seen.add(p["full"].lower())
    out.append(p)
json.dump(out, open(sys.argv[2], "w"))
PYEOF
        then
            log "  [LINKEDIN ERROR] Dedupe step crashed (see $(_rb_errlog))"
            li_fail="${li_fail:-dedupe_crash}"
        elif ! _rb_score_titles "$relevant_json.in" "$relevant_json"; then
            log "  [LINKEDIN ERROR] Title filter crashed (see $(_rb_errlog))"
            li_fail="${li_fail:-title_filter_crash}"
        else
            # Same rule as Step 3: everyone except skip words / hard veto, unless
            # APOLLO_DECISION_MAKERS_ONLY=1. Email-less saves still need a
            # decision-maker title (P3, checked in _rb_save_pending).
            local rl
            while IFS= read -r rl; do
                [ -n "$rl" ] && log "  [LINKEDIN SKIP] $rl"
            done < <(RB_DM_ONLY="${APOLLO_DECISION_MAKERS_ONLY:-0}" _rb_py "$venue_id linkedin" python3 - "$relevant_json" /tmp/pipeline_li_selected.json <<'PYEOF'
import json, os, sys
dm_only = os.environ.get("RB_DM_ONLY") == "1"
keep = []
for p in json.load(open(sys.argv[1])):
    why = p.get("why", "")
    if why.startswith("veto"):
        print("%s (%s) - skipped by title (%s)" % (p["full"], p.get("title", ""), why))
    elif dm_only and p.get("score", 0) <= 0:
        print("%s (%s) - not a booking decision-maker title" % (p["full"], p.get("title", "")))
    else:
        keep.append(p)
keep.sort(key=lambda p: -p.get("score", 0))
json.dump(keep, open(sys.argv[2], "w"))
PYEOF
            )
            TOTAL_FOUND=$(_rb_py "$venue_id linkedin" python3 -c 'import json, sys
print(len(json.load(open(sys.argv[1]))))' /tmp/pipeline_li_selected.json)
        fi
    fi
    TOTAL_FOUND="${TOTAL_FOUND:-0}"
    echo "$TOTAL_FOUND" > /tmp/pipeline_li_found_count
    local skv=(pages "$pages_read" results "$results_total" rejected "$n_rej" employees "$employees" relevant "$TOTAL_FOUND")

    if [ "$TOTAL_FOUND" = "0" ]; then
        [ "$pages_read" -gt 0 ] && log "  No new people found on LinkedIn."
        _rb_li_finish "$venue_id" "$li_block" "$li_fail" 0 "$count_before" "$deferred_before" "$credits_before" "${skv[@]}"
        return 0
    fi
    log ""
    log "  LinkedIn found $TOTAL_FOUND new people. Enriching via Apollo API..."

    local PEOPLE_JSON
    PEOPLE_JSON=$(cat /tmp/pipeline_li_selected.json)
    local li_pending=0 enrich_err="" line_kind idx ename etitle eemail estatus lfull ltitle cname

    if [ -z "$DOMAIN" ] || ! check_apollo_credits; then
        [ -z "$DOMAIN" ] && log "  [SKIP] No domain — adding contacts without emails"
        while IFS=$'\x1f' read -r lfull ltitle <&7; do
            [ -n "$lfull" ] || continue
            _rb_save_pending "$venue_id" "$lfull" "$ltitle" "linkedin" && li_pending=$((li_pending + 1))
        done 7< <(printf '%s' "$PEOPLE_JSON" | _rb_py "$venue_id linkedin" python3 -c 'import json, sys
for p in json.load(sys.stdin):
    print("%s\x1f%s" % (p["full"], p.get("title", "")))')
        _rb_li_finish "$venue_id" "$li_block" "$li_fail" "$li_pending" "$count_before" "$deferred_before" "$credits_before" "${skv[@]}"
        return 0
    fi

    # Enrich via Apollo API — bulk match by name + domain. Names go in through the
    # environment: the old 'echo | python3 << PYEOF' fed the script to stdin and
    # dropped every name since March (PB-1).
    local ENRICH_RESULT rc
    ENRICH_RESULT=$(RB_LI_PEOPLE="$PEOPLE_JSON" RB_DOMAIN="$DOMAIN" APOLLO_API_KEY="$APOLLO_API_KEY" \
        APOLLO_API_BASE="$APOLLO_API_BASE" _rb_py "$venue_id linkedin-enrich" python3 - <<'PYEOF'
import json, os, re, sys
import requests

US = "\x1f"
people = json.loads(os.environ["RB_LI_PEOPLE"])
domain = os.environ["RB_DOMAIN"]


def clean(s):
    return re.sub(r"[\x1f\t\r\n]+", " ", str(s or "")).strip()


details = [{"first_name": p["first"], "last_name": p["last"], "domain": domain} for p in people]
for i in range(0, len(details), 10):
    batch = details[i:i + 10]
    try:
        r = requests.post(os.environ["APOLLO_API_BASE"] + "/people/bulk_match",
                          headers={"Content-Type": "application/json", "x-api-key": os.environ["APOLLO_API_KEY"]},
                          json={"details": batch, "reveal_personal_emails": False}, timeout=60)
    except requests.RequestException as e:
        print("ERROR" + US + "network_" + type(e).__name__)
        sys.exit(3)
    if r.status_code != 200:
        print("bulk_match HTTP %s: %s" % (r.status_code, r.text[:300]), file=sys.stderr)
        print("ERROR" + US + "http_%s" % r.status_code)
        sys.exit(3)
    data = r.json()
    matches = data.get("matches") or []
    credits = data.get("credits_consumed")
    if not isinstance(credits, int):
        credits = sum(1 for m in matches if m)
    print("CREDITS" + US + str(credits), flush=True)
    # Match j belongs to batch[j]; the old .index(None) repeated the first miss.
    for j in range(len(batch)):
        p = people[i + j]
        m = matches[j] if j < len(matches) else None
        if not m:
            print(US.join(["NOMATCH", str(i + j), "", "", "", "", clean(p["full"]), clean(p.get("title"))]))
            continue
        email = clean(m.get("email")).lower()
        if "@" not in email or email.startswith("email_not_unlocked"):
            email = ""
        name = clean(m.get("name")) or clean("%s %s" % (m.get("first_name") or "", m.get("last_name") or ""))
        print(US.join(["MATCH", str(i + j), name, clean(m.get("title")), email, clean(m.get("email_status")),
                       clean(p["full"]), clean(p.get("title"))]), flush=True)
PYEOF
    )
    rc=$?
    local credits
    credits=$(printf '%s\n' "$ENRICH_RESULT" | awk -F$'\x1f' '$1=="CREDITS"{s+=$2} END{print s+0}')
    _rb_apollo_credits_add "$credits"
    if [ $rc -ne 0 ]; then
        enrich_err=$(printf '%s\n' "$ENRICH_RESULT" | awk -F$'\x1f' '$1=="ERROR"{print $2; exit}')
        log "  [APOLLO ERROR] LinkedIn enrichment failed (${enrich_err:-crash}) — unprocessed names stay pending for retry"
        echo "error:enrich" > /tmp/pipeline_li_verdict
        enrich_err="enrich_${enrich_err:-crash}"
    fi

    # Process results in this shell (KNOWN_NAMES, credits and ZB counters persist)
    while IFS=$'\x1f' read -r line_kind idx ename etitle eemail estatus lfull ltitle <&7; do
        if [ "$line_kind" = "MATCH" ] && [ -n "$eemail" ] && [ "$estatus" != "unavailable" ]; then
            log "  >>> $ename ($etitle): $eemail [$estatus]"
            cname=$(_rb_py "$venue_id linkedin" python3 "$SCRIPT_DIR/outreach_rules.py" clean-name "$ename")
            verify_and_push "$eemail" "$venue_id" "${cname:-$lfull}" "${etitle:-$ltitle}" "linkedin+apollo" "external"
            KNOWN_NAMES="${KNOWN_NAMES}|||$(printf '%s' "${cname:-$lfull}" | tr '[:upper:]' '[:lower:]')"
        elif [ "$line_kind" = "MATCH" ]; then
            log "  --- $ename ($etitle): no email"
            _rb_save_pending "$venue_id" "$lfull" "$ltitle" "linkedin" && li_pending=$((li_pending + 1))
        elif [ "$line_kind" = "NOMATCH" ]; then
            log "  --- $lfull ($ltitle): not in Apollo"
            _rb_save_pending "$venue_id" "$lfull" "$ltitle" "linkedin" && li_pending=$((li_pending + 1))
        fi
    done 7< <(printf '%s\n' "$ENRICH_RESULT")

    log "  LinkedIn + Apollo API done. Credits used: $APOLLO_CREDITS_USED"
    _rb_li_finish "$venue_id" "$li_block" "${enrich_err:-$li_fail}" "$li_pending" "$count_before" "$deferred_before" "$credits_before" "${skv[@]}"
}

# Emit the [STEP] linkedin line: blocked > failed > ok (saved or pending) > empty.
_rb_li_finish() {
    local vid="$1" block="$2" fail="$3" pending="$4" cb="$5" db="$6" crb="$7"; shift 7
    local saved deferred status
    saved=$(( $(_rb_count_lines /tmp/pipeline_contacts_count) - cb ))
    deferred=$(( $(_rb_count_lines /tmp/pipeline_deferred_count) - db ))
    _rb_apollo_credits_sync
    if [ -n "$block" ]; then status="blocked"
    elif [ -n "$fail" ]; then status="failed"
    elif [ $((saved + deferred + pending)) -gt 0 ]; then status="ok"
    else status="empty"; fi
    _rb_emit_step "$vid" linkedin "$status" "$@" saved "$saved" pending "$pending" deferred "$deferred" \
        credits "$((APOLLO_CREDITS_USED - crb))" ${block:+reason "$block"} ${fail:+reason "$fail"}
}

# =================================================================
# REPORT GENERATION — produces HTML report from pipeline.log
# =================================================================
generate_report() {
    # C4, called at batch END (after postcheck): rebuilds this run's report from the run
    # log, the sheet, the candidate log, crawl coverage, the misses file and verify_run,
    # overwrites the report file registered for RUN_ID and updates that manifest entry.
    # One report + one manifest entry per RUN_ID, however many batches the run has.
    # Usage: generate_report RUN_LOG_FILE RUN_ID [VENUE_IDS_CSV]
    #   REPORTS_DIR=dir        use another reports/ dir (tests)
    #   REPORT_OFFLINE=1       no sheet / ZeroBounce reads (counts come from the log)
    #   REPORT_SKIP_VERIFY=1   don't run verify_run.sh
    #   RUN_MORE_BATCHES=1     more batches follow: entry stays "running" (venues stay hidden)
    local run_log="$1" run_id="$2" venue_csv="${3:-}"
    if [ -z "$run_id" ]; then
        log "[REPORT] FAILED: usage: generate_report RUN_LOG_FILE RUN_ID [VENUE_IDS_CSV]"
        return 1
    fi
    if [ -n "$run_log" ] && [ ! -f "$run_log" ]; then
        log "[REPORT] WARNING: run log not found: $run_log (using saved run state + sheet only)"
    fi
    log ""
    log "[REPORT] Generating report for run $run_id..."
    local out rc line
    out=$(_report_tool report "$run_log" "$run_id" "$venue_csv")
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        log "[REPORT] FAILED: report for $run_id was not written (exit $rc; see ${ERR_LOG:-${SCRIPT_DIR}/reports/runs/python-errors.log})"
        return 1
    fi
    while IFS= read -r line; do
        log "[REPORT] $line"
    done <<< "$out"
    return 0
}

manifest_register_run() {
    # C4, called at batch START: creates or extends this run's manifest entry (status
    # "running", venue_ids) and writes a stub report, so the app hides these venues until
    # the finished report is reviewed. Idempotent per RUN_ID; never removes entries.
    # Prints the report path on stdout (log lines go to stderr).
    local run_id="$1" venue_csv="$2" out rc
    if [ -z "$run_id" ] || [ -z "$venue_csv" ]; then
        log "[REPORT] FAILED: usage: manifest_register_run RUN_ID VENUE_IDS_CSV" >&2
        return 1
    fi
    out=$(_report_tool register "$run_id" "$venue_csv")
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        log "[REPORT] FAILED: could not register run $run_id in the manifest (exit $rc): its venues are NOT hidden in the app" >&2
        return 1
    fi
    log "[REPORT] Run $run_id registered (status running; venues hidden in the app until reviewed): $out" >&2
    echo "$out"
}

# Runs the report program. Python stderr is shown and appended to ERR_LOG (P9).
_report_tool() {
    local errf rc err_log="${ERR_LOG:-${SCRIPT_DIR}/reports/runs/python-errors.log}"
    errf=$(mktemp "${TMPDIR:-/tmp}/pipeline_report_err.XXXXXX") || return 1
    REPORT_SCRIPT_DIR="$SCRIPT_DIR" \
    REPORT_DIR="${REPORTS_DIR:-${SCRIPT_DIR}/reports}" \
    REPORT_APPS_SCRIPT_URL="$APPS_SCRIPT_URL" \
    REPORT_CANDIDATE_LOG="${REPORT_CANDIDATE_LOG:-$CANDIDATE_LOG}" \
    REPORT_COVERAGE_DIR="${REPORT_COVERAGE_DIR:-$COVERAGE_DIR}" \
    REPORT_ZB_RUN_ID="${ZB_RUN_ID:-}" \
        python3 - "$@" 2>"$errf" <<'REPORTPY'
import sys, os, re, json, html, time, hashlib, fcntl, tempfile, subprocess, urllib.parse
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor

# Run-report generator shared by manifest_register_run (batch start) and
# generate_report (batch end). Everything untrusted arrives via argv/env (P10).
ENV = os.environ
SCRIPT_DIR = ENV.get('REPORT_SCRIPT_DIR') or os.getcwd()
REPORT_DIR = ENV.get('REPORT_DIR') or os.path.join(SCRIPT_DIR, 'reports')
RUNS_DIR = os.path.join(REPORT_DIR, 'runs')
MANIFEST = os.path.join(REPORT_DIR, 'manifest.json')
CANDIDATE_LOG = ENV.get('REPORT_CANDIDATE_LOG') or os.path.join(REPORT_DIR, 'discovery-candidates.jsonl')
COVERAGE_DIR = ENV.get('REPORT_COVERAGE_DIR') or os.path.join(REPORT_DIR, 'web-coverage')
API = ENV.get('REPORT_APPS_SCRIPT_URL', '')
OFFLINE = ENV.get('REPORT_OFFLINE') == '1'
MORE_BATCHES = ENV.get('RUN_MORE_BATCHES') == '1'
APP_URL = 'https://atdi1029-byte.github.io/gig-outreach/?venue='
STUB_MARK = '<!-- report-status: running-stub -->'
VID_PAT = r'[A-Z]{2}-[A-Z0-9_]{2,6}-\d+'


def warn(msg):
    print('WARN: ' + msg, file=sys.stderr)


sys.path.insert(0, SCRIPT_DIR)
try:
    import outreach_rules as R
except Exception as exc:  # the report must still render without it
    R = None
    warn(f'outreach_rules import failed ({exc}); contact/social self-checks are limited')


def e(s):
    return html.escape('' if s is None else str(s), quote=True)


def safe_name(s):
    return re.sub(r'[^A-Za-z0-9_.-]', '_', s or '') or 'run'


def safe_url(u):
    u = (u or '').strip()
    return u if re.match(r'^https?://', u, re.I) else ''


def now_local():
    return datetime.now().astimezone()


def title_date(d):
    return f'{d:%B} {d.day}, {d.year}'


def parse_ids(csv):
    out = []
    for v in re.split(r'[,\s]+', csv or ''):
        v = v.strip()
        if v and v not in out:
            out.append(v)
    return out


# ------------------------------------------------------------------ manifest
def _lock_path():
    h = hashlib.md5(os.path.abspath(MANIFEST).encode()).hexdigest()[:10]
    return os.path.join(tempfile.gettempdir(), f'outreach-manifest-{h}.lock')


def _element_spans(text):
    dec = json.JSONDecoder()
    i = text.index('[') + 1
    n, spans = len(text), []
    while True:
        while i < n and text[i] in ' \t\r\n':
            i += 1
        if i >= n:
            raise ValueError('unterminated manifest array')
        if text[i] == ']':
            return spans
        _, end = dec.raw_decode(text, i)
        spans.append((i, end))
        i = end
        while i < n and text[i] in ' \t\r\n':
            i += 1
        if i < n and text[i] == ',':
            i += 1
        elif i < n and text[i] == ']':
            return spans
        else:
            raise ValueError(f'unexpected character in manifest at offset {i}')


def _fmt_entry(entry):
    # Same layout as the hand-written entries: 4-space keys, venue_ids on one line.
    return '{\n' + ',\n'.join(f'    {json.dumps(k)}: {json.dumps(v)}' for k, v in entry.items()) + '\n  }'


def atomic_write(path, content):
    d = os.path.dirname(path) or '.'
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(path) + '.', suffix='.tmp', dir=d)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class ManifestError(Exception):
    pass


def manifest_update(mutate):
    """mutate(entries) -> (index or None to insert at top, entry).

    Only our entry's text is replaced/inserted; every other entry stays byte-identical.
    A manifest that doesn't parse aborts the write (never start over from [])."""
    os.makedirs(REPORT_DIR, exist_ok=True)
    with open(_lock_path(), 'a') as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        text = open(MANIFEST, encoding='utf-8').read() if os.path.exists(MANIFEST) else ''
        if not text.strip():
            text = '[]\n'
        try:
            entries = json.loads(text)
            if not isinstance(entries, list):
                raise ValueError('not a JSON list')
            spans = _element_spans(text)
            if len(spans) != len(entries):
                raise ValueError('layout not understood')
        except ValueError as exc:
            raise ManifestError(f'{MANIFEST} is not valid ({exc}); it was NOT modified. Fix it by hand, then rerun.')
        idx, entry = mutate(entries)
        body = _fmt_entry(entry)
        if idx is None:
            if spans:
                s = spans[0][0]
                new_text = text[:s] + body + ',\n  ' + text[s:]
            else:
                new_text = '[\n  ' + body + '\n]\n'
        else:
            s, t = spans[idx]
            new_text = text[:s] + body + text[t:]
        check = json.loads(new_text)
        before = [x for i, x in enumerate(entries) if i != idx]
        after = check[1:] if idx is None else [x for i, x in enumerate(check) if i != idx]
        mine = check[0] if idx is None else check[idx]
        if before != after or mine != entry:
            raise ManifestError('manifest update would change other entries; not written')
        atomic_write(MANIFEST, new_text)
        return entry


def entry_ids(entry):
    ids = entry.get('venue_ids') or []
    if isinstance(ids, str):
        ids = ids.split(',')
    out = []
    for v in ids:
        v = str(v).strip()
        if v and v not in out:
            out.append(v)
    return out


def find_run(entries, run_id):
    for i, x in enumerate(entries):
        if isinstance(x, dict) and x.get('run_id') == run_id:
            return i
    return None


def pick_report_file(entries, when):
    used = {x.get('file') for x in entries if isinstance(x, dict)}
    base = when.strftime('%Y-%m-%d_%H-%M')
    for k in range(1, 100):
        name = base + ('.html' if k == 1 else f'-{k}.html')
        if name not in used and not os.path.exists(os.path.join(REPORT_DIR, name)):
            return name
    raise RuntimeError('no free report file name')


def running_texts(run_id, n, when):
    return (f'{title_date(when)} \u2014 Run {run_id} in progress ({n} venues so far)',
            f'Pipeline run {run_id} is in progress: {n} venues registered. They stay hidden in the app '
            f'until this report is complete and reviewed.')


def ensure_entry(run_id, ids, set_running):
    """Create or extend this run's manifest entry. Idempotent per run_id."""
    when = now_local()
    stamp = when.isoformat(timespec='seconds')

    def mutate(entries):
        i = find_run(entries, run_id)
        if i is None:
            title, summary = running_texts(run_id, len(ids), when)
            return None, {
                'file': pick_report_file(entries, when), 'date': when.strftime('%Y-%m-%d'),
                'title': title, 'summary': summary, 'venues': len(ids), 'verified_emails': 0,
                'apollo_credits': 0, 'venue_ids': ids, 'run_id': run_id, 'status': 'running',
                'started_at': stamp, 'updated_at': stamp,
            }
        entry = dict(entries[i])
        old = entry_ids(entry)
        merged = old + [v for v in ids if v not in old]
        if set_running:
            # A new batch after a finished report: bump rev so a review tick given to the
            # earlier version doesn't silently cover the new venues (app keys reviews by file[#rev]).
            if len(merged) > len(old) and entry.get('status') not in ('running', 'in_progress'):
                entry['rev'] = int(entry.get('rev') or 0) + 1
            entry['status'] = 'running'
            entry['title'], entry['summary'] = running_texts(run_id, len(merged), when)
        entry['venue_ids'] = merged
        entry['venues'] = len(merged)
        entry['updated_at'] = stamp
        return i, entry

    return manifest_update(mutate)


# ------------------------------------------------------------------ state + ledger
def state_path(run_id):
    return os.path.join(RUNS_DIR, safe_name(run_id) + '.report-state.json')


def load_state(run_id):
    p = state_path(run_id)
    if os.path.exists(p):
        try:
            with open(p, encoding='utf-8') as f:
                st = json.load(f)
            if isinstance(st, dict):
                st.setdefault('venues', {})
                st.setdefault('batches', [])
                return st
        except Exception as exc:
            warn(f'report state {p} unreadable ({exc}); rebuilding from this log only')
    return {'run_id': run_id, 'venues': {}, 'batches': []}


def load_ledger(run_id):
    p = os.path.join(RUNS_DIR, safe_name(run_id) + '.jsonl')
    reg, marks = {}, {}
    if not os.path.exists(p):
        return reg, marks, False
    with open(p, encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get('type') == 'venue' and row.get('step') == 'registered' and row.get('venue_id'):
                reg[row['venue_id']] = row
            elif row.get('type') == 'run':
                marks[row.get('step')] = row
    return reg, marks, True


# ------------------------------------------------------------------ log parsing
TS_PREFIX = re.compile(r'^(\d\d:\d\d:\d\d) (.*)$')
BR_PREFIX = re.compile(r'^\s*\[(\d\d:\d\d:\d\d)\] ?(.*)$')
START_RE = re.compile(r'=== Pipeline started (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ===')
STARTED_RE = re.compile(r'^\s*Started: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s*$')
HEADER_RE = re.compile(r'#{3,}\s*VENUE \[(\d+)/(\d+)\]:\s*(.*?)\s*#*\s*$')
PIPE_RE = re.compile(r'^\s*PIPELINE:\s*(.*)\s\(([^()]+)\)\s*$')
DONE_RE = re.compile(r'^\s*DONE:\s*(.*?)\s*\|\s*(\d+) min\s*\|\s*(\d\d:\d\d:\d\d)')
STEP_RE = re.compile(r'\[STEP\]\s+(\S+)\s+([A-Za-z_]+)\s+([A-Za-z_]+)\b(.*)$')
KV_RE = re.compile(r'([A-Za-z_][\w.-]*)=("[^"]*"|\'[^\']*\'|\S+)')
STEPHDR_RE = re.compile(r'={6,}\s*STEP (\w+):\s*(.*?)\s*={6,}')
SKIPLINE_RE = re.compile(r'✗\s+(.*)\s\(([^()\s]+)\)\s+—\s+(.*)$')
IDFIX_RE = re.compile(r"\[ID FIX\] '([^']*)' not in sheet — using real ID '([^']*)'")
SAVE_RE = re.compile(r'✓ (Added|Saved)([^:<]*):\s*(.*?)\s*<([^<>\s]+@[^<>\s]+)>(.*)$')
ENRICH_RE = re.compile(r'>>>\s+(.*):\s+(\S+@\S+?)(?:\s+\[([\w-]+)\])?\s*$')
PENDING_RE = re.compile(r'---\s+(.*):\s+(no email.*|not in Apollo.*)$')
APOLLO_BASE_RE = re.compile(r'\[APOLLO\] Credits used this run: (\d+)')
APOLLO_TOTAL_RE = re.compile(r'Apollo API done: (\d+) credits|LinkedIn \+ Apollo API done\. Credits used: (\d+)')
ZB_RE = re.compile(r'\[ZB SAFE\] (\S+@\S+) → ([\w-]+) \((.*)\)')
STATUS_SET_RE = re.compile(r'Setting status → (\w+)')
PY_ERR_RE = re.compile(r'^\s*(?:[A-Za-z_][\w.]*(?:Error|Exception)(?::|$)|Traceback \(most recent call last\))')
BASH_ERR_RE = re.compile(r'\.sh: line \d+: (.*)$')
BASH_FATAL_RE = re.compile(r'syntax error|command not found|unbound variable|bad substitution|unexpected|expression expected|Permission denied', re.I)
STEP_OF_HEADER = {'1': 'web', '1B': 'social', '1C': 'social', '2': 'social', '3': 'apollo',
                  '3B': 'apollo', '4': 'linkedin', '5': 'google'}
POSTCHECK_MARKS = ('AUTO-RUNNING POSTCHECK', 'POST-PIPELINE VERIFICATION', 'Post-Pipeline Check Started')


def split_name_title(s):
    """'John (Jack) Smith (Director (Events))' -> ('John (Jack) Smith', 'Director (Events)')."""
    s = (s or '').strip()
    if not s.endswith(')'):
        return s, ''
    depth = 0
    for i in range(len(s) - 1, -1, -1):
        if s[i] == ')':
            depth += 1
        elif s[i] == '(':
            depth -= 1
            if depth == 0:
                name, title = s[:i].strip(), s[i + 1:-1].strip()
                return name, ('' if title == 'None' else title)
    return s, ''


def parse_kv(rest):
    kv = {}
    for k, v in KV_RE.findall(rest or ''):
        if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
            v = v[1:-1]
        kv[k] = v
    return kv


def new_rec(vid, order):
    return {'venue_id': vid, 'name': '', 'website': '', 'order': order, 'attempts': 0, 'started': False,
            'done': False, 'elapsed_min': None, 'skip': '', 'log_status': '', 'steps': {}, 'legacy': {},
            'saved': [], 'titles': {}, 'pending': [], 'apollo_segments': [], 'zb_charged': 0,
            'zb_deferred': [], 'errors': [], 'notes': [], 'pages': [], 'home': {}, 'form': '',
            'crawl_summary': '', 'batch_started': '', 'batch_ended': '', 'log': '', 'flags': [],
            'apollo_candidates': [], 'watchdog': ''}


def add_unique(lst, item, limit=None):
    if item and item not in lst and (limit is None or len(lst) < limit):
        lst.append(item)


def parse_log(path):
    """Per-venue facts + per-batch facts from a pipeline run log (new [STEP] lines and old text)."""
    venues, order = {}, [0]
    batches, run_items, saved_global = [], [], []
    st = {'cur': None, 'pending': None, 'step': None, 'in_post': False, 'dt': None,
          'inv_apollo': 0, 'last_page': None, 'batch': None}
    idfix = {}

    def rec_for(vid):
        vid = idfix.get(vid, vid)
        if vid not in venues:
            order[0] += 1
            venues[vid] = new_rec(vid, order[0])
            venues[vid]['log'] = path
        return venues[vid]

    def start_batch(dt_str):
        b = {'log': path, 'started': dt_str or '', 'ended': '', 'venue_ids': [], 'mode': '',
             'complete': False, 'postcheck': False, 'items': [], 'stopped': ''}
        batches.append(b)
        st['batch'] = b
        return b

    def close_pending():
        p = st['pending']
        if p and p.get('skip') and not p.get('merged'):
            run_items.append({'kind': 'unresolved_skip', 'name': p['name'], 'reason': p['skip']})
        st['pending'] = None

    def leg(rec, step):
        return rec['legacy'].setdefault(step, {'ran': False, 'failed': [], 'skipped': '', 'via': ''})

    def page(rec, url, kind, via):
        pg = {'url': url, 'kind': kind, 'via': via, 'ok': None, 'emails': []}
        rec['pages'].append(pg)
        st['last_page'] = pg
        return pg

    with open(path, encoding='utf-8', errors='replace') as f:
        raw_lines = f.read().splitlines()

    for raw in raw_lines:
        t = raw
        hhmmss = None
        m = TS_PREFIX.match(t) or BR_PREFIX.match(t)
        if m:
            hhmmss, t = m.group(1), m.group(2)
        m = START_RE.search(t)
        if m:
            close_pending()
            st['cur'], st['step'], st['in_post'], st['inv_apollo'] = None, None, False, 0
            st['dt'] = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
            start_batch(m.group(1))
            continue
        m = STARTED_RE.match(t)
        if m:
            st['dt'] = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
        if not hhmmss:
            m = DONE_RE.match(t)
            if m:
                hhmmss = m.group(3)
        if hhmmss and st['dt'] is not None:
            cand = datetime.combine(st['dt'].date(), datetime.strptime(hhmmss, '%H:%M:%S').time())
            if cand < st['dt'] - timedelta(hours=1):
                cand += timedelta(days=1)
            st['dt'] = cand
        b = st['batch'] or start_batch('')
        if st['dt'] is not None:
            b['ended'] = st['dt'].strftime('%Y-%m-%d %H:%M:%S')
        cur = st['cur']

        # ---- run-level markers
        if t.startswith('BATCH MODE:'):
            b['mode'] = t.strip()
        if '=== BATCH COMPLETE ===' in t:
            b['complete'] = True
            st['cur'], st['step'] = None, None
            close_pending()
            continue
        if any(k in t for k in POSTCHECK_MARKS):
            b['postcheck'] = True
            st['in_post'], st['cur'], st['step'] = True, None, None
            close_pending()
            continue
        if re.search(r'\[CHROME\] (WARNING|FAIL)', t) or re.match(r'\s*PREFLIGHT (FAIL|WARN)\b', t):
            add_unique(b['items'], t.strip())
        if 'Paid verification paused' in t:
            add_unique(b['items'], 'ZeroBounce paid verification paused: ' + t.split('paused:', 1)[-1].strip(), None)
        if '[STOP] Apollo credit cap reached' in t:
            add_unique(b['items'], t.strip())
        m = re.search(r'\[RUN\] ((?:STOPPED|ABORTED)\b.*)$', t)
        if m:
            b['stopped'] = m.group(1).strip()
            add_unique(b['items'], '[RUN] ' + m.group(1).strip())
        m = re.search(r'\[WATCHDOG\] (.*)$', t)
        if m:
            mid = re.search(r'\((' + VID_PAT + r')\)', m.group(1))
            target = rec_for(mid.group(1)) if mid else st['cur']
            if target is not None:
                target['watchdog'] = m.group(1).strip()[:200]
            else:
                add_unique(b['items'], '[WATCHDOG] ' + m.group(1).strip()[:200])
        m = re.search(r'\[WRITE\] FAILED (.*)$', t)
        if m:
            mid = re.search(r'\bfor (' + VID_PAT + r')\b', m.group(1))
            target = rec_for(mid.group(1)) if mid else st['cur']
            if target is not None:
                add_unique(target['flags'], ['fail', 'sheet write failed: ' + m.group(1).strip()[:200]], 8)
            else:
                add_unique(b['items'], '[WRITE] FAILED ' + m.group(1).strip()[:200])
        m = IDFIX_RE.search(t)
        if m:
            idfix[m.group(1)] = m.group(2)

        # ---- structured step lines (C3) attribute by id, wherever they appear
        m = STEP_RE.search(t)
        if m:
            vid, step, status, rest = m.group(1), m.group(2).lower(), m.group(3).lower(), m.group(4)
            rec = rec_for(vid)
            rec['steps'][step] = {'status': status, 'kv': parse_kv(rest), 'raw': t.strip()[:300]}
            if st['pending'] and not st['cur'] and not st['in_post']:
                p = st['pending']
                rec['name'] = rec['name'] or p['name']
                if p.get('skip'):
                    rec['skip'] = rec['skip'] or p['skip']
                for n in p.get('notes') or []:
                    add_unique(rec['notes'], n)
                p['merged'] = True
                st['pending'] = None
                st['cur'] = rec
            add_unique(b['venue_ids'], rec['venue_id'])
            if step == 'postcheck':
                b['postcheck'] = True
            continue

        m = HEADER_RE.search(t)
        if m:
            close_pending()
            st['cur'], st['step'] = None, None
            name = m.group(3)
            mid = re.search(r'\((' + VID_PAT + r')\)\s*$', name)
            st['pending'] = {'name': re.sub(r'\s*\(' + VID_PAT + r'\)\s*$', '', name).strip(), 'skip': ''}
            if mid:
                rec = rec_for(mid.group(1))
                rec['name'] = rec['name'] or st['pending']['name']
                st['pending']['merged'] = True
                st['pending']['rec'] = rec
            continue

        m = SKIPLINE_RE.search(t)
        if m:
            rec = rec_for(m.group(2).strip())
            rec['name'] = rec['name'] or m.group(1).strip()
            rec['skip'] = rec['skip'] or m.group(3).strip()
            add_unique(b['venue_ids'], rec['venue_id'])
            continue

        m = PIPE_RE.match(t)
        if m and not st['in_post']:
            rec = rec_for(m.group(2).strip())
            rec['name'] = m.group(1).strip() or rec['name']
            rec['attempts'] += 1
            rec['started'] = True
            if rec['attempts'] > 1 and not rec['done']:
                add_unique(rec['notes'], 'restarted: an earlier attempt did not finish')
            rec['done'] = False
            rec['batch_started'] = b['started']
            rec['apollo_segments'].append({'base': st['inv_apollo'], 'base_seen': False, 'max': None})
            p = st['pending']
            if p:
                if p.get('skip'):
                    rec['skip'] = p['skip']
                for n in p.get('notes') or []:
                    add_unique(rec['notes'], n)
                p['merged'] = True
                st['pending'] = None
            st['cur'], st['step'], st['last_page'] = rec, 'setup', None
            add_unique(b['venue_ids'], rec['venue_id'])
            continue

        if st['pending'] and not cur:
            p = st['pending']
            if p.get('rec'):
                cur = st['cur'] = p['rec']
            else:
                mm = re.search(r'\[SKIP\] (Already \w+|Venue status prevents[^:]*: \S+)', t)
                if mm:
                    p['skip'] = mm.group(1)
                if '[LOOKUP] No website found' in t:
                    p.setdefault('notes', []).append('no website found (Google lookup)')
                continue

        if st['in_post'] and not cur:
            m = SAVE_RE.search(t)
            if m:
                add_unique(saved_global, m.group(4).lower())
            continue
        if not cur:
            continue
        rec = cur
        rec['batch_ended'] = b['ended']

        m = DONE_RE.match(t)
        if m:
            rec['done'] = True
            rec['elapsed_min'] = int(m.group(2))
            st['cur'], st['step'] = None, None
            continue

        m = STEPHDR_RE.search(t)
        if m:
            step = STEP_OF_HEADER.get(m.group(1).upper(), m.group(1).lower())
            st['step'] = step
            L = leg(rec, step)
            sk = re.search(r'\(SKIPPED\s*[—-]\s*([^)]*)\)', m.group(2))
            if sk:
                L['skipped'] = sk.group(1).strip()
            else:
                L['ran'] = True
            continue
        step = st['step'] or 'setup'

        # ---- errors: attribute a crash to the step that was running
        if PY_ERR_RE.match(t) and not t.lstrip().startswith('Traceback'):
            add_unique(leg(rec, step)['failed'], 'python error: ' + t.strip()[:160], 5)
            add_unique(rec['errors'], f'{step}: {t.strip()[:200]}', 20)
            continue
        m = BASH_ERR_RE.search(t)
        if m and 'Broken pipe' not in t:
            if BASH_FATAL_RE.search(m.group(1)):
                add_unique(leg(rec, step)['failed'], 'shell error: ' + m.group(1).strip()[:160], 5)
            add_unique(rec['errors'], f'{step}: {t.strip()[:200]}', 20)
            continue
        if '[API ERROR]' in t:
            add_unique(rec['notes'], t.strip()[:220], 12)
        m = re.search(r'\[GOOGLE BLOCKED\] (.*)$', t)
        if m:
            add_unique(rec['flags'], ['warn', 'Google search blocked: ' + m.group(1).strip()[:160]], 6)
        m = re.search(r'\[SOCIAL REJECTED\] (.*)$', t)
        if m:
            add_unique(rec['flags'], ['warn', 'social link not saved: ' + m.group(1).strip()[:160]], 6)
        m = re.search(r'\[SOCIAL EXISTS\] (.*)$', t)
        if m:
            add_unique(rec['flags'], ['check', m.group(1).strip()[:200]], 6)
        m = re.search(r'\[CAP\] (\d+ more relevant people not enriched[^:]*)', t)
        if m:
            add_unique(rec['flags'], ['check', 'Apollo: ' + m.group(1).strip()], 3)
        m = re.search(r'\[APOLLO CANDIDATE\] (.*?)(?: — shared brand domain.*)?$', t)
        if m:
            add_unique(rec['apollo_candidates'], m.group(1).strip()[:120], 40)

        # ---- contacts, titles, pending people
        m = SAVE_RE.search(t)
        if m:
            qual, name, email, tail = m.group(2), m.group(3).strip(), m.group(4).lower(), m.group(5)
            q = (qual + ' ' + tail).lower()
            verified = 'unverified' if 'unverified' in q or 'deferred' in q else ('role' if 'role' in q else 'valid')
            if name.lower() in (email, '(no name)', 'none'):
                name = ''
            if not any(c['email'] == email for c in rec['saved']):
                rec['saved'].append({'name': name, 'email': email, 'verified': verified, 'step': step})
            add_unique(saved_global, email)
            continue
        m = ENRICH_RE.search(t)
        if m:
            _, title = split_name_title(m.group(1))
            if title:
                rec['titles'][m.group(2).lower()] = title
            continue
        m = PENDING_RE.search(t)
        if m:
            name, title = split_name_title(m.group(1))
            if name and not any(p['name'] == name for p in rec['pending']):
                rec['pending'].append({'name': name, 'title': title, 'why': m.group(2).strip()[:60]})
            continue

        # ---- credits / verification
        m = APOLLO_BASE_RE.search(t)
        if m and rec['apollo_segments']:
            seg = rec['apollo_segments'][-1]
            if not seg['base_seen']:
                seg['base'], seg['base_seen'] = int(m.group(1)), True
        m = APOLLO_TOTAL_RE.search(t)
        if m and rec['apollo_segments']:
            val = int(m.group(1) or m.group(2))
            seg = rec['apollo_segments'][-1]
            seg['max'] = max(seg['max'] or 0, val)
            st['inv_apollo'] = val
        m = ZB_RE.search(t)
        if m:
            if 'charged=True' in m.group(3):
                rec['zb_charged'] += 1
            if m.group(2) == 'deferred':
                add_unique(rec['zb_deferred'], m.group(1).lower())
        m = STATUS_SET_RE.search(t)
        if m:
            rec['log_status'] = m.group(1)
            L = leg(rec, 'final')
            L['ran'] = True

        # ---- legacy step outcomes
        if '[SKIP] No website URL' in t:
            leg(rec, 'web')['skipped'] = 'no_website'
        if 'Chrome scrape failed' in t:
            leg(rec, 'web')['via'] = 'chrome failed'
        if '[CURL FALLBACK] Success' in t:
            leg(rec, 'web')['via'] = 'curl'
            rec['home']['via'] = 'curl'
        if '[ERROR] Both Chrome and curl' in t:
            add_unique(leg(rec, 'web')['failed'], 'homepage could not be fetched (Chrome and curl both failed)')
            rec['home']['via'] = 'failed'
        if 'Recursive discovery audit failed' in t:
            add_unique(leg(rec, 'web')['failed'], 'static site crawl failed')
        if re.search(r'Found:\s+\(domain: , org_id: \)', t):
            add_unique(leg(rec, 'apollo')['failed'], 'org lookup returned nothing')
        if '[SKIP] Apollo step' in t:
            leg(rec, 'apollo')['skipped'] = 'credit_cap'
        if 'APOLLO MISMATCH' in t:
            add_unique(rec['notes'], t.strip()[:220], 12)
        m = re.search(r"LinkedIn verdict '([^']*)'", t)
        if m:
            add_unique(leg(rec, 'linkedin')['failed'], f"no results (verdict '{m.group(1)}')")
        if '[LOOKUP] No website found' in t:
            add_unique(rec['notes'], 'no website found (Google lookup)')
        if re.search(r'Website (DNS failure|returned (404|410))', t):
            add_unique(rec['notes'], t.strip()[:160])

        # ---- website pages (what was visited and what it yielded)
        m = re.search(r'Opening in Chrome: (\S+)', t)
        if m:
            pg = page(rec, m.group(1), 'home', 'chrome')
            rec['home'] = {'url': m.group(1), 'via': 'chrome'}
            continue
        if '[CURL FALLBACK]' in t and st['last_page'] is not None and st['last_page'] in rec['pages']:
            st['last_page']['via'] = 'curl'
            continue
        m = re.search(r'(\[LOCATION\] Re-scraped: )?Emails: (\d+) \| FB: (\S+) \| IG: (\S+)(?: \| Contact Form: (\S+))?', t)
        if m:
            if not m.group(1):
                rec['home'].update({'emails': int(m.group(2)), 'fb': m.group(3), 'ig': m.group(4)})
                homepg = next((p for p in rec['pages'] if p['kind'] == 'home'), None)
                if homepg is not None and rec['home'].get('via') != 'failed':
                    homepg['via'] = rec['home'].get('via', homepg['via'])
                    homepg['ok'] = True
            if m.group(5) and m.group(5) != 'none':
                rec['form'] = m.group(5)
            continue
        m = re.search(r'Validating contact form URL: (\S+)', t)
        if m:
            page(rec, m.group(1), 'form', 'chrome')
            continue
        m = re.search(r'Found on (?:contact page|subpage): (.+)$', t)
        if m and st['last_page'] is not None and st['last_page'] in rec['pages']:
            for em in re.split(r'[,\s]+', m.group(1)):
                if '@' in em:
                    add_unique(st['last_page']['emails'], em.lower())
            st['last_page']['ok'] = True
            continue
        m = re.search(r'\[LOCATION\] (?:Found|Re-scraping location page): (\S+)', t)
        if m:
            page(rec, m.group(1), 'location', 'chrome')
            continue
        m = re.search(r'\[PROBE\] Found: (\S+)', t)
        if m:
            page(rec, m.group(1), 'probe', 'curl')['ok'] = True
            continue
        m = re.search(r'Crawling subpage \((\d+)\): (\S+)', t)
        if m:
            page(rec, m.group(2), 'subpage', 'chrome')
            continue
        m = re.search(r'\[CONTACT\] Probing (\S+)', t)
        if m:
            page(rec, m.group(1), 'contact probe', 'chrome')
            continue
        m = re.search(r'\[CONTACT\] Found emails on (\S+)', t)
        if m and st['last_page'] is not None:
            st['last_page']['ok'] = True
            continue
        m = re.search(r'\[CONTACT FORM\] Found on subpage(?: \(curl\))?: (\S+)', t)
        if m:
            rec['form'] = rec['form'] or m.group(1)
            continue
        m = re.search(r'SKIP \(other location: [^)]*\): (\S+)', t)
        if m:
            page(rec, m.group(1), 'subpage', 'skipped (other location)')['ok'] = False
            continue
        if '✗ No submittable form found' in t:
            rec['form'] = ''
            add_unique(rec['notes'], 'contact form URL cleared: no submittable form found')
        m = re.search(r'\[COVERAGE\] (pages=.*)$', t)
        if m:
            rec['crawl_summary'] = m.group(1).strip()

    close_pending()
    for rec in venues.values():
        segs = rec.pop('apollo_segments', [])
        rec['apollo_credits'] = sum(max(0, s['max'] - s['base']) for s in segs if s['max'] is not None)
    return venues, batches, run_items, saved_global, idfix


def merge_rec(old, new):
    """Same venue seen in an earlier batch log (logs may be per batch): keep both histories."""
    if not old or old.get('log') == new.get('log'):
        return new
    out = dict(new)
    out['attempts'] = old.get('attempts', 0) + new.get('attempts', 0)
    out['apollo_credits'] = old.get('apollo_credits', 0) + new.get('apollo_credits', 0)
    out['zb_charged'] = old.get('zb_charged', 0) + new.get('zb_charged', 0)
    for k in ('saved', 'pending', 'zb_deferred', 'errors', 'notes', 'flags', 'apollo_candidates'):
        seen = list(new.get(k) or [])
        for x in old.get(k) or []:
            if x not in seen:
                seen.append(x)
        out[k] = seen
    out['titles'] = dict(old.get('titles') or {}, **(new.get('titles') or {}))
    if not new.get('pages'):
        out['pages'] = old.get('pages') or []
    steps = dict(old.get('steps') or {})
    steps.update(new.get('steps') or {})
    out['steps'] = steps
    out['name'] = new.get('name') or old.get('name')
    return out


# ------------------------------------------------------------------ external data
def fetch_detail(vid):
    if not API:
        return None, 'APPS_SCRIPT_URL not set'
    url = API + '?' + urllib.parse.urlencode({'action': 'venue_detail', 'venue_id': vid})
    err = ''
    for _ in range(2):
        try:
            out = subprocess.run(['curl', '-sL', '--max-time', '25', url],
                                 capture_output=True, text=True, timeout=40)
            d = json.loads(out.stdout)
            if d.get('status') == 'ok' and isinstance(d.get('venue'), dict):
                return d, ''
            err = f"status={d.get('status')} {str(d.get('message', ''))[:80]}".strip()
        except Exception as exc:
            err = f'{type(exc).__name__}: {exc}'[:160]
        time.sleep(1)
    return None, err


def fetch_sheet(vids):
    fixture = ENV.get('REPORT_SHEET_FIXTURE')
    if fixture:  # tests: <dir>/<venue_id>.json holds a venue_detail response
        out = {}
        for vid in vids:
            p = os.path.join(fixture, safe_name(vid) + '.json')
            out[vid] = (json.load(open(p)), '') if os.path.exists(p) else (None, 'no fixture')
        return out, ''
    if OFFLINE:
        return {}, 'offline (REPORT_OFFLINE=1)'
    if not API:
        return {}, 'APPS_SCRIPT_URL not set'
    out = {}
    with ThreadPoolExecutor(max_workers=6) as ex:
        for vid, res in zip(vids, ex.map(fetch_detail, vids)):
            out[vid] = res
    return out, ''


def to_epoch(local_str):
    try:
        return time.mktime(datetime.strptime(local_str, '%Y-%m-%d %H:%M:%S').timetuple())
    except Exception:
        return None


def iso_epoch(s):
    try:
        return datetime.fromisoformat(str(s).replace('Z', '+00:00')).timestamp()
    except Exception:
        return None


CONFIDENT_REJECT = re.compile(r'junk|hard_reject|placeholder|malformed|invalid|owner|long_digits|hash|image|too_long|noreply|dup', re.I)


def classify_candidate(disps):
    saved = [d for d in disps if d.startswith('saved')]
    if saved:
        return ('deferred' if all('deferred' in d for d in saved) else 'saved'), saved[-1]
    finals = [d for d in disps if d not in ('discovered', 'already_known')]
    if not finals:
        return ('known', 'already_known') if 'already_known' in disps else ('undecided', 'no decision logged')
    last = finals[-1]
    if 'deferred' in last:
        return 'deferred', last
    return 'rejected', last


def load_candidates(vids, windows, run_id):
    if not os.path.exists(CANDIDATE_LOG):
        return {}, f'candidate log not found ({CANDIDATE_LOG})'
    rows, bad = {}, 0
    with open(CANDIDATE_LOG, encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                row = json.loads(line)
            except Exception:
                bad += 1
                continue
            vid = row.get('venue_id')
            if vid not in vids:
                continue
            ts = iso_epoch(row.get('timestamp'))
            lo, hi = windows.get(vid, (None, None))
            in_win = ts is not None and lo is not None and lo <= ts <= hi
            if not (row.get('run_id') == run_id or in_win):
                continue
            em = str(row.get('email') or '').lower().strip()
            ckind = str(row.get('kind') or 'email').lower()
            value = em or str(row.get('value') or '').strip()
            if not value:
                continue
            key = em or f'{ckind}:{value.lower()}'
            c = rows.setdefault(vid, {}).setdefault(key, {'email': value, 'ckind': 'email' if em else ckind, 'disps': [],
                                                           'name': '', 'title': '', 'source': '', 'evidence_url': ''})
            c['disps'].append(str(row.get('disposition') or ''))
            for k in ('name', 'title', 'source', 'evidence_url'):
                if row.get(k):
                    c[k] = str(row[k])
    out = {}
    for vid, by in rows.items():
        lst = []
        for c in by.values():
            c['kind'], c['reason'] = classify_candidate(c['disps'])
            lst.append(c)
        out[vid] = lst
    return out, (f'{bad} unreadable candidate lines' if bad else '')


def uncertain(c):
    """A rejected/deferred find a human might still want (recall safety net)."""
    if c['kind'] in ('deferred', 'undecided'):
        return c['kind'] == 'undecided' or not c.get('on_sheet')
    if c['kind'] != 'rejected':
        return False
    if c.get('ckind', 'email') == 'email' and R is not None and (R.junk_reason(c['email']) or R.hard_reject_reason(c['email'])):
        return False
    if CONFIDENT_REJECT.search(c['reason']) and not (R and 'do_not_mail' in c['reason'] and R.is_role_email(c['email'])):
        return False
    return True


def maybe_person(c):
    """Uncertain find that looks like a personal mailbox (not info@/events@)."""
    if c.get('ckind', 'email') != 'email':
        return uncertain(c) and c['kind'] == 'rejected' and c['ckind'] in ('contact', 'person')
    return uncertain(c) and c['kind'] == 'rejected' and not (R is not None and R.is_role_email(c['email']))


def load_coverage(vid, lo, hi):
    p = os.path.join(COVERAGE_DIR, safe_name(vid) + '.json')
    if not os.path.exists(p):
        return None, 'no crawl coverage file'
    try:
        with open(p, encoding='utf-8') as f:
            d = json.load(f)
    except Exception as exc:
        return None, f'coverage file unreadable ({exc})'
    ts = iso_epoch(d.get('coverage_generated_at'))
    if lo is not None and ts is not None and not (lo - 600 <= ts <= hi + 600):
        return None, 'crawl coverage file is from another run'
    return d, ''


def load_misses(run_id):
    p = os.path.join(RUNS_DIR, safe_name(run_id) + '.misses.jsonl')
    if not os.path.exists(p):
        return None, 0
    items, bad, seen = [], 0, set()
    with open(p, encoding='utf-8', errors='replace') as f:
        for line in f:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                bad += 1
                continue
            if not isinstance(row, dict) or row.get('pipeline_had') in (True, 'true', 'True'):
                continue
            key = (row.get('venue_id'), str(row.get('kind', '')).lower(), str(row.get('value', '')).strip().lower())
            if key in seen:
                continue
            seen.add(key)
            items.append(row)
    return items, bad


PENDING_RUN_MARKS = ('report', 'taste_review')


def run_verify(run_id, report_file):
    """verify_run.sh --json --embed-report: the gate writes its own block into the report."""
    vr = os.path.join(SCRIPT_DIR, 'verify_run.sh')
    if ENV.get('REPORT_SKIP_VERIFY') == '1':
        return {'ran': False, 'why': 'skipped (REPORT_SKIP_VERIFY=1)'}
    if not os.path.exists(vr):
        return {'ran': False, 'why': 'verify_run.sh not found'}
    args = ['bash', vr, run_id, '--json', '--embed-report', report_file] + (['--no-sheet'] if OFFLINE else [])
    env = dict(ENV, RUN_ID=run_id, REPORTS_DIR=REPORT_DIR)
    if ENV.get('REPORT_SHEET_FIXTURE'):
        env['VERIFY_SHEET_FIXTURE_DIR'] = ENV['REPORT_SHEET_FIXTURE']
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=1200, cwd=SCRIPT_DIR, env=env)
    except subprocess.TimeoutExpired:
        return {'ran': False, 'why': 'verify_run.sh timed out after 20 min'}
    except Exception as exc:
        return {'ran': False, 'why': f'verify_run.sh could not start: {exc}'}
    try:
        res = json.loads(p.stdout)
        if not isinstance(res, dict) or 'verdict' not in res:
            raise ValueError('no verdict in output')
    except Exception as exc:
        tail = [x for x in ((p.stderr or '') + '\n' + (p.stdout or '')).splitlines() if x.strip()][-1:] or ['no output']
        return {'ran': False, 'why': f'verify_run.sh exit {p.returncode}, no JSON verdict ({exc}): {tail[0][:200]}'}
    res['ran'] = True
    res['rc'] = p.returncode
    # report/taste_review can only be marked after this report exists: not a problem yet
    missing = [m for m in res.get('missing') or [] if isinstance(m, (list, tuple)) and len(m) >= 2]
    # Manual ledger marks are the session's follow-up step, not a pipeline problem: one summary line.
    res['pending_marks'] = [m for m in missing if len(m) > 2 and re.search(r'\bno mark\b|not recorded', str(m[2]))]
    res['missing_now'] = [m for m in missing if m not in res['pending_marks']
                          and not (m[0] == '(run)' and m[1] in PENDING_RUN_MARKS)]
    res['review_items'] = [r for r in res.get('review') or [] if isinstance(r, dict) and r.get('kind') != 'miss']
    res['gate_clean'] = not res['missing_now'] and not res['pending_marks'] and not res['review_items'] and \
        not any(isinstance(r, dict) and r.get('kind') == 'miss' for r in res.get('review') or [])
    return res


def zb_budget():
    zb_run = ENV.get('REPORT_ZB_RUN_ID', '')
    guard = os.path.join(SCRIPT_DIR, 'zerobounce_guard.py')
    if not zb_run or not os.path.exists(guard):
        return None
    try:
        p = subprocess.run([sys.executable, guard, 'budget', '--run-id', zb_run] + (['--no-balance'] if OFFLINE else []),
                           capture_output=True, text=True, timeout=60, cwd=SCRIPT_DIR)
        return json.loads(p.stdout)
    except Exception as exc:
        warn(f'zerobounce_guard budget failed: {exc}')
        return None


# ------------------------------------------------------------------ evaluation
REQUIRED_STEPS = ('web', 'social', 'apollo', 'linkedin', 'final')
FINAL_FAIL_TEXT = {
    'timeout': 'killed by the watchdog after {minutes} min',
    'crash': 'the venue run crashed (exit {exit})',
    'aborted': 'the run was aborted (signal {signal}) while this venue was running',
    'status_write_failed': 'final status was not written to the sheet (sheet: {status}, wanted: {wanted})',
    'sheet_unreadable': 'the sheet could not be read to set the final status',
    'venue_not_in_sheet': 'venue_id is not in the sheet; nothing was run',
    'name_id_mismatch': 'batch name and venue_id point at different sheet venues; nothing was run',
    'missing_venue_id': 'no venue_id; nothing was run',
}
RESUMABLE = ('timeout', 'crash', 'aborted')
NOT_RUN = RESUMABLE + ('venue_not_in_sheet', 'name_id_mismatch', 'missing_venue_id')
COVER_COLS = ('web', 'social', 'apollo', 'linkedin', 'google', 'postcheck', 'final')
GAP_SKIP_RE = re.compile(r'cap|credit|budget|quota|wall|login|captcha|disabled|skip_|timeout|error|fail|crash|unavailable|chrome', re.I)
FAMILIES = (
    ('contact', re.compile(r'contact|get-in-touch|inquir|enquir|reach-us|find-us|visit|location', re.I)),
    ('about', re.compile(r'about|our-story|story|history|who-we-are', re.I)),
    ('events', re.compile(r'event|private|part(y|ies)|wedding|banquet|cater|group|meeting|celebrat|function|book', re.I)),
    ('team', re.compile(r'team|staff|leadership|people|management|directory|meet-|owner|board|chef', re.I)),
)
USABLE = ('valid', 'role', 'unverified')   # Alex, Sep 25: ZB-deferred emails are saved as unverified
REVERIFY_HINT = './reverify.sh --unverified checks them once ZeroBounce credits are topped up'


def norm_url(u):
    u = (u or '').strip().lower()
    u = re.sub(r'^https?://', '', u)
    u = re.sub(r'^www\.', '', u)
    return u.split('#')[0].rstrip('/')


def url_path(u):
    try:
        p = urllib.parse.urlparse(u if '://' in u else 'http://' + u)
        return (p.path or '/') + (('?' + p.query) if p.query else '')
    except Exception:
        return u


def web_pages(rec, cov):
    """Merge browser/curl pages from the log with the static crawl's pages, keyed by URL."""
    pages = {}
    for p in rec.get('pages') or []:
        k = norm_url(p['url'])
        q = pages.setdefault(k, {'url': p['url'], 'how': [], 'ok': None, 'emails': [], 'kind': p['kind']})
        add_unique(q['how'], p['via'])
        if p['ok'] is not None:
            q['ok'] = bool(q['ok']) or p['ok'] if q['ok'] is not None else p['ok']
        for x in p['emails']:
            add_unique(q['emails'], x)
        if p['kind'] == 'home':
            q['kind'] = 'home'
    for p in (cov or {}).get('pages') or []:
        u = p.get('url') or ''
        k = norm_url(u)
        q = pages.setdefault(k, {'url': u, 'how': [], 'ok': None, 'emails': [], 'kind': 'crawl'})
        add_unique(q['how'], 'crawl')
        ok = bool(p.get('ok'))
        q['ok'] = ok if q['ok'] is None else (q['ok'] or ok)
        for x in p.get('emails') or []:
            add_unique(q['emails'], str(x).lower())
    for p in (cov or {}).get('pdfs') or []:
        u = p.get('url') or ''
        q = pages.setdefault(norm_url(u), {'url': u, 'how': [], 'ok': None, 'emails': [], 'kind': 'pdf'})
        add_unique(q['how'], 'pdf')
        q['ok'] = bool(p.get('ok'))
        for x in p.get('emails') or []:
            add_unique(q['emails'], str(x).lower())
    return list(pages.values())


def page_family(p, site=''):
    path = url_path(p['url']).lower()
    if p.get('kind') == 'home' or path in ('/', '', '/index.html', '/home') or \
            (site and norm_url(p['url']) == norm_url(site)):
        return 'home'
    for fam, rx in FAMILIES:
        if rx.search(path):
            return fam
    return ''


def family_status(pages, site=''):
    fam = {}
    for p in pages:
        f = page_family(p, site)
        if not f:
            continue
        cur = fam.get(f, '')
        if p['ok'] or p['emails']:
            fam[f] = 'ok'
        elif p['ok'] is None and cur != 'ok':
            fam[f] = 'tried'
        elif p['ok'] is False and cur == '':
            fam[f] = 'failed'
    return fam


def social_problem(url, venue_name, venue_site):
    u = (url or '').strip()
    if not u:
        return ''
    low = u.lower()
    if re.search(r'profile\.php|sharer|share\.php|/groups/|/people/|/p/|/reel/|/explore/|/hashtag/', low):
        return 'not a page URL'
    m = re.search(r'(?:facebook|instagram)\.com/([^/?#]+)', low)
    handle = m.group(1) if m else ''
    if not handle:
        return 'no page handle'
    if R is None or not venue_name:
        return ''
    words = re.sub(r'[._-]+', ' ', handle)
    if R.org_name_matches(words, venue_name) or R.freemail_linked_to_venue(handle, venue_name):
        if venue_site and R.is_shared_domain(venue_site):
            brand = R.registrable_domain(venue_site).split('.')[0]
            if brand and brand in handle:
                return f'brand/chain account ({handle}) on a property of {R.registrable_domain(venue_site)}'
        return ''
    return f"handle '{handle}' doesn't match the venue name"


def contact_problem(c, venue_name, venue_site):
    em = (c.get('email') or '').lower()
    probs = []
    nm = c.get('name') or ''
    if '*' in nm:
        probs.append('masked name')
    elif nm and em and re.sub(r'[^a-z]', '', nm.lower()) == re.sub(r'[^a-z]', '', em.split('@', 1)[0]):
        probs.append(f"name '{nm}' was made from the email address")
    elif nm and R is not None and not R.is_real_person_name(nm) and not (R.is_role_email(em) if em else False):
        probs.append(f"name '{nm}' doesn't look like a person")
    if em and R is not None:
        r = R.junk_reason(em) or R.hard_reject_reason(em)
        if r:
            probs.append(r)
        vreg = R.registrable_domain(venue_site) if venue_site else ''
        ereg = R.registrable_domain(em.split('@', 1)[1]) if '@' in em else ''
        if vreg and ereg and ereg != vreg and ereg not in R.FREEMAIL_DOMAINS and not R.is_non_venue_host(venue_site):
            probs.append(f'off-domain ({ereg} vs {vreg})')
    return probs


def evaluate(run_id, vids, venues, sheet, sheet_err, cands, misses, ledger_reg, batches, run_items, saved_global):
    items = []  # {vid, sev: fail|warn|check, text}
    rows = []
    any_step_lines = any(v.get('steps') for v in venues.values())
    postcheck_ran = any(b.get('postcheck') for b in batches)
    misses_by = {}
    for mi in misses or []:
        misses_by.setdefault(mi.get('venue_id'), []).append(mi)

    for vid in vids:
        rec = venues.get(vid)
        res, err = sheet.get(vid, (None, sheet_err or 'not fetched'))
        sv = (res or {}).get('venue') or {}
        contacts = (res or {}).get('contacts') or []
        reg = ledger_reg.get(vid, {})
        name = sv.get('name') or (rec or {}).get('name') or reg.get('venue_name') or vid
        site = sv.get('website') or reg.get('website') or (rec or {}).get('home', {}).get('url') or ''
        row = {'vid': vid, 'name': name, 'site': site, 'category': sv.get('category', ''),
               'city': sv.get('city') or reg.get('city', ''), 'state': sv.get('state') or reg.get('state', ''),
               'sheet_status': sv.get('status', ''), 'fb': sv.get('facebook', ''), 'ig': sv.get('instagram', ''),
               'form': sv.get('contact_form', '') or (rec or {}).get('form', ''), 'rec': rec or {},
               'sheet_ok': res is not None, 'contacts': contacts, 'cands': cands.get(vid, []),
               'misses': misses_by.get(vid, []), 'issues': [], 'gaps': 0}
        rows.append(row)

        def add(sev, text, gap=False):
            row['issues'].append((sev, text))
            items.append({'vid': vid, 'sev': sev, 'text': text})
            if gap:
                row['gaps'] += 1

        sheet_emails = {str(c.get('email') or '').lower() for c in contacts}
        for c in row['cands']:
            c['on_sheet'] = c['email'].lower() in sheet_emails
        saved_this_run = {c['email'] for c in (rec or {}).get('saved', [])} | set(saved_global)
        saved_this_run |= {c['email'] for c in row['cands'] if c['kind'] in ('saved', 'deferred')}
        for c in contacts:
            c['_new'] = bool(c.get('email')) and c['email'].lower() in saved_this_run
        row['usable'] = sum(1 for c in contacts if c.get('email') and str(c.get('verified', '')).lower() in USABLE)
        row['new'] = sum(1 for c in contacts if c.get('_new') and str(c.get('verified', '')).lower() in USABLE)
        row['unverified'] = sorted(c['email'].lower() for c in contacts
                                   if c.get('email') and str(c.get('verified', '')).lower() == 'unverified')
        if not row['sheet_ok']:
            fk = ((rec or {}).get('steps', {}).get('final') or {}).get('kv', {})
            offline = bool(sheet_err)
            row['usable'] = int(fk.get('valid_contacts') or 0) if str(fk.get('valid_contacts', '')).isdigit() \
                else sum(1 for c in (rec or {}).get('saved', []) if c['verified'] in USABLE)
            row['new'] = sum(1 for c in (rec or {}).get('saved', []) if c['verified'] in USABLE)
            row['unverified'] = sorted(c['email'] for c in (rec or {}).get('saved', []) if c['verified'] == 'unverified')
            if not offline and fk.get('reason') != 'venue_not_in_sheet':
                add('fail', f'could not read the sheet ({err}); counts come from the log')
        final_kv = ((rec or {}).get('steps', {}).get('final') or {}).get('kv', {})
        row['status'] = row['sheet_status'] or final_kv.get('status') or (rec or {}).get('log_status') or ''

        skip = (rec or {}).get('skip', '')
        fstep = ((rec or {}).get('steps') or {}).get('final') or {}
        if fstep.get('status') == 'skipped':
            skip = skip or fstep['kv'].get('reason', 'skipped')
            rec['skip'] = skip
        row['skipped'] = bool(skip) and (not (rec or {}).get('started') or fstep.get('status') == 'skipped'
                                         or not rec.get('steps') and not rec.get('done'))
        if not rec:
            add('fail', 'not processed: no log lines for this venue (run died or it was never reached; resume the run)', True)
            continue
        if row['skipped']:
            low = skip.lower()
            if re.search(r'dns|closed|404|410|dead', low):
                add('check', f'skipped: {skip}')
            continue
        if not rec.get('done') and 'final' not in rec.get('steps', {}):
            add('fail', 'did not finish (no DONE line: killed, timed out or crashed)', True)

        # ---- per-source coverage
        steps = rec.get('steps') or {}
        row['legacy'] = not steps
        fin = steps.get('final') or {}
        fin_reason = fin.get('kv', {}).get('reason', '') if fin.get('status') in ('failed', 'blocked') else ''
        if fin_reason:
            kv = dict(fin.get('kv', {}))
            try:
                text = FINAL_FAIL_TEXT[fin_reason].format(**{k: kv.get(k, '?') for k in ('minutes', 'exit', 'signal', 'status', 'wanted')})
            except KeyError:
                text = 'failed: ' + ' '.join(f'{k}={v}' for k, v in kv.items())
            if fin_reason == 'timeout' and rec.get('watchdog'):
                text += f" ({rec['watchdog']})"
            if kv.get('via') == 'postcheck':
                text += ' [postcheck]'
            if fin_reason in RESUMABLE:
                text += f' — resume with ./pipeline.sh --resume {run_id}'
            add('fail', 'final: ' + text, True)
        elif rec.get('watchdog'):
            add('warn', 'watchdog: ' + rec['watchdog'])
        if fin_reason in NOT_RUN:
            for sev, text in rec.get('flags') or []:
                add(sev, text)
            continue
        if steps:
            for s in REQUIRED_STEPS:
                stp = steps.get(s)
                if not stp:
                    add('fail', f'{s}: no [STEP] line (not attempted or not logged)', True)
                    continue
                reason = stp['kv'].get('reason', '')
                if s == 'final' and fin_reason:
                    continue
                if stp['status'] in ('failed', 'blocked'):
                    add('fail', f"{s} {stp['status']}: " + (' '.join(f'{k}={v}' for k, v in stp['kv'].items()) or 'no detail'), True)
                elif stp['status'] == 'skipped' and (not reason or GAP_SKIP_RE.search(reason)):
                    add('fail', f"{s} skipped{(' (' + reason + ')') if reason else ' with no reason'}", True)
            ap = steps.get('apollo') or {}
            if ap.get('kv', {}).get('reason') == 'org_mismatch':
                add('warn', 'apollo: matched a different company, so no people were taken; needs a manual Apollo check', True)
            if ap.get('status') == 'skipped' and ap.get('kv', {}).get('reason') == 'shared_domain':
                n_c = ap['kv'].get('candidates', '0')
                names = rec.get('apollo_candidates') or []
                if (n_c.isdigit() and int(n_c) > 0) or names:
                    add('check', f'apollo skipped (shared brand domain): {n_c if n_c.isdigit() else len(names)} candidate(s) '
                        'for you to judge' + (': ' + '; '.join(names[:5]) + (' …' if len(names) > 5 else '') if names else ''))
            for s, stp in steps.items():
                if s in REQUIRED_STEPS:
                    continue
                if stp['status'] in ('failed', 'blocked'):
                    add('fail', f"{s} {stp['status']}: " + (' '.join(f'{k}={v}' for k, v in stp['kv'].items()) or 'no detail'), True)
            for err in rec.get('errors') or []:
                s = err.split(':', 1)[0]
                if s in steps and steps[s]['status'] in ('ok', 'empty') and re.search(r'Error|Exception|syntax error', err):
                    add('warn', f"error inside {s} although it reported {steps[s]['status']}: {err.split(':', 1)[1].strip()[:140]}")
                    break
            if row['usable'] == 0 and 'postcheck' not in steps and postcheck_ran:
                add('fail', 'postcheck: no [STEP] line for this zero-contact venue', True)
        else:
            for s, L in (rec.get('legacy') or {}).items():
                if L['failed']:
                    add('fail', f'{s} failed: ' + '; '.join(L['failed'][:2])
                        + (f' (+{len(L["failed"]) - 2} more)' if len(L['failed']) > 2 else ''), True)
                if L.get('skipped') and GAP_SKIP_RE.search(L['skipped']):
                    add('fail', f"{s} skipped ({L['skipped']})", True)
            if (rec.get('legacy', {}).get('web') or {}).get('via') in ('curl', 'chrome failed'):
                add('warn', 'web: Chrome scrape failed; homepage read via curl only (no JS, no names)', True)

        # ---- website coverage (pages actually visited, what they yielded)
        lo = to_epoch(rec.get('batch_started') or '') if rec.get('batch_started') else None
        hi = (to_epoch(rec.get('batch_ended')) or time.time()) if rec.get('batch_ended') else time.time()
        cov, cov_err = load_coverage(vid, lo, hi)
        pages = web_pages(rec, cov)
        fam = family_status(pages, site)
        for s_name in ('web', 'postcheck'):
            for f_name in re.split(r'[,;|]+', ((steps.get(s_name) or {}).get('kv') or {}).get('visited', '')):
                f_name = f_name.strip().lower()
                if f_name in ('home', 'contact', 'about', 'events', 'team'):
                    fam[f_name] = 'ok'
                elif f_name in ('form', 'contact_form') and not row['form']:
                    row['form'] = '(visited)'
        row.update({'pages': pages, 'fam': fam, 'cov': cov, 'cov_err': cov_err})
        has_site = bool(site) and not (R and R.is_non_venue_host(site))
        web_kv = (steps.get('web') or {}).get('kv', {})
        web_skipped = (steps.get('web') or {}).get('status') == 'skipped' or \
            (rec.get('legacy', {}).get('web') or {}).get('skipped')
        if has_site and not web_skipped:
            step_pages = str(web_kv.get('pages', '')).isdigit() and int(web_kv['pages']) > 0
            if not pages and not step_pages and not web_kv.get('visited'):
                add('fail', 'website: no pages recorded as visited', True)
            elif fam.get('home') != 'ok' and rec.get('home', {}).get('via') == 'failed':
                add('fail', 'website: homepage could not be fetched', True)
            crawl_failed = any('crawl' in x for x in (rec.get('legacy', {}).get('web') or {}).get('failed', []))
            if cov is None and not crawl_failed:
                add('warn', f'website: {cov_err}', True)
            elif cov is not None:
                c = cov.get('coverage') or {}
                okn, tried = int(c.get('successful_page_count') or 0), int(c.get('visited_page_count') or 0)
                if tried and okn == 0:
                    add('fail', f'website crawl: 0 of {tried} pages loaded (blocked or down?)', True)
                elif tried >= 6 and okn * 2 < tried:
                    add('warn', f'website crawl: only {okn} of {tried} pages loaded')
                hp = cov.get('high_priority_unvisited') or []
                if hp:
                    add('fail', f'website: {len(hp)} contact/events/team page(s) found but not visited: '
                        + ', '.join(url_path(u) for u in hp[:4]) + (' …' if len(hp) > 4 else ''), True)
            if 'contact' not in fam and not row['form']:
                add('warn', 'website: no contact page or contact form was visited', True)
        elif not has_site:
            add('check', 'no usable website on the sheet' + (f' ({site})' if site else ''))

        # ---- contacts / candidates / socials / location self-checks
        usable_zero = row['usable'] == 0 and row['sheet_ok']
        unc = [c for c in row['cands'] if uncertain(c)]
        if usable_zero:
            txt = f"0 usable contacts (status {row['status'] or '?'})"
            if unc:
                txt += '; uncertain finds: ' + ', '.join(f"{c['email']} ({c['reason']})" for c in unc[:6]) + \
                    (f' +{len(unc) - 6} more' if len(unc) > 6 else '')
            add('check', txt)
        else:
            people = [c for c in unc if maybe_person(c)]
            if people:
                add('check', f'{len(people)} possible personal address(es) rejected: ' + ', '.join(
                    f"{c['email']} ({c['reason']})" for c in people[:4]) + (' …' if len(people) > 4 else ''))
        # Deferred (ZB couldn't check) emails are saved as unverified; only a deferred email that
        # did NOT reach the sheet is a problem.
        deferred = sorted({c['email'] for c in row['cands'] if c['kind'] == 'deferred'} | set(rec.get('zb_deferred') or []))
        on_sheet = {str(c.get('email') or '').lower() for c in contacts}
        lost = [x for x in deferred if row['sheet_ok'] and x not in on_sheet]
        if lost:
            add('warn', f'{len(lost)} deferred email(s) not on the sheet (should be saved as unverified): ' + ', '.join(lost[:4]))
        for c in contacts:
            if not c.get('_new'):
                continue
            for pr in contact_problem(c, name, site):
                add('warn', f"new contact {c.get('name') or '(no name)'} <{c.get('email')}>: {pr}")
        for label, url in (('Facebook', row['fb']), ('Instagram', row['ig'])):
            pr = social_problem(url, name, site)
            if pr:
                add('warn', f'{label} {url}: {pr}')
        if row['state'] and R is not None and not R.in_target_area(row['state']):
            add('warn', f"outside the target area ({row['state']})")
        if site and R is not None and R.is_non_venue_host(site):
            add('warn', f'website on the sheet is not the venue\'s own site ({site})')
        if row['sheet_ok']:
            s = row['status']
            if row['usable'] > 0 and s not in ('pipelined', 'contacted'):
                add('warn', f"{row['usable']} usable contact(s) but status is {s or 'blank'}")
            if row['usable'] == 0 and s == 'pipelined':
                add('warn', 'status is pipelined but no usable contact is on the sheet')
            if row['usable'] == 0 and s == 'untouched':
                add('warn', 'processed with 0 usable contacts but status is still untouched (should be needs_review)')
        for n in rec.get('notes') or []:
            if '[API ERROR]' in n or 'APOLLO MISMATCH' in n:
                add('warn', n)
        for sev, text in rec.get('flags') or []:
            add(sev, text)
        if row['misses']:
            add('warn', f"{len(row['misses'])} item(s) the pipeline missed (see Missed by the pipeline)")

    # ---- run-level
    run_rows = []

    def radd(sev, text):
        run_rows.append({'vid': None, 'sev': sev, 'text': text})

    for b in batches:
        for it in b.get('items') or []:
            if it.startswith(('[RUN] STOPPED', '[RUN] ABORTED')):
                if batches and b is batches[-1]:
                    radd('fail', it + ('' if '--resume' in it else f' — resume with ./pipeline.sh --resume {run_id}'))
                continue
            sev = 'fail' if (re.search(r'FAIL|WARNING', it) and 'CHROME' in it) or it.startswith(('PREFLIGHT FAIL', '[WRITE] FAILED')) else 'warn'
            radd(sev, it)
    for ri in run_items:
        if ri.get('kind') == 'unresolved_skip':
            radd('check', f"venue '{ri['name']}' skipped ({ri['reason']}); no venue_id in the log")
    if sheet_err:
        radd('check', f'sheet not read ({sheet_err}): contact counts, statuses and socials come from the log')
    if any_step_lines and not postcheck_ran:
        radd('fail', 'postcheck did not run for this run')
    if not any_step_lines and any(venues.get(v) for v in vids):
        radd('check', 'old log format (no [STEP] lines): per-source coverage is inferred from log text, not proven')
    return rows, items, run_rows


# ------------------------------------------------------------------ rendering
CSS = '''
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Georgia', serif; background: #0c1a22; color: #e0e0e0;
    padding: 40px; max-width: 980px; margin: 0 auto; line-height: 1.6; }
  h1 { color: #6ecfcf; font-size: 1.8rem; margin-bottom: 5px;
    border-bottom: 2px solid #6ecfcf; padding-bottom: 10px; }
  .date { color: #999; margin-bottom: 20px; font-size: 0.95rem; }
  h2 { color: #e8944c; font-size: 1.3rem; margin: 30px 0 15px;
    border-left: 4px solid #e8944c; padding-left: 12px; }
  h3 { color: #6ecfcf; font-size: 1.05rem; margin: 18px 0 8px; }
  table { width: 100%; border-collapse: collapse; margin: 10px 0; font-size: 0.85rem; }
  th { background: #1a2e3a; color: #6ecfcf; padding: 8px 10px; text-align: left; }
  td { padding: 6px 10px; border-bottom: 1px solid #1a2e3a; vertical-align: top; }
  .tbl { overflow-x: auto; }
  a { color: #6ecfcf; text-decoration: none; }
  .stat-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin: 15px 0; }
  .stat-box { background: #1a2e3a; border-radius: 8px; padding: 12px; text-align: center; }
  .stat-box .num { font-size: 1.7rem; font-weight: bold; color: #6ecfcf; }
  .stat-box .label { font-size: 0.8rem; color: #999; margin-top: 2px; }
  .verdict { border-radius: 8px; padding: 16px 20px; margin: 10px 0 20px; font-size: 1.05rem; }
  .verdict strong { font-size: 1.3rem; display: block; margin-bottom: 4px; }
  .verdict.clean { background: #1a2a1a; border: 2px solid #4caf50; }
  .verdict.clean strong { color: #4caf50; }
  .verdict.dirty { background: #2a1a1a; border: 2px solid #e85050; }
  .verdict.dirty strong { color: #e85050; }
  .verdict.running, .verdict.pending { background: #2a2414; border: 2px solid #e8944c; }
  .verdict.pending strong { color: #e8944c; }
  .verdict.running strong { color: #e8944c; }
  .review-box { background: #1a1a2a; border: 2px solid #e8944c; border-radius: 8px;
    padding: 20px; margin: 20px 0; }
  .review-box h2 { margin-top: 0; border: none; padding: 0; }
  .review-item { display: flex; justify-content: space-between; align-items: flex-start;
    padding: 10px 0; border-bottom: 1px solid #1a2e3a; gap: 12px; }
  .review-item:last-child { border-bottom: none; }
  .review-item .venue-name { font-size: 1rem; }
  .review-item .venue-type { color: #888; font-size: 0.8rem; }
  .review-item ul { list-style: none; margin-top: 4px; font-size: 0.85rem; }
  .review-item .contact-count { font-size: 1.4rem; font-weight: bold; color: #e85050;
    min-width: 40px; text-align: center; }
  .contact-count.good { color: #4caf50; }
  .sev-fail { color: #e85050; }
  .sev-warn { color: #ff9800; }
  .sev-check { color: #6ecfcf; }
  .ok { color: #4caf50; }
  .empty { color: #999; }
  .failed, .blocked, .missing { color: #e85050; font-weight: bold; }
  .skipped { color: #d8b04c; }
  .ran { color: #888; }
  .cell small { display: block; color: #888; font-size: 0.72rem; line-height: 1.3; }
  tr.gap td:first-child { border-left: 3px solid #e85050; }
  td.emails-zero { color: #e85050; font-weight: bold; }
  td.emails-good { color: #4caf50; font-weight: bold; }
  details { margin: 24px 0; }
  details summary { color: #e8944c; font-size: 1.15rem; cursor: pointer; padding: 8px 0;
    font-weight: bold; border-left: 4px solid #e8944c; padding-left: 12px; }
  details details { margin: 8px 0 8px 12px; }
  details details summary { font-size: 0.95rem; color: #6ecfcf; border-left-color: #1a2e3a; }
  .pill { display: inline-block; background: #1a2e3a; color: #6ecfcf; padding: 1px 8px;
    border-radius: 12px; font-size: 0.75rem; margin-left: 6px; }
  .muted { color: #888; font-size: 0.85rem; }
  .placeholder { color: #e8944c; font-style: italic; }
  pre { background: #08131a; border: 1px solid #1a2e3a; padding: 12px; overflow-x: auto;
    font-size: 0.75rem; line-height: 1.35; white-space: pre; }
  @media (max-width: 640px) {
    body { padding: 16px; }
    .stat-grid { grid-template-columns: repeat(2, 1fr); }
    table { font-size: 0.78rem; }
    td, th { padding: 5px 6px; }
  }
'''


def page_shell(title, body):
    return ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
            f'<title>Outreach Run Report &mdash; {e(title)}</title>\n<style>{CSS}</style>\n</head>\n<body>\n'
            + body + '\n</body>\n</html>\n')


def venue_link(vid, name, cls=''):
    style = f' class="{cls}"' if cls else ''
    return f'<a href="{e(APP_URL + urllib.parse.quote(str(vid), safe=""))}"{style}>{e(name or vid)}</a>'


def step_cell(rec, step):
    stp = (rec.get('steps') or {}).get(step)
    if stp:
        status = stp['status']
        kv = stp['kv']
        keys = [k for k in ('via', 'pages', 'emails', 'saved', 'rejected', 'deferred', 'found', 'people',
                            'results', 'domain_results', 'name_results', 'count', 'status', 'valid_contacts',
                            'new', 'reason', 'verdict') if k in kv][:4]
        detail = ' '.join(f'{k}={kv[k]}' for k in keys)
        full = ' '.join(f'{k}={v}' for k, v in kv.items())
        return f'<td class="cell" title="{e(full)}"><span class="{e(status)}">{e(status)}</span><small>{e(detail)}</small></td>'
    L = (rec.get('legacy') or {}).get(step)
    if L:
        if L['failed']:
            return f'<td class="cell" title="{e("; ".join(L["failed"]))}"><span class="failed">failed</span><small>{e(L["failed"][0][:40])}</small></td>'
        if L.get('skipped'):
            return f'<td class="cell"><span class="skipped">skipped</span><small>{e(L["skipped"][:40])}</small></td>'
        if step == 'web' and L.get('via'):
            return '<td class="cell"><span class="failed">curl</span><small>Chrome failed</small></td>'
        if step == 'final' and rec.get('log_status'):
            return f'<td class="cell"><span class="ran">ran</span><small>{e(rec["log_status"])}</small></td>'
        if L.get('ran'):
            return '<td class="cell"><span class="ran">ran?</span><small>old log</small></td>'
    return '<td class="cell"><span class="missing">&mdash;</span></td>'


FAM_SYM = {'ok': ('ok', '&#10003;'), 'tried': ('ran', '?'), 'failed': ('failed', '&#10007;')}


def fam_cell(fam, key):
    cls, sym = FAM_SYM.get(fam.get(key, ''), ('missing', '&middot;'))
    return f'<td class="{cls}" style="text-align:center">{sym}</td>'


def render(run_id, entry, rows, items, run_rows, stats, misses, misses_bad, batches, cand_err,
           status, keep_blocks, generated):
    title = title_date(generated)
    n_fail = sum(1 for i in items + run_rows if i['sev'] == 'fail')
    n_warn = sum(1 for i in items + run_rows if i['sev'] == 'warn')
    n_check = sum(1 for i in items + run_rows if i['sev'] == 'check')
    clean = n_fail == 0 and n_warn == 0
    legacy = all(r.get('legacy', True) for r in rows if r['rec'])
    b = []
    b.append('<h1>Outreach Run Report</h1>')
    span = stats['span']
    b.append(f'<div class="date">{e(title)} &mdash; run <strong>{e(run_id)}</strong> &mdash; {len(rows)} venues in '
             f'{stats["nbatches"]} batch{"es" if stats["nbatches"] != 1 else ""}'
             + (f' &mdash; {e(span)}' if span else '') + '</div>')

    b.append('<!-- REPORT_BANNER -->')

    b.append('<div class="stat-grid">')
    for num, label in ((len(rows), 'Venues'), (stats['pipelined'], 'Pipelined'), (stats['needs_review'], 'Needs review'),
                       (stats['new'], 'New contacts'), (stats['gaps'], 'Coverage gaps'),
                       ('&mdash;' if misses is None else len(misses), 'Missed items'),
                       (stats['apollo'], 'Apollo credits'), (stats['zb'], 'ZB credits')):
        b.append(f'  <div class="stat-box"><div class="num">{num}</div><div class="label">{e(label)}</div></div>')
    b.append('</div>')

    # ---- needs your eyes: only problems
    by_vid = {}
    for it in items:
        by_vid.setdefault(it['vid'], []).append(it)
    sev_rank = {'fail': 0, 'warn': 1, 'check': 2}
    flagged = [r for r in rows if r['issues']]
    flagged.sort(key=lambda r: (min(sev_rank[s] for s, _ in r['issues']), r['usable'], r['rec'].get('order', 0) if r['rec'] else 0))
    b.append('<div class="review-box">')
    b.append(f'  <h2 id="needs-review">Needs Your Eyes</h2>')
    if not flagged and not run_rows:
        b.append('  <p class="ok"><!-- REPORT_NOTHING -->Nothing. Every venue ran every source cleanly.</p>')
    b.append('<!-- REPORT_GATE -->')
    if run_rows:
        b.append('  <div class="review-item"><div><div class="venue-name">Whole run</div><ul>')
        for it in run_rows:
            b.append(f'    <li class="sev-{it["sev"]}">{e(it["text"])}</li>')
        b.append('  </ul></div></div>')
    for r in flagged:
        loc = ' '.join(x for x in (r['city'], r['state']) if x)
        b.append('  <div class="review-item"><div>')
        b.append(f'    <div class="venue-name">{venue_link(r["vid"], r["name"])}</div>')
        b.append(f'    <div class="venue-type">{e(r["category"] or "?")} | {e(loc or "?")} | {e(r["status"] or "?")}</div><ul>')
        for sev, text in sorted(r['issues'], key=lambda x: sev_rank[x[0]]):
            b.append(f'      <li class="sev-{sev}">{e(text)}</li>')
        cnt = '&mdash;' if r['skipped'] else r['usable']
        good = ' good' if r['usable'] > 1 else ''
        b.append(f'    </ul></div><div class="contact-count{good}">{cnt}</div></div>')
    b.append('</div>')

    # ---- misses
    b.append('<h2 id="missed">Missed by the pipeline</h2>')
    if misses is None:
        b.append(f'<p class="muted">The miss audit hasn\'t run yet (no reports/runs/{e(safe_name(run_id))}.misses.jsonl).</p>')
    elif not misses:
        b.append('<p class="ok">Audit ran: nothing missed.</p>')
    else:
        name_of = {r['vid']: r['name'] for r in rows}
        b.append('<div class="tbl"><table><tr><th>Venue</th><th>Kind</th><th>What was missed</th><th>Where found</th><th>Likely cause</th></tr>')
        for mi in sorted(misses, key=lambda x: str(x.get('venue_id'))):
            vid = str(mi.get('venue_id') or '')
            src = str(mi.get('source_url') or '')
            src_html = f'<a href="{e(safe_url(src))}">{e(url_path(src) if safe_url(src) else src)}</a>' if safe_url(src) else e(src)
            b.append(f'<tr><td>{venue_link(vid, name_of.get(vid, vid))}</td><td>{e(mi.get("kind"))}</td>'
                     f'<td>{e(mi.get("value"))}</td><td>{src_html}</td><td>{e(mi.get("cause_guess"))}</td></tr>')
        b.append('</table></div>')
    if misses_bad:
        b.append(f'<p class="sev-warn">{misses_bad} unreadable line(s) in the misses file.</p>')

    # ---- website coverage (the part Alex checks most)
    b.append('<h2 id="website-coverage">Website coverage</h2>')
    b.append('<p class="muted">Pages the run actually opened on each venue\'s own site. &#10003; loaded, ? tried (no proof it loaded), '
             '&#10007; failed, &middot; not tried. Home / Contact / About / Events / Team, then the contact form.</p>')
    b.append('<div class="tbl"><table><tr><th>Venue</th><th>How</th><th>Pages ok/tried</th><th>H</th><th>C</th><th>A</th>'
             '<th>E</th><th>T</th><th>Form</th><th>Emails on site</th><th>Not visited</th></tr>')
    web_rows = [r for r in rows if r['rec'] and not r['skipped']]
    web_rows.sort(key=lambda r: (-r['gaps'], r['usable'], r['rec'].get('order', 0)))
    for r in web_rows:
        pages = r.get('pages') or []
        okn = sum(1 for p in pages if p['ok'] or p['emails'])
        emails = set()
        for p in pages:
            emails.update(p['emails'])
        home_via = (r['rec'].get('home') or {}).get('via') or ''
        wk = ((r['rec'].get('steps') or {}).get('web') or {}).get('kv', {})
        how = wk.get('via') or home_via or ('crawl' if r.get('cov') else '')
        hp = ((r.get('cov') or {}).get('high_priority_unvisited') or [])
        cls = ' class="gap"' if r['gaps'] else ''
        b.append(f'<tr{cls}><td>{venue_link(r["vid"], r["name"])}</td><td class="{"failed" if how in ("curl", "failed") else ""}">{e(how or "?")}</td>'
                 f'<td>{okn}/{len(pages)}</td>' + ''.join(fam_cell(r.get('fam') or {}, k) for k in ('home', 'contact', 'about', 'events', 'team'))
                 + f'<td class="{"ok" if r["form"] else "missing"}" style="text-align:center">{"&#10003;" if r["form"] else "&middot;"}</td>'
                 f'<td>{len(emails)}</td><td class="{"failed" if hp else ""}">{len(hp)}</td></tr>')
    b.append('</table></div>')
    for r in web_rows:
        pages = r.get('pages') or []
        if not pages and not r.get('cov_err'):
            continue
        cov = r.get('cov') or {}
        c = cov.get('coverage') or {}
        head = f'{e(r["name"])} &mdash; {len(pages)} page(s)'
        if c:
            head += f' &middot; crawl {c.get("successful_page_count", 0)}/{c.get("visited_page_count", 0)} loaded'
        b.append(f'<details><summary>{head}</summary>')
        if r.get('cov_err'):
            b.append(f'<p class="muted">{e(r["cov_err"])}</p>')
        hp = cov.get('high_priority_unvisited') or []
        if hp:
            b.append('<p class="sev-fail">Found but not visited: ' + ', '.join(
                f'<a href="{e(safe_url(u))}">{e(url_path(u))}</a>' for u in hp[:20]) + '</p>')
        b.append('<div class="tbl"><table><tr><th>Page</th><th>How</th><th>Result</th><th>Emails found</th></tr>')
        for p in sorted(pages, key=lambda p: (page_family(p) == '', url_path(p['url']))):
            res = 'ok' if p['ok'] else ('failed' if p['ok'] is False else '?')
            if p['emails'] and not p['ok']:
                res = 'ok'
            href = safe_url(p['url'])
            label = e(url_path(p['url']))
            link = f'<a href="{e(href)}">{label}</a>' if href else label
            b.append(f'<tr><td>{link}</td><td>{e(", ".join(p["how"]))}</td><td class="{ "ok" if res == "ok" else ("failed" if res == "failed" else "ran")}">{res}</td>'
                     f'<td>{e(", ".join(p["emails"]))}</td></tr>')
        b.append('</table></div></details>')

    # ---- per-source coverage
    b.append('<h2 id="source-coverage">Source coverage</h2>')
    b.append('<p class="muted">One row per venue: every source the run tried and what it returned ([STEP] lines). '
             'Red = failed/blocked/missing, which is a coverage gap.</p>')
    extra = sorted({s for r in rows for s in (r['rec'].get('steps') or {}) if s not in COVER_COLS})
    cols = list(COVER_COLS) + extra
    b.append('<div class="tbl"><table><tr><th>Venue</th>' + ''.join(f'<th>{e(c)}</th>' for c in cols) + '<th>Contacts</th></tr>')
    for r in sorted([r for r in rows if r['rec']], key=lambda r: (-r['gaps'], r['usable'], r['rec'].get('order', 0))):
        cls = ' class="gap"' if r['gaps'] else ''
        cnt_cls = 'emails-zero' if r['usable'] == 0 else 'emails-good'
        cnt = '&mdash;' if r['skipped'] else r['usable']
        if r['skipped']:
            b.append(f'<tr{cls}><td>{venue_link(r["vid"], r["name"])}</td><td colspan="{len(cols)}" class="skipped">skipped: {e(r["rec"].get("skip"))}</td><td>{cnt}</td></tr>')
            continue
        b.append(f'<tr{cls}><td>{venue_link(r["vid"], r["name"])}</td>' + ''.join(step_cell(r['rec'], c) for c in cols)
                 + f'<td class="{cnt_cls}">{cnt}</td></tr>')
    b.append('</table></div>')

    # ---- everything else, collapsed
    b.append('<details><summary>All venues &mdash; contacts and candidates (sorted by contact count)</summary>')
    b.append('<div class="tbl"><table><tr><th>Venue</th><th>Category</th><th>Location</th><th>Contacts</th><th>New</th><th>Status</th></tr>')
    for r in sorted(rows, key=lambda r: (r['usable'], r['rec'].get('order', 0) if r['rec'] else 0)):
        cnt = '&mdash;' if r['skipped'] or not r['rec'] else r['usable']
        cls = 'emails-zero' if not r['usable'] else 'emails-good'
        b.append(f'<tr><td>{venue_link(r["vid"], r["name"])}</td><td>{e(r["category"])}</td><td>{e(" ".join(x for x in (r["city"], r["state"]) if x))}</td>'
                 f'<td class="{cls}">{cnt}</td><td>{r["new"]}</td><td>{e(r["status"])}</td></tr>')
    b.append('</table></div>')
    for r in rows:
        rec = r['rec']
        b.append(f'<h3>{venue_link(r["vid"], r["name"])}<span class="pill">{e(r["category"] or "?")}</span></h3>')
        links = [f'<a href="{e(safe_url(u))}">{lbl}</a>' for lbl, u in
                 (('Website', r['site']), ('Facebook', r['fb']), ('Instagram', r['ig']), ('Contact form', r['form'])) if safe_url(u)]
        extra_bits = []
        if rec:
            if rec.get('elapsed_min') is not None:
                extra_bits.append(f'{rec["elapsed_min"]} min')
            extra_bits.append(f'Apollo {rec.get("apollo_credits", 0)} cr')
            extra_bits.append(f'ZB {rec.get("zb_charged", 0)} cr')
        b.append(f'<div class="muted">{" &bull; ".join(links)}{(" &mdash; " if links and extra_bits else "")}{e(" | ".join(extra_bits))}</div>')
        titles = (rec or {}).get('titles') or {}
        if r['contacts']:
            b.append('<div class="tbl"><table><tr><th>Name</th><th>Title</th><th>Email</th><th>Verified</th><th>Source</th><th>New</th></tr>')
            for c in sorted(r['contacts'], key=lambda c: (not c.get('_new'), str(c.get('verified')) not in USABLE)):
                em = c.get('email') or ''
                probs = contact_problem(c, r['name'], r['site']) if em else []
                ttl = c.get('title') or titles.get(em.lower(), '')
                b.append(f'<tr><td>{e(c.get("name") or "(no name)")}</td><td>{e(ttl)}</td><td>{e(em or "—")}</td>'
                         + (f'<td class="sev-warn">unverified &mdash; needs ZB check</td>' if str(c.get('verified')) == 'unverified' else
                            f'<td class="{"ok" if str(c.get("verified")) in USABLE else "ran"}">{e(c.get("verified"))}</td>')
                         + f'<td>{e(c.get("source"))}</td>'
                         f'<td>{"new" if c.get("_new") else ""}{(" <span class=sev-warn>&#9888; " + e("; ".join(probs)) + "</span>") if probs else ""}</td></tr>')
            b.append('</table></div>')
        elif rec and rec.get('saved'):
            b.append('<div class="tbl"><table><tr><th>Name</th><th>Title</th><th>Email</th><th>Saved as</th></tr>')
            for c in rec['saved']:
                b.append(f'<tr><td>{e(c["name"] or "(no name)")}</td><td>{e(titles.get(c["email"], ""))}</td><td>{e(c["email"])}</td><td>{e(c["verified"])}</td></tr>')
            b.append('</table></div>')
        else:
            b.append('<p class="muted">No contacts on the sheet.</p>')
        apc = (rec or {}).get('apollo_candidates') or []
        if apc:
            b.append('<p class="muted">Apollo candidates not enriched (shared brand domain, your call): ' + e('; '.join(apc)) + '</p>')
        pend = (rec or {}).get('pending') or []
        if pend:
            b.append('<p class="muted">People found without an email: ' + '; '.join(
                e(p['name'] + (f' ({p["title"]})' if p['title'] else '')) for p in pend) + '</p>')
        rej = [c for c in r['cands'] if c['kind'] in ('rejected', 'undecided') or (c['kind'] == 'deferred' and not c.get('on_sheet'))]
        if rej:
            b.append(f'<details><summary>{len(rej)} candidate(s) not saved</summary><div class="tbl"><table>'
                     '<tr><th>Found</th><th>Why not saved</th><th>Name / title</th><th>Source</th></tr>')
            for c in sorted(rej, key=lambda c: (not uncertain(c), c['email'])):
                mark = ' class="sev-warn"' if uncertain(c) else ''
                ev = safe_url(c.get('evidence_url'))
                src = e(c.get('source')) + (f' <a href="{e(ev)}">page</a>' if ev else '')
                kind_lbl = '' if c.get('ckind', 'email') == 'email' else f'{c["ckind"]}: '
                b.append(f'<tr><td{mark}>{e(kind_lbl + c["email"])}</td><td>{e(c["reason"])}</td><td>{e(" / ".join(x for x in (c.get("name"), c.get("title")) if x))}</td><td>{src}</td></tr>')
            b.append('</table></div></details>')
    b.append('</details>')

    skipped = [r for r in rows if r['skipped']]
    if skipped:
        b.append(f'<details><summary>Skipped venues ({len(skipped)})</summary><div class="tbl"><table><tr><th>Venue</th><th>Reason</th></tr>')
        for r in skipped:
            b.append(f'<tr><td>{venue_link(r["vid"], r["name"])}</td><td>{e(r["rec"].get("skip"))}</td></tr>')
        b.append('</table></div></details>')

    b.append('<details><summary>Run stats</summary><div class="tbl"><table><tr><th>What</th><th>Value</th></tr>')
    for k, v in stats['table']:
        b.append(f'<tr><td>{e(k)}</td><td>{e(v)}</td></tr>')
    b.append('</table></div></details>')

    b.append('<h2 id="taste-review">Taste Review</h2>')
    b.append('<!-- TASTE_REVIEW:BEGIN -->' + keep_blocks.get('TASTE_REVIEW', '\n<p class="placeholder" data-placeholder="1">'
             'Taste review pending: the session fills this in (runbook step 6).</p>\n') + '<!-- TASTE_REVIEW:END -->')
    b.append('<!-- SESSION_NOTES:BEGIN -->' + keep_blocks.get('SESSION_NOTES', '\n') + '<!-- SESSION_NOTES:END -->')

    b.append('<!-- verify_run:begin --><h2>Run gate (verify_run.sh)</h2><p class="muted">not embedded yet</p><!-- verify_run:end -->')
    if cand_err:
        b.append(f'<p class="sev-warn">Candidate log: {e(cand_err)}</p>')
    logs = sorted({bb.get('log', '') for bb in batches if bb.get('log')})
    b.append(f'<p class="muted">Generated {e(generated.strftime("%Y-%m-%d %H:%M:%S"))} by pipeline.sh generate_report from '
             f'{e(", ".join(os.path.basename(x) for x in logs) or "no log")}.</p>')
    info = {'n_fail': n_fail, 'n_warn': n_warn, 'n_check': n_check, 'legacy': legacy, 'status': status,
            'gaps': stats['gaps'], 'zero': stats['zero'], 'misses': None if misses is None else len(misses),
            'miss_venues': stats['miss_venues'], 'miss_rate': stats['miss_rate'], 'unverified': stats['unverified'],
            'run_id': run_id, 'stopped': (batches[-1].get('stopped') if batches else '') or ''}
    return page_shell(title, '\n'.join(b)), info


def final_verdict(info, gate):
    """One verdict for banner + manifest: the report's own checks AND the verify_run gate."""
    gate_items = (len(gate.get('missing_now') or []) + len(gate.get('review_items') or [])) if gate.get('ran') else 0
    mine = info['n_fail'] + info['n_warn']
    gate_txt = f', gate {gate_items}' if gate_items else ''
    if info['status'] == 'running':
        return 'running', ('STOPPED (resumable)' if info.get('stopped') else 'RUNNING'), mine
    if info['legacy']:
        return 'dirty', 'UNVERIFIED (old log format)', mine
    if mine == 0 and gate.get('ran') and gate.get('gate_clean'):
        return 'clean', 'CLEAN', 0
    if mine + gate_items == 0 and gate.get('ran'):
        return 'pending', f"CLEAN SO FAR ({len(gate.get('pending_marks') or [])} manual marks pending)", 0
    return 'dirty', f'NOT CLEAN ({mine} items{gate_txt})', mine


def banner_html(info, gate):
    cls, word, n = final_verdict(info, gate)
    if cls == 'running' and info.get('stopped'):
        head = 'RUN STOPPED &mdash; resumable'
        text = (f"{info['stopped']}. Resume with ./pipeline.sh --resume {info['run_id']} (venues stay hidden in the app). "
                f'{n} problem(s) so far.')
    elif cls == 'running':
        head = 'RUN IN PROGRESS &mdash; results so far'
        text = f'{n} problem(s) so far. More batches are still running; these venues stay hidden in the app.'
    elif info['legacy']:
        head = 'UNVERIFIED &mdash; old log format'
        text = f'{n} problem(s) detected from log text; per-source coverage cannot be proven for this log.'
    elif cls == 'pending':
        head = 'CLEAN SO FAR &mdash; manual check marks pending'
        text = ("The pipeline's own evidence shows no problem. The gate still waits for "
                f"{len(gate.get('pending_marks') or [])} manual check mark(s) (session step), then re-run the report.")
    elif cls == 'clean':
        head = 'CLEAN'
        text = 'Every required source ran, nothing failed or looks wrong, and the gate agrees.' + \
            (f" {info['n_check']} item(s) below are just for a quick look (zero contacts / skipped)." if info['n_check'] else '')
    else:
        g_n = len(gate.get('missing_now') or []) + len(gate.get('review_items') or []) if gate.get('ran') else 0
        head = f'NOT CLEAN &mdash; {n} item(s) need your eyes' if n else 'NOT CLEAN &mdash; see the gate findings'
        text = (f"{info['n_fail']} failure(s)/gap(s) and {info['n_warn']} warning(s) listed per venue"
                + (f", {info['n_check']} more to look at" if info['n_check'] else '')
                + (f"; the gate adds {g_n} finding(s) (collapsed below, mostly the same problems)." if g_n else '.'))
    miss = ("miss audit hasn't run yet" if info['misses'] is None else
            f"{info['misses']} missed item(s) at {info['miss_venues']} venue(s) (miss rate {info['miss_rate']})")
    gate_line = (f"Gate (verify_run): {e(gate.get('verdict'))}" + (' &mdash; report/taste_review marks still to come' if
                 any(m[0] == '(run)' and m[1] in PENDING_RUN_MARKS for m in gate.get('missing') or [] if len(m) >= 2) else '')
                 if gate.get('ran') else f"Gate (verify_run) did not run: {e(gate.get('why'))}")
    return (f'<div class="verdict {cls}"><strong>{head}</strong>{e(text)}<br><span class="muted">'
            f"Coverage gaps: <strong>{info['gaps']}</strong> &middot; Misses: <strong>{e(miss)}</strong> &middot; "
            f"Zero-contact venues: <strong>{info['zero']}</strong>"
            + (f" &middot; Unverified: <strong>{info['unverified']}</strong> (saved, need a ZeroBounce check: {e(REVERIFY_HINT)})"
               if info.get('unverified') else '')
            + f"<br>{gate_line}</span></div>")


def gate_html(gate):
    if not gate.get('ran'):
        return ('  <div class="review-item"><div><div class="venue-name">Run gate</div><ul>'
                f'<li class="sev-fail">verify_run did not run: {e(gate.get("why"))}</li></ul></div></div>')
    rows = [('fail', f'{e(m[0])} {e(m[1])}: missing{(" &mdash; " + e(m[2])) if len(m) > 2 and m[2] else ""}') for m in gate.get('missing_now') or []]
    pend = gate.get('pending_marks') or []
    if pend:
        by = {}
        for m in pend:
            by.setdefault(m[1], set()).add(m[0])
        rows.append(('check', e(f'{len(pend)} manual check mark(s) not recorded yet (session step): '
                                + ', '.join(f'{k} {len(v)}' for k, v in sorted(by.items(), key=lambda x: -len(x[1]))))))
    rows += [('warn', e(f"{r.get('venue_id', '')} {r.get('kind', '')} {r.get('step', '')}: {r.get('detail', '')}"))
             for r in gate.get('review_items') or []]
    if not rows:
        return ''
    lis = ''.join(f'<li class="sev-{sev}">{txt}</li>' for sev, txt in rows[:60])
    more = f'<li class="muted">+{len(rows) - 60} more in the gate output below</li>' if len(rows) > 60 else ''
    return (f'  <details><summary>Gate findings (verify_run): {len(rows) - (1 if pend else 0)}'
            f'{" + pending marks" if pend else ""}</summary>'
            f'<ul style="list-style:none;font-size:0.85rem">{lis}{more}</ul></details>')


def keep_blocks_from(path):
    out = {}
    if not os.path.exists(path):
        return out
    try:
        text = open(path, encoding='utf-8').read()
    except Exception:
        return out
    for name in ('TASTE_REVIEW', 'SESSION_NOTES'):
        m = re.search(f'<!-- {name}:BEGIN -->(.*?)<!-- {name}:END -->', text, re.S)
        if m and 'data-placeholder="1"' not in m.group(1) and m.group(1).strip():
            out[name] = m.group(1)
    return out


def stub_html(run_id, ids, names, when):
    rows = ''.join(f'<li>{venue_link(v, names.get(v, v))}</li>' for v in ids)
    body = (f'{STUB_MARK}\n<h1>Outreach Run Report</h1>\n<div class="date">{e(title_date(when))} &mdash; run '
            f'<strong>{e(run_id)}</strong></div>\n<div class="verdict running"><strong>RUN IN PROGRESS</strong>'
            f'Started {e(when.strftime("%Y-%m-%d %H:%M"))}. {len(ids)} venues registered; they stay hidden in the app '
            'until the finished report is reviewed.</div>\n'
            f'<h2>Venues in this run</h2>\n<ul style="margin-left:20px">{rows}</ul>')
    return page_shell(title_date(when), body)


# ------------------------------------------------------------------ commands
def cmd_register(run_id, csv):
    ids = parse_ids(csv)
    entry = ensure_entry(run_id, ids, set_running=True)
    path = os.path.join(REPORT_DIR, entry['file'])
    existing = open(path, encoding='utf-8').read() if os.path.exists(path) else None
    if existing is None or STUB_MARK in existing:
        reg, _, _ = load_ledger(run_id)
        st = load_state(run_id)
        ids_all = entry_ids(entry)
        names = {v: (reg.get(v) or {}).get('venue_name') or (st['venues'].get(v) or {}).get('name') or v
                 for v in ids_all}
        atomic_write(path, stub_html(run_id, ids_all, names, now_local()))
    print(path)
    return 0


def cmd_report(log_path, run_id, csv):
    generated = now_local()
    st = load_state(run_id)
    parsed, batches_new, run_items, saved_global, idfix = {}, [], [], [], {}
    if log_path and os.path.exists(log_path):
        parsed, batches_new, run_items, saved_global, idfix = parse_log(log_path)
    elif log_path:
        warn(f'run log not found: {log_path}; using saved state and the sheet only')
    for vid, rec in parsed.items():
        st['venues'][vid] = merge_rec(st['venues'].get(vid), rec)
    keys = {(b['log'], b['started']) for b in batches_new}
    st['batches'] = [b for b in st['batches'] if (b.get('log'), b.get('started')) not in keys] + batches_new
    st['saved_global'] = sorted(set(st.get('saved_global') or []) | set(saved_global))
    st['idfix'] = dict(st.get('idfix') or {}, **idfix)

    ids = parse_ids(csv)
    entry = ensure_entry(run_id, ids, set_running=False)
    vids = []
    for vid in entry_ids(entry) + [v for v in st['venues'] if re.fullmatch(VID_PAT, v)]:
        real = st['idfix'].get(vid, vid)
        if real not in vids:
            vids.append(real)

    reg, marks, has_ledger = load_ledger(run_id)
    sheet, sheet_err = fetch_sheet(vids)
    # Batch venues skipped before any id was logged ("[SKIP] Already pipelined"): match by name.
    norm = lambda x: re.sub(r'[^a-z0-9]+', ' ', str(x or '').lower()).strip()
    unresolved = [ri for ri in run_items if ri.get('kind') == 'unresolved_skip']
    for ri in unresolved:
        for vid in vids:
            if vid in st['venues']:
                continue
            names = {norm(((sheet.get(vid) or (None,))[0] or {}).get('venue', {}).get('name')),
                     norm((reg.get(vid) or {}).get('venue_name'))}
            if norm(ri['name']) in names:
                rec = new_rec(vid, 10 ** 6)
                rec.update({'name': ri['name'], 'skip': ri['reason'], 'log': log_path})
                st['venues'][vid] = rec
                run_items.remove(ri)
                break
    windows = {}
    started_epoch = iso_epoch(entry.get('started_at') or entry.get('started')) or time.time() - 86400
    for vid in vids:
        rec = st['venues'].get(vid) or {}
        lo = to_epoch(rec.get('batch_started') or '') or started_epoch
        hi = to_epoch(rec.get('batch_ended') or '') or time.time()
        windows[vid] = (lo - 120, max(hi, lo) + 900)
    cands, cand_err = load_candidates(set(vids), windows, run_id)
    misses, misses_bad = load_misses(run_id)
    rows, items, run_rows = evaluate(run_id, vids, st['venues'], sheet, sheet_err, cands, misses, reg,
                                     st['batches'], run_items, st['saved_global'])
    for old, new in st['idfix'].items():
        run_rows.append({'vid': None, 'sev': 'check', 'text': f'batch venue_id {old} is not in the sheet; the run used {new} (matched by domain)'})
    if not has_ledger:
        run_rows.append({'vid': None, 'sev': 'warn', 'text': f'no ledger reports/runs/{safe_name(run_id)}.jsonl (register batches with mark_step.sh --batch)'})

    # ---- stats
    starts = [datetime.strptime(b['started'], '%Y-%m-%d %H:%M:%S') for b in st['batches'] if b.get('started')]
    ends = [datetime.strptime(b['ended'], '%Y-%m-%d %H:%M:%S') for b in st['batches'] if b.get('ended')]
    span = ''
    if starts and ends:
        mins = int((max(ends) - min(starts)).total_seconds() // 60)
        work = sum(max(0, int((datetime.strptime(b['ended'], '%Y-%m-%d %H:%M:%S') -
                               datetime.strptime(b['started'], '%Y-%m-%d %H:%M:%S')).total_seconds() // 60))
                   for b in st['batches'] if b.get('started') and b.get('ended'))
        span = f'{min(starts):%b %d %H:%M} to {max(ends):%b %d %H:%M} ({mins // 60}h{mins % 60:02d}m wall, {work // 60}h{work % 60:02d}m running)'
    processed = [r for r in rows if r['rec'] and not r['skipped']]
    apollo = sum((st['venues'].get(r['vid']) or {}).get('apollo_credits', 0) for r in rows)
    zb = sum((st['venues'].get(r['vid']) or {}).get('zb_charged', 0) for r in rows)
    miss_venues = len({m.get('venue_id') for m in misses or []})
    stats = {
        'span': span, 'nbatches': len([b for b in st['batches'] if b.get('venue_ids') or b.get('started')]) or 1,
        'pipelined': sum(1 for r in rows if r['status'] == 'pipelined'),
        'needs_review': sum(1 for r in rows if r['status'] == 'needs_review'),
        'new': sum(r['new'] for r in rows), 'gaps': sum(r['gaps'] for r in rows),
        'zero': sum(1 for r in processed if r['usable'] == 0), 'apollo': apollo, 'zb': zb,
        'unverified': sum(len(r.get('unverified') or []) for r in rows),
        'miss_venues': miss_venues,
        'miss_rate': f'{(100.0 * miss_venues / len(rows)):.0f}%' if rows else '0%',
    }
    zbinfo = zb_budget()
    table = [('Venues in run', str(len(rows))), ('Processed', str(len(processed))),
             ('Skipped', str(sum(1 for r in rows if r['skipped']))),
             ('Usable contacts on sheet (valid+role)', str(sum(r['usable'] for r in rows))),
             ('New usable contacts this run', str(stats['new'])),
             ('Unverified contacts (saved, need a ZeroBounce check)', str(stats['unverified'])),
             ('Apollo credits (from log, per-venue deltas)', str(apollo)),
             ('ZeroBounce credits (charged=True in log)', str(zb))]
    if zbinfo:
        table.append(('ZeroBounce guard (this process)', f"run {zbinfo.get('run_used')}/{zbinfo.get('run_limit')}, "
                      f"today {zbinfo.get('day_used')}/{zbinfo.get('day_limit')}, balance {zbinfo.get('credits_remaining')}"))
    for bt in st['batches']:
        table.append((f"Batch log {os.path.basename(bt.get('log', ''))}", f"{bt.get('started') or '?'} to {bt.get('ended') or '?'}; "
                      f"{len(bt.get('venue_ids') or [])} venues; {bt.get('mode', '')}; "
                      f"{'complete' if bt.get('complete') else 'no BATCH COMPLETE line'}; postcheck {'ran' if bt.get('postcheck') else 'not seen'}"))
    if sheet_err:
        table.append(('Sheet', sheet_err))
    stats['table'] = table

    status = 'running' if MORE_BATCHES else 'complete'
    path = os.path.join(REPORT_DIR, entry['file'])
    doc, info = render(run_id, entry, rows, items, run_rows, stats, misses, misses_bad,
                       st['batches'], cand_err, status, keep_blocks_from(path), generated)
    atomic_write(path, doc)
    gate = run_verify(run_id, path)
    doc = open(path, encoding='utf-8').read()
    if not gate.get('ran'):
        doc = re.sub(r'<!-- verify_run:begin -->.*?<!-- verify_run:end -->',
                     lambda _m: '<!-- verify_run:begin --><h2>Run gate (verify_run.sh)</h2><p class="sev-fail">verify_run did not run: '
                     + e(gate.get('why')) + '</p><!-- verify_run:end -->', doc, count=1, flags=re.S)
    doc = doc.replace('<!-- REPORT_BANNER -->', banner_html(info, gate), 1).replace('<!-- REPORT_GATE -->', gate_html(gate), 1)
    if (gate.get('missing_now') or gate.get('review_items')) if gate.get('ran') else True:
        doc = doc.replace('<!-- REPORT_NOTHING -->Nothing. Every venue ran every source cleanly.', 'Only the gate findings above.', 1)
    atomic_write(path, doc)
    vcls, verdict, _ = final_verdict(info, gate)
    clean = vcls == 'clean'
    miss_part = 'miss audit not run' if misses is None else f'{len(misses)} missed'
    title = (f'{title_date(generated)} \u2014 Run {run_id} ({len(rows)} venues) \u2014 {verdict}: '
             f'{stats["pipelined"]} pipelined, {stats["needs_review"]} needs_review, {stats["new"]} new contacts, '
             f'{stats["gaps"]} coverage gaps, {miss_part}')
    summary = (f'{len(rows)} venues ({len(processed)} processed, {len(rows) - len(processed)} skipped/unprocessed) in '
               f'{stats["nbatches"]} batch(es). {stats["pipelined"]} pipelined, {stats["needs_review"]} needs_review, '
               f'{stats["zero"]} with 0 usable contacts. {stats["new"]} new usable contacts; '
               f'{sum(r["usable"] for r in rows)} usable on the sheet. Coverage gaps: {stats["gaps"]}. '
               f'Misses: {"audit not run yet" if misses is None else len(misses)}. Apollo {apollo} credits, ZeroBounce {zb} credits.'
               + (f' Runtime {span}.' if span else '')
               + (f" Gate: {gate.get('verdict')}" if gate.get('ran') else ' Gate: verify_run did not run.'))
    stamp = generated.isoformat(timespec='seconds')

    def mutate(entries):
        i = find_run(entries, run_id)
        cur = dict(entries[i]) if i is not None else dict(entry)
        cur.update({'title': title, 'summary': summary, 'venues': len(rows), 'verified_emails': stats['new'],
                    'apollo_credits': apollo, 'zb_credits_used': zb, 'status': status, 'clean': clean,
                    'coverage_gaps': stats['gaps'], 'misses': None if misses is None else len(misses),
                    'updated_at': stamp})
        old = entry_ids(cur)
        cur['venue_ids'] = old + [v for v in vids if v not in old]
        return i, cur

    manifest_update(mutate)
    st['file'] = entry['file']
    st['updated_at'] = stamp
    os.makedirs(RUNS_DIR, exist_ok=True)
    atomic_write(state_path(run_id), json.dumps(st, indent=1, default=str))
    print(f'Report saved: {path}')
    print(f'Verdict: {verdict} | gaps {stats["gaps"]} | {miss_part} | {stats["pipelined"]} pipelined | {stats["new"]} new contacts')
    print(f'Manifest updated: {entry["file"]} (run {run_id}, status {status}, {len(rows)} venue_ids)')
    return 0


def main(argv):
    try:
        if len(argv) >= 3 and argv[0] == 'register':
            return cmd_register(argv[1], argv[2])
        if len(argv) >= 3 and argv[0] == 'report':
            return cmd_report(argv[1], argv[2], argv[3] if len(argv) > 3 else '')
    except ManifestError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1
    print('usage: register RUN_ID VENUE_IDS_CSV | report RUN_LOG RUN_ID [VENUE_IDS_CSV]', file=sys.stderr)
    return 2


sys.exit(main(sys.argv[1:]))
REPORTPY
    rc=$?
    if [ -s "$errf" ]; then
        sed 's/^/  [report] /' "$errf" >&2
        mkdir -p "$(dirname "$err_log")" 2>/dev/null
        sed "s/^/$(date '+%Y-%m-%d %H:%M:%S') [report:$1] /" "$errf" >> "$err_log"
    fi
    rm -f "$errf"
    return $rc
}

# =================================================================
# STEP 5: GOOGLE FALLBACK (when all other steps found no email)
# Searches Google for the venue website and scrapes it for emails.
# Also re-tries Instagram search with city appended (catches cases
# where the IG handle doesn't match the venue name, e.g. a parent
# farm name like @tranquilityfarmvirginia for "Otium Cellars").
# =================================================================
step5_google_fallback() {
    local venue="$1" venue_id="$2" city="$3"

    local email_count known_count
    email_count=$(grep -c . /tmp/pipeline_contacts_count 2>/dev/null)
    known_count=$(printf '%s' "$KNOWN_EMAILS" | tr '|' '\n' | grep -c .)
    if [ "${email_count:-0}" -gt 0 ] || [ "${known_count:-0}" -gt 0 ]; then
        log "[STEP] $venue_id google skipped reason=has_contacts results=0 emails=0"
        return  # Already have emails — skip
    fi

    log ""
    log "========== STEP 5: Google Fallback (no email found yet) =========="

    # --- 5A: Find real website via Google and scrape for email ---
    local g_status="empty" g_site="none" g_ig="none" g_reason="" g_results=0 rc before
    before=$(grep -c . /tmp/pipeline_contacts_count 2>/dev/null)
    log "  Googling: \"$venue\" contact $city"
    runner_google_candidates "\"$venue\" contact${city:+ $city}"
    rc=$?
    if [ "$rc" = 2 ]; then
        g_status="blocked"; g_site="blocked"; g_reason="captcha"
        log "  [FALLBACK] Google blocked the search (CAPTCHA) — no fallback website lookup"
    elif [ "$rc" != 0 ]; then
        g_status="failed"; g_site="chrome_error"; g_reason="chrome_error"
        log "  [FALLBACK] Google search failed (Chrome error) — no fallback website lookup"
    elif [ -z "$RUNNER_GOOGLE_RAW" ]; then
        log "  [FALLBACK] Google returned no site"
    else
        g_results=$(printf '%s' "$RUNNER_GOOGLE_RAW" | tr '|' '\n' | grep -c .)
        # Google can return directories/tourism pages first. Choose only a URL that
        # plausibly belongs to this exact venue.
        local found_site
        found_site=$(runner_py step5a python3 "${SCRIPT_DIR}/venue_quality.py" choose-website "$venue" "$RUNNER_GOOGLE_RAW")
        if [ -z "$found_site" ]; then
            log "  [FALLBACK] Search results did not contain a trustworthy venue website"
        else
            local f_verdict f_host f_reg f_shared f_prefix f_url
            IFS=$'\x1f' read -r f_verdict f_host f_reg f_shared f_prefix f_url <<< "$(runner_site_info "$found_site" "$venue")"
            if [ "$f_verdict" != "ok" ]; then
                log "  [FALLBACK] Found site $found_site is not usable as this venue's website (${f_verdict:-unparseable}) — ignoring"
            elif [ -n "$VENUE_DOMAIN" ] && [ "$f_reg" = "$VENUE_DOMAIN" ]; then
                log "  [FALLBACK] No new site found (or same domain as before)"
                g_site="same"
            elif [ -n "$VENUE_DOMAIN" ]; then
                # SAFETY: never overwrite an existing venue website with a fallback result
                # and never change VENUE_DOMAIN — the fallback site may be a directory/tourism
                # page (e.g. visitloudoun.org) not the actual venue website
                log "  [FALLBACK] Found site $found_site but venue already has domain $VENUE_DOMAIN — skipping (won't overwrite)"
                g_site="other_domain"
            else
                log "  [FALLBACK] Found site (no existing website): $f_url (domain: $f_reg)"
                g_status="ok"; g_site="found"
                runner_set_venue_globals "$venue" "$venue_id" "$f_url"
                runner_update_venue "$venue_id" website "$f_url" || true
                step1_website "$venue" "$venue_id" "$VENUE_WEBSITE" "$city"
            fi
        fi
    fi

    # --- 5B: Re-try Instagram with city to catch parent-brand handles ---
    # Only when this venue has NO Instagram anywhere: not found by step 1/1B this run
    # (PB-11: 1B always writes the check file) and not on the sheet. A Google guess
    # must never replace a handle taken from the venue's own website (PC-4/PD-7).
    runner_step5b "$venue" "$venue_id" "$city"
    case "$RUNNER_5B_RESULT" in
        found) g_ig="found"; g_status="ok" ;;
        blocked) g_ig="blocked"; [ "$g_status" = "empty" ] && { g_status="blocked"; g_reason="captcha_ig_search"; } ;;
        failed) g_ig="failed"; [ "$g_status" = "empty" ] && { g_status="failed"; g_reason="ig_search_failed"; } ;;
        *) g_ig="$RUNNER_5B_RESULT" ;;
    esac
    local g_emails
    g_emails=$(( $(grep -c . /tmp/pipeline_contacts_count 2>/dev/null) - ${before:-0} ))
    [ "$g_emails" -gt 0 ] && g_status="ok"
    log "[STEP] $venue_id google $g_status results=$g_results emails=$g_emails site=$g_site ig=${g_ig:-none}${g_reason:+ reason=$g_reason}"
}

runner_step5b() {
    local venue="$1" venue_id="$2" city="$3" current_ig="" detail="/tmp/pipeline_step5_detail.json"
    RUNNER_5B_RESULT="none"
    [ -s /tmp/pipeline_step1_ig.txt ] && current_ig=$(head -1 /tmp/pipeline_step1_ig.txt)
    if [ ${#current_ig} -le 5 ] && [ -f /tmp/pipeline_ig_check.json ]; then
        current_ig=$(runner_json_get /tmp/pipeline_ig_check.json venue.instagram)
    fi
    if [ ${#current_ig} -gt 5 ] && [ "$current_ig" != "None" ]; then
        log "  [FALLBACK] Instagram already found this run ($current_ig) — not re-searching"
        RUNNER_5B_RESULT="known"
        return
    fi
    # Fresh sheet read before any save: without it a save could overwrite an Instagram (P7)
    if ! runner_fetch_detail "$venue_id" "$detail"; then
        log "  [FALLBACK] Could not read the venue from the sheet — skipping the Instagram retry (won't risk overwriting)"
        RUNNER_5B_RESULT="failed"
        return
    fi
    current_ig=$(runner_json_get "$detail" venue.instagram)
    if [ ${#current_ig} -gt 5 ] && [ "$current_ig" != "None" ]; then
        log "  [FALLBACK] Sheet already has Instagram $current_ig — not re-searching"
        RUNNER_5B_RESULT="known"
        return
    fi
    if ! declare -F _rb_pick_social >/dev/null || ! declare -F _rb_save_social >/dev/null; then
        log "  [FALLBACK] Instagram retry unavailable (social helpers missing) — skipped"
        RUNNER_5B_RESULT="failed"
        return
    fi

    log "  [FALLBACK] Re-trying Instagram: $venue $city site:instagram.com"
    local rc ig_raw
    runner_google_nav "$venue${city:+ $city} site:instagram.com"
    rc=$?
    if [ "$rc" = 2 ]; then RUNNER_5B_RESULT="blocked"; return; fi
    if [ "$rc" != 0 ]; then
        log "  [FALLBACK] Chrome did not run the Instagram search (see $ERR_LOG)"
        RUNNER_5B_RESULT="failed"
        return
    fi
    ig_raw=$(runner_chrome_js_file "${SCRIPT_DIR}/js/extract_ig.js")
    if [ -z "$ig_raw" ] || [ "$ig_raw" = "missing value" ] || [ "$ig_raw" = "[]" ]; then
        log "  [FALLBACK] No Instagram found with city search"
        return
    fi

    # Same P7 matcher as step 1B: the handle must be the venue's name, not a brand,
    # a person or a lookalike ('joydahlgren_', 'stonecreekinn'). Rejects are logged
    # as candidates by the matcher.
    local picks line best="" rejected=""
    picks=$(_rb_pick_social instagram "$venue" "$detail" "$ig_raw" "$venue_id")
    while IFS= read -r line; do
        case "$line" in
            BEST$'\x1f'*) best=$(printf '%s' "$line" | cut -d$'\x1f' -f2) ;;
            REJECT$'\x1f'*) rejected="${rejected:+$rejected; }$(printf '%s' "$line" | cut -d$'\x1f' -f2-3 | tr '\037' ' ')" ;;
        esac
    done <<< "$picks"
    if [ -z "$best" ]; then
        log "  [FALLBACK] Instagram handle doesn't match venue name '$venue' — rejecting: ${rejected:-no usable candidate}"
        return
    fi
    log "  [FALLBACK] Found Instagram: $best"
    _rb_save_social "$venue_id" instagram "$best"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "$best" > /tmp/pipeline_step1_ig.txt
        RUNNER_5B_RESULT="found"
        # Try scraping the IG profile for email via step2
        step2_social "$venue" "$venue_id"
    else
        log "  [FALLBACK] Instagram $best was not saved (sheet answer $rc) — not scraping it"
    fi
}

# =================================================================
# MAIN RUNNER
# =================================================================
# Helpers for run_venue and the batch runner (runner_* names). run_venue runs in a
# watchdog subshell, so anything that must outlive one venue is kept in
# /tmp/pipeline_run_* files (never cleared per venue) or in RUNNER_STATE_FILE.
RUNNER_STATE_FILE="/tmp/pipeline_run_state_$$"
RUNNER_OSA_TIMEOUT="${OSA_TIMEOUT_SEC:-45}"
VENUE_TIMEOUT_MIN="${VENUE_TIMEOUT_MIN:-25}"
MAX_BATCH_SIZE=8
MAX_FAIL_STREAK="${MAX_FAIL_STREAK:-2}"
RUNNER_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
RUNNER_CHILD_PID=""
RUNNER_CUR_VID=""
RUNNER_CUR_NAME=""
RUNNER_STOPPED=0
RUNNER_STOP_REASON=""
RUNNER_STREAK_WEB=0
RUNNER_STREAK_APOLLO=0
RUNNER_STREAK_SOCIAL=0
RUNNER_STREAK_TIMEOUT=0
RUNNER_GOOGLE_RAW=""
RUNNER_SITE_VERDICT=""
ERR_LOG="${ERR_LOG:-${SCRIPT_DIR}/reports/runs/python-errors.log}"
mkdir -p "$(dirname "$ERR_LOG")" 2>/dev/null
RUNS_DIR="${SCRIPT_DIR}/reports/runs"

# runner_py TAG CMD...: run a python command; its stderr goes to ERR_LOG with a
# venue/step prefix instead of vanishing (P9). Stdout and stdin pass through.
runner_py() {
    local tag="$1" ef rc
    shift
    ef=$(mktemp "${TMPDIR:-/tmp}/pipeline_run_pyerr.XXXXXX" 2>/dev/null) || ef="/tmp/pipeline_run_pyerr_$$"
    "$@" 2>"$ef"
    rc=$?
    if [ -s "$ef" ]; then
        awk -v p="$(date '+%Y-%m-%d %H:%M:%S') [${VENUE_ID:-run} ${tag}] " '{print p $0}' "$ef" >> "$ERR_LOG" 2>/dev/null
    fi
    rm -f "$ef"
    return $rc
}

runner_urlencode() {
    runner_py urlencode python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# runner_json_get FILE a.b.c — prints the value ('' if missing); exit 1 if FILE isn't JSON
runner_json_get() {
    runner_py json_get python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
for k in sys.argv[2].split('.'):
    d = d.get(k, '') if isinstance(d, dict) else ''
print('' if d is None else d)
PYEOF
}

# venue_detail with one retry. 0 = got a JSON answer (ok or error) in FILE.
runner_fetch_detail() {
    local vid="$1" out="$2" q try
    q=$(runner_urlencode "$vid")
    [ -z "$q" ] && return 1
    for try in 1 2; do
        rm -f "$out"  # a failed fetch must not leave an older venue's answer in place
        curl -sL --max-time 60 "${APPS_SCRIPT_URL}?action=venue_detail&venue_id=${q}" -o "$out" 2>/dev/null
        if runner_py detail_check python3 - "$out" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get('status') in ('ok', 'error') else 1)
PYEOF
        then
            return 0
        fi
        [ "$try" = 1 ] && sleep 3
    done
    return 1
}

# One line, \x1f-separated: state status category website city name n_contacts n_valid first_emails
# state: ok | not_found | unreadable. n_valid counts contacts whose verified is valid/role/unverified (P4).
runner_detail_summary() {
    runner_py detail_summary python3 - "$1" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print('unreadable'); sys.exit(0)
if not isinstance(d, dict) or d.get('status') not in ('ok', 'error'):
    print('unreadable'); sys.exit(0)
if d.get('status') == 'error':
    print('not_found' if 'not found' in str(d.get('message', '')).lower() else 'unreadable'); sys.exit(0)
v = d.get('venue') or {}
cs = d.get('contacts') or []
def clean(s):
    return ' '.join(str('' if s is None else s).replace('\x1f', ' ').split())
# P4 + Alex's Sep 25 decision: ZB-deferred saves are 'unverified' and still count
valid = [c for c in cs if c.get('email') and str(c.get('verified', '')).strip().lower() in ('valid', 'role', 'unverified', 'verified')]
emails = [c.get('email', '') for c in cs if c.get('email')]
print('\x1f'.join(['ok', clean(v.get('status')), clean(v.get('category')), clean(v.get('website')),
                   clean(v.get('city')), clean(v.get('name')), str(len(cs)), str(len(valid)),
                   clean(','.join(emails[:3]))]))
PYEOF
}

# update_venue with a checked response (PD-19). 0 only when the sheet confirms the value.
runner_update_venue() {
    local vid="$1" field="$2" value="$3" q resp verdict try
    if [ -z "$vid" ] || [ -z "$field" ]; then
        log "  [WRITE] update_venue ${field:-?} skipped — empty venue_id"
        return 1
    fi
    q=$(runner_py update_encode python3 -c 'import sys, urllib.parse as u; print(u.urlencode({"action": "update_venue", "venue_id": sys.argv[1], "field": sys.argv[2], "value": sys.argv[3]}))' "$vid" "$field" "$value")
    if [ -z "$q" ]; then
        log "  [WRITE] FAILED update_venue $field for $vid — could not encode the request"
        return 1
    fi
    for try in 1 2; do
        resp=$(curl -sL --max-time 60 "${APPS_SCRIPT_URL}?${q}" 2>/dev/null)
        verdict=$(printf '%s' "$resp" | runner_py update_check python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no JSON response"); sys.exit(0)
if d.get("status") == "ok" and d.get("verified", True) is not False:
    print("ok")
elif d.get("status") == "ok":
    print("value did not persist (sheet has %r)" % d.get("persisted"))
else:
    print(str(d.get("message") or d)[:200])
')
        [ "$verdict" = "ok" ] && return 0
        [ "$verdict" != "no JSON response" ] && break
        [ "$try" = 1 ] && sleep 3
    done
    log "  [WRITE] FAILED update_venue $field=${value:0:80} for $vid: ${verdict:-no response}"
    return 1
}

# Append to the venue's notes instead of overwriting them (PD-6). FILE = a venue_detail JSON.
runner_append_note() {
    local vid="$1" f="$2" text="$3" cur
    if ! cur=$(runner_json_get "$f" venue.notes); then
        log "  [WARN] Could not read the venue's notes — not writing '$text'"
        return 1
    fi
    case "$cur" in *"$text"*) return 0 ;; esac
    runner_update_venue "$vid" notes "${cur:+$cur | }$text"
}

# runner_site_info URL VENUE_NAME -> verdict host registrable shared prefix url (\x1f-separated)
# verdict: ok | brand_page (brand/chain site without this property's page) | non_venue | invalid
runner_site_info() {
    runner_py site_info python3 - "$SCRIPT_DIR" "$1" "$2" <<'PYEOF'
import re, sys, urllib.parse
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
raw, venue = sys.argv[2].strip(), sys.argv[3]
url = raw if re.match(r'(?i)^https?://', raw) else 'https://' + raw.lstrip('/')
out = ['invalid', '', '', 'false', '', url]
host = R.host_of(url)
HOST_RE = re.compile(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$')
if not host or not HOST_RE.match(host):
    print('\x1f'.join(out)); sys.exit(0)
reg = R.registrable_domain(host)
out[1], out[2] = host, reg
if R.is_non_venue_host(host):
    out[0] = 'non_venue'
    print('\x1f'.join(out)); sys.exit(0)
shared = reg in R.SHARED_BRAND_DOMAINS
out[3] = 'true' if shared else 'false'
if not shared:
    out[0], out[4] = 'ok', host
    print('\x1f'.join(out)); sys.exit(0)
# Shared brand domain: the property's own pages sit under a path or a subdomain.
path = urllib.parse.unquote(urllib.parse.urlparse(url).path or '').lower()
segs = [s for s in path.split('/') if s]
if segs and '.' in segs[-1]:
    segs[-1] = segs[-1].rsplit('.', 1)[0]
GENERIC_PAGES = {'overview', 'home', 'index', 'default', 'main', 'hoteldetail', 'hotel-overview',
                 'about', 'about-us', 'contact', 'contact-us', 'en', 'en-us', 'us'}
while segs and segs[-1] in GENERIC_PAGES:
    segs.pop()
sub = host[:-len(reg)].rstrip('.') if host != reg else ''
label = reg.split('.')[0]
PROP_STOP = {'hotel', 'hotels', 'suites', 'resort', 'club', 'country', 'golf', 'collection',
             'autograph', 'tribute', 'portfolio', 'lodge', 'residence', 'inn', 'the', 'and', 'by'}
words = [w for w in re.sub(r'[^a-z0-9\s]', ' ', venue.lower()).split()
         if len(w) >= 4 and w not in PROP_STOP and w not in label]
hay = re.sub(r'[^a-z0-9]', '', sub + ' ' + ' '.join(segs))
if (sub or segs) and (not words or any(w in hay for w in words)):
    out[0] = 'ok'
    out[4] = host + ('/' + '/'.join(segs) if segs else '')
else:
    out[0] = 'brand_page'
print('\x1f'.join(out))
PYEOF
}

# C1: set the per-venue globals every step reads. WEBSITE may be '' (no website yet).
runner_set_venue_globals() {
    VENUE_NAME="$1"; VENUE_ID="$2"; VENUE_WEBSITE=""
    VENUE_DOMAIN=""; VENUE_SHARED_DOMAIN="false"; VENUE_SITE_PREFIX=""
    VENUE_MAIL_ALIAS=""; export VENUE_MAIL_ALIAS
    RUNNER_SITE_VERDICT="none"
    if [ -n "$3" ]; then
        local v h r s p u
        IFS=$'\x1f' read -r v h r s p u <<< "$(runner_site_info "$3" "$1")"
        RUNNER_SITE_VERDICT="${v:-invalid}"
        case "$RUNNER_SITE_VERDICT" in
            ok) VENUE_WEBSITE="$u"; VENUE_DOMAIN="$r"; VENUE_SHARED_DOMAIN="$s"; VENUE_SITE_PREFIX="$p" ;;
            # Brand homepage: nothing on it is this property's, but the domain is still
            # the brand's, so brand addresses and brand-wide people searches stay rejected.
            brand_page) VENUE_DOMAIN="$r"; VENUE_SHARED_DOMAIN="true" ;;
        esac
    fi
    export VENUE_NAME VENUE_ID VENUE_WEBSITE VENUE_DOMAIN VENUE_SHARED_DOMAIN VENUE_SITE_PREFIX
}

# Clear every per-venue temp file. Convention for all steps: anything under
# /tmp/pipeline_* is per-venue and wiped here, EXCEPT the run-level names below;
# new run-level files must be named /tmp/pipeline_run_*.
runner_clear_venue_tmp() {
    local f
    for f in /tmp/pipeline_*; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
            pipeline_run_*|pipeline_batch*|pipeline_seen_orgs*|pipeline_zb_paused_*|\
            pipeline_apollo_exhausted_*|pipeline_apollo_credits_*|pipeline_li_walled_*|\
            pipeline_li_empty_streak_*|pipeline_skipped*|pipeline_flags.txt|pipeline_linkedin_*|\
            pipeline_website_scrape.js|pipeline_venue_lookup.json|pipeline_untouched.json) continue ;;
        esac
        rm -f "$f"
    done
}

# Cross-venue counters that the watchdog subshell must hand back to the batch loop.
runner_save_state() {
    printf 'APOLLO_CREDITS_USED=%s\nLINKEDIN_WALLED=%s\nLINKEDIN_EMPTY_STREAK=%s\n' \
        "${APOLLO_CREDITS_USED:-0}" "${LINKEDIN_WALLED:-0}" "${LINKEDIN_EMPTY_STREAK:-0}" \
        > "${RUNNER_STATE_FILE}.tmp" 2>/dev/null && mv -f "${RUNNER_STATE_FILE}.tmp" "$RUNNER_STATE_FILE"
}

runner_load_state() {
    local k v
    [ -f "$RUNNER_STATE_FILE" ] && while IFS='=' read -r k v; do
        case "$v" in ''|*[!0-9]*) continue ;; esac
        case "$k" in
            APOLLO_CREDITS_USED) APOLLO_CREDITS_USED="$v" ;;
            LINKEDIN_WALLED) LINKEDIN_WALLED="$v" ;;
            LINKEDIN_EMPTY_STREAK) LINKEDIN_EMPTY_STREAK="$v" ;;
        esac
    done < "$RUNNER_STATE_FILE"
    # Step 3/4 keep their own run-level files too (they survive a watchdog kill)
    v=$(cat "/tmp/pipeline_apollo_credits_$$" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -gt "${APOLLO_CREDITS_USED:-0}" ] && APOLLO_CREDITS_USED="$v" ;; esac
    [ -f "/tmp/pipeline_li_walled_$$" ] && LINKEDIN_WALLED=1
    return 0
}

# --- Chrome (every call bounded by an AppleScript timeout; values go in via argv, P10) ---
runner_chrome_nav() {
    osascript -e 'on run argv' -e "with timeout of ${RUNNER_OSA_TIMEOUT} seconds" \
        -e 'tell application "Google Chrome" to set URL of active tab of front window to (item 1 of argv)' \
        -e 'end timeout' -e 'end run' "$1" >/dev/null 2>>"$ERR_LOG"
}

runner_chrome_js_file() {
    osascript -e 'on run argv' -e "with timeout of ${RUNNER_OSA_TIMEOUT} seconds" \
        -e 'tell application "Google Chrome" to set r to execute active tab of front window javascript (read POSIX file (item 1 of argv) as «class utf8»)' \
        -e 'end timeout' -e 'return r' -e 'end run' "$1" 2>>"$ERR_LOG"
}

# Cheap between-venue check that Chrome still answers Apple Events with JavaScript.
runner_chrome_alive() {
    local r
    r=$(osascript -e 'with timeout of 20 seconds' \
        -e 'tell application "Google Chrome" to set r to execute active tab of front window javascript "1+1"' \
        -e 'end timeout' -e 'return r' 2>>"$ERR_LOG")
    [ "$r" = "2" ]
}

# Open a Google search in Chrome. 0 ok, 1 Chrome failed, 2 Google showed a CAPTCHA.
# Uses step 1B's helper (CAPTCHA/consent detection) when it is there.
runner_google_nav() {
    if declare -F _rb_google_search >/dev/null; then
        _rb_google_search "$1"
        return $?
    fi
    local q
    q=$(runner_urlencode "$1")
    [ -z "$q" ] && return 1
    runner_chrome_nav "https://www.google.com/search?q=${q}" || return 1
    sleep 4
    return 0
}

# Google search -> RUNNER_GOOGLE_RAW (pipe-joined candidate sites from extract_cite.js).
# Returns like runner_google_nav.
runner_google_candidates() {
    RUNNER_GOOGLE_RAW=""
    local out rc
    runner_google_nav "$1"
    rc=$?
    [ "$rc" != 0 ] && return "$rc"
    out=$(runner_chrome_js_file "${SCRIPT_DIR}/js/extract_cite.js") || return 1
    [ "$out" = "missing value" ] && out=""
    case "$out" in
        \[*) out=$(printf '%s' "$out" | runner_py cite_json python3 -c 'import json, sys; print("|".join(x for x in json.load(sys.stdin) if isinstance(x, str)))') ;;
    esac
    RUNNER_GOOGLE_RAW="$out"
    return 0
}

# Same business? exact normalized name, or org-matches either way.
runner_names_match() {
    runner_py names_match python3 - "$SCRIPT_DIR" "$1" "$2" <<'PYEOF'
import re, sys, unicodedata
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
a, b = sys.argv[2], sys.argv[3]
def norm(s):
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode().lower().replace('&', ' and ').replace("'", '').replace('`', '')
    return ' '.join(re.sub(r'[^a-z0-9]+', ' ', s).split())
ok = norm(a) == norm(b) or R.org_name_matches(a, b) or R.org_name_matches(b, a)
sys.exit(0 if ok else 1)
PYEOF
}

# The ID passed in isn't in the sheet: find the venue that owns this website's host.
# Never on shared brand domains (find_by_domain returns the first sonesta.com venue).
runner_find_by_domain() {
    local website="$1" venue="$2" v h r s p u q resp
    IFS=$'\x1f' read -r v h r s p u <<< "$(runner_site_info "$website" "$venue")"
    [ "$v" = "ok" ] && [ "$s" = "false" ] && [ -n "$h" ] || return 0
    q=$(runner_urlencode "$h")
    resp=$(curl -sL --max-time 60 "${APPS_SCRIPT_URL}?action=find_by_domain&domain=${q}" 2>/dev/null)
    printf '%s' "$resp" | runner_py find_by_domain python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("status") == "ok" and d.get("venue_id") and (R.org_name_matches(d.get("name", ""), sys.argv[2]) or R.org_name_matches(sys.argv[2], d.get("name", ""))):
    print(d["venue_id"])
' "$SCRIPT_DIR" "$venue"
}

# runner_site_liveness URL -> "verdict http_code curl_exit url"
# verdict: alive | root (deep link dead, site root up) | dns | refused | gone
# A timeout / TLS error / 403 is a live site that's slow or blocks bots, not a closure.
runner_site_liveness() {
    local url="$1" code rc
    code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 -A "$RUNNER_UA" "$url" 2>/dev/null)
    rc=$?
    if [ "$rc" = 6 ] || [ "$rc" = 7 ]; then
        sleep 5
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 25 -A "$RUNNER_UA" "$url" 2>/dev/null)
        rc=$?
        if [ "$rc" = 7 ] && [ "${url#https://}" != "$url" ]; then
            local http_url="http://${url#https://}" c2
            c2=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 25 -A "$RUNNER_UA" "$http_url" 2>/dev/null)
            if [ $? = 0 ]; then
                echo "alive ${c2:-000} 0 $http_url"
                return
            fi
        fi
    fi
    case "$rc" in
        6) echo "dns ${code:-000} $rc $url"; return ;;
        7) echo "refused ${code:-000} $rc $url"; return ;;
    esac
    if [ "$rc" = 0 ] && { [ "$code" = "404" ] || [ "$code" = "410" ]; }; then
        local root rcode
        root=$(runner_py site_root python3 -c 'import sys, urllib.parse as u; p = u.urlparse(sys.argv[1]); print("%s://%s/" % (p.scheme, p.netloc) if p.path.strip("/") else "")' "$url")
        if [ -n "$root" ] && [ "$VENUE_SHARED_DOMAIN" != "true" ]; then
            rcode=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 -A "$RUNNER_UA" "$root" 2>/dev/null)
            if [ $? = 0 ]; then
                case "$rcode" in
                    404|410|000) ;;
                    *) echo "root $code 0 $root"; return ;;
                esac
            fi
        fi
        echo "gone $code 0 $url"
        return
    fi
    echo "alive ${code:-000} $rc $url"
}

# Dead website: flag it (appended to notes), needs_review per P4, never demote.
runner_flag_dead() {
    local venue="$1" vid="$2" kind="$3" site="$4" vdfile="$5" cur="$6" label
    case "$kind" in
        dns) label="DNS failure"
            log "  [WARN] Website DNS failure ($site) — venue may be closed" ;;
        refused) label="connection refused"
            log "  [WARN] Website refused the connection ($site) — venue may be closed" ;;
        *) label="HTTP ${kind#gone:}"
            log "  [WARN] Website returned ${kind#gone:} ($site) — venue may be closed" ;;
    esac
    log "  Flagging as possibly closed and skipping"
    runner_append_note "$vid" "$vdfile" "PIPELINE_FLAG: $label, possibly closed (${RUN_ID:-$(date +%Y-%m-%d)})" || true
    local final_status="$cur"
    if [ "$cur" = "pipelined" ] || [ "$cur" = "contacted" ]; then
        log "  [STATUS] Keeping status '$cur' (never demoted); the notes flag records the dead website"
    elif runner_update_venue "$vid" status needs_review; then
        log "  Setting status → needs_review (website unreachable: $label)"
        final_status="needs_review"
    fi
    echo "${venue}|${vid}|${label} — possibly closed" >> "${SKIPPED_VENUES_FILE:-/tmp/pipeline_skipped.txt}"
    log "[STEP] $vid final skipped reason=dead_website detail=$(printf '%s' "$label" | tr ' ' '_') status=${final_status:-unknown}"
}

# Step 3b: Apollo's org domain differs from the venue's site. Under P1 addresses there
# are off the venue's domain, so verify_and_push logs them as candidates (report) unless
# the venue has no website of its own. Runs only when step 3 matched THIS venue.
runner_step3b() {
    local venue="$1" venue_id="$2" verdict alt v h r s p u
    verdict=$(head -1 /tmp/pipeline_apollo_verdict 2>/dev/null)
    alt="$APOLLO_DOMAIN"
    case "$verdict" in ok:*) ;; *) return 0 ;; esac
    [ -z "$alt" ] || [ "$alt" = "None" ] || [ "$VENUE_SHARED_DOMAIN" = "true" ] && return 0
    IFS=$'\x1f' read -r v h r s p u <<< "$(runner_site_info "$alt" "$venue")"
    [ "$v" = "ok" ] && [ "$s" = "false" ] || return 0
    [ "$r" = "$VENUE_DOMAIN" ] && return 0
    log ""
    log "========== STEP 3b: Alternate Domain Scrape ($r) =========="
    if [ -n "$VENUE_DOMAIN" ]; then
        log "  $r is not the venue's own domain ($VENUE_DOMAIN): addresses found there are logged as candidates for review, not saved"
    fi
    local alt_url alt_html alt_emails alt_email seen=" "
    for alt_url in "https://$r" "https://$r/contact" "https://$r/contact-us" "https://www.$r" "https://www.$r/contact"; do
        alt_html=$(curl -sL --compressed --max-time 10 -A "$RUNNER_UA" "$alt_url" 2>/dev/null)
        [ -z "$alt_html" ] && continue
        alt_emails=$(printf '%s' "$alt_html" | runner_py step3b python3 -c '
import re, sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
html = sys.stdin.read()
out = set()
for m in re.findall(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}", html):
    e = R.normalize_email(m)
    if e and not R.junk_reason(e) and len(e) <= 60:
        out.add(e)
print("\n".join(sorted(out)))
' "$SCRIPT_DIR")
        [ -z "$alt_emails" ] && continue
        log "  Found on $alt_url:"
        while IFS= read -r alt_email <&5; do
            [ -z "$alt_email" ] && continue
            case "$seen" in *" $alt_email "*) continue ;; esac
            seen="$seen$alt_email "
            log "    $alt_email"
            verify_and_push "$alt_email" "$venue_id" "" "" "alt_domain_scrape" "external"
        done 5<<< "$alt_emails"
    done
}

# Final status per P4, from the sheet's TOTAL valid/role/unverified contacts after the run.
runner_final_status() {
    local venue="$1" vid="$2" start_status="$3"
    local new deferred fd="/tmp/pipeline_rv_final.json"
    new=$(grep -c . /tmp/pipeline_contacts_count 2>/dev/null); new=${new:-0}
    deferred=$(grep -c . /tmp/pipeline_deferred_count 2>/dev/null); deferred=${deferred:-0}
    local state="unreadable" cur="" valid=0 x
    if runner_fetch_detail "$vid" "$fd"; then
        IFS=$'\x1f' read -r state cur x x x x x valid x <<< "$(runner_detail_summary "$fd")"
    fi
    if [ "$state" != "ok" ]; then
        log "  [WARN] Could not re-read the venue from the sheet — deciding status from this run's saves only"
        cur="$start_status"; valid="$new"
    fi
    local target="" st
    if [ "${valid:-0}" -gt 0 ] 2>/dev/null; then
        st=ok
        if [ "$cur" = "pipelined" ] || [ "$cur" = "contacted" ]; then
            log "  Status stays $cur ($valid verified contacts on sheet, $new new this run)"
        else
            log "  Setting status → pipelined ($valid verified contacts on sheet, $new new this run)"
            target=pipelined
        fi
    else
        st=empty
        if [ "$cur" = "pipelined" ] || [ "$cur" = "contacted" ]; then
            log "  [STATUS] No valid/role/unverified contacts on the sheet, but status '$cur' is never demoted"
        else
            log "  Setting status → needs_review (no verified contacts saved)"
            target=needs_review
        fi
    fi
    local write_ok=1
    if [ -n "$target" ]; then
        runner_update_venue "$vid" status "$target" || write_ok=0
        if [ "$target" = "needs_review" ] && [ "$state" = "ok" ]; then
            runner_append_note "$vid" "$fd" "PIPELINE: 0 contacts ${RUN_ID:-$(date +%Y-%m-%d)}" || true
        fi
    fi
    local kv="valid_contacts=${valid:-0} new=$new deferred=$deferred"
    if [ "$write_ok" = 0 ]; then
        log "[STEP] $vid final failed reason=status_write_failed status=${cur:-unknown} wanted=$target $kv"
    elif [ "$state" != "ok" ]; then
        log "[STEP] $vid final failed reason=sheet_unreadable status=${target:-${cur:-unknown}} $kv"
    else
        log "[STEP] $vid final $st status=${target:-${cur:-unknown}} $kv"
    fi
}

run_venue() {
    local venue="$1" venue_id="$2" website="$3" city="$4"
    local start_time
    start_time=$(date +%s)
    case "$website" in None|none|null|NULL) website="" ;; esac

    # PD-4/PD-13: never run the paid steps under a blank name or ID
    if [ -z "$venue_id" ] || [ -z "$venue" ]; then
        log "  [ERROR] run_venue needs a venue name and ID (got name='$venue', id='$venue_id') — refusing to run"
        log "[STEP] ${venue_id:-unknown} final failed reason=missing_venue_id"
        return 1
    fi

    # Clear per-venue temp files and globals so the previous venue's data can't bleed in
    runner_clear_venue_tmp
    APOLLO_DOMAIN=""
    ZB_VENUE_CREDITS=0
    runner_set_venue_globals "$venue" "$venue_id" ""

    # One venue_detail read, reused for the ID check, status, category and website (C5: nested venue.*)
    local vd="/tmp/pipeline_rv_detail.json"
    local vd_state vd_status vd_category vd_website vd_city vd_name vd_ncontacts vd_nvalid vd_emails
    runner_fetch_detail "$venue_id" "$vd"
    IFS=$'\x1f' read -r vd_state vd_status vd_category vd_website vd_city vd_name vd_ncontacts vd_nvalid vd_emails <<< "$(runner_detail_summary "$vd")"

    # Resolve real venue ID — if the passed ID doesn't exist in the sheet,
    # look it up by domain. Catches the case where discover.sh assigned a
    # different ID than what was passed manually.
    if [ "$vd_state" = "not_found" ]; then
        local real_id=""
        [ -n "$website" ] && real_id=$(runner_find_by_domain "$website" "$venue")
        if [ -n "$real_id" ] && [ "$real_id" != "$venue_id" ]; then
            log "  [ID FIX] '$venue_id' not in sheet — using real ID '$real_id' (matched by domain of $website)"
            venue_id="$real_id"
            runner_set_venue_globals "$venue" "$venue_id" ""
            runner_fetch_detail "$venue_id" "$vd"
            IFS=$'\x1f' read -r vd_state vd_status vd_category vd_website vd_city vd_name vd_ncontacts vd_nvalid vd_emails <<< "$(runner_detail_summary "$vd")"
        else
            log "  [ERROR] Venue ID '$venue_id' is not in the sheet — refusing (contacts would be filed under a missing venue)"
            log "[STEP] $venue_id final failed reason=venue_not_in_sheet"
            return 1
        fi
    elif [ "$vd_state" != "ok" ]; then
        log "  [WARN] Could not read venue $venue_id from the sheet (Apps Script error or timeout) — status checks are best-effort"
    fi
    if [ "$vd_state" = "ok" ] && [ -n "$vd_name" ] && ! runner_names_match "$vd_name" "$venue"; then
        log "  [ERROR] Venue ID $venue_id is '$vd_name' in the sheet, not '$venue' — refusing to file contacts under the wrong venue"
        log "[STEP] $venue_id final failed reason=name_id_mismatch"
        return 1
    fi

    # --- EXISTING DATA CHECK ---
    # Existing contacts are NOT a completion signal. A prior run may have found an
    # owner/founder while missing events, catering, sales, social links, PDFs, etc.
    # Only venues that are explicitly contacted/closed are skipped here.
    if [ "$vd_status" = "contacted" ] || [ "$vd_status" = "closed" ]; then
        log "  [SKIP] Venue status prevents new outreach research: SKIP:$vd_status"
        echo "${venue}|${venue_id}|Status: SKIP:${vd_status}" >> "${SKIPPED_VENUES_FILE:-/tmp/pipeline_skipped.txt}"
        log "[STEP] $venue_id final skipped reason=status_$vd_status status=$vd_status"
        return 0
    elif [ "${vd_ncontacts:-0}" -gt 0 ] 2>/dev/null; then
        log "  [RESEARCH AGAIN] Existing contacts found, but web discovery will still run: $vd_emails"
    fi

    # The recovery path (./pipeline.sh "Name" ID) passes no website: use the sheet's
    if [ -z "$website" ] && [ -n "$vd_website" ] && [ "$vd_website" != "None" ]; then
        website="$vd_website"
        log "  [WEBSITE] Using the sheet's website: $website"
    fi
    [ -z "$city" ] && city="$vd_city"

    # Classify the website: brand homepages, listing/social pages and garbage values
    # ("https://86.3K+") are not this venue's site (PD-10, EVID-10).
    local orig_website="$website" had_scheme=1
    if [ -n "$website" ]; then
        printf '%s' "$website" | grep -qiE '^https?://' || had_scheme=0
        runner_set_venue_globals "$venue" "$venue_id" "$website"
        case "$RUNNER_SITE_VERDICT" in
            ok) website="$VENUE_WEBSITE" ;;
            brand_page)
                log "  [DOMAIN] Website $orig_website is the $VENUE_DOMAIN brand site, not this property's own page — looking for the property page"
                website="" ;;
            non_venue)
                log "  [DOMAIN] Website $orig_website is a listing/social site, not the venue's own website — looking for the real one"
                website="" ;;
            *)
                log "  [URL] Website value '$orig_website' is not a valid URL — treating the venue as having no website"
                website="" ;;
        esac
    fi

    # If no website, Google it via Chrome
    if [ -z "$website" ]; then
        log "  [LOOKUP] No website — Googling '$venue'..."
        if ! runner_google_candidates "$venue"; then
            log "  [LOOKUP] Google search failed (Chrome error or CAPTCHA) — continuing without a website"
        elif [ -z "$RUNNER_GOOGLE_RAW" ]; then
            log "  [LOOKUP] No website found via Google"
        else
            # Require a plausible official-site match. The old matcher accepted weak
            # token overlaps and could attach an unrelated Google result to a venue.
            local FOUND_SITE fv fh fr fs fp fu
            FOUND_SITE=$(runner_py lookup python3 "${SCRIPT_DIR}/venue_quality.py" choose-website "$venue" "$RUNNER_GOOGLE_RAW")
            if [ -n "$FOUND_SITE" ]; then
                IFS=$'\x1f' read -r fv fh fr fs fp fu <<< "$(runner_site_info "$FOUND_SITE" "$venue")"
            fi
            if [ -n "$FOUND_SITE" ] && [ "$fv" = "ok" ]; then
                website="$fu"
                log "  [LOOKUP] Found: $website"
                runner_set_venue_globals "$venue" "$venue_id" "$website"
                runner_update_venue "$venue_id" website "$website" || true
            else
                log "  [WARN] Google returned results but none matched venue '$venue': $RUNNER_GOOGLE_RAW"
            fi
        fi
    elif [ "$had_scheme" = 0 ]; then
        log "  [URL FIX] Added https:// scheme: $website"
        runner_update_venue "$venue_id" website "$website" || true
    fi

    # C1 domain globals (set by runner_set_venue_globals) drive every step's domain checks
    log "  [DOMAIN] Venue domain: ${VENUE_DOMAIN:-none}"
    if [ "$VENUE_SHARED_DOMAIN" = "true" ]; then
        if [ -n "$VENUE_SITE_PREFIX" ]; then
            log "  [DOMAIN] Shared brand domain — only pages under $VENUE_SITE_PREFIX count as this property's own site"
        else
            log "  [DOMAIN] Shared brand domain with no property page — brand-wide addresses and people are not this venue's"
        fi
    fi

    # Re-check category by venue name — ONLY if current category is generic 'restaurant'
    # Never overwrite intentional categories (art_gallery, museum, etc.)
    if [ "$vd_category" = "restaurant" ]; then
        local CORRECT_CAT
        CORRECT_CAT=$(runner_py category python3 "${SCRIPT_DIR}/venue_quality.py" category "restaurant" "$venue")
        [ "$CORRECT_CAT" = "restaurant" ] && CORRECT_CAT=""
        if [ -n "$CORRECT_CAT" ]; then
            log "  [FIX] Name-based category: $CORRECT_CAT (was restaurant) — updating sheet"
            runner_update_venue "$venue_id" category "$CORRECT_CAT" || true
        fi
    fi

    log ""
    log "============================================================"
    log " PIPELINE: $venue ($venue_id)"
    log " Website: $website"
    log " Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    # Track how many new contacts we find (file-based to survive subshells)
    rm -f /tmp/pipeline_contacts_count

    # Freshness check: ping the website to catch dead/closed venues early
    if [ -n "$website" ]; then
        local liveness http_code curl_rc live_url
        read -r liveness http_code curl_rc live_url <<< "$(runner_site_liveness "$website")"
        case "$liveness" in
            dns|refused|gone)
                [ "$liveness" = "gone" ] && liveness="gone:$http_code"
                runner_flag_dead "$venue" "$venue_id" "$liveness" "$website" "$vd" "$vd_status"
                return 0 ;;
            root)
                log "  [WEBSITE] $website returned $http_code but the site root is up — using $live_url for this run"
                website="$live_url"
                runner_set_venue_globals "$venue" "$venue_id" "$website" ;;
            *)
                if [ -n "$live_url" ] && [ "$live_url" != "$website" ]; then
                    log "  [WEBSITE] https refused, http works — using $live_url for this run"
                    website="$live_url"
                    runner_set_venue_globals "$venue" "$venue_id" "$website"
                fi
                if [ "${curl_rc:-0}" != "0" ]; then
                    log "  Website check: HTTP ${http_code} ✓ (curl exit $curl_rc: slow or blocking bots — treated as alive)"
                else
                    log "  Website check: HTTP ${http_code} ✓"
                fi ;;
        esac
    fi

    # Check ZeroBounce budget, but NEVER skip discovery because verification is paused.
    if ! check_zb_credits; then
        log "  [ZB SAFE] Continuing venue discovery with paid verification paused"
    fi

    # Load existing contacts once
    load_existing "$venue_id"
    ZB_VENUE_CREDITS=0  # Reset per-venue ZB counter
    log "  Known emails: $(printf '%s' "$KNOWN_EMAILS" | tr '|' '\n' | grep -c .)"
    log "  Known names: $(printf '%s' "$KNOWN_NAMES" | tr '|' '\n' | grep -c .)"

    step1_website "$venue" "$venue_id" "$website" "$city"
    step1b_ig_search "$venue" "$venue_id"
    step1c_fb_search "$venue" "$venue_id"
    step2_social "$venue" "$venue_id"
    # Check Apollo credits before the expensive API step
    if ! check_apollo_credits; then
        log "  [SKIP] Apollo step — credits too low"
        log "[STEP] $venue_id apollo skipped reason=credit_cap"
    else
        step3_apollo_api "$venue" "$venue_id" "$website" "$city"
    fi
    runner_save_state

    # Step 3b: Scrape alternate domain if Apollo returned a different one
    runner_step3b "$venue" "$venue_id"

    # LinkedIn — skip only if SKIP_LINKEDIN=1, or once this run has hit the wall
    rm -f /tmp/pipeline_li_verdict
    [ -f "/tmp/pipeline_li_walled_$$" ] && LINKEDIN_WALLED=1
    if [ "${SKIP_LINKEDIN:-0}" != "1" ] && [ "${LINKEDIN_WALLED:-0}" != "1" ]; then
        step4_linkedin "$venue" "$venue_id"
        local LI_VERDICT
        LI_VERDICT=$(cat /tmp/pipeline_li_verdict 2>/dev/null || echo "unknown")
        case "$LI_VERDICT" in
            found:*)
                runner_update_venue "$venue_id" linkedin_pending false || true
                ;;
            *)
                # empty / wall / unknown: the search did not actually happen. Keep it pending.
                runner_update_venue "$venue_id" linkedin_pending true || true
                log "  LinkedIn verdict '$LI_VERDICT' — kept linkedin_pending=true for retry"
                echo "FLAG:LinkedIn did not return results ($LI_VERDICT) — venue kept linkedin_pending" >> /tmp/pipeline_flags.txt
                ;;
        esac
    elif [ "${LINKEDIN_WALLED:-0}" = "1" ]; then
        log ""
        log "========== STEP 4: LinkedIn (SKIPPED — wall hit earlier this run) =========="
        runner_update_venue "$venue_id" linkedin_pending true || true
        echo "wall" > /tmp/pipeline_li_verdict
        log "  Marked linkedin_pending=true"
        log "[STEP] $venue_id linkedin blocked reason=login_wall_earlier_in_run"
    else
        log ""
        log "========== STEP 4: LinkedIn (SKIPPED — SKIP_LINKEDIN=1) =========="
        runner_update_venue "$venue_id" linkedin_pending true || true
        log "  Marked linkedin_pending=true"
        log "[STEP] $venue_id linkedin skipped reason=skip_linkedin"
    fi
    runner_save_state

    # Step 5: Google fallback if nothing found yet
    step5_google_fallback "$venue" "$venue_id" "$city"

    # Status reflects the sheet's total valid/role contacts (P4)
    runner_final_status "$venue" "$venue_id" "$vd_status"
    runner_save_state

    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$(( (end_time - start_time) / 60 ))

    log ""
    log "============================================================"
    log " DONE: $venue | ${elapsed} min | $(date '+%H:%M:%S')"
    log "============================================================"
}

# =================================================================
# BATCH RUNNER
# =================================================================
runner_usage() {
    cat <<'USAGE'
Usage:
  ./pipeline.sh --batch FILE.json        run one batch (max 8 venues; ALLOW_LARGE_BATCH=1 overrides)
  ./pipeline.sh --run N [--max-batches K]
                                         unattended run: ./build_batch.sh --total N builds a plan
                                         (batches of <= 8), then every batch runs under one RUN_ID
  ./pipeline.sh --plan [PLAN|LATEST] [--max-batches K]
                                         run an existing build_batch.sh --total plan
  ./pipeline.sh --resume [RUN_ID|RUN_LOG_FILE]
                                         re-run the run's venues that have no DONE: line, finish
                                         their postcheck/report, then continue the run's plan
  ./pipeline.sh "Venue Name" [VENUE_ID [WEBSITE [CITY]]]
                                         one venue; without an ID the name must match exactly
  ./pipeline.sh --linkedin-retry         re-run LinkedIn for venues with linkedin_pending=true
  ./pipeline.sh --report [RUN_ID]        rebuild a run's report (after manual marks / the miss audit)
Env: RUN_ID, RUN_LOG, VENUE_TIMEOUT_MIN (25), POSTCHECK_TIMEOUT_MIN, SKIP_PREFLIGHT=1,
     ALLOW_CURL_ONLY=1, ALLOW_DEGRADED=1, MAX_FAIL_STREAK (2), SKIP_LINKEDIN=1
USAGE
}

runner_proc_tree() {
    local p="$1" c
    echo "$p"
    for c in $(pgrep -P "$p" 2>/dev/null); do runner_proc_tree "$c"; done
}

runner_kill_tree() {
    local pids
    pids=$(runner_proc_tree "$1")
    kill -TERM $pids 2>/dev/null
    sleep 2
    kill -KILL $pids 2>/dev/null
}

# runner_run_guarded SECONDS LABEL CMD... — run CMD in a subshell, kill its whole
# process tree after SECONDS (macOS has no `timeout`). Returns CMD's exit, or 124.
runner_run_guarded() {
    local secs="$1" label="$2" waited=0 rc
    shift 2
    ( RUNNER_IN_CHILD=1; "$@" ) &
    RUNNER_CHILD_PID=$!
    while kill -0 "$RUNNER_CHILD_PID" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            log "  [WATCHDOG] $label still running after $((secs / 60)) min — killing it"
            runner_kill_tree "$RUNNER_CHILD_PID"
            wait "$RUNNER_CHILD_PID" 2>/dev/null
            RUNNER_CHILD_PID=""
            return 124
        fi
        sleep 2
        waited=$((waited + 2))
    done
    wait "$RUNNER_CHILD_PID"
    rc=$?
    RUNNER_CHILD_PID=""
    return $rc
}

LOCK_FILE="/tmp/pipeline.lock"
LOCK_DIR="/tmp/pipeline.lock.d"
RUNNER_HAVE_LOCK=0
runner_lock_holder_alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null && ps -p "$1" -o command= 2>/dev/null | grep -q 'pipeline\.sh'
}

# Atomic (mkdir) lock, taken before any run-level cleanup (PD-16).
runner_take_lock() {
    local pid
    if [ -f "$LOCK_FILE" ] && [ ! -d "$LOCK_DIR" ]; then
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if runner_lock_holder_alive "$pid"; then
            echo "ERROR: Pipeline already running (PID $pid). Wait for it to finish."
            return 1
        fi
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if runner_lock_holder_alive "$pid"; then
            echo "ERROR: Pipeline already running (PID $pid). Wait for it to finish."
            return 1
        fi
        echo "WARNING: Stale lock file found (PID ${pid:-?} not running). Removing."
        rm -rf "$LOCK_DIR"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "ERROR: could not take the pipeline lock ($LOCK_DIR)"
            return 1
        fi
    fi
    echo $$ > "$LOCK_DIR/pid"
    echo $$ > "$LOCK_FILE"
    RUNNER_HAVE_LOCK=1
    export PIPELINE_LOCK_PID=$$
}

runner_on_exit() {
    [ "${RUNNER_IN_CHILD:-0}" = "1" ] && return
    [ -n "$RUNNER_CHILD_PID" ] && runner_kill_tree "$RUNNER_CHILD_PID"
    # Squarespace event pages make Chrome auto-download .ics files; remove only
    # the ones that appeared during this run (PD-17), never the user's older files.
    if [ -n "${RUNNER_ICS_MARKER:-}" ] && [ -f "$RUNNER_ICS_MARKER" ]; then
        local ics
        while IFS= read -r ics; do
            [ -n "$ics" ] && rm -f "$ics" && log "[CLEANUP] Removed calendar download from this run: $ics"
        done < <(find "$HOME/Downloads" -maxdepth 1 -type f -name '*.ics' -newer "$RUNNER_ICS_MARKER" 2>/dev/null)
        rm -f "$RUNNER_ICS_MARKER"
    fi
    rm -f "$RUNNER_STATE_FILE" "${RUNNER_STATE_FILE}.tmp" "/tmp/pipeline_apollo_credits_$$" \
          "/tmp/pipeline_li_walled_$$" "/tmp/pipeline_li_empty_streak_$$" /tmp/pipeline_run_*_$$ \
          /tmp/pipeline_run_postcheck_out.txt /tmp/pipeline_run_reapply.json /tmp/pipeline_run_status_check.json
    if [ "$RUNNER_HAVE_LOCK" = "1" ]; then
        rm -rf "$LOCK_DIR"
        rm -f "$LOCK_FILE"
    fi
}

runner_on_signal() {
    local sig="$1"
    trap - INT TERM
    log ""
    log "[RUN] ABORTED (signal $sig)${RUNNER_CUR_VID:+ during venue $RUNNER_CUR_NAME ($RUNNER_CUR_VID)}. Resume with: ./pipeline.sh --resume ${RUN_ID:-<RUN_ID>}"
    [ -n "$RUNNER_CUR_VID" ] && log "[STEP] $RUNNER_CUR_VID final failed reason=aborted signal=$sig"
    if [ -n "$RUNNER_CHILD_PID" ]; then
        runner_kill_tree "$RUNNER_CHILD_PID"
        RUNNER_CHILD_PID=""
    fi
    [ "$sig" = "INT" ] && exit 130
    exit 143
}

runner_stop() {
    RUNNER_STOPPED=1
    RUNNER_STOP_REASON="$1"
    log ""
    log "[RUN] STOPPED: $1"
    log "[RUN] Unfinished venues have no DONE: line. Fix the cause, then resume with: ./pipeline.sh --resume ${RUN_ID}"
}

# C6. --quick between batches of a multi-batch run.
runner_preflight() {
    if [ "${SKIP_PREFLIGHT:-0}" = "1" ]; then
        log "[PREFLIGHT] Skipped (SKIP_PREFLIGHT=1)"
        return 0
    fi
    if [ ! -x "${SCRIPT_DIR}/preflight.sh" ]; then
        log "PREFLIGHT FAIL: preflight.sh missing or not executable — aborting (SKIP_PREFLIGHT=1 bypasses)"
        return 1
    fi
    local rc
    runner_run_guarded 600 preflight "${SCRIPT_DIR}/preflight.sh" --for pipeline "$@"
    rc=$?
    if [ "$rc" != 0 ]; then
        log "[PREFLIGHT] FAIL (exit $rc) — aborting. Fix the FAIL lines above, or set SKIP_PREFLIGHT=1 to bypass."
        return 1
    fi
    log "[PREFLIGHT] OK"
}

# EVID-9: run the REAL website scrape file (U1's write_scrape_js) on a real page.
# The old probe ran "1+1", which passed while every scrape came back empty.
runner_chrome_probe() {
    local url="${1:-https://www.google.com/}" out try
    if [ "${SKIP_CHROME_PROBE:-0}" = "1" ]; then
        log "[CHROME] Probe skipped (SKIP_CHROME_PROBE=1)"
        return 0
    fi
    if ! declare -F write_scrape_js >/dev/null; then
        if runner_chrome_alive; then
            CHROME_JS_OK=1
            log "[CHROME] JavaScript from Apple Events: OK (basic probe only — write_scrape_js not available)"
            return 0
        fi
        CHROME_JS_OK=0
        log "[CHROME] FAIL: Chrome did not execute JavaScript. Enable View > Developer > Allow JavaScript from Apple Events."
        [ "${ALLOW_CURL_ONLY:-0}" = "1" ] && { log "[CHROME] ALLOW_CURL_ONLY=1 — continuing curl-only"; return 0; }
        return 1
    fi
    write_scrape_js
    if [ ! -s /tmp/pipeline_website_scrape.js ]; then
        log "[CHROME] FAIL: write_scrape_js did not produce /tmp/pipeline_website_scrape.js"
        return 1
    fi
    runner_chrome_nav "$url"
    for try in 1 2; do
        sleep $((try * 6))
        out=$(runner_chrome_js_file /tmp/pipeline_website_scrape.js)
        if printf '%s' "$out" | runner_py chrome_probe python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) else 1)' 2>/dev/null; then
            CHROME_JS_OK=1
            log "[CHROME] JavaScript from Apple Events: OK (website scrape probe on $url returned ${#out} bytes of JSON)"
            return 0
        fi
    done
    CHROME_JS_OK=0
    log "[CHROME] FAIL: the website scrape JS returned '${out:0:120}' on $url (expected JSON). Check View > Developer > Allow JavaScript from Apple Events and $ERR_LOG."
    if [ "${ALLOW_CURL_ONLY:-0}" = "1" ]; then
        log "[CHROME] ALLOW_CURL_ONLY=1 — continuing; website scrapes will be curl-only"
        return 0
    fi
    return 1
}

# --- run bookkeeping: RUN_ID, run log, saved batches, ledger, manifest ---
runner_valid_run_id() {
    case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    return 0
}

runner_batch_file() { echo "${RUNS_DIR}/${RUN_ID}.batch$1.json"; }

runner_batch_numbers() {
    local n=1
    while [ -f "$(runner_batch_file "$n")" ]; do echo "$n"; n=$((n + 1)); done
}

runner_next_batch_no() {
    local n=1
    while [ -f "$(runner_batch_file "$n")" ]; do n=$((n + 1)); done
    echo "$n"
}

# Distinct venue ids across this run's saved batches, comma-separated, in order.
runner_run_venue_csv() {
    local files=() n
    for n in $(runner_batch_numbers); do files+=("$(runner_batch_file "$n")"); done
    [ ${#files[@]} -eq 0 ] && return 0
    runner_py run_csv python3 - "${files[@]}" <<'PYEOF'
import json, sys
seen = []
for p in sys.argv[1:]:
    try:
        with open(p) as f:
            for v in json.load(f):
                vid = str((v or {}).get('venue_id') or '').strip()
                if vid and vid not in seen:
                    seen.append(vid)
    except Exception as e:
        print(f"unreadable batch file {p}: {e}", file=sys.stderr)
print(','.join(seen))
PYEOF
}

runner_run_venue_count() {
    local csv
    csv=$(runner_run_venue_csv)
    [ -z "$csv" ] && { echo 0; return; }
    echo "$csv" | tr ',' '\n' | grep -c .
}

# Is this venue already finished in the run log? (resume: re-run only venues without DONE:)
runner_venue_done() {
    local vid="$1" name="$2"
    [ -f "$RUN_LOG" ] || return 1
    grep -qE "\[STEP\] ${vid//./\\.} final (ok|empty|skipped)( |$)" "$RUN_LOG" && return 0
    grep -qF " DONE: $name |" "$RUN_LOG"
}

runner_ledger_has() {
    local vid="$1" ledger="${RUNS_DIR}/$2.jsonl"
    [ -f "$ledger" ] && grep -q "\"venue_id\": *\"$vid\"" "$ledger"
}

# Batch JSON -> one \x1f-separated line per venue (id name website city). Refuses bad entries.
runner_parse_batch() {
    runner_py batch_load python3 - "$1" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR: cannot read {path}: {e}"); sys.exit(2)
if not isinstance(data, list):
    print(f"ERROR: {path} is not a JSON list"); sys.exit(2)
def clean(s):
    return ' '.join(str('' if s is None else s).replace('\x1f', ' ').split())
bad, rows, seen = [], [], set()
for i, v in enumerate(data):
    if not isinstance(v, dict):
        bad.append(f"#{i + 1} is not an object"); continue
    vid, name = clean(v.get('venue_id')), clean(v.get('name'))
    if not vid or not name:
        bad.append(f"#{i + 1} has no venue_id or name"); continue
    if vid in seen:
        continue
    seen.add(vid)
    rows.append('\x1f'.join([vid, name, clean(v.get('website')), clean(v.get('city'))]))
if bad:
    print("ERROR: invalid batch entries: " + '; '.join(bad)); sys.exit(3)
print('\n'.join(rows))
PYEOF
}

# Loads a batch JSON into B_IDS/B_NAMES/B_WEBS/B_CITIES (B_COUNT).
runner_load_batch() {
    B_IDS=(); B_NAMES=(); B_WEBS=(); B_CITIES=(); B_COUNT=0
    local out rc id name web city
    out=$(runner_parse_batch "$1")
    rc=$?
    if [ "$rc" != 0 ]; then
        log "[BATCH] ${out:-ERROR: could not parse batch file $1 (see $ERR_LOG)}"
        return 1
    fi
    while IFS=$'\x1f' read -r id name web city; do
        [ -z "$id" ] && continue
        B_IDS[$B_COUNT]="$id"; B_NAMES[$B_COUNT]="$name"; B_WEBS[$B_COUNT]="$web"; B_CITIES[$B_COUNT]="$city"
        B_COUNT=$((B_COUNT + 1))
    done <<< "$out"
    return 0
}

# Loaded batch venues (B_*) that have no finished result in the run log yet.
runner_unfinished_ids() {
    local i
    for ((i = 0; i < B_COUNT; i++)); do
        runner_venue_done "${B_IDS[$i]}" "${B_NAMES[$i]}" || echo "${B_IDS[$i]}"
    done
}

# Registers the batch's venues in the ledger (mark_step.sh) unless already registered.
runner_register_ledger() {
    local bfile="$1" vid missing=0 out rc
    for vid in "${B_IDS[@]}"; do
        runner_ledger_has "$vid" "$RUN_ID" || missing=$((missing + 1))
    done
    [ "$missing" = 0 ] && return 0
    local args=(--batch "$bfile" "$RUN_ID")
    if [ -f "${RUNS_DIR}/${RUN_ID}.jsonl" ]; then
        args+=(--append)
    elif [ "$RUNNER_MODE" = "--run" ] || [ "$RUNNER_MODE" = "--plan" ]; then
        args+=(--new-run)
    fi
    out=$("${SCRIPT_DIR}/mark_step.sh" "${args[@]}" 2>&1)
    rc=$?
    while IFS= read -r vid; do [ -n "$vid" ] && log "  $vid"; done <<< "$out"
    if [ "$rc" != 0 ]; then
        log "[LEDGER] FAILED: ./mark_step.sh ${args[*]} exited $rc — refusing to run venues verify_run can't see. Register the batch yourself or set RUN_ID."
        return 1
    fi
    return 0
}

# C4: stub report + manifest entry at batch start so the app gates these venues now.
# manifest_register_run prints the report path on stdout (its log lines go to stderr).
runner_manifest_register() {
    local out rc
    if ! declare -F manifest_register_run >/dev/null; then
        log "[REPORT] WARNING: manifest_register_run is not available — venues are not gated in the app until a report exists"
        return 0
    fi
    out=$(manifest_register_run "$RUN_ID" "$1")
    rc=$?
    if [ "$rc" != 0 ] || [ -z "$out" ]; then
        log "[REPORT] WARNING: manifest_register_run failed (exit $rc) — the app will not hide this batch's venues"
        return 0
    fi
    RUNNER_REPORT_PATH=$(printf '%s\n' "$out" | tail -1)
    log "[REPORT] Manifest gate written (push reports/manifest.json + $RUNNER_REPORT_PATH for the app to see it)"
}

# RUN_MORE_BATCHES=1 keeps the manifest entry "running" while more batches follow.
runner_report() {
    local more="${1:-0}" rc
    if ! declare -F generate_report >/dev/null; then
        log "[REPORT] WARNING: generate_report is not available — no report written"
        return 1
    fi
    sleep 2  # let the tee'd run log catch up before it is parsed
    if [ "$more" = "1" ]; then
        RUN_MORE_BATCHES=1 generate_report "$RUN_LOG" "$RUN_ID" "$(runner_run_venue_csv)"
    else
        RUN_MORE_BATCHES= generate_report "$RUN_LOG" "$RUN_ID" "$(runner_run_venue_csv)"
    fi
    rc=$?
    if [ "$rc" != 0 ]; then
        log "[REPORT] FAILED: generate_report exited $rc — see the lines above and $ERR_LOG"
        return 1
    fi
    RUNNER_LAST_REPORT_MORE="$more"
    return 0
}

# Handoff point for the session's miss audit: reports/runs/<RUN_ID>.batch<N>.done
runner_write_marker() {
    local bno="$1" csv="$2"
    runner_py batch_marker python3 - "${RUNS_DIR}/${RUN_ID}.batch${bno}.done" "$RUN_ID" "$bno" "$csv" "$RUN_LOG" "${RUNNER_REPORT_PATH:-}" <<'PYEOF'
import json, os, re, sys, datetime
path, rid, bno, csv, run_log, report = sys.argv[1:7]
ids = [v for v in csv.split(',') if v]
final = {}
try:
    with open(run_log, errors='replace') as f:
        for line in f:
            m = re.search(r'\[STEP\] (\S+) final (\w+)(.*)$', line)
            if m and m.group(1) in ids:
                st = re.search(r'\bstatus=(\S+)', m.group(3))
                final[m.group(1)] = {'result': m.group(2), 'status': st.group(1) if st else ''}
except OSError:
    pass
doc = {'run_id': rid, 'batch': int(bno), 'venue_ids': ids, 'final': final,
       'finished_at': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
       'run_log': run_log, 'report': report,
       'batch_file': os.path.join(os.path.dirname(path), f'{rid}.batch{bno}.json')}
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(doc, f, indent=2)
os.replace(tmp, path)
PYEOF
    if [ $? = 0 ]; then
        log "[RUN] Batch $bno done — marker ${RUNS_DIR}/${RUN_ID}.batch${bno}.done (ready for the miss audit)"
    else
        log "[RUN] WARNING: could not write the batch $bno marker (see $ERR_LOG)"
    fi
}

# Last [STEP] status of STEP among LINES; 'degraded' for a curl-only web scrape.
runner_step_status() {
    local line st
    line=$(printf '%s\n' "$1" | grep -E "\[STEP\] [^ ]+ $2 " | tail -1)
    [ -z "$line" ] && return 0
    st=$(printf '%s\n' "$line" | sed -E 's/.*\[STEP\] [^ ]+ [a-z_]+ ([a-z]+).*/\1/')
    # " via=" with the space: step 1 also writes home_via=curl when Chrome worked but
    # the site walled it, which is not a Chrome failure.
    case "$line" in *" via=curl"*) [ "$st" != "skipped" ] && st="degraded" ;; esac
    echo "$st"
}

runner_streak() {
    case "$1" in
        failed|blocked|degraded) echo $(( $2 + 1 )) ;;
        ok|empty|skipped) echo 0 ;;
        *) echo "$2" ;;
    esac
}

# After each venue: stop the run loudly (resumable) instead of grinding on degraded.
runner_after_venue_checks() {
    local vid="$1" from="$2" rc="$3" lines st
    if [ "$rc" = 124 ]; then RUNNER_STREAK_TIMEOUT=$((RUNNER_STREAK_TIMEOUT + 1)); else RUNNER_STREAK_TIMEOUT=0; fi
    [ "${ALLOW_DEGRADED:-0}" = "1" ] && return 0
    if [ -f "$APOLLO_EXHAUSTED_FLAG" ]; then
        RUNNER_STOP_REASON="Apollo credits exhausted or the per-batch cap (MAX_APOLLO=$MAX_APOLLO) was reached"
        return 1
    fi
    # ZeroBounce paused/deferred is NOT a stop: those emails are saved as 'unverified'
    # for ./reverify.sh (Alex, Sep 25). Apollo exhaustion, Chrome and hangs are.
    if [ "$RUNNER_STREAK_TIMEOUT" -ge "$MAX_FAIL_STREAK" ]; then
        RUNNER_STOP_REASON="$RUNNER_STREAK_TIMEOUT venues in a row hit the ${VENUE_TIMEOUT_MIN}-minute watchdog (Chrome or a crawl is hanging)"
        return 1
    fi
    lines=$(tail -n +"$((from + 1))" "$LOG_FILE" 2>/dev/null | grep -F "[STEP] $vid ")
    st=$(runner_step_status "$lines" web)
    [ "${ALLOW_CURL_ONLY:-0}" = "1" ] && [ "$st" = "degraded" ] && st=""
    RUNNER_STREAK_WEB=$(runner_streak "$st" "$RUNNER_STREAK_WEB")
    RUNNER_STREAK_APOLLO=$(runner_streak "$(runner_step_status "$lines" apollo)" "$RUNNER_STREAK_APOLLO")
    RUNNER_STREAK_SOCIAL=$(runner_streak "$(runner_step_status "$lines" social)" "$RUNNER_STREAK_SOCIAL")
    if [ "$RUNNER_STREAK_WEB" -ge "$MAX_FAIL_STREAK" ]; then
        RUNNER_STOP_REASON="website scrape failed or fell back to curl on $RUNNER_STREAK_WEB venues in a row (Chrome JavaScript not working?)"
        return 1
    fi
    if [ "$RUNNER_STREAK_APOLLO" -ge "$MAX_FAIL_STREAK" ]; then
        RUNNER_STOP_REASON="Apollo step failed on $RUNNER_STREAK_APOLLO venues in a row (API key, credits or outage?)"
        return 1
    fi
    if [ "$RUNNER_STREAK_SOCIAL" -ge "$MAX_FAIL_STREAK" ]; then
        RUNNER_STOP_REASON="social/Google searches failed or were blocked on $RUNNER_STREAK_SOCIAL venues in a row (CAPTCHA?)"
        return 1
    fi
    return 0
}

runner_postcheck_cmd() {
    set -o pipefail
    "${SCRIPT_DIR}/postcheck.sh" --venues "$1" --run-id "$RUN_ID" 2>&1 | tee /tmp/pipeline_run_postcheck_out.txt
}

# C7 on the batch's finished venues, then re-apply P4 where postcheck saved something.
runner_postcheck() {
    local vid ids=() csv rc secs
    for vid in "$@"; do
        grep -qE "\[STEP\] ${vid//./\\.} final (ok|empty)( |$)" "$RUN_LOG" 2>/dev/null || continue
        grep -qF "[STEP] $vid postcheck " "$RUN_LOG" 2>/dev/null && continue
        ids+=("$vid")
    done
    log ""
    if [ ${#ids[@]} -eq 0 ]; then
        log "=== AUTO-RUNNING POSTCHECK ON THIS BATCH: nothing to check (no finished venue without a postcheck result) ==="
        return 0
    fi
    csv=$(IFS=,; echo "${ids[*]}")
    log "=== AUTO-RUNNING POSTCHECK ON THIS BATCH (${#ids[@]} venues: $csv) ==="
    if [ ! -x "${SCRIPT_DIR}/postcheck.sh" ]; then
        log "[WARN] postcheck.sh not found or not executable at ${SCRIPT_DIR}/postcheck.sh"
        return 1
    fi
    if [ -n "${POSTCHECK_TIMEOUT_MIN:-}" ]; then
        secs=$((POSTCHECK_TIMEOUT_MIN * 60))
    elif [ "${POSTCHECK_MAX_MINUTES:-30}" = "0" ]; then
        secs=$((${#ids[@]} * 20 * 60))
    else
        secs=$(( (${POSTCHECK_MAX_MINUTES:-30} + 15) * 60 ))
    fi
    rm -f /tmp/pipeline_run_postcheck_out.txt
    export ERR_LOG ZB_RUN_ID RUN_ID
    runner_run_guarded "$secs" postcheck runner_postcheck_cmd "$csv"
    rc=$?
    case "$rc" in
        0) ;;
        2) log "[POSTCHECK] Some venues were degraded, failed or cut by the time budget (exit 2) — see their [STEP] postcheck lines" ;;
        124) log "[POSTCHECK] WARNING: postcheck was killed by the watchdog after $((secs / 60)) min" ;;
        *) log "[POSTCHECK] ERROR: postcheck exited $rc for venues $csv (bad arguments or no venues?)" ;;
    esac
    # postcheck never writes venue status: re-apply P4 where it saved or enriched contacts
    local line saved enriched
    while IFS= read -r line <&5; do
        vid=$(printf '%s\n' "$line" | sed -E 's/.*\[STEP\] ([^ ]+) postcheck .*/\1/')
        saved=$(printf '%s\n' "$line" | sed -nE 's/.* saved=([0-9]+).*/\1/p')
        enriched=$(printf '%s\n' "$line" | sed -nE 's/.* enriched=([0-9]+).*/\1/p')
        if [ "${saved:-0}" -gt 0 ] || [ "${enriched:-0}" -gt 0 ]; then
            runner_reapply_status "$vid" "${saved:-0}"
        fi
    done 5< <(grep -F "[STEP] " /tmp/pipeline_run_postcheck_out.txt 2>/dev/null | grep -F " postcheck ")
    return 0
}

# P4 after postcheck: promote to pipelined when the sheet now has valid/role contacts.
runner_reapply_status() {
    local vid="$1" saved="$2" fd="/tmp/pipeline_run_reapply.json" state cur valid x
    runner_fetch_detail "$vid" "$fd" || { log "  [STATUS] $vid: could not re-read the sheet after postcheck"; return 1; }
    IFS=$'\x1f' read -r state cur x x x x x valid x <<< "$(runner_detail_summary "$fd")"
    [ "$state" = "ok" ] || return 1
    if [ "${valid:-0}" -gt 0 ] && [ "$cur" != "pipelined" ] && [ "$cur" != "contacted" ]; then
        if runner_update_venue "$vid" status pipelined; then
            log "  [$vid] Setting status → pipelined ($valid verified contacts on sheet, found by postcheck)"
            local notes
            if notes=$(runner_json_get "$fd" venue.notes) && [ -n "$notes" ]; then
                local cleaned
                cleaned=$(runner_py notes_clean python3 -c 'import re, sys; print(re.sub(r"( \| )?PIPELINE: 0 contacts " + re.escape(sys.argv[2]) + r"[^|]*", "", sys.argv[1]).strip(" |"))' "$notes" "${RUN_ID:-}")
                [ "$cleaned" != "$notes" ] && runner_update_venue "$vid" notes "$cleaned" >/dev/null
            fi
            log "[STEP] $vid final ok status=pipelined valid_contacts=$valid new=$saved deferred=0 via=postcheck"
        else
            log "[STEP] $vid final failed reason=status_write_failed status=$cur wanted=pipelined valid_contacts=$valid via=postcheck"
        fi
    fi
}

# First website in the batch that is the venue's own page — the Chrome probe target.
runner_probe_url() {
    local i v h r s p u
    for ((i = 0; i < B_COUNT; i++)); do
        [ -n "${B_WEBS[$i]}" ] || continue
        IFS=$'\x1f' read -r v h r s p u <<< "$(runner_site_info "${B_WEBS[$i]}" "${B_NAMES[$i]}")"
        [ "$v" = "ok" ] && { echo "$u"; return; }
    done
    echo "https://www.google.com/"
}

# One batch: <= 8 venues, per-venue watchdog, postcheck, report, marker.
# 0 = done, 2 = refused (bad/oversized batch, ledger), 3 = STOPPED (resumable).
runner_run_batch() {
    local bfile="$1" bno="$2" i rc
    runner_load_batch "$bfile" || return 2
    if [ "$B_COUNT" -eq 0 ]; then
        log "[BATCH] Batch file $bfile is empty — nothing to do"
        return 0
    fi
    if [ "$B_COUNT" -gt "$MAX_BATCH_SIZE" ] && [ "${ALLOW_LARGE_BATCH:-0}" != "1" ]; then
        log "[BATCH] REFUSED: $B_COUNT venues in $bfile; the limit is $MAX_BATCH_SIZE per batch (P6). Use --run N for more venues, or set ALLOW_LARGE_BATCH=1."
        return 2
    fi
    runner_register_ledger "$bfile" || return 2
    local batch_csv
    batch_csv=$(IFS=,; echo "${B_IDS[*]}")

    local pending=()
    for ((i = 0; i < B_COUNT; i++)); do
        runner_venue_done "${B_IDS[$i]}" "${B_NAMES[$i]}" || pending+=("$i")
    done

    runner_manifest_register "$(runner_run_venue_csv)"
    log ""
    log "BATCH MODE: $B_COUNT venues"
    log "[RUN] $RUN_ID batch $bno: $batch_csv (${#pending[@]} to run; log $RUN_LOG)"

    # Per-batch caps, as when every batch was its own process
    case "$ZB_RUN_ID" in pipeline-*-$$*) export ZB_RUN_ID="pipeline-${RUN_ID}-b${bno}-$$" ;; esac
    APOLLO_CREDITS_USED=0
    echo 0 > "/tmp/pipeline_apollo_credits_$$"
    runner_save_state
    RUNNER_STREAK_WEB=0; RUNNER_STREAK_APOLLO=0; RUNNER_STREAK_SOCIAL=0; RUNNER_STREAK_TIMEOUT=0
    rm -f "$SKIPPED_VENUES_FILE"

    if [ ${#pending[@]} -gt 0 ]; then
        if ! check_zb_credits; then
            log "[RUN] ZeroBounce is paused: personal emails in batch $bno are saved as 'unverified' — run ./reverify.sh once credits are back"
        fi
        if ! runner_chrome_probe "$(runner_probe_url)"; then
            runner_stop "Chrome website-scrape probe failed before batch $bno"
            runner_report 1
            return 3
        fi
    fi

    local idx vid name web city vstatus from line n=0
    for idx in "${pending[@]}"; do
        n=$((n + 1))
        vid="${B_IDS[$idx]}"; name="${B_NAMES[$idx]}"; web="${B_WEBS[$idx]}"; city="${B_CITIES[$idx]}"
        log ""
        log "########## VENUE [$((idx + 1))/$B_COUNT]: $name ##########"
        # Skip venues already pipelined or contacted (C5: status is nested under venue)
        vstatus=""
        if runner_fetch_detail "$vid" /tmp/pipeline_run_status_check.json; then
            vstatus=$(runner_json_get /tmp/pipeline_run_status_check.json venue.status)
        fi
        if [ "$vstatus" = "pipelined" ] || [ "$vstatus" = "contacted" ]; then
            log "  [SKIP] Already $vstatus — skipping"
            log "[STEP] $vid final skipped reason=already_$vstatus status=$vstatus"
            continue
        fi
        if ! runner_chrome_alive; then
            sleep 10
            if ! runner_chrome_alive && [ "${ALLOW_CURL_ONLY:-0}" != "1" ]; then
                runner_stop "Chrome stopped answering JavaScript before venue $name ($vid)"
                break
            fi
        fi
        from=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        RUNNER_CUR_VID="$vid"; RUNNER_CUR_NAME="$name"
        runner_run_guarded $((VENUE_TIMEOUT_MIN * 60)) "venue $name ($vid)" run_venue "$name" "$vid" "$web" "$city"
        rc=$?
        runner_load_state
        if [ "$rc" = 124 ]; then
            log "[STEP] $vid final failed reason=timeout minutes=$VENUE_TIMEOUT_MIN"
        elif ! tail -n +"$((${from:-0} + 1))" "$LOG_FILE" 2>/dev/null | grep -qE '\[STEP\] [^ ]+ final '; then
            log "[STEP] $vid final failed reason=crash exit=$rc"
        fi
        RUNNER_CUR_VID=""; RUNNER_CUR_NAME=""
        if ! runner_after_venue_checks "$vid" "${from:-0}" "$rc"; then
            runner_stop "$RUNNER_STOP_REASON"
            break
        fi
        if [ "$n" -lt "${#pending[@]}" ]; then sleep 30; fi
    done

    if [ -f "$SKIPPED_VENUES_FILE" ] && [ -s "$SKIPPED_VENUES_FILE" ]; then
        log ""
        log "============================================================"
        log " SKIPPED VENUES (need manual lookup):"
        log "============================================================"
        while IFS='|' read -r SNAME SVID SREASON; do
            log "  ✗ $SNAME ($SVID) — $SREASON"
        done < "$SKIPPED_VENUES_FILE"
        log "============================================================"
    fi
    if [ -s /tmp/pipeline_flags.txt ]; then
        log ""
        log "--- FLAGS raised in this batch ---"
        while IFS= read -r line; do log "  $line"; done < /tmp/pipeline_flags.txt
        : > /tmp/pipeline_flags.txt
    fi
    if [ "$RUNNER_STOPPED" = "1" ]; then
        runner_report 1   # unfinished: the manifest entry stays "running"
        return 3
    fi
    log "=== BATCH COMPLETE ==="

    runner_postcheck "${B_IDS[@]}"
    runner_report "${RUNNER_MORE_AFTER:-0}"
    runner_write_marker "$bno" "$batch_csv"
    return 0
}

# --run / --plan: build_batch.sh --total N writes a plan (<dir>/plan.json + batch_NN.json,
# <= 8 venues each, no repeats). It must run before this script takes its lock.
# runner_plan_json ARG -> plan.json path ('' if none). ARG: plan.json | plan dir | LATEST.
runner_plan_json() {
    local a="${1:-LATEST}" d
    case "$a" in
        LATEST|latest) d=$(head -1 "${SCRIPT_DIR}/reports/runs/plans/LATEST" 2>/dev/null) ;;
        *) d="$a" ;;
    esac
    [ -d "$d" ] && d="$d/plan.json"
    [ -n "$d" ] && [ -f "$d" ] && echo "$d"
}

runner_plan_batches() {
    runner_py plan_batches python3 - "$1" <<'PYEOF'
import json, os, sys
p = sys.argv[1]
with open(p) as f:
    plan = json.load(f)
for b in sorted(plan.get('batches', []), key=lambda b: int(b.get('index') or 0)):
    f = b.get('file') or ''
    if f and not os.path.isabs(f):
        f = os.path.join(os.path.dirname(p), f)
    print(f)
PYEOF
}

# Run the plan's batches this run hasn't taken yet, one batch of <= 8 at a time, all
# under RUN_ID. Batches already taken are left to --resume's unfinished-venue pass.
runner_run_plan() {
    local plan="$1" files=() f n bno rc started=0 total i=0
    echo "$plan" > "${RUNS_DIR}/${RUN_ID}.plan"
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(runner_plan_batches "$plan")
    total=${#files[@]}
    if [ "$total" -eq 0 ]; then
        log "[RUN] Plan $plan lists no batch files (see $ERR_LOG)"
        return 2
    fi
    log "[RUN] Plan $plan: $total batch(es)"
    for f in "${files[@]}"; do
        i=$((i + 1))
        bno=""
        for n in $(runner_batch_numbers); do
            cmp -s "$f" "$(runner_batch_file "$n")" && { bno="$n"; break; }
        done
        [ -n "$bno" ] && continue
        if [ ! -f "$f" ]; then
            runner_stop "plan batch file is missing: $f"
            return 3
        fi
        if [ -n "${RUNNER_MAX_BATCHES:-}" ] && [ "$started" -ge "$RUNNER_MAX_BATCHES" ]; then
            log "[RUN] --max-batches $RUNNER_MAX_BATCHES reached; continue the plan with: ./pipeline.sh --resume $RUN_ID"
            return 0
        fi
        if [ "$RUNNER_BATCHES_DONE" -gt 0 ] && ! runner_preflight --quick; then
            runner_stop "preflight failed between batches"
            return 3
        fi
        bno=$(runner_next_batch_no)
        if ! cp "$f" "$(runner_batch_file "$bno")"; then
            runner_stop "could not save plan batch $f under $RUNS_DIR"
            return 3
        fi
        RUNNER_MORE_AFTER=0
        [ "$i" -lt "$total" ] && RUNNER_MORE_AFTER=1
        log ""
        log "[RUN] Plan batch $i/$total -> batch $bno of run $RUN_ID"
        runner_run_batch "$(runner_batch_file "$bno")" "$bno"
        rc=$?
        started=$((started + 1))
        RUNNER_BATCHES_DONE=$((RUNNER_BATCHES_DONE + 1))
        [ "$rc" != 0 ] && return "$rc"
    done
    log "[RUN] Plan finished: $(runner_run_venue_count) venues in run $RUN_ID"
    [ "${RUNNER_LAST_REPORT_MORE:-0}" = "1" ] && runner_report 0
    return 0
}

# --resume: saved batches first (venues without a DONE: line), then the rest of the plan.
runner_resume() {
    local bno any=0 rc last
    if [ -z "$(runner_batch_numbers)" ] && [ -f "${RUNS_DIR}/${RUN_ID}.jsonl" ]; then
        # A run started before batches were saved: rebuild them from the ledger.
        if runner_py resume_ledger python3 - "${RUNS_DIR}/${RUN_ID}.jsonl" "$RUNS_DIR" "$RUN_ID" <<'PYEOF'
import json, os, sys
ledger, runs_dir, rid = sys.argv[1:4]
groups, order = {}, []
with open(ledger) as f:
    for line in f:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get('type') == 'venue' and r.get('step') == 'registered' and r.get('venue_id'):
            v = {k: r.get(k, '') for k in ('venue_id', 'website', 'city', 'state')}
            v['name'] = r.get('venue_name', '')
            b = int(r.get('batch') or 0)
            groups.setdefault(b, []).append(v)
            if b not in order:
                order.append(b)
chunks = []
for b in order:
    vs = groups[b]
    chunks += [vs[i:i + 8] for i in range(0, len(vs), 8)]
if not chunks:
    sys.exit(1)
for i, c in enumerate(chunks, 1):
    with open(os.path.join(runs_dir, f'{rid}.batch{i}.json'), 'w') as f:
        json.dump(c, f, indent=2)
PYEOF
        then
            log "[RESUME] Rebuilt this run's batches from the ledger"
        fi
    fi
    last=$(runner_batch_numbers | tail -1)
    for bno in $(runner_batch_numbers); do
        if [ -f "${RUNS_DIR}/${RUN_ID}.batch${bno}.done" ] && runner_load_batch "$(runner_batch_file "$bno")" \
           && [ -z "$(runner_unfinished_ids)" ]; then
            log "[RESUME] Batch $bno already finished (marker present, every venue has a result)"
            continue
        fi
        any=1
        log "[RESUME] Finishing batch $bno"
        RUNNER_MORE_AFTER=0
        { [ "$bno" != "$last" ] || [ -f "${RUNS_DIR}/${RUN_ID}.plan" ]; } && RUNNER_MORE_AFTER=1
        runner_run_batch "$(runner_batch_file "$bno")" "$bno"
        rc=$?
        RUNNER_BATCHES_DONE=$((RUNNER_BATCHES_DONE + 1))
        [ "$rc" != 0 ] && return "$rc"
    done
    [ "$any" = 0 ] && log "[RESUME] Every saved batch of $RUN_ID is finished"
    if [ -f "${RUNS_DIR}/${RUN_ID}.plan" ]; then
        local plan
        plan=$(runner_plan_json "$(head -1 "${RUNS_DIR}/${RUN_ID}.plan")")
        if [ -z "$plan" ]; then
            log "[RESUME] WARNING: this run's plan ($(head -1 "${RUNS_DIR}/${RUN_ID}.plan")) is gone — only saved batches were resumed"
            return 0
        fi
        runner_run_plan "$plan"
        return $?
    fi
    [ "${RUNNER_LAST_REPORT_MORE:-0}" = "1" ] && runner_report 0
    return 0
}

# Send everything this process prints into the run log too, unless stdout already is it.
runner_setup_run_log() {
    RUN_LOG="${RUN_LOG:-${RUNS_DIR}/${RUN_ID}.log}"
    mkdir -p "$(dirname "$RUN_LOG")" && touch "$RUN_LOG" || { echo "ERROR: cannot write run log $RUN_LOG"; exit 1; }
    local out_ino log_ino
    exec 3>&1
    out_ino=$(stat -f %i /dev/fd/3 2>/dev/null)
    exec 3>&-
    log_ino=$(stat -f %i "$RUN_LOG" 2>/dev/null)
    if [ -z "$out_ino" ] || [ "$out_ino" != "$log_ino" ]; then
        exec > >(tee -a "$RUN_LOG") 2>&1
    fi
    export RUN_ID RUN_LOG
}

# Single-venue lookup: exact venue_id or exact normalized name, else refuse and list candidates.
runner_lookup_venue() {
    local f="/tmp/pipeline_venue_lookup.json"
    curl -sL --max-time 120 "${APPS_SCRIPT_URL}?action=venues" -o "$f" 2>/dev/null
    runner_py venue_lookup python3 - "$f" "$1" <<'PYEOF'
import json, re, sys, unicodedata
path, target = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception as e:
    print(f"ERROR\x1fcould not read the venue list from the sheet: {e}"); sys.exit(0)
def norm(s):
    s = unicodedata.normalize('NFKD', str(s or '')).encode('ascii', 'ignore').decode().lower().replace('&', ' and ').replace("'", '').replace('`', '')
    return ' '.join(re.sub(r'[^a-z0-9]+', ' ', s).split())
def clean(s):
    return ' '.join(str('' if s is None else s).replace('\x1f', ' ').split())
venues = [v.get('venue', v) for v in (data.get('venues') or [])]
t = norm(target)
hits = [v for v in venues if str(v.get('venue_id', '')).strip().lower() == target.strip().lower()]
if not hits:
    hits = [v for v in venues if norm(v.get('name')) == t]
def row(v):
    return '\x1f'.join(clean(v.get(k)) for k in ('venue_id', 'name', 'website', 'city', 'state', 'status'))
if len(hits) == 1:
    print('FOUND\x1f' + row(hits[0])); sys.exit(0)
if len(hits) > 1:
    print('AMBIGUOUS')
    for v in hits[:15]:
        print(row(v))
    sys.exit(0)
words = [w for w in t.split() if len(w) > 2 and w not in {'the', 'and', 'for'}]
cands = [v for v in venues if words and all(w in norm(v.get('name')) for w in words)]
if not cands:
    import difflib
    names = {norm(v.get('name')): v for v in venues if v.get('name')}
    cands = [names[n] for n in difflib.get_close_matches(t, list(names), n=10, cutoff=0.6)]
print('NOT_FOUND')
for v in cands[:10]:
    print(row(v))
PYEOF
}

# --linkedin-retry: re-run step 4 for venues with linkedin_pending=true (PB-18/PD-3).
runner_linkedin_retry_one() {
    step4_linkedin "$1" "$2"
    runner_save_state
}

runner_linkedin_retry() {
    local q="/tmp/pipeline_linkedin_queue.txt" c="/tmp/pipeline_linkedin_clear.txt"
    log "LINKEDIN RETRY MODE: Finding venues with linkedin_pending=true..."
    curl -sL --max-time 120 "${APPS_SCRIPT_URL}?action=dashboard" -o /tmp/pipeline_linkedin_retry.json 2>/dev/null
    if ! runner_py linkedin_queue python3 - /tmp/pipeline_linkedin_retry.json "$q" "$c" <<'PYEOF'
import json, os, sys
src, queue, clear = sys.argv[1:4]
with open(src) as f:
    data = json.load(f)
SKIP = set(filter(None, os.environ.get('SKIP_VENUES', '').split(',')))
def clean(s):
    return ' '.join(str('' if s is None else s).replace('\x1f', ' ').split())
# Venues that already have an email contact don't need LinkedIn
with_email = {c.get('venue_id') for c in data.get('contacts', []) if c.get('email') and c.get('venue_id')}
qa, ca = [], []
for v in data.get('venues', []):
    v = v.get('venue', v)
    if str(v.get('linkedin_pending', '')).lower() != 'true' or v.get('venue_id') in SKIP:
        continue
    if str(v.get('status', '')).lower() in ('contacted', 'needs_review', 'closed'):
        continue
    row = [clean(v.get('venue_id')), clean(v.get('name')), clean(v.get('website'))]
    (ca if v.get('venue_id') in with_email else qa).append('\x1f'.join(row))
with open(queue, 'w') as f:
    f.write(''.join(r + '\n' for r in qa))
with open(clear, 'w') as f:
    f.write(''.join(r + '\n' for r in ca))
print(f"{len(qa)} to retry, {len(ca)} to clear", file=sys.stderr)
PYEOF
    then
        log "[ERROR] Could not read the dashboard for linkedin_pending venues (see $ERR_LOG)"
        return 1
    fi
    local VID NAME WEB rc verdict
    while IFS=$'\x1f' read -r VID NAME WEB <&4; do
        [ -z "$VID" ] && continue
        log "  [SKIP] $NAME already has emails — clearing linkedin_pending"
        runner_update_venue "$VID" linkedin_pending false || true
    done 4< "$c"
    while IFS=$'\x1f' read -r VID NAME WEB <&4; do
        [ -z "$VID" ] || [ -z "$NAME" ] && continue
        if [ "${LINKEDIN_WALLED:-0}" = "1" ]; then
            log "  [STOP] LinkedIn wall hit — leaving the remaining venues pending"
            break
        fi
        log ""
        log "########## LINKEDIN RETRY: $NAME ($VID) ##########"
        runner_clear_venue_tmp
        runner_set_venue_globals "$NAME" "$VID" "$WEB"
        APOLLO_DOMAIN=""
        [ "$VENUE_SHARED_DOMAIN" = "false" ] && APOLLO_DOMAIN="$VENUE_DOMAIN"
        load_existing "$VID"
        runner_run_guarded $((VENUE_TIMEOUT_MIN * 60)) "LinkedIn retry $NAME ($VID)" runner_linkedin_retry_one "$NAME" "$VID"
        rc=$?
        runner_load_state
        verdict=$(cat /tmp/pipeline_li_verdict 2>/dev/null || echo unknown)
        [ "$rc" = 124 ] && verdict="timeout"
        case "$verdict" in
            found:*)
                runner_update_venue "$VID" linkedin_pending false && log "  Cleared linkedin_pending" ;;
            *)
                log "  LinkedIn verdict '$verdict' — kept linkedin_pending=true" ;;
        esac
        sleep 10
    done 4< "$q"
    log "=== LINKEDIN RETRY COMPLETE ==="
}

# =================================================================
# ENTRY POINT
# =================================================================
RUNNER_MODE="${1:-}"
RUNNER_MAX_BATCHES=""
RUNNER_BATCHES_DONE=0
RUNNER_REPORT_PATH=""
case "$RUNNER_MODE" in
    --smart-picks)
        log "ERROR: --smart-picks is disabled because it bypasses build_batch.sh validation."
        log "Run: ./build_batch.sh 8 --dry-run"
        log "Then: ./build_batch.sh 8 && ./pipeline.sh --batch /tmp/pipeline_batch.json"
        exit 2 ;;
    ""|-h|--help)
        runner_usage
        exit 2 ;;
    --report)
        # Rebuild a run's report from its saved state (after manual marks or the miss audit)
        RUN_ID="${2:-}"
        [ -z "$RUN_ID" ] && [ -f "${RUNS_DIR}/CURRENT" ] && RUN_ID=$(tr -d '[:space:]' < "${RUNS_DIR}/CURRENT")
        if ! runner_valid_run_id "$RUN_ID" || ! declare -F generate_report >/dev/null; then
            echo "[ERROR] usage: $0 --report [RUN_ID]  (no valid RUN_ID, or generate_report missing)"
            exit 1
        fi
        generate_report "" "$RUN_ID" ""
        exit $? ;;
    --batch|--run|--plan|--resume|--linkedin-retry) ;;
    -*)
        echo "ERROR: unknown option '$RUNNER_MODE'"
        runner_usage
        exit 2 ;;
esac

# Parse the mode's arguments before touching anything
RUNNER_ARG=""
RUNNER_PLAN=""
if [ "$RUNNER_MODE" != "--linkedin-retry" ] && [ "${RUNNER_MODE#--}" != "$RUNNER_MODE" ]; then
    _args=("${@:2}")
    _i=0
    while [ "$_i" -lt "${#_args[@]}" ]; do
        case "${_args[$_i]}" in
            --max-batches)
                RUNNER_MAX_BATCHES="${_args[$((_i + 1))]:-}"
                case "$RUNNER_MODE:$RUNNER_MAX_BATCHES" in
                    --batch:*|*:|*:*[!0-9]*) echo "[ERROR] --max-batches N only goes with --run/--plan/--resume"; exit 1 ;;
                esac
                _i=$((_i + 2)) ;;
            -*) echo "[ERROR] unexpected option '${_args[$_i]}'"; runner_usage; exit 1 ;;
            *)
                if [ -n "$RUNNER_ARG" ]; then echo "[ERROR] unexpected argument '${_args[$_i]}'"; runner_usage; exit 1; fi
                RUNNER_ARG="${_args[$_i]}"
                _i=$((_i + 1)) ;;
        esac
    done
fi
case "$RUNNER_MODE" in
    --batch)
        if [ -z "$RUNNER_ARG" ] || [ ! -f "$RUNNER_ARG" ]; then
            echo "[ERROR] File not found: ${RUNNER_ARG:-<none>}  (usage: $0 --batch venues.json)"
            exit 1
        fi ;;
    --run)
        case "$RUNNER_ARG" in ''|*[!0-9]*) echo "[ERROR] usage: $0 --run N [--max-batches K]"; exit 1 ;; esac
        if [ "$RUNNER_ARG" -lt 1 ] || [ "$RUNNER_ARG" -gt 80 ]; then echo "[ERROR] --run N must be 1-80"; exit 1; fi ;;
    --plan)
        RUNNER_PLAN=$(runner_plan_json "${RUNNER_ARG:-LATEST}")
        if [ -z "$RUNNER_PLAN" ]; then
            echo "[ERROR] no plan found for '${RUNNER_ARG:-LATEST}' (build one with ./build_batch.sh --total N)"
            exit 1
        fi
        # A plan belongs to one run; running it again would redo those venues
        for _p in "${RUNS_DIR}"/*.plan; do
            [ -f "$_p" ] && [ "$(head -1 "$_p")" = "$RUNNER_PLAN" ] || continue
            echo "[ERROR] plan $RUNNER_PLAN was already used by run $(basename "$_p" .plan) — continue it with: ./pipeline.sh --resume $(basename "$_p" .plan)"
            exit 1
        done ;;
esac

# --run N: build the whole run's plan first — build_batch.sh refuses while the lock is held
if [ "$RUNNER_MODE" = "--run" ] || [ "$RUNNER_MODE" = "--plan" ]; then
    if [ -z "${RUN_ID:-}" ]; then
        RUN_ID="run-$(date +%Y%m%d-%H%M)"
        if [ -e "${RUNS_DIR}/${RUN_ID}.jsonl" ] || [ -e "${RUNS_DIR}/${RUN_ID}.log" ] || [ -e "${RUNS_DIR}/${RUN_ID}.batch1.json" ]; then
            RUN_ID="${RUN_ID}-$$"
        fi
    fi
    if ! runner_valid_run_id "$RUN_ID"; then
        echo "[ERROR] invalid RUN_ID '$RUN_ID' (letters, digits, . _ - only)"
        exit 1
    fi
    if [ -f "${RUNS_DIR}/${RUN_ID}.plan" ]; then
        echo "[ERROR] run $RUN_ID already has a plan ($(head -1 "${RUNS_DIR}/${RUN_ID}.plan")) — continue it with: ./pipeline.sh --resume $RUN_ID"
        exit 1
    fi
fi
if [ "$RUNNER_MODE" = "--run" ]; then
    RUNNER_PLAN_DIR="${SCRIPT_DIR}/reports/runs/plans/plan-${RUN_ID}"
    log "[RUN] Building the run plan: ./build_batch.sh --total $RUNNER_ARG --out-dir $RUNNER_PLAN_DIR"
    (cd "$SCRIPT_DIR" && ./build_batch.sh --total "$RUNNER_ARG" --out-dir "$RUNNER_PLAN_DIR")
    _rc=$?
    if [ "$_rc" = 4 ]; then
        log "[RUN] build_batch.sh found no eligible venues — nothing to run"
        exit 0
    elif [ "$_rc" != 0 ]; then
        log "[ERROR] build_batch.sh --total $RUNNER_ARG failed (exit $_rc) — nothing was run"
        exit 1
    fi
    RUNNER_PLAN=$(runner_plan_json "$RUNNER_PLAN_DIR")
    if [ -z "$RUNNER_PLAN" ]; then
        log "[ERROR] build_batch.sh reported success but wrote no plan.json in $RUNNER_PLAN_DIR"
        exit 1
    fi
fi

runner_take_lock || exit 1
trap 'runner_on_exit' EXIT
trap 'runner_on_signal INT' INT
trap 'runner_on_signal TERM' TERM

# Run-level cleanup, now safely behind the lock (PD-16)
rm -f "$ZB_EXHAUSTED_FLAG" "$APOLLO_EXHAUSTED_FLAG" /tmp/pipeline_step1_fb.txt /tmp/pipeline_step1_ig.txt \
      /tmp/pipeline_seen_orgs /tmp/pipeline_flags.txt "$RUNNER_STATE_FILE" "/tmp/pipeline_apollo_credits_$$" \
      "/tmp/pipeline_li_walled_$$" "/tmp/pipeline_li_empty_streak_$$"
RUNNER_ICS_MARKER="/tmp/pipeline_run_started_$$"
touch "$RUNNER_ICS_MARKER"
SKIPPED_VENUES_FILE="/tmp/pipeline_skipped_venues"
rm -f "$SKIPPED_VENUES_FILE"
LINKEDIN_WALLED=0
LINKEDIN_EMPTY_STREAK=0
CHROME_JS_OK=0
mkdir -p "$RUNS_DIR"

# RUN_ID: env RUN_ID, else (batch) the CURRENT run if it registered these venues, else new
RUNNER_CURRENT=""
[ -f "${RUNS_DIR}/CURRENT" ] && RUNNER_CURRENT=$(tr -d '[:space:]' < "${RUNS_DIR}/CURRENT")
case "$RUNNER_MODE" in
    --batch)
        runner_load_batch "$RUNNER_ARG" || exit 1
        if [ "$B_COUNT" -eq 0 ]; then
            log "[BATCH] Batch file $RUNNER_ARG is empty — nothing to do"
            exit 0
        fi
        if [ "$B_COUNT" -gt "$MAX_BATCH_SIZE" ] && [ "${ALLOW_LARGE_BATCH:-0}" != "1" ]; then
            log "[BATCH] REFUSED: $B_COUNT venues in $RUNNER_ARG; the limit is $MAX_BATCH_SIZE per batch (P6). Use --run N for more venues, or set ALLOW_LARGE_BATCH=1."
            exit 2
        fi
        if [ -z "${RUN_ID:-}" ]; then
            case "$(basename "$RUNNER_ARG")" in
                *.batch[0-9]*.json)
                    RUN_ID=$(basename "$RUNNER_ARG" | sed -E 's/\.batch[0-9]+\.json$//') ;;
            esac
        fi
        if [ -z "${RUN_ID:-}" ] && [ -n "$RUNNER_CURRENT" ]; then
            for _vid in "${B_IDS[@]}"; do
                if runner_ledger_has "$_vid" "$RUNNER_CURRENT"; then RUN_ID="$RUNNER_CURRENT"; break; fi
            done
        fi ;;
    --resume)
        case "$RUNNER_ARG" in
            *.log) [ -f "$RUNNER_ARG" ] && RUN_LOG="$RUNNER_ARG" && RUN_ID="${RUN_ID:-$(basename "$RUNNER_ARG" .log)}" ;;
            ?*) RUN_ID="$RUNNER_ARG" ;;
        esac
        RUN_ID="${RUN_ID:-$RUNNER_CURRENT}"
        if [ -z "$RUN_ID" ] || { [ ! -f "${RUNS_DIR}/${RUN_ID}.jsonl" ] && [ ! -f "${RUNS_DIR}/${RUN_ID}.batch1.json" ]; }; then
            echo "[ERROR] --resume: no ledger or saved batches for run '${RUN_ID:-?}' in $RUNS_DIR"
            exit 1
        fi ;;
esac
if [ "$RUNNER_MODE" = "--batch" ]; then
    if [ -z "${RUN_ID:-}" ]; then
        RUN_ID="run-$(date +%Y%m%d-%H%M)"
        if [ -e "${RUNS_DIR}/${RUN_ID}.jsonl" ] || [ -e "${RUNS_DIR}/${RUN_ID}.log" ] || [ -e "${RUNS_DIR}/${RUN_ID}.batch1.json" ]; then
            RUN_ID="${RUN_ID}-$$"
        fi
    fi
fi
if [ -n "${RUN_ID:-}" ] && ! runner_valid_run_id "$RUN_ID"; then
    echo "[ERROR] invalid RUN_ID '$RUN_ID' (letters, digits, . _ - only)"
    exit 1
fi
case "$RUNNER_MODE" in
    --batch|--run|--plan|--resume) runner_setup_run_log ;;
esac

echo "" >> "$LOG_FILE"
log "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ==="
[ -n "${RUN_ID:-}" ] && [ "$RUNNER_MODE" != "" ] && [ "${RUNNER_MODE#-}" != "$RUNNER_MODE" ] && log "[RUN] run_id=$RUN_ID mode=${RUNNER_MODE#--} log=$RUN_LOG"

RUNNER_EXIT=0
if [ "$RUNNER_MODE" = "--linkedin-retry" ]; then
    runner_linkedin_retry || RUNNER_EXIT=1

elif [ "$RUNNER_MODE" = "--batch" ]; then
    runner_preflight || exit 1
    # Re-use the saved copy when this is a batch the run already has (resume/re-run)
    RUNNER_BNO=""
    for _n in $(runner_batch_numbers); do
        if cmp -s "$RUNNER_ARG" "$(runner_batch_file "$_n")"; then RUNNER_BNO="$_n"; break; fi
    done
    if [ -z "$RUNNER_BNO" ]; then
        RUNNER_BNO=$(runner_next_batch_no)
        cp "$RUNNER_ARG" "$(runner_batch_file "$RUNNER_BNO")" || { log "[ERROR] could not save the batch under $RUNS_DIR"; exit 1; }
    fi
    runner_run_batch "$(runner_batch_file "$RUNNER_BNO")" "$RUNNER_BNO"
    RUNNER_EXIT=$?

elif [ "$RUNNER_MODE" = "--run" ] || [ "$RUNNER_MODE" = "--plan" ]; then
    runner_preflight || exit 1
    log "[RUN] Unattended run of plan $RUNNER_PLAN in batches of <= $MAX_BATCH_SIZE${RUNNER_MAX_BATCHES:+ (at most $RUNNER_MAX_BATCHES batch(es) now)}"
    runner_run_plan "$RUNNER_PLAN"
    RUNNER_EXIT=$?

elif [ "$RUNNER_MODE" = "--resume" ]; then
    runner_preflight || exit 1
    log "[RESUME] Resuming run $RUN_ID (log $RUN_LOG)"
    runner_resume
    RUNNER_EXIT=$?

else
    SV_NAME="$1"
    SV_ID="${2:-}"; SV_WEB="${3:-}"; SV_CITY="${4:-}"
    if [ -z "$SV_ID" ]; then
        # Exact id or exact name only: a loose match could run the paid steps on the wrong venue
        log "Looking up venue ID for: $SV_NAME"
        SV_LOOKUP=$(runner_lookup_venue "$SV_NAME")
        SV_VERDICT=$(printf '%s\n' "$SV_LOOKUP" | head -1 | cut -d$'\x1f' -f1)
        case "$SV_VERDICT" in
            FOUND)
                IFS=$'\x1f' read -r _ SV_ID SV_NAME SV_WEB SV_CITY _ _ <<< "$(printf '%s\n' "$SV_LOOKUP" | head -1)"
                log "  Found: $SV_ID (website: ${SV_WEB:-none}, city: ${SV_CITY:-unknown})" ;;
            AMBIGUOUS|NOT_FOUND)
                if [ "$SV_VERDICT" = "AMBIGUOUS" ]; then
                    echo "[ERROR] '$SV_NAME' matches more than one venue. Re-run with the ID: ./pipeline.sh \"Name\" VENUE_ID"
                else
                    echo "[ERROR] Could not find venue '$SV_NAME' in the sheet (exact name or venue_id)."
                fi
                printf '%s\n' "$SV_LOOKUP" | sed 1d | while IFS=$'\x1f' read -r c_id c_name c_web c_city c_state c_status; do
                    echo "  candidate: $c_id  $c_name  (${c_city:-?}, ${c_state:-?}, $c_status)"
                done
                exit 1 ;;
            *)
                echo "[ERROR] Venue lookup failed: $(printf '%s' "$SV_LOOKUP" | cut -d$'\x1f' -f2-)"
                exit 1 ;;
        esac
    fi
    # Tee into the current run's log when this venue belongs to that run (PROC-6)
    if [ -z "${RUN_ID:-}" ] && [ -n "$RUNNER_CURRENT" ] && runner_ledger_has "$SV_ID" "$RUNNER_CURRENT"; then
        RUN_ID="$RUNNER_CURRENT"
    fi
    if [ -n "${RUN_ID:-}" ] && runner_valid_run_id "$RUN_ID"; then
        runner_setup_run_log
        echo "=== Pipeline started $(date '+%Y-%m-%d %H:%M:%S') ==="  # into the run log only
        log "[RUN] Single venue $SV_ID, logged into run $RUN_ID ($RUN_LOG)"
    fi
    runner_preflight || exit 1
    B_COUNT=1; B_WEBS=("$SV_WEB"); B_NAMES=("$SV_NAME")
    runner_chrome_probe "$(runner_probe_url)" || exit 3
    RUNNER_CUR_VID="$SV_ID"; RUNNER_CUR_NAME="$SV_NAME"
    runner_run_guarded $((VENUE_TIMEOUT_MIN * 60)) "venue $SV_NAME ($SV_ID)" run_venue "$SV_NAME" "$SV_ID" "$SV_WEB" "$SV_CITY"
    RUNNER_EXIT=$?
    [ "$RUNNER_EXIT" = 124 ] && log "[STEP] $SV_ID final failed reason=timeout minutes=$VENUE_TIMEOUT_MIN"
    RUNNER_CUR_VID=""; RUNNER_CUR_NAME=""
fi

exit "$RUNNER_EXIT"
