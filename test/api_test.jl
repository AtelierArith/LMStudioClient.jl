using Dates
using Test
using HTTP
using LMStudioClient

function with_test_server(f::Function, handler::Function; stream::Bool=false)
    server = HTTP.serve!(handler; stream=stream, listenany=true, verbose=false)
    try
        return f(HTTP.port(server))
    finally
        close(server)
    end
end

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

    captured = Ref{Any}(nothing)
    fake_status_transport = function (; method, path, body=nothing, stream, client)
        captured[] = (; method, path, body, stream)
        return Dict(
            "job_id" => "job_456",
            "status" => "completed",
            "downloaded_bytes" => 100,
            "total_size_bytes" => 100,
            "completed_at" => "2026-04-18T00:00:01Z",
        )
    end

    status_job = LMStudioClient.download_status(client, "job_456"; _transport=fake_status_transport)

    @test captured[].method == "GET"
    @test captured[].path == "/api/v1/models/download/status/job_456"
    @test isnothing(captured[].body)
    @test captured[].stream == false
    @test status_job.status == :completed
    @test status_job.completed_at == DateTime("2026-04-18T00:00:01")

    paused_transport = function (; method, path, body=nothing, stream, client)
        return Dict(
            "job_id" => "job_paused",
            "status" => "paused",
            "downloaded_bytes" => 50,
            "total_size_bytes" => 100,
        )
    end

    paused_job = LMStudioClient.download_status(client, "job_paused"; _transport=paused_transport)
    @test paused_job.status == :paused

    bad_transport = function (; method, path, body=nothing, stream, client)
        return Dict("job_id" => "job_bad", "status" => "mystery_state")
    end

    @test_throws LMStudioClient.LMStudioProtocolError LMStudioClient.download_status(client, "job_bad"; _transport=bad_transport)
end

@testset "transport error translation" begin
    with_test_server(req -> HTTP.Response(418, "teapot")) do port
        client = Client(base_url="http://127.0.0.1:$(port)")

        err = try
            LMStudioClient._request_json(client, "GET", "/boom"; body=nothing)
            nothing
        catch caught
            caught
        end

        @test err isa LMStudioClient.LMStudioHTTPError
        @test err.status == 418
        @test err.body == "teapot"
    end

    with_test_server(req -> HTTP.Response(
        400,
        ["Content-Type" => "application/json"],
        "{\"error\":{\"type\":\"bad_request\",\"message\":\"invalid input\",\"code\":\"400\",\"param\":\"input\"}}",
    )) do port
        client = Client(base_url="http://127.0.0.1:$(port)")

        err = try
            LMStudioClient._request_json(client, "GET", "/boom"; body=nothing)
            nothing
        catch caught
            caught
        end

        @test err isa LMStudioClient.LMStudioAPIError
        @test err.error_type == "bad_request"
        @test err.message == "invalid input"
        @test err.code == "400"
        @test err.param == "input"
    end
end

@testset "stream transport sends request body and yields SSE lines" begin
    request_body = Ref("")

    handler = function (http::HTTP.Stream)
        request_body[] = String(read(http))
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/event-stream")
        HTTP.setheader(http, "Cache-Control" => "no-cache")
        HTTP.startwrite(http)
        write(http, "event: message.delta\n")
        write(http, "data: {\"type\":\"message.delta\",\"content\":\"Hello\"}\n\n")
        write(http, "event: chat.end\n")
        write(http, "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[],\"stats\":{\"input_tokens\":1,\"total_output_tokens\":1,\"reasoning_output_tokens\":0,\"tokens_per_second\":12.0,\"time_to_first_token_seconds\":0.1},\"response_id\":\"resp_stream\"}}\n\n")
    end

    with_test_server(handler; stream=true) do port
        client = Client(base_url="http://127.0.0.1:$(port)")
        lines = collect(LMStudioClient._stream_request_lines(
            client,
            "POST",
            "/api/v1/chat";
            body=Dict(
                "model" => "google/gemma-4-e2b",
                "input" => "Say hello",
                "stream" => true,
            ),
        ))

        @test occursin("\"model\":\"google/gemma-4-e2b\"", request_body[])
        @test occursin("\"input\":\"Say hello\"", request_body[])
        @test lines[1] == "event: message.delta"
        @test lines[2] == "data: {\"type\":\"message.delta\",\"content\":\"Hello\"}"
        @test lines[end - 1] == "data: {\"type\":\"chat.end\",\"result\":{\"model_instance_id\":\"google/gemma-4-e2b\",\"output\":[],\"stats\":{\"input_tokens\":1,\"total_output_tokens\":1,\"reasoning_output_tokens\":0,\"tokens_per_second\":12.0,\"time_to_first_token_seconds\":0.1},\"response_id\":\"resp_stream\"}}"
    end
