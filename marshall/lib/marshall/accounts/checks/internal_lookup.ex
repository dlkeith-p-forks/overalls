defmodule Marshall.Accounts.Checks.InternalLookup do
  @moduledoc "Only the trusted in-process coordinator can resolve registered sharing recipients."
  use Ash.Policy.SimpleCheck
  @impl true
  def describe(_), do: "trusted internal account lookup"
  @impl true
  def match?(%Marshall.Authorization.SystemActor{purpose: :compute}, _, _), do: true
  def match?(_, _, _), do: false
end
