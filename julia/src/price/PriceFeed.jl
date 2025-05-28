"""
PriceFeed.jl - Main module for price feed integrations in CutePanel

This module provides a unified interface to various price feed sources,
both on-chain (e.g., Chainlink) and off-chain (e.g., CEX APIs).
"""
module PriceFeed

# Base types and interfaces
include("PriceFeedBase.jl")
using .PriceFeedBase
export AbstractPriceFeed, PriceFeedConfig, PriceData, PricePoint # Re-export base types
export get_latest_price, get_historical_prices, get_price_feed_info, list_supported_pairs # Re-export base functions

# Concrete Implementations
# Each implementation should be in its own file and included here.
# Example: Chainlink
include("ChainlinkFeed.jl") # Assuming ChainlinkFeed.jl is in the same directory
using .ChainlinkFeed
export ChainlinkPriceFeed, create_chainlink_feed # Re-export Chainlink specific items

# Placeholder for other price feed implementations (e.g., Binance, Coinbase, Pyth, etc.)
# include("BinanceFeed.jl")
# using .BinanceFeed
# export BinancePriceFeed, create_binance_feed

# --- Factory Function ---

"""
    create_price_feed(provider_name::String, config::PriceFeedConfig)::AbstractPriceFeed

Factory function to create a price feed instance based on the provider name.
The `config` should contain provider-specific details if needed, beyond general
fields like api_key, rpc_url, etc. The `config.name` field in PriceFeedConfig
should match the `provider_name` or be used by the concrete constructor.

# Arguments
- `provider_name::String`: The name of the price feed provider (e.g., "chainlink", "binance").
- `config::PriceFeedConfig`: The configuration for the price feed.

# Returns
- `AbstractPriceFeed`: An instance of the specified price feed provider.
"""
function create_price_feed(provider_name::String, config::PriceFeedConfig)::AbstractPriceFeed
    provider_lower = lowercase(provider_name)
    
    if provider_lower == "chainlink"
        # Ensure the config name matches, or use the provider_name to imply type
        if lowercase(config.name) != "chainlink"
            @warn "PriceFeedConfig name '$(config.name)' does not match provider '$provider_name'. Using '$provider_name'."
        end
        return ChainlinkFeed.create_chainlink_feed(config) # create_chainlink_feed is in ChainlinkFeed.jl
    # elseif provider_lower == "binance"
    #     return BinanceFeed.create_binance_feed(config)
    # Add other providers here
    else
        error("Unsupported price feed provider: $provider_name. Supported: chainlink, ...")
    end
end

"""
    list_available_price_feed_providers()::Vector{String}

Lists the names of all price feed providers for which an implementation exists.
"""
function list_available_price_feed_providers()::Vector{String}
    # This list should be updated as new providers are implemented.
    return ["chainlink"] # Add "binance", "coinbase", etc. as they are implemented
end

# No __init__ needed for PriceFeed itself, submodules handle their own if necessary.

end # module PriceFeed
