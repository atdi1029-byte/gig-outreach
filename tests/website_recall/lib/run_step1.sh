#!/bin/bash
# Run ONE venue through pipeline.sh's website step (step1_website) inside the harness sandbox.
#
# usage: run_step1.sh PIPELINE_SH SUPPORT_DIR OUTDIR STORE_DIR MODE VENUE_ID NAME WEBSITE CITY
#   MODE  chrome = headless Chrome answers the osascript calls (the scrape JS really runs)
#         curl   = Chrome JS unavailable (osascript execute fails) -> the curl fallbacks run
# Env: UW_NET=replay|record|live (default replay), UW_NODE, UW_KEEP_CHROME=1.
#
# Everything with side effects is stubbed: osascript/curl are replaced on PATH (lib/bin),
# python `requests` is routed through the replay store (lib/py/sitecustomize.py), the Apps
# Script URL is fake, and verify_and_push/record_candidate/log only write to OUTDIR.
set -u
PIPE="$1"; SUPPORT="$2"; OUT="$3"; STORE_DIR="$4"; MODE="$5"; VID="$6"; VNAME="$7"; VWEB="$8"; VCITY="${9:-}"
LIB="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/work"; SD="$OUT/scriptdir"
rm -rf "$WORK" "$SD"; mkdir -p "$WORK" "$SD/reports/runs" "$SD/reports/web-coverage" "$OUT/coverage"
: > "$OUT/step1.log"; : > "$OUT/vp.tsv"; : > "$OUT/cand.tsv"; : > "$OUT/api.jsonl"; : > "$OUT/trace.jsonl"

