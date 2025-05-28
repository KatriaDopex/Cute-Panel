# packages/pythonWrapper/src/cutepanel_wrapper/langchain_tools.py

import asyncio # For running async methods from sync _run
from typing import Type, Optional, Dict, Any
from pydantic import BaseModel, Field

from langchain_core.tools import BaseTool

# Assuming CutePanelClient is accessible.
from cutepanel_wrapper.client import CutePanelClient, CutePanelAPIError


class CutePanelAgentTaskArgs(BaseModel):
    """Input arguments for the CutePanelAgentTaskExecutorTool."""
    agent_id: str = Field(description="The unique identifier of the CutePanel agent to target.")
    ability_name: str = Field(description="The name of the ability to execute on the CutePanel agent.")
    task_parameters: Optional[Dict[str, Any]] = Field(
        default=None, 
        description="Optional dictionary of parameters to pass to the agent's ability."
    )


class CutePanelAgentTaskExecutorTool(BaseTool):
    """
    A LangChain tool to execute a specific task (ability) on a CutePanel agent
    and get its result. Useful for letting LLM agents leverage specialized
    CutePanel agents for data retrieval, analysis, or action execution.
    """
    name: str = "cutepanel_agent_task_executor"
    description: str = (
        "Executes a specified task (ability) on a target CutePanel agent. "
        "Provide the agent_id, the ability_name to call, and any necessary task_parameters. "
        "Returns the result of the task execution from the CutePanel agent."
    )
    args_schema: Type[BaseModel] = CutePanelAgentTaskArgs
    cutepanel_client: CutePanelClient

    def _run(
        self, 
        agent_id: str, 
        ability_name: str, 
        task_parameters: Optional[Dict[str, Any]] = None,
        **kwargs: Any 
    ) -> str:
        """Use the tool synchronously."""
        try:
            return asyncio.run(self._arun(agent_id=agent_id, ability_name=ability_name, task_parameters=task_parameters, **kwargs))
        except RuntimeError as e:
            if "cannot be called from a running event loop" in str(e):
                return ("Error: Synchronous _run called from an async context. "
                        "Use the tool's async interface (e.g., `await tool.arun(...)`) in async code.")
            return f"A RuntimeError occurred in _run: {str(e)}"
        except Exception as e:
            return f"An unexpected error occurred in _run: {str(e)}"

    async def _arun(
        self, 
        agent_id: str, 
        ability_name: str, 
        task_parameters: Optional[Dict[str, Any]] = None,
        **kwargs: Any
    ) -> str:
        """Use the tool asynchronously."""
        try:
            task_payload = {
                "ability": ability_name,
                "parameters": task_parameters if task_parameters else {}
            }
            result = await self.cutepanel_client.agents.execute_task(
                agent_id=agent_id,
                task_payload=task_payload
            )
            if result.get("status") == "success":
                return f"Task executed successfully on agent {agent_id}. Result: {result.get('result', 'No specific result content.')}"
            else:
                return f"Task execution on agent {agent_id} failed. Response: {result}"
        except CutePanelAPIError as e:
            return f"CutePanel API Error (async): {e.status_code} - {e.error_message}. Details: {e.response_data}"
        except Exception as e:
            return f"An unexpected error occurred (async) while executing CutePanel agent task: {str(e)}"


class CutePanelGetLatestPriceArgs(BaseModel):
    """Input arguments for the CutePanelGetLatestPriceTool."""
    provider_name: str = Field(description="The name of the price feed provider (e.g., 'chainlink').")
    base_asset: str = Field(description="The base asset symbol (e.g., 'BTC').")
    quote_asset: str = Field(description="The quote asset symbol (e.g., 'USD').")


