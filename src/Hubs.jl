module Hubs

include("core/CoreDomain.jl")

# The legacy implementation remains available while the new domain and compiler
# layers are introduced behind regression-tested boundaries.
include("legacy/Legacy.jl")

end # module Hubs
