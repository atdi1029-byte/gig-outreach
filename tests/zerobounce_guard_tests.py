#!/usr/bin/env python3
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sqlite3
import threading
import time
import urllib.error
from datetime import datetime, timedelta, timezone
from unittest import mock

import zerobounce_guard as zg
from zerobounce_guard import GuardConfig, ZeroBounceGuard, VendorError


class FakeGuard(ZeroBounceGuard):
    def __init__(self, config, fail_emails=None, vendor_error_emails=None, credits=1000, verdict="valid"):
        self.remote_calls = []
        self.fail_emails = set(fail_emails or [])
        self.vendor_error_emails = set(vendor_error_emails or [])
        self.credits = credits
        self.verdict = verdict
        super().__init__(config)

    def get_credits(self):
        return self.credits

    def _validate_remote(self, email):
        self.remote_calls.append(email)
        if email in self.fail_emails:
            raise TimeoutError("simulated timeout")
        if email in self.vendor_error_emails:
            raise VendorError("Invalid API key or your account ran out of credits")
        return {"status": self.verdict, "sub_status": ""}


class ZeroBounceGuardTests(unittest.TestCase):
    def make_config(self, db, run=3, day=4):
        return GuardConfig(
            api_key="test-key",
            db_path=Path(db),
            enabled=True,
            max_per_run=run,
            max_per_day=day,
            min_balance=0,
            cache_days=180,
            unknown_cache_days=30,
            fail_closed=True,
        )

    def test_same_email_is_only_paid_once(self):
        with tempfile.TemporaryDirectory() as td:
            g = FakeGuard(self.make_config(Path(td) / "guard.sqlite3"))
            a = g.verify("Person@Example.com", "web", "run-a")
            b = g.verify("person@example.com", "apollo", "run-a")
            self.assertTrue(a["charged"])
            self.assertFalse(b["charged"])
            self.assertTrue(b["cached"])
            self.assertEqual(g.remote_calls, ["person@example.com"])

    def test_per_run_cap_blocks_extra_calls(self):
        with tempfile.TemporaryDirectory() as td:
            g = FakeGuard(self.make_config(Path(td) / "guard.sqlite3", run=2, day=10))
            self.assertEqual(g.verify("a@example.com", "web", "run-a")["status"], "valid")
            self.assertEqual(g.verify("b@example.com", "web", "run-a")["status"], "valid")
            third = g.verify("c@example.com", "web", "run-a")
            self.assertEqual(third["status"], "deferred")
            self.assertEqual(third["reason"], "run_budget_reached")
            self.assertEqual(len(g.remote_calls), 2)

    def test_day_cap_is_shared_across_run_ids(self):
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "guard.sqlite3"
            g1 = FakeGuard(self.make_config(db, run=10, day=2))
            g2 = FakeGuard(self.make_config(db, run=10, day=2))
            g1.verify("a@example.com", "web", "run-a")
            g2.verify("b@example.com", "web", "run-b")
            third = g1.verify("c@example.com", "web", "run-c")
            self.assertEqual(third["status"], "deferred")
            self.assertEqual(third["reason"], "day_budget_reached")
            self.assertEqual(len(g1.remote_calls) + len(g2.remote_calls), 2)

    def test_timeout_still_consumes_budget_attempt(self):
        with tempfile.TemporaryDirectory() as td:
            g = FakeGuard(
                self.make_config(Path(td) / "guard.sqlite3", run=1, day=10),
                fail_emails={"bad@example.com"},
            )
            first = g.verify("bad@example.com", "web", "run-a")
            self.assertEqual(first["status"], "deferred")
            self.assertTrue(first["charged"])
            self.assertEqual(first["reason"], "validation_request_failed_budget_counted")
            second = g.verify("next@example.com", "web", "run-a")
            self.assertEqual(second["status"], "deferred")
            self.assertEqual(second["reason"], "run_budget_reached")
            self.assertEqual(g.remote_calls, ["bad@example.com"])

    def test_disabled_kill_switch_makes_no_remote_call(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3")
            cfg.enabled = False
            g = FakeGuard(cfg)
            r = g.verify("a@example.com", "web", "run-a")
            self.assertEqual(r["status"], "deferred")
            self.assertEqual(r["reason"], "disabled")
            self.assertEqual(g.remote_calls, [])

    # ---- vendor errors are not verdicts (SUP-9) ----
    def test_vendor_error_is_not_a_cached_unknown(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3", run=10, day=10)
            g = FakeGuard(cfg, vendor_error_emails={"a@example.com"})
            r = g.verify("a@example.com", "web", "run-a")
            self.assertEqual((r["status"], r["reason"], r["charged"]), ("deferred", "vendor_error", False))
            row = sqlite3.connect(str(cfg.db_path)).execute("SELECT status, sub_status FROM cache").fetchone()
            self.assertEqual(row, ("error", "vendor_error"))
            again = g.verify("a@example.com", "web", "run-a")          # inside the error window: no call
            self.assertEqual((again["status"], again["reason"]), ("deferred", "recent_request_error"))
            self.assertEqual(g.remote_calls, ["a@example.com"])
            g.config.error_cache_hours = 0                              # window over: retried
            g.vendor_error_emails.clear()
            time.sleep(0.01)
            self.assertEqual(g.verify("a@example.com", "web", "run-a")["status"], "valid")
            self.assertEqual(len(g.remote_calls), 2)

    def test_error_body_raises_vendor_error(self):
        with tempfile.TemporaryDirectory() as td:
            g = ZeroBounceGuard(self.make_config(Path(td) / "guard.sqlite3"))
            with mock.patch.object(g, "_http_json", return_value={"error": "Invalid API key"}):
                with self.assertRaises(VendorError):
                    g._validate_remote("a@example.com")
            with mock.patch.object(g, "_http_json", return_value={"status": "valid", "sub_status": ""}):
                self.assertEqual(g._validate_remote("a@example.com")["status"], "valid")

    def test_error_never_overwrites_a_real_verdict(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3", run=10, day=10)
            g = FakeGuard(cfg, verdict="unknown")
            g.verify("a@example.com", "web", "run-a")
            g.fail_emails.add("a@example.com")
            g.verify("a@example.com", "web", "run-a", retry_unknown=True)
            row = sqlite3.connect(str(cfg.db_path)).execute("SELECT status FROM cache").fetchone()
            self.assertEqual(row[0], "unknown")

    # ---- curl fallback can't double-pay (SUP-8 / SEC-4) ----
    def _http_guard(self, td):
        return ZeroBounceGuard(self.make_config(Path(td) / "guard.sqlite3"))

    def test_curl_fallback_only_before_the_request_is_sent(self):
        ok = mock.Mock(returncode=0, stdout='{"status": "valid"}')
        with tempfile.TemporaryDirectory() as td:
            g = self._http_guard(td)
            with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("ssl handshake")), \
                    mock.patch("subprocess.run", return_value=ok) as run:
                self.assertEqual(g._http_json(zg.ZB_VALIDATE_URL, {"email": "a@x.com"})["status"], "valid")
                self.assertEqual(run.call_count, 1)
            with mock.patch("urllib.request.urlopen", side_effect=TimeoutError("read timed out")), \
                    mock.patch("subprocess.run", return_value=ok) as run:
                with self.assertRaises(TimeoutError):
                    g._http_json(zg.ZB_VALIDATE_URL, {"email": "a@x.com"})
                self.assertEqual(run.call_count, 0)          # may have been billed: no second call
            err = urllib.error.HTTPError("u", 429, "Too Many Requests", {}, None)
            with mock.patch("urllib.request.urlopen", side_effect=err), \
                    mock.patch("subprocess.run", return_value=ok) as run:
                with self.assertRaises(VendorError):
                    g._http_json(zg.ZB_VALIDATE_URL, {"email": "a@x.com"})
                self.assertEqual(run.call_count, 0)
            with mock.patch("urllib.request.urlopen", side_effect=TimeoutError("read timed out")), \
                    mock.patch("subprocess.run", return_value=mock.Mock(returncode=0, stdout='{"Credits": "42"}')) as run:
                self.assertEqual(g._http_json(zg.ZB_CREDITS_URL, {}, retry_after_send=True)["Credits"], "42")
                self.assertEqual(run.call_count, 1)          # free endpoint: retry is fine

    # ---- in-flight lock lasts until the verdict is cached (SUP-19) ----
    def test_second_process_waits_for_the_first_verdict(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3", run=10, day=10)
            cfg.inflight_wait = 5
            g = FakeGuard(cfg)
            con = sqlite3.connect(str(cfg.db_path))
            con.execute("INSERT INTO inflight(email,reserved_at,run_id,phase) VALUES (?,?,?,'calling')",
                        ("a@example.com", time.time(), "other-run"))
            con.commit()

            def finish_other():
                time.sleep(1)
                c2 = sqlite3.connect(str(cfg.db_path))
                c2.execute("INSERT INTO cache(email,status,sub_status,verified_at,source) VALUES (?,?,?,?,?)",
                           ("a@example.com", "valid", "", datetime.now(timezone.utc).isoformat(), "web"))
                c2.execute("DELETE FROM inflight WHERE email = ?", ("a@example.com",))
                c2.commit()
            t = threading.Thread(target=finish_other)
            t.start()
            r = g.verify("a@example.com", "web", "run-a")
            t.join()
            self.assertEqual((r["status"], r["charged"]), ("valid", False))
            self.assertEqual(g.remote_calls, [])

    def test_calling_row_is_not_counted_twice(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3", run=10, day=10)
            g = FakeGuard(cfg)
            with g._connect() as con:
                con.execute("INSERT INTO usage(used_at,usage_date,run_id,email,status,source) VALUES (?,?,?,?,?,?)",
                            (zg._iso_now(), zg._utc_now().date().isoformat(), "run-a", "a@example.com", "attempted", "web"))
                con.execute("INSERT INTO inflight(email,reserved_at,run_id,phase) VALUES (?,?,?,'calling')",
                            ("a@example.com", time.time(), "run-a"))
                self.assertEqual(g._budget_counts(con, "run-a"), (1, 1, 0, 0))

    # ---- fail closed, reserve, TTL ----
    def test_fail_closed_and_reserve(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3")
            g = FakeGuard(cfg, credits=None)
            self.assertEqual(g.verify("a@example.com", "web", "run-a")["reason"], "credit_check_failed")
            g.credits = 50
            g.config.min_balance = 100
            self.assertEqual(g.verify("a@example.com", "web", "run-a")["reason"], "reserve_reached")
            self.assertEqual(g.remote_calls, [])
            self.assertEqual(sqlite3.connect(str(cfg.db_path)).execute("SELECT COUNT(*) FROM inflight").fetchone()[0], 0)

    def test_unknown_ttl_and_retry_unknown(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = self.make_config(Path(td) / "guard.sqlite3", run=10, day=10)
            g = FakeGuard(cfg, verdict="unknown")
            g.verify("a@example.com", "web", "run-a")
            self.assertTrue(g.verify("a@example.com", "web", "run-a")["cached"])
            old = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
            sqlite3.connect(str(cfg.db_path)).execute("UPDATE cache SET verified_at = ?", (old,)).connection.commit()
            g.verify("a@example.com", "web", "run-a")
            self.assertEqual(len(g.remote_calls), 2)

    def test_lookup_is_free_and_budget_reports_settings(self):
        with tempfile.TemporaryDirectory() as td:
            g = FakeGuard(self.make_config(Path(td) / "guard.sqlite3"))
            g.verify("a@example.com", "web", "run-a")
            out = g.lookup(["A@example.com", "b@example.com"])
            self.assertTrue(out["a@example.com"]["fresh"])
            self.assertIsNone(out["b@example.com"])
            self.assertEqual(len(g.remote_calls), 1)
            b = g.budget("run-a")
            self.assertTrue(b["enabled"])
            self.assertIn("ZB_MAX_PER_RUN", b["settings"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
