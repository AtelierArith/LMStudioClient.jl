# LMStudioClient.jl

Thin Julia client for LM Studio's native REST API.

It supports:

- model listing
- loaded model listing
- model download
- model load
- model unload
- server status
- non-streaming chat
- stateful chat with `ChatSession`
- streaming chat via `stream_chat`

Use `LMStudioClient.jl` when you want LM Studio-native model management and chat
flows rather than a higher-level prompting abstraction.

## Prerequisites

- Julia 1.12+
- A running LM Studio server
- By default, `Client()` connects to `http://127.0.0.1:1234`

Before you run the examples below, confirm the exact model identifier in LM Studio itself. If you use the `lms` CLI, `lms ls` shows installed models and `lms ps` shows loaded models.

## Installation

### Repo-local Development

Clone the repository first, then run Julia from the repository root:

```bash
git clone <your-repo-url>
cd LMStudioClient
```

```julia
using Pkg
Pkg.develop(path=".")
```

### Scratch Environment

For a scratch environment outside the repo:

```julia
using Pkg
Pkg.activate("lmstudio-scratch")
Pkg.develop(path="/absolute/path/to/LMStudioClient")
Pkg.instantiate()
```

## Quickstart

Make sure the LM Studio server is already running before you execute the example below. If you use the `lms` CLI, one way to start it is:

```bash
lms server start -p 1234 --bind 127.0.0.1
```

```julia
using LMStudioClient

client = Client()

status = server_status(client)
println("reachable=$(status.reachable), authenticated=$(status.authenticated)")

models = list_models(client; domain=:llm)
if isempty(models)
    println("No LLM models installed.")
else
    println(first(models).key)
end

# Replace this with a model identifier that exists in your LM Studio setup.
job = download_model(client, "google/gemma-4-e2b")
wait_for_download(client, job; timeout=1800)

load_model(client, "google/gemma-4-e2b"; context_length=8192)

response = chat(client; model="google/gemma-4-e2b", input="Reply with the single word BLUE.")

for item in response.output
    if item isa MessageOutput
        println(item.content)
    end
end
```

## Streaming Chat

```julia
using LMStudioClient

client = Client(
    base_url=get(ENV, "LMSTUDIO_BASE_URL", "http://127.0.0.1:1234"),
)

# Replace the model name with one that exists in your LM Studio setup.
# Confirm the exact identifier in LM Studio first. If you use the CLI,
# `lms ls` shows installed models and `lms ps` shows loaded ones.
model = get(ENV, "LMSTUDIO_MODEL", "google/gemma-4-e2b")

for event in stream_chat(client; model=model, input="Say hello")
    if event isa MessageDeltaEvent
        print(event.content)
    elseif event isa StreamErrorEvent
        @warn "stream error" event.error
    elseif event isa ChatEndEvent
        println()
    end
end
```

The streamed text chunks arrive in `MessageDeltaEvent(content::String)`.

## More Docs

- [Getting Started](docs/src/getting-started.md)
- [Model Management](docs/src/model-management.md)
- [Streaming](docs/src/streaming.md)

## Relationship To PromptingTools.jl

`PromptingTools.jl` and `LMStudioClient.jl` live at different layers.
`PromptingTools.jl` is a higher-level prompting interface, while
`LMStudioClient.jl` provides thin access to LM Studio's native REST API for
model management and native chat flows.

`PromptingTools.jl` is often the easier fit when you mainly want:

- one-shot generation through OpenAI-compatible APIs
- embeddings
- client-managed multi-turn chat
- prompt templates and REPL ergonomics
- higher-level extraction or classification helpers

`LMStudioClient.jl` is the better fit when you need:

- LM Studio-native model download, load, unload, and listing
- server-side stateful chat via `response_id` and `ChatSession`
- native streaming event types via `stream_chat`
- LM Studio-specific load options such as `context_length` and `flash_attention`
- download job polling with statuses such as `downloading`, `completed`, and `already_downloaded`

## Building The Docs Locally

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Then open `docs/build/index.html`.
