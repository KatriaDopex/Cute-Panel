# julia/src/api/BlockchainHandlers.jl
module BlockchainHandlers

using HTTP, Logging, Dates
using ..Utils # For standardized responses
import ..framework.CutePanelFramework.Blockchain # Main Blockchain module

function connect_handler(req::HTTP.Request)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    network_name = get(query_params, "network", "ethereum")
    endpoint_url = get(query_params, "endpoint_url", nothing) # Allow overriding default from config

    try
        connection_status = Blockchain.connect(network=network_name, endpoint_url=endpoint_url)
        if connection_status["connected"]
            return Utils.json_response(connection_status)
        else
            err_msg = get(connection_status, "error", "Failed to connect to network '$network_name'")
            return Utils.error_response(err_msg, 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=connection_status)
        end
    catch e
        @error "Error in connect_handler for network $network_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to connect to network '$network_name': $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_balance_handler(req::HTTP.Request, network::String, address::String)
    if isempty(network) || isempty(address)
        return Utils.error_response("Network and address parameters cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["network", "address"]))
    end
    
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)

    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get balance.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end

        balance = Blockchain.get_balance_generic(address, conn_dict)
        
        # Determine currency unit based on network (simplified)
        unit = if network == "solana" "SOL"
               elseif network in ["ethereum", "polygon", "arbitrum", "optimism", "base", "avalanche", "bsc", "fantom"] "ETH_LIKE" # Native currency of EVM chain
               else "UNKNOWN_NATIVE_CURRENCY"
               end

        return Utils.json_response(Dict("network"=>network, "address"=>address, "balance"=>balance, "unit"=>unit))
    catch e
        @error "Error in get_balance_handler for $network, $address" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get balance for $address on $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_token_balance_handler(req::HTTP.Request, network::String, wallet_address::String, token_address::String)
    if isempty(network) || isempty(wallet_address) || isempty(token_address)
        return Utils.error_response("Network, wallet_address, and token_address parameters cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["network", "wallet_address", "token_address"]))
    end
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)

    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get token balance.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end

        balance = Blockchain.get_token_balance_generic(wallet_address, token_address, conn_dict)
        # TODO: Could try to fetch token symbol using get_decimals_generic and another call if needed for response
        return Utils.json_response(Dict("network"=>network, "wallet_address"=>wallet_address, "token_address"=>token_address, "balance"=>balance))
    catch e
        @error "Error in get_token_balance_handler for $network, wallet $wallet_address, token $token_address" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get token balance: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# TODO: Add handlers for other Blockchain.jl functions:
# - get_transaction_receipt_generic
# - send_raw_transaction_generic (requires careful security considerations for private keys if signing is involved)

