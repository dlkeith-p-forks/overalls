defmodule Marshall.Vault do
  @moduledoc "Encryption for credentials and transient secret payloads, with a tagged rotation keyring."
  use Cloak.Vault, otp_app: :marshall

  # @cc [owner:ghuntley,label:security] vault-explicit-development-key
  # Missing MARSHALL_CLOAK_KEYS MUST fail startup unless development-key use was
  # explicitly enabled. Supplying an invalid keyring MUST fail even when that
  # development option is enabled, never silently fall back to the zero key.
  @impl GenServer
  def init(config) do
    encoded = System.get_env("MARSHALL_CLOAK_KEYS")

    ciphers =
      cond do
        is_binary(encoded) ->
          keyring!(encoded)

        Keyword.get(config, :allow_development_key, false) ->
          [
            default:
              {Cloak.Ciphers.AES.GCM, tag: "development-only", key: :binary.copy(<<0>>, 32)}
          ]

        true ->
          raise "MARSHALL_CLOAK_KEYS is required"
      end

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end

  # @cc [owner:ghuntley,label:security] vault-tagged-ordered-keyring
  # A keyring MUST contain 1..16 uniquely tagged 32-byte keys; its first key
  # encrypts new values while retained tags decrypt existing ciphertext. Invalid
  # input MUST raise a fixed error containing no encoded or decoded key material.
  @doc "Parses an ordered JSON keyring. Errors never include key material."
  @spec keyring!(String.t()) :: keyword()
  def keyring!(encoded) do
    with {:ok, entries} when is_list(entries) and length(entries) in 1..16 <- JSON.decode(encoded),
         {:ok, ciphers, ids} <- parse_entries(entries),
         true <- length(ids) == length(Enum.uniq(ids)) do
      ciphers
    else
      _ -> raise ArgumentError, "invalid MARSHALL_CLOAK_KEYS keyring"
    end
  end

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, [], []}, fn entry, {:ok, ciphers, ids} ->
      with %{"id" => id, "key" => encoded} when map_size(entry) == 2 <- entry,
           true <- is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,32}\z/, id),
           true <- is_binary(encoded),
           {:ok, key} when byte_size(key) == 32 <- Base.decode64(encoded) do
        cipher = {:default, {Cloak.Ciphers.AES.GCM, tag: "marshall:#{id}", key: key}}
        {:cont, {:ok, ciphers ++ [cipher], [id | ids]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end
end
