defmodule Susan.Keyring do
  @moduledoc """
  The push-key sealing keyring (`SUSAN_PUSH_KEY_SIGNING_KEY`).

  The secret is a JSON document `{"active": N, "keys": {"N": "<base64url 32
  bytes>", ...}}` with integer key ids 1..255. New push keys are sealed with
  the active key; every listed key still opens envelopes it sealed, so a
  rotation adds a key, makes it active and later removes the retired one once
  its envelopes have expired (90 days).
  """

  @enforce_keys [:active, :keys]
  defstruct [:active, :keys]

  @type id :: 1..255
  @type t :: %__MODULE__{active: id(), keys: %{id() => <<_::256>>}}

  # @cc [owner:ghuntley,label:security] susan-keyring-closed-shape
  # The keyring MUST hold 1..16 distinct 32-byte keys with integer ids 1..255
  # and an active id that is present. Any other shape MUST be refused without
  # echoing key material.
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(encoded) when is_binary(encoded) and byte_size(encoded) <= 8192 do
    with {:ok, %{"active" => active, "keys" => keys} = document} <- JSON.decode(encoded),
         true <- Map.keys(document) -- ["active", "keys"] == [],
         true <- is_integer(active) and active in 1..255,
         true <- is_map(keys) and map_size(keys) in 1..16,
         {:ok, decoded} <- decode_keys(keys),
         true <- Map.has_key?(decoded, active),
         true <- decoded |> Map.values() |> Enum.uniq() |> length() == map_size(decoded) do
      {:ok, %__MODULE__{active: active, keys: decoded}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @spec fetch(t(), integer()) :: {:ok, <<_::256>>} | :error
  def fetch(%__MODULE__{keys: keys}, id) do
    case Map.fetch(keys, id) do
      {:ok, key} -> {:ok, key}
      :error -> :error
    end
  end

  @doc "A subkey for a fixed purpose, derived from the active key with HMAC-SHA256."
  @spec derive(t(), String.t()) :: <<_::256>>
  def derive(%__MODULE__{active: active, keys: keys}, purpose) when is_binary(purpose),
    do: :crypto.mac(:hmac, :sha256, Map.fetch!(keys, active), "susan/v1/" <> purpose)

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn
      {id, value}, {:ok, acc} when is_binary(id) and is_binary(value) ->
        with true <- Regex.match?(~r/\A[1-9][0-9]{0,2}\z/, id),
             number when number in 1..255 <- String.to_integer(id),
             {:ok, <<_::256>> = key} <- Base.url_decode64(value, padding: false) do
          {:cont, {:ok, Map.put(acc, number, key)}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defimpl Inspect do
    def inspect(%{active: active, keys: keys}, _opts),
      do: "#Susan.Keyring<active: #{active}, ids: #{inspect(Enum.sort(Map.keys(keys)))}>"
  end
end