function get_chain_id_handler(req::HTTP.Request, network::String)
    if isempty(network)
        return Utils.error_response("Network parameter cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"network"))
    end
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get chain ID.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        chain_id = Blockchain.get_chain_id_generic(conn_dict)
        return Utils.json_response(Dict("network"=>network, "chain_id"=>chain_id))
    catch e
        @error "Error in get_chain_id_handler for $network" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get chain ID for $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_gas_price_handler(req::HTTP.Request, network::String)
    if isempty(network)
        return Utils.error_response("Network parameter cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"network"))
    end
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get gas price.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        gas_price = Blockchain.get_gas_price_generic(conn_dict)
        unit = network == "solana" ? "SOL_PER_SIGNATURE" : "GWEI" # Simplified unit
        return Utils.json_response(Dict("network"=>network, "gas_price"=>gas_price, "unit"=>unit))
    catch e
        @error "Error in get_gas_price_handler for $network" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get gas price for $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_transaction_count_handler(req::HTTP.Request, network::String, address::String)
    if isempty(network) || isempty(address)
        return Utils.error_response("Network and address parameters cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["network", "address"]))
    end
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    block_tag = get(query_params, "block_tag", "latest")
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get transaction count.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        nonce = Blockchain.get_transaction_count_generic(address, conn_dict, block_tag=block_tag)
        if nonce == -1 # Error indicator from underlying function
             return Utils.error_response("Failed to retrieve transaction count for $address on $network.", 500, error_code="CHAIN_RPC_ERROR")
        end
        return Utils.json_response(Dict("network"=>network, "address"=>address, "nonce"=>nonce, "block_tag"=>block_tag))
    catch e
        @error "Error in get_transaction_count_handler for $network, $address" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get transaction count for $address on $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function estimate_gas_handler(req::HTTP.Request, network::String)
    if isempty(network)
        return Utils.error_response("Network parameter cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"network"))
    end
    
    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a valid JSON object containing transaction parameters.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    # Ensure tx_params are strings as expected by some RPCs, especially hex values
    tx_params = Dict{String, String}(string(k) => string(v) for (k,v) in body)


    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to estimate gas.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        
        estimated_gas = Blockchain.estimate_gas_generic(tx_params, conn_dict)
        if estimated_gas == -1 # Error indicator
            return Utils.error_response("Failed to estimate gas on $network. Transaction may be invalid or revert.", 400, error_code="GAS_ESTIMATION_FAILED", details=tx_params)
        end
        return Utils.json_response(Dict("network"=>network, "estimated_gas"=>estimated_gas, "tx_params_received"=>tx_params))
    catch e
        @error "Error in estimate_gas_handler for $network" exception=(e, catch_backtrace())
        # Check if error message indicates a revert, which is common for estimateGas
        if occursin("revert", lowercase(sprint(showerror, e))) || occursin("execution reverted", lowercase(sprint(showerror, e)))
            return Utils.error_response("Gas estimation failed: Transaction likely to revert. $(sprint(showerror, e))", 400, error_code="TRANSACTION_REVERT", details=tx_params)
        end
        return Utils.error_response("Failed to estimate gas on $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function eth_call_handler(req::HTTP.Request, network::String)
    if isempty(network)
        return Utils.error_response("Network parameter cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"network"))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict) || !haskey(body, "to") || !haskey(body, "data")
        return Utils.error_response("Request body must be a JSON object with 'to' and 'data' fields.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    to_address = get(body, "to", "")
    data_payload = get(body, "data", "")

    if isempty(to_address) || isempty(data_payload)
        return Utils.error_response("'to' and 'data' fields cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' for eth_call.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        
        result_hex = Blockchain.eth_call_generic(to_address, data_payload, conn_dict)
        return Utils.json_response(Dict("network"=>network, "to"=>to_address, "data_sent"=>data_payload, "result"=>result_hex))
    catch e
        @error "Error in eth_call_handler for $network" exception=(e, catch_backtrace())
        return Utils.error_response("eth_call failed on $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function send_raw_transaction_handler(req::HTTP.Request, network::String)
    if isempty(network)
        return Utils.error_response("Network parameter cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"network"))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict) || !haskey(body, "signed_tx_hex") || !isa(body["signed_tx_hex"], String) || isempty(body["signed_tx_hex"])
        return Utils.error_response("Request body must be a JSON object with a non-empty 'signed_tx_hex' field.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    signed_tx_hex = body["signed_tx_hex"]

    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to send transaction.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        
        tx_hash = Blockchain.send_raw_transaction_generic(signed_tx_hex, conn_dict)
        return Utils.json_response(Dict("network"=>network, "transaction_hash"=>tx_hash, "message"=>"Raw transaction sent successfully."))
    catch e
        @error "Error in send_raw_transaction_handler for $network" exception=(e, catch_backtrace())
        # Check for specific RPC errors if possible (e.g., "nonce too low", "insufficient funds")
        return Utils.error_response("Failed to send raw transaction on $network: $(sprint(showerror, e))", 400, error_code="TRANSACTION_SEND_FAILED") # 400 for tx rejection
    end
end

function get_transaction_receipt_handler(req::HTTP.Request, network::String, tx_hash::String)
    if isempty(network) || isempty(tx_hash)
        return Utils.error_response("Network and transaction hash parameters cannot be empty.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["network", "tx_hash"]))
    end
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    endpoint_url = get(query_params, "endpoint_url", nothing)
    try
        conn_dict = Blockchain.connect(network=network, endpoint_url=endpoint_url)
        if !conn_dict["connected"]
            return Utils.error_response("Failed to connect to network '$network' to get transaction receipt.", 503, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR, details=conn_dict)
        end
        
        receipt = Blockchain.get_transaction_receipt_generic(tx_hash, conn_dict)
        if isnothing(receipt)
            # This can mean the transaction is pending, not found, or an error occurred that Blockchain.jl handled by returning nothing.
            # The underlying function logs errors for actual RPC failures.
            return Utils.json_response(Dict("network"=>network, "transaction_hash"=>tx_hash, "status"=>"pending_or_not_found", "receipt"=>nothing), 202) # 202 Accepted if pending
        end
        return Utils.json_response(Dict("network"=>network, "transaction_hash"=>tx_hash, "receipt"=>receipt))
    catch e
        @error "Error in get_transaction_receipt_handler for $network, $tx_hash" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get transaction receipt for $tx_hash on $network: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# The send_transaction_handler that relied on backend signing has been removed.
# All transactions requiring signing are expected to be signed client-side (TypeScript)
# and submitted via the /sendrawtransaction endpoint.

end # module BlockchainHandlers
