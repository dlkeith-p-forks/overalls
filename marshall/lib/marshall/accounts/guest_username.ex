defmodule Marshall.Accounts.GuestUsername do
  @moduledoc "Canonical Linux account names derived only from durable guest UIDs."

  # @cc [owner:ghuntley,label:security] guest-username-durable-uid
  # The Linux login MUST be u followed by the exact decimal durable UID.
  # Values outside the allocated integer range MUST fail closed; email or
  # another human-selected string MUST NOT participate in guest naming.
  @spec from_uid(term()) :: {:ok, String.t()} | :error
  def from_uid(uid) when is_integer(uid) and uid in 200_000..999_999 do
    {:ok, "u" <> Integer.to_string(uid)}
  end

  def from_uid(_), do: :error
end
