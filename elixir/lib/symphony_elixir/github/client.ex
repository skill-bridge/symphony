defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST v3 client for the Symphony tracker.

  Reuses `Req` (already a dep via the Linear client) and respects the same
  conventions:

    * Authorization header `token <api_key>`. The token is resolved by the
      config layer from `tracker.api_key` (e.g. `$GITHUB_TOKEN`).
    * Endpoint defaults to `https://api.github.com` for github.com. GitHub
      Enterprise users override via `tracker.endpoint`.
    * Pagination follows the `Link: <...>; rel="next"` header.
    * Network timeout: 30 s (mirrors Linear).

  Symphony only exercises a small slice of the API surface:

    * `GET /repos/:owner/:repo/issues?state=open&labels=...&page=1` to list
      candidates; pull requests are filtered out client-side via the
      `pull_request` field that GitHub bolts onto the issue payload.
    * `GET /repos/:owner/:repo/issues/:number` for state refresh by id.
    * `POST /repos/:owner/:repo/issues/:number/comments` to write back.
    * `PATCH /repos/:owner/:repo/issues/:number` to flip `state`.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- ensure_credentials(tracker),
         labels <- normalise_labels(tracker.required_labels),
         {:ok, owner, repo} <- parse_repo(tracker.repo) do
      do_fetch_pages(tracker, owner, repo, "open", labels, 1, [])
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    tracker = Config.settings!().tracker

    with :ok <- ensure_credentials(tracker),
         labels <- normalise_labels(tracker.required_labels),
         {:ok, owner, repo} <- parse_repo(tracker.repo) do
      collect_states(tracker, owner, repo, normalise_states(states), labels, [])
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with :ok <- ensure_credentials(tracker),
         {:ok, owner, repo} <- parse_repo(tracker.repo) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case fetch_issue(tracker, owner, repo, issue_id) do
          {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
          {:ok, :not_found} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, _} = err -> err
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with :ok <- ensure_credentials(tracker),
         {:ok, owner, repo} <- parse_repo(tracker.repo),
         {:ok, headers} <- request_headers(tracker),
         number when is_integer(number) <- parse_number(issue_id),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post("#{base_url(tracker)}/repos/#{owner}/#{repo}/issues/#{number}/comments",
             headers: headers,
             json: %{"body" => body},
             connect_options: [timeout: 30_000]
           ) do
      :ok
    else
      :error ->
        {:error, {:invalid_issue_number, issue_id}}

      {:ok, %{status: status} = response} ->
        Logger.warning("GitHub create_comment failed status=#{status} #{summarize(response)}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker
    normalised = normalise_state_name(state_name)

    with :ok <- ensure_credentials(tracker),
         :ok <- validate_state(normalised),
         {:ok, owner, repo} <- parse_repo(tracker.repo),
         {:ok, headers} <- request_headers(tracker),
         number when is_integer(number) <- parse_number(issue_id),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.patch("#{base_url(tracker)}/repos/#{owner}/#{repo}/issues/#{number}",
             headers: headers,
             json: %{"state" => normalised},
             connect_options: [timeout: 30_000]
           ) do
      :ok
    else
      :error ->
        {:error, {:invalid_issue_number, issue_id}}

      {:error, :unsupported_state} ->
        {:error, {:unsupported_github_state, state_name}}

      {:ok, %{status: status} = response} ->
        Logger.warning("GitHub update_issue_state failed status=#{status} #{summarize(response)}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- internal HTTP --------------------------------------------------------

  defp do_fetch_pages(tracker, owner, repo, state, labels, page, acc) do
    case list_request(tracker, owner, repo, state, labels, page) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        new_issues =
          body
          |> List.wrap()
          |> Enum.reject(&pull_request?/1)
          |> Enum.map(&normalise_issue(&1, tracker.repo))

        next_acc = acc ++ new_issues

        if has_next_page?(headers) and length(new_issues) > 0 do
          do_fetch_pages(tracker, owner, repo, state, labels, page + 1, next_acc)
        else
          {:ok, next_acc}
        end

      {:ok, %{status: status} = response} ->
        Logger.warning("GitHub list_issues status=#{status} #{summarize(response)}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_states(_tracker, _owner, _repo, [], _labels, acc), do: {:ok, acc}

  defp collect_states(tracker, owner, repo, [state | rest], labels, acc) do
    case do_fetch_pages(tracker, owner, repo, state, labels, 1, []) do
      {:ok, issues} -> collect_states(tracker, owner, repo, rest, labels, acc ++ issues)
      {:error, _} = err -> err
    end
  end

  defp list_request(tracker, owner, repo, state, labels, page) do
    with {:ok, headers} <- request_headers(tracker) do
      params = [
        {"state", state},
        {"per_page", Integer.to_string(@page_size)},
        {"page", Integer.to_string(page)}
      ]

      params = if labels == [], do: params, else: params ++ [{"labels", Enum.join(labels, ",")}]

      Req.get("#{base_url(tracker)}/repos/#{owner}/#{repo}/issues",
        headers: headers,
        params: params,
        connect_options: [timeout: 30_000]
      )
    end
  end

  defp fetch_issue(tracker, owner, repo, issue_id) do
    with {:ok, headers} <- request_headers(tracker),
         number when is_integer(number) <- parse_number(issue_id) do
      case Req.get("#{base_url(tracker)}/repos/#{owner}/#{repo}/issues/#{number}",
             headers: headers,
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: 200, body: body}} ->
          if pull_request?(body) do
            {:ok, :not_found}
          else
            {:ok, normalise_issue(body, tracker.repo)}
          end

        {:ok, %{status: 404}} ->
          {:ok, :not_found}

        {:ok, %{status: status} = response} ->
          Logger.warning("GitHub fetch_issue status=#{status} #{summarize(response)}")
          {:error, {:github_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:ok, :not_found}
      {:error, _} = err -> err
    end
  end

  defp request_headers(tracker) do
    case tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        token = String.trim(token)

        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"User-Agent", "symphony-elixir"}
         ]}
    end
  end

  defp ensure_credentials(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_github_api_token}
      is_nil(tracker.repo) -> {:error, :missing_github_repo}
      String.trim(to_string(tracker.repo)) == "" -> {:error, :missing_github_repo}
      true -> :ok
    end
  end

  defp parse_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:invalid_github_repo, repo}}
    end
  end

  defp parse_repo(_repo), do: {:error, :missing_github_repo}

  defp parse_number(value) when is_integer(value), do: value

  defp parse_number(value) when is_binary(value) do
    trimmed = String.trim_leading(value, "#") |> String.trim()

    case Integer.parse(trimmed) do
      {n, ""} when n > 0 -> n
      _ -> :error
    end
  end

  defp parse_number(_), do: :error

  defp validate_state("open"), do: :ok
  defp validate_state("closed"), do: :ok
  defp validate_state(_), do: {:error, :unsupported_state}

  defp normalise_state_name(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalise_states(states) when is_list(states) do
    states
    |> Enum.map(&normalise_state_name/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in ["open", "closed"]))
  end

  defp normalise_labels(nil), do: []
  defp normalise_labels(""), do: []

  defp normalise_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalise_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp pull_request?(%{"pull_request" => %{}}), do: true
  defp pull_request?(_), do: false

  defp has_next_page?(headers) when is_list(headers) do
    headers
    |> Enum.any?(fn
      {name, value} when is_binary(value) ->
        String.downcase(name) == "link" and String.contains?(value, ~s(rel="next"))

      _ ->
        false
    end)
  end

  defp has_next_page?(_), do: false

  defp summarize(%{body: body}) do
    body
    |> case do
      bin when is_binary(bin) ->
        bin
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      other ->
        inspect(other, limit: 20)
    end
    |> truncate(@max_error_body_log_bytes)
    |> then(&("body=" <> &1))
  end

  defp summarize(_), do: ""

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    binary_part(value, 0, max) <> "...<truncated>"
  end

  defp truncate(value, _max), do: value

  # --- normalisation --------------------------------------------------------

  @spec normalise_issue(map(), String.t() | nil) :: Issue.t()
  def normalise_issue(payload, _repo_full_name) when is_map(payload) do
    number = payload["number"]
    labels = extract_labels(payload["labels"])

    # The orchestrator pattern-matches on `%Linear.Issue{}` everywhere, so the
    # GitHub adapter populates that same struct. The owner/repo pair is
    # available at write time via `Config.settings!().tracker.repo`, and the
    # numeric id alone is sufficient to address GitHub PATCH/POST endpoints.
    %Issue{
      id: number_to_id(number),
      identifier: number_to_identifier(number),
      title: payload["title"],
      description: payload["body"],
      priority: priority_from_labels(labels),
      state: payload["state"] || "open",
      branch_name: nil,
      url: payload["html_url"],
      assignee_id: assignee_login(payload),
      labels: labels,
      blocked_by: [],
      assigned_to_worker: true,
      created_at: parse_datetime(payload["created_at"]),
      updated_at: parse_datetime(payload["updated_at"])
    }
  end

  defp number_to_id(number) when is_integer(number), do: Integer.to_string(number)
  defp number_to_id(_), do: nil

  defp number_to_identifier(number) when is_integer(number), do: "##{number}"
  defp number_to_identifier(_), do: nil

  defp extract_labels(nil), do: []

  defp extract_labels(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [String.downcase(String.trim(name))]
      name when is_binary(name) -> [String.downcase(String.trim(name))]
      _ -> []
    end)
  end

  defp priority_from_labels(labels) do
    Enum.find_value(labels, fn label ->
      case Regex.run(~r/^priority\/(\d+)$/, label) do
        [_, n] ->
          case Integer.parse(n) do
            {value, _} -> value
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp assignee_login(%{"assignee" => %{"login" => login}}) when is_binary(login), do: login

  defp assignee_login(%{"assignees" => assignees}) when is_list(assignees) do
    Enum.find_value(assignees, fn
      %{"login" => login} when is_binary(login) -> login
      _ -> nil
    end)
  end

  defp assignee_login(_), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp base_url(tracker) do
    case tracker.endpoint do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> "https://api.github.com"
    end
  end
end
