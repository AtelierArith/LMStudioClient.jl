using Test
using LMStudioClient
using HTTP

function wait_until(predicate::Function; timeout::Real=1.0)
    deadline = time() + timeout
    while time() < deadline
        predicate() && return true
        sleep(0.01)
    end
    return predicate()
end

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

@testset "SSE parser flushes final event at EOF" begin
    raw = [
        "event: message.delta",
        "data: {\"type\":\"message.delta\",\"content\":\"Goodbye\"}",
    ]

    events = collect(LMStudioClient._decode_sse_lines(raw))

    @test length(events) == 1
    @test events[1] isa MessageDeltaEvent
    @test events[1].content == "Goodbye"
end

@testset "stream_chat delivers incrementally from a producer channel" begin
    release = Channel{Nothing}(1)
    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(8) do channel
            put!(channel, "event: chat.start")
            put!(channel, "data: {\"type\":\"chat.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}")
            put!(channel, "")
            take!(release)
            put!(channel, "event: chat.end")
            put!(channel, "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[],\"stats\":{\"input_tokens\":1,\"total_output_tokens\":0,\"reasoning_output_tokens\":0,\"tokens_per_second\":0.0,\"time_to_first_token_seconds\":0.1},\"response_id\":\"resp_live\"}}")
            put!(channel, "")
        end
    end

    client = Client()
    task = @async stream_chat(client; model="google/gemma-4-e2b", input="Say hi.", _stream_transport=fake_stream_transport)

    returned_early = wait_until(() -> istaskdone(task); timeout=0.2)
    @test returned_early

    events = fetch(task)
    first_event = take!(events)
    @test first_event isa ChatStartEvent

    put!(release, nothing)
    rest = collect(events)
    @test length(rest) == 1
    @test rest[1] isa ChatEndEvent
    @test rest[1].result.response_id == "resp_live"
end

