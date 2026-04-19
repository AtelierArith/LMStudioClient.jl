module LMStudioClient

include("types.jl")
include("errors.jl")
include("transport.jl")
include("api.jl")
include("sse.jl")

export Client
export ChatSession
export DownloadJob
export LoadModelResult
export ChatStats
export ChatResponse
export ChatOutputItem
export MessageOutput
export ReasoningOutput
export ToolCallOutput
export UnknownOutputItem
export LMStudioEvent
export ChatStartEvent
export ModelLoadStartEvent
export ModelLoadProgressEvent
export ModelLoadEndEvent
export PromptProcessingStartEvent
export PromptProcessingProgressEvent
export PromptProcessingEndEvent
export ReasoningStartEvent
export ReasoningDeltaEvent
export ReasoningEndEvent
export ToolCallStartEvent
export ToolCallArgumentsEvent
export ToolCallSuccessEvent
export ToolCallFailureEvent
export MessageStartEvent
export MessageDeltaEvent
export MessageEndEvent
export StreamErrorEvent
export ChatEndEvent
export UnknownEvent
export download_model
export download_status
export wait_for_download
export load_model
export chat
export stream_chat

end # module LMStudioClient
