# Streaming

`stream_chat` returns an iterable `Channel{LMStudioEvent}`. On the successful path it yields incremental events as LM Studio produces them and finishes with a `ChatEndEvent`. Stream-level failures may instead arrive as `StreamErrorEvent`, and transport or parsing failures can terminate iteration by throwing.

## Minimal Streaming Loop

```julia
using LMStudioClient

client = Client()

for event in stream_chat(client; model="google/gemma-4-e2b", input="Say hello")
    if event isa MessageDeltaEvent
        print(event.content)
    elseif event isa StreamErrorEvent
        @warn "stream error" event.error
    elseif event isa ChatEndEvent
        println()
    end
end
```

`MessageDeltaEvent.content` contains streamed text chunks. `ChatEndEvent.result` carries the final `ChatResponse`, and `ChatEndEvent.result.response_id` is the final response id when LM Studio includes one.

Replace `google/gemma-4-e2b` with a model that is actually available on your local LM Studio server.

## Before Streaming

- Make sure the LM Studio server is running.
- Make sure the model name you pass to `stream_chat` is available in your LM Studio setup.
- Confirm the exact model identifier in LM Studio before you run the sample. If you use the `lms` CLI, `lms ls` shows installed models and `lms ps` shows loaded ones.
- If you want a shell-friendly script, read `base_url` and `model` from `LMSTUDIO_BASE_URL` and `LMSTUDIO_MODEL`.

## Important Event Types

- `MessageDeltaEvent`: streamed text chunks in `content`
- `ChatEndEvent`: final `ChatResponse` in `result`
- `StreamErrorEvent`: stream-level error payloads in `error`

You can inspect other `LMStudioEvent` subtypes as needed, but the message streaming path above is the usual starting point.

## Override The Server URL

```julia
client = Client(base_url="http://192.168.1.50:1234")
```

Use a different `base_url` when LM Studio is exposed on another host or port.

For a reusable script, it is often convenient to let the shell provide both:

```julia
client = Client(base_url=get(ENV, "LMSTUDIO_BASE_URL", "http://127.0.0.1:1234"))
model = get(ENV, "LMSTUDIO_MODEL", "google/gemma-4-e2b")
```

## Streaming With `ChatSession`

```julia
using LMStudioClient

client = Client(base_url="http://127.0.0.1:1234")
session = ChatSession("google/gemma-4-e2b")

for event in stream_chat(client, session, "Tell me a short story.")
    if event isa MessageDeltaEvent
        print(event.content)
    elseif event isa ChatEndEvent
        println()
    end
end
```

When you use `stream_chat(client, session, ...)`, `session.previous_response_id` is updated once the stream reaches `ChatEndEvent`, so the next turn can continue from the last response automatically when LM Studio returned a response id.

The session overload owns `model`, `system_prompt`, and `previous_response_id`, so do not pass those keywords to `stream_chat(client, session, ...)`.

## Troubleshooting

- If you receive a `StreamErrorEvent`, LM Studio accepted the request and reported an error through the stream payload.
- If iteration throws an exception instead, the failure happened in the client transport or while parsing the stream before a normal event could be yielded.
- If you are unsure which model name to use, first confirm it in LM Studio itself, then pass that exact name to `stream_chat`.
