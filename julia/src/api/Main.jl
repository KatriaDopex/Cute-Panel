# backend-julia/src/main.jl
# Main entry point for the Julia backend application.

# Ensure 'src' is in the load path if running scripts directly,
# or manage as a package where 'agents' and 'api' are top-level modules.
# For simplicity with include, we assume this file is in 'src' and
# 'agents' and 'api' are subdirectories.

@info "Loading backend modules..."

# Load Core Modules from agents/
include("agents/Config.jl")
include("agents/AgentMetrics.jl") # Depends on Config
# include("agents/AgentMonitor.jl") # Uncomment if you have this module
include("agents/LLMIntegration.jl") # Might depend on Config
include("agents/Agents.jl")       # Depends on Config, AgentMetrics, LLMIntegration
include("agents/Persistence.jl")  # Depends on Agents, Config, AgentMetrics

# Load API Layer Modules from api/
include("api/Utils.jl") # Renamed from ApiUtils.jl
include("api/AgentHandlers.jl")    # Depends on api/Utils.jl and agents/Agents.jl
include("api/MetricsHandlers.jl")  # Depends on api/Utils.jl and agents/AgentMetrics.jl
include("api/LlmHandlers.jl")      # Depends on api/Utils.jl and agents/LLMIntegration.jl, agents/Config.jl
include("api/Routes.jl")           # Depends on handler modules
include("api/MainServer.jl")       # Depends on api/Routes.jl and agents/Config.jl

# It's generally better practice to structure your project as a Julia package.
# If structured as a package (e.g., CutePanel), your imports would be like:
# using .Config, .AgentMetrics, .LLMIntegration, .Agents, .Persistence
# using .Api.Utils, .Api.AgentHandlers, ...
# And then the `include` calls are handled by Julia's package manager.
# The `using ..agents.Agents` style within API modules assumes that `src` is part
# of the module hierarchy recognized by Julia's module system.

function main()
    @info "Starting Julia Agent Backend System..."

    # Modules with __init__ functions (like Config, Persistence, Agents)
    # will have their initialization logic run automatically when they are loaded (included/used).

    # Start the API server
    # The MainServer.start_server() will block if async=false in Oxygen.serve/serveparallel
    try
        # Assuming MainServer.jl defines `module MainServer`
        # and `start_server` is exported or accessed via MainServer.start_server
        api.MainServer.start_server() # Or just MainServer.start_server() if `using .api.MainServer`
    catch e
        @error "Failed to start the API server or server crashed." exception=(e, catch_backtrace())
        # exit(1) # Optionally exit if server fails to start
    end

    @info "Julia Agent Backend has shut down."
end

# Run the main function if this script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
else
    # If included as part of a larger system or package,
    # you might not want to automatically call main().
    # The modules are loaded, and `main()` can be called explicitly.
    @info "Backend modules loaded. Call main() to start the server."
end
