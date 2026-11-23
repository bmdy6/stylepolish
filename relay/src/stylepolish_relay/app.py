"""ASGI relay. Bodies live only in bounded memory; ledger data is metadata only."""
import asyncio
from contextlib import asynccontextmanager, suppress
import hashlib
import json
import logging
import time
from uuid import UUID

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .config import Settings
from .ledger import Ledger, Denied
from .protocol import InvalidRequest, UpstreamFailure, SSEUsage, prepare, usage

log = logging.getLogger("stylepolish_relay")
ERRORS = {
    "invite_invalid": (401, "邀请码无效"),
    "invite_exhausted": (403, "试用额度用完"),
    "monthly_cap_reached": (403, "本月试用已满"),
    "rate_limited": (429, "稍后再试"),
    "input_too_long": (413, "这段太长，请用本地规则"),
    "upstream_error": (502, "网络不通，请用本地规则"),
    "invalid_request": (400, "请求格式无效"),
}


def error(code: str) -> JSONResponse:
    status, message = ERRORS[code]
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status,
                        headers={"Cache-Control": "no-store"})


def identity(request: Request) -> tuple[str, str]:
    auth = request.headers.get("authorization", "")
    try:
        scheme, code = auth.split(" ")
        if scheme.lower() != "bearer" or not code or len(code) > 32:
            raise ValueError
        device = UUID(request.headers.get("x-stylepolish-device", ""))
    except ValueError:
        raise Denied("invite_invalid") from None
    return code, hashlib.sha256(device.bytes).hexdigest()


class Ticket:
    def __init__(self, service, row, prompt, output, reserved):
        self.service, self.row = service, row
        self.prompt, self.output, self.reserved = prompt, output, reserved
        self.finished = False

    def finish(self, tokens=None, status=502, rejected=False):
        if self.finished:
            return
        if rejected:
            prompt, cached, output, cost, state = 0, 0, 0, 0, "actual"
        elif tokens is not None:
            prompt, cached, output = tokens
            cost = self.service.settings.prices.cost(prompt, cached, output)
            state = "actual"
        else:
            prompt, cached, output, cost, state = self.prompt, 0, self.output, self.reserved, "estimated"
        self.service.ledger.settle(self.row, prompt, cached, output, cost, status, state)
        self.finished = True
        log.info("request settled status=%d accounting=%s", status, state)


class RelayStream(Response):
    """Drain upstream outside downstream cancellation, without retaining a transcript."""
    def __init__(self, service, response, ticket, deadline):
        super().__init__(status_code=response.status_code, media_type="text/event-stream",
                         headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})
        self.raw_headers = [(k, v) for k, v in self.raw_headers if k != b"content-length"]
        self.service, self.upstream, self.ticket, self.deadline = service, response, ticket, deadline
        self.queue = asyncio.Queue()
        self.disconnected = False

    async def pump(self):
        parser = SSEUsage(self.service.settings.response_bytes)
        size, status = 0, 200
        try:
            async with asyncio.timeout_at(self.deadline):
                async for chunk in self.upstream.aiter_bytes():
                    size += len(chunk)
                    if size > self.service.settings.response_bytes:
                        raise UpstreamFailure
                    frames = parser.feed(chunk)
                    if not self.disconnected:
                        for frame in frames:
                            self.queue.put_nowait(frame)
                    if parser.done:
                        break
                if not parser.done or parser.tokens is None:
                    raise UpstreamFailure
        except (Exception, asyncio.CancelledError):
            status = 502
            if not self.disconnected:
                self.queue.put_nowait(b"data: " + error("upstream_error").body + b"\n\n")
        finally:
            try:
                self.ticket.finish(parser.tokens, 499 if self.disconnected else status)
            finally:
                with suppress(Exception):
                    await self.upstream.aclose()
                self.queue.put_nowait(None)

    async def __call__(self, scope, receive, send):
        producer = self.service.track(self.pump())

        async def watch():
            while True:
                if (await receive())["type"] == "http.disconnect":
                    return

        watcher = asyncio.create_task(watch())
        getter = None
        try:
            await send({"type": "http.response.start", "status": self.status_code, "headers": self.raw_headers})
            while True:
                getter = asyncio.create_task(self.queue.get())
                done, _ = await asyncio.wait((getter, watcher), return_when=asyncio.FIRST_COMPLETED)
                if watcher in done:
                    self.disconnected = True
                    break
                chunk = getter.result()
                if chunk is None:
                    await send({"type": "http.response.body", "body": b"", "more_body": False})
                    break
                await send({"type": "http.response.body", "body": chunk, "more_body": True})
        except (Exception, asyncio.CancelledError):
            self.disconnected = True
        finally:
            watcher.cancel()
            if getter and not getter.done():
                getter.cancel()
            await asyncio.gather(watcher, *([getter] if getter else []), return_exceptions=True)
            # Drop queued text immediately on disconnect; pump continues to usage.
            if self.disconnected:
                while not self.queue.empty():
                    self.queue.get_nowait()
            # Do not propagate downstream cancellation into the billable upstream reader.
            if not self.disconnected:
                await asyncio.shield(producer)