end

@testset "stream transport preserves final unterminated SSE line at EOF" begin
    handler = function (http::HTTP.Stream)
        _ = String(read(http))
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/event-stream")
        HTTP.setheader(http, "Cache-Control" => "no-cache")
        HTTP.startwrite(http)
        write(http, "event: message.delta\n")
        write(http, "data: {\"type\":\"message.delta\",\"content\":\"Tail\"}")
    end

    with_test_server(handler; stream=true) do port
        client = Client(base_url="http://127.0.0.1:$(port)")
        events = collect(LMStudioClient._decode_sse_lines(LMStudioClient._stream_request_lines(
            client,
            "POST",
            "/api/v1/chat";
            body=Dict(
                "model" => "google/gemma-4-e2b",
                "input" => "Say hello",
                "stream" => true,
            ),
        )))

        @test length(events) == 1
        @test events[1] isa MessageDeltaEvent
        @test events[1].content == "Tail"
    end
end

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
        Dict(
            "model_instance_id" => "google/gemma-4-e2b",
            "output" => [
                Dict("type" => "message", "content" => "Blue."),
                Dict("type" => "reasoning", "content" => "Recalling prior message."),
                Dict(
                    "type" => "tool_call",
                    "tool" => "lookup_memory",
                    "arguments" => Dict("key" => "favorite_color"),
                    "output" => "blue",
                    "provider_info" => Dict("provider" => "lmstudio"),
                ),
                Dict("type" => "custom_kind", "payload" => "mystery"),
            ],
            "stats" => Dict(
                "input_tokens" => 5,
                "total_output_tokens" => 8,
                "reasoning_output_tokens" => 2,
                "tokens_per_second" => 16.0,
                "time_to_first_token_seconds" => 0.2,
            ),
            "response_id" => "resp_2",
        ),
    ]

    fake_transport = function (; method, path, body, stream, client)
        push!(calls, (; method, path, body, stream))
        return popfirst!(responses)
    end

    client = Client()
    job = LMStudioClient.wait_for_download(client, "job_123"; poll_interval=0.0, _transport=fake_transport)
    @test job.status == :completed

    loaded = LMStudioClient.load_model(client, "google/gemma-4-e2b"; context_length=8192, _transport=fake_transport)
    @test loaded isa LoadModelResult
    @test loaded.instance_id == "google/gemma-4-e2b"
    @test loaded.load_config["context_length"] == 8192
    @test loaded.type == :llm

    session = ChatSession("google/gemma-4-e2b")
    reply = LMStudioClient.chat(client, session, "What color did I mention?"; _transport=fake_transport)
    @test reply.response_id == "resp_1"
    @test session.previous_response_id == "resp_1"
    @test calls[end].body["model"] == "google/gemma-4-e2b"
    @test calls[end].body["input"] == "What color did I mention?"

    direct_reply = chat(client; model="google/gemma-4-e2b", input="Say hello.", _transport=fake_transport)
    @test direct_reply.response_id == "resp_2"
    @test length(direct_reply.output) == 4
    @test direct_reply.output[1] isa MessageOutput
    @test direct_reply.output[1].content == "Blue."
    @test direct_reply.output[2] isa ReasoningOutput
    @test direct_reply.output[2].content == "Recalling prior message."
    @test direct_reply.output[3] isa ToolCallOutput
    @test direct_reply.output[3].tool == "lookup_memory"
    @test direct_reply.output[3].arguments["key"] == "favorite_color"
    @test direct_reply.output[3].output == "blue"
    @test direct_reply.output[3].provider_info["provider"] == "lmstudio"
    @test direct_reply.output[4] isa UnknownOutputItem
    @test direct_reply.output[4].raw["type"] == "custom_kind"
    @test calls[end].body["model"] == "google/gemma-4-e2b"
    @test calls[end].body["input"] == "Say hello."

    embedding_load_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/models/load"
        return Dict(
            "type" => "embedding",
            "instance_id" => "nomic-embed-text-v1.5",
            "status" => "loaded",
            "load_time_seconds" => 1.0,
            "load_config" => Dict("context_length" => 2048),
        )
    end

    embedding_loaded = LMStudioClient.load_model(
        client,
        "nomic-ai/nomic-embed-text-v1.5";
        context_length=2048,
        _transport=embedding_load_transport,
    )
    @test embedding_loaded isa LoadModelResult
    @test embedding_loaded.type == :embedding
    @test embedding_loaded.status == :loaded
    @test embedding_loaded.instance_id == "nomic-embed-text-v1.5"
    @test embedding_loaded.load_config["context_length"] == 2048
end

