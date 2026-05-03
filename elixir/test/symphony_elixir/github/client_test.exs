defmodule SymphonyElixir.GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Linear.Issue

  describe "normalise_issue/2" do
    test "maps GitHub REST issue payload to Issue struct" do
      payload = %{
        "id" => 999_001,
        "node_id" => "I_kwDOABC",
        "number" => 1234,
        "title" => "Fix login flow",
        "body" => "# Repro\n...",
        "state" => "open",
        "html_url" => "https://github.com/skill-bridge/skillbridge-ai-platform/issues/1234",
        "labels" => [
          %{"name" => "Symphony"},
          %{"name" => "bug"},
          %{"name" => "priority/2"}
        ],
        "assignee" => %{"login" => "genki1234"},
        "created_at" => "2026-05-01T12:00:00Z",
        "updated_at" => "2026-05-02T03:30:00Z"
      }

      assert %Issue{
               id: "1234",
               identifier: "#1234",
               title: "Fix login flow",
               description: "# Repro\n...",
               state: "open",
               url: "https://github.com/skill-bridge/skillbridge-ai-platform/issues/1234",
               assignee_id: "genki1234",
               labels: ["symphony", "bug", "priority/2"],
               priority: 2,
               assigned_to_worker: true,
               blocked_by: []
             } = Client.normalise_issue(payload, "skill-bridge/skillbridge-ai-platform")
    end

    test "falls back through assignees[] when assignee is null" do
      payload = %{
        "number" => 7,
        "title" => "x",
        "state" => "open",
        "labels" => [],
        "assignee" => nil,
        "assignees" => [%{"login" => "alice"}, %{"login" => "bob"}]
      }

      assert %Issue{assignee_id: "alice"} = Client.normalise_issue(payload, "owner/repo")
    end

    test "lowercases labels and discards malformed entries" do
      payload = %{
        "number" => 1,
        "title" => "x",
        "state" => "open",
        "labels" => [%{"name" => "Symphony"}, "RAW", %{"foo" => "bar"}, "  Trim  "]
      }

      assert %Issue{labels: ["symphony", "raw", "trim"]} =
               Client.normalise_issue(payload, "owner/repo")
    end

    test "priority is nil when no priority/* label is present" do
      payload = %{
        "number" => 1,
        "title" => "x",
        "state" => "open",
        "labels" => [%{"name" => "bug"}]
      }

      assert %Issue{priority: nil} = Client.normalise_issue(payload, "owner/repo")
    end

    test "ISO-8601 timestamps decode to DateTime" do
      payload = %{
        "number" => 1,
        "title" => "x",
        "state" => "open",
        "labels" => [],
        "created_at" => "2026-05-01T12:00:00Z",
        "updated_at" => "garbage"
      }

      assert %Issue{created_at: %DateTime{}, updated_at: nil} =
               Client.normalise_issue(payload, "owner/repo")
    end
  end
end
