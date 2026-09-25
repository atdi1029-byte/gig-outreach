#!/usr/bin/python3
"""Replay-store health: per venue, response status counts by client kind, so a site that
started blocking us mid-capture (403/429 after earlier 200s) is visible.
usage: store_health.py [SNAPSHOTS_DIR] [--venues IDS] [--merge-from OTHER_STORE_ROOT]
--drop-errors deletes 0/403/429/503 entries so the next `run_recall.sh --net record` refetches them.
--merge-from copies entries from another store root when ours is missing or is an error (>=400/0)
and theirs is a 200 (used to repair a capture spoiled by a temporary block)."""
import collections, glob, json, os, shutil, sys
root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "snapshots")
venues = None
merge = None
drop = "--drop-errors" in sys.argv
for i, a in enumerate(sys.argv):
    if a == "--venues":
        venues = set(sys.argv[i + 1].split(","))
    if a == "--merge-from":
        merge = sys.argv[i + 1]
for vd in sorted(glob.glob(os.path.join(root, "*"))):
    vid = os.path.basename(vd)
    if venues and vid not in venues:
        continue
    if merge and os.path.isdir(os.path.join(merge, vid, "entries")):
        n = 0
        for mp in glob.glob(os.path.join(merge, vid, "entries", "*.json")):
            src = json.load(open(mp))
            dst_p = os.path.join(vd, "entries", os.path.basename(mp))
            dst = json.load(open(dst_p)) if os.path.exists(dst_p) else None
            if src.get("status") == 200 and (dst is None or not (200 <= int(dst.get("status") or 0) < 400)):
                if src.get("body"):
                    os.makedirs(os.path.join(vd, "bodies"), exist_ok=True)
                    b = os.path.join(vd, src["body"])
                    if not os.path.exists(b):
                        shutil.copy(os.path.join(merge, vid, src["body"]), b)
                json.dump(src, open(dst_p, "w"))
                n += 1
        print("%s merged %d entries" % (vid, n))
    c = collections.Counter()
    for mp in glob.glob(os.path.join(vd, "entries", "*.json")):
        try:
            m = json.load(open(mp))
        except Exception:
            continue
        s = int(m.get("status") or 0)
        if drop and s in (0, 403, 429, 503):
            os.unlink(mp)   # refetched by the next --net record run
            continue
        c[(m.get("kind"), "ok" if 200 <= s < 400 else str(s))] += 1
    bad = {k: v for k, v in c.items() if k[1] in ("403", "429", "0", "503")}
    tot = sum(c.values())
    flag = "  <-- blocked?" if sum(bad.values()) > max(3, tot * 0.2) else ""
    print("%-14s entries=%-4d %s%s" % (vid, tot, " ".join("%s:%s=%d" % (k[0], k[1], v) for k, v in sorted(c.items())), flag))
