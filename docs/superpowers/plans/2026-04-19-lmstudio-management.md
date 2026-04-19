# LM Studio Management Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add model listing, loaded-model listing, unload, and server status APIs to `LMStudioClient.jl`, while renaming `LoadedModel` to `LoadModelResult` as a deliberate breaking change.

**Architecture:** Keep the existing flat API shape and file layout. Reuse `GET /api/v1/models` as the single source for both downloaded-model and loaded-instance views, model `server_status` as a client-side probe over that endpoint, and preserve the thin-client approach by exposing typed core fields plus `raw` payload escape hatches.

**Tech Stack:** Julia 1.12, HTTP.jl, JSON3.jl, Documenter.jl, LM Studio REST API v1

---

## File Structure

### Existing files to modify

- `src/types.jl`
  - Rename `LoadedModel` to `LoadModelResult`
  - Add `ModelInfo`, `LoadedModelInfo`, `UnloadModelResult`, `ServerStatus`
- `src/api.jl`
  - Add model-list parsing, loaded-instance flattening, unload, and server-status logic
  - Update `load_model` to return `LoadModelResult`
- `src/LMStudioClient.jl`
  - Update exports for renamed and new public types/functions
- `test/api_test.jl`
  - Add fake transport / fake server tests for the new management APIs
  - Update type name assertions from `LoadedModel` to `LoadModelResult`
- `test/live_api_test.jl`
  - Add live coverage for `server_status`, `list_models`, and `list_loaded_models`
  - Keep `unload_model` live verification optional / non-destructive
- `README.md`
  - Expand supported flows and quickstart to include management APIs
- `docs/src/index.md`
  - Add the new management page to the docs landing page
- `docs/src/getting-started.md`
  - Show `server_status` and model discovery before first load/chat
- `docs/make.jl`
  - Register the new docs page in the Documenter nav

### New files to create

- `docs/src/model-management.md`
  - Usage-first examples for `server_status`, `list_models`, `list_loaded_models`, `load_model`, `unload_model`

---

### Task 1: Rename `LoadedModel` To `LoadModelResult`

**Files:**
- Modify: `src/types.jl`
- Modify: `src/api.jl`
- Modify: `src/LMStudioClient.jl`
- Modify: `test/api_test.jl`

- [ ] **Step 1: Write the failing type-rename test updates**

Update the load-related assertions in `test/api_test.jl` so the file expects `LoadModelResult` instead of `LoadedModel`.

```julia
loaded = LMStudioClient.load_model(client, "google/gemma-4-e2b"; context_length=8192, _transport=fake_transport)
@test loaded isa LoadModelResult
@test loaded.instance_id == "google/gemma-4-e2b"
@test loaded.load_config["context_length"] == 8192
@test loaded.type == :llm

embedding_loaded = LMStudioClient.load_model(
    client,
    "nomic-ai/nomic-embed-text-v1.5";
    context_length=2048,
    _transport=embedding_load_transport,
)
@test embedding_loaded isa LoadModelResult
@test embedding_loaded.type == :embedding
@test embedding_loaded.status == :loaded
```

- [ ] **Step 2: Run the API test file to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: FAIL with `UndefVarError: LoadModelResult not defined` or similar type/export failure.

- [ ] **Step 3: Rename the public type and update exports**

In `src/types.jl`, replace the old struct with:

```julia
struct LoadModelResult
    type::Symbol
    instance_id::String
    status::Symbol
    load_time_seconds::Float64
    load_config::Dict{String,Any}
end
```

In `src/api.jl`, update `load_model` to construct `LoadModelResult(...)`:

```julia
return LoadModelResult(
    _parse_load_type(String(data["type"])),
    String(data["instance_id"]),
    _parse_load_status(String(data["status"])),
    Float64(data["load_time_seconds"]),
    get(data, "load_config", Dict{String,Any}()),
)
```

In `src/LMStudioClient.jl`, replace:

```julia
export LoadedModel
```

with:

