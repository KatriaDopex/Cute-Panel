"""
DEX.jl - Main module for Decentralized Exchange (DEX) integrations in CutePanel

This module provides a unified interface to various DEX protocols,
allowing for trading, liquidity management, and price discovery.
"""
module DEX

# Base types and interfaces
include("DEXBase.jl")
using .DEXBase
export AbstractDEX, DEXConfig, DEXOrder, DEXTrade, DEXPair, DEXToken # Re-export base types
export OrderType, OrderSide, OrderStatus, TradeStatus # Re-export enums
export get_price, get_liquidity, create_order, cancel_order, get_order_status # Re-export base functions
export get_trades, get_pairs, get_tokens, get_balance, get_trading_pairs

# Concrete Implementations
# Each DEX implementation should be in its own file and included here.
include("UniswapDEX.jl") # Assuming UniswapDEX.jl is in the same directory
using .UniswapDEX
export Uniswap, UniswapV2, UniswapV3, create_uniswap_dex # Re-export Uniswap specific items

# SushiSwap DEX implementation
include("SushiSwapDEX.jl")
using .SushiSwapDEX
export SushiSwapDEX, create_sushiswap_dex

"""
    create_sushiswap_dex(version::String, config::DEXConfig)::SushiSwapDEX

Factory function to create a SushiSwapDEX instance.
"""
function create_sushiswap_dex(version::String, config::DEXConfig)::SushiSwapDEX
    # You can add version-specific logic here if needed
    return SushiSwapDEX.SushiSwapDEX(config)
end

# --- Factory Function ---

"""
    create_dex_instance(protocol_name::String, version::String, config::DEXConfig)::AbstractDEX

Factory function to create a DEX instance based on the protocol name and version.
The `config` should contain protocol-specific details if needed.
The `config.name` field in DEXConfig can be used to identify specific instances.

# Arguments
- `protocol_name::String`: The name of the DEX protocol (e.g., "uniswap", "sushiswap").
- `version::String`: The protocol version (e.g., "v2", "v3").
- `config::DEXConfig`: The configuration for the DEX instance.

# Returns
- `AbstractDEX`: An instance of the specified DEX protocol and version.
"""
function create_dex_instance(protocol_name::String, version::String, config::DEXConfig)::AbstractDEX
    protocol_lower = lowercase(protocol_name)
    
    if protocol_lower == "uniswap"
        # Ensure the config name reflects Uniswap or use protocol_name to imply type
        if lowercase(config.name) != "uniswap" && !startswith(lowercase(config.name), "uniswap")
            @warn "DEXConfig name '$(config.name)' might not align with protocol '$protocol_name'. Proceeding based on protocol_name."
        end
        return UniswapDEX.create_uniswap_dex(version, config) # create_uniswap_dex is in UniswapDEX.jl
    elseif protocol_lower == "sushiswap"
        return SushiSwapDEX.create_sushiswap_dex(version, config)
    # Add other DEX protocols here
    else
        error("Unsupported DEX protocol: $protocol_name. Supported: uniswap, sushiswap, ...")
    end
end

"""
    list_available_dex_protocols()::Vector{String}

Lists the names of all DEX protocols for which an implementation exists.
"""
function list_available_dex_protocols()::Vector{String}
    # This list should be updated as new DEX integrations are implemented.
    return ["uniswap", "sushiswap"] # Add "curve", etc. as they are implemented
end

# No __init__ needed for DEX.jl itself, submodules handle their own if necessary.

end # module DEX
