#!/usr/bin/env bash
# run.sh — orchestrate a pipeline run
#
# Usage:
#   ./run.sh start [count]    Build batch, create ledger, launch pipeline in background
#   ./run.sh status           Show pipeline progress (tail log)
#   ./run.sh wait             Block until pipeline finishes (or dies)
#   ./run.sh finish           Parse log, run postcheck, print what's still owed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$SCRIPT_DIR/reports/runs"
mkdir -p "$RUNS_DIR"

current_run() {
  if [[ -f "$RUNS_DIR/.current" ]]; then
    cat "$RUNS_DIR/.current"
  else
    echo ""; return 1
  fi
}

current_log() {
  local rid
  rid=$(current_run) || { echo "ERROR: no current run" >&2; return 1; }
  echo "$RUNS_DIR/$rid.log"
}

pipeline_pid() {
  pgrep -f 'pipeline.sh --batch' 2>/dev/null || true
}

cmd_start() {
  local count="${1:-8}"

  # Refuse if pipeline already running
  local pid
  pid=$(pipeline_pid)
  if [[ -n "$pid" ]]; then
    echo "ERROR: pipeline.sh already running (PID $pid). Use ./run.sh status or wait." >&2
    exit 1
  fi

  # Build batch
  echo "Building batch of $count..."
  "$SCRIPT_DIR/build_batch.sh" "$count"
  if [[ ! -f /tmp/pipeline_batch.json ]]; then
    echo "ERROR: build_batch.sh did not produce /tmp/pipeline_batch.json" >&2
    exit 1
  fi

  # Check batch isn't empty
  local venue_count
  venue_count=$(python3 -c "import json; print(len(json.load(open('/tmp/pipeline_batch.json'))))" 2>/dev/null || echo 0)
  if [[ "$venue_count" -eq 0 ]]; then
    echo "ERROR: batch is empty" >&2
    exit 1
  fi

  # Create ledger
  local run_id="run-$(date +%Y%m%d-%H%M)"
  python3 "$SCRIPT_DIR/run_ledger.py" init "$run_id" /tmp/pipeline_batch.json
  echo "$run_id" > "$RUNS_DIR/.current"

  # Launch pipeline in background
  local log="$RUNS_DIR/$run_id.log"
  echo "Launching pipeline ($venue_count venues) in background..."
  nohup caffeinate -i "$SCRIPT_DIR/pipeline.sh" --batch /tmp/pipeline_batch.json > "$log" 2>&1 &
  local bg_pid=$!
  echo "$bg_pid" > "$RUNS_DIR/.pid"

  echo ""
  echo "Run:      $run_id"
  echo "PID:      $bg_pid"
  echo "Log:      $log"
  echo "Venues:   $venue_count"
  echo ""
  echo "Poll with:  ./run.sh status"
  echo "Block with: ./run.sh wait"
}

cmd_status() {
  local log
  log=$(current_log) || exit 1
  local rid
  rid=$(current_run)

  echo "Run: $rid"

  local pid
  pid=$(pipeline_pid)
  if [[ -n "$pid" ]]; then
    echo "Status: RUNNING (PID $pid)"
  else
    if grep -q '=== BATCH COMPLETE ===' "$log" 2>/dev/null; then
      echo "Status: COMPLETE"
    else
      echo "Status: STOPPED (no BATCH COMPLETE marker — may have died)"
    fi
  fi

  echo ""
  echo "--- Last 10 lines ---"
  tail -10 "$log" 2>/dev/null || echo "(no log yet)"
}

cmd_wait() {
  local log
  log=$(current_log) || exit 1
  local rid
  rid=$(current_run)

  echo "Waiting for run $rid to finish..."

  # Wait for PID if we have one
  if [[ -f "$RUNS_DIR/.pid" ]]; then
    local pid
    pid=$(cat "$RUNS_DIR/.pid")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Tailing log (PID $pid)... Ctrl-C to stop watching (pipeline continues)."
      tail -f "$log" --pid="$pid" 2>/dev/null || wait "$pid" 2>/dev/null
    fi
  fi

  # Check outcome
  if grep -q '=== BATCH COMPLETE ===' "$log" 2>/dev/null; then
    echo ""
    echo "Pipeline finished successfully."
  else
    echo ""
    echo "WARNING: pipeline exited WITHOUT a BATCH COMPLETE marker."
    echo "Check the log for errors: $log"
  fi
}

cmd_finish() {
  local rid
  rid=$(current_run) || exit 1
  local log="$RUNS_DIR/$rid.log"

  # Don't finish if still running
  local pid
  pid=$(pipeline_pid)
  if [[ -n "$pid" ]]; then
    echo "ERROR: pipeline still running (PID $pid). Use ./run.sh wait first." >&2
    exit 1
  fi

  echo "=== Finishing run $rid ==="
  echo ""

  # 1. Parse automated steps from log
  if [[ -f "$log" ]]; then
    python3 "$SCRIPT_DIR/run_ledger.py" from-log "$rid" "$log"
  else
    echo "WARNING: no log at $log"
  fi

  # 2. Mark pipeline_complete if log shows it
  if grep -q '=== BATCH COMPLETE ===' "$log" 2>/dev/null; then
    python3 "$SCRIPT_DIR/run_ledger.py" run "$rid" pipeline_complete --evidence "BATCH COMPLETE in log"
  fi

  # 3. Run postcheck
  echo ""
  echo "Running postcheck..."
  "$SCRIPT_DIR/postcheck.sh" 2>&1 | tee -a "$RUNS_DIR/${rid}_postcheck.log"
  python3 "$SCRIPT_DIR/run_ledger.py" run "$rid" postcheck --evidence "ran postcheck.sh"

  # 4. Show what's still owed
  echo ""
  python3 "$SCRIPT_DIR/run_ledger.py" show "$rid"
  echo ""
  python3 "$SCRIPT_DIR/run_ledger.py" verify "$rid"
}

# Dispatch
case "${1:-}" in
  start)  cmd_start "${2:-8}" ;;
  status) cmd_status ;;
  wait)   cmd_wait ;;
  finish) cmd_finish ;;
  *)
    echo "Usage: ./run.sh {start [N]|status|wait|finish}"
    exit 1
    ;;
esac
