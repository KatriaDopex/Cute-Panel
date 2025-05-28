// packages/core/src/api/ApiClient.ts

import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse, AxiosError, InternalAxiosRequestConfig } from 'axios';


// --- Type Definitions ---
export interface JuliaApiErrorDetail {
  message: string;
  error_code?: string;
  details?: any;
  status_code: number;
}

export interface JuliaApiResponseError {
  error: JuliaApiErrorDetail;
}

export interface Agent {
  agent_id: string;
  name: string;
  type: string;
  status: string;
  // Add other common agent properties as they become known
  [key: string]: any; // Allow other dynamic properties
}

export interface AgentListResponse {
  agents: Agent[];
  // Add other potential pagination or metadata fields if the API returns them
}

export interface CreateAgentConfig {
    name: string;
    type: string;
    parameters?: Record<string, any>;
    abilities?: string[];
    // Add other configuration properties as needed
    [key: string]: any;
}

export interface ExecuteTaskPayload {
    ability: string;
    parameters?: Record<string, any>;
}

// Custom error class for API errors
export class ApiClientError extends Error {
  public readonly statusCode: number;
  public readonly errorCode?: string;
  public readonly errorDetails?: any;

  constructor(message: string, statusCode: number, errorCode?: string, errorDetails?: any) {
    super(message);
    this.name = 'ApiClientError';
    this.statusCode = statusCode;
    this.errorCode = errorCode;
    this.errorDetails = errorDetails;
    Object.setPrototypeOf(this, ApiClientError.prototype);
  }
}

// --- Sub-client for Agents ---
class AgentsApiClient {
  private mainClient: CutePanelClientTS; // Changed to CutePanelClientTS

  constructor(mainClient: CutePanelClientTS) { // Changed to CutePanelClientTS
    this.mainClient = mainClient;
  }

  public async list(agentType?: string, status?: string): Promise<Agent[]> {
    const params: Record<string, string> = {};
    if (agentType) params['type'] = agentType;
    if (status) params['status'] = status;
    
    // Assuming the actual API response for listing agents is { agents: Agent[] }
    const response = await this.mainClient.get<AgentListResponse>('/agents', { params });
    return response.agents || [];
  }

  public async get(agentId: string): Promise<Agent> {
    return this.mainClient.get<Agent>(`/agents/${agentId}`);
  }

  public async create(config: CreateAgentConfig): Promise<Agent> { 
    // The backend might return the full agent object or just a confirmation with ID.
    // Adjusting to expect Agent based on common patterns.
    return this.mainClient.post<Agent>('/agents/create', config); 
  }
  
  public async start(agentId: string): Promise<any> { // Return type can be more specific if known
    return this.mainClient.post(`/agents/${agentId}/start`);
  }

  public async stop(agentId: string): Promise<any> { // Return type can be more specific
    return this.mainClient.post(`/agents/${agentId}/stop`);
  }
  
  public async executeTask(agentId: string, taskPayload: ExecuteTaskPayload): Promise<any> { // Return type can be more specific
    return this.mainClient.post(`/agents/${agentId}/execute_task`, taskPayload);
  }
  // TODO: Add other agent methods: pause, resume, delete, get_task_status, get_task_result, list_agent_tasks, cancel_agent_task
}

// --- Main CutePanel TypeScript Client ---
export class CutePanelClientTS {
  private axiosInstance: AxiosInstance;
  private apiKey?: string;

  // Sub-clients
  public agents: AgentsApiClient;
  // public swarms: SwarmsApiClient; // To be added
  // ... other clients

  constructor(baseURL: string, apiKey?: string) {
    this.apiKey = apiKey;
    this.axiosInstance = axios.create({
      baseURL: baseURL, // e.g., http://localhost:8080/api/v1 (CutePanel backend port)
      headers: {
        'Content-Type': 'application/json',
      },
    });

    this.axiosInstance.interceptors.request.use(
      (config: InternalAxiosRequestConfig) => {
        if (this.apiKey) {
          config.headers = config.headers || {};
          config.headers['X-API-Key'] = this.apiKey;
        }
        return config;
      },
      (error: AxiosError) => {
        return Promise.reject(error);
      }
    );

    // Initialize sub-clients
    this.agents = new AgentsApiClient(this);
    // this.swarms = new SwarmsApiClient(this); // Example for future
  }
  
