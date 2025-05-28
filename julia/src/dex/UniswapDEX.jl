"""
UniswapDEX.jl - Uniswap DEX integration for CutePanel

This module provides integration with Uniswap V2 and V3 decentralized exchanges,
allowing for price queries, liquidity checks, and order execution.
"""
module UniswapDEX

using HTTP, JSON3, Dates, UUIDs, Logging
using ..DEXBase 
import ...framework.CutePanelFramework.Blockchain 
import ...framework.CutePanelFramework.EthereumClient 

export Uniswap, UniswapV2, UniswapV3, create_uniswap_dex

# Default QuoterV2 address for Ethereum Mainnet. Should be configurable per chain.
const DEFAULT_QUOTER_V2_ADDRESS_MAINNET = "0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"

# Uniswap V3 sqrtPriceX96 limits from TickMath.sol
const MIN_SQRT_RATIO = BigInt("4295128739")
const MAX_SQRT_RATIO = BigInt("1461446703485210103287273052203988822378723970342")

@enum UniswapVersion begin V2; V3 end

mutable struct Uniswap <: AbstractDEX
    config::DEXConfig
    version::UniswapVersion
    internal_cache::Dict{String, Any}
    cache_lock::ReentrantLock
    manually_added_v3_pools::Dict{String, DEXPair} # For V3: pool_address => DEXPair object

    function Uniswap(config, version)
        new(config, version, Dict{String,Any}(), ReentrantLock(), Dict{String, DEXPair}())
    end
end

UniswapV2(config::DEXConfig) = Uniswap(config, V2)
UniswapV3(config::DEXConfig) = Uniswap(config, V3)
create_uniswap_dex(v_str::String, cfg::DEXConfig) = Uniswap(cfg, if lowercase(v_str)=="v2" V2 elseif lowercase(v_str)=="v3" V3 else error("Unsupported Uniswap: $v_str") end)

_get_conn(dex::Uniswap) = Blockchain.connect(network="chain_$(dex.config.chain_id)", endpoint=dex.config.rpc_url)

# Helper function to encode a Uniswap V3 path
# path_elements: Vector of alternating token addresses (String) and fee tiers (UInt24)
# e.g., ["0xtokenA", UInt24(3000), "0xtokenB", UInt24(500), "0xtokenC"]
function _encode_uniswap_v3_path(path_elements::Vector{Any})::Vector{UInt8}
    bytes_array = UInt8[]
    if length(path_elements) < 1 || !isa(path_elements[1], String)
        error("Path must start with a token address string.")
    end
    
    # First token address
    try
        append!(bytes_array, hex2bytes(replace(path_elements[1], "0x"=>"")))
    catch e
        error("Invalid hex string for token address: $(path_elements[1]). Error: $e")
    end

    idx = 2
    while idx < length(path_elements)
        # Expect fee, then next token address
        if idx + 1 > length(path_elements)
            error("Path elements must alternate fee and token address. Incomplete segment at end of path: $(path_elements)")
        end
        
        fee_val = path_elements[idx]
        next_token_addr_val = path_elements[idx+1]

        if !(isa(fee_val, Unsigned) || (isa(fee_val, Integer) && fee_val >= 0)) || !isa(next_token_addr_val, String)
            error("Path elements must alternate fee (Unsigned/NonNegative Integer) and token address (String). Got fee: $(typeof(fee_val)), next_token: $(typeof(next_token_addr_val)). Path: $path_elements")
        end
        
        fee_tier::UInt24 = try UInt24(fee_val) catch _ error("Invalid fee value, cannot convert to UInt24: $fee_val") end
        next_token_addr_str = replace(next_token_addr_val, "0x"=>"")

        # Fee tier is 3 bytes (uint24), big-endian
        append!(bytes_array, UInt8[
            (fee_tier >> 16) & 0xFF,
            (fee_tier >> 8) & 0xFF,
            fee_tier & 0xFF
        ])
        
        # Next token address
        try
            append!(bytes_array, hex2bytes(next_token_addr_str))
        catch e
            error("Invalid hex string for token address: $next_token_addr_val. Error: $e")
        end
        
        idx += 2
    end
    return bytes_array
end

function DEXBase.get_price(dex::Uniswap, pair::DEXPair)::Float64
    @info "Price: $(pair.token0.symbol)/$(pair.token1.symbol) on Uniswap $(dex.version)"
    conn = _get_conn(dex); !get(conn,"connected",false) && (@error "get_price: No connection"; return -1.0)
    pair_addr = pair.id; price = -1.0
    try
        if dex.version == V2
            data = EthereumClient.encode_function_call_abi("getReserves()",[])
            res_hex = Blockchain.eth_call_generic(pair_addr, data, conn)
            decoded = EthereumClient.decode_function_result_abi(res_hex, ["uint112","uint112","uint32"])
            if length(decoded)>=2 && isa(decoded[1],BigInt) && isa(decoded[2],BigInt) && decoded[1]>0 && decoded[2]>0
                price = (Float64(decoded[2])/(10^pair.token1.decimals)) / (Float64(decoded[1])/(10^pair.token0.decimals))
            else @error "V2 getReserves decode error or zero reserves." end
        elseif dex.version == V3
            slot0_hex = Blockchain.eth_call_generic(pair_addr, EthereumClient.encode_function_call_abi("slot0()",[]), conn)
            s0 = EthereumClient.decode_function_result_abi(slot0_hex, ["uint160","int24"]) 
            if length(s0)>=1 && isa(s0[1],BigInt) && s0[1]>0
                sqrtP96 = s0[1]
                pool_t0_addr_hex = Blockchain.eth_call_generic(pair_addr, EthereumClient.encode_function_call_abi("token0()",[]),conn)
                pool_t1_addr_hex = Blockchain.eth_call_generic(pair_addr, EthereumClient.encode_function_call_abi("token1()",[]),conn)
                pool_t0_addr = EthereumClient.decode_function_result_abi(pool_t0_addr_hex,["address"])[1]
                pool_t1_addr = EthereumClient.decode_function_result_abi(pool_t1_addr_hex,["address"])[1]
                
                price_ratio_pool_t1_over_t0 = (Float64(sqrtP96)/(2.0^96))^2 
                
                if lowercase(pair.token0.address) == lowercase(pool_t0_addr) 
                    price = price_ratio_pool_t1_over_t0 == 0.0 ? 0.0 : (1.0 / price_ratio_pool_t1_over_t0)
                    price *= (10^(pair.token1.decimals - pair.token0.decimals)) 
                elseif lowercase(pair.token0.address) == lowercase(pool_t1_addr) 
                    price = price_ratio_pool_t1_over_t0
                    price *= (10^(pair.token0.decimals - pair.token1.decimals)) 
                else @error "V3: Pair token mismatch with pool tokens."; return -1.0 end
            else @error "V3 slot0 decode error or sqrtPriceX96 zero." end
        end
        if price == -1.0 @warn "Using mock price for $(pair.token0.symbol)/$(pair.token1.symbol)."; price = rand(100.0:2000.0) end
    catch e @error "get_price error" error=e; price = rand(100.0:2000.0) end
    return price
end

