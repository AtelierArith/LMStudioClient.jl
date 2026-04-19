# LM Studio Management Surface Design

Date: 2026-04-19

## Goal

`LMStudioClient.jl` を、chat-centric な thin client から、LM Studio の主要なモデル管理フローも扱える thin client へ広げる。

今回追加する対象:

- downloaded model の一覧取得
- loaded model instance の一覧取得
- loaded model instance の unload
- 簡単な server health/status probe

今回の前提:

- 後方互換性は維持しない
- 既存の flat function API は維持する
- LM Studio native REST API v1 を直接使う

非対象:

- namespace ベースの大規模 API 再設計
- embeddings 専用の高級ラッパー
- repository/search 系 API の追加
- CLI 呼び出しを使った status 実装

## External Contract

公式 docs で確認できる現行 v1 REST endpoint を前提にする。

- `GET /api/v1/models`
- `POST /api/v1/models/load`
- `POST /api/v1/models/unload`
- `POST /api/v1/models/download`
- `GET /api/v1/models/download/status`
- `POST /api/v1/chat`

重要な制約:

- loaded model 専用の別 REST endpoint は使わない
- server health/status 専用 endpoint は現行 docs 上存在しない
- したがって `list_loaded_models` は `GET /api/v1/models` の `loaded_instances` を flatten して作る
- `server_status` は `GET /api/v1/models` への probe を client-side に要約した結果とする

Reference:

- LM Studio REST overview: `https://lmstudio.ai/docs/developer/rest`
- List Models: `https://lmstudio.ai/docs/developer/rest/list`
- Unload Model: `https://lmstudio.ai/docs/developer/rest/unload`

## Public API

flat なトップレベル関数 API を維持する。

```julia
using LMStudioClient

client = Client()

status = server_status(client)
models = list_models(client)
loaded = list_loaded_models(client)

job = download_model(client, "google/gemma-4-e2b")
wait_for_download(client, job)

loaded_result = load_model(client, "google/gemma-4-e2b"; context_length=8192)
unloaded = unload_model(client, loaded_result.instance_id)
```

公開 API 一覧:

- `Client(; base_url="http://127.0.0.1:1234", api_token=nothing, timeout=30.0)`
- `server_status(client)`
- `list_models(client; domain=nothing)`
- `list_loaded_models(client; domain=nothing)`
- `download_model(client, model; quantization=nothing)`
- `download_status(client, job_id)`
- `wait_for_download(client, job_or_job_id; poll_interval=1.0, timeout=nothing)`
- `load_model(client, model; context_length=nothing, kwargs...)`
- `unload_model(client, instance_id::String)`
- `chat(client; model, input, system_prompt=nothing, previous_response_id=nothing, store=true, kwargs...)`
- `chat(client, session::ChatSession, input; kwargs...)`
- `stream_chat(client; model, input, system_prompt=nothing, previous_response_id=nothing, store=true, kwargs...)`
- `stream_chat(client, session::ChatSession, input; kwargs...)`

## Breaking Changes

後方互換を維持しない前提で、公開型を整理する。

### Rename

- `LoadedModel` を廃止し、`LoadModelResult` に改名する

理由:

- 既存の `LoadedModel` は `POST /api/v1/models/load` の結果であり、「loaded model 一覧の要素」ではない
- 今回 `LoadedModelInfo` を導入するため、`LoadedModel` という名前は曖昧で不適切

### New Public Types

- `ModelInfo`
- `LoadedModelInfo`
- `LoadModelResult`
- `UnloadModelResult`
- `ServerStatus`

## Core Types

### ModelInfo

`GET /api/v1/models` の `models[i]` を表す canonical struct。

想定 field:

- `type::Symbol`
- `publisher::String`
- `key::String`
- `display_name::String`
- `architecture::Union{Nothing,String}`
- `quantization::Union{Nothing,Dict{String,Any}}`
- `size_bytes::Int`
- `params_string::Union{Nothing,String}`
- `max_context_length::Int`
- `format::Union{Nothing,String}`
- `capabilities::Dict{String,Any}`
- `description::Union{Nothing,String}`
- `variants::Vector{String}`
- `selected_variant::Union{Nothing,String}`
- `raw::Dict{String,Any}`

`loaded_instances` は `ModelInfo` の primary field にしない。必要なら `raw` から参照できるようにする。

### LoadedModelInfo

`GET /api/v1/models` の各 `loaded_instances[j]` を、親 model 情報つきで flatten した struct。

想定 field:

- `instance_id::String`
- `model_key::String`
- `type::Symbol`
- `publisher::String`
- `display_name::String`
- `architecture::Union{Nothing,String}`
- `context_length::Int`
- `eval_batch_size::Union{Nothing,Int}`
- `parallel::Union{Nothing,Int}`
- `flash_attention::Union{Nothing,Bool}`
- `num_experts::Union{Nothing,Int}`
- `offload_kv_cache_to_gpu::Union{Nothing,Bool}`
- `raw::Dict{String,Any}`

### LoadModelResult

`POST /api/v1/models/load` の結果を表す。既存 `LoadedModel` の置き換え。

- `type::Symbol`
- `instance_id::String`
- `status::Symbol`
- `load_time_seconds::Float64`
- `load_config::Dict{String,Any}`

### UnloadModelResult

`POST /api/v1/models/unload` の結果を表す。

- `instance_id::String`
- `raw::Dict{String,Any}`

### ServerStatus

REST resource ではなく、probe 結果の要約。

