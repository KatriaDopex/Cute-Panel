"""
TradingStrategy.jl - Core module for defining and managing trading strategies in CutePanel.
"""
module TradingStrategy

try
    using ..dex.DEXBase 
    using ..dex.DEX 
    using ..swarm 
    using ..swarm.SwarmBase
    using ..price.PriceFeedBase
    using ..price.PriceFeed 
    using Statistics, LinearAlgebra, Random, Dates, Logging
    # Explicitly import Blockchain to access its functions if needed by helpers here
    using ..blockchain # For Blockchain.get_gas_price_generic
    @info "TradingStrategy.jl: Successfully loaded core dependencies."
catch e
    @error "TradingStrategy.jl: Error loading core dependencies." exception=(e, catch_backtrace())
    module DEXBaseStub; struct DEXToken end; struct AbstractDEX end; struct DEXPair end; get_price(dex, pair)=0.0; get_liquidity(dex,pair)=(0.0,0.0); end
    module DEXStub; create_dex_instance(p,v,c)=nothing; end
    module PriceFeedBaseStub; struct PriceData end; struct PricePoint end; struct AbstractPriceFeed end; end
    module PriceFeedStub; get_historical_prices(pf,b,q;kwargs...)=PriceFeedBaseStub.PriceData(); create_price_feed(p,c)=nothing; get_latest_price(pf,b,q)=PriceFeedBaseStub.PricePoint(now(),0.0); end
    module SwarmBase; struct OptimizationProblem end; end
    module Swarms; struct SwarmConfig end; createSwarm(c)=nothing; startSwarm(id)=nothing; getSwarmStatus(id)=nothing; getSwarm(id)=nothing; stopSwarm(id)=nothing; SWARM_ERROR=1; SWARM_COMPLETED=2; SWARM_STOPPED=3; end
    module Blockchain; get_gas_price_generic(conn)=0.0; connect(;kwargs...)=Dict("connected"=>false); end # Mock Blockchain
    using .DEXBaseStub, .DEXStub, .PriceFeedBaseStub, .PriceFeedStub, .SwarmBase, .Swarms, .Blockchain, Statistics, LinearAlgebra, Random, Dates, Logging
end

export AbstractStrategy, OptimalPortfolioStrategy, ArbitrageStrategy
export optimize_portfolio, find_arbitrage_opportunities, execute_strategy, backtest_strategy

abstract type AbstractStrategy end

struct OptimalPortfolioStrategy <: AbstractStrategy
    name::String; tokens::Vector{DEXBase.DEXToken}; price_feed_provider_name::String; price_feed_config::Dict{Symbol, Any}; risk_free_rate::Float64; optimization_params::Dict{String, Any}
    function OptimalPortfolioStrategy(name, tokens; price_feed_provider="chainlink", price_feed_config_override=Dict(), risk_free_rate=0.02, optimization_params=Dict("max_iterations"=>100, "population_size"=>50))
        isempty(tokens) && error("Tokens required.")
        # Ensure chain_id is present for price_feed_config
        chain_id_to_use = if !isempty(tokens) tokens[1].chain_id elseif haskey(price_feed_config_override, :chain_id) price_feed_config_override[:chain_id] else 1 end
        cfg = merge(Dict(:name=>name*"_pf", :chain_id=>chain_id_to_use, :rpc_url=>get(ENV,"ETH_RPC_URL","http://localhost:8545")), price_feed_config_override)
        new(name, tokens, price_feed_provider, cfg, risk_free_rate, optimization_params)
    end
end

struct ArbitrageStrategy <: AbstractStrategy
    name::String; dex_instances::Vector{AbstractDEX}; tokens_of_interest::Vector{DEXToken}; 
    min_profit_threshold_percent::Float64; max_trade_size_usd::Float64; 
    optimization_params::Dict{String, Any}; 
    price_feed_provider_name::String; 
    price_feed_config::Dict{Symbol, Any}; 

    function ArbitrageStrategy(name, dex_instances, tokens; 
                               min_profit_threshold_percent=0.1, 
                               max_trade_size_usd=1000.0, 
                               optimization_params=Dict("typical_swap_gas_units"=>200000, "liquidity_fraction_threshold"=>0.05),
                               price_feed_provider="chainlink", 
                               price_feed_config_override=Dict())
        (length(dex_instances)<1 && length(tokens)<2) && @warn "Arbitrage may not find opportunities."
        isempty(tokens) && error("Tokens of interest required.")
        
        default_pf_chain_id = !isempty(dex_instances) ? dex_instances[1].config.chain_id : 1
        default_pf_rpc_url = !isempty(dex_instances) ? dex_instances[1].config.rpc_url : get(ENV,"ETH_RPC_URL","http://localhost:8545")
        default_pf_config = Dict{Symbol, Any}(:name => name * "_arb_gas_pf", :chain_id => default_pf_chain_id, :rpc_url => default_pf_rpc_url)
        final_pf_config = merge(default_pf_config, price_feed_config_override)

        new(name, dex_instances, tokens, min_profit_threshold_percent, max_trade_size_usd, optimization_params, price_feed_provider, final_pf_config)
    end
end

# New constructor for ArbitrageStrategy that takes DEX configuration dictionaries
function ArbitrageStrategy(
    name::String, 
    dex_configurations::Vector{Dict{String,Any}}, # List of Dicts, each a DEX config
    tokens::Vector{DEXBase.DEXToken};
    min_profit_threshold_percent=0.1, 
    max_trade_size_usd=1000.0, 
    optimization_params=Dict("typical_swap_gas_units"=>200000, "liquidity_fraction_threshold"=>0.05),
    price_feed_provider="chainlink", 
    price_feed_config_override=Dict()
)
    rehydrated_dex_instances = DEXBase.AbstractDEX[]
    for dex_conf_item in dex_configurations
        protocol = get(dex_conf_item, "protocol", "uniswap") # Default if missing
        version = get(dex_conf_item, "version", "v2")     # Default if missing
        
        # Construct DEXConfig parameters from dex_conf_item
        # Ensure all required fields for DEXConfig are present or have defaults
        dex_config_args = Dict{Symbol, Any}(
            :name => get(dex_conf_item, "dex_name", protocol * "_" * version), # Use "dex_name" from stored config
            :protocol => protocol,
            :version => version,
            :chain_id => get(dex_conf_item, "chain_id", 1), # Default to 1 if not specified
            :rpc_url => get(dex_conf_item, "rpc_url", ""), # Should be provided
            :router_address => get(dex_conf_item, "router_address", ""),
            :factory_address => get(dex_conf_item, "factory_address", ""),
            :api_key => get(dex_conf_item, "api_key", ""),
            :gas_limit => get(dex_conf_item, "gas_limit", 300000),
            :gas_price => get(dex_conf_item, "gas_price", 5.0),
            :slippage => get(dex_conf_item, "slippage", 0.5),
            :timeout => get(dex_conf_item, "timeout", 30),
            :metadata => get(dex_conf_item, "metadata", Dict{String,Any}())
        )
        if isempty(dex_config_args[:rpc_url])
            @error "RPC URL missing for DEX configuration in ArbitrageStrategy: $dex_conf_item"
            # Decide how to handle: error out, or skip this DEX? For now, error out.
            error("RPC URL missing for a DEX configuration when re-instantiating ArbitrageStrategy '$name'")
        end

        try
            dex_config_obj = DEXBase.DEXConfig(; dex_config_args...)
            instance = DEX.create_dex_instance(protocol, version, dex_config_obj) # Call the factory from DEX.jl
            push!(rehydrated_dex_instances, instance)
        catch e
            @error "Failed to re-instantiate DEX from configuration for ArbitrageStrategy '$name'." config=dex_conf_item exception=(e, catch_backtrace())
            # Decide handling: error out, or continue without this DEX? For now, error out.
            error("Failed to re-instantiate a DEX for ArbitrageStrategy '$name': $e")
        end
    end

    if isempty(rehydrated_dex_instances) && !isempty(dex_configurations)
        error("ArbitrageStrategy '$name': No DEX instances could be re-instantiated from provided configurations.")
    end

    # Call the original constructor with the rehydrated DEX instances
    return ArbitrageStrategy(name, rehydrated_dex_instances, tokens; 
                             min_profit_threshold_percent=min_profit_threshold_percent,
                             max_trade_size_usd=max_trade_size_usd,
                             optimization_params=optimization_params,
                             price_feed_provider=price_feed_provider,
                             price_feed_config_override=price_feed_config_override)
end


