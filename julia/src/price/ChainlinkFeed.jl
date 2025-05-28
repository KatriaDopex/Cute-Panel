"""
ChainlinkFeed.jl - Chainlink price feed integration for CutePanel

This module provides integration with Chainlink price feeds by interacting
with Chainlink contracts on EVM-compatible blockchains.
"""
module ChainlinkFeed

using Dates, Logging, JSON3, HTTP
# Assuming PriceFeedBase.jl is in the same directory or correctly pathed by the parent PriceFeed.jl
using ..PriceFeedBase 
# Assuming Blockchain.jl (and its EthereumClient) is accessible for on-chain calls.
# This might require `using Main.CutePanelFramework.Blockchain` or similar if loaded by a central framework module.
# For now, direct relative path for a common structure. This needs careful review of actual module loading.
# Assuming Blockchain.jl is now correctly loaded via CutePanelFramework.jl and available in this scope.
import ...framework.CutePanelFramework.Blockchain # Access Blockchain via the framework
# EthereumClient might be needed for ABI encoding if not handled by Blockchain.jl directly
import ...framework.CutePanelFramework.EthereumClient 

export ChainlinkPriceFeed, create_chainlink_feed

# Default Chainlink feed registry (Mainnet Ethereum)
# Pair => (FeedAddress, DecimalsReturnedByFeedContract)
# Note: Most Chainlink feeds return 8 decimals for price, but some (like currency pairs against non-USD) might differ.
# The `decimals` field here refers to the decimals of the *price data itself* from the contract,
# not the decimals of the underlying assets.
const DEFAULT_CHAINLINK_FEEDS_MAINNET = Dict{String, Tuple{String, Int}}(
    "ETH/USD"  => ("0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419", 8),
    "BTC/USD"  => ("0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c", 8),
    "LINK/USD" => ("0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c", 8),
    "DAI/USD"  => ("0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9", 8), # DAI/USD might actually be 18 for price
    "USDC/USD" => ("0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", 8),
    "USDT/USD" => ("0x3E7d1eAB13ad0104d2750B8863b489D65364e32D", 8),
    "AAVE/USD" => ("0x547a514d5e3769680Ce22B2361c10Ea13619e8a9", 8),
    "UNI/USD"  => ("0x553303d460EE0afB37EdFf9bE42922D8FF63220e", 8),
    # Aliases
    "WETH/USD" => ("0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419", 8),
    # Example for a non-USD pair (ETH/BTC) - address and decimals would be specific
    # "ETH/BTC"  => ("0xDebXASAFDS...", 18), # Price of ETH in BTC, often 18 decimals
)
# TODO: Add registries for other networks (Polygon, Arbitrum, etc.)

"""
    ChainlinkPriceFeed <: AbstractPriceFeed

Structure representing a Chainlink price feed. It interacts with Chainlink contracts on an EVM chain.
"""
mutable struct ChainlinkPriceFeed <: AbstractPriceFeed
    config::PriceFeedConfig # Includes rpc_url, chain_id for the specific network
    # feed_registry: Dict{String, Tuple{String, Int}} # Pair "BASE/QUOTE" => (FeedAddress, PriceDecimalsFromFeed)
    # For simplicity, we'll use a pre-defined registry for now, but config could override/extend this.
    
    # Internal cache for price data to reduce RPC calls
    price_cache::Dict{String, Tuple{PricePoint, DateTime}} # "BASE/QUOTE" => (PricePoint, ExpiryTime)

    function ChainlinkPriceFeed(config::PriceFeedConfig)
        # TODO: Load feed registry based on config.chain_id or from config.metadata
        # For now, assumes mainnet if not specified or uses a default.
        new(config, Dict{String, Tuple{PricePoint, DateTime}}())
    end
end

function create_chainlink_feed(config::PriceFeedConfig)::ChainlinkPriceFeed
    return ChainlinkPriceFeed(config)
end

function _get_feed_details(feed::ChainlinkPriceFeed, base_asset::String, quote_asset::String)::Union{Tuple{String, Int}, Nothing}
    pair_key = uppercase("$(base_asset)/$(quote_asset)")
    # TODO: Use a dynamic registry based on feed.config.chain_id
    # For now, hardcoding mainnet.
    if feed.config.chain_id == 1 || isnothing(feed.config.chain_id) # Default to mainnet
        return get(DEFAULT_CHAINLINK_FEEDS_MAINNET, pair_key, nothing)
    else
        @warn "Chainlink feed registry not implemented for chain ID $(feed.config.chain_id). Pair $pair_key not found."
        return nothing
    end
end

# ===== Implementation of PriceFeedBase Interface =====

