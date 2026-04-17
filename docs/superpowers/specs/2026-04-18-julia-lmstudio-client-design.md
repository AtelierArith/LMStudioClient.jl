# Julia LM Studio Client Design

Date: 2026-04-18

## Goal

`@lmstudio/sdk` を参考にしつつ、Julia ではより薄い API で LM Studio native REST API の主要機能を利用できるクライアントを提供する。

v1 の対象範囲:

- モデルのダウンロード
- モデルのロード
- チャット
- stateful chat
- full SSE event を返す streaming chat

v1 の非対象:

- embeddings
- repository 全機能
- plugins / MCP の高級ラッパー
- `@lmstudio/sdk` 同等の namespace 全再現

## External Contract

LM Studio の現行 native REST API を直接利用する。

- `POST /api/v1/models/download`
- `GET /api/v1/models/download/status/:job_id`
- `POST /api/v1/models/load`
- `POST /api/v1/chat`

採用理由:

- 今回必要な download / load / chat / stateful chat / streaming をすべて満たす
- `lmstudio-js` の内部 WebSocket 実装を Julia に持ち込まずに済む
- Julia 側 API を薄く、LM Studio の公式ドキュメントに対応づけやすい

## Public API

v1 はトップレベル関数中心にする。

```julia
using LMStudioClient

client = Client()

job = download_model(client, "google/gemma-4-e2b")
job = wait_for_download(client, job)

loaded = load_model(client, "google/gemma-4-e2b"; context_length=8192)

resp = chat(client; model="google/gemma-4-e2b", input="Hello")

for event in stream_chat(client; model="google/gemma-4-e2b", input="Hello")
    @show event
end

session = ChatSession("google/gemma-4-e2b")
resp1 = chat(client, session, "My favorite color is blue.")
resp2 = chat(client, session, "What color did I mention?")
```

公開 API:

- `Client(; base_url="http://127.0.0.1:1234", api_token=nothing, timeout=...)`
- `download_model(client, model; quantization=nothing)`
- `download_status(client, job_id)`
- `wait_for_download(client, job_or_job_id; poll_interval=1.0, timeout=nothing)`
- `load_model(client, model; context_length=nothing, kwargs...)`
- `chat(client; model, input, system_prompt=nothing, previous_response_id=nothing, store=true, stream=false, kwargs...)`
- `chat(client, session::ChatSession, input; kwargs...)`
- `stream_chat(client; model, input, system_prompt=nothing, previous_response_id=nothing, store=true, kwargs...)`
- `stream_chat(client, session::ChatSession, input; kwargs...)`

`stream_chat` は `LMStudioEvent` を順に返す iterator を返す。

## Core Types

### Client

HTTP 接続設定を保持する。

- `base_url::String`
- `api_token::Union{Nothing,String}`
- `timeout`
- internal HTTP options

### DownloadJob

`/models/download` および `/models/download/status` の結果を表す。

- `job_id::Union{Nothing,String}`
- `status::Symbol`
- `total_size_bytes::Union{Nothing,Int}`
- `downloaded_bytes::Union{Nothing,Int}`
- `started_at`
- `completed_at`
- `bytes_per_second`
- `estimated_completion`

### LoadedModel

`/models/load` の結果を表す。

- `type::Symbol`
- `instance_id::String`
- `status::Symbol`
- `load_time_seconds::Float64`
- `load_config::Dict{String,Any}`

### ChatResponse

non-streaming chat の最終結果を表す。

- `model_instance_id::String`
- `output::Vector{ChatOutputItem}`
- `stats::ChatStats`
- `response_id::Union{Nothing,String}`

### ChatSession

stateful chat 補助用の軽量 struct。

- `model::String`
- `previous_response_id::Union{Nothing,String}`
- `system_prompt::Union{Nothing,String}`
- optional default generation parameters

`chat(client, session, ...)` と `stream_chat(client, session, ...)` は成功時に `previous_response_id` を更新する。

### Streaming Events

`stream_chat` は以下の concrete event を返す。

- `ChatStartEvent`
- `ModelLoadStartEvent`
- `ModelLoadProgressEvent`
- `ModelLoadEndEvent`
- `PromptProcessingStartEvent`
- `PromptProcessingProgressEvent`
- `PromptProcessingEndEvent`
- `ReasoningStartEvent`
- `ReasoningDeltaEvent`
- `ReasoningEndEvent`
- `ToolCallStartEvent`
- `ToolCallArgumentsEvent`
- `ToolCallSuccessEvent`
- `ToolCallFailureEvent`
- `MessageStartEvent`
- `MessageDeltaEvent`
- `MessageEndEvent`
- `StreamErrorEvent`
- `ChatEndEvent`
- `UnknownEvent`

`ChatEndEvent` は `result::ChatResponse` を持つ。
`UnknownEvent` は forward compatibility 用に raw payload を保持する。

## Module Layout

```text
src/
  LMStudioClient.jl
  types.jl
  errors.jl
  transport.jl
  sse.jl
  api.jl
```

