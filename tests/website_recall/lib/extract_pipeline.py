#!/usr/bin/python3
"""Pull the function definitions (and the simple header assignments) out of a pipeline.sh
so the website step can run on its own, without executing the script's main code.

usage: extract_pipeline.py PIPELINE.sh WORKDIR OUT_DEFS.sh OUT_HEADER.sh

Function bodies are found by bash itself: a candidate closing `}` at column 0 only ends a
function if `bash -n` accepts the chunk (python/JS heredocs and multi-line python -c strings
contain column-0 braces too). Every `/tmp/pipeline_` path is rewritten to WORKDIR so parallel
harness runs can't collide with each other or with a real pipeline run.
Works for the old inline scrape-JS heredoc and for a write_scrape_js() function alike.
"""
import re
import subprocess
import sys

START = re.compile(r"^(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?\s*(?:#.*)?$")
ASSIGN = re.compile(r"^(?:export\s+|readonly\s+|declare\s+(?:-[a-zA-Z]+\s+)?)?([A-Za-z_][A-Za-z0-9_]*)=")
# Globals the harness sets itself (fake Apps Script URL, sandboxed dirs).
OVERRIDDEN = {"APPS_SCRIPT_URL", "SCRIPT_DIR", "SCRIPT_DIR_EARLY", "LOG_FILE", "CANDIDATE_LOG", "COVERAGE_DIR",
              "ERR_LOG", "ZEROBOUNCE_KEY", "APOLLO_API_KEY", "ZB_GUARD", "ZB_RUN_ID"}


def parses(text):
    r = subprocess.run(["bash", "-n"], input=text.encode(), capture_output=True)
    return r.returncode == 0


def main():
    src, work, out_defs, out_hdr = sys.argv[1:5]
    lines = open(src, encoding="utf-8", errors="surrogateescape").read().split("\n")
    starts = [i for i, l in enumerate(lines) if START.match(l)]
    funcs = []
    for i in starts:
        name = START.match(lines[i]).group(1)
        end = None
        for j in range(i + 1, len(lines)):
            if lines[j].rstrip() == "}" or re.match(r"^\}\s*(#.*)?$", lines[j]):
                chunk = "\n".join(lines[i:j + 1]) + "\n"
                if parses(chunk):
                    end = j
                    break
        if end is None:
            sys.stderr.write("extract_pipeline: could not find the end of %s()\n" % name)
            continue
        funcs.append((name, i, end))
    if not funcs:
        sys.stderr.write("extract_pipeline: no functions found in %s\n" % src)
        return 1
    inside = set()
    for _, a, b in funcs:
        inside.update(range(a, b + 1))
    names = [f[0] for f in funcs]
    # Header/region assignments: top-level, single-line, no command substitution, before step1b.
    limit = next((a for n, a, _ in funcs if n == "step1b_ig_search"), len(lines))
    hdr = []
    for k in range(0, limit):
        if k in inside:
            continue
        l = lines[k]
        m = ASSIGN.match(l)
        if not m or m.group(1) in OVERRIDDEN:
            continue
        if "$(" in l or "`" in l or re.search(r"\$\{?[0-9@*]", l) or "source " in l:
            continue
        if parses(l + "\n"):
            hdr.append(l)
    work = work.rstrip("/")

    def fix(t):
        return t.replace("/tmp/pipeline_", work + "/pipeline_")
    defs = []
    for n, a, b in funcs:
        defs.append(fix("\n".join(lines[a:b + 1])))
    open(out_defs, "w", encoding="utf-8", errors="surrogateescape").write("\n\n".join(defs) + "\n")
    open(out_hdr, "w", encoding="utf-8", errors="surrogateescape").write(fix("\n".join(hdr)) + "\n")
    print(" ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
