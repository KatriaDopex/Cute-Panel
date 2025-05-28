# backend-julia/src/agents/LLMIntegration.jl

"""
LLM Integration Module for Agents.jl

Provides a common interface for interacting with various Language Model providers,
supporting pluggability and advanced features.
"""
module LLMIntegration

using Logging, Pkg # Use Pkg to check package availability
using JSON3 # Needed for parsing/serializing provider-specific configs and request/response bodies
using HTTP  # For making direct HTTP calls

# Import the abstract type from the Agents module
import ..AgentCore: AbstractLLMIntegration # Relative import for sibling module in parent dir

export chat, get_provider_status # Export the new status function

# --- Concrete Implementations of AbstractLLMIntegration ---
struct OpenAILLMIntegration <: AbstractLLMIntegration end
struct AnthropicLLMIntegration <: AbstractLLMIntegration end
struct LlamaLLMIntegration <: AbstractLLMIntegration end
struct MistralLLMIntegration <: AbstractLLMIntegration end
struct CohereLLMIntegration <: AbstractLLMIntegration end
struct GeminiLLMIntegration <: AbstractLLMIntegration end
struct EchoLLMIntegration <: AbstractLLMIntegration end # Fallback

# --- Provider Availability Checks (Conceptual) ---
is_openai_available() = true
is_anthropic_available() = true # For direct HTTP, assume available if configured
# ... other availability checks (can be enhanced later if needed)


"""
    chat(llm::AbstractLLMIntegration, prompt::String; cfg::Dict)

Generic fallback. Concrete types must implement their own `chat` method.
"""
function chat(llm::AbstractLLMIntegration, prompt::String; cfg::Dict)
    @warn "Chat method not implemented for LLM integration type $(typeof(llm)). Falling back to echo."
    return "[LLM Integration Error] Echo: " * prompt
end

# --- OpenAI Implementation using Direct HTTP ---
function chat(llm::OpenAILLMIntegration, prompt::String; cfg::Dict)
    api_key = get(ENV, "OPENAI_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        @error "OpenAI API key not found in ENV or agent configuration."
        return "[LLM ERROR: OpenAI API Key Missing]"
    end

    model = get(cfg, "model", "gpt-4o-mini") # OpenAI model
    temperature = get(cfg, "temperature", 0.7)
    max_tokens_to_sample = get(cfg, "max_tokens", 1024) # Renamed for clarity, maps to OpenAI's max_tokens
    system_prompt_content = get(cfg, "system_prompt", "")
    openai_api_base = get(cfg, "api_base", "https://api.openai.com/v1")
    chat_endpoint = "$openai_api_base/chat/completions"

    headers = Dict(
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $api_key"
    )

    messages = []
    if !isempty(system_prompt_content)
        push!(messages, Dict("role" => "system", "content" => system_prompt_content))
    end
    push!(messages, Dict("role" => "user", "content" => prompt))

    payload = Dict(
        "model" => model,
        "messages" => messages,
        "temperature" => temperature,
        "max_tokens" => max_tokens_to_sample
    )
    # Add other OpenAI specific parameters from cfg if needed (e.g., top_p, stream)
    # if haskey(cfg, "stream") && cfg["stream"] == true
    #     payload["stream"] = true
    #     # Note: Handling streaming responses would require different logic below
    # end

    json_payload = JSON3.write(payload)
    @debug "Sending request to OpenAI" endpoint=chat_endpoint model=model
    try
        response = HTTP.post(chat_endpoint, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 60))
        response_body_str = String(response.body)
        @debug "OpenAI Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            if haskey(json_response, "choices") && !isempty(json_response.choices) &&
               haskey(json_response.choices[1], "message") && haskey(json_response.choices[1].message, "content")
                return json_response.choices[1].message.content
            else
                @error "OpenAI response format error." full_response=json_response
                return "[LLM ERROR: OpenAI response format error]"
            end
        else
            @error "OpenAI API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str # Basic error detail
            try # Try to parse more specific error
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "error") && haskey(json_error.error, "message")
                    error_details = json_error.error.message
                end
            catch end
            return "[LLM ERROR: OpenAI API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during OpenAI API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end

