using Dates

const _DOWNLOAD_STATUS_MAP = Dict(
    "already_downloaded" => :already_downloaded,
    "completed" => :completed,
    "downloading" => :downloading,
    "failed" => :failed,
    "paused" => :paused,
)

const _LOAD_TYPE_MAP = Dict(
    "llm" => :llm,
    "embedding" => :embedding,
)

const _LOAD_STATUS_MAP = Dict(
    "loaded" => :loaded,
)

function _parse_datetime(value)
    if value === nothing
        return nothing
    end
    if value isa DateTime
        return value
    end
    if value isa AbstractString
        return DateTime(replace(value, "Z" => ""))
    end
    return value
end

function _parse_download_status(value::AbstractString)
    status = get(_DOWNLOAD_STATUS_MAP, lowercase(value), nothing)
    if status === nothing
        throw(LMStudioProtocolError("unexpected download status: $(value)"))
    end
    return status
end

function _parse_load_type(value::AbstractString)
    load_type = get(_LOAD_TYPE_MAP, lowercase(value), nothing)
    if load_type === nothing
        throw(LMStudioProtocolError("unexpected load type: $(value)"))
    end
    return load_type
end

function _parse_load_status(value::AbstractString)
    status = get(_LOAD_STATUS_MAP, lowercase(value), nothing)
    if status === nothing
        throw(LMStudioProtocolError("unexpected load status: $(value)"))
    end
    return status
end

function _parse_download_job(data::AbstractDict{String,<:Any})
    DownloadJob(
        get(data, "job_id", nothing),
        _parse_download_status(String(data["status"])),
        get(data, "total_size_bytes", nothing),
        get(data, "downloaded_bytes", nothing),
        _parse_datetime(get(data, "started_at", nothing)),
        _parse_datetime(get(data, "completed_at", nothing)),
        get(data, "bytes_per_second", nothing),
        _parse_datetime(get(data, "estimated_completion", nothing)),
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
    data = _transport(; method="GET", path="/api/v1/models/download/status/$(job_id)", body=nothing, stream=false, client=client)
    return _parse_download_job(data)
end

function wait_for_download(client::Client, job_or_job_id; poll_interval::Real=1.0, timeout::Union{Nothing,Real}=nothing, _transport=_request_adapter)
    started = time()
    deadline = isnothing(timeout) ? nothing : started + timeout

    job = job_or_job_id isa DownloadJob ? job_or_job_id : download_status(client, String(job_or_job_id); _transport=_transport)
    if !isnothing(deadline) && time() >= deadline
        throw(LMStudioTimeoutError("Timed out waiting for download to complete"))
    end

    if job.status == :already_downloaded || job.status == :completed
        return job
    end

    while true
        now = time()
        if !isnothing(deadline) && now >= deadline
            throw(LMStudioTimeoutError("Timed out waiting for download to complete"))
        end

        sleep_for = isnothing(deadline) ? poll_interval : min(poll_interval, deadline - now)
        sleep(sleep_for)
        job = download_status(client, something(job.job_id, String(job_or_job_id)); _transport=_transport)
        if !isnothing(deadline) && time() >= deadline
            throw(LMStudioTimeoutError("Timed out waiting for download to complete"))
        end
        if job.status == :completed || job.status == :already_downloaded
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
    return LoadModelResult(
        _parse_load_type(String(data["type"])),
        String(data["instance_id"]),
        _parse_load_status(String(data["status"])),
        Float64(data["load_time_seconds"]),
        get(data, "load_config", Dict{String,Any}()),
    )
end

function _parse_output_item(item::AbstractDict{String,<:Any})
    kind = get(item, "type", "unknown")
    if kind == "message"
        return MessageOutput(String(item["content"]))
    elseif kind == "reasoning"
        return ReasoningOutput(String(item["content"]))
    elseif kind == "tool_call"
        return ToolCallOutput(
            String(item["tool"]),
            get(item, "arguments", Dict{String,Any}()),
            String(get(item, "output", "")),
            get(item, "provider_info", Dict{String,Any}()),
        )
    else
        return UnknownOutputItem(Dict{String,Any}(item))
    end
end

function _parse_chat_response(data::AbstractDict{String,<:Any})
    stats_data = get(data, "stats", Dict{String,Any}())
    stats = ChatStats(
        Int(get(stats_data, "input_tokens", 0)),
        Int(get(stats_data, "total_output_tokens", 0)),
        Int(get(stats_data, "reasoning_output_tokens", 0)),
        Float64(get(stats_data, "tokens_per_second", 0.0)),
        Float64(get(stats_data, "time_to_first_token_seconds", 0.0)),
        haskey(stats_data, "model_load_time_seconds") ? Float64(stats_data["model_load_time_seconds"]) : nothing,
    )
    output = ChatOutputItem[_parse_output_item(item) for item in get(data, "output", Any[])]
    return ChatResponse(String(data["model_instance_id"]), output, stats, get(data, "response_id", nothing))
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
    for key in (:model, :previous_response_id, :system_prompt)
        if haskey(kwargs, key)
            throw(ArgumentError("session-owned keyword override not allowed: $(key)"))
        end
    end

    response = chat(
        client;
        model=session.model,
        input=input,
        previous_response_id=session.previous_response_id,
        system_prompt=session.system_prompt,
        kwargs...,
    )
    session.previous_response_id = response.response_id
    return response
end

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
    for key in (:model, :previous_response_id, :system_prompt)
        if haskey(kwargs, key)
            throw(ArgumentError("session-owned keyword override not allowed: $(key)"))
        end
    end

    upstream = stream_chat(
        client;
        model=session.model,
        input=input,
        previous_response_id=session.previous_response_id,
        system_prompt=session.system_prompt,
        kwargs...,
    )
    buffered_events = LMStudioEvent[]
    done = Ref(false)
    failure = Ref{Any}(nothing)
    signal = Channel{Nothing}(1)

    @async begin
        try
            for event in upstream
                if event isa ChatEndEvent
                    session.previous_response_id = event.result.response_id
                end
                push!(buffered_events, event)
                !isready(signal) && put!(signal, nothing)
            end
        catch err
            failure[] = err
        finally
            done[] = true
            !isready(signal) && put!(signal, nothing)
        end
    end

    return Channel{LMStudioEvent}(32) do channel
        index = 1
        while true
            while index <= length(buffered_events)
                put!(channel, buffered_events[index])
                index += 1
            end

            done[] && break
            take!(signal)
        end

        if !isnothing(failure[])
            throw(failure[])
        end
    end
end

function _request_adapter(; method, path, body=nothing, stream, client)
    @assert stream == false
    return _request_json(client, method, path; body=body)
end

function _stream_adapter(; method, path, body=nothing, stream, client)
    @assert stream == true
    return _stream_request_lines(client, method, path; body=body)
end
