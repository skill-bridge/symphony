defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.

  Maps the five Tracker callbacks onto `GitHub.Client`, which speaks the
  REST v3 API. The mapping is intentionally thin: state transitions reduce
  to flipping `open`/`closed`, comments POST to the standard endpoint, and
  candidate selection follows GitHub's native `?state=open&labels=...`
  filter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client

  @impl true
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @impl true
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @impl true
  def update_issue_state(issue_id, state_name),
    do: client_module().update_issue_state(issue_id, state_name)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
