"""
Blockchain.jl - Core module for blockchain interactions in CutePanel.

Provides a unified interface for interacting with various blockchain networks,
including EVM-compatible chains and others like Solana.
"""
module Blockchain

using HTTP, JSON3, Dates, Base64, Printf, Logging

# Include the main application configuration module
try
    include("../config/config.jl") # Path from src/blockchain/ to config/
    MainAppConfig = Config # Alias the loaded Config module
    @info "Blockchain.jl: Successfully included main application config."
catch e
    @error "Blockchain.jl: Failed to include main application config. Will use internal defaults." exception=e
    # Define a fallback AppConfigModule if main config fails to load
    module MainAppConfig
        load() = nothing # Placeholder
        get_value(cfg, key, default) = default
    end
end

# Include submodules or specific client implementations
include("EthereumClient.jl") # Assuming EthereumClient.jl is in the same directory
# Wallet.jl is simplified and no longer directly used for signing by Blockchain.jl's core generic functions.
# If any utility from Wallet.jl (like address validation) were needed, it could be `using .Wallet`
# but for now, its primary role (dev wallet object) is not used by these generic functions.

# Re-export key functionalities from submodules if they are namespaced
using .EthereumClient 
# using .Wallet # Not strictly needed if Blockchain.jl doesn't use Wallet types/functions directly

export connect, get_balance, get_transaction_receipt_generic, is_node_healthy_generic
export get_chain_id_generic, get_gas_price_generic, get_token_balance_generic, send_raw_transaction_generic, eth_call_generic
export get_transaction_count_generic, estimate_gas_generic, get_decimals_generic
export SUPPORTED_CHAINS_CONFIG, get_rpc_endpoint, get_chain_name_from_id 

# Configuration for supported blockchain networks will be loaded from MainAppConfig

const SUPPORTED_CHAINS_CONFIG = Ref(Dict{String, Dict{String,Any}}()) # To be populated by _load_blockchain_config

function _load_blockchain_config()
    app_config = MainAppConfig.load() # Load the main application configuration
    
    if isnothing(app_config)
        @error "Blockchain.jl: Main application configuration could not be loaded. Using empty blockchain config."
        SUPPORTED_CHAINS_CONFIG[] = Dict{String, Dict{String,Any}}()
        return
    end

    # Get RPC URLs and supported chains from the loaded application config
    # The paths like "blockchain.rpc_urls" are based on the structure in julia/config/config.jl's DEFAULT_CONFIG
    rpc_urls_from_config = MainAppConfig.get_value(app_config, "blockchain.rpc_urls", Dict())
    supported_chains_list = MainAppConfig.get_value(app_config, "blockchain.supported_chains", []) # List of chain names

    loaded_config = Dict{String, Dict{String,Any}}()

    # Prioritize chains listed in "supported_chains" from config
    for chain_key_any in supported_chains_list
        chain_key = lowercase(string(chain_key_any)) # Ensure lowercase string
        
        # Get RPC URL: ENV variable > config file's rpc_urls section > hardcoded DEFAULT_RPC_URLS (as last resort)
        env_var_name = uppercase(chain_key) * "_RPC_URL"
        rpc_url = get(ENV, env_var_name, get(rpc_urls_from_config, chain_key, get(DEFAULT_RPC_URLS, chain_key, "")))

        if isempty(rpc_url)
            @warn "No RPC URL found for supported chain: $chain_key (checked ENV.$env_var_name, config.blockchain.rpc_urls.$chain_key, and internal defaults)."
            continue
        end
        
        # Chain ID mapping (can be expanded or made configurable, or fetched from node if possible)
        chain_id = if chain_key == "ethereum"; 1
                     elseif chain_key == "polygon"; 137
                     elseif chain_key == "arbitrum"; 42161
                     elseif chain_key == "optimism"; 10
                     elseif chain_key == "base"; 8453
                     elseif chain_key == "avalanche"; 43114
                     elseif chain_key == "bsc"; 56
                     elseif chain_key == "fantom"; 250
                     elseif chain_key == "solana"; -1 # Special value for Solana
                     else; 0 # Unknown or to be fetched
                     end
        
        loaded_config[chain_key] = Dict("rpc_url" => rpc_url, "chain_id" => chain_id, "name" => chain_key)
    end
    
    # Fallback for any chains in DEFAULT_RPC_URLS not covered by supported_chains_list (e.g. if supported_chains is empty)
    # This ensures some level of default functionality if config is minimal.
    if isempty(loaded_config) && !isempty(DEFAULT_RPC_URLS)
        @warn "blockchain.supported_chains list in config was empty or resulted in no valid configurations. Falling back to internal DEFAULT_RPC_URLS."
        for (chain_key, default_url) in DEFAULT_RPC_URLS
            if !haskey(loaded_config, chain_key) # Add only if not already processed
                env_var_name = uppercase(chain_key) * "_RPC_URL"
                rpc_url = get(ENV, env_var_name, default_url) # ENV still takes precedence over hardcoded default
                chain_id = if chain_key == "ethereum"; 1 elseif chain_key == "polygon"; 137 elseif chain_key == "solana"; -1 else 0 end # Simplified
                loaded_config[chain_key] = Dict("rpc_url" => rpc_url, "chain_id" => chain_id, "name" => chain_key)
            end
        end
    end

    SUPPORTED_CHAINS_CONFIG[] = loaded_config
    @info "Blockchain configuration initialized with $(length(SUPPORTED_CHAINS_CONFIG[])) chains from main application config and environment variables."
