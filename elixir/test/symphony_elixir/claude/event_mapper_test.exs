defmodule SymphonyElixir.Claude.EventMapperTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.{EventMapper, ToolTracker}

  setup do
    ToolTracker.clear()
    :ok
  end

  # --- system events --------------------------------------------------------

  test "system/init returns an :init tuple with session metadata" do
    raw = %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => "sess-1",
      "cwd" => "/tmp/work",
      "model" => "claude-opus-4-7",
      "tools" => ["Read", "Edit"]
    }

    assert {:init, payload} = EventMapper.map_event(raw)

    assert payload == %{
             claude_session_id: "sess-1",
             cwd: "/tmp/work",
             model: "claude-opus-4-7",
             tools: ["Read", "Edit"]
           }
  end

  test "system/api_retry surfaces attempt + retry metadata" do
    raw = %{
      "type" => "system",
      "subtype" => "api_retry",
      "attempt" => 2,
      "max_retries" => 5,
      "retry_delay_ms" => 1000,
      "error_status" => 529,
      "error" => "overloaded"
    }

    assert {:emit, :api_retry, payload} = EventMapper.map_event(raw)
    assert payload.attempt == 2
    assert payload.max_retries == 5
    assert payload.retry_delay_ms == 1000
    assert payload.error_status == 529
    assert payload.error == "overloaded"
    assert payload.claude == raw
  end

  test "system/status emits a :status_change event with permissionMode" do
    raw = %{
      "type" => "system",
      "subtype" => "status",
      "status" => "running",
      "permissionMode" => "acceptEdits"
    }

    assert {:emit, :status_change, payload} = EventMapper.map_event(raw)
    assert payload.status == "running"
    assert payload.permissionMode == "acceptEdits"
  end

  test "system/compact_boundary forwards trigger and pre/post token counts" do
    raw = %{
      "type" => "system",
      "subtype" => "compact_boundary",
      "trigger" => "auto",
      "pre_tokens" => 90_000,
      "post_tokens" => 18_000,
      "duration_ms" => 1234
    }

    assert {:emit, :compact_boundary, payload} = EventMapper.map_event(raw)
    assert payload.trigger == "auto"
    assert payload.pre_tokens == 90_000
    assert payload.post_tokens == 18_000
    assert payload.duration_ms == 1234
  end

  test "system/plugin_install emits :plugin_install with status + name" do
    raw = %{
      "type" => "system",
      "subtype" => "plugin_install",
      "status" => "ok",
      "name" => "linear",
      "error" => nil
    }

    assert {:emit, :plugin_install, payload} = EventMapper.map_event(raw)
    assert payload.status == "ok"
    assert payload.name == "linear"
  end

  test "system/notification carries key/text/priority and tags source=system" do
    raw = %{
      "type" => "system",
      "subtype" => "notification",
      "key" => "permission_required",
      "text" => "Approve write?",
      "priority" => "high"
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert payload.key == "permission_required"
    assert payload.text == "Approve write?"
    assert payload.priority == "high"
    assert payload.source == "system"
  end

  test "system/files_persisted normalises files + failed lists" do
    raw = %{
      "type" => "system",
      "subtype" => "files_persisted",
      "files" => ["a.txt", "b.txt"],
      "failed" => []
    }

    assert {:emit, :files_persisted, payload} = EventMapper.map_event(raw)
    assert payload.files == ["a.txt", "b.txt"]
    assert payload.failed == []
  end

  test "system/task_* subtypes funnel into a single :task_event with subtype" do
    raw = %{
      "type" => "system",
      "subtype" => "task_progress",
      "task_id" => "T1",
      "progress" => 0.5
    }

    assert {:emit, :task_event, payload} = EventMapper.map_event(raw)
    assert payload.subtype == "task_progress"
    assert payload[:task_id] == "T1"
    assert payload[:progress] == 0.5
    assert payload.claude == raw
  end

  test "system/session_state_changed forwards the new state" do
    raw = %{
      "type" => "system",
      "subtype" => "session_state_changed",
      "state" => "idle"
    }

    assert {:emit, :session_state_changed, payload} = EventMapper.map_event(raw)
    assert payload.state == "idle"
  end

  test "system/mirror_error → :other_message" do
    raw = %{"type" => "system", "subtype" => "mirror_error", "detail" => "oops"}
    assert {:emit, :other_message, payload} = EventMapper.map_event(raw)
    assert payload.subtype == "mirror_error"
    assert payload.type == "system"
  end

  test "unknown system subtype falls through to :other_message" do
    raw = %{"type" => "system", "subtype" => "ninja_subtype", "x" => 1}
    assert {:emit, :other_message, payload} = EventMapper.map_event(raw)
    assert payload.type == "system"
    assert payload.subtype == "ninja_subtype"
    assert payload.claude == raw
  end

  # --- assistant ------------------------------------------------------------

  test "assistant message becomes a notification with text and tool_calls" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "hello"},
          %{"type" => "text", "text" => "world"},
          %{
            "type" => "tool_use",
            "id" => "tu-1",
            "name" => "Read",
            "input" => %{"path" => "/tmp/x"}
          }
        ]
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)

    assert payload.role == "assistant"
    assert payload.text == "hello\nworld"

    assert payload.tool_calls == [
             %{id: "tu-1", name: "Read", input: %{"path" => "/tmp/x"}}
           ]

    assert payload.claude == raw

    assert get_in(payload.params, ["msg", "type"]) == "assistant_message"
    assert get_in(payload.params, ["msg", "tokens"]) == %{}
    assert get_in(payload.params, ["tokenUsage", "total"]) == 0
  end

  test "assistant message keeps cache fields separate and reports billable input+output only" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "cache_creation_input_tokens" => 5,
          "cache_read_input_tokens" => 7
        }
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)

    # raw usage keeps every bucket
    assert payload.usage == %{
             "input_tokens" => 10,
             "output_tokens" => 20,
             "cache_creation_input_tokens" => 5,
             "cache_read_input_tokens" => 7
           }

    # billable total is input + output ONLY (cache fields are not billed twice)
    assert get_in(payload.params, ["tokenUsage", "total"]) == 30

    # Codex-compatible deep path also exposes the billable total
    info = get_in(payload.params, ["msg", "payload", "info", "total_token_usage"])
    assert info["input_tokens"] == 10
    assert info["output_tokens"] == 20
    assert info["total_tokens"] == 30
  end

  test "assistant params include both Codex-compatible and legacy total paths" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)

    # Codex path
    assert get_in(payload.params, ["msg", "payload", "info", "total_token_usage", "total_tokens"]) ==
             7

    # legacy path
    assert get_in(payload.params, ["tokenUsage", "total"]) == 7
  end

  test "assistant token_ready=false when output_tokens is zero" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "tool_use", "id" => "tu-z", "name" => "Read", "input" => %{}}
        ],
        "usage" => %{"input_tokens" => 100, "output_tokens" => 0}
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert get_in(payload.params, ["token_ready"]) == false
  end

  test "assistant token_ready=true when output_tokens > 0" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 9}
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert get_in(payload.params, ["token_ready"]) == true
  end

  test "assistant message extracts thinking content blocks" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "thinking", "thinking" => "let me consider"},
          %{"type" => "text", "text" => "answer"}
        ]
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert payload.thinking == "let me consider"
    assert payload.text == "answer"
  end

  test "assistant message with redacted_thinking keeps a placeholder" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "redacted_thinking"}, %{"type" => "text", "text" => "hi"}]
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert payload.thinking == "[redacted]"
  end

  test "assistant message exposes stop_reason and model" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "x"}],
        "stop_reason" => "end_turn",
        "model" => "claude-opus-4-7"
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert payload.stop_reason == "end_turn"
    assert payload.model == "claude-opus-4-7"
  end

  test "assistant message with string content collapses into text" do
    raw = %{
      "type" => "assistant",
      "message" => %{"content" => "plain string body"}
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert payload.text == "plain string body"
    assert payload.tool_calls == []
  end

  # --- tool correlation through ToolTracker ---------------------------------

  test "tool_use registration is picked up by the matching tool_result" do
    assistant = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu-7",
            "name" => "Bash",
            "input" => %{"command" => "ls"}
          }
        ]
      }
    }

    {:emit, :notification, _} = EventMapper.map_event(assistant)
    Process.sleep(2)

    user = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tu-7",
            "content" => "out"
          }
        ]
      }
    }

    {:emit, :notification, payload} = EventMapper.map_event(user)
    assert [%{tool_name: "Bash", duration_ms: dur, content: "out"}] = payload.tool_results
    assert is_integer(dur) and dur >= 0
  end

  test "tool_result without prior tool_use leaves tool_name nil" do
    user = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tu-orphan",
            "content" => "stale"
          }
        ]
      }
    }

    {:emit, :notification, payload} = EventMapper.map_event(user)
    assert [%{tool_name: nil, duration_ms: nil, content: "stale", id: "tu-orphan"}] = payload.tool_results
  end

  test "tool_result is_error=true strips ANSI + tool_use_error envelope" do
    body = "<tool_use_error>\e[31merr 1\nerr 2\e[0m</tool_use_error>"

    user = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tu-err",
            "is_error" => true,
            "content" => body
          }
        ]
      }
    }

    {:emit, :notification, payload} = EventMapper.map_event(user)
    [%{content: stripped, is_error: true}] = payload.tool_results
    refute String.contains?(stripped, "tool_use_error")
    refute String.contains?(stripped, "\e[")
    assert String.contains?(stripped, "err 1")
    assert String.contains?(stripped, "err 2")
  end

  test "tool_result with content list joins block text" do
    user = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tu-list",
            "content" => [
              %{"type" => "text", "text" => "line1"},
              %{"type" => "text", "text" => "line2"}
            ]
          }
        ]
      }
    }

    {:emit, :notification, payload} = EventMapper.map_event(user)
    [%{content: text}] = payload.tool_results
    assert text == "line1\nline2"
  end

  test "user message defaults is_error to false when missing" do
    raw = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "tu-3", "content" => "ok"}
        ]
      }
    }

    assert {:emit, :notification, payload} = EventMapper.map_event(raw)
    assert [%{id: "tu-3", is_error: false, content: "ok"}] = payload.tool_results
  end

  # --- result events --------------------------------------------------------

  test "result/success becomes a {:result, success} tuple with all metadata" do
    raw = %{
      "type" => "result",
      "subtype" => "success",
      "duration_ms" => 1234,
      "duration_api_ms" => 999,
      "num_turns" => 3,
      "total_cost_usd" => 0.0123,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 2},
      "modelUsage" => %{"claude-opus-4-7" => %{"inputTokens" => 1, "outputTokens" => 2}},
      "permission_denials" => [],
      "stop_reason" => "end_turn",
      "terminal_reason" => nil,
      "result" => "all done"
    }

    assert {:result, payload} = EventMapper.map_event(raw)
    assert payload.status == :success
    assert payload.duration_ms == 1234
    assert payload.duration_api_ms == 999
    assert payload.num_turns == 3
    assert payload.total_cost_usd == 0.0123
    assert payload.usage == %{"input_tokens" => 1, "output_tokens" => 2}
    assert payload.model_usage == %{"claude-opus-4-7" => %{"inputTokens" => 1, "outputTokens" => 2}}
    assert payload.permission_denials == []
    assert payload.stop_reason == "end_turn"
    assert payload.result_text == "all done"
  end

  test "result/success but is_error=true downgrades to :failed with reason success_with_error" do
    raw = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "duration_ms" => 50,
      "errors" => ["auth_failed"],
      "result" => "n/a"
    }

    assert {:result, payload} = EventMapper.map_event(raw)
    assert payload.status == :failed
    assert payload.subtype == "success_with_error"
    assert payload.is_error == true
    assert payload.errors == ["auth_failed"]
    # reason picks up errors[] when present
    assert payload.reason == "auth_failed"
  end

  test "result/error_max_turns becomes a {:result, failed} tuple" do
    raw = %{
      "type" => "result",
      "subtype" => "error_max_turns",
      "duration_ms" => 99,
      "error" => nil,
      "usage" => %{"output_tokens" => 5}
    }

    assert {:result, payload} = EventMapper.map_event(raw)
    assert payload.status == :failed
    assert payload.subtype == "error_max_turns"
    assert payload.duration_ms == 99
    assert payload.reason == "error_max_turns"
    assert payload.usage == %{"output_tokens" => 5}
    # default-empty fields
    assert payload.errors == []
    assert payload.permission_denials == []
    assert payload.model_usage == %{}
  end

  test "result/error_max_budget_usd uses the subtype as the reason fallback" do
    raw = %{"type" => "result", "subtype" => "error_max_budget_usd"}
    assert {:result, %{subtype: "error_max_budget_usd", reason: "error_max_budget_usd"}} =
             EventMapper.map_event(raw)
  end

  test "result/error_during_execution preserves api_error_status and errors[]" do
    raw = %{
      "type" => "result",
      "subtype" => "error_during_execution",
      "is_error" => true,
      "api_error_status" => 500,
      "errors" => ["timeout", "retry-exhausted"],
      "permission_denials" => [%{"tool" => "Bash"}]
    }

    assert {:result, payload} = EventMapper.map_event(raw)
    assert payload.api_error_status == 500
    assert payload.errors == ["timeout", "retry-exhausted"]
    assert payload.permission_denials == [%{"tool" => "Bash"}]
    assert payload.reason == "timeout; retry-exhausted"
  end

  test "result preserves modelUsage, terminal_reason and stop_reason on failure" do
    raw = %{
      "type" => "result",
      "subtype" => "error_during_execution",
      "modelUsage" => %{"haiku" => %{"inputTokens" => 0, "outputTokens" => 0}},
      "terminal_reason" => "killed",
      "stop_reason" => "tool_use"
    }

    assert {:result, payload} = EventMapper.map_event(raw)
    assert payload.model_usage == %{"haiku" => %{"inputTokens" => 0, "outputTokens" => 0}}
    assert payload.terminal_reason == "killed"
    assert payload.stop_reason == "tool_use"
  end

  test "result reason prefers explicit error string over fallback" do
    raw = %{
      "type" => "result",
      "subtype" => "error_during_execution",
      "error" => "something specific"
    }

    assert {:result, %{reason: "something specific"}} = EventMapper.map_event(raw)
  end

  # --- streaming and other top-level events --------------------------------

  test "stream_event with text_delta surfaces delta_text" do
    raw = %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "ab"}
      }
    }

    assert {:emit, :stream_event, payload} = EventMapper.map_event(raw)
    assert payload.event_type == "content_block_delta"
    assert payload.delta_text == "ab"
    assert payload.content_index == 0
  end

  test "stream_event with thinking_delta surfaces delta_thinking" do
    raw = %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "thinking_delta", "thinking" => "hmm"}
      }
    }

    assert {:emit, :stream_event, payload} = EventMapper.map_event(raw)
    assert payload.delta_thinking == "hmm"
  end

  test "stream_event with input_json_delta surfaces delta_partial_json" do
    raw = %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"a"}
      }
    }

    assert {:emit, :stream_event, payload} = EventMapper.map_event(raw)
    assert payload.delta_partial_json == "{\"a"
  end

  test "stream_event passes ttft_ms when present" do
    raw = %{
      "type" => "stream_event",
      "ttft_ms" => 123,
      "event" => %{"type" => "message_start", "delta" => %{}}
    }

    assert {:emit, :stream_event, payload} = EventMapper.map_event(raw)
    assert payload.ttft_ms == 123
  end

  test "tool_progress emits :tool_progress with elapsed time" do
    raw = %{
      "type" => "tool_progress",
      "tool_use_id" => "tu-9",
      "tool_name" => "Bash",
      "elapsed_time_seconds" => 42
    }

    assert {:emit, :tool_progress, payload} = EventMapper.map_event(raw)
    assert payload.tool_use_id == "tu-9"
    assert payload.tool_name == "Bash"
    assert payload.elapsed_time_seconds == 42
  end

  test "tool_use_summary emits :tool_summary" do
    raw = %{
      "type" => "tool_use_summary",
      "summary" => "did stuff",
      "preceding_tool_use_ids" => ["tu-1", "tu-2"]
    }

    assert {:emit, :tool_summary, payload} = EventMapper.map_event(raw)
    assert payload.summary == "did stuff"
    assert payload.preceding_tool_use_ids == ["tu-1", "tu-2"]
  end

  test "auth_status emits :auth_status with output and error" do
    raw = %{
      "type" => "auth_status",
      "is_authenticating" => false,
      "output" => "ok",
      "error" => nil
    }

    assert {:emit, :auth_status, payload} = EventMapper.map_event(raw)
    assert payload.is_authenticating == false
    assert payload.output == "ok"
  end

  test "rate_limit_event emits :rate_limit_event with rate_limit_info AND :rate_limits alias" do
    raw = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"input_tokens" => %{"remaining" => 100, "reset_at" => "2025"}}
    }

    assert {:emit, :rate_limit_event, payload} = EventMapper.map_event(raw)
    assert payload.rate_limit_info == %{"input_tokens" => %{"remaining" => 100, "reset_at" => "2025"}}
    assert payload.rate_limits == payload.rate_limit_info
  end

  test "prompt_suggestion emits :prompt_suggestion" do
    raw = %{"type" => "prompt_suggestion", "suggestion" => "try this"}
    assert {:emit, :prompt_suggestion, payload} = EventMapper.map_event(raw)
    assert payload.suggestion == "try this"
  end

  test "keep_alive returns :ignore" do
    assert EventMapper.map_event(%{"type" => "keep_alive"}) == :ignore
  end

  test "control_request/response/cancel funnels through :control_message" do
    for type <- ["control_request", "control_response", "control_cancel_request"] do
      raw = %{"type" => type, "id" => "c-1", "payload" => %{"k" => "v"}}
      assert {:emit, :control_message, payload} = EventMapper.map_event(raw)
      assert payload.type == type
      assert payload.payload["id"] == "c-1"
      refute Map.has_key?(payload.payload, "type")
    end
  end

  test "post_turn_summary / task_summary / transcript_mirror map to :other_message" do
    for type <- ["post_turn_summary", "task_summary", "transcript_mirror"] do
      raw = %{"type" => type, "x" => 1}
      assert {:emit, :other_message, payload} = EventMapper.map_event(raw)
      assert payload.type == type
      assert payload.claude == raw
    end
  end

  test "unknown type goes through :other_message with the type tag" do
    raw = %{"type" => "tool_use", "id" => "tu-9", "name" => "Bash"}

    assert {:emit, :other_message, payload} = EventMapper.map_event(raw)
    assert payload == %{type: "tool_use", claude: raw}
  end

  test "non-object input falls back to :other_message" do
    assert {:emit, :other_message, %{claude: "garbage"}} = EventMapper.map_event("garbage")
  end

  test "fully malformed map without type still maps to :other_message" do
    assert {:emit, :other_message, %{claude: %{"foo" => "bar"}}} =
             EventMapper.map_event(%{"foo" => "bar"})
  end
end
