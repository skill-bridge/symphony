defmodule SymphonyElixir.Claude.ToolTracker do
  @moduledoc """
  Per-process registry that correlates tool_use ids with their tool_result so we
  can surface tool name + duration when results come back. Uses Process
  dictionary scoped to the calling AgentRunner task — same lifetime as
  ClaudeBackend's turn counter.

  ## Lifecycle

    * `begin/2` — Called when the assistant emits a `tool_use` content block.
    * `finish/1` — Called when the user echo emits the matching `tool_result`.
      Returns `%{name, duration_ms}` for the originally registered tool, or
      `nil` if the id was never seen (e.g. mirrored from a previous turn).
    * `clear/0` — Wipes the table; called between turns by the backend.
    * `stats/0` — Cheap introspection for tests/dashboard.

  Because we lean on the calling process's dictionary the table is automatically
  scoped to a single backend invocation; nothing is shared between concurrent
  runs.
  """

  @key {:__symphony_claude_tool_tracker__}

  @typedoc "Public summary returned by `finish/1`."
  @type tool_finish :: %{name: String.t(), duration_ms: integer()}

  @doc """
  Register a `tool_use` block as in-flight. Subsequent `finish/1` for the same
  id reports how long it took. Calling `begin/2` twice for the same id keeps
  the latest registration (last-write-wins) which matches Claude's behaviour
  when an event is replayed.
  """
  @spec begin(String.t(), String.t()) :: :ok
  def begin(tool_use_id, tool_name)
      when is_binary(tool_use_id) and is_binary(tool_name) do
    table = Process.get(@key, %{})

    Process.put(
      @key,
      Map.put(table, tool_use_id, %{
        name: tool_name,
        started_at: System.monotonic_time(:millisecond)
      })
    )

    :ok
  end

  @doc """
  Look up and remove the in-flight entry for `tool_use_id`. Returns
  `%{name, duration_ms}` on success, `nil` when the id isn't tracked.
  """
  @spec finish(String.t()) :: tool_finish() | nil
  def finish(tool_use_id) when is_binary(tool_use_id) do
    table = Process.get(@key, %{})

    case Map.pop(table, tool_use_id) do
      {nil, _} ->
        nil

      {%{name: name, started_at: started}, rest} ->
        Process.put(@key, rest)
        %{name: name, duration_ms: System.monotonic_time(:millisecond) - started}
    end
  end

  @doc "Drop every in-flight entry. Safe to call when nothing is registered."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "Snapshot of how many entries are currently tracked."
  @spec stats() :: %{in_flight: non_neg_integer()}
  def stats do
    %{in_flight: Process.get(@key, %{}) |> map_size()}
  end
end