end

# Define DEFAULT_RPC_URLS here as a fallback if config system fails or is minimal
const DEFAULT_RPC_URLS = Dict(
    "ethereum" => "https://mainnet.infura.io/v3/YOUR_INFURA_KEY", # User should replace this
    "polygon"  => "https://polygon-rpc.com",
    "solana"   => "https://api.mainnet-beta.solana.com"
    # Add other common defaults if desired
)

function __init__()
    _load_blockchain_config() # Load config when module is initialized
end

function get_rpc_endpoint(network_name_or_id::Union{String, Int})::Union{String, Nothing}
    configs = SUPPORTED_CHAINS_CONFIG[]
    if isa(network_name_or_id, String)
        norm_name = lowercase(network_name_or_id)
        return haskey(configs, norm_name) ? configs[norm_name]["rpc_url"] : nothing
    elseif isa(network_name_or_id, Int) # Lookup by chain_id
        for (name, details) in configs
            if details["chain_id"] == network_name_or_id
                return details["rpc_url"]
            end
        end
        return nothing
    end
    return nothing
end

function get_chain_name_from_id(chain_id::Int)::Union{String, Nothing}
    configs = SUPPORTED_CHAINS_CONFIG[]
    for (name, details) in configs
        if details["chain_id"] == chain_id
            return name
        end
    end
    return nothing
end


"""
    connect(; network::String="ethereum", endpoint_url::Union{String,Nothing}=nothing)

Establishes and tests a connection to a specified blockchain network.
Returns a dictionary representing the connection state.
"""
function connect(; network::String="ethereum", endpoint_url::Union{String,Nothing}=nothing)
    norm_network_name = lowercase(network)
    
    final_endpoint_url = if !isnothing(endpoint_url)
        endpoint_url
    else
        get_rpc_endpoint(norm_network_name)
    end

    if isnothing(final_endpoint_url)
        @error "No RPC endpoint configured or found for network: $norm_network_name."
        return Dict("network" => norm_network_name, "endpoint" => nothing, "connected" => false, "error" => "RPC endpoint not configured")
    end

    is_healthy = is_node_healthy_generic(norm_network_name, final_endpoint_url)
    
    chain_id = -1 # Default for unknown or non-EVM
    if is_healthy && norm_network_name != "solana" # Solana doesn't have eth_chainId
        try
            # Attempt to get chain_id for EVM chains
            temp_conn_dict = Dict("network" => norm_network_name, "endpoint" => final_endpoint_url, "connected" => true)
            chain_id = get_chain_id_generic(temp_conn_dict)
        catch e
            @warn "Could not fetch chain_id for $norm_network_name via $final_endpoint_url" error=e
        end
    end

    return Dict(
        "network" => norm_network_name,
        "endpoint" => final_endpoint_url,
        "connected" => is_healthy,
        "chain_id_retrieved" => chain_id, # May differ from configured if endpoint is wrong
        "timestamp" => string(now(UTC))
    )
