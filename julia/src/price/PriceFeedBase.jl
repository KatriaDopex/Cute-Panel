"""
PriceFeedBase.jl - Base module for price feed integrations

This module provides the base types and interfaces for integrating with
price feeds and oracles in CutePanel.
"""
module PriceFeedBase

export AbstractPriceFeed, PriceFeedConfig, PriceData, PricePoint
export get_latest_price, get_historical_prices, get_price_feed_info, list_supported_pairs

using Dates

"""
    PricePoint

Structure representing a single price point.

# Fields
- `timestamp::DateTime`: The timestamp of the price point
- `price::Float64`: The price value
- `volume::Float64`: The trading volume (if available)
- `open::Float64`: The opening price (if available)
- `high::Float64`: The highest price (if available)
- `low::Float64`: The lowest price (if available)
- `close::Float64`: The closing price (if available)
"""
struct PricePoint
    timestamp::DateTime
    price::Float64
    volume::Float64    # Default to 0.0 if not applicable
    open::Float64      # Default to 0.0 or price if not applicable
    high::Float64      # Default to 0.0 or price
    low::Float64       # Default to 0.0 or price
    close::Float64     # Default to 0.0 or price
    
    function PricePoint(
        timestamp::DateTime,
        price::Float64;
        volume::Float64 = 0.0,
        open_price::Float64 = price, # Use 'open_price' to avoid conflict with 'open' function
        high_price::Float64 = price,
        low_price::Float64 = price,
        close_price::Float64 = price
    )
        new(timestamp, price, volume, open_price, high_price, low_price, close_price)
    end
end

"""
    PriceData

Structure representing a collection of price points.

# Fields
- `base_asset::String`: The base asset (e.g., "ETH")
- `quote_asset::String`: The quote asset (e.g., "USD")
- `source::String`: The source of the price data (e.g., "Chainlink", "Binance")
- `interval::String`: The interval of the price data (e.g., "1h", "1d")
- `points::Vector{PricePoint}`: The price points
"""
struct PriceData
    base_asset::String
    quote_asset::String
    source::String
    interval::String
    points::Vector{PricePoint}
end

"""
    PriceFeedConfig

Structure representing the configuration for a price feed.

# Fields
- `name::String`: The name of the price feed provider (e.g., "Chainlink")
- `api_key::String`: API key for the price feed (if applicable)
- `api_secret::String`: API secret for the price feed (if applicable)
- `base_url::String`: Base URL for the price feed API (if applicable for HTTP feeds)
- `rpc_url::String`: RPC URL if the feed is on-chain (e.g., for Chainlink direct contract reads)
- `chain_id::Int`: Chain ID if on-chain
- `timeout::Int`: Timeout in seconds for API calls or RPC requests
- `cache_duration::Int`: Duration in seconds to cache responses
- `metadata::Dict{String, Any}`: Additional provider-specific metadata
"""
struct PriceFeedConfig
    name::String
    api_key::String
    api_secret::String
    base_url::String
    rpc_url::String 
    chain_id::Union{Int, Nothing} # Can be nothing if not an on-chain feed
    timeout::Int
    cache_duration::Int # in seconds
    metadata::Dict{String, Any}
    
    function PriceFeedConfig(;
        name::String,
        api_key::String = "",
        api_secret::String = "",
        base_url::String = "",
        rpc_url::String = "",
        chain_id::Union{Int, Nothing} = nothing,
        timeout::Int = 30,
        cache_duration::Int = 60, # Cache for 1 minute by default
        metadata::Dict{String, Any} = Dict{String, Any}()
    )
        new(name, api_key, api_secret, base_url, rpc_url, chain_id, timeout, cache_duration, metadata)
    end
end

"""
    AbstractPriceFeed

Abstract type for price feed implementations. Concrete types must implement the interface methods.
"""
abstract type AbstractPriceFeed end

# ===== Interface Methods (to be implemented by concrete price feed types) =====

"""
    get_latest_price(feed::AbstractPriceFeed, base_asset::String, quote_asset::String)::PricePoint

Get the latest price for a trading pair.
"""
function get_latest_price(feed::AbstractPriceFeed, base_asset::String, quote_asset::String)::PricePoint
    error("get_latest_price not implemented for $(typeof(feed))")
end

"""
    get_historical_prices(feed::AbstractPriceFeed, base_asset::String, quote_asset::String;
                         interval::String="1d", limit::Int=100, 
                         start_time::Union{DateTime, Nothing}=nothing,
                         end_time::Union{DateTime, Nothing}=nothing)::PriceData

Get historical prices for a trading pair.
If `start_time` is provided, `limit` might be ignored or used as a cap.
If only `limit` is provided, it fetches the latest `limit` points for the interval.
"""
function get_historical_prices(feed::AbstractPriceFeed, base_asset::String, quote_asset::String;
                              interval::String="1d", limit::Int=100, 
                              start_time::Union{DateTime, Nothing}=nothing,
                              end_time::Union{DateTime, Nothing}=nothing)::PriceData
    error("get_historical_prices not implemented for $(typeof(feed))")
end

"""
    get_price_feed_info(feed::AbstractPriceFeed)::Dict{String, Any}

Get information about the price feed provider (e.g., supported assets, capabilities).
"""
function get_price_feed_info(feed::AbstractPriceFeed)::Dict{String, Any}
    error("get_price_feed_info not implemented for $(typeof(feed))")
end

"""
    list_supported_pairs(feed::AbstractPriceFeed)::Vector{Tuple{String, String}}

List all trading pairs supported by this price feed instance.
Returns a vector of tuples, where each tuple is (base_asset, quote_asset).
"""
function list_supported_pairs(feed::AbstractPriceFeed)::Vector{Tuple{String, String}}
    error("list_supported_pairs not implemented for $(typeof(feed))")
end

end # module PriceFeedBase