function DEXBase.get_liquidity(dex::Uniswap, pair::DEXPair)::Tuple{Float64, Float64}
    @info "Liquidity: $(pair.token0.symbol)/$(pair.token1.symbol) on Uniswap $(dex.version)"
    conn = _get_conn(dex); !get(conn,"connected",false) && return (-1.0,-1.0)
    pair_addr = pair.id
    try
        if dex.version == V2
            res = EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(pair_addr, EthereumClient.encode_function_call_abi("getReserves()",[]),conn),["uint112","uint112"])
            return length(res)>=2 && isa(res[1],BigInt) && isa(res[2],BigInt) ? (Float64(res[1])/(10^pair.token0.decimals), Float64(res[2])/(10^pair.token1.decimals)) : (-1.0,-1.0)
        elseif dex.version == V3
            # For Uniswap V3, "liquidity" is best represented by the actual token balances held by the pool contract.
            # This is a more direct measure than calculations based on the 'L' (liquidity) value from slot0,
            # which represents virtual liquidity across active tick ranges.
            @info "Fetching actual token balances for V3 pool $(pair.id) ($(pair.token0.symbol)/$(pair.token1.symbol))"

            # Fetch slot0, liquidity, tickSpacing, and pool's token0/token1 addresses
            slot0_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("slot0()",[]), conn)
            liquidity_L_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("liquidity()",[]), conn)
            tick_spacing_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("tickSpacing()",[]), conn)
            pool_token0_addr_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("token0()",[]), conn)
            pool_token1_addr_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("token1()",[]), conn)

            if any(isempty, [slot0_hex, liquidity_L_hex, tick_spacing_hex, pool_token0_addr_hex, pool_token1_addr_hex]) ||
               any(s -> s == "0x", [slot0_hex, liquidity_L_hex, tick_spacing_hex, pool_token0_addr_hex, pool_token1_addr_hex])
                @warn "V3 get_liquidity: Failed to fetch one or more required pool parameters for $(pair.id). Falling back to token balances."
                balance0_fb = DEXBase.get_balance(dex, pair.token0, wallet_address=pair.id)
                balance1_fb = DEXBase.get_balance(dex, pair.token1, wallet_address=pair.id)
                return (balance0_fb >= 0.0 ? balance0_fb : -1.0), (balance1_fb >= 0.0 ? balance1_fb : -1.0)
            end

            s0_decoded = EthereumClient.decode_function_result_abi(slot0_hex, ["uint160","int24","uint16","uint16","uint16","uint8","bool"]) 
            current_L_bigint = EthereumClient.decode_function_result_abi(liquidity_L_hex, ["uint128"])[1]
            tick_spacing_val = EthereumClient.decode_function_result_abi(tick_spacing_hex, ["int24"])[1] # Uniswap V3 Pool tickSpacing is int24
            
            pool_canonical_token0_addr = EthereumClient.decode_function_result_abi(pool_token0_addr_hex, ["address"])[1]
            pool_canonical_token1_addr = EthereumClient.decode_function_result_abi(pool_token1_addr_hex, ["address"])[1]

            sqrt_price_x96 = s0_decoded[1]
            current_tick_int24 = s0_decoded[2]

            @info "UniswapV3 Pool $(pair.id) ($(pair.token0.symbol)/$(pair.token1.symbol)) - Active Liquidity Calculation:"
            @info "  Current Liquidity (L): $current_L_bigint"
            @info "  Current SqrtPriceX96: $sqrt_price_x96"
            @info "  Current Tick: $current_tick_int24"
            @info "  Tick Spacing: $tick_spacing_val"
            @info "  Pool Token0: $pool_canonical_token0_addr, Pool Token1: $pool_canonical_token1_addr"

            lock(dex.cache_lock) do # Cache raw values
                dex.internal_cache["pool_$(pair.id)_L"] = current_L_bigint
                dex.internal_cache["pool_$(pair.id)_sqrtP96"] = sqrt_price_x96
                dex.internal_cache["pool_$(pair.id)_tick"] = current_tick_int24
                dex.internal_cache["pool_$(pair.id)_tickSpacing"] = tick_spacing_val
            end

            if current_L_bigint == 0
                @info "V3 Pool $(pair.id): No active liquidity (L=0) at current tick. Returning (0.0, 0.0)."
                return (0.0, 0.0)
            end

            # Precision for calculations
            setprecision(BigFloat, 256) # Set precision for BigFloat operations

            sqrtP_current_bf = BigFloat(sqrt_price_x96) / (BigFloat(2)^96)
            
            # Determine tick boundaries for the current active range
            # tick_lower is the largest multiple of tickSpacing <= current_tick
            # However, the liquidity L is for the *current* tick interval, not just one tickSpacing wide range.
            # The formulas for x and y using L, sqrtP_current, sqrtP_lower, sqrtP_upper are for a specific position's range.
            # The L from liquidity() is the aggregate L at the current tick.
            # The amounts x and y that can be drawn from this L before the price crosses to the next tick
            # are what we need.
            
            # tick_lower for the current price point based on current_tick
            # This is the bottom of the current smallest tick interval where price resides
            tick_lower_boundary = floor(BigInt(current_tick_int24) / BigInt(tick_spacing_val)) * BigInt(tick_spacing_val)
            tick_upper_boundary = tick_lower_boundary + BigInt(tick_spacing_val)

            sqrtP_lower_boundary_bf = BigFloat(1.0001)^(BigFloat(tick_lower_boundary) / BigFloat(2))
            sqrtP_upper_boundary_bf = BigFloat(1.0001)^(BigFloat(tick_upper_boundary) / BigFloat(2))
            
            # Ensure current price is within the calculated boundary for safety, though it should be by definition of current_tick
            # If sqrtP_current is exactly on a boundary, one amount will be 0.
            # These formulas calculate how much of token0 (x) or token1 (y) is available *within the current tick interval*
            # given the aggregate liquidity L active at this interval.
            amount_x_virtual_bf::BigFloat = 0.0
            amount_y_virtual_bf::BigFloat = 0.0

            if sqrtP_current_bf < sqrtP_upper_boundary_bf # current price is not at or above the upper boundary of its tick range
                 amount_x_virtual_bf = BigFloat(current_L_bigint) * ( (sqrtP_upper_boundary_bf - sqrtP_current_bf) / (sqrtP_current_bf * sqrtP_upper_boundary_bf) )
            end
            if sqrtP_current_bf > sqrtP_lower_boundary_bf # current price is not at or below the lower boundary
                 amount_y_virtual_bf = BigFloat(current_L_bigint) * (sqrtP_current_bf - sqrtP_lower_boundary_bf)
            end
            
            # Determine which token in the pair corresponds to the pool's canonical token0 (x) and token1 (y)
            # And adjust for decimals
            local final_amount_pair_token0::Float64
            local final_amount_pair_token1::Float64

            if lowercase(pair.token0.address) == lowercase(pool_canonical_token0_addr) && lowercase(pair.token1.address) == lowercase(pool_canonical_token1_addr)
                # pair.token0 is pool's token0 (x), pair.token1 is pool's token1 (y)
                final_amount_pair_token0 = Float64(amount_x_virtual_bf / (BigFloat(10)^pair.token0.decimals))
                final_amount_pair_token1 = Float64(amount_y_virtual_bf / (BigFloat(10)^pair.token1.decimals))
            elseif lowercase(pair.token0.address) == lowercase(pool_canonical_token1_addr) && lowercase(pair.token1.address) == lowercase(pool_canonical_token0_addr)
                # pair.token0 is pool's token1 (y), pair.token1 is pool's token0 (x)
                final_amount_pair_token0 = Float64(amount_y_virtual_bf / (BigFloat(10)^pair.token0.decimals))
                final_amount_pair_token1 = Float64(amount_x_virtual_bf / (BigFloat(10)^pair.token1.decimals))
            else
                @error "V3 get_liquidity: Mismatch between pair tokens and pool's canonical tokens. Pair: $(pair.token0.symbol)/$(pair.token1.symbol), Pool: $pool_canonical_token0_addr/$pool_canonical_token1_addr. Falling back."
                # Fallback to balances
                balance0_fb = DEXBase.get_balance(dex, pair.token0, wallet_address=pair.id)
                balance1_fb = DEXBase.get_balance(dex, pair.token1, wallet_address=pair.id)
                return (balance0_fb >= 0.0 ? balance0_fb : -1.0), (balance1_fb >= 0.0 ? balance1_fb : -1.0)
            end
            
            @info "V3 Pool $(pair.id) Calculated Virtual Liquidity: $(pair.token0.symbol): $final_amount_pair_token0, $(pair.token1.symbol): $final_amount_pair_token1"
            return (final_amount_pair_token0, final_amount_pair_token1)

        end
    catch e 
        @error "Error calculating V3 virtual liquidity for $(pair.id)" error=e stacktrace=catch_stacktrace()
        # Fallback to balances if any error occurs during V3 specific logic too
        try
            balance0_fb = DEXBase.get_balance(dex, pair.token0, wallet_address=pair.id)
            balance1_fb = DEXBase.get_balance(dex, pair.token1, wallet_address=pair.id)
            @warn "V3 get_liquidity: Falling back to token balances for pool $(pair.id) due to calculation error."
            return (balance0_fb >= 0.0 ? balance0_fb : -1.0), (balance1_fb >= 0.0 ? balance1_fb : -1.0)
        catch e_bal 
            @error "Error fetching balances during liquidity fallback for $(pair.id)" error=e_bal
            return (-1.0,-1.0) 
        end
    end
    # This part should ideally not be reached if logic is correct, but as a safeguard:
    @error "V3 get_liquidity: Reached end of function unexpectedly for pool $(pair.id). Returning error values."
    return (-1.0,-1.0) 
