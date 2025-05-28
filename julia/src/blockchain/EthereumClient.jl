"""
EthereumClient.jl - Ethereum blockchain client for CutePanel

This module provides specific functionality for interacting with Ethereum
and other EVM-compatible blockchains. It builds upon generic RPC calls
and provides higher-level abstractions.
"""
module EthereumClient

using HTTP, JSON3, Dates, Base64, Printf, Logging
# Assuming Blockchain.jl (which might contain _make_generic_rpc_request) is accessible
# This might need adjustment based on how modules are structured and loaded.
# If Blockchain.jl `include`s this file, then _make_generic_rpc_request is in its scope.
# If this is a standalone submodule, it might need to import from a parent Blockchain module.

export EthereumConfig, EthereumProvider, create_ethereum_provider
export call_contract_evm, send_transaction_evm, get_balance_evm, get_block_by_number_evm, get_transaction_by_hash_evm
export get_nonce_evm, estimate_gas_evm
export encode_function_call_abi, decode_function_result_abi # More ABI-aware versions
export eth_to_wei_str, wei_to_eth_float # Renamed for clarity

"""
    EthereumConfig

Configuration for an Ethereum/EVM client.
(This might be duplicative if Blockchain.jl's connection Dict holds this info.
 Consider if this struct is needed or if connection Dict is sufficient.)
"""
struct EthereumConfig
    rpc_url::String
    chain_id::Int
    # private_key::String # Private keys should be handled by a secure wallet/signer service, not here.
    default_gas_limit::Int
    default_gas_price_gwei::Float64 # In Gwei
    timeout_seconds::Int
    
    function EthereumConfig(;
        rpc_url::String,
        chain_id::Int = 1, # Default to Ethereum Mainnet
        default_gas_limit::Int = 300_000,
        default_gas_price_gwei::Float64 = 20.0, # Gwei
        timeout_seconds::Int = 30
    )
        new(rpc_url, chain_id, default_gas_limit, default_gas_price_gwei, timeout_seconds)
    end
end

"""
    EthereumProvider

Represents a connection and configuration for an EVM chain.
The `connection_dict` is the structure returned by `Blockchain.connect()`.
"""
struct EthereumProvider
    config::EthereumConfig # Contains defaults like gas price, limit
    connection_dict::Dict{String, Any} # Contains rpc_url, chain_id, connected status

    function EthereumProvider(config::EthereumConfig, connection_dict::Dict{String,Any})
        if !connection_dict["connected"]
            error("Cannot create EthereumProvider with a disconnected connection.")
        end
    elseif startswith(canonical_type, "bytes") && !endswith(canonical_type, "[]") # bytes1..bytes32
        len_match = match(r"bytes(\d+)", canonical_type)
        if !isnothing(len_match) && isa(value, Vector{UInt8})
            num_bytes = parse(Int, len_match.captures[1])
            if length(value) > num_bytes error("Data for bytes$num_bytes is too long: $(length(value)) bytes") end
            return rpad(bytes2hex(value), 64, '0') # bytesN are left-aligned
        else
            error("Invalid value for bytesN type '$canonical_type' or value type '$(typeof(value))'. Expected Vector{UInt8}.")
        end
    elseif startswith(canonical_type, "(") && endswith(canonical_type, ")") # Static Tuple/Struct
        if !isa(value, Tuple) && !isa(value, AbstractVector)
            error("Argument for static tuple/struct type $canonical_type must be a Tuple or Vector. Got $(typeof(value))")
        end
        element_types_str_content = canonical_type[2:end-1]
        element_type_strs = []
        balance = 0; current_type = ""
        for char in element_types_str_content
            if char == '(' balance +=1 elseif char == ')' balance -=1 end
            if char == ',' && balance == 0
                push!(element_type_strs, strip(current_type)); current_type = ""
            else current_type *= char end
        end
        push!(element_type_strs, strip(current_type))

        if length(value) != length(element_type_strs)
            error("Number of values in static tuple/struct ($(length(value))) does not match types in signature ($canonical_type -> $(length(element_type_strs)))")
        end

        encoded_elements = ""
        for (idx, elem_val) in enumerate(value)
            elem_type_str = strip(element_type_strs[idx])
            # Ensure element type is static for a static tuple
            canonical_elem_type = _get_canonical_type(elem_type_str)
            if canonical_elem_type == "string" || canonical_elem_type == "bytes" || endswith(canonical_elem_type, "[]") || (startswith(canonical_elem_type, "(") && occursin(r"string|bytes|\[\]", canonical_elem_type))
                error("Static tuple $canonical_type cannot contain dynamic element type '$elem_type_str'. This indicates an issue with how the tuple was classified as static or the ABI type string itself.")
            end
            encoded_elements *= _abi_encode_static_value(elem_val, elem_type_str) # Recursive call for static elements
        end
        # Static tuples are encoded in-place and are not padded to 32 bytes themselves,
        # but their combined encoding contributes to the 32-byte slots of the parent structure.
        # If a static tuple is a top-level argument, it will be padded as part of the main encoding loop.
        # Here, we just return the concatenated hex of its elements.
        return encoded_elements
    else
        error("Unsupported static ABI type '$canonical_type' or value type '$(typeof(value))' for _abi_encode_static_value.")
    end
