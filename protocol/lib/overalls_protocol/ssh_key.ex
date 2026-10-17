defmodule OverallsProtocol.SSHKey do
  @moduledoc "Bounded OpenSSH user public keys, independent of account authority."
  @maximum 4096
  @type t :: %{public_key: binary(), fingerprint: binary(), algorithm: binary()}

  # @cc [owner:ghuntley,label:security] ssh-user-key-canonical-identity
  # Parsing MUST accept exactly one supported public key, reject private keys,
  # certificates and authorized_keys options, and derive identity from the full
  # validated wire blob, never its comment. Peer values MUST NOT create atoms.
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_public_key}
  def parse(value) when is_binary(value) and byte_size(value) <= @maximum do
    if String.valid?(value) do
      case String.split(String.trim(value), ~r/[ \t]+/, parts: 3) do
        [algorithm, encoded | comment] ->
          with true <- Enum.all?(comment, &single_line?/1),
               {:ok, blob} <- Base.decode64(encoded),
               true <- Base.encode64(blob) == encoded,
               {:ok, %{algorithm: ^algorithm} = key} <- from_blob(blob) do
            {:ok, key}
          else
            _ -> {:error, :invalid_public_key}
          end

        _ ->
          {:error, :invalid_public_key}
      end
    else
      {:error, :invalid_public_key}
    end
  end

  def parse(_), do: {:error, :invalid_public_key}

  @spec from_blob(term()) :: {:ok, t()} | {:error, :invalid_public_key}
  def from_blob(blob) when is_binary(blob) and byte_size(blob) <= @maximum do
    with {:ok, algorithm, rest} <- field(blob),
         true <- valid?(algorithm, rest) do
      {:ok,
       %{
         algorithm: algorithm,
         public_key: algorithm <> " " <> Base.encode64(blob),
         fingerprint: "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
       }}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  def from_blob(_), do: {:error, :invalid_public_key}

  defp valid?("ssh-ed25519", <<32::32, _key::binary-size(32)>>), do: true

  defp valid?("ssh-rsa", rest) do
    with {:ok, exponent, rest} <- field(rest),
         {:ok, modulus, <<>>} <- field(rest),
         {:ok, e} <- positive_integer(exponent),
         {:ok, n} <- positive_integer(modulus) do
      e >= 3 and e <= 0xFFFFFFFF and rem(e, 2) == 1 and
        n >= Bitwise.bsl(1, 2047) and n < Bitwise.bsl(1, 8192) and rem(n, 2) == 1
    else
      _ -> false
    end
  end

  defp valid?("ecdsa-sha2-" <> curve, rest)
       when curve in ["nistp256", "nistp384", "nistp521"] do
    size =
      case curve do
        "nistp256" -> 65
        "nistp384" -> 97
        "nistp521" -> 133
      end

    with {:ok, ^curve, rest} <- field(rest),
         {:ok, <<4, _::binary>> = point, <<>>} <- field(rest) do
      byte_size(point) == size
    else
      _ -> false
    end
  end

  defp valid?(_, _), do: false

  defp field(<<size::32, value::binary-size(size), rest::binary>>), do: {:ok, value, rest}
  defp field(_), do: :error

  defp positive_integer(<<0, first, _::binary>> = bytes) when first >= 128,
    do: {:ok, :binary.decode_unsigned(bytes)}

  defp positive_integer(<<first, _::binary>> = bytes) when first in 1..127,
    do: {:ok, :binary.decode_unsigned(bytes)}

  defp positive_integer(_), do: :error

  defp single_line?(value),
    do: String.printable?(value) and not String.contains?(value, ["\n", "\r"])
end