  private handleApiError(error: AxiosError): never {
    if (error.response) {
      const responseData = error.response.data as JuliaApiResponseError | any;
      if (responseData && responseData.error && responseData.error.message) {
        const errDetail = responseData.error;
        throw new ApiClientError(
          errDetail.message,
          errDetail.status_code || error.response.status,
          errDetail.error_code,
          errDetail.details
        );
      } else {
        throw new ApiClientError(
          (error.response.data as any)?.message || error.message,
          error.response.status,
          'UNKNOWN_CLIENT_ERROR',
          error.response.data
        );
      }
    } else if (error.request) {
      throw new ApiClientError('No response received from server', 503, 'NETWORK_ERROR', error.request);
    } else {
      throw new ApiClientError(`Request setup error: ${error.message}`, 500, 'REQUEST_SETUP_ERROR');
    }
  }

  public async get<T = any>(path: string, config?: AxiosRequestConfig): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.axiosInstance.get(path, config);
      return response.data;
    } catch (error) {
      this.handleApiError(error as AxiosError);
    }
  }

  public async post<T = any>(path: string, data?: any, config?: AxiosRequestConfig): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.axiosInstance.post(path, data, config);
      return response.data;
    } catch (error) {
      this.handleApiError(error as AxiosError);
    }
  }

  public async put<T = any>(path: string, data?: any, config?: AxiosRequestConfig): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.axiosInstance.put(path, data, config);
      return response.data;
    } catch (error) {
      this.handleApiError(error as AxiosError);
    }
  }

  public async delete<T = any>(path: string, config?: AxiosRequestConfig): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.axiosInstance.delete(path, config);
      return response.data;
    } catch (error) {
      this.handleApiError(error as AxiosError);
    }
  }

  public async getStatus(): Promise<any> { // Example: Get overall backend status
    return this.get('/status');
  }
}

// Example Usage (can be moved to a test file or an example script)
/*
async function main() {
  const cutepanelClient = new CutePanelClientTS('http://localhost:8080/api/v1', 'YOUR_API_KEY_IF_NEEDED');

  try {
    console.log('Getting backend status...');
    const status = await cutepanelClient.getStatus();
    console.log('Status:', status);

    console.log('Listing agents...');
    const agents = await cutepanelClient.agents.list();
    console.log('Agents:', agents);

    if (agents.length > 0 && agents[0]) {
      console.log(`Getting details for agent ${agents[0].agent_id}...`);
      const agentDetail = await cutepanelClient.agents.get(agents[0].agent_id);
      console.log('Agent Detail:', agentDetail);
    }

    // const newAgentPayload: CreateAgentConfig = {
    //   name: "MyTSAgentFromSDK",
    //   type: "SimpleDataAgent", 
    //   abilities: ["ping"]
    // };
    // console.log('Creating agent...');
    // const newAgent = await cutepanelClient.agents.create(newAgentPayload);
    // console.log('New Agent:', newAgent);

    // if (newAgent && newAgent.agent_id) {
    //   console.log(`Starting agent ${newAgent.agent_id}...`);
    //   await cutepanelClient.agents.start(newAgent.agent_id);
    //   console.log(`Executing task on agent ${newAgent.agent_id}...`);
    //   const taskResult = await cutepanelClient.agents.executeTask(newAgent.agent_id, { ability: "ping" });
    //   console.log('Task Result:', taskResult);
    // }

  } catch (error) {
    if (error instanceof ApiClientError) {
      console.error(`API Error (${error.statusCode}, Code: ${error.errorCode || 'N/A'}): ${error.message}`);
      if (error.errorDetails) {
        console.error('Details:', JSON.stringify(error.errorDetails, null, 2));
      }
    } else {
      console.error('Unknown Error:', error);
    }
  }
}

// main();
*/
