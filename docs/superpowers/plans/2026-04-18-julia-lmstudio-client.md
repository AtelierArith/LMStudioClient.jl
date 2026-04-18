# Julia LM Studio Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a thin Julia client for LM Studio's native REST API that supports model download, model load, non-streaming chat, stateful chat, and full-event streaming chat.

**Architecture:** The package will be a REST-native thin client built on `HTTP.jl`. Public functions in `api.jl` will map directly to LM Studio's `/api/v1/*` endpoints, typed response structs will live in `types.jl`, and `stream_chat` will return an iterable `Channel{LMStudioEvent}` backed by an SSE parser in `sse.jl`.

**Tech Stack:** Julia, `HTTP.jl`, `JSON3.jl`, `StructTypes.jl`, stdlib `Dates`, stdlib `Test`

---

## File Structure

### Package Files

- Modify: `Project.toml`
  Add runtime dependencies `HTTP`, `JSON3`, and `StructTypes`.

- Modify: `src/LMStudioClient.jl`
  Replace the placeholder module with includes and public exports.

- Create: `src/types.jl`
  Define `Client`, `DownloadJob`, `LoadedModel`, `ChatStats`, `ChatResponse`, `ChatSession`, `ChatOutputItem` subtypes, `LMStudioEvent` subtypes, and `UnknownEvent`.

- Create: `src/errors.jl`
  Define `LMStudioHTTPError`, `LMStudioAPIError`, `LMStudioProtocolError`, and `LMStudioTimeoutError`.

- Create: `src/transport.jl`
  Implement low-level HTTP helpers for JSON requests and streaming requests.

- Create: `src/sse.jl`
  Implement SSE frame parsing and event decoding from LM Studio's named event stream.

- Create: `src/api.jl`
  Implement `download_model`, `download_status`, `wait_for_download`, `load_model`, `chat`, and `stream_chat`.

### Test Files

- Create: `test/runtests.jl`
  Main test entry point and optional live-test gate.

- Create: `test/types_test.jl`
  Verify constructors, exports, and typed decoding helpers.

- Create: `test/api_test.jl`
  Verify request/response mapping for download, load, chat, and `ChatSession`.

- Create: `test/sse_test.jl`
  Verify SSE parsing and full event decoding.

- Create: `test/live_api_test.jl`
  Optional end-to-end tests against a running LM Studio server using `google/gemma-4-e2b`.

## Task 1: Bootstrap The Package Surface

**Files:**
- Modify: `Project.toml`
- Modify: `src/LMStudioClient.jl`
- Create: `src/types.jl`
- Create: `src/errors.jl`
- Create: `test/runtests.jl`
- Create: `test/types_test.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/types_test.jl
using Test
using LMStudioClient

@testset "public surface" begin
    client = Client()
    @test client.base_url == "http://127.0.0.1:1234"
    @test isnothing(client.api_token)

    session = ChatSession("google/gemma-4-e2b")
    @test session.model == "google/gemma-4-e2b"
    @test isnothing(session.previous_response_id)

    job = DownloadJob(nothing, :already_downloaded, nothing, nothing, nothing, nothing, nothing, nothing)
    @test job.status == :already_downloaded
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `Client`, `ChatSession`, and `DownloadJob` do not exist and the package still exports only `greet`.

- [ ] **Step 3: Write minimal implementation**

```toml
# Project.toml
name = "LMStudioClient"
uuid = "bd03a44f-7599-420b-a0ff-985714b58da8"
version = "0.1.0"
authors = ["Satoshi Terasaki <terasakisatoshi.math@gmail.com>"]

[deps]
HTTP = "cd3eb016-35fb-5094-929b-558a96fad6f3"
JSON3 = "0f8b85d8-7281-11e9-16c2-39f4f5ccdd29"
StructTypes = "856f2bd8-1eba-4b0a-8007-ebc267875bd4"
```

```julia
# src/LMStudioClient.jl
module LMStudioClient

include("types.jl")
include("errors.jl")

export Client
export ChatSession
export DownloadJob
export LoadedModel
export ChatStats
export ChatResponse
export LMStudioEvent

end # module LMStudioClient
```

```julia
# src/types.jl
struct Client
    base_url::String
    api_token::Union{Nothing,String}
    timeout::Float64
end

