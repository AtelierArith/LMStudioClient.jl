using Test
using LMStudioClient

include("types_test.jl")
include("api_test.jl")
include("sse_test.jl")

if get(ENV, "LMSTUDIO_RUN_LIVE_TESTS", "0") == "1"
    include("live_api_test.jl")
end
