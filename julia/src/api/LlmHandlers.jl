# backend-julia/src/api/LlmHandlers.jl
module LlmHandlers # Filename LlmHandlers.jl implies module LlmHandlers

using HTTP
using ..Utils # Updated from ApiUtils to Utils

# Import from the 'agents' subdirectory
import ..agents.LLMIntegration
import ..agents.Config

function get_configured_llm_providers_handler(req::HTTP.Request)
    try
        default_llm_config = agents.Config.get_config("agent.default_llm_config", Dict())
        known_providers = ["openai", "anthropic", "llama", "mistral", "cohere", "gemini", "echo"]
        available_and_configured = []

        for provider_name in known_providers
            # Check if the LLMIntegration module can create an instance for this provider
            # This indirectly checks if the provider is known to create_llm_integration
            if agents.LLMIntegration.create_llm_integration(Dict("provider" => provider_name)) !== nothing
                 push!(available_and_configured, provider_name)
            end
        end
        return Utils.json_response(Dict("configured_providers" => available_and_configured, "default_config_example" => default_llm_config))
    catch e
        @error "Error in get_configured_llm_providers_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get LLM provider information: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_llm_provider_status_handler(req::HTTP.Request, provider_name::String)
    if isempty(provider_name)
        return Utils.error_response("Provider name cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"provider_name"))
    end
    try
        # Attempt to create an LLM instance for the provider.
        # The `cfg` for status check can be minimal, primarily for API key if needed by status check.
        # We can use the default agent LLM config for this provider as a base.
        default_provider_cfg = Dict{String,Any}("provider" => provider_name) # Minimal config
        
        # Try to get more specific default config for this provider if available globally
        # This assumes `agents.Config.get_config` can fetch nested dicts for specific providers
        # e.g., config structure like: llm.providers.openai.api_key, llm.providers.openai.model
        # For now, we'll pass a simple config, and get_provider_status will use ENV vars or its own defaults.
        # A more robust approach might fetch the global default config for this provider.
        
        # Get the global default LLM config for the agent system, which might contain API keys or base URLs
        # This is from agents/Config.jl's DEFAULT_CONFIG["llm"] or its overrides.
        # However, `get_provider_status` in LLMIntegration.jl already checks ENV and then passed `cfg`.
        # So, we can pass a minimal `cfg` here, or a more specific one if we construct it.
        
        # Let's use a minimal config, relying on LLMIntegration.get_provider_status to use ENV vars
        # or defaults within the `cfg` passed to it (which is currently empty for this status check).
        # The `cfg` in `get_provider_status` is primarily for `api_key`, `api_base`, `model` (for Gemini check).
        
        # Construct a config dict that `get_provider_status` can use.
        # It might need `api_key` (if not in ENV), `api_base`, `model` (for Gemini).
        # These would ideally come from a global configuration for the provider.
        # For now, let's assume `get_provider_status` primarily relies on ENV for keys,
        # and we pass an empty `cfg` or one with just the provider name.
        
        llm_instance = LLMIntegration.create_llm_integration(Dict("provider" => provider_name))
        if isnothing(llm_instance)
            return Utils.error_response("LLM provider '$provider_name' is not supported or recognized.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("provider_name"=>provider_name))
        end

        # The `cfg` passed to `get_provider_status` should contain any relevant parameters
        # for the status check itself, like API keys if not from ENV, or specific model for Gemini.
        # We can try to fetch the default config for this provider from the global agent config.
        # This is a bit indirect. `agents.Config.get_config("llm.providers.$provider_name", Dict())`
        # would be ideal if config was structured that way.
        # For now, pass an empty dict; `get_provider_status` will use ENV for keys.
        status_check_cfg = Dict{String,Any}() 
        # If specific models are needed for status checks (like Gemini), they are hardcoded in get_provider_status
        # or could be passed via `status_check_cfg` if we had a good way to get them here.

        status_info = LLMIntegration.get_provider_status(llm_instance, status_check_cfg)
        
        return Utils.json_response(status_info)
    catch e
        @error "Error in get_llm_provider_status_handler for $provider_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get status for LLM provider '$provider_name': $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function direct_llm_chat_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    prompt = get(body, "prompt", "")
    provider_config = get(body, "llm_config", Dict{String,Any}()) # llm_config is expected to be a Dict

    if isempty(prompt)
        return Utils.error_response("Prompt cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"prompt"))
    end
    if !isa(provider_config, Dict) || !haskey(provider_config, "provider") || !isa(provider_config["provider"], String) || isempty(provider_config["provider"])
        return Utils.error_response("llm_config must be an object and specify a non-empty 'provider' string", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"llm_config.provider"))
    end

    try
        llm_instance = agents.LLMIntegration.create_llm_integration(provider_config)
        if isnothing(llm_instance)
            return Utils.error_response("Could not create LLM integration for provider: $(provider_config["provider"]). Check provider name and configuration.", 400, error_code="LLM_PROVIDER_INIT_FAILED", details=Dict("provider_config"=>provider_config))
        end

        # The `chat` function in LLMIntegration might throw its own errors for API issues
        response_text = agents.LLMIntegration.chat(llm_instance, prompt; cfg=provider_config) 
        
        return Utils.json_response(Dict("prompt" => prompt, "response" => response_text, "provider_used" => provider_config["provider"]))
    catch e
        # Catch errors from LLMIntegration.chat (e.g., API key errors, network issues with LLM provider)
        @error "Error in direct_llm_chat_handler" exception=(e, catch_backtrace())
        # It might be useful to inspect `e` to return a more specific error code if possible
        return Utils.error_response("LLM direct chat failed: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR)
    end
end

end
