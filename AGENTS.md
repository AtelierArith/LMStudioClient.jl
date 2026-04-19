# AGENTS.md

## Purpose

This repository contains `LMStudioClient.jl`, a thin Julia client for LM Studio's native REST API.

The currently supported user-facing flows are:

- model download
- model load
- non-streaming chat
- stateful chat with `ChatSession`
- streaming chat with `stream_chat`

Primary entry points:

- [README.md](/Users/terasaki/tmp/LMStudioClient/README.md:1)
- [docs/src/getting-started.md](/Users/terasaki/tmp/LMStudioClient/docs/src/getting-started.md:1)
- [docs/src/streaming.md](/Users/terasaki/tmp/LMStudioClient/docs/src/streaming.md:1)

## Repo Status

As of this file:

- the streaming transport bug in `src/transport.jl` has been fixed for current `HTTP.jl`
- live download, load, chat, and `stream_chat` have been exercised against a real LM Studio server
- the test model used in discussion and live verification was `google/gemma-4-e2b`

## Working Conventions

When changing code in this repo, preserve these assumptions unless the user explicitly wants to change them:

- Julia compat target is `1.12`
- `Client()` defaults to `http://127.0.0.1:1234`
- `HTTP.jl` streaming behavior is tested against the current `HTTP.open` API
- docs are intentionally minimal and usage-first, not a full generated API reference

## Fast Start For Agents

### Local package checks

Run the normal suite with:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Build docs with:

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

### Live LM Studio checks

Start the LM Studio local server:

```bash
lms server start -p 1234 --bind 127.0.0.1
```

Check server status:

```bash
lms server status
curl http://127.0.0.1:1234/
```

Inspect local and loaded models:

```bash
lms ls
lms ps
```

Run live tests:

```bash
LMSTUDIO_RUN_LIVE_TESTS=1 LMSTUDIO_TEST_MODEL=google/gemma-4-e2b julia --project -e 'using Pkg; Pkg.test()'
```

## Known Good Live Workflow

The following sequence has been verified end-to-end:

1. Start LM Studio server with `lms server start -p 1234 --bind 127.0.0.1`
2. Download a model via `download_model(client, "google/gemma-4-e2b")`
3. Wait for completion via `wait_for_download(...)`
4. Load the model via `load_model(client, "google/gemma-4-e2b"; context_length=8192)`
5. Run `stream_chat` and receive `MessageDeltaEvent` chunks from the real server

The scratch user script used during downstream testing is:

- [tmp/stream-chat-user-test/stream_chat_minimal.jl](/Users/terasaki/tmp/LMStudioClient/tmp/stream-chat-user-test/stream_chat_minimal.jl:1)

## Known Pitfalls

### LM Studio server is often the first blocker

If `http://127.0.0.1:1234` is unreachable, do not debug package code first. Confirm:

- `lms server status`
- `curl http://127.0.0.1:1234/`

### `download_model` may return `already_downloaded`

Live API behavior is not always the same as the initial happy-path assumption:

- when a model is already on disk, `download_model(...)` may return `status == :already_downloaded`
- in that case `job.job_id` may be `nothing`
- `total_size_bytes` may also be absent

Do not write live tests that require those fields unconditionally.

### `stream_chat` can fail for model readiness, not only transport reasons

If the transport is healthy but the model is missing or unloaded, LM Studio may return an API error such as:

- `model_not_found`
- invalid model identifier

Check `lms ls` and `lms ps` before assuming a client bug.

### Streaming transport expectations

`src/transport.jl` now depends on these details:

- body-bearing streaming requests are sent with `HTTP.open(...; ...) do io`
- request body is written manually, then `closewrite(io)` is called before reading
- response lines are split from `readavailable(io)` chunks
- a final unterminated line at EOF must still be preserved and flushed

If you touch this area, re-run:

- `test/api_test.jl`
- `test/sse_test.jl`
- live tests when possible

## Important Test Files

- [test/api_test.jl](/Users/terasaki/tmp/LMStudioClient/test/api_test.jl:1)
- [test/sse_test.jl](/Users/terasaki/tmp/LMStudioClient/test/sse_test.jl:1)
- [test/live_api_test.jl](/Users/terasaki/tmp/LMStudioClient/test/live_api_test.jl:1)

Pay particular attention to:

- transport-level streaming regression coverage
- EOF handling for unterminated final SSE lines
- live handling of `already_downloaded`

## Documentation Map

- [README.md](/Users/terasaki/tmp/LMStudioClient/README.md:1): repo entrypoint and minimal quickstart
- [docs/src/getting-started.md](/Users/terasaki/tmp/LMStudioClient/docs/src/getting-started.md:1): `Client`, download/load, `chat`, `ChatSession`
- [docs/src/streaming.md](/Users/terasaki/tmp/LMStudioClient/docs/src/streaming.md:1): `stream_chat`, event types, troubleshooting
- [docs/test-reports/](/Users/terasaki/tmp/LMStudioClient/docs/test-reports): downstream user-perspective reports

## Recommended Agent Behavior

- Prefer proving behavior with tests or a real LM Studio server over reasoning from source alone.
- If a live test fails, distinguish these cases before editing code:
  - server unreachable
  - model missing or unloaded
  - LM Studio API returned a structured error
  - client transport/parsing bug
- When adding live assertions, keep them tolerant of real LM Studio payload variation.
- Keep docs aligned with what a downstream user can discover without reading package internals.
