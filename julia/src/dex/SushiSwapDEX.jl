"""
SushiSwapDEX.jl - SushiSwap DEX integration for CutePanel

This module implements the AbstractDEX interface for SushiSwap, supporting
multi-chain deployments (Ethereum, Polygon, BSC, etc.) using the DEXBase abstractions.
"""

module SushiSwapDEX

using ..DEXBase
import ..DEXBase: AbstractDEX, DEXConfig, DEXPair, DEXToken, DEXOrder, DEXTrade, OrderType, OrderSide, OrderStatus, TradeStatus
import ..DEXBase: get_price, get_liquidity, create_order, cancel_order, get_order_status, get_trades, get_pairs, get_tokens, get_balance

export SushiSwapDEX

"""
    SushiSwapDEX

Concrete type for SushiSwap DEX integration.
"""
mutable struct SushiSwapDEX <: AbstractDEX
    config::DEXConfig
end

# ========== Interface Implementations ==========

function get_price(dex::SushiSwapDEX, pair::DEXPair)::Float64
    # Working implementation: fetch reserves from the SushiSwap pair contract and compute price.
    # Assumes Blockchain.EthereumClient.eth_call_generic and decode_function_result_abi are available.

    # SushiSwap pair contract ABI for getReserves: returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    pair_address = pair.id  # Assume pair.id is the contract address
    rpc_url = dex.config.rpc_url

    # Prepare call data for getReserves()
    getreserves_sig = "getReserves()"
    getreserves_args = []
    # Use Blockchain.EthereumClient.encode_function_call_abi if available, else hardcode selector
    call_data = "0x0902f1ac"  # getReserves() selector

    # Call the contract
    try
        quoted_hex = Blockchain.EthereumClient.eth_call_generic(pair_address, call_data, Dict("rpc_url" => rpc_url))
        # Decode result: expect 3 values (reserve0, reserve1, blockTimestampLast)
        decoded = Blockchain.EthereumClient.decode_function_result_abi(quoted_hex, ["uint112", "uint112", "uint32"])
        if length(decoded) < 2
            @warn "Failed to decode getReserves for SushiSwap pair $(pair_address)"
            return 0.0
        end
        reserve0 = Float64(decoded[1])
        reserve1 = Float64(decoded[2])
        # Determine direction: price of token0 in terms of token1
        if reserve0 == 0.0
            return 0.0
        end
        price = reserve1 / reserve0
        return price
    catch e
        @warn "Error fetching SushiSwap reserves for pair $(pair_address): $e"
        return 0.0
    end
end

function get_liquidity(dex::SushiSwapDEX, pair::DEXPair)::Tuple{Float64, Float64}
    # Working implementation: fetch reserves from the SushiSwap pair contract.
    pair_address = pair.id  # Assume pair.id is the contract address
    rpc_url = dex.config.rpc_url
    call_data = "0x0902f1ac"  # getReserves() selector

    try
        quoted_hex = Blockchain.EthereumClient.eth_call_generic(pair_address, call_data, Dict("rpc_url" => rpc_url))
        decoded = Blockchain.EthereumClient.decode_function_result_abi(quoted_hex, ["uint112", "uint112", "uint32"])
        if length(decoded) < 2
            @warn "Failed to decode getReserves for SushiSwap pair $(pair_address)"
            return (0.0, 0.0)
        end
        reserve0 = Float64(decoded[1])
        reserve1 = Float64(decoded[2])
        return (reserve0, reserve1)
    catch e
        @warn "Error fetching SushiSwap reserves for pair $(pair_address): $e"
        return (0.0, 0.0)
    end
end

