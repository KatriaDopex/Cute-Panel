"""
RaydiumDEX.jl - Raydium DEX integration for CutePanel (Solana, via Python FFI)

Implements the AbstractDEX interface for Raydium using PyCall.jl to call the Python client in
packages/pythonWrapper/src/cutepanel_wrapper/raydium_client.py.
"""

module RaydiumDEX

using ..DEXBase
using PyCall
const py_ray = pyimport("cutepanel_wrapper.raydium_client")

import ..DEXBase: AbstractDEX, DEXConfig, DEXPair, DEXToken, DEXOrder, DEXTrade, OrderType, OrderSide, OrderStatus, TradeStatus
import ..DEXBase: get_price, get_liquidity, create_order, cancel_order, get_order_status, get_trades, get_pairs, get_tokens, get_balance

export RaydiumDEX

mutable struct RaydiumDEX <: AbstractDEX
    config::DEXConfig
end

function get_price(dex::RaydiumDEX, pair::DEXPair)::Float64
    rpc_url = dex.config.rpc_url
    pool_address = pair.id
    return py_ray.get_price_from_pool(rpc_url, pool_address)
end

function get_liquidity(dex::RaydiumDEX, pair::DEXPair)::Tuple{Float64, Float64}
    rpc_url = dex.config.rpc_url
    pool_address = pair.id
    reserves = py_ray.get_pool_reserves(rpc_url, pool_address)
    return (Float64(reserves[1]), Float64(reserves[2]))
end

function get_pairs(dex::RaydiumDEX; limit::Int=100)::Vector{DEXPair}
    py_pairs = py_ray.get_pairs_from_raydium_api(limit)
    pairs = DEXPair[]
    for pool in py_pairs
        token0 = DEXToken(
            String(pool["token0"]["address"]),
            String(pool["token0"]["symbol"]),
            String(pool["token0"]["name"]),
            Int(pool["token0"]["decimals"]),
            dex.config.chain_id
        )
        token1 = DEXToken(
            String(pool["token1"]["address"]),
            String(pool["token1"]["symbol"]),
            String(pool["token1"]["name"]),
            Int(pool["token1"]["decimals"]),
            dex.config.chain_id
        )
        pair_obj = DEXPair(
            String(pool["pool_address"]),
            token0,
            token1,
            Float64(pool["fee"]),
            String(pool["protocol"])
        )
        push!(pairs, pair_obj)
    end
    return pairs
end

function get_tokens(dex::RaydiumDEX; limit::Int=100)::Vector{DEXToken}
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

function get_balance(dex::RaydiumDEX, token::DEXToken; wallet_address::String="")::Float64
    rpc_url = dex.config.rpc_url
    address = wallet_address != "" ? wallet_address : (haskey(dex.config.metadata, "wallet_address") ? dex.config.metadata["wallet_address"] : "")
    if address == ""
        @warn "No wallet address provided for get_balance."
        return 0.0
    end
    return py_ray.get_token_balance(rpc_url, address, token.address)
end

function get_trades(dex::RaydiumDEX, pair::DEXPair; limit::Int=100, from_timestamp::Float64=0.0)::Vector{DEXTrade}
    rpc_url = dex.config.rpc_url
    # Raydium pools are linked to Serum markets; for demo, use pool_address as market_address
    market_address = pair.id
    py_trades = py_ray.get_trade_history_from_serum(rpc_url, market_address, limit)
    trades = DEXTrade[]
    for t in py_trades
        side = t["side"] == "buy" ? OrderSide.BUY : OrderSide.SELL
        trade = DEXTrade(
            String(t["order_id"]),
            "",
            pair,
            side,
            Float64(t["size"]),
            Float64(t["price"]),
            0.0,
            TradeStatus.CONFIRMED,
            Float64(t["timestamp"]),
            String(t["order_id"]),
            Dict{String, Any}()
        )
        push!(trades, trade)
    end
    return trades
end

function create_order(dex::RaydiumDEX, pair::DEXPair, order_type::OrderType,
                     side::OrderSide, amount::Float64, price::Float64=0.0)::DEXOrder
    # TODO: Implement via Python FFI (requires wallet, signing, and Solana transaction logic)
    error("create_order not yet implemented for RaydiumDEX via FFI")
end

function cancel_order(dex::RaydiumDEX, order_id::String)::Bool
    error("cancel_order not implemented for RaydiumDEX")
end

function get_order_status(dex::RaydiumDEX, order_id::String)::DEXOrder
    error("get_order_status not implemented for RaydiumDEX")
end

function get_token_metadata(dex::RaydiumDEX, token_address::String)::DEXToken
    py_meta = py_ray.get_token_metadata_from_registry(token_address)
    return DEXToken(
        String(py_meta["address"]),
        String(py_meta["symbol"]),
        String(py_meta["name"]),
        Int(py_meta["decimals"]),
        dex.config.chain_id
    )
end

get_fee(dex::RaydiumDEX)::Float64 = 0.0025
get_program_id(dex::RaydiumDEX)::String = dex.config.metadata["program_id"] if haskey(dex.config.metadata, "program_id") else ""

end # module RaydiumDEX
