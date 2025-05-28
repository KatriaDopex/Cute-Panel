# julia/src/agents/AgentCore.jl
module AgentCore

using ..Config
export Agent, AgentConfig, AgentStatus, AgentType,
       AbstractAgentMemory, AbstractAgentQueue, AbstractLLMIntegration, AGENTS_LOCK, ABILITY_REGISTRY, register_ability, AGENTS

using UUIDs, Dates
using DataStructures

# ----------------------------------------------------------------------
# CONSTANTS
# ----------------------------------------------------------------------
const MAX_TASK_HISTORY = Config.get_config("agent.max_task_history", 100)

# ----------------------------------------------------------------------
# SCHEDULE TYPE
# ----------------------------------------------------------------------
abstract type Schedule end

# ----------------------------------------------------------------------
# ENUMS
# ----------------------------------------------------------------------
@enum AgentType begin
    TRADING = 1; MONITOR = 2; ARBITRAGE = 3; DATA_COLLECTION = 4;
    NOTIFICATION = 5; CUSTOM = 99; DEV = 100 # Added DEV type
end

@enum AgentStatus begin
    CREATED = 1; INITIALIZING = 2; RUNNING = 3;
    PAUSED = 4; STOPPED = 5; ERROR = 6
end

@enum TaskStatus begin
    TASK_PENDING = 1
    TASK_RUNNING = 2
    TASK_COMPLETED = 3
    TASK_FAILED = 4
    TASK_CANCELLED = 5
    TASK_UNKNOWN = 99 # For loading potentially old/corrupt data
end

# ----------------------------------------------------------------------
# SKILL ENGINE (Registry defined here, processing logic in agent loop)
# ----------------------------------------------------------------------
# Schedule Struct for Advanced Scheduling is defined above

"""
    Skill

Represents a scheduled skill an agent can perform.

# Fields
- `name::String`: Skill name
- `fn::Function`: The Julia function implementing the skill logic
- `schedule::Union{Schedule, Nothing}`: The scheduling definition (nothing for on-demand only)
"""
struct Skill
    name::String
    fn::Function
    schedule::Union{Schedule, Nothing} # Use the new Schedule type
end

"""
    SkillState

Mutable state associated with an agent's skill.

# Fields
- `skill::Skill`: The skill definition
- `xp::Float64`: Experience points for the skill
- `last_exec::DateTime`: Timestamp of the last execution
"""
mutable struct SkillState
    skill::Skill
    xp::Float64
    last_exec::DateTime
end

# ----------------------------------------------------------------------
# ABSTRACT TYPES for Pluggability (NEW)
# ----------------------------------------------------------------------
"""
    AbstractAgentMemory

Abstract type for agent memory implementations.
Concrete types must implement:
- `get_value(mem::AbstractAgentMemory, key::String)`
- `set_value!(mem::AbstractAgentMemory, key::String, val)`
- `delete_value!(mem::AbstractAgentMemory, key::String)`
- `clear!(mem::AbstractAgentMemory)`
- `length(mem::AbstractAgentMemory)`
- `keys(mem::AbstractAgentMemory)`
"""
abstract type AbstractAgentMemory end

"""
    AbstractAgentQueue

Abstract type for agent task queue implementations.
Concrete types must implement:
- `enqueue!(q::AbstractAgentQueue, item, priority::Real)`
- `dequeue!(q::AbstractAgentQueue)`
- `peek(q::AbstractAgentQueue)`
- `isempty(q::AbstractAgentQueue)`
- `length(q::AbstractAgentQueue)`
"""
abstract type AbstractAgentQueue end

"""
    AbstractLLMIntegration

Abstract type for LLM integration implementations.
Concrete types must implement:
- `chat(llm::AbstractLLMIntegration, prompt::String; cfg::Dict)`
"""
abstract type AbstractLLMIntegration end

# ----------------------------------------------------------------------
# DEFAULT PLUGGABLE IMPLEMENTATIONS
# ----------------------------------------------------------------------
# Example Default Memory: OrderedDict Memory
struct OrderedDictAgentMemory <: AbstractAgentMemory
    data::OrderedDict{String, Any}
    max_size::Int
