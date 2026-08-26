using CompileIQ
using Documenter

DocMeta.setdocmeta!(CompileIQ, :DocTestSetup, :(using CompileIQ); recursive=true)

makedocs(;
    modules=[CompileIQ],
    authors="AntonOresten <antonoresten@proton.me> and contributors",
    sitename="CompileIQ.jl",
    format=Documenter.HTML(;
        canonical="https://jool-space.github.io/CompileIQ.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/jool-space/CompileIQ.jl",
    devbranch="main",
)
