// packages/agents/src/AgentsService.ts

import { ApiClient, ApiClientError } from '@cutepanel/core/api/ApiClient'; // Using path alias
import {
  AgentInfo,
  AgentListFilters,
  AgentConfigCreatePayload,
  AgentStatusDetail,
  AgentUpdatePayload,
  AgentLifecycleResponse,
  TaskPayload,
  TaskSubmissionResult,
  ListAgentTasksResponse,
  TaskListFilters,
  TaskExecutionResult,
  AgentMemoryResponse,
  AgentMemorySetResponse,
  AgentMemoryClearResponse,
  BulkDeletePayload,
  BulkDeleteResponse
} from './types';

export class AgentsService {
  private apiClient: ApiClient;

  constructor(apiClient: ApiClient) {
    this.apiClient = apiClient;
  }

  /**
   * Lists all agents, with optional filtering.
   * Corresponds to GET /api/v1/agents
   */
  public async listAgents(filters?: AgentListFilters): Promise<AgentInfo[]> {
    try {
      // Build query parameters if filters are provided
      const queryParams = new URLSearchParams();
      if (filters?.type) {
        queryParams.append('type', String(filters.type));
      }
      if (filters?.status) {
        queryParams.append('status', String(filters.status));
      }
      const queryString = queryParams.toString();
      const path = queryString ? `/agents?${queryString}` : '/agents';
      
      // The backend is expected to return AgentInfo[] directly on success
      const response = await this.apiClient.get<AgentInfo[]>(path);
      return response; // Assuming direct array response based on AgentHandlers.list_agents_handler
    } catch (error) {
      // ApiClientError will be thrown by apiClient on network/API errors
      // Re-throw or handle more specifically if needed
      throw error;
    }
  }

  /**
   * Creates a new agent.
   * Corresponds to POST /api/v1/agents
   */
  public async createAgent(payload: AgentConfigCreatePayload): Promise<AgentInfo> {
    // Backend returns: Dict("id" => new_agent.id, "name" => new_agent.name, "status" => string(new_agent.status))
    // This matches parts of AgentInfo.
    return this.apiClient.post<AgentInfo>('/agents', payload);
  }

  /**
   * Gets the status and details of a specific agent.
   * Corresponds to GET /api/v1/agents/{agent_id}
   */
  public async getAgentStatus(agentId: string): Promise<AgentStatusDetail> {
    return this.apiClient.get<AgentStatusDetail>(`/agents/${agentId}`);
  }

  /**
   * Updates an existing agent.
   * Corresponds to PUT /api/v1/agents/{agent_id}
   */
  public async updateAgent(agentId: string, payload: AgentUpdatePayload): Promise<AgentStatusDetail> {
    // Backend returns full agent status after update
    return this.apiClient.put<AgentStatusDetail>(`/agents/${agentId}`, payload);
  }

  /**
   * Deletes an agent.
   * Corresponds to DELETE /api/v1/agents/{agent_id}
   */
  public async deleteAgent(agentId: string): Promise<{ message: string; agent_id: string }> {
    return this.apiClient.delete<{ message: string; agent_id: string }>(`/agents/${agentId}`);
  }
  
  /**
   * Clones an existing agent.
   * Corresponds to POST /api/v1/agents/{agent_id}/clone
   */
  public async cloneAgent(agentId: string, newName: string, parameterOverrides?: Record<string, any>): Promise<AgentInfo> {
    const payload = { new_name: newName, parameter_overrides: parameterOverrides || {} };
    // Backend returns: Dict("id" => cloned_agent.id, "name" => cloned_agent.name, "status" => string(cloned_agent.status))
    return this.apiClient.post<AgentInfo>(`/agents/${agentId}/clone`, payload);
  }

  /**
   * Deletes multiple agents in bulk.
   * Corresponds to POST /api/v1/agents/bulk-delete
   */
  public async bulkDeleteAgents(payload: BulkDeletePayload): Promise<BulkDeleteResponse> {
      return this.apiClient.post<BulkDeleteResponse>('/agents/bulk-delete', payload);
  }

  // --- Agent Lifecycle ---
  public async startAgent(agentId: string): Promise<AgentLifecycleResponse> {
    return this.apiClient.post<AgentLifecycleResponse>(`/agents/${agentId}/start`);
  }

  public async stopAgent(agentId: string): Promise<AgentLifecycleResponse> {
    return this.apiClient.post<AgentLifecycleResponse>(`/agents/${agentId}/stop`);
  }

  public async pauseAgent(agentId: string): Promise<AgentLifecycleResponse> {
    return this.apiClient.post<AgentLifecycleResponse>(`/agents/${agentId}/pause`);
  }

  public async resumeAgent(agentId: string): Promise<AgentLifecycleResponse> {
    return this.apiClient.post<AgentLifecycleResponse>(`/agents/${agentId}/resume`);
  }

  // --- Agent Tasks ---
  public async executeTask(agentId: string, task: TaskPayload): Promise<TaskSubmissionResult> {
    return this.apiClient.post<TaskSubmissionResult>(`/agents/${agentId}/tasks`, task);
  }

  public async listAgentTasks(agentId: string, filters?: TaskListFilters): Promise<ListAgentTasksResponse> {
    const queryParams = new URLSearchParams();
    if (filters?.status_filter) {
      queryParams.append('status_filter', String(filters.status_filter));
    }
    if (filters?.limit !== undefined) {
      queryParams.append('limit', String(filters.limit));
    }
    const queryString = queryParams.toString();
    const path = queryString ? `/agents/${agentId}/tasks?${queryString}` : `/agents/${agentId}/tasks`;
    return this.apiClient.get<ListAgentTasksResponse>(path);
  }

  public async getTaskStatus(agentId: string, taskId: string): Promise<AgentTaskSummary> { 
    // Backend returns AgentTaskSummary structure for status
    return this.apiClient.get<AgentTaskSummary>(`/agents/${agentId}/tasks/${taskId}`);
  }

  public async getTaskResult(agentId: string, taskId: string): Promise<TaskExecutionResult> {
    return this.apiClient.get<TaskExecutionResult>(`/agents/${agentId}/tasks/${taskId}/result`);
  }

  public async cancelTask(agentId: string, taskId: string): Promise<{ success: boolean; task_id: string; message?: string }> {
    return this.apiClient.post<{ success: boolean; task_id: string; message?: string }>(`/agents/${agentId}/tasks/${taskId}/cancel`);
  }
  
  // --- Agent Memory ---
  public async getAgentMemory(agentId: string, key: string): Promise<AgentMemoryResponse> {
    return this.apiClient.get<AgentMemoryResponse>(`/agents/${agentId}/memory/${key}`);
  }

  public async setAgentMemory(agentId: string, key: string, value: any): Promise<AgentMemorySetResponse> {
    return this.apiClient.post<AgentMemorySetResponse>(`/agents/${agentId}/memory/${key}`, { value });
  }

  public async clearAgentMemory(agentId: string): Promise<AgentMemoryClearResponse> {
    return this.apiClient.delete<AgentMemoryClearResponse>(`/agents/${agentId}/memory`);
  }
}
