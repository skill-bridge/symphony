defmodule SymphonyElixir.GitHub.Issue do
  @moduledoc """
  Normalised GitHub issue representation, mirrored on the Linear schema so the
  orchestrator can treat both backends uniformly.

  Choices specific to GitHub:

    * `id` is the issue **number** as a string (`"123"`). GitHub's PATCH/POST
      endpoints take `(owner, repo, number)`; the repo comes from runtime
      config, so storing the number alone is sufficient.
    * `identifier` is `"#{number}"` (display-friendly) so workspace keys
      sanitise to `_<number>`.
    * `state` is the GitHub native state — `"open"` or `"closed"` — which
      lines up cleanly with `active_states: ["open"]` / `terminal_states:
      ["closed"]` in the workflow.
    * `branch_name` is left `nil`. The agent prompt is expected to ask Claude
      to create a `claude-refactor/<asset>-<ts>` branch in line with the
      Skill Bridge convention.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :node_id,
    :number,
    :repo,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          node_id: String.t() | nil,
          number: integer() | nil,
          repo: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
