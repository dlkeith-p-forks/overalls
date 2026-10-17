defmodule Marshall.Accounts.AdminEvents do
  @moduledoc "Bounded redacted administrator audit projection."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Authorization.{Cedar, SystemActor}
  require Ash.Query

  # @cc [owner:ghuntley,label:security;capacity] admin-audit-bounded-projection
  # Audit reads MUST recheck current Control room read authority, return at most 100
  # rows, and expose only actor/target identifiers, action kind and UTC time.
  # Credentials, tokens, request payloads and terminal bytes MUST never escape.
  @impl true
  def run(input, _, %{actor: actor}) do
    if Cedar.allowed?(actor, "admin_read", Cedar.entity("ControlPlane", "marshall")) do
      query =
        AdminEvent
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(input.arguments.limit + 1)

      query =
        if input.arguments.before,
          do: Ash.Query.filter(query, id < ^input.arguments.before),
          else: query

      rows = Ash.read!(query, actor: SystemActor.compute())

      {:ok,
       %{
         items:
           rows
           |> Enum.take(input.arguments.limit)
           |> Enum.map(&Map.take(&1, [:id, :actor_id, :target_id, :kind, :inserted_at])),
         next_cursor:
           if(length(rows) > input.arguments.limit,
             do: Enum.at(rows, input.arguments.limit - 1).id,
             else: nil
           )
       }}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end
end