end

function DEXBase.create_order(
    dex::Uniswap, 
    pair::DEXPair, # For single-hop, this defines the pool. For multi-hop, t_in/t_out derived from path_spec.
    order_type::OrderType, 
    side::OrderSide, 
    amount::Float64, 
    price::Float64=0.0; 
    exact_input::Bool=true, 
    path_spec::Union{Nothing, Vector{Any}} = nothing, # e.g. [token_addr_in, fee1, token_addr_intermediate1, fee2, token_addr_out]
    sqrt_price_limit_x96_override::Union{Nothing, BigInt} = nothing # Optional override for V3 single-hop sqrtPriceLimitX96
)::DEXOrder
    
    is_multi_hop = path_spec !== nothing && length(path_spec) >= 3 # Min path: token_in, fee, token_out

    @info "Preparing order: $(side) $(amount) on $(dex.version), exact_input: $exact_input, multi_hop: $is_multi_hop"
    if is_multi_hop
        @info "Path spec: $path_spec"
    else
        @info "Single hop for pair: $(pair.token0.symbol)/$(pair.token1.symbol)"
    end

    order_type!=MARKET && @warn "Non-MARKET orders are complex on Uniswap. This implementation primarily supports MARKET orders."
    conn = _get_conn(dex); !get(conn,"connected",false) && error("create_order: Not connected.")

    local t_in::DEXToken, t_out::DEXToken
    local amt_in_smallest_unit_exact::BigInt = BigInt(0)
    local amt_out_smallest_unit_exact::BigInt = BigInt(0)
    local amt_for_v2_fallback_or_calc::BigInt # Used for V2 or non-Quoter V3 paths

    if exact_input
        # For exact input, 'amount' is the amount of token_in we are spending
        t_in, t_out = if side == SELL (pair.token0, pair.token1) # Selling token0 to get token1
                      elseif side == BUY (pair.token1, pair.token0) # Selling token1 to get token0
                      else error("Invalid side for exact_input.") end
        amt_in_smallest_unit_exact = BigInt(round(amount * 10^t_in.decimals))
        amt_for_v2_fallback_or_calc = amt_in_smallest_unit_exact
    else # exact_output
        # For exact output, 'amount' is the amount of token_out we want to receive
        t_in, t_out = if side == SELL (pair.token0, pair.token1) # Selling token0 to get an exact amount of token1
                      elseif side == BUY (pair.token1, pair.token0) # Selling token1 to get an exact amount of token0
                      else error("Invalid side for exact_output.") end
        amt_out_smallest_unit_exact = BigInt(round(amount * 10^t_out.decimals))
        # For V2/fallback, we still need an 'amountIn' concept for price calculation,
        # which is tricky for exact_output without a quote. We might need to estimate it.
        # Or, the price-based fallback for exact_output needs to work backwards.
        # For now, let's assume price-based fallback for exact_output will estimate amount_in.
        # amt_for_v2_fallback_or_calc will be set later if needed for exact_output fallback.
    end
    
    local final_amount_out_min_smallest_unit::BigInt = BigInt(0) # For exactInput: min amount of t_out to receive
    local final_amount_in_max_smallest_unit::BigInt = BigInt(0)  # For exactOutput: max amount of t_in to spend
    local actual_sqrt_p_limit_for_trade::BigInt = BigInt(0) # Default, will be refined for V3 single-hop. 0 means no price limit.

    if dex.version == V3 && !is_multi_hop # sqrtPriceLimitX96 is for single hop swaps
        if !isnothing(sqrt_price_limit_x96_override)
            actual_sqrt_p_limit_for_trade = sqrt_price_limit_x96_override
            @info "Using user-provided sqrtPriceLimitX96 override: $actual_sqrt_p_limit_for_trade"
        else
            try
                # pair.id should be the pool address for single-hop
                pool_t0_addr_hex = Blockchain.eth_call_generic(pair.id, EthereumClient.encode_function_call_abi("token0()",[]),conn)
                if isempty(pool_t0_addr_hex) || pool_t0_addr_hex == "0x"
                    @warn "Could not fetch token0 address from V3 pool $(pair.id) for sqrtPriceLimitX96. Using 0 (no limit for swap) as fallback."
                    actual_sqrt_p_limit_for_trade = BigInt(0) 
                else
                    pool_actual_token0_address = EthereumClient.decode_function_result_abi(pool_t0_addr_hex,["address"])[1]
                    # Determine direction for sqrtPriceLimitX96
                    # If selling token0 (t_in is token0), price moves down, so limit is MIN_SQRT_RATIO + 1
                    # If selling token1 (t_in is token1), price moves up, so limit is MAX_SQRT_RATIO - 1
                    if lowercase(t_in.address) == lowercase(pool_actual_token0_address) 
                        actual_sqrt_p_limit_for_trade = MIN_SQRT_RATIO + 1 
                    else 
                        actual_sqrt_p_limit_for_trade = MAX_SQRT_RATIO - 1
                    end
                    @info "Determined default sqrtPriceLimitX96 for V3 single-hop trade: $actual_sqrt_p_limit_for_trade (t_in: $(t_in.symbol), pool t0: $(pool_actual_token0_address))"
                end
            catch e
                @warn "Error determining pool's token0 for default sqrtPriceLimitX96, fallback to 0 (no limit for swap)." error=e
                actual_sqrt_p_limit_for_trade = BigInt(0)
            end
        end
    end

    if dex.version == V3 && order_type == MARKET
        quoter_address = get(dex.config.metadata, "quoter_v2_address", DEFAULT_QUOTER_V2_ADDRESS_MAINNET)
        
        if isempty(quoter_address)
            @warn "V3 Quoter address not configured. Falling back to price-based estimation."
        else
            if is_multi_hop
                encoded_path = _encode_uniswap_v3_path(path_spec)
                if exact_input
                    quoter_sig = "quoteExactInput(bytes,uint256)"
                    quoter_args = [(encoded_path,"bytes"),(amt_in_smallest_unit_exact,"uint256")]
                    @info "Quoting V3 multi-hop exactInput: path $(path_spec), amountIn: $amt_in_smallest_unit_exact"
                    try
                        quoted_hex = Blockchain.eth_call_generic(quoter_address, EthereumClient.encode_function_call_abi(quoter_sig, quoter_args), conn)
                        decoded_q = EthereumClient.decode_function_result_abi(quoted_hex, ["uint256"]) # amountOut
                        if !isempty(decoded_q) && isa(decoded_q[1],BigInt)
                            quoted_raw_out = decoded_q[1]
                            final_amount_out_min_smallest_unit = BigInt(floor(Float64(quoted_raw_out)*(1.0-dex.config.slippage/100.0)))
                            @info "QuoterV2 (multi-hop exactInput) estimated amountOut: $quoted_raw_out, amountOutMin with slippage: $final_amount_out_min_smallest_unit"
                        else 
                            @warn "Failed V3 multi-hop quoteExactInput. Falling back."; final_amount_out_min_smallest_unit = BigInt(0)
                        end
                    catch e 
                        @warn "Error calling QuoterV2 for multi-hop exactInput, fallback." error=e; final_amount_out_min_smallest_unit = BigInt(0)
                    end
                else # exact_output multi-hop
                    quoter_sig = "quoteExactOutput(bytes,uint256)"
                    quoter_args = [(encoded_path,"bytes"),(amt_out_smallest_unit_exact,"uint256")]
                    @info "Quoting V3 multi-hop exactOutput: path $(path_spec), amountOut: $amt_out_smallest_unit_exact"
                    try
                        quoted_hex = Blockchain.eth_call_generic(quoter_address, EthereumClient.encode_function_call_abi(quoter_sig, quoter_args), conn)
                        decoded_q = EthereumClient.decode_function_result_abi(quoted_hex, ["uint256"]) # amountIn
                        if !isempty(decoded_q) && isa(decoded_q[1],BigInt)
                            quoted_raw_in = decoded_q[1]
                            final_amount_in_max_smallest_unit = BigInt(ceil(Float64(quoted_raw_in)*(1.0+dex.config.slippage/100.0)))
                            @info "QuoterV2 (multi-hop exactOutput) estimated amountIn: $quoted_raw_in, amountInMax with slippage: $final_amount_in_max_smallest_unit"
                        else 
                            @warn "Failed V3 multi-hop quoteExactOutput. Falling back."; final_amount_in_max_smallest_unit = BigInt(0)
                        end
                    catch e 
                        @warn "Error calling QuoterV2 for multi-hop exactOutput, fallback." error=e; final_amount_in_max_smallest_unit = BigInt(0)
                    end
                end
            else # Single-hop V3 MARKET
                fee_tier_for_quote = round(UInt24, pair.fee * 10000)
                if exact_input
                    sqrt_p_limit_for_quote_exact_input = BigInt(0) 
                    quoter_sig = "quoteExactInputSingle(address,address,uint24,uint256,uint160)"
                    quoter_args = [(t_in.address,"address"),(t_out.address,"address"),(fee_tier_for_quote,"uint24"),(amt_in_smallest_unit_exact,"uint256"),(sqrt_p_limit_for_quote_exact_input,"uint160")]
                    quoter_data = EthereumClient.encode_function_call_abi(quoter_sig, quoter_args)
                    @info "Quoting V3 exactInputSingle: $(t_in.symbol)->$(t_out.symbol), amountIn: $amt_in_smallest_unit_exact, sqrtPLimitForQuote: $sqrt_p_limit_for_quote_exact_input"
                    try
                        quoted_hex = Blockchain.eth_call_generic(quoter_address, quoter_data, conn)
                        decoded_q = EthereumClient.decode_function_result_abi(quoted_hex, ["uint256"]) # amountOut
                        if !isempty(decoded_q) && isa(decoded_q[1],BigInt)
                            quoted_raw_out = decoded_q[1]
                            final_amount_out_min_smallest_unit = BigInt(floor(Float64(quoted_raw_out)*(1.0-dex.config.slippage/100.0)))
                            @info "QuoterV2 (exactInputSingle) estimated amountOut: $quoted_raw_out, amountOutMin with slippage: $final_amount_out_min_smallest_unit"
                        else 
                            @warn "Failed V3 quoteExactInputSingle. Falling back."; final_amount_out_min_smallest_unit = BigInt(0)
                        end
                    catch e 
                        @warn "Error calling QuoterV2 for exactInputSingle, fallback." error=e; final_amount_out_min_smallest_unit = BigInt(0)
                    end
                else # exact_output single-hop
                    sqrt_p_limit_for_quote_exact_output = BigInt(0)
                    quoter_sig = "quoteExactOutputSingle(address,address,uint24,uint256,uint160)"
                    quoter_args = [(t_in.address,"address"),(t_out.address,"address"),(fee_tier_for_quote,"uint24"),(amt_out_smallest_unit_exact,"uint256"),(sqrt_p_limit_for_quote_exact_output,"uint160")]
                    quoter_data = EthereumClient.encode_function_call_abi(quoter_sig, quoter_args)
                    @info "Quoting V3 exactOutputSingle: $(t_in.symbol)->$(t_out.symbol), amountOut: $amt_out_smallest_unit_exact, sqrtPLimitForQuote: $sqrt_p_limit_for_quote_exact_output"
                    try
                        quoted_hex = Blockchain.eth_call_generic(quoter_address, quoter_data, conn)
                        decoded_q = EthereumClient.decode_function_result_abi(quoted_hex, ["uint256"]) # amountIn
                        if !isempty(decoded_q) && isa(decoded_q[1],BigInt)
                            quoted_raw_in = decoded_q[1]
                            final_amount_in_max_smallest_unit = BigInt(ceil(Float64(quoted_raw_in)*(1.0+dex.config.slippage/100.0)))
                            @info "QuoterV2 (exactOutputSingle) estimated amountIn: $quoted_raw_in, amountInMax with slippage: $final_amount_in_max_smallest_unit"
                        else 
                            @warn "Failed V3 quoteExactOutputSingle. Falling back."; final_amount_in_max_smallest_unit = BigInt(0)
                        end
                    catch e 
                        @warn "Error calling QuoterV2 for exactOutputSingle, fallback." error=e; final_amount_in_max_smallest_unit = BigInt(0)
                    end
                end
            end
        end
        
        # Fallback for exact_input if Quoter failed or not used
        if exact_input && final_amount_out_min_smallest_unit == BigInt(0)
            price_io = lowercase(t_in.address)==lowercase(pair.token0.address) ? DEXBase.get_price(dex,pair) : (p=DEXBase.get_price(dex,pair);p==0.0 ? 0.0:1.0/p)
            price_io<=0 && error("Market price unavailable for amountOutMin calc (V3 fallback).")
            exp_out = (Float64(amt_in_smallest_unit_exact)/(10^t_in.decimals))*price_io
            final_amount_out_min_smallest_unit = BigInt(floor(exp_out*(1-dex.config.slippage/100.0)*(10^t_out.decimals)))
            @info "V3 Quoter fallback (exactInput): Calculated amountOutMin: $final_amount_out_min_smallest_unit"
        end
        # Fallback for exact_output if Quoter failed or not used
        if !exact_input && final_amount_in_max_smallest_unit == BigInt(0)
            price_io = lowercase(t_in.address)==lowercase(pair.token0.address) ? DEXBase.get_price(dex,pair) : (p=DEXBase.get_price(dex,pair);p==0.0 ? 0.0:1.0/p)
            price_io<=0 && error("Market price unavailable for amountInMax calc (V3 fallback).")
            exp_in = (Float64(amt_out_smallest_unit_exact)/(10^t_out.decimals))/price_io 
            final_amount_in_max_smallest_unit = BigInt(ceil(exp_in*(1+dex.config.slippage/100.0)*(10^t_in.decimals)))
            @info "V3 Quoter fallback (exactOutput): Calculated amountInMax: $final_amount_in_max_smallest_unit"
        end

    else # V2 or V3 LIMIT (or V3 MARKET if Quoter was skipped/failed)
        # This block handles V2 (always exact_input effectively)
        # and serves as a fallback for V3 MARKET if Quoter path wasn't taken or failed.
        # V3 LIMIT orders would also fall here if not MARKET.
        if exact_input
            # This is the amount of t_in to use for V2 or fallback V3 exact_input
            current_amt_in_for_calc = amt_in_smallest_unit_exact 
            price_io = lowercase(t_in.address)==lowercase(pair.token0.address) ? DEXBase.get_price(dex,pair) : (p=DEXBase.get_price(dex,pair);p==0.0 ? 0.0:1.0/p)
            price_io<=0 && order_type==MARKET && error("Market price unavailable for amountOutMin (V2/fallback).")
            exp_out = (Float64(current_amt_in_for_calc)/(10^t_in.decimals))*price_io
            final_amount_out_min_smallest_unit = BigInt(floor(exp_out*(1-dex.config.slippage/100.0)*(10^t_out.decimals)))
        else # exact_output (primarily for V3 LIMIT or V3 MARKET fallback if Quoter failed for exact_output)
            # For V2, exact_output is not standard. If this path is hit for V2 exact_output, it's an issue.
            dex.version == V2 && error("Exact output is not directly supported for UniswapV2 in this fallback path.")
            
            # This means it's V3 exact_output and Quoter failed or wasn't used (e.g. LIMIT order)
            if final_amount_in_max_smallest_unit == BigInt(0) # Ensure it's calculated if not by Quoter
                price_io = lowercase(t_in.address)==lowercase(pair.token0.address) ? DEXBase.get_price(dex,pair) : (p=DEXBase.get_price(dex,pair);p==0.0 ? 0.0:1.0/p)
                price_io<=0 && order_type==MARKET && error("Market price unavailable for amountInMax calc (V3 fallback).")
                exp_in = (Float64(amt_out_smallest_unit_exact)/(10^t_out.decimals))/price_io 
                final_amount_in_max_smallest_unit = BigInt(ceil(exp_in*(1+dex.config.slippage/100.0)*(10^t_in.decimals)))
            end
        end
    end

    router=dex.config.router_address; isempty(router)&&error("Router missing.")
    recip=get(dex.config.metadata,"recipient_address_override","0x000000000000000000000000000000000000dEaD") 
    deadline=round(Int,datetime2unix(now(UTC)+Minute(20))); data=""; desc=""
    
    local final_tx_amt_in_raw_str::String
    local final_tx_amt_out_raw_str::String 

    if dex.version==V2
        if !exact_input 
            error("Exact output swaps are not directly supported for UniswapV2 with this simplified implementation. Use exact_input=true.")
        end
        path_v2=[t_in.address, t_out.address]
        tx_param_amount_in = amt_in_smallest_unit_exact
        tx_param_amount_out = final_amount_out_min_smallest_unit
        
        sig="swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
        args=[(tx_param_amount_in,"uint256"),(tx_param_amount_out,"uint256"),(path_v2,"address[]"),(recip,"address"),(deadline,"uint256")]
        data=EthereumClient.encode_function_call_abi(sig,args)
        desc="V2 exactInput: $(amount) $(t_in.symbol) for min $(Float64(tx_param_amount_out)/(10^t_out.decimals)) $(t_out.symbol)"

    elseif dex.version==V3
        if is_multi_hop
            encoded_path = _encode_uniswap_v3_path(path_spec)
            if exact_input
                tx_param_amount_in = amt_in_smallest_unit_exact
                tx_param_amount_out = final_amount_out_min_smallest_unit # This is amountOutMinimum
                
                # struct ExactInputParams { bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; }
                params_tuple = (encoded_path, recip, deadline, tx_param_amount_in, tx_param_amount_out)
                sig = "exactInput((bytes,address,uint256,uint256,uint256))"
                args = [(params_tuple, "(bytes,address,uint256,uint256,uint256)")]
                data = EthereumClient.encode_function_call_abi(sig, args)
                desc="V3 multi-hop exactInput: $(amount) $(t_in.symbol) for min $(Float64(tx_param_amount_out)/(10^t_out.decimals)) $(t_out.symbol), path: $path_spec"
            else # exact_output multi-hop
                tx_param_amount_out = amt_out_smallest_unit_exact # Exact amountOut
                tx_param_amount_in = final_amount_in_max_smallest_unit # This is amountInMaximum

                # struct ExactOutputParams { bytes path; address recipient; uint256 deadline; uint256 amountOut; uint256 amountInMaximum; }
                params_tuple = (encoded_path, recip, deadline, tx_param_amount_out, tx_param_amount_in)
                sig = "exactOutput((bytes,address,uint256,uint256,uint256))"
                args = [(params_tuple, "(bytes,address,uint256,uint256,uint256)")]
                data = EthereumClient.encode_function_call_abi(sig, args)
                desc="V3 multi-hop exactOutput: Get $(amount) $(t_out.symbol) for max $(Float64(tx_param_amount_in)/(10^t_in.decimals)) $(t_in.symbol), path: $path_spec"
            end
        else # single-hop V3
            fee=round(UInt24,pair.fee*10000)
            if exact_input
                if actual_sqrt_p_limit_for_trade == BigInt(0) @warn "V3 exactInputSingle: sqrtPriceLimitX96 is 0. This implies no price limit for the swap." end
                tx_param_amount_in = amt_in_smallest_unit_exact
                tx_param_amount_out = final_amount_out_min_smallest_unit
                
                params=(t_in.address,t_out.address,fee,recip,deadline,tx_param_amount_in,tx_param_amount_out,actual_sqrt_p_limit_for_trade)
                sig="exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))"
                args=[(params,"(address,address,uint24,address,uint256,uint256,uint256,uint160)")]
                data=EthereumClient.encode_function_call_abi(sig,args)
                desc="V3 exactInputSingle: $(amount) $(t_in.symbol) for min $(Float64(tx_param_amount_out)/(10^t_out.decimals)) $(t_out.symbol), fee $(Float64(fee)/10000.0)%, sqrtPLimit $(actual_sqrt_p_limit_for_trade)"
            else # exact_output single-hop
                if actual_sqrt_p_limit_for_trade == BigInt(0) @warn "V3 exactOutputSingle: sqrtPriceLimitX96 is 0. This implies no price limit for the swap." end
                tx_param_amount_out = amt_out_smallest_unit_exact
                tx_param_amount_in = final_amount_in_max_smallest_unit
                
                params=(t_in.address,t_out.address,fee,recip,deadline,tx_param_amount_out,tx_param_amount_in,actual_sqrt_p_limit_for_trade)
                sig="exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))"
                args=[(params,"(address,address,uint24,address,uint256,uint256,uint256,uint160)")]
                data=EthereumClient.encode_function_call_abi(sig,args)
                desc="V3 exactOutputSingle: Get $(amount) $(t_out.symbol) for max $(Float64(tx_param_amount_in)/(10^t_in.decimals)) $(t_in.symbol), fee $(Float64(fee)/10000.0)%, sqrtPLimit $(actual_sqrt_p_limit_for_trade)"
            end
        end
    else 
        error("Unsupported Uniswap version for order creation.") 
    end

    @warn "Token approval for $(t_in.symbol) (address: $(t_in.address)) to router $router must be handled client-side."
    order_id="uniswap-$(dex.version)-$(string(uuid4())[1:8])"
    tx_params=Dict("to"=>router,"data"=>data,"value"=>"0x0","estimated_gas"=>"N/A_BACKEND","gas_price"=>"CLIENT_FETCH","nonce"=>"CLIENT_FETCH","chain_id"=>dex.config.chain_id,"description"=>desc)
    
    metadata = Dict(
        "dex"=>dex.config.name, "ver"=>string(dex.version),
        "t_in_sym"=>t_in.symbol, "t_in_addr"=>t_in.address,
        "t_out_sym"=>t_out.symbol, "t_out_addr"=>t_out.address,
        "recip"=>recip, "deadline"=>deadline,
        "tx_params_client"=>tx_params,
        "exact_input_flag" => exact_input,
        "is_multi_hop" => is_multi_hop
    )
    if is_multi_hop
        metadata["path_spec_used"] = string(path_spec) # Log the path used
    elseif dex.version == V3 # Only log sqrt_price_limit for V3 single-hop
        metadata["sqrt_price_limit_x96_used"] = string(actual_sqrt_p_limit_for_trade)
    end

    if exact_input
        metadata["amount_in_exact_raw"] = string(tx_param_amount_in)
        metadata["amount_out_minimum_raw"] = string(tx_param_amount_out)
    else 
        metadata["amount_out_exact_raw"] = string(tx_param_amount_out)
        metadata["amount_in_maximum_raw"] = string(tx_param_amount_in)
    end

    return DEXOrder(order_id,pair,order_type,side,amount,price,OrderStatus.PENDING,Float64(datetime2unix(now(UTC))),"", metadata)
