defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour shared by every agent backend (Codex app-server, Claude Code stream-json, ...).

  AgentRunner talks to backends only through this contract. The session struct is
  opaque to the caller — backends use it to keep whatever live state they need
  (subprocess port, JSON-RPC pending requests, generated session UUID, ...).

  ## Required emitted events

  Backends MUST forward each runtime event through `on_message/1` so the
  orchestrator can update its in-memory snapshot and the dashboard can render
  progress. The canonical event set mirrors the Codex app-server protocol:

    * `:session_started` — first turn launched, includes `session_id`,
      `thread_id`, `turn_id`.
    * `:turn_completed` — turn ended successfully.
    * `:turn_failed` — turn ended with an error reason.
    * `:turn_cancelled` — turn was cancelled (timeout, kill, ...).
    * `:turn_ended_with_error` — orchestrator-side error after the turn.
    * `:tool_call_completed` / `:tool_call_failed` /
      `:unsupported_tool_call` — tool invocations.
    * `:approval_auto_approved` — auto-approval decision recorded.
    * `:turn_input_required` — agent asked for input we can't supply.
    * `:notification` — informational message (text chunk, status, ...).
    * `:other_message` / `:malformed` — diagnostic catch-alls.

  Token usage SHOULD be reported by including a `params` (or other)
  field that the orchestrator's `integrate_codex_update/2` can pick up.
  """

  @typedoc """
  Opaque per-session struct returned by `c:start_session/2` and threaded back
  into `c:run_turn/4` and `c:stop_session/1`.
  """
  @type session :: map()

  @typedoc """
  Per-turn handle returned to AgentRunner. Must include at least
  `:session_id`, `:thread_id`, `:turn_id`.
  """
  @type turn_session :: %{
          required(:session_id) => String.t(),
          required(:thread_id) => String.t(),
          required(:turn_id) => String.t(),
          optional(any) => any
        }

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(
              session :: session(),
              prompt :: String.t(),
              issue :: map(),
              opts :: keyword()
            ) :: {:ok, turn_session()} | {:error, term()}

  @callback stop_session(session :: session()) :: :ok

  @doc """
  Resolve the configured backend module from current settings.

  Defaults to Codex app-server (existing behaviour) so configurations that
  predate `agent.kind` keep working unchanged.
  """
  @spec resolve!() :: module()
  def resolve! do
    case SymphonyElixir.Config.settings!().agent.kind do
      "claude" -> SymphonyElixir.Claude.Backend
      "codex" -> SymphonyElixir.Codex.AppServer
      nil -> SymphonyElixir.Codex.AppServer
      other -> raise ArgumentError, "unsupported agent.kind: #{inspect(other)}"
    end
  end
end
