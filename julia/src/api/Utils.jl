# backend-julia/src/api/Utils.jl
module Utils # Changed module name from ApiUtils

using HTTP
using JSON3

export json_response, error_response, parse_request_body
export ERROR_CODE_INVALID_INPUT, ERROR_CODE_NOT_FOUND, ERROR_CODE_UNAUTHORIZED, ERROR_CODE_FORBIDDEN, ERROR_CODE_SERVER_ERROR, ERROR_CODE_EXTERNAL_SERVICE_ERROR

# Standardized Error Codes
const ERROR_CODE_INVALID_INPUT = "INVALID_INPUT"
const ERROR_CODE_NOT_FOUND = "NOT_FOUND"
const ERROR_CODE_UNAUTHORIZED = "UNAUTHORIZED"
const ERROR_CODE_FORBIDDEN = "FORBIDDEN"
const ERROR_CODE_SERVER_ERROR = "SERVER_ERROR"
const ERROR_CODE_EXTERNAL_SERVICE_ERROR = "EXTERNAL_SERVICE_ERROR"
# Add more specific codes as needed

"""
    json_response(data::Any, status_code::Int=200)

Creates an HTTP.Response with JSON data.
"""
function json_response(data::Any, status_code::Int=200)
    body = JSON3.write(data)
    headers = ["Content-Type" => "application/json"]
    return HTTP.Response(status_code, headers, body=body)
end

"""
    error_response(message::String, status_code::Int; error_code::Union{String, Nothing}=nothing, details::Any=nothing)

Creates a standardized JSON error HTTP.Response.
"""
function error_response(message::String, status_code::Int; error_code::Union{String, Nothing}=nothing, details::Any=nothing)
    error_payload = Dict{String, Any}("message" => message) # Changed "error" to "message" for clarity
    if !isnothing(error_code)
        error_payload["error_code"] = error_code
    end
    if !isnothing(details)
        error_payload["details"] = details
    end
    # It's good practice to also include the status code in the body for easier debugging by clients
    error_payload["status_code"] = status_code 
    return json_response(Dict("error" => error_payload), status_code) # Wrap in a top-level "error" object
end

"""
    parse_request_body(req::HTTP.Request)

Parses the JSON request body into a Dict.
Returns the Dict or nothing if parsing fails or body is empty.
"""
function parse_request_body(req::HTTP.Request)
    if isempty(req.body)
        return nothing
    end
    try
        return JSON3.read(String(req.body))
    catch e
        @warn "Failed to parse request body as JSON" exception=(e, catch_backtrace())
        return nothing # Or throw a specific error
    end
end

end
