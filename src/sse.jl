using JSON3

function _decode_event(event_name::AbstractString, payload::AbstractDict{String,<:Any})
    if event_name == "chat.start"
        return ChatStartEvent(String(payload["model_instance_id"]))
    elseif event_name == "model_load.start"
        return ModelLoadStartEvent(String(payload["model_instance_id"]))
    elseif event_name == "model_load.progress"
        return ModelLoadProgressEvent(String(payload["model_instance_id"]), Float64(payload["progress"]))
    elseif event_name == "model_load.end"
        return ModelLoadEndEvent(String(payload["model_instance_id"]), Float64(payload["load_time_seconds"]))
    elseif event_name == "prompt_processing.start"
        return PromptProcessingStartEvent()
    elseif event_name == "prompt_processing.progress"
        return PromptProcessingProgressEvent(Float64(payload["progress"]))
    elseif event_name == "prompt_processing.end"
        return PromptProcessingEndEvent()
    elseif event_name == "reasoning.start"
        return ReasoningStartEvent()
    elseif event_name == "reasoning.delta"
        return ReasoningDeltaEvent(String(payload["content"]))
    elseif event_name == "reasoning.end"
        return ReasoningEndEvent()
    elseif event_name == "tool_call.start"
        return ToolCallStartEvent(
            String(payload["tool"]),
            Dict{String,Any}(get(payload, "provider_info", Dict{String,Any}())),
        )
    elseif event_name == "tool_call.arguments"
        return ToolCallArgumentsEvent(
            String(payload["tool"]),
            Dict{String,Any}(get(payload, "arguments", Dict{String,Any}())),
            Dict{String,Any}(get(payload, "provider_info", Dict{String,Any}())),
        )
    elseif event_name == "tool_call.success"
        return ToolCallSuccessEvent(
            String(payload["tool"]),
            Dict{String,Any}(get(payload, "arguments", Dict{String,Any}())),
            String(get(payload, "output", "")),
            Dict{String,Any}(get(payload, "provider_info", Dict{String,Any}())),
        )
    elseif event_name == "tool_call.failure"
        return ToolCallFailureEvent(
            String(payload["reason"]),
            Dict{String,Any}(get(payload, "metadata", Dict{String,Any}())),
        )
    elseif event_name == "message.start"
        return MessageStartEvent()
    elseif event_name == "message.delta"
        return MessageDeltaEvent(String(payload["content"]))
    elseif event_name == "message.end"
        return MessageEndEvent()
    elseif event_name == "error"
        return StreamErrorEvent(Dict{String,Any}(get(payload, "error", Dict{String,Any}())))
    elseif event_name == "chat.end"
        return ChatEndEvent(_parse_chat_response(get(payload, "result", Dict{String,Any}())))
    else
        return UnknownEvent(String(event_name), Dict{String,Any}(payload))
    end
end

function _decode_sse_lines(lines)
    return _error_aware_channel(LMStudioEvent, 32) do channel
        event_name = nothing
        data_lines = String[]
        flush_event!() = if !isnothing(event_name)
            payload = JSON3.read(join(data_lines, "\n"), Dict{String,Any})
            put!(channel, _decode_event(event_name, payload))
        end

        for line in lines
            if isempty(line)
                flush_event!()
                event_name = nothing
                empty!(data_lines)
            elseif startswith(line, "event: ")
                event_name = line[8:end]
            elseif startswith(line, "data: ")
                push!(data_lines, line[7:end])
            end
        end

        flush_event!()
    end
end