Client(; base_url::String="http://127.0.0.1:1234", api_token::Union{Nothing,String}=nothing, timeout::Real=30.0) =
    Client(base_url, api_token, Float64(timeout))

mutable struct ChatSession
    model::String
    previous_response_id::Union{Nothing,String}
    system_prompt::Union{Nothing,String}
end

ChatSession(model::String; previous_response_id::Union{Nothing,String}=nothing, system_prompt::Union{Nothing,String}=nothing) =
    ChatSession(model, previous_response_id, system_prompt)

struct DownloadJob
    job_id::Union{Nothing,String}
    status::Symbol
    total_size_bytes::Union{Nothing,Int}
    downloaded_bytes::Union{Nothing,Int}
    started_at
    completed_at
    bytes_per_second
    estimated_completion
end

struct LoadedModel
    type::Symbol
    instance_id::String
    status::Symbol
    load_time_seconds::Float64
    load_config::Dict{String,Any}
end

struct ChatStats
    input_tokens::Int
    total_output_tokens::Int
    reasoning_output_tokens::Int
    tokens_per_second::Float64
    time_to_first_token_seconds::Float64
    model_load_time_seconds::Union{Nothing,Float64}
end

abstract type ChatOutputItem end
abstract type LMStudioEvent end

struct ChatResponse
    model_instance_id::String
    output::Vector{ChatOutputItem}
    stats::ChatStats
    response_id::Union{Nothing,String}
end
```

```julia
# src/errors.jl
struct LMStudioHTTPError <: Exception
    status::Int
    body::String
end

struct LMStudioAPIError <: Exception
    error_type::String
    message::String
    code::Union{Nothing,String}
    param::Union{Nothing,String}
end

struct LMStudioProtocolError <: Exception
    message::String
end

struct LMStudioTimeoutError <: Exception
    message::String
end
```

```julia
# test/runtests.jl
using Test
using LMStudioClient

include("types_test.jl")
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS with one `public surface` testset and no references to `greet`.

- [ ] **Step 5: Commit**

```bash
git add Project.toml src/LMStudioClient.jl src/types.jl src/errors.jl test/runtests.jl test/types_test.jl
git commit -m "feat: bootstrap Julia LM Studio client surface"
```

## Task 2: Add JSON Transport And Download APIs

**Files:**
- Create: `src/transport.jl`
- Create: `src/api.jl`
- Modify: `src/LMStudioClient.jl`
- Modify: `test/runtests.jl`
- Create: `test/api_test.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/api_test.jl
using Test
using LMStudioClient

@testset "download APIs" begin
    captured = Ref{Any}(nothing)
    fake_transport = function (; method, path, body, stream, client)
        captured[] = (; method, path, body, stream)
        return Dict(
            "job_id" => "job_123",
            "status" => "downloading",
            "total_size_bytes" => 100,
            "started_at" => "2026-04-18T00:00:00Z",
        )
    end

    client = Client()
    job = LMStudioClient.download_model(client, "google/gemma-4-e2b"; _transport=fake_transport)

    @test captured[].method == "POST"
    @test captured[].path == "/api/v1/models/download"
    @test captured[].body["model"] == "google/gemma-4-e2b"
    @test job.job_id == "job_123"
    @test job.status == :downloading
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `download_model` does not exist and the module does not include any transport layer.

- [ ] **Step 3: Write minimal implementation**

```julia
# src/transport.jl
using HTTP
using JSON3

function _headers(client::Client)
    headers = ["Content-Type" => "application/json"]
    if !isnothing(client.api_token)
        push!(headers, "Authorization" => "Bearer $(client.api_token)")
    end
    return headers
end

function _request_json(client::Client, method::String, path::String; body::Dict{String,Any}=Dict{String,Any}())
    response = HTTP.request(
        method,
        string(client.base_url, path),
        _headers(client),
        JSON3.write(body);
        readtimeout=client.timeout,
    )
    if response.status < 200 || response.status >= 300
        throw(LMStudioHTTPError(response.status, String(response.body)))
    end
    return JSON3.read(String(response.body), Dict{String,Any})
end
```

```julia
# src/api.jl
using Dates

function _parse_download_job(data::Dict{String,Any})
    DownloadJob(
        get(data, "job_id", nothing),
        Symbol(data["status"]),
        get(data, "total_size_bytes", nothing),
        get(data, "downloaded_bytes", nothing),
        get(data, "started_at", nothing),
        get(data, "completed_at", nothing),
        get(data, "bytes_per_second", nothing),
        get(data, "estimated_completion", nothing),
    )