役割:

- `types.jl`: public struct, event type, response type
- `errors.jl`: custom exception
- `transport.jl`: HTTP request / response handling
- `sse.jl`: SSE parsing と iterator 実装
- `api.jl`: public API と JSON mapping

## Data Flow

### Download

1. `download_model` が `POST /api/v1/models/download` を呼ぶ
2. `DownloadJob` を返す
3. `wait_for_download` は `already_downloaded` なら即 return
4. `job_id` がある場合は `GET /api/v1/models/download/status/:job_id` を polling
5. `completed` で return, `failed` で例外

### Load

1. `load_model` が `POST /api/v1/models/load` を呼ぶ
2. kwargs を request body に反映する
3. `LoadedModel` を返す

### Chat

1. request body を構築する
2. `session` がある場合は `session.model` と `session.previous_response_id` を優先利用する
3. `POST /api/v1/chat` を呼ぶ
4. `ChatResponse` を返す
5. `response_id` がある場合、`session.previous_response_id` を更新する

### Stream Chat

1. `POST /api/v1/chat` with `stream=true`
2. HTTP response body を SSE として逐次 parse
3. named event を `LMStudioEvent` subtype に decode
4. iterator から順に yield
5. `chat.end` を受けたら `ChatEndEvent` を返し、必要なら session を更新

## Request Mapping

v1 では request option は docs で確認できたものを中心に露出する。

共通 chat parameter:

- `model`
- `input`
- `system_prompt`
- `previous_response_id`
- `store`
- `temperature`
- `top_p`
- `top_k`
- `min_p`
- `repeat_penalty`
- `max_output_tokens`
- `reasoning`
- `context_length`

load parameter:

- `model`
- `context_length`
- `eval_batch_size`
- `flash_attention`
- `num_experts`
- `offload_kv_cache_to_gpu`
- `echo_load_config`

実装方針:

- まずは明示的な keyword を受け取る
- body には `nothing` でない値だけを送る
- unknown option の受け口は v1 では作らない

## Error Handling

### Exception Types

- `LMStudioHTTPError`
- `LMStudioAPIError`
- `LMStudioProtocolError`
- `LMStudioTimeoutError`

### Rules

- 非 2xx HTTP は `LMStudioHTTPError`
- JSON の `error` payload は `LMStudioAPIError`
- SSE frame 不正や decode 不能 event は `LMStudioProtocolError`
- 未知 event type は例外にせず `UnknownEvent`

streaming 中に `error` event が流れた場合:

- `StreamErrorEvent` を iterator に流す
- 後続の `chat.end` があれば最後まで読む

## Testing Strategy

### Unit Tests

- request body construction
- response JSON decode
- SSE frame parser
- event type mapping
- `ChatSession` update logic
- download polling stop condition

### Mocked Integration Tests

`HTTP.jl` のローカルテストサーバーまたは transport の差し替えで以下を検証する。

- download happy path
- download failure path
- load happy path
- chat happy path
- stateful chat with `previous_response_id`
- stream chat with mixed event sequence
- stream with `error` then `chat.end`

### Live Integration Tests

LM Studio が手元で起動しているときのみ実行する optional test とする。

前提:

- LM Studio server が `http://127.0.0.1:1234` で動作
- 必要なら API token を環境変数で指定

使用モデル:

- `google/gemma-4-e2b`

実施内容:

1. `download_model`
2. `wait_for_download`
3. `load_model`
4. `chat`
5. `stream_chat`
6. `ChatSession` を用いた 2 turn stateful chat

## Compatibility And Assumptions

- 対象 API は LM Studio native REST API v1
- LM Studio 0.4.0 以降を前提とする
- Julia 側は REST-native thin client であり、`@lmstudio/sdk` の完全移植は狙わない
- examples と live test の基準モデルは `google/gemma-4-e2b`

## Risks

- SSE 実装差異により `HTTP.jl` 上で逐次読み出しの調整が必要になる可能性がある
- LM Studio API の event type 追加時に strict decode だと壊れやすい
- live integration test はローカル環境依存なので CI で常時実行しにくい

対策:

- unknown event を許容する
- parser を unit test で固定する
- live test は opt-in にする

## Recommended Implementation Order

1. type と error の定義
2. transport 層
3. non-streaming download/load/chat
4. SSE parser
5. `stream_chat`
6. `ChatSession`
7. mocked tests
8. optional live tests

## References

- LM Studio REST API overview: `https://lmstudio.ai/docs/developer/rest`
- Download endpoint: `https://lmstudio.ai/docs/developer/rest/download`
- Download status endpoint: `https://lmstudio.ai/docs/developer/rest/download-status`
- Load endpoint: `https://lmstudio.ai/docs/developer/rest/load`
- Chat endpoint: `https://lmstudio.ai/docs/developer/rest/chat`
- Stateful chats: `https://lmstudio.ai/docs/developer/rest/stateful-chats`
- Streaming events: `https://lmstudio.ai/docs/developer/rest/streaming-events`
