# packages/pythonWrapper/src/cutepanel_wrapper/adk_tools.py
# Contains tools compatible with Google Agent Development Kit (ADK)
# that leverage the CutePanelClient.

import asyncio
from typing import Dict, Any, Optional
from pydantic import BaseModel, Field

# Assuming CutePanelClient is accessible from the parent package
from .client import CutePanelClient, CutePanelAPIError

# Placeholder for ADK's Tool or FunctionCallable base class if it exists.
# If ADK tools are just functions with type hints, we can define them directly.
# For this example, we'll define functions and Pydantic models for their args.

class GetCutePanelAgentStatusADKArgs(BaseModel):
    """Arguments for the get_cutepanel_agent_status ADK tool."""
    agent_id: str = Field(description="The unique identifier of the CutePanel agent to query.")

async def get_cutepanel_agent_status_adk_tool(
    cutepanel_client: CutePanelClient, 
    agent_id: str
) -> Dict[str, Any]:
    """
    ADK-compatible tool function to get the status of a CutePanel agent.
    """
    try:
        agent_details = await cutepanel_client.agents.get(agent_id=agent_id)
        if agent_details and "id" in agent_details and "status" in agent_details:
            return {
                "tool_name": "get_cutepanel_agent_status",
                "status": "success",
                "agent_id": agent_details.get("id"),
                "agent_name": agent_details.get("name"),
                "agent_status": agent_details.get("status"),
                "agent_type": agent_details.get("type"),
                "details": agent_details 
            }
        else:
            return {
                "tool_name": "get_cutepanel_agent_status",
                "status": "error",
                "message": f"Could not retrieve valid status details for agent {agent_id}.",
                "response": agent_details
            }
    except CutePanelAPIError as e:
        if e.status_code == 404:
            return {"tool_name": "get_cutepanel_agent_status", "status": "error", "message": f"CutePanel Agent with ID '{agent_id}' not found."}
        return {"tool_name": "get_cutepanel_agent_status", "status": "error", "message": f"CutePanel API Error: {e.status_code} - {e.error_message}", "details": e.response_data}
    except Exception as e:
        return {"tool_name": "get_cutepanel_agent_status", "status": "error", "message": f"An unexpected error occurred: {str(e)}"}


class ExecuteCutePanelAgentTaskADKArgs(BaseModel):
    """Arguments for the execute_cutepanel_agent_task ADK tool."""
    agent_id: str = Field(description="The unique identifier of the CutePanel agent to target.")
    ability_name: str = Field(description="The name of the ability to execute on the CutePanel agent.")
    task_parameters: Optional[Dict[str, Any]] = Field(
        default=None, 
        description="Optional dictionary of parameters to pass to the agent's ability."
    )