end

function download_model(client::Client, model::String; quantization::Union{Nothing,String}=nothing, _transport=_request_adapter)
    body = Dict{String,Any}("model" => model)
    if !isnothing(quantization)
        body["quantization"] = quantization
    end
    data = _transport(; method="POST", path="/api/v1/models/download", body=body, stream=false, client=client)
    return _parse_download_job(data)
end

function download_status(client::Client, job_id::String; _transport=_request_adapter)
    data = _transport(; method="GET", path="/api/v1/models/download/status/$(job_id)", body=Dict{String,Any}(), stream=false, client=client)
    return _parse_download_job(data)
end

function _request_adapter(; method, path, body, stream, client)
    @assert stream == false
    return _request_json(client, method, path; body=body)
end
```

```julia
# src/LMStudioClient.jl
module LMStudioClient

include("types.jl")
include("errors.jl")
include("transport.jl")
include("api.jl")

export Client
export ChatSession
export DownloadJob
export LoadedModel
export ChatStats
export ChatResponse
export LMStudioEvent
export download_model
export download_status

end # module LMStudioClient
```

```julia
# test/runtests.jl
using Test
using LMStudioClient

include("types_test.jl")
include("api_test.jl")
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS with `download APIs` verifying the request path and decoded `DownloadJob`.

- [ ] **Step 5: Commit**

```bash
git add src/transport.jl src/api.jl src/LMStudioClient.jl test/runtests.jl test/api_test.jl
git commit -m "feat: add transport and download APIs"
```

## Task 3: Implement Download Polling, Load, And Non-Streaming Chat

**Files:**
- Modify: `src/types.jl`
- Modify: `src/api.jl`
- Modify: `test/api_test.jl`

- [ ] **Step 1: Write the failing test**

```julia
# append to test/api_test.jl
@testset "load chat and session APIs" begin
    calls = Any[]
    responses = [
        Dict("job_id" => "job_123", "status" => "completed", "downloaded_bytes" => 100, "total_size_bytes" => 100),
        Dict("type" => "llm", "instance_id" => "google/gemma-4-e2b", "status" => "loaded", "load_time_seconds" => 2.5, "load_config" => Dict("context_length" => 8192)),
        Dict(
            "model_instance_id" => "google/gemma-4-e2b",
            "output" => [Dict("type" => "message", "content" => "Blue.")],
            "stats" => Dict(
                "input_tokens" => 10,
                "total_output_tokens" => 2,
                "reasoning_output_tokens" => 0,
                "tokens_per_second" => 20.0,
                "time_to_first_token_seconds" => 0.4,
            ),
            "response_id" => "resp_1",
        ),
    ]

    fake_transport = function (; method, path, body, stream, client)
        push!(calls, (; method, path, body, stream))
        return popfirst!(responses)
    end

    client = Client()
    job = wait_for_download(client, "job_123"; poll_interval=0.0, _transport=fake_transport)
    @test job.status == :completed

    loaded = load_model(client, "google/gemma-4-e2b"; context_length=8192, _transport=fake_transport)
    @test loaded.instance_id == "google/gemma-4-e2b"
    @test loaded.load_config["context_length"] == 8192

    session = ChatSession("google/gemma-4-e2b")
    reply = chat(client, session, "What color did I mention?"; _transport=fake_transport)
    @test reply.response_id == "resp_1"
    @test session.previous_response_id == "resp_1"
    @test calls[end].body["model"] == "google/gemma-4-e2b"
    @test calls[end].body["input"] == "What color did I mention?"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `wait_for_download`, `load_model`, and `chat` are missing and `ChatResponse` output decoding is not implemented.

- [ ] **Step 3: Write minimal implementation**

```julia
# append to src/types.jl
struct MessageOutput <: ChatOutputItem
    content::String
end

struct ReasoningOutput <: ChatOutputItem
    content::String
end

struct ToolCallOutput <: ChatOutputItem
    tool::String
    arguments::Dict{String,Any}
    output::String
    provider_info::Dict{String,Any}
end

struct UnknownOutputItem <: ChatOutputItem
    raw::Dict{String,Any}
