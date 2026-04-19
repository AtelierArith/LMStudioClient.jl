using Dates

@testset "public surface" begin
    client = Client()
    @test client.base_url == "http://127.0.0.1:1234"
    @test isnothing(client.api_token)
    @test client.timeout == 30
    @test client.timeout isa Int

    normalized_client = Client(base_url="http://127.0.0.1:1234/")
    @test normalized_client.base_url == "http://127.0.0.1:1234"

    fractional_timeout_client = Client(timeout=1.2)
    @test fractional_timeout_client.timeout == 2
    @test fractional_timeout_client.timeout isa Int

    session = ChatSession("google/gemma-4-e2b")
    @test session.model == "google/gemma-4-e2b"
    @test isnothing(session.previous_response_id)
    @test isnothing(session.system_prompt)

    job = DownloadJob(nothing, :already_downloaded, nothing, nothing, nothing, nothing, nothing, nothing)
    @test job.status == :already_downloaded
    @test fieldtype(DownloadJob, 5) == Union{Nothing,DateTime}
    @test fieldtype(DownloadJob, 6) == Union{Nothing,DateTime}
    @test fieldtype(DownloadJob, 7) == Union{Nothing,Float64}
    @test fieldtype(DownloadJob, 8) == Union{Nothing,DateTime}

    loaded = LoadModelResult(:loaded, "model_inst_1", :ready, 12.5, Dict("foo" => "bar"))
    @test loaded.type == :loaded
    @test loaded.instance_id == "model_inst_1"
    @test loaded.status == :ready
    @test loaded.load_time_seconds == 12.5
    @test loaded.load_config == Dict("foo" => "bar")

    stats = ChatStats(11, 22, 3, 4.5, 0.7, nothing)
    @test stats.input_tokens == 11
    @test stats.total_output_tokens == 22
    @test stats.reasoning_output_tokens == 3
    @test stats.tokens_per_second == 4.5
    @test stats.time_to_first_token_seconds == 0.7
    @test isnothing(stats.model_load_time_seconds)

    response = ChatResponse("model_inst_1", LMStudioClient.ChatOutputItem[], stats, "resp_123")
    @test response.model_instance_id == "model_inst_1"
    @test isempty(response.output)
    @test response.stats === stats
    @test response.response_id == "resp_123"

    http_error = LMStudioClient.LMStudioHTTPError(500, "boom")
    @test http_error.status == 500
    @test http_error.body == "boom"

    api_error = LMStudioClient.LMStudioAPIError("bad_request", "invalid input", "400", "input")
    @test api_error.error_type == "bad_request"
    @test api_error.message == "invalid input"
    @test api_error.code == "400"
    @test api_error.param == "input"

    protocol_error = LMStudioClient.LMStudioProtocolError("unexpected payload")
    @test protocol_error.message == "unexpected payload"

    timeout_error = LMStudioClient.LMStudioTimeoutError("timed out")
    @test timeout_error.message == "timed out"

    @test isabstracttype(LMStudioClient.ChatOutputItem)
    @test isabstracttype(LMStudioEvent)
    @test isconcretetype(LoadModelResult)
    @test isconcretetype(ChatStats)
    @test isconcretetype(ChatResponse)
end
