#!/usr/bin/env python3
"""Cost-safe ZeroBounce verification helper.

All project ZeroBounce lookups should go through this module. It provides:
- persistent cache (same email is not paid for repeatedly)
- per-run and per-day paid-validation caps
- a minimum account-balance reserve
- concurrency protection so two processes cannot validate the same email at once
- fail-closed behavior when the credit balance cannot be checked

Environment variables (all optional except ZEROBOUNCE_KEY):
  ZEROBOUNCE_KEY              API key. Loaded from .env if present.
  ZB_ENABLED                  1 = allow paid validations, 0 = emergency kill switch (default 0)
  ZB_MAX_PER_RUN              Paid validation ATTEMPTS allowed per process/run (default 5)
  ZB_MAX_PER_DAY              Paid validation ATTEMPTS allowed across all scripts/copies per UTC day (default 10)
  ZB_MIN_BALANCE              Never intentionally spend below this many account credits (default 500)
  ZB_CACHE_DAYS               Cache non-unknown statuses for this many days (default 180)
  ZB_UNKNOWN_CACHE_DAYS       Cache unknown statuses for this many days (default 30)
  ZB_ERROR_CACHE_HOURS        After a failed request (timeout, vendor error) don't retry the
                              same email for this many hours (default 6); never a verdict
  ZB_INFLIGHT_WAIT            Seconds to wait for another process validating the same email (45)
  ZB_FAIL_CLOSED              1 = do not validate if balance check fails (default 1)
  ZB_DB_PATH                  Override the shared SQLite cache/usage database path
                              (default ~/.outreach/zerobounce_guard.sqlite3)

The defaults above apply only when neither the environment nor .env sets a value.
.env normally does (ZB_ENABLED=1 and high caps); `budget` prints the effective
values with their source (env / .env / default).

CLI examples:
  python3 zerobounce_guard.py verify person@example.com --source website --run-id pipeline-123
  python3 zerobounce_guard.py budget --run-id pipeline-123
  python3 zerobounce_guard.py lookup a@x.com b@y.com     # cached verdicts only, never paid
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DB = Path.home() / ".outreach" / "zerobounce_guard.sqlite3"
ZB_VALIDATE_URL = "https://api.zerobounce.net/v2/validate"
ZB_CREDITS_URL = "https://api.zerobounce.net/v2/getcredits"


_DOTENV_KEYS: set = set()   # keys whose value came from .env (not the caller's environment)


def _load_dotenv(path: Path) -> None:
    """Load simple KEY=VALUE lines without requiring python-dotenv."""
    if not path.exists():
        return
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if not key:
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            if key not in os.environ:
                os.environ[key] = value
                _DOTENV_KEYS.add(key)
    except OSError:
        pass


_load_dotenv(SCRIPT_DIR / ".env")


def _env_int(name: str, default: int, minimum: int = 0) -> int:
    try:
        return max(minimum, int(os.environ.get(name, str(default)).strip()))
    except (TypeError, ValueError):
        return default


def _env_bool(name: str, default: bool = True) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _utc_now().isoformat()


def _normalize_email(email: str) -> str:
    return (email or "").strip().lower()


class VendorError(Exception):
    """ZeroBounce answered, but with an error instead of a verdict (bad key, no
    credits, rate limit, 4xx/5xx). Not billed, and never cached as a verdict."""


ERROR_SUB_STATUSES = ("request_error", "vendor_error")


@dataclass
class GuardConfig:
    api_key: str
    db_path: Path
    enabled: bool = False
    max_per_run: int = 5
    max_per_day: int = 10
    min_balance: int = 500
    cache_days: int = 180
    unknown_cache_days: int = 30
    fail_closed: bool = True
    error_cache_hours: int = 6
    inflight_wait: int = 45

    @classmethod
    def from_env(cls) -> "GuardConfig":
        return cls(
            api_key=os.environ.get("ZEROBOUNCE_KEY", "").strip(),
            db_path=Path(os.environ.get("ZB_DB_PATH", str(DEFAULT_DB))).expanduser(),
            enabled=_env_bool("ZB_ENABLED", False),
            max_per_run=_env_int("ZB_MAX_PER_RUN", 5),
            max_per_day=_env_int("ZB_MAX_PER_DAY", 10),
            min_balance=_env_int("ZB_MIN_BALANCE", 500),
            cache_days=_env_int("ZB_CACHE_DAYS", 180),
            unknown_cache_days=_env_int("ZB_UNKNOWN_CACHE_DAYS", 30),
            fail_closed=_env_bool("ZB_FAIL_CLOSED", True),
            error_cache_hours=_env_int("ZB_ERROR_CACHE_HOURS", 6),
            inflight_wait=_env_int("ZB_INFLIGHT_WAIT", 45),
        )


class ZeroBounceGuard:
    def __init__(self, config: Optional[GuardConfig] = None):
        self.config = config or GuardConfig.from_env()
        self.config.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.config.db_path), timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS cache (
                    email TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    sub_status TEXT DEFAULT '',
                    verified_at TEXT NOT NULL,
                    source TEXT DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS usage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    used_at TEXT NOT NULL,
                    usage_date TEXT NOT NULL,
                    run_id TEXT NOT NULL,
                    email TEXT NOT NULL,
                    status TEXT NOT NULL,
                    source TEXT DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS idx_usage_date ON usage(usage_date);
                CREATE INDEX IF NOT EXISTS idx_usage_run ON usage(run_id);
                CREATE TABLE IF NOT EXISTS inflight (
                    email TEXT PRIMARY KEY,
                    reserved_at REAL NOT NULL,
                    run_id TEXT NOT NULL
                );
                """
            )
            # phase: 'reserved' (counts against the budget) or 'calling' (the usage row
            # already counts it). The row stays until the verdict is cached, so a second
            # process can't pay for the same email while the vendor call is running.
            cols = {r[1] for r in conn.execute("PRAGMA table_info(inflight)")}
            if "phase" not in cols:
                conn.execute("ALTER TABLE inflight ADD COLUMN phase TEXT DEFAULT 'reserved'")

    def _counts(self, conn: sqlite3.Connection, run_id: str) -> tuple[int, int]:
        today = _utc_now().date().isoformat()
        run_used = conn.execute(
            "SELECT COUNT(*) FROM usage WHERE run_id = ?", (run_id,)
        ).fetchone()[0]
        day_used = conn.execute(
            "SELECT COUNT(*) FROM usage WHERE usage_date = ?", (today,)
        ).fetchone()[0]
        return int(run_used), int(day_used)

    def _budget_counts(self, conn: sqlite3.Connection, run_id: str) -> tuple[int, int, int, int]:
        """Return paid + currently reserved counts so concurrent runs cannot overshoot caps."""
        run_used, day_used = self._counts(conn, run_id)
        run_reserved = conn.execute(
            "SELECT COUNT(*) FROM inflight WHERE run_id = ? AND COALESCE(phase,'reserved') = 'reserved'", (run_id,)
        ).fetchone()[0]
        day_reserved = conn.execute(
            "SELECT COUNT(*) FROM inflight WHERE COALESCE(phase,'reserved') = 'reserved'").fetchone()[0]
        return int(run_used), int(day_used), int(run_reserved), int(day_reserved)

    def _result_base(self, run_id: str) -> Dict[str, Any]:
        with self._connect() as conn:
            conn.execute("DELETE FROM inflight WHERE reserved_at < ?", (time.time() - 300,))
            run_used, day_used, run_reserved, day_reserved = self._budget_counts(conn, run_id)
        return {
            "run_id": run_id,
            "run_used": run_used,
            "run_reserved": run_reserved,
            "run_limit": self.config.max_per_run,
            "day_used": day_used,
            "day_reserved": day_reserved,
            "day_limit": self.config.max_per_day,
            "reserve": self.config.min_balance,
        }

    def _cached_result(self, conn: sqlite3.Connection, email: str, retry_unknown: bool) -> Optional[Dict[str, Any]]:
        row = conn.execute(
            "SELECT email,status,sub_status,verified_at,source FROM cache WHERE email = ?",
            (email,),
        ).fetchone()
        if not row:
            return None
        status = (row["status"] or "unknown").lower()
        sub = (row["sub_status"] or "").lower()
        if sub in ERROR_SUB_STATUSES or status == "error":
            # a recent failed request: don't hammer the vendor, but it is not a verdict
            try:
                failed = datetime.fromisoformat(row["verified_at"])
                if failed.tzinfo is None:
                    failed = failed.replace(tzinfo=timezone.utc)
                age_h = (_utc_now() - failed).total_seconds() / 3600
            except Exception:
                age_h = 10**9
            if age_h > self.config.error_cache_hours:
                return None
            return {"status": "deferred", "sub_status": sub, "cached": True, "charged": False,
                    "reason": "recent_request_error", "verified_at": row["verified_at"]}
        if retry_unknown and status == "unknown":
            return None
        try:
            verified = datetime.fromisoformat(row["verified_at"])
            if verified.tzinfo is None:
                verified = verified.replace(tzinfo=timezone.utc)
            age_days = (_utc_now() - verified).total_seconds() / 86400
        except Exception:
            age_days = 10**9
        ttl = self.config.unknown_cache_days if status == "unknown" else self.config.cache_days
        if age_days > ttl:
            return None
        return {
            "status": status,
            "sub_status": row["sub_status"] or "",
            "cached": True,
            "charged": False,
            "reason": "cache_hit",
            "verified_at": row["verified_at"],
        }

    def _http_json(self, url: str, params: Dict[str, str], timeout: int = 15,
                   retry_after_send: bool = False) -> Dict[str, Any]:
        """GET JSON. Falls back to curl only when urllib failed BEFORE the request
        reached the server (connect / TLS handshake — python.org 3.9 on this Mac has
        no CA certs), so a paid /validate call can never be sent twice. For free
        endpoints retry_after_send=True also retries timeouts and bad bodies."""
        query = urllib.parse.urlencode(params)
        full_url = f"{url}?{query}"
        try:
            req = urllib.request.Request(full_url, headers={"User-Agent": "outreach-zb-guard/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            # the server answered with an error status: nothing to retry, not a verdict
            raise VendorError(f"HTTP {exc.code}") from exc
        except urllib.error.URLError:
            # urllib wraps errors from connect/handshake/send in URLError; the
            # request never got an answer, so trying again with curl is safe.
            return self._curl_json(full_url, timeout)
        except Exception:
            # read timeout / reset after the request was sent: it may have been billed
            if retry_after_send:
                return self._curl_json(full_url, timeout)
            raise
        return json.loads(body)

    @staticmethod
    def _curl_json(full_url: str, timeout: int) -> Dict[str, Any]:
        import subprocess
        result = subprocess.run(
            ["curl", "-s", "--max-time", str(timeout), full_url],
            capture_output=True, text=True, timeout=timeout + 5
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise RuntimeError(f"curl failed (exit {result.returncode})")
        return json.loads(result.stdout)

    def get_credits(self) -> Optional[int]:
        if not self.config.api_key:
            return None
        try:
            data = self._http_json(ZB_CREDITS_URL, {"api_key": self.config.api_key}, timeout=10,
                                   retry_after_send=True)
            raw = data.get("Credits", data.get("credits"))
            return int(raw)
        except Exception:
            return None

    def _validate_remote(self, email: str) -> Dict[str, Any]:
        data = self._http_json(
            ZB_VALIDATE_URL,
            {"api_key": self.config.api_key, "email": email, "ip_address": ""},
            timeout=20,
        )
        # {"error": "..."} (bad key, no credits, rate limit) is not a verdict
        if not isinstance(data, dict) or data.get("error") or not data.get("status"):
            detail = data.get("error") if isinstance(data, dict) else data
            raise VendorError(str(detail or "response without a status")[:200])
        return {
            "status": str(data["status"]).lower(),
            "sub_status": str(data.get("sub_status", "") or ""),
        }

    def settings(self) -> Dict[str, Any]:
        """Effective limits and where each came from (env / .env / default)."""
        c = self.config
        effective = {"ZB_ENABLED": c.enabled, "ZB_MAX_PER_RUN": c.max_per_run, "ZB_MAX_PER_DAY": c.max_per_day,
                     "ZB_MIN_BALANCE": c.min_balance, "ZB_FAIL_CLOSED": c.fail_closed,
                     "ZB_CACHE_DAYS": c.cache_days, "ZB_UNKNOWN_CACHE_DAYS": c.unknown_cache_days}
        out = {}
        for key, value in effective.items():
            src = ".env" if key in _DOTENV_KEYS else ("env" if key in os.environ else "default")
            out[key] = {"value": value, "source": src}
        return out

    def _wait_for_other(self, email: str) -> Optional[Dict[str, Any]]:
        """Another process is validating this email: wait for its cached verdict
        instead of paying again. None if it doesn't appear in time."""
        deadline = time.time() + self.config.inflight_wait
        while time.time() < deadline:
            time.sleep(1)
            with self._connect() as conn:
                hit = self._cached_result(conn, email, retry_unknown=False)
                busy = conn.execute("SELECT 1 FROM inflight WHERE email = ? AND reserved_at >= ?",
                                    (email, time.time() - 300)).fetchone()
            if hit:
                return {**hit, "reason": "waited_for_other_process" if hit.get("status") != "deferred" else hit["reason"]}
            if not busy:
                return None
        return None

    def lookup(self, emails) -> Dict[str, Any]:
        """Cached verdicts only — never calls the vendor. fresh=False means a verify
        call would pay (no row, expired, or a cached request error)."""
        out: Dict[str, Any] = {}
        with self._connect() as conn:
            for raw in emails:
                email = _normalize_email(raw)
                if not email:
                    continue
                row = conn.execute("SELECT status,sub_status,verified_at FROM cache WHERE email = ?", (email,)).fetchone()
                if not row:
                    out[email] = None
                    continue
                hit = self._cached_result(conn, email, retry_unknown=False)
                out[email] = {"status": (row["status"] or "").lower(), "sub_status": row["sub_status"] or "",
                              "verified_at": row["verified_at"],
                              "fresh": bool(hit) and hit.get("status") != "deferred"}
        return out

    def budget(self, run_id: str, include_balance: bool = True) -> Dict[str, Any]:
        result = self._result_base(run_id)
        result.update({"allowed": True, "reason": "ok", "enabled": self.config.enabled,
                       "settings": self.settings()})
        if not self.config.enabled:
            result.update({"allowed": False, "reason": "disabled", "credits_remaining": None})
            return result
        if not self.config.api_key:
            result.update({"allowed": False, "reason": "no_api_key", "credits_remaining": None})
            return result
        if result["run_used"] + result.get("run_reserved", 0) >= self.config.max_per_run:
            result.update({"allowed": False, "reason": "run_budget_reached"})
        elif result["day_used"] + result.get("day_reserved", 0) >= self.config.max_per_day:
            result.update({"allowed": False, "reason": "day_budget_reached"})
        if include_balance:
            credits = self.get_credits()
            result["credits_remaining"] = credits
            if credits is None and self.config.fail_closed:
                result.update({"allowed": False, "reason": "credit_check_failed"})
            elif credits is not None and credits <= self.config.min_balance:
                result.update({"allowed": False, "reason": "reserve_reached"})
        return result

    def verify(self, email: str, source: str, run_id: str, retry_unknown: bool = False) -> Dict[str, Any]:
        email = _normalize_email(email)
        base = self._result_base(run_id)
        if not email or "@" not in email:
            return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "invalid_email_input"}

        # Cache is checked even when paid verification is disabled. That means the
        # emergency kill switch prevents new spend without throwing away validation
        # results the user has already paid for.
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("DELETE FROM inflight WHERE reserved_at < ?", (time.time() - 300,))
            cached = self._cached_result(conn, email, retry_unknown)
            if cached:
                run_used, day_used = self._counts(conn, run_id)
                conn.commit()
                return {
                    "email": email,
                    **cached,
                    "run_id": run_id,
                    "run_used": run_used,
                    "run_limit": self.config.max_per_run,
                    "day_used": day_used,
                    "day_limit": self.config.max_per_day,
                    "reserve": self.config.min_balance,
                }
            if not self.config.enabled:
                conn.commit()
                return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "disabled"}
            if not self.config.api_key:
                conn.commit()
                return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "no_api_key"}

            # Reserve this email atomically. This prevents two concurrently running
            # scripts from both paying to validate the same address.
            run_used, day_used, run_reserved, day_reserved = self._budget_counts(conn, run_id)
            if run_used + run_reserved >= self.config.max_per_run:
                conn.commit()
                return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "run_budget_reached"}
            if day_used + day_reserved >= self.config.max_per_day:
                conn.commit()
                return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "day_budget_reached"}
            try:
                conn.execute(
                    "INSERT INTO inflight(email,reserved_at,run_id,phase) VALUES (?,?,?,'reserved')",
                    (email, time.time(), run_id),
                )
                conn.commit()
            except sqlite3.IntegrityError:
                conn.rollback()
                waited = self._wait_for_other(email)
                if waited:
                    return {"email": email, **waited, "run_id": run_id, "run_used": base["run_used"],
                            "run_limit": self.config.max_per_run, "day_used": base["day_used"],
                            "day_limit": self.config.max_per_day, "reserve": self.config.min_balance}
                return {**base, "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "already_inflight"}

        # Always check the current vendor balance before a paid validation. If the
        # balance check fails, default to NOT spending (fail closed).
        credits_before = self.get_credits()
        if credits_before is None and self.config.fail_closed:
            with self._connect() as conn:
                conn.execute("DELETE FROM inflight WHERE email = ?", (email,))
            return {**self._result_base(run_id), "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "credit_check_failed", "credits_remaining": None}
        if credits_before is not None and credits_before <= self.config.min_balance:
            with self._connect() as conn:
                conn.execute("DELETE FROM inflight WHERE email = ?", (email,))
            return {**self._result_base(run_id), "email": email, "status": "deferred", "cached": False, "charged": False, "reason": "reserve_reached", "credits_remaining": credits_before}

        # Count the paid ATTEMPT before making the vendor call. This is deliberately
        # conservative: a timeout or broken response may still consume a vendor credit,
        # so it must consume our local budget too. Otherwise a flaky connection could
        # blow through the cap with many unique addresses. Atomically replace the
        # inflight reservation with a usage record so concurrent processes still see it.
        attempted_at = _iso_now()
        usage_date = _utc_now().date().isoformat()
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            cur = conn.execute(
                "INSERT INTO usage(used_at,usage_date,run_id,email,status,source) VALUES (?,?,?,?,?,?)",
                (attempted_at, usage_date, run_id, email, "attempted", source),
            )
            usage_id = int(cur.lastrowid)
            conn.execute("UPDATE inflight SET phase = 'calling', reserved_at = ? WHERE email = ?", (time.time(), email))
            run_used, day_used = self._counts(conn, run_id)
            conn.commit()

        try:
            remote = self._validate_remote(email)
            status = remote["status"]
            sub_status = remote["sub_status"]
        except Exception as exc:
            # Keep the usage row so retries can't exceed the caps. The failure is
            # remembered for ZB_ERROR_CACHE_HOURS only, never as an "unknown" verdict.
            # A vendor error (it answered with an error) isn't billed; a timeout or
            # reset after sending may have been.
            vendor = isinstance(exc, VendorError)
            sub = "vendor_error" if vendor else "request_error"
            failed_at = _iso_now()
            with self._connect() as conn:
                conn.execute("BEGIN IMMEDIATE")
                conn.execute("UPDATE usage SET status = ? WHERE id = ?", (sub, usage_id))
                # an existing real verdict (retry_unknown / expired) is not overwritten by an error
                conn.execute(
                    """
                    INSERT INTO cache(email,status,sub_status,verified_at,source)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(email) DO UPDATE SET
                        status=excluded.status, sub_status=excluded.sub_status,
                        verified_at=excluded.verified_at, source=excluded.source
                    WHERE cache.status = 'error' OR cache.sub_status IN ('request_error', 'vendor_error')
                    """,
                    (email, "error", sub, failed_at, source),
                )
                conn.execute("DELETE FROM inflight WHERE email = ?", (email,))
                conn.commit()
            return {
                **self._result_base(run_id),
                "email": email,
                "status": "deferred",
                "cached": False,
                "charged": not vendor,
                "reason": "vendor_error" if vendor else "validation_request_failed_budget_counted",
                "error": str(exc)[:200],
                "credits_remaining": credits_before,
            }

        used_at = _iso_now()
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("UPDATE usage SET status = ? WHERE id = ?", (status, usage_id))
            conn.execute(
                """
                INSERT INTO cache(email,status,sub_status,verified_at,source)
                VALUES (?,?,?,?,?)
                ON CONFLICT(email) DO UPDATE SET
                    status=excluded.status,
                    sub_status=excluded.sub_status,
                    verified_at=excluded.verified_at,
                    source=excluded.source
                """,
                (email, status, sub_status, used_at, source),
            )
            conn.execute("DELETE FROM inflight WHERE email = ?", (email,))
            run_used, day_used = self._counts(conn, run_id)
            conn.commit()

        return {
            "email": email,
            "status": status,
            "sub_status": sub_status,
            "cached": False,
            "charged": True,
            "reason": "verified",
            "verified_at": used_at,
            "credits_remaining_before": credits_before,
            "run_id": run_id,
            "run_used": run_used,
            "run_limit": self.config.max_per_run,
            "day_used": day_used,
            "day_limit": self.config.max_per_day,
            "reserve": self.config.min_balance,
        }


def verify_email(email: str, source: str = "unknown", run_id: Optional[str] = None, retry_unknown: bool = False) -> Dict[str, Any]:
    run_id = run_id or os.environ.get("ZB_RUN_ID") or f"python-{os.getpid()}-{int(time.time())}"
    return ZeroBounceGuard().verify(email, source=source, run_id=run_id, retry_unknown=retry_unknown)


def _main() -> int:
    parser = argparse.ArgumentParser(description="Cost-safe ZeroBounce verification")
    sub = parser.add_subparsers(dest="command", required=True)

    verify_p = sub.add_parser("verify")
    verify_p.add_argument("email")
    verify_p.add_argument("--source", default="unknown")
    verify_p.add_argument("--run-id", default=os.environ.get("ZB_RUN_ID", f"cli-{os.getpid()}-{int(time.time())}"))
    verify_p.add_argument("--retry-unknown", action="store_true")

    budget_p = sub.add_parser("budget")
    budget_p.add_argument("--run-id", default=os.environ.get("ZB_RUN_ID", f"cli-{os.getpid()}-{int(time.time())}"))
    budget_p.add_argument("--no-balance", action="store_true")

    lookup_p = sub.add_parser("lookup", help="print cached verdicts (free); emails as args or one per line on stdin")
    lookup_p.add_argument("emails", nargs="*")

    args = parser.parse_args()
    guard = ZeroBounceGuard()
    if args.command == "verify":
        result = guard.verify(args.email, args.source, args.run_id, retry_unknown=args.retry_unknown)
    elif args.command == "lookup":
        emails = args.emails or [l.strip() for l in sys.stdin if l.strip()]
        result = guard.lookup(emails)
    else:
        result = guard.budget(args.run_id, include_balance=not args.no_balance)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