end
# Implement AbstractAgentMemory interface for OrderedDictAgentMemory
get_value(mem::OrderedDictAgentMemory, key::String) = get(mem.data, key, nothing)
set_value!(mem::OrderedDictAgentMemory, key::String, val) = (mem.data[key] = val; _touch!(mem.data, key); _enforce_lru_size!(mem)) # Need helper for size
delete_value!(mem::OrderedDictAgentMemory, key::String) = delete!(mem.data, key)
clear!(mem::OrderedDictAgentMemory) = empty!(mem.data)
Base.length(mem::OrderedDictAgentMemory) = length(mem.data)
Base.keys(mem::OrderedDictAgentMemory) = keys(mem.data)
_touch!(mem::OrderedDict{String,Any}, key) = (val = mem[key]; delete!(mem,key); mem[key] = val) # Helper for LRU
_enforce_lru_size!(mem::OrderedDictAgentMemory) = while length(mem.data) > mem.max_size; popfirst!(mem.data); end # Helper for size limit

# Example Default Queue: Priority Queue
struct PriorityAgentQueue <: AbstractAgentQueue
    queue::PriorityQueue{Any, Float64} # Stores task_ids
end
# Implement AbstractAgentQueue interface for PriorityAgentQueue
DataStructures.enqueue!(q::PriorityAgentQueue, item, priority::Real) = enqueue!(q.queue, item, priority)
DataStructures.dequeue!(q::PriorityAgentQueue) = dequeue!(q.queue)
DataStructures.peek(q::PriorityAgentQueue) = peek(q.queue)
Base.isempty(q::PriorityAgentQueue) = isempty(q.queue)
Base.length(q::PriorityAgentQueue) = length(q.queue)

# # Example Default LLM Integration (Uses LLMIntegration module)
# struct DefaultLLMIntegration <: AbstractLLMIntegration
#     # Could store config or other state here if needed
# end
# # Implement AbstractLLMIntegration interface
# LLMIntegration.chat(llm::DefaultLLMIntegration, prompt::String; cfg::Dict) = LLMIntegration.chat(prompt; cfg=cfg)

# ----------------------------------------------------------------------
# CONFIG STRUCT
# ----------------------------------------------------------------------
"""
    AgentConfig

Configuration for creating a new agent.

# Fields
- `name::String`: Agent name
- `type::AgentType`: Agent type (enum)
- `abilities::Vector{String}`: List of ability names this agent type can perform
- `chains::Vector{String}`: List of chain names this agent type can execute
- `parameters::Dict{String,Any}`: Agent-specific parameters
- `llm_config::Dict{String,Any}`: Configuration for the LLM provider (can specify implementation type)
- `memory_config::Dict{String,Any}`: Configuration for agent memory (can specify implementation type)
- `queue_config::Dict{String,Any}`: Configuration for agent queue (can specify implementation type) (NEW)
- `max_task_history::Int`: Maximum number of tasks to keep in history
"""
struct AgentConfig
    name::String
    type::AgentType
    abilities::Vector{String}
    chains::Vector{String}
    parameters::Dict{String,Any}
    llm_config::Dict{String,Any}
    memory_config::Dict{String,Any}
    queue_config::Dict{String,Any} # NEW: Queue config
    max_task_history::Int

    function AgentConfig(name::String, type::AgentType;
                         abilities::Vector{String}=String[], chains::Vector{String}=String[],
                         parameters::Dict{String,Any}=Dict(),
                         llm_config::Dict{String,Any}=Dict(),
                         memory_config::Dict{String,Any}=Dict(),
                         queue_config::Dict{String,Any}=Dict(), # NEW: Default queue config
                         max_task_history::Int=MAX_TASK_HISTORY)
        isempty(llm_config) && (llm_config = Dict("provider"=>"openai","model"=>"gpt-4o-mini","temperature"=>0.7,"max_tokens"=>1024))
        isempty(memory_config) && (memory_config = Dict("type"=>"ordered_dict","max_size"=>1000,"retention_policy"=>"lru")) # Added default type
        isempty(queue_config) && (queue_config = Dict("type"=>"priority_queue")) # NEW: Default queue type
        new(name, type, abilities, chains, parameters, llm_config, memory_config, queue_config, max_task_history)
    end
end

