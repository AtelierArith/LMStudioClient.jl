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

## Prerequisites

- Julia 1.12+
- A running LM Studio server
- By default, `Client()` connects to `http://127.0.0.1:1234`

Before you run the examples below, confirm the exact model identifier in LM Studio itself. If you use the `lms` CLI, `lms ls` shows installed models and `lms ps` shows loaded models.

## Installation

Clone the repository first, then run Julia from the repository root:

```bash
git clone <your-repo-url>
cd LMStudioClient
```

```julia
using Pkg
Pkg.develop(path=".")
```

If you are using this package from another Julia environment, add it there in the usual way.

For a scratch environment outside the repo:

```julia
using Pkg
Pkg.activate("lmstudio-scratch")
Pkg.develop(path="/absolute/path/to/LMStudioClient")
Pkg.instantiate()
```

## Quickstart

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

## Building The Docs Locally

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Then open `docs/build/index.html`.