@testset "chat response parsing tolerates missing ids and preserves session state" begin
    parsed = LMStudioClient._parse_chat_response(Dict(
        "model_instance_id" => nothing,
        "output" => Any[],
        "stats" => Dict(
            "input_tokens" => 2,
            "total_output_tokens" => 0,
            "reasoning_output_tokens" => 0,
            "tokens_per_second" => 0.0,
            "time_to_first_token_seconds" => 0.1,
        ),
        "response_id" => nothing,
    ))

    @test parsed.model_instance_id == "unknown"
    @test isempty(parsed.output)
    @test isnothing(parsed.response_id)

    fake_transport = function (; method, path, body, stream, client)
        @test method == "POST"
        @test path == "/api/v1/chat"
        @test body["model"] == "google/gemma-4-e2b"
        @test body["previous_response_id"] == "resp_existing"
        return Dict(
            "model_instance_id" => nothing,
            "output" => Any[],
            "stats" => Dict(
                "input_tokens" => 2,
                "total_output_tokens" => 0,
                "reasoning_output_tokens" => 0,
                "tokens_per_second" => 0.0,
                "time_to_first_token_seconds" => 0.1,
            ),
            "response_id" => nothing,
        )
    end

    client = Client()
    session = ChatSession("google/gemma-4-e2b"; previous_response_id="resp_existing")
    reply = LMStudioClient.chat(client, session, "Continue."; _transport=fake_transport)

    @test reply.model_instance_id == "unknown"
    @test isnothing(reply.response_id)
    @test session.previous_response_id == "resp_existing"
