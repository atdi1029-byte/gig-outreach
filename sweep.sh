#!/bin/bash
# =============================================================
# sweep.sh — CHROME-based Google Maps discovery for specific cities
#
# This is NOT the city "sweep" procedure. A sweep is venue research Claude does
# with WebSearch / WebFetch / curl in the terminal and never touches Chrome
# (Alex, Sep 22 2026). This script drives Chrome through `discover.sh --taste`.
# Only run it when Alex explicitly asks for Chrome / Google Maps discovery.
#
# Usage:
#   ./sweep.sh --chrome "Annapolis MD"
#   ./sweep.sh --chrome "Annapolis MD" "Severna Park MD"
#
# Runs every venue-type query for exactly the given cities (DC/MD/VA only),
# skipping queries already recorded in taste_queries.txt. New venues land as
# needs_review. Exits non-zero when nothing could be run or Chrome failed
# (exit codes are discover.sh's: 1 setup error, 3 Chrome unreachable,
# 4 some queries failed and will be retried, 5 pipeline.sh is running).
#
# Requirements:
#   - Chrome open
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cat >&2 <<'MSG'
************************************************************************
 WARNING: sweep.sh is CHROME-based Google Maps discovery (discover.sh --taste).
 It is NOT the city sweep procedure. A sweep is WebSearch/WebFetch research
 in the terminal, with no Chrome at any step.
************************************************************************
MSG

if [ "${1:-}" = "--chrome" ]; then
    shift
elif [ "${SWEEP_ALLOW_CHROME:-0}" != "1" ]; then
    echo "Refusing to drive Chrome without an explicit --chrome flag." >&2
    echo "Usage: ./sweep.sh --chrome \"City ST\" [\"City2 ST2\" ...]" >&2
    exit 2
fi

# pipeline.sh owns Chrome while /tmp/pipeline.lock.d/pid is a live pipeline.sh (PD-16);
# discover.sh re-checks this, but say so before anything else happens.
_lock_pid=$(cat "${PIPELINE_LOCK_DIR:-/tmp/pipeline.lock.d}/pid" 2>/dev/null || cat "${PIPELINE_LOCK_FILE:-/tmp/pipeline.lock}" 2>/dev/null)
case "$_lock_pid" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$_lock_pid" != "${PIPELINE_LOCK_PID:-}" ] && kill -0 "$_lock_pid" 2>/dev/null \
                && ps -p "$_lock_pid" -o command= 2>/dev/null | grep -q 'pipeline\.sh'; then
            echo "ERROR: pipeline.sh is running (PID $_lock_pid) and is driving Chrome. Run sweep.sh after it finishes." >&2
            exit 5
        fi
        ;;
esac

if [ $# -eq 0 ]; then
    echo "Usage: ./sweep.sh --chrome \"City ST\" [\"City2 ST2\" ...]" >&2
    echo "Example: ./sweep.sh --chrome \"Annapolis MD\"" >&2
    exit 1
fi

# One "City ST" per line; discover.sh builds every venue-type query for each and
# refuses cities outside the target states.
CITIES=$(printf '%s\n' "$@")

echo "[sweep] Cities: $*"
echo "[sweep] Running Chrome discovery for these cities — no query limit"
echo ""

SWEEP_CITIES="$CITIES" MAX_QUERIES="${MAX_QUERIES:-999}" "$SCRIPT_DIR/discover.sh" --taste
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[sweep] discover.sh exited $rc — see discover.log" >&2
fi
exit "$rc"