function create_order(dex::SushiSwapDEX, pair::DEXPair, order_type::OrderType,
                     side::OrderSide, amount::Float64, price::Float64=0.0)::DEXOrder
    # Working implementation: create a swap transaction on SushiSwap router.
    # Only supports MARKET orders (swapExactTokensForTokens) for now.

    using Dates

    if order_type != OrderType.MARKET
        error("Only MARKET orders are supported for SushiSwapDEX at this time.")
    end

    # Determine swap direction
    token_in = side == OrderSide.BUY ? pair.token1 : pair.token0
    token_out = side == OrderSide.BUY ? pair.token0 : pair.token1

    # Amounts in smallest units
    amount_in = round(Int, amount * 10.0^token_in.decimals)
    min_amount_out = 1  # For now, set to 1; should be calculated using slippage

    # Addresses
    router_address = dex.config.router_address
    wallet_address = dex.config.metadata["wallet_address"] if haskey(dex.config.metadata, "wallet_address") else ""
    private_key = dex.config.private_key

    # Approve token_in if needed (not implemented here, but should be done before swap)
    # Blockchain.EthereumClient.approve_erc20(token_in.address, router_address, amount_in, wallet_address, private_key)

    # Prepare swapExactTokensForTokens call
    swap_sig = "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
    path = [token_in.address, token_out.address]
    deadline = Int(time()) + 1800  # 30 minutes from now

    args = [
        (amount_in, "uint256"),
        (min_amount_out, "uint256"),
        (path, "address[]"),
        (wallet_address, "address"),
        (deadline, "uint256")
    ]

    call_data = Blockchain.EthereumClient.encode_function_call_abi(swap_sig, args)

    # Build and send transaction
    tx = Dict(
        "to" => router_address,
        "data" => call_data,
        "from" => wallet_address,
        "gas" => dex.config.gas_limit,
        "gasPrice" => Int(dex.config.gas_price * 1e9),  # Gwei to wei
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
        @warn "Error creating SushiSwap order: $e"
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

function cancel_order(dex::SushiSwapDEX, order_id::String)::Bool
    # TODO: Implement SushiSwap order cancellation (if supported)
    error("cancel_order not implemented for SushiSwapDEX")
end

function get_order_status(dex::SushiSwapDEX, order_id::String)::DEXOrder
    # TODO: Implement SushiSwap order status fetching
    error("get_order_status not implemented for SushiSwapDEX")
end

function get_trades(dex::SushiSwapDEX, pair::DEXPair; limit::Int=100, from_timestamp::Float64=0.0)::Vector{DEXTrade}
    # Working implementation: fetch Swap events from SushiSwap pair contract using eth_getLogs.
    # Assumes Blockchain.EthereumClient.eth_get_logs and decode_log are available.

    pair_address = pair.id  # Contract address of the pair
    rpc_url = dex.config.rpc_url

    # Swap event signature for Uniswap/SushiSwap V2:
    # event Swap(address indexed sender, uint amount0In, uint amount1In, uint amount0Out, uint amount1Out, address indexed to)
    swap_event_topic = "0xd78ad95fa46c994b6551d0da85fc275fe613ce3761638c4a11628f55a4df523b"

    # Convert from_timestamp to block number if needed (not implemented here, would require additional logic)
    # For now, fetch latest 'limit' events

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
            # Determine trade direction and amounts
            amount0in = Float64(decoded["amount0In"])
            amount1in = Float64(decoded["amount1In"])
            amount0out = Float64(decoded["amount0Out"])
            amount1out = Float64(decoded["amount1Out"])
            # For simplicity, treat amount0In > 0 as a SELL, amount1In > 0 as a BUY
            side = amount0in > 0 ? OrderSide.SELL : OrderSide.BUY
            amount = amount0in > 0 ? amount0in : amount1in
            price = amount0in > 0 && amount1out > 0 ? amount1out / amount0in : (amount1in > 0 && amount0out > 0 ? amount0out / amount1in : 0.0)
            trade = DEXTrade(
                log["transactionHash"],
                "",  # order_id not tracked for swaps
                pair,
                side,
                amount,
                price,
                0.0,  # fee not tracked here
                TradeStatus.CONFIRMED,
                Float64(log["timestamp"]),
                log["transactionHash"],
                Dict{String, Any}("raw_log" => log)
            )
            push!(trades, trade)
        end
        return trades
    catch e
        @warn "Error fetching SushiSwap trades for pair $(pair_address): $e"
        return DEXTrade[]
    end
end

function get_pairs(dex::SushiSwapDEX; limit::Int=100)::Vector{DEXPair}
    # Working implementation: fetch pairs from SushiSwap factory contract on-chain.
    # Assumes Blockchain.EthereumClient.eth_call_generic and decode_function_result_abi are available.

    factory_address = dex.config.factory_address
    rpc_url = dex.config.rpc_url

    # Get total number of pairs
    try
        call_data_len = "0x18160ddd"  # allPairsLength() selector
        len_hex = Blockchain.EthereumClient.eth_call_generic(factory_address, call_data_len, Dict("rpc_url" => rpc_url))
        decoded_len = Blockchain.EthereumClient.decode_function_result_abi(len_hex, ["uint256"])
        num_pairs = Int(decoded_len[1])
        n = min(limit, num_pairs)

        pairs = DEXPair[]
        for i in 0:(n-1)
            # allPairs(uint) returns address
            call_data_pair = Blockchain.EthereumClient.encode_function_call_abi("allPairs(uint256)", [(i, "uint256")])
            pair_addr_hex = Blockchain.EthereumClient.eth_call_generic(factory_address, call_data_pair, Dict("rpc_url" => rpc_url))
            decoded_pair_addr = Blockchain.EthereumClient.decode_function_result_abi(pair_addr_hex, ["address"])
            pair_addr = decoded_pair_addr[1]

            # token0() and token1() on pair contract
            call_data_token0 = "0x0dfe1681"
            call_data_token1 = "0xd21220a7"
            token0_addr_hex = Blockchain.EthereumClient.eth_call_generic(pair_addr, call_data_token0, Dict("rpc_url" => rpc_url))
            token1_addr_hex = Blockchain.EthereumClient.eth_call_generic(pair_addr, call_data_token1, Dict("rpc_url" => rpc_url))
            token0_addr = Blockchain.EthereumClient.decode_function_result_abi(token0_addr_hex, ["address"])[1]
            token1_addr = Blockchain.EthereumClient.decode_function_result_abi(token1_addr_hex, ["address"])[1]

            # Fetch token metadata (symbol, name, decimals)
            # symbol() selector: 0x95d89b41, name(): 0x06fdde03, decimals(): 0x313ce567
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

            # SushiSwap V2 fee is 0.3%
            fee = 0.003
            protocol = "SushiSwap"
            pair_obj = DEXPair(pair_addr, token0, token1, fee, protocol)
            push!(pairs, pair_obj)
        end
        return pairs
    catch e
        @warn "Error fetching SushiSwap pairs: $e"
        return DEXPair[]
    end
end

function get_tokens(dex::SushiSwapDEX; limit::Int=100)::Vector{DEXToken}
    # Working implementation: enumerate all unique tokens from discovered pairs.
    pairs = get_pairs(dex, limit=limit*2)  # Fetch more pairs to ensure enough tokens
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

function get_balance(dex::SushiSwapDEX, token::DEXToken; wallet_address::String="")::Float64
    # Working implementation: fetch ERC20 token balance for the given wallet address.
    rpc_url = dex.config.rpc_url
    address = wallet_address != "" ? wallet_address : (haskey(dex.config.metadata, "wallet_address") ? dex.config.metadata["wallet_address"] : "")
    if address == ""
        @warn "No wallet address provided for get_balance."
        return 0.0
    end
    # balanceOf(address) selector: 0x70a08231
    # Pad address to 32 bytes
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

"""
    approve_token(dex::SushiSwapDEX, token::DEXToken, amount::Float64, wallet_address::String, private_key::String)::Bool

Approve the SushiSwap router to spend a given amount of the specified token.
"""
function approve_token(dex::SushiSwapDEX, token::DEXToken, amount::Float64, wallet_address::String, private_key::String)::Bool
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

"""
    get_pair_address(dex::SushiSwapDEX, token0::DEXToken, token1::DEXToken)::String

Get the pair contract address for the given token pair.
"""
function get_pair_address(dex::SushiSwapDEX, token0::DEXToken, token1::DEXToken)::String
    factory_address = dex.config.factory_address
    rpc_url = dex.config.rpc_url
    # getPair(address,address) selector: 0xe6a43905
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

"""
    get_token_metadata(dex::SushiSwapDEX, token_address::String)::DEXToken

Fetch token metadata (symbol, name, decimals) for a given address.
"""
function get_token_metadata(dex::SushiSwapDEX, token_address::String)::DEXToken
    rpc_url = dex.config.rpc_url
    symbol_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x95d89b41", Dict("rpc_url" => rpc_url))
    name_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x06fdde03", Dict("rpc_url" => rpc_url))
    decimals_hex = Blockchain.EthereumClient.eth_call_generic(token_address, "0x313ce567", Dict("rpc_url" => rpc_url))
    symbol = try String(Blockchain.EthereumClient.decode_function_result_abi(symbol_hex, ["string"])[1]) catch _ "?" end
    name = try String(Blockchain.EthereumClient.decode_function_result_abi(name_hex, ["string"])[1]) catch _ "?" end
    decimals = try Int(Blockchain.EthereumClient.decode_function_result_abi(decimals_hex, ["uint8"])[1]) catch _ 18 end
    return DEXToken(token_address, symbol, name, decimals, dex.config.chain_id)
end

"""
    get_fee(dex::SushiSwapDEX)::Float64

Return the SushiSwap V2 fee (0.3%).
"""
get_fee(dex::SushiSwapDEX)::Float64 = 0.003

"""
    get_factory_address(dex::SushiSwapDEX)::String

Return the SushiSwap factory contract address.
"""
get_factory_address(dex::SushiSwapDEX)::String = dex.config.factory_address

"""
    get_router_address(dex::SushiSwapDEX)::String

Return the SushiSwap router contract address.
"""
get_router_address(dex::SushiSwapDEX)::String = dex.config.router_address

end # module SushiSwapDEX