class CutePanelGetLatestPriceTool(BaseTool):
    """
    A LangChain tool to fetch the latest price of an asset pair from a specific
    price feed provider via the CutePanel backend.
    """
    name: str = "cutepanel_get_latest_price"
    description: str = (
        "Fetches the latest market price for a given asset pair (e.g., BTC/USD) "
        "from a specified price feed provider integrated with CutePanel. "
        "Provide the provider_name, base_asset symbol, and quote_asset symbol."
    )
    args_schema: Type[BaseModel] = CutePanelGetLatestPriceArgs
    cutepanel_client: CutePanelClient

    def _run(
        self,
        provider_name: str,
        base_asset: str,
        quote_asset: str,
        **kwargs: Any
    ) -> str:
        """Use the tool synchronously."""
        try:
            return asyncio.run(self._arun(provider_name=provider_name, base_asset=base_asset, quote_asset=quote_asset, **kwargs))
        except RuntimeError as e:
            if "cannot be called from a running event loop" in str(e):
                return ("Error: Synchronous _run called from an async context. "
                        "Use the tool's async interface (e.g., `await tool.arun(...)`) in async code.")
            return f"A RuntimeError occurred in _run: {str(e)}"
        except Exception as e: 
            return f"An unexpected error occurred in _run: {str(e)}"

    async def _arun(
        self,
        provider_name: str,
        base_asset: str,
        quote_asset: str,
        **kwargs: Any
    ) -> str:
        """Use the tool asynchronously."""
        try:
            result = await self.cutepanel_client.price_feed.get_latest_price(
                provider_name=provider_name,
                base_asset=base_asset,
                quote_asset=quote_asset
            )
            if result and "price" in result and "asset_pair" in result:
                return (f"Successfully fetched price for {result['asset_pair']} from {provider_name}. "
                        f"Price: {result['price']} {quote_asset} (as of {result.get('timestamp', 'N/A')}).")
            else:
                return f"Failed to get price for {base_asset}/{quote_asset} from {provider_name}. Response: {result}"
        except CutePanelAPIError as e:
            return f"CutePanel API Error fetching price (async): {e.status_code} - {e.error_message}. Details: {e.response_data}"
        except Exception as e:
            return f"An unexpected error occurred (async) while fetching price: {str(e)}"


class CutePanelGetAgentStatusArgs(BaseModel):
    """Input arguments for the CutePanelGetAgentStatusTool."""
    agent_id: str = Field(description="The unique identifier of the CutePanel agent to query.")


class CutePanelGetAgentStatusTool(BaseTool):
    """
    A LangChain tool to fetch the current status and details of a specific CutePanel agent.
    """
    name: str = "cutepanel_get_agent_status"
    description: str = (
        "Retrieves the current status and details (like name, type, tasks completed) "
        "for a specified CutePanel agent using its agent_id."
    )
    args_schema: Type[BaseModel] = CutePanelGetAgentStatusArgs
    cutepanel_client: CutePanelClient

    def _run(
        self,
        agent_id: str,
        **kwargs: Any
    ) -> str:
        """Use the tool synchronously."""
        try:
            return asyncio.run(self._arun(agent_id=agent_id, **kwargs))
        except RuntimeError as e:
            if "cannot be called from a running event loop" in str(e):
                return ("Error: Synchronous _run called from an async context. "
                        "Use the tool's async interface (e.g., `await tool.arun(...)`) in async code.")
            return f"A RuntimeError occurred in _run: {str(e)}"
        except Exception as e: 
            return f"An unexpected error occurred in _run: {str(e)}"

    async def _arun(
        self,
        agent_id: str,
        **kwargs: Any
    ) -> str:
        """Use the tool asynchronously."""
        try:
            agent_details = await self.cutepanel_client.agents.get(agent_id=agent_id)
            if agent_details and "id" in agent_details and "status" in agent_details:
                return (f"Status for CutePanel agent {agent_details.get('name', agent_id)} (ID: {agent_details['id']}): "
                        f"Status: {agent_details['status']}, Type: {agent_details.get('type', 'N/A')}. "
                        f"Full details: {agent_details}")
            else:
                return f"Could not retrieve valid status details for agent {agent_id}. Response: {agent_details}"
        except CutePanelAPIError as e:
            if e.status_code == 404:
                return f"CutePanel Agent with ID '{agent_id}' not found."
            return f"CutePanel API Error fetching agent status (async): {e.status_code} - {e.error_message}. Details: {e.response_data}"
        except Exception as e:
            return f"An unexpected error occurred (async) while fetching agent status: {str(e)}"