end
```

```julia
# append to src/api.jl
function wait_for_download(client::Client, job_or_job_id; poll_interval::Real=1.0, timeout::Union{Nothing,Real}=nothing, _transport=_request_adapter)
    job = job_or_job_id isa DownloadJob ? job_or_job_id : download_status(client, String(job_or_job_id); _transport=_transport)
    if job.status == :already_downloaded || job.status == :completed
        return job
    end
    started = time()
    while true
        if !isnothing(timeout) && (time() - started) > timeout
            throw(LMStudioTimeoutError("Timed out waiting for download to complete"))
        end
        sleep(poll_interval)
        job = download_status(client, something(job.job_id, String(job_or_job_id)); _transport=_transport)
        if job.status == :completed
            return job
        elseif job.status == :failed
            throw(LMStudioAPIError("download_failed", "Model download failed", nothing, nothing))
        end
    end
end

function load_model(client::Client, model::String; context_length::Union{Nothing,Int}=nothing, eval_batch_size::Union{Nothing,Int}=nothing, flash_attention::Union{Nothing,Bool}=nothing, num_experts::Union{Nothing,Int}=nothing, offload_kv_cache_to_gpu::Union{Nothing,Bool}=nothing, echo_load_config::Bool=false, _transport=_request_adapter)
    body = Dict{String,Any}("model" => model, "echo_load_config" => echo_load_config)
    !isnothing(context_length) && (body["context_length"] = context_length)
    !isnothing(eval_batch_size) && (body["eval_batch_size"] = eval_batch_size)
    !isnothing(flash_attention) && (body["flash_attention"] = flash_attention)
    !isnothing(num_experts) && (body["num_experts"] = num_experts)
    !isnothing(offload_kv_cache_to_gpu) && (body["offload_kv_cache_to_gpu"] = offload_kv_cache_to_gpu)
    data = _transport(; method="POST", path="/api/v1/models/load", body=body, stream=false, client=client)
    return LoadedModel(Symbol(data["type"]), data["instance_id"], Symbol(data["status"]), Float64(data["load_time_seconds"]), get(data, "load_config", Dict{String,Any}()))
end

function _parse_output_item(item::Dict{String,Any})
    kind = get(item, "type", "unknown")
    if kind == "message"
        return MessageOutput(item["content"])
    elseif kind == "reasoning"
        return ReasoningOutput(item["content"])
    elseif kind == "tool_call"
        return ToolCallOutput(item["tool"], get(item, "arguments", Dict{String,Any}()), get(item, "output", ""), get(item, "provider_info", Dict{String,Any}()))
    else
        return UnknownOutputItem(item)
    end
end

function _parse_chat_response(data::Dict{String,Any})
    stats_data = get(data, "stats", Dict{String,Any}())
    stats = ChatStats(
        Int(get(stats_data, "input_tokens", 0)),
        Int(get(stats_data, "total_output_tokens", 0)),
        Int(get(stats_data, "reasoning_output_tokens", 0)),
        Float64(get(stats_data, "tokens_per_second", 0.0)),
        Float64(get(stats_data, "time_to_first_token_seconds", 0.0)),
        haskey(stats_data, "model_load_time_seconds") ? Float64(stats_data["model_load_time_seconds"]) : nothing,
    )
    output = [_parse_output_item(item) for item in get(data, "output", Dict{String,Any}[])]
    return ChatResponse(data["model_instance_id"], output, stats, get(data, "response_id", nothing))
end

function chat(client::Client; model::String, input, system_prompt::Union{Nothing,String}=nothing, previous_response_id::Union{Nothing,String}=nothing, store::Bool=true, temperature=nothing, top_p=nothing, top_k=nothing, min_p=nothing, repeat_penalty=nothing, max_output_tokens=nothing, reasoning=nothing, context_length=nothing, _transport=_request_adapter)
    body = Dict{String,Any}("model" => model, "input" => input, "store" => store)
    !isnothing(system_prompt) && (body["system_prompt"] = system_prompt)
    !isnothing(previous_response_id) && (body["previous_response_id"] = previous_response_id)
    for (key, value) in [
        "temperature" => temperature,
        "top_p" => top_p,
        "top_k" => top_k,
        "min_p" => min_p,
        "repeat_penalty" => repeat_penalty,
        "max_output_tokens" => max_output_tokens,
        "reasoning" => reasoning,
        "context_length" => context_length,
    ]
        !isnothing(value) && (body[key] = value)
    end
    data = _transport(; method="POST", path="/api/v1/chat", body=body, stream=false, client=client)
    return _parse_chat_response(data)
