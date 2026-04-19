using Documenter
using LMStudioClient

makedocs(
    sitename = "LMStudioClient.jl",
    modules = [LMStudioClient],
    format = Documenter.HTML(
        repolink = nothing,
        edit_link = nothing,
    ),
    remotes = nothing,
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Streaming" => "streaming.md",
    ],
)
