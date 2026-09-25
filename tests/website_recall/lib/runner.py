#!/usr/bin/python3
"""Website-recall benchmark runner (called by ../run_recall.sh; see its header for usage)."""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

LIB = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.dirname(LIB)                      # tests/website_recall
REPO = os.path.dirname(os.path.dirname(HOME))    # the Email repo


def materialize_rev(rev, dest):
    """pipeline.sh + site_discovery.py from a git revision; every other support file from the working tree."""
    sup = os.path.join(dest, "support")
    os.makedirs(sup, exist_ok=True)
    for f in os.listdir(REPO):
        if f.startswith(".") or f in ("reports", "tests"):
            continue
        dst = os.path.join(sup, f)
        if not os.path.lexists(dst):
            os.symlink(os.path.join(REPO, f), dst)
    for f in ("pipeline.sh", "site_discovery.py"):
        r = subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (rev, f)], capture_output=True)
        if r.returncode == 0:
            p = os.path.join(sup, f)
            if os.path.lexists(p):
                os.unlink(p)
            open(p, "wb").write(r.stdout)
    return os.path.join(sup, "pipeline.sh"), sup


def run_task(args, v, mode, out_root):
    out = os.path.join(out_root, v["venue_id"], mode)
    store = os.path.join(args.snapshots, v["venue_id"])
    os.makedirs(store, exist_ok=True)
    env = dict(os.environ, UW_NET=args.net)
    if mode == "sd":
        cmd = ["/usr/bin/python3", os.path.join(LIB, "run_sd.py"), os.path.join(args.support_dir, "site_discovery.py"),
               out, store, v["venue_id"], v["website"]]
    else:
        cmd = ["bash", os.path.join(LIB, "run_step1.sh"), args.pipeline, args.support_dir, out, store, mode,
               v["venue_id"], v["name"], v["website"], v.get("city", "")]
    try:
        subprocess.run(cmd, env=env, timeout=args.timeout, capture_output=True)
    except subprocess.TimeoutExpired:
        open(os.path.join(out, "status"), "w").write("TIMEOUT")
    try:
        st = open(os.path.join(out, "status")).read().strip()
    except Exception:
        st = "?"
    return v["venue_id"], mode, st


def scrape_js_for(args, work):
    """Materialize the pipeline's Chrome scrape JS: write_scrape_js() if present, else the inline heredoc."""
    os.makedirs(work, exist_ok=True)
    defs, hdr = os.path.join(work, "defs.sh"), os.path.join(work, "header.sh")
    r = subprocess.run(["/usr/bin/python3", os.path.join(LIB, "extract_pipeline.py"), args.pipeline, work, defs, hdr],
                       capture_output=True, text=True)
    funcs = r.stdout.split()
    target = os.path.join(work, "pipeline_website_scrape.js")
    if "write_scrape_js" in funcs:
        subprocess.run(["bash", "-c", '. "$1" 2>/dev/null; . "$2"; SCRIPT_DIR="$3"; write_scrape_js "$4" >/dev/null 2>&1; write_scrape_js >/dev/null 2>&1; true',
                        "_", hdr, defs, args.support_dir, target], capture_output=True)
        if os.path.exists(target):
            return target, "write_scrape_js"
    text = open(defs, errors="ignore").read()
    m = re.search(r"cat\s*>\s*\"?[^\n\"]*pipeline_website_scrape\.js\"?\s*<<-?\s*'?\"?(\w+)'?\"?\s*\n(.*?)\n\1\s*\n", text, re.S)
    if m:
        open(target, "w").write(m.group(2) + "\n")
        return target, "inline_heredoc"
    return None, "not_found"


