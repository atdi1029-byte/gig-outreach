#!/usr/bin/env python3
"""Make every venue in the sweep write-ups (sweep_*.md) reachable by the pipeline.

    import_sweep_files.py            preview: what's missing or not marked as a sweep find
    import_sweep_files.py --apply    add / tag / promote, with read-back

Alex, Sep 29 2026: "make sure you can access every place in the sweeps we are doing and
every one in the future". On Sep 29, 44 venues listed under READY TO ADD in the Georgetown,
Cleveland Park and Reston write-ups had never reached the sheet.

For each table row under a "READY TO ADD" heading (| # | Name | Website | Address | City |
State | Category |):
  - not on the sheet  -> add_venue with source "sweep:<file>", status untouched when it has
                         its own website; a missing or bare brand site (marriott.com) is
                         left blank as needs_review, and the night run's backfill finds it
  - on the sheet, but its source isn't a sweep -> note "Sweep find (<file>)", so planning
                         treats it as one (outreach_rules.is_sweep_find)
  - on the sheet as needs_review with a website and no park flag -> untouched (the sweep
                         verified it; the runbook allows this promotion)
Never touches pipelined / contacted / closed / dismissed rows. The backend's own
duplicate check (name, city, state, website) still guards every add.
"""
import glob
import json
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import outreach_rules as R  # noqa: E402

API = ("https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
PARKED = re.compile(r"pipeline|0 contacts|zero contacts|closed|dead|not a venue|junk|motel|airbnb|vrbo|"
                    r"too far|out of area|quarantin|duplicate|wrong business|flag", re.I)
BRAND_HOMEPAGES = {"marriott.com", "hilton.com", "hyatt.com", "ihg.com", "ritzcarlton.com",
                   "fourseasons.com", "citizenm.com", "invitedclubs.com", "sonesta.com",
                   "kimptonhotels.com", "choicehotels.com", "wyndhamhotels.com", "accor.com"}
END_HEADINGS = re.compile(r"excluded|closed|removed|coming soon|top \d+|priority|notes|already", re.I)


def api(params, timeout=60):
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception:
            time.sleep(3 * attempt)
    return {"status": "error", "message": "no answer"}


def norm(s):
    s = unicodedata.normalize("NFKD", str(s or "")).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[’'`]", "", s.replace("&", " and "))
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"^the\s+", "", re.sub(r"[^a-z0-9]+", " ", s).strip())


FILLER = {"the", "and", "at", "of", "a", "restaurant", "bar", "dc", "va", "md", "grill", "kitchen", "cafe"}


def tokens(s):
    return set(re.sub(r"[^a-z0-9]+", " ", unicodedata.normalize("NFKD", str(s or "")).encode(
        "ascii", "ignore").decode().lower().replace("&", " ")).split()) - FILLER


def host(u):
    u = re.sub(r"^https?://", "", (u or "").strip().lower())
    return re.sub(r"^www\.", "", u).split("/")[0]


def rows_from(path):
    """Table rows under READY TO ADD headings -> dicts keyed by the table header."""
    out, active, header = [], False, None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("#"):
            h = line.lstrip("#").strip()
            if line.startswith("## "):
                active = "ready to add" in h.lower()
            elif active and END_HEADINGS.search(h) and "ready" not in h.lower():
                active = False
            header = None
            continue
        if not active or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if set("".join(cells)) <= set("-: "):
            continue
        if cells and cells[0] == "#":
            header = [c.lower() for c in cells]
            continue
        if not header or not cells or not cells[0].isdigit():
            continue
        row = dict(zip(header, cells))
        if row.get("name"):
            out.append(row)
    return out


def main(argv):
    apply = "--apply" in argv
    venues = api({"action": "venues"}, timeout=180).get("venues") or []
    if not venues:
        print("could not read the venue list — nothing done")
        return 1
    by_name, by_host = {}, {}
    for v in venues:
        by_name.setdefault(norm(v.get("name")), []).append(v)
        if v.get("website"):
            by_host.setdefault(host(v["website"]), []).append(v)
    tally = {"rows": 0, "on_sheet": 0, "added": 0, "tagged": 0, "promoted": 0, "failed": 0}
    for path in sorted(glob.glob(str(HERE / "sweep_*.md"))):
        stem = Path(path).stem.replace("sweep_", "").replace("_", "-")
        for r in rows_from(path):
            tally["rows"] += 1
            name, web = r.get("name", "").replace("*", "").strip(), r.get("website", "").strip()
            city, state = r.get("city", "").strip(), r.get("state", "").strip().upper()
            n, h = norm(name), host(web) if "." in web else ""
            same_state = lambda v: not state or str(v.get("state", "")).upper() == state
            hits = [v for v in by_name.get(n, []) if same_state(v)]
            if not hits and h and h not in BRAND_HOMEPAGES:
                hits = [v for v in by_host.get(h, []) if same_state(v)]
            if not hits:
                # "Seven" is "Seven Restaurant & Bar", "Masti (Hyatt Regency)" is "Masti at Hyatt
                # Regency Reston": one name's words inside the other's, same city and state
                mine = tokens(name)
                hits = [v for v in venues if mine and same_state(v) and norm(v.get("city")) == norm(city)
                        and mine <= tokens(v.get("name"))]
            if hits:
                tally["on_sheet"] += 1
                v = hits[0]
                vid, st, notes = v.get("venue_id"), v.get("status"), str(v.get("notes") or "")
                if st not in ("untouched", "needs_review"):
                    continue
                if not R.is_sweep_find(v):
                    print(f"TAG      {vid:<14} {name[:44]:<44} sweep find ({stem})")
                    tally["tagged"] += 1
                    if apply:
                        notes = f"{notes} | Sweep find ({stem})".strip(" |")
                        if api({"action": "update_venue", "venue_id": vid, "field": "notes", "value": notes}).get("status") != "ok":
                            tally["failed"] += 1
                if st == "needs_review" and (v.get("website") or "").strip() and not PARKED.search(
                        f"{v.get('check_status') or ''} {notes}"):
                    print(f"PROMOTE  {vid:<14} {name[:44]:<44} needs_review -> untouched (in the {stem} sweep)")
                    tally["promoted"] += 1
                    if apply and api({"action": "update_venue", "venue_id": vid, "field": "status",
                                      "value": "untouched"}).get("status") != "ok":
                        tally["failed"] += 1
                continue
            if state not in R.TARGET_STATES:
                continue
            own = h and h not in BRAND_HOMEPAGES and not R.is_non_venue_host(h)
            url = ("https://" + web if not web.startswith("http") else web) if own else ""
            status = "untouched" if url else "needs_review"
            print(f"ADD      {name[:44]:<44} {url or '(no own website yet)'} | {city}, {state} -> {status}")
            tally["added"] += 1
            if not apply:
                continue
            res = api({"action": "add_venue", "name": name, "website": url, "city": city, "state": state,
                       "address": r.get("address", ""), "category": (r.get("category") or "other").lower(),
                       "status": status, "source": f"sweep:{stem}",
                       "notes": f"From the {stem} sweep write-up (added {time.strftime('%Y-%m-%d')}: it never reached the sheet)."},
                      timeout=120)
            if res.get("status") != "ok":
                print(f"         FAILED: {str(res.get('message') or res)[:120]}")
                tally["failed"] += 1
            elif res.get("duplicate"):
                print(f"         already there as {res.get('venue_id')} ({res.get('existing_status')})")
                tally["added"] -= 1
                tally["on_sheet"] += 1
    print(("APPLIED: " if apply else "PREVIEW: ") + " ".join(f"{k}={n}" for k, n in tally.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