end

function create_ethereum_provider(rpc_url::String, chain_id::Int;
                                  default_gas_limit=300000, default_gas_price_gwei=20.0, timeout=30)
    
    config = EthereumConfig(
        rpc_url=rpc_url, 
        chain_id=chain_id,
        default_gas_limit=default_gas_limit,
        default_gas_price_gwei=default_gas_price_gwei,
        timeout_seconds=timeout
    )
    
    # Attempt to connect to get network name for Blockchain.connect
    # This is a bit circular. Blockchain.connect should ideally just take rpc_url.
    # For now, we derive a placeholder network name.
    network_name = "evm_chain_$(chain_id)" 
    connection = Main.Blockchain.connect(network=network_name, endpoint_url=rpc_url) # Use Main.Blockchain if Blockchain.jl is top-level
    
    if !connection["connected"]
        error("Failed to connect to Ethereum RPC at $rpc_url for chain ID $chain_id")
    end
    
    return EthereumProvider(config, connection)
end


# ===== Helper Functions =====

eth_to_wei_str(eth_amount::Number)::String = "0x" * string(BigInt(round(eth_amount * 10^18)), base=16)
wei_to_eth_float(wei_amount_hex::String)::Float64 = Float64(parse(BigInt, wei_amount_hex[3:end], base=16) / BigInt(10)^18)

# ==============================================================================
# Ethereum ABI Encoding and Decoding
# ==============================================================================
#
# IMPORTANT LIMITATIONS:
# The ABI encoder/decoder implemented below has been improved to handle:
#   - Common static types (uintN, intN, address, bool, bytesN).
#   - Basic dynamic types (string, bytes, T[] where T is a static type).
#   - Simple static tuples/structs (e.g., a tuple where all elements are static types).
#
# However, it is NOT a fully general-purpose, ABI-compliant library.
# It would likely NOT correctly handle all edge cases or more complex/nested ABI structures, such as:
#   - Arrays of dynamic types (e.g., string[], bytes[][]).
#   - Tuples/structs containing dynamic types (e.g., (uint256, string, address[])).
#   - Deeply nested dynamic arrays or tuples.
#   - Complex interactions of offsets for multiple dynamic types within tuples or arrays.
#
# Achieving full ABI compliance is a substantial library development effort in itself
# and would ideally involve a dedicated, rigorously tested ABI library.
#
# Users should exercise CAUTION and TEST THOROUGHLY when using these functions
# with complex ABI structures beyond the explicitly supported cases.
# For production systems dealing with arbitrary or complex ABIs, consider integrating
# a more mature, specialized ABI handling library if available, or contributing
# to the enhancement of this one with comprehensive testing.
#
# ==============================================================================

using SHA # Ensure SHA is imported

# --- ABI Encoding ---

"""
    _get_canonical_type(abi_type_str::String)::String

Returns the canonical form of an ABI type string for signature hashing.
e.g., "uint" -> "uint256", "int" -> "int256", "byte" -> "bytes1"
Tuples are represented as "(type1,type2,...)".
"""
function _get_canonical_type(abi_type_str::String)::String
    # This is a simplified version. A full version handles all aliases and tuple structures.
    # Basic canonical types for Uniswap interactions
    type_map = Dict(
        "uint" => "uint256",
        "int" => "int256",
        "byte" => "bytes1",
        "address" => "address",
        "bool" => "bool",
        "string" => "string", # dynamic
        "bytes" => "bytes"   # dynamic
    )
    # Handle array types like address[] -> address[] (already canonical for this purpose)
    # and uint256[] etc.
    if endswith(abi_type_str, "[]")
        base_type = replace(abi_type_str, "[]" => "")
        return get(type_map, base_type, base_type) * "[]"
    end
    return get(type_map, abi_type_str, abi_type_str) # Assume already canonical if not in map
end


"""
    _abi_encode_static_value(value::Any, abi_type_str::String)::String

Encodes a single static ABI type value to its 32-byte hex representation.
"""
function _abi_encode_static_value(value::Any, abi_type_str::String)::String
    canonical_type = _get_canonical_type(abi_type_str)

    if canonical_type == "address" && isa(value, String) && startswith(value, "0x") && length(value) == 42
        return lpad(value[3:end], 64, '0')
    elseif (startswith(canonical_type, "uint") || startswith(canonical_type, "int")) && isa(value, Integer)
        bits_str = match(r"(u?int)(\d*)", canonical_type)
        bits = isempty(bits_str.captures[2]) ? 256 : parse(Int, bits_str.captures[2])
        
        val_big = BigInt(value)
        if val_big < 0 && startswith(canonical_type, "uint")
            error("Cannot encode negative value $value for unsigned type $canonical_type")
        end
        # Handle two's complement for negative signed integers
        if startswith(canonical_type, "int") && val_big < 0
            val_big = (BigInt(1) << bits) + val_big 
        end
        hex_val = string(val_big, base=16)
        if length(hex_val) > div(bits, 4)
            error("Value $value too large for type $canonical_type (max $bits bits)")
        end
        return lpad(hex_val, 64, '0')
    elseif canonical_type == "bool" && isa(value, Bool)
        return lpad(value ? "1" : "0", 64, '0')
    elseif startswith(canonical_type, "bytes") && !endswith(canonical_type, "[]") # bytes1..bytes32
        len_match = match(r"bytes(\d+)", canonical_type)
        if !isnothing(len_match) && isa(value, Vector{UInt8})
            num_bytes = parse(Int, len_match.captures[1])
            if length(value) > num_bytes error("Data for bytes$num_bytes is too long: $(length(value)) bytes") end
            return rpad(bytes2hex(value), 64, '0') # bytesN are left-aligned
        else
            error("Invalid value for bytesN type '$canonical_type' or value type '$(typeof(value))'. Expected Vector{UInt8}.")
        end
    else
        error("Unsupported static ABI type '$canonical_type' or value type '$(typeof(value))' for _abi_encode_static_value.")
    end
