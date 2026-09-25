#!/usr/bin/python3
"""Make sure every page a benchmark item sits on is in the replay store, as the curl client,
python requests and headless Chrome (rendered DOM) each saw it. Polite: <=1 request/s per site.

usage: capture.py [--benchmark B.json] [--snapshots DIR] [--venues IDS] [--workers 4] [--refresh]
Then run `run_recall.sh --net record` once per pipeline version to capture the pages that
pipeline's own crawl asks for.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

LIB = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.dirname(LIB)
sys.path.insert(0, LIB)
from store import Store, polite_wait  # noqa: E402


def pages_of(v):
    out = [v["website"]]
    for it in v["items"]:
        for u in [it.get("page")] + it.get("also_on", []):
            if u and u not in out:
                out.append(u)
    return out


def capture_venue(v, a):
    store_dir = os.path.join(a.snapshots, v["venue_id"])
    os.makedirs(store_dir, exist_ok=True)
    env = dict(os.environ, UW_STORE=store_dir, UW_NET="record", UW_HOSTLOCK_DIR="/tmp/uw_hostlock",
               PYTHONPATH=os.path.join(LIB, "py"), PYTHONWARNINGS="ignore")
    st = Store(store_dir)
    done = []
    state = tempfile.mkdtemp(prefix="uwcap_")
    env_c = dict(env, UW_CHROME_STATE=state)
    launched = False
    try:
        for u in pages_of(v):
            if a.refresh or st.get("curl", u)[0] is None:
                subprocess.run([os.path.join(LIB, "bin", "curl"), "-sL", "--compressed", "--max-time", "15", "-o", "/dev/null", u],
                               env=env, capture_output=True, timeout=120)
            if a.refresh or st.get("req", u)[0] is None:
                subprocess.run(["/usr/bin/python3", "-c", "import requests,sys\ntry: requests.Session().get(sys.argv[1], timeout=15, headers={'User-Agent':'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36'})\nexcept Exception: pass", u],
                               env=env, capture_output=True, timeout=120)
            if a.refresh or st.get("chrome", u)[0] is None:
                if not launched:
                    subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "launch"], env=env_c, capture_output=True, timeout=60)
                    launched = True
                subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "nav", u], env=env_c, capture_output=True, timeout=120)
            done.append(u)
    finally:
        if launched:
            subprocess.run(["node", os.path.join(LIB, "chromectl.mjs"), "kill"], env=env_c, capture_output=True, timeout=60)
        shutil.rmtree(state, ignore_errors=True)
    return v["venue_id"], len(done)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--benchmark", default=os.path.join(HOME, "benchmark.json"))
    ap.add_argument("--snapshots", default=os.path.join(HOME, "snapshots"))
    ap.add_argument("--venues", default="")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--refresh", action="store_true")
    a = ap.parse_args()
    bench = json.load(open(a.benchmark))
    vs = [v for v in bench["venues"] if not a.venues or v["venue_id"] in set(a.venues.split(","))]
    with ThreadPoolExecutor(a.workers) as ex:
        for vid, n in ex.map(lambda v: capture_venue(v, a), vs):
            print(vid, n, "pages captured", flush=True)


if __name__ == "__main__":
    main()
