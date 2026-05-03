defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Adapter

  defmodule FakeClient do
    @moduledoc false
    def fetch_candidate_issues, do: {:ok, [%{id: "1"}]}
    def fetch_issues_by_states(states), do: {:ok, [{:states, states}]}
    def fetch_issue_states_by_ids(ids), do: {:ok, [{:ids, ids}]}
    def create_comment(issue_id, body), do: send(self(), {:comment, issue_id, body}) && :ok
    def update_issue_state(issue_id, state), do: send(self(), {:state, issue_id, state}) && :ok
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  test "fetch_candidate_issues/0 delegates to client" do
    assert {:ok, [%{id: "1"}]} = Adapter.fetch_candidate_issues()
  end

  test "fetch_issues_by_states/1 forwards states" do
    assert {:ok, [{:states, ["open"]}]} = Adapter.fetch_issues_by_states(["open"])
  end

  test "fetch_issue_states_by_ids/1 forwards ids" do
    assert {:ok, [{:ids, ["1", "2"]}]} = Adapter.fetch_issue_states_by_ids(["1", "2"])
  end

  test "create_comment/2 forwards to client" do
    assert :ok = Adapter.create_comment("123", "hello")
    assert_received {:comment, "123", "hello"}
  end

  test "update_issue_state/2 forwards to client" do
    assert :ok = Adapter.update_issue_state("123", "closed")
    assert_received {:state, "123", "closed"}
  end
end
