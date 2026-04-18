struct LMStudioHTTPError <: Exception
    status::Int
    body::String
end

struct LMStudioAPIError <: Exception
    error_type::String
    message::String
    code::Union{Nothing,String}
    param::Union{Nothing,String}
end

struct LMStudioProtocolError <: Exception
    message::String
end

struct LMStudioTimeoutError <: Exception
    message::String
end