function PriceFeedBase.get_latest_price(feed::ChainlinkPriceFeed, base_asset::String, quote_asset::String)::PricePoint
    pair_key = uppercase("$(base_asset)/$(quote_asset)")

    # Check cache
    if haskey(feed.price_cache, pair_key)
        cached_price_point, expiry_time = feed.price_cache[pair_key]
        if now(UTC) < expiry_time
            @debug "Cache hit for $pair_key on Chainlink feed."
            return cached_price_point
        end
    end

    feed_details = _get_feed_details(feed, base_asset, quote_asset)
    if isnothing(feed_details)
        error("Chainlink feed for $pair_key not found in registry for chain ID $(feed.config.chain_id).")
    end
    feed_address, price_decimals = feed_details

    # Establish connection to the blockchain
    # The rpc_url and network name should be part of feed.config
    # For Chainlink, network name is usually derived from chain_id
    network_name = feed.config.chain_id == 1 ? "ethereum" : "unknown_chain_$(feed.config.chain_id)" # Simplification
    
    connection_params = Dict("network" => network_name, "endpoint" => feed.config.rpc_url)
    conn_details = Blockchain.connect(network=network_name, endpoint_url=feed.config.rpc_url)
    if !get(conn_details, "connected", false)
        error("Failed to connect to blockchain RPC for Chainlink feed: $(feed.config.rpc_url). Error: $(get(conn_details, "error", "Unknown connection error"))")
    end

    # Function signature for latestRoundData(): "latestRoundData()"
    # The refined `encode_function_call_abi` expects a Vector{Tuple{Any, String}} for args.
    # For no arguments, pass an empty vector of this type.
    data_payload = EthereumClient.encode_function_call_abi("latestRoundData()", Vector{Tuple{Any, String}}())
    
    hex_result = Blockchain.eth_call_generic(feed_address, data_payload, conn_details)

    if hex_result == "0x" || length(hex_result) < (2 + 5 * 64) # Expecting 5 uint256/int256/uint80 values
        @error "Invalid or empty response from Chainlink contract for $pair_key: $hex_result"
        # Fallback or error
        return PricePoint(now(UTC), -1.0) # Indicate error
    end
    
    # Decode the result using placeholder ABI decoder
    # latestRoundData() returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    # A real ABI decoder would parse types from the ABI definition.
    # For our placeholder, we provide type strings.
    output_abi_types = ["uint80", "int256", "uint256", "uint256", "uint80"]
    decoded_results = EthereumClient.decode_function_result_abi(hex_result, output_abi_types)

    if length(decoded_results) < 5
        @error "Failed to decode Chainlink response for $pair_key. Expected 5 results, got $(length(decoded_results)). Response: $hex_result"
        return PricePoint(now(UTC), -1.0, volume=-1.0) # Indicate error, perhaps with a specific error field
    end

    # roundId_val = decoded_results[1] # Should be BigInt
    answer_val = decoded_results[2]    # Should be BigInt (can be negative for some feeds, though not typical for price)
    # startedAt_val = decoded_results[3] # Should be BigInt
    updatedAt_unix = decoded_results[4] # Should be BigInt
    # answeredInRound_val = decoded_results[5] # Should be BigInt

    # Ensure types are as expected from decoder before arithmetic
    if !(isa(answer_val, BigInt) && isa(updatedAt_unix, BigInt))
        @error "Decoded Chainlink values have unexpected types. Answer: $(typeof(answer_val)), UpdatedAt: $(typeof(updatedAt_unix))"
        return PricePoint(now(UTC), -1.0, volume=-1.0) # Indicate error
    end

    price = Float64(answer_val) / (10^price_decimals)
    timestamp_dt = unix2datetime(Float64(updatedAt_unix))

    price_point = PricePoint(timestamp_dt, price) # volume, ohlc are default 0.0
    
    # Update cache
    cache_expiry = now(UTC) + Second(feed.config.cache_duration)
    feed.price_cache[pair_key] = (price_point, cache_expiry)
    
    return price_point
end

