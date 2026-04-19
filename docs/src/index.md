# LMStudioClient.jl

`LMStudioClient.jl` is a thin Julia client for LM Studio's native REST API.

It is aimed at local-model workflows such as:

- downloading models
- loading models
- one-shot chat
- stateful chat with `ChatSession`
- streaming chat with `stream_chat`

## Prerequisites

- Julia 1.12+
- A running LM Studio server
- By default, `Client()` connects to `http://127.0.0.1:1234`

## Docs

- [Getting Started](getting-started.md)
- [Streaming](streaming.md)
