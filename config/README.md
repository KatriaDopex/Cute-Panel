# Configuration Directory

This directory contains configuration files for the JuliaOS Framework.

## Files

- `default.env` - Default environment variables template
- `tsconfig.base.json` - Base TypeScript configuration
- `hardhat.config.js` - Hardhat configuration for contract development
- `tokens.json` - Token configuration for various blockchain networks

## Environment Configuration

For development, copy the default.env to your project root:

```bash
cp config/default.env .env
```

Then edit the `.env` file with your specific settings:

```env
# API keys
INFURA_API_KEY=your-infura-key
ALCHEMY_API_KEY=your-alchemy-key
OPENAI_API_KEY=your-openai-key
ANTHROPIC_API_KEY=your-anthropic-key
CHAINLINK_API_KEY=your-chainlink-key

# Private keys (never commit these to version control)
PRIVATE_KEY=your-private-key

# Network RPC URLs
ETHEREUM_RPC_URL=https://mainnet.infura.io/v3/your-infura-key
BASE_RPC_URL=https://mainnet.base.org
BSC_RPC_URL=https://bsc-dataseed.binance.org
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc
AVALANCHE_RPC_URL=https://api.avax.network/ext/bc/C/rpc
FANTOM_RPC_URL=https://rpc.ftm.tools
SOLANA_RPC_URL=https://api.mainnet-beta.solana.com

# Feature flags
ENABLE_SWARM=true
ENABLE_MONITORING=true
ENABLE_CHAINLINK=true
ENABLE_WORMHOLE=true
```

## TypeScript Configuration

To use the base TypeScript configuration in a package:

```json
{
  "extends": "../../config/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"]
}
```