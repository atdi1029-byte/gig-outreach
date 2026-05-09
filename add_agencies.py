#!/usr/bin/env python3
"""Add agencies from agent_discovery.json to the outreach sheet as category=agent."""
import json
import urllib.parse
import urllib.request
import sys
import time

APPS_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"

with open("/Users/alexbarnett/Documents/Code/Claude/Email/agent_discovery.json") as f:
    agencies = json.load(f)

print(f"Adding {len(agencies)} agencies as category=agent...")
batch = []
failed = []

for i, a in enumerate(agencies, 1):
    params = {
        "action": "add_venue",
        "name": a["name"],
        "category": "agent",
        "website": a.get("website", ""),
        "city": a.get("city", ""),
        "state": a.get("state", ""),
        "source": "agent_discovery",
        "notes": a.get("description", ""),
    }
    url = APPS_SCRIPT_URL + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        if data.get("status") == "ok":
            vid = data.get("venue_id", "")
            msg = data.get("message", "added")
            print(f"  [{i}/{len(agencies)}] {a['name']:<40} -> {vid} ({msg})")
            batch.append({
                "name": a["name"],
                "venue_id": vid,
                "website": a.get("website", ""),
                "city": a.get("city", ""),
            })
        else:
            print(f"  [{i}/{len(agencies)}] {a['name']:<40} FAILED: {data}")
            failed.append(a["name"])
    except Exception as e:
        print(f"  [{i}/{len(agencies)}] {a['name']:<40} ERROR: {e}")
        failed.append(a["name"])
    time.sleep(0.3)

# Write batch file for pipeline.sh --batch
with open("/Users/alexbarnett/Documents/Code/Claude/Email/agency_batch.json", "w") as f:
    json.dump(batch, f, indent=2)

print()
print(f"SUCCESS: {len(batch)}/{len(agencies)} added")
if failed:
    print(f"FAILED: {failed}")
print(f"Batch file written: agency_batch.json ({len(batch)} venues)")
