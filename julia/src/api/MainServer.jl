# backend-julia/src/api/MainServer.jl
module MainServer # Filename MainServer.jl implies module MainServer

using Oxygen
using HTTP # Required for HTTP.Request, HTTP.Response if using custom middleware
using ..Routes # Sibling module
using JSON3 # For JSON responses in middleware

# Import the main application Config module
include("../../config/config.jl") # Assuming MainServer.jl is in src/api/
# Use `MainAppConfig` to avoid conflict with `agents.Config` if it were also used here.
MainAppConfig = Config 

# Load the main application configuration once
const APP_CONFIG = MainAppConfig.load(joinpath(@__DIR__, "..", "..", "config", "config.toml"))

# Basic logging middleware example
function logging_middleware(handler)
    return function(req::HTTP.Request)
        t = time()
        @info "Request: $(req.method) $(req.target)"
        response = handler(req)
        duration = round((time() - t) * 1000, digits=2)
        @info "Response: $(response.status) ($(duration)ms)"
        return response
    end
end

# Basic CORS middleware example
function cors_middleware(handler)
    return function(req::HTTP.Request)
        if req.method == "OPTIONS"
            headers = [
                "Access-Control-Allow-Origin" => "*",
                "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type, Authorization, X-API-Key", # Added X-API-Key
            ]
            return HTTP.Response(204, headers)
        end
        response = handler(req)
        HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
        HTTP.setheader(response, "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS")
        HTTP.setheader(response, "Access-Control-Allow-Headers" => "Content-Type, Authorization, X-API-Key")
        return response
    end
end

# API Key Authentication Middleware
function auth_middleware(handler)
    return function(req::HTTP.Request)
        auth_enabled = MainAppConfig.get_value(APP_CONFIG, "security.enable_authentication", true)

        if !auth_enabled
            return handler(req) # Authentication is disabled, proceed
        end

        api_key_header = HTTP.header(req, "X-API-Key", "")
        
        if isempty(api_key_header)
            @warn "AuthMiddleware: Missing X-API-Key header"
            return HTTP.Response(401, ["Content-Type" => "application/json"], body=JSON3.write(Dict("error" => "Unauthorized: Missing API Key")))
        end

        valid_keys = MainAppConfig.get_value(APP_CONFIG, "security.api_keys", ["default-secret-key-please-change"])
        # Ensure valid_keys is always a Vector, even if config returns a single string by mistake
        if !(valid_keys isa AbstractVector)
            @error "AuthMiddleware: 'security.api_keys' in config is not a list. Denying access."
            return HTTP.Response(500, ["Content-Type" => "application/json"], body=JSON3.write(Dict("error" => "Server configuration error")))
        end

        if !(api_key_header in valid_keys)
            @warn "AuthMiddleware: Invalid API Key provided"
            return HTTP.Response(403, ["Content-Type" => "application/json"], body=JSON3.write(Dict("error" => "Forbidden: Invalid API Key")))
        end
        
        # API Key is valid
        return handler(req)
    end
end

"""
    start_server(; default_host::String="0.0.0.0", default_port::Int=8000)

Configures and starts the Oxygen HTTP server for the API.
"""
function start_server(; default_host::String="0.0.0.0", default_port::Int=8000) # Default port from Oxygen, not agents.Config
    # Use APP_CONFIG for server host and port
    api_host = MainAppConfig.get_value(APP_CONFIG, "server.host", default_host)
    api_port = MainAppConfig.get_value(APP_CONFIG, "server.port", default_port)

    @info "Initializing API server on $api_host:$api_port..."

    Routes.register_routes()
    
    # Middleware order matters: logging -> cors -> auth -> router
    # Auth middleware should be one of the first to protect endpoints.
    # CORS should typically be early to handle OPTIONS requests.
    # Logging can be first or last depending on what you want to log.
    # Here, logging is outermost to capture all request/response info.
    
    # Oxygen's serveparallel can take a vector of middleware.
    # The order in the vector is the order they are applied (wrapper order).
    # Outermost (first applied) to innermost (last applied before route handler).
    server_middleware = [
        logging_middleware, # Logs everything
        cors_middleware,    # Handles CORS headers and OPTIONS requests
        auth_middleware     # Handles API key authentication
    ]

    try
        Oxygen.serveparallel(; host=api_host, port=api_port, async=false, middleware=server_middleware)
        
        @info "API server stopped."
    catch e
        @error "API server failed to start or crashed." exception=(e, catch_backtrace())
    end
end

end
