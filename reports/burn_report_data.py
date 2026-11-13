#!/usr/bin/python3
"""Data for the end-of-burn report (Nov 6-13 2026). Read-only; re-runnable; no arguments.

    /usr/bin/python3 reports/burn_report_data.py

Writes reports/burn_report_data.json and prints a short summary. It reads:
  - reports/runs/burn-*.log                 the burn's own log (rounds, waits, pauses, exits)
  - reports/runs/<RUN_ID>.log / .batchN.json / .stopped, reports/runs/plans/plan-<RUN_ID>/
  - reports/discovery-candidates.jsonl      every address the pipeline saw, with what it did
  - reports/runs/<RUN_ID>.deepdive-saved.json  what the after-round audit saved / flagged
                                            (every committed version, via `git show`)
  - reports/repair/cleanup-*contacts*.json, night-flagged-*.json   contacts deleted since
  - the live sheet: one GET ?action=dashboard (the same call night_zero.py makes)
  - ~/.outreach/zerobounce_guard.sqlite3    paid ZeroBounce checks per run (opened read-only)
  - two balance reads that cost nothing: Apollo api_profile, ZeroBounce getcredits
    (keys parsed from .env, never printed; BURN_REPORT_NO_LIVE=1 skips them)

It writes nothing but the JSON, never calls a write action on the backend, never touches
Chrome, and never spends a credit. No email address is written to the JSON.
"""
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta

REPORTS = os.path.dirname(os.path.abspath(__file__))
HERE = os.path.dirname(REPORTS)
RUNS = os.path.join(REPORTS, "runs")
REPAIR = os.path.join(REPORTS, "repair")
OUT = os.path.join(REPORTS, "burn_report_data.json")
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True          # importing night_zero must not leave a .pyc behind

SENDABLE = {"valid", "role", "unverified", "verified"}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
STEPS = ("web", "social", "apollo", "linkedin", "google", "final", "postcheck")
NOTES = []


def note(text):
    if text not in NOTES:
        NOTES.append(text)


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S") if dt else None


def mins(a, b):
    return round((b - a).total_seconds() / 60, 1) if a and b else None


def norm_email(e):
    return str(e or "").strip().lower()


LOCAL_RE = re.compile(r"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@(?![A-Za-z0-9-]+\.[A-Za-z])")
GENERIC_LOCAL = {"info", "contact", "hello", "office", "events", "event", "catering", "sales", "booking", "bookings",
                 "privateevents", "banquets", "weddings", "chef", "owner", "gm", "manager", "membership", "frontdesk",
                 "reception", "stay", "guest", "admin", "calendar", "gala", "press", "marketing", "careers", "hr",
                 "billing", "privacy", "webmaster", "noreply", "no-reply", "reservations", "eat", "meet", "ciao",
                 "food", "sayhello", "director", "accounting", "wecare", "team", "support", "general", "inquiries"}


def scrub(s):
    """No address leaves this script: full addresses become [email]; a bare mailbox name
    ('jsmith@') becomes [mailbox]@ unless it is a generic word (info@, events@ ...)."""
    if not isinstance(s, str):
        return s
    s = EMAIL_RE.sub("[email]", s)
    return LOCAL_RE.sub(lambda m: m.group(0) if m.group(1).lower() in GENERIC_LOCAL else "[mailbox]@", s)


def rel(p):
    return os.path.relpath(p, HERE)


def utc_to_local(ts):
    """ISO UTC stamp (sheet, candidate log) -> naive local datetime."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).astimezone().replace(tzinfo=None)
    except ValueError:
        return None


def cid_num(cid):
    m = re.match(r"C-(\d+)$", str(cid or "").strip())
    return int(m.group(1)) if m else None


# ----------------------------------------------------------------------------- burn logs

BURN_PATTERNS = [
    ("burn_start", re.compile(r"^=+ Night run (\d{4}-\d\d-\d\d) (\d\d:\d\d) \(mode burn\)")),
    ("night_done", re.compile(r"^=+ Night done")),
    ("launch", re.compile(r"^(New run|Resuming) (run-\d{8}-\d{4})")),
    ("pipeline_exit", re.compile(r"^pipeline\.sh --(run|resume) (run-\d{8}-\d{4}) exited (\d+) — ?(.*)")),
    ("run_stats", re.compile(r"^Committed: Burn run (run-\d{8}-\d{4}): (.*)")),
    ("round_done", re.compile(r"^Round (\d+) done \((run-\d{8}-\d{4})\)")),
    ("audit_start", re.compile(r"^Deep dive \((run-\d{8}-\d{4})\): researching")),
    ("audit_saved", re.compile(r"^Deep dive \((run-\d{8}-\d{4})\) saved: (.*)")),
    ("audit_nothing", re.compile(r"^Deep dive \((run-\d{8}-\d{4})\): no findings file")),
    ("audit_waits", re.compile(r"^Deep dive \((run-\d{8}-\d{4})\): Claude is out")),
    ("fix_waits", re.compile(r"^Fix session: Claude is out")),
    ("fix_start", re.compile(r"^Fix session for: (.*)")),
    ("fix_revert", re.compile(r"^Fix session left uncommitted code changes — reverting: (.*)")),
    ("fix_committed", re.compile(r"^Fix session committed (\d+) change")),
    ("pause_start", re.compile(r"^Paused \(\.burn_pause\)")),
    ("pause_end", re.compile(r"^Pause lifted")),
    ("claude_out_start", re.compile(r"^Claude is out of credits")),
    ("claude_out_end", re.compile(r"^Claude answers again")),
    ("claude_session_end", re.compile(r"^Claude session ended \(exit (\d+)\): ?(.*)")),
    ("retry_wait", re.compile(r"^Stopped \((.*)\) — trying again in (\d+) min \((\d+) of (\d+)\)")),
    ("gave_up", re.compile(r"^Run stopped (\d+) times in a row: (.*)")),
    ("zb_refused", re.compile(r"^ZeroBounce NOT usable: (.*)")),
    ("zb_ok", re.compile(r"^ZeroBounce OK \(balance (\d+)\)")),
    ("apollo_left", re.compile(r"^Apollo credits left: (\d+) \(stop below (\d+)\)")),
    ("lock", re.compile(r"^Another night run is going")),
    ("burn_over", re.compile(r"^Out of (\w+) credits — the burn is over")),
    ("rounds_begin", re.compile(r"^Burn: rounds of (\d+)")),
    ("pool_repair", re.compile(r"^Pool repair: (.*)")),
]


def parse_burn_logs():
    """Every timestamped line of every burn log, dated. The logs only print HH:MM:SS: the
    date starts from the file name and moves on a day each time the clock goes backwards
    (checked: inside these logs the clock never steps back otherwise); 'Night run
    YYYY-MM-DD' headers and 'New run run-YYYYMMDD-HHMM' lines re-set it."""
    events, sessions = [], []
    for path in sorted(glob.glob(os.path.join(RUNS, "burn-*.log"))):
        m = re.search(r"burn-(\d{8})-(\d{4})\.log$", path)
        if not m:
            continue
        day = datetime.strptime(m.group(1), "%Y%m%d").date()
        prev_t = None
        sess = {"file": rel(path), "started": None, "ended": None, "reached_rounds": False,
                "rounds_launched": [], "last_timestamped_line": None, "last_raw_line": None}
        with open(path, errors="replace") as f:
            for n, raw in enumerate(f, 1):
                line = raw.rstrip("\n")
                if line.strip():
                    sess["last_raw_line"] = scrub(line.strip()[:300])
                mt = re.match(r"\[(\d\d):(\d\d):(\d\d)\] (.*)", line)
                if not mt:
                    continue
                t = (int(mt.group(1)), int(mt.group(2)), int(mt.group(3)))
                text = mt.group(4)
                if prev_t is not None and t < prev_t:
                    day += timedelta(days=1)
                prev_t = t
                hd = BURN_PATTERNS[0][1].match(text)
                if hd:
                    day = datetime.strptime(hd.group(1), "%Y-%m-%d").date()
                nr = re.match(r"New run run-(\d{8})-(\d\d)(\d\d)", text)
                if nr and (int(nr.group(2)), int(nr.group(3))) == t[:2]:
                    day = datetime.strptime(nr.group(1), "%Y%m%d").date()
                dt = datetime(day.year, day.month, day.day, *t)
                ev = {"dt": dt, "file": rel(path), "line_no": n, "text": text, "kind": "other", "m": None}
                for kind, rx in BURN_PATTERNS:
                    mm = rx.match(text)
                    if mm:
                        ev["kind"], ev["m"] = kind, mm
                        break
                events.append(ev)
                sess["started"] = sess["started"] or dt
                sess["ended"] = dt
                sess["last_timestamped_line"] = scrub(text[:300])
                if ev["kind"] == "rounds_begin":
                    sess["reached_rounds"] = True
                if ev["kind"] == "launch" and ev["m"].group(2) not in sess["rounds_launched"]:
                    sess["rounds_launched"].append(ev["m"].group(2))
        if sess["started"]:
            sessions.append(sess)
    events.sort(key=lambda e: (e["dt"], e["file"], e["line_no"]))
    sessions.sort(key=lambda s: s["started"])
    return events, sessions


def src_line(ev):
    return {"file": ev["file"], "line_no": ev["line_no"],
            "line": scrub("[%s] %s" % (ev["dt"].strftime("%H:%M:%S"), ev["text"][:400]))}


# ------------------------------------------------------------------------------ run logs

def load_plan(run_id):
    pdir = os.path.join(RUNS, "plans", f"plan-{run_id}")
    try:
        plan = json.load(open(os.path.join(pdir, "plan.json")))
    except (OSError, ValueError):
        return None, {}
    venues = {}
    for b in plan.get("batches") or []:
        p = os.path.join(pdir, "batch_%02d.json" % int(b.get("index") or 0))
        try:
            for v in json.load(open(p)):
                vid = str((v or {}).get("venue_id") or "").strip()
                if vid:
                    venues[vid] = dict(v, _plan_batch=b.get("index"))
        except (OSError, ValueError):
            continue
    return plan, venues


def load_batches(run_id):
    """venue_id -> batch entry (+ _batch number), in run order, from the saved batch files."""
    out = {}
    files = glob.glob(os.path.join(RUNS, f"{run_id}.batch*.json"))
    files = sorted(files, key=lambda p: int(re.search(r"\.batch(\d+)\.json$", p).group(1)))
    for p in files:
        n = int(re.search(r"\.batch(\d+)\.json$", p).group(1))
        try:
            for v in json.load(open(p)):
                vid = str((v or {}).get("venue_id") or "").strip()
                if vid and vid not in out:
                    out[vid] = dict(v, _batch=n)
        except (OSError, ValueError):
            continue
    return out