@testset "stream_chat decodes Task 5 events and updates session state" begin
    raw_lines = [
        "event: chat.start",
        "data: {\"type\":\"chat.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}",
        "",
        "event: model_load.start",
        "data: {\"type\":\"model_load.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}",
        "",
        "event: model_load.progress",
        "data: {\"type\":\"model_load.progress\",\"model_instance_id\":\"google/gemma-4-e2b\",\"progress\":0.5}",
        "",
        "event: model_load.end",
        "data: {\"type\":\"model_load.end\",\"model_instance_id\":\"google/gemma-4-e2b\",\"load_time_seconds\":1.25}",
        "",
        "event: prompt_processing.start",
        "data: {\"type\":\"prompt_processing.start\"}",
        "",
        "event: prompt_processing.progress",
        "data: {\"type\":\"prompt_processing.progress\",\"progress\":0.75}",
        "",
        "event: prompt_processing.end",
        "data: {\"type\":\"prompt_processing.end\"}",
        "",
        "event: reasoning.start",
        "data: {\"type\":\"reasoning.start\"}",
        "",
        "event: reasoning.delta",
        "data: {\"type\":\"reasoning.delta\",\"content\":\"Considering prior turn.\"}",
        "",
        "event: reasoning.end",
        "data: {\"type\":\"reasoning.end\"}",
        "",
        "event: tool_call.start",
        "data: {\"type\":\"tool_call.start\",\"tool\":\"lookup_memory\",\"provider_info\":{\"provider\":\"lmstudio\"}}",
        "",
        "event: tool_call.arguments",
        "data: {\"type\":\"tool_call.arguments\",\"tool\":\"lookup_memory\",\"arguments\":{\"key\":\"favorite_color\"},\"provider_info\":{\"provider\":\"lmstudio\"}}",
        "",
        "event: tool_call.success",
        "data: {\"type\":\"tool_call.success\",\"tool\":\"lookup_memory\",\"arguments\":{\"key\":\"favorite_color\"},\"output\":\"blue\",\"provider_info\":{\"provider\":\"lmstudio\"}}",
        "",
        "event: tool_call.failure",
        "data: {\"type\":\"tool_call.failure\",\"reason\":\"tool unavailable\",\"metadata\":{\"tool\":\"lookup_memory\"}}",
        "",
        "event: message.start",
        "data: {\"type\":\"message.start\"}",
        "",
        "event: message.delta",
        "data: {\"type\":\"message.delta\",\"content\":\"Blue\"}",
        "",
        "event: message.end",
        "data: {\"type\":\"message.end\"}",
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

    @test length(events) == 18
    @test events[1] isa ChatStartEvent
    @test events[2] isa ModelLoadStartEvent
    @test events[3] isa ModelLoadProgressEvent
    @test events[3].progress == 0.5
    @test events[4] isa ModelLoadEndEvent
    @test events[4].load_time_seconds == 1.25
    @test events[5] isa PromptProcessingStartEvent
    @test events[6] isa PromptProcessingProgressEvent
    @test events[6].progress == 0.75
    @test events[7] isa PromptProcessingEndEvent
    @test events[8] isa ReasoningStartEvent
    @test events[9] isa ReasoningDeltaEvent
    @test events[9].content == "Considering prior turn."
    @test events[10] isa ReasoningEndEvent
    @test events[11] isa ToolCallStartEvent
    @test events[11].tool == "lookup_memory"
    @test events[11].provider_info["provider"] == "lmstudio"
    @test events[12] isa ToolCallArgumentsEvent
    @test events[12].arguments["key"] == "favorite_color"
    @test events[13] isa ToolCallSuccessEvent
    @test events[13].output == "blue"
    @test events[14] isa ToolCallFailureEvent
    @test events[14].reason == "tool unavailable"
    @test events[14].metadata["tool"] == "lookup_memory"
    @test events[15] isa MessageStartEvent
    @test events[16] isa MessageDeltaEvent
    @test events[16].content == "Blue"
    @test events[end - 1] isa MessageEndEvent
    @test events[end] isa ChatEndEvent
    @test events[end].result.response_id == "resp_2"
    @test session.previous_response_id == "resp_2"
end

@testset "stream_chat session updates even when caller only partially consumes a long stream" begin
    release = Channel{Nothing}(1)

    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(128) do channel
            put!(channel, "event: chat.start")
            put!(channel, "data: {\"type\":\"chat.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}")
            put!(channel, "")

            take!(release)
            for idx in 1:40
                put!(channel, "event: message.delta")
                put!(channel, "data: {\"type\":\"message.delta\",\"content\":\"chunk $(idx)\"}")
                put!(channel, "")
            end

            put!(channel, "event: chat.end")
            put!(channel, "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[{\"type\":\"message\",\"content\":\"Blue\"}],\"stats\":{\"input_tokens\":5,\"total_output_tokens\":40,\"reasoning_output_tokens\":0,\"tokens_per_second\":15.0,\"time_to_first_token_seconds\":0.2},\"response_id\":\"resp_long\"}}")
            put!(channel, "")
        end
    end

    client = Client()
    session = ChatSession("google/gemma-4-e2b")
    task = @async stream_chat(client, session, "Keep going."; _stream_transport=fake_stream_transport)

    returned_early = wait_until(() -> istaskdone(task); timeout=0.2)
    @test returned_early

    put!(release, nothing)
    events = fetch(task)

    first_event = take!(events)
    @test first_event isa ChatStartEvent
    @test isnothing(session.previous_response_id)

    @test wait_until(() -> session.previous_response_id == "resp_long")

    rest = collect(events)
    @test any(event -> event isa ChatEndEvent, rest)
end

@testset "stream_chat session overload applies backpressure instead of buffering unbounded events" begin
    total_chunks = 2000
    produced = Ref(0)

    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(0) do channel
            put!(channel, "event: chat.start")
            put!(channel, "data: {\"type\":\"chat.start\",\"model_instance_id\":\"google/gemma-4-e2b\"}")
            put!(channel, "")

            for idx in 1:total_chunks
                produced[] += 1
                put!(channel, "event: message.delta")
                put!(channel, "data: {\"type\":\"message.delta\",\"content\":\"chunk $(idx)\"}")
                put!(channel, "")
            end

            put!(channel, "event: chat.end")
            put!(channel, "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[{\"type\":\"message\",\"content\":\"Blue\"}],\"stats\":{\"input_tokens\":5,\"total_output_tokens\":$(total_chunks),\"reasoning_output_tokens\":0,\"tokens_per_second\":15.0,\"time_to_first_token_seconds\":0.2},\"response_id\":\"resp_backpressure\"}}")
            put!(channel, "")
        end
    end

    client = Client()
    session = ChatSession("google/gemma-4-e2b")
    events = stream_chat(client, session, "Keep going."; _stream_transport=fake_stream_transport)

    first_event = take!(events)
    @test first_event isa ChatStartEvent

    reached_end_without_consumer = wait_until(() -> session.previous_response_id == "resp_backpressure"; timeout=0.5)
    @test reached_end_without_consumer == false
    @test produced[] < total_chunks

    close(events)
end

@testset "stream_chat surfaces producer API errors directly" begin
    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(1) do channel
            throw(LMStudioClient.LMStudioAPIError("invalid_request", "Invalid model identifier", "model_not_found", "model"))
        end
    end

    client = Client()
    err = try
        collect(stream_chat(client; model="definitely/not-a-real-model", input="Say hello.", _stream_transport=fake_stream_transport))
        nothing
    catch err
        err
    end
    @test err isa LMStudioClient.LMStudioAPIError
    @test err.error_type == "invalid_request"
    @test err.code == "model_not_found"
end

@testset "stream_chat unwraps HTTP request errors to LMStudio API errors" begin
    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(1) do channel
            request = HTTP.Request("POST", "http://127.0.0.1:1234/api/v1/chat")
            api_error = LMStudioClient.LMStudioAPIError("invalid_request", "Invalid model identifier", "model_not_found", "model")
            throw(HTTP.Exceptions.RequestError(request, api_error))
        end
    end

    client = Client()
    err = try
        collect(stream_chat(client; model="definitely/not-a-real-model", input="Say hello.", _stream_transport=fake_stream_transport))
        nothing
    catch err
        err
    end
    @test err isa LMStudioClient.LMStudioAPIError
    @test err.error_type == "invalid_request"
    @test err.code == "model_not_found"
end

@testset "stream_chat session overload surfaces producer API errors directly" begin
    fake_stream_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test stream == true
        @test body["stream"] == true
        return Channel{String}(1) do channel
            throw(LMStudioClient.LMStudioAPIError("invalid_request", "Invalid model identifier", "model_not_found", "model"))
        end
    end

    client = Client()
    session = ChatSession("definitely/not-a-real-model")
    err = try
        collect(stream_chat(client, session, "Say hello."; _stream_transport=fake_stream_transport))
        nothing
    catch err
        err
    end
    @test err isa LMStudioClient.LMStudioAPIError
    @test err.error_type == "invalid_request"
    @test err.code == "model_not_found"
    @test isnothing(session.previous_response_id)
end
