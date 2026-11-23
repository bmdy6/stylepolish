"""Real loopback HTTP/SSE, fake upstream only. No ports are published externally."""
import asyncio
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

import httpx
from starlette.applications import Starlette
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route
import uvicorn

from stylepolish_relay.app import create_app
from stylepolish_relay.config import Settings, Prices


class SocketTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_uvicorn_disconnect_preserves_actual_usage(self):
        servers, threads = [], []
        def start(app):
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            server = uvicorn.Server(uvicorn.Config(app, log_config=None, access_log=False, lifespan="on"))
            thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
            servers.append(server)
            threads.append(thread)
            thread.start()
            deadline = time.monotonic() + 5
            while not server.started and thread.is_alive() and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertTrue(server.started)
            return port

        async def upstream(request):
            self.assertEqual(request.headers["authorization"], "Bearer fake-loopback-key")
            body = await request.json()
            tokens = {"prompt_tokens": 30, "completion_tokens": 12,
                      "prompt_tokens_details": {"cached_tokens": 10}}
            if not body.get("stream"):
                return JSONResponse({"choices": [], "usage": tokens})
            async def events():
                yield b'data: {"choices":[{"delta":{"content":"fake text"}}]}\n\n'
                await asyncio.sleep(0.1)
                yield b"data: " + json.dumps({"usage": tokens}).encode() + b"\n\n"
                yield b"data: [DONE]\n\n"
            return StreamingResponse(events(), media_type="text/event-stream")

        try:
            upstream_port = start(Starlette(routes=[Route("/v1/chat/completions", upstream, methods=["POST"])]))
            with tempfile.TemporaryDirectory() as tmp:
                settings = Settings(database=Path(tmp) / "relay.db", prices=Prices("2", "0.5", "8"),
                                    upstream_url=f"http://127.0.0.1:{upstream_port}/v1/chat/completions", upstream_timeout=2)
                app = create_app(settings, key="fake-loopback-key")
                code = app.state.service.ledger.create("socket test")
                port = start(app)
                headers = {"Authorization": "Bearer " + code,
                           "X-StylePolish-Device": "00112233-4455-4677-8899-aabbccddeeff"}
                body = {"messages": [{"role": "user", "content": "fake text"}]}
                async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}", trust_env=False) as client:
                    response = await client.post("/v1/chat/completions", headers=headers, json=body)
                    self.assertEqual(response.status_code, 200)
                    async with client.stream("POST", "/v1/chat/completions", headers=headers,
                                             json={**body, "stream": True}) as response:
                        self.assertEqual(response.status_code, 200)
                        async for line in response.aiter_lines():
                            if "fake text" in line:
                                break
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        rows = app.state.service.ledger.usage()
                        if rows[0]["pending"] == 0:
                            break
                        await asyncio.sleep(0.01)
                    self.assertEqual(rows[0]["pending"], 0)
                    self.assertEqual(rows[0]["estimated"], 0)
                    self.assertEqual(rows[0]["calls"], 2)
                    with app.state.service.ledger.connection() as db:
                        last = db.execute("SELECT status,cost FROM requests ORDER BY id DESC LIMIT 1").fetchone()
                    self.assertEqual(last["status"], 499)
                    self.assertEqual(last["cost"], settings.prices.cost(30, 10, 12))
                # Shutdown before removing the SQLite directory.
                servers[-1].should_exit = True
                await asyncio.to_thread(threads[-1].join, 5)
                self.assertFalse(threads[-1].is_alive())
        finally:
            for server in servers:
                server.should_exit = True
            for thread in threads:
                await asyncio.to_thread(thread.join, 5)
                self.assertFalse(thread.is_alive())
