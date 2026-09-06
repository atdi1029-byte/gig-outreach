#!/usr/bin/env bash
# verify_run.sh — gate script, wraps run_ledger.py verify
#
# Usage:
#   ./verify_run.sh [run_id]        (default: current run)
#
# Also runs from-log to pick up automated steps before verifying.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$SCRIPT_DIR/reports/runs"

# Resolve run ID
if [[ -n "${1:-}" ]]; then
  RUN_ID="$1"
elif [[ -f "$RUNS_DIR/.current" ]]; then
  RUN_ID=$(cat "$RUNS_DIR/.current")
else
  echo "ERROR: no run_id given and no .current run" >&2; exit 1
fi

# Parse automated steps from pipeline log if it exists
LOG="$RUNS_DIR/$RUN_ID.log"
if [[ -f "$LOG" ]]; then
  python3 "$SCRIPT_DIR/run_ledger.py" from-log "$RUN_ID" "$LOG"
  echo ""
fi

# Show the matrix then verify
python3 "$SCRIPT_DIR/run_ledger.py" show "$RUN_ID"
echo ""
python3 "$SCRIPT_DIR/run_ledger.py" verify "$RUN_ID"
