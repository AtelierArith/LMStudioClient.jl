using Dates

struct Client
    base_url::String
    api_token::Union{Nothing,String}
    timeout::Int
end

function _normalize_timeout_seconds(timeout::Real)
    isfinite(timeout) || throw(ArgumentError("timeout must be finite"))
    timeout >= 0 || throw(ArgumentError("timeout must be non-negative"))
    return ceil(Int, timeout)
end

Client(; base_url::String="http://127.0.0.1:1234", api_token::Union{Nothing,String}=nothing, timeout::Real=30.0) =
    Client(base_url, api_token, _normalize_timeout_seconds(timeout))

mutable struct ChatSession
    model::String
    previous_response_id::Union{Nothing,String}
    system_prompt::Union{Nothing,String}
end

ChatSession(model::String; previous_response_id::Union{Nothing,String}=nothing, system_prompt::Union{Nothing,String}=nothing) =
    ChatSession(model, previous_response_id, system_prompt)

struct DownloadJob
    job_id::Union{Nothing,String}
    status::Symbol
    total_size_bytes::Union{Nothing,Int}
    downloaded_bytes::Union{Nothing,Int}
    started_at::Union{Nothing,DateTime}
    completed_at::Union{Nothing,DateTime}
    bytes_per_second::Union{Nothing,Float64}
    estimated_completion::Union{Nothing,DateTime}
end

struct ModelInfo
    type::Symbol
    publisher::String
    key::String
    display_name::String
    architecture::Union{Nothing,String}
    quantization::Union{Nothing,Dict{String,Any}}
    size_bytes::Int
    params_string::Union{Nothing,String}
    max_context_length::Int
    format::Union{Nothing,String}
    capabilities::Dict{String,Any}
    description::Union{Nothing,String}
    variants::Vector{String}
    selected_variant::Union{Nothing,String}
    raw::Dict{String,Any}
end

struct LoadedModelInfo
    instance_id::String
    model_key::String
    type::Symbol
    publisher::String
    display_name::String
    architecture::Union{Nothing,String}
    context_length::Int
    eval_batch_size::Union{Nothing,Int}
    parallel::Union{Nothing,Int}
    flash_attention::Union{Nothing,Bool}
    num_experts::Union{Nothing,Int}
    offload_kv_cache_to_gpu::Union{Nothing,Bool}
    raw::Dict{String,Any}
end

struct LoadModelResult
    type::Symbol
    instance_id::String
    status::Symbol
    load_time_seconds::Float64
    load_config::Dict{String,Any}
end

struct ChatStats
    input_tokens::Int
    total_output_tokens::Int
    reasoning_output_tokens::Int
    tokens_per_second::Float64
    time_to_first_token_seconds::Float64
    model_load_time_seconds::Union{Nothing,Float64}
end

abstract type ChatOutputItem end
abstract type LMStudioEvent end

struct MessageOutput <: ChatOutputItem
    content::String
end

struct ReasoningOutput <: ChatOutputItem
    content::String
end

struct ToolCallOutput <: ChatOutputItem
    tool::String
    arguments::Dict{String,Any}
    output::String
    provider_info::Dict{String,Any}
end

struct UnknownOutputItem <: ChatOutputItem
    raw::Dict{String,Any}
end

struct ChatResponse
    model_instance_id::String
    output::Vector{ChatOutputItem}
    stats::ChatStats
    response_id::Union{Nothing,String}
end

struct ChatStartEvent <: LMStudioEvent
    model_instance_id::String
end

struct ModelLoadStartEvent <: LMStudioEvent
    model_instance_id::String
end

struct ModelLoadProgressEvent <: LMStudioEvent
    model_instance_id::String
    progress::Float64
end

struct ModelLoadEndEvent <: LMStudioEvent
    model_instance_id::String
    load_time_seconds::Float64
end

struct PromptProcessingStartEvent <: LMStudioEvent end

struct PromptProcessingProgressEvent <: LMStudioEvent
    progress::Float64
end

struct PromptProcessingEndEvent <: LMStudioEvent end

struct ReasoningStartEvent <: LMStudioEvent end

struct ReasoningDeltaEvent <: LMStudioEvent
    content::String
end

struct ReasoningEndEvent <: LMStudioEvent end

struct ToolCallStartEvent <: LMStudioEvent
    tool::String
    provider_info::Dict{String,Any}
end

struct ToolCallArgumentsEvent <: LMStudioEvent
    tool::String
    arguments::Dict{String,Any}
    provider_info::Dict{String,Any}
end

struct ToolCallSuccessEvent <: LMStudioEvent
    tool::String
    arguments::Dict{String,Any}
    output::String
    provider_info::Dict{String,Any}
end

struct ToolCallFailureEvent <: LMStudioEvent
    reason::String
    metadata::Dict{String,Any}
end

struct MessageStartEvent <: LMStudioEvent end

struct MessageDeltaEvent <: LMStudioEvent
    content::String
end

struct MessageEndEvent <: LMStudioEvent end

struct StreamErrorEvent <: LMStudioEvent
    error::Dict{String,Any}
end

struct ChatEndEvent <: LMStudioEvent
    result::ChatResponse
end

struct UnknownEvent <: LMStudioEvent
    event_type::String
    raw::Dict{String,Any}
end
