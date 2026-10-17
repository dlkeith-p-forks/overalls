defmodule Marshall.SSH.KeyRegistry do
  @moduledoc "Canonical active-key recognition shared by SSH entry points."
  alias Marshall.Authorization.SystemActor
  alias Marshall.SSH.Key
  require Ash.Query

  # @cc [owner:ghuntley,label:security] ssh-active-key-recognition
  # Recognition MUST use the archival-filtered resource and compare the exact
  # canonical public key. Recognition alone MUST NOT grant user or VM authority.
  # Admission callers MUST retain their existing row-lock ordering.
  @spec find(OverallsProtocol.SSHKey.t(), :none | :share) :: Key.t() | nil
  def find(parsed, lock \\ :none) do
    query = Ash.Query.filter(Key, fingerprint == ^parsed.fingerprint)
    query = if lock == :share, do: Ash.Query.lock(query, "FOR SHARE"), else: query

    case Ash.read_one!(query, actor: SystemActor.compute()) do
      %{public_key: public_key} = key when public_key == parsed.public_key -> key
      _ -> nil
    end
  end
end
