# Getting Started

## Connect To LM Studio

```julia
using LMStudioClient

client = Client()
```

By default, `Client()` targets `http://127.0.0.1:1234`. Make sure the LM Studio server is running before you call request functions such as `download_model`, `load_model`, `chat`, or `stream_chat`.

If your LM Studio server is exposed on another host or needs authentication, construct the client with `Client(base_url=..., api_token=...)`.

## Download And Load A Model

Replace `google/gemma-4-e2b` with any model that is available in your local LM Studio install.

```julia
job = download_model(client, "google/gemma-4-e2b")
wait_for_download(client, job)

loaded = load_model(client, "google/gemma-4-e2b"; context_length=8192)
println(loaded.instance_id)
```

## Run A One-Shot Chat

`chat` returns a `ChatResponse`. The response can contain message output, reasoning output, and tool call output, so it is often clearer to print just the assistant message content.

```julia
response = chat(
    client;
    model = "google/gemma-4-e2b",
    input = "Reply with the single word BLUE.",
)

message = first(item.content for item in response.output if item isa MessageOutput)
println(message)
```

## Continue A Conversation With `ChatSession`

`ChatSession` keeps track of the previous response id for you, which makes it easy to continue a conversation without passing it manually.

```julia
session = ChatSession("google/gemma-4-e2b")

first_reply = chat(client, session, "My name is Mina.")
second_reply = chat(client, session, "What is my name?")

println(first(item.content for item in first_reply.output if item isa MessageOutput))
println(first(item.content for item in second_reply.output if item isa MessageOutput))
```
