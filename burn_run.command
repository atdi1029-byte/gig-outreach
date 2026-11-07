#!/bin/bash
# The 24/7 outreach burn (Alex, Nov 6 2026): rounds of 25 until ZeroBounce or Apollo runs out.
# Opened in Terminal (open burn_run.command) so Chrome automation runs with Terminal's
# permission. The burn runs detached (nohup): closing this window doesn't stop it (the first
# start, Nov 6 23:08, died of SIGHUP when its window closed). This window only shows the log.
# Pause: touch .burn_pause / resume: rm .burn_pause. Log: reports/runs/burn-*.log
cd "$(dirname "$0")" || exit 1
nohup ./night_run.sh --burn > /dev/null 2>&1 &
disown
echo "Outreach 24/7 started (PID $!). Closing this window does NOT stop it; pause with: touch .burn_pause"
sleep 5
tail -n 20 -F "$(ls -t reports/runs/burn-*.log | head -1)"