```julia
export LoadModelResult
```

- [ ] **Step 4: Run the API test file to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: PASS for all existing `test/api_test.jl` testsets.

- [ ] **Step 5: Commit**

```bash
git add src/types.jl src/api.jl src/LMStudioClient.jl test/api_test.jl
git commit -m "refactor: rename LoadedModel to LoadModelResult"
```

### Task 2: Add `ModelInfo`, `LoadedModelInfo`, `list_models`, and `list_loaded_models`

**Files:**
- Modify: `src/types.jl`
- Modify: `src/api.jl`
- Modify: `src/LMStudioClient.jl`
- Modify: `test/api_test.jl`

- [ ] **Step 1: Write the failing tests for model listing and flattening**

Append a new testset to `test/api_test.jl`:

```julia
@testset "model listing APIs" begin
    captured = Ref{Any}(nothing)
    fake_transport = function (; method, path, body=nothing, stream, client)
        captured[] = (; method, path, body, stream)
        return Dict(
            "models" => Any[
                Dict(
                    "type" => "llm",
                    "publisher" => "google",
                    "key" => "google/gemma-4-e2b",
                    "display_name" => "Gemma 4 E2B",
                    "architecture" => "gemma4",
                    "quantization" => Dict("name" => "Q4_K_M", "bits_per_weight" => 4),
                    "size_bytes" => 4410000000,
                    "params_string" => "4.6B",
                    "loaded_instances" => Any[
                        Dict(
                            "id" => "google/gemma-4-e2b:1",
                            "config" => Dict(
                                "context_length" => 8192,
                                "eval_batch_size" => 512,
                                "parallel" => 4,
                                "flash_attention" => true,
                                "num_experts" => 0,
                                "offload_kv_cache_to_gpu" => true,
                            ),
                        ),
                    ],
                    "max_context_length" => 131072,
                    "format" => "gguf",
                    "capabilities" => Dict("vision" => false, "trained_for_tool_use" => true),
                    "description" => nothing,
                    "variants" => Any["google/gemma-4-e2b@q4_k_m"],
                    "selected_variant" => "google/gemma-4-e2b@q4_k_m",
                ),
                Dict(
                    "type" => "embedding",
                    "publisher" => "nomic",
                    "key" => "text-embedding-nomic-embed-text-v1.5",
                    "display_name" => "Nomic Embed Text v1.5",
                    "quantization" => Dict("name" => "F16", "bits_per_weight" => 16),
                    "size_bytes" => 84000000,
                    "params_string" => nothing,
                    "loaded_instances" => Any[],
                    "max_context_length" => 2048,
                    "format" => "gguf",
                ),
            ],
        )
    end

    client = Client()
    models = LMStudioClient.list_models(client; _transport=fake_transport)
    @test captured[].method == "GET"
    @test captured[].path == "/api/v1/models"
    @test isnothing(captured[].body)
    @test length(models) == 2
    @test models[1] isa ModelInfo
    @test models[1].type == :llm
    @test models[1].key == "google/gemma-4-e2b"
    @test models[2].type == :embedding

    llm_only = LMStudioClient.list_models(client; domain=:llm, _transport=fake_transport)
    @test length(llm_only) == 1
    @test llm_only[1].type == :llm

    loaded = LMStudioClient.list_loaded_models(client; _transport=fake_transport)
    @test length(loaded) == 1
    @test loaded[1] isa LoadedModelInfo
    @test loaded[1].instance_id == "google/gemma-4-e2b:1"
    @test loaded[1].model_key == "google/gemma-4-e2b"
    @test loaded[1].context_length == 8192
    @test loaded[1].parallel == 4

    embedding_only = LMStudioClient.list_loaded_models(client; domain=:embedding, _transport=fake_transport)
    @test isempty(embedding_only)
end
```

- [ ] **Step 2: Run the API test file to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: FAIL with missing `ModelInfo`, `LoadedModelInfo`, `list_models`, or `list_loaded_models`.