_calc_returns(prices::Matrix{Float64}) = diff(log.(max.(prices, 1e-9)), dims=1)
_calc_expected_returns(prices::Matrix{Float64}) = vec(mean(_calc_returns(prices), dims=1))
_calc_cov_matrix(prices::Matrix{Float64}) = cov(_calc_returns(prices))
function _calc_portfolio_perf(w,mr,cv,rfr) td=252; pr=sum(w.*mr)*td; pv=sqrt(abs(w'*cv*w))*sqrt(td); (pv<1e-9 ? 0.0 : (pr-rfr)/pv) end

function optimize_portfolio(strategy::OptimalPortfolioStrategy, hist_prices::Matrix{Float64})
    n_tok=length(strategy.tokens); (size(hist_prices,2)!=n_tok || size(hist_prices,1)<20) && error("Price data mismatch or insufficient.")
    mr=_calc_expected_returns(hist_prices); cv=_calc_cov_matrix(hist_prices)
    objfn(w) = (s=sum(abs.(w)); s < 1e-9 ? Inf : -_calc_portfolio_perf(abs.(w)./s,mr,cv,strategy.risk_free_rate))
    p=strategy.optimization_params; algo=get(p,"algorithm_type","PSO"); pop=get(p,"population_size",30); iter=get(p,"max_iterations",50) 
    ap=get(p,lowercase(algo)*"_params",Dict{String,Any}()); ap[Symbol(algo=="PSO" ? "num_particles" : "pop_size")] = pop
    sw_cfg = Swarms.SwarmConfig(strategy.name*"-Opt",algo,opt_prob; algorithm_params=ap,max_iter=iter)
    sw = Swarms.createSwarm(sw_cfg); @info "Starting swarm $(sw.id) for portfolio optimization..."
    Swarms.startSwarm(sw.id); _wait_for_swarm_completion(sw.id, 300) 
    res=Swarms.getSwarm(sw.id); opt_w=fill(1.0/n_tok,n_tok)
    if !isnothing(res) && !isnothing(res.best_solution_found) && sum(res.best_solution_found.position)>1e-6
        opt_w=abs.(res.best_solution_found.position)./sum(abs.(res.best_solution_found.position))
        @info "Swarm opt found weights. Best -Sharpe: $(res.best_solution_found.fitness)"
    else @error "Swarm opt failed for $(strategy.name)." end
    r_val,v_val,s_val = _calc_portfolio_perf(opt_w,mr,cv,strategy.risk_free_rate)
    return Dict("optimal_weights"=>opt_w, "expected_annual_return"=>r_val, "annual_volatility"=>v_val, "sharpe_ratio"=>s_val)
end
_wait_for_swarm_completion(id,timeout) = for _ in 1:timeout/2 if (s=Swarms.getSwarmStatus(id); isnothing(s) || s["status"]∈["COMPLETED","ERROR","STOPPED"]) break; end; sleep(2); end

function _find_dex_pair(dex::AbstractDEX, tA::DEXToken, tB::DEXToken)
    try 
        pairs_from_dex = DEXBase.get_pairs(dex, limit=1000) 
        for p_obj in pairs_from_dex 
            if (lowercase(p_obj.token0.address)==lowercase(tA.address) && lowercase(p_obj.token1.address)==lowercase(tB.address)) || 
               (uppercase(p_obj.token0.symbol)==uppercase(tA.symbol) && uppercase(p_obj.token1.symbol)==uppercase(tB.symbol)) 
                return p_obj 
            end
            if (lowercase(p_obj.token0.address)==lowercase(tB.address) && lowercase(p_obj.token1.address)==lowercase(tA.address)) || 
               (uppercase(p_obj.token0.symbol)==uppercase(tB.symbol) && uppercase(p_obj.token1.symbol)==uppercase(tA.symbol)) 
                return p_obj 
            end
        end
    catch e @warn "Err finding pair" dex=dex.config.name error=e end
    return nothing
end

function _get_native_asset_price_for_gas(strat_arb::ArbitrageStrategy, dex_chain_id::Int)::Float64
    native_symbol = if dex_chain_id == 1 || dex_chain_id == 5 "ETH" 
                     elseif dex_chain_id == 137 "MATIC" 
                     elseif dex_chain_id == 56 "BNB"   
                     else nothing end
    if isnothing(native_symbol)
        @warn "Cannot determine native asset for chain ID $dex_chain_id. Using default gas cost USD."
        return get(strat_arb.optimization_params, "default_gas_cost_usd_per_tx", 5.0) / (get(strat_arb.optimization_params, "typical_swap_gas_units", 200000) * 1e-9) # Implies a GWEI price
    end
    try
        # Use the ArbitrageStrategy's own price_feed_config
        pf_cfg_symbols = strat_arb.price_feed_config # This is Dict{Symbol, Any}
        pf_instance = PriceFeed.create_price_feed(strat_arb.price_feed_provider_name, PriceFeedBase.PriceFeedConfig(;pf_cfg_symbols...))
        price_point = PriceFeed.get_latest_price(pf_instance, native_symbol, "USD")
        return price_point.price > 0 ? price_point.price : get(strat_arb.optimization_params, "default_native_asset_price_usd", 2000.0)
    catch e
        @warn "Failed to get native asset price ($native_symbol/USD) for gas cost. Using default." error=e
        return get(strat_arb.optimization_params, "default_native_asset_price_usd", 2000.0)
    end
end

# Helper to get Uniswap V3 QuoterV2 address from DEX config
_get_v3_quoter_address(dex_config::DEXBase.DEXConfig) = get(dex_config.metadata, "quoter_v2_address", DEX.UniswapDEX.DEFAULT_QUOTER_V2_ADDRESS_MAINNET)


# Helper function to get quoted output amount from Uniswap V3 QuoterV2
# This is a simplified version for single-hop exact input.
function _get_v3_quoted_output_amount(
    dex_v3::DEXBase.AbstractDEX, # Assumed to be a UniswapV3 instance
    token_in::DEXToken, 
    token_out::DEXToken, 
    amount_in_units_smallest::BigInt,
    pool_fee_tier_raw::Float64 # e.g., 0.0005 for 0.05%
)::Union{BigInt, Nothing}
    
    # Ensure this is actually a Uniswap instance to access its specific fields/helpers
    # This check might be better using multiple dispatch or a more robust type check
    # if other DEX types could be passed. For now, assume it's a Uniswap struct.
    if !(hasproperty(dex_v3, :version) && dex_v3.version == DEX.UniswapDEX.V3)
        @warn "_get_v3_quoted_output_amount called with non-UniswapV3 DEX type. Dex: $(dex_v3.config.name)"
        return nothing
    end

    conn = DEX.UniswapDEX._get_conn(dex_v3) # Use internal helper from UniswapDEX
    if !get(conn, "connected", false)
        @error "Quoter call failed: No connection for DEX $(dex_v3.config.name)"
        return nothing
    end

    quoter_address = _get_v3_quoter_address(dex_v3.config)
    if isempty(quoter_address)
        @warn "QuoterV2 address not configured for DEX $(dex_v3.config.name). Cannot get V3 quote."
        return nothing
    end

    fee_tier_uint24 = try round(UInt24, pool_fee_tier_raw * 1_000_000) catch _ # Uniswap fee tiers are in parts per million for Quoter
        # The pair.fee is stored as 0.05 for 0.05%. The quoter needs it as 500 (for 0.05%) or 3000 (for 0.3%)
        # So, if pair.fee is 0.05 (%), then fee_tier_uint24 should be 500.
        # If pair.fee is 0.0005 (decimal), then * 1_000_000 = 500.
        # Let's assume pair.fee is stored as percentage points / 100, e.g. 0.05 for 0.05%
        # So, 0.05 * 10000 = 500.
        # The create_order uses pair.fee * 10000. Let's be consistent.
        # However, Uniswap V3 fees are typically 500, 3000, 10000 (0.05%, 0.3%, 1%)
        # If pair.fee is 0.05 (meaning 0.05, not 0.05%), then 0.05 * 1_000_000 = 50000. This is wrong.
        # If pair.fee is 0.0005 (for 0.05% fee tier), then 0.0005 * 1_000_000 = 500. This is correct.
        # Let's assume pair.fee is stored as the decimal representation (e.g. 0.0005 for 0.05% tier)
        # The create_order uses `round(UInt24, pair.fee*10000)`. This implies pair.fee is like 0.05 for 0.05%
        # Let's stick to `pair.fee` being the percentage value (e.g., 0.05 for 0.05% tier, 0.3 for 0.3% tier)
        # Then the fee for quoter is `pair.fee / 100 * 1_000_000 = pair.fee * 10000`
        fee_val_for_quoter = round(UInt24, pool_fee_tier_raw * 10000) # e.g. if pool_fee_tier_raw is 0.05 (for 0.05%), this becomes 500
        @debug "Converted pool_fee_tier_raw $pool_fee_tier_raw to fee_val_for_quoter $fee_val_for_quoter for Quoter."
        fee_val_for_quoter
    end


    sqrt_price_limit_x96_for_quote = BigInt(0) # 0 means no price limit for quote

    quoter_sig = "quoteExactInputSingle(address,address,uint24,uint256,uint160)"
    quoter_args = [
        (token_in.address, "address"),
        (token_out.address, "address"),
        (fee_tier_uint24, "uint24"), # This should be the fee tier like 500, 3000
        (amount_in_units_smallest, "uint256"),
        (sqrt_price_limit_x96_for_quote, "uint160")
    ]
    
    quoter_call_data = Blockchain.EthereumClient.encode_function_call_abi(quoter_sig, quoter_args)
    
    try
        quoted_hex = Blockchain.eth_call_generic(quoter_address, quoter_call_data, conn)
        if isempty(quoted_hex) || quoted_hex == "0x"
            @warn "QuoterV2 call returned empty for $(token_in.symbol)->$(token_out.symbol) on DEX $(dex_v3.config.name)."
            return nothing
        end
        decoded_q = Blockchain.EthereumClient.decode_function_result_abi(quoted_hex, ["uint256"]) # amountOut
        if !isempty(decoded_q) && isa(decoded_q[1], BigInt)
            return decoded_q[1] # amountOut in smallest units
        else
            @warn "Failed to decode QuoterV2 result for $(token_in.symbol)->$(token_out.symbol) on DEX $(dex_v3.config.name)." decoded_q=decoded_q
            return nothing
        end
    catch e
        @error "Error calling QuoterV2 for $(token_in.symbol)->$(token_out.symbol) on DEX $(dex_v3.config.name)" error=e
        return nothing
    end
end


function find_arbitrage_opportunities(strat::ArbitrageStrategy)
    ops=[]; @info "Scanning arbitrage: $(strat.name)"
    liquidity_fraction_threshold = get(strat.optimization_params, "liquidity_fraction_threshold", 0.05) 
    
    # Refined gas units: allow a dict or a single value
    gas_units_param = get(strat.optimization_params, "swap_gas_units", 200000) # Default if not specified or malformed
    
    function get_gas_units_for_dex(dex_instance::AbstractDEX, is_multi_hop_leg::Bool=false)
        # Define default gas units
        default_v2_swap = 150000
        default_v3_single_hop = 200000
        # default_v3_multi_hop = 300000 # For future use if a leg itself is multi-hop

        if isa(gas_units_param, Dict)
            if dex_instance.config.protocol == "uniswap" && dex_instance.config.version == "v3"
                # For now, assume arbitrage legs are single hops on V3 for gas estimation
                return get(gas_units_param, "uniswap_v3_single_hop", default_v3_single_hop)
            elseif dex_instance.config.protocol == "uniswap" && dex_instance.config.version == "v2"
                return get(gas_units_param, "uniswap_v2_swap", default_v2_swap)
            else # Generic or unknown DEX type
                return get(gas_units_param, "default_swap", default_v2_swap) # Fallback to a general default
            end
        elseif isa(gas_units_param, Integer)
            return Int(gas_units_param) # Use the single provided value for all
        else
            @warn "Invalid swap_gas_units format in ArbitrageStrategy optimization_params. Expected Dict or Integer. Using default."
            return default_v2_swap # Fallback default if format is wrong
        end
    end

    simulated_slippage_pct_per_10k_usd = get(strat.optimization_params, "simulated_slippage_pct_per_10k_usd", 0.05)

    for i in 1:length(strat.tokens_of_interest), j in (i+1):length(strat.tokens_of_interest)
        tA=strat.tokens_of_interest[i]; tB=strat.tokens_of_interest[j]
        for d1_idx in 1:length(strat.dex_instances), d2_idx in 1:length(strat.dex_instances)
            if d1_idx==d2_idx && length(strat.dex_instances) > 1 continue end 
            dex1=strat.dex_instances[d1_idx]; dex2=strat.dex_instances[d2_idx]
            p1=_find_dex_pair(dex1,tA,tB); p2=_find_dex_pair(dex2,tA,tB); (isnothing(p1)||isnothing(p2)) && continue
            price1_tA_in_tB_raw=DEXBase.get_price(dex1,p1); 
            # Ensure tA is token0 for price1_tA_in_tB_raw to mean "price of tA in tB"
            # If p1.token0 is tB, then get_price returns price of tB in tA, so we need to invert.
            # The get_price in UniswapDEX already handles this inversion based on pair.token0 vs pair.token1.
            # So, price1_tA_in_tB_raw should be price of p1.token0 in p1.token1.
            # We need to align it with tA and tB.
            # If tA is p1.token0, then price1_tA_in_tB_raw is price of tA in tB.
            # If tA is p1.token1, then price1_tA_in_tB_raw is price of tB in tA, so invert.
            if lowercase(p1.token0.address) == lowercase(tB.address) # means p1.token0 is tB, p1.token1 is tA
                 price1_tA_in_tB_raw = (price1_tA_in_tB_raw == 0.0 ? Inf : 1.0/price1_tA_in_tB_raw)
            end

            price2_tA_in_tB_raw=DEXBase.get_price(dex2,p2); 
            if lowercase(p2.token0.address) == lowercase(tB.address)
                 price2_tA_in_tB_raw = (price2_tA_in_tB_raw == 0.0 ? Inf : 1.0/price2_tA_in_tB_raw)
            end
            
            (price1_tA_in_tB_raw<=0||price2_tA_in_tB_raw<=0||price1_tA_in_tB_raw==Inf||price2_tA_in_tB_raw==Inf) && continue
            
            # --- Effective Price Calculation (Buy on dex1, Sell on dex2) ---
            # Amount of tA to use for quoting, based on max_trade_size_usd
            # Need USD price of tA. Use strategy's price feed.
            pf_cfg_symbols = strat.price_feed_config
            pf_instance_for_sizing = PriceFeed.create_price_feed(strat.price_feed_provider_name, PriceFeedBase.PriceFeedConfig(;pf_cfg_symbols...))
            price_tA_usd = try PriceFeed.get_latest_price(pf_instance_for_sizing, tA.symbol, "USD").price catch _ 0.0 end
            
            (price_tA_usd <= 0) && (@warn "Could not get USD price for $(tA.symbol) for sizing. Skipping path."; continue)
            
            amount_in_tA_for_quote_smallest = BigInt(round((strat.max_trade_size_usd / price_tA_usd) * (10^tA.decimals)))
            
            local price1_tA_in_tB_effective_buy::Float64
            local price2_tA_in_tB_effective_sell::Float64

            # Effective price for buying tB with tA on dex1
            if dex1.config.protocol == "uniswap" && dex1.config.version == "v3"
                quoted_amount_out_tB_smallest = _get_v3_quoted_output_amount(dex1, tA, tB, amount_in_tA_for_quote_smallest, p1.fee)
                if isnothing(quoted_amount_out_tB_smallest) || quoted_amount_out_tB_smallest == 0
                    @warn "V3 Quoter failed for dex1 $(dex1.config.name), $(tA.symbol)->$(tB.symbol). Using raw price + linear slippage."
                    slippage_factor_dex1 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                    price1_tA_in_tB_effective_buy = price1_tA_in_tB_raw * (1 + slippage_factor_dex1)
                else
                    amount_in_tA_float = Float64(amount_in_tA_for_quote_smallest) / (10^tA.decimals)
                    amount_out_tB_float = Float64(quoted_amount_out_tB_smallest) / (10^tB.decimals)
                    price1_tA_in_tB_effective_buy = amount_out_tB_float > 0 ? amount_in_tA_float / amount_out_tB_float : Inf 
                    # This is price of tB in tA. We need price of tA in tB for buying tB.
                    # If 1 tA gets X tB, price of tA in tB is X.
                    # If we spend Y tA to get Z tB, effective price of tA in tB is Z/Y.
                    price1_tA_in_tB_effective_buy = amount_in_tA_float > 0 ? amount_out_tB_float / amount_in_tA_float : 0.0
                end
            else # V2 or other DEX
                slippage_factor_dex1 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                # Buying tB with tA: price of tA in tB. If price increases due to slippage, we get less tB for tA.
                price1_tA_in_tB_effective_buy = price1_tA_in_tB_raw * (1 - slippage_factor_dex1) 
            end

            # Effective price for selling tB for tA on dex2
            # We are selling tB (amount derived from the buy leg) to get tA.
            # For quoting, we need amount_in of tB. Assume it's roughly strat.max_trade_size_usd worth of tB.
            price_tB_usd = try PriceFeed.get_latest_price(pf_instance_for_sizing, tB.symbol, "USD").price catch _ 0.0 end
            (price_tB_usd <= 0) && (@warn "Could not get USD price for $(tB.symbol) for sizing sell leg. Skipping path."; continue)
            amount_in_tB_for_quote_smallest = BigInt(round((strat.max_trade_size_usd / price_tB_usd) * (10^tB.decimals)))

            if dex2.config.protocol == "uniswap" && dex2.config.version == "v3"
                quoted_amount_out_tA_smallest = _get_v3_quoted_output_amount(dex2, tB, tA, amount_in_tB_for_quote_smallest, p2.fee)
                if isnothing(quoted_amount_out_tA_smallest) || quoted_amount_out_tA_smallest == 0
                    @warn "V3 Quoter failed for dex2 $(dex2.config.name), $(tB.symbol)->$(tA.symbol). Using raw price + linear slippage."
                    slippage_factor_dex2 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                    price2_tA_in_tB_effective_sell = price2_tA_in_tB_raw * (1 - slippage_factor_dex2) # Selling tA for tB, price of tA in tB decreases
                else
                    amount_in_tB_float = Float64(amount_in_tB_for_quote_smallest) / (10^tB.decimals)
                    amount_out_tA_float = Float64(quoted_amount_out_tA_smallest) / (10^tA.decimals)
                    # We are selling tB to get tA. The quote gives amount_out_tA for amount_in_tB.
                    # Effective price of tA in tB is amount_out_tA / amount_in_tB (how much tA we get per tB sold).
                    # This is price of tA in tB.
                    price2_tA_in_tB_effective_sell = amount_in_tB_float > 0 ? amount_out_tA_float / amount_in_tB_float : 0.0
                end
            else # V2 or other DEX
                slippage_factor_dex2 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                price2_tA_in_tB_effective_sell = price2_tA_in_tB_raw * (1 - slippage_factor_dex2)
            end
            
            (price1_tA_in_tB_effective_buy <=0 || price2_tA_in_tB_effective_sell <=0 || price1_tA_in_tB_effective_buy == Inf) && continue

            # Arbitrage: Buy tA on dex1 (pay tB), sell tA on dex2 (receive tB)
            # So, we want price of tA in tB on dex1 (buy_price_tA_in_tB) to be LOW
            # and price of tA in tB on dex2 (sell_price_tA_in_tB) to be HIGH.
            # The variables price1_tA_in_tB_effective_buy and price2_tA_in_tB_effective_sell are already "price of tA in tB".
            # For buying tA on dex1: we pay tB. If tA costs X tB, effective cost is higher due to slippage.
            # So, if price1_tA_in_tB_raw is "tB per tA", then effective price is price1_tA_in_tB_raw * (1 + slippage_factor_dex1)
            # The current code has: price1_tA_in_tB_effective_buy = price1_tA_in_tB_raw * (1 - slippage_factor_dex1) for V2. This seems to be price of tA if we sell it.
            # Let's redefine:
            #   rate_buy_tA_with_tB_dex1: How much tB you pay for 1 tA on dex1 (higher is worse)
            #   rate_sell_tA_for_tB_dex2: How much tB you get for 1 tA on dex2 (higher is better)
            # The current price variables are "price of tA in terms of tB".
            # So, price1_tA_in_tB_raw is "how many tB for one tA".
            # When buying tA on dex1, we pay more tB: effective_cost_tA_in_tB_dex1 = price1_tA_in_tB_raw / (1 - slippage_factor_dex1) (if using factor on output)
            # Or, if using factor on input price: price1_tA_in_tB_raw * (1 + slippage_factor_dex1)
            
            # Let's use the Quoter output directly for V3, and stick to the existing linear model for V2 for now,
            # but ensure the direction of slippage application is correct.
            # price1_tA_in_tB_effective_buy: cost of 1 tA in terms of tB on dex1 (buy leg)
            # price2_tA_in_tB_effective_sell: revenue for 1 tA in terms of tB on dex2 (sell leg)
            # We need price2_tA_in_tB_effective_sell > price1_tA_in_tB_effective_buy

            if price2_tA_in_tB_effective_sell > price1_tA_in_tB_effective_buy 
                gross_profit_ratio = (price2_tA_in_tB_effective_sell / price1_tA_in_tB_effective_buy) - 1.0
                
                # Use the USD price of tA for sizing the trade in tA units
                trade_size_tA_units_float = strat.max_trade_size_usd / price_tA_usd
                
                liq1_res0, liq1_res1 = DEXBase.get_liquidity(dex1, p1)
                dex1_tA_liq = lowercase(p1.token0.address)==lowercase(tA.address) ? liq1_res0 : liq1_res1
                liq2_res0, liq2_res1 = DEXBase.get_liquidity(dex2, p2)
                dex2_tA_liq = lowercase(p2.token0.address)==lowercase(tA.address) ? liq2_res0 : liq2_res1
                is_liquid_enough = (dex1_tA_liq > 0 && trade_size_tA_units < liquidity_fraction_threshold * dex1_tA_liq) && (dex2_tA_liq > 0 && trade_size_tA_units < liquidity_fraction_threshold * dex2_tA_liq)
                
                # Dynamic gas cost (assuming DEXs are on same chain for simplicity of this example leg)
                # A more robust solution would get gas for each DEX's chain.
                dex1_chain_id = dex1.config.chain_id
                # Assuming dex1 and dex2 are on the same chain for gas price calculation for simplicity.
                conn_dex1 = _get_conn(dex1) 
                current_gas_price_gwei = Blockchain.get_gas_price_generic(conn_dex1) 
                native_asset_price_usd = _get_native_asset_price_for_gas(strat, dex1_chain_id)

                gas_units_dex1 = get_gas_units_for_dex(dex1)
                gas_units_dex2 = get_gas_units_for_dex(dex2)

                gas_cost_dex1_usd = (current_gas_price_gwei * 1e-9) * gas_units_dex1 * native_asset_price_usd
                gas_cost_dex2_usd = (current_gas_price_gwei * 1e-9) * gas_units_dex2 * native_asset_price_usd
                total_gas_cost_usd = gas_cost_dex1_usd + gas_cost_dex2_usd
                
                net_profit_usd = (strat.max_trade_size_usd * gross_profit_ratio) - total_gas_cost_usd
                net_profit_pct_before_risk_adj = strat.max_trade_size_usd > 0 ? (net_profit_usd / strat.max_trade_size_usd) * 100.0 : 0.0

                risk_adjustment_factor_pct = get(strat.optimization_params, "risk_adjustment_factor_pct", 0.0)
                final_net_profit_pct = net_profit_pct_before_risk_adj * (1 - risk_adjustment_factor_pct / 100.0)
                
                if final_net_profit_pct >= strat.min_profit_threshold_percent && is_liquid_enough
                    push!(ops, Dict("type"=>"spatial",
                                    "path"=>"$(tA.symbol) $(dex1.config.name)->$(dex2.config.name)",
                                    "profit_pct_net"=>round(final_net_profit_pct,digits=4), # Store the risk-adjusted net profit
                                    "details"=>"Buy $(tA.symbol) on $(dex1.config.name) @ effective price $(round(price1_tA_in_tB_effective_buy, digits=6)) (raw: $(round(price1_tA_in_tB_raw, digits=6))), Sell on $(dex2.config.name) @ effective price $(round(price2_tA_in_tB_effective_sell, digits=6)) (raw: $(round(price2_tA_in_tB_raw, digits=6))). Gross (post-slippage, pre-gas): $(round(gross_profit_ratio*100,digits=4))%, Est. Gas Cost USD: $(round(total_gas_cost_usd, digits=2)), Risk Adj Pct: $risk_adjustment_factor_pct"))
                end
            end
        end
    end
    num_tokens_of_interest = length(strat.tokens_of_interest) 
    if num_tokens_of_interest >=3
        for dex_inst in strat.dex_instances, i in 1:num_tokens_of_interest, j in 1:num_tokens_of_interest, k in 1:num_tokens_of_interest
            if i==j||j==k||k==i continue end
            tA=strat.tokens_of_interest[i]; tB=strat.tokens_of_interest[j]; tC=strat.tokens_of_interest[k]
            
            pAB=_find_dex_pair(dex_inst,tA,tB); pBC=_find_dex_pair(dex_inst,tB,tC); pCA=_find_dex_pair(dex_inst,tC,tA)
            (isnothing(pAB)||isnothing(pBC)||isnothing(pCA)) && continue
            
            priceAB_raw=DEXBase.get_price(dex_inst,pAB); if lowercase(pAB.token0.address)==lowercase(tB.address) priceAB_raw=(priceAB_raw==0.0 ? Inf : 1.0/priceAB_raw) end
            priceBC_raw=DEXBase.get_price(dex_inst,pBC); if lowercase(pBC.token0.address)==lowercase(tC.address) priceBC_raw=(priceBC_raw==0.0 ? Inf : 1.0/priceBC_raw) end
            priceCA_raw=DEXBase.get_price(dex_inst,pCA); if lowercase(pCA.token0.address)==lowercase(tA.address) priceCA_raw=(priceCA_raw==0.0 ? Inf : 1.0/priceCA_raw) end
            (priceAB_raw<=0||priceBC_raw<=0||priceCA_raw<=0||priceAB_raw==Inf||priceBC_raw==Inf||priceCA_raw==Inf) && continue

            # --- Triangular Arbitrage Effective Rate Calculation ---
            # Start with an initial amount of tA (e.g., strat.max_trade_size_usd worth)
            # For simplicity in quoting, we'll use strat.max_trade_size_usd as the reference value for each leg's input.
            
            # USD prices for sizing quotes
            price_tA_usd_tri = try PriceFeed.get_latest_price(pf_instance_for_sizing, tA.symbol, "USD").price catch _ 0.0 end
            price_tB_usd_tri = try PriceFeed.get_latest_price(pf_instance_for_sizing, tB.symbol, "USD").price catch _ 0.0 end
            price_tC_usd_tri = try PriceFeed.get_latest_price(pf_instance_for_sizing, tC.symbol, "USD").price catch _ 0.0 end

            if price_tA_usd_tri <= 0 || price_tB_usd_tri <= 0 || price_tC_usd_tri <= 0
                @warn "Triangular Arb: Could not get USD price for one or more tokens ($(tA.symbol), $(tB.symbol), $(tC.symbol)). Skipping path."
                continue
            end

            initial_amount_tA_units_float = strat.max_trade_size_usd / price_tA_usd_tri
            initial_amount_tA_smallest = BigInt(round(initial_amount_tA_units_float * (10^tA.decimals)))

            amount_tB_after_leg1_smallest::Union{BigInt, Nothing}
            amount_tC_after_leg2_smallest::Union{BigInt, Nothing}
            final_amount_tA_after_leg3_smallest::Union{BigInt, Nothing}

            # Leg 1: tA -> tB
            if dex_inst.config.protocol == "uniswap" && dex_inst.config.version == "v3"
                amount_tB_after_leg1_smallest = _get_v3_quoted_output_amount(dex_inst, tA, tB, initial_amount_tA_smallest, pAB.fee)
            else # V2 or other DEX (linear slippage)
                slippage_factor_leg1 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                # priceAB_raw is tB per tA. Slippage reduces output.
                effective_rate_AB = priceAB_raw * (1 - slippage_factor_leg1)
                amount_tB_after_leg1_smallest = BigInt(round(initial_amount_tA_units_float * effective_rate_AB * (10^tB.decimals)))
            end
            (isnothing(amount_tB_after_leg1_smallest) || amount_tB_after_leg1_smallest <= 0) && continue

            # Leg 2: tB -> tC
            # Input for this leg is amount_tB_after_leg1_smallest
            if dex_inst.config.protocol == "uniswap" && dex_inst.config.version == "v3"
                amount_tC_after_leg2_smallest = _get_v3_quoted_output_amount(dex_inst, tB, tC, amount_tB_after_leg1_smallest, pBC.fee)
            else
                slippage_factor_leg2 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                # priceBC_raw is tC per tB.
                effective_rate_BC = priceBC_raw * (1 - slippage_factor_leg2)
                amount_tB_leg2_input_float = Float64(amount_tB_after_leg1_smallest) / (10^tB.decimals)
                amount_tC_after_leg2_smallest = BigInt(round(amount_tB_leg2_input_float * effective_rate_BC * (10^tC.decimals)))
            end
            (isnothing(amount_tC_after_leg2_smallest) || amount_tC_after_leg2_smallest <= 0) && continue
            
            # Leg 3: tC -> tA
            # Input for this leg is amount_tC_after_leg2_smallest
            if dex_inst.config.protocol == "uniswap" && dex_inst.config.version == "v3"
                final_amount_tA_after_leg3_smallest = _get_v3_quoted_output_amount(dex_inst, tC, tA, amount_tC_after_leg2_smallest, pCA.fee)
            else
                slippage_factor_leg3 = (strat.max_trade_size_usd / 10000.0) * (simulated_slippage_pct_per_10k_usd / 100.0)
                # priceCA_raw is tA per tC.
                effective_rate_CA = priceCA_raw * (1 - slippage_factor_leg3)
                amount_tC_leg3_input_float = Float64(amount_tC_after_leg2_smallest) / (10^tC.decimals)
                final_amount_tA_after_leg3_smallest = BigInt(round(amount_tC_leg3_input_float * effective_rate_CA * (10^tA.decimals)))
            end
            (isnothing(final_amount_tA_after_leg3_smallest) || final_amount_tA_after_leg3_smallest <= 0) && continue

            final_amount_tA_units_float = Float64(final_amount_tA_after_leg3_smallest) / (10^tA.decimals)
            
            # Profit calculation
            gross_profit_ratio_tri = (final_amount_tA_units_float / initial_amount_tA_units_float) - 1.0
            
            dex_chain_id = dex_inst.config.chain_id
            conn_dex = _get_conn(dex_inst) 
            current_gas_price_gwei = Blockchain.get_gas_price_generic(conn_dex)
            native_asset_price_usd = _get_native_asset_price_for_gas(strat, dex_chain_id)
            
            # For triangular, all 3 swaps are on the same dex_inst
            gas_units_per_leg_tri = get_gas_units_for_dex(dex_inst) # Assuming single-hop for each leg
            gas_cost_one_tx_usd = (current_gas_price_gwei * 1e-9) * gas_units_per_leg_tri * native_asset_price_usd
            total_gas_cost_usd_tri = 3 * gas_cost_one_tx_usd

            value_of_trade_in_usd = strat.max_trade_size_usd 
            net_profit_usd_tri = (value_of_trade_in_usd * gross_profit_ratio_tri) - total_gas_cost_usd_tri
            net_profit_pct_before_risk_adj_tri = value_of_trade_in_usd > 0 ? (net_profit_usd_tri / value_of_trade_in_usd) * 100.0 : 0.0
            
            risk_adjustment_factor_pct = get(strat.optimization_params, "risk_adjustment_factor_pct", 0.0)
            final_net_profit_pct_tri = net_profit_pct_before_risk_adj_tri * (1 - risk_adjustment_factor_pct / 100.0)

            if final_net_profit_pct_tri >= strat.min_profit_threshold_percent 
                 final_rate_tri = 1.0 + gross_profit_ratio_tri # This is rate after slippage but before gas/risk_adj
                 push!(ops, Dict("type"=>"triangular","dex"=>dex_inst.config.name,"path"=>"$(tA.symbol)->$(tB.symbol)->$(tC.symbol)->$(tA.symbol)","rate_after_slippage"=>round(final_rate_tri, digits=8),"profit_pct_net"=>round(final_net_profit_pct_tri,digits=4), "gross_profit_pct_pre_gas"=>round(gross_profit_ratio_tri*100,digits=4), "est_gas_cost_usd"=>round(total_gas_cost_usd_tri,digits=2), "risk_adj_pct_applied"=>risk_adjustment_factor_pct))
            end
        end
    end
    end
    !isempty(ops) && @info "Found $(length(ops)) arbitrage opportunities."
    return ops
end

function execute_strategy(strategy::OptimalPortfolioStrategy; historical_prices_matrix=nothing, num_days_history=90, interval="1d")
    # Global risk enforcement at function entry
    try
        import ..RiskManagement
        state = RiskManagement.RiskState(0.0, now(), Dict{String, Float64}())
        trade_ctx = Dict(
            "dex_name" => "global",
            "trade_size_usd" => 0.0,
            "asset" => "global",
            "new_exposure" => 0.0,
            "entry_price" => 0.0,
            "current_price" => 0.0,
            "account_balance" => 0.0
        )
        RiskManagement.enforce_risk(trade_ctx, state)
    catch e
        @error "Risk check failed at entry to execute_strategy: $e"
        error("Risk check failed: $e")
    end
    @info "Executing OptimalPortfolio: $(strategy.name)"
    hist_prices = !isnothing(historical_prices_matrix) ? historical_prices_matrix : begin
        @info "Fetching historical data for OptimalPortfolio..."
        pf_cfg = PriceFeedBase.PriceFeedConfig(;strategy.price_feed_config...)
        pf_inst = PriceFeed.create_price_feed(strategy.price_feed_provider_name, pf_cfg) # Removed Symbol()
        @warn "Multi-asset historical data fetching placeholder."
        num_tok = length(strategy.tokens); mock_hp = zeros(Float64,num_days_history,num_tok)
        for i in 1:num_tok mock_hp[:,i] .= rand(50:2000) .* (1 .+ cumsum((rand(num_days_history).-0.5).*0.02)) end; mock_hp
    end
    opt_res = optimize_portfolio(strategy, hist_prices)
    return Dict("name"=>strategy.name, "type"=>"OptimalPortfolio", "result"=>opt_res, "action"=>"Weights optimized.")
end
function execute_strategy(strategy::ArbitrageStrategy) 
    @info "Executing Arbitrage: $(strategy.name)"
    ops = find_arbitrage_opportunities(strategy)
    return Dict("name"=>strategy.name, "type"=>"Arbitrage", "opportunities"=>ops, "action"=>isempty(ops) ? "No ops." : "Ops identified.")
end

function backtest_strategy(
    strategy::AbstractStrategy, 
    hist_market_data::Any; 
    initial_capital=10000.0, 
    tx_cost_pct=0.1, 
    risk_params::RiskManagement.RiskParameters = RiskManagement.RiskParameters(), 
    slippage_model_params::Dict = Dict("pct_per_10k_usd" => 0.05, "fixed_pct" => 0.0), # Slippage model params
    # SL/TP percentages for single-asset strategies will be fetched from strategy.optimization_params
    start_date=nothing, 
    end_date=nothing
)::Dict{String,Any}
    # Global risk enforcement at function entry
    try
        import ..RiskManagement
        state = RiskManagement.RiskState(0.0, now(), Dict{String, Float64}())
        trade_ctx = Dict(
            "dex_name" => "global",
            "trade_size_usd" => 0.0,
            "asset" => "global",
            "new_exposure" => 0.0,
            "entry_price" => 0.0,
            "current_price" => 0.0,
            "account_balance" => initial_capital
        )
        RiskManagement.enforce_risk(trade_ctx, state)
    catch e
        @error "Risk check failed at entry to backtest_strategy: $e"
        error("Risk check failed: $e")
    end
    @info "Backtesting $(strategy.name) with Risk Management and Slippage Model: $slippage_model_params"
    td_per_year=252
    # isa(strategy,ArbitrageStrategy) && (@warn "Arbitrage backtest not implemented."; return Dict("status"=>"Not Implemented")) # Removed early exit
    prices = hist_market_data # prices is hist_market_data
    if (isa(strategy,MovingAverageCrossoverStrategy)||isa(strategy,MeanReversionStrategy)) && !isa(prices,Vector{Float64}) && !isa(strategy,ArbitrageStrategy) error("MA/MR expect Vector{Float64}") end
    if isa(strategy,OptimalPortfolioStrategy) && !isa(prices,Matrix{Float64}) error("OptimalPortfolio expects Matrix{Float64}") end
    num_points = isa(prices,Vector) ? length(prices) : size(prices,1)
    num_points<2 && (@warn "Insufficient data."; return Dict("status"=>"Insufficient data"))
    
    cash = initial_capital
    portfolio_values = [initial_capital] # Renamed for clarity
    trade_log = [] # Renamed for clarity, will store more detailed NamedTuples

    # For single-asset strategies (MA, MR)
    current_position_units = 0.0
    current_position_avg_cost_per_unit = 0.0 # Cost basis including tx fees
    active_stop_loss_price = 0.0 # Fixed stop-loss
    active_take_profit_price = Inf 
    active_trailing_stop_price = 0.0 # For trailing stop
    position_high_water_mark = 0.0 # Highest price observed since position opened (for trailing stop)
    trailing_stop_active_for_position = false
    current_trailing_stop_pct = 0.0 # Store the percentage for the current position

    # Initialize RiskManager
    risk_manager = RiskManagement.RiskManager(risk_params, initial_capital)

    # For multi-asset strategies (OptimalPortfolio)
    # current_asset_positions: Dict{String, Dict{"units":Float64, "avg_cost_per_unit":Float64}}
    # This would be more complex to integrate with current rebalance logic, deferring detailed per-asset P&L for OptimalPortfolio for now.
    # We will still log rebalance costs.
    # cur_weights = isa(strategy,OptimalPortfolioStrategy) ? zeros(length(strategy.tokens)) : nothing # Not actively used for P&L yet

    for t in 2:num_points 
        # Determine current market snapshot for strategy execution
        market_snap = isa(strategy,OptimalPortfolioStrategy) ? prices[1:t,:] : prices[1:t]
        
        # Ensure enough data for strategy's lookback period
        min_lookback = if isa(strategy,MovingAverageCrossoverStrategy) strategy.long_window 
                       elseif isa(strategy,MeanReversionStrategy) strategy.lookback_period 
                       elseif isa(strategy,OptimalPortfolioStrategy) 20 # Typical min lookback for covariance matrix
                       else 0 end
        
        current_data_length = isa(market_snap,Vector) ? length(market_snap) : size(market_snap,1)
        
        current_total_value = cash + (isa(strategy,OptimalPortfolioStrategy) ? 
                                        (isempty(trade_log) || !haskey(trade_log[end], :current_portfolio_assets_value) ? 0.0 : trade_log[end].current_portfolio_assets_value) : 
                                        (current_position_units * (isa(prices,Vector) ? prices[t] : 0.0)))
        
        if current_data_length < min_lookback
            push!(portfolio_values, current_total_value)
            continue
        end
        
        exec_res = execute_strategy(strategy, market_snap) # Get strategy signal/weights
        
        if isa(strategy,MovingAverageCrossoverStrategy) || isa(strategy,MeanReversionStrategy)
            signal = get(exec_res,"signal","HOLD")
            asset_price_at_t = isa(prices,Vector) ? prices[t] : 0.0 # Current price for decision
            asset_symbol = get(strategy, :token, DEXToken("","GENERIC_ASSET","",18,1)).symbol # Assuming strategy might have a .token field
            
            # Check for SL/TP hits before processing new signals
            sl_tp_sell_triggered = false
            if current_position_units > 0 && asset_price_at_t > 0
                # Update Trailing Stop High Water Mark and Price
                if trailing_stop_active_for_position
                    if asset_price_at_t > position_high_water_mark
                        position_high_water_mark = asset_price_at_t
                        new_trailing_stop = position_high_water_mark * (1 - current_trailing_stop_pct / 100.0)
                        if new_trailing_stop > active_trailing_stop_price # Ensure TSL only moves up
                            active_trailing_stop_price = new_trailing_stop
                            # Log TSL adjustment if needed for detailed debugging, or just let it update silently
                            # @info "Trailing stop for $asset_symbol adjusted to $active_trailing_stop_price based on new HWM $position_high_water_mark"
                        end
                    end
                end

                # Priority of stop checks: 1. Trailing Stop, 2. Fixed Stop-Loss, 3. Take-Profit
                action_taken_this_step = ""
                
                if trailing_stop_active_for_position && asset_price_at_t <= active_trailing_stop_price
                    action_taken_this_step = "TRAILING_STOP_SELL"
                    @info "Trailing stop triggered for $asset_symbol at $asset_price_at_t (TSL: $active_trailing_stop_price, HWM: $position_high_water_mark)"
                elseif active_stop_loss_price > 0 && asset_price_at_t <= active_stop_loss_price # Fixed SL (active_stop_loss_price > 0 indicates it's set)
                    action_taken_this_step = "STOP_LOSS_SELL"
                    @info "Fixed stop-loss triggered for $asset_symbol at $asset_price_at_t (SL: $active_stop_loss_price)"
                elseif active_take_profit_price != Inf && asset_price_at_t >= active_take_profit_price # Take Profit
                    action_taken_this_step = "TAKE_PROFIT_SELL"
                    @info "Take-profit triggered for $asset_symbol at $asset_price_at_t (TP: $active_take_profit_price)"
                end

                if !isempty(action_taken_this_step)
                    units_to_sell = current_position_units
                    # Slippage for SL/TP/TSL hits is currently based on asset_price_at_t (market price at trigger)
                    # More advanced: could model worse slippage for panic/market orders from stops
                    raw_exit_price_stop = asset_price_at_t 
                    
                    slippage_pct_per_10k_usd_stop = get(slippage_model_params, "pct_per_10k_usd", 0.0)
                    fixed_slippage_pct_stop = get(slippage_model_params, "fixed_pct", 0.0)
                    trade_value_usd_estimate_stop = units_to_sell * raw_exit_price_stop
                    
                    variable_slippage_effect_stop = (trade_value_usd_estimate_stop / 10000.0) * (slippage_pct_per_10k_usd_stop / 100.0) * raw_exit_price_stop
                    fixed_slippage_effect_stop = (fixed_slippage_pct_stop / 100.0) * raw_exit_price_stop
                    total_slippage_per_unit_stop = (units_to_sell > 0) ? (variable_slippage_effect_stop + fixed_slippage_effect_stop) / units_to_sell : 0.0
                    
                    effective_exit_price_stop = raw_exit_price_stop - total_slippage_per_unit_stop
                    effective_exit_price_stop = max(0.0, effective_exit_price_stop)

                    gross_proceeds = units_to_sell * effective_exit_price_stop # Use effective price
                    transaction_fee = gross_proceeds * (tx_cost_pct / 100.0)
                    net_proceeds = gross_proceeds - transaction_fee
                    cost_of_goods_sold = current_position_avg_cost_per_unit * units_to_sell
                    pnl_realized = net_proceeds - cost_of_goods_sold
                    cash += net_proceeds
                    
                    log_entry_details = Dict(
                        :timestamp=>t, :type=>"TRADE", :action=>action_taken_this_step, :token=>asset_symbol, :units=>units_to_sell, 
                        :price_raw_market=>raw_exit_price_stop, :price_effective_fill=>effective_exit_price_stop,
                        :slippage_amount_per_unit=>total_slippage_per_unit_stop,
                        :gross_value=>gross_proceeds, :tx_cost=>transaction_fee, :net_value_change_cash=>net_proceeds,
                        :realized_pnl=>pnl_realized, :avg_cost_basis_of_sold_units=>current_position_avg_cost_per_unit,
                        :cash_balance_after_trade=>cash, :asset_units_after_trade=>0.0
                    )
                    if action_taken_this_step == "TRAILING_STOP_SELL"
                        log_entry_details[:tsl_hit_at] = active_trailing_stop_price
                        log_entry_details[:hwm_at_tsl_hit] = position_high_water_mark
                    elseif action_taken_this_step == "STOP_LOSS_SELL"
                        log_entry_details[:sl_hit_at] = active_stop_loss_price
                    elseif action_taken_this_step == "TAKE_PROFIT_SELL"
                        log_entry_details[:tp_hit_at] = active_take_profit_price
                    end
                    log_entry_details[:fixed_sl_active_at_trade] = active_stop_loss_price # Log other stop levels for context
                    log_entry_details[:tp_active_at_trade] = active_take_profit_price
                    log_entry_details[:trailing_sl_active_at_trade] = trailing_stop_active_for_position
                    log_entry_details[:trailing_sl_price_at_trade] = active_trailing_stop_price


                    # Real-time trade logging
                    try
                        import ..TradeLogger
                        TradeLogger.log_trade(log_entry_details)
                    catch e
                        @warn "TradeLogger failed: $e"
                    end

                    push!(trade_log, NamedTuple(log_entry_details))
                    
                    current_position_units = 0.0; current_position_avg_cost_per_unit = 0.0; 
                    active_stop_loss_price = 0.0; active_take_profit_price = Inf;
                    active_trailing_stop_price = 0.0; position_high_water_mark = 0.0; trailing_stop_active_for_position = false; current_trailing_stop_pct = 0.0;
                    sl_tp_sell_triggered = true
                end
            end

            if !sl_tp_sell_triggered 
                opt_params = isa(strategy, MovingAverageCrossoverStrategy) ? strategy.optimization_params : strategy.optimization_params
                
                # Slippage parameters from slippage_model_params
                slippage_pct_per_10k_usd = get(slippage_model_params, "pct_per_10k_usd", 0.0) 
                fixed_slippage_pct = get(slippage_model_params, "fixed_pct", 0.0)

                if signal=="BUY" && current_position_units == 0 && asset_price_at_t > 0
                    raw_entry_price = asset_price_at_t 
                    sl_pct = get(opt_params, "stop_loss_pct", 5.0)
                    tp_pct = get(opt_params, "take_profit_pct", 10.0)
                    stop_loss_price_for_buy_signal = raw_entry_price * (1 - sl_pct / 100.0) # SL for sizing based on raw price
                    
                    risk_manager.position_sizer.account_balance = cash
                    units_to_buy = RiskManagement.calculate_position_size(risk_manager.position_sizer, raw_entry_price, stop_loss_price_for_buy_signal)
                    
                    if units_to_buy > 0
                        trade_value_usd_estimate = units_to_buy * raw_entry_price
                        
                        # Calculate slippage per unit
                        variable_slippage_effect = (trade_value_usd_estimate / 10000.0) * (slippage_pct_per_10k_usd / 100.0) * raw_entry_price
                        fixed_slippage_effect = (fixed_slippage_pct / 100.0) * raw_entry_price
                        total_slippage_cost_per_unit = (units_to_buy > 0) ? (variable_slippage_effect + fixed_slippage_effect) / units_to_buy : 0.0
                        
                        effective_entry_price = raw_entry_price + total_slippage_cost_per_unit # BUYING: price moves against us
                        
                        gross_cost = units_to_buy * effective_entry_price
                        transaction_fee = gross_cost * (tx_cost_pct / 100.0)
                        net_cost_of_buy = gross_cost + transaction_fee

                        if cash >= net_cost_of_buy
                            cash -= net_cost_of_buy
                            current_position_units = units_to_buy
                            current_position_avg_cost_per_unit = net_cost_of_buy / units_to_buy 
                            
                            active_stop_loss_price = effective_entry_price * (1 - sl_pct / 100.0) 
                            active_take_profit_price = effective_entry_price * (1 + tp_pct / 100.0)
                            
                            # Trailing Stop Initialization
                            current_trailing_stop_pct = get(opt_params, "trailing_stop_pct", 0.0) 
                            if current_trailing_stop_pct > 0.0
                                active_trailing_stop_price = effective_entry_price * (1 - current_trailing_stop_pct / 100.0)
                                position_high_water_mark = effective_entry_price # Initialize HWM with entry price
                                trailing_stop_active_for_position = true
                                @info "BUY: Trailing stop activated for $asset_symbol. Initial TSL: $active_trailing_stop_price (HWM: $position_high_water_mark, Pct: $current_trailing_stop_pct%)"
                            else # Ensure reset if not used for this trade
                                trailing_stop_active_for_position = false
                                active_trailing_stop_price = 0.0
                                position_high_water_mark = 0.0
                            end

                            push!(trade_log, (timestamp=t, type="TRADE", action="BUY", token=asset_symbol, units=units_to_buy, 
                                             price_raw_market=raw_entry_price, price_effective_fill=effective_entry_price, 
                                             slippage_amount_per_unit=total_slippage_cost_per_unit,
                                             gross_value=gross_cost, tx_cost=transaction_fee, net_value_change_cash=(-net_cost_of_buy), 
                                             realized_pnl=nothing, avg_cost_basis_of_new_position=current_position_avg_cost_per_unit,
                                             sl_set_at=active_stop_loss_price, tp_set_at=active_take_profit_price,
                                             trailing_sl_pct_param = current_trailing_stop_pct, initial_trailing_sl_price = trailing_stop_active_for_position ? active_trailing_stop_price : nothing,
                                             cash_balance_after_trade=cash, asset_units_after_trade=current_position_units))
                        else
                            @warn "BUY for $asset_symbol at $t skipped: Insufficient cash ($cash) for net cost ($net_cost_of_buy) after slippage."
                        end
                    end
                elseif (signal=="SELL"||(isa(strategy,MeanReversionStrategy)&&signal=="NEAR_MEAN"&&current_position_units>0)) && current_position_units > 0 && asset_price_at_t > 0
                    units_to_sell = current_position_units 
                    raw_exit_price = asset_price_at_t

                    trade_value_usd_estimate = units_to_sell * raw_exit_price
                    variable_slippage_effect = (trade_value_usd_estimate / 10000.0) * (slippage_pct_per_10k_usd / 100.0) * raw_exit_price
                    fixed_slippage_effect = (fixed_slippage_pct / 100.0) * raw_exit_price
                    total_slippage_loss_per_unit = (units_to_sell > 0) ? (variable_slippage_effect + fixed_slippage_effect) / units_to_sell : 0.0
                    
                    effective_exit_price = raw_exit_price - total_slippage_loss_per_unit # SELLING: price moves against us
                    effective_exit_price = max(0.0, effective_exit_price) 

                    gross_proceeds = units_to_sell * effective_exit_price
                    transaction_fee = gross_proceeds * (tx_cost_pct / 100.0)
                    net_proceeds_from_sell = gross_proceeds - transaction_fee
                    
                    cost_of_goods_sold = current_position_avg_cost_per_unit * units_to_sell
                    pnl_realized = net_proceeds_from_sell - cost_of_goods_sold

                    cash += net_proceeds_from_sell
                    push!(trade_log, (timestamp=t, type="TRADE", action="SIGNAL_SELL", token=asset_symbol, units=units_to_sell, 
                                     price_raw_market=raw_exit_price, price_effective_fill=effective_exit_price,
                                     slippage_amount_per_unit=total_slippage_loss_per_unit,
                                     gross_value=gross_proceeds, tx_cost=transaction_fee, net_value_change_cash=net_proceeds_from_sell,
                                     realized_pnl=pnl_realized, avg_cost_basis_of_sold_units=current_position_avg_cost_per_unit,
                                     sl_active_at_trade=active_stop_loss_price, tp_active_at_trade=active_take_profit_price,
                                     trailing_sl_active_on_sell = trailing_stop_active_for_position, trailing_sl_price_on_sell = active_trailing_stop_price, # Log state of TSL when signal sell occurs
                                     cash_balance_after_trade=cash, asset_units_after_trade=0.0))
                    current_position_units = 0.0; current_position_avg_cost_per_unit = 0.0; 
                    active_stop_loss_price = 0.0; active_take_profit_price = Inf;
                    active_trailing_stop_price = 0.0; position_high_water_mark = 0.0; trailing_stop_active_for_position = false; current_trailing_stop_pct = 0.0; # Reset all stops
                end
            end
            current_asset_value = current_position_units * asset_price_at_t 
            push!(portfolio_values, cash + current_asset_value)

        elseif isa(strategy, ArbitrageStrategy)
            @warn """
            Arbitrage strategy backtesting is initiated. This assumes:
            1. `hist_market_data` (passed as `prices`) is a Vector where each element `prices[t]` 
               is a snapshot of all required market data (multi-DEX, multi-pair prices/liquidity, native asset prices for gas) for that timestep.
            2. The `find_arbitrage_opportunities` function has been refactored to accept this `prices[t]` snapshot 
               and use it for all its data needs, instead of making live calls.
            This refactoring of `find_arbitrage_opportunities` is crucial and not part of this specific update.
            """
            
            # For ArbitrageStrategy, market_snap is the data for the current timestep t
            # This data needs to be in a format that find_arbitrage_opportunities can use.
            # We assume prices[t] is this snapshot.
            market_data_at_t = prices[t] 

            # TODO: Refactor find_arbitrage_opportunities to accept market_data_at_t
            # For now, we'll call it with strategy only, and it will use its live-like calls, 
            # which is NOT a true backtest against historical data unless its internals are changed.
            # ops = find_arbitrage_opportunities(strategy) 
            # Ideal call: ops = find_arbitrage_opportunities(strategy, market_data_at_t)
            
            # Placeholder: For the purpose of this structural update, we'll call the existing
            # find_arbitrage_opportunities. This will NOT reflect a true backtest state
            # without internal changes to find_arbitrage_opportunities.
            @debug "Arbitrage backtest step $t: Calling find_arbitrage_opportunities. Ensure it's using historical data if this is a true backtest."
            ops = find_arbitrage_opportunities(strategy) # This needs to be find_arbitrage_opportunities(strategy, market_data_at_t) after refactor

            if !isempty(ops)
                # Simplified: execute the first profitable opportunity found
                # A more complex backtester might try to execute multiple, or best, or consider capital allocation
                best_op = nothing
                max_profit_pct = -Inf
                for op in ops # Find the op with the highest profit_pct
                    current_op_profit_pct = get(op, "profit_pct", -Inf)
                    if current_op_profit_pct > max_profit_pct
                        max_profit_pct = current_op_profit_pct
                        best_op = op
                    end
                end

                if !isnothing(best_op)
                    op_type = get(best_op, "type", "unknown_arbitrage")
                    op_path = get(best_op, "path", "unknown_path")
                    op_profit_pct = get(best_op, "profit_pct", 0.0) # Percentage
                    op_details = get(best_op, "details", "")
                    
                    # est_gas_cost_usd should ideally be part of the opportunity dict and specific to that op
                    # find_arbitrage_opportunities currently calculates this.
                    # Example: est_gas_cost_usd = get(best_op, "est_gas_cost_usd", 50.0) # Default if not found
                    # The current `find_arbitrage_opportunities` returns `est_gas_cost_usd` for triangular,
                    # and `total_gas_cost_usd` (which is `Est. Gas Cost USD` in details string) for spatial.
                    # We need to parse it or ensure it's consistently named.
                    # For simplicity, let's try to get it from details if not directly available.
                    
                    est_gas_cost_usd = 0.0
                    if haskey(best_op, "est_gas_cost_usd")
                        est_gas_cost_usd = best_op["est_gas_cost_usd"]
                    elseif haskey(best_op, "total_gas_cost_usd") # Older key from some versions
                         est_gas_cost_usd = best_op["total_gas_cost_usd"]
                    elseif occursin("Est. Gas Cost USD: ", op_details)
                        try
                            gas_str = match(r"Est. Gas Cost USD: (\d+\.?\d*)", op_details)[1]
                            est_gas_cost_usd = parse(Float64, gas_str)
                        catch
                            @warn "Could not parse gas cost from op_details: $op_details"
                            est_gas_cost_usd = 50.0 # Fallback
                        end
                    else
                         @warn "Gas cost not found in opportunity, using default."
                         est_gas_cost_usd = 50.0 # Fallback
                    end


                    trade_value_usd = strategy.max_trade_size_usd # Arbitrage attempts to use this capital
                    
                    # Profit calculation based on effective prices (which includes slippage) and gas costs
                    # The profit_pct from find_arbitrage_opportunities should already be net of slippage but gross of gas.
                    # So, gross_profit_usd_from_op_pct = trade_value_usd * (op_profit_pct / 100.0)
                    # net_profit_usd = gross_profit_usd_from_op_pct - est_gas_cost_usd
                    # However, the `profit_pct` in `find_arbitrage_opportunities` is already net of estimated gas for spatial.
                    # For triangular, it's also net. Let's assume op_profit_pct is net profit.
                    
                    # Re-evaluating: find_arbitrage_opportunities returns "profit_pct" which is NET of gas and slippage.
                    net_profit_usd = trade_value_usd * (op_profit_pct / 100.0)


                    if cash + net_profit_usd >= 0 # Ensure arb doesn't bankrupt (e.g. huge gas, small profit)
                        cash += net_profit_usd
                        push!(trade_log, (
                            timestamp=t, type="ARBITRAGE", action=op_type, token_path=op_path,
                            units=NaN, # Units are complex for arbitrage, depends on legs
                            price=NaN, # Price is also complex
                            trade_value_usd=trade_value_usd,
                            gross_profit_estimate_pct=op_profit_pct, # This is net of slippage and gas from find_arbitrage
                            est_gas_cost_usd=est_gas_cost_usd, # For record keeping
                            net_realized_pnl_usd=net_profit_usd,
                            cash_balance_after_trade=cash,
                            details=op_details
                        ))
                        @info "Arbitrage executed: $op_type on $op_path, Net Profit USD: $net_profit_usd"
                    else
                        @warn "Arbitrage opportunity skipped due to negative cash impact: $op_path, Profit USD: $net_profit_usd"
                    end
                end
            end
            # For arbitrage, portfolio value is typically just cash unless it holds inventory (not modeled here)
            push!(portfolio_values, cash)

        elseif isa(strategy,OptimalPortfolioStrategy)
            target_weights = get(get(exec_res,"result",Dict{String,Any}()),"optimal_weights",nothing)
                transaction_fee = gross_cost * (tx_cost_pct / 100.0)
                net_cost_of_buy = gross_cost + transaction_fee

                if cash >= net_cost_of_buy && units_to_buy > 0
                    cash -= net_cost_of_buy
                    
                    # Update position and cost basis
                    # total_cost_of_new_units = net_cost_of_buy (already includes fees)
                    # new_total_value_at_cost = (current_position_units * current_position_avg_cost_per_unit) + total_cost_of_new_units
                    # current_position_units += units_to_buy
                    # current_position_avg_cost_per_unit = current_position_units > 0 ? new_total_value_at_cost / current_position_units : 0.0
                    # Simplified: since we only buy if cur_units == 0, avg_cost is just cost/units for this buy
                    current_position_units = units_to_buy
                    current_position_avg_cost_per_unit = net_cost_of_buy / units_to_buy

                    push!(trade_log, (timestamp=t, action="BUY", token=asset_symbol, units=units_to_buy, price=asset_price_at_t, 
                                     gross_value=gross_cost, tx_cost=transaction_fee, net_value_change_cash=(-net_cost_of_buy), 
                                     realized_pnl=nothing, avg_cost_basis=current_position_avg_cost_per_unit))
                end
            elseif (signal=="SELL" || (isa(strategy,MeanReversionStrategy) && signal=="NEAR_MEAN" && current_position_units > 0)) && current_position_units > 0 && asset_price_at_t > 0
                units_to_sell = current_position_units # Sell all
                gross_proceeds = units_to_sell * asset_price_at_t
                transaction_fee = gross_proceeds * (tx_cost_pct / 100.0)
                net_proceeds_from_sell = gross_proceeds - transaction_fee
                
                cost_of_goods_sold = current_position_avg_cost_per_unit * units_to_sell
                pnl_realized = net_proceeds_from_sell - cost_of_goods_sold

                cash += net_proceeds_from_sell
                push!(trade_log, (timestamp=t, action="SELL", token=asset_symbol, units=units_to_sell, price=asset_price_at_t,
                                 gross_value=gross_proceeds, tx_cost=transaction_fee, net_value_change_cash=net_proceeds_from_sell,
                                 realized_pnl=pnl_realized, avg_cost_basis=current_position_avg_cost_per_unit))
                current_position_units = 0.0
                current_position_avg_cost_per_unit = 0.0
            end
            current_asset_value = current_position_units * asset_price_at_t
            push!(portfolio_values, cash + current_asset_value)

        elseif isa(strategy,OptimalPortfolioStrategy)
            target_weights = get(get(exec_res,"result",Dict{String,Any}()),"optimal_weights",nothing)
            current_asset_prices = prices[t,:] # Vector of prices for all tokens in portfolio
            current_portfolio_assets_value = 0.0 # This will be sum of individual asset values if tracked

            # Step 1: Simulate selling all current holdings to rebalance (simplified)
            # This needs to be more granular if we track individual asset positions and P&L
            # For now, assume 'pos_val' from previous step is liquidated
            
            # Calculate value of current holdings before rebalance
            # This requires knowing current units of each asset if we were tracking them.
            # The old `pos_val` was a single float. Let's assume it represents the sum of market values.
            # If `trade_log` is not empty and last entry has `current_portfolio_assets_value`
            value_of_holdings_before_rebalance = if isempty(trade_log) || !haskey(trade_log[end], :current_portfolio_assets_value)
                # If it's the first rebalance, pos_val might be 0 or based on initial state.
                # This part is tricky without full per-asset tracking from t=1.
                # Let's assume if no prior rebalance, pos_val is 0 for this calculation.
                # Or, better, use the portfolio_values[-1] - cash.
                length(portfolio_values) > 1 ? portfolio_values[end] - cash : 0.0
            else
                trade_log[end].current_portfolio_assets_value # Value from *after* last rebalance, aged by price changes
                # This is still an approximation. True value requires pricing each asset holding.
                # For simplicity, let's use (portfolio_values[end] - cash) as market value of assets.
                portfolio_values[end] - cash 
            end


            if !isnothing(target_weights) && value_of_holdings_before_rebalance > 0 # If there's something to sell
                sell_tx_cost = value_of_holdings_before_rebalance * (tx_cost_pct / 100.0)
                cash += (value_of_holdings_before_rebalance - sell_tx_cost)
                push!(trade_log, (timestamp=t, action="REBALANCE_SELL_ALL", token="PORTFOLIO", units=NaN, price=NaN,
                                 gross_value=value_of_holdings_before_rebalance, tx_cost=sell_tx_cost, net_value_change_cash=(value_of_holdings_before_rebalance - sell_tx_cost),
                                 realized_pnl=nothing)) # PNL for portfolio sell is complex, sum of individual asset P&Ls
            end
            
            # Cash available for buying new positions
            cash_for_new_buys = cash # All cash is now available
            total_value_for_reallocation = cash_for_new_buys # This is the new "total portfolio value" to allocate based on weights

            new_portfolio_holdings_value_after_buy = 0.0
            if !isnothing(target_weights)
                for (idx, weight) in enumerate(target_weights)
                    token_symbol = strategy.tokens[idx].symbol
                    asset_price_now = current_asset_prices[idx]
                    
                    intended_value_of_asset = total_value_for_reallocation * weight
                    # Cost to acquire this position, including transaction fee
                    buy_tx_cost_for_asset = intended_value_of_asset * (tx_cost_pct / 100.0)
                    net_cost_for_asset_buy = intended_value_of_asset + buy_tx_cost_for_asset
                    
                    units_of_asset_to_buy = asset_price_now > 0 ? intended_value_of_asset / asset_price_now : 0.0

                    if cash >= net_cost_for_asset_buy && units_of_asset_to_buy > 0
                        cash -= net_cost_for_asset_buy
                        new_portfolio_holdings_value_after_buy += intended_value_of_asset # Value at current market prices, pre-fee for this portion
                        push!(trade_log, (timestamp=t, action="REBALANCE_BUY", token=token_symbol, units=units_of_asset_to_buy, price=asset_price_now,
                                         gross_value=intended_value_of_asset, tx_cost=buy_tx_cost_for_asset, net_value_change_cash=(-net_cost_for_asset_buy),
                                         realized_pnl=nothing, target_weight=weight))
                    else
                        # Could log a warning if unable to achieve target weight due to cash or price
                    end
                end
            end
            # Store the market value of assets held after rebalancing for the next step's reference
            # This is an important field for the next iteration if OptimalPortfolioStrategy
             if !isempty(trade_log) && trade_log[end].action == "REBALANCE_BUY" # Add to the last buy entry or a summary entry
                 # This is a bit hacky. Better to have a portfolio state object.
                 # For now, let's assume the last entry can hold this.
                 # Or, add a specific log entry for portfolio state.
                 # Let's just use cash + new_portfolio_holdings_value_after_buy for portfolio_values
             end
            push!(portfolio_values, cash + new_portfolio_holdings_value_after_buy)
            # Add current_portfolio_assets_value to the last trade log entry if it was a rebalance
            if !isempty(trade_log) && occursin("REBALANCE", trade_log[end].action)
                # Create a new NamedTuple for the last entry by merging existing and adding the new field
                last_entry = trade_log[end]
                trade_log[end] = merge(last_entry, (current_portfolio_assets_value=new_portfolio_holdings_value_after_buy,))
            end
        else
             # If strategy type is unknown or no action taken, just carry forward portfolio value
            push!(portfolio_values, portfolio_values[end]) # Should be current_total_value if no trades
        end
        
        # Portfolio-level risk check (e.g., max drawdown)
        if !RiskManagement.check_risk_limits(risk_manager, portfolio_values[end])
            @warn "Portfolio risk limit violated at step $t. Portfolio value: $(portfolio_values[end])"
            # Optionally, could halt backtest or take other actions here
        end
    end
    
    final_value = portfolio_values[end]
    total_return_pct = (final_value / initial_capital - 1.0) * 100.0
    
    # Calculate Sharpe Ratio (approximate, using simple daily returns)
    daily_returns = diff(log.(filter(x->x>0, portfolio_values))) # Ensure positive values for log
    sharpe_ratio = 0.0
    if !isempty(daily_returns) && length(daily_returns) > 1 && std(daily_returns) > 1e-9 # Need at least 2 returns for std
        sharpe_ratio = (mean(daily_returns) * sqrt(td_per_year)) / std(daily_returns)
    end
    
    # Calculate Max Drawdown
    peak_value = initial_capital
    max_drawdown_pct = 0.0
    for val in portfolio_values
        val <= 0 && continue # Skip non-positive values for drawdown calculation if they occur
        peak_value = max(peak_value, val)
        drawdown = (peak_value - val) / peak_value
        max_drawdown_pct = max(max_drawdown_pct, drawdown)
    end
    max_drawdown_pct *= 100.0

    # Enhanced Performance Metrics Calculation
    num_winning_trades = 0
    num_losing_trades = 0
    total_gross_profit = 0.0
    total_gross_loss = 0.0
    
    pnl_generating_trades = filter(entry -> haskey(entry, :realized_pnl) && !isnothing(entry.realized_pnl), trade_log)
    total_pnl_trades = length(pnl_generating_trades)

    for entry in pnl_generating_trades
        pnl = entry.realized_pnl
        if pnl > 0
            num_winning_trades += 1
            total_gross_profit += pnl
        elseif pnl < 0
            num_losing_trades += 1
            total_gross_loss += abs(pnl)
        end
    end

    win_rate = total_pnl_trades > 0 ? num_winning_trades / total_pnl_trades : 0.0
    loss_rate = total_pnl_trades > 0 ? num_losing_trades / total_pnl_trades : 0.0
    avg_win_amount = num_winning_trades > 0 ? total_gross_profit / num_winning_trades : 0.0
    avg_loss_amount = num_losing_trades > 0 ? total_gross_loss / num_losing_trades : 0.0
    profit_factor = total_gross_loss > 0 ? total_gross_profit / total_gross_loss : Inf # Handle case of no losses
    payoff_ratio = avg_loss_amount > 0 ? avg_win_amount / avg_loss_amount : Inf # Handle case of no losing trades or no wins

    return Dict("name"=>strategy.name,
                "initial_capital"=>initial_capital,
                "final_value"=>final_value,
                "total_return_pct"=>total_return_pct,
                "sharpe_ratio_approx"=>sharpe_ratio,
                "max_drawdown_pct"=>max_drawdown_pct,
                "num_total_trades_logged"=>length(trade_log),
                "num_pnl_trades"=>total_pnl_trades,
                "num_winning_trades"=>num_winning_trades,
                "num_losing_trades"=>num_losing_trades,
                "total_gross_profit"=>total_gross_profit,
                "total_gross_loss"=>total_gross_loss,
                "win_rate_pct"=>win_rate * 100.0,
                "loss_rate_pct"=>loss_rate * 100.0,
                "avg_win_amount"=>avg_win_amount,
                "avg_loss_amount"=>avg_loss_amount,
                "profit_factor"=>profit_factor,
                "payoff_ratio"=>payoff_ratio,
                "trade_log_preview"=>trade_log[1:min(5,length(trade_log))], 
                "full_trade_log"=>trade_log, 
                "portfolio_value_over_time"=>portfolio_values)
end
export backtest_strategy 

include("RiskManagement.jl")
include("MovingAverageStrategy.jl")
include("MeanReversionImpl.jl")

using .RiskManagement
export RiskParameters, PositionSizer, StopLossManager, RiskManager 
export calculate_position_size, set_stop_loss, set_take_profit, check_risk_limits 
export calculate_value_at_risk, calculate_expected_shortfall, calculate_kelly_criterion 

using .MovingAverageStrategy
export MovingAverageCrossoverStrategy 

using .MeanReversionImpl
export MeanReversionStrategy 

end # module TradingStrategy
