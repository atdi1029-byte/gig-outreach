#!/bin/bash
# =============================================================
# City Sweep — Full venue discovery for a specific city
#
# Usage:
#   ./sweep.sh "Annapolis MD"
#   ./sweep.sh "Annapolis MD" "Severna Park MD"
#
# Runs ALL venue type queries for the given city/cities.
# No MAX_QUERIES cap — exhausts every type.
#
# Requirements:
#   - Chrome open
#   - Chrome: View → Developer → Allow JavaScript from Apple Events
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
    echo "Usage: ./sweep.sh \"City State\" [\"City2 State2\" ...]"
    echo "Example: ./sweep.sh \"Annapolis MD\""
    exit 1
fi

# Build CITY_FILTER regex from all arguments
FILTER=""
for arg in "$@"; do
    if [ -n "$FILTER" ]; then
        FILTER="${FILTER}|${arg}"
    else
        FILTER="${arg}"
    fi
done

echo "[sweep] Cities: $*"
echo "[sweep] Filter: $FILTER"
echo "[sweep] Running full discovery — no query limit"
echo ""

CITY_FILTER="$FILTER" MAX_QUERIES=999 "$SCRIPT_DIR/discover.sh" --taste
