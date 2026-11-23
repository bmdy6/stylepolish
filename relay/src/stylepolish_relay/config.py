"""Non-secret configuration and exact USD arithmetic."""
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
import json
import os
import tomllib
from urllib.parse import urlsplit

SCALE = 10**12


def money(value: str) -> int:
    try:
        number = Decimal(str(value))
        scaled = number * SCALE
        if not number.is_finite() or number < 0 or number > 1_000_000 or scaled != scaled.to_integral_value():
            raise ValueError
        return int(scaled)
    except (InvalidOperation, ValueError, OverflowError):
        raise ValueError("Invalid USD amount") from None


def usd(amount: int) -> str:
    text = format(Decimal(amount) / SCALE, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


@dataclass(frozen=True)
class Prices:
    input: str
    cached_input: str
    output: str

    def __post_init__(self):
        for value in (self.input, self.cached_input, self.output):
            if money(value) % 10**6:
                raise ValueError("Prices support at most six decimal places")
        if money(self.input) == 0 or money(self.output) == 0:
            raise ValueError("Input and output prices must be positive")

    def cost(self, prompt: int, cached: int, output: int) -> int:
        return ((prompt - cached) * (money(self.input) // 10**6)
                + cached * (money(self.cached_input) // 10**6)
                + output * (money(self.output) // 10**6))

    def reserve(self, prompt: int, output: int) -> int:
        return prompt * max(money(self.input), money(self.cached_input)) // 10**6 + output * money(self.output) // 10**6


@dataclass(frozen=True)
class Settings:
    database: Path = Path("state/relay.db")
    host: str = "127.0.0.1"
    port: int = 8787
    upstream_url: str = "https://api.openai.com/v1/chat/completions"
    model: str = "gpt-6-luna"
    service_tier: str = "priority"
    key_env: str = "STYLEPOLISH_UPSTREAM_KEY"
    vault_path: Path = Path("~/.config/ai-vault/vault.json")
    vault_key: str = ""
    invite_usd: str = "3"
    monthly_usd: str = "30"
    requests_per_minute: int = 20
    input_chars: int = 2000
    body_bytes: int = 65536
    output_tokens: int = 2048
    response_bytes: int = 2097152
    upstream_timeout: float = 90
    prices: Prices | None = field(default=None)

    def __post_init__(self):
        money(self.invite_usd)
        money(self.monthly_usd)
        for value in (self.port, self.requests_per_minute, self.input_chars, self.body_bytes,
                      self.output_tokens, self.response_bytes):
            if type(value) is not int or not 0 < value <= 10_000_000:
                raise ValueError("Invalid numeric configuration")
        if not 0 < self.port < 65536 or not 0 < self.upstream_timeout <= 600:
            raise ValueError("Invalid port or timeout")
        url = urlsplit(self.upstream_url)
        if (url.scheme not in ("http", "https") or not url.hostname or url.username
                or url.password or url.query or url.fragment
                or (url.scheme == "http" and url.hostname not in ("127.0.0.1", "localhost", "::1"))):
            raise ValueError("Upstream must be HTTPS (HTTP allowed only on loopback)")
        if not self.model or not self.service_tier:
            raise ValueError("Model and service tier are required")

    @classmethod
    def load(cls, path: str | None = None):
        try:
            data = tomllib.loads(Path(path).read_text()) if path else {}
            if "prices" in data:
                data["prices"] = Prices(**data["prices"])
            for key in ("database", "vault_path"):
                if key in data:
                    data[key] = Path(data[key]).expanduser()
            return cls(**data)
        except Exception:
            # Never print parser exceptions: invalid config may contain a credential.
            raise ValueError("Invalid relay configuration") from None

    def credential(self) -> str:
        key = os.environ.get(self.key_env, "")
        if not key and self.vault_key:
            try:
                vault = json.loads(self.vault_path.expanduser().read_text())
                found = []

                def visit(node):
                    if isinstance(node, dict):
                        for name, value in node.items():
                            if name == self.vault_key and isinstance(value, dict):
                                found.append(value.get("value"))
                            else:
                                visit(value)
                visit(vault)
                if len(found) == 1 and isinstance(found[0], str):
                    key = found[0]
            except Exception:
                pass
        if not key or any(c.isspace() for c in key) or not key.isascii():
            raise ValueError("Upstream credential unavailable")
        return key
