"""
TradeLogger.jl - Real-time trade logging for CutePanel agents/strategies

Logs trades to both the console and a file (logs/trade_log.json).
"""

module TradeLogger

using JSON
using Dates

const TRADE_LOG_PATH = joinpath(@__DIR__, "../../logs/trade_log.json")

function log_trade(trade::Dict)
    # Console output
    println("[TRADE LOG] ", JSON.json(trade))
    # File logging (append as JSON line)
    open(TRADE_LOG_PATH, "a") do io
        println(io, JSON.json(trade))
    end
end

end # module TradeLogger