class CutePanelExecuteSwapArgs(BaseModel):
    """Input arguments for the CutePanelExecuteSwapTool."""
    dex_name: str = Field(description="Name or ID of the DEX instance on CutePanel.")
    network: str = Field(description="The blockchain network the DEX operates on (e.g., 'ethereum', 'polygon').")
    token_in_address: str = Field(description="Contract address of the token to be swapped (input token).")
    token_out_address: str = Field(description="Contract address of the token to be received (output token).")
    amount_in: str = Field(description="Amount of input token to swap, in its smallest units (e.g., wei for ETH-like tokens).")
    slippage_tolerance: Optional[float] = Field(
        default=0.5, 
        description="Maximum allowed slippage percentage (e.g., 0.5 for 0.5%). Defaults to 0.5%."
    )
    recipient_address: Optional[str] = Field(
        default=None, 
        description="Optional address to receive the output tokens. If None, defaults to the sender/caller address configured in CutePanel."
    )
    deadline: Optional[int] = Field(
        default=None, 
        description="Optional Unix timestamp (seconds since epoch) for the swap deadline."
    )

class CutePanelExecuteSwapTool(BaseTool):
    """
    A LangChain tool to execute a token swap on a specified DEX via the CutePanel backend.
    """
    name: str = "cutepanel_execute_dex_swap"
    description: str = (
        "Executes a token swap on a specified Decentralized Exchange (DEX). "
        "You need to provide the DEX name (as configured in CutePanel), the network, "
        "input token address, output token address, and the amount of input token (in smallest units). "
        "Optional parameters include slippage_tolerance (defaults to 0.5%), recipient_address, and deadline."
    )
    args_schema: Type[BaseModel] = CutePanelExecuteSwapArgs
    cutepanel_client: CutePanelClient

    def _run(
        self,
        dex_name: str,
        network: str,
        token_in_address: str,
        token_out_address: str,
        amount_in: str,
        slippage_tolerance: Optional[float] = 0.5,
        recipient_address: Optional[str] = None,
        deadline: Optional[int] = None,
        **kwargs: Any
    ) -> str:
        """Use the tool synchronously."""
        try:
            return asyncio.run(self._arun(
                dex_name=dex_name, network=network, 
                token_in_address=token_in_address, token_out_address=token_out_address,
                amount_in=amount_in, slippage_tolerance=slippage_tolerance,
                recipient_address=recipient_address, deadline=deadline, **kwargs
            ))
        except RuntimeError as e:
            if "cannot be called from a running event loop" in str(e):
                return ("Error: Synchronous _run called from an async context. "
                        "Use the tool's async interface (e.g., `await tool.arun(...)`) in async code.")
            return f"A RuntimeError occurred in _run: {str(e)}"
        except Exception as e: 
            return f"An unexpected error occurred in _run: {str(e)}"

    async def _arun(
        self,
        dex_name: str,
        network: str,
        token_in_address: str,
        token_out_address: str,
        amount_in: str,
        slippage_tolerance: Optional[float] = 0.5,
        recipient_address: Optional[str] = None,
        deadline: Optional[int] = None,
        **kwargs: Any
    ) -> str:
        """Use the tool asynchronously."""
        try:
            effective_slippage = slippage_tolerance if slippage_tolerance is not None else 0.5
            result = await self.cutepanel_client.dex.execute_swap(
                dex_name=dex_name, network=network,
                token_in_address=token_in_address, token_out_address=token_out_address,
                amount_in=amount_in, slippage_tolerance=effective_slippage,
                recipient_address=recipient_address, deadline=deadline
            )
            if result.get("status") == "success":
                return (f"DEX swap initiated successfully on {dex_name} ({network}). "
                        f"Transaction Hash: {result.get('transaction_hash', 'N/A')}. "
                        f"Message: {result.get('message', '')}")
            else:
                return f"DEX swap execution failed on {dex_name} ({network}). Response: {result}"
        except CutePanelAPIError as e:
            return f"CutePanel API Error during DEX swap (async): {e.status_code} - {e.error_message}. Details: {e.response_data}"
        except Exception as e:
            return f"An unexpected error occurred (async) during DEX swap: {str(e)}"


