#!/usr/bin/env python3
"""Zero-contact venues of a run, with what the pipeline saw, for the night deep dive.

    night_zero.py RUN_ID            writes reports/runs/RUN_ID.zero.json, prints a summary
    night_zero.py RUN_ID --stats    prints the run's numbers as key=value (for night_status.py)

A venue is "zero" when the pipeline finished it (final ok / empty / failed) and the sheet
has no sendable email contact for it (verified valid / role / unverified). Venues already
handled by a deep dive (RUN_ID.deepdive.done) are left out, so a resumed run only sends
its new zeros. Read-only: one ?action=dashboard call, the run log, the candidate log and
the crawl coverage files.
"""
import glob
import json
import os
import re
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "reports", "runs")
API = os.environ.get("APPS_SCRIPT_URL") or (
    "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
SENDABLE = {"valid", "role", "unverified", "verified"}


def api(params, timeout=180):
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception:
            if attempt == 2:
                raise
    return {}


def run_venues(run_id):
    """venue_id -> batch entry, from the run's saved batch files, in run order."""
    out = {}
    files = sorted(glob.glob(os.path.join(RUNS, f"{run_id}.batch*.json")),
                   key=lambda p: int(re.search(r"\.batch(\d+)\.json$", p).group(1)))
    for p in files:
        try:
            for v in json.load(open(p)):
                vid = str((v or {}).get("venue_id") or "").strip()
                if vid and vid not in out:
                    out[vid] = v
        except (OSError, ValueError):
            continue
    return out


def run_log_finals(run_id, ids=()):
    """venue_id -> (result, kv dict, [every STEP line]) from the run log. Ids are matched
    against the run's own venue ids first: a few sheet ids contain a space (MD-ART -498)."""
    finals, steps = {}, {}
    spaced = sorted((i for i in ids if " " in i), key=len, reverse=True)
    path = os.path.join(RUNS, f"{run_id}.log")
    try:
        with open(path, errors="replace") as f:
            for line in f:
                i = line.find("[STEP] ")
                if i < 0:
                    continue
                s = line[i:].strip()
                rest = s[7:]
                vid = next((x for x in spaced if rest.startswith(x + " ")), None) or rest.split(" ", 1)[0]
                tail = rest[len(vid):].strip()
                steps.setdefault(vid, []).append(s[:600])
                m = re.match(r"final (\w+)(.*)$", tail)
                if m:
                    kv = dict(re.findall(r"(\w+)=(\S+)", m.group(2)))
                    finals[vid] = (m.group(1), kv)
    except OSError:
        pass
    return finals, steps


def done_ids(run_id):
    try:
        return {l.strip() for l in open(os.path.join(RUNS, f"{run_id}.deepdive.done")) if l.strip()}
    except OSError:
        return set()


def candidates(run_id, ids):
    out = {}
    path = os.path.join(HERE, "reports", "discovery-candidates.jsonl")
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if run_id not in line:
                    continue
                try:
                    c = json.loads(line)
                except ValueError:
                    continue
                vid = c.get("venue_id")
                if c.get("run_id") != run_id or vid not in ids:
                    continue
                lst = out.setdefault(vid, [])
                if len(lst) < 40:
                    lst.append({k: c.get(k) for k in ("kind", "email", "name", "title", "source",
                                                      "disposition", "evidence_url") if c.get(k)})
    except OSError:
        pass
    return out


def coverage(vid):
    out = []
    for sub in ("web-coverage", "postcheck-web-coverage"):
        p = os.path.join(HERE, "reports", sub, f"{vid}.json")
        if not os.path.exists(p):
            continue
        rec = {"file": os.path.relpath(p, HERE)}
        try:
            d = json.load(open(p))
            cov = d.get("coverage") or {}
            pages = d.get("pages") or []
            rec.update({
                "base": d.get("final_base") or d.get("base"),
                "pages_fetched": len(pages),
                "pages_ok": sum(1 for x in pages if x.get("ok")),
                "blocked": cov.get("blocked_reason") or bool(cov.get("blocked")),
                "high_priority_unvisited": (d.get("high_priority_unvisited") or [])[:10],
                "contact_forms": (d.get("contact_forms") or [])[:5],
                "people": (d.get("people") or [])[:10],
            })
        except (OSError, ValueError, AttributeError):
            pass
        out.append(rec)
    return out


def main(argv):
    if not argv or not re.fullmatch(r"[A-Za-z0-9._-]+", argv[0]):
        print(__doc__)
        return 2
    run_id = argv[0]
    stats_only = "--stats" in argv[1:]
    batch = run_venues(run_id)
    if not batch:
        print(f"no batch files for {run_id} in {RUNS}", file=sys.stderr)
        return 1
    finals, steps = run_log_finals(run_id, list(batch))
    dash = api({"action": "dashboard"})
    if dash.get("status") != "ok":
        print(f"dashboard read failed: {str(dash)[:200]}", file=sys.stderr)
        return 1
    venues = {v.get("venue_id"): v for v in dash.get("venues") or []}
    sendable = {}
    for c in dash.get("contacts") or []:
        if c.get("email") and str(c.get("verified", "")).strip().lower() in SENDABLE:
            sendable[c.get("venue_id")] = sendable.get(c.get("venue_id"), 0) + 1

    finished = [v for v in batch if v in finals and finals[v][0] in ("ok", "empty", "failed")]
    skipped = [v for v in batch if v in finals and finals[v][0] == "skipped"]
    with_contacts = [v for v in finished if sendable.get(v, 0) > 0]
    zero = [v for v in finished if sendable.get(v, 0) == 0]
    new = 0
    for v in finished:
        try:
            new += int(finals[v][1].get("new", 0))
        except ValueError:
            pass

    if stats_only:
        print(" ".join([f"venues={len(batch)}", f"processed={len(finished)}", f"skipped={len(skipped)}",
                        f"with_contacts={len(with_contacts)}", f"zero={len(zero)}", f"new_contacts={new}",
                        f"unfinished={len(batch) - len(finished) - len(skipped)}"]))
        return 0

    already = done_ids(run_id)
    todo = [v for v in zero if v not in already]
    cands = candidates(run_id, set(todo))
    out = {"run_id": run_id, "venues": []}
    for vid in todo:
        v = venues.get(vid) or {}
        b = batch.get(vid) or {}
        out["venues"].append({
            "venue_id": vid,
            "name": v.get("name") or b.get("name"),
            "website": v.get("website") or b.get("website"),
            "city": v.get("city") or b.get("city"),
            "state": v.get("state") or b.get("state"),
            "category": v.get("category"),
            "status": v.get("status"),
            "facebook": v.get("facebook") or "",
            "instagram": v.get("instagram") or "",
            "contact_form": v.get("contact_form") or "",
            "notes": (v.get("notes") or "")[:400],
            "pipeline_result": finals[vid][0],
            "pipeline_steps": steps.get(vid, [])[-25:],
            "candidates": cands.get(vid, []),
            "coverage": coverage(vid),
        })
    path = os.path.join(RUNS, f"{run_id}.zero.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, indent=1)
    os.replace(tmp, path)
    print(f"{run_id}: {len(batch)} venues, {len(finished)} finished, {len(with_contacts)} with contacts, "
          f"{len(zero)} zero ({len(todo)} not yet deep-dived) -> {os.path.relpath(path, HERE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