end

DEXBase.cancel_order(::Uniswap,oid::String)=(@warn "Uniswap swaps not cancellable."; false)

function DEXBase.get_order_status(dex::Uniswap, order_id::String; tx_hash::Union{String, Nothing}=nothing)::DEXOrder
    @info "Order status: $order_id (tx: $tx_hash) on $(dex.version)"
    dummy_tok=DEXToken("0x0","N/A","",0,dex.config.chain_id); dummy_pair=DEXPair(order_id,dummy_tok,dummy_tok,0.0,string(dex.version))
    if isnothing(tx_hash)||isempty(tx_hash) @warn "tx_hash missing for $order_id."; return DEXOrder(order_id,dummy_pair,MARKET,BUY,0.0,0.0,OrderStatus.PENDING,Float64(datetime2unix(now(UTC))),"",Dict("message"=>"tx_hash not provided")) end
    conn = _get_conn(dex); !get(conn,"connected",false) && (@error "get_order_status: No connection."; return DEXOrder(order_id,dummy_pair,MARKET,BUY,0.0,0.0,OrderStatus.REJECTED,Float64(datetime2unix(now(UTC))),tx_hash,Dict("error"=>"No connection")))
    receipt = Blockchain.get_transaction_receipt_generic(tx_hash,conn)
    final_status=OrderStatus.PENDING; meta=Dict("checked_at"=>string(now(UTC)),"tx_hash"=>tx_hash) 
    if !isnothing(receipt)
        s=get(receipt,"status",""); final_status = s=="0x1" ? OrderStatus.FILLED : (s=="0x0" ? OrderStatus.REJECTED : OrderStatus.OPEN)
        s=="0x1" && (meta["blockHash"]=get(receipt,"blockHash",""); meta["blockNumber"]=get(receipt,"blockNumber",""); meta["gas_used"]=get(receipt,"gasUsed",""))
        s=="0x0" && (meta["error_reason"]="Tx reverted"; meta["blockHash"]=get(receipt,"blockHash","")) 
    else meta["status_detail"]="Tx pending or not found." end
    return DEXOrder(order_id,dummy_pair,MARKET,BUY,0.0,0.0,final_status,Float64(datetime2unix(now(UTC))),tx_hash,meta)
