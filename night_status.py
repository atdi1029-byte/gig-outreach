#!/usr/bin/env python3
"""night_status.json: what the app shows about the night runs (Alex, Sep 29 2026).

night_run.sh writes it and pushes it; the app reads it from GitHub Pages and shows
the alert as a banner on the home screen, plus one line about last night.

    night_status.py start                       a new night begins (keeps any alert)
    night_status.py alert KIND LEVEL TITLE [DETAIL]
                                                KIND: zerobounce apollo chrome pool asleep error
                                                LEVEL: stop (red, needs Alex) | warn (amber, FYI)
    night_status.py clear-alert [KIND ...]      clear the alert (only if it is one of KINDs)
    night_status.py run RUN_ID key=value ...    add/update one run of this night
                                                (ints stay ints: venues=50 zero=12 ...)
    night_status.py note TEXT                   one plain line for the app (replaces the last)
    night_status.py finish STATE                done | stopped | skipped; files the night in history
    night_status.py show
"""
import fcntl
import json
import os
import sys
import tempfile
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.environ.get("NIGHT_STATUS_FILE") or os.path.join(HERE, "night_status.json")
HISTORY_MAX = 21
KINDS = {"zerobounce", "apollo", "chrome", "pool", "asleep", "error"}


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def load():
    try:
        with open(PATH) as f:
            d = json.load(f)
        if isinstance(d, dict):
            return d
    except (OSError, ValueError):
        pass
    return {"alert": None, "night": None, "history": []}


def save(d):
    d["updated_at"] = now()
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH), prefix=".night_status.")
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=1)
        f.write("\n")
    os.replace(tmp, PATH)


def parse_value(v):
    if v.lstrip("-").isdigit():
        return int(v)
    return v


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] != "show":
        # night_run.sh updates it from the main loop and the background deep dive at once
        lock = open(PATH + ".lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    cmd, args = argv[0], argv[1:]
    d = load()
    d.setdefault("history", [])
    if cmd == "start":
        d["night"] = {"date": datetime.now().strftime("%Y-%m-%d"), "started_at": now(),
                      "finished_at": None, "state": "running", "runs": [], "note": ""}
    elif cmd == "alert":
        if len(args) < 3 or args[0] not in KINDS or args[1] not in ("stop", "warn"):
            print("usage: alert KIND stop|warn TITLE [DETAIL]", file=sys.stderr)
            return 2
        old = d.get("alert") or {}
        since = old.get("since") if old.get("kind") == args[0] else None
        d["alert"] = {"kind": args[0], "level": args[1], "title": args[2],
                      "detail": args[3] if len(args) > 3 else "", "since": since or now()}
    elif cmd == "clear-alert":
        a = d.get("alert")
        if a and (not args or a.get("kind") in args):
            d["alert"] = None
    elif cmd == "run":
        if not args:
            print("usage: run RUN_ID key=value ...", file=sys.stderr)
            return 2
        night = d.get("night") or {}
        runs = night.setdefault("runs", [])
        rec = next((r for r in runs if r.get("run_id") == args[0]), None)
        if rec is None:
            rec = {"run_id": args[0]}
            runs.append(rec)
        for kv in args[1:]:
            if "=" in kv:
                k, v = kv.split("=", 1)
                rec[k] = parse_value(v)
        d["night"] = night
    elif cmd == "note":
        night = d.get("night") or {}
        night["note"] = " ".join(args)
        d["night"] = night
    elif cmd == "finish":
        night = d.get("night") or {}
        night["state"] = args[0] if args else "done"
        night["finished_at"] = now()
        d["night"] = night
        hist = [h for h in d["history"] if h.get("started_at") != night.get("started_at")]
        d["history"] = ([dict(night)] + hist)[:HISTORY_MAX]
    elif cmd == "show":
        print(json.dumps(d, indent=1))
        return 0
    else:
        print(__doc__)
        return 2
    save(d)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