end

function chat(client::Client, session::ChatSession, input; kwargs...)
    response = chat(client; model=session.model, input=input, previous_response_id=session.previous_response_id, system_prompt=session.system_prompt, kwargs...)
    if !isnothing(response.response_id)
        session.previous_response_id = response.response_id
    end
    return response
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS with `load chat and session APIs` confirming polling, load decoding, non-streaming chat, and `ChatSession` state updates.

- [ ] **Step 5: Commit**

```bash
git add src/types.jl src/api.jl test/api_test.jl
git commit -m "feat: implement download polling load and chat APIs"
```

## Task 4: Implement SSE Frame Parsing And Event Decoding

**Files:**
- Create: `src/sse.jl`
- Modify: `src/types.jl`
- Modify: `src/LMStudioClient.jl`
- Create: `test/sse_test.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/sse_test.jl
using Test
using LMStudioClient

@testset "SSE parser and event decoding" begin
    raw = [
        "event: message.delta",
        "data: {\"type\":\"message.delta\",\"content\":\"Hello\"}",
        "",
        "event: chat.end",
        "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[],\"stats\":{\"input_tokens\":1,\"total_output_tokens\":1,\"reasoning_output_tokens\":0,\"tokens_per_second\":12.0,\"time_to_first_token_seconds\":0.1}}}",
        "",
    ]

    events = collect(LMStudioClient._decode_sse_lines(raw))

    @test length(events) == 2
    @test events[1] isa MessageDeltaEvent
    @test events[1].content == "Hello"
    @test events[2] isa ChatEndEvent
    @test events[2].result.model_instance_id == "google/gemma-4-e2b"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `_decode_sse_lines`, `MessageDeltaEvent`, and `ChatEndEvent` do not exist.

- [ ] **Step 3: Write minimal implementation**

```julia
# append to src/types.jl
struct ChatStartEvent <: LMStudioEvent
    model_instance_id::String
end

struct ModelLoadProgressEvent <: LMStudioEvent
    model_instance_id::String
    progress::Float64
end

struct MessageDeltaEvent <: LMStudioEvent
    content::String
end

struct StreamErrorEvent <: LMStudioEvent
    error::Dict{String,Any}
end

struct ChatEndEvent <: LMStudioEvent
    result::ChatResponse
end

struct UnknownEvent <: LMStudioEvent
    event_type::String
    raw::Dict{String,Any}
end
```

```julia
# src/sse.jl
using JSON3

function _decode_event(event_name::String, payload::Dict{String,Any})
    if event_name == "message.delta"
        return MessageDeltaEvent(payload["content"])
    elseif event_name == "chat.end"
        return ChatEndEvent(_parse_chat_response(payload["result"]))
    elseif event_name == "error"
        return StreamErrorEvent(payload["error"])
    elseif event_name == "model_load.progress"
        return ModelLoadProgressEvent(payload["model_instance_id"], Float64(payload["progress"]))
    elseif event_name == "chat.start"
        return ChatStartEvent(payload["model_instance_id"])
    else
        return UnknownEvent(event_name, payload)
    end
end

function _decode_sse_lines(lines)
    Channel{LMStudioEvent}(32) do channel
        event_name = nothing
        data_lines = String[]
        for line in lines
            if isempty(line)
                if !isnothing(event_name)
                    payload = JSON3.read(join(data_lines, "\n"), Dict{String,Any})
                    put!(channel, _decode_event(event_name, payload))
                end
                event_name = nothing
                empty!(data_lines)
                continue
            end
            if startswith(line, "event: ")
                event_name = line[8:end]
            elseif startswith(line, "data: ")
                push!(data_lines, line[7:end])
            end
        end
    end
end
```

```julia
# src/LMStudioClient.jl
module LMStudioClient

include("types.jl")
include("errors.jl")
include("transport.jl")
include("api.jl")
include("sse.jl")

export Client
export ChatSession
export DownloadJob
export LoadedModel
export ChatStats
export ChatResponse
export LMStudioEvent
export MessageDeltaEvent
export ChatEndEvent
export StreamErrorEvent
export download_model
export download_status

