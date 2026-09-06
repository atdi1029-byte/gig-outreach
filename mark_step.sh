#!/usr/bin/env bash
# mark_step.sh — thin wrapper around run_ledger.py
#
# Usage:
#   ./mark_step.sh RUN_ID VENUE_ID step [--status done|skip|blocked] [--evidence "..."]
#   ./mark_step.sh RUN_ID RUN step [--status done|skip|blocked] [--evidence "..."]
#   ./mark_step.sh --batch /tmp/pipeline_batch.json   (creates new run)
#
# Examples:
#   ./mark_step.sh run-20260906-1430 VA-REST-123 contact_pages --evidence "homepage+/contact: events@…"
#   ./mark_step.sh run-20260906-1430 VA-REST-123 fb_checked --status skip --evidence "no page"
#   ./mark_step.sh run-20260906-1430 RUN taste_review --evidence "3 new votes"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --batch mode: create a new run
if [[ "${1:-}" == "--batch" ]]; then
  BATCH_FILE="${2:?Usage: mark_step.sh --batch <batch.json>}"
  RUN_ID="run-$(date +%Y%m%d-%H%M)"
  python3 "$SCRIPT_DIR/run_ledger.py" init "$RUN_ID" "$BATCH_FILE"
  echo "$RUN_ID" > "$SCRIPT_DIR/reports/runs/.current"
  echo "Current run: $RUN_ID"
  exit 0
fi

RUN_ID="${1:?Usage: mark_step.sh <run_id> <venue_id|RUN> <step> [--status X] [--evidence \"...\"]}"
ENTITY="${2:?}"
STEP="${3:?}"
shift 3

if [[ "$ENTITY" == "RUN" ]]; then
  python3 "$SCRIPT_DIR/run_ledger.py" run "$RUN_ID" "$STEP" "$@"
else
  python3 "$SCRIPT_DIR/run_ledger.py" mark "$RUN_ID" "$ENTITY" "$STEP" "$@"
fi
