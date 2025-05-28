# julia/src/api/API.jl
module API

# This module serves as the main entry point for the API layer,
# bringing together all handlers, routes, and the server.

# Utils are used by handlers
include("Utils.jl")

# Include all handler modules
include("AgentHandlers.jl")
include("BlockchainHandlers.jl")
include("DexHandlers.jl")
include("LlmHandlers.jl")
include("MetricsHandlers.jl")
include("PriceFeedHandlers.jl")
include("SwarmHandlers.jl")
include("TradingHandlers.jl")

# Include Routes (which uses the handlers)
include("Routes.jl")

# Include MainServer (which uses Routes and starts the server)
include("MainServer.jl")

# Export the function to start the server, namespaced under API
# e.g., CutePanel.API.start_server()
using .MainServer: start_server
export start_server

# Optionally, re-export handler modules if they need to be accessed directly,
# though typically interaction is via the server endpoints.
# export AgentHandlers, BlockchainHandlers, etc.

function __init__()
    @info "CutePanel API Layer (module API) initialized."
end

end # module API
