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
        open_stream = if body === nothing
            callback -> HTTP.open(
                callback,
                method,
                string(client.base_url, path),
                _headers(client; include_content_type=false);
                readtimeout=client.timeout,
                status_exception=false,
            )
        else
            callback -> HTTP.open(
                callback,
                method,
                string(client.base_url, path),
                _headers(client),
                JSON3.write(body);
                readtimeout=client.timeout,
                status_exception=false,
            )
        end

        open_stream(function(io)
            response = HTTP.startread(io)
            if response.status < 200 || response.status >= 300
                body = String(read(io))
                api_error = _maybe_api_error(body)
                !isnothing(api_error) && throw(api_error)
                throw(LMStudioHTTPError(response.status, body))
            end
            for line in eachline(io)
                put!(lines, line)
            end
        end)
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