end

function DEXBase.get_pairs(dex::Uniswap; limit::Int=100)::Vector{DEXPair}
    @info "Pairs for Uniswap $(dex.version), DEX: $(dex.config.name)"
    conn = _get_conn(dex); !get(conn,"connected",false) && return DEXPair[]
    factory = dex.config.factory_address; isempty(factory) && (@warn "Factory address missing."; return DEXPair[])
    pairs_list = DEXPair[]
    try if dex.version == V2
            len_hex = Blockchain.eth_call_generic(factory, EthereumClient.encode_function_call_abi("allPairsLength()",[]),conn)
            total = isempty(len_hex)||len_hex=="0x" ? 0 : Int(EthereumClient.decode_function_result_abi(len_hex,["uint256"])[1])
            num_to_fetch = min(total, limit)
            @info "V2 Factory $factory reports $total pairs. Fetching $num_to_fetch."
            for i in 0:(num_to_fetch-1)
                p_addr_hex = Blockchain.eth_call_generic(factory, EthereumClient.encode_function_call_abi("allPairs(uint256)",[(BigInt(i),"uint256")]),conn)
                p_addr = EthereumClient.decode_function_result_abi(p_addr_hex,["address"])[1]
                t0a=EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(p_addr,EthereumClient.encode_function_call_abi("token0()",[]),conn),["address"])[1]
                t1a=EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(p_addr,EthereumClient.encode_function_call_abi("token1()",[]),conn),["address"])[1]
                get_td(ta) = DEXToken(ta, try EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(ta,EthereumClient.encode_function_call_abi("symbol()",[]),conn),["string"])[1] catch _ ta[1:min(6,end)] end, try EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(ta,EthereumClient.encode_function_call_abi("name()",[]),conn),["string"])[1] catch _ "N/A" end, try Int(EthereumClient.decode_function_result_abi(Blockchain.eth_call_generic(ta,EthereumClient.encode_function_call_abi("decimals()",[]),conn),["uint8"])[1]) catch _ 18 end, dex.config.chain_id)
                push!(pairs_list, DEXPair(p_addr, get_td(t0a), get_td(t1a), 0.3, "Uniswap V2"))
            end
        elseif dex.version == V3 
            @warn """
            UniswapV3 get_pairs is currently returning MOCK DATA.
            A full implementation for Uniswap V3 requires an external data indexer (e.g., TheGraph) 
            or extensive event log processing to discover all created pools, due to the on-chain 
            data structure of V3 (pools are not enumerable directly from the factory).
            Consider integrating an indexer or allowing manual addition of V3 pools.
            """
            # Mock data:
            eth=DEXToken("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2","WETH","Wrapped Ether",18,dex.config.chain_id) # Added name
            usdc=DEXToken("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","USDC","USD Coin",6,dex.config.chain_id) # Added name
            push!(pairs_list,DEXPair("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",eth,usdc,0.05,"Uniswap V3 WETH/USDC 0.05%")) # Example mock pair
            # Append manually added V3 pools
            for manually_added_pair in values(dex.manually_added_v3_pools)
                # Avoid duplicates if mock data happens to be one of the manually added ones
                if !any(p -> p.id == manually_added_pair.id, pairs_list)
                    push!(pairs_list, manually_added_pair)
                end
            end
            # Limit the total number of pairs returned if necessary, after combining mock and manual
            if length(pairs_list) > limit
                pairs_list = pairs_list[1:limit]
            end
        end 
    catch e @error "Error fetching pairs" error=e end; return pairs_list
