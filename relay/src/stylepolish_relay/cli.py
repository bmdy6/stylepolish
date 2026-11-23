"""Local operator commands; only serve reads the upstream credential."""
import argparse
import json
import logging
import os
import sys
import time

from .config import Settings
from .ledger import Ledger


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="StylePolish invite relay")
    parser.add_argument("--config", help="TOML file (no credentials in this file)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("serve", help="Start the relay on configured host/port")
    create = commands.add_parser("create", help="Generate an invite")
    create.add_argument("--note", default="", help="Optional administrative note; do not put text or secrets here")
    create.add_argument("--budget-usd", help="Override this invite's lifetime budget")
    revoke = commands.add_parser("revoke", help="Revoke one invite")
    revoke.add_argument("code")
    commands.add_parser("usage", help="List lifetime usage for every invite")
    commands.add_parser("month", help="Show current UTC month's spend, including reservations")
    args = parser.parse_args(argv)
    try:
        settings = Settings.load(args.config)
        if args.command == "serve":
            if settings.prices is None:
                raise ValueError("Configure billing prices before serving")
            from .app import create_app
            import uvicorn
            # No access logs (IP/query) or transport debug traces (headers/body).
            os.umask(0o077)
            logging.basicConfig(level=logging.INFO, format="%(name)s %(message)s")
            for name in ("httpx", "httpcore", "uvicorn.access"):
                logger = logging.getLogger(name)
                logger.disabled = True
                logger.propagate = False
            app = create_app(settings)
            uvicorn.run(app, host=settings.host, port=settings.port, access_log=False,
                        log_config=None, timeout_graceful_shutdown=int(settings.upstream_timeout) + 5)
            return 0
        ledger = Ledger(settings)
        if args.command == "create":
            result = {"code": ledger.create(args.note, args.budget_usd)}
        elif args.command == "revoke":
            ledger.revoke(args.code)
            result = {"status": "revoked"}
        elif args.command == "usage":
            result = ledger.usage()
        else:
            result = ledger.month(time.time())
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception:
        # argparse already emits safe usage errors; never print data-bearing exceptions.
        print("Relay command failed; check configuration, billing prices, credential source and database access.", file=sys.stderr)
        return 1