end # module LMStudioClient
```

```julia
# test/runtests.jl
using Test
using LMStudioClient

include("types_test.jl")
include("api_test.jl")
include("sse_test.jl")
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS with `SSE parser and event decoding` confirming SSE frame grouping and typed event mapping.

- [ ] **Step 5: Commit**

```bash
git add src/types.jl src/sse.jl src/LMStudioClient.jl test/runtests.jl test/sse_test.jl
git commit -m "feat: add SSE parsing and event decoding"
```

## Task 5: Implement Full-Event `stream_chat`

**Files:**
- Modify: `src/types.jl`
- Modify: `src/transport.jl`
- Modify: `src/sse.jl`
- Modify: `src/api.jl`
- Modify: `test/sse_test.jl`

- [ ] **Step 1: Write the failing test**

```julia
# append to test/sse_test.jl
@testset "stream_chat" begin
    raw_lines = [
        "event: chat.start",
        "data: {\"type\":\"chat.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}",
        "",
        "event: message.delta",
        "data: {\"type\":\"message.delta\",\"content\":\"Blue\"}",
        "",
        "event: chat.end",
        "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[{\"type\":\"message\",\"content\":\"Blue\"}],\"stats\":{\"input_tokens\":5,\"total_output_tokens\":1,\"reasoning_output_tokens\":0,\"tokens_per_second\":15.0,\"time_to_first_token_seconds\":0.2},\"response_id\":\"resp_2\"}}",
        "",
    ]

    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return raw_lines
    end

    client = Client()
    session = ChatSession("google/gemma-4-e2b")
    events = collect(stream_chat(client, session, "What color did I mention?"; _stream_transport=fake_stream_transport))

    @test events[1] isa ChatStartEvent
    @test events[2] isa MessageDeltaEvent
    @test events[end] isa ChatEndEvent
    @test session.previous_response_id == "resp_2"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `stream_chat` does not exist and transport cannot open a streaming response.

- [ ] **Step 3: Write minimal implementation**

```julia
# append to src/types.jl
struct ModelLoadStartEvent <: LMStudioEvent
    model_instance_id::String
end

struct ModelLoadEndEvent <: LMStudioEvent
    model_instance_id::String
    load_time_seconds::Float64
end

struct PromptProcessingStartEvent <: LMStudioEvent end
struct PromptProcessingProgressEvent <: LMStudioEvent
    progress::Float64
end
struct PromptProcessingEndEvent <: LMStudioEvent end
struct ReasoningStartEvent <: LMStudioEvent end
struct ReasoningDeltaEvent <: LMStudioEvent
    content::String
end
struct ReasoningEndEvent <: LMStudioEvent end
struct ToolCallStartEvent <: LMStudioEvent
    tool::String
    provider_info::Dict{String,Any}
end
struct ToolCallArgumentsEvent <: LMStudioEvent
    tool::String
    arguments::Dict{String,Any}
    provider_info::Dict{String,Any}
end
struct ToolCallSuccessEvent <: LMStudioEvent
    tool::String
    arguments::Dict{String,Any}
    output::String
    provider_info::Dict{String,Any}
end
struct ToolCallFailureEvent <: LMStudioEvent
    reason::String
    metadata::Dict{String,Any}
end
struct MessageStartEvent <: LMStudioEvent end
struct MessageEndEvent <: LMStudioEvent end
```

```julia
# append to src/transport.jl
function _stream_request_lines(client::Client, method::String, path::String; body::Dict{String,Any}=Dict{String,Any}())
    lines = String[]
    HTTP.open(method, string(client.base_url, path), _headers(client), JSON3.write(body); readtimeout=client.timeout) do io
        for line in eachline(io)
            push!(lines, line)
        end
    end
    return lines