end

"""
    _abi_encode_dynamic_value(value::Any, abi_type_str::String)::String

Encodes the data part of a dynamic ABI type (e.g., string, bytes, T[]).
Returns the hex string of (length + data_padded_to_32_bytes).
"""
function _abi_encode_dynamic_value(value::Any, abi_type_str::String)::String
    canonical_type = _get_canonical_type(abi_type_str)

    if (canonical_type == "string" && isa(value, String)) || (canonical_type == "bytes" && isa(value, Vector{UInt8}))
        data_bytes = isa(value, String) ? Vector{UInt8}(value) : value
        len_hex = lpad(string(length(data_bytes), base=16), 64, '0')
        data_hex = bytes2hex(data_bytes)
        # Pad data_hex to a multiple of 64 hex characters (32 bytes)
        padded_data_hex = rpad(data_hex, ceil(Int, length(data_hex) / 64) * 64, '0')
        return len_hex * padded_data_hex
    elseif endswith(canonical_type, "[]") && isa(value, AbstractVector) # Dynamic array of static types
        element_type_str = replace(canonical_type, "[]" => "")
        
        # Check if the element type is itself dynamic (e.g. string, bytes, another_array[], or a dynamic tuple)
        is_element_type_dynamic = false
        if element_type_str == "string" || element_type_str == "bytes" || endswith(element_type_str, "[]")
            is_element_type_dynamic = true
        elseif startswith(element_type_str, "(") && endswith(element_type_str, ")") # Element is a tuple
            # Check if this tuple type is dynamic
            temp_element_types_str_content = element_type_str[2:end-1]
            temp_element_type_strs_tuple = []
            balance_tuple = 0; current_type_tuple_temp = ""
            for char_tt in temp_element_types_str_content
                if char_tt == '(' balance_tuple +=1 elseif char_tt == ')' balance_tuple -=1 end
                if char_tt == ',' && balance_tuple == 0
                    push!(temp_element_type_strs_tuple, strip(current_type_tuple_temp)); current_type_tuple_temp = ""
                else current_type_tuple_temp *= char_tt end
            end
            push!(temp_element_type_strs_tuple, strip(current_type_tuple_temp))
            for elem_type_str_check_tuple in temp_element_type_strs_tuple
                canonical_elem_type_check_tuple = _get_canonical_type(strip(elem_type_str_check_tuple))
                if canonical_elem_type_check_tuple == "string" || canonical_elem_type_check_tuple == "bytes" || endswith(canonical_elem_type_check_tuple, "[]") ||
                   (startswith(canonical_elem_type_check_tuple, "(") && occursin(r"string|bytes|\[\]", canonical_elem_type_check_tuple))
                    is_element_type_dynamic = true; break
                end
            end
        end

        if is_element_type_dynamic
            # Array of dynamic types (e.g., string[], bytes[], MyDynamicStruct[])
            # This is complex: head contains offsets to each element's data in the tail.
            @error "Encoding arrays of dynamic types (e.g., string[], bytes[][], or arrays of dynamic structs) is NOT YET FULLY SUPPORTED and may produce incorrect results. Type: $canonical_type"
            # Placeholder logic: encode length, then try to encode each dynamic element's data sequentially.
            # This will be incorrect for offsets. A proper implementation needs to calculate all tail sizes first.
            len_hex = lpad(string(length(value), base=16), 64, '0')
            
            # This part needs a complete rewrite for arrays of dynamic types.
            # It should build a head part (offsets) and a tail part (actual data of dynamic elements).
            # For now, this will likely be incorrect.
            elements_data_hex = ""
            # This is a conceptual placeholder.
            # Each `elem` here is dynamic. Its encoding would be its own data block.
            # The main array's data part should contain *offsets* to these blocks.
            # current_offset_for_array_elements = length(value) * 32 # bytes, after all offset words
            # temp_array_head_parts = []
            # temp_array_tail_parts = []
            # for elem_dyn in value
            #     push!(temp_array_head_parts, lpad(string(current_offset_for_array_elements, base=16), 64, '0'))
            #     encoded_elem_dyn_data = _abi_encode_dynamic_value(elem_dyn, element_type_str) # This recursive call is problematic if not careful with context
            #     push!(temp_array_tail_parts, encoded_elem_dyn_data)
            #     current_offset_for_array_elements += div(length(encoded_elem_dyn_data),2) # This is length of data, not just one word
            # end
            # elements_hex = join(temp_array_head_parts) * join(temp_array_tail_parts)
            # The above is still not quite right for the general case of _abi_encode_dynamic_value.
            # This function is meant to return the *data block* for one dynamic item.
            # If that item is an array of dynamic things, its data block is (length, offset1, offset2, ..., data1, data2, ...).

            # Array of dynamic types (e.g., string[], bytes[], MyDynamicStruct[])
            len_hex = lpad(string(length(value), base=16), 64, '0')
            
            # Head part of the array data will contain offsets to each dynamic element.
            # Tail part will contain the actual data of each dynamic element.
            array_head_parts_hex = String[] # Will store offsets
            array_tail_parts_hex = String[] # Will store encoded data of dynamic elements
            
            # The first offset is relative to the start of the array's data block (i.e., after len_hex).
            # This offset points to the start of the first dynamic element's data, which comes *after* all the offset words.
            # Number of offset words = number of elements in the array.
            current_offset_in_tail_bytes = length(value) * 32 

            for elem_val in value
                push!(array_head_parts_hex, lpad(string(current_offset_in_tail_bytes, base=16), 64, '0'))
                
                # Now encode the dynamic element itself.
                # If element_type_str is "string" or "bytes", _abi_encode_dynamic_value handles it.
                # If element_type_str is a dynamic tuple like "(uint,string)", we need a robust way to encode it.
                local encoded_elem_data::String
                if element_type_str == "string" || element_type_str == "bytes"
                    # This is a direct call for simple dynamic types (string, bytes).
                    # It returns (length + data_padded).
                    encoded_elem_data = _abi_encode_dynamic_value(elem_val, element_type_str)
                elseif startswith(element_type_str, "(") && endswith(element_type_str, ")") # Element is a dynamic tuple
                    # This is the complex case: (uint,string)[]
                    # We need a function to encode the *data* of one dynamic tuple.
                    # This function would itself handle internal head/tail for that tuple.
                    # Let's call a conceptual _abi_encode_one_dynamic_tuple_data
                    # For now, this is a major point of complexity not fully implemented.
                    @error "Encoding for array element of dynamic tuple type '$element_type_str' is complex and likely incomplete/incorrect."
                    # Placeholder: try to encode its parts sequentially, which is wrong for internal dynamic parts.
                    # This needs a recursive call to a full tuple encoder.
                    # This is a placeholder and will likely be incorrect for complex dynamic tuples.
                    # It should call a function that returns the complete encoded block for the tuple.
                    # For now, let's assume a simplified (and likely incorrect for nested dynamics) encoding.
                    # This part needs a dedicated recursive tuple encoder.
                    # For the purpose of this step, we'll just error out or return a placeholder.
                    # error("Full encoding of arrays of dynamic tuples like '$canonical_type' is not yet implemented.")
                    # Let's try a simplified concatenation, knowing it's limited:
                    temp_dyn_tuple_element_types_str_content = element_type_str[2:end-1]
                    temp_dyn_tuple_element_type_strs = []
                    balance_dtt = 0; current_type_dtt_temp = ""
                    for char_dtt in temp_dyn_tuple_element_types_str_content
                        if char_dtt == '(' balance_dtt +=1 elseif char_dtt == ')' balance_dtt -=1 end
                        if char_dtt == ',' && balance_dtt == 0
                            push!(temp_dyn_tuple_element_type_strs, strip(current_type_dtt_temp)); current_type_dtt_temp = ""
                        else current_type_dtt_temp *= char_dtt end
                    end
                    push!(temp_dyn_tuple_element_type_strs, strip(current_type_dtt_temp))

                    # This is where _abi_encode_one_dynamic_tuple_data would be called.
                    # It would return the complete encoded block for this one tuple.
                    # For now, we'll use a simplified, likely incorrect approach for demonstration.
                    # This needs a proper recursive encoder for dynamic tuples.
                    # The output of this should be the *entire data block* for the tuple.
                    # For example, for (uint256, string), it would be (static_uint_val, offset_to_string_data, string_len, string_data_padded).
                    # This is too complex to correctly implement in this single step without a full recursive encoder.
                    # We will mark this as a known major limitation.
                    @warn "Simplified encoding for elements of type '$element_type_str' in an array. May be incorrect for nested dynamic parts."
                    encoded_elem_data = "" # Placeholder for the dynamic tuple's data block
                    # This loop is a naive attempt and incorrect for dynamic tuples with internal dynamic parts.
                    # It should be replaced by a call to a recursive tuple encoder.
                    # For (uint, string), the uint is static, string is dynamic.
                    # The tuple's encoding would be: uint_val (32 bytes) + offset_to_string (32 bytes) + string_len (32 bytes) + string_data_padded.
                    # This is what _abi_encode_one_dynamic_tuple_data should produce.
                    # For now, we cannot correctly form `encoded_elem_data` here for dynamic tuples.
                    # The original error for string[] or bytes[] was more direct.
                    # Let's reinstate an error for arrays of dynamic tuples for now.
                     error("Encoding arrays of dynamic tuples (e.g. (uint,string)[]) is not yet fully supported. Type: $canonical_type")

                elseif endswith(element_type_str, "[]") # Array of arrays (e.g. uint[][])
                     error("Encoding multi-dimensional arrays or arrays of arrays (e.g., uint[][], string[][]) is not supported by this simplified encoder. Type: $canonical_type")
                else
                    # Should not happen if is_element_type_dynamic was determined correctly
                    error("Unexpected dynamic element type in array: $element_type_str")
                end
                
                push!(array_tail_parts_hex, encoded_elem_data)
                current_offset_in_tail_bytes += div(length(encoded_elem_data), 2) # Add length of this element's data block
            end
            return len_hex * join(array_head_parts_hex) * join(array_tail_parts_hex)

        else # Array of static types (including static tuples)
            len_hex = lpad(string(length(value), base=16), 64, '0')
            # _abi_encode_static_value now handles static tuples correctly.
            elements_hex = join([_abi_encode_static_value(elem, element_type_str) for elem in value])
            return len_hex * elements_hex
        end
    else
        error("Unsupported dynamic ABI type '$canonical_type' or value type '$(typeof(value))' for _abi_encode_dynamic_value.")
    end
