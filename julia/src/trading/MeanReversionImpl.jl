"""
MeanReversionImpl.jl - Implements mean reversion trading strategies.
"""
module MeanReversionImpl

using ..TradingStrategy # To subtype AbstractStrategy
# using ..PriceFeedBase
using Statistics, Logging, Dates

export MeanReversionStrategy, execute_strategy #, backtest_strategy

"""
    MeanReversionStrategy <: AbstractStrategy

A strategy that trades based on the assumption that asset prices revert to their mean.
It typically uses Bollinger Bands or similar statistical measures.
"""
struct MeanReversionStrategy <: AbstractStrategy
    name::String
    asset_pair::String # e.g., "ETH/USD"
    lookback_period::Int # For calculating mean and standard deviation
    std_dev_multiplier::Float64 # Number of std deviations for bands
    # price_data_source::AbstractPriceFeed
    # execution_context::AbstractDEX

    function MeanReversionStrategy(
        name::String,
        asset_pair::String;
        lookback_period::Int=20,
        std_dev_multiplier::Float64=2.0
        # price_data_source, execution_context
    )
        if lookback_period <= 1
            error("Lookback period must be greater than 1.")
        end
        if std_dev_multiplier <= 0
            error("Standard deviation multiplier must be positive.")
        end
        new(name, asset_pair, lookback_period, std_dev_multiplier) #, price_data_source, execution_context)
    end
end

"""
    _calculate_bollinger_bands(prices::Vector{Float64}, window::Int, std_dev_mult::Float64)
Helper to calculate Bollinger Bands: (Middle Band, Upper Band, Lower Band).
Returns NaNs for initial part where window is not full.
"""
function _calculate_bollinger_bands(prices::Vector{Float64}, window::Int, std_dev_mult::Float64)
    if length(prices) < window
        return (fill(NaN, length(prices)), fill(NaN, length(prices)), fill(NaN, length(prices)))
    end
    
    middle_band = Vector{Float64}(undef, length(prices))
    upper_band = Vector{Float64}(undef, length(prices))
    lower_band = Vector{Float64}(undef, length(prices))

    middle_band[1:window-1] .= NaN
    upper_band[1:window-1] .= NaN
    lower_band[1:window-1] .= NaN

    for i in window:length(prices)
        window_prices = prices[i-window+1:i]
        sma = mean(window_prices)
        std_dev = std(window_prices, corrected=false) # Population standard deviation for consistency
        
        middle_band[i] = sma
        upper_band[i] = sma + (std_dev_mult * std_dev)
        lower_band[i] = sma - (std_dev_mult * std_dev)
    end
    return middle_band, upper_band, lower_band
end


"""
    execute_strategy(strategy::MeanReversionStrategy, historical_prices::Vector{Float64})

Executes the mean reversion strategy based on provided historical prices.
Returns a trading signal ("BUY", "SELL", "HOLD_LONG", "HOLD_SHORT", "EXIT") and details.
"""
function TradingStrategy.execute_strategy(strategy::MeanReversionStrategy, historical_prices::Vector{Float64})
    @info "Executing MeanReversionStrategy: $(strategy.name) for $(strategy.asset_pair)"

    if length(historical_prices) < strategy.lookback_period
        @warn "Not enough historical price data (got $(length(historical_prices)), need $(strategy.lookback_period)) for MeanReversionStrategy."
        return Dict("signal"=>"HOLD", "reason"=>"Insufficient data", "details"=>nothing)
    end

    middle_band, upper_band, lower_band = _calculate_bollinger_bands(historical_prices, strategy.lookback_period, strategy.std_dev_multiplier)

    last_valid_idx = findlast(!isnan, middle_band)
    if isnothing(last_valid_idx)
        @warn "Could not compute valid Bollinger Bands for signal generation."
        return Dict("signal"=>"HOLD", "reason"=>"Band computation failed", "details"=>nothing)
    end

    current_price = historical_prices[last_valid_idx]
    current_middle = middle_band[last_valid_idx]
    current_upper = upper_band[last_valid_idx]
    current_lower = lower_band[last_valid_idx]

    signal = "HOLD" # Default, or could be HOLD_LONG/HOLD_SHORT if a position is open
    reason = "Price within bands."

    # Entry signals
    if current_price <= current_lower
        signal = "BUY" # Price touched or crossed below lower band - potential buy (revert to mean)
        reason = "Price ($(round(current_price, digits=2))) at or below Lower Band ($(round(current_lower, digits=2)))."
    elseif current_price >= current_upper
        signal = "SELL" # Price touched or crossed above upper band - potential sell (revert to mean)
        reason = "Price ($(round(current_price, digits=2))) at or above Upper Band ($(round(current_upper, digits=2)))."
    # Exit signal (example: price reverts to the mean)
    # This part needs state tracking (if a position is open)
    # For a stateless signal generator, we might just indicate "near mean"
    elseif abs(current_price - current_middle) < (0.1 * (current_upper - current_lower)) # Example: price is very close to mean
        signal = "NEAR_MEAN" # Could be an exit signal if in a position
        reason = "Price ($(round(current_price, digits=2))) near Middle Band ($(round(current_middle, digits=2)))."
    end
    
    details = Dict(
        "asset_pair" => strategy.asset_pair,
        "current_price" => current_price,
        "lookback_period" => strategy.lookback_period,
        "std_dev_multiplier" => strategy.std_dev_multiplier,
        "lower_band" => round(current_lower, digits=4),
        "middle_band" => round(current_middle, digits=4),
        "upper_band" => round(current_upper, digits=4),
        "timestamp" => string(now(UTC))
    )
    
    @info "Signal for $(strategy.asset_pair): $signal. Reason: $reason"
    return Dict("signal"=>signal, "reason"=>reason, "details"=>details)
end

# TODO: Implement backtest_strategy for MeanReversionStrategy

end # module MeanReversionImpl
