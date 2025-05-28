"""
raydium_client.py - Python FFI client for Raydium/Serum/Solana integration

This module provides Python functions for Raydium DEX operations using solana-py and pyserum.
It is designed to be called from Julia via PyCall.jl or another FFI bridge.
"""

from solana.rpc.api import Client as SolanaClient
from solana.publickey import PublicKey
from solana.account import Account
from solana.rpc.types import TxOpts
from solana.transaction import Transaction
from solana.system_program import SYS_PROGRAM_ID
from spl.token.client import Token
from spl.token.constants import TOKEN_PROGRAM_ID
import base64
import requests

# Optionally, import pyserum for orderbook/trade history
try:
    from pyserum.market import Market
    from pyserum.connection import conn
except ImportError:
    Market = None
    conn = None

# Raydium/Serum program IDs (mainnet)
RAYDIUM_AMM_PROGRAM_ID = "RVKd61ztZW9GdKzvKzF1i8LZRxur2Y2c1SU1bEoSxgU"
SERUM_DEX_PROGRAM_ID = "9xQeWvG816bUx9EPa4uRZbM7PpA6vGz5o1r5bQ6hJvQY"

def get_solana_client(rpc_url):
    return SolanaClient(rpc_url)

def get_token_balance(rpc_url, wallet_address, token_mint):
    client = get_solana_client(rpc_url)
    resp = client.get_token_accounts_by_owner(wallet_address, mint=token_mint)
    if not resp["result"]["value"]:
        return 0.0
    account_pubkey = resp["result"]["value"][0]["pubkey"]
    balance_resp = client.get_token_account_balance(account_pubkey)
    return float(balance_resp["result"]["value"]["uiAmount"])

def get_pool_reserves(rpc_url, pool_address):
    # Raydium pool reserves are stored in the pool account data
    # This requires parsing the account data layout (see Raydium docs)
    client = get_solana_client(rpc_url)
    resp = client.get_account_info(pool_address)
    if not resp["result"]["value"]:
        return (0.0, 0.0)
    data = base64.b64decode(resp["result"]["value"]["data"][0])
    # Raydium AMM pool layout: reserves at known offsets
    # For demonstration, use placeholder offsets (real offsets require Raydium layout)
    reserve0 = int.from_bytes(data[64:72], "little")
    reserve1 = int.from_bytes(data[72:80], "little")
    return (reserve0, reserve1)

def get_price_from_pool(rpc_url, pool_address):
    reserve0, reserve1 = get_pool_reserves(rpc_url, pool_address)
    if reserve0 == 0:
        return 0.0
    return reserve1 / reserve0

def get_pairs_from_raydium_api(limit=100):
    # Use Raydium's public API to fetch pool info
    url = "https://api.raydium.io/v2/main/pairs"
    resp = requests.get(url)
    pairs = []
    if resp.status_code == 200:
        data = resp.json()
        for i, pool in enumerate(data):
            if i >= limit:
                break
            pairs.append({
                "pool_address": pool["ammId"],
                "token0": {
                    "address": pool["baseMint"],
                    "symbol": pool["baseSymbol"],
                    "name": pool["name"].split("/")[0],
                    "decimals": int(pool["baseDecimals"])
                },
                "token1": {
                    "address": pool["quoteMint"],
                    "symbol": pool["quoteSymbol"],
                    "name": pool["name"].split("/")[1],
                    "decimals": int(pool["quoteDecimals"])
                },
                "fee": 0.0025,
                "protocol": "Raydium"
            })
    return pairs

def get_trade_history_from_serum(rpc_url, market_address, limit=100):
    if Market is None:
        raise ImportError("pyserum is not installed")
    connection = conn(rpc_url)
    market = Market.load(connection, PublicKey(market_address), PublicKey(SERUM_DEX_PROGRAM_ID))
    trades = []
    for event in market.load_fills(limit=limit):
        trades.append({
            "price": event.price,
            "size": event.size,
            "side": event.side,
            "order_id": str(event.order_id),
            "timestamp": event.timestamp
        })
    return trades

def get_token_metadata_from_registry(token_address):
    # Use Solana token registry or on-chain metadata
    url = f"https://raw.githubusercontent.com/solana-labs/token-list/main/src/tokens/solana.tokenlist.json"
    resp = requests.get(url)
    if resp.status_code == 200:
        data = resp.json()
        for token in data["tokens"]:
            if token["address"] == token_address:
                return {
                    "address": token["address"],
                    "symbol": token["symbol"],
                    "name": token["name"],
                    "decimals": int(token["decimals"])
                }
    return {
        "address": token_address,
        "symbol": "?",
        "name": "?",
        "decimals": 6
    }
