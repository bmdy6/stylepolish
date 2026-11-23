import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from stylepolish_relay.config import Settings, Prices, money
from stylepolish_relay.ledger import Ledger, Denied


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.db"
        self.now = datetime(2026, 11, 30, 23, 59, tzinfo=timezone.utc).timestamp()
        self.settings = Settings(database=self.path, invite_usd="3", monthly_usd="5")
        self.ledger = Ledger(self.settings)
        self.code = self.ledger.create("tester")

    def reserve(self, amount=money("1"), code=None, now=None):
        return self.ledger.reserve(code or self.code, "hashed-device", amount, 10, 20,
                                   self.now if now is None else now)

    def test_exact_last_call_then_exhausted(self):
        row = self.reserve(money("3"))
        self.ledger.settle(row, 10, 0, 20, money("3"), 200, "actual")
        self.assertEqual(self.ledger.invite(self.code)["remaining_percent"], 0)
        with self.assertRaises(Denied) as cm:
            self.reserve(1)
        self.assertEqual(cm.exception.code, "invite_exhausted")

    def test_concurrent_invite_reservations_do_not_overrun(self):
        def attempt(_):
            try:
                return Ledger(self.settings).reserve(self.code, "hash", money("1"), 1, 1, self.now)
            except Denied:
                return None
        with ThreadPoolExecutor(max_workers=12) as pool:
            admitted = list(pool.map(attempt, range(24)))
        self.assertEqual(sum(x is not None for x in admitted), 3)
        self.assertEqual(self.ledger.usage()[0]["spent_usd"], "3")

    def test_concurrent_global_cap_across_codes(self):
        codes = [self.ledger.create("") for _ in range(12)]
        def attempt(code):
            try:
                return self.reserve(code=code)
            except Denied as error:
                self.assertEqual(error.code, "monthly_cap_reached")
        with ThreadPoolExecutor(max_workers=12) as pool:
            admitted = list(pool.map(attempt, codes))
        self.assertEqual(sum(x is not None for x in admitted), 5)

    def test_utc_month_resets_but_invite_lifetime_does_not(self):
        self.reserve(money("3"))
        other = self.ledger.create("")
        self.reserve(money("2"), other)
        with self.assertRaises(Denied) as cm:
            self.reserve(1, other)
        self.assertEqual(cm.exception.code, "monthly_cap_reached")
        december = datetime(2026, 12, 1, tzinfo=timezone.utc).timestamp()
        self.assertEqual(self.ledger.month(december)["spent_usd"], "0")
        self.reserve(money("1"), other, december)
        with self.assertRaises(Denied) as cm:
            self.reserve(1, now=december)
        self.assertEqual(cm.exception.code, "invite_exhausted")

    def test_late_settlement_belongs_to_admission_month(self):
        row = self.reserve()
        self.ledger.settle(row, 1, 0, 2, money("0.5"), 200, "actual")
        self.assertEqual(self.ledger.month(self.now)["spent_usd"], "0.5")
        self.assertEqual(self.ledger.month(self.now + 120)["spent_usd"], "0")

    def test_settlement_is_idempotent_and_restart_retains_reserve(self):
        row = self.reserve()
        reopened = Ledger(self.settings)
        self.assertEqual(reopened.usage()[0]["pending"], 1)
        reopened.settle(row, 4, 1, 2, money("0.4"), 200, "actual")
        reopened.settle(row, 4, 1, 2, money("0.4"), 200, "actual")
        self.assertEqual(reopened.usage()[0]["spent_usd"], "0.4")

    def test_cached_price_is_not_double_counted(self):
        prices = Prices("2", "0.5", "8")
        self.assertEqual(prices.cost(1000, 600, 200), money("0.0027"))

    def test_revoked_status_and_generation_format(self):
        import re
        self.assertRegex(self.code, r"^SP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$")
        self.ledger.revoke(self.code)
        self.assertEqual(self.ledger.invite(self.code)["status"], "revoked")
        with self.assertRaises(Denied) as cm:
            self.reserve()
        self.assertEqual(cm.exception.code, "invite_invalid")

    def test_rate_limit_is_persistent_and_sliding(self):
        for _ in range(20):
            row = self.reserve(1)
            self.ledger.settle(row, 0, 0, 0, 0, 200, "actual")
        with self.assertRaises(Denied) as cm:
            self.reserve(1)
        self.assertEqual(cm.exception.code, "rate_limited")
        self.reserve(1, now=self.now + 60)
