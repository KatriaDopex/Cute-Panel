using Pkg
Pkg.activate(".")

using DotEnv
DotEnv.load!()

using CutePanel

function main()
    cfg = CutePanel.CutePanelFramework.AgentCore.AgentConfig(
        "TestAgent",
        CutePanel.CutePanelFramework.AgentCore.CUSTOM;
        abilities=["ping"],
        parameters=Dict{String, Any}("demo" => true),
        llm_config=Dict{String, Any}(),
        memory_config=Dict{String, Any}(),
        queue_config=Dict{String, Any}(), 
    )
    
    # create agent
    agent = CutePanel.CutePanelFramework.Agents.createAgent(cfg)
    @info "Agent $(agent.id) created successfully"
    println()

    # start agent
    is_started = CutePanel.CutePanelFramework.Agents.startAgent(agent.id)
    @info "Agent $(agent.id) started successfully"
    println()

    # pause agent
    is_paused = CutePanel.CutePanelFramework.Agents.pauseAgent(agent.id)
    @info "Agent $(agent.id) paused successfully"
    println()

    # get agent status
    status = CutePanel.CutePanelFramework.Agents.getAgentStatus(agent.id)
    @show status
    println()

    # resume agent
    is_resumed = CutePanel.CutePanelFramework.Agents.resumeAgent(agent.id)
    @info "Agent $(agent.id) resumed successfully"
    println()

    # execute ping task
    result = CutePanel.CutePanelFramework.Agents.executeAgentTask(agent.id, Dict{String, Any}("ability" => "ping"))
    @show result
    println()

    # execute llm chat task
    result = CutePanel.CutePanelFramework.Agents.executeAgentTask(agent.id, Dict{String, Any}("ability" => "llm_chat", "prompt" => "how are you?"))
    @show result
    println()

    # stop agent
    is_stopped = CutePanel.CutePanelFramework.Agents.stopAgent(agent.id)
    @info "Agent $(agent.id) stopped successfully"
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end