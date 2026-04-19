using Test
using LMStudioClient

if get(ENV, "LMSTUDIO_RUN_LIVE_TESTS", "0") != "1"
    @info "Skipping live LM Studio API test; set LMSTUDIO_RUN_LIVE_TESTS=1 to run it"
else
    @testset "live LM Studio API" begin
        client = Client(
            base_url=get(ENV, "LMSTUDIO_BASE_URL", "http://127.0.0.1:1234"),
            api_token=get(ENV, "LMSTUDIO_API_TOKEN", nothing),
        )

        model = get(ENV, "LMSTUDIO_TEST_MODEL", "google/gemma-4-e2b")

        job = download_model(client, model)
        if isnothing(job.job_id)
            @test job.status == :already_downloaded
        else
            status_job = download_status(client, something(job.job_id))
            @test status_job.job_id == job.job_id
            @test status_job.status in (:completed, :downloading)
            @test !isnothing(status_job.total_size_bytes)
        end
        final_job = wait_for_download(client, job; poll_interval=1.0, timeout=1800)
        @test final_job.status in (:already_downloaded, :completed)

        loaded = load_model(client, model; context_length=8192)
        @test loaded.status == :loaded
        @test loaded.instance_id != ""

        response = chat(client; model=model, input="Reply with the single word BLUE.")
        response_text = join([item.content for item in response.output if item isa MessageOutput], " ")
        @test response.model_instance_id != ""
        @test !isempty(response.output)
        @test occursin(r"blue"i, response_text)

        stream_events = collect(stream_chat(client; model=model, input="Reply with the single word GREEN."))
        stream_text = join([event.content for event in stream_events if event isa MessageDeltaEvent], "")
        @test !isempty(stream_events)
        @test any(event -> event isa MessageDeltaEvent, stream_events)
        @test any(event -> event isa ChatEndEvent, stream_events)
        @test occursin(r"green"i, stream_text)

        session = ChatSession(model)
        first_reply = chat(client, session, "Remember the word orange.")
        second_reply = chat(client, session, "What word did I ask you to remember?")
        second_reply_text = join([item.content for item in second_reply.output if item isa MessageOutput], " ")
        @test !isnothing(first_reply.response_id)
        @test !isnothing(second_reply.response_id)
        @test occursin(r"orange"i, second_reply_text)
        @test session.previous_response_id == second_reply.response_id
    end
end
