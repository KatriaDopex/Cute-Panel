# packages/pythonWrapper/src/cutepanel_wrapper/client.py

import httpx
import json
import asyncio # Added for async operations
from typing import Optional, Dict, Any, List

# Define a custom exception for API errors
class CutePanelAPIError(Exception):
    """
    Custom exception raised for errors encountered while interacting with the CutePanel API.

    Attributes:
        status_code (int): The HTTP status code of the error response.
        error_message (str): A descriptive message for the error.
        response_data (Optional[Dict]): The JSON response body from the API, if available,
                                         containing further error details.
    """
    def __init__(self, status_code: int, error_message: str, response_data: Optional[Dict[str, Any]] = None):
        self.status_code = status_code
        self.error_message = error_message
        self.response_data = response_data
        super().__init__(f"CutePanel API Error {status_code}: {error_message} {response_data if response_data else ''}")

class CutePanelClient:
    """
    Asynchronous client for interacting with the CutePanel backend API.

    This client provides methods to interact with various modules of CutePanel,
    such as Agents, Swarms, Blockchain, DEX, Trading, etc. All interaction
    methods are asynchronous and should be awaited.

    It is recommended to use the client as an async context manager:
    ```python
    async with CutePanelClient(base_url="...") as client:
        status = await client.get_status()
    ```

    Attributes:
        agents (AgentsClient): Client for agent-related operations.
        swarms (SwarmsClient): Client for swarm-related operations.
        blockchain (BlockchainClient): Client for blockchain interactions.
        dex (DexClient): Client for DEX operations.
        price_feed (PriceFeedClient): Client for price feed data.
        trading (TradingClient): Client for trading and portfolio management.
        storage (StorageClient): Client for storage operations.
        llm (LLMClient): Client for LLM interactions via CutePanel.
        cross_chain (CrossChainClient): Client for cross-chain functionalities.
    """
    def __init__(self, base_url: str = "http://localhost:8080/api/v1", timeout: float = 30.0):
        """
        Initializes the asynchronous CutePanelClient.

        Args:
            base_url (str): The base URL of the CutePanel backend API.
                            Defaults to "http://localhost:8080/api/v1".
            timeout (float): Default timeout for HTTP requests in seconds.
                             Defaults to 30.0.
        """
        if not base_url.endswith('/'):
            base_url += '/'
        self.base_url = base_url
        self.timeout = timeout
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=self.timeout)
        
        self.agents = AgentsClient(self)
        self.swarms = SwarmsClient(self)
        self.blockchain = BlockchainClient(self)
        self.dex = DexClient(self)
        self.price_feed = PriceFeedClient(self)
        self.trading = TradingClient(self)
        self.storage = StorageClient(self)
        self.llm = LLMClient(self)
        self.cross_chain = CrossChainClient(self)
        # print(f"CutePanelClient initialized for API endpoint: {self.base_url}") # Can be un-commented for debugging

    async def _request(self, method: str, endpoint: str, params: Optional[Dict[str, Any]] = None, data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Internal helper method to make asynchronous HTTP requests to the CutePanel API.

        This method handles request construction, execution, and basic error handling,
        including raising `CutePanelAPIError` for non-2xx responses or other issues.

        Args:
            method (str): HTTP method (e.g., "GET", "POST", "PUT", "DELETE").
            endpoint (str): API endpoint path relative to the base_url (e.g., "agents/create").
            params (Optional[Dict[str, Any]]): URL query parameters.
            data (Optional[Dict[str, Any]]): JSON request body for POST/PUT requests.

        Returns:
            Dict[str, Any]: The JSON response from the API as a dictionary.
                            Returns an empty dictionary if the response content is empty.

        Raises:
            CutePanelAPIError: If the API returns an error status code, if the request fails
                             due to network issues, or if the response cannot be decoded as JSON.
        """
        try:
            response = await self._client.request(method, endpoint, params=params, json=data)
            response.raise_for_status()  # Raises httpx.HTTPStatusError for 4xx/5xx responses
            if not response.content:
                return {}
            return response.json()
        except httpx.HTTPStatusError as e:
            error_message = f"HTTP error occurred: {e.response.status_code} - {e.response.reason_phrase}"
            response_data = None
            try:
                response_data = e.response.json()
                if "error" in response_data: error_message = response_data["error"]
                elif "message" in response_data: error_message = response_data["message"]
            except json.JSONDecodeError:
                error_message += f" (Non-JSON error response: {e.response.text[:100]})"
            raise CutePanelAPIError(status_code=e.response.status_code, error_message=error_message, response_data=response_data) from e
        except httpx.RequestError as e:
            raise CutePanelAPIError(status_code=503, error_message=f"Request failed: {e.__class__.__name__} - {str(e)}") from e
        except json.JSONDecodeError as e:
            raise CutePanelAPIError(status_code=500, error_message=f"Failed to decode JSON response from API: {str(e)}", response_data={"raw_response": response.text if response else "No response"}) from e

    async def get_status(self) -> Dict[str, Any]:
        """
        Asynchronously gets the overall status of the CutePanel backend.

        Assumes the backend provides a status endpoint (e.g., "/status").

        Returns:
            Dict[str, Any]: A dictionary containing status information from the backend.
                            Example: `{"status": "OK", "version": "0.1.0"}`

        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._request("GET", "status")

    async def close(self):
        """
        Asynchronously closes the underlying HTTP client session.

        It's recommended to use the client as an async context manager (`async with`)
        to ensure the session is closed automatically.
        """
        await self._client.aclose()
        # print("CutePanelClient session closed.") # Can be un-commented for debugging

    async def __aenter__(self) -> "CutePanelClient":
        """Enter the async context manager."""
        return self

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any):
        """Exit the async context manager, ensuring the client is closed."""
        await self.close()