- [ ] **Step 3: Add the new public types**

Insert these structs into `src/types.jl` below `DownloadJob` and above `ChatStats`:

```julia
struct ModelInfo
    type::Symbol
    publisher::String
    key::String
    display_name::String
    architecture::Union{Nothing,String}
    quantization::Union{Nothing,Dict{String,Any}}
    size_bytes::Int
    params_string::Union{Nothing,String}
    max_context_length::Int
    format::Union{Nothing,String}
    capabilities::Dict{String,Any}
    description::Union{Nothing,String}
    variants::Vector{String}
    selected_variant::Union{Nothing,String}
    raw::Dict{String,Any}
end

struct LoadedModelInfo
    instance_id::String
    model_key::String
    type::Symbol
    publisher::String
    display_name::String
    architecture::Union{Nothing,String}
    context_length::Int
    eval_batch_size::Union{Nothing,Int}
    parallel::Union{Nothing,Int}
    flash_attention::Union{Nothing,Bool}
    num_experts::Union{Nothing,Int}
    offload_kv_cache_to_gpu::Union{Nothing,Bool}
    raw::Dict{String,Any}
end
```

Update `src/LMStudioClient.jl` exports:

```julia
export ModelInfo
export LoadedModelInfo
export list_models
export list_loaded_models
```

- [ ] **Step 4: Implement model parsing and flattening**

Add helpers to `src/api.jl`:

```julia
function _parse_model_info(data::AbstractDict{String,<:Any})
    ModelInfo(
        _parse_load_type(String(data["type"])),
        String(get(data, "publisher", "")),
        String(data["key"]),
        String(get(data, "display_name", data["key"])),
        isnothing(get(data, "architecture", nothing)) ? nothing : String(data["architecture"]),
        isnothing(get(data, "quantization", nothing)) ? nothing : Dict{String,Any}(data["quantization"]),
        Int(get(data, "size_bytes", 0)),
        isnothing(get(data, "params_string", nothing)) ? nothing : String(data["params_string"]),
        Int(get(data, "max_context_length", 0)),
        isnothing(get(data, "format", nothing)) ? nothing : String(data["format"]),
        haskey(data, "capabilities") ? Dict{String,Any}(data["capabilities"]) : Dict{String,Any}(),
        isnothing(get(data, "description", nothing)) ? nothing : String(data["description"]),
        [String(item) for item in get(data, "variants", Any[])],
        isnothing(get(data, "selected_variant", nothing)) ? nothing : String(data["selected_variant"]),
        Dict{String,Any}(data),
    )
end

function _parse_loaded_model_infos(model_data::AbstractDict{String,<:Any})
    model_type = _parse_load_type(String(model_data["type"]))
    publisher = String(get(model_data, "publisher", ""))
    model_key = String(model_data["key"])
    display_name = String(get(model_data, "display_name", model_key))
    architecture = isnothing(get(model_data, "architecture", nothing)) ? nothing : String(model_data["architecture"])

    return LoadedModelInfo[
        LoadedModelInfo(
            String(instance["id"]),
            model_key,
            model_type,
            publisher,
            display_name,
            architecture,
            Int(instance["config"]["context_length"]),
            haskey(instance["config"], "eval_batch_size") ? Int(instance["config"]["eval_batch_size"]) : nothing,
            haskey(instance["config"], "parallel") ? Int(instance["config"]["parallel"]) : nothing,
            haskey(instance["config"], "flash_attention") ? Bool(instance["config"]["flash_attention"]) : nothing,
            haskey(instance["config"], "num_experts") ? Int(instance["config"]["num_experts"]) : nothing,
            haskey(instance["config"], "offload_kv_cache_to_gpu") ? Bool(instance["config"]["offload_kv_cache_to_gpu"]) : nothing,
            Dict{String,Any}(instance),
        )
        for instance in get(model_data, "loaded_instances", Any[])
    ]
end

function list_models(client::Client; domain=nothing, _transport=_request_adapter)
    data = _transport(; method="GET", path="/api/v1/models", body=nothing, stream=false, client=client)
    models = [_parse_model_info(model) for model in get(data, "models", Any[])]
    isnothing(domain) && return models
    return [model for model in models if model.type == domain]
end

function list_loaded_models(client::Client; domain=nothing, _transport=_request_adapter)
    data = _transport(; method="GET", path="/api/v1/models", body=nothing, stream=false, client=client)
    loaded = LoadedModelInfo[]
    for model in get(data, "models", Any[])
        model_type = _parse_load_type(String(model["type"]))
        if isnothing(domain) || model_type == domain
            append!(loaded, _parse_loaded_model_infos(model))
        end
    end
    return loaded
end
```