# --- Anthropic (Claude) Implementation using Direct HTTP ---
function chat(llm::AnthropicLLMIntegration, prompt::String; cfg::Dict)
    api_key = get(ENV, "ANTHROPIC_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        @error "Anthropic API key not found in ENV or agent configuration."
        return "[LLM ERROR: Anthropic API Key Missing]"
    end

    model = get(cfg, "model", "claude-3-haiku-20240307") # Anthropic model
    max_tokens_to_sample = get(cfg, "max_tokens", 1024) # Anthropic uses "max_tokens"
    temperature = get(cfg, "temperature", 0.7)
    system_prompt_content = get(cfg, "system_prompt", "") # Anthropic uses a "system" parameter
    anthropic_api_base = get(cfg, "api_base", "https://api.anthropic.com/v1")
    messages_endpoint = "$anthropic_api_base/messages"
    anthropic_version = get(cfg, "anthropic_version", "2023-06-01")

    headers = Dict(
        "Content-Type" => "application/json",
        "x-api-key" => api_key,
        "anthropic-version" => anthropic_version
    )

    # Anthropic's message format is slightly different
    messages = [
        Dict("role" => "user", "content" => prompt)
    ]

    payload = Dict(
        "model" => model,
        "messages" => messages,
        "max_tokens" => max_tokens_to_sample,
        "temperature" => temperature
    )
    if !isempty(system_prompt_content)
        payload["system"] = system_prompt_content
    end
    # Add other Anthropic specific parameters from cfg if needed (e.g., top_p, top_k, stream)
    # if haskey(cfg, "stream") && cfg["stream"] == true
    #     payload["stream"] = true
    #     # Note: Handling streaming responses would require different logic below
    # end

    json_payload = JSON3.write(payload)
    @debug "Sending request to Anthropic Messages API" endpoint=messages_endpoint model=model
    try
        response = HTTP.post(messages_endpoint, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 60))
        response_body_str = String(response.body)
        @debug "Anthropic Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            # Anthropic response structure: content is an array of blocks, usually one text block
            if haskey(json_response, "content") && !isempty(json_response.content) &&
               haskey(json_response.content[1], "type") && json_response.content[1].type == "text" &&
               haskey(json_response.content[1], "text")
                return json_response.content[1].text
            else
                @error "Anthropic response format error." full_response=json_response
                return "[LLM ERROR: Anthropic response format error]"
            end
        else
            @error "Anthropic API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str # Basic error detail
            try # Try to parse more specific error
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "error") && haskey(json_error.error, "message")
                    error_details = json_error.error.message
                elseif haskey(json_error, "type") && haskey(json_error, "message") # Another common error format
                    error_details = "$(json_error.type): $(json_error.message)"
                end
            catch end
            return "[LLM ERROR: Anthropic API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during Anthropic API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end


