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

## Relationship To PromptingTools.jl

`PromptingTools.jl` and `LMStudioClient.jl` live at different layers.
`PromptingTools.jl` is a higher-level prompting interface, while `LMStudioClient.jl`
provides thin access to LM Studio's native REST API for model management and
native chat flows.

Features that are often easier to cover with `PromptingTools.jl`:

| Feature | Easy to replace with `PromptingTools.jl`? | Notes |
| --- | --- | --- |
| One-shot text generation | Yes | `PromptingTools.jl` can target OpenAI-compatible APIs, so LM Studio's `/v1/chat/completions` style usage fits naturally there. |
| Embeddings | Yes | `PromptingTools.jl` provides `aiembed` for embedding-oriented workflows. |
| Client-managed multi-turn chat | Mostly | `PromptingTools.jl` can keep and resend conversation history, even though that is different from LM Studio's server-side state. |
| Prompt templates and REPL ergonomics | Yes | This is one of the main strengths of `PromptingTools.jl` via `aigenerate`, `@ai_str`, and related helpers. |
| High-level extraction and classification workflows | Often | `PromptingTools.jl` offers higher-level helpers such as `aiextract` and `aiclassify`. |

Features where `LMStudioClient.jl` is the better fit:

| Feature | Why `LMStudioClient.jl` fits better | Status in this package |
| --- | --- | --- |
| Model download, load, unload, and listing | These use LM Studio native `/api/v1/models*` endpoints rather than OpenAI-compatible inference APIs. | Supported |
| Server-side stateful chat | LM Studio native `/api/v1/chat` returns `response_id` values for continuing or branching conversations without resending full history. | Supported via `ChatSession` |
| Native streaming event types | LM Studio native streams include `model_load.*`, `prompt_processing.*`, `reasoning.*`, `tool_call.*`, `message.*`, and `chat.end`. | Supported via `stream_chat` |
| Load-time runtime controls | Native load requests expose LM Studio-specific knobs such as `context_length`, `eval_batch_size`, `flash_attention`, `num_experts`, and `offload_kv_cache_to_gpu`. | Supported |
| Download job polling | Native download endpoints expose statuses such as `downloading`, `completed`, and `already_downloaded`, plus progress metadata. | Supported |

LM Studio's native API also includes capabilities such as MCP via API, but this
package currently focuses on the flows listed above.

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
# LMStudioClient.jl