- [ ] **Step 5: Run the API test file to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: PASS for the new `model listing APIs` testset and all existing API tests.

- [ ] **Step 6: Commit**

```bash
git add src/types.jl src/api.jl src/LMStudioClient.jl test/api_test.jl
git commit -m "feat: add model listing APIs"
```

### Task 3: Add `UnloadModelResult`, `unload_model`, and `server_status`

**Files:**
- Modify: `src/types.jl`
- Modify: `src/api.jl`
- Modify: `src/LMStudioClient.jl`
- Modify: `test/api_test.jl`

- [ ] **Step 1: Write the failing tests for unload and server status**

Append this testset to `test/api_test.jl`:

```julia
@testset "unload and server status APIs" begin
    captured = Ref{Any}(nothing)
    unload_transport = function (; method, path, body, stream, client)
        captured[] = (; method, path, body, stream)
        return Dict("instance_id" => "google/gemma-4-e2b:9")
    end

    client = Client()
    unloaded = LMStudioClient.unload_model(client, "google/gemma-4-e2b:9"; _transport=unload_transport)
    @test captured[].method == "POST"
    @test captured[].path == "/api/v1/models/unload"
    @test captured[].body["instance_id"] == "google/gemma-4-e2b:9"
    @test unloaded isa UnloadModelResult
    @test unloaded.instance_id == "google/gemma-4-e2b:9"

    ok_transport = function (; method, path, body=nothing, stream, client)
        return Dict("models" => Any[Dict("type" => "llm", "key" => "google/gemma-4-e2b", "display_name" => "Gemma", "publisher" => "google", "loaded_instances" => Any[], "size_bytes" => 1, "max_context_length" => 1)])
    end
    ok_status = LMStudioClient.server_status(client; _transport=ok_transport)
    @test ok_status.reachable == true
    @test ok_status.authenticated == true
    @test ok_status.model_count == 1
    @test isnothing(ok_status.error_kind)

    unauthorized_transport = function (; method, path, body=nothing, stream, client)
        throw(LMStudioClient.LMStudioHTTPError(401, "unauthorized"))
    end
    unauthorized = LMStudioClient.server_status(client; _transport=unauthorized_transport)
    @test unauthorized.reachable == true
    @test unauthorized.authenticated == false
    @test isnothing(unauthorized.model_count)

    timeout_transport = function (; method, path, body=nothing, stream, client)
        throw(LMStudioClient.LMStudioTimeoutError("Timed out"))
    end
    timed_out = LMStudioClient.server_status(client; _transport=timeout_transport)
    @test timed_out.reachable == false
    @test timed_out.error_kind == :timeout

    transport_failure = function (; method, path, body=nothing, stream, client)
        throw(IOError("boom"))
    end
    failed = LMStudioClient.server_status(client; _transport=transport_failure)
    @test failed.reachable == false
    @test failed.error_kind == :transport
end
```

- [ ] **Step 2: Run the API test file to verify it fails**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: FAIL with missing `UnloadModelResult`, `unload_model`, or `server_status`.

- [ ] **Step 3: Add the new type and exports**

Insert these structs into `src/types.jl`:

```julia
struct UnloadModelResult
    instance_id::String
    raw::Dict{String,Any}
end

struct ServerStatus
    reachable::Bool
    authenticated::Union{Nothing,Bool}
    model_count::Union{Nothing,Int}
    error_kind::Union{Nothing,Symbol}
    raw_error::Union{Nothing,Any}
end
```

Update `src/LMStudioClient.jl`:

```julia
export UnloadModelResult
export ServerStatus
export unload_model
export server_status
```

- [ ] **Step 4: Implement unload and server-status logic**

Add to `src/api.jl`:

```julia
function _parse_unload_result(data::AbstractDict{String,<:Any})
    return UnloadModelResult(String(data["instance_id"]), Dict{String,Any}(data))
end

function unload_model(client::Client, instance_id::String; _transport=_request_adapter)
    data = _transport(
        ; method="POST",
        path="/api/v1/models/unload",
        body=Dict{String,Any}("instance_id" => instance_id),
        stream=false,
        client=client,
    )
    return _parse_unload_result(data)
end

function server_status(client::Client; _transport=_request_adapter)
    try
        data = _transport(; method="GET", path="/api/v1/models", body=nothing, stream=false, client=client)
        return ServerStatus(true, true, length(get(data, "models", Any[])), nothing, nothing)
    catch err
        if err isa LMStudioHTTPError
            if err.status == 401 || err.status == 403
                return ServerStatus(true, false, nothing, nothing, err)
            end
            return ServerStatus(true, nothing, nothing, :http, err)
        elseif err isa LMStudioAPIError
            return ServerStatus(true, true, nothing, :api, err)
        elseif err isa LMStudioTimeoutError
            return ServerStatus(false, nothing, nothing, :timeout, err)
        else
            return ServerStatus(false, nothing, nothing, :transport, err)
        end
    end
end
```

- [ ] **Step 5: Run the API test file to verify it passes**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/api_test.jl")'
```

Expected: PASS for the new `unload and server status APIs` testset and all existing API tests.

- [ ] **Step 6: Commit**

```bash
git add src/types.jl src/api.jl src/LMStudioClient.jl test/api_test.jl
git commit -m "feat: add unload and server status APIs"
```

### Task 4: Update Live Tests and User-Facing Docs

**Files:**
- Modify: `test/live_api_test.jl`
- Modify: `README.md`
- Modify: `docs/src/index.md`
- Modify: `docs/src/getting-started.md`
- Create: `docs/src/model-management.md`
- Modify: `docs/make.jl`

- [ ] **Step 1: Write the failing live-test and docs assertions**

In `test/live_api_test.jl`, add these checks near the top of the main testset:

```julia
status = server_status(client)
@test status.reachable == true
@test status.authenticated in (true, nothing)

models = list_models(client)
@test !isempty(models)
@test any(model -> model.key == model_name || startswith(model.key, model_name), models)

loaded_models = list_loaded_models(client)
@test any(item -> item.model_key == model || startswith(item.instance_id, model), loaded_models)
```

Use `model_name = model` if you keep the existing variable name as-is.

In `README.md`, replace the top bullet list with:

```md
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
```

- [ ] **Step 2: Run the live test file in dry-run fashion to verify the new references fail**

Run:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); include("test/live_api_test.jl")'
```

Expected: If `LMSTUDIO_RUN_LIVE_TESTS` is unset, the file should still parse and print the skip message. If it fails to parse because the new symbols do not exist yet, fix those symbols before moving on.

- [ ] **Step 3: Update the docs and live coverage**

Update `README.md` quickstart to show discovery before load:

```julia
client = Client()

println(server_status(client).reachable)

models = list_models(client; domain=:llm)
println(first(models).key)
```

Create `docs/src/model-management.md` with:

```md
# Model Management

## Check Server Status

```julia
using LMStudioClient

client = Client()
status = server_status(client)
println(status.reachable)
```

## List Downloaded Models

```julia
models = list_models(client)
for model in models
    println(model.key)