end

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
                        Dict(
                            "id" => "google/gemma-4-e2b:2",
                            "config" => Dict(
                                "context_length" => 4096,
                                "eval_batch_size" => 256,
                                "parallel" => 2,
                                "flash_attention" => false,
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
                    "publisher" => nothing,
                    "key" => "text-embedding-nomic-embed-text-v1.5",
                    "display_name" => nothing,
                    "quantization" => Dict("name" => "F16", "bits_per_weight" => 16),
                    "size_bytes" => 84000000,
                    "params_string" => nothing,
                    "loaded_instances" => nothing,
                    "max_context_length" => 2048,
                    "format" => "gguf",
                    "capabilities" => nothing,
                    "variants" => nothing,
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
    @test models[2].publisher == ""
    @test models[2].display_name == "text-embedding-nomic-embed-text-v1.5"
    @test isempty(models[2].capabilities)
    @test isempty(models[2].variants)

    llm_only = LMStudioClient.list_models(client; domain=:llm, _transport=fake_transport)
    @test length(llm_only) == 1
    @test llm_only[1].type == :llm

    loaded = LMStudioClient.list_loaded_models(client; _transport=fake_transport)
    @test captured[].method == "GET"
    @test captured[].path == "/api/v1/models"
    @test isnothing(captured[].body)
    @test length(loaded) == 2
    @test loaded[1] isa LoadedModelInfo
    @test loaded[1].instance_id == "google/gemma-4-e2b:1"
    @test loaded[1].model_key == "google/gemma-4-e2b"
    @test loaded[1].context_length == 8192
    @test loaded[1].parallel == 4
    @test loaded[2].instance_id == "google/gemma-4-e2b:2"
    @test loaded[2].context_length == 4096
    @test loaded[2].eval_batch_size == 256
    @test loaded[2].parallel == 2
    @test loaded[2].flash_attention == false

    embedding_only = LMStudioClient.list_loaded_models(client; domain=:embedding, _transport=fake_transport)
    @test isempty(embedding_only)
end

@testset "Task 3 quality fixes" begin
    client = Client()

    timeout_transport = function (; method, path, body=nothing, stream, client)
        return Dict("job_id" => "job_timeout", "status" => "downloading")
    end

    caught = nothing
    elapsed = @elapsed begin
        try
            LMStudioClient.wait_for_download(
                client,
                "job_timeout";
                poll_interval=1.0,
                timeout=0.05,
                _transport=timeout_transport,
            )
        catch e
            caught = e
        end
    end
    @test elapsed < 0.5
    @test caught isa LMStudioClient.LMStudioTimeoutError

    slow_initial_transport = function (; method, path, body=nothing, stream, client)
        result = Dict("job_id" => "job_slow", "status" => "completed", "downloaded_bytes" => 100, "total_size_bytes" => 100)
        sleep(0.1)
        return result
    end

    caught = nothing
    try
        LMStudioClient.wait_for_download(
            client,
            "job_slow";
            poll_interval=0.0,
            timeout=0.05,
            _transport=slow_initial_transport,
        )
    catch e
        caught = e
    end
    @test caught isa LMStudioClient.LMStudioTimeoutError

    poll_count = Ref(0)
    slow_followup_transport = function (; method, path, body=nothing, stream, client)
        poll_count[] += 1
        if poll_count[] == 1
            return Dict("job_id" => "job_followup", "status" => "downloading")
        end
        sleep(0.1)
        return Dict("job_id" => "job_followup", "status" => "completed", "downloaded_bytes" => 100, "total_size_bytes" => 100)
    end

    @test_throws LMStudioClient.LMStudioTimeoutError LMStudioClient.wait_for_download(
        client,
        "job_followup";
        poll_interval=0.0,
        timeout=0.05,
        _transport=slow_followup_transport,
    )

    paused_polls = Ref(0)
    paused_transport = function (; method, path, body=nothing, stream, client)
        paused_polls[] += 1
        if paused_polls[] == 1
            return Dict("job_id" => "job_paused", "status" => "paused")
        end
        return Dict(
            "job_id" => "job_paused",
            "status" => "completed",
            "downloaded_bytes" => 100,
            "total_size_bytes" => 100,
        )
    end

    paused_job = LMStudioClient.wait_for_download(
        client,
        "job_paused";
        poll_interval=0.0,
        timeout=0.05,
        _transport=paused_transport,
    )
    @test paused_job.status == :completed
    @test paused_polls[] == 2

    missing_id_job = DownloadJob(nothing, :downloading, nothing, nothing, nothing, nothing, nothing, nothing)
    @test_throws LMStudioClient.LMStudioProtocolError LMStudioClient.wait_for_download(
        client,
        missing_id_job;
        poll_interval=0.0,
        timeout=0.05,
        _transport=paused_transport,
    )

    bad_type_transport = function (; method, path, body, stream, client)
        return Dict(
            "type" => "mystery",
            "instance_id" => "model_inst_1",
            "status" => "loaded",
            "load_time_seconds" => 1.0,
            "load_config" => Dict{String,Any}(),
        )
    end

    @test_throws LMStudioClient.LMStudioProtocolError LMStudioClient.load_model(
        client,
        "google/gemma-4-e2b";
        _transport=bad_type_transport,
    )

    bad_status_transport = function (; method, path, body, stream, client)
        return Dict(
            "type" => "llm",
            "instance_id" => "model_inst_1",
            "status" => "mystery",
            "load_time_seconds" => 1.0,
            "load_config" => Dict{String,Any}(),
        )
    end

    @test_throws LMStudioClient.LMStudioProtocolError LMStudioClient.load_model(
        client,
        "google/gemma-4-e2b";
        _transport=bad_status_transport,
    )

    no_id_transport = function (; method, path, body, stream, client)
        return Dict(
            "model_instance_id" => "google/gemma-4-e2b",
            "output" => [Dict("type" => "message", "content" => "I forgot the id.")],
            "stats" => Dict(
                "input_tokens" => 3,
                "total_output_tokens" => 5,
                "reasoning_output_tokens" => 0,
                "tokens_per_second" => 10.0,
                "time_to_first_token_seconds" => 0.1,
            ),
            "response_id" => nothing,
        )
    end

    session = ChatSession("google/gemma-4-e2b"; previous_response_id="resp_stale")
    reply = LMStudioClient.chat(client, session, "Continue"; _transport=no_id_transport)
    @test isnothing(reply.response_id)
    @test session.previous_response_id == "resp_stale"

    called = Ref(false)
    no_call_transport = function (; method, path, body, stream, client)
        called[] = true
        return Dict{String,Any}()
    end

    protected_session = ChatSession(
        "google/gemma-4-e2b";
        previous_response_id="resp_protected",
        system_prompt="Stay concise.",
    )
    err = nothing
    try
        LMStudioClient.chat(
            client,
            protected_session,
            "Continue";
            model="other-model",
            _transport=no_call_transport,
        )
        @test false
    catch caught
        err = caught
    end
    @test err isa ArgumentError
    @test occursin("session-owned", sprint(showerror, err))
    @test called[] == false
end

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

    structured_unauthorized_transport = function (; method, path, body=nothing, stream, client)
        throw(LMStudioClient.LMStudioAPIError("unauthorized", "unauthorized", "401", nothing))
    end
    structured_unauthorized = LMStudioClient.server_status(client; _transport=structured_unauthorized_transport)
    @test structured_unauthorized.reachable == true
    @test structured_unauthorized.authenticated == false
    @test isnothing(structured_unauthorized.model_count)

    structured_auth_type_transport = function (; method, path, body=nothing, stream, client)
        throw(LMStudioClient.LMStudioAPIError("authentication_error", "api key missing", nothing, nothing))
    end
    structured_auth_type = LMStudioClient.server_status(client; _transport=structured_auth_type_transport)
    @test structured_auth_type.reachable == true
    @test structured_auth_type.authenticated == false
    @test isnothing(structured_auth_type.model_count)

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