"""
    TaskResult

Holds the lifecycle info and outcome of a single agent task.

# Fields
- `task_id::String`               – unique identifier for this task  
- `status::TaskStatus`            – current lifecycle status  
- `submitted::DateTime`           – when the task was enqueued  
- `start_time::Union{DateTime,Nothing}`    – when execution began (nothing if never started)
- `end_time::Union{DateTime,Nothing}`   – when execution ended (nothing if still pending/running)
- `output_result::Any`                   – the returned value on success (or partial output)
- `error_details::Union{String,Nothing}`  – error message if the task failed, else `nothing`
"""
mutable struct TaskResult
    task_id::String
    status::TaskStatus
    submitted::DateTime
    start_time::Union{DateTime, Nothing}
    end_time::Union{DateTime, Nothing}
    output_result::Any
    error_details::Union{Exception, Nothing}

    function TaskResult(task_id::String; 
                        status::TaskStatus=TASK_PENDING,
                        submitted::DateTime=now(),
                        start_time::Union{DateTime,Nothing}=nothing,
                        end_time::Union{DateTime,Nothing}=nothing,
                        output_result::Any=nothing,
                        error_details::Union{Exception,Nothing}=nothing)
        new(task_id, status, submitted, start_time, end_time, output_result, error_details)
    end
end

# ----------------------------------------------------------------------
# MAIN AGENT STRUCTURE
# ----------------------------------------------------------------------
"""
    Agent

Represents an autonomous agent instance.

# Fields
- `id::String`: Unique agent ID
- `name::String`: Agent name
- `type::AgentType`: Agent type
- `status::AgentStatus`: Current status
- `created::DateTime`: Creation timestamp
- `updated::DateTime`: Last update timestamp (reflects status/config changes)
- `config::AgentConfig`: Agent configuration
- `memory::AbstractAgentMemory`: Agent memory implementation (NEW: Abstract Type)
- `task_history::Vector{Dict{String,Any}}`: History of completed tasks (capped)
- `skills::Dict{String,SkillState}`: State of registered skills
- `queue::AbstractAgentQueue`: Agent task queue implementation (NEW: Abstract Type)
- `task_results::Dict{String, TaskResult}`: Dictionary to track submitted tasks by ID (NEW)
- `llm_integration::Union{AbstractLLMIntegration, Nothing}`: LLM integration instance (NEW: Abstract Type)
- `swarm_connection::Any`: Swarm connection object (type depends on backend) (Moved from Swarm module concept)
- `lock::ReentrantLock`: Lock for protecting mutable agent state (NEW)
- `condition::Condition`: Condition variable for signaling the agent loop (NEW)
- `last_error::Union{Exception, Nothing}`: The last error encountered (NEW)
- `last_error_timestamp::Union{DateTime, Nothing}`: Timestamp of the last error (NEW)
- `last_activity::DateTime`: Timestamp of the last significant activity (NEW)
"""
mutable struct Agent
    id::String; name::String; type::AgentType; status::AgentStatus
    created::DateTime; updated::DateTime; config::AgentConfig
    memory::AbstractAgentMemory          # LRU memory (NEW: Abstract Type)
    task_history::Vector{Dict{String,Any}}
    skills::Dict{String,SkillState}
    queue::AbstractAgentQueue        # message queue (stores task_ids) (NEW: Abstract Type)
    task_results::Dict{String, TaskResult} # NEW: Dictionary to track tasks by ID
    llm_integration::Union{AbstractLLMIntegration, Nothing} # NEW: LLM instance
    swarm_connection::Any # Swarm connection object (type depends on backend) (NEW)
    lock::ReentrantLock                      # NEW: Lock for protecting mutable state
    condition::Condition                     # NEW: Condition variable for signaling loop
    last_error::Union{Exception, Nothing}    # NEW: Last error object
    last_error_timestamp::Union{DateTime, Nothing} # NEW: Timestamp of last error
    last_activity::DateTime                  # NEW: Timestamp of last activity
end

# ----------------------------------------------------------------------
# GLOBAL REGISTRIES & AGENT STORAGE
# ----------------------------------------------------------------------
const AGENTS          = Dict{String,Agent}() # Global dictionary of agents
const AGENT_THREADS = Dict{String,Task}() # Map agent ID to its running task
const ABILITY_REGISTRY = Dict{String,Function}() # Global registry of ability functions
const AGENTS_LOCK     = ReentrantLock() # Lock for concurrent access to AGENTS dict and AGENT_THREADS

# ----------------------------------------------------------------------
# ABILITY REGISTRY (Definition here, registration function above) ------
# ----------------------------------------------------------------------
# register_ability function is defined above

"""
    register_ability(name::String, fn::Function)

Registers a function under a given name in the global ABILITY_REGISTRY.
"""
function register_ability(name::String, fn::Function)
    lock(AGENTS_LOCK) do
        ABILITY_REGISTRY[name] = fn
    end
end

end # module AgentCore
