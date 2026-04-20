using HTTP
using JSON3

struct _ErrorAwareChannel{T,F} <: Base.AbstractChannel{T}
    channel::Channel{T}
    failure::Base.RefValue{Any}
    cancelled::Base.RefValue{Bool}
    producer_task::Task
    on_close::F
end

Base.IteratorEltype(::Type{<:_ErrorAwareChannel}) = Base.HasEltype()
Base.IteratorSize(::Type{<:_ErrorAwareChannel}) = Base.SizeUnknown()
Base.eltype(::Type{_ErrorAwareChannel{T}}) where {T} = T
Base.isopen(stream::_ErrorAwareChannel) = isopen(stream.channel)

function _cancel_task(task::Task)
    istaskdone(task) && return nothing
    current_task() === task && return nothing
    @async begin
        try
            Base.throwto(task, InterruptException())
        catch err
            if !(err isa InterruptException || err isa InvalidStateException || err isa TaskFailedException)
                return nothing
            end
        end
    end
    return nothing
end

function _maybe_close(stream)
    applicable(close, stream) || return nothing
    try
        close(stream)
    catch err
        if !(err isa InvalidStateException)
            throw(_root_task_failure(err))
        end
    end
    return nothing
end

function Base.close(stream::_ErrorAwareChannel)
    stream.cancelled[] = true
    isopen(stream.channel) && close(stream.channel)
    stream.on_close()
    _cancel_task(stream.producer_task)
    return nothing
end

function Base.wait(stream::_ErrorAwareChannel)
    try
        wait(stream.channel)
    catch err
        if err isa InvalidStateException
            _throw_stream_failure(stream)
            return nothing
        end
        throw(_root_task_failure(err))
    end
    _throw_stream_failure(stream)
    return nothing
end

function _root_task_failure(err)
    current = err
    while true
        if current isa TaskFailedException
            exceptions = collect(Base.current_exceptions(current.task))
            length(exceptions) == 1 || break
            nested = first(exceptions)[1]
            nested === current && break
            current = nested
        elseif current isa HTTP.Exceptions.RequestError
            nested = current.error
            nested === current && break
            current = nested
        else
            break
        end
    end
    return current
end

function _throw_stream_failure(stream::_ErrorAwareChannel)
    isnothing(stream.failure[]) && return nothing
    throw(_root_task_failure(stream.failure[]))
end

_is_cancelled_close(err, cancelled::Bool) = cancelled && (err isa InterruptException || err isa InvalidStateException)

function Base.iterate(stream::_ErrorAwareChannel)
    try
        item = iterate(stream.channel)
        isnothing(item) && _throw_stream_failure(stream)
        return item
    catch err
        if err isa InvalidStateException
            _throw_stream_failure(stream)
        end
        throw(_root_task_failure(err))
    end
end

function Base.iterate(stream::_ErrorAwareChannel, state)
    try
        item = iterate(stream.channel, state)
        isnothing(item) && _throw_stream_failure(stream)
        return item
    catch err
        if err isa InvalidStateException
            _throw_stream_failure(stream)
        end
        throw(_root_task_failure(err))
    end
end

function Base.take!(stream::_ErrorAwareChannel)
    try
        return take!(stream.channel)
    catch err
        if err isa InvalidStateException
            _throw_stream_failure(stream)
        end
        throw(_root_task_failure(err))
    end
end

function _error_aware_channel(producer::Function, ::Type{T}, size::Integer; on_close=()->nothing) where {T}
    channel = Channel{T}(size)
    failure = Ref{Any}(nothing)
    cancelled = Ref(false)

    task = @async begin
        try
            producer(channel)
        catch err
            if !_is_cancelled_close(err, cancelled[])
                failure[] = err
            end
        finally
            isopen(channel) && close(channel)
        end
    end

    return _ErrorAwareChannel{T,typeof(on_close)}(channel, failure, cancelled, task, on_close)
end

function _error_aware_channel(::Type{T}, size::Integer, producer::Function; on_close=()->nothing) where {T}
    return _error_aware_channel(producer, T, size; on_close=on_close)
end

function _maybe_api_error(body::AbstractString)
    isempty(body) && return nothing

    data = try
        JSON3.read(body, Dict{String,Any})
    catch
        nothing
    end

    if data isa AbstractDict{String,<:Any} && haskey(data, "error")
        error_payload = data["error"]
        if error_payload isa AbstractDict{String,<:Any}
            return LMStudioAPIError(
                String(get(error_payload, "type", "api_error")),
                String(get(error_payload, "message", "LM Studio API error")),
                isnothing(get(error_payload, "code", nothing)) ? nothing : String(error_payload["code"]),
                isnothing(get(error_payload, "param", nothing)) ? nothing : String(error_payload["param"]),
            )
        end
    end

    return nothing
end

function _headers(client::Client; include_content_type::Bool=true)
    headers = Pair{String,String}[]
    if include_content_type
        push!(headers, "Content-Type" => "application/json")
    end
    if !isnothing(client.api_token)
        push!(headers, "Authorization" => "Bearer $(client.api_token)")
    end
    return headers
end

function _request_json(client::Client, method::String, path::String; body::Union{Nothing,Dict{String,Any}}=Dict{String,Any}())
    if body === nothing
        response = HTTP.request(
            method,
            string(client.base_url, path),
            _headers(client; include_content_type=false);
            readtimeout=client.timeout,
            status_exception=false,
        )
        return _decode_json_response(response)
    end

    response = HTTP.request(
        method,
        string(client.base_url, path),
        _headers(client),
        JSON3.write(body);
        readtimeout=client.timeout,
        status_exception=false,
    )

    return _decode_json_response(response)
end

function _stream_request_lines(client::Client, method::String, path::String; body::Union{Nothing,Dict{String,Any}}=Dict{String,Any}())
    return _error_aware_channel(String, 32) do lines
        request_body = body === nothing ? nothing : JSON3.write(body)
        headers = body === nothing ? _headers(client; include_content_type=false) : _headers(client)
        normalize_line(raw_line::Vector{UInt8}) = begin
            line = String(raw_line)
            endswith(line, "\n") && (line = chop(line))
            endswith(line, "\r") && (line = chop(line))
            line
        end

        HTTP.open(
            method,
            string(client.base_url, path),
            headers;
            readtimeout=client.timeout,
            status_exception=false,
        ) do io
            if !isnothing(request_body)
                write(io, request_body)
                closewrite(io)
            end
            response = HTTP.startread(io)
            if response.status < 200 || response.status >= 300
                body = String(read(io))
                api_error = _maybe_api_error(body)
                !isnothing(api_error) && throw(api_error)
                throw(LMStudioHTTPError(response.status, body))
            end
            pending = UInt8[]
            while !eof(io)
                chunk = readavailable(io)
                isempty(chunk) && continue
                append!(pending, chunk)

                while true
                    newline_index = findfirst(==(UInt8('\n')), pending)
                    isnothing(newline_index) && break
                    put!(lines, normalize_line(pending[1:newline_index]))
                    deleteat!(pending, 1:newline_index)
                end
            end

            if !isempty(pending)
                put!(lines, normalize_line(pending))
            end
        end
    end
end

function _decode_json_response(response)
    body = String(response.body)
    if response.status < 200 || response.status >= 300
        api_error = _maybe_api_error(body)
        !isnothing(api_error) && throw(api_error)
        throw(LMStudioHTTPError(response.status, body))
    end

    api_error = _maybe_api_error(body)
    !isnothing(api_error) && throw(api_error)

    return JSON3.read(body, Dict{String,Any})
end
