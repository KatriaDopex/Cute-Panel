"""
RiskManagement.jl - Global risk management module for CutePanel agents/DEXes

Enforces max trade size, stop-loss/take-profit, exposure limits, daily loss limits, and custom rules
based on config/risk_management.toml.
"""

module RiskManagement

using TOML
using Dates

const RISK_CONFIG_PATH = joinpath(@__DIR__, "../../config/risk_management.toml")

mutable struct RiskState
    daily_loss::Float64
    last_trade_time::DateTime
    exposure::Dict{String, Float64}  # asset symbol => USD exposure
end

function load_risk_config()
    return TOML.parsefile(RISK_CONFIG_PATH)
end

function check_max_trade_size(dex_name::String, trade_size_usd::Float64, config)::Bool
    max_size = get(config["max_trade_size"], dex_name, 0.0)
    return trade_size_usd <= max_size
end

function check_stop_loss(entry_price::Float64, current_price::Float64, config)::Bool
    if !get(config["stop_loss"], "enabled", false)
        return true
    end
    percent = get(config["stop_loss"], "percent", 0.0)
    loss = (entry_price - current_price) / entry_price * 100
    return loss < percent
end

function check_take_profit(entry_price::Float64, current_price::Float64, config)::Bool
    if !get(config["take_profit"], "enabled", false)
        return false
    end
    percent = get(config["take_profit"], "percent", 0.0)
    gain = (current_price - entry_price) / entry_price * 100
    return gain >= percent
end

function check_exposure(asset::String, new_exposure::Float64, config)::Bool
    max_exp = get(config["exposure_limits"], asset, 0.0)
    return new_exposure <= max_exp
end

function check_daily_loss(state::RiskState, config)::Bool
    if !get(config["daily_loss_limits"], "enabled", false)
        return true
    end
    max_loss = get(config["daily_loss_limits"], "max_loss_usd", 0.0)
    return state.daily_loss <= max_loss
end

function check_min_account_balance(account_balance::Float64, config)::Bool
    min_bal = get(config["custom_rules"], "min_account_balance_usd", 0.0)
    return account_balance >= min_bal
end

function check_trade_cooldown(state::RiskState, config)::Bool
    cooldown = get(config["custom_rules"], "trade_cooldown_seconds", 0)
    now = now()
    return (now - state.last_trade_time) > Second(cooldown)
end

function enforce_risk(trade_ctx::Dict, state::RiskState)
    config = load_risk_config()
    dex_name = trade_ctx["dex_name"]
    trade_size_usd = trade_ctx["trade_size_usd"]
    asset = trade_ctx["asset"]
    new_exposure = trade_ctx["new_exposure"]
    entry_price = trade_ctx["entry_price"]
    current_price = trade_ctx["current_price"]
    account_balance = trade_ctx["account_balance"]

    if !check_max_trade_size(dex_name, trade_size_usd, config)
        error("Trade size $trade_size_usd exceeds max for $dex_name")
    end
    if !check_exposure(asset, new_exposure, config)
        error("Exposure $new_exposure exceeds max for $asset")
    end
    if !check_daily_loss(state, config)
        error("Daily loss limit exceeded")
    end
    if !check_min_account_balance(account_balance, config)
        error("Account balance $account_balance below minimum")
    end
    if !check_trade_cooldown(state, config)
        error("Trade cooldown not met")
    end
    if !check_stop_loss(entry_price, current_price, config)
        error("Stop-loss triggered")
    end
    if check_take_profit(entry_price, current_price, config)
        return :take_profit
    end
    return :ok
end

end # module RiskManagement
