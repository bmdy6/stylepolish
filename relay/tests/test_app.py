import asyncio
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import time
import unittest
from unittest.mock import patch
from uuid import UUID

import httpx
from stylepolish_relay.app import create_app
from stylepolish_relay.config import Settings, Prices, money

SECRET = "fake-upstream-secret-sentinel"
TEXT = "private-body-sentinel"
DEVICE = "00112233-4455-4677-8899-aabbccddeeff"
USAGE = {"prompt_tokens": 20, "completion_tokens": 10, "prompt_tokens_details": {"cached_tokens": 5}}


def payload(stream=False):
    return {"messages": [{"role": "system", "content": "rules"}, {"role": "user", "content": TEXT}],
            "model": "untrusted-model", "service_tier": "untrusted-tier", "stream": stream,
            "max_completion_tokens": 20}


def event(data):
    return b"data: " + json.dumps(data).encode() + b"\n\n"


class FakeStream(httpx.AsyncByteStream):
    def __init__(self, parts, error=False, gate=None):
        self.parts, self.error, self.gate = parts, error, gate
        self.closed = False

    async def __aiter__(self):
        for index, part in enumerate(self.parts):
            if index and self.gate:
                await self.gate.wait()
            await asyncio.sleep(0)
            yield part
        if self.error:
            raise httpx.ReadError(TEXT + SECRET)

    async def aclose(self):
        self.closed = True


class AppTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # A test that accidentally leaves the fake transport cannot reach the network.
        self.network = patch.object(socket.socket, "connect", side_effect=AssertionError("Live network forbidden"))
        self.network.start()
        self.addCleanup(self.network.stop)
        self.settings = Settings(database=Path(self.tmp.name) / "relay.db", prices=Prices("2", "0.5", "8"))
        self.seen = []
        self.handler = self.success
        self.app = create_app(self.settings, key=SECRET, transport=httpx.MockTransport(self.upstream))
        self.service = self.app.state.service
        self.ledger = self.service.ledger
        self.code = self.ledger.create("offline tester")
        self.headers = {"Authorization": "Bearer " + self.code, "X-StylePolish-Device": DEVICE}
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://relay.test")

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.service.close()

    async def upstream(self, request):
        self.seen.append(request)
        result = self.handler(request)
        return await result if hasattr(result, "__await__") else result

    def success(self, request):
        return httpx.Response(200, json={"choices": [{"message": {"content": TEXT}}], "usage": USAGE})

    async def post(self, body=None, headers=None):
        return await self.client.post("/v1/chat/completions", json=payload() if body is None else body,
                                      headers=self.headers if headers is None else headers)

    def row(self):
        with self.ledger.connection() as db:
            return dict(db.execute("SELECT * FROM requests ORDER BY id DESC LIMIT 1").fetchone())

    def error(self, response, status, code):
        self.assertEqual(response.status_code, status, response.text)
        self.assertEqual(response.json()["error"]["code"], code)
        self.assertNotIn(TEXT, response.text)
        self.assertNotIn(SECRET, response.text)

    async def test_raw_success_model_tier_override_and_actual_cached_charge(self):
        expected = self.success(None).content
        response = await self.post()
        self.assertEqual(response.content, expected)
        sent = json.loads(self.seen[0].content)
        self.assertEqual(sent["model"], self.settings.model)
        self.assertEqual(sent["service_tier"], self.settings.service_tier)
        self.assertFalse(sent["store"])
        self.assertEqual(self.seen[0].headers["authorization"], "Bearer " + SECRET)
        self.assertNotIn("x-stylepolish-device", self.seen[0].headers)
        self.assertEqual(self.row()["cost"], self.settings.prices.cost(20, 5, 10))
        self.assertEqual(self.row()["accounting"], "actual")
        response = await self.client.get("/v1/invite", headers=self.headers)
        self.assertEqual(response.json()["status"], "active")
        self.assertEqual(set(response.json()), {"status", "remaining_percent"})

    async def test_invalid_unknown_revoked_and_missing_device(self):
        for headers in ({}, {**self.headers, "Authorization": "Bearer SP-AAAA-BBBB"},
                        {"Authorization": self.headers["Authorization"]},
                        {**self.headers, "X-StylePolish-Device": "bad"}):
            with self.subTest(headers=list(headers)):
                self.error(await self.post(headers=headers), 401, "invite_invalid")
        self.ledger.revoke(self.code)
        self.error(await self.post(), 401, "invite_invalid")
        self.assertEqual((await self.client.get("/v1/invite", headers=self.headers)).json(),
                         {"status": "revoked", "remaining_percent": 100})
        self.assertFalse(self.seen)

    async def test_invite_and_monthly_errors(self):
        row = self.ledger.reserve(self.code, "hash", money("3"), 1, 1, time.time())
        self.error(await self.post(), 403, "invite_exhausted")
        self.ledger.settle(row, 0, 0, 0, 0, 502, "actual")
        with self.ledger.connection() as db:
            db.execute("UPDATE requests SET cost=? WHERE id=?", (money("30"), row))
        other = self.ledger.create("")
        self.error(await self.post(headers={**self.headers, "Authorization": "Bearer " + other}), 403, "monthly_cap_reached")
        self.assertFalse(self.seen)

    async def test_rate_error_precedes_length_and_never_calls_upstream(self):
        for _ in range(20):
            row = self.ledger.reserve(self.code, "hash", 1, 1, 1, time.time())
            self.ledger.settle(row, 0, 0, 0, 0, 200, "actual")
        body = payload()
        body["messages"][1]["content"] = "字" * 2001
        self.error(await self.post(body), 429, "rate_limited")
        self.assertFalse(self.seen)

    async def test_input_limit_counts_user_text_not_system_rules(self):
        body = payload()
        body["messages"][0]["content"] = "rules" * 1000
        body["messages"][1]["content"] = "字" * 2000
        self.assertEqual((await self.post(body)).status_code, 200)
        body["messages"][1]["content"] += "字"
        self.error(await self.post(body), 413, "input_too_long")
        self.assertEqual(len(self.seen), 1)

    async def test_oversized_body_and_malformed_or_billable_options(self):
        response = await self.client.post("/v1/chat/completions", content=b"x" * 65537, headers=self.headers)
        self.error(response, 413, "input_too_long")
        for body in ([], {"messages": []}, {**payload(), "n": 2}, {**payload(), "tools": []},
                     {**payload(), "max_completion_tokens": -1}, {**payload(), "stream": "yes"}):
            with self.subTest(body=type(body).__name__):
                self.error(await self.post(body), 400, "invalid_request")
        response = await self.client.post("/v1/chat/completions", content=b"{", headers=self.headers)
        self.error(response, 400, "invalid_request")
        self.assertFalse(self.seen)

    async def test_upstream_http_errors_are_sanitized_and_release_reserve(self):
        for status in (400, 401, 403, 429, 500, 302):
            with self.subTest(status=status):
                self.handler = lambda r: httpx.Response(status, text=TEXT + SECRET,
                                                        headers={"location": "https://example.invalid"})
                self.error(await self.post(), 502, "upstream_error")
                self.assertEqual(self.row()["cost"], 0)
        self.assertEqual(len(self.seen), 6)

    async def test_timeout_and_missing_usage_keep_estimated_reservation(self):
        def fail(request):
            raise httpx.ReadTimeout(TEXT + SECRET)
        self.handler = fail
        self.error(await self.post(), 502, "upstream_error")
        self.assertEqual(self.row()["accounting"], "estimated")
        self.assertGreater(self.row()["cost"], 0)
        self.handler = lambda r: httpx.Response(200, json={"choices": []})
        self.error(await self.post(), 502, "upstream_error")
        self.assertEqual(self.row()["accounting"], "estimated")

    async def test_raw_sse_fragmented_usage_and_done(self):
        raw = event({"choices": [{"delta": {"content": TEXT}}]}) + event({"usage": USAGE}) + b"data: [DONE]\n\n"
        stream = FakeStream([raw[:9], raw[9:30], raw[30:]])
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await self.post(payload(True))
        self.assertEqual(response.content, raw)
        self.assertTrue(json.loads(self.seen[0].content)["stream_options"]["include_usage"])
        self.assertEqual(self.row()["accounting"], "actual")
        self.assertTrue(stream.closed)

    async def drive_disconnect(self, stream):
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        incoming = asyncio.Queue()
        await incoming.put({"type": "http.request", "body": json.dumps(payload(True)).encode(), "more_body": False})
        sent = []
        async def send(message):
            sent.append(message)
            if message["type"] == "http.response.body" and message.get("body"):
                await incoming.put({"type": "http.disconnect"})
                if stream.gate:
                    stream.gate.set()
        scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "method": "POST",
                 "path": "/v1/chat/completions", "raw_path": b"/v1/chat/completions", "query_string": b"",
                 "headers": [(k.lower().encode(), v.encode()) for k, v in self.headers.items()],
                 "scheme": "http", "server": ("relay.test", 80), "client": ("192.0.2.1", 1234), "http_version": "1.1"}
        await asyncio.wait_for(self.app(scope, incoming.get, send), timeout=2)
        return sent

    async def test_client_disconnect_drains_later_usage_and_charges_actual(self):
        gate = asyncio.Event()
        stream = FakeStream([event({"choices": [{"delta": {"content": TEXT}}]}),
                             event({"usage": USAGE}), b"data: [DONE]\n\n"], gate=gate)
        await self.drive_disconnect(stream)
        await self.service.drain()
        self.assertEqual(self.row()["accounting"], "actual")
        self.assertEqual(self.row()["status"], 499)
        self.assertEqual(self.row()["cost"], self.settings.prices.cost(20, 5, 10))
        self.assertTrue(stream.closed)

    async def test_upstream_stream_loss_without_usage_is_estimated(self):
        stream = FakeStream([event({"choices": [{"delta": {"content": TEXT}}]})], error=True)
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await self.post(payload(True))
        self.assertIn(b'"code":"upstream_error"', response.content)
        self.assertEqual(self.row()["accounting"], "estimated")
        self.assertGreater(self.row()["cost"], 0)

    async def test_upstream_loss_after_usage_charges_known_tokens(self):
        stream = FakeStream([event({"usage": USAGE})], error=True)
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        await self.post(payload(True))
        self.assertEqual(self.row()["accounting"], "actual")
        self.assertEqual(self.row()["cost"], self.settings.prices.cost(20, 5, 10))

    async def test_privacy_database_and_logs_never_contain_text_key_uuid_or_ip(self):
        with self.assertLogs(level="DEBUG") as logs:
            await self.post()
            self.handler = lambda r: httpx.Response(500, text=TEXT + SECRET)
            await self.post()
            stream = FakeStream([event({"choices": [{"delta": {"content": TEXT}}]})], error=True)
            self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
            await self.post(payload(True))
        serialized = "\n".join(logs.output).encode()
        for file in Path(self.tmp.name).iterdir():
            serialized += file.read_bytes()
        for value in (TEXT, SECRET, DEVICE, "192.0.2.1", "rules"):
            self.assertNotIn(value.encode(), serialized)
        self.assertEqual(self.row()["device_hash"], hashlib.sha256(UUID(DEVICE).bytes).hexdigest())

    async def test_http_exact_final_call_succeeds_then_rejects(self):
        from stylepolish_relay.protocol import prepare
        from stylepolish_relay.config import usd
        _, bound, output = prepare(json.dumps(payload()).encode(), self.settings)
        amount = self.settings.prices.reserve(bound, output)
        with self.ledger.connection() as db:
            db.execute("UPDATE invites SET budget=? WHERE code=?", (amount, self.code))
        self.handler = lambda r: httpx.Response(200, json={"usage": {"prompt_tokens": bound,
                                                                   "completion_tokens": output}})
        self.assertEqual((await self.post()).status_code, 200)
        self.assertEqual(self.ledger.usage()[0]["spent_usd"], usd(amount))
        self.assertEqual((await self.client.get("/v1/invite", headers=self.headers)).json(),
                         {"status": "exhausted", "remaining_percent": 0})
        self.error(await self.post(), 403, "invite_exhausted")
        self.assertEqual(len(self.seen), 1)

    async def test_http_concurrency_reserves_before_upstream(self):
        from stylepolish_relay.protocol import prepare
        _, bound, output = prepare(json.dumps(payload()).encode(), self.settings)
        amount = self.settings.prices.reserve(bound, output)
        with self.ledger.connection() as db:
            db.execute("UPDATE invites SET budget=? WHERE code=?", (amount, self.code))
        arrived, release = asyncio.Event(), asyncio.Event()
        async def delayed(request):
            arrived.set()
            await release.wait()
            return self.success(request)
        self.handler = delayed
        first = asyncio.create_task(self.post())
        await asyncio.wait_for(arrived.wait(), 1)
        rest = await asyncio.gather(*(self.post() for _ in range(15)))
        for response in rest:
            self.error(response, 403, "invite_exhausted")
        release.set()
        self.assertEqual((await first).status_code, 200)
        self.assertEqual(len(self.seen), 1)

    async def test_slow_stream_deadline_retains_estimate_and_closes(self):
        self.service.settings = replace(self.settings, upstream_timeout=0.02)
        stream = FakeStream([event({"choices": []}), event({"usage": USAGE})], gate=asyncio.Event())
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await asyncio.wait_for(self.post(payload(True)), 1)
        self.assertIn(b'"code":"upstream_error"', response.content)
        self.assertEqual(self.row()["accounting"], "estimated")
        self.assertTrue(stream.closed)

    async def test_missing_usage_done_is_not_forwarded_as_success(self):
        stream = FakeStream([event({"choices": []}), b"data: [DONE]\n\n"])
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await self.post(payload(True))
        self.assertNotIn(b"[DONE]", response.content)
        self.assertIn(b'"code":"upstream_error"', response.content)
        self.assertEqual(self.row()["accounting"], "estimated")

    async def test_usage_done_does_not_wait_for_upstream_socket_close(self):
        gate = asyncio.Event()
        stream = FakeStream([event({"usage": USAGE}) + b"data: [DONE]\n\n", b"ignored"], gate=gate)
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await asyncio.wait_for(self.post(payload(True)), 0.5)
        self.assertIn(b"[DONE]", response.content)
        self.assertEqual(self.row()["accounting"], "actual")
        self.assertTrue(stream.closed)

    async def test_split_upstream_sse_error_cannot_leak_secret(self):
        raw = event({"error": {"message": SECRET + TEXT}})
        stream = FakeStream([raw[:-2], raw[-2:]])
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await self.post(payload(True))
        self.assertNotIn(SECRET.encode(), response.content)
        self.assertNotIn(TEXT.encode(), response.content)
        self.assertIn(b'"code":"upstream_error"', response.content)

    async def test_multiline_crlf_sse_preserves_event_bytes(self):
        raw = b': heartbeat\r\n\r\ndata: {"usage":\r\ndata: ' + json.dumps(USAGE).encode() + b'}\r\n\r\ndata: [DONE]\r\n\r\n'
        stream = FakeStream([raw[:25], raw[25:37], raw[37:]])
        self.handler = lambda r: httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        response = await self.post(payload(True))
        self.assertEqual(response.content, raw)
        self.assertEqual(self.row()["accounting"], "actual")

    async def test_upstream_200_error_envelope_is_sanitized(self):
        self.handler = lambda r: httpx.Response(200, json={"error": {"message": SECRET + TEXT}, "usage": USAGE})
        self.error(await self.post(), 502, "upstream_error")
        self.assertEqual(self.row()["cost"], self.settings.prices.cost(20, 5, 10))

    async def test_client_cannot_raise_output_cap_and_legacy_limit_is_normalized(self):
        body = payload()
        body["max_completion_tokens"] = 999999
        await self.post(body)
        self.assertEqual(json.loads(self.seen[-1].content)["max_completion_tokens"], 2048)
        body.pop("max_completion_tokens")
        body["max_tokens"] = 7
        await self.post(body)
        sent = json.loads(self.seen[-1].content)
        self.assertEqual(sent["max_completion_tokens"], 7)
        self.assertNotIn("max_tokens", sent)

    async def test_oversized_response_is_bounded_and_keeps_reservation(self):
        self.service.settings = replace(self.settings, response_bytes=64)
        self.error(await self.post(), 502, "upstream_error")
        self.assertEqual(self.row()["accounting"], "estimated")
        self.assertGreater(self.row()["cost"], 0)
