defmodule SymphonyElixir.Claude.EventMapper do
  @moduledoc """
  Translate Claude Code stream-json messages into the canonical event shape
  Symphony's orchestrator and dashboard expect.

  Claude's stream-json format produces objects with a top-level `"type"` that
  determines the rest of the schema. The mapper has three return shapes:

    * `{:emit, event_atom, payload}` — Forwarded to `on_message` as a single
      message. Most operational events use this.
    * `{:init, payload}` — Returned for `system/init`; the backend uses it to
      finalise the session header before re-emitting as a notification.
    * `{:result, payload}` — Returned for the terminal `result` event of a
      turn. The backend pulls `:status` to decide success vs. failure.
    * `:ignore` — Discarded entirely (e.g. `keep_alive`). The backend simply
      continues the receive loop.

  ## Token reporting

  The orchestrator's `extract_token_usage/1` walks several known paths to find
  a billable total. Claude's wire format puts caching numbers next to the
  generation totals, but Anthropic dashboards charge for `input_tokens +
  output_tokens` only — caching numbers are reported separately. The mapper
  therefore:

    * stores the raw `input/output/cache_creation/cache_read` map under
      `:usage` (no summing);
    * publishes the **billable** `input + output` total under both the
      Codex-compatible `params.msg.payload.info.total_token_usage` path *and*
      the legacy `params.tokenUsage.total` path so either consumer wins.

  Assistants that emit only tool calls (`output_tokens == 0`) flag
  `params.token_ready: false` so the dashboard can skip them when aggregating.

  ## Tool correlation

  When the assistant emits a `tool_use` block we register it with
  `ToolTracker.begin/2`; when the matching `tool_result` arrives we drain it
  with `ToolTracker.finish/1` so the result carries `tool_name` + `duration_ms`
  alongside the raw content.
  """

  alias SymphonyElixir.Claude.ToolTracker

  @type emitted ::
          {:emit, atom(), map()}
          | {:init, map()}
          | {:result, map()}
          | :ignore

  # --- top-level dispatch ---------------------------------------------------

  @spec map_event(term()) :: emitted()

  def map_event(%{"type" => "system", "subtype" => "init"} = msg) do
    {:init,
     %{
       claude_session_id: msg["session_id"],
       cwd: msg["cwd"],
       model: msg["model"],
       tools: msg["tools"]
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "api_retry"} = msg) do
    {:emit, :api_retry,
     %{
       attempt: msg["attempt"],
       max_retries: msg["max_retries"],
       retry_delay_ms: msg["retry_delay_ms"],
       error_status: msg["error_status"],
       error: msg["error"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "status"} = msg) do
    {:emit, :status_change,
     %{
       status: msg["status"],
       permissionMode: msg["permissionMode"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "compact_boundary"} = msg) do
    {:emit, :compact_boundary,
     %{
       trigger: msg["trigger"],
       pre_tokens: msg["pre_tokens"],
       post_tokens: msg["post_tokens"],
       duration_ms: msg["duration_ms"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "plugin_install"} = msg) do
    {:emit, :plugin_install,
     %{
       status: msg["status"],
       name: msg["name"],
       error: msg["error"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "notification"} = msg) do
    {:emit, :notification,
     %{
       key: msg["key"],
       text: msg["text"],
       priority: msg["priority"],
       source: "system",
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "files_persisted"} = msg) do
    {:emit, :files_persisted,
     %{
       files: msg["files"] || [],
       failed: msg["failed"] || [],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => subtype} = msg)
      when subtype in [
             "task_started",
             "task_progress",
             "task_updated",
             "task_notification"
           ] do
    {:emit, :task_event,
     msg
     |> Map.drop(["type", "subtype"])
     |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
     |> Map.put(:subtype, subtype)
     |> Map.put(:claude, msg)}
  end

  def map_event(%{"type" => "system", "subtype" => "session_state_changed"} = msg) do
    {:emit, :session_state_changed,
     %{
       state: msg["state"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => "mirror_error"} = msg) do
    {:emit, :other_message,
     %{
       type: "system",
       subtype: "mirror_error",
       claude: msg
     }}
  end

  def map_event(%{"type" => "system", "subtype" => subtype} = msg)
      when is_binary(subtype) do
    {:emit, :other_message,
     %{
       type: "system",
       subtype: subtype,
       claude: msg
     }}
  end

  # --- assistant ------------------------------------------------------------

  def map_event(%{"type" => "assistant", "message" => message} = msg) do
    register_tool_uses(message)

    usage = extract_usage(message)
    billable = billable_tokens(usage)
    token_ready = token_ready?(usage)

    {:emit, :notification,
     %{
       role: "assistant",
       text: extract_text(message),
       thinking: extract_thinking(message),
       tool_calls: extract_tool_calls(message),
       stop_reason: get_in(message, ["stop_reason"]),
       model: get_in(message, ["model"]),
       usage: usage,
       params: %{
         "msg" => %{
           "type" => "assistant_message",
           "tokens" => usage,
           "payload" => %{
             "info" => %{
               "total_token_usage" => %{
                 "input_tokens" => Map.get(usage, "input_tokens", 0),
                 "output_tokens" => Map.get(usage, "output_tokens", 0),
                 "total_tokens" => billable
               }
             }
           }
         },
         "tokenUsage" => %{"total" => billable},
         "token_ready" => token_ready
       },
       claude: msg
     }}
  end

  # --- user ----------------------------------------------------------------

  def map_event(%{"type" => "user", "message" => message} = msg) do
    {:emit, :notification,
     %{
       role: "user",
       text: extract_text(message),
       tool_results: extract_tool_results(message),
       claude: msg
     }}
  end

  # --- result --------------------------------------------------------------

  def map_event(%{"type" => "result", "subtype" => "success", "is_error" => true} = msg),
    do: {:result, build_result_failed(msg, "success_with_error")}

  def map_event(%{"type" => "result", "subtype" => "success"} = msg),
    do: {:result, build_result_success(msg)}

  def map_event(%{"type" => "result", "subtype" => subtype} = msg)
      when is_binary(subtype),
      do: {:result, build_result_failed(msg, subtype)}

  # --- streaming + auxiliary message types ---------------------------------

  def map_event(%{"type" => "stream_event"} = msg) do
    event = msg["event"] || %{}
    delta = event["delta"] || %{}

    {:emit, :stream_event,
     %{
       event_type: event["type"],
       content_index: event["index"] || msg["index"],
       delta_text: delta["text"],
       delta_thinking: delta["thinking"],
       delta_partial_json: delta["partial_json"],
       ttft_ms: msg["ttft_ms"] || event["ttft_ms"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "tool_progress"} = msg) do
    {:emit, :tool_progress,
     %{
       tool_use_id: msg["tool_use_id"],
       tool_name: msg["tool_name"],
       elapsed_time_seconds: msg["elapsed_time_seconds"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "tool_use_summary"} = msg) do
    {:emit, :tool_summary,
     %{
       summary: msg["summary"],
       preceding_tool_use_ids: msg["preceding_tool_use_ids"] || [],
       claude: msg
     }}
  end

  def map_event(%{"type" => "auth_status"} = msg) do
    {:emit, :auth_status,
     %{
       is_authenticating: msg["is_authenticating"],
       output: msg["output"],
       error: msg["error"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "rate_limit_event"} = msg) do
    info = msg["rate_limit_info"] || msg["rate_limits"] || %{}

    {:emit, :rate_limit_event,
     %{
       rate_limit_info: info,
       rate_limits: info,
       claude: msg
     }}
  end

  def map_event(%{"type" => "prompt_suggestion"} = msg) do
    {:emit, :prompt_suggestion,
     %{
       suggestion: msg["suggestion"],
       claude: msg
     }}
  end

  def map_event(%{"type" => "keep_alive"}), do: :ignore

  def map_event(%{"type" => type} = msg)
      when type in ["control_request", "control_response", "control_cancel_request"] do
    {:emit, :control_message,
     %{
       type: type,
       payload: Map.drop(msg, ["type"]),
       claude: msg
     }}
  end

  def map_event(%{"type" => type} = msg)
      when type in ["post_turn_summary", "task_summary", "transcript_mirror"] do
    {:emit, :other_message, %{type: type, claude: msg}}
  end

  def map_event(%{"type" => type} = msg) when is_binary(type) do
    {:emit, :other_message, %{type: type, claude: msg}}
  end

  def map_event(other) do
    {:emit, :other_message, %{claude: other}}
  end

  # --- result builders ------------------------------------------------------

  defp build_result_success(msg) do
    %{
      status: :success,
      duration_ms: msg["duration_ms"],
      duration_api_ms: msg["duration_api_ms"],
      num_turns: msg["num_turns"],
      total_cost_usd: msg["total_cost_usd"],
      usage: msg["usage"],
      model_usage: msg["modelUsage"] || %{},
      permission_denials: msg["permission_denials"] || [],
      stop_reason: msg["stop_reason"],
      terminal_reason: msg["terminal_reason"],
      result_text: msg["result"]
    }
  end

  defp build_result_failed(msg, subtype) do
    %{
      status: :failed,
      subtype: subtype,
      duration_ms: msg["duration_ms"],
      duration_api_ms: msg["duration_api_ms"],
      num_turns: msg["num_turns"],
      total_cost_usd: msg["total_cost_usd"],
      is_error: msg["is_error"] || false,
      api_error_status: msg["api_error_status"],
      errors: msg["errors"] || [],
      reason: error_reason(msg, subtype),
      usage: msg["usage"],
      model_usage: msg["modelUsage"] || %{},
      permission_denials: msg["permission_denials"] || [],
      stop_reason: msg["stop_reason"],
      terminal_reason: msg["terminal_reason"],
      result_text: msg["result"]
    }
  end

  defp error_reason(msg, fallback) do
    cond do
      is_binary(msg["error"]) and msg["error"] != "" ->
        msg["error"]

      is_list(msg["errors"]) and msg["errors"] != [] ->
        msg["errors"]
        |> Enum.map(&to_string/1)
        |> Enum.join("; ")

      true ->
        fallback
    end
  end

  # --- content extraction --------------------------------------------------

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_text(%{"content" => text}) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp extract_thinking(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "thinking", "thinking" => text} when is_binary(text) -> [text]
      %{"type" => "redacted_thinking"} -> ["[redacted]"]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_thinking(_), do: ""

  defp extract_tool_calls(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_use", "name" => name, "input" => input, "id" => id} ->
        [%{id: id, name: name, input: input}]

      _ ->
        []
    end)
  end

  defp extract_tool_calls(_), do: []

  defp register_tool_uses(%{"content" => content}) when is_list(content) do
    Enum.each(content, fn
      %{"type" => "tool_use", "id" => id, "name" => name}
      when is_binary(id) and is_binary(name) ->
        ToolTracker.begin(id, name)

      _ ->
        :ok
    end)
  end

  defp register_tool_uses(_), do: :ok

  defp extract_tool_results(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_result"} = block ->
        tid = block["tool_use_id"]
        is_error = Map.get(block, "is_error", false)
        stats = if is_binary(tid), do: ToolTracker.finish(tid), else: nil

        body =
          if is_error,
            do: stripped_content(block["content"]),
            else: raw_content(block["content"])

        [
          %{
            id: tid,
            is_error: is_error,
            content: body,
            tool_name: stats && stats.name,
            duration_ms: stats && stats.duration_ms
          }
        ]

      _ ->
        []
    end)
  end

  defp extract_tool_results(_), do: []

  defp raw_content(content) when is_binary(content), do: content

  defp raw_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_block_text/1)
    |> Enum.join("\n")
  end

  defp raw_content(_), do: ""

  defp extract_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_block_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_block_text(text) when is_binary(text), do: text
  defp extract_block_text(_), do: ""

  defp stripped_content(content) do
    text = raw_content(content)

    text
    |> String.replace(~r/<\/?tool_use_error>/, "")
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> truncate_long(2_048)
  end

  defp truncate_long(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_long(text, max_bytes) do
    lines = String.split(text, "\n")
    first_line = List.first(lines) || ""
    tail_len = max_bytes - byte_size(first_line) - 16

    tail =
      if tail_len > 0 and byte_size(text) > tail_len do
        binary_part(text, byte_size(text) - tail_len, tail_len)
      else
        ""
      end

    first_line <> "\n...\n" <> tail
  end

  # --- usage helpers --------------------------------------------------------

  defp extract_usage(%{"usage" => %{} = usage}) do
    %{
      "input_tokens" => Map.get(usage, "input_tokens", 0),
      "output_tokens" => Map.get(usage, "output_tokens", 0),
      "cache_creation_input_tokens" => Map.get(usage, "cache_creation_input_tokens", 0),
      "cache_read_input_tokens" => Map.get(usage, "cache_read_input_tokens", 0)
    }
  end

  defp extract_usage(_), do: %{}

  defp billable_tokens(%{} = usage) do
    Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
  end

  defp billable_tokens(_), do: 0

  defp token_ready?(%{} = usage) do
    Map.get(usage, "output_tokens", 0) > 0
  end

  defp token_ready?(_), do: false
end
