// packages/agents/src/types.ts

// Corresponds to AgentType enum in Julia backend (Agents.jl)
export enum AgentType {
  TRADING = 'TRADING',
  MONITOR = 'MONITOR',
  ARBITRAGE = 'ARBITRAGE',
  DATA_COLLECTION = 'DATA_COLLECTION',
  NOTIFICATION = 'NOTIFICATION',
  CUSTOM = 'CUSTOM',
  DEV = 'DEV',
}

// Corresponds to AgentStatus enum in Julia backend (Agents.jl)
export enum AgentStatus {
  CREATED = 'CREATED',
  INITIALIZING = 'INITIALIZING',
  RUNNING = 'RUNNING',
  PAUSED = 'PAUSED',
  STOPPED = 'STOPPED',
  ERROR = 'ERROR',
}

// Corresponds to TaskStatus enum in Julia backend (Agents.jl)
export enum TaskStatus {
  TASK_PENDING = 'TASK_PENDING',
  TASK_RUNNING = 'TASK_RUNNING',
  TASK_COMPLETED = 'TASK_COMPLETED',
  TASK_FAILED = 'TASK_FAILED',
  TASK_CANCELLED = 'TASK_CANCELLED',
  TASK_UNKNOWN = 'TASK_UNKNOWN',
}

// Payload for creating a new agent (matches AgentHandlers.create_agent_handler expectations)
export interface AgentConfigCreatePayload {
  name: string;
  type: AgentType | string; // Allow string for flexibility, backend validates
  abilities?: string[];
  chains?: string[];
  parameters?: Record<string, any>;
  llm_config?: Record<string, any>;
  memory_config?: Record<string, any>;
  queue_config?: Record<string, any>;
  max_task_history?: number;
}

// Information returned when an agent is created or listed
export interface AgentInfo {
  id: string;
  name: string;
  type: AgentType | string; // Backend returns string representation of enum
  status: AgentStatus | string; // Backend returns string representation of enum
  created?: string; // ISO DateTime string
  updated?: string; // ISO DateTime string
}

// Detailed status of an agent (matches AgentHandlers.get_agent_status_handler response)
export interface AgentStatusDetail extends AgentInfo {
  uptime_seconds?: number;
  time_since_last_activity_seconds?: number;
  tasks_completed?: number; // Note: History might be capped
  queue_len?: number;
  memory_size?: number;
  last_error?: string | null;
  last_error_timestamp?: string | null;
}

// Payload for updating an agent (matches AgentHandlers.update_agent_handler expectations)
export interface AgentUpdatePayload {
  name?: string;
  config?: {
    parameters?: Record<string, any>;
    // Add other updatable config fields here if backend supports them
  };
}

// Response from agent lifecycle actions (start, stop, pause, resume)
export interface AgentLifecycleResponse {
  message: string;
  agent_id: string;
  new_status: AgentStatus | string;
}

// Payload for executing a task (matches AgentHandlers.execute_agent_task_handler expectations)
export interface TaskPayload {
  ability: string;
  mode?: 'direct' | 'queue'; // default "direct"
  priority?: number; // for queue mode
  [key: string]: any; // Allow other parameters for the ability
}

// Result of submitting a task (matches AgentHandlers.execute_agent_task_handler response)
export interface TaskSubmissionResult {
  success: boolean;
  queued?: boolean; // True if task was queued, false if direct (or not present)
  agent_id: string;
  task_id: string;
  queue_length?: number; // If queued
  // If direct and successful, may contain ability's output directly merged here
  [key: string]: any; 
}

// Summary of a task when listing tasks
export interface AgentTaskSummary {
  task_id: string;
  status: TaskStatus | string;
  submitted_time: string; // ISO DateTime string
  start_time?: string | null; // ISO DateTime string
  end_time?: string | null; // ISO DateTime string
  ability: string;
}

// Response when listing agent tasks
export interface ListAgentTasksResponse {
  success: boolean;
  agent_id: string;
  tasks: AgentTaskSummary[];
  count: number;
}

// Detailed result of a specific task (matches AgentHandlers.get_task_result_handler response)
export interface TaskExecutionResult {
  task_id: string;
  status: TaskStatus | string;
  submitted_time: string; // ISO DateTime string
  start_time?: string | null; // ISO DateTime string
  end_time?: string | null; // ISO DateTime string
  input: TaskPayload; // The original task input
  result?: any; // Output from the ability if successful
  error?: string | null; // Error message if failed or cancelled
}

// Response for memory operations
export interface AgentMemoryResponse {
  key: string;
  value: any;
}

export interface AgentMemorySetResponse {
  message: string;
  agent_id: string;
  key: string;
}

export interface AgentMemoryClearResponse {
  message: string;
  agent_id: string;
}

// Filters for listing agents
export interface AgentListFilters {
    type?: AgentType | string;
    status?: AgentStatus | string;
}

// Filters for listing tasks
export interface TaskListFilters {
    status_filter?: TaskStatus | string;
    limit?: number;
}

// For bulk delete operation
export interface BulkDeletePayload {
    agent_ids: string[];
}

export interface BulkDeleteResultItem {
    agent_id: string;
    success: boolean;
    message?: string;
    error?: string;
}
export interface BulkDeleteResponse {
    message: string;
    results: BulkDeleteResultItem[];
}
