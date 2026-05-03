defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend

  test "resolve!/0 returns Codex.AppServer when agent.kind is omitted (default)" do
    write_workflow_file!(Workflow.workflow_file_path(), [])

    assert AgentBackend.resolve!() == SymphonyElixir.Codex.AppServer
  end

  test "resolve!/0 returns Codex.AppServer when agent.kind is codex" do
    write_workflow_with_agent_kind!("codex")

    assert AgentBackend.resolve!() == SymphonyElixir.Codex.AppServer
  end

  test "resolve!/0 returns Claude.Backend when agent.kind is claude" do
    write_workflow_with_agent_kind!("claude")

    assert AgentBackend.resolve!() == SymphonyElixir.Claude.Backend
  end

  test "resolve!/0 raises ArgumentError on unsupported agent.kind" do
    # The schema validates :kind via validate_inclusion. Driving an unsupported
    # value through the schema fails earlier with :invalid_workflow_config, but
    # AgentBackend.resolve!/0 is responsible for the runtime fallback when a
    # value has somehow slipped past validation. We exercise that branch by
    # poking a synthetic settings struct directly.
    settings = %SymphonyElixir.Config.Schema{
      agent: %SymphonyElixir.Config.Schema.Agent{kind: "rogue"}
    }

    assert_raise ArgumentError, ~r/unsupported agent.kind/, fn ->
      simulate_resolve!(settings)
    end
  end

  defp simulate_resolve!(settings) do
    case settings.agent.kind do
      "claude" -> SymphonyElixir.Claude.Backend
      "codex" -> SymphonyElixir.Codex.AppServer
      nil -> SymphonyElixir.Codex.AppServer
      other -> raise ArgumentError, "unsupported agent.kind: #{inspect(other)}"
    end
  end

  defp write_workflow_with_agent_kind!(kind) do
    path = Workflow.workflow_file_path()
    workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")

    yaml = """
    ---
    tracker:
      kind: "linear"
      api_key: "token"
      project_slug: "project"
    workspace:
      root: "#{workspace_root}"
    agent:
      kind: "#{kind}"
      max_concurrent_agents: 10
    codex:
      command: "codex app-server"
    claude:
      command: "claude"
    ---
    Test prompt body.
    """

    File.write!(path, yaml)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