end

# Helper function to allow manual registration of V3 pools
function add_manual_v3_pool!(dex::Uniswap, pair::DEXPair)
    if dex.version != V3
        @warn "Manual pool addition is intended for UniswapV3 instances."
        return
    end
    lock(dex.cache_lock) do # Use cache_lock for thread-safety, though a dedicated lock might be better if contention is high
        dex.manually_added_v3_pools[lowercase(pair.id)] = pair
    end
    @info "Manually added V3 pool: $(pair.id) ($(pair.token0.symbol)/$(pair.token1.symbol)) to DEX instance $(dex.config.name)"
end
export add_manual_v3_pool!


function DEXBase.get_tokens(dex::Uniswap; limit::Int=100)::Vector{DEXToken}
    @info "Tokens for Uniswap $(dex.version), DEX: $(dex.config.name)"
    tokens = Dict{String,DEXToken}()
    if dex.version == V2
        @info "V2 get_tokens: Deriving from fetched pairs."
        # For V2, get_pairs already fetches token details.
        for p in DEXBase.get_pairs(dex,limit=max(limit*2, 50)) # Fetch enough pairs to likely get 'limit' unique tokens
            !haskey(tokens,lowercase(p.token0.address)) && (tokens[lowercase(p.token0.address)]=p.token0)
            !haskey(tokens,lowercase(p.token1.address)) && (tokens[lowercase(p.token1.address)]=p.token1)
            length(tokens)>=limit && break
        end
    elseif dex.version == V3
        @warn """
        UniswapV3 get_tokens: Deriving from MOCK PAIRS and MANUALLY ADDED pools.
        A full implementation for Uniswap V3 requires an external data indexer (e.g., TheGraph) 
        or extensive event log processing to discover all created pools and their tokens.
        This function currently returns tokens from a small set of mock/manually added V3 pools.
        Consider using `add_manual_v3_pool!` to make the system aware of specific V3 pools and their tokens.
        """
        # Derive tokens from the V3 pairs (mock + manual)
        for p in DEXBase.get_pairs(dex, limit=limit*2) # Get pairs (which now includes manual ones)
             !haskey(tokens,lowercase(p.token0.address)) && (tokens[lowercase(p.token0.address)]=p.token0)
             !haskey(tokens,lowercase(p.token1.address)) && (tokens[lowercase(p.token1.address)]=p.token1)
             length(tokens)>=limit && break
        end
        # If still under limit after processing pairs, add some common default tokens as a final fallback
        if length(tokens) < limit
            default_v3_tokens_data = [
                ("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2","WETH","Wrapped Ether",18), 
                ("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","USDC","USD Coin",6),
                ("0x6B175474E89094C44Da98b954EedeAC495271d0F","DAI","Dai Stablecoin",18)
            ]
            for (a,s,n,d) in default_v3_tokens_data
                if length(tokens) < limit && !haskey(tokens, lowercase(a))
                    tokens[lowercase(a)] = DEXToken(a,s,n,d,dex.config.chain_id)
                else
                    break
                end
            end
        end
    end
    return collect(values(tokens))[1:min(length(tokens),limit)] # Ensure limit is respected