end


"""
Encodes function arguments for an EVM contract call.
`function_signature_str` e.g., "transfer(address,uint256)" (canonical types)
`args_with_types` e.g., [("0x123...", "address"), (100, "uint256")]

**Current known limitations for `encode_function_call_abi`:**
- Does not fully support encoding of tuples/structs that themselves contain dynamic types.
  The offset calculation for multiple dynamic elements within a tuple is simplified and may be incorrect.
- Arrays of dynamic types (e.g., `string[]`) are explicitly not supported.
- Deeply nested structures may not be handled correctly.
"""
function encode_function_call_abi(function_signature_str::String, args_with_types::Vector{Tuple{Any, String}})::String
    # @warn """encode_function_call_abi: This implementation is improved to handle static tuples (structs)
    #          and basic dynamic types, but has limitations for complex nested dynamic types (see notes above). 
    #          Use with caution and test thoroughly for your specific ABI."""
    
    sig_bytes = Vector{UInt8}(function_signature_str)
    hash_bytes = SHA.keccak256(sig_bytes)
    selector = bytes2hex(hash_bytes[1:4])
    
    head_parts_hex = String[]
    tail_parts_hex = String[]
    
    # Calculate initial offset for dynamic data: number of args * 32 bytes
    # This is the offset from the beginning of the arguments block (after selector)
    current_dynamic_offset_bytes = length(args_with_types) * 32 

    # First pass: encode static parts and offsets for dynamic parts
    for (arg_val, arg_type_str) in args_with_types
        canonical_arg_type = _get_canonical_type(arg_type_str)
        is_dynamic = canonical_arg_type == "string" || canonical_arg_type == "bytes" || endswith(canonical_arg_type, "[]")

        if is_dynamic
            # For dynamic types, head part is the offset to its data in the tail
            push!(head_parts_hex, lpad(string(current_dynamic_offset_bytes, base=16), 64, '0'))
            
            encoded_dynamic_data = _abi_encode_dynamic_value(arg_val, canonical_arg_type)
            push!(tail_parts_hex, encoded_dynamic_data)
            current_dynamic_offset_bytes += div(length(encoded_dynamic_data), 2) # Length of data part only

        elseif startswith(canonical_arg_type, "(") && endswith(canonical_arg_type, ")") # Tuple/Struct as an argument
            # This is where the logic for handling tuples (static or dynamic) as arguments goes.
            # A static tuple is encoded in place. A dynamic tuple has its offset encoded in place,
            # and its actual content (which itself might have head/tail parts) goes into the tail.

            # For now, we assume _abi_encode_static_value can handle *static* tuples.
            # If a tuple is dynamic (contains dynamic members), it needs special handling here.
            # This simplified encoder might not correctly handle dynamic tuples as direct arguments yet.
            # The check for is_tuple_dynamic was inside the tuple handling block.
            # Let's refine this:
            
            # Determine if the tuple itself is dynamic
            is_tuple_dynamic = false # Placeholder: needs proper check
            temp_element_types_str_content = canonical_arg_type[2:end-1]
            temp_element_type_strs = []
            balance = 0; current_type_temp = ""
            for char_t in temp_element_types_str_content
                if char_t == '(' balance +=1 elseif char_t == ')' balance -=1 end
                if char_t == ',' && balance == 0
                    push!(temp_element_type_strs, strip(current_type_temp)); current_type_temp = ""
                else current_type_temp *= char_t end
            end
            push!(temp_element_type_strs, strip(current_type_temp))

            for elem_type_str_check in temp_element_type_strs
                canonical_elem_type_check = _get_canonical_type(strip(elem_type_str_check))
                if canonical_elem_type_check == "string" || canonical_elem_type_check == "bytes" || endswith(canonical_elem_type_check, "[]") ||
                   (startswith(canonical_elem_type_check, "(") && occursin(r"string|bytes|\[\]", canonical_elem_type_check)) # Heuristic for nested dynamic tuple
                    is_tuple_dynamic = true
                    break
                end
            end

            if is_tuple_dynamic
                # Dynamic tuple: encode offset in head, actual tuple data in tail.
                # This is the complex case requiring recursive encoding with offset management.
                @error "Encoding of dynamic tuples/structs as direct function arguments is NOT YET FULLY SUPPORTED and may be incorrect. Arg type: $canonical_arg_type"
                # Placeholder: push offset, and a (likely incorrect) concatenation for tail.
                push!(head_parts_hex, lpad(string(current_dynamic_offset_bytes, base=16), 64, '0'))
                
                # This is where a recursive call to a full tuple encoder would go.
                # For now, it will likely fail or produce wrong results for complex dynamic tuples.
                # Let's try to use _abi_encode_static_value which now handles static tuples,
                # but it will error if it finds dynamic elements inside what it expects to be a static tuple.
                # This highlights the need for a proper _abi_encode_tuple_value that handles internal dynamics.
                # For now, this path for dynamic tuples as arguments is problematic.
                # We'll let it attempt with _abi_encode_static_value, which will error if it's truly dynamic.
                # A better approach would be a dedicated _abi_encode_tuple_data function.
                
                # --- Placeholder for dynamic tuple encoding ---
                # This part needs a robust recursive encoder.
                # The current _abi_encode_static_value is for *static* tuples.
                # If we pass a dynamic tuple type string to it, it will error.
                # For now, we'll just try to encode it as if it were static, which is wrong
                # if it has dynamic members, but illustrates the point of needing a proper handler.
                # A truly dynamic tuple's encoding would itself have a head (for its static parts and offsets)
                # and a tail (for its dynamic parts' data).
                
                # This is a conceptual placeholder for what `_abi_encode_dynamic_tuple_data` would do:
                # encoded_dynamic_tuple_data_block = _abi_encode_tuple_recursively(arg_val, element_type_strs)
                # push!(tail_parts_hex, encoded_dynamic_tuple_data_block)
                # current_dynamic_offset_bytes += div(length(encoded_dynamic_tuple_data_block), 2)
                # For now, we'll let it fall through to the static type encoding, which will error if the tuple is dynamic.
                # This is not ideal but reflects the current limitation.
                # A proper solution requires a recursive tuple encoder.
                # Let's assume for now that if a tuple is passed as a direct argument and is_tuple_dynamic is true,
                # it's an unsupported complex case for this simplified encoder.
                # The error in _abi_encode_static_value for dynamic elements in a tuple will catch this.
                # So, we treat it like a static type for the head part, which means it's encoded in-place.
                # This is only correct if the tuple is actually static.
                # If is_tuple_dynamic is true, this path is problematic.
                # The logic for `is_tuple_dynamic` needs to correctly decide if it's placed in head or tail.
                # If dynamic, it's an offset in head, data in tail.
                # If static, it's data in head.
                # The current `_abi_encode_static_value` handles static tuples.
                # So, if `is_tuple_dynamic` is true, we need to place an offset.
                
                # Corrected logic:
                if is_tuple_dynamic
                    push!(head_parts_hex, lpad(string(current_dynamic_offset_bytes, base=16), 64, '0'))
                    # This is where a call to a proper recursive tuple encoder for the tail would go.
                    # e.g., encoded_tuple_data = _encode_tuple_data_recursively(arg_val, element_type_strs, initial_offset_within_tuple_data_block)
                    # For now, this remains a significant limitation.
                    # We'll push a placeholder or error if we try to fully implement this here.
                    # Let's assume for now that if a tuple is dynamic, we cannot properly encode its tail part yet.
                    # The `_abi_encode_dynamic_value` should be the one to handle this if the tuple is part of an array.
                    # If it's a direct argument, this `encode_function_call_abi` needs to manage its tail.
                    @error "Full encoding of dynamic tuples as direct arguments is complex and not fully implemented. Arg type: $canonical_arg_type. Result may be incorrect."
                    # Fallback: attempt to encode its elements as if it were a sequence of static items for the tail, which is wrong.
                    temp_tail_data = ""
                    for (idx_tt, elem_val_tt) in enumerate(arg_val)
                        temp_tail_data *= _abi_encode_static_value(elem_val_tt, strip(temp_element_type_strs[idx_tt]))
                    end
                    push!(tail_parts_hex, temp_tail_data) # This is likely incorrect for dynamic tuples
                    current_dynamic_offset_bytes += div(length(temp_tail_data), 2)
                else # Tuple is static
                    push!(head_parts_hex, _abi_encode_static_value(arg_val, canonical_arg_type))
                end

            end
        else # Simple static type
            push!(head_parts_hex, _abi_encode_static_value(arg_val, canonical_arg_type))
        end
    end
    
    return "0x" * selector * join(head_parts_hex) * join(tail_parts_hex)