end

# Generic RPC request helper (primarily for EVM-like JSON-RPC)
function _make_generic_rpc_request(endpoint_url::String, method::String, params::AbstractArray)
    request_body = Dict(
        "jsonrpc" => "2.0",
        "id" => rand(UInt32),
        "method" => method,
        "params" => params
    )
    try
        response = HTTP.post(
            endpoint_url,
            ["Content-Type" => "application/json"],
            JSON3.write(request_body);
            timeout = 20 # Default timeout
        )
        response_json = JSON3.read(String(response.body))
        
        if haskey(response_json, "error")
            err_details = response_json.error
            err_msg = "RPC Error for method $method: $(get(err_details, "message", "Unknown RPC error")) (Code: $(get(err_details, "code", "N/A")))"
            @error err_msg full_error=err_details
            error(err_msg) # Throw an error to be caught by calling function
        end
        return response_json.result
    catch e
        @error "Generic RPC request failed for method $method to $endpoint_url" exception=(e, catch_backtrace())
        rethrow(e) # Propagate the exception
    end
end

# --- Generic Blockchain Interaction Functions ---
# These will delegate to chain-specific implementations or use generic JSON-RPC.

function is_node_healthy_generic(network_name::String, endpoint_url::String)::Bool
    try
        if network_name == "solana"
            # Solana-specific health check
            result = _make_generic_rpc_request(endpoint_url, "getHealth", [])
            return result == "ok"
        else # Assume EVM-compatible
            result = _make_generic_rpc_request(endpoint_url, "web3_clientVersion", [])
            return !isnothing(result) && !isempty(result)
        end
    catch e
        @warn "Node health check failed for $network_name at $endpoint_url" error=e
        return false
    end
end

function get_chain_id_generic(connection::Dict)::Int
    # `connection` is the Dict returned by `connect()`
    if !connection["connected"] error("Not connected to network: $(connection["network"])") end
    
    if connection["network"] == "solana"
        # Solana doesn't have a numeric chain ID in the EVM sense.
        # Mainnet-beta, Testnet, Devnet are identified by cluster URL or genesis hash.
        # We can return a conventional value or error.
        @warn "get_chain_id_generic: Solana does not use numeric chain IDs like EVM chains. Returning conventional -1."
        return -1 
    end
    # Assumes EVM chain
    hex_chain_id = _make_generic_rpc_request(connection["endpoint"], "eth_chainId", [])
    return parse(Int, hex_chain_id[3:end], base=16)
end


function get_balance_generic(address::String, connection::Dict)::Float64
    if !connection["connected"] error("Not connected to network: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]

    try
        if network == "solana"
            result = _make_generic_rpc_request(endpoint, "getBalance", [address])
            balance_lamports = result["value"] # result is Dict("context"=>..., "value"=>...)
            return balance_lamports / 1_000_000_000 # Lamports to SOL
        else # Assume EVM
            hex_result = _make_generic_rpc_request(endpoint, "eth_getBalance", [address, "latest"])
            balance_wei = parse(BigInt, hex_result[3:end], base=16)
            return Float64(balance_wei / BigInt(10)^18) # Wei to Ether
        end
    catch e
        @error "Error getting balance for $address on $network" error=e
        return 0.0 # Fallback
    end
end

function get_token_balance_generic(wallet_address::String, token_contract_address::String, connection::Dict)::Float64
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]

    try
        if network == "solana"
            # SPL Token Balance for Solana
            # This requires knowing the token's mint address and the associated token account for the wallet.
            # A common approach is to use `getTokenAccountsByOwner` then find the one for the mint.
            # This is a simplified placeholder.
            @warn "get_token_balance_generic for Solana SPL tokens is a complex placeholder."
            # params = [wallet_address, Dict("mint" => token_contract_address), Dict("encoding" => "jsonParsed")]
            # result = _make_generic_rpc_request(endpoint, "getTokenAccountsByOwner", params)
            # if !isempty(result["value"]) ... parse result ... end
            return 0.0 # Placeholder
        else # Assume EVM ERC20
            # ERC20 balanceOf(address) function signature: 0x70a08231
            padded_address = lpad(wallet_address[3:end], 64, '0') # Remove 0x and pad
            data = "0x70a08231" * padded_address
            
            hex_balance = eth_call_generic(token_contract_address, data, connection)
            balance_smallest_unit = parse(BigInt, hex_balance[3:end], base=16)
            
            # Get token decimals
            token_decimals = get_decimals_generic(token_contract_address, connection)
            return Float64(balance_smallest_unit / BigInt(10)^token_decimals)
        end
    catch e
        @error "Error getting token balance for $wallet_address, token $token_contract_address on $network" error=e
        return 0.0
    end
