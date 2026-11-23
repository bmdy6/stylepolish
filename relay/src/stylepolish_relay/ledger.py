"""SQLite is the sole owner of admission and spend, including in-flight calls."""
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
import os
import secrets
import sqlite3

from .config import Settings, money, usd


class Denied(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def month_key(now: float) -> str:
    return datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m")


class Ledger:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.path = Path(settings.database)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Create without a permissive window; SQLite journal inherits DB permissions.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        os.chmod(self.path, 0o600)
        with self.connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS invites (
                    code TEXT PRIMARY KEY, note TEXT NOT NULL, budget INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS requests (
                    id INTEGER PRIMARY KEY, code TEXT NOT NULL REFERENCES invites(code),
                    device_hash TEXT NOT NULL, started REAL NOT NULL, month TEXT NOT NULL,
                    prompt INTEGER NOT NULL, cached INTEGER NOT NULL DEFAULT 0,
                    output INTEGER NOT NULL, cost INTEGER NOT NULL,
                    status INTEGER NOT NULL DEFAULT 0, accounting TEXT NOT NULL DEFAULT 'reserved'
                );
                CREATE INDEX IF NOT EXISTS requests_code_time ON requests(code, started);
                CREATE INDEX IF NOT EXISTS requests_month ON requests(month);
            ''')

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            yield db
        finally:
            db.close()

    def create(self, note: str, budget: str | None = None) -> str:
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        if len(note) > 500:
            raise ValueError("Note is too long")
        amount = money(self.settings.invite_usd if budget is None else budget)
        with self.connection() as db:
            for _ in range(10):
                letters = "".join(secrets.choice(alphabet) for _ in range(8))
                code = f"SP-{letters[:4]}-{letters[4:]}"
                try:
                    db.execute("INSERT INTO invites(code,note,budget) VALUES(?,?,?)", (code, note, amount))
                    return code
                except sqlite3.IntegrityError:
                    continue
        raise RuntimeError("Could not generate invite")

    def revoke(self, code: str):
        with self.connection() as db:
            if not db.execute("UPDATE invites SET revoked=1 WHERE code=?", (code,)).rowcount:
                raise Denied("invite_invalid")

    def invite(self, code: str) -> dict:
        with self.connection() as db:
            row = db.execute('''SELECT i.*, COALESCE(SUM(r.cost),0) AS spent
                FROM invites i LEFT JOIN requests r ON r.code=i.code
                WHERE i.code=? GROUP BY i.code''', (code,)).fetchone()
        if row is None:
            raise Denied("invite_invalid")
        remaining = max(0, row["budget"] - row["spent"])
        status = "revoked" if row["revoked"] else "exhausted" if not remaining else "active"
        return {"status": status, "remaining_percent": remaining * 100 // row["budget"] if row["budget"] else 0}

    def check(self, db, code: str, now: float, amount: int = 0):
        row = db.execute("SELECT * FROM invites WHERE code=?", (code,)).fetchone()
        if row is None or row["revoked"]:
            raise Denied("invite_invalid")
        spent = db.execute("SELECT COALESCE(SUM(cost),0) FROM requests WHERE code=?", (code,)).fetchone()[0]
        if spent >= row["budget"] or spent + amount > row["budget"]:
            raise Denied("invite_exhausted")
        total = db.execute("SELECT COALESCE(SUM(cost),0) FROM requests WHERE month=?", (month_key(now),)).fetchone()[0]
        cap = money(self.settings.monthly_usd)
        if total >= cap or total + amount > cap:
            raise Denied("monthly_cap_reached")
        count = db.execute("SELECT COUNT(*) FROM requests WHERE code=? AND started>?", (code, now - 60)).fetchone()[0]
        if count >= self.settings.requests_per_minute:
            raise Denied("rate_limited")

    def precheck(self, code: str, now: float):
        with self.connection() as db:
            self.check(db, code, now)

    def reserve(self, code: str, device: str, amount: int, prompt: int, output: int, now: float) -> int:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db, code, now, amount)
            row = db.execute('''INSERT INTO requests(code,device_hash,started,month,prompt,output,cost)
                VALUES(?,?,?,?,?,?,?)''', (code, device, now, month_key(now), prompt, output, amount))
            db.execute("COMMIT")
            return row.lastrowid

    def settle(self, row: int, prompt: int, cached: int, output: int, cost: int, status: int, accounting: str):
        with self.connection() as db:
            db.execute('''UPDATE requests SET prompt=?,cached=?,output=?,cost=?,status=?,accounting=?
                WHERE id=? AND accounting='reserved' ''', (prompt, cached, output, cost, status, accounting, row))

    def usage(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute('''SELECT i.*, COALESCE(SUM(r.cost),0) AS spent,
                COUNT(r.id) AS calls, COALESCE(SUM(r.prompt),0) AS prompt,
                COALESCE(SUM(r.cached),0) AS cached, COALESCE(SUM(r.output),0) AS output,
                COALESCE(SUM(r.accounting='reserved'),0) AS pending,
                COALESCE(SUM(r.accounting='estimated'),0) AS estimated
                FROM invites i LEFT JOIN requests r ON r.code=i.code GROUP BY i.code ORDER BY i.code''').fetchall()
        return [{"code": r["code"], "note": r["note"], "revoked": bool(r["revoked"]),
                 "budget_usd": usd(r["budget"]), "spent_usd": usd(r["spent"]),
                 **{k: r[k] for k in ("calls", "prompt", "cached", "output", "pending", "estimated")}} for r in rows]

    def month(self, now: float) -> dict:
        month = month_key(now)
        with self.connection() as db:
            row = db.execute('''SELECT COALESCE(SUM(cost),0) AS spent, COUNT(*) AS calls,
                COALESCE(SUM(accounting='reserved'),0) AS pending,
                COALESCE(SUM(accounting='estimated'),0) AS estimated FROM requests WHERE month=?''', (month,)).fetchone()
        return {"month": month, "spent_usd": usd(row["spent"]), "cap_usd": self.settings.monthly_usd,
                **{key: row[key] for key in ("calls", "pending", "estimated")}}
