"""
QuickSwapDEX.jl - QuickSwap DEX integration for CutePanel (Polygon)

Implements the AbstractDEX interface for QuickSwap, supporting multi-chain deployments (Polygon, etc.) using the DEXBase abstractions.
"""

module QuickSwapDEX

using ..DEXBase
import ..DEXBase: AbstractDEX, DEXConfig, DEXPair, DEXToken, DEXOrder, DEXTrade, OrderType, OrderSide, OrderStatus, TradeStatus
import ..DEXBase: get_price, get_liquidity, create_order, cancel_order, get_order_status, get_trades, get_pairs, get_tokens, get_balance

export QuickSwapDEX

"""
    QuickSwapDEX

Concrete type for QuickSwap DEX integration.
"""
mutable struct QuickSwapDEX <: AbstractDEX
    config::DEXConfig
end

# ========== Interface Implementations ==========

function get_price(dex::QuickSwapDEX, pair::DEXPair)::Float64
    pair_address = pair.id
    rpc_url = dex.config.rpc_url
    call_data = "0x0902f1ac"
    try
        quoted_hex = Blockchain.EthereumClient.eth_call_generic(pair_address, call_data, Dict("rpc_url" => rpc_url))
        decoded = Blockchain.EthereumClient.decode_function_result_abi(quoted_hex, ["uint112", "uint112", "uint32"])
        if length(decoded) < 2
            @warn "Failed to decode getReserves for QuickSwap pair $(pair_address)"
            return 0.0
        end
        reserve0 = Float64(decoded[1])
        reserve1 = Float64(decoded[2])
        if reserve0 == 0.0
            return 0.0
        end
        price = reserve1 / reserve0
        return price
    catch e
        @warn "Error fetching QuickSwap reserves for pair $(pair_address): $e"
        return 0.0
    end
end

function get_liquidity(dex::QuickSwapDEX, pair::DEXPair)::Tuple{Float64, Float64}
    pair_address = pair.id
    rpc_url = dex.config.rpc_url
    call_data = "0x0902f1ac"
    try
        quoted_hex = Blockchain.EthereumClient.eth_call_generic(pair_address, call_data, Dict("rpc_url" => rpc_url))
        decoded = Blockchain.EthereumClient.decode_function_result_abi(quoted_hex, ["uint112", "uint112", "uint32"])
        if length(decoded) < 2
            @warn "Failed to decode getReserves for QuickSwap pair $(pair_address)"
            return (0.0, 0.0)
        end
        reserve0 = Float64(decoded[1])
        reserve1 = Float64(decoded[2])
        return (reserve0, reserve1)
    catch e
        @warn "Error fetching QuickSwap reserves for pair $(pair_address): $e"
        return (0.0, 0.0)
    end
end

function create_order(dex::QuickSwapDEX, pair::DEXPair, order_type::OrderType,
                     side::OrderSide, amount::Float64, price::Float64=0.0)::DEXOrder
    using Dates
    if order_type != OrderType.MARKET
        error("Only MARKET orders are supported for QuickSwapDEX at this time.")
    end
    token_in = side == OrderSide.BUY ? pair.token1 : pair.token0
    token_out = side == OrderSide.BUY ? pair.token0 : pair.token1
    amount_in = round(Int, amount * 10.0^token_in.decimals)
    min_amount_out = 1
    router_address = dex.config.router_address
    wallet_address = dex.config.metadata["wallet_address"] if haskey(dex.config.metadata, "wallet_address") else ""
    private_key = dex.config.private_key
    swap_sig = "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
    path = [token_in.address, token_out.address]
    deadline = Int(time()) + 1800
    args = [
        (amount_in, "uint256"),
        (min_amount_out, "uint256"),
        (path, "address[]"),
        (wallet_address, "address"),
        (deadline, "uint256")
    ]
    call_data = Blockchain.EthereumClient.encode_function_call_abi(swap_sig, args)
    tx = Dict(
        "to" => router_address,
        "data" => call_data,
        "from" => wallet_address,
        "gas" => dex.config.gas_limit,
        "gasPrice" => Int(dex.config.gas_price * 1e9),
        "value" => 0
    )
    try
        tx_hash = Blockchain.EthereumClient.send_signed_transaction(tx, private_key, dex.config.rpc_url)
        order_id = tx_hash
        status = OrderStatus.PENDING
        timestamp = time()
        return DEXOrder(
            order_id,
            pair,
            order_type,
            side,
            amount,
            price,
            status,
            timestamp,
            tx_hash,
            Dict{String, Any}("tx" => tx)
        )
    catch e
        @warn "Error creating QuickSwap order: $e"
        return DEXOrder(
            "order_failed",
            pair,
            order_type,
            side,
            amount,
            price,
            OrderStatus.REJECTED,
            time(),
            "",
            Dict{String, Any}("error" => string(e))
        )
    end
