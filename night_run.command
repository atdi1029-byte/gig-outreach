#!/bin/bash
# Opened in Terminal at 1:00 by launchd (~/Library/LaunchAgents/com.alexbarnett.outreach-night.plist)
# so the night run automates Chrome with Terminal's permission. Log: reports/runs/night-YYYYMMDD.log
cd "$(dirname "$0")" || exit 1
./night_run.sh
echo "Night run finished $(date '+%H:%M'). This window can be closed."