# SCRIPT_DIR stand-in: the support files (site_discovery.py, outreach_rules.py, env_check.sh,
# js/ ...) from SUPPORT_DIR, but never .env (keys, real Apps Script URL) or the real reports/.
for f in "$SUPPORT"/* ; do
    b="$(basename "$f")"
    case "$b" in reports|tests|pipeline.log|postcheck.log|discover.log|node_modules) continue ;; esac
    ln -s "$f" "$SD/$b" 2>/dev/null
done
rm -f "$SD/pipeline.sh"; ln -s "$PIPE" "$SD/pipeline.sh"

if ! /usr/bin/python3 "$LIB/extract_pipeline.py" "$PIPE" "$WORK" "$OUT/defs.sh" "$OUT/header.sh" > "$OUT/functions.txt" 2> "$OUT/extract.err"; then
    echo "EXTRACT_FAILED" > "$OUT/status"; exit 3
fi
grep -qw step1_website "$OUT/functions.txt" || { echo "NO_STEP1" > "$OUT/status"; exit 3; }

export UW_STORE="$STORE_DIR" UW_NET="${UW_NET:-replay}" UW_TRACE="$OUT/trace.jsonl" UW_API_LOG="$OUT/api.jsonl"
export UW_CHROME_STATE="$OUT/chrome" UW_HOSTLOCK_DIR="${UW_HOSTLOCK_DIR:-/tmp/uw_hostlock}"
export UW_CHROME=on; [ "$MODE" = "curl" ] && export UW_CHROME=off
export PATH="$LIB/bin:$PATH"
export PYTHONPATH="$LIB/py${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONWARNINGS="ignore"
export SITE_DISCOVERY_DELAY="${SITE_DISCOVERY_DELAY:-0}"   # politeness is enforced by the store (1 req/s/host when live)
export APPS_SCRIPT_URL="https://apps-script.invalid/exec"
export UW_VENUE_JSON="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"venue_id":sys.argv[1],"name":sys.argv[2],"website":sys.argv[3],"city":sys.argv[4],"status":"untouched"}))' "$VID" "$VNAME" "$VWEB" "$VCITY")"

if [ "$UW_CHROME" = "on" ]; then
    "${UW_NODE:-node}" "$LIB/chromectl.mjs" launch > /dev/null 2>> "$OUT/stderr.log" || { echo "CHROME_LAUNCH_FAILED" > "$OUT/status"; exit 4; }
fi

(
    cd "$SD"
    [ -f "$SD/env_check.sh" ] && . "$SD/env_check.sh"
    export PATH="$LIB/bin:$PATH"   # keep the stubs ahead of env_check's python shim
    . "$OUT/header.sh" 2>/dev/null
    . "$OUT/defs.sh"
    SCRIPT_DIR="$SD"; SCRIPT_DIR_EARLY="$SD"
    LOG_FILE="$OUT/pipeline.log"; CANDIDATE_LOG="$OUT/candidates.jsonl"; COVERAGE_DIR="$OUT/coverage"
    ERR_LOG="$OUT/python-errors.log"; APPS_SCRIPT_URL="https://apps-script.invalid/exec"
    # Exported and disabled, so no subprocess (guard, python block) can reach ZeroBounce or
    # Apollo even if a stub is bypassed. The guard refuses with ZB_ENABLED=false.
    export ZEROBOUNCE_KEY="benchmark-no-key" APOLLO_API_KEY="benchmark-no-key" ZB_ENABLED=false ZB_FAIL_CLOSED=true
    log() { printf '%s\n' "$*" >> "$OUT/step1.log"; }
    sleep() { :; }
    rand_delay() { :; }
    verify_and_push() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" >> "$OUT/vp.tsv"; }
    record_candidate() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" >> "$OUT/cand.tsv"; }
    # C1 per-venue globals (normally set by run_venue).
    VENUE_NAME="$VNAME"; VENUE_ID="$VID"; VENUE_WEBSITE="$VWEB"; APOLLO_DOMAIN=""
    _dom_json="$(python3 "$SD/outreach_rules.py" domain "$VWEB" 2>/dev/null)"
    VENUE_DOMAIN="$(printf '%s' "$_dom_json" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print("" if d.get("non_venue") else d.get("registrable",""))
except Exception: print("")' 2>/dev/null)"
    VENUE_SHARED_DOMAIN="$(printf '%s' "$_dom_json" | python3 -c 'import json,sys
try: print("true" if json.load(sys.stdin).get("shared") else "false")
except Exception: print("false")' 2>/dev/null)"
    VENUE_SITE_PREFIX="$(python3 -c 'import sys
from urllib.parse import urlsplit
u=urlsplit(sys.argv[1] if "://" in sys.argv[1] else "https://"+sys.argv[1]); h=u.netloc.lower()
h=h[4:] if h.startswith("www.") else h
print(h + (u.path.rstrip("/") if sys.argv[2]=="true" else ""))' "$VWEB" "$VENUE_SHARED_DOMAIN" 2>/dev/null)"
    KNOWN_EMAILS=""; KNOWN_NAMES=""; ZB_VENUE_CREDITS=0
    # load_existing isn't run here: stand in for an empty, readable sheet row, or the
    # pipeline refuses to save socials/contact forms ("sheet's current value is unknown").
    LOAD_EXISTING_OK="yes"; VENUE_EXISTING_FB=""; VENUE_EXISTING_IG=""; VENUE_EXISTING_FORM=""
    export VENUE_NAME VENUE_ID VENUE_WEBSITE VENUE_DOMAIN VENUE_SHARED_DOMAIN VENUE_SITE_PREFIX APOLLO_DOMAIN ERR_LOG
    rm -f "$WORK"/pipeline_* 2>/dev/null
    step1_website "$VNAME" "$VID" "$VWEB" "$VCITY"
) > "$OUT/stdout.log" 2> "$OUT/stderr.log"
rc=$?
if [ "$UW_CHROME" = "on" ] && [ "${UW_KEEP_CHROME:-0}" != "1" ]; then
    "${UW_NODE:-node}" "$LIB/chromectl.mjs" kill > /dev/null 2>&1
fi
echo "rc=$rc" > "$OUT/status"
exit 0