end

function cancel_order(dex::QuickSwapDEX, order_id::String)::Bool
    error("cancel_order not implemented for QuickSwapDEX")
end

function get_order_status(dex::QuickSwapDEX, order_id::String)::DEXOrder
    error("get_order_status not implemented for QuickSwapDEX")
end

function get_trades(dex::QuickSwapDEX, pair::DEXPair; limit::Int=100, from_timestamp::Float64=0.0)::Vector{DEXTrade}
    pair_address = pair.id
    rpc_url = dex.config.rpc_url
    swap_event_topic = "0xd78ad95fa46c994b6551d0da85fc275fe613ce3761638c4a11628f55a4df523b"
    try
        logs = Blockchain.EthereumClient.eth_get_logs(
            pair_address,
            [swap_event_topic],
            Dict("rpc_url" => rpc_url, "limit" => limit)
        )
        trades = DEXTrade[]
        for log in logs
            decoded = Blockchain.EthereumClient.decode_log(
                log,
                [
                    ("address", "sender", true),
                    ("uint256", "amount0In", false),
                    ("uint256", "amount1In", false),
                    ("uint256", "amount0Out", false),
                    ("uint256", "amount1Out", false),
                    ("address", "to", true)
                ]
            )
            amount0in = Float64(decoded["amount0In"])
            amount1in = Float64(decoded["amount1In"])
            amount0out = Float64(decoded["amount0Out"])
            amount1out = Float64(decoded["amount1Out"])
            side = amount0in > 0 ? OrderSide.SELL : OrderSide.BUY
            amount = amount0in > 0 ? amount0in : amount1in
            price = amount0in > 0 && amount1out > 0 ? amount1out / amount0in : (amount1in > 0 && amount0out > 0 ? amount0out / amount1in : 0.0)
            trade = DEXTrade(
                log["transactionHash"],
                "",
                pair,
                side,
                amount,
                price,
                0.0,
                TradeStatus.CONFIRMED,
                Float64(log["timestamp"]),
                log["transactionHash"],
                Dict{String, Any}("raw_log" => log)
            )
            push!(trades, trade)
        end
        return trades
    catch e
        @warn "Error fetching QuickSwap trades for pair $(pair_address): $e"
        return DEXTrade[]
    end
end

function get_pairs(dex::QuickSwapDEX; limit::Int=100)::Vector{DEXPair}
    factory_address = dex.config.factory_address
    rpc_url = dex.config.rpc_url
    try
        call_data_len = "0x18160ddd"
        len_hex = Blockchain.EthereumClient.eth_call_generic(factory_address, call_data_len, Dict("rpc_url" => rpc_url))
        decoded_len = Blockchain.EthereumClient.decode_function_result_abi(len_hex, ["uint256"])
        num_pairs = Int(decoded_len[1])
        n = min(limit, num_pairs)
        pairs = DEXPair[]
        for i in 0:(n-1)
            call_data_pair = Blockchain.EthereumClient.encode_function_call_abi("allPairs(uint256)", [(i, "uint256")])
            pair_addr_hex = Blockchain.EthereumClient.eth_call_generic(factory_address, call_data_pair, Dict("rpc_url" => rpc_url))
            decoded_pair_addr = Blockchain.EthereumClient.decode_function_result_abi(pair_addr_hex, ["address"])
            pair_addr = decoded_pair_addr[1]
            call_data_token0 = "0x0dfe1681"
            call_data_token1 = "0xd21220a7"
            token0_addr_hex = Blockchain.EthereumClient.eth_call_generic(pair_addr, call_data_token0, Dict("rpc_url" => rpc_url))
            token1_addr_hex = Blockchain.EthereumClient.eth_call_generic(pair_addr, call_data_token1, Dict("rpc_url" => rpc_url))
            token0_addr = Blockchain.EthereumClient.decode_function_result_abi(token0_addr_hex, ["address"])[1]
            token1_addr = Blockchain.EthereumClient.decode_function_result_abi(token1_addr_hex, ["address"])[1]
            function get_token_meta(addr)
                symbol_hex = Blockchain.EthereumClient.eth_call_generic(addr, "0x95d89b41", Dict("rpc_url" => rpc_url))
                name_hex = Blockchain.EthereumClient.eth_call_generic(addr, "0x06fdde03", Dict("rpc_url" => rpc_url))
                decimals_hex = Blockchain.EthereumClient.eth_call_generic(addr, "0x313ce567", Dict("rpc_url" => rpc_url))
                symbol = try String(Blockchain.EthereumClient.decode_function_result_abi(symbol_hex, ["string"])[1]) catch _ "?" end
                name = try String(Blockchain.EthereumClient.decode_function_result_abi(name_hex, ["string"])[1]) catch _ "?" end
                decimals = try Int(Blockchain.EthereumClient.decode_function_result_abi(decimals_hex, ["uint8"])[1]) catch _ 18 end
                return DEXToken(addr, symbol, name, decimals, dex.config.chain_id)
            end
            token0 = get_token_meta(token0_addr)
            token1 = get_token_meta(token1_addr)
            fee = 0.003  # QuickSwap V2 fee is 0.3%
            protocol = "QuickSwap"
            pair_obj = DEXPair(pair_addr, token0, token1, fee, protocol)
            push!(pairs, pair_obj)
        end
        return pairs
    catch e
        @warn "Error fetching QuickSwap pairs: $e"
        return DEXPair[]
    end