async def execute_cutepanel_agent_task_adk_tool(
    cutepanel_client: CutePanelClient,
    agent_id: str,
    ability_name: str,
    task_parameters: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """
    ADK-compatible tool function to execute a task (ability) on a CutePanel agent.
    """
    try:
        task_payload = {
            "ability": ability_name,
            "parameters": task_parameters if task_parameters else {}
        }
        result = await cutepanel_client.agents.execute_task(
            agent_id=agent_id,
            task_payload=task_payload
        )
        if result.get("status") == "success":
            return {
                "tool_name": "execute_cutepanel_agent_task",
                "status": "success",
                "agent_id": agent_id,
                "ability_name": ability_name,
                "task_id": result.get("task_id"),
                "result": result.get("result", "No specific result content.")
            }
        else:
            return {
                "tool_name": "execute_cutepanel_agent_task",
                "status": "error",
                "message": f"Task execution on agent {agent_id} for ability {ability_name} failed.",
                "response": result
            }
    except CutePanelAPIError as e:
        return {"tool_name": "execute_cutepanel_agent_task", "status": "error", "message": f"CutePanel API Error executing task: {e.status_code} - {e.error_message}", "details": e.response_data}
    except Exception as e:
        return {"tool_name": "execute_cutepanel_agent_task", "status": "error", "message": f"An unexpected error occurred while executing agent task: {str(e)}"}


class GetCutePanelLatestPriceADKArgs(BaseModel):
    """Arguments for the get_cutepanel_latest_price ADK tool."""
    provider_name: str = Field(description="The name of the price feed provider (e.g., 'chainlink').")
    base_asset: str = Field(description="The base asset symbol (e.g., 'BTC').")
    quote_asset: str = Field(description="The quote asset symbol (e.g., 'USD').")

async def get_cutepanel_latest_price_adk_tool(
    cutepanel_client: CutePanelClient,
    provider_name: str,
    base_asset: str,
    quote_asset: str
) -> Dict[str, Any]:
    """
    ADK-compatible tool function to get the latest price of an asset pair from CutePanel.
    """
    try:
        result = await cutepanel_client.price_feed.get_latest_price(
            provider_name=provider_name,
            base_asset=base_asset,
            quote_asset=quote_asset
        )
        if result and "price" in result and "asset_pair" in result:
            return {
                "tool_name": "get_cutepanel_latest_price",
                "status": "success",
                "provider_name": provider_name,
                "asset_pair": result.get("asset_pair"),
                "price": result.get("price"),
                "timestamp": result.get("timestamp")
            }
        else:
            return {"tool_name": "get_cutepanel_latest_price", "status": "error", "message": f"Failed to get price for {base_asset}/{quote_asset} from {provider_name}.", "response": result}
    except CutePanelAPIError as e:
        return {"tool_name": "get_cutepanel_latest_price", "status": "error", "message": f"CutePanel API Error fetching price: {e.status_code} - {e.error_message}", "details": e.response_data}
    except Exception as e:
        return {"tool_name": "get_cutepanel_latest_price", "status": "error", "message": f"An unexpected error occurred while fetching price: {str(e)}"}


class ExecuteCutePanelDexSwapADKArgs(BaseModel):
    """Arguments for the execute_cutepanel_dex_swap ADK tool."""
    dex_name: str = Field(description="Name or ID of the DEX instance on CutePanel.")
    network: str = Field(description="The blockchain network the DEX operates on (e.g., 'ethereum', 'polygon').")
    token_in_address: str = Field(description="Contract address of the token to be swapped (input token).")
    token_out_address: str = Field(description="Contract address of the token to be received (output token).")
    amount_in: str = Field(description="Amount of input token to swap, in its smallest units (e.g., wei for ETH-like tokens).")
    slippage_tolerance: Optional[float] = Field(default=0.5, description="Maximum allowed slippage percentage (e.g., 0.5 for 0.5%). Defaults to 0.5%.")
    recipient_address: Optional[str] = Field(default=None, description="Optional address to receive the output tokens. If None, defaults to the sender/caller address configured in CutePanel.")
    deadline: Optional[int] = Field(default=None, description="Optional Unix timestamp (seconds since epoch) for the swap deadline.")

async def execute_cutepanel_dex_swap_adk_tool(
    cutepanel_client: CutePanelClient,
    dex_name: str,
    network: str,
    token_in_address: str,
    token_out_address: str,
    amount_in: str,
    slippage_tolerance: Optional[float] = 0.5,
    recipient_address: Optional[str] = None,
    deadline: Optional[int] = None
) -> Dict[str, Any]:
    """
    ADK-compatible tool function to execute a token swap on a specified DEX via CutePanel.
    """
    try:
        effective_slippage = slippage_tolerance if slippage_tolerance is not None else 0.5
        result = await cutepanel_client.dex.execute_swap(
            dex_name=dex_name,
            network=network,
            token_in_address=token_in_address,
            token_out_address=token_out_address,
            amount_in=amount_in,
            slippage_tolerance=effective_slippage,
            recipient_address=recipient_address,
            deadline=deadline
        )
        if result.get("status") == "success":
            return {
                "tool_name": "execute_cutepanel_dex_swap",
                "status": "success",
                "dex_name": dex_name,
                "network": network,
                "transaction_hash": result.get("transaction_hash"),
                "message": result.get("message", "Swap submitted successfully.")
            }
        else:
            return {"tool_name": "execute_cutepanel_dex_swap", "status": "error", "message": f"DEX swap execution failed on {dex_name} ({network}).", "response": result}
    except CutePanelAPIError as e:
        return {"tool_name": "execute_cutepanel_dex_swap", "status": "error", "message": f"CutePanel API Error during DEX swap: {e.status_code} - {e.error_message}", "details": e.response_data}
    except Exception as e:
        return {"tool_name": "execute_cutepanel_dex_swap", "status": "error", "message": f"An unexpected error occurred during DEX swap: {str(e)}"}


class AddCutePanelDexLiquidityADKArgs(BaseModel):
    """Arguments for the add_cutepanel_dex_liquidity ADK tool."""
    dex_name: str = Field(description="Name or ID of the DEX instance on CutePanel.")
    network: str = Field(description="The blockchain network the DEX operates on.")
    token_a_address: str = Field(description="Contract address of the first token in the pair.")
    token_b_address: str = Field(description="Contract address of the second token in the pair.")
    amount_a_desired: str = Field(description="Desired amount of token A to add (in smallest units).")
    amount_b_desired: str = Field(description="Desired amount of token B to add (in smallest units).")
    amount_a_min: str = Field(description="Minimum amount of token A to add, for slippage control (in smallest units).")
    amount_b_min: str = Field(description="Minimum amount of token B to add, for slippage control (in smallest units).")
    recipient_address: str = Field(description="Address to receive the LP tokens or liquidity NFT.")
    deadline: int = Field(description="Unix timestamp (seconds since epoch) for the transaction deadline.")
    tick_lower: Optional[int] = Field(default=None, description="For concentrated liquidity (e.g., Uniswap V3), the lower tick of the price range.")
    tick_upper: Optional[int] = Field(default=None, description="For concentrated liquidity (e.g., Uniswap V3), the upper tick of the price range.")

async def add_cutepanel_dex_liquidity_adk_tool(
    cutepanel_client: CutePanelClient,
    dex_name: str, network: str,
    token_a_address: str, token_b_address: str,
    amount_a_desired: str, amount_b_desired: str,
    amount_a_min: str, amount_b_min: str,
    recipient_address: str, deadline: int,
    tick_lower: Optional[int] = None, tick_upper: Optional[int] = None
) -> Dict[str, Any]:
    """
    ADK-compatible tool function to add liquidity to a DEX pool via CutePanel.
    """
    try:
        result = await cutepanel_client.dex.add_liquidity(
            dex_name=dex_name, network=network,
            token_a_address=token_a_address, token_b_address=token_b_address,
            amount_a_desired=amount_a_desired, amount_b_desired=amount_b_desired,
            amount_a_min=amount_a_min, amount_b_min=amount_b_min,
            recipient_address=recipient_address, deadline=deadline,
            tick_lower=tick_lower, tick_upper=tick_upper
        )
        if result.get("status") == "success":
            return {
                "tool_name": "add_cutepanel_dex_liquidity",
                "status": "success",
                "dex_name": dex_name,
                "network": network,
                "transaction_hash": result.get("transaction_hash"),
                "lp_amount": result.get("lp_amount"),
                "message": result.get("message", "Add liquidity transaction submitted successfully.")
            }
        else:
            return {"tool_name": "add_cutepanel_dex_liquidity", "status": "error", "message": f"Add liquidity failed on {dex_name} ({network}).", "response": result}
    except CutePanelAPIError as e:
        return {"tool_name": "add_cutepanel_dex_liquidity", "status": "error", "message": f"CutePanel API Error during add liquidity: {e.status_code} - {e.error_message}", "details": e.response_data}
    except Exception as e:
        return {"tool_name": "add_cutepanel_dex_liquidity", "status": "error", "message": f"An unexpected error occurred during add liquidity: {str(e)}"}


# --- Example of how these tools might be described for ADK ---
# ADK_TOOL_DESCRIPTIONS = [
#     {
#         "function_declarations": [
#             # ... (other tool descriptions)
#             {
#                 "name": "add_cutepanel_dex_liquidity_adk_tool",
#                 "description": "Adds liquidity to a specified DEX pool via CutePanel.",
#                 "parameters": AddCutePanelDexLiquidityADKArgs.schema()
#             }
#         ]
#     }
# ]

# --- Conceptual Test/Usage ---
async def _test_adk_tool():
    class MockAsyncADKAgentsClient:
        async def get(self, agent_id: str) -> Dict[str, Any]:
            print(f"MockAsyncADKAgentsClient.get called for agent_id: '{agent_id}'")
            await asyncio.sleep(0)
            if agent_id == "adk_agent_007":
                return {"id": "adk_agent_007", "name": "ADK Price Watcher", "type": "DATA_AGENT", "status": "RUNNING"}
            raise CutePanelAPIError(404, "Agent not found for ADK test", {"agent_id": agent_id})

        async def execute_task(self, agent_id: str, task_payload: Dict[str, Any]) -> Dict[str, Any]:
            print(f"MockAsyncADKAgentsClient.execute_task called for agent_id: '{agent_id}', payload: {task_payload}")
            await asyncio.sleep(0)
            if agent_id == "adk_agent_007" and task_payload.get("ability") == "fetch_price":
                return {"status": "success", "task_id": "task_123", "result": {"price": 68000.0, "asset": "BTC/USD"}}
            return {"status": "failure", "message": "Mocked task execution failure."}
    
    class MockAsyncADKPriceFeedClient:
        async def get_latest_price(self, provider_name: str, base_asset: str, quote_asset: str) -> Dict[str, Any]:
            print(f"MockAsyncADKPriceFeedClient.get_latest_price for {base_asset}/{quote_asset} via {provider_name}")
            await asyncio.sleep(0)
            if provider_name == "chainlink" and base_asset == "BTC" and quote_asset == "USD":
                return {"price": "69000.00", "asset_pair": "BTC/USD", "timestamp": "2025-05-11T19:00:00Z"}
            return {"error": "Mock price not available"}

    class MockAsyncADKDexClient: 
        async def execute_swap(self, **kwargs) -> Dict[str, Any]:
            print(f"MockAsyncADKDexClient.execute_swap called with: {kwargs}")
            await asyncio.sleep(0)
            if kwargs.get("token_in_address") == "0xINPUT_ADK" and kwargs.get("token_out_address") == "0xOUTPUT_ADK":
                return {"status": "success", "transaction_hash": "0xadk_swap_tx_hash_789", "message": "ADK Swap submitted successfully"}
            return {"status": "failure", "message": "ADK Swap failed due to insufficient liquidity (mocked)."}
        
        async def add_liquidity(self, **kwargs) -> Dict[str, Any]: # Added mock method
            print(f"MockAsyncADKDexClient.add_liquidity called with: {kwargs}")
            await asyncio.sleep(0)
            if kwargs.get("token_a_address") == "0xTOKENA_ADK" and kwargs.get("token_b_address") == "0xTOKENB_ADK":
                return {"status": "success", "transaction_hash": "0xadk_add_liq_tx_hash_123", "lp_amount": "1000000"}
            return {"status": "failure", "message": "ADK Add liquidity failed (mocked)."}


    class MockAsyncADKCutePanelClient:
        def __init__(self, base_url: str = ""):
            self.agents = MockAsyncADKAgentsClient()
            self.price_feed = MockAsyncADKPriceFeedClient()
            self.dex = MockAsyncADKDexClient() 
            print("MockAsyncADKCutePanelClient initialized.")
        async def __aenter__(self): return self
        async def __aexit__(self, exc_type, exc_val, exc_tb): pass
        async def close(self): pass

    mock_client = MockAsyncADKCutePanelClient()

    # ... (existing tests) ...
    print("\n--- Testing ADK Tool: get_cutepanel_agent_status_adk_tool ---")
    result1 = await get_cutepanel_agent_status_adk_tool(mock_client, "adk_agent_007")
    print("ADK Tool Result 1 (Agent Found):", result1)

    print("\n--- Testing ADK Tool: execute_cutepanel_agent_task_adk_tool ---")
    task_params = {"asset": "BTC/USD", "source": "Chainlink"}
    result3 = await execute_cutepanel_agent_task_adk_tool(mock_client, "adk_agent_007", "fetch_price", task_params)
    print("ADK Tool Result 3 (Task Success):", result3)

    print("\n--- Testing ADK Tool: get_cutepanel_latest_price_adk_tool ---")
    price_result_adk1 = await get_cutepanel_latest_price_adk_tool(mock_client, "chainlink", "BTC", "USD")
    print("ADK Price Tool Result 1 (Success):", price_result_adk1)

    print("\n--- Testing ADK Tool: execute_cutepanel_dex_swap_adk_tool ---")
    swap_result_adk1 = await execute_cutepanel_dex_swap_adk_tool(
        cutepanel_client=mock_client, dex_name="uniswap_adk", network="ethereum",
        token_in_address="0xINPUT_ADK", token_out_address="0xOUTPUT_ADK",
        amount_in="1000000000000000000" 
    )
    print("ADK Swap Tool Result 1 (Success):", swap_result_adk1)

    print("\n--- Testing ADK Tool: add_cutepanel_dex_liquidity_adk_tool ---")
    add_liq_adk1 = await add_cutepanel_dex_liquidity_adk_tool(
        cutepanel_client=mock_client, dex_name="sushiswap_adk", network="ethereum",
        token_a_address="0xTOKENA_ADK", token_b_address="0xTOKENB_ADK",
        amount_a_desired="1000000", amount_b_desired="500000000",
        amount_a_min="990000", amount_b_min="495000000",
        recipient_address="0xRECIPIENT_ADK", deadline=1700000000 + 3600
    )
    print("ADK Add Liquidity Result 1 (Success):", add_liq_adk1)

    add_liq_adk2 = await add_cutepanel_dex_liquidity_adk_tool(
        cutepanel_client=mock_client, dex_name="another_dex_adk", network="polygon",
        token_a_address="0xTOKENC_ADK", token_b_address="0xTOKEND_ADK",
        amount_a_desired="100", amount_b_desired="200",
        amount_a_min="90", amount_b_min="180",
        recipient_address="0xRECIPIENT_ADK", deadline=1700000000 + 3600
    )
    print("ADK Add Liquidity Result 2 (Failure):", add_liq_adk2)


if __name__ == "__main__":
    asyncio.run(_test_adk_tool())