function PriceFeedBase.get_historical_prices(feed::ChainlinkPriceFeed, base_asset::String, quote_asset::String;
                                           interval::String="1d", limit::Int=100, 
                                           start_time::Union{DateTime, Nothing}=nothing,
                                           end_time::Union{DateTime, Nothing}=nothing)::PriceData
    
    @info "Fetching historical prices for $base_asset/$quote_asset from Chainlink feed $(feed.config.name)."
    @warn "Chainlink on-chain historical data is fetched by round, 'interval' param is informational. Result count determined by 'limit' and time filters."

    points = PricePoint[]
    pair_key = uppercase("$(base_asset)/$(quote_asset)")

    feed_details = _get_feed_details(feed, base_asset, quote_asset)
    if isnothing(feed_details)
        @error "Chainlink feed for $pair_key not found in registry for chain ID $(feed.config.chain_id)."
        return PriceData(uppercase(base_asset), uppercase(quote_asset), "Chainlink-"*feed.config.name, interval, points)
    end
    feed_address, price_decimals = feed_details

    network_name = feed.config.chain_id == 1 ? "ethereum" : "unknown_chain_$(feed.config.chain_id)"
    conn_details = Blockchain.connect(network=network_name, endpoint_url=feed.config.rpc_url)
    if !get(conn_details, "connected", false)
        @error "Failed to connect to blockchain RPC for Chainlink feed: $(feed.config.rpc_url)."
        return PriceData(uppercase(base_asset), uppercase(quote_asset), "Chainlink-"*feed.config.name, interval, points)
    end

    try
        # 1. Get latest round data to find the current roundId
        latest_round_data_payload = EthereumClient.encode_function_call_abi("latestRoundData()", Vector{Tuple{Any, String}}())
        latest_hex_result = Blockchain.eth_call_generic(feed_address, latest_round_data_payload, conn_details)
        
        output_abi_types_round_data = ["uint80", "int256", "uint256", "uint256", "uint80"]
        latest_decoded = EthereumClient.decode_function_result_abi(latest_hex_result, output_abi_types_round_data)

        if length(latest_decoded) < 5 || !isa(latest_decoded[1], BigInt)
            @error "Failed to decode latestRoundData or get current roundId for $pair_key."
            return PriceData(uppercase(base_asset), uppercase(quote_asset), "Chainlink-"*feed.config.name, interval, points)
        end
        current_round_id = latest_decoded[1]

        # 2. Iterate backwards for 'limit' rounds
        # Function signature for getRoundData(uint80): "getRoundData(uint80)"
        # Output types are the same as latestRoundData.
        
        for i in 0:(limit-1)
            round_to_fetch = current_round_id - BigInt(i)
            if round_to_fetch <= 0 break end # Stop if roundId becomes non-positive

            get_round_data_payload = EthereumClient.encode_function_call_abi("getRoundData(uint80)", [ (round_to_fetch, "uint80") ])
            hex_round_result = Blockchain.eth_call_generic(feed_address, get_round_data_payload, conn_details)
            
            decoded_round = EthereumClient.decode_function_result_abi(hex_round_result, output_abi_types_round_data)

            if length(decoded_round) >= 5 && isa(decoded_round[2], BigInt) && isa(decoded_round[4], BigInt)
                answer_val = decoded_round[2]
                updatedAt_unix = decoded_round[4]
                
                price_val = Float64(answer_val) / (10^price_decimals)
                timestamp_dt = unix2datetime(Float64(updatedAt_unix))

                # Apply time filters
                if !isnothing(start_time) && timestamp_dt < start_time continue end
                if !isnothing(end_time) && timestamp_dt > end_time continue end
                
                # Chainlink feeds typically don't provide OHLCV for individual rounds.
                # Price from `answer` is effectively the closing price for that round's update.
                push!(points, PricePoint(timestamp_dt, price_val, 
                                         open_price=price_val, high_price=price_val, 
                                         low_price=price_val, close_price=price_val))
            else
                @warn "Failed to decode or insufficient data for round $round_to_fetch for $pair_key. Skipping."
            end
        end
        
        # Sort points by timestamp ascending if they were collected out of order (though iterating backwards should maintain order)
        sort!(points, by = p -> p.timestamp)

    catch e
        @error "Error fetching historical Chainlink data for $pair_key" exception=(e, catch_backtrace())
    end
    
    return PriceData(uppercase(base_asset), uppercase(quote_asset), "Chainlink-"*feed.config.name, interval, points)
end

function PriceFeedBase.get_price_feed_info(feed::ChainlinkPriceFeed)::Dict{String, Any}
    return Dict(
        "provider_name" => "Chainlink",
        "config_name" => feed.config.name,
        "rpc_url" => feed.config.rpc_url,
        "chain_id" => feed.config.chain_id,
        "cache_duration_seconds" => feed.config.cache_duration,
        "supported_pairs_on_this_instance" => list_supported_pairs(feed) # Based on its internal registry
    )
end

function PriceFeedBase.list_supported_pairs(feed::ChainlinkPriceFeed)::Vector{Tuple{String, String}}
    # This should reflect the pairs available in the feed's specific registry for its chain_id
    # For now, using the hardcoded mainnet one as an example.
    registry = DEFAULT_CHAINLINK_FEEDS_MAINNET # Should be dynamic based on feed.config.chain_id
    
    supported = Vector{Tuple{String, String}}()
    for pair_str in keys(registry)
        parts = split(pair_str, "/")
        if length(parts) == 2
            push!(supported, (parts[1], parts[2]))
        end
    end
    return supported
end

end # module ChainlinkFeed
