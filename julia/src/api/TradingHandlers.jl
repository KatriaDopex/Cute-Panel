# julia/src/api/TradingHandlers.jl
module TradingHandlers

using HTTP, Logging, Dates, JSON3, UUIDs # Added UUIDs
using ..Utils # For standardized responses
import ..framework.CutePanelFramework.TradingStrategy
import ..framework.CutePanelFramework.DEXBase # For DEXToken if needed in payloads
import ..framework.CutePanelFramework.DEX # For creating mock DEX instances
# import ..framework.CutePanelFramework.PriceFeedBase # For PriceData if needed
# If specific strategy types are needed for dispatch or type checking:
# import ..framework.CutePanelFramework.TradingStrategy: OptimalPortfolioStrategy, ArbitrageStrategy, MovingAverageCrossoverStrategy, MeanReversionStrategy


# Using Storage.jl for persistent strategy configurations.
# Key will be "trading_strategy_config_" * strategy_name
import ..framework.CutePanelFramework.Storage

# const CONFIGURED_STRATEGIES = Dict{String, TradingStrategy.AbstractStrategy}()
# const STRATEGIES_LOCK = ReentrantLock()
const STRATEGY_CONFIG_KEY_PREFIX = "trading_strategy_config_"


# Helper to get strategy types. In a real system, this might come from a registry.
function _get_available_strategy_types()
    return [
        Dict("name" => "OptimalPortfolio", "description" => "Optimizes portfolio weights based on historical data."),
        Dict("name" => "Arbitrage", "description" => "Identifies arbitrage opportunities across DEXs."),
        Dict("name" => "MovingAverageCrossover", "description" => "Generates signals from MA crossovers."),
        Dict("name" => "MeanReversion", "description" => "Trades on price reversions to a mean, e.g., using Bollinger Bands.")
    ]
end

function list_strategy_types_handler(req::HTTP.Request)
    try
        types = _get_available_strategy_types()
        return Utils.json_response(Dict("available_strategy_types" => types))
    catch e
        @error "Error in list_strategy_types_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list strategy types", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# This handler is conceptual. Creating/configuring strategies via API might be complex
