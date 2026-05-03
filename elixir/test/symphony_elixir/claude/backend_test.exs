defmodule SymphonyElixir.Claude.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Backend

  @moduletag :tmp_dir

  test "start_session/2 rejects workspaces outside the configured root" do
    test_root = make_test_root("start-session-invalid")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside = Path.join(test_root, "outside")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside)

      write_claude_workflow!(test_root, workspace_root, claude_command: "/usr/bin/true")

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               Backend.start_session(outside)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session/2 returns a session struct with thread_id, workspace, and metadata" do
    test_root = make_test_root("start-session-ok")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(workspace)

      write_claude_workflow!(test_root, workspace_root, claude_command: "/usr/bin/true")

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-fixed")

      assert session.thread_id == "thread-fixed"

      assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert session.workspace == expected_workspace

      assert session.metadata == %{
               thread_id: "thread-fixed",
               worker_host: nil,
               is_continuation: false,
               requested_thread_id: "thread-fixed"
             }

      assert session.command == ["/usr/bin/true"]
      assert session.worker_host == nil
      assert session.is_continuation == false

      assert :ok = Backend.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session/2 fails when claude.command is blank" do
    test_root = make_test_root("blank-command")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CMD")
      File.mkdir_p!(workspace)

      write_claude_workflow!(test_root, workspace_root, claude_command: " ")

      assert {:error, :missing_claude_command} = Backend.start_session(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "stop_session/1 returns :ok and clears the per-session turn counter" do
    test_root = make_test_root("stop-session")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STOP")
      File.mkdir_p!(workspace)

      write_claude_workflow!(test_root, workspace_root, claude_command: "/usr/bin/true")

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-stop")
      assert :ok = Backend.stop_session(session)

      # After stop_session the Process dictionary entry should be gone. Calling
      # stop_session a second time must remain idempotent.
      assert :ok = Backend.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 emits session_started, notifications, and turn_completed in order" do
    test_root = make_test_root("run-turn-success")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RUN")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-run.trace")

      write_fake_claude!(claude_binary, success_payload(trace_file))
      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      issue = build_issue("MT-RUN")

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-run")

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:ok, %{session_id: session_id, thread_id: "thread-run", turn_id: "turn-1"}} =
               Backend.run_turn(session, "Hello", issue, on_message: on_message)

      assert session_id == "thread-run-turn-1"

      assert_received {:claude_message,
                       %{
                         event: :session_started,
                         session_id: ^session_id,
                         thread_id: "thread-run",
                         turn_id: "turn-1"
                       }}

      assert_received {:claude_message, %{event: :notification, stage: :init}}
      assert_received {:claude_message, %{event: :notification, role: "assistant"}}

      assert_received {:claude_message,
                       %{
                         event: :turn_completed,
                         session_id: ^session_id,
                         result: %{status: :success}
                       }}

      assert :ok = Backend.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 returns {:error, {:no_result_event, ...}} when claude exits cleanly with no result" do
    test_root = make_test_root("run-turn-no-result")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-NR")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")

      write_fake_claude!(claude_binary, """
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"ses-2"}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-nr")
      issue = build_issue("MT-NR")

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:error, {:no_result_event, :exit_normal, stderr_tail}} =
               Backend.run_turn(session, "Hi", issue, on_message: on_message)

      assert is_binary(stderr_tail)

      assert_received {:claude_message, %{event: :session_started}}
      assert_received {:claude_message, %{event: :turn_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session/2 with resume_thread_id forces --resume on the very first turn" do
    test_root = make_test_root("resume-on-first-turn")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RES1")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume-first.trace")

      write_fake_claude!(claude_binary, """
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"thread-existing"}'
      printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0.0}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      assert {:ok, session} =
               Backend.start_session(workspace, resume_thread_id: "thread-existing")

      assert session.thread_id == "thread-existing"
      assert session.is_continuation == true
      assert session.metadata.is_continuation == true
      assert session.metadata.requested_thread_id == "thread-existing"

      issue = build_issue("MT-RES1")

      assert {:ok, %{turn_id: "turn-1"}} =
               Backend.run_turn(session, "resume me", issue, on_message: fn _ -> :ok end)

      trace = File.read!(trace_file)

      argv_lines =
        trace
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "ARGV:"))

      assert length(argv_lines) == 1
      [argv] = argv_lines

      # turn 1, but is_continuation: true => --resume, NOT --session-id.
      assert argv =~ "--resume"
      refute argv =~ "--session-id"
      assert argv =~ "thread-existing"
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 surfaces stderr_tail on :no_result_event when claude wrote diagnostics to stderr" do
    test_root = make_test_root("stderr-tail")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STDERR")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")

      # No result event, but a noisy line on stderr that we should observe in
      # the surfaced stderr_tail.
      write_fake_claude!(claude_binary, """
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-err"}'
      printf 'SANDBOX_DEBUG: simulated stderr noise\\n' >&2
      printf 'second-stderr-line\\n' >&2
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-stderr")
      issue = build_issue("MT-STDERR")

      noop = fn _ -> :ok end

      assert {:error, {:no_result_event, :exit_normal, stderr_tail}} =
               Backend.run_turn(session, "Hi", issue, on_message: noop)

      assert is_binary(stderr_tail)
      assert stderr_tail =~ "SANDBOX_DEBUG: simulated stderr noise"
      assert stderr_tail =~ "second-stderr-line"
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 attaches stderr_tail to :turn_failed reason on a result-error subtype" do
    test_root = make_test_root("stderr-tail-failed")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FAIL")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")

      write_fake_claude!(claude_binary, """
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-fail"}'
      printf 'BOOM-ERROR-MARKER\\n' >&2
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","duration_ms":7,"error":"explode"}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-fail")
      issue = build_issue("MT-FAIL")

      noop = fn _ -> :ok end

      assert {:error, {:turn_failed, %{stderr_tail: tail, status: :failed} = result}} =
               Backend.run_turn(session, "Hi", issue, on_message: noop)

      assert is_binary(tail)
      assert tail =~ "BOOM-ERROR-MARKER"
      assert result.subtype == "error_during_execution"
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 emits :stall_detected when no chunks arrive within stall_timeout_ms but still beats turn_timeout_ms" do
    test_root = make_test_root("stall")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STALL")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")

      # Sleep longer than stall_timeout_ms but shorter than turn_timeout_ms,
      # then emit a successful result so the turn completes normally. We
      # expect at least one :stall_detected notification in flight.
      write_fake_claude!(claude_binary, """
      cat > /dev/null
      sleep 0.4
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-stall"}'
      printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0.0}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root,
        claude_command: claude_binary,
        # keep stall fast so the test is quick, but turn_timeout much larger.
        stall_timeout_ms: 100,
        turn_timeout_ms: 5_000
      )

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-stall")
      issue = build_issue("MT-STALL")

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:ok, %{turn_id: "turn-1"}} =
               Backend.run_turn(session, "Hi", issue, on_message: on_message)

      assert_received {:claude_message,
                       %{event: :stall_detected, since_last_chunk_ms: 100, elapsed_ms: elapsed}}

      assert is_integer(elapsed) and elapsed >= 100
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 emits :resume_landing_failed when claude lands on a different session_id" do
    test_root = make_test_root("resume-landing")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RLAND")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")

      # Asked to resume "thread-A" but claude lands on a brand-new session id.
      write_fake_claude!(claude_binary, """
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"thread-DIFFERENT"}'
      printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0.0}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      assert {:ok, session} =
               Backend.start_session(workspace, resume_thread_id: "thread-A")

      issue = build_issue("MT-RLAND")

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:ok, _} =
               Backend.run_turn(session, "Hi", issue, on_message: on_message)

      assert_received {:claude_message,
                       %{
                         event: :resume_landing_failed,
                         requested: "thread-A",
                         actual: "thread-DIFFERENT"
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn/4 across two turns increments turn_number and switches --session-id to --resume" do
    test_root = make_test_root("run-turn-resume")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RES")
      File.mkdir_p!(workspace)

      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume.trace")

      # Capture argv to a trace file. We do not care about the prompt body; just
      # consume stdin and emit a successful result so the turn completes.
      write_fake_claude!(claude_binary, """
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      cat > /dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-x"}'
      printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0.0}'
      exit 0
      """)

      write_claude_workflow!(test_root, workspace_root, claude_command: claude_binary)

      issue = build_issue("MT-RES")

      assert {:ok, session} = Backend.start_session(workspace, thread_id: "thread-resume")

      noop = fn _msg -> :ok end

      assert {:ok, %{turn_id: "turn-1"}} =
               Backend.run_turn(session, "first prompt", issue, on_message: noop)

      assert {:ok, %{turn_id: "turn-2"}} =
               Backend.run_turn(session, "second prompt", issue, on_message: noop)

      trace = File.read!(trace_file)
      argv_lines = trace |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "ARGV:"))

      assert length(argv_lines) == 2

      [first, second] = argv_lines
      assert first =~ "--session-id"
      refute first =~ "--resume"
      assert first =~ "thread-resume"

      assert second =~ "--resume"
      refute second =~ "--session-id"
      assert second =~ "thread-resume"
    after
      File.rm_rf(test_root)
    end
  end

  defp build_issue(identifier) do
    %SymphonyElixir.Linear.Issue{
      id: "issue-" <> identifier,
      identifier: identifier,
      title: "Claude backend test",
      description: "Drive the Claude backend from a fake CLI",
      state: "In Progress",
      url: "https://example.org/issues/" <> identifier,
      labels: ["backend"]
    }
  end

  defp success_payload(trace_file) do
    """
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-1","cwd":"/tmp"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":42,"num_turns":1,"total_cost_usd":0.0,"result":"done"}'
    exit 0
    """
  end

  defp write_fake_claude!(path, body) do
    File.write!(path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(path, 0o755)
  end

  defp make_test_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-backend-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp write_claude_workflow!(_test_root, workspace_root, opts) do
    claude_command = Keyword.fetch!(opts, :claude_command)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, 5000)
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, 0)
    path = Workflow.workflow_file_path()

    yaml = """
    ---
    tracker:
      kind: "linear"
      api_key: "token"
      project_slug: "project"
    workspace:
      root: "#{workspace_root}"
    agent:
      kind: "claude"
      max_concurrent_agents: 10
    codex:
      command: "codex app-server"
    claude:
      command: "#{claude_command}"
      turn_timeout_ms: #{turn_timeout_ms}
      stall_timeout_ms: #{stall_timeout_ms}
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
