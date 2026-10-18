defmodule Marshall.Accounts.GitSettings do
  @moduledoc "Current account Git preferences and trusted per-projection commit policy."
  alias Marshall.Accounts.User

  @trailer "Co-authored-by: Overalls <noreply@overalls.dev>"

  # @cc [owner:ghuntley,label:security] current-git-trailer-policy
  # Every model projection MUST read the immutable configuration owner's current
  # preference. The final trusted instruction MUST supersede earlier trailer
  # policy, use only the fixed attribution, and never rewrite prior commits.
  @spec instruction(Ecto.UUID.t()) :: String.t()
  def instruction(owner_id) do
    case Marshall.Accounts.Security.current(owner_id) do
      %User{deleted_at: nil, commit_trailers_enabled: true} -> policy(true)
      _ -> policy(false)
    end
  end

  @spec policy(boolean()) :: String.t()
  def policy(enabled?) do
    directive =
      if enabled? do
        "For new Git commits you create, preserve all existing trailers and append exactly once, after a blank line, this fixed trailer if it is absent: " <>
          @trailer
      else
        "Do not add the Overalls co-author trailer to new Git commits. Preserve existing trailers."
      end

    "[overalls-current-commit-policy-v1]\n" <>
      "This is the current commit attribution policy and supersedes all earlier commit attribution instructions, including retained context and summaries. " <>
      directive <>
      ". Never amend or rewrite past commits to apply this policy.\n[/overalls-current-commit-policy-v1]"
  end
end
