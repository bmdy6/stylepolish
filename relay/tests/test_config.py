from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from stylepolish_relay.config import Settings, Prices, money, usd
from stylepolish_relay.cli import main


class ConfigTests(unittest.TestCase):
    def test_integer_money_formats_without_losing_trailing_zero(self):
        for value in ("30", "0.003", "100", "3", "0"):
            self.assertEqual(usd(money(value)), value)

    def test_invalid_money_and_config(self):
        for value in ("NaN", "Infinity", "-1", "0.0000000000001"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                money(value)
        with self.assertRaises(ValueError):
            Prices("0", "0", "1")
        for url in ("http://remote.test/v1", "https://key@host/v1", "https://host/v1?key=secret"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                Settings(upstream_url=url)

    def test_env_precedes_vault_and_vault_key_is_unique(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "vault.json"
            path.write_text(json.dumps({"group": {"service": {"MY_KEY": {"value": "fake-vault"}}}}))
            settings = Settings(vault_path=path, vault_key="MY_KEY", key_env="TEST_RELAY_KEY")
            with patch.dict(os.environ, {"TEST_RELAY_KEY": "fake-env"}):
                self.assertEqual(settings.credential(), "fake-env")
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(settings.credential(), "fake-vault")
                path.write_text('{"a":{"MY_KEY":{"value":"secret"}},"b":{"MY_KEY":{"value":"other"}}}')
                with self.assertRaisesRegex(ValueError, "^Upstream credential unavailable$"):
                    settings.credential()

    def test_config_parse_error_does_not_echo_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text('unexpected = "sensitive-config-sentinel"')
            with self.assertRaisesRegex(ValueError, "^Invalid relay configuration$"):
                Settings.load(str(path))

    def test_cli_create_note_usage_month_revoke_without_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text('database = "' + str(Path(tmp) / "relay.db") + '"\n')
            def run(*args):
                out = StringIO()
                with redirect_stdout(out), patch.dict(os.environ, {}, clear=True):
                    self.assertEqual(main(["--config", str(path), *args]), 0)
                return json.loads(out.getvalue())
            code = run("create", "--note", "offline friend")["code"]
            self.assertEqual(run("usage")[0]["note"], "offline friend")
            self.assertEqual(run("month")["spent_usd"], "0")
            run("revoke", code)
            self.assertTrue(run("usage")[0]["revoked"])

    def test_serve_without_prices_fails_closed_without_reading_key(self):
        with patch.object(Settings, "credential", side_effect=AssertionError("must not read credential")):
            err = StringIO()
            with redirect_stderr(err):
                self.assertEqual(main(["serve"]), 1)
            self.assertIn("prices", err.getvalue().lower())

    def test_launcher_uses_configured_host_port_without_access_logging(self):
        import asyncio
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text('database = "' + str(Path(tmp) / "relay.db") + '"\nport = 19876\n'
                            '[prices]\ninput = "1"\ncached_input = "0.5"\noutput = "2"\n')
            seen = {}
            def run(app, **kwargs):
                seen.update(kwargs)
                asyncio.run(app.state.service.close())
            with patch.dict(os.environ, {"STYLEPOLISH_UPSTREAM_KEY": "fake-only"}), patch("uvicorn.run", run):
                self.assertEqual(main(["--config", str(path), "serve"]), 0)
            self.assertEqual(seen["host"], "127.0.0.1")
            self.assertEqual(seen["port"], 19876)
            self.assertFalse(seen["access_log"])