end
```

```julia
# replace _decode_event in src/sse.jl
function _decode_event(event_name::String, payload::Dict{String,Any})
    if event_name == "chat.start"
        return ChatStartEvent(payload["model_instance_id"])
    elseif event_name == "model_load.start"
        return ModelLoadStartEvent(payload["model_instance_id"])
    elseif event_name == "model_load.progress"
        return ModelLoadProgressEvent(payload["model_instance_id"], Float64(payload["progress"]))
    elseif event_name == "model_load.end"
        return ModelLoadEndEvent(payload["model_instance_id"], Float64(payload["load_time_seconds"]))
    elseif event_name == "prompt_processing.start"
        return PromptProcessingStartEvent()
    elseif event_name == "prompt_processing.progress"
        return PromptProcessingProgressEvent(Float64(payload["progress"]))
    elseif event_name == "prompt_processing.end"
        return PromptProcessingEndEvent()
    elseif event_name == "reasoning.start"
        return ReasoningStartEvent()
    elseif event_name == "reasoning.delta"
        return ReasoningDeltaEvent(payload["content"])
    elseif event_name == "reasoning.end"
        return ReasoningEndEvent()
    elseif event_name == "tool_call.start"
        return ToolCallStartEvent(payload["tool"], get(payload, "provider_info", Dict{String,Any}()))
    elseif event_name == "tool_call.arguments"
        return ToolCallArgumentsEvent(payload["tool"], get(payload, "arguments", Dict{String,Any}()), get(payload, "provider_info", Dict{String,Any}()))
    elseif event_name == "tool_call.success"
        return ToolCallSuccessEvent(payload["tool"], get(payload, "arguments", Dict{String,Any}()), get(payload, "output", ""), get(payload, "provider_info", Dict{String,Any}()))
    elseif event_name == "tool_call.failure"
        return ToolCallFailureEvent(payload["reason"], get(payload, "metadata", Dict{String,Any}()))
    elseif event_name == "message.start"
        return MessageStartEvent()
    elseif event_name == "message.delta"
        return MessageDeltaEvent(payload["content"])
    elseif event_name == "message.end"
        return MessageEndEvent()
    elseif event_name == "error"
        return StreamErrorEvent(payload["error"])
    elseif event_name == "chat.end"
        return ChatEndEvent(_parse_chat_response(payload["result"]))
    else
        return UnknownEvent(event_name, payload)
    end
end
```

```julia
# append to src/api.jl
function stream_chat(client::Client; model::String, input, system_prompt::Union{Nothing,String}=nothing, previous_response_id::Union{Nothing,String}=nothing, store::Bool=true, temperature=nothing, top_p=nothing, top_k=nothing, min_p=nothing, repeat_penalty=nothing, max_output_tokens=nothing, reasoning=nothing, context_length=nothing, _stream_transport=_stream_adapter)
    body = Dict{String,Any}("model" => model, "input" => input, "store" => store, "stream" => true)
    !isnothing(system_prompt) && (body["system_prompt"] = system_prompt)
    !isnothing(previous_response_id) && (body["previous_response_id"] = previous_response_id)
    for (key, value) in [
        "temperature" => temperature,
        "top_p" => top_p,
        "top_k" => top_k,
        "min_p" => min_p,
        "repeat_penalty" => repeat_penalty,
        "max_output_tokens" => max_output_tokens,
        "reasoning" => reasoning,
        "context_length" => context_length,
    ]
        !isnothing(value) && (body[key] = value)
    end
    lines = _stream_transport(; method="POST", path="/api/v1/chat", body=body, stream=true, client=client)
    return _decode_sse_lines(lines)
end

function stream_chat(client::Client, session::ChatSession, input; kwargs...)
    upstream = stream_chat(client; model=session.model, input=input, previous_response_id=session.previous_response_id, system_prompt=session.system_prompt, kwargs...)
    return Channel{LMStudioEvent}(32) do channel
        for event in upstream
            if event isa ChatEndEvent && !isnothing(event.result.response_id)
                session.previous_response_id = event.result.response_id
            end
            put!(channel, event)
        end
    end
end

function _stream_adapter(; method, path, body, stream, client)
    @assert stream == true
    return _stream_request_lines(client, method, path; body=body)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS with `stream_chat` returning a full-event iterable and updating `ChatSession` from the final `chat.end` event.

- [ ] **Step 5: Commit**

```bash
git add src/types.jl src/transport.jl src/sse.jl src/api.jl test/sse_test.jl
git commit -m "feat: implement streaming chat with full SSE events"
```

## Task 6: Add Live Integration Tests And Usage Example

