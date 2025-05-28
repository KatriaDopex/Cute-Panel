"""
MovingAverageStrategy.jl - Implements moving average-based trading strategies.
"""
module MovingAverageStrategy

using ..TradingStrategy # To subtype AbstractStrategy
# Potentially using ..PriceFeedBase or specific PriceFeed implementations
# using ..PriceFeedBase
using Statistics, Logging, Dates

export MovingAverageCrossoverStrategy, execute_strategy #, backtest_strategy

"""
    MovingAverageCrossoverStrategy <: AbstractStrategy

A strategy that generates trading signals based on the crossover of two moving averages.
"""
struct MovingAverageCrossoverStrategy <: AbstractStrategy
    name::String
    asset_pair::String # e.g., "ETH/USD"
    short_window::Int  # Lookback period for the short moving average
    long_window::Int   # Lookback period for the long moving average
    # price_data_source::AbstractPriceFeed # Ideal
    # execution_context::AbstractDEX # For placing trades

    function MovingAverageCrossoverStrategy(
        name::String,
        asset_pair::String;
        short_window::Int=20,
        long_window::Int=50
        # price_data_source, execution_context
    )
        if short_window <= 0 || long_window <= 0
            error("Moving average windows must be positive.")
        end
        if short_window >= long_window
            error("Short window must be less than long window for a crossover strategy.")
        end
        new(name, asset_pair, short_window, long_window) #, price_data_source, execution_context)
    end
end

"""
    _calculate_sma(prices::Vector{Float64}, window::Int)::Vector{Float64}
Helper to calculate Simple Moving Average. Returns NaNs for initial part where window is not full.
"""
function _calculate_sma(prices::Vector{Float64}, window::Int)::Vector{Float64}
    if length(prices) < window
        return fill(NaN, length(prices)) # Not enough data for any window
    end
    sma = Vector{Float64}(undef, length(prices))
    sma[1:window-1] .= NaN # Fill initial part with NaN
    for i in window:length(prices)
        sma[i] = mean(prices[i-window+1:i])
    end
    return sma
end

"""
    execute_strategy(strategy::MovingAverageCrossoverStrategy, historical_prices::Vector{Float64})

Executes the moving average crossover strategy based on provided historical prices.
Returns a trading signal ("BUY", "SELL", "HOLD") and details.
`historical_prices` should be a vector of closing prices for the strategy's asset_pair.
"""
function TradingStrategy.execute_strategy(strategy::MovingAverageCrossoverStrategy, historical_prices::Vector{Float64})
    @info "Executing MovingAverageCrossoverStrategy: $(strategy.name) for $(strategy.asset_pair)"
    
    if length(historical_prices) < strategy.long_window
        @warn "Not enough historical price data (got $(length(historical_prices)), need at least $(strategy.long_window)) to calculate long MA."
        return Dict("signal"=>"HOLD", "reason"=>"Insufficient data", "details"=>nothing)
    end

    short_ma = _calculate_sma(historical_prices, strategy.short_window)
    long_ma = _calculate_sma(historical_prices, strategy.long_window)

    # Consider the latest available non-NaN values
    last_valid_idx = findlast(!isnan, long_ma)
    if isnothing(last_valid_idx) || last_valid_idx < 2
         @warn "Could not compute valid MAs for signal generation."
        return Dict("signal"=>"HOLD", "reason"=>"MA computation failed", "details"=>nothing)
    end

    current_short_ma = short_ma[last_valid_idx]
    prev_short_ma = short_ma[last_valid_idx-1]
    current_long_ma = long_ma[last_valid_idx]
    prev_long_ma = long_ma[last_valid_idx-1]
    
    current_price = historical_prices[last_valid_idx]

    signal = "HOLD"
    reason = "No crossover."

    # Bullish crossover: short MA crosses above long MA
    if prev_short_ma <= prev_long_ma && current_short_ma > current_long_ma
        signal = "BUY"
        reason = "Short MA ($(round(current_short_ma, digits=2))) crossed above Long MA ($(round(current_long_ma, digits=2)))."
    # Bearish crossover: short MA crosses below long MA
    elseif prev_short_ma >= prev_long_ma && current_short_ma < current_long_ma
        signal = "SELL"
        reason = "Short MA ($(round(current_short_ma, digits=2))) crossed below Long MA ($(round(current_long_ma, digits=2)))."
    end
    
    details = Dict(
        "asset_pair" => strategy.asset_pair,
        "current_price" => current_price,
        "short_ma_window" => strategy.short_window,
        "long_ma_window" => strategy.long_window,
        "current_short_ma" => round(current_short_ma, digits=4),
        "current_long_ma" => round(current_long_ma, digits=4),
        "timestamp" => string(now(UTC)) # Assuming latest price corresponds to now
    )

    @info "Signal for $(strategy.asset_pair): $signal. Reason: $reason"
    return Dict("signal"=>signal, "reason"=>reason, "details"=>details)
end

# TODO: Implement backtest_strategy for MovingAverageCrossoverStrategy

end # module MovingAverageStrategy
