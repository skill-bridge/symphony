defmodule SymphonyElixir.Claude.Backend do
  @moduledoc """
  Claude Code agent backend.

  Implements `SymphonyElixir.AgentBackend` by driving the `claude` CLI in
  `--output-format stream-json` mode. Unlike Codex's app-server, Claude has no
  long-lived process: every turn is a fresh `claude` invocation that resumes
  the same session UUID via `--session-id` (first turn) and `--resume`
  (continuation turns).

  ## Lifecycle

    * `start_session/2` validates the workspace path and reserves a session
      UUID. No subprocess is spawned yet.
    * `run_turn/4` spawns `claude` with the prompt on stdin, parses the
      NDJSON stream, and forwards canonical events through `on_message`.
    * `stop_session/1` clears any per-session bookkeeping.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.{Config, PathSafety, SSH}
  alias SymphonyElixir.Claude.{EventMapper, StreamJson, ToolTracker}

  @session_state_key :__symphony_claude_session_state__

  # Cap accumulated parser buffer (a single, never-newline-terminated line)
  # at 10 MiB. A single tool_result that big is almost certainly pathological,
  # so we drop the partial line to protect the BEAM binary heap.
  @max_buffer_bytes 10 * 1024 * 1024

  # Read at most this many trailing bytes of the stderr capture file when
  # surfacing it on a failed turn. Keeps logs/messages bounded.
  @stderr_tail_max_bytes 8_192

  @typedoc """
  Per-session opaque struct returned by `start_session/2`. The Codex backend
  carries a live port; Claude carries only metadata since its CLI is invoked
  per turn.
  """
  @type session :: %{
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          metadata: map(),
          command: [String.t()],
          is_continuation: boolean()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    resume_thread_id = Keyword.get(opts, :resume_thread_id)
    is_continuation = is_binary(resume_thread_id)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, command} <- resolve_command() do
      thread_id = resume_thread_id || Keyword.get(opts, :thread_id) || gen_uuid()
      reset_turn_counter(thread_id)

      session = %{
        thread_id: thread_id,
        workspace: expanded_workspace,
        worker_host: worker_host,
        metadata: %{
          thread_id: thread_id,
          worker_host: worker_host,
          is_continuation: is_continuation,
          requested_thread_id: thread_id
        },
        command: command,
        is_continuation: is_continuation
      }

      {:ok, session}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(%{thread_id: thread_id} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = bump_turn_counter(thread_id)
    turn_id = "turn-#{turn_number}"
    session_id = "#{thread_id}-#{turn_id}"

    Logger.info(
      "Claude session starting for #{issue_context(issue)} session_id=#{session_id} workspace=#{session.workspace} turn=#{turn_number}"
    )

    case open_claude_port(session, prompt, turn_number) do
      {:ok, port, stderr_path} ->
        emit_message(
          on_message,
          :session_started,
          %{session_id: session_id, thread_id: thread_id, turn_id: turn_id},
          session.metadata
        )

        case stream_turn(port, on_message, session.metadata, session_id, stderr_path) do
          {:ok, result} ->
            emit_message(
              on_message,
              :turn_completed,
              %{
                session_id: session_id,
                thread_id: thread_id,
                turn_id: turn_id,
                result: result
              },
              session.metadata
            )

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            emit_message(
              on_message,
              :turn_failed,
              %{
                session_id: session_id,
                thread_id: thread_id,
                turn_id: turn_id,
                reason: reason
              },
              session.metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        emit_message(on_message, :startup_failed, %{reason: reason}, session.metadata)
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{thread_id: thread_id}) do
    clear_turn_counter(thread_id)
    ToolTracker.clear()
    :ok
  end

  # --- subprocess management ------------------------------------------------

  defp open_claude_port(%{worker_host: nil} = session, prompt, turn_number) do
    bash = System.find_executable("bash")

    cond do
      is_nil(bash) ->
        {:error, :bash_not_found}

      true ->
        with {:ok, prompt_path} <- write_prompt_tempfile(prompt) do
          stderr_path = stderr_tempfile_path()

          command_line =
            session.command
            |> build_command_line(
              session.thread_id,
              turn_number,
              prompt_path,
              session.is_continuation
            )
            |> wrap_with_stderr_capture(stderr_path)

          try do
            port =
              Port.open(
                {:spawn_executable, String.to_charlist(bash)},
                [
                  :binary,
                  :exit_status,
                  :hide,
                  :use_stdio,
                  {:cd, String.to_charlist(session.workspace)},
                  # `set -m` enables job control so the shell becomes a process
                  # group leader; the spawned `claude` (and its node children)
                  # share that pgid, which we kill on timeout.
                  {:args, ["-c", "set -m; " <> command_line]}
                ]
              )

            {:ok, port, stderr_path}
          rescue
            error ->
              File.rm(prompt_path)
              cleanup_stderr(stderr_path)
              {:error, {:port_open_failed, Exception.message(error)}}
          end
        end
    end
  end

  defp open_claude_port(%{worker_host: worker_host} = session, prompt, turn_number)
       when is_binary(worker_host) do
    with {:ok, remote_prompt_path} <- write_remote_prompt_file(worker_host, prompt) do
      command_line =
        build_command_line(
          session.command,
          session.thread_id,
          turn_number,
          remote_prompt_path,
          session.is_continuation
        )

      remote = "cd #{shell_escape(session.workspace)} && #{command_line}"

      case SSH.start_port(worker_host, remote) do
        # Remote runs do not have a local stderr capture file; pass nil so the
        # downstream `read_stderr_tail/1` becomes a no-op.
        {:ok, port} -> {:ok, port, nil}
        {:error, _} = err -> err
      end
    end
  end

  defp write_prompt_tempfile(prompt) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-prompt-#{:erlang.unique_integer([:positive])}.txt"
      )

    case File.write(path, prompt) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:prompt_tempfile_write_failed, reason}}
    end
  end

  defp write_remote_prompt_file(worker_host, prompt) do
    remote_path =
      "/tmp/symphony-claude-prompt-#{:erlang.unique_integer([:positive])}.txt"

    encoded = Base.encode64(prompt)

    case SSH.run(
           worker_host,
           "umask 077 && printf %s #{shell_escape(encoded)} | base64 --decode > #{shell_escape(remote_path)}"
         ) do
      {:ok, {_output, 0}} -> {:ok, remote_path}
      {:ok, {output, status}} ->
        {:error, {:remote_prompt_write_failed, worker_host, {:nonzero_exit, status, output}}}
      {:error, reason} ->
        {:error, {:remote_prompt_write_failed, worker_host, reason}}
    end
  end

  defp stderr_tempfile_path do
    Path.join(
      System.tmp_dir!(),
      "symphony-claude-stderr-#{:erlang.unique_integer([:positive])}.log"
    )
  end

  # Wrap the user-visible command so stderr is teed to a file we can read on
  # failure, while stdout is forwarded untouched to the BEAM port. Doing this
  # in bash (rather than `:stderr_to_stdout`) keeps the NDJSON stream clean of
  # `[SandboxDebug]` lines and node warnings.
  defp wrap_with_stderr_capture(command_line, stderr_path) do
    "{ " <> command_line <> "; } 2> " <> shell_escape(stderr_path)
  end

  defp build_command_line(command_words, thread_id, turn_number, prompt_path, is_continuation)
       when is_list(command_words) do
    base = command_words |> Enum.map(&shell_escape/1) |> Enum.join(" ")

    flag = if turn_number > 1 or is_continuation, do: "--resume", else: "--session-id"

    extra =
      [
        "--print",
        "--output-format",
        "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        flag,
        thread_id
      ]
      |> Enum.map(&shell_escape/1)
      |> Enum.join(" ")

    quoted_prompt = shell_escape(prompt_path)
    "cat #{quoted_prompt} | " <> base <> " " <> extra <> "; rm -f #{quoted_prompt}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp shell_escape(value), do: shell_escape(to_string(value))

  # --- stream loop ----------------------------------------------------------

  defp stream_turn(port, on_message, metadata, session_id, stderr_path) do
    turn_started_at = System.monotonic_time(:millisecond)

    do_stream_turn(
      port,
      StreamJson.new(),
      on_message,
      metadata,
      session_id,
      nil,
      turn_started_at,
      stderr_path
    )
  end

  defp do_stream_turn(
         port,
         parser,
         on_message,
         metadata,
         session_id,
         last_result,
         turn_started_at,
         stderr_path
       ) do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        handle_chunk(
          port,
          parser,
          on_message,
          metadata,
          session_id,
          last_result,
          chunk,
          turn_started_at,
          stderr_path
        )

      {^port, {:exit_status, 0}} ->
        finalise(parser, on_message, metadata, session_id, last_result, :exit_normal, stderr_path)

      {^port, {:exit_status, status}} ->
        finalise(
          parser,
          on_message,
          metadata,
          session_id,
          last_result,
          {:exit_nonzero, status},
          stderr_path
        )
    after
      stall_timeout_ms() ->
        elapsed = System.monotonic_time(:millisecond) - turn_started_at
        total = turn_timeout_ms()

        cond do
          elapsed > total ->
            safe_close(port)
            stderr_tail = read_stderr_tail(stderr_path)
            cleanup_stderr(stderr_path)
            {:error, {:turn_timeout, total, stderr_tail}}

          stall_timeout_ms() == 0 ->
            # stall detection disabled — fall through to receive again.
            do_stream_turn(
              port,
              parser,
              on_message,
              metadata,
              session_id,
              last_result,
              turn_started_at,
              stderr_path
            )

          true ->
            emit_message(
              on_message,
              :stall_detected,
              %{
                session_id: session_id,
                since_last_chunk_ms: stall_timeout_ms(),
                elapsed_ms: elapsed
              },
              metadata
            )

            do_stream_turn(
              port,
              parser,
              on_message,
              metadata,
              session_id,
              last_result,
              turn_started_at,
              stderr_path
            )
        end
    end
  end

  defp handle_chunk(
         port,
         parser,
         on_message,
         metadata,
         session_id,
         last_result,
         chunk,
         turn_started_at,
         stderr_path
       ) do
    {:ok, events, parser} = StreamJson.feed(parser, chunk)

    parser = enforce_buffer_cap(parser, on_message, metadata, session_id)

    last_result =
      Enum.reduce(events, last_result, fn event, acc ->
        process_event(event, on_message, metadata, session_id, acc)
      end)

    do_stream_turn(
      port,
      parser,
      on_message,
      metadata,
      session_id,
      last_result,
      turn_started_at,
      stderr_path
    )
  end

  # Inspect the parser's leftover (un-newlined) buffer. A single line growing
  # past `@max_buffer_bytes` indicates a runaway tool_result; drop the partial
  # data so we don't OOM the BEAM binary heap and surface a notice.
  defp enforce_buffer_cap(%StreamJson{buffer: buffer} = parser, on_message, metadata, session_id) do
    size = byte_size(buffer)

    if size > @max_buffer_bytes do
      emit_message(
        on_message,
        :buffer_overflow,
        %{session_id: session_id, buffer_size: size, limit: @max_buffer_bytes},
        metadata
      )

      %{parser | buffer: ""}
    else
      parser
    end
  end

  defp finalise(parser, on_message, metadata, session_id, last_result, exit_marker, stderr_path) do
    {:ok, trailing, _parser} = StreamJson.flush(parser)

    last_result =
      Enum.reduce(trailing, last_result, fn event, acc ->
        process_event(event, on_message, metadata, session_id, acc)
      end)

    stderr_tail = read_stderr_tail(stderr_path)
    cleanup_stderr(stderr_path)

    case last_result do
      %{status: :success} = result ->
        {:ok, result}

      %{status: :failed} = result ->
        {:error, {:turn_failed, Map.put(result, :stderr_tail, stderr_tail)}}

      nil ->
        {:error, {:no_result_event, exit_marker, stderr_tail}}
    end
  end

  defp process_event({:malformed, raw, reason}, on_message, metadata, _session_id, acc) do
    emit_message(on_message, :malformed, %{raw: trim(raw), reason: reason}, metadata)
    acc
  end

  defp process_event(%{} = obj, on_message, metadata, session_id, acc) do
    case EventMapper.map_event(obj) do
      {:emit, event, payload} ->
        emit_message(on_message, event, payload, metadata)
        acc

      {:init, %{claude_session_id: claude_sid} = payload} ->
        # Detect resume landing failure: we asked claude to resume a specific
        # thread, but the system/init for the *first* event of the turn came
        # back with a different session_id, meaning claude silently started a
        # fresh conversation. Only fire on the first init we observe.
        if acc == nil and Map.get(metadata, :is_continuation) == true and
             is_binary(claude_sid) and claude_sid != Map.get(metadata, :requested_thread_id) do
          emit_message(
            on_message,
            :resume_landing_failed,
            %{
              session_id: session_id,
              requested: Map.get(metadata, :requested_thread_id),
              actual: claude_sid
            },
            metadata
          )
        end

        emit_message(on_message, :notification, Map.put(payload, :stage, :init), metadata)
        acc

      {:init, payload} ->
        emit_message(on_message, :notification, Map.put(payload, :stage, :init), metadata)
        acc

      {:result, %{status: :success} = result} ->
        result

      {:result, %{status: :failed} = result} ->
        result

      :ignore ->
        acc
    end
  end

  defp safe_close(port) do
    os_pid = port_os_pid(port)

    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    # Kill the entire process group so claude's spawned node children also
    # die. The bash wrapper uses `set -m`, making bash itself the pgid; the
    # negative target is the standard POSIX "kill the whole pgrp" idiom.
    if is_integer(os_pid) and os_pid > 0 do
      _ = System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
      Process.sleep(2_000)
      _ = System.cmd("kill", ["-KILL", "-#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp port_os_pid(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end
    catch
      _, _ -> nil
    end
  end

  # --- stderr buffer helpers ------------------------------------------------

  defp read_stderr_tail(nil), do: ""

  defp read_stderr_tail(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        offset = max(0, size - @stderr_tail_max_bytes)

        case File.open(path, [:read, :binary]) do
          {:ok, fd} ->
            :file.position(fd, {:bof, offset})
            chunk = IO.binread(fd, @stderr_tail_max_bytes)
            File.close(fd)
            normalize_stderr_chunk(chunk)

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp normalize_stderr_chunk(chunk) when is_binary(chunk), do: chunk
  defp normalize_stderr_chunk(_), do: ""

  defp cleanup_stderr(nil), do: :ok

  defp cleanup_stderr(path) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  defp trim(line) when is_binary(line) do
    line
    |> String.slice(0, 256)
  end

  # --- emit + state helpers -------------------------------------------------

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp reset_turn_counter(thread_id) do
    Process.put({@session_state_key, thread_id}, 0)
    :ok
  end

  defp bump_turn_counter(thread_id) do
    current = Process.get({@session_state_key, thread_id}, 0)
    next = current + 1
    Process.put({@session_state_key, thread_id}, next)
    next
  end

  defp clear_turn_counter(thread_id) do
    Process.delete({@session_state_key, thread_id})
    :ok
  end

  # --- workspace + config ---------------------------------------------------

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error,
           {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error,
           {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp resolve_command do
    raw =
      Config.settings!().claude.command
      |> to_string()
      |> String.trim()

    case OptionParser.split(raw) do
      [] -> {:error, :missing_claude_command}
      words -> {:ok, words}
    end
  rescue
    error -> {:error, {:invalid_claude_command, Exception.message(error)}}
  end

  defp turn_timeout_ms do
    Config.settings!().claude.turn_timeout_ms
  end

  defp stall_timeout_ms do
    case Config.settings!().claude.stall_timeout_ms do
      nil -> 0
      n when is_integer(n) -> n
    end
  end

  defp gen_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000), Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000), e]
    )
    |> IO.iodata_to_binary()
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "issue_id=unknown"
end