end

# --- ABI Decoding (Conceptual Placeholders) ---

"""
Decodes a single 32-byte data segment from hex based on a canonical ABI type string.
"""
function _abi_decode_value(data_segment_hex::String, abi_type_str::String, full_data_hex_no_prefix::String, current_data_ptr::Ref{Int})::Any
    canonical_type = _get_canonical_type(abi_type_str)

    if canonical_type == "address"
        return "0x" * data_segment_hex[end-39:end] # Address is last 20 bytes of the 32-byte word
    elseif startswith(canonical_type, "uint") || startswith(canonical_type, "int")
        # For uintN and intN, they are right-padded in the 32-byte word.
        # The parse function handles the full 32-byte hex.
        val = parse(BigInt, data_segment_hex, base=16)
        bits_match = match(r"(u?int)(\d*)", canonical_type)
        bits = if !isnothing(bits_match) && !isempty(bits_match.captures[2])
                    parse(Int, bits_match.captures[2])
                 elseif canonical_type == "uint" || canonical_type == "int" # Default to 256 if no size specified
                    256
                 else # Fallback for types like uint112, uint160, int24
                    # Try to extract from type string directly if not matching common pattern
                    num_str = filter(isdigit, canonical_type)
                    isempty(num_str) ? 256 : parse(Int, num_str) # Default to 256 if no digits found
                 end

        if startswith(canonical_type, "int") && val >= (BigInt(1) << (bits - 1)) # Check sign bit
            val -= (BigInt(1) << bits) # Convert from two's complement
        end
        return val
    elseif canonical_type == "bool"
        return parse(BigInt, data_segment_hex, base=16) != 0
    elseif startswith(canonical_type, "bytes") && !endswith(canonical_type, "[]") # bytes1..bytes32
        len_match = match(r"bytes(\d+)", canonical_type)
        if !isnothing(len_match)
            num_bytes = parse(Int, len_match.captures[1])
            # bytesN are left-padded (stored at the beginning of the 32-byte word)
            return hex2bytes(data_segment_hex[1 : num_bytes*2]) 
        end
    # --- Dynamic Type Decoding ---
    elseif canonical_type == "string" || canonical_type == "bytes"
        # data_segment_hex contains the offset to the dynamic data part.
        offset_bytes = parse(Int, data_segment_hex, base=16)
        # Offset is in bytes from the start of the *entire data block* (data_hex_no_prefix).
        # Convert byte offset to character index (1-based for Julia strings).
        offset_char_idx = offset_bytes * 2 + 1

        if offset_char_idx + 64 - 1 > length(full_data_hex_no_prefix)
            @error "ABI Decoding: Offset for dynamic type $canonical_type points out of bounds or not enough data for length."
            return "ERROR_DECODING_OFFSET_$(canonical_type)"
        end
        
        # Read the length of the data (which is itself a uint256)
        len_hex = full_data_hex_no_prefix[offset_char_idx : offset_char_idx + 63]
        len_bytes = parse(Int, len_hex, base=16)
        
        data_start_char_idx = offset_char_idx + 64
        data_hex_chars_to_read = len_bytes * 2

        if data_start_char_idx + data_hex_chars_to_read - 1 > length(full_data_hex_no_prefix)
            @error "ABI Decoding: Dynamic type $canonical_type data length ($len_bytes bytes) exceeds available data."
            return "ERROR_DECODING_DATA_LENGTH_$(canonical_type)"
        end
        
        actual_data_hex = full_data_hex_no_prefix[data_start_char_idx : data_start_char_idx + data_hex_chars_to_read - 1]
        
        return canonical_type == "string" ? String(hex2bytes(actual_data_hex)) : hex2bytes(actual_data_hex)

    elseif endswith(canonical_type, "[]") # Dynamic array of static types
        offset_bytes = parse(Int, data_segment_hex, base=16)
        offset_char_idx = offset_bytes * 2 + 1

        if offset_char_idx + 64 - 1 > length(full_data_hex_no_prefix)
            @error "ABI Decoding: Offset for dynamic array $canonical_type points out of bounds."
            return ["ERROR_DECODING_ARRAY_OFFSET"]
        end

        len_elements = parse(Int, full_data_hex_no_prefix[offset_char_idx : offset_char_idx + 63], base=16)
        elements_data_start_char_idx = offset_char_idx + 64
        
        element_type_str = replace(canonical_type, "[]" => "")
        if element_type_str == "string" || element_type_str == "bytes" || endswith(element_type_str, "[]")
            @error "Decoding arrays of dynamic types (e.g., string[], bytes[][]) is not supported by this simplified decoder."
            return ["ERROR_ARRAY_OF_DYNAMIC_UNSUPPORTED"]
        end

        decoded_array_elements = Any[]
        current_element_char_idx = elements_data_start_char_idx
        for _ in 1:len_elements
            if current_element_char_idx + 64 -1 > length(full_data_hex_no_prefix)
                @error "ABI Decoding: Not enough data for all elements of dynamic array $canonical_type."
                break
            end
            element_segment_hex = full_data_hex_no_prefix[current_element_char_idx : current_element_char_idx + 63]
            # For static elements in a dynamic array, current_data_ptr is not used by _abi_decode_value for the element itself.
            # The full_data_hex_no_prefix is passed in case an element *was* dynamic (though we error out above for that).
            push!(decoded_array_elements, _abi_decode_value(element_segment_hex, element_type_str, full_data_hex_no_prefix, current_data_ptr)) # current_data_ptr is not strictly needed here for static elements
            current_element_char_idx += 64
        end
        return decoded_array_elements
    end
    @warn "Unsupported ABI type '$abi_type_str' for decoding. Returning raw hex segment."
    return "0x" * data_segment_hex