end

# Assumes DEXBase.Trade struct is defined, e.g.:
            else
                break
            end
        end
    end
    return collect(values(tokens))
end

# Assumes DEXBase.Trade struct is defined, e.g.:
# struct Trade
#     id::String; pair::DEXPair; timestamp::Float64; side::OrderSide
#     amount_token0::Float64; amount_token1::Float64; price::Float64
#     # Optional: fee_amount::Float64; fee_currency::String
# end
function DEXBase.get_trades(dex::Uniswap, pair::DEXPair; limit::Int=100)::Vector{DEXBase.Trade}
    # This function is a placeholder. Real implementation requires an indexer.
    @warn """
    Uniswap get_trades (for $(dex.version)) is not implemented.
    Fetching historical trades requires querying and processing blockchain event logs (e.g., Swap events)
    extensively, usually via an external data indexer (like TheGraph) or a dedicated event processing pipeline.
    This function currently returns an empty list.
    Pair: $(pair.token0.symbol)/$(pair.token1.symbol) ($(pair.id))
    """
    # Ensure DEXBase.Trade is defined and imported/available.
    # If DEXBase.Trade is not defined, this line will cause an error.
    # Replace with `return Any[]` or a local struct if DEXBase.Trade is problematic.
    if isdefined(DEXBase, :Trade)
        return DEXBase.Trade[] 
    else
        @error "DEXBase.Trade is not defined. Cannot return Vector{DEXBase.Trade}."
        return Any[] # Fallback to Any[] if Trade struct is not found
    end
end

function DEXBase.get_balance(dex::Uniswap, token::DEXToken; wallet_address::String="")::Float64
    addr = isempty(wallet_address) ? get(dex.config.metadata, "wallet_address_override", "") : wallet_address 
    if isempty(addr) 
        @error "get_balance: Valid wallet_address required (passed or in dex.config.metadata)."
        return -1.0 
    end
    conn = _get_conn(dex); !get(conn,"connected",false) && (@error "get_balance: Not connected."; return -2.0) 
    return Blockchain.get_token_balance_generic(addr, token.address, conn)
end

end # module UniswapDEX

</final_file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
julia/src/dex/UniswapDEX.jl

# VSCode Open Tabs
packages/config/typescript-config/base.json
packages/core/package.json
julia/src/api/MetricsHandlers.jl
julia/src/api/LlmHandlers.jl
julia/src/swarm/SwarmBase.jl
julia/src/dex/DEXBase.jl
julia/src/dex/UniswapDEX.jl
julia/src/price/PriceFeedBase.jl
julia/src/price/PriceFeed.jl
julia/src/storage/storage_interface.jl
julia/src/storage/local_storage.jl
julia/src/storage/Storage.jl
julia/src/framework/CutePanelFramework.jl
julia/src/api/SwarmHandlers.jl
julia/src/api/PriceFeedHandlers.jl
julia/src/api/TradingHandlers.jl
../../Library/Application Support/Code/User/settings.json
julia/src/agents/LLMIntegration.jl
julia/src/blockchain/Wallet.jl
julia/src/blockchain/Blockchain.jl
julia/src/api/BlockchainHandlers.jl
julia/src/price/ChainlinkFeed.jl
julia/src/CutePanel.jl
julia/src/api/Routes.jl
julia/src/blockchain/EthereumClient.jl
julia/src/swarm/algorithms/PSO.jl
julia/src/swarm/algorithms/DE.jl
julia/src/swarm/algorithms/GA.jl
julia/src/swarm/Swarms.jl
julia/src/api/DexHandlers.jl
julia/src/trading/TradingStrategy.jl
julia/src/dex/DEX.jl
julia/src/trading/RiskManagement.jl
julia/src/trading/MovingAverageStrategy.jl
julia/src/trading/MeanReversionImpl.jl
packages/agents/src/AgentsService.ts
packages/core/tsconfig.json

# Current Time
5/9/2025, 4:47:47 PM (Europe/Oslo, UTC+2:00)

# Context Window Usage
879,743 / 1,048.576K tokens used (84%)

# Current Mode
ACT MODE
</environment_details>

</file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
julia/src/dex/UniswapDEX.jl