end

function get_decimals_generic(token_contract_address::String, connection::Dict)::Int
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    # ERC20 decimals() function signature: 0x313ce567
    data = "0x313ce567"
    hex_result = eth_call_generic(token_contract_address, data, connection)
    if hex_result == "0x" || isempty(hex_result) || length(hex_result) <=2
        @warn "get_decimals_generic eth_call returned empty/invalid result for $token_contract_address on $(connection["network"]). Assuming 18."
        return 18 # Common default, but risky
    end
    return parse(Int, hex_result[3:end], base=16)
end

function eth_call_generic(to_address::String, data::String, connection::Dict)
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    if !startswith(data, "0x") data = "0x" * data end
    
    params = [Dict("to" => to_address, "data" => data), "latest"]
    return _make_generic_rpc_request(connection["endpoint"], "eth_call", params)
end

# --- Placeholders for other generic functions ---

function get_gas_price_generic(connection::Dict)::Float64
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]
    try
        if network == "solana"
            # Solana uses a different fee mechanism (lamports per signature, priority fees)
            # This is a simplification; real fee estimation is more complex.
            # getRecentPrioritizationFees can be used for priority fees.
            # getFees for base fee.
            result = _make_generic_rpc_request(endpoint, "getFees", [])
            # Example: result.value.feeCalculator.lamportsPerSignature
            return get(get(get(result,"value",Dict()),"feeCalculator",Dict()),"lamportsPerSignature", 5000) / 1_000_000_000 # Convert to SOL
        else # Assume EVM
            hex_gas_price = _make_generic_rpc_request(endpoint, "eth_gasPrice", [])
            gas_price_wei = parse(BigInt, hex_gas_price[3:end], base=16)
            return Float64(gas_price_wei / BigInt(10)^9) # Convert to Gwei
        end
    catch e
        @error "Error getting gas price for $network" error=e
        return 0.0 # Fallback
    end
end

function get_transaction_count_generic(address::String, connection::Dict; block_tag::String="latest")::Int
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]
    try
        if network == "solana"
            # Solana doesn't have a direct nonce concept like EVM.
            # Transaction ordering is based on recent blockhash and leader schedule.
            # For some operations, one might query account info for sequence numbers if applicable.
            @warn "get_transaction_count_generic: Solana does not use EVM-style nonces. Returning 0."
            return 0 
        else # Assume EVM
            hex_nonce = _make_generic_rpc_request(endpoint, "eth_getTransactionCount", [address, block_tag])
            return parse(Int, hex_nonce[3:end], base=16)
        end
    catch e
        @error "Error getting transaction count for $address on $network" error=e
        return -1 # Indicate error
    end
end

