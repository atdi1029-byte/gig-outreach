#!/bin/bash
# The 24/7 outreach burn (Alex, Nov 6 2026): rounds of 25 until ZeroBounce or Apollo runs out.
# Opened in Terminal (open burn_run.command) so Chrome automation runs with Terminal's
# permission. Pause: touch .burn_pause / resume: rm .burn_pause. Log: reports/runs/burn-*.log
cd "$(dirname "$0")" || exit 1
./night_run.sh --burn
echo "Burn finished $(date '+%H:%M'). This window can be closed."
