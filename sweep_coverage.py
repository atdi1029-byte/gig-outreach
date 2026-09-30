#!/usr/bin/env python3
"""Where every sweep find stands: will it reach a night run, and if not, why.

    sweep_coverage.py            summary + every venue that is stuck
    sweep_coverage.py --all      list every sweep venue with its state

Sweep finds = venues whose source says sweep or that carry the "Sweep find (...)" note
(outreach_rules.is_sweep_find), plus READY TO ADD rows in sweep_*.md that aren't on the
sheet at all. The reasons come from build_batch.sh itself (BB_REASONS_OUT), so this can't
drift from what the night run actually picks. Read-only.
"""
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import outreach_rules as R  # noqa: E402

API = ("https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
PARKED = re.compile(r"pipeline|0 contacts|zero contacts|closed|dead|not a venue|junk|motel|airbnb|vrbo|"
                    r"too far|out of area|quarantin|duplicate|wrong business|flag", re.I)

# build_batch reason -> the group Alex sees
GROUPS = [
    ("ready", "In the run queue", ()),
    ("last", "In the run queue after every DC/MD/VA venue (Pennsylvania / Delaware)", ()),
    ("worked", "Already worked (contacts in the app, or run with nothing found)", ()),
    ("website", "Waiting for its own website (the night run looks these up in Chrome)",
     ("no website", "junk website", "bare brand homepage as website", "website not verified as the venue's own")),
    ("verify", "Waiting for the pool check (verify_pool.py, every night)", ()),
    ("rules", "Left out by your rules", ("out of area (not DC/MD/VA)", "too far", "past gig",
                                          "thumbs-down vote", "junk gate", "blank/malformed city")),
    ("dupe", "Duplicate of a venue or site already on the list",
     ("duplicate site (kept the best row)", "site already pipelined/contacted",
      "same name as a venue already worked", "already in a report", "has contacts")),
    ("closed", "Closed", ()),
    ("missing", "In a sweep write-up but not on the sheet (the night run adds these)", ()),
    ("other", "Other", ()),
]


def api(params, timeout=180):
    url = API + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def main(argv):
    show_all = "--all" in argv
    fd, out = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    env = dict(os.environ, BB_REASONS_OUT=out, BB_SITE_CHECK="0")
    subprocess.run([str(HERE / "build_batch.sh"), "--total", "50", "--dry-run"], cwd=HERE, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
    bb = json.load(open(out))
    os.unlink(out)
    reasons, pool, last = bb["reasons"], set(bb["pool"]), set(bb.get("last") or [])
    venues = api({"action": "venues"}).get("venues") or []
    sweep = [v for v in venues if R.is_sweep_find(v)]

    groups = collections.defaultdict(list)
    for v in sweep:
        vid, st = v["venue_id"], v.get("status")
        why = reasons.get(vid, "")
        if vid in last:
            g = "last"
        elif vid in pool:
            g = "ready"
        elif st in ("pipelined", "contacted", "sent"):
            g = "worked"
        elif st in ("closed", "dismissed"):
            g = "closed"
        elif st == "needs_review":
            notes = f"{v.get('check_status') or ''} {v.get('notes') or ''}"
            if re.search(r"pipeline", notes, re.I):
                g, why = "worked", "run before, no usable contact found"
            elif re.search(r"closed", notes, re.I):
                g = "closed"
            elif not (v.get("website") or "").strip():
                g, why = "website", "no website"
            elif PARKED.search(notes):
                g, why = "other", "parked: " + PARKED.search(notes).group(0)
            elif not R.sweep_state_ok(v.get("state"), True):
                g, why = "rules", "out of area (not DC/MD/VA/PA/DE)"
            else:
                g = "verify"
        else:
            g = next((key for key, _, rs in GROUPS if why in rs), "other")
        groups[g].append((v, why))

    # READY TO ADD rows that never reached the sheet
    try:
        prev = subprocess.run([sys.executable, str(HERE / "import_sweep_files.py")], cwd=HERE,
                              capture_output=True, text=True, timeout=900).stdout
        for line in prev.splitlines():
            if line.startswith("ADD "):
                groups["missing"].append(({"name": line[9:53].strip(), "venue_id": "-", "city": "",
                                           "state": ""}, line[53:].strip()))
    except Exception as exc:  # the audit still reports the sheet side
        print(f"(could not read the sweep write-ups: {exc})")

    total = sum(len(x) for x in groups.values())
    print(f"Sweep finds: {total}")
    for key, label, _ in GROUPS:
        if groups.get(key):
            print(f"  {len(groups[key]):5d}  {label}")
    stuck = [k for k in ("website", "verify", "missing", "other")]
    for key, label, _ in GROUPS:
        if not groups.get(key) or (key not in stuck and not show_all):
            continue
        print(f"\n== {label}")
        sub = collections.Counter(w for _, w in groups[key])
        if len(sub) > 1:
            print("   " + ", ".join(f"{w or '?'} {n}" for w, n in sub.most_common()))
        for v, why in sorted(groups[key], key=lambda x: (x[0].get("state") or "", x[0].get("name") or "")):
            print(f"   {v.get('venue_id', '-'):<14} {str(v.get('name'))[:44]:<44} "
                  f"{v.get('city') or ''} {v.get('state') or ''}  {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
