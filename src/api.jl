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

const _SESSION_STREAM_BUFFER_SIZE = 256

_safe_int(x, default::Int=0) = try Int(x) catch _; default end
_safe_float(x, default::Float64=0.0) = try Float64(x) catch _; default end
_safe_bool(x, default=nothing) = try Bool(x) catch _; default end
_haskey_int(config, key) = haskey(config, key) ? _safe_int(config[key]) : nothing
_haskey_bool(config, key) = haskey(config, key) ? _safe_bool(config[key]) : nothing

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

_optional_string(value) = value === nothing ? nothing : String(value)
_optional_string(value, default::String) = value === nothing ? default : String(value)

function _optional_string_vector(value)
    value === nothing && return String[]
    return [String(item) for item in value]
end

_optional_string_dict(value) = value === nothing ? Dict{String,Any}() : Dict{String,Any}(value)

function _optional_string_dict(value, default::Dict{String,Any})
    value === nothing && return default
    return Dict{String,Any}(value)
end

function _parse_model_info(data::AbstractDict{String,<:Any})
    key = String(data["key"])
    ModelInfo(
        _parse_load_type(String(data["type"])),
        _optional_string(get(data, "publisher", nothing), ""),
        key,
        _optional_string(get(data, "display_name", nothing), key),
        _optional_string(get(data, "architecture", nothing)),
        isnothing(get(data, "quantization", nothing)) ? nothing : Dict{String,Any}(data["quantization"]),
        Int(get(data, "size_bytes", 0)),
        _optional_string(get(data, "params_string", nothing)),
        Int(get(data, "max_context_length", 0)),
        _optional_string(get(data, "format", nothing)),
        _optional_string_dict(get(data, "capabilities", nothing)),
        _optional_string(get(data, "description", nothing)),
        _optional_string_vector(get(data, "variants", Any[])),
        _optional_string(get(data, "selected_variant", nothing)),
        Dict{String,Any}(data),
    )
end

function _parse_loaded_model_infos(model_data::AbstractDict{String,<:Any})
    model_type = _parse_load_type(String(model_data["type"]))
    model_key = String(model_data["key"])
    publisher = _optional_string(get(model_data, "publisher", nothing), "")
    display_name = _optional_string(get(model_data, "display_name", nothing), model_key)
    architecture = _optional_string(get(model_data, "architecture", nothing))
    loaded_instances = get(model_data, "loaded_instances", Any[])
    loaded_instances === nothing && return LoadedModelInfo[]

    return LoadedModelInfo[
        LoadedModelInfo(
            String(instance["id"]),
            model_key,
            model_type,
            publisher,
            display_name,
            architecture,
            try Int(instance["config"]["context_length"]) catch _; 0 end,
            _haskey_int(instance["config"], "eval_batch_size"),
            _haskey_int(instance["config"], "parallel"),
            _haskey_bool(instance["config"], "flash_attention"),
            _haskey_int(instance["config"], "num_experts"),
            _haskey_bool(instance["config"], "offload_kv_cache_to_gpu"),
            Dict{String,Any}(instance),
        )
        for instance in loaded_instances
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

    job = if job_or_job_id isa DownloadJob
        job_or_job_id
    else
        if !isnothing(deadline) && time() >= deadline
            throw(LMStudioTimeoutError("Timed out waiting for download to complete"))
        end
        download_status(client, String(job_or_job_id); _transport=_transport)
    end

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
        poll_job_id = if !isnothing(job.job_id)
            job.job_id
        elseif job_or_job_id isa DownloadJob
            throw(LMStudioProtocolError("download job missing job_id for non-terminal status: $(job.status)"))
        else
            String(job_or_job_id)
        end
        job = download_status(client, poll_job_id; _transport=_transport)
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

function _parse_unload_result(data::AbstractDict{String,<:Any})
    return UnloadModelResult(String(data["instance_id"]), Dict{String,Any}(data))
end

const _AUTH_API_ERROR_TYPES = Set((
    "auth_error",
    "authentication_error",
    "forbidden",
    "permission_denied",
    "unauthenticated",
    "unauthorized",
))

function _is_auth_api_error(err::LMStudioAPIError)
    if !isnothing(err.code) && (err.code == "401" || err.code == "403")
        return true
    end

    return lowercase(err.error_type) in _AUTH_API_ERROR_TYPES
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
            if _is_auth_api_error(err)
                return ServerStatus(true, false, nothing, nothing, err)
            end
            return ServerStatus(true, true, nothing, :api, err)
        elseif err isa LMStudioTimeoutError
            return ServerStatus(false, nothing, nothing, :timeout, err)
        else
            return ServerStatus(false, nothing, nothing, :transport, err)
        end
    end
end

function _parse_output_item(item::AbstractDict{String,<:Any})
    kind = get(item, "type", "unknown")
    if kind == "message"
        return MessageOutput(try String(item["content"]) catch _; "" end)
    elseif kind == "reasoning"
        return ReasoningOutput(try String(item["content"]) catch _; "" end)
    elseif kind == "tool_call"
        return ToolCallOutput(
            try String(item["tool"]) catch _; "" end,
            get(item, "arguments", Dict{String,Any}()),
            try String(get(item, "output", "")) catch _; "" end,
            get(item, "provider_info", Dict{String,Any}()),
        )
    else
        return UnknownOutputItem(Dict{String,Any}(item))
    end
end

function _parse_chat_response(data::AbstractDict{String,<:Any})
    stats_data = get(data, "stats", Dict{String,Any}())
    stats = ChatStats(
        _safe_int(get(stats_data, "input_tokens", 0)),
        _safe_int(get(stats_data, "total_output_tokens", 0)),
        _safe_int(get(stats_data, "reasoning_output_tokens", 0)),
        _safe_float(get(stats_data, "tokens_per_second", 0.0)),
        _safe_float(get(stats_data, "time_to_first_token_seconds", 0.0)),
        haskey(stats_data, "model_load_time_seconds") ? _safe_float(stats_data["model_load_time_seconds"]) : nothing,
    )
    output = ChatOutputItem[_parse_output_item(item) for item in get(data, "output", Any[])]
    model_instance_id = _optional_string(get(data, "model_instance_id", nothing), "unknown")
    return ChatResponse(model_instance_id, output, stats, get(data, "response_id", nothing))
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
    if !isnothing(response.response_id)
        session.previous_response_id = response.response_id
    end
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
    return _error_aware_channel(LMStudioEvent, _SESSION_STREAM_BUFFER_SIZE; on_close=() -> _maybe_close(upstream)) do channel
        for event in upstream
            if event isa ChatEndEvent
                if !isnothing(event.result.response_id)
                    session.previous_response_id = event.result.response_id
                end
            end
            put!(channel, event)
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
