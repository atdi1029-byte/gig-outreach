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
  - every contact passes outreach_rules.contact_gate (Nov 11 2026): back-office mailboxes
    and titles (accounting, legal, HR, IT, admissions, science, fundraising, caregivers)
    are never saved, and at most MAX_NEW_CONTACTS_PER_VENUE (10) are added per venue
  - contacts the full audit flagged (flag_contacts: wrong business / not a venue person)
    are DELETED from the sheet: a backup JSON of every row is written first
    (reports/repair/night-flagged-RUN_ID-STAMP.json), rows that were already emailed or
    messaged are never touched, and each delete is read back. NIGHT_DELETE_FLAGGED=0 only lists them.
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


def is_touched(c):
    """Emailed or messaged rows are history: never deleted (same rule as repair_data.py)."""
    sent = c.get("email_sent")
    return (sent not in (False, None, "", "false", "False")) or c.get("ig_dm_sent") in (True, "true") \
        or c.get("fb_msg_sent") in (True, "true")


class FlagDeleter:
    """Deletes the full audit's flagged contacts: backup first, then delete, then read back."""

    def __init__(self, run_id, dry):
        self.dry = dry or os.environ.get("NIGHT_DELETE_FLAGGED", "1") == "0"
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.backup_path = os.path.join(HERE, "reports", "repair", f"night-flagged-{run_id}-{stamp}.json")
        self.rows = []

    def _write_backup(self):
        os.makedirs(os.path.dirname(self.backup_path), exist_ok=True)
        tmp = self.backup_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"taken_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                       "why": "night_save.py: contacts flagged by the full audit (flag_contacts)",
                       "contacts": self.rows}, f, indent=1, default=str)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.backup_path)

    def run(self, vid, d, flagged, keep_emails):
        """Returns one outcome dict per flagged entry; d = the venue_detail just read."""
        out = []
        rows = d.get("contacts") or []
        for fl in flagged:
            email = R.normalize_email((fl or {}).get("email") if isinstance(fl, dict) else fl)
            rec = {"email": email or str(fl)[:120], "reason": (fl.get("reason") if isinstance(fl, dict) else "") or ""}
            out.append(rec)
            if not email:
                rec["outcome"] = "skipped:no_email"
                continue
            if email in keep_emails:
                rec["outcome"] = "skipped:also_found_as_a_contact"
                continue
            hits = [c for c in rows if R.normalize_email(c.get("email")) == email]
            if not hits:
                rec["outcome"] = "not_on_sheet"
                continue
            if len(hits) > 1 or not str(hits[0].get("contact_id") or "").strip():
                rec["outcome"] = "skipped:ambiguous_row"
                continue
            row = hits[0]
            if is_touched(row):
                rec["outcome"] = "skipped:already_contacted"
                continue
            if self.dry:
                rec["outcome"] = "would_delete"
                continue
            self.rows.append(dict(row, venue_id=row.get("venue_id") or vid, flag_reason=rec["reason"]))
            self._write_backup()          # the backup holds this row before it is deleted
            resp = api({"action": "delete_contact", "contact_id": row.get("contact_id"),
                        "venue_id": vid, "email": email})
            if resp.get("status") != "ok":
                rec["outcome"] = "error:" + str(resp.get("message") or resp.get("reason") or "api_error")[:120]
                continue
            rb = detail(vid)
            if rb is None:
                rec["outcome"] = "error:readback_failed"
            elif any(R.normalize_email(c.get("email")) == email for c in rb.get("contacts") or []):
                rec["outcome"] = "error:still_on_sheet"
            else:
                rec["outcome"] = "deleted"
                rows = rb.get("contacts") or []
        return out


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
    totals = {"saved": 0, "venues_rescued": 0, "socials": 0, "rejected": 0, "errors": 0,
              "flagged": 0, "deleted": 0}
    zb_out = ""
    deleter = FlagDeleter(run_id, dry)
    cap = int(os.environ.get("MAX_NEW_CONTACTS_PER_VENUE") or 10)
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
        # Contacts the full audit flagged (wrong business, not a venue person) are deleted
        # (Nov 11 2026), backup first, emailed rows never; see FlagDeleter.
        flagged = fv.get("flag_contacts") or []
        keep = {R.normalize_email(c.get("email") or "") for c in fv.get("contacts") or []} - {""}
        vr = {"venue_id": vid, "name": v.get("name"), "contacts": [], "socials": [],
              "flagged": deleter.run(vid, d, flagged, keep) if flagged else []}
        totals["flagged"] += len(vr["flagged"])
        n_del = sum(1 for x in vr["flagged"] if x.get("outcome") == "deleted")
        totals["deleted"] += n_del
        totals["errors"] += sum(1 for x in vr["flagged"] if str(x.get("outcome", "")).startswith("error"))
        if n_del:
            d = detail(vid) or d
        before = sendable_count(d)
        have = {R.normalize_email(c.get("email")) for c in d.get("contacts") or [] if c.get("email")}
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
            gate = R.contact_gate(email, name, title, chk["action"], venue_name=v.get("name") or "",
                                  venue_city=v.get("city") or "")
            if not gate["ok"]:
                out["outcome"] = "rejected:" + gate["reason"]
                totals["rejected"] += 1
                continue
            if saved_here >= cap:
                out["outcome"] = "not_saved:venue_contact_cap"
                continue
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
        if n_del and not dry:
            d3 = detail(vid)
            if d3 is not None and sendable_count(d3) == 0:
                vr["now_zero"] = True   # status is never demoted; the next deep dive re-researches it
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
           "totals": totals, "zerobounce_out": zb_out, "venues": results,
           "flagged_backup": deleter.backup_path if deleter.rows else ""}
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
