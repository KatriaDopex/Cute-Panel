"""
Custom Agent Template for CutePanel
This template demonstrates how to configure and use multiple DEXes (Uniswap, SushiSwap) in an agent or trading strategy.
"""

using CutePanel
using CutePanel.dex.DEX
using CutePanel.dex.DEXBase
using CutePanel.trading.TradingStrategy

# Example DEX configurations
uniswap_config = DEXBase.DEXConfig(
    name = "UniswapV2_Mainnet",
    protocol = "uniswap",
    version = "v2",
    chain_id = 1,
    rpc_url = "https://mainnet.infura.io/v3/YOUR_INFURA_KEY",
    router_address = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    factory_address = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    api_key = "",
    private_key = "",
    gas_limit = 300000,
    gas_price = 5.0,
    slippage = 0.5,
    timeout = 30,
    metadata = Dict{String, Any}(),
)

sushiswap_config = DEXBase.DEXConfig(
    name = "SushiSwap_Mainnet",
    protocol = "sushiswap",
    version = "v1",
    chain_id = 1,
    rpc_url = "https://mainnet.infura.io/v3/YOUR_INFURA_KEY",
    router_address = "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F",
    factory_address = "0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac",
    api_key = "",
    private_key = "",
    gas_limit = 300000,
    gas_price = 5.0,
    slippage = 0.5,
    timeout = 30,
    metadata = Dict{String, Any}(),
)

# Example: Create DEX instances
uniswap_dex = DEX.create_dex_instance("uniswap", "v2", uniswap_config)
sushiswap_dex = DEX.create_dex_instance("sushiswap", "v1", sushiswap_config)

# Example: Use in Multi-DEX ArbitrageStrategy
tokens = [
    DEXBase.DEXToken("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "WETH", "Wrapped Ether", 18, 1),
    DEXBase.DEXToken("0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "USDC", "USD Coin", 6, 1),
]

dex_configs = [
    Dict("protocol" => "uniswap", "version" => "v2", "dex_name" => "UniswapV2_Mainnet", "chain_id" => 1, "rpc_url" => "https://mainnet.infura.io/v3/YOUR_INFURA_KEY", "router_address" => "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f", "factory_address" => "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"),
    Dict("protocol" => "sushiswap", "version" => "v1", "dex_name" => "SushiSwap_Mainnet", "chain_id" => 1, "rpc_url" => "https://mainnet.infura.io/v3/YOUR_INFURA_KEY", "router_address" => "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F", "factory_address" => "0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac"),
]

arb_strategy = TradingStrategy.ArbitrageStrategy(
    "MultiDEX-Arb",
    dex_configs,
    tokens;
    min_profit_threshold_percent = 0.1,
    max_trade_size_usd = 1000.0,
    optimization_params = Dict(
        "swap_gas_units" => Dict(
            "uniswap_v2_swap" => 150000,
            "default_swap" => 150000
        ),
        "simulated_slippage_pct_per_10k_usd" => 0.05
    )
)

# Example agent loop: monitor and execute arbitrage
while true
    result = TradingStrategy.execute_strategy(arb_strategy)
    println("Arbitrage result: ", result)
    sleep(30)  # Wait before next check
end