# --- Placeholder Implementations for Other Providers (using direct HTTP) ---
function chat(llm::LlamaLLMIntegration, prompt::String; cfg::Dict)
    endpoint_url = get(cfg, "endpoint_url", get(ENV, "LLAMA_ENDPOINT_URL", ""))
    api_key = get(cfg, "api_key", get(ENV, "LLAMA_API_KEY", "")) # Generic key name
    model_identifier = get(cfg, "model", "llama3-8b-8192") # Example model, user must configure

    is_local_endpoint = occursin("localhost", endpoint_url) || occursin("127.0.0.1", endpoint_url)

    if isempty(endpoint_url)
        @warn "Llama endpoint URL not found in agent configuration or ENV. Using mock response."
        return """
        [MOCK Llama RESPONSE]
        Llama integration requires 'endpoint_url' to be configured.
        For your prompt: "$(prompt)", a possible answer could be:
        "This is a mock response from the Llama integration. Please configure your Llama endpoint."
        """
    end

    if !is_local_endpoint && isempty(api_key)
        @warn "Llama API key not found for external endpoint '$endpoint_url'. Using mock response. Some endpoints may not require a key."
        # Some public or self-hosted endpoints might not need a key.
        # We could proceed if user explicitly configured no key, but for safety, mock if external and no key.
        # However, to allow keyless external endpoints, we can proceed but log a warning.
        # For now, let's be strict: if external and no key, mock. User can pass an empty string as key if truly keyless.
        # Reconsidering: Many self-hosted or research endpoints are keyless. Let's allow it but warn.
        if get(cfg, "requires_api_key", true) && isempty(api_key) # Add a config to specify if key is needed
             @warn "Llama API key not found for external endpoint '$endpoint_url' and 'requires_api_key' is true or default. Using mock response."
             return """
             [MOCK Llama RESPONSE]
             Llama API key not provided for external endpoint.
             For your prompt: "$(prompt)", a possible answer could be:
             "This is a mock response. Configure LLAMA_API_KEY or set 'requires_api_key': false in config if endpoint is keyless."
             """
        end
    end

    headers = Dict("Content-Type" => "application/json")
    if !isempty(api_key)
        headers["Authorization"] = "Bearer $api_key"
    end

    # Assuming an OpenAI-compatible API structure for the Llama endpoint
    # Users might need to adjust this payload based on their specific Llama hosting solution.
    messages = [Dict("role" => "user", "content" => prompt)]
    system_prompt_content = get(cfg, "system_prompt", "")
    if !isempty(system_prompt_content)
        pushfirst!(messages, Dict("role" => "system", "content" => system_prompt_content))
    end

    payload = Dict(
        "model" => model_identifier,
        "messages" => messages,
        "temperature" => get(cfg, "temperature", 0.7),
        "max_tokens" => get(cfg, "max_tokens", 1024)
        # Add other common parameters like "stream" if supported by endpoint
    )

    json_payload = JSON3.write(payload)
    @debug "Sending request to Llama endpoint" endpoint=endpoint_url model=model_identifier
    try
        response = HTTP.post(endpoint_url, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 120))
        response_body_str = String(response.body)
        @debug "Llama Endpoint Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            # Assuming OpenAI-compatible response structure:
            if haskey(json_response, "choices") && !isempty(json_response.choices) &&
               haskey(json_response.choices[1], "message") && haskey(json_response.choices[1].message, "content")
                return json_response.choices[1].message.content
            # Fallback for some other common structures (e.g. direct text or Groq-like)
            elseif haskey(json_response, "text") # Direct text
                return json_response.text
            elseif haskey(json_response, "generated_text") # HuggingFace TGI
                return json_response.generated_text
            else
                @error "Llama endpoint response format error. Expected OpenAI-like structure or known alternatives." full_response=json_response
                return "[LLM ERROR: Llama endpoint response format error]"
            end
        else
            @error "Llama endpoint API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str
            try
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "error") && haskey(json_error.error, "message")
                    error_details = json_error.error.message
                elseif haskey(json_error, "message")
                     error_details = json_error.message
                elseif haskey(json_error, "detail") && isa(json_error.detail, String)
                    error_details = json_error.detail
                end
            catch end
            return "[LLM ERROR: Llama Endpoint API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during Llama endpoint API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end

function chat(llm::MistralLLMIntegration, prompt::String; cfg::Dict)
    api_key = get(ENV, "MISTRAL_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        @warn "Mistral API key not found in ENV or agent configuration. Using mock response."
        return """
        [MOCK Mistral RESPONSE]
        If an API key were provided, I would have contacted Mistral AI.
        For your prompt: "$(prompt)", a possible answer could be:
        "This is a mock response from the Mistral integration. Please configure your MISTRAL_API_KEY."
        """
    end

    model = get(cfg, "model", "mistral-small-latest") # Default Mistral model
    temperature = get(cfg, "temperature", 0.7)
    max_tokens_to_sample = get(cfg, "max_tokens", 1024)
    system_prompt_content = get(cfg, "system_prompt", "")
    mistral_api_base = get(cfg, "api_base", "https://api.mistral.ai/v1")
    chat_endpoint = "$mistral_api_base/chat/completions"

    headers = Dict(
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Authorization" => "Bearer $api_key"
    )

    messages = []
    if !isempty(system_prompt_content)
        # Mistral's API format for system prompt might differ or be part of the user message context
        # For simplicity, prepending to user prompt if system prompt is basic.
        # A more robust solution would check Mistral's exact API for system messages.
        # Current Mistral API uses a similar message structure to OpenAI.
        push!(messages, Dict("role" => "system", "content" => system_prompt_content))
    end
    push!(messages, Dict("role" => "user", "content" => prompt))

    payload = Dict(
        "model" => model,
        "messages" => messages,
        "temperature" => temperature,
        "max_tokens" => max_tokens_to_sample
        # "safe_prompt" => get(cfg, "safe_prompt", false) # Example of another Mistral param
    )

    json_payload = JSON3.write(payload)
    @debug "Sending request to Mistral AI" endpoint=chat_endpoint model=model
    try
        response = HTTP.post(chat_endpoint, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 60))
        response_body_str = String(response.body)
        @debug "Mistral AI Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            if haskey(json_response, "choices") && !isempty(json_response.choices) &&
               haskey(json_response.choices[1], "message") && haskey(json_response.choices[1].message, "content")
                return json_response.choices[1].message.content
            else
                @error "Mistral AI response format error." full_response=json_response
                return "[LLM ERROR: Mistral AI response format error]"
            end
        else
            @error "Mistral AI API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str
            try
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "message")
                    error_details = json_error.message
                elseif haskey(json_error, "detail") && isa(json_error.detail, String) # Another possible error format
                    error_details = json_error.detail
                elseif haskey(json_error, "detail") && isa(json_error.detail, Vector) && !isempty(json_error.detail) && haskey(json_error.detail[1], "msg")
                     error_details = json_error.detail[1].msg # For validation errors
                end
            catch end
            return "[LLM ERROR: Mistral API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during Mistral AI API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end