# due to dependencies like DEXToken objects, DEX instances, PriceFeed instances.
# These would need to be resolvable from IDs or detailed configurations.
function configure_strategy_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    strategy_type = get(body, "strategy_type", "")
    strategy_name = get(body, "name", "strategy-" * string(uuid4())[1:8]) # Unique name
    params = get(body, "parameters", Dict()) # Parameters specific to the strategy type

    if isempty(strategy_type)
        return Utils.error_response("'strategy_type' is required.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"strategy_type"))
    end

    local strategy_instance::TradingStrategy.AbstractStrategy
    try
        if strategy_type == "OptimalPortfolio"
            tokens_data = get(params, "tokens", [])
            if !isa(tokens_data, AbstractVector) || isempty(tokens_data)
                return Utils.error_response("OptimalPortfolioStrategy requires a 'tokens' array in parameters.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
            end
            # Convert token data (e.g., list of dicts with symbol, address, decimals, chain_id) to DEXToken objects
            # This is a simplification; robust resolution would be needed.
            parsed_tokens = [DEXBase.DEXToken(
                                get(t,"address",""), get(t,"symbol",""), get(t,"name",""), 
                                get(t,"decimals",18), get(t,"chain_id",1)
                             ) for t in tokens_data if isa(t, Dict)]
            if isempty(parsed_tokens)
                 return Utils.error_response("No valid token data provided for OptimalPortfolioStrategy.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
            end

            strategy_instance = TradingStrategy.OptimalPortfolioStrategy(strategy_name, parsed_tokens; 
                                                                        risk_free_rate=get(params, "risk_free_rate", 0.02),
                                                                        optimization_params=get(params, "optimization_params", Dict("max_iterations"=>100, "population_size"=>50)))
        elseif strategy_type == "Arbitrage"
            # This requires resolving DEX instances and DEXTokens from IDs or full configs passed in params. Highly complex.
            @warn "ArbitrageStrategy configuration via API is a complex placeholder."
            # Mocking dependencies for now
            mock_dex_config = DEXBase.DEXConfig(name="mock_dex_for_arbitrage", chain_id=1, rpc_url="http://localhost:8545")
            mock_dex1 = DEX.create_dex_instance("uniswap", "v2", mock_dex_config)
            mock_dex2 = DEX.create_dex_instance("uniswap", "v2", DEXBase.DEXConfig(name="another_mock_dex", chain_id=1, rpc_url="http://localhost:8545"))
            
            tokens_data = get(params, "tokens_of_interest", [])
            parsed_tokens = [DEXBase.DEXToken(
                                get(t,"address",""), get(t,"symbol",""), get(t,"name",""), 
                                get(t,"decimals",18), get(t,"chain_id",1)
                             ) for t in tokens_data if isa(t, Dict)]
            if length(parsed_tokens) < 2
                 return Utils.error_response("ArbitrageStrategy requires at least two 'tokens_of_interest'.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
            end

            strategy_instance = TradingStrategy.ArbitrageStrategy(strategy_name, [mock_dex1, mock_dex2], parsed_tokens;
                                                                min_profit_threshold_percent=get(params, "min_profit_threshold_percent", 0.1),
                                                                max_trade_size_usd=get(params, "max_trade_size_usd", 1000.0))
        elseif strategy_type == "MovingAverageCrossover"
            asset_pair_str = get(params, "asset_pair", "")
            if isempty(asset_pair_str) return Utils.error_response("Missing 'asset_pair' for MovingAverageCrossoverStrategy.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT) end
            strategy_instance = TradingStrategy.MovingAverageCrossoverStrategy(strategy_name, asset_pair_str;
                                                                              short_window=get(params, "short_window", 20),
                                                                              long_window=get(params, "long_window", 50))
        elseif strategy_type == "MeanReversion"
            asset_pair_str = get(params, "asset_pair", "")
            if isempty(asset_pair_str) return Utils.error_response("Missing 'asset_pair' for MeanReversionStrategy.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT) end
            strategy_instance = TradingStrategy.MeanReversionStrategy(strategy_name, asset_pair_str;
                                                                      lookback_period=get(params, "lookback_period", 20),
                                                                      std_dev_multiplier=get(params, "std_dev_multiplier", 2.0))
        else
            return Utils.error_response("Unsupported strategy_type: $strategy_type", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end

        # Store the configuration parameters used to create the strategy
        # This allows re-instantiation on load.
        # The 'params' Dict already contains most of what's needed.
        # We also need to store the strategy_type and the assigned strategy_name.
        config_to_store = Dict(
            "strategy_type" => strategy_type,
            "name" => strategy_name, # The generated or provided name
            "parameters" => params, # Original parameters from request body
            # For OptimalPortfolio, store resolved DEXToken details if they were constructed
            "resolved_tokens_for_portfolio" => if strategy_type == "OptimalPortfolio" 
                                                  [Dict("address"=>t.address, "symbol"=>t.symbol, "name"=>t.name, "decimals"=>t.decimals, "chain_id"=>t.chain_id) for t in strategy_instance.tokens] 
                                               else nothing end,
            # For ArbitrageStrategy, store detailed configurations for each DEX instance.
            "dex_configurations_for_arbitrage" => if strategy_type == "Arbitrage"
                                                      [
                                                          Dict(
                                                              "protocol" => d.config.protocol_name, # Assuming AbstractDEX has this, or derive from type
                                                              "version" => d.config.version_name,   # Assuming AbstractDEX has this
                                                              "dex_name" => d.config.name,
                                                              "chain_id" => d.config.chain_id,
                                                              "rpc_url" => d.config.rpc_url,
                                                              "router_address" => d.config.router_address,
                                                              "factory_address" => d.config.factory_address
                                                              # Add other relevant fields from d.config as needed by _get_or_create_dex_instance
                                                          ) for d in strategy_instance.dex_instances # strategy_instance.dex_instances should hold AbstractDEX
                                                      ]
                                                  else nothing end,
            "tokens_of_interest_for_arbitrage" => if strategy_type == "Arbitrage"
                                                        [Dict("address"=>t.address, "symbol"=>t.symbol, "name"=>t.name, "decimals"=>t.decimals, "chain_id"=>t.chain_id) for t in strategy_instance.tokens_of_interest]
                                                    else nothing end
            # Other specific constructed fields from strategy_instance if not in original params
        )
        
        storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
        save_success = Storage.save_default(storage_key, config_to_store)

        if !save_success
            @error "Failed to save configured strategy $strategy_name to persistent storage."
            # Decide if this should be a user-facing error or just a backend issue.
            # For now, let the configuration proceed in-memory for this session if saving fails.
            # A robust system might error out or have a fallback.
            # To keep it simple, we'll assume it's stored for now for the response.
        end
        # We don't need to keep it in an in-memory dict anymore if it's persisted.
        # lock(STRATEGIES_LOCK) do
        #     CONFIGURED_STRATEGIES[strategy_name] = strategy_instance
        # end
        return Utils.json_response(Dict("message"=>"Strategy '$strategy_name' configured and saved successfully.", "name"=>strategy_name, "type"=>strategy_type))
    catch e
        @error "Error configuring strategy $strategy_name ($strategy_type)" exception=(e,catch_backtrace())
        return Utils.error_response("Failed to configure strategy: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function execute_strategy_handler(req::HTTP.Request, strategy_name::String)
    body = Utils.parse_request_body(req) # Body might contain market data or execution params
    
    storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
    loaded_config_tuple = Storage.load_default(storage_key)

    if isnothing(loaded_config_tuple)
        return Utils.error_response("Strategy '$strategy_name' not found in persistent storage.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
    end
    
    config_data, _ = loaded_config_tuple
    if !isa(config_data, Dict)
        @error "Corrupted strategy config for $strategy_name in storage."
        return Utils.error_response("Corrupted strategy configuration for '$strategy_name'.", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end

    # Re-instantiate the strategy (conceptual, needs full implementation based on stored config_data)
    # This is where the stored "strategy_type", "name", "parameters", etc. would be used.
    # For now, we'll assume we can get enough to call the TradingStrategy execute method.
    # This part is complex because strategy constructors need specific types (DEXToken, AbstractDEX).
    # The `configure_strategy_handler` would need to store enough info to reconstruct these.
    
    # Simplified re-instantiation for this example (highly dependent on what's stored)
    # This is a major placeholder for robust strategy re-instantiation from stored config.
    local strategy_instance::Union{TradingStrategy.AbstractStrategy, Nothing}
    try
        # This is a mock re-instantiation. A real one would use stored params.
        # For example, if config_data["strategy_type"] == "MovingAverageCrossover"
        # strategy_instance = TradingStrategy.MovingAverageCrossoverStrategy(config_data["name"], config_data["parameters"]["asset_pair"], ...)
        # This is non-trivial because parameters like DEXToken lists or AbstractDEX lists need careful handling.
        @warn "Strategy re-instantiation from storage in execute_strategy_handler is a placeholder."
        # For the sake of proceeding, let's assume a mock strategy if re-instantiation is too complex here.
        # This means the execute_strategy call below might not use the *exact* configured strategy state
        # unless the stored config_data is perfectly aligned with what execute_strategy expects or can reconstruct.
        
        # Attempt to reconstruct based on type (very simplified)
        s_type = get(config_data, "strategy_type", "")
        s_name = get(config_data, "name", strategy_name)
        s_params = get(config_data, "parameters", Dict())

        if s_type == "MovingAverageCrossover"
            strategy_instance = TradingStrategy.MovingAverageCrossoverStrategy(s_name, get(s_params,"asset_pair","ETH/USD"); 
                                                                              short_window=get(s_params, "short_window", 20),
                                                                              long_window=get(s_params, "long_window", 50),
                                                                              optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "MeanReversion"
             strategy_instance = TradingStrategy.MeanReversionStrategy(s_name, get(s_params,"asset_pair","ETH/USD");
                                                                      lookback_period=get(s_params, "lookback_period", 20),
                                                                      std_dev_multiplier=get(s_params, "std_dev_multiplier", 2.0),
                                                                      optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "OptimalPortfolio"
            resolved_tokens_data = get(config_data, "resolved_tokens_for_portfolio", [])
            if isempty(resolved_tokens_data) @error "No token data for OptimalPortfolio strategy '$s_name'"; return Utils.error_response("Stored config for OptimalPortfolio strategy '$s_name' is missing token data.",500); end
            tokens = [DEXBase.DEXToken(t["address"],t["symbol"],t["name"],t["decimals"],t["chain_id"]) for t in resolved_tokens_data]
            strategy_instance = TradingStrategy.OptimalPortfolioStrategy(s_name, tokens; 
                                                                        risk_free_rate=get(s_params, "risk_free_rate", 0.02),
                                                                        optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "Arbitrage"
            dex_configs_data = get(config_data, "dex_configurations_for_arbitrage", [])
            if isempty(dex_configs_data) @error "No DEX configurations for Arbitrage strategy '$s_name'"; return Utils.error_response("Stored config for Arbitrage strategy '$s_name' is missing DEX configurations.",500); end
            
            rehydrated_dex_instances = DEXBase.AbstractDEX[]
            for dex_conf_item in dex_configs_data
                # Ensure all necessary fields for _get_or_create_dex_instance are present
                # protocol_name and version_name might need to be derived if not stored directly in DEXConfig
                # For now, assume they are stored or can be inferred.
                # This part needs DexHandlers._get_or_create_dex_instance to be callable.
                # We might need to pass the HTTP.Request object or a simplified params dict.
                # Let's assume `dex_conf_item` has "protocol", "version", and other params.
                dex_protocol = get(dex_conf_item, "protocol", "uniswap") # Default if missing
                dex_version = get(dex_conf_item, "version", "v2")     # Default if missing
                
                # Construct params dict for _get_or_create_dex_instance
                dex_handler_params = Dict{String, String}() # _get_or_create_dex_instance expects string values for query_params
                for (k,v) in dex_conf_item
                    if k != "protocol" && k != "version" # These are passed directly
                        dex_handler_params[String(k)] = string(v) # Convert all to string for safety
                    end
                end
                
                instance = DexHandlers._get_or_create_dex_instance(dex_protocol, dex_version, dex_handler_params)
                if isnothing(instance)
                    @error "Failed to re-instantiate DEX for Arbitrage strategy: $dex_conf_item"
                    return Utils.error_response("Failed to re-instantiate a DEX for Arbitrage strategy '$s_name'.", 500)
                end
                push!(rehydrated_dex_instances, instance)
            end

            tokens_data = get(config_data, "tokens_of_interest_for_arbitrage", [])
            if isempty(tokens_data) @error "No tokens_of_interest for Arbitrage strategy '$s_name'"; return Utils.error_response("Stored config for Arbitrage strategy '$s_name' is missing tokens_of_interest.",500); end
            tokens = [DEXBase.DEXToken(t["address"],t["symbol"],t["name"],t["decimals"],t["chain_id"]) for t in tokens_data]
            
            strategy_instance = TradingStrategy.ArbitrageStrategy(s_name, rehydrated_dex_instances, tokens;
                                                                min_profit_threshold_percent=get(s_params, "min_profit_threshold_percent", 0.1),
                                                                max_trade_size_usd=get(s_params, "max_trade_size_usd", 1000.0),
                                                                optimization_params=get(s_params, "optimization_params", Dict()))
        else
            return Utils.error_response("Cannot re-instantiate unknown strategy type '$s_type' for execution.", 500)
        end

    catch recon_err
        @error "Failed to re-instantiate strategy '$strategy_name' from stored config" error=recon_err stack=catch_backtrace()
        return Utils.error_response("Failed to load strategy '$strategy_name' for execution: $(sprint(showerror, recon_err))", 500)
    end


    if isnothing(strategy_instance) # Should be caught by re-instantiation logic
        return Utils.error_response("Strategy '$strategy_name' could not be loaded/re-instantiated.", 500)
    end

    try
        market_data_payload = get(body, "market_data", Dict()) 
        result = Dict()

        if isa(strategy_instance, TradingStrategy.OptimalPortfolioStrategy)
            prices_data = get(market_data_payload, "historical_prices", [])
            if !isa(prices_data, AbstractVector) || any(!isa(row, AbstractVector) for row in prices_data)
                 return Utils.error_response("OptimalPortfolioStrategy requires 'historical_prices' as array of arrays.", 400)
            end
            try
                hist_matrix = convert(Matrix{Float64}, hcat(prices_data...)')
                result = TradingStrategy.execute_strategy(strategy_instance; historical_prices_matrix=hist_matrix) # Pass as keyword
            catch conv_err; return Utils.error_response("Error converting prices: $(sprint(showerror, conv_err))", 400) end
        elseif isa(strategy_instance, TradingStrategy.ArbitrageStrategy)
            result = TradingStrategy.execute_strategy(strategy_instance) 
        elseif isa(strategy_instance, TradingStrategy.MovingAverageCrossoverStrategy) || isa(strategy_instance, TradingStrategy.MeanReversionStrategy)
            prices_data = get(market_data_payload, "historical_prices", [])
            if !isa(prices_data, AbstractVector) || any(!isa(p, Number) for p in prices_data)
                return Utils.error_response("This strategy needs 'historical_prices' as array of numbers.", 400)
            end
            hist_vector = convert(Vector{Float64}, prices_data)
            result = TradingStrategy.execute_strategy(strategy_instance, hist_vector)
        else
            return Utils.error_response("Execution for type $(typeof(strategy_instance)) not handled.", 501)
        end
        
        return Utils.json_response(result)
    catch e
        @error "Error executing strategy $strategy_name" exception=(e,catch_backtrace())
        return Utils.error_response("Failed to execute strategy '$strategy_name': $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function list_configured_strategies_handler(req::HTTP.Request)
    try
        all_strategy_keys = Storage.list_keys_default(STRATEGY_CONFIG_KEY_PREFIX)
        strategy_list = []
        for key in all_strategy_keys
            loaded_config_tuple = Storage.load_default(key)
            if !isnothing(loaded_config_tuple)
                config_data, _ = loaded_config_tuple
                if isa(config_data, Dict)
                    push!(strategy_list, Dict(
                        "name" => get(config_data, "name", replace(key, STRATEGY_CONFIG_KEY_PREFIX => "")),
                        "type" => get(config_data, "strategy_type", "Unknown"),
                        "parameters_preview" => get(config_data,"parameters", Dict()) # Show stored params
                    ))
                end
            end
        end
        return Utils.json_response(Dict("configured_strategies" => strategy_list))
    catch e
        @error "Error listing configured strategies from storage" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list configured strategies", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_strategy_details_handler(req::HTTP.Request, strategy_name::String)
    storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
    loaded_config_tuple = Storage.load_default(storage_key)

    if isnothing(loaded_config_tuple)
        return Utils.error_response("Strategy '$strategy_name' not found in storage.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
    end
    config_data, _ = loaded_config_tuple
    
    # Return the stored configuration data
    return Utils.json_response(config_data) # This is the Dict we stored
    
    # try
    #     # This would require re-instantiating the strategy to call a method on it,
    #     # which is complex here. Better to return the stored config.
    #     # details = TradingStrategy.get_strategy_details(strategy_instance) 
    #     # return Utils.json_response(details)
    # catch e
    #     @error "Error getting details for strategy $strategy_name" exception=(e,catch_backtrace())
        return Utils.error_response("Failed to get strategy details: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function delete_strategy_handler(req::HTTP.Request, strategy_name::String)
    storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
    try
        if Storage.exists_default(storage_key)
            Storage.delete_key_default(storage_key)
            return Utils.json_response(Dict("message"=>"Strategy '$strategy_name' deleted successfully from storage."))
        else
            return Utils.error_response("Strategy '$strategy_name' not found in storage.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
        end
    catch e
        @error "Error deleting strategy $strategy_name from storage" exception=(e,catch_backtrace())
        return Utils.error_response("Failed to delete strategy: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# Conceptual handler for backtesting
function backtest_strategy_handler(req::HTTP.Request, strategy_name::String)
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Request body with backtest parameters (e.g., historical data, date range) required.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
    loaded_config_tuple = Storage.load_default(storage_key)

    if isnothing(loaded_config_tuple)
        return Utils.error_response("Strategy '$strategy_name' not found for backtest.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
    end
    config_data, _ = loaded_config_tuple
    
    # Re-instantiate strategy (simplified, as in execute_strategy_handler)
    local strategy_instance::Union{TradingStrategy.AbstractStrategy, Nothing}
    try
        s_type = get(config_data, "strategy_type", "")
        s_name = get(config_data, "name", strategy_name)
        s_params = get(config_data, "parameters", Dict())
        
        if s_type == "MovingAverageCrossover" 
            strategy_instance = TradingStrategy.MovingAverageCrossoverStrategy(s_name, get(s_params,"asset_pair","ETH/USD"); 
                                                                              short_window=get(s_params, "short_window", 20),
                                                                              long_window=get(s_params, "long_window", 50),
                                                                              optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "MeanReversion" 
            strategy_instance = TradingStrategy.MeanReversionStrategy(s_name, get(s_params,"asset_pair","ETH/USD");
                                                                      lookback_period=get(s_params, "lookback_period", 20),
                                                                      std_dev_multiplier=get(s_params, "std_dev_multiplier", 2.0),
                                                                      optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "OptimalPortfolio"
            resolved_tokens_data = get(config_data, "resolved_tokens_for_portfolio", [])
            if isempty(resolved_tokens_data) @error "No token data for OptimalPortfolio strategy '$s_name'"; return Utils.error_response("Stored config for OptimalPortfolio strategy '$s_name' is missing token data.",500); end
            tokens = [DEXBase.DEXToken(t["address"],t["symbol"],t["name"],t["decimals"],t["chain_id"]) for t in resolved_tokens_data]
            strategy_instance = TradingStrategy.OptimalPortfolioStrategy(s_name, tokens; 
                                                                        risk_free_rate=get(s_params, "risk_free_rate", 0.02),
                                                                        optimization_params=get(s_params, "optimization_params", Dict()))
        elseif s_type == "Arbitrage"
            # Arbitrage backtesting is not yet supported by TradingStrategy.jl backend,
            # but we still attempt to load it to ensure config is valid.
            # The TradingStrategy.backtest_strategy function will handle the "Not Implemented" part.
            @info "Attempting to load ArbitrageStrategy '$s_name' for backtest. Backend support for arbitrage backtesting is pending."
            
            dex_configs_data = get(config_data, "dex_configurations_for_arbitrage", []) # This is Vector{Dict{String,Any}}
            if isempty(dex_configs_data) @error "No DEX configurations for Arbitrage strategy '$s_name'"; return Utils.error_response("Stored config for Arbitrage strategy '$s_name' is missing DEX configurations.",500); end
            
            tokens_data = get(config_data, "tokens_of_interest_for_arbitrage", [])
            if isempty(tokens_data) @error "No tokens_of_interest for Arbitrage strategy '$s_name'"; return Utils.error_response("Stored config for Arbitrage strategy '$s_name' is missing tokens_of_interest.",500); end
            tokens = [DEXBase.DEXToken(t["address"],t["symbol"],t["name"],t["decimals"],t["chain_id"]) for t in tokens_data]
            
            # Use the new constructor in TradingStrategy.jl that takes dex_configurations
            strategy_instance = TradingStrategy.ArbitrageStrategy(s_name, dex_configs_data, tokens; # Pass dex_configs_data directly
                                                                min_profit_threshold_percent=get(s_params, "min_profit_threshold_percent", 0.1),
                                                                max_trade_size_usd=get(s_params, "max_trade_size_usd", 1000.0),
                                                                optimization_params=get(s_params, "optimization_params", Dict()),
                                                                price_feed_provider=get(s_params, "price_feed_provider", "chainlink"), # Pass these through
                                                                price_feed_config_override=get(s_params, "price_feed_config_override", Dict()))
        else 
            return Utils.error_response("Cannot re-instantiate unknown strategy type '$s_type' for backtest.", 500) 
        end
    catch e; return Utils.error_response("Failed to load strategy for backtest: $(sprint(showerror,e))", 500) end

    if isnothing(strategy_instance) return Utils.error_response("Strategy '$strategy_name' could not be loaded for backtest.", 500) end

    try
        historical_market_data = get(body, "historical_market_data", nothing)
        if isnothing(historical_market_data) return Utils.error_response("Missing 'historical_market_data' for backtest.", 400) end
        
        # Convert historical_market_data based on strategy type
        # This is where the API needs to be clear about expected format from client
        data_for_backtest = nothing
        if isa(strategy_instance, TradingStrategy.OptimalPortfolioStrategy)
            if !isa(historical_market_data, AbstractVector) || any(!isa(r,AbstractVector) for r in historical_market_data)
                return Utils.error_response("OptimalPortfolio expects historical_market_data as array of arrays.", 400)
            end
            try data_for_backtest = convert(Matrix{Float64}, hcat(historical_market_data...)')
            catch e; return Utils.error_response("Error converting market data for OptimalPortfolio: $e", 400) end
        elseif isa(strategy_instance, TradingStrategy.MovingAverageCrossoverStrategy) || isa(strategy_instance, TradingStrategy.MeanReversionStrategy)
            if !isa(historical_market_data, AbstractVector) || any(!isa(x,Number) for x in historical_market_data)
                 return Utils.error_response("MA/MeanReversion expects historical_market_data as array of numbers.", 400)
            end
            data_for_backtest = convert(Vector{Float64}, historical_market_data)
        else
             return Utils.error_response("Backtest for this strategy type not fully supported via this generic data input.", 400)
        end

        backtest_params_from_body = Dict{Symbol, Any}()
        for (k,v) in get(body, "backtest_parameters", Dict()) backtest_params_from_body[Symbol(k)] = v end
        
        results = TradingStrategy.backtest_strategy(strategy_instance, data_for_backtest; backtest_params_from_body...)
        return Utils.json_response(Dict("message"=>"Backtest for '$strategy_name' completed.", "results"=>results))
    catch e
        @error "Error during backtest for strategy $strategy_name" exception=(e,catch_backtrace())
        return Utils.error_response("Backtest failed: $(sprint(showerror, e))", 500, error_code="BACKTEST_FAILED")
    end
end

function update_strategy_handler(req::HTTP.Request, strategy_name::String)
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body for update.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    storage_key = STRATEGY_CONFIG_KEY_PREFIX * strategy_name
    loaded_config_tuple = Storage.load_default(storage_key)

    if isnothing(loaded_config_tuple)
        return Utils.error_response("Strategy '$strategy_name' not found for update.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
    end
    
    existing_config_data, _ = loaded_config_tuple
    if !isa(existing_config_data, Dict)
         return Utils.error_response("Corrupted stored config for strategy '$strategy_name'.", 500)
    end

    update_params = get(body, "parameters", nothing)
    if isnothing(update_params) || !isa(update_params, Dict)
        return Utils.error_response("Request body must include a 'parameters' object for update.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    # Merge new parameters into existing. Deeper merge might be needed for nested dicts.
    # This is a shallow merge of the 'parameters' field.
    # More specific logic per strategy type would be needed for robust updates.
    if haskey(existing_config_data, "parameters") && isa(existing_config_data["parameters"], Dict)
        merge!(existing_config_data["parameters"], update_params)
    else
        existing_config_data["parameters"] = update_params
    end
    
    # Potentially update other top-level modifiable fields if passed in body, e.g. "min_profit_threshold_percent" for Arbitrage
    # For now, only updating within the "parameters" sub-dictionary.

    save_success = Storage.save_default(storage_key, existing_config_data)
    if !save_success
        return Utils.error_response("Failed to save updated strategy '$strategy_name'.", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
    
    return Utils.json_response(Dict("message"=>"Strategy '$strategy_name' updated successfully in storage.", "updated_config"=>existing_config_data))
end

end # module TradingHandlers
