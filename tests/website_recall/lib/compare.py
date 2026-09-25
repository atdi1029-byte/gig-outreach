#!/usr/bin/python3
"""Compare two scored runs item by item.

usage: compare.py RUN_A RUN_B [--modes chrome,curl,sd]
Prints recall per mode for both runs and every item that flipped (gained / lost).
"""
import argparse
import collections
import json
import os


def load(d):
    r = json.load(open(os.path.join(d, "results.json")))
    items = {}
    for it in r["items"]:
        items[(it["mode"], it["venue_id"], it["kind"], (it["value"] or "").lower())] = it
    return r, items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--modes", default="")
    a = ap.parse_args()
    ra, ia = load(a.a)
    rb, ib = load(a.b)
    modes = [m for m in (a.modes.split(",") if a.modes else sorted(set(ra["modes"]) | set(rb["modes"]))) if m]
    print("A = %s\nB = %s" % (a.a, a.b))
    for m in modes:
        fa = ra["modes"].get(m, {})
        fb = rb["modes"].get(m, {})
        ta, tb = fa.get("total", {}).get("ALL", 0), fb.get("total", {}).get("ALL", 0)
        ga, gb = fa.get("found", {}).get("ALL", 0), fb.get("found", {}).get("ALL", 0)
        print("%-7s A %3d/%-3d  B %3d/%-3d" % (m, ga, ta, gb, tb))
        keys = sorted(set(k for k in list(fa.get("total", {})) + list(fb.get("total", {})) if k != "ALL"))
        for k in keys:
            print("   %-24s A %3d/%-3d  B %3d/%-3d" % (k, fa.get("found", {}).get(k, 0), fa.get("total", {}).get(k, 0),
                                                    fb.get("found", {}).get(k, 0), fb.get("total", {}).get(k, 0)))
        flips = collections.defaultdict(list)
        for key in sorted(set(k for k in ia if k[0] == m) | set(k for k in ib if k[0] == m)):
            x, y = ia.get(key), ib.get(key)
            fx, fy = bool(x and x["found"]), bool(y and y["found"])
            if fx != fy:
                it = y or x
                flips["gained" if fy else "lost"].append("%-14s %-12s %-16s %s" % (key[1], key[2], it["type"], key[3][:45]))
        for kind in ("gained", "lost"):
            if flips[kind]:
                print("   %s in B (%d):" % (kind, len(flips[kind])))
                for l in flips[kind]:
                    print("      " + l)


if __name__ == "__main__":
    main()
