#!/usr/bin/python3
"""Run site_discovery.py static-crawl on its own (the "sd" path), replayed from the store,
and write its findings in the same files run_step1.sh produces so score.py can grade it.

usage: run_sd.py SITE_DISCOVERY_PY OUTDIR STORE_DIR VENUE_ID WEBSITE
Same crawl bounds as pipeline.sh (--max-pages 40 --max-depth 3). The JSON is taken from the
first line that starts with '{' so an old version that prints diagnostics to stdout can still be
graded on what it found (the pipeline itself fails to parse that output; see the chrome/curl paths).
"""
import json
import os
import subprocess
import sys

LIB = os.path.dirname(os.path.abspath(__file__))


def main():
    sd, out, store, vid, website = sys.argv[1:6]
    os.makedirs(out, exist_ok=True)
    for f in ("vp.tsv", "cand.tsv", "api.jsonl", "trace.jsonl", "step1.log"):
        open(os.path.join(out, f), "w").close()
    env = dict(os.environ, UW_STORE=store, UW_NET=os.environ.get("UW_NET", "replay"),
               UW_TRACE=os.path.join(out, "trace.jsonl"), PYTHONPATH=os.path.join(LIB, "py"),
               PYTHONWARNINGS="ignore", SITE_DISCOVERY_DELAY="0",
               UW_HOSTLOCK_DIR=os.environ.get("UW_HOSTLOCK_DIR", "/tmp/uw_hostlock"))
    args = ["/usr/bin/python3", sd, "static-crawl", website, "--max-pages", "40", "--max-depth", "3"]
    r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=1500)
    open(os.path.join(out, "sd.stdout"), "w").write(r.stdout)
    open(os.path.join(out, "stderr.log"), "w").write(r.stderr[-20000:])
    raw = r.stdout
    stdout_clean = raw.lstrip().startswith("{")
    i = raw.find("\n{")
    js = raw if raw.lstrip().startswith("{") else (raw[i + 1:] if i >= 0 else "")
    try:
        d = json.loads(js)
    except Exception as e:
        open(os.path.join(out, "status"), "w").write("SD_JSON_FAILED rc=%d %s" % (r.returncode, str(e)[:80]))
        return 0
    with open(os.path.join(out, "vp.tsv"), "a") as f:
        for c in d.get("contacts", []):
            e = (c.get("email") or "").strip()
            if e:
                f.write("\t".join([e, vid, (c.get("name_hint") or "").replace("\t", " "),
                                   (c.get("title_hint") or "").replace("\t", " "), "sd", "mailto" if c.get("mailto") else ""]) + "\n")
    with open(os.path.join(out, "cand.tsv"), "a") as f:
        for p in d.get("people", []) or []:
            n = (p.get("name") or "").strip()
            if n:
                f.write("\t".join([(p.get("email") or ""), vid, n.replace("\t", " "), (p.get("title") or "").replace("\t", " "), "sd_people", "", p.get("source", "") or ""]) + "\n")
    with open(os.path.join(out, "api.jsonl"), "a") as f:
        for cf in d.get("contact_forms", []) or []:
            u = cf.get("url") or cf.get("page") or ""
            if u:
                f.write(json.dumps({"action": "update_venue", "params": {"venue_id": vid, "field": "contact_form", "value": u, "kind": cf.get("kind", "")}}) + "\n")
            for extra in ("provider_url", "src", "action"):
                if cf.get(extra):
                    f.write(json.dumps({"action": "update_venue", "params": {"venue_id": vid, "field": "contact_form", "value": cf[extra]}}) + "\n")
    cov = d.get("coverage", {})
    with open(os.path.join(out, "step1.log"), "a") as f:
        f.write("[SD] stdout_json_only=%s pages=%s contacts=%d people=%d forms=%d missing_kinds=%s blocked=%s\n" % (
            stdout_clean, cov.get("visited_page_count"), len(d.get("contacts", [])), len(d.get("people", []) or []),
            len(d.get("contact_forms", []) or []), cov.get("page_kinds_missing"), cov.get("blocked")))
    open(os.path.join(out, "status"), "w").write("rc=0" if stdout_clean else "rc=0")
    open(os.path.join(out, "sd_stdout_clean"), "w").write("yes" if stdout_clean else "no")
    return 0


if __name__ == "__main__":
    sys.exit(main())
