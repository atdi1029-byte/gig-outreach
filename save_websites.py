#!/usr/bin/env python3
"""Write researched venue websites to the sheet (sweep finds saved without one, or with a
directory / tourism / bare brand page instead of their own site).

    save_websites.py FINDINGS.json [FINDINGS.json ...]           preview (writes nothing)
    save_websites.py FINDINGS.json [...] --apply                  write + read back

FINDINGS: a JSON list of {"venue_id", "website", "confidence": high|medium|low,
"closed": bool, "facebook", "instagram", "evidence"} (what the research agents return).

- website: must be http(s), not a directory/social/review host, not a bare brand homepage;
  written only for confidence high/medium, then read back. For confidence high the note
  "Website checked YYYY-MM-DD" marks it as confirmed by hand, so build_batch/verify_pool
  accept a property page whose domain doesn't spell the venue's name
  (reston.org/.../The-Lake-House).
- closed (confidence high): status -> closed, with the evidence in the notes.
- facebook / instagram: only where the sheet has none. Never overwrites.
Only venues in untouched / needs_review are touched. Safe to re-run: done rows are skipped.
"""
import json
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import outreach_rules as R  # noqa: E402
from venue_quality import website_match_score  # noqa: E402

API = ("https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
CHECKED = f"Website checked {date.today().isoformat()}"
CHECKED_RX = re.compile(r"(?i)website checked \d{4}-\d{2}-\d{2}")


def api(params, timeout=45):
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception:
            time.sleep(3 * attempt)
    return {"status": "error", "message": "no answer"}


def update(vid, field, value):
    d = api({"action": "update_venue", "venue_id": vid, "field": field, "value": value})
    return d.get("status") == "ok" and d.get("verified", True) is not False


def clean_url(u):
    u = (u or "").strip()
    if u and not re.match(r"^https?://", u, re.I):
        u = "https://" + u
    return u if re.match(r"^https?://[^\s/]+\.[a-z]{2,}(/\S*)?$", u, re.I) else ""


def social_ok(u, host):
    return bool(re.match(r"^https?://([a-z0-9-]+\.)*" + re.escape(host) + r"/\S+$", (u or "").strip(), re.I))


def same_url(a, b):
    return a.rstrip("/").lower() == b.rstrip("/").lower()


def handle(r, v, apply):
    """One finding -> (printed lines, tally delta)."""
    out, t = [], {}

    def add(k):
        t[k] = t.get(k, 0) + 1

    vid = r.get("venue_id")
    if not v or v.get("status") not in ("untouched", "needs_review"):
        add("skipped")
        return out, t
    name, conf = v.get("name") or "", str(r.get("confidence") or "").lower()
    notes = str(v.get("notes") or "")
    if r.get("closed") and conf == "high":
        why = re.sub(r"\s+", " ", str(r.get("evidence") or ""))[:140]
        out.append(f"CLOSED  {vid:<14} {name[:40]:<40} {why}")
        add("closed")
        if apply and not (update(vid, "status", "closed") and
                          update(vid, "notes", f"{notes} | Closed ({CHECKED[16:]}): {why}".strip(" |"))):
            out.append("        write FAILED")
            add("failed")
        return out, t
    url, cur = clean_url(r.get("website")), clean_url(v.get("website"))
    if url and conf in ("high", "medium") and not R.is_non_venue_host(url):
        score = website_match_score(name, url)
        same = same_url(cur, url)
        vouch = conf == "high" and not CHECKED_RX.search(notes)
        if score == -100:
            out.append(f"REJECT  {vid:<14} {name[:40]:<40} {url} (blocked host)")
            add("skipped")
        elif same and not vouch:
            add("same")
        else:
            out.append(f"{'CONFIRM' if same else 'WEBSITE'} {vid:<14} {name[:40]:<40} {url} (match {score})")
            add("same" if same else "website")
            if apply:
                ok = same or update(vid, "website", url)
                # only a high-confidence check vouches for a site whose domain doesn't match
                if ok and vouch:
                    ok = update(vid, "notes", f"{notes} | {CHECKED}".strip(" |"))
                if ok and not same:
                    back = api({"action": "venue_detail", "venue_id": vid}).get("venue") or {}
                    ok = same_url(clean_url(back.get("website")), url)
                if not ok:
                    out.append("        write/read-back FAILED")
                    add("failed")
    for field, host in (("facebook", "facebook.com"), ("instagram", "instagram.com")):
        val = str(r.get(field) or "").strip()
        if val and social_ok(val, host) and not str(v.get(field) or "").strip():
            add("social")
            if apply and not update(vid, field, val):
                add("failed")
    return out, t


def main(argv):
    files = [a for a in argv if not a.startswith("--")]
    apply = "--apply" in argv
    if not files:
        print(__doc__)
        return 2
    rows = []
    for f in files:
        rows += json.load(open(f))
    venues = {v["venue_id"]: v for v in api({"action": "venues"}, timeout=180).get("venues") or []}
    if not venues:
        print("could not read the venue list — nothing written")
        return 1
    tally = dict.fromkeys(("website", "same", "closed", "social", "skipped", "failed"), 0)
    lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=6) as ex:
        for out, t in ex.map(lambda r: handle(r, venues.get(r.get("venue_id")), apply), rows):
            with lock:
                for line in out:
                    print(line, flush=True)
                for k, n in t.items():
                    tally[k] += n
    print(("APPLIED: " if apply else "PREVIEW: ") + " ".join(f"{k}={n}" for k, n in tally.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