**Files:**
- Create: `test/live_api_test.jl`
- Modify: `test/runtests.jl`
- Modify: `src/LMStudioClient.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/live_api_test.jl
using Test
using LMStudioClient

@testset "live LM Studio API" begin
    client = Client(
        base_url=get(ENV, "LMSTUDIO_BASE_URL", "http://127.0.0.1:1234"),
        api_token=get(ENV, "LMSTUDIO_API_TOKEN", nothing),
    )

    model = get(ENV, "LMSTUDIO_TEST_MODEL", "google/gemma-4-e2b")

    job = download_model(client, model)
    final_job = wait_for_download(client, job; poll_interval=1.0, timeout=1800)
    @test final_job.status in (:already_downloaded, :completed)

    loaded = load_model(client, model; context_length=8192)
    @test loaded.status == :loaded

    response = chat(client; model=model, input="Reply with the single word BLUE.")
    @test response.model_instance_id != ""
    @test !isempty(response.output)

    stream_events = collect(stream_chat(client; model=model, input="Reply with the single word GREEN."))
    @test any(event -> event isa MessageDeltaEvent, stream_events)
    @test stream_events[end] isa ChatEndEvent

    session = ChatSession(model)
    first_reply = chat(client, session, "Remember the word orange.")
    second_reply = chat(client, session, "What word did I ask you to remember?")
    @test !isnothing(first_reply.response_id)
    @test !isnothing(second_reply.response_id)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
LMSTUDIO_RUN_LIVE_TESTS=1 julia --project -e 'using Pkg; Pkg.test()'
```

Expected: FAIL because `test/live_api_test.jl` is not included yet and the live-test gate does not exist.

- [ ] **Step 3: Write minimal implementation**

```julia
# test/runtests.jl
using Test
using LMStudioClient

include("types_test.jl")
include("api_test.jl")
include("sse_test.jl")

if get(ENV, "LMSTUDIO_RUN_LIVE_TESTS", "0") == "1"
    include("live_api_test.jl")
end
```

```julia
# src/LMStudioClient.jl
module LMStudioClient

include("types.jl")
include("errors.jl")
include("transport.jl")
include("api.jl")
include("sse.jl")

export Client
export ChatSession
export DownloadJob
export LoadedModel
export ChatStats
export ChatResponse
export LMStudioEvent
export ChatStartEvent
export ModelLoadStartEvent
export ModelLoadProgressEvent
export ModelLoadEndEvent
export PromptProcessingStartEvent
export PromptProcessingProgressEvent
export PromptProcessingEndEvent
export ReasoningStartEvent
export ReasoningDeltaEvent
export ReasoningEndEvent
export ToolCallStartEvent
export ToolCallArgumentsEvent
export ToolCallSuccessEvent
export ToolCallFailureEvent
export MessageStartEvent
export MessageDeltaEvent
export MessageEndEvent
export StreamErrorEvent
export ChatEndEvent
export UnknownEvent
export download_model
export download_status
export wait_for_download
export load_model
export chat
export stream_chat

end # module LMStudioClient
```

- [ ] **Step 4: Run test to verify it passes**

Run mocked suite:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS without requiring LM Studio.

Run live suite:

```bash
LMSTUDIO_RUN_LIVE_TESTS=1 LMSTUDIO_TEST_MODEL=google/gemma-4-e2b julia --project -e 'using Pkg; Pkg.test()'
```

Expected: PASS against a running LM Studio server, with download, load, chat, streaming, and stateful chat working end to end.

- [ ] **Step 5: Commit**

```bash
git add src/LMStudioClient.jl test/runtests.jl test/live_api_test.jl
git commit -m "test: add optional live LM Studio API coverage"
```

## Self-Review

### Spec Coverage

- Download model: Task 2 and Task 3
- Download status and polling: Task 3
- Load model: Task 3
- Non-streaming chat: Task 3
- Stateful chat via `ChatSession`: Task 3 and Task 5
- Full SSE event support: Task 4 and Task 5
- Optional live verification using `google/gemma-4-e2b`: Task 6

No spec requirement is left without an implementation task.

### Placeholder Scan

- No `TODO`, `TBD`, or "implement later" markers remain.
- Each task includes exact file paths, commands, and concrete code snippets.
- No step says "write tests" without giving the test code.

### Type Consistency

- `Client`, `ChatSession`, `DownloadJob`, `LoadedModel`, `ChatResponse`, and `LMStudioEvent` are introduced in Task 1 and used consistently in later tasks.
- `stream_chat` is consistently defined as returning an iterable `Channel{LMStudioEvent}`.
- `ChatSession.previous_response_id` is updated in both non-streaming and streaming flows, matching the approved spec.