class Service:
    def __init__(self, settings, key, transport=None, clock=time.time):
        if settings.prices is None:
            raise ValueError("Configure billing prices before serving")
        self.settings, self.clock = settings, clock
        self.ledger = Ledger(settings)
        self.client = httpx.AsyncClient(headers={"Authorization": "Bearer " + key},
                                        transport=transport, timeout=settings.upstream_timeout,
                                        follow_redirects=False, trust_env=False)
        self.tasks = set()

    def track(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)

        def completed(done):
            self.tasks.discard(done)
            if not done.cancelled() and done.exception() is not None:
                log.error("accounting task failed; reservation retained")

        task.add_done_callback(completed)
        return task

    async def drain(self):
        if self.tasks:
            await asyncio.gather(*tuple(self.tasks), return_exceptions=True)

    async def close(self):
        await self.drain()
        await self.client.aclose()

    async def invite(self, request):
        code, _ = identity(request)
        return JSONResponse(self.ledger.invite(code), headers={"Cache-Control": "no-store"})

    async def post(self, request):
        code, device = identity(request)
        self.ledger.precheck(code, self.clock())
        raw = bytearray()
        async with asyncio.timeout(10):
            async for chunk in request.stream():
                raw.extend(chunk)
                if len(raw) > self.settings.body_bytes:
                    raise Denied("input_too_long")
        body, prompt, output = prepare(raw, self.settings)
        amount = self.settings.prices.reserve(prompt, output)
        row = self.ledger.reserve(code, device, amount, prompt, output, self.clock())
        ticket = Ticket(self, row, prompt, output, amount)
        response, tokens = None, None
        deadline = asyncio.get_running_loop().time() + self.settings.upstream_timeout
        try:
            async with asyncio.timeout_at(deadline):
                upstream_request = self.client.build_request("POST", self.settings.upstream_url, json=body)
                response = await self.client.send(upstream_request, stream=True)
                if not 200 <= response.status_code < 300:
                    ticket.finish(status=502, rejected=True)
                    await response.aclose()
                    return error("upstream_error")
                if body.get("stream", False):
                    if response.headers.get("content-type", "").split(";")[0].strip() != "text/event-stream":
                        raise UpstreamFailure
                    return RelayStream(self, response, ticket, deadline)
                result = bytearray()
                async for chunk in response.aiter_bytes():
                    result.extend(chunk)
                    if len(result) > self.settings.response_bytes:
                        raise UpstreamFailure
                value = json.loads(result)
                tokens = usage(value.get("usage"))
                if "error" in value:
                    raise UpstreamFailure
                ticket.finish(tokens, response.status_code)
                await response.aclose()
                return Response(bytes(result), status_code=response.status_code, media_type="application/json",
                                headers={"Cache-Control": "no-store"})
        except (Exception, asyncio.CancelledError) as exc:
            ticket.finish(tokens)
            if response:
                with suppress(Exception):
                    await response.aclose()
            if isinstance(exc, asyncio.CancelledError):
                raise
            return error("upstream_error")


class SafeApp:
    def __init__(self, app):
        self.app, self.state = app, app.state

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        started = False

        async def guarded_send(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)
        try:
            await self.app(scope, receive, guarded_send)
        except Denied as exc:
            if not started:
                await error(exc.code)(scope, receive, send)
        except InvalidRequest:
            if not started:
                await error("invalid_request")(scope, receive, send)
        except Exception:
            if not started:
                await error("upstream_error")(scope, receive, send)


def create_app(settings: Settings, *, key: str | None = None, transport=None, clock=time.time):
    service = Service(settings, settings.credential() if key is None else key, transport, clock)

    async def endpoint(request):
        # Catch inside Starlette so ServerErrorMiddleware cannot emit a different body.
        try:
            return await (service.invite(request) if request.method == "GET" else service.post(request))
        except Denied as exc:
            return error(exc.code)
        except InvalidRequest:
            return error("invalid_request")
        except Exception:
            return error("upstream_error")

    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            await service.close()

    app = Starlette(routes=[Route("/v1/invite", endpoint, methods=["GET"]),
                            Route("/v1/chat/completions", endpoint, methods=["POST"])], lifespan=lifespan)
    app.state.service = service
    return SafeApp(app)
