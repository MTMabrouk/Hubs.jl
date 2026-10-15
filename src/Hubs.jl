module Hubs

include("core/CoreDomain.jl")
include("compiler/Compiler.jl")
include("backends/Backends.jl")

# The legacy implementation remains available while the new domain and compiler
# layers are introduced behind regression-tested boundaries.
include("legacy/Legacy.jl")

end # module Hubs
