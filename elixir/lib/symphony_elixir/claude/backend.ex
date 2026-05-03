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
  alias SymphonyElixir.Claude.{EventMapper, StreamJson}

  @session_state_key :__symphony_claude_session_state__

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
          command: [String.t()]
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, command} <- resolve_command() do
      thread_id = Keyword.get(opts, :thread_id) || gen_uuid()
      reset_turn_counter(thread_id)

      session = %{
        thread_id: thread_id,
        workspace: expanded_workspace,
        worker_host: worker_host,
        metadata: %{thread_id: thread_id, worker_host: worker_host},
        command: command
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
      {:ok, port} ->
        emit_message(
          on_message,
          :session_started,
          %{session_id: session_id, thread_id: thread_id, turn_id: turn_id},
          session.metadata
        )

        case stream_turn(port, on_message, session.metadata, session_id) do
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
          command_line =
            build_command_line(session.command, session.thread_id, turn_number, prompt_path)

          try do
            port =
              Port.open(
                {:spawn_executable, String.to_charlist(bash)},
                [
                  :binary,
                  :exit_status,
                  :stderr_to_stdout,
                  :hide,
                  :use_stdio,
                  {:cd, String.to_charlist(session.workspace)},
                  {:args, ["-lc", command_line]}
                ]
              )

            {:ok, port}
          rescue
            error ->
              File.rm(prompt_path)
              {:error, {:port_open_failed, Exception.message(error)}}
          end
        end
    end
  end

  defp open_claude_port(%{worker_host: worker_host} = session, prompt, turn_number)
       when is_binary(worker_host) do
    with {:ok, remote_prompt_path} <- write_remote_prompt_file(worker_host, prompt) do
      command_line =
        build_command_line(session.command, session.thread_id, turn_number, remote_prompt_path)

      remote = "cd #{shell_escape(session.workspace)} && #{command_line}"

      case SSH.start_port(worker_host, remote) do
        {:ok, port} -> {:ok, port}
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

  defp build_command_line(command_words, thread_id, turn_number, prompt_path)
       when is_list(command_words) do
    base = Enum.map(command_words, &shell_escape/1) |> Enum.join(" ")

    extra =
      [
        "--print",
        "--output-format",
        "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        if(turn_number == 1, do: "--session-id", else: "--resume"),
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

  defp stream_turn(port, on_message, metadata, session_id) do
    do_stream_turn(port, StreamJson.new(), on_message, metadata, session_id, nil)
  end

  defp do_stream_turn(port, parser, on_message, metadata, session_id, last_result) do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        handle_chunk(port, parser, on_message, metadata, session_id, last_result, chunk)

      {^port, {:exit_status, 0}} ->
        finalise(parser, on_message, metadata, session_id, last_result, :exit_normal)

      {^port, {:exit_status, status}} ->
        finalise(parser, on_message, metadata, session_id, last_result, {:exit_nonzero, status})
    after
      turn_timeout_ms() ->
        safe_close(port)
        {:error, {:turn_timeout, turn_timeout_ms()}}
    end
  end

  defp handle_chunk(port, parser, on_message, metadata, session_id, last_result, chunk) do
    {:ok, events, parser} = StreamJson.feed(parser, chunk)

    last_result =
      Enum.reduce(events, last_result, fn event, acc ->
        process_event(event, on_message, metadata, session_id, acc)
      end)

    do_stream_turn(port, parser, on_message, metadata, session_id, last_result)
  end

  defp finalise(parser, on_message, metadata, session_id, last_result, exit_marker) do
    {:ok, trailing, _parser} = StreamJson.flush(parser)

    last_result =
      Enum.reduce(trailing, last_result, fn event, acc ->
        process_event(event, on_message, metadata, session_id, acc)
      end)

    case last_result do
      %{status: :success} = result -> {:ok, result}
      %{status: :failed} = result -> {:error, {:turn_failed, result}}
      nil -> {:error, {:no_result_event, exit_marker}}
    end
  end

  defp process_event({:malformed, raw, reason}, on_message, metadata, _session_id, acc) do
    emit_message(on_message, :malformed, %{raw: trim(raw), reason: reason}, metadata)
    acc
  end

  defp process_event(%{} = obj, on_message, metadata, _session_id, acc) do
    case EventMapper.map_event(obj) do
      {:emit, event, payload} ->
        emit_message(on_message, event, payload, metadata)
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
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end
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
