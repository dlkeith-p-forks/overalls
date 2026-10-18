defmodule Marshall.Accounts.Profile do
  @moduledoc "Self-service profile preferences: the actor's own time zone."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{Security, TimeZones, User}
  alias Marshall.Compute.Ledger
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] time-zone-self-only
  # set_time_zone MUST update only the row of the authenticated actor, locked
  # inside the ledger transaction through the internal store action. No
  # argument may select another user, and a non-user or retired actor MUST be
  # refused without a write.

  # @cc [owner:ghuntley,label:security] time-zone-validated
  # A supplied zone MUST pass TimeZones.valid?/1 before any write and an
  # invalid one MUST roll back with the closed reason :invalid_time_zone.
  # A nil argument clears the saved zone. The emitted event MUST carry only
  # the user id, never the zone text.
  @impl true
  def run(input, _, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(fn ->
        user = Security.lock_user!(actor.id)
        zone = normalize(input.arguments[:time_zone])
        unless is_nil(zone) or TimeZones.valid?(zone), do: Ledger.rollback(:invalid_time_zone)
        updated = Ledger.update!(user, :store_time_zone, %{time_zone: zone})
        %{user_id: updated.id, time_zone: updated.time_zone}
      end)

    with {:ok, outcome} <- result do
      unless Marshall.Repo.in_transaction?(),
        do: Marshall.Events.emit("account.time_zone_changed", user_id: outcome.user_id)

      {:ok, outcome}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  @spec normalize(term()) :: String.t() | nil
  defp normalize(zone) when is_binary(zone) do
    case String.trim(zone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil
end