- `reachable::Bool`
- `authenticated::Union{Nothing,Bool}`
- `model_count::Union{Nothing,Int}`
- `error_kind::Union{Nothing,Symbol}`
- `raw_error::Union{Nothing,Any}`

`error_kind` 候補:

- `:http`
- `:api`
- `:timeout`
- `:transport`

## Endpoint Mapping

### `list_models`

- endpoint: `GET /api/v1/models`
- return: `Vector{ModelInfo}`
- `domain` は `:llm` / `:embedding` / `nothing` を受け、client-side filter する

### `list_loaded_models`

- endpoint: `GET /api/v1/models`
- return: `Vector{LoadedModelInfo}`
- 各 model の `loaded_instances` を flatten して構築する
- `domain` は parent model の `type` を用いて filter する

### `unload_model`

- endpoint: `POST /api/v1/models/unload`
- request body: `Dict("instance_id" => instance_id)`
- return: `UnloadModelResult`

### `server_status`

- probe endpoint: `GET /api/v1/models`
- 専用 health endpoint がないため、あくまで management API 到達性の判定とする

判定 rules:

- 2xx:
  - `reachable=true`
  - `authenticated=true`
  - `model_count=length(models)`
- 401 / 403:
  - `reachable=true`
  - `authenticated=false`
  - `model_count=nothing`
- `LMStudioHTTPError` のその他:
  - `reachable=true`
  - `authenticated=nothing`
  - `error_kind=:http`
- `LMStudioAPIError`:
  - `reachable=true`
  - `authenticated=true`
  - `error_kind=:api`
- `LMStudioTimeoutError`:
  - `reachable=false`
  - `authenticated=nothing`
  - `error_kind=:timeout`
- その他 transport failure:
  - `reachable=false`
  - `authenticated=nothing`
  - `error_kind=:transport`

## Internal Structure

既存の module layout を維持して拡張する。

```text
src/
  LMStudioClient.jl
  types.jl
  errors.jl
  transport.jl
  sse.jl
  api.jl
```

変更内容:

- `src/types.jl`
  - `LoadedModel` を `LoadModelResult` に置換
  - `ModelInfo`, `LoadedModelInfo`, `UnloadModelResult`, `ServerStatus` を追加
- `src/api.jl`
  - `_parse_model_info`
  - `_parse_loaded_model_infos`
  - `_parse_unload_result`
  - `list_models`
  - `list_loaded_models`
  - `unload_model`
  - `server_status`
- `src/LMStudioClient.jl`
  - export list を更新

## Parsing Rules

### Model type normalization

既存の `:llm` / `:embedding` を再利用する。

### Optional field handling

LM Studio docs では absent と `null` が混在するため、Julia 側は `Union{Nothing,T}` で正規化する。

### Raw preservation

新規 management struct は `raw::Dict{String,Any}` を持つ。

理由:

- docs と実サーバ payload の差分に耐えやすい
- v1 の thin client 方針に合う
- 初版で fields を出し切れなくても downstream user が逃げ道を持てる

## Error Handling

既存 exception type は維持する。

- `LMStudioHTTPError`
- `LMStudioAPIError`
- `LMStudioProtocolError`
- `LMStudioTimeoutError`

`server_status` だけは、これらをそのまま再 throw せず `ServerStatus` に畳み込む。
他の API は既存方針どおり exception を投げる。

## Testing

### Unit / fake transport tests

追加対象:

- `list_models` が `GET /api/v1/models` を呼ぶ
- `list_models(...; domain=:llm)` と `domain=:embedding` が client-side filter する
- `list_loaded_models` が nested `loaded_instances` を flatten する
- `unload_model` が `POST /api/v1/models/unload` に `instance_id` を送る
- `server_status` が success / 401 / 403 / timeout / transport failure を正しく分類する

### HTTP fake server tests

既存の `HTTP.serve!` ベースを再利用して:

- `GET /api/v1/models` payload の end-to-end parse
- `POST /api/v1/models/unload` payload shape

### Live tests

追加対象:

- `server_status(client)` が `reachable=true` を返す
- `list_models(client)` が少なくとも 1 件以上返す
- `list_loaded_models(client)` が loaded model を返す

`unload_model` live test は慎重に扱う。

初版方針:

- live suite では必須にしない
- 専用 instance を安全に作って壊せる設計が入るまでは optional verification に留める

## Documentation

README と docs は usage-first を維持する。

### README

supported flows に追加:

- model listing
- loaded model listing
- model unload
- server status

quick examples を短く追加する。

### `docs/src/getting-started.md`

冒頭で以下を見せる:

1. `server_status(client)`
2. `list_models(client)`
3. 必要なら `list_loaded_models(client)`

これにより first-time user が最初に接続性と model discovery を確認できる。

### New doc page

`docs/src/model-management.md` を追加し、以下を集約する。

- `server_status`
- `list_models`
- `list_loaded_models`
- `load_model`
- `unload_model`

`streaming.md` は原則変更しない。

## Migration Impact

breaking change の主要点は 1 つ。

- `LoadedModel` を使っていた downstream code は `LoadModelResult` へ置換が必要

README と getting-started でこの rename を反映し、公開 surface の基準名を新しいものへ揃える。

## Completion Criteria

この作業は以下を満たした時点で完了とする。

1. `ModelInfo`, `LoadedModelInfo`, `UnloadModelResult`, `ServerStatus`, `LoadModelResult` が公開される
2. `list_models`, `list_loaded_models`, `unload_model`, `server_status` が実装される
3. `load_model` の戻り値型名が `LoadModelResult` に更新される
4. fake server test と live test が追加される
5. README / getting-started / model-management docs が更新される