function estimate_gas_generic(tx_params::Dict, connection::Dict)::Int
    # tx_params for EVM: {"from": "0x...", "to": "0x...", "value": "0x...", "data": "0x..."}
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]
    try
        if network == "solana"
            # Solana gas/fee estimation is different. `getFeeForMessage` is used with a compiled message.
            # This is a highly simplified placeholder.
            @warn "estimate_gas_generic for Solana is a placeholder. Real fee estimation is complex."
            return 5000 # Placeholder compute units * some factor
        else # Assume EVM
            # Ensure essential fields for EVM estimateGas
            if !haskey(tx_params, "to") 
                error("Missing 'to' field in tx_params for EVM estimateGas")
            end
            # 'from' is optional for eth_estimateGas but often good to include if known
            # 'value' defaults to 0x0 if not present
            # 'data' defaults to 0x if not present
            call_obj = Dict{String, String}()
            for (k,v) in tx_params
                if k in ["from", "to", "value", "data", "gas", "gasPrice"] # Common fields
                    call_obj[k] = v
                end
            end

            hex_gas_estimate = _make_generic_rpc_request(endpoint, "eth_estimateGas", [call_obj])
            estimated_gas = parse(Int, hex_gas_estimate[3:end], base=16)
            # It's common to add a buffer to the estimate
            return Int(ceil(estimated_gas * 1.2)) 
        end
    catch e
        @error "Error estimating gas on $network" error=e tx_params=tx_params
        return -1 # Indicate error
    end
end

"""
function send_raw_transaction_generic(signed_tx_hex::String, connection::Dict)::String
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]
    try
        if network == "solana"
            # For Solana, signed_tx_hex is typically base64 encoded string of the serialized transaction
            # The RPC method is "sendTransaction"
            # params: [signed_tx_base64_string, {"encoding": "base64", "skipPreflight": false, "preflightCommitment": "confirmed"}]
            # This is a placeholder, actual encoding and params might vary.
            @warn "send_raw_transaction_generic for Solana: Ensure signed_tx_hex is base64 encoded."
            # Assuming signed_tx_hex is already base64 for Solana
            tx_hash = _make_generic_rpc_request(endpoint, "sendTransaction", [signed_tx_hex, Dict("encoding"=>"base64")])
            return tx_hash # Returns transaction signature
        else # Assume EVM
            if !startswith(signed_tx_hex, "0x")
                error("EVM signed transaction hex must start with 0x")
            end
            tx_hash = _make_generic_rpc_request(endpoint, "eth_sendRawTransaction", [signed_tx_hex])
            return tx_hash # Returns transaction hash
        end
    catch e
        @error "Error sending raw transaction on $network" error=e
        rethrow(e)
    end
end

function get_transaction_receipt_generic(tx_hash::String, connection::Dict)::Union{Dict, Nothing}
    if !connection["connected"] error("Not connected: $(connection["network"])") end
    network = connection["network"]
    endpoint = connection["endpoint"]
    try
        if network == "solana"
            # Solana uses "getTransaction" with specific configuration for verbosity
            # The structure of a Solana receipt (TransactionResponse) is very different from EVM.
            # params: [tx_hash_string, {"encoding": "jsonParsed", "maxSupportedTransactionVersion": 0, "commitment": "confirmed"}]
            @warn "get_transaction_receipt_generic for Solana: Response structure differs significantly from EVM."
            receipt = _make_generic_rpc_request(endpoint, "getTransaction", [tx_hash, "jsonParsed"]) # Or Dict for config
            return receipt # This will be a complex object
        else # Assume EVM
            receipt = _make_generic_rpc_request(endpoint, "eth_getTransactionReceipt", [tx_hash])
            return receipt # Can be nothing if tx is pending or not found
        end
    catch e
        # If RPC error indicates "not found" or similar, it might be valid for a pending/unknown tx.
        # For now, log and rethrow. Specific handling might be needed.
        @error "Error getting transaction receipt for $tx_hash on $network" error=e
        # Consider returning nothing or a specific error type instead of rethrowing for "not found" cases.
        if occursin("not found", lowercase(sprint(showerror, e))) # Basic check
            return nothing
        end
        rethrow(e)
    end
end


@info "Blockchain module (re)loaded with updated generic functions."

end # module Blockchain
