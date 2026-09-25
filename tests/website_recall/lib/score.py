#!/usr/bin/python3
"""Score one harness run against benchmark.json.

usage: score.py BENCHMARK.json RUN_DIR [--modes chrome,curl] [--json OUT.json]
RUN_DIR/<venue_id>/<mode>/ holds run_step1.sh output (vp.tsv, cand.tsv, api.jsonl, trace.jsonl, step1.log).

An expected item counts as FOUND when the website step handed it on:
  email        -> passed to verify_and_push or record_candidate (any name)
  person       -> a verify_and_push/record_candidate/add_contact call carries that name
  contact_form -> an update_venue contact_form value matching the item (same page, or same provider host)
Each miss is labelled with its type and whether the page it sits on was ever visited (and by which path).
"""
import argparse
import collections
import json
import os
import re
import sys
from urllib.parse import urlsplit, unquote

TYPE_ORDER = ["person_no_email", "third_party_form", "native_form", "obfuscated_text", "cloudflare_href",
              "cloudflare_attr", "js_rendered", "pdf", "script_json", "entity_encoded", "mailto", "plain_text"]


def norm_email(e):
    e = unquote((e or "").strip().lower())
    e = re.sub(r"^mailto:", "", e).split("?")[0].strip(" .,;:<>\"'()[]")
    return e


def norm_page(u):
    if not u:
        return ""
    try:
        p = urlsplit(u.strip())
    except Exception:
        return u.strip().lower()
    host = p.netloc.lower()
    host = host[4:] if host.startswith("www.") else host
    path = (p.path or "/").rstrip("/") or "/"
    return host + path + (("?" + p.query) if p.query else "")


def name_tokens(n):
    return [t for t in re.findall(r"[a-z]+", (n or "").lower()) if len(t) > 1]


def name_match(expected, got):
    et, gt = name_tokens(expected), set(name_tokens(got))
    if not et or not gt:
        return False
    last = et[-1]
    return last in gt and (et[0] in gt or len(et) == 1)


def primary_type(item):
    hows = item.get("how", [])
    for t in TYPE_ORDER:
        if t in hows:
            return t
    return hows[0] if hows else "other"


def load_run(d):
    out = {"emails": {}, "names": [], "forms": [], "visited": collections.defaultdict(set), "status": "",
           "js_errors": [], "missing_urls": set(), "approx": 0, "step_lines": []}
    if not os.path.isdir(d):
        out["status"] = "not_run"
        return out
    try:
        out["status"] = open(os.path.join(d, "status")).read().strip()
    except Exception:
        out["status"] = "unknown"
    for fn, src in (("vp.tsv", "verify_and_push"), ("cand.tsv", "candidate")):
        p = os.path.join(d, fn)
        if not os.path.exists(p):
            continue
        for line in open(p, errors="ignore"):
            parts = line.rstrip("\n").split("\t")
            if not parts:
                continue
            e = norm_email(parts[0])
            name = parts[2] if len(parts) > 2 else ""
            title = parts[3] if len(parts) > 3 else ""
            if e:
                rec = out["emails"].setdefault(e, {"names": set(), "via": set()})
                if name:
                    rec["names"].add(name)
                rec["via"].add(src)
            if name:
                out["names"].append((name, title, src))
    p = os.path.join(d, "api.jsonl")
    if os.path.exists(p):
        for line in open(p, errors="ignore"):
            try:
                r = json.loads(line)
            except Exception:
                continue
            prm = r.get("params", {})
            if r.get("action") == "update_venue" and prm.get("field") == "contact_form" and prm.get("value"):
                out["forms"].append(unquote(str(prm["value"])))
            if r.get("action") == "add_contact":
                if prm.get("name"):
                    out["names"].append((str(prm.get("name")), str(prm.get("title", "")), "add_contact"))
                if prm.get("email"):
                    e = norm_email(str(prm["email"]))
                    out["emails"].setdefault(e, {"names": set(), "via": set()})["via"].add("add_contact")
    p = os.path.join(d, "trace.jsonl")
    if os.path.exists(p):
        for line in open(p, errors="ignore"):
            try:
                r = json.loads(line)
            except Exception:
                continue
            via = r.get("via")
            if via in ("curl", "req", "chrome"):
                u = r.get("url", "")
                if r.get("found") and r.get("source") not in ("missing", "not_loaded") and int(r.get("status") or 200) < 400:
                    out["visited"][norm_page(u)].add(via)
                    if r.get("final_url"):
                        out["visited"][norm_page(r["final_url"])].add(via)
                elif r.get("source") == "missing":
                    out["missing_urls"].add(u)
                if r.get("approx"):
                    out["approx"] += 1
            elif via == "chrome-eval" and r.get("error"):
                out["js_errors"].append(r["error"].split("\n")[0][:160])
    p = os.path.join(d, "step1.log")
    if os.path.exists(p):
        out["step_lines"] = [l.strip() for l in open(p, errors="ignore") if l.startswith("[STEP]") or "[STEP]" in l[:12]]
    return out