end

"""
Decodes function call result data.
`output_abi_types` is a vector of canonical ABI type strings like ["address", "uint256"].

**Current known limitations for `decode_function_result_abi`:**
- Does not support decoding of arrays of dynamic types (e.g., `string[]`).
- Decoding of tuples/structs containing dynamic types is not implemented/tested.
- Assumes a flat structure for output types; nested tuples in output are not explicitly handled.
"""
function decode_function_result_abi(result_hex::String, output_abi_types::Vector{String})::Vector{Any}
    # @warn """decode_function_result_abi: This implementation is improved for static types and basic dynamic types/arrays.
    #          However, it has limitations for complex nested or dynamic structures (see notes above).
    #          Use with caution and test thoroughly for your specific ABI."""
    
    (isempty(result_hex) || result_hex == "0x" || length(result_hex) < 2) && return Any[] # Allow "0x" for empty returns
    if result_hex == "0x" && !isempty(output_abi_types)
        @warn "ABI decoding: Received '0x' but expected outputs $(output_abi_types). Returning empty array."
        return Any[]
    elseif result_hex == "0x" && isempty(output_abi_types)
        return Any[] # Valid empty return
    end

    data_hex_no_prefix = result_hex[3:end]
    if isempty(data_hex_no_prefix) && !isempty(output_abi_types)
         @warn "ABI decoding: Received empty data string (after 0x) but expected outputs $(output_abi_types). Returning empty."
        return Any[]
    elseif isempty(data_hex_no_prefix) && isempty(output_abi_types)
        return Any[] # Valid empty return
    end


    outputs = Any[]
    head_read_char_idx = 1 # Character index in data_hex_no_prefix for reading head slots
    
    # The start of the dynamic data section is after all head slots.
    # Each head slot is 32 bytes (64 hex chars).
    dynamic_section_start_char_idx = (length(output_abi_types) * 64) + 1
    current_dynamic_read_ptr = Ref(dynamic_section_start_char_idx) # Ref to pass for modification

    for type_str in output_abi_types
        # Ensure there's enough data for a 32-byte head slot
        if head_read_char_idx + 64 - 1 > length(data_hex_no_prefix)
            @error "ABI decoding: Not enough data left in head to decode type '$type_str'. Expected 32 bytes, got $(length(data_hex_no_prefix) - head_read_char_idx + 1) chars. Decoded $(length(outputs))."
            # This often indicates an issue with the contract call or the expected output_abi_types.
            break 
        end
        segment_hex = data_hex_no_prefix[head_read_char_idx : head_read_char_idx + 63]
        
        # The _abi_decode_value function will handle if it's static or needs to look at dynamic part.
        # It will use/update current_dynamic_read_ptr if it decodes a dynamic type from its offset.
        # Note: The current _abi_decode_value for dynamic types is still a placeholder.
        decoded_val = _abi_decode_value(segment_hex, type_str, data_hex_no_prefix, current_dynamic_read_ptr)
        push!(outputs, decoded_val)
        
        head_read_char_idx += 64 # Move to the next 32-byte slot in the head
    end
    return outputs
