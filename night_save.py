#!/usr/bin/env python3
"""Save what the night deep dive found (reports/runs/RUN_ID.deepdive.json) to the sheet.

    night_save.py RUN_ID [--dry-run]

The deep dive (a Claude session) only researches and writes findings; this script is the
one that writes, under the runbook's save policy (outreach_rules.py):
  - no email = never saved (people without an email stay in the findings file)
  - junk / operational / general inboxes (info@, contact@ ...) are never saved
  - off-domain addresses are rejected unless the finding says allow_off_domain (the
    venue's own site publishes that domain for its contacts), then re-checked on it
  - every saved contact needs a real person name (first.last emails are the only
    exception); function inboxes (events@, catering@ ...) with a name -> verified=role,
    no ZeroBounce credit; personal inboxes -> ZeroBounce, saved only when valid
  - Facebook / Instagram / contact form are written only where the sheet is empty
  - a venue that now has a sendable contact goes to pipelined (never demoted) and loses
    its "PIPELINE: 0 contacts RUN_ID" park note
Every write is read back. Results: reports/runs/RUN_ID.deepdive-saved.json; the venues
it handled are appended to RUN_ID.deepdive.done. Prints key=value totals on the last line.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import outreach_rules as R  # noqa: E402

RUNS = os.path.join(HERE, "reports", "runs")
API = os.environ.get("APPS_SCRIPT_URL") or (
    "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec")
GUARD = os.path.join(HERE, "zerobounce_guard.py")
SENDABLE = {"valid", "role", "unverified", "verified"}
ZB_OUTAGE = {"run_budget_reached", "day_budget_reached", "reserve_reached", "credit_check_failed",
             "disabled", "no_api_key"}
OWN_EMAILS = {"atdi1029@gmail.com", "alexbarnettclassical@gmail.com", "abar89251@gmail.com",
              "alex@alexbarnettclassical.com"}


def api(params, timeout=60):
    """GET the backend. Resends on a transport error, and on LOCK_BUSY (another writer held
    the backend lock for 30s; nothing was written)."""
    url = API + "?" + urllib.parse.urlencode(params)
    last = {"status": "error", "message": "no answer"}
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                last = json.loads(r.read().decode("utf-8", "replace"))
        except Exception as exc:
            last = {"status": "error", "message": f"no answer: {exc}"}
            if attempt >= 2:
                return last
            time.sleep(3)
            continue
        if not (last.get("busy") or str(last.get("message") or "").startswith("LOCK_BUSY")):
            return last
        time.sleep(5 * attempt)
    return last


def detail(vid):
    d = api({"action": "venue_detail", "venue_id": vid})
    return d if d.get("status") == "ok" else None


def sendable_count(d):
    return sum(1 for c in (d or {}).get("contacts") or []
               if c.get("email") and str(c.get("verified", "")).strip().lower() in SENDABLE)


def update_venue(vid, field, value):
    d = api({"action": "update_venue", "venue_id": vid, "field": field, "value": value})
    return d.get("status") == "ok" and d.get("verified", True) is not False


def zb_verify(email, run_id):
    try:
        out = subprocess.run([sys.executable, GUARD, "verify", email, "--source", "night_deepdive",
                              "--run-id", f"night-{run_id}"], capture_output=True, text=True, timeout=120)
        return json.loads(out.stdout or "{}")
    except Exception as exc:
        return {"status": "deferred", "reason": f"guard_error:{exc}"}


def social_ok(url, host):
    u = (url or "").strip()
    return bool(re.match(r"^https?://([a-z0-9-]+\.)*" + re.escape(host) + r"/[^\s]+$", u, re.I))


def main(argv):
    if not argv or not re.fullmatch(r"[A-Za-z0-9._-]+", argv[0]):
        print(__doc__)
        return 2
    run_id, dry = argv[0], "--dry-run" in argv[1:]
    src = os.path.join(RUNS, f"{run_id}.deepdive.json")
    try:
        findings = json.load(open(src))
    except (OSError, ValueError) as exc:
        print(f"no readable findings file {src}: {exc}", file=sys.stderr)
        print("saved=0 venues_rescued=0 socials=0 rejected=0 errors=1")
        return 1
    results, done = [], []
    totals = {"saved": 0, "venues_rescued": 0, "socials": 0, "rejected": 0, "errors": 0}
    zb_out = ""
    for fv in findings.get("venues") or []:
        vid = str(fv.get("venue_id") or "").strip()
        if not vid:
            continue
        d = detail(vid)
        if not d:
            results.append({"venue_id": vid, "error": "venue_detail failed"})
            totals["errors"] += 1
            continue
        v = d.get("venue") or {}
        before = sendable_count(d)
        have = {R.normalize_email(c.get("email")) for c in d.get("contacts") or [] if c.get("email")}
        vr = {"venue_id": vid, "name": v.get("name"), "contacts": [], "socials": []}
        saved_here = 0
        for c in fv.get("contacts") or []:
            email = R.normalize_email(c.get("email") or "")
            out = {"email": email or "", "name": c.get("name") or "", "source_url": c.get("source_url") or ""}
            vr["contacts"].append(out)
            if not email:
                out["outcome"] = "not_saved:no_email"
                continue
            if email in have:
                out["outcome"] = "known"
                continue
            if email in OWN_EMAILS:
                out["outcome"] = "rejected:own_email"
                totals["rejected"] += 1
                continue
            on_site = bool(c.get("found_on_venue_site"))
            mailto = bool(c.get("venue_mailto"))
            chk = R.check_email(email, venue_domain=v.get("website") or "", venue_name=v.get("name") or "",
                                found_on_venue_site=on_site, venue_mailto=mailto)
            allow_off = False
            if chk["action"] == "reject" and chk["reason"].startswith("off_domain") and c.get("allow_off_domain"):
                chk = R.check_email(email, venue_domain=email.split("@", 1)[1], venue_name=v.get("name") or "",
                                    found_on_venue_site=True, venue_mailto=mailto)
                allow_off = chk["action"] != "reject"
            if chk["action"] == "reject":
                out["outcome"] = "rejected:" + chk["reason"]
                totals["rejected"] += 1
                continue
            name = R.clean_person_name(c.get("name") or "") or R.clean_person_name(chk.get("name_hint") or "")
            if not name:
                out["outcome"] = "rejected:no_person_name"
                totals["rejected"] += 1
                continue
            title = re.sub(r"\s+", " ", str(c.get("title") or "")).strip()[:80]
            if chk["action"] == "role":
                verified = "role"
            else:
                if zb_out:
                    zb = {"status": "deferred", "reason": zb_out}
                else:
                    zb = {"status": "dry_run"} if dry else zb_verify(email, run_id)
                st, why = str(zb.get("status") or ""), str(zb.get("reason") or "")
                if st == "valid" or st == "dry_run":
                    verified = "valid"
                elif st in ("deferred", "pending") and why in ZB_OUTAGE:
                    zb_out = why
                    verified = "unverified"   # same as the pipeline when ZeroBounce runs out
                else:
                    out["outcome"] = f"rejected:zerobounce_{st or 'error'}"
                    totals["rejected"] += 1
                    continue
            out.update({"name": name, "title": title, "verified": verified})
            if dry:
                out["outcome"] = "would_save"
                continue
            params = {"action": "add_contact", "venue_id": vid, "name": name, "title": title, "email": email,
                      "source": "night_" + re.sub(r"[^a-z_]", "", str(c.get("source") or "deepdive").lower())[:24],
                      "verified": verified, "is_generic": "true" if verified == "role" else "false"}
            if allow_off:
                params["allow_off_domain"] = "true"
            resp = api(params)
            dup = resp.get("duplicate") is True or "uplicate" in str(resp.get("message") or "")
            if resp.get("status") != "ok" and not dup:
                out["outcome"] = "error:" + str(resp.get("reason") or resp.get("message") or "api_error")[:120]
                totals["errors"] += 1
                continue
            if dup or ("created" in resp and str(resp.get("created")).lower() != "true"):
                out["outcome"] = "duplicate:" + str(resp.get("existing_venue_id") or vid)
                continue
            rb = detail(vid)
            if rb and any(R.normalize_email(x.get("email")) == email for x in rb.get("contacts") or []):
                out["outcome"] = "saved"
                have.add(email)
                saved_here += 1
                totals["saved"] += 1
            else:
                out["outcome"] = "error:readback_failed"
                totals["errors"] += 1
        for field, host in (("facebook", "facebook.com"), ("instagram", "instagram.com"), ("contact_form", "")):
            val = str(fv.get(field) or "").strip()
            if not val:
                continue
            ok = social_ok(val, host) if host else bool(re.match(r"^https?://\S+$", val))
            rec = {"field": field, "value": val}
            vr["socials"].append(rec)
            if not ok:
                rec["outcome"] = "rejected:bad_url"
            elif str(v.get(field) or "").strip():
                rec["outcome"] = "kept_existing"
            elif dry:
                rec["outcome"] = "would_save"
            elif update_venue(vid, field, val):
                rec["outcome"] = "saved"
                totals["socials"] += 1
            else:
                rec["outcome"] = "error:write_failed"
                totals["errors"] += 1
        if saved_here and not dry:
            d2 = detail(vid) or d
            v2 = d2.get("venue") or v
            if sendable_count(d2) > 0 and before == 0:
                totals["venues_rescued"] += 1
            if sendable_count(d2) > 0 and v2.get("status") not in ("pipelined", "contacted"):
                vr["status"] = "pipelined" if update_venue(vid, "status", "pipelined") else "status_write_failed"
            notes = str(v2.get("notes") or "")
            cleaned = re.sub(r"( \| )?PIPELINE: 0 contacts " + re.escape(run_id) + r"[^|]*", "", notes).strip(" |")
            stamp = f"NIGHT DEEP DIVE {run_id}: +{saved_here} contacts"
            if stamp not in cleaned:
                cleaned = f"{cleaned} | {stamp}" if cleaned else stamp
            if cleaned != notes:
                update_venue(vid, "notes", cleaned)
        results.append(vr)
        if fv.get("researched", True):
            done.append(vid)
    doc = {"run_id": run_id, "dry_run": dry, "at": datetime.now().astimezone().isoformat(timespec="seconds"),
           "totals": totals, "zerobounce_out": zb_out, "venues": results}
    if not dry:
        with open(os.path.join(RUNS, f"{run_id}.deepdive-saved.json"), "w") as f:
            json.dump(doc, f, indent=1)
        with open(os.path.join(RUNS, f"{run_id}.deepdive.done"), "a") as f:
            f.write("".join(v + "\n" for v in done))
    else:
        print(json.dumps(doc, indent=1))
    print(" ".join(f"{k}={v}" for k, v in totals.items()) + (f" zerobounce_out={zb_out}" if zb_out else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
