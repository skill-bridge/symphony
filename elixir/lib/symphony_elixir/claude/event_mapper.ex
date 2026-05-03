defmodule SymphonyElixir.Claude.EventMapper do
  @moduledoc """
  Translate Claude Code stream-json messages into the canonical event shape
  Symphony's orchestrator and dashboard expect.

  Claude's stream-json format produces objects with a top-level `"type"` that
  determines the rest of the schema. We map the most common ones:

    * `system / init` → returns an internal `{:init, %{session_id, ...}}`
      so the backend can finalise its session header.
    * `assistant`     → `:notification` carrying the assistant text chunk and
      any token-usage block we can extract.
    * `user`          → `:notification` (echoed back, includes tool_result).
    * `tool_use`      → `:notification` so the dashboard sees in-progress work.
    * `result`        → `:turn_completed` (subtype `success`) or
      `:turn_failed` (subtype `error_*`).

  Anything we don't recognise is funneled through `:other_message`.
  """

  @type emitted ::
          {:emit, atom(), map()}
          | {:init, map()}
          | {:result, map()}
          | :ignore

  @spec map_event(map()) :: emitted()
  def map_event(%{"type" => "system", "subtype" => "init"} = msg) do
    {:init,
     %{
       claude_session_id: msg["session_id"],
       cwd: msg["cwd"],
       model: msg["model"],
       tools: msg["tools"]
     }}
  end

  def map_event(%{"type" => "assistant", "message" => message} = msg) do
    {:emit, :notification,
     %{
       role: "assistant",
       text: extract_text(message),
       tool_calls: extract_tool_calls(message),
       params: %{
         "msg" => %{
           "type" => "assistant_message",
           "tokens" => extract_usage(message)
         },
         "tokenUsage" => %{
           "total" => total_tokens(extract_usage(message))
         }
       },
       claude: msg
     }}
  end

  def map_event(%{"type" => "user", "message" => message} = msg) do
    {:emit, :notification,
     %{
       role: "user",
       text: extract_text(message),
       tool_results: extract_tool_results(message),
       claude: msg
     }}
  end

  def map_event(%{"type" => "result", "subtype" => "success"} = msg) do
    {:result,
     %{
       status: :success,
       duration_ms: msg["duration_ms"],
       num_turns: msg["num_turns"],
       total_cost_usd: msg["total_cost_usd"],
       usage: msg["usage"],
       result_text: msg["result"]
     }}
  end

  def map_event(%{"type" => "result", "subtype" => subtype} = msg)
      when is_binary(subtype) do
    {:result,
     %{
       status: :failed,
       subtype: subtype,
       duration_ms: msg["duration_ms"],
       reason: msg["error"] || subtype,
       usage: msg["usage"]
     }}
  end

  def map_event(%{"type" => type} = msg) when is_binary(type) do
    {:emit, :other_message, %{type: type, claude: msg}}
  end

  def map_event(other) do
    {:emit, :other_message, %{claude: other}}
  end

  # --- helpers -------------------------------------------------------------

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

  defp extract_tool_calls(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_use", "name" => name, "input" => input, "id" => id} ->
        [%{id: id, name: name, input: input}]

      _ ->
        []
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_tool_results(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_result"} = block ->
        [
          %{
            id: block["tool_use_id"],
            is_error: Map.get(block, "is_error", false),
            content: block["content"]
          }
        ]

      _ ->
        []
    end)
  end

  defp extract_tool_results(_), do: []

  defp extract_usage(%{"usage" => %{} = usage}) do
    %{
      "input_tokens" => Map.get(usage, "input_tokens", 0),
      "output_tokens" => Map.get(usage, "output_tokens", 0),
      "cache_creation_input_tokens" => Map.get(usage, "cache_creation_input_tokens", 0),
      "cache_read_input_tokens" => Map.get(usage, "cache_read_input_tokens", 0)
    }
  end

  defp extract_usage(_), do: %{}

  defp total_tokens(%{} = usage) do
    Map.get(usage, "input_tokens", 0) +
      Map.get(usage, "output_tokens", 0) +
      Map.get(usage, "cache_creation_input_tokens", 0) +
      Map.get(usage, "cache_read_input_tokens", 0)
  end

  defp total_tokens(_), do: 0
end
