"""Validate the supported text-only completion surface and inspect usage in memory."""
import json
import re

from .config import Settings
from .ledger import Denied


class InvalidRequest(Exception):
    pass


class UpstreamFailure(Exception):
    pass


def prepare(raw: bytes, settings: Settings) -> tuple[dict, int, int]:
    try:
        body = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        allowed = {"model", "service_tier", "messages", "stream", "stream_options", "max_tokens",
                   "max_completion_tokens", "n", "temperature", "top_p", "frequency_penalty",
                   "presence_penalty", "stop", "seed", "response_format", "reasoning_effort", "store"}
        if not isinstance(body, dict) or body.keys() - allowed:
            raise ValueError
        messages = body.get("messages")
        if not isinstance(messages, list) or not messages:
            raise ValueError
        chars, users = 0, 0
        for message in messages:
            if (not isinstance(message, dict) or message.keys() - {"role", "content", "name"}
                    or message.get("role") not in ("system", "developer", "user", "assistant")):
                raise ValueError
            content = message.get("content")
            if isinstance(content, list):
                if not content or any(not isinstance(p, dict) or set(p) != {"type", "text"}
                                      or p["type"] != "text" or not isinstance(p["text"], str) for p in content):
                    raise ValueError
                content = "".join(p["text"] for p in content)
            if not isinstance(content, str):
                raise ValueError
            if message["role"] == "user":
                users += 1
                chars += len(content)
        if not users:
            raise ValueError
        if chars > settings.input_chars:
            raise Denied("input_too_long")
        if type(body.get("stream", False)) is not bool or type(body.get("n", 1)) is not int or body.get("n", 1) != 1:
            raise ValueError
        if "max_tokens" in body and "max_completion_tokens" in body:
            raise ValueError
        output = body.pop("max_tokens", body.get("max_completion_tokens", settings.output_tokens))
        if type(output) is not int or output < 1:
            raise ValueError
        output = min(output, settings.output_tokens)
        body.update(model=settings.model, service_tier=settings.service_tier,
                    max_completion_tokens=output, store=False)
        if body.get("stream", False):
            body["stream_options"] = {"include_usage": True}
        else:
            body.pop("stream_options", None)
        # UTF-8 byte count overestimates ordinary byte-tokenized text, including all
        # schema/options. Extra framing covers message delimiters. Not a tokenizer.
        prompt_bound = len(json.dumps(body, ensure_ascii=False).encode("utf-8")) + 4096 + len(messages) * 64
        return body, prompt_bound, output
    except Denied:
        raise
    except (ValueError, TypeError, KeyError, RecursionError, UnicodeError):
        raise InvalidRequest from None


def usage(value) -> tuple[int, int, int]:
    try:
        prompt, output = value["prompt_tokens"], value["completion_tokens"]
        details = value.get("prompt_tokens_details") or {}
        cached = details.get("cached_tokens", 0)
        if any(type(v) is not int or v < 0 or v > 100_000_000 for v in (prompt, cached, output)) or cached > prompt:
            raise ValueError
        return prompt, cached, output
    except (TypeError, KeyError, ValueError, AttributeError):
        raise UpstreamFailure from None


class SSEUsage:
    def __init__(self, limit: int):
        self.buffer = b""
        self.limit = limit
        self.tokens = None
        self.done = False

    def feed(self, chunk: bytes) -> list[bytes]:
        self.buffer += chunk
        if len(self.buffer) > self.limit:
            raise UpstreamFailure
        frames = []
        while match := re.search(rb"\r?\n\r?\n", self.buffer):
            frame, self.buffer = self.buffer[:match.end()], self.buffer[match.end():]
            data_lines = []
            for line in frame.splitlines():
                if line.startswith(b"data:"):
                    value = line[5:]
                    data_lines.append(value[1:] if value.startswith(b" ") else value)
            if data_lines:
                data = b"\n".join(data_lines).strip()
                if data == b"[DONE]":
                    if self.tokens is None:
                        raise UpstreamFailure
                    self.done = True
                else:
                    try:
                        value = json.loads(data)
                    except (ValueError, UnicodeError, RecursionError):
                        raise UpstreamFailure from None
                    if not isinstance(value, dict) or "error" in value:
                        raise UpstreamFailure
                    if value.get("usage") is not None:
                        tokens = usage(value["usage"])
                        if self.tokens is not None and (tokens[0] < self.tokens[0] or tokens[2] < self.tokens[2]):
                            raise UpstreamFailure
                        self.tokens = tokens
            # Preserve each validated frame byte-for-byte, including line endings.
            # Never forward half an error event before its JSON can be inspected.
            frames.append(frame)
            if self.done:
                break
        return frames