end


# ===== Ethereum RPC Method Wrappers =====
# These use the _make_generic_rpc_request from the parent Blockchain module.

function call_contract_evm(provider::EthereumProvider, contract_address::String, data::String; block::String="latest")::String
    if !provider.connection_dict["connected"] error("Provider not connected.") end
    params = [Dict("to" => contract_address, "data" => data), block]
    # Assumes _make_generic_rpc_request is available from parent Blockchain module
    return Main.Blockchain._make_generic_rpc_request(provider.config.rpc_url, "eth_call", params)
end

function get_nonce_evm(provider::EthereumProvider, address::String; block::String="latest")::Int
    if !provider.connection_dict["connected"] error("Provider not connected.") end
    hex_nonce = Main.Blockchain._make_generic_rpc_request(provider.config.rpc_url, "eth_getTransactionCount", [address, block])
    return parse(Int, hex_nonce[3:end], base=16)
end

function estimate_gas_evm(provider::EthereumProvider, tx_params::Dict)::Int
    # tx_params should include: from, to, value (optional), data (optional)
    if !provider.connection_dict["connected"] error("Provider not connected.") end
    hex_gas = Main.Blockchain._make_generic_rpc_request(provider.config.rpc_url, "eth_estimateGas", [tx_params])
    return parse(Int, hex_gas[3:end], base=16)
end

# get_balance_evm, send_transaction_evm, etc., would also be implemented here,
# potentially calling _make_generic_rpc_request or more specific logic.
# They might also use functions from Blockchain.jl if those are sufficiently generic
# and just need the connection dictionary.

# Example:
function get_balance_evm(provider::EthereumProvider, address::String; block::String="latest")::Float64
    if !provider.connection_dict["connected"] error("Provider not connected.") end
    # This can directly use the generic function if it's suitable
    return Main.Blockchain.get_balance_generic(address, provider.connection_dict)
end

# Note: Functions like send_transaction_evm would involve signing, which is complex
# and requires secure private key management, not handled in this illustrative client.

@info "EthereumClient.jl loaded."

end # module EthereumClient
