# Invite relay design

Scope: only the relay; the public endpoint is `/v1/chat/completions`. No App changes, installation, deployment or live model calls.

Starlette exposes GET /v1/invite and POST /v1/chat/completions. httpx sends to one configured upstream/model/tier; SQLite (standard library) owns invites, rate checks, reservations and settlement. uv runs the Python 3.11+ service and argparse admin commands.

## Accounting and side effects

Use integer picodollars and configured prices, never binary floating point. Admission uses BEGIN IMMEDIATE to check invite, lifetime balance, UTC request-start month balance and sliding-minute rate, then reserve the full conservative input/output cost before calling upstream. Reservations count toward both caps across processes. Actual prompt/cached/completion tokens replace the reservation once usage is known. No automatic release of uncertain reservations after crashes.

Text-only requests use a deliberately conservative input bound: serialized outbound UTF-8 bytes plus 4096 framing tokens. Enforce n=1, text messages, bounded body/output, and only the ordinary text-completion options used by the App; reject unsupported potentially billable extensions. Reserve at the larger input/cache price. Prices must match the model and tier's actual bill; this is an admission bound for a conforming text-token upstream, not a provider billing guarantee. A positive balance smaller than one whole reservation can be temporarily unusable (documented).

Stream bytes pass through unchanged, with include_usage forced. The response monitors disconnects while a separately tracked, time-bounded upstream reader drains usage and settles. Upstream loss/missing usage/timeout retains the reservation as explicitly estimated. Known HTTP rejection releases it. Non-stream results must contain valid usage. A crash leaves reserved rows charged, visible to the admin.

Limits: original user text <= 2000 Unicode code points by default; system/developer text is covered by body bytes. Body <= 64 KiB; output <= 2048 tokens; response <= 2 MiB; total upstream duration <= 90s, all configurable. Validate UUID device header, hash canonical UUID using SHA-256. GET recognizes a known revoked invite as status revoked; POST rejects it with invite_invalid. UTC month is anchored at admission, including streams crossing midnight.

## Privacy and errors

Database stores generated code, optional admin note, budget/revocation, hashed device, UTC time/month, token counts, fixed status/accounting states, cost. Never persist request/response text, IP, upstream errors/headers or credentials. Production launcher disables access/client transport logs; public errors are fixed strings. Credentials read only at service startup from configurable environment name or ai-vault path/unique key name. No real key is needed for tests/admin commands.

## Alternatives considered

1. Charge only after usage: simple, but concurrent requests can overrun caps.
2. Serialize all requests: avoids a race but blocks all users behind a stream and still needs a bound for the final call.
3. Atomic conservative reservations (selected): supports concurrency and restart safety; trades some near-limit availability and uncertain-stream overcount for a hard admission ceiling.

## Evidence matrix

All six agreed errors; malformed/device cases; exact final reservation; separate invite/global concurrency; month rollover/cross-month requests; nonstream cached pricing; raw SSE/fragmented events; client disconnect with later usage; upstream loss with and without usage; timeout/shutdown/crash reservations; rate checks across instances; body/output bounds; CLI/vault/config; inspect logs and database bytes for secret/content sentinels. All upstream traffic is fake and tests block real network use. Swift tests/release build are compilation checks only and must not launch the App.