end
```

## List Loaded Models

```julia
loaded = list_loaded_models(client)
for item in loaded
    println(item.instance_id)
end
```

## Unload A Model

```julia
result = unload_model(client, "google/gemma-4-e2b:1")
println(result.instance_id)
```
```

Update `docs/src/index.md` list and links:

```md
- downloading models
- listing downloaded models
- listing loaded models
- loading and unloading models
- one-shot chat
- stateful chat with `ChatSession`
- streaming chat with `stream_chat`

## Docs

- [Getting Started](getting-started.md)
- [Model Management](model-management.md)
- [Streaming](streaming.md)
```

Update `docs/make.jl` pages:

```julia
pages = [
    "Home" => "index.md",
    "Getting Started" => "getting-started.md",
    "Model Management" => "model-management.md",
    "Streaming" => "streaming.md",
],
```

In `docs/src/getting-started.md`, prepend the new discovery flow:

```md
## Check Server Reachability And Discover Models

```julia
using LMStudioClient

client = Client()

status = server_status(client)
println(status.reachable)

models = list_models(client; domain=:llm)
println(first(models).key)
```
```

- [ ] **Step 4: Run tests and docs build**

Run:

```bash
julia --project -e 'using Pkg; Pkg.test()'
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
LMSTUDIO_RUN_LIVE_TESTS=1 LMSTUDIO_TEST_MODEL=google/gemma-4-e2b julia --project -e 'using Pkg; Pkg.test()'
```

Expected:

- unit/integration tests PASS
- docs build completes without errors
- live tests PASS for `server_status`, `list_models`, `list_loaded_models`, existing download/load/chat/stream/session checks

- [ ] **Step 5: Commit**

```bash
git add test/live_api_test.jl README.md docs/src/index.md docs/src/getting-started.md docs/src/model-management.md docs/make.jl
git commit -m "docs: add management API guidance and live coverage"
```

### Task 5: Final Verification And Feature Test

**Files:**
- Modify: `docs/test-reports/` (new generated report only if rerun requested)

- [ ] **Step 1: Re-run the downstream user feature test**

Run the same scratch-environment user flow used earlier, but now verify the new management path first:

```bash
lms server status
lms ls
lms ps
```

Create a scratch script with:

```julia
using LMStudioClient

client = Client()
println(server_status(client).reachable)

models = list_models(client; domain=:llm)
println(first(models).key)

loaded = list_loaded_models(client)
println(length(loaded))
```

- [ ] **Step 2: Save the report**

Write a new report under `docs/test-reports/test-feature-<timestamp>.md` summarizing:

```md
## Issues Found

None.
```

if the rerun is clean.

- [ ] **Step 3: Run a final repo verification**

Run:

```bash
git status --short
julia --project -e 'using Pkg; Pkg.test()'
```

Expected:

- only intentional modified/tracked files remain
- test suite PASS

- [ ] **Step 4: Commit**

```bash
git add docs/test-reports
git commit -m "test: verify management surface from user docs"
```

---

## Self-Review

### Spec coverage

- `LoadedModel` to `LoadModelResult` rename: covered in Task 1
- `ModelInfo` / `LoadedModelInfo`: covered in Task 2
- `UnloadModelResult` / `ServerStatus`: covered in Task 3
- `list_models` / `list_loaded_models`: covered in Task 2
- `unload_model` / `server_status`: covered in Task 3
- fake transport / HTTP tests: covered in Tasks 2 and 3
- live tests: covered in Task 4
- README/docs updates: covered in Task 4
- downstream-user rerun: covered in Task 5

### Placeholder scan

- No `TODO`, `TBD`, or “similar to Task N” placeholders remain.
- Every code-changing step includes concrete code snippets.
- Every verification step includes exact commands and expected outcomes.

### Type consistency

- `LoadModelResult` is the only post-rename load result type used anywhere in the plan.
- `ModelInfo`, `LoadedModelInfo`, `UnloadModelResult`, and `ServerStatus` names are used consistently across tests, implementation, and docs.