class AgentsClient:
    """
    Asynchronous client for managing and interacting with CutePanel Agents.

    Provides methods for creating, listing, starting, stopping, and otherwise
    managing agents, as well as executing tasks on them.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the AgentsClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def create(self, config: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously creates a new agent in CutePanel.

        Args:
            config (Dict[str, Any]): A dictionary containing the agent's configuration,
                                     such as name, type, parameters, and abilities.
                                     Example: `{"name": "MyAgent", "type": "SimpleAgent", ...}`

        Returns:
            Dict[str, Any]: The response from the API, typically including the new agent's ID
                            and status. Example: `{"agent_id": "xyz123", "status": "CREATED"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", "agents/create", data=config)

    async def list(self, agent_type: Optional[str] = None, status: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously lists agents, optionally filtered by type or status.

        Args:
            agent_type (Optional[str]): Filter agents by their type (e.g., "DataCollectionAgent").
            status (Optional[str]): Filter agents by their status (e.g., "RUNNING", "STOPPED").

        Returns:
            List[Dict[str, Any]]: A list of dictionaries, where each dictionary represents an agent.
                                  Example: `[{"agent_id": "xyz123", "name": "MyAgent", ...}]`
                                  Returns an empty list if no agents match or an error occurs.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if agent_type: params["type"] = agent_type
        if status: params["status"] = status
        response = await self._main_client._request("GET", "agents", params=params)
        return response.get("agents", [])

    async def get(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves details for a specific agent.

        Args:
            agent_id (str): The unique identifier of the agent.

        Returns:
            Dict[str, Any]: A dictionary containing the agent's details.
                            Example: `{"agent_id": "xyz123", "name": "MyAgent", "status": "RUNNING", ...}`
        
        Raises:
            CutePanelAPIError: If the agent is not found or the API request fails.
        """
        return await self._main_client._request("GET", f"agents/{agent_id}")

    async def start(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously starts a specific agent.

        Args:
            agent_id (str): The unique identifier of the agent to start.

        Returns:
            Dict[str, Any]: Response from the API, typically confirming the start action.
                            Example: `{"agent_id": "xyz123", "status": "STARTING"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/start")

    async def stop(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously stops a specific agent.

        Args:
            agent_id (str): The unique identifier of the agent to stop.

        Returns:
            Dict[str, Any]: Response from the API, typically confirming the stop action.
                            Example: `{"agent_id": "xyz123", "status": "STOPPING"}`

        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/stop")

    async def pause(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously pauses a specific agent. (If supported by the agent type)

        Args:
            agent_id (str): The unique identifier of the agent to pause.

        Returns:
            Dict[str, Any]: Response from the API, typically confirming the pause action.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/pause")

    async def resume(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously resumes a specific paused agent. (If supported)

        Args:
            agent_id (str): The unique identifier of the agent to resume.

        Returns:
            Dict[str, Any]: Response from the API, typically confirming the resume action.

        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/resume")
        
    async def delete(self, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously deletes a specific agent.

        Args:
            agent_id (str): The unique identifier of the agent to delete.

        Returns:
            Dict[str, Any]: Response from the API, typically confirming the deletion.
                            Example: `{"agent_id": "xyz123", "status": "DELETED"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("DELETE", f"agents/{agent_id}")

    async def execute_task(self, agent_id: str, task_payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously executes a task on a specific agent.

        The `task_payload` should typically include an "ability" name and any "parameters"
        required by that ability.

        Args:
            agent_id (str): The unique identifier of the agent.
            task_payload (Dict[str, Any]): A dictionary defining the task.
                                           Example: `{"ability": "get_weather", "parameters": {"city": "London"}}`

        Returns:
            Dict[str, Any]: Response from the API, which might include a task ID for tracking
                            and an initial status or direct result.
                            Example: `{"task_id": "task789", "status": "PENDING"}` or `{"result": ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/execute_task", data=task_payload)
    
    async def get_task_status(self, agent_id: str, task_id: str) -> Dict[str, Any]:
        """
        Asynchronously gets the status of a specific task for an agent.

        Args:
            agent_id (str): The unique identifier of the agent.
            task_id (str): The unique identifier of the task.

        Returns:
            Dict[str, Any]: A dictionary containing the task's status.
                            Example: `{"task_id": "task789", "status": "COMPLETED", ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"agents/{agent_id}/tasks/{task_id}/status")

    async def get_task_result(self, agent_id: str, task_id: str) -> Dict[str, Any]:
        """
        Asynchronously gets the result of a completed or failed task for an agent.

        Args:
            agent_id (str): The unique identifier of the agent.
            task_id (str): The unique identifier of the task.

        Returns:
            Dict[str, Any]: A dictionary containing the task's result.
                            Example: `{"task_id": "task789", "status": "COMPLETED", "result": ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails or the task is not yet complete.
        """
        return await self._main_client._request("GET", f"agents/{agent_id}/tasks/{task_id}/result")

    async def list_agent_tasks(self, agent_id: str, status_filter: Optional[str] = None, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Lists tasks associated with a specific agent.
        Args:
            agent_id (str): The ID of the agent.
            status_filter (Optional[str]): Filter tasks by status (e.g., "PENDING", "RUNNING", "COMPLETED").
            limit (Optional[int]): Limit the number of tasks returned.
        Returns:
            List[Dict[str, Any]]: A list of tasks.
        """
        params: Dict[str, Any] = {}
        if status_filter: params["status"] = status_filter
        if limit: params["limit"] = limit
        response = await self._main_client._request("GET", f"agents/{agent_id}/tasks", params=params)
        return response.get("tasks", [])

    async def cancel_agent_task(self, agent_id: str, task_id: str) -> Dict[str, Any]:
        """
        Attempts to cancel a pending or running task for an agent.
        Args:
            agent_id (str): The ID of the agent.
            task_id (str): The ID of the task to cancel.
        Returns:
            Dict[str, Any]: Confirmation of the cancellation attempt.
        """
        return await self._main_client._request("POST", f"agents/{agent_id}/tasks/{task_id}/cancel")

class SwarmsClient:
    """
    Asynchronous client for managing and interacting with CutePanel Swarms.

    Provides methods for creating, listing, controlling, and inspecting swarms
    of agents working collaboratively on optimization or other tasks.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the SwarmsClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def create(self, config: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously creates a new swarm in CutePanel.

        Args:
            config (Dict[str, Any]): Configuration for the swarm, including its type,
                                     objective function, algorithm, member agents, etc.
                                     Example: `{"name": "MyOptimizerSwarm", "algorithm": "PSO", ...}`

        Returns:
            Dict[str, Any]: Response from the API, typically including the new swarm's ID.
                            Example: `{"swarm_id": "swarm456", "status": "INITIALIZED"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", "swarms/create", data=config)

    async def list(self, status: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously lists swarms, optionally filtered by status.

        Args:
            status (Optional[str]): Filter swarms by their status (e.g., "RUNNING", "COMPLETED").

        Returns:
            List[Dict[str, Any]]: A list of dictionaries, each representing a swarm.
                                  Example: `[{"swarm_id": "swarm456", "name": "MyOptimizerSwarm", ...}]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if status: params["status"] = status
        response = await self._main_client._request("GET", "swarms", params=params)
        return response.get("swarms", [])

    async def get(self, swarm_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves details for a specific swarm.

        Args:
            swarm_id (str): The unique identifier of the swarm.

        Returns:
            Dict[str, Any]: A dictionary containing the swarm's details.
        
        Raises:
            CutePanelAPIError: If the swarm is not found or the API request fails.
        """
        return await self._main_client._request("GET", f"swarms/{swarm_id}")

    async def start(self, swarm_id: str) -> Dict[str, Any]:
        """
        Asynchronously starts a specific swarm's execution.

        Args:
            swarm_id (str): The unique identifier of the swarm to start.

        Returns:
            Dict[str, Any]: Response from the API, confirming the start action.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"swarms/{swarm_id}/start")

    async def stop(self, swarm_id: str) -> Dict[str, Any]:
        """
        Asynchronously stops a specific swarm's execution.

        Args:
            swarm_id (str): The unique identifier of the swarm to stop.

        Returns:
            Dict[str, Any]: Response from the API, confirming the stop action.

        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"swarms/{swarm_id}/stop")
        
    async def delete(self, swarm_id: str) -> Dict[str, Any]:
        """
        Asynchronously deletes a specific swarm.

        Args:
            swarm_id (str): The unique identifier of the swarm to delete.

        Returns:
            Dict[str, Any]: Response from the API, confirming the deletion.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("DELETE", f"swarms/{swarm_id}")

    async def add_agent(self, swarm_id: str, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously adds an existing agent to a specific swarm.

        Args:
            swarm_id (str): The unique identifier of the swarm.
            agent_id (str): The unique identifier of the agent to add.

        Returns:
            Dict[str, Any]: Response from the API, confirming the addition.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"swarms/{swarm_id}/agents/add", data={"agent_id": agent_id})

    async def remove_agent(self, swarm_id: str, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously removes an agent from a specific swarm.

        Args:
            swarm_id (str): The unique identifier of the swarm.
            agent_id (str): The unique identifier of the agent to remove.

        Returns:
            Dict[str, Any]: Response from the API, confirming the removal.

        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"swarms/{swarm_id}/agents/remove", data={"agent_id": agent_id})

    async def get_best_solution(self, swarm_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves the best solution found by a swarm so far.

        Args:
            swarm_id (str): The unique identifier of the swarm.

        Returns:
            Dict[str, Any]: A dictionary representing the best solution and its fitness/details.
                            Example: `{"solution": {...}, "fitness": 0.95, ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"swarms/{swarm_id}/solution")

    async def get_swarm_agent_details(self, swarm_id: str, agent_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves details of a specific agent participating in a swarm.
        This might include its current particle/solution, fitness, or other swarm-specific state.

        Args:
            swarm_id (str): The unique identifier of the swarm.
            agent_id (str): The unique identifier of the agent within the swarm.

        Returns:
            Dict[str, Any]: Detailed information about the agent's state within the swarm.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"swarms/{swarm_id}/agents/{agent_id}")

    async def update_swarm_parameters(self, swarm_id: str, parameters: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously updates parameters of a configured or running swarm.
        This could be used to dynamically tune algorithm parameters, termination criteria, etc.

        Args:
            swarm_id (str): The unique identifier of the swarm.
            parameters (Dict[str, Any]): A dictionary of parameters to update.

        Returns:
            Dict[str, Any]: Response from the API, confirming the parameter update.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"swarms/{swarm_id}/parameters", data=parameters)

    async def get_iteration_history(self, swarm_id: str, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously retrieves the iteration history of a swarm's execution.
        This might include metrics like best fitness per iteration.

        Args:
            swarm_id (str): The unique identifier of the swarm.
            limit (Optional[int]): Limit the number of history records returned.

        Returns:
            List[Dict[str, Any]]: A list of dictionaries, each representing an iteration's state or metrics.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if limit: params["limit"] = limit
        response = await self._main_client._request("GET", f"swarms/{swarm_id}/history", params=params)
        return response.get("history", [])

class BlockchainClient:
    """
    Asynchronous client for interacting with blockchain functionalities via CutePanel.

    Provides methods for connecting to networks, querying balances, transaction details,
    gas prices, and sending raw transactions.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the BlockchainClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def connect(self, network: str) -> Dict[str, Any]:
        """
        Asynchronously establishes and tests a connection to a specified blockchain network.

        Args:
            network (str): Name of the network (e.g., "ethereum", "polygon", "bsc").

        Returns:
            Dict[str, Any]: Connection status details from the API.
                            Example: `{"status": "connected", "network_id": 1, "client_version": "..."}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", "blockchain/connect", data={"network": network})

    async def get_balance(self, network: str, address: str) -> Dict[str, Any]:
        """
        Asynchronously gets the native asset balance for an address on a specific network.

        Args:
            network (str): Name of the network.
            address (str): Wallet address to query.

        Returns:
            Dict[str, Any]: Balance information.
                            Example: `{"address": "0x...", "balance": "1.2345", "unit": "ETH"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/balance/{address}")

    async def get_token_balance(self, network: str, wallet_address: str, token_contract_address: str) -> Dict[str, Any]:
        """
        Asynchronously gets the ERC20 (or equivalent) token balance for an address.

        Args:
            network (str): Name of the network.
            wallet_address (str): Wallet address to query.
            token_contract_address (str): Contract address of the token.

        Returns:
            Dict[str, Any]: Token balance information.
                            Example: `{"wallet_address": "0x...", "token_address": "0x...", "balance": "100.0", "symbol": "USDC", "decimals": 6}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/tokens/{token_contract_address}/balance/{wallet_address}")

    async def get_transaction_receipt(self, network: str, tx_hash: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves the receipt for a given transaction hash.

        Args:
            network (str): Name of the network.
            tx_hash (str): Transaction hash.

        Returns:
            Dict[str, Any]: Transaction receipt details.
        
        Raises:
            CutePanelAPIError: If the API request fails or the transaction is not found/mined.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/transactions/{tx_hash}/receipt")

    async def get_gas_price(self, network: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves the current gas price for the specified network.

        Args:
            network (str): Name of the network.

        Returns:
            Dict[str, Any]: Gas price information.
                            Example: `{"gas_price": "20.5", "unit": "gwei", "fast": "25", "standard": "20", "slow": "15"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/gas_price")

    async def send_raw_transaction(self, network: str, signed_tx_hex: str) -> Dict[str, Any]:
        """
        Asynchronously sends a pre-signed raw transaction to the network.

        Args:
            network (str): Name of the network.
            signed_tx_hex (str): The hex-encoded signed transaction string (e.g., "0x...").

        Returns:
            Dict[str, Any]: Response from the API, typically including the transaction hash.
                            Example: `{"transaction_hash": "0x...", "status": "submitted"}`
        
        Raises:
            CutePanelAPIError: If the API request fails (e.g., invalid transaction, network error).
        """
        return await self._main_client._request("POST", f"blockchain/{network}/transactions/send_raw", data={"signed_tx_hex": signed_tx_hex})

    async def get_block_number(self, network: str) -> Dict[str, Any]:
        """
        Asynchronously gets the latest block number for the specified network.

        Args:
            network (str): Name of the network.

        Returns:
            Dict[str, Any]: Block number information.
                            Example: `{"network": "ethereum", "block_number": 12345678}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/block_number")

    async def get_transaction_details(self, network: str, tx_hash: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves detailed information about a specific transaction,
        which may include more data than just the receipt.

        Args:
            network (str): Name of the network.
            tx_hash (str): Transaction hash.

        Returns:
            Dict[str, Any]: Detailed transaction information.
        
        Raises:
            CutePanelAPIError: If the API request fails or the transaction is not found.
        """
        return await self._main_client._request("GET", f"blockchain/{network}/transactions/{tx_hash}")

class DexClient:
    """
    Asynchronous client for interacting with Decentralized Exchange (DEX) functionalities
    managed by CutePanel.

    Provides methods for listing DEXes, getting prices, liquidity, executing swaps,
    and managing liquidity positions.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the DexClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_dexes(self, network: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously lists available DEX instances, optionally filtered by network.

        Args:
            network (Optional[str]): Name of the network to filter by (e.g., "ethereum").

        Returns:
            List[Dict[str, Any]]: A list of DEX configurations.
                                  Example: `[{"name": "UniswapV2", "network": "ethereum", ...}]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if network: params["network"] = network
        response = await self._main_client._request("GET", "dexes", params=params)
        return response.get("dexes", [])

    async def get_pair_price(self, dex_name: str, token_a_address: str, token_b_address: str, network: str) -> Dict[str, Any]:
        """
        Asynchronously gets the price for a token pair on a specific DEX.

        Args:
            dex_name (str): Name or ID of the DEX instance (e.g., "uniswapv2").
            token_a_address (str): Contract address of the first token in the pair.
            token_b_address (str): Contract address of the second token in the pair.
            network (str): The blockchain network the DEX operates on.

        Returns:
            Dict[str, Any]: Price information for the pair.
                            Example: `{"pair": "TKA/TKB", "price": "15.5", "dex": "uniswapv2"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"dexes/{network}/{dex_name}/price"
        params = {"token_a": token_a_address, "token_b": token_b_address}
        return await self._main_client._request("GET", endpoint, params=params)

    async def get_liquidity(self, dex_name: str, token_a_address: str, token_b_address: str, network: str) -> Dict[str, Any]:
        """
        Asynchronously gets the liquidity for a token pair on a specific DEX.

        Args:
            dex_name (str): Name or ID of the DEX instance.
            token_a_address (str): Contract address of the first token.
            token_b_address (str): Contract address of the second token.
            network (str): The blockchain network.

        Returns:
            Dict[str, Any]: Liquidity information (e.g., amounts of token A and B in the pool).
                            Example: `{"token_a_reserve": "1000", "token_b_reserve": "15500", ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"dexes/{network}/{dex_name}/liquidity"
        params = {"token_a": token_a_address, "token_b": token_b_address}
        return await self._main_client._request("GET", endpoint, params=params)

    async def execute_swap(self, dex_name: str, network: str, token_in_address: str, token_out_address: str, 
                     amount_in: str, slippage_tolerance: float = 0.5, 
                     recipient_address: Optional[str] = None, deadline: Optional[int] = None) -> Dict[str, Any]:
        """
        Asynchronously executes a token swap on a specific DEX.

        Args:
            dex_name (str): Name or ID of the DEX instance.
            network (str): The blockchain network.
            token_in_address (str): Contract address of the input token.
            token_out_address (str): Contract address of the output token.
            amount_in (str): Amount of input token to swap (in its smallest units).
            slippage_tolerance (float): Maximum allowed slippage percentage (e.g., 0.5 for 0.5%).
                                        Defaults to 0.5.
            recipient_address (Optional[str]): Address to receive the output tokens. 
                                               Defaults to the sender/caller if None.
            deadline (Optional[int]): Swap deadline as a Unix timestamp (seconds since epoch).

        Returns:
            Dict[str, Any]: Response from the API, typically including the transaction hash.
                            Example: `{"transaction_hash": "0x...", "status": "submitted"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"dexes/{network}/{dex_name}/swap"
        payload = {
            "token_in_address": token_in_address, "token_out_address": token_out_address,
            "amount_in": amount_in, "slippage_tolerance": slippage_tolerance
        }
        if recipient_address: payload["recipient_address"] = recipient_address
        if deadline: payload["deadline"] = deadline
        return await self._main_client._request("POST", endpoint, data=payload)

    async def add_liquidity(self, dex_name: str, network: str, token_a_address: str, token_b_address: str,
                            amount_a_desired: str, amount_b_desired: str,
                            amount_a_min: str, amount_b_min: str,
                            recipient_address: str, deadline: int,
                            tick_lower: Optional[int] = None, tick_upper: Optional[int] = None) -> Dict[str, Any]:
        """
        Asynchronously adds liquidity to a pair on a specific DEX.
        Supports both standard and concentrated liquidity (e.g., Uniswap V3 via ticks).

        Args:
            dex_name (str): Name or ID of the DEX instance.
            network (str): The blockchain network.
            token_a_address (str): Contract address of the first token.
            token_b_address (str): Contract address of the second token.
            amount_a_desired (str): Desired amount of token A to add (smallest units).
            amount_b_desired (str): Desired amount of token B to add (smallest units).
            amount_a_min (str): Minimum amount of token A to add (smallest units, for slippage).
            amount_b_min (str): Minimum amount of token B to add (smallest units, for slippage).
            recipient_address (str): Address to receive LP tokens or liquidity NFT.
            deadline (int): Transaction deadline timestamp (seconds since epoch).
            tick_lower (Optional[int]): For concentrated liquidity, the lower tick of the range.
            tick_upper (Optional[int]): For concentrated liquidity, the upper tick of the range.

        Returns:
            Dict[str, Any]: Response from the API, typically including the transaction hash.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"dexes/{network}/{dex_name}/liquidity/add"
        payload = {
            "token_a_address": token_a_address, "token_b_address": token_b_address,
            "amount_a_desired": amount_a_desired, "amount_b_desired": amount_b_desired,
            "amount_a_min": amount_a_min, "amount_b_min": amount_b_min,
            "recipient_address": recipient_address, "deadline": deadline
        }
        if tick_lower is not None and tick_upper is not None:
            payload["tick_lower"] = tick_lower
            payload["tick_upper"] = tick_upper
        return await self._main_client._request("POST", endpoint, data=payload)

    async def remove_liquidity(self, dex_name: str, network: str, lp_token_address_or_nft_id: str,
                               liquidity_amount: str, amount_a_min: str, amount_b_min: str,
                               recipient_address: str, deadline: int,
                               tick_lower: Optional[int] = None, tick_upper: Optional[int] = None) -> Dict[str, Any]:
        """
        Asynchronously removes liquidity from a pair on a specific DEX.
        Supports both standard LP tokens and concentrated liquidity position NFTs.

        Args:
            dex_name (str): Name or ID of the DEX instance.
            network (str): The blockchain network.
            lp_token_address_or_nft_id (str): Address of the LP token or ID of the liquidity position NFT.
            liquidity_amount (str): Amount of LP tokens/liquidity to remove (smallest units).
            amount_a_min (str): Minimum amount of token A to receive (smallest units).
            amount_b_min (str): Minimum amount of token B to receive (smallest units).
            recipient_address (str): Address to receive the withdrawn tokens.
            deadline (int): Transaction deadline timestamp.
            tick_lower (Optional[int]): For concentrated liquidity, lower tick of the position being removed.
            tick_upper (Optional[int]): For concentrated liquidity, upper tick of the position being removed.

        Returns:
            Dict[str, Any]: Response from the API, typically including the transaction hash.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"dexes/{network}/{dex_name}/liquidity/remove"
        payload = {
            "lp_token_address_or_nft_id": lp_token_address_or_nft_id,
            "liquidity_amount": liquidity_amount,
            "amount_a_min": amount_a_min, "amount_b_min": amount_b_min,
            "recipient_address": recipient_address, "deadline": deadline
        }
        if tick_lower is not None and tick_upper is not None:
            payload["tick_lower"] = tick_lower
            payload["tick_upper"] = tick_upper
        return await self._main_client._request("POST", endpoint, data=payload)

class PriceFeedClient:
    """
    Asynchronous client for accessing price feed functionalities via CutePanel.

    Provides methods to list available price feed providers and fetch current
    or historical price data for asset pairs.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the PriceFeedClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_providers(self) -> List[Dict[str, Any]]:
        """
        Asynchronously lists available price feed providers configured in CutePanel.

        Returns:
            List[Dict[str, Any]]: A list of provider details.
                                  Example: `[{"name": "Chainlink", "type": "onchain", ...}]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", "price_feeds/providers")
        return response.get("providers", [])

    async def get_latest_price(self, provider_name: str, base_asset: str, quote_asset: str) -> Dict[str, Any]:
        """
        Asynchronously gets the latest price for an asset pair from a specific provider.

        Args:
            provider_name (str): Name of the price feed provider (e.g., "chainlink").
            base_asset (str): The base asset symbol (e.g., "BTC").
            quote_asset (str): The quote asset symbol (e.g., "USD").

        Returns:
            Dict[str, Any]: Price information.
                            Example: `{"asset_pair": "BTC/USD", "price": "60000.0", "timestamp": "..."}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"price_feeds/{provider_name}/latest"
        params = {"base_asset": base_asset, "quote_asset": quote_asset}
        return await self._main_client._request("GET", endpoint, params=params)

    async def get_historical_prices(self, provider_name: str, base_asset: str, quote_asset: str, 
                                     start_time: Optional[str] = None, end_time: Optional[str] = None, 
                                     interval: Optional[str] = None) -> Dict[str, Any]:
        """
        Asynchronously gets historical prices for an asset pair from a specific provider.

        Args:
            provider_name (str): Name of the price feed provider.
            base_asset (str): Base asset symbol.
            quote_asset (str): Quote asset symbol.
            start_time (Optional[str]): Start timestamp (ISO 8601 format, e.g., "2023-01-01T00:00:00Z").
            end_time (Optional[str]): End timestamp (ISO 8601 format).
            interval (Optional[str]): Time interval for candles/data points (e.g., "1h", "1d", "5m").
                                      The supported intervals depend on the provider and backend implementation.

        Returns:
            Dict[str, Any]: Historical price data, typically a list of candles or data points.
                            Example: `{"asset_pair": "BTC/USD", "data": [{"timestamp": ..., "open": ..., "high": ..., "low": ..., "close": ..., "volume": ...}]}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = f"price_feeds/{provider_name}/historical"
        params: Dict[str, Any] = {"base_asset": base_asset, "quote_asset": quote_asset}
        if start_time: params["start_time"] = start_time
        if end_time: params["end_time"] = end_time
        if interval: params["interval"] = interval
        return await self._main_client._request("GET", endpoint, params=params)

class TradingClient:
    """
    Asynchronous client for trading, portfolio, and strategy management via CutePanel.

    Provides methods for listing and executing trading strategies, managing portfolios,
    placing orders, and retrieving trading-related information.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the TradingClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_strategies(self) -> List[Dict[str, Any]]:
        """
        Asynchronously lists available trading strategies configured in CutePanel.

        Returns:
            List[Dict[str, Any]]: A list of trading strategy configurations/details.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", "trading/strategies")
        return response.get("strategies", [])

    async def get_strategy_details(self, strategy_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves details for a specific trading strategy.

        Args:
            strategy_id (str): The unique identifier of the trading strategy.

        Returns:
            Dict[str, Any]: Detailed information about the strategy.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"trading/strategies/{strategy_id}")

    async def execute_strategy(self, strategy_id: str, parameters: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Asynchronously executes a specific trading strategy.
        This might trigger rebalancing, order generation, etc., based on the strategy's logic.

        Args:
            strategy_id (str): The ID of the strategy to execute.
            parameters (Optional[Dict[str, Any]]): Execution-specific parameters 
                                                   (e.g., dry_run, specific market data).

        Returns:
            Dict[str, Any]: Result of the strategy execution (e.g., orders placed, portfolio changes).
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        data = {"parameters": parameters if parameters else {}}
        return await self._main_client._request("POST", f"trading/strategies/{strategy_id}/execute", data=data)

    async def get_portfolio_status(self, portfolio_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Asynchronously retrieves the status and holdings of a portfolio.
        If portfolio_id is not provided, it might return the default or main portfolio.

        Args:
            portfolio_id (Optional[str]): The ID of the portfolio.

        Returns:
            Dict[str, Any]: Portfolio status, holdings, P&L, etc.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        endpoint = "trading/portfolio"
        if portfolio_id:
            endpoint = f"trading/portfolios/{portfolio_id}"
        return await self._main_client._request("GET", endpoint)

    async def backtest_strategy(self, strategy_id: str, backtest_config: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously runs a backtest for a given strategy with specified configuration.

        Args:
            strategy_id (str): The ID of the strategy to backtest.
            backtest_config (Dict[str, Any]): Configuration for the backtest
                (e.g., historical data range, initial capital, transaction costs).

        Returns:
            Dict[str, Any]: Backtest results (performance metrics, trade log, equity curve).
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"trading/strategies/{strategy_id}/backtest", data=backtest_config)

    async def create_order(self, order_details: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously places a new trading order.

        Args:
            order_details (Dict[str, Any]): Dictionary containing order parameters like
                asset_pair, type (limit/market), side (buy/sell), amount, price (for limit orders), etc.
                Also, portfolio_id or account_id if applicable.

        Returns:
            Dict[str, Any]: Response from the API, typically including an order_id and status.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", "trading/orders/create", data=order_details)

    async def get_order_status(self, order_id: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves the status of a specific trading order.

        Args:
            order_id (str): The unique identifier of the order.

        Returns:
            Dict[str, Any]: Detailed status of the order.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"trading/orders/{order_id}/status")

    async def cancel_order(self, order_id: str) -> Dict[str, Any]:
        """
        Asynchronously attempts to cancel an open trading order.

        Args:
            order_id (str): The unique identifier of the order to cancel.

        Returns:
            Dict[str, Any]: Confirmation of the cancellation request.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"trading/orders/{order_id}/cancel")

    async def list_open_orders(self, portfolio_id: Optional[str] = None, asset_pair: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously lists open trading orders, optionally filtered.

        Args:
            portfolio_id (Optional[str]): Filter by portfolio ID.
            asset_pair (Optional[str]): Filter by asset pair (e.g., "BTC/USD").

        Returns:
            List[Dict[str, Any]]: A list of open orders.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if portfolio_id: params["portfolio_id"] = portfolio_id
        if asset_pair: params["asset_pair"] = asset_pair
        response = await self._main_client._request("GET", "trading/orders/open", params=params)
        return response.get("orders", [])

    async def get_trade_history(self, portfolio_id: Optional[str] = None, asset_pair: Optional[str] = None, 
                                start_time: Optional[str] = None, end_time: Optional[str] = None, 
                                limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously retrieves the history of executed trades.

        Args:
            portfolio_id (Optional[str]): Filter by portfolio ID.
            asset_pair (Optional[str]): Filter by asset pair (e.g., "BTC/USD").
            start_time (Optional[str]): Filter by start time (ISO 8601 format, e.g., "2023-01-01T00:00:00Z").
            end_time (Optional[str]): Filter by end time (ISO 8601 format).
            limit (Optional[int]): Limit the number of trades returned.

        Returns:
            List[Dict[str, Any]]: A list of trade history records.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params: Dict[str, Any] = {}
        if portfolio_id: params["portfolio_id"] = portfolio_id
        if asset_pair: params["asset_pair"] = asset_pair
        if start_time: params["start_time"] = start_time
        if end_time: params["end_time"] = end_time
        if limit: params["limit"] = limit
        response = await self._main_client._request("GET", "trading/trades/history", params=params)
        return response.get("trades", [])

    async def get_portfolio_performance(self, portfolio_id: str, 
                                        start_time: Optional[str] = None, 
                                        end_time: Optional[str] = None) -> Dict[str, Any]:
        """
        Asynchronously retrieves performance metrics for a specific portfolio over a period.

        Args:
            portfolio_id (str): The ID of the portfolio.
            start_time (Optional[str]): Start time for performance calculation (ISO 8601 format).
            end_time (Optional[str]): End time for performance calculation (ISO 8601 format).

        Returns:
            Dict[str, Any]: Portfolio performance metrics (e.g., returns, Sharpe ratio, max drawdown).
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params: Dict[str, Any] = {}
        if start_time: params["start_time"] = start_time
        if end_time: params["end_time"] = end_time
        return await self._main_client._request("GET", f"trading/portfolios/{portfolio_id}/performance", params=params)

    async def get_portfolio_positions(self, portfolio_id: str) -> List[Dict[str, Any]]:
        """
        Asynchronously retrieves the current asset positions for a specific portfolio.

        Args:
            portfolio_id (str): The ID of the portfolio.

        Returns:
            List[Dict[str, Any]]: A list of asset positions.
                                  Example: `[{"asset": "BTC", "amount": "0.5", "value_usd": "30000.00"}, ...]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", f"trading/portfolios/{portfolio_id}/positions")
        return response.get("positions", [])

class StorageClient:
    """
    Asynchronous client for interacting with storage functionalities in CutePanel.

    Provides methods to list storage providers, save, load, delete, and manage
    data across various configured storage backends (e.g., local, Arweave, IPFS).
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the StorageClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_providers(self) -> List[Dict[str, Any]]:
        """
        Asynchronously lists available storage providers configured in CutePanel.

        Returns:
            List[Dict[str, Any]]: A list of storage provider details.
                                  Example: `[{"name": "local_sqlite", "type": "database"}, {"name": "arweave_mainnet", "type": "decentralized"}]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", "storage/providers")
        return response.get("providers", [])

    async def save(self, provider_name: str, key: str, data: Any, metadata: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Asynchronously saves data to the specified storage provider.

        Args:
            provider_name (str): Name of the storage provider (e.g., "local_sqlite", "arweave").
            key (str): The unique key under which to store the data.
            data (Any): The data to store (will be serialized, typically to JSON by the backend).
            metadata (Optional[Dict[str, Any]]): Optional metadata (tags, descriptions) to store alongside the data.

        Returns:
            Dict[str, Any]: Confirmation of the save operation, possibly including a transaction ID
                            or content identifier for decentralized storage.
                            Example: `{"status": "success", "cid": "bafy...", "provider": "arweave"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        payload = {"key": key, "data": data}
        if metadata:
            payload["metadata"] = metadata
        return await self._main_client._request("POST", f"storage/{provider_name}/save", data=payload)

    async def load(self, provider_name: str, key: str) -> Dict[str, Any]:
        """
        Asynchronously loads data from the specified storage provider.

        Args:
            provider_name (str): Name of the storage provider.
            key (str): The key of the data to load.

        Returns:
            Dict[str, Any]: The loaded data and its metadata.
                            Example: `{"key": "my_data", "data": {"value": 42}, "metadata": {"tag": "test"}}`
        
        Raises:
            CutePanelAPIError: If the API request fails or the key is not found.
        """
        return await self._main_client._request("GET", f"storage/{provider_name}/load/{key}")

    async def delete(self, provider_name: str, key: str) -> Dict[str, Any]:
        """
        Asynchronously deletes data from the specified storage provider.

        Args:
            provider_name (str): Name of the storage provider.
            key (str): The key of the data to delete.

        Returns:
            Dict[str, Any]: Confirmation of the delete operation.
                            Example: `{"status": "success", "key_deleted": "my_data"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("DELETE", f"storage/{provider_name}/delete/{key}")

    async def list_keys(self, provider_name: str, prefix: Optional[str] = None) -> List[str]:
        """
        Asynchronously lists keys in the specified storage provider, optionally filtered by prefix.

        Args:
            provider_name (str): Name of the storage provider.
            prefix (Optional[str]): Prefix to filter keys by.

        Returns:
            List[str]: A list of keys. Example: `["config/agent1", "data/log_20230101"]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params = {}
        if prefix:
            params["prefix"] = prefix
        response = await self._main_client._request("GET", f"storage/{provider_name}/keys", params=params)
        return response.get("keys", [])

    async def exists(self, provider_name: str, key: str) -> Dict[str, bool]:
        """
        Asynchronously checks if a key exists in the specified storage provider.

        Args:
            provider_name (str): Name of the storage provider.
            key (str): The key to check.

        Returns:
            Dict[str, bool]: A dictionary indicating existence. Example: `{"exists": True}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"storage/{provider_name}/exists/{key}")

class LLMClient:
    """
    Asynchronous client for interacting with Large Language Model (LLM) functionalities
    provided or managed by CutePanel.

    This client allows listing LLM providers, performing chat completions, and
    generating text embeddings by routing requests through the CutePanel backend.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the LLMClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_providers(self) -> List[Dict[str, Any]]:
        """
        Asynchronously lists available LLM providers configured in CutePanel.

        Returns:
            List[Dict[str, Any]]: A list of LLM provider details.
                                  Example: `[{"name": "OpenAI", "models": ["gpt-4o-mini", "gpt-4-turbo"]}, ...]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", "llm/providers")
        return response.get("providers", [])

    async def chat_completion(self, provider_name: str, model_name: str, messages: List[Dict[str, str]], 
                               parameters: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Asynchronously sends a chat completion request to a specific LLM via CutePanel.

        Args:
            provider_name (str): Name of the LLM provider (e.g., "openai", "anthropic").
            model_name (str): Name of the model (e.g., "gpt-4o-mini", "claude-3-opus").
            messages (List[Dict[str, str]]): A list of message objects, where each message
                                             has a "role" (e.g., "user", "assistant", "system")
                                             and "content" (the message text).
                                             Example: `[{"role": "user", "content": "Hello, world!"}]`
            parameters (Optional[Dict[str, Any]]): Additional parameters for the LLM request,
                                                   such as temperature, max_tokens, top_p, etc.
                                                   These are provider/model specific.

        Returns:
            Dict[str, Any]: The LLM's response, typically including the generated message.
                            Example: `{"id": "chatcmpl-...", "choices": [{"message": {"role": "assistant", "content": "..."}}], ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        payload = {
            "model": model_name,
            "messages": messages,
            "parameters": parameters if parameters else {}
        }
        return await self._main_client._request("POST", f"llm/{provider_name}/chat", data=payload)

    async def get_text_embedding(self, provider_name: str, model_name: str, text_input: str, 
                                  parameters: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Asynchronously gets a text embedding for the given input text using a specific LLM.

        Args:
            provider_name (str): Name of the LLM provider.
            model_name (str): Name of the embedding model.
            text_input (str): The text to get an embedding for. Can be a single string or
                              a list of strings if the backend supports batching.
            parameters (Optional[Dict[str, Any]]): Additional parameters for the embedding request,
                                                   provider/model specific.

        Returns:
            Dict[str, Any]: The embedding vector(s) and any associated metadata.
                            Example for single input: `{"embedding": [0.1, 0.2, ...], "model": "text-embedding-ada-002"}`
                            Example for multiple inputs (if supported): `{"embeddings": [[...], [...]], ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        payload = {
            "model": model_name,
            "input": text_input, # Backend should handle if this is a list for batching
            "parameters": parameters if parameters else {}
        }
        return await self._main_client._request("POST", f"llm/{provider_name}/embeddings", data=payload)

    async def get_llm_provider_capabilities(self, provider_name: str) -> Dict[str, Any]:
        """
        Asynchronously retrieves capabilities and details for a specific LLM provider.

        Args:
            provider_name (str): The name of the LLM provider.

        Returns:
            Dict[str, Any]: Details about the provider, such as supported models,
                            features (e.g., streaming, function calling), rate limits, etc.
                            Example: `{"name": "OpenAI", "models": [...], "supports_streaming": True}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"llm/providers/{provider_name}/capabilities")

    async def stream_chat_completion(self, provider_name: str, model_name: str, messages: List[Dict[str, str]], 
                                      parameters: Optional[Dict[str, Any]] = None) -> AsyncIterator[Dict[str, Any]]: # type: ignore
        """
        Asynchronously sends a chat completion request and streams the response.
        Note: Requires the CutePanel backend to support a streaming endpoint for this.

        Args:
            provider_name (str): Name of the LLM provider.
            model_name (str): Name of the model.
            messages (List[Dict[str, str]]): List of message objects.
            parameters (Optional[Dict[str, Any]]): Additional LLM parameters.

        Yields:
            Dict[str, Any]: Chunks of the LLM's response as they arrive.
                            The structure of chunks depends on the backend's streaming implementation
                            (e.g., Server-Sent Events data).

        Raises:
            CutePanelAPIError: If the initial request fails or an error occurs during streaming.
        """
        payload = {
            "model": model_name,
            "messages": messages,
            "parameters": parameters if parameters else {}
        }
        # Assuming a streaming endpoint like '/llm/{provider_name}/chat/stream'
        # The actual implementation of handling the stream (e.g., parsing SSE)
        # would depend on how the CutePanel backend provides the stream.
        # httpx's aiter_text(), aiter_bytes(), or aiter_lines() would be used here.
        async with self._main_client._client.stream("POST", f"llm/{provider_name}/chat/stream", json=payload) as response:
            response.raise_for_status() # Check for initial errors
            async for chunk_str in response.aiter_text(): # Example: assuming text chunks
                # This part needs to be adapted based on the actual streaming format from CutePanel
                # For example, if it's JSON lines:
                try:
                    yield json.loads(chunk_str) 
                except json.JSONDecodeError:
                    # Handle non-JSON chunks or malformed data if necessary
                    # Or simply yield the raw string if that's the expected format
                    yield {"raw_chunk": chunk_str} # Placeholder for raw data

class CrossChainClient:
    """
    Asynchronous client for interacting with cross-chain functionalities in CutePanel.

    Provides methods for listing supported bridges, getting quotes for transfers,
    initiating transfers, checking transfer status, and retrieving transfer history.
    """
    def __init__(self, main_client: CutePanelClient):
        """
        Initializes the CrossChainClient.

        Args:
            main_client (CutePanelClient): The main CutePanelClient instance.
        """
        self._main_client = main_client

    async def list_bridges(self) -> List[Dict[str, Any]]:
        """
        Asynchronously lists supported cross-chain bridge protocols.

        Returns:
            List[Dict[str, Any]]: A list of bridge details.
                                  Example: `[{"name": "HopProtocol", "supported_chains": ["ethereum", "polygon"]}, ...]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        response = await self._main_client._request("GET", "cross_chain/bridges")
        return response.get("bridges", [])

    async def get_quote(self, bridge_name: str, from_chain: str, to_chain: str, 
                        from_token: str, to_token: str, amount: str) -> Dict[str, Any]:
        """
        Asynchronously gets a quote for a cross-chain transfer.

        Args:
            bridge_name (str): Name of the bridge protocol.
            from_chain (str): Source chain ID or name (e.g., "ethereum").
            to_chain (str): Destination chain ID or name (e.g., "polygon").
            from_token (str): Source token address or symbol.
            to_token (str): Destination token address or symbol.
            amount (str): Amount of source token to transfer (in its smallest units).

        Returns:
            Dict[str, Any]: Quote details, including estimated output amount, fees, and estimated time.
                            Example: `{"bridge": "Hop", "output_amount": "99.5", "fee": "0.5", ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        payload = {
            "from_chain": from_chain, "to_chain": to_chain,
            "from_token": from_token, "to_token": to_token,
            "amount": amount
        }
        return await self._main_client._request("POST", f"cross_chain/bridges/{bridge_name}/quote", data=payload)

    async def initiate_transfer(self, bridge_name: str, transfer_params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Asynchronously initiates a cross-chain transfer.

        Args:
            bridge_name (str): Name of the bridge protocol.
            transfer_params (Dict[str, Any]): Parameters for the transfer, including
                from_chain, to_chain, from_token, to_token, amount, recipient_address, etc.
                May also include signed transactions if required by the bridge's flow.

        Returns:
            Dict[str, Any]: Response from the API, typically including a transaction ID or bridge operation ID.
                            Example: `{"operation_id": "bridge_op_123", "status": "pending"}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("POST", f"cross_chain/bridges/{bridge_name}/transfer", data=transfer_params)

    async def get_transfer_status(self, bridge_name: str, operation_id: str) -> Dict[str, Any]:
        """
        Asynchronously checks the status of a cross-chain transfer operation.

        Args:
            bridge_name (str): Name of the bridge protocol.
            operation_id (str): The ID of the bridge operation or transaction.

        Returns:
            Dict[str, Any]: Status details of the transfer.
                            Example: `{"operation_id": "bridge_op_123", "status": "completed", ...}`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        return await self._main_client._request("GET", f"cross_chain/bridges/{bridge_name}/status/{operation_id}")

    async def get_supported_assets(self, bridge_name: str, from_chain: Optional[str] = None, to_chain: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously lists assets supported by a specific bridge, optionally filtered by source or destination chain.

        Args:
            bridge_name (str): Name of the bridge protocol.
            from_chain (Optional[str]): Filter by source chain ID or name.
            to_chain (Optional[str]): Filter by destination chain ID or name.

        Returns:
            List[Dict[str, Any]]: A list of supported assets and their details for the specified bridge and chains.
                                  Example: `[{"token_symbol": "USDC", "from_chain_address": "0x...", "to_chain_address": "0x..."}]`
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params: Dict[str, Any] = {}
        if from_chain: params["from_chain"] = from_chain
        if to_chain: params["to_chain"] = to_chain
        response = await self._main_client._request("GET", f"cross_chain/bridges/{bridge_name}/assets", params=params)
        return response.get("assets", [])

    async def get_transfer_history(self, bridge_name: Optional[str] = None, user_address: Optional[str] = None, 
                                   from_chain: Optional[str] = None, to_chain: Optional[str] = None,
                                   token_address: Optional[str] = None, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Asynchronously retrieves the history of cross-chain transfers, with various optional filters.

        Args:
            bridge_name (Optional[str]): Filter by bridge protocol name.
            user_address (Optional[str]): Filter by user's address involved in transfers.
            from_chain (Optional[str]): Filter by source chain.
            to_chain (Optional[str]): Filter by destination chain.
            token_address (Optional[str]): Filter by token address.
            limit (Optional[int]): Limit the number of history records returned.

        Returns:
            List[Dict[str, Any]]: A list of cross-chain transfer history records.
        
        Raises:
            CutePanelAPIError: If the API request fails.
        """
        params: Dict[str, Any] = {}
        if bridge_name: params["bridge_name"] = bridge_name
        if user_address: params["user_address"] = user_address
        if from_chain: params["from_chain"] = from_chain
        if to_chain: params["to_chain"] = to_chain
        if token_address: params["token_address"] = token_address
        if limit: params["limit"] = limit
        response = await self._main_client._request("GET", "cross_chain/transfers/history", params=params)
        return response.get("transfers", [])

async def main():
    print("Running CutePanelClient async example...")
    try:
        async with CutePanelClient(base_url="http://localhost:8080/api/v1") as client:
            status = await client.get_status()
            print("\nCutePanel Backend Status:", status)
            print("\n--- Agent Operations ---")
            agents_list = await client.agents.list()
            print("List of Agents:", agents_list)
            print("\n--- Swarm Operations ---")
            swarms_list = await client.swarms.list()
            print("List of Swarms:", swarms_list)
    except CutePanelAPIError as e:
        print(f"API Error: {e.status_code} - {e.error_message}")
        if e.response_data: print("Error Details:", e.response_data)
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

if __name__ == "__main__":
    asyncio.run(main())