end

function get_tokens(dex::QuickSwapDEX; limit::Int=100)::Vector{DEXToken}
    pairs = get_pairs(dex, limit=limit*2)
    token_map = Dict{String, DEXToken}()
    for pair in pairs
        if !haskey(token_map, pair.token0.address)
            token_map[pair.token0.address] = pair.token0
        end
        if !haskey(token_map, pair.token1.address)
            token_map[pair.token1.address] = pair.token1
        end
        if length(token_map) >= limit
            break
        end
    end
    return collect(values(token_map))[1:min(limit, length(token_map))]
end

function get_balance(dex::QuickSwapDEX, token::DEXToken; wallet_address::String="")::Float64
    rpc_url = dex.config.rpc_url
    address = wallet_address != "" ? wallet_address : (haskey(dex.config.metadata, "wallet_address") ? dex.config.metadata["wallet_address"] : "")
    if address == ""
        @warn "No wallet address provided for get_balance."
        return 0.0
    end
    padded_addr = lpad(replace(lowercase(address), "0x" => ""), 64, "0")
    call_data = "0x70a08231" * padded_addr
    try
        balance_hex = Blockchain.EthereumClient.eth_call_generic(token.address, call_data, Dict("rpc_url" => rpc_url))
        decoded = Blockchain.EthereumClient.decode_function_result_abi(balance_hex, ["uint256"])
        balance = Float64(decoded[1]) / 10.0^token.decimals
        return balance
    catch e
        @warn "Error fetching balance for token $(token.symbol) at $(token.address): $e"
        return 0.0
    end
end

# ========== Helper and Utility Functions ==========

function approve_token(dex::QuickSwapDEX, token::DEXToken, amount::Float64, wallet_address::String, private_key::String)::Bool
    rpc_url = dex.config.rpc_url
    router_address = dex.config.router_address
    amount_wei = round(Int, amount * 10.0^token.decimals)
    try
        tx_hash = Blockchain.EthereumClient.approve_erc20(token.address, router_address, amount_wei, wallet_address, private_key, rpc_url)
        return tx_hash != ""
    catch e
        @warn "Error approving token $(token.symbol): $e"
        return false
    end
end

function get_pair_address(dex::QuickSwapDEX, token0::DEXToken, token1::DEXToken)::String
    factory_address = dex.config.factory_address
    rpc_url = dex.config.rpc_url
    padded0 = lpad(replace(lowercase(token0.address), "0x" => ""), 64, "0")
    padded1 = lpad(replace(lowercase(token1.address), "0x" => ""), 64, "0")
    call_data = "0xe6a43905" * padded0 * padded1
    try
        pair_hex = Blockchain.EthereumClient.eth_call_generic(factory_address, call_data, Dict("rpc_url" => rpc_url))
        decoded = Blockchain.EthereumClient.decode_function_result_abi(pair_hex, ["address"])
        return decoded[1]
    catch e
        @warn "Error fetching pair address for $(token0.symbol)-$(token1.symbol): $e"
        return ""
    end
end

function get_token_metadata(dex::QuickSwapDEX, token_address::String)::DEXToken
    rpc_url = dex.config.rpc_url
    symbol_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x95d89b41", Dict("rpc_url" => rpc_url))
    name_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x06fdde03", Dict("rpc_url" => rpc_url))
    decimals_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x313ce567", Dict("rpc_url" => rpc_url))
    symbol = try String(Blockchain.EthereumClient.decode_function_result_abi(symbol_hex, ["string"])[1]) catch _ "?" end
    name = try String(Blockchain.EthereumClient.decode_function_result_abi(name_hex, ["string"])[1]) catch _ "?" end
    decimals = try Int(Blockchain.EthereumClient.decode_function_result_abi(decimals_hex, ["uint8"])[1]) catch _ 18 end
    return DEXToken(token_address, symbol, name, decimals, dex.config.chain_id)
end

get_fee(dex::QuickSwapDEX)::Float64 = 0.003
get_factory_address(dex::QuickSwapDEX)::String = dex.config.factory_address
get_router_address(dex::QuickSwapDEX)::String = dex.config.router_address

end # module QuickSwapDEX
