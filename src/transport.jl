using HTTP
using JSON3

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
    return Channel{String}(32) do lines
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