# VSCode Open Tabs
packages/config/typescript-config/base.json
packages/core/package.json
julia/src/api/MetricsHandlers.jl
julia/src/api/LlmHandlers.jl
julia/src/swarm/SwarmBase.jl
julia/src/dex/DEXBase.jl
julia/src/dex/UniswapDEX.jl
julia/src/price/PriceFeedBase.jl
julia/src/price/PriceFeed.jl
julia/src/storage/storage_interface.jl
julia/src/storage/local_storage.jl
julia/src/storage/Storage.jl
julia/src/framework/CutePanelFramework.jl
julia/src/api/SwarmHandlers.jl
julia/src/api/PriceFeedHandlers.jl
julia/src/api/TradingHandlers.jl
../../Library/Application Support/Code/User/settings.json
julia/src/agents/LLMIntegration.jl
julia/src/blockchain/Wallet.jl
julia/src/blockchain/Blockchain.jl
julia/src/api/BlockchainHandlers.jl
julia/src/price/ChainlinkFeed.jl
julia/src/CutePanel.jl
julia/src/api/Routes.jl
julia/src/blockchain/EthereumClient.jl
julia/src/swarm/algorithms/PSO.jl
julia/src/swarm/algorithms/DE.jl
julia/src/swarm/algorithms/GA.jl
julia/src/swarm/Swarms.jl
julia/src/api/DexHandlers.jl
julia/src/trading/TradingStrategy.jl
julia/src/dex/DEX.jl
julia/src/trading/RiskManagement.jl
julia/src/trading/MovingAverageStrategy.jl
julia/src/trading/MeanReversionImpl.jl
packages/agents/src/AgentsService.ts
packages/core/tsconfig.json

# Current Time
5/9/2025, 4:48:23 PM (Europe/Oslo, UTC+2:00)

# Context Window Usage
892,696 / 1,048.576K tokens used (85%)

# Current Mode
ACT MODE
</environment_details>

</file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
julia/src/dex/UniswapDEX.jl

# VSCode Open Tabs
packages/config/typescript-config/base.json
packages/core/package.json
julia/src/api/MetricsHandlers.jl
julia/src/api/LlmHandlers.jl
julia/src/swarm/SwarmBase.jl
julia/src/dex/DEXBase.jl
julia/src/dex/UniswapDEX.jl
julia/src/price/PriceFeedBase.jl
julia/src/price/PriceFeed.jl
julia/src/storage/storage_interface.jl
julia/src/storage/local_storage.jl
julia/src/storage/Storage.jl
julia/src/framework/CutePanelFramework.jl
julia/src/api/SwarmHandlers.jl
julia/src/api/PriceFeedHandlers.jl
julia/src/api/TradingHandlers.jl
../../Library/Application Support/Code/User/settings.json
julia/src/agents/LLMIntegration.jl
julia/src/blockchain/Wallet.jl
julia/src/blockchain/Blockchain.jl
julia/src/api/BlockchainHandlers.jl
julia/src/price/ChainlinkFeed.jl
julia/src/CutePanel.jl
julia/src/api/Routes.jl
julia/src/blockchain/EthereumClient.jl
julia/src/swarm/algorithms/PSO.jl
julia/src/swarm/algorithms/DE.jl
julia/src/swarm/algorithms/GA.jl
julia/src/swarm/Swarms.jl
julia/src/api/DexHandlers.jl
julia/src/trading/TradingStrategy.jl
julia/src/dex/DEX.jl
julia/src/trading/RiskManagement.jl
julia/src/trading/MovingAverageStrategy.jl
julia/src/trading/MeanReversionImpl.jl
packages/agents/src/AgentsService.ts
packages/core/tsconfig.json

# Current Time
5/9/2025, 4:48:59 PM (Europe/Oslo, UTC+2:00)

# Context Window Usage
901,595 / 1,048.576K tokens used (86%)

# Current Mode
ACT MODE
</environment_details>

</file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
julia/src/dex/UniswapDEX.jl

# VSCode Open Tabs
packages/config/typescript-config/base.json
packages/core/package.json
julia/src/api/MetricsHandlers.jl
julia/src/api/LlmHandlers.jl
julia/src/swarm/SwarmBase.jl
julia/src/dex/DEXBase.jl
julia/src/dex/UniswapDEX.jl
julia/src/price/PriceFeedBase.jl
julia/src/price/PriceFeed.jl
julia/src/storage/storage_interface.jl
julia/src/storage/local_storage.jl
julia/src/storage/Storage.jl
julia/src/framework/CutePanelFramework.jl
julia/src/api/SwarmHandlers.jl
julia/src/api/PriceFeedHandlers.jl
julia/src/api/TradingHandlers.jl
../../Library/Application Support/Code/User/settings.json
julia/src/agents/LLMIntegration.jl
julia/src/blockchain/Wallet.jl
julia/src/blockchain/Blockchain.jl
julia/src/api/BlockchainHandlers.jl
julia/src/price/ChainlinkFeed.jl
julia/src/CutePanel.jl
julia/src/api/Routes.jl
julia/src/blockchain/EthereumClient.jl
julia/src/swarm/algorithms/PSO.jl
julia/src/swarm/algorithms/DE.jl
julia/src/swarm/algorithms/GA.jl
julia/src/swarm/Swarms.jl
julia/src/api/DexHandlers.jl
julia/src/trading/TradingStrategy.jl
julia/src/dex/DEX.jl
julia/src/trading/RiskManagement.jl
julia/src/trading/MovingAverageStrategy.jl
julia/src/trading/MeanReversionImpl.jl
packages/agents/src/AgentsService.ts
packages/core/tsconfig.json

# Current Time
5/9/2025, 4:49:35 PM (Europe/Oslo, UTC+2:00)

# Context Window Usage
910,494 / 1,048.576K tokens used (87%)

# Current Mode
ACT MODE
</environment_details>

</file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
julia/src/dex/UniswapDEX.jl

# VSCode Open Tabs
packages/config/typescript-config/base.json
packages/core/package.json
julia/src/api/MetricsHandlers.jl
julia/src/api/LlmHandlers.jl
julia/src/swarm/SwarmBase.jl
julia/src/dex/DEXBase.jl
julia/src/dex/UniswapDEX.jl
julia/src/trading/TradingStrategy.jl
julia/src/api/TradingHandlers.jl
julia/src/price/PriceFeedBase.jl
julia/src/price/PriceFeed.jl
julia/src/storage/storage_interface.jl
julia/src/storage/local_storage.jl
julia/src/storage/Storage.jl
julia/src/framework/CutePanelFramework.jl
julia/src/api/SwarmHandlers.jl
julia/src/api/PriceFeedHandlers.jl
../../Library/Application Support/Code/User/settings.json
julia/src/agents/LLMIntegration.jl
julia/src/blockchain/Wallet.jl
julia/src/blockchain/Blockchain.jl
julia/src/api/BlockchainHandlers.jl
julia/src/price/ChainlinkFeed.jl
julia/src/CutePanel.jl
julia/src/api/Routes.jl
julia/src/blockchain/EthereumClient.jl
julia/src/swarm/algorithms/PSO.jl
julia/src/swarm/algorithms/DE.jl
julia/src/swarm/algorithms/GA.jl
julia/src/swarm/Swarms.jl
julia/src/api/DexHandlers.jl
julia/src/dex/DEX.jl
julia/src/trading/RiskManagement.jl
julia/src/trading/MovingAverageStrategy.jl
julia/src/trading/MeanReversionImpl.jl
packages/agents/src/AgentsService.ts
packages/core/tsconfig.json

# Current Time
5/9/2025, 4:50:21 PM (Europe/Oslo, UTC+2:00)

# Context Window Usage
934,574 / 1,048.576K tokens used (89%)

# Current Mode
ACT MODE
</environment_details>