class CutePanelAddLiquidityArgs(BaseModel):
    """Input arguments for the CutePanelAddLiquidityTool."""
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


class CutePanelAddLiquidityTool(BaseTool):
    """
    A LangChain tool to add liquidity to a DEX pool via the CutePanel backend.
    Supports both standard and concentrated liquidity pools.
    """
    name: str = "cutepanel_add_dex_liquidity"
    description: str = (
        "Adds liquidity to a specified Decentralized Exchange (DEX) pool. "
        "Provide DEX details, token pair addresses, desired and minimum amounts, recipient, and deadline. "
        "For concentrated liquidity pools (like Uniswap V3), also provide tick_lower and tick_upper."
    )
    args_schema: Type[BaseModel] = CutePanelAddLiquidityArgs
    cutepanel_client: CutePanelClient

    def _run(
        self,
        dex_name: str, network: str,
        token_a_address: str, token_b_address: str,
        amount_a_desired: str, amount_b_desired: str,
        amount_a_min: str, amount_b_min: str,
        recipient_address: str, deadline: int,
        tick_lower: Optional[int] = None, tick_upper: Optional[int] = None,
        **kwargs: Any
    ) -> str:
        """Use the tool synchronously."""
        try:
            return asyncio.run(self._arun(
                dex_name=dex_name, network=network,
                token_a_address=token_a_address, token_b_address=token_b_address,
                amount_a_desired=amount_a_desired, amount_b_desired=amount_b_desired,
                amount_a_min=amount_a_min, amount_b_min=amount_b_min,
                recipient_address=recipient_address, deadline=deadline,
                tick_lower=tick_lower, tick_upper=tick_upper, **kwargs
            ))
        except RuntimeError as e:
            if "cannot be called from a running event loop" in str(e):
                return ("Error: Synchronous _run called from an async context. "
                        "Use the tool's async interface (e.g., `await tool.arun(...)`) in async code.")
            return f"A RuntimeError occurred in _run: {str(e)}"
        except Exception as e: 
            return f"An unexpected error occurred in _run: {str(e)}"

    async def _arun(
        self,
        dex_name: str, network: str,
        token_a_address: str, token_b_address: str,
        amount_a_desired: str, amount_b_desired: str,
        amount_a_min: str, amount_b_min: str,
        recipient_address: str, deadline: int,
        tick_lower: Optional[int] = None, tick_upper: Optional[int] = None,
        **kwargs: Any
    ) -> str:
        """Use the tool asynchronously."""
        try:
            result = await self.cutepanel_client.dex.add_liquidity(
                dex_name=dex_name, network=network,
                token_a_address=token_a_address, token_b_address=token_b_address,
                amount_a_desired=amount_a_desired, amount_b_desired=amount_b_desired,
                amount_a_min=amount_a_min, amount_b_min=amount_b_min,
                recipient_address=recipient_address, deadline=deadline,
                tick_lower=tick_lower, tick_upper=tick_upper
            )
            if result.get("status") == "success":
                return (f"Add liquidity transaction initiated successfully on {dex_name} ({network}). "
                        f"Transaction Hash: {result.get('transaction_hash', 'N/A')}. "
                        f"Message: {result.get('message', '')}")
            else:
                return f"Add liquidity failed on {dex_name} ({network}). Response: {result}"
        except CutePanelAPIError as e:
            return f"CutePanel API Error during add liquidity (async): {e.status_code} - {e.error_message}. Details: {e.response_data}"
        except Exception as e:
            return f"An unexpected error occurred (async) during add liquidity: {str(e)}"


