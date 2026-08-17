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
  ZB_FAIL_CLOSED              1 = do not validate if balance check fails (default 1)
  ZB_DB_PATH                  Override the shared SQLite cache/usage database path
                              (default ~/.outreach/zerobounce_guard.sqlite3)

CLI examples:
  python3 zerobounce_guard.py verify person@example.com --source website --run-id pipeline-123
  python3 zerobounce_guard.py budget --run-id pipeline-123
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
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
            os.environ.setdefault(key, value)
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
            "SELECT COUNT(*) FROM inflight WHERE run_id = ?", (run_id,)
        ).fetchone()[0]
        day_reserved = conn.execute("SELECT COUNT(*) FROM inflight").fetchone()[0]
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

    def _http_json(self, url: str, params: Dict[str, str], timeout: int = 15) -> Dict[str, Any]:
        query = urllib.parse.urlencode(params)
        full_url = f"{url}?{query}"
        # Try urllib first, fall back to curl if SSL certs are broken (Python 3.9 on macOS)
        try:
            req = urllib.request.Request(full_url, headers={"User-Agent": "outreach-zb-guard/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body)
        except Exception:
            import subprocess
            result = subprocess.run(
                ["curl", "-s", "--max-time", str(timeout), full_url],
                capture_output=True, text=True, timeout=timeout + 5
            )
            if result.returncode == 0 and result.stdout.strip():
                return json.loads(result.stdout)
            raise

    def get_credits(self) -> Optional[int]:
        if not self.config.api_key:
            return None
        try:
            data = self._http_json(ZB_CREDITS_URL, {"api_key": self.config.api_key}, timeout=10)
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
        return {
            "status": str(data.get("status", "unknown") or "unknown").lower(),
            "sub_status": str(data.get("sub_status", "") or ""),
        }

    def budget(self, run_id: str, include_balance: bool = True) -> Dict[str, Any]:
        result = self._result_base(run_id)
        result.update({"allowed": True, "reason": "ok"})
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
                    "INSERT INTO inflight(email,reserved_at,run_id) VALUES (?,?,?)",
                    (email, time.time(), run_id),
                )
                conn.commit()
            except sqlite3.IntegrityError:
                conn.rollback()
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
            conn.execute("DELETE FROM inflight WHERE email = ?", (email,))
            run_used, day_used = self._counts(conn, run_id)
            conn.commit()

        try:
            remote = self._validate_remote(email)
            status = remote["status"]
            sub_status = remote["sub_status"]
        except Exception as exc:
            # Assume the attempt may have been billable. Cache it and keep the usage
            # record so retries cannot silently exceed the configured spend limits.
            failed_at = _iso_now()
            with self._connect() as conn:
                conn.execute("UPDATE usage SET status = ? WHERE id = ?", ("request_error", usage_id))
                conn.execute(
                    """
                    INSERT INTO cache(email,status,sub_status,verified_at,source)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(email) DO UPDATE SET
                        status=excluded.status, sub_status=excluded.sub_status,
                        verified_at=excluded.verified_at, source=excluded.source
                    """,
                    (email, "unknown", "request_error", failed_at, source),
                )
            return {
                **self._result_base(run_id),
                "email": email,
                "status": "deferred",
                "cached": False,
                "charged": True,
                "reason": "validation_request_failed_budget_counted",
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

    args = parser.parse_args()
    guard = ZeroBounceGuard()
    if args.command == "verify":
        result = guard.verify(args.email, args.source, args.run_id, retry_unknown=args.retry_unknown)
    else:
        result = guard.budget(args.run_id, include_balance=not args.no_balance)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
