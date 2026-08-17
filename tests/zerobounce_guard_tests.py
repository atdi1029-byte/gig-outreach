#!/usr/bin/env python3
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from zerobounce_guard import GuardConfig, ZeroBounceGuard


class FakeGuard(ZeroBounceGuard):
    def __init__(self, config, fail_emails=None):
        self.remote_calls = []
        self.fail_emails = set(fail_emails or [])
        super().__init__(config)

    def get_credits(self):
        return 1000

    def _validate_remote(self, email):
        self.remote_calls.append(email)
        if email in self.fail_emails:
            raise TimeoutError("simulated timeout")
        return {"status": "valid", "sub_status": ""}


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