def form_match(item, forms):
    want = [norm_page(u) for u in ([item.get("value")] + item.get("accept", []) + [item.get("page")]) if u]
    prov_host = item.get("provider_host", "")
    for f in forms:
        nf = norm_page(f.split("#")[0])
        if nf in want:
            return f
        if prov_host and prov_host in f.lower():
            return f
    return None


def score_item(item, run):
    kind = item["kind"]
    if kind == "email":
        e = norm_email(item["value"])
        rec = run["emails"].get(e)
        if not rec:
            return False, None
        extra = {"via": sorted(rec["via"])}
        if item.get("name"):
            extra["name_attached"] = any(name_match(item["name"], n) for n in rec["names"])
        return True, extra
    if kind == "person":
        for n, t, src in run["names"]:
            if name_match(item["name"], n):
                return True, {"via": src, "got": n}
        return False, None
    if kind == "contact_form":
        f = form_match(item, run["forms"])
        return (f is not None), ({"got": f} if f else None)
    return False, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("benchmark")
    ap.add_argument("run_dir")
    ap.add_argument("--modes", default="chrome,curl")
    ap.add_argument("--json", default="")
    ap.add_argument("--venues", default="")
    ap.add_argument("--quiet-found", action="store_true")
    a = ap.parse_args()
    bench = json.load(open(a.benchmark))
    modes = [m for m in a.modes.split(",") if m]
    only = set(a.venues.split(",")) if a.venues else None
    results = {"modes": {}, "items": []}
    lines = []
    for mode in modes:
        tot = collections.Counter()
        fnd = collections.Counter()
        name_tot = name_ok = 0
        per_venue = []
        misses = []
        run_problems = []
        for v in bench["venues"]:
            if only and v["venue_id"] not in only:
                continue
            run = load_run(os.path.join(a.run_dir, v["venue_id"], mode))
            if not run["status"].startswith("rc="):
                run_problems.append((v["venue_id"], run["status"]))
            vf = vt = 0
            for it in v["items"]:
                if it.get("exclude"):
                    continue
                t = primary_type(it)
                ok, extra = score_item(it, run)
                keys = ["ALL", "kind:" + it["kind"], "type:" + t, "prio:" + it.get("priority", "normal"),
                        "access:" + v.get("access", "open")]
                for k in keys:
                    tot[k] += 1
                    if ok:
                        fnd[k] += 1
                vt += 1
                vf += 1 if ok else 0
                if it["kind"] == "email" and it.get("name") and ok:
                    name_tot += 1
                    name_ok += 1 if extra.get("name_attached") else 0
                visited = set()
                for pg in [it.get("page", "")] + it.get("also_on", []):
                    visited |= run["visited"].get(norm_page(pg), set())
                visited = sorted(visited)
                rec = {"mode": mode, "venue_id": v["venue_id"], "kind": it["kind"], "value": it.get("value") or it.get("name"),
                       "name": it.get("name", ""), "type": t, "how": it.get("how", []), "page": it.get("page", ""),
                       "found": ok, "extra": extra, "page_visited_by": visited}
                results["items"].append(rec)
                if not ok:
                    misses.append(rec)
            per_venue.append((v["venue_id"], vf, vt, run["status"], len(run["js_errors"]), len(run["missing_urls"])))
        results["modes"][mode] = {"total": dict(tot), "found": dict(fnd), "names_attached": [name_ok, name_tot],
                                  "run_problems": run_problems}
        lines.append("=" * 78)
        lines.append("MODE %s   overall recall: %d / %d = %.0f%%" % (mode, fnd["ALL"], tot["ALL"], 100.0 * fnd["ALL"] / max(1, tot["ALL"])))
        lines.append("  names attached to found staff emails: %d / %d" % (name_ok, name_tot))
        for grp in ("kind:", "prio:", "access:", "type:"):
            ks = sorted(k for k in tot if k.startswith(grp))
            lines.append("  " + "  ".join("%s %d/%d" % (k[len(grp):], fnd[k], tot[k]) for k in ks))
        if run_problems:
            lines.append("  RUN PROBLEMS: " + ", ".join("%s=%s" % x for x in run_problems))
        lines.append("  per venue (found/total, js_errors, uncaptured urls requested):")
        for vid, vf, vt, st, je, mu in per_venue:
            lines.append("    %-14s %2d/%-2d  js_err=%-3d uncaptured=%-3d %s" % (vid, vf, vt, je, mu, "" if st.startswith("rc=") else st))
        lines.append("  misses:")
        for m in misses:
            pv = ",".join(m["page_visited_by"]) or "NOT VISITED"
            lines.append("    %-14s %-12s %-18s %-40s page=%s [%s]" % (m["venue_id"], m["kind"], m["type"], (m["value"] or "")[:40], m["page"][:70], pv))
    txt = "\n".join(lines)
    print(txt)
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1, default=list)


if __name__ == "__main__":
    main()