def parse_run_log(run_id, vids):
    """One pass over the run log. Lines carry no date except 'Started: YYYY-MM-DD HH:MM:SS';
    DONE lines and the postcheck's [HH:MM:SS] lines are dated from the last such line."""
    path = os.path.join(RUNS, f"{run_id}.log")
    res = {"venues": {}, "apollo_obs": [], "zb_obs": [], "batches": {}, "counts": Counter(),
           "step_tally": Counter(), "events": [], "first_started": None, "last_done": None,
           "zb_reasons": Counter(), "exists": os.path.exists(path)}
    if not res["exists"]:
        return res
    vid_alt = "|".join(re.escape(v) for v in sorted(vids, key=len, reverse=True)) or r"\S+"
    step_rx = re.compile(r"\[STEP\] (%s|\S+) (%s) (\w+)(.*)$" % (vid_alt, "|".join(STEPS)))
    cur_dt, cur_vid, cur_batch = None, None, None
    pending = []          # observations waiting for the next dated line

    def stamp(dt):
        nonlocal cur_dt
        cur_dt = dt
        for o in pending:
            o["dt"] = dt
        del pending[:]

    def clock(h, m, s):
        if cur_dt is None:
            return None
        cand = cur_dt.replace(hour=h, minute=m, second=s)
        if cand < cur_dt - timedelta(seconds=60):
            cand += timedelta(days=1)
        return cand

    def batch(n):
        return res["batches"].setdefault(n, {"batch": n, "venue_ids": [], "to_run": [], "dt": None,
                                             "apollo_balance_at_start": [], "counter_last_line": None,
                                             "step_credits": 0, "postcheck_apollo_credits": 0})

    with open(path, errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            mt = re.match(r"\[(\d\d):(\d\d):(\d\d)\]\s?(.*)", line)
            body = line
            if mt:
                dt = clock(int(mt.group(1)), int(mt.group(2)), int(mt.group(3)))
                if dt:
                    stamp(dt)
                body = mt.group(4)
            s = body.strip()
            m = re.match(r"Started: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", s)
            if m:
                dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                stamp(dt)
                res["first_started"] = res["first_started"] or dt
                if cur_vid:
                    v = res["venues"].setdefault(cur_vid, {"steps": {}, "runs_in_log": 0})
                    v["started"] = dt
                    v["runs_in_log"] += 1
                    v["steps"] = {}
                    v.pop("done", None)
                    v.pop("minutes", None)
                if cur_batch and batch(cur_batch)["dt"] is None:
                    batch(cur_batch)["dt"] = dt
                continue
            m = re.match(r"PIPELINE: (.*) \(([^()]+)\)\s*$", s)
            if m:
                cur_vid = m.group(2).strip()
                continue
            m = re.match(r"DONE: (.*) \| (\d+) min \| (\d\d):(\d\d):(\d\d)", s)
            if m:
                dt = clock(int(m.group(3)), int(m.group(4)), int(m.group(5)))
                if dt:
                    stamp(dt)
                    res["last_done"] = dt
                if cur_vid and cur_vid in res["venues"]:
                    res["venues"][cur_vid]["done"] = dt
                    res["venues"][cur_vid]["minutes"] = int(m.group(2))
                continue
            m = step_rx.search(body)
            if m:
                vid, step, status, tail = m.group(1), m.group(2), m.group(3), m.group(4)
                kv = dict(re.findall(r"(\w+)=(\S+)", tail))
                res["step_tally"][f"{step}:{status}"] += 1
                v = res["venues"].setdefault(vid, {"steps": {}, "runs_in_log": 0})
                v["steps"][step] = {"status": status, "kv": kv, "line_no": n}
                if step in ("apollo", "linkedin"):
                    try:
                        if cur_batch:
                            batch(cur_batch)["step_credits"] += int(kv.get("credits", 0))
                    except ValueError:
                        pass
                if status in ("failed", "blocked") and step != "postcheck":
                    res["events"].append({"kind": f"step_{status}", "step": step, "venue_id": vid,
                                          "reason": kv.get("reason", ""), "line_no": n, "dt": cur_dt,
                                          "line": scrub(body.strip()[:300])})
                    pending.append(res["events"][-1]) if cur_dt is None else None
                continue
            m = re.match(r"\[RUN\] (run-\d{8}-\d{4}) batch (\d+): (.+?) \((\d+) to run", s)
            if m:
                cur_batch = int(m.group(2))
                b = batch(cur_batch)
                b["venue_ids"] = m.group(3).split(",")
                b["to_run"].append(int(m.group(4)))
                continue
            m = re.match(r"\[RUN\] Apollo credits left on the account: (\d+) \(stop below (\d+)\)", s)
            if m:
                o = {"balance": int(m.group(1)), "floor": int(m.group(2)), "batch": cur_batch,
                     "line_no": n, "dt": None, "run_id": run_id}
                res["apollo_obs"].append(o)
                pending.append(o)
                if cur_batch:
                    batch(cur_batch)["apollo_balance_at_start"].append(o)
                continue
            m = re.match(r"\[APOLLO\] Credits used this run: (\d+) / (\d+)", s)
            if m:
                if cur_batch:
                    batch(cur_batch)["counter_last_line"] = int(m.group(1))
                continue
            m = re.match(r"PREFLIGHT OK: ZeroBounce: .*?balance=(\d+)", s)
            if m:
                o = {"balance": int(m.group(1)), "line_no": n, "dt": None, "kind": "preflight"}
                res["zb_obs"].append(o)
                pending.append(o)
                continue
            m = re.match(r"\[ZB SAFE\] run (\d+)/(\d+), today (\d+)/(\d+), balance (\d+), reserve (\d+)", s)
            if m:
                o = {"balance": int(m.group(5)), "line_no": n, "dt": cur_dt, "kind": "zb_safe"}
                res["zb_obs"].append(o)
                if cur_dt is None:
                    pending.append(o)
                continue
            if "[ZB SAFE]" in s and "charged=True" in s:
                res["counts"]["zb_charged_lines"] += 1
                continue
            m = re.search(r"\[DEFERRED\] \S+ — ZeroBounce (\S+);", s)
            if m:
                res["counts"]["zb_deferred_saved_unverified"] += 1
                res["zb_reasons"][m.group(1)] += 1
                continue
            m = re.search(r"\| Apollo credits: (\d+) \|", s)
            if m and s.startswith("Venues:"):
                if cur_batch:
                    batch(cur_batch)["postcheck_apollo_credits"] += int(m.group(1))
                continue
            for kind, rx in (("run_stopped", r"\[RUN\] STOPPED: (.*)"),
                             ("run_aborted", r"\[RUN\] ABORTED (.*)"),
                             ("preflight_fail", r"PREFLIGHT FAIL: (?!\d+ check)(.*)"),
                             ("linkedin_wall", r"\[LINKEDIN WALL\] (.*)"),
                             ("google_blocked", r"\[GOOGLE BLOCKED\] ?(.*)"),
                             ("api_error", r"\[API ERROR\] (.*)"),
                             ("site_bot_wall", r"\[BLOCKED\] (.*)")):
                m = re.match(rx, s)
                if m:
                    res["counts"][kind] += 1
                    e = {"kind": kind, "what": scrub(m.group(1)[:220]), "venue_id": cur_vid,
                         "line_no": n, "dt": cur_dt, "line": scrub(s[:300])}
                    res["events"].append(e)
                    if kind == "preflight_fail" or cur_dt is None:
                        pending.append(e)      # dated by the next dated line
                    break
    for o in pending:                         # nothing dated came after
        o["dt"] = o.get("dt") or cur_dt
    return res


# ------------------------------------------------------------- candidate log, audit, sheet

def load_candidates(run_ids):
    """(run, venue, email) -> the pipeline's own save record (disposition saved_*), plus
    every other disposition per (venue, email) for tracing rows the log says failed."""
    saves, trace, dup = {}, defaultdict(list), 0
    path = os.path.join(REPORTS, "discovery-candidates.jsonl")
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if '"run-' not in line:
                    continue
                try:
                    c = json.loads(line)
                except ValueError:
                    continue
                rid = c.get("run_id")
                if rid not in run_ids or not c.get("email") or "@" not in str(c.get("email")):
                    continue
                key = (rid, c.get("venue_id"), norm_email(c.get("email")))
                disp = str(c.get("disposition") or "")
                if disp.startswith("saved_"):
                    if key in saves:
                        dup += 1
                    else:
                        saves[key] = c
                else:
                    trace[key].append(c)
    except OSError:
        note("reports/discovery-candidates.jsonl could not be read: pipeline saves could not be listed.")
    if dup:
        note(f"{dup} repeated 'saved' lines in the candidate log for the same run, venue and address were counted once.")
    return saves, trace


def git_versions(path):
    """Every committed version of a file (oldest first), then the working copy if it differs."""
    out = []
    try:
        hashes = subprocess.run(["git", "-C", HERE, "log", "--format=%H", "--", rel(path)],
                                capture_output=True, text=True, timeout=60).stdout.split()
        for h in reversed(hashes):
            txt = subprocess.run(["git", "-C", HERE, "show", f"{h}:{rel(path)}"],
                                 capture_output=True, text=True, timeout=60).stdout
            try:
                out.append(json.loads(txt))
            except ValueError:
                continue
    except Exception as exc:                       # git missing: the working copy still counts
        note(f"git history of {rel(path)} could not be read ({type(exc).__name__}); only the current file was used.")
    try:
        cur = json.load(open(path))
        if not any(d.get("at") == cur.get("at") for d in out):
            out.append(cur)
    except (OSError, ValueError):
        pass
    seen, uniq = set(), []
    for d in out:
        if d.get("at") in seen:
            continue
        seen.add(d.get("at"))
        uniq.append(d)
    return uniq


def load_audit(run_id):
    """What night_save.py did for this round. The file is rewritten each time the audit
    runs again (a round audited in two parts), so every committed version is read."""
    path = os.path.join(RUNS, f"{run_id}.deepdive-saved.json")
    sessions, saved, flagged = [], {}, {}
    if not os.path.exists(path):
        return None
    src = {}
    try:
        for fv in (json.load(open(os.path.join(RUNS, f"{run_id}.deepdive.json"))).get("venues") or []):
            for c in fv.get("contacts") or []:
                src[(fv.get("venue_id"), norm_email(c.get("email")))] = str(c.get("source") or "")
    except (OSError, ValueError, AttributeError):
        pass
    for d in git_versions(path):
        if d.get("dry_run"):
            continue
        sessions.append({"at": (d.get("at") or "")[:19].replace("T", " "), "totals": d.get("totals") or {},
                         "zerobounce_out": d.get("zerobounce_out") or "",
                         "flagged_backup": rel(d["flagged_backup"]) if d.get("flagged_backup") else ""})
        for v in d.get("venues") or []:
            vid = v.get("venue_id")
            for c in v.get("contacts") or []:
                if c.get("outcome") == "saved" and c.get("email"):
                    saved[(vid, norm_email(c["email"]))] = dict(c, _at=d.get("at"),
                                                               _source=src.get((vid, norm_email(c["email"])), ""))
            for fl in v.get("flagged") or []:
                if fl.get("email"):
                    flagged[(vid, norm_email(fl["email"]))] = fl
    return {"sessions": sessions, "saved": saved, "flagged": flagged}


def load_cleanups():
    """Deleted-contact backups: (venue, email) / contact_id / email -> cleanup name."""
    by_key, by_cid, by_email, info, rows_by_key = {}, {}, {}, [], {}
    files = sorted(glob.glob(os.path.join(REPAIR, "cleanup-*contacts*.json")) +
                   glob.glob(os.path.join(REPAIR, "night-flagged-*.json")))
    for p in files:
        try:
            d = json.load(open(p))
        except (OSError, ValueError):
            note(f"{rel(p)} could not be read as JSON; its deletions are not counted.")
            continue
        rows = d.get("contacts") if isinstance(d, dict) else d
        if not isinstance(rows, list):
            continue
        name = os.path.basename(p)[:-5]
        deleted = [r for r in rows if isinstance(r, dict) and not r.get("keep")]
        kept = [r for r in rows if isinstance(r, dict) and r.get("keep")]
        md = re.search(r"(\d{8})", name)
        info.append({"cleanup": name, "file": rel(p),
                     "date_in_name": datetime.strptime(md.group(1), "%Y%m%d").strftime("%Y-%m-%d") if md else None,
                     "backup_file_written": fmt(datetime.fromtimestamp(os.path.getmtime(p))),
                     "rows_in_backup": len(rows), "rows_deleted": len(deleted), "rows_marked_keep": len(kept),
                     "by_venue": dict(Counter(str(r.get("venue_id") or "(no venue id in backup)") for r in deleted))})
        for r in deleted:
            e = norm_email(r.get("email"))
            if r.get("venue_id") and e:
                by_key[(r["venue_id"], e)] = name
                rows_by_key[(r["venue_id"], e)] = r
            if r.get("contact_id"):
                by_cid[str(r["contact_id"])] = name
            if e:
                by_email.setdefault(e, (name, r))
    return {"by_key": by_key, "by_cid": by_cid, "by_email": by_email, "info": info, "rows": rows_by_key}


def zb_usage():
    """Paid ZeroBounce checks per run id from the guard's own table (read-only)."""
    path = os.path.expanduser(os.environ.get("ZB_DB_PATH") or "~/.outreach/zerobounce_guard.sqlite3")
    try:
        conn = sqlite3.connect("file:" + urllib.parse.quote(path) + "?mode=ro", uri=True, timeout=10)
        rows = conn.execute("SELECT run_id, status, COUNT(*), MIN(used_at), MAX(used_at) FROM usage "
                            "GROUP BY run_id, status").fetchall()
        conn.close()
        out = {}
        for rid, status, n, first, last in rows:
            d = out.setdefault(rid, {"paid": 0, "first": first, "last": last, "by_status": {}})
            d["paid"] += int(n)
            d["by_status"][status] = int(n)
            d["first"], d["last"] = min(d["first"], first), max(d["last"], last)
        return out
    except Exception as exc:
        note(f"ZeroBounce guard table ({path}) could not be read ({type(exc).__name__}): exact paid checks per round are null.")
        return None


def env_value(key):
    try:
        with open(os.path.join(HERE, ".env"), errors="replace") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?%s=(.*)$" % re.escape(key), line.rstrip("\n"))
                if m:
                    return m.group(1).strip().strip("'\"")
    except OSError:
        pass
    return ""


def live_balances():
    out = {"apollo": None, "zerobounce": None, "read_at": fmt(datetime.now())}
    if os.environ.get("BURN_REPORT_NO_LIVE") == "1":
        note("Live balance reads were skipped (BURN_REPORT_NO_LIVE=1); 'now' uses the last logged values only.")
        return out
    key = env_value("APOLLO_API_KEY")
    if key:
        try:
            req = urllib.request.Request(
                "https://api.apollo.io/api/v1/users/api_profile?include_credit_usage=true",
                headers={"X-Api-Key": key, "Cache-Control": "no-cache", "User-Agent": "curl/8.4.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                out["apollo"] = int(json.loads(r.read().decode("utf-8", "replace")).get("num_credits_remaining"))
        except Exception as exc:
            note(f"Apollo's balance could not be read live ({type(exc).__name__}); 'now' is the last logged value.")
    key = env_value("ZEROBOUNCE_KEY")
    if key:
        try:
            url = "https://api.zerobounce.net/v2/getcredits?" + urllib.parse.urlencode({"api_key": key})
            with urllib.request.urlopen(url, timeout=30) as r:
                val = int(json.loads(r.read().decode("utf-8", "replace")).get("Credits"))
            if val >= 0:
                out["zerobounce"] = val
            else:
                note("ZeroBounce answered the live balance read with -1 (key refused); 'now' is the last logged value.")
        except Exception as exc:
            note(f"ZeroBounce's balance could not be read live ({type(exc).__name__}; it refuses any network but the "
                 "home IP); 'now' is the last logged value.")
    return out


# ------------------------------------------------------------------------------- labels

KIND = {"restaurant": "restaurant", "hotel": "hotel", "yacht_club": "club", "country_club": "club",
        "private_club": "club", "winery": "winery", "brewery": "winery", "wine_bar": "wine bar", "bar": "wine bar",
        "event_venue": "event venue", "event": "event venue", "concert_series": "event venue",
        "art_gallery": "gallery/museum", "museum": "gallery/museum", "senior_living": "senior living",
        "church": "church", "theater": "theater/music venue", "music_venue": "theater/music venue",
        "luxury_apts": "apartments"}


def kind_of(v):
    return KIND.get(str(v.get("classified_category") or "").strip()) or \
        KIND.get(str(v.get("category") or "").strip()) or "other"


def source_label(raw):
    r = str(raw or "").strip().lower()
    if r.startswith("night_"):
        return "audit (deep dive)"
    if r.startswith("postcheck"):
        return "postcheck"
    if "linkedin" in r:
        return "linkedin"
    if r.startswith("apollo"):
        return "apollo"
    if r.startswith("website") or r in ("curl website",):
        return "website"
    if r in ("social", "facebook", "instagram"):
        return "social"
    if r.startswith("google"):
        return "google"
    return "other"


# --------------------------------------------------------------------------------- main

def main():
    events, sessions = parse_burn_logs()
    if not events:
        print("no burn logs found in", RUNS, file=sys.stderr)
        return 1
    burn_start = min(s["started"] for s in sessions)
    run_ids = []
    for ev in events:
        if ev["kind"] == "launch" and ev["m"].group(2) not in run_ids:
            run_ids.append(ev["m"].group(2))
    run_ids.sort()
    burn_end_ev = next((e for e in events if e["kind"] == "burn_over"), None)
    last_ev = events[-1]["dt"]
    other_runs = []
    for p in glob.glob(os.path.join(RUNS, "run-*.log")):
        rid = os.path.basename(p)[:-4]
        m = re.match(r"run-(\d{8})-(\d{4})$", rid)
        if m and rid not in run_ids:
            dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M")
            if burn_start <= dt <= last_ev:
                other_runs.append(rid)
    if other_runs:
        note("Run logs inside the burn's dates that no burn log launched (left out): " + ", ".join(sorted(other_runs)))

    # ---- the live sheet (read-only: one dashboard GET, the call night_zero.py makes)
    import night_zero
    dash = night_zero.api({"action": "dashboard"})
    if dash.get("status") != "ok":
        print("dashboard read failed:", str(dash)[:200], file=sys.stderr)
        return 1
    sheet_venues = {v.get("venue_id"): v for v in dash.get("venues") or []}
    sheet_by_key, sheet_by_email, sheet_by_venue = {}, defaultdict(list), defaultdict(list)
    for c in dash.get("contacts") or []:
        e = norm_email(c.get("email"))
        sheet_by_key[(c.get("venue_id"), e)] = c
        if e:
            sheet_by_email[e].append(c)
        sheet_by_venue[c.get("venue_id")].append(c)

    cleanups = load_cleanups()
    cand_saves, cand_trace = load_candidates(set(run_ids))
    zb_db = zb_usage()
    live = live_balances()

    saves_by_rv = defaultdict(list)
    for (rid, vid, e), c in cand_saves.items():
        saves_by_rv[(rid, vid)].append((e, c))

    # ---- first pass: runs, their venues, audits
    runs, audits, logs, plans, batches_by_run = {}, {}, {}, {}, {}
    for rid in run_ids:
        plan, plan_venues = load_plan(rid)
        batch_venues = load_batches(rid)
        plans[rid] = (plan, plan_venues)
        batches_by_run[rid] = batch_venues
        logs[rid] = parse_run_log(rid, list(batch_venues) + list(plan_venues))
        audits[rid] = load_audit(rid)

    # contact ids at or after the first burn save = made during the burn
    burn_ids = []
    for (rid, vid, e) in cand_saves:
        row = sheet_by_key.get((vid, e))
        if row and cid_num(row.get("contact_id")) is not None:
            burn_ids.append(cid_num(row.get("contact_id")))
    for cid in cleanups["by_cid"]:
        if cid_num(cid) is not None:
            burn_ids.append(cid_num(cid))
    first_burn_cid = min(burn_ids) if burn_ids else None
    if first_burn_cid is None:
        note("No burn save could be matched to a sheet row, so contacts made before the burn could not be told apart by contact id.")

    def is_burn_row(row):
        n = cid_num(row.get("contact_id"))
        if first_burn_cid is not None and n is not None:
            return n >= first_burn_cid
        dt = utc_to_local(row.get("verified_date"))
        return bool(dt and dt >= burn_start)

    venues_out, people_all = [], []
    src_disagree = 0
    flagged_unmatched = Counter()
    seen_venue_runs = defaultdict(list)

    for rid in run_ids:
        plan, plan_venues = plans[rid]
        batch_venues = batches_by_run[rid]
        log = logs[rid]
        audit = audits[rid] or {"sessions": [], "saved": {}, "flagged": {}}
        order = list(batch_venues) + [v for v in plan_venues if v not in batch_venues]
        used_flags = set()
        for vid in order:
            b = batch_venues.get(vid) or plan_venues.get(vid) or {}
            in_batch = vid in batch_venues
            lv = log["venues"].get(vid) or {}
            steps = lv.get("steps") or {}
            final = steps.get("final")
            fin_status = final["status"] if final else None
            fin_reason = (final or {}).get("kv", {}).get("reason", "")
            finished = bool(final) and fin_status in ("ok", "empty", "failed") and fin_reason != "aborted"
            skipped = bool(final) and fin_status == "skipped"
            sv = sheet_venues.get(vid) or {}
            people, matched_rows = [], set()

            def add_person(email, saved_by, src_raw, name, title, verified_at_save, saved_at, evidence=""):
                nonlocal src_disagree
                row = sheet_by_key.get((vid, email))
                p = {"name": "", "title": "", "source": source_label(src_raw), "source_detail": src_raw,
                     "saved_by": saved_by, "verified": verified_at_save, "verified_when_saved": verified_at_save,
                     "still_on_sheet": False, "deleted_in": None, "contact_id": None,
                     "saved_at": fmt(saved_at), "emailed": None, "flagged_by_audit": False, "flag_reason": None}
                if evidence:
                    p["evidence"] = scrub(str(evidence)[:200])
                if row:
                    matched_rows.add(row.get("contact_id"))
                    p.update({"name": row.get("name") or "", "title": row.get("title") or "",
                              "verified": str(row.get("verified") or ""), "still_on_sheet": True,
                              "contact_id": row.get("contact_id"),
                              "emailed": row.get("email_sent") not in (False, None, "", "false", "False"),
                              "source_on_sheet": row.get("source") or ""})
                    if source_label(row.get("source")) != p["source"]:
                        src_disagree += 1
                else:
                    cname = cleanups["by_key"].get((vid, email))
                    crow = cleanups["rows"].get((vid, email))
                    if not cname and email in cleanups["by_email"] and email not in sheet_by_email:
                        cname, crow = cleanups["by_email"][email]
                    if cname:
                        p.update({"deleted_in": cname, "name": (crow or {}).get("name") or name or "",
                                  "title": (crow or {}).get("title") or title or "",
                                  "contact_id": (crow or {}).get("contact_id")})
                        if (crow or {}).get("verified"):
                            p["verified"] = str(crow["verified"])
                    elif email in sheet_by_email:
                        other = sheet_by_email[email][0]
                        p.update({"name": other.get("name") or name or "", "title": other.get("title") or title or "",
                                  "still_on_sheet": True, "on_sheet_under_venue": other.get("venue_id"),
                                  "verified": str(other.get("verified") or ""), "contact_id": other.get("contact_id")})
                    else:
                        p.update({"name": name or "", "title": title or "",
                                  "deleted_in": "unknown (not on the sheet and in no cleanup backup)"})
                p["has_name"] = bool(str(p["name"]).strip())
                fl = audit["flagged"].get((vid, email))
                if fl:
                    used_flags.add((vid, email))
                    p["flagged_by_audit"] = True
                    p["flag_reason"] = scrub(str(fl.get("reason") or "")[:400])
                    if fl.get("outcome"):
                        p["flag_outcome"] = fl["outcome"]
                people.append(p)
                return p

            for email, c in sorted(saves_by_rv.get((rid, vid), []), key=lambda x: x[1].get("timestamp") or ""):
                add_person(email, "pipeline", str(c.get("source") or ""), c.get("name"), c.get("title"),
                           str(c.get("disposition") or "")[6:], utc_to_local(c.get("timestamp")))
            for (avid, email), c in sorted(audit["saved"].items(), key=lambda x: x[1].get("_at") or ""):
                if avid != vid:
                    continue
                row = sheet_by_key.get((vid, email))
                raw = (row or {}).get("source") or ("night_" + (c.get("_source") or
                                                                ("apollo" if str(c.get("source_url")).startswith("apollo") else "deepdive")))
                at = None
                try:
                    at = datetime.fromisoformat(c.get("_at")).replace(tzinfo=None)
                except (TypeError, ValueError):
                    pass
                add_person(email, "audit (deep dive)", raw, c.get("name"), c.get("title"),
                           str(c.get("verified") or ""), at, c.get("source_url"))
            before_burn = 0
            for row in sheet_by_venue.get(vid, []):
                if row.get("contact_id") in matched_rows:
                    continue
                if not is_burn_row(row):
                    before_burn += 1
                    continue
                if seen_venue_runs.get(vid) and rid != seen_venue_runs[vid][-1] and not in_batch:
                    continue
                if not in_batch:
                    continue        # a planned-only entry never owns sheet rows
                email = norm_email(row.get("email"))
                tr = cand_trace.get((rid, vid, email)) or []
                failed = [t for t in tr if str(t.get("disposition") or "").startswith(("api_save_failed", "api_readback_failed"))]
                if failed:
                    add_person(email, "pipeline (the log recorded the save as failed, but the row is on the sheet)",
                               str(failed[0].get("source") or row.get("source") or ""), row.get("name"), row.get("title"),
                               str(row.get("verified") or ""), utc_to_local(failed[0].get("timestamp")))
                else:
                    add_person(email, "other (on the sheet since the burn began, in no run log or audit file)",
                               str(row.get("source") or ""), row.get("name"), row.get("title"),
                               str(row.get("verified") or ""), utc_to_local(row.get("verified_date")))
            if in_batch:
                seen_venue_runs[vid].append(rid)

            now_rows = sheet_by_venue.get(vid, []) if in_batch else []
            sendable_now = sum(1 for r in now_rows if r.get("email") and str(r.get("verified", "")).strip().lower() in SENDABLE)
            if not in_batch or not (finished or skipped):
                outcome = "not reached"
            elif skipped:
                outcome = "skipped"
            else:
                outcome = "contacts" if sendable_now > 0 else "zero"
            step_view = {}
            for st in STEPS:
                if st in steps:
                    kv = steps[st]["kv"]
                    d = {"status": steps[st]["status"]}
                    for k in ("saved", "role", "unverified", "credits", "reason", "new", "enriched"):
                        if k in kv:
                            try:
                                d[k] = int(kv[k])
                            except ValueError:
                                d[k] = kv[k]
                    step_view[st] = d
            entry = {
                "run_id": rid, "venue_id": vid, "name": b.get("name") or sv.get("name"),
                "kind": kind_of(b), "batch_bucket": b.get("batch_bucket"),
                "classified_category": b.get("classified_category"), "category": b.get("category"),
                "city": b.get("city"), "state": b.get("state"), "website": b.get("website"),
                "taste_score": b.get("taste_score"), "upscale_score": b.get("upscale_score"),
                "batch": b.get("_batch") if in_batch else None,
                "in_a_started_batch": in_batch,
                "finished": finished, "outcome": outcome,
                "outcome_when_run": ("not reached" if outcome == "not reached" else "skipped" if skipped
                                     else "contacts" if people else "zero"),
                "pipeline_result": fin_status, "pipeline_result_reason": fin_reason or None,
                "started": fmt(lv.get("started")), "done": fmt(lv.get("done")), "minutes": lv.get("minutes"),
                "times_started_in_log": lv.get("runs_in_log") or 0,
                "steps": step_view,
                "status_on_sheet_now": sv.get("status"),
                "contacts_saved_in_burn": len(people),
                "contacts_on_sheet_now": len(now_rows),
                "sendable_on_sheet_now": sendable_now,
                "contacts_from_before_burn": before_burn,
                "people": people,
            }
            venues_out.append(entry)
            for p in people:
                people_all.append((rid, vid, entry["kind"], p))
        for key in audit["flagged"]:
            if key not in used_flags:
                flagged_unmatched[rid] += 1

    # ---- runs
    launches = [e for e in events if e["kind"] == "launch"]
    exits = [e for e in events if e["kind"] == "pipeline_exit"]
    segs_by_run = defaultdict(list)
    for i, la in enumerate(launches):
        rid = la["m"].group(2)
        nxt = launches[i + 1]["dt"] if i + 1 < len(launches) else None
        ex = next((x for x in exits if x["m"].group(2) == rid and x["dt"] >= la["dt"] and x["file"] == la["file"]
                   and (nxt is None or x["dt"] <= nxt) and x["line_no"] > la["line_no"]), None)
        seg = {"launch": la, "exit": ex, "run_id": rid,
               "ran_s": (ex["dt"] - la["dt"]).total_seconds() if ex else None,
               "code": int(ex["m"].group(3)) if ex else None,
               "message": scrub(ex["m"].group(4).strip()) if ex else None}
        seg["real"] = ex is None or seg["code"] == 0 or seg["ran_s"] >= 120
        segs_by_run[rid].append(seg)
    all_segs = sorted((s for v in segs_by_run.values() for s in v), key=lambda s: s["launch"]["dt"])

    audit_windows = []        # (run, start, end) of each audit session, from the burn log
    open_audit = {}
    for e in events:
        if e["kind"] == "audit_start":
            open_audit[e["m"].group(1)] = e
        elif e["kind"] in ("audit_saved", "audit_nothing") and e["m"].group(1) in open_audit:
            st = open_audit.pop(e["m"].group(1))
            audit_windows.append({"run_id": e["m"].group(1), "start": st["dt"], "end": e["dt"],
                                  "result": scrub(e["text"][:200]),
                                  "totals": dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", e["m"].group(2)))
                                  if e["kind"] == "audit_saved" else None})
    for rid_open, st in open_audit.items():
        audit_windows.append({"run_id": rid_open, "start": st["dt"], "end": None,
                              "result": "no 'saved' line in the burn log yet", "totals": None})

    apollo_tl, zb_tl = [], []
    for e in events:
        if e["kind"] == "apollo_left":
            apollo_tl.append({"dt": e["dt"], "balance": int(e["m"].group(1)), "floor": int(e["m"].group(2)),
                              "source": "%s:%d" % (e["file"], e["line_no"]), "run_id": None, "batch": None})
        elif e["kind"] == "zb_ok":
            zb_tl.append({"dt": e["dt"], "balance": int(e["m"].group(1)),
                          "source": "%s:%d" % (e["file"], e["line_no"]), "run_id": None})
    for rid in run_ids:
        lf = rel(os.path.join(RUNS, rid + ".log"))
        fallback = segs_by_run[rid][0]["launch"]["dt"] if segs_by_run.get(rid) else None
        for o in logs[rid]["apollo_obs"]:
            apollo_tl.append({"dt": o["dt"] or fallback, "balance": o["balance"], "floor": o["floor"],
                              "source": "%s:%d" % (lf, o["line_no"]), "run_id": rid, "batch": o["batch"]})
        for o in logs[rid]["zb_obs"]:
            zb_tl.append({"dt": o["dt"] or fallback, "balance": o["balance"],
                          "source": "%s:%d" % (lf, o["line_no"]), "run_id": rid})
    try:
        _al = (json.load(open(os.path.join(HERE, "night_status.json"))).get("alert") or {})
        _m = re.search(r"Apollo has (\d+) credits? left \(the floor is (\d+)\)", str(_al.get("detail") or ""))
        if _al.get("kind") == "apollo" and _m and _al.get("since"):
            apollo_tl.append({"dt": datetime.fromisoformat(_al["since"]).replace(tzinfo=None), "balance": int(_m.group(1)),
                              "floor": int(_m.group(2)), "source": "night_status.json (the app alert's text)",
                              "run_id": None, "batch": None})
    except (OSError, ValueError):
        pass
    apollo_tl.sort(key=lambda o: (o["dt"] or burn_start, o["source"]))
    zb_tl.sort(key=lambda o: (o["dt"] or burn_start, o["source"]))

    def overlap_audits(a, b):
        return sorted({w["run_id"] for w in audit_windows
                       if a and w["start"] < (b or datetime.max) and (w["end"] or datetime.max) > a})

    runs_out, credits_rounds_apollo, credits_rounds_zb = [], [], []
    venues_by_run = defaultdict(list)
    for v in venues_out:
        venues_by_run[v["run_id"]].append(v)
    for rid in run_ids:
        plan, plan_venues = plans[rid]
        log = logs[rid]
        audit = audits[rid]
        segs = segs_by_run.get(rid, [])
        vs = venues_by_run[rid]
        in_batches = [v for v in vs if v["in_a_started_batch"]]
        finished = [v for v in in_batches if v["finished"]]
        ppl = [p for v in vs for p in v["people"]]
        pipe = [p for p in ppl if p["saved_by"].startswith("pipeline")]
        aud = [p for p in ppl if p["saved_by"].startswith("audit")]
        oth = [p for p in ppl if p["saved_by"].startswith("other")]
        last_exit = next((s for s in reversed(segs) if s["exit"]), None)
        stopped_file = None
        try:
            stopped_file = scrub(open(os.path.join(RUNS, rid + ".stopped"), errors="replace").read().strip())
        except OSError:
            pass
        stats_ev = [e for e in events if e["kind"] == "run_stats" and e["m"].group(1) == rid]
        burn_stats = None
        if stats_ev:
            kvs = dict(re.findall(r"(\w+)=(\d+)", stats_ev[-1]["m"].group(2)))
            burn_stats = {k: int(v) for k, v in kvs.items()} or {"text": scrub(stats_ev[-1]["m"].group(2))}
        sess = [w for w in audit_windows if w["run_id"] == rid]
        audit_tot = Counter()
        for w in sess:
            for k, v in (w["totals"] or {}).items():
                audit_tot[k] += v
        a_obs = [o for o in apollo_tl if o["run_id"] == rid]
        z_obs = [o for o in zb_tl if o["run_id"] == rid]
        run_end = last_exit["exit"]["dt"] if last_exit else None
        a_after = next((o for o in apollo_tl if a_obs and o["dt"] and run_end and o["dt"] >= run_end
                        and o is not a_obs[-1] and o["run_id"] != rid), None)
        z_after = next((o for o in zb_tl if o["dt"] and run_end and o["dt"] >= run_end and o["run_id"] != rid), None)
        deleted_by = Counter(p["deleted_in"] for p in ppl if p["deleted_in"])
        zb_pipe = (zb_db or {}).get(rid, {}).get("paid") if zb_db is not None else None
        zb_aud = (zb_db or {}).get("night-" + rid, {}).get("paid") if zb_db is not None else None
        if zb_db is not None:
            zb_pipe, zb_aud = zb_pipe or 0, zb_aud or 0
        interruptions = []
        for s in segs:
            if s["exit"] and s["code"] != 0:
                interruptions.append({"at": fmt(s["exit"]["dt"]), "exit_code": s["code"],
                                      "message": s["message"] or None, "launched": fmt(s["launch"]["dt"])})
        stopped_reason = None
        if last_exit and last_exit["code"] != 0:
            stopped_reason = re.sub(r"^\[RUN\] STOPPED: ", "", last_exit["message"] or "") or (
                "pipeline.sh exited %d with no message in the burn log" % last_exit["code"])
        r = {
            "run_id": rid,
            "started": fmt(segs[0]["launch"]["dt"]) if segs else None,
            "started_date": segs[0]["launch"]["dt"].strftime("%Y-%m-%d") if segs else None,
            "started_time": segs[0]["launch"]["dt"].strftime("%H:%M") if segs else None,
            "ended": fmt(run_end),
            "ended_date": run_end.strftime("%Y-%m-%d") if run_end else None,
            "ended_time": run_end.strftime("%H:%M") if run_end else None,
            "first_venue_started": fmt(log["first_started"]), "last_venue_done": fmt(log["last_done"]),
            "pipeline_minutes_running": round(sum(s["ran_s"] or 0 for s in segs) / 60, 1) if segs else None,
            "launches": [{"how": s["launch"]["m"].group(1), "at": fmt(s["launch"]["dt"]),
                          "exited": fmt(s["exit"]["dt"]) if s["exit"] else None, "exit_code": s["code"],
                          "message": s["message"] or None} for s in segs],
            "venues_planned": (plan or {}).get("selected"),
            "venues_in_started_batches": len(in_batches),
            "venues_finished": len(finished),
            "venues_skipped": sum(1 for v in in_batches if v["outcome"] == "skipped"),
            "venues_not_reached": sum(1 for v in vs if v["outcome"] == "not reached"),
            "venues_with_contacts_now": sum(1 for v in finished if v["outcome"] == "contacts"),
            "venues_zero_now": sum(1 for v in finished if v["outcome"] == "zero"),
            "venues_with_contacts_when_run": sum(1 for v in finished if v["outcome_when_run"] == "contacts"),
            "stopped_reason": stopped_reason,
            "venue_kinds": dict(Counter(v["kind"] for v in in_batches)),
            "stopped_file": stopped_file,
            "interruptions": interruptions,
            "apollo_balance_at_start": a_obs[0]["balance"] if a_obs else None,
            "apollo_balance_at_end": a_after["balance"] if a_after else None,
            "apollo_balance_at_end_read": ({"at": fmt(a_after["dt"]), "source": a_after["source"]} if a_after else None),
            "zerobounce_balance_at_start": z_obs[0]["balance"] if z_obs else None,
            "zerobounce_balance_at_end": z_obs[-1]["balance"] if z_obs else None,
            "zerobounce_balance_next_read": ({"balance": z_after["balance"], "at": fmt(z_after["dt"]),
                                             "source": z_after["source"]} if z_after else None),
            "contacts_saved_by_pipeline": len(pipe),
            "contacts_saved_by_pipeline_by_status": dict(Counter(p["verified_when_saved"] for p in pipe)),
            "contacts_saved_by_audit": len(aud) if audit is not None else None,
            "contacts_saved_other": len(oth),
            "contacts_saved_total": len(ppl),
            "contacts_still_on_sheet": sum(1 for p in ppl if p["still_on_sheet"]),
            "contacts_flagged_by_audit": (audit_tot.get("flagged") if sess and any(w["totals"] for w in sess) else None),
            "contacts_flagged_distinct": len(audit["flagged"]) if audit is not None else None,
            "contacts_flagged_matched_to_burn_people": sum(1 for p in ppl if p["flagged_by_audit"]),
            "contacts_deleted_by_audit": (audit_tot.get("deleted", 0) if sess and any(w["totals"] for w in sess) else None),
            "contacts_deleted_in_cleanups": dict(deleted_by),
            "contacts_deleted_total": sum(deleted_by.values()),
            "audit_sessions": [{"started": fmt(w["start"]), "ended": fmt(w["end"]), "minutes": mins(w["start"], w["end"]),
                                "result": w["result"], "totals": w["totals"]} for w in sess],
            "audit_saved_file_versions": [s_ for s_ in (audit or {}).get("sessions", [])],
            "burn_log_stats": burn_stats,
            "step_results": dict(sorted(log["step_tally"].items())),
            "log_counts": dict(log["counts"]),
            "zerobounce_deferred_reasons": dict(log["zb_reasons"]),
        }
        if burn_stats and burn_stats.get("new_contacts") is not None and burn_stats["new_contacts"] != len(pipe):
            note(f"{rid}: the burn log's last stat line says new_contacts={burn_stats['new_contacts']}; this file counts "
                 f"{len(pipe)} pipeline saves for the round (candidate-log save records, plus rows the log recorded as "
                 "a failed save that are on the sheet). The stat line adds up the 'new=' of each venue's final step; "
                 "the per-address count is used here.")
        if audit is None:
            r["audit_note"] = "no deepdive-saved.json for this round (the audit has not saved, or never ran)"
        runs_out.append(r)

        # credits per round
        per_batch = []
        bnums = sorted(log["batches"])
        for i, bn in enumerate(bnums):
            b = log["batches"][bn]
            obs = b["apollo_balance_at_start"]
            first = obs[0] if obs else None
            idx = apollo_tl.index(next(o for o in apollo_tl if first and o["source"].endswith(":%d" % first["line_no"])
                                       and o["run_id"] == rid)) if first else None
            # a resumed batch reads the balance again: the next read is the first one with another batch or run
            nxt = None
            if idx is not None:
                nxt = next((o for o in apollo_tl[idx + 1:] if not (o["run_id"] == rid and o["batch"] == bn)), None)
            same_run_next = bool(nxt and nxt["run_id"] == rid)
            per_batch.append({
                "batch": bn, "venues": len(b["venue_ids"]), "started": fmt(b["dt"]),
                "apollo_balance_at_start": first["balance"] if first else None,
                "balance_reads_in_batch": [o["balance"] for o in obs],
                "next_balance_read": ({"balance": nxt["balance"], "at": fmt(nxt["dt"]), "source": nxt["source"],
                                       "is_next_batch_of_same_round": same_run_next} if nxt else None),
                "balance_drop_to_next_read": (first["balance"] - nxt["balance"]) if first and nxt else None,
                "pipeline_counter_last_line": b["counter_last_line"],
                "pipeline_step_credits": b["step_credits"] + b["postcheck_apollo_credits"],
                "audit_sessions_running_meanwhile": overlap_audits(b["dt"], nxt["dt"] if nxt else None) if b["dt"] else None,
            })
        drop = (a_obs[0]["balance"] - a_after["balance"]) if a_obs and a_after else None
        credits_rounds_apollo.append({
            "run_id": rid,
            "balance_at_start": a_obs[0]["balance"] if a_obs else None,
            "balance_at_start_read": fmt(a_obs[0]["dt"]) if a_obs else None,
            "balance_at_end": a_after["balance"] if a_after else None,
            "balance_at_end_read": fmt(a_after["dt"]) if a_after else None,
            "balance_at_end_source": a_after["source"] if a_after else None,
            "account_balance_drop": drop,
            "pipeline_counter_last_lines_summed": (sum(b["counter_last_line"] or 0 for b in log["batches"].values())
                                                   if log["batches"] else None),
            "pipeline_step_credits_summed": (sum(b["step_credits"] + b["postcheck_apollo_credits"]
                                                 for b in log["batches"].values()) if log["batches"] else None),
            "batches": per_batch,
        })
        credits_rounds_zb.append({
            "run_id": rid,
            "balance_at_start": z_obs[0]["balance"] if z_obs else None,
            "balance_at_end_last_line_of_round": z_obs[-1]["balance"] if z_obs else None,
            "balance_next_read": z_after["balance"] if z_after else None,
            "balance_next_read_at": fmt(z_after["dt"]) if z_after else None,
            "paid_checks_pipeline": zb_pipe, "paid_checks_audit": zb_aud,
            "paid_checks_by_result": ({k: (zb_db.get(rid, {}).get("by_status", {}).get(k, 0) +
                                           zb_db.get("night-" + rid, {}).get("by_status", {}).get(k, 0))
                                       for k in sorted(set(zb_db.get(rid, {}).get("by_status", {})) |
                                                       set(zb_db.get("night-" + rid, {}).get("by_status", {})))}
                                      if zb_db is not None else None),
            "paid_lines_in_run_log": log["counts"].get("zb_charged_lines", 0) if log["exists"] else None,
            "saved_unverified_because_zerobounce_deferred": log["counts"].get("zb_deferred_saved_unverified", 0),
        })

    # ---- totals
    in_batches = [v for v in venues_out if v["in_a_started_batch"]]
    finished = [v for v in in_batches if v["finished"]]
    all_p = [p for (_, _, _, p) in people_all]
    on_sheet = [p for p in all_p if p["still_on_sheet"]]
    by_kind = {}
    for k in sorted({v["kind"] for v in in_batches}):
        vk = [v for v in finished if v["kind"] == k]
        pk = [p for v in vk for p in v["people"]]
        by_kind[k] = {
            "venues_finished": len(vk),
            "venues_in_started_batches": sum(1 for v in in_batches if v["kind"] == k),
            "venues_with_contacts_now": sum(1 for v in vk if v["outcome"] == "contacts"),
            "venues_with_contacts_when_run": sum(1 for v in vk if v["outcome_when_run"] == "contacts"),
            "contacts_saved_during_burn": len(pk),
            "contacts_still_on_sheet": sum(1 for p in pk if p["still_on_sheet"]),
            "contacts_deleted": sum(1 for p in pk if p["deleted_in"]),
            "contacts_now_per_finished_venue": round(sum(1 for p in pk if p["still_on_sheet"]) / len(vk), 2) if vk else None,
        }
    unique_finished = {v["venue_id"] for v in finished}
    extra_rows = [c for c in dash.get("contacts") or [] if is_burn_row(c)
                  and c.get("venue_id") not in {v["venue_id"] for v in in_batches}]
    totals = {
        "rounds": len(run_ids),
        "rounds_that_ran_at_least_one_venue": sum(1 for r in runs_out if r["venues_finished"] > 0),
        "venues_planned": sum(r["venues_planned"] or 0 for r in runs_out),
        "venues_in_started_batches": len(in_batches),
        "venues_run": len(finished),
        "venues_run_distinct_ids": len(unique_finished),
        "venues_skipped": sum(1 for v in in_batches if v["outcome"] == "skipped"),
        "venues_not_reached": sum(1 for v in venues_out if v["outcome"] == "not reached"),
        "venues_with_at_least_one_contact_now": sum(1 for v in finished if v["outcome"] == "contacts"),
        "venues_with_any_row_on_sheet_now": sum(1 for v in finished if v["contacts_on_sheet_now"] > 0),
        "venues_with_contacts_when_run": sum(1 for v in finished if v["outcome_when_run"] == "contacts"),
        "venues_zero_now": sum(1 for v in finished if v["outcome"] == "zero"),
        "contacts_saved_during_burn": len(all_p),
        "contacts_saved_by": dict(Counter(p["saved_by"].split(" (")[0] if p["saved_by"].startswith(("pipeline", "other"))
                                          else p["saved_by"] for p in all_p)),
        "contacts_still_on_sheet": len(on_sheet),
        "contacts_still_on_sheet_sendable": sum(1 for p in on_sheet if p["verified"].strip().lower() in SENDABLE),
        "contacts_still_on_sheet_by_verified": dict(Counter(p["verified"] for p in on_sheet)),
        "contacts_still_on_sheet_without_a_name": sum(1 for p in on_sheet if not p["has_name"]),
        "contacts_still_on_sheet_already_emailed": sum(1 for p in on_sheet if p.get("emailed")),
        "contacts_still_on_sheet_flagged_by_audit": sum(1 for p in on_sheet if p["flagged_by_audit"]),
        "contacts_deleted_in_cleanups": dict(Counter(p["deleted_in"] for p in all_p if p["deleted_in"])),
        "contacts_deleted_total": sum(1 for p in all_p if p["deleted_in"]),
        "contacts_by_source_saved_during_burn": dict(Counter(p["source"] for p in all_p)),
        "contacts_by_source_still_on_sheet": dict(Counter(p["source"] for p in on_sheet)),
        "contacts_by_source_detail_saved_during_burn": dict(Counter(p["source_detail"] for p in all_p)),
        "contacts_by_source_detail_still_on_sheet": dict(Counter(p["source_detail"] for p in on_sheet)),
        "contacts_by_sheet_source_field_now": dict(Counter(p.get("source_on_sheet", "") for p in on_sheet)),
        "contacts_saved_unverified_when_saved": sum(1 for p in all_p if p["verified_when_saved"] == "unverified"),
        "venues_by_kind": by_kind,
        "step_results_all_rounds": dict(sorted(sum((Counter(logs[r_]["step_tally"]) for r_ in run_ids), Counter()).items())),
        "cleanups": cleanups["info"],
        "sheet_rows_made_since_burn_began_on_venues_outside_the_rounds": len(extra_rows),
        "first_contact_id_of_the_burn": ("C-%d" % first_burn_cid) if first_burn_cid else None,
        "sheet_read_at": dash.get("generated_at"),
        "sheet_totals_now": dash.get("stats"),
    }

    # ---- credits
    a_start = next((o for o in apollo_tl if o["dt"]), None)
    z_start = next((o for o in zb_tl if o["dt"]), None)
    a_last, z_last = (apollo_tl[-1] if apollo_tl else None), (zb_tl[-1] if zb_tl else None)
    alert = {}
    try:
        alert = (json.load(open(os.path.join(HERE, "night_status.json"))).get("alert") or {})
    except (OSError, ValueError):
        pass
    burn_done = None
    try:
        burn_done = open(os.path.join(HERE, ".burn_done"), errors="replace").readline().strip()
    except OSError:
        pass
    audit_statements = []
    for rid in run_ids:
        p = os.path.join(RUNS, rid + ".deepdive-session.json")
        try:
            txt = json.load(open(p)).get("result") or ""
        except (OSError, ValueError, AttributeError):
            continue
        for m in re.finditer(r"[^.\n]*Apollo[^.\n]*credit[^\n]*?(?:\.(?=\s|$)|$)", txt):
            audit_statements.append({"run_id": rid, "file": rel(p), "text": scrub(m.group(0).strip()[:400])})
    within = [b for cr in credits_rounds_apollo for b in cr["batches"]
              if b["next_balance_read"] and b["next_balance_read"]["is_next_batch_of_same_round"]
              and b["balance_drop_to_next_read"] is not None]
    quiet = [b for b in within if not b["audit_sessions_running_meanwhile"]]
    zb_other, zb_status_all = {}, Counter()
    if zb_db is not None:
        for k, v in zb_db.items():
            first = utc_to_local(v.get("first"))
            if not (first and first >= burn_start):
                continue
            zb_status_all.update(v["by_status"])
            if k in run_ids or (k.startswith("night-") and k[6:] in run_ids):
                continue
            zb_other[k] = v["paid"]
        z0 = next((o for o in zb_tl if o["dt"]), None)
        if z0 and live["zerobounce"] is not None:
            rows_n = sum(zb_status_all.values())
            not_valid = zb_status_all.get("unknown", 0) + zb_status_all.get("request_error", 0)
            note(f"ZeroBounce: the balance fell by {z0['balance'] - live['zerobounce']} ({z0['balance']} at the start, "
                 f"{live['zerobounce']} read live now); the guard's usage table holds {rows_n} lookups since the burn "
                 f"began, {not_valid} of them with result unknown or request_error ({rows_n} - {not_valid} = "
                 f"{rows_n - not_valid}). The table does not record whether ZeroBounce charged for those.")
    credits = {
        "apollo": {
            "start_of_burn": {"balance": a_start["balance"], "at": fmt(a_start["dt"]), "source": a_start["source"]} if a_start else None,
            "now": {"live_read": live["apollo"], "live_read_at": live["read_at"] if live["apollo"] is not None else None,
                    "last_logged": {"balance": a_last["balance"], "at": fmt(a_last["dt"]), "source": a_last["source"]} if a_last else None,
                    "app_alert": scrub(alert.get("detail")) if alert.get("kind") == "apollo" else None},
            "per_round": credits_rounds_apollo,
            "timeline": [{"at": fmt(o["dt"]), "balance": o["balance"], "stop_below": o["floor"], "run_id": o["run_id"],
                          "batch": o["batch"], "source": o["source"]} for o in apollo_tl],
            "counter_check": {
                "what": "batches whose next balance read is the next batch of the same round",
                "batches": len(within),
                "account_balance_drop": sum(b["balance_drop_to_next_read"] for b in within),
                "pipeline_counter_last_lines": sum(b["pipeline_counter_last_line"] or 0 for b in within),
                "pipeline_step_credits": sum(b["pipeline_step_credits"] or 0 for b in within),
                "of_which_with_no_audit_session_running": {
                    "batches": len(quiet),
                    "account_balance_drop": sum(b["balance_drop_to_next_read"] for b in quiet),
                    "pipeline_counter_last_lines": sum(b["pipeline_counter_last_line"] or 0 for b in quiet),
                    "pipeline_step_credits": sum(b["pipeline_step_credits"] or 0 for b in quiet)},
            },
            "audit_sessions_own_statements": audit_statements,
        },
        "zerobounce": {
            "start_of_burn": {"balance": z_start["balance"], "at": fmt(z_start["dt"]), "source": z_start["source"]} if z_start else None,
            "now": {"live_read": live["zerobounce"], "live_read_at": live["read_at"] if live["zerobounce"] is not None else None,
                    "last_logged": {"balance": z_last["balance"], "at": fmt(z_last["dt"]), "source": z_last["source"]} if z_last else None},
            "per_round": credits_rounds_zb,
            "paid_checks_pipeline_all_rounds": sum(c["paid_checks_pipeline"] or 0 for c in credits_rounds_zb) if zb_db is not None else None,
            "paid_checks_audit_all_rounds": sum(c["paid_checks_audit"] or 0 for c in credits_rounds_zb) if zb_db is not None else None,
            "paid_checks_other_since_burn_began": zb_other if zb_db is not None else None,
            "lookups_by_result_since_burn_began": dict(zb_status_all) if zb_db is not None else None,
            "balance_reads_at_burn_starts": [{"at": fmt(o["dt"]), "balance": o["balance"], "source": o["source"]}
                                            for o in zb_tl if o["run_id"] is None],
        },
        "burn_done_file": burn_done,
    }

    # ---- incidents
    inc = []

    def add_inc(dt, kind, what, until=None, source=None, **extra):
        d = {"at": fmt(dt), "date": dt.strftime("%Y-%m-%d") if dt else None, "time": dt.strftime("%H:%M:%S") if dt else None,
             "kind": kind, "what": scrub(what), "until": fmt(until), "minutes": mins(dt, until), "source": source}
        d.update(extra)
        inc.append(d)

    reached = [s for s in sessions if s["reached_rounds"]]
    for i, s in enumerate(sessions):
        nxt = next((x for x in sessions[i + 1:] if x["reached_rounds"]), None)
        s["gap_to_next_working_start_min"] = mins(s["ended"], nxt["started"]) if nxt else None
        if not s["reached_rounds"]:
            add_inc(s["started"], "burn_start_did_not_reach_rounds",
                    "A burn start that never got to the rounds. Last timestamped line: " + (s["last_timestamped_line"] or "") +
                    " | last line of the file: " + (s["last_raw_line"] or ""),
                    until=s["ended"], source={"file": s["file"], "line_no": None, "line": s["last_timestamped_line"]})
        elif nxt and not (burn_end_ev and burn_end_ev["file"] == s["file"]):
            add_inc(s["ended"], "burn_process_ended",
                    "The burn log ends here (the process stopped or was stopped); the next working start is "
                    + fmt(nxt["started"]) + ". Last timestamped line: " + (s["last_timestamped_line"] or ""),
                    until=nxt["started"], source={"file": s["file"], "line_no": None, "line": s["last_timestamped_line"]},
                    reason_in_log=next((scrub(e["text"]) for e in reversed(events)
                                        if e["file"] == s["file"] and e["kind"] == "gave_up"), None))
    open_pause = open_out = None
    zb_run = None
    for e in events:
        k = e["kind"]
        if k == "pause_start":
            open_pause = e
        elif k == "pause_end" and open_pause:
            add_inc(open_pause["dt"], "paused_by_alex", "Paused with .burn_pause until it was removed",
                    until=e["dt"], source=src_line(open_pause), ended_by=src_line(e))
            open_pause = None
        elif k == "claude_out_start":
            open_out = e
        elif k == "claude_out_end" and open_out:
            add_inc(open_out["dt"], "claude_out_of_credits_wait",
                    "Claude is out of credits (or not answering): the burn waited, checking every 30 min. " + e["text"],
                    until=e["dt"], source=src_line(open_out), ended_by=src_line(e))
            open_out = None
        elif k == "claude_session_end" and int(e["m"].group(1)) != 0:
            add_inc(e["dt"], "claude_session_failed",
                    "A Claude session ended with exit %s: %s" % (e["m"].group(1), e["m"].group(2)[:200]), source=src_line(e))
        elif k == "audit_waits":
            add_inc(e["dt"], "audit_waits_for_claude", "The audit of %s waits because Claude is out" % e["m"].group(1),
                    source=src_line(e), run_id=e["m"].group(1))
        elif k == "fix_waits":
            add_inc(e["dt"], "fix_session_waits_for_claude", e["text"], source=src_line(e))
        elif k == "fix_revert":
            add_inc(e["dt"], "fix_session_reverted",
                    "The fix session left uncommitted code changes; they were reverted: " + e["m"].group(1), source=src_line(e))
        elif k == "gave_up":
            add_inc(e["dt"], "run_stopped_too_often", e["text"], source=src_line(e))
        elif k == "zb_refused":
            if zb_run and zb_run["file"] == e["file"] and zb_run["msg"] == e["m"].group(1):
                zb_run["inc"]["times"] += 1
                zb_run["inc"]["until"] = fmt(e["dt"])
                zb_run["inc"]["minutes"] = mins(zb_run["dt"], e["dt"])
            else:
                add_inc(e["dt"], "zerobounce_refused", "ZeroBounce NOT usable: " + re.sub(r"\(\d+\.\d+\.\d+\.\d+\)", "(IP)", e["m"].group(1)),
                        source=src_line(e), times=1)
                inc[-1]["source"]["line"] = re.sub(r"\(\d+\.\d+\.\d+\.\d+\)", "(IP)", inc[-1]["source"]["line"])
                zb_run = {"file": e["file"], "msg": e["m"].group(1), "inc": inc[-1], "dt": e["dt"]}
        elif k == "lock":
            pass      # covered by burn_start_did_not_reach_rounds
        elif k == "burn_over":
            add_inc(e["dt"], "burn_over", e["text"], source=src_line(e))
    if open_pause:
        add_inc(open_pause["dt"], "paused_by_alex", "Paused with .burn_pause; no 'Pause lifted' line follows",
                source=src_line(open_pause))
    if open_out:
        add_inc(open_out["dt"], "claude_out_of_credits_wait", "Claude out; no 'Claude answers again' line follows",
                source=src_line(open_out))

    # pipeline stops: from a non-zero exit to the next launch that really ran
    i = 0
    while i < len(all_segs):
        s = all_segs[i]
        if not (s["exit"] and s["code"] != 0):
            i += 1
            continue
        j = i + 1
        tries = []
        while j < len(all_segs) and not all_segs[j]["real"]:
            tries.append(all_segs[j])
            j += 1
        nxt = all_segs[j] if j < len(all_segs) else None
        msgs = Counter((t["code"], t["message"] or "") for t in tries)
        msg = s["message"] or "no reason in the burn log"
        cause = ("pause (.burn_pause)" if "paused by Alex" in msg else "chrome" if "Chrome" in msg
                 else "apollo" if "Apollo" in msg else "google" if "Google" in msg or "CAPTCHA" in msg
                 else "zerobounce" if "ZeroBounce" in msg
                 else "pipeline killed (exit 143 = SIGTERM), no reason logged" if s["code"] == 143 else "other")
        add_inc(s["exit"]["dt"], "pipeline_stopped",
                "pipeline.sh for %s exited %d: %s" % (s["run_id"], s["code"], msg),
                until=nxt["launch"]["dt"] if nxt else None, source=src_line(s["exit"]),
                run_id=s["run_id"], exit_code=s["code"], cause=cause,
                ran_minutes_before_stop=round(s["ran_s"] / 60, 1),
                failed_retries=len(tries),
                failed_retry_exits=[{"exit_code": c, "message": m_ or None, "times": n} for (c, m_), n in msgs.items()],
                next_working_launch=({"run_id": nxt["run_id"], "how": nxt["launch"]["m"].group(1),
                                      "at": fmt(nxt["launch"]["dt"])} if nxt else None))
        i = j if j > i else i + 1
    # short launches that were themselves the first stop are covered above; note the rest
    for rid in run_ids:
        log = logs[rid]
        lf = rel(os.path.join(RUNS, rid + ".log"))
        pf = [e for e in log["events"] if e["kind"] == "preflight_fail"]
        if pf:
            c = Counter(e["what"] for e in pf)
            quick = [s_ for s_ in segs_by_run.get(rid, []) if s_["exit"] and s_["code"] != 0 and not s_["real"]]
            add_inc(quick[0]["exit"]["dt"] if quick else pf[0]["dt"], "preflight_failed",
                    "Preflight failed %d time(s) in %s: %s" % (
                        len(pf), rid, "; ".join("%s (x%d)" % (k, n) for k, n in c.items())),
                    until=quick[-1]["exit"]["dt"] if len(quick) > 1 else None,
                    source={"file": lf, "line_no": pf[0]["line_no"], "line": pf[0]["line"]}, run_id=rid,
                    time_is=("first to last of the burn log's quick non-zero exits of this run (preflight lines carry no time)"
                             if quick else "the next dated line of the run log (preflight lines carry no time)"))
        for e in log["events"]:
            if e["kind"] in ("linkedin_wall", "google_blocked", "run_aborted"):
                add_inc(e["dt"], e["kind"], "%s: %s" % (rid, e["what"]),
                        source={"file": lf, "line_no": e["line_no"], "line": e["line"]}, run_id=rid, venue_id=e.get("venue_id"),
                        time_is="start of the venue being worked on (the line itself has no time)")
                if e["kind"] == "linkedin_wall":
                    inc[-1]["linkedin_steps_skipped_after_it"] = sum(
                        1 for x in log["events"] if x["kind"] == "step_blocked" and x["step"] == "linkedin"
                        and x["reason"] == "login_wall_earlier_in_run" and x["line_no"] > e["line_no"])
            elif e["kind"] in ("step_failed", "step_blocked") and (e["step"], e["reason"]) not in (
                    ("linkedin", "empty_page1"), ("final", "aborted"), ("linkedin", "login_wall_earlier_in_run")):
                add_inc(e["dt"], "pipeline_" + e["kind"], "%s: %s step %s for %s (%s)" % (
                    rid, e["step"], e["kind"][5:], e["venue_id"], e["reason"] or "no reason given"),
                    source={"file": lf, "line_no": e["line_no"], "line": e["line"]}, run_id=rid, venue_id=e["venue_id"],
                    time_is="start of the venue being worked on (the line itself has no time)")
        n_def = log["counts"].get("zb_deferred_saved_unverified", 0)
        if n_def:
            first_dt = log["first_started"]
            add_inc(first_dt, "zerobounce_deferred",
                    "%s: %d address(es) saved as unverified because ZeroBounce was not asked (%s)" % (
                        rid, n_def, ", ".join("%s x%d" % kv for kv in log["zb_reasons"].items())),
                    source={"file": lf, "line_no": None, "line": "[DEFERRED] lines"}, run_id=rid,
                    time_is="start of the round (the lines are spread over it)")
        n_api = log["counts"].get("api_error", 0)
        if n_api:
            ev = [e for e in log["events"] if e["kind"] == "api_error"]
            add_inc(ev[0]["dt"], "backend_write_errors", "%s: %d [API ERROR] line(s) (a sheet write failed or could not be read back)" % (rid, n_api),
                    source={"file": lf, "line_no": ev[0]["line_no"], "line": ev[0]["line"][:160]}, run_id=rid,
                    time_is="start of the venue being worked on at the first such line")
        lw = log["step_tally"].get("linkedin:failed", 0) + log["step_tally"].get("linkedin:blocked", 0)
        if lw:
            runs_out[run_ids.index(rid)]["linkedin_steps_failed_or_blocked"] = lw
    for r in runs_out:
        if r["contacts_saved_by_pipeline"] and r["contacts_deleted_total"] * 2 >= r["contacts_saved_total"]:
            st = datetime.strptime(r["started"], "%Y-%m-%d %H:%M:%S") if r["started"] else None
            en = datetime.strptime(r["ended"], "%Y-%m-%d %H:%M:%S") if r["ended"] else None
            add_inc(st, "round_mostly_deleted_later",
                    "%s saved %d contacts; %d of them were deleted in later cleanups (%s)" % (
                        r["run_id"], r["contacts_saved_total"], r["contacts_deleted_total"],
                        ", ".join("%s: %d" % kv for kv in r["contacts_deleted_in_cleanups"].items())),
                    until=en, source={"file": "reports/discovery-candidates.jsonl + reports/repair backups", "line_no": None, "line": None},
                    run_id=r["run_id"])
        if r["stopped_file"] and "\n" in r["stopped_file"]:
            p = os.path.join(RUNS, r["run_id"] + ".stopped")
            add_inc(datetime.fromtimestamp(os.path.getmtime(p)), "run_closed_by_hand",
                    r["run_id"] + ".stopped: " + r["stopped_file"].split("\n")[-1],
                    source={"file": rel(p), "line_no": None, "line": r["stopped_file"].split("\n")[-1]}, run_id=r["run_id"],
                    time_is="when the .stopped file was last written")
    for c in cleanups["info"]:
        dt = datetime.strptime(c["backup_file_written"], "%Y-%m-%d %H:%M:%S")
        add_inc(dt, "cleanup", "%s: %d contacts deleted from the sheet (%s)" % (
            c["cleanup"], c["rows_deleted"], ", ".join("%s: %d" % kv for kv in sorted(c["by_venue"].items(), key=lambda x: -x[1]))),
            source={"file": c["file"], "line_no": None, "line": None},
            time_is="when the backup file was last written (the deletion itself is not timed anywhere)")
    inc.sort(key=lambda d: (d["at"] or "9999", d["kind"]))

    # ---- notes
    note("Times are local (US Eastern). Burn-log lines carry only HH:MM:SS; dates come from the file name and from "
         "each time the clock steps back, checked against the 'New run run-YYYYMMDD-HHMM' lines.")
    note("'Saved during the burn' = the pipeline's own save records in reports/discovery-candidates.jsonl (disposition "
         "saved_valid / saved_role / saved_unverified) for the burn's run ids, plus contacts with outcome 'saved' in every "
         "committed version of <RUN_ID>.deepdive-saved.json, plus sheet rows made since the burn began on a round's venue "
         "that neither file explains. 'Still on the sheet' = the same venue and address is on the live sheet now.")
    note("A person's name, title and verified status are the sheet's when the row is still there; for deleted rows they "
         "come from the cleanup backup (the Nov 10 backup has no source or verified column, so verified is the status at "
         "save time) or from the candidate log.")
    note("Apollo: the balance drop of a round is the account balance read at its first batch minus the next read after "
         "the round ended. The account is shared: the audit sessions (Apollo through Claude) ran while the next round "
         "ran, and any work by hand in between also counts, so the drop is not the pipeline's use alone. Nothing on disk "
         "splits it. credits.apollo.counter_check gives the batches where no audit session overlapped.")
    note("The pipeline's '[APOLLO] Credits used this run' counter starts again at 0 in every batch and is printed before "
         "each venue's Apollo step, so its last line misses the last venue; pipeline_step_credits (the credits= fields "
         "of the apollo and linkedin step lines plus the postcheck's 'Apollo credits') is its complete form.")
    note("ZeroBounce 'paid_checks' per round are the rows of the guard's own usage table "
         "(~/.outreach/zerobounce_guard.sqlite3): run ids <RUN_ID> (pipeline) and night-<RUN_ID> (audit). They are "
         "lookups the guard counted against its budget, by result in paid_checks_by_result.")
    if not any(logs[r]["counts"].get("google_blocked") for r in run_ids):
        note("No Google CAPTCHA block is logged in any round of the burn: no '[GOOGLE BLOCKED]' line in a run log and no "
             "Google stop in a burn log. LinkedIn walls and Chrome stops are in incidents.")
    gaps = [i_ for i_ in inc if i_["kind"] == "burn_process_ended" and not i_.get("reason_in_log")]
    if gaps:
        note("Why the burn process itself ended at " + "; ".join(g["at"] for g in gaps) + " is not in any log: the burn "
             "log simply ends. The exits with code 143 (SIGTERM, i.e. the pipeline was killed from outside) carry no "
             "reason either. Email/CLAUDE.md says of Nov 8 only that 'Alex had it stopped outright'.")
    last = run_ids[-1]
    if audits[last] is None:
        note(f"{last}: the after-round audit has not saved anything yet (no deepdive-saved.json), so its audit numbers "
             "are null; re-run this script once it has.")
    if flagged_unmatched:
        note("Audit flags that match no contact saved during the burn at that venue (the address was never on the sheet, "
             "or the flag names no address): " + ", ".join("%s: %d" % kv for kv in sorted(flagged_unmatched.items())))
    if src_disagree:
        note(f"{src_disagree} contact(s) carry a source on the sheet that falls in a different group than the step that "
             "saved them; 'source' is the step at save time, 'source_on_sheet' is the sheet's field.")
    if not any((a or {}).get("sessions") and any(s_.get("flagged_backup") for s_ in a["sessions"]) for a in audits.values()) \
            and not glob.glob(os.path.join(REPAIR, "night-flagged-*.json")):
        note("The audit deleted nothing itself: no reports/repair/night-flagged-*.json backup exists and every "
             "'deleted' total is 0 or absent. Flagged contacts were only listed (outcome 'would_delete' from Nov 11, no "
             "outcome before); every deletion counted here is in a cleanup backup listed in totals.cleanups.")
    replanned = defaultdict(list)
    for v in venues_out:
        replanned[v["venue_id"]].append((v["run_id"], v["outcome"]))
    again = {k: v for k, v in replanned.items() if len(v) > 1}
    if again:
        ran_later = sum(1 for v in again.values() if v[0][1] == "not reached" and any(o != "not reached" for _, o in v[1:]))
        note(f"{len(again)} venue ids appear in more than one round (planned in a round that stopped before reaching them, "
             f"then planned again); {ran_later} of them ran in a later round. venues has one entry per round.")
    if totals["sheet_rows_made_since_burn_began_on_venues_outside_the_rounds"]:
        note(f"{totals['sheet_rows_made_since_burn_began_on_venues_outside_the_rounds']} sheet row(s) made since the burn "
             "began sit on venues that were in no round; they are not in venues or totals.")
    note("Not determined: who or what killed the pipeline at each exit 143; how many Apollo credits the audits and "
         "by-hand work used (only the audit sessions' own sentences, in credits.apollo.audit_sessions_own_statements, "
         "which are model-written, not measured); the exact time of each cleanup (the backup file's write time is given).")

    doc = {
        "generated_at": fmt(datetime.now()),
        "burn": {"started": fmt(burn_start), "ended": fmt(burn_end_ev["dt"]) if burn_end_ev else None,
                 "ended_reason": scrub(burn_end_ev["text"]) if burn_end_ev else None,
                 "burn_done_file": burn_done, "logs": [s["file"] for s in sessions]},
        "runs": runs_out,
        "venues": venues_out,
        "totals": totals,
        "credits": credits,
        "incidents": inc,
        "burn_sessions": [{"file": s["file"], "started": fmt(s["started"]), "ended": fmt(s["ended"]),
                           "reached_rounds": s["reached_rounds"], "rounds_launched": s["rounds_launched"],
                           "last_timestamped_line": s["last_timestamped_line"], "last_raw_line": s["last_raw_line"],
                           "gap_to_next_working_start_min": s.get("gap_to_next_working_start_min")} for s in sessions],
        "notes": NOTES,
    }

    scrubbed = [0]

    def clean(o):
        if isinstance(o, dict):
            return {k: clean(v) for k, v in o.items()}
        if isinstance(o, list):
            return [clean(v) for v in o]
        if isinstance(o, str):
            new = scrub(o)
            if new != o:
                scrubbed[0] += 1
            return new
        return o

    doc = clean(doc)
    doc["notes"].append("No email address is in this file: every text field was passed through an address filter "
                        "before writing (flag reasons and log lines show '[email]' in their place, and "
                        "'[mailbox]@' for a bare personal mailbox name; generic ones such as info@ or events@ stay).")
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False, default=str)
    os.replace(tmp, OUT)

    t = totals
    print(f"burn {doc['burn']['started']} -> {doc['burn']['ended']} ({doc['burn']['ended_reason']})")
    print(f"rounds {t['rounds']} ({t['rounds_that_ran_at_least_one_venue']} ran a venue) | venues run {t['venues_run']} "
          f"(in batches {t['venues_in_started_batches']}, planned {t['venues_planned']}, not reached {t['venues_not_reached']})")
    print(f"venues with a contact now {t['venues_with_at_least_one_contact_now']} | when run {t['venues_with_contacts_when_run']}")
    print(f"contacts saved {t['contacts_saved_during_burn']} {t['contacts_saved_by']} | still on sheet {t['contacts_still_on_sheet']} "
          f"| deleted {t['contacts_deleted_total']} {t['contacts_deleted_in_cleanups']}")
    print(f"by source, saved: {t['contacts_by_source_saved_during_burn']}")
    print(f"by source, on sheet: {t['contacts_by_source_still_on_sheet']}")
    a, z = credits["apollo"], credits["zerobounce"]
    print(f"apollo {a['start_of_burn'] and a['start_of_burn']['balance']} -> live {a['now']['live_read']} / last logged "
          f"{a['now']['last_logged'] and a['now']['last_logged']['balance']} | zerobounce "
          f"{z['start_of_burn'] and z['start_of_burn']['balance']} -> live {z['now']['live_read']} / last logged "
          f"{z['now']['last_logged'] and z['now']['last_logged']['balance']}")
    print(f"incidents {len(inc)} | notes {len(doc['notes'])} | wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
