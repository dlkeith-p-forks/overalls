defmodule Marshall.Accounts.ValidTimeZone do
  @moduledoc "Resource-level guard: a stored time zone is nil or a resolvable IANA identifier."
  use Ash.Resource.Validation
  alias Marshall.Accounts.TimeZones

  @impl true
  def describe(_opts), do: [message: "must be a known time zone", vars: []]

  # @cc [owner:ghuntley,label:security] stored-time-zone-resolvable
  # The internal store action MUST refuse any non-nil time zone that the
  # compiled database cannot resolve, so a bypass of the profile coordinator
  # still cannot persist an unusable identifier.
  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :time_zone) do
      nil -> :ok
      zone -> if TimeZones.valid?(zone), do: :ok, else: {:error, field: :time_zone}
    end
  end
end