function chat(llm::CohereLLMIntegration, prompt::String; cfg::Dict)
    api_key = get(ENV, "COHERE_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        @warn "Cohere API key not found in ENV or agent configuration. Using mock response."
        return """
        [MOCK Cohere RESPONSE]
        If an API key were provided, I would have contacted Cohere.
        For your prompt: "$(prompt)", a possible answer could be:
        "This is a mock response from the Cohere integration. Please configure your COHERE_API_KEY."
        """
    end

    model = get(cfg, "model", "command-r") # Default Cohere model
    temperature = get(cfg, "temperature", 0.3) # Cohere's default is often lower
    max_tokens = get(cfg, "max_tokens", 1024)
    # Cohere uses `chat_history` and `message`
    # system_prompt can be part of chat_history or a preamble to the message
    system_prompt_content = get(cfg, "system_prompt", "") 
    cohere_api_base = get(cfg, "api_base", "https://api.cohere.ai/v1")
    chat_endpoint = "$cohere_api_base/chat"

    headers = Dict(
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $api_key",
        "Cohere-Version" => get(cfg, "cohere_version", "2022-12-06") # Example version
    )

    # Construct chat history if needed, or just send the message
    # For simplicity, if system_prompt is provided, we can prepend it to the user's prompt
    # or structure it as a system turn in chat_history if the model supports it well.
    # Cohere's chat endpoint takes a `message` and optional `chat_history`.
    # A `preamble` can also be used for system-level instructions.

    payload = Dict{String, Any}(
        "model" => model,
        "message" => isempty(system_prompt_content) ? prompt : system_prompt_content * "\n\nUser: " * prompt, # Simple prepend for system
        "temperature" => temperature,
        "max_tokens" => max_tokens
        # "chat_history" => [], # Example: [{"role": "USER", "message": "Previous message"}]
        # "preamble" => system_prompt_content, # Alternative for system prompt
        # "connectors" => [{"id": "web-search"}] # Example for using Cohere connectors
    )
    # More sophisticated system prompt handling:
    if haskey(cfg, "preamble") && !isempty(cfg["preamble"])
        payload["preamble"] = cfg["preamble"]
        payload["message"] = prompt # Use raw prompt if preamble is used
    elseif !isempty(system_prompt_content) && !haskey(cfg, "preamble")
        # If system_prompt is given but not preamble, use it in chat_history
        payload["chat_history"] = [Dict("role" => "SYSTEM", "message" => system_prompt_content)]
        payload["message"] = prompt
    end


    json_payload = JSON3.write(payload)
    @debug "Sending request to Cohere" endpoint=chat_endpoint model=model
    try
        response = HTTP.post(chat_endpoint, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 60))
        response_body_str = String(response.body)
        @debug "Cohere Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            # Cohere's chat response structure has a "text" field for the reply.
            # It might also have "chat_history", "tool_calls", etc.
            if haskey(json_response, "text")
                return json_response.text
            elseif haskey(json_response, "tool_calls") && !isnothing(json_response.tool_calls) && !isempty(json_response.tool_calls)
                # Handle tool calls if necessary, or return a representation
                return "[Cohere Tool Call Requested: $(JSON3.write(json_response.tool_calls))]"
            else
                @error "Cohere response format error. Missing 'text' field." full_response=json_response
                return "[LLM ERROR: Cohere response format error]"
            end
        else
            @error "Cohere API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str
            try
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "message")
                    error_details = json_error.message
                end
            catch end
            return "[LLM ERROR: Cohere API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during Cohere API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end