async def _test_main(): 
    class MockAsyncAgentsClient:
        async def execute_task(self, agent_id: str, task_payload: Dict[str, Any]) -> Dict[str, Any]:
            print(f"MockAsyncAgentsClient.execute_task called with: agent_id='{agent_id}', payload='{task_payload}'")
            await asyncio.sleep(0)
            if agent_id == "test_agent_123" and task_payload.get("ability") == "get_weather":
                return {"status": "success", "result": {"temperature": "25C", "condition": "Sunny"}}
            elif task_payload.get("ability") == "error_ability":
                raise CutePanelAPIError(500, "Simulated server error", {"detail": "Something went wrong"})
            return {"status": "failure", "message": "Unknown agent or ability"}

        async def get(self, agent_id: str) -> Dict[str, Any]: 
            print(f"MockAsyncAgentsClient.get called for agent_id: '{agent_id}'")
            await asyncio.sleep(0)
            if agent_id == "test_agent_123":
                return {"id": "test_agent_123", "name": "Weather Reporter", "type": "DATA_AGENT", "status": "RUNNING", "tasks_completed": 10}
            elif agent_id == "test_agent_stopped":
                return {"id": "test_agent_stopped", "name": "Idle Trader", "type": "TRADING_AGENT", "status": "STOPPED"}
            else:
                raise CutePanelAPIError(404, "Agent not found", {"agent_id": agent_id})

    class MockAsyncPriceFeedClient: 
        async def get_latest_price(self, provider_name: str, base_asset: str, quote_asset: str) -> Dict[str, Any]:
            print(f"MockAsyncPriceFeedClient.get_latest_price called for {base_asset}/{quote_asset} via {provider_name}")
            await asyncio.sleep(0)
            if provider_name == "chainlink" and base_asset == "BTC" and quote_asset == "USD":
                return {"price": "65000.00", "asset_pair": "BTC/USD", "timestamp": "2024-05-11T12:00:00Z"}
            elif base_asset == "ETH" and quote_asset == "USD":
                 raise CutePanelAPIError(404, "Price feed not found for ETH/USD on chainlink_mock", {"provider": provider_name})
            return {"error": "Price not available"}

    class MockAsyncDexClient: 
        async def execute_swap(self, **kwargs) -> Dict[str, Any]:
            print(f"MockAsyncDexClient.execute_swap called with: {kwargs}")
            await asyncio.sleep(0)
            if kwargs.get("token_in_address") == "0xINPUT" and kwargs.get("token_out_address") == "0xOUTPUT":
                return {"status": "success", "transaction_hash": "0xswap_tx_hash_123", "message": "Swap submitted successfully"}
            return {"status": "failure", "message": "Swap failed due to insufficient liquidity (mocked)."}
        
        async def add_liquidity(self, **kwargs) -> Dict[str, Any]: # Added mock method
            print(f"MockAsyncDexClient.add_liquidity called with: {kwargs}")
            await asyncio.sleep(0)
            if kwargs.get("token_a_address") == "0xTOKENA" and kwargs.get("token_b_address") == "0xTOKENB":
                return {"status": "success", "transaction_hash": "0xadd_liq_tx_hash_456", "lp_amount": "1000000"}
            return {"status": "failure", "message": "Add liquidity failed (mocked)."}


    class MockAsyncCutePanelClient: 
        def __init__(self, base_url: str = ""):
            self.agents = MockAsyncAgentsClient()
            self.price_feed = MockAsyncPriceFeedClient()
            self.dex = MockAsyncDexClient() 
            print("MockAsyncCutePanelClient initialized.")
        
        async def __aenter__(self): return self
        async def __aexit__(self, exc_type, exc_val, exc_tb): pass
        async def close(self): pass 

    mock_async_client = MockAsyncCutePanelClient()
    
    # ... (existing test cases for other tools) ...

    print("\n--- Test Case 1 (Agent Task): Successful Execution ---")
    agent_task_tool = CutePanelAgentTaskExecutorTool(cutepanel_client=mock_async_client)
    result1 = agent_task_tool.invoke({ 
        "agent_id": "test_agent_123",
        "ability_name": "get_weather",
        "task_parameters": {"city": "San Francisco"}
    })
    print("Result 1:", result1)

    price_tool = CutePanelGetLatestPriceTool(cutepanel_client=mock_async_client)
    print("\n--- Test Case 4 (Price Tool): Successful Price Fetch ---")
    price_result1 = price_tool.invoke({
        "provider_name": "chainlink",
        "base_asset": "BTC",
        "quote_asset": "USD"
    })
    print("Price Result 1:", price_result1)

    agent_status_tool = CutePanelGetAgentStatusTool(cutepanel_client=mock_async_client)
    print("\n--- Test Case 7 (Agent Status Tool): Agent Found (Running) ---")
    status_result1 = agent_status_tool.invoke({"agent_id": "test_agent_123"})
    print("Status Result 1:", status_result1)
    
    swap_tool = CutePanelExecuteSwapTool(cutepanel_client=mock_async_client)
    print("\n--- Test Case 10 (Swap Tool): Successful Swap ---")
    swap_result1 = swap_tool.invoke({
        "dex_name": "uniswapv3",
        "network": "ethereum",
        "token_in_address": "0xINPUT",
        "token_out_address": "0xOUTPUT",
        "amount_in": "1000000000000000000" 
    })
    print("Swap Result 1:", swap_result1)

    # Test CutePanelAddLiquidityTool
    add_liquidity_tool = CutePanelAddLiquidityTool(cutepanel_client=mock_async_client)
    print(f"\nTool Name: {add_liquidity_tool.name}")
    print(f"Tool Description: {add_liquidity_tool.description}")
    print(f"Tool Args Schema: {add_liquidity_tool.args_schema.schema_json(indent=2)}")

    print("\n--- Test Case 12 (Add Liquidity Tool): Successful Add Liquidity ---")
    add_liq_result1 = add_liquidity_tool.invoke({
        "dex_name": "sushiswap",
        "network": "ethereum",
        "token_a_address": "0xTOKENA",
        "token_b_address": "0xTOKENB",
        "amount_a_desired": "1000000", # 1 TokenA (6 decimals)
        "amount_b_desired": "500000000000000000", # 0.5 TokenB (18 decimals)
        "amount_a_min": "990000",
        "amount_b_min": "495000000000000000",
        "recipient_address": "0xRECIPIENT",
        "deadline": 1700000000 
    })
    print("Add Liquidity Result 1:", add_liq_result1)
    # Expected: "Add liquidity transaction initiated successfully on sushiswap (ethereum). Transaction Hash: 0xadd_liq_tx_hash_456. Message: "

    print("\n--- Test Case 13 (Add Liquidity Tool): Failed Add Liquidity ---")
    add_liq_result2 = add_liquidity_tool.invoke({
        "dex_name": "anotherdex",
        "network": "polygon",
        "token_a_address": "0xTOKENC",
        "token_b_address": "0xTOKEND",
        "amount_a_desired": "100",
        "amount_b_desired": "200",
        "amount_a_min": "90",
        "amount_b_min": "180",
        "recipient_address": "0xRECIPIENT",
        "deadline": 1700000000
    })
    print("Add Liquidity Result 2:", add_liq_result2)
    # Expected: "Add liquidity failed on anotherdex (polygon). Response: {'status': 'failure', 'message': 'Add liquidity failed (mocked).'}"


if __name__ == '__main__':
    asyncio.run(_test_main())
