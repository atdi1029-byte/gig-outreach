#!/usr/bin/env python3
"""Syntax-check the Python embedded in the outreach shell scripts.

The scripts run dozens of `python3 << EOF ... EOF` and `python3 -c "..."` blocks
with stderr sent to /dev/null, so a SyntaxError/IndentationError silently turns a
whole step into "no data" (that is how the Apollo org lookup died for a run).
This extracts every block, replaces shell expansions with a placeholder, and
compiles it. Exit 1 if any block fails.

    python3 tests/check_heredocs.py [script.sh ...]   # default: all *.sh in the repo
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

HEREDOC_START = re.compile(r"""python3?\b[^\n<]*<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""")
DASH_C = re.compile(r"""python3?\s+-c\s+(['"])""")


def _neutralise_shell(src):
    """Replace $(...), ${...} and $VAR with a string-safe placeholder."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "\\" and i + 1 < n and src[i + 1] in '$`"\\':
            out.append(src[i + 1])
            i += 2
            continue
        if c == "$" and i + 1 < n and src[i + 1] == "(":
            depth, j = 1, i + 2
            while j < n and depth:
                depth += {"(": 1, ")": -1}.get(src[j], 0)
                j += 1
            out.append("SHELLVAL")
            i = j
            continue
        if c == "$" and i + 1 < n and src[i + 1] == "{":
            j = src.find("}", i)
            out.append("SHELLVAL")
            i = (j + 1) if j != -1 else n
            continue
        if c == "$" and i + 1 < n and (src[i + 1].isalpha() or src[i + 1] == "_"):
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            out.append("SHELLVAL")
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def blocks(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = text.split("\n")
    # heredocs
    i = 0
    while i < len(lines):
        m = HEREDOC_START.search(lines[i])
        if m and not lines[i].lstrip().startswith("#"):
            quoted, tag = bool(m.group(1)), m.group(2)
            strip_tabs = "<<-" in lines[i]
            body, j = [], i + 1
            while j < len(lines):
                probe = lines[j].lstrip("\t") if strip_tabs else lines[j]
                if probe.strip() == tag:
                    break
                body.append(probe)
                j += 1
            src = "\n".join(body)
            if not quoted:
                src = _neutralise_shell(src)
            yield i + 1, "heredoc", src
            i = j + 1
            continue
        i += 1
    # python3 -c '...' / "..."
    for m in DASH_C.finditer(text):
        q = m.group(1)
        j, buf = m.end(), []
        while j < len(text):
            ch = text[j]
            if q == "'":
                if text.startswith("'\\''", j):      # bash '\'' = literal quote
                    buf.append("'")
                    j += 4
                    continue
                if ch == "'":
                    break
            else:
                if ch == "\\":
                    buf.append(text[j:j + 2])
                    j += 2
                    continue
                if text.startswith("$(", j):          # skip nested command substitution
                    depth, k = 1, j + 2
                    while k < len(text) and depth:
                        depth += {"(": 1, ")": -1}.get(text[k], 0)
                        k += 1
                    buf.append(text[j:k])
                    j = k
                    continue
                if ch == '"':
                    break
            buf.append(ch)
            j += 1
        src = "".join(buf)
        line = text.count("\n", 0, m.start()) + 1
        if text[:m.start()].rsplit("\n", 1)[-1].lstrip().startswith("#"):
            continue
        if q == '"':
            src = _neutralise_shell(src)
        yield line, "-c", src


def main(argv):
    paths = argv or sorted(glob.glob(os.path.join(ROOT, "*.sh")))
    failures = total = 0
    for p in paths:
        for line, kind, src in blocks(p):
            total += 1
            try:
                compile(src, f"{os.path.basename(p)}:{line}", "exec")
            except SyntaxError as e:
                failures += 1
                bad = (e.text or "").rstrip()
                print(f"FAIL {os.path.basename(p)}:{line} ({kind}) block line {e.lineno}: {e.msg}: {bad[:120]}")
    print(f"checked {total} embedded python blocks in {len(paths)} scripts: {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