function chat(llm::GeminiLLMIntegration, prompt::String; cfg::Dict)
    api_key = get(ENV, "GOOGLE_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        @warn "Google (Gemini) API key not found in ENV or agent configuration. Using mock response."
        return """
        [MOCK Gemini RESPONSE]
        If an API key were provided, I would have contacted Google Gemini.
        For your prompt: "$(prompt)", a possible answer could be:
        "This is a mock response from the Google Gemini integration. Please configure your GOOGLE_API_KEY."
        """
    end

    model = get(cfg, "model", "gemini-1.5-flash-latest") # Default Gemini model
    # Gemini API has specific parameters for generationConfig
    generation_config = Dict{String, Any}(
        "temperature" => get(cfg, "temperature", 0.7),
        "maxOutputTokens" => get(cfg, "max_tokens", 1024) # Maps to maxOutputTokens
        # "topP" => get(cfg, "top_p", 0.95),
        # "topK" => get(cfg, "top_k", 40)
    )
    # Filter out any nil values from generation_config if API is strict
    filter!((k,v) -> !isnothing(v), generation_config)


    # System prompt handling for Gemini is typically done by structuring "contents"
    # with alternating user/model roles, or by providing a specific systemInstruction field if available for the model.
    # For basic chat, we send a single user prompt.
    system_prompt_content = get(cfg, "system_prompt", "")
    
    gemini_api_base = get(cfg, "api_base", "https://generativelanguage.googleapis.com/v1beta/models")
    # Note: API key is part of the URL for Gemini's generateContent endpoint
    chat_endpoint = "$gemini_api_base/$model:generateContent?key=$api_key"

    headers = Dict("Content-Type" => "application/json")

    # Construct contents payload
    # Gemini expects a list of "Content" objects, each with "parts" and "role" (optional for single turn user)
    contents = []
    if !isempty(system_prompt_content)
        # A common way to handle system prompts if not directly supported is to prepend
        # or use a specific "system" role if the model/API version supports it.
        # For Gemini, a multi-turn context can be built in `contents`.
        # For a simple system prompt, it might be part of the first user message or a separate instruction.
        # The `system_instruction` field is available for some models/versions.
        # For now, let's assume a simple user prompt, system_prompt might need specific handling.
        # If `system_instruction` is a top-level parameter in the payload:
        # payload["system_instruction"] = Dict("parts" => [Dict("text" => system_prompt_content)])
        # Or, if it's part of contents:
        # push!(contents, Dict("role" => "system", "parts" => [Dict("text" => system_prompt_content)]))
        # For simplicity, we'll just use the user prompt for now.
        # A more robust implementation would check Gemini API docs for current best practice on system prompts.
        # Let's assume for now, if system_prompt is there, we make it the first "user" turn, then the actual prompt.
        # This is not ideal. Gemini's API is more nuanced.
        # A better approach for system instructions with gemini-1.5-flash-latest:
        # payload["systemInstruction"] = Dict("parts" => [Dict("text" => system_prompt_content)])
        # Then contents would just be the user prompt.
        # Let's try to use systemInstruction if present.
    end
    push!(contents, Dict("parts" => [Dict("text" => prompt)])) # User's main prompt

    payload = Dict{String, Any}(
        "contents" => contents,
        "generationConfig" => generation_config
    )
    if !isempty(system_prompt_content) # Add system_instruction if provided
        payload["systemInstruction"] = Dict("parts" => [Dict("text" => system_prompt_content)])
    end


    json_payload = JSON3.write(payload)
    @debug "Sending request to Google Gemini" endpoint=chat_endpoint model=model
    try
        response = HTTP.post(chat_endpoint, headers, json_payload; readtimeout=get(cfg, "request_timeout_seconds", 120)) # Gemini can be slower
        response_body_str = String(response.body)
        @debug "Google Gemini Response Status: $(response.status)"

        if response.status == 200
            json_response = JSON3.read(response_body_str)
            # Gemini response structure: json_response.candidates[1].content.parts[1].text
            if haskey(json_response, "candidates") && !isempty(json_response.candidates) &&
               haskey(json_response.candidates[1], "content") && haskey(json_response.candidates[1].content, "parts") &&
               !isempty(json_response.candidates[1].content.parts) && haskey(json_response.candidates[1].content.parts[1], "text")
                return json_response.candidates[1].content.parts[1].text
            elseif haskey(json_response, "promptFeedback") && haskey(json_response.promptFeedback, "blockReason")
                block_reason = json_response.promptFeedback.blockReason
                block_message = get(json_response.promptFeedback, "blockReasonMessage", "")
                @error "Google Gemini prompt blocked" reason=block_reason message=block_message
                return "[LLM ERROR: Google Gemini prompt blocked - $block_reason. $block_message]"
            else
                @error "Google Gemini response format error." full_response=json_response
                return "[LLM ERROR: Google Gemini response format error]"
            end
        else
            @error "Google Gemini API request failed" status=response.status response_body=response_body_str
            error_details = response_body_str
            try
                json_error = JSON3.read(response_body_str)
                if haskey(json_error, "error") && haskey(json_error.error, "message")
                    error_details = json_error.error.message
                end
            catch end
            return "[LLM ERROR: Google Gemini API Status $(response.status) - $(error_details)]"
        end
    catch e
        @error "Exception during Google Gemini API call" exception=(e, catch_backtrace())
        return "[LLM ERROR: Exception - $(string(e))]"
    end
end

function chat(llm::EchoLLMIntegration, prompt::String; cfg::Dict)
    @debug "Using Echo LLM integration."
    return "[LLM disabled/echo] Echo: " * prompt
end


# --- Provider Status Check Functions ---

"""
    get_provider_status(llm::AbstractLLMIntegration, cfg::Dict)::Dict{String, Any}

Generic fallback for provider status. Concrete types should implement this.
"""
function get_provider_status(llm::AbstractLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_type = string(typeof(llm))
    return Dict("provider" => provider_type, "status" => "unknown", "message" => "Status check not implemented for $provider_type.")
end

function get_provider_status(llm::OpenAILLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "OpenAI"
    api_key = get(ENV, "OPENAI_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "OpenAI API key not found.")
    end

    openai_api_base = get(cfg, "api_base", "https://api.openai.com/v1")
    models_endpoint = "$openai_api_base/models"
    headers = Dict("Authorization" => "Bearer $api_key")

    try
        response = HTTP.get(models_endpoint, headers; readtimeout=get(cfg, "status_check_timeout_seconds", 10))
        if response.status == 200
            # Optionally parse response.data to list some models or confirm structure
            return Dict("provider" => provider_name, "status" => "ok", "message" => "Successfully connected and listed models.")
        else
            return Dict("provider" => provider_name, "status" => "error", "message" => "API request to list models failed with status $(response.status).", "details" => String(response.body))
        end
    catch e
        return Dict("provider" => provider_name, "status" => "error", "message" => "Exception during OpenAI status check: $(string(e))")
    end
end

function get_provider_status(llm::AnthropicLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "Anthropic"
    api_key = get(ENV, "ANTHROPIC_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "Anthropic API key not found.")
    end
    # Anthropic doesn't have a simple free "ping" or "list models" endpoint.
    # A successful small chat request would confirm, but that costs tokens.
    # For now, if key is present, assume "configured".
    return Dict("provider" => provider_name, "status" => "configured", "message" => "Anthropic API key is present. Full connectivity test requires a chat request.")
end

function get_provider_status(llm::LlamaLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "Llama (Custom Endpoint)"
    endpoint_url = get(cfg, "endpoint_url", get(ENV, "LLAMA_ENDPOINT_URL", ""))
    if isempty(endpoint_url)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "Llama endpoint URL not found.")
    end
    # For custom endpoints, a simple HTTP GET or OPTIONS request might suffice as a health check if the endpoint supports it.
    # This is highly dependent on the specific Llama hosting.
    # For now, if endpoint_url is set, consider it "configured".
    # A real check might try HTTP.request("HEAD", endpoint_url) or similar.
    try
        # Attempt a HEAD request as a basic connectivity check
        response = HTTP.request("HEAD", endpoint_url; readtimeout=get(cfg, "status_check_timeout_seconds", 10))
        if response.status >= 200 && response.status < 400 # Broad success range
            return Dict("provider" => provider_name, "status" => "ok", "endpoint" => endpoint_url, "message" => "Endpoint reachable (HEAD request successful with status $(response.status)).")
        else
            return Dict("provider" => provider_name, "status" => "error", "endpoint" => endpoint_url, "message" => "Endpoint check (HEAD request) failed with status $(response.status).")
        end
    catch e
        return Dict("provider" => provider_name, "status" => "error", "endpoint" => endpoint_url, "message" => "Exception during Llama endpoint status check: $(string(e))")
    end
end

# Similar simplified status checks for Mistral, Cohere, Gemini
function get_provider_status(llm::MistralLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "Mistral"
    api_key = get(ENV, "MISTRAL_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "Mistral API key not found.")
    end
    # Could try /v1/models like OpenAI if Mistral supports it and it's a lightweight check.
    # For now, "configured" if key is present.
    return Dict("provider" => provider_name, "status" => "configured", "message" => "Mistral API key is present. Full connectivity test requires a chat/models request.")
end

function get_provider_status(llm::CohereLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "Cohere"
    api_key = get(ENV, "COHERE_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "Cohere API key not found.")
    end
    return Dict("provider" => provider_name, "status" => "configured", "message" => "Cohere API key is present. Full connectivity test requires an API request.")
end

function get_provider_status(llm::GeminiLLMIntegration, cfg::Dict)::Dict{String, Any}
    provider_name = "Google Gemini"
    api_key = get(ENV, "GOOGLE_API_KEY", get(cfg, "api_key", ""))
    if isempty(api_key)
        return Dict("provider" => provider_name, "status" => "misconfigured", "message" => "Google (Gemini) API key not found.")
    end
    # Gemini's model listing is often `GET /v1beta/models?key=$API_KEY`
    # This could be a status check.
    model_to_check = get(cfg, "model", "gemini-1.5-flash-latest") # Use a configured model for the check
    gemini_api_base = get(cfg, "api_base", "https://generativelanguage.googleapis.com/v1beta/models")
    model_info_endpoint = "$gemini_api_base/$model_to_check?key=$api_key"
    headers = Dict("Content-Type" => "application/json")

    try
        response = HTTP.get(model_info_endpoint, headers; readtimeout=get(cfg, "status_check_timeout_seconds", 10))
        if response.status == 200
            return Dict("provider" => provider_name, "status" => "ok", "message" => "Successfully connected and fetched info for model '$model_to_check'.")
        else
            return Dict("provider" => provider_name, "status" => "error", "message" => "API request for model info failed with status $(response.status).", "details" => String(response.body))
        end
    catch e
        return Dict("provider" => provider_name, "status" => "error", "message" => "Exception during Gemini status check: $(string(e))")
    end
end

function get_provider_status(llm::EchoLLMIntegration, cfg::Dict)::Dict{String, Any}
    return Dict("provider" => "Echo", "status" => "active", "message" => "Echo LLM is always active (local echo).")
end


# --- Helper function to create the correct LLM integration instance ---
function create_llm_integration(config::Dict{String, Any})::Union{AbstractLLMIntegration, Nothing}
    provider = lowercase(get(config, "provider", "none"))
    if provider == "openai"; return OpenAILLMIntegration()
    elseif provider == "anthropic"; return AnthropicLLMIntegration()
    elseif provider == "llama"; return LlamaLLMIntegration()
    elseif provider == "mistral"; return MistralLLMIntegration()
    elseif provider == "cohere"; return CohereLLMIntegration()
    elseif provider == "gemini"; return GeminiLLMIntegration()
    elseif provider == "echo"; return EchoLLMIntegration()
    elseif provider == "none" || isempty(provider); return nothing
    else
        @warn "Unknown LLM provider '$provider'. No LLM integration created."
        return nothing
    end
end

# --- Placeholder for Advanced LLM Features ---
# ... (select_model, apply_prompt_template, etc. remain as conceptual placeholders) ...

end # module LLMIntegration