def page_level(args, bench, out_root):
    """Run the scrape JS directly on each expected item's page snapshot (isolates extractor from crawler)."""
    work = os.path.join(out_root, "_pagelevel")
    js, how = scrape_js_for(args, work)
    res = {"js_source": how, "items": []}
    if not js:
        print("page-level: could not find the scrape JS in", args.pipeline)
        return res
    state = tempfile.mkdtemp(prefix="uwpl_")
    lines = ["PAGE-LEVEL (Chrome scrape JS on the item's own page, %s):" % how]
    ok_n = tot_n = 0
    try:
        for v in bench["venues"]:
            if args.venues and v["venue_id"] not in args.venues:
                continue
            env = dict(os.environ, UW_NET="replay", UW_STORE=os.path.join(args.snapshots, v["venue_id"]),
                       UW_CHROME_STATE=state, UW_TRACE=os.path.join(work, "trace.jsonl"))
            subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "launch"], env=env, capture_output=True)
            cache = {}
            for it in v["items"]:
                if it["kind"] != "email" or it.get("exclude") or not it.get("page"):
                    continue
                pg = it["page"]
                if pg not in cache:
                    subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "nav", pg], env=env, capture_output=True)
                    r = subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "evalfile", js], env=env, capture_output=True, text=True)
                    try:
                        cache[pg] = (json.loads(r.stdout), "")
                    except Exception:
                        cache[pg] = (None, (r.stderr or r.stdout).strip().split("\n")[0][:120])
                data, err = cache[pg]
                emails = {}
                if data:
                    for c in data.get("contacts", data.get("emails", [])):
                        if isinstance(c, dict):
                            emails[(c.get("email") or "").lower()] = c
                        else:
                            emails[str(c).lower()] = {"email": str(c)}
                e = it["value"].lower()
                found = e in emails
                name_ok = None
                if found and it.get("name"):
                    got = emails[e].get("name", "")
                    name_ok = bool(got) and it["name"].split()[-1].lower() in got.lower()
                tot_n += 1
                ok_n += 1 if found else 0
                res["items"].append({"venue_id": v["venue_id"], "value": it["value"], "page": pg, "found": found,
                                     "name_attached": name_ok, "error": err, "how": it.get("how", [])})
                lines.append("  %-4s %-14s %-40s %-26s %s%s" % ("ok" if found else "MISS", v["venue_id"], it["value"][:40],
                             ",".join(it.get("how", []))[:26], pg[:60], ("  JS ERROR: " + err) if err else ""))
            subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "kill"], env=env, capture_output=True)
    finally:
        shutil.rmtree(state, ignore_errors=True)
    lines.insert(1, "  found %d / %d email items on their own page" % (ok_n, tot_n))
    print("\n".join(lines))
    res["summary"] = [ok_n, tot_n]
    return res


def main():
    ap = argparse.ArgumentParser(prog="run_recall.sh")
    ap.add_argument("--pipeline", default=os.path.join(REPO, "pipeline.sh"))
    ap.add_argument("--git-rev", default="")
    ap.add_argument("--support-dir", default="")
    ap.add_argument("--benchmark", default=os.path.join(HOME, "benchmark.json"))
    ap.add_argument("--snapshots", default=os.path.join(HOME, "snapshots"))
    ap.add_argument("--modes", default="chrome,curl,sd")
    ap.add_argument("--net", default="replay", choices=["replay", "record", "live"])
    ap.add_argument("--venues", default="")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--out", default="")
    ap.add_argument("--label", default="")
    ap.add_argument("--page-level", action="store_true")
    ap.add_argument("--score-only", default="")
    args = ap.parse_args()
    args.venues = set(x for x in args.venues.split(",") if x)
    bench = json.load(open(args.benchmark))
    if args.score_only:
        out_root = args.score_only
    else:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        label = args.label or (("rev-" + args.git_rev) if args.git_rev else os.path.basename(os.path.dirname(os.path.abspath(args.pipeline))))
        out_root = args.out or os.path.join(HOME, "runs", "%s-%s" % (stamp, re.sub(r"[^A-Za-z0-9_.-]", "_", label)))
        os.makedirs(out_root, exist_ok=True)
        if args.git_rev:
            args.pipeline, sup = materialize_rev(args.git_rev, out_root)
            args.support_dir = args.support_dir or sup
        args.pipeline = os.path.abspath(args.pipeline)
        args.support_dir = os.path.abspath(args.support_dir or REPO)
        json.dump({"pipeline": args.pipeline, "support_dir": args.support_dir, "modes": args.modes, "net": args.net,
                   "started": stamp}, open(os.path.join(out_root, "run.json"), "w"), indent=1)
        print("pipeline:", args.pipeline)
        print("support :", args.support_dir)
        print("out     :", out_root)
        venues = [v for v in bench["venues"] if not args.venues or v["venue_id"] in args.venues]
        modes = [m for m in args.modes.split(",") if m]
        if args.net == "replay":
            tasks = [(v, m) for v in venues for m in modes]
            with ThreadPoolExecutor(args.workers) as ex:
                for vid, m, st in ex.map(lambda t: run_task(args, t[0], t[1], out_root), tasks):
                    print("  %-14s %-6s %s" % (vid, m, st), flush=True)
        else:
            # One worker per venue so a site never sees parallel requests from us.
            def per_venue(v):
                return [run_task(args, v, m, out_root) for m in modes]
            with ThreadPoolExecutor(args.workers) as ex:
                for rs in ex.map(per_venue, venues):
                    for vid, m, st in rs:
                        print("  %-14s %-6s %s" % (vid, m, st), flush=True)
    score_cmd = ["/usr/bin/python3", os.path.join(LIB, "score.py"), args.benchmark, out_root, "--modes", args.modes,
                 "--json", os.path.join(out_root, "results.json")]
    if args.venues:
        score_cmd += ["--venues", ",".join(sorted(args.venues))]
    r = subprocess.run(score_cmd, capture_output=True, text=True)
    open(os.path.join(out_root, "report.txt"), "w").write(r.stdout)
    print(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    if args.page_level and not args.score_only:
        pl = page_level(args, bench, out_root)
        json.dump(pl, open(os.path.join(out_root, "page_level.json"), "w"), indent=1)
    print("report:", os.path.join(out_root, "report.txt"))


if __name__ == "__main__":
    main()
