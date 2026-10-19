defmodule OverallsProtocol.PushPoke do
  @moduledoc """
  Content-free, end-to-end encrypted Mila push pokes, format v1 (ADR-0225).

  A poke tells one device that something needs attention and where to open
  it. Marshall seals `{v, kind, route}` to the device's X25519 public key; the
  relay (Susan, ADR-0224) and the push providers see only the opaque result.

      layout     = 0x01 || ephemeral_x25519_public(32) || nonce(12)
                   || chacha20_poly1305_ciphertext || tag(16)
      key        = HKDF-SHA256(ikm = X25519(ephemeral, device),
                               salt = ephemeral_public || device_public,
                               info = "overalls-mila-poke-v1", length = 32)
      aad        = "overalls-mila-poke-v1" || 0x00 || deployment host (ASCII)
      plaintext  = {"kind":KIND,"route":ROUTE,"v":1}, at most 512 bytes

  The wire form is base64url without padding. The shared vectors in
  `test/fixtures/push_pokes.json` are consumed by Mila's Dart and Swift
  decryptors as well as this module.
  """

  alias OverallsProtocol.AppRoute

  @version 1
  @label "overalls-mila-poke-v1"
  @maximum_plaintext 512
  @overhead 1 + 32 + 12 + 16
  @maximum_bytes @overhead + @maximum_plaintext
  @kinds %{"needs_input" => :needs_input}

  @type kind :: :needs_input
  @type payload :: %{kind: kind(), route: String.t()}
  @type open_error :: :encoding | :version | :length | :authentication | :plaintext
  @type seal_error :: :invalid_payload | :invalid_key | :invalid_host
  @type seal_option :: {:ephemeral_private, <<_::256>>} | {:nonce, <<_::96>>}

  @doc "Maximum length of an encoded v1 poke, in base64url characters."
  @spec maximum_encoded_length() :: pos_integer()
  def maximum_encoded_length, do: div(@maximum_bytes * 4 + 2, 3)

  @doc "Closed notification kinds, as wire strings."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@kinds)

  @doc "Derives the X25519 public key for a 32-byte private scalar."
  @spec public_key(<<_::256>>) :: <<_::256>>
  def public_key(<<_::binary-size(32)>> = private) do
    {public, _} = :crypto.generate_key(:ecdh, :x25519, private)
    public
  end

  @doc "Generates a fresh device X25519 key pair `{public, private}` (tests and tooling)."
  @spec generate_key_pair() :: {<<_::256>>, <<_::256>>}
  def generate_key_pair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    {public, private}
  end

  # @cc [owner:ghuntley,label:security;protocol] push-poke-content-free
  # A sealed poke MUST contain only the version, a closed kind and a canonical
  # application route for the bound deployment host, encrypted to the device
  # key with the deployment host in the AAD. Sealing MUST refuse any other
  # plaintext, so prompts, output, names and credentials cannot be sent.
  @doc """
  Seals a payload to a device public key for `host`.

  `:ephemeral_private` and `:nonce` exist for the shared test vectors; normal
  callers let both be generated from the system CSPRNG.
  """
  @spec seal(payload(), binary(), String.t(), [seal_option()]) ::
          {:ok, String.t()} | {:error, seal_error()}
  def seal(payload, device_public, host, options \\ [])

  def seal(%{kind: kind, route: route} = payload, device_public, host, options)
      when map_size(payload) == 2 and is_binary(device_public) and is_list(options) do
    with :ok <- valid_host(host),
         :ok <- valid_device_key(device_public),
         {:ok, plaintext} <- encode_plaintext(kind, route, host),
         {:ok, ephemeral_private, nonce} <- seal_material(options) do
      ephemeral_public = public_key(ephemeral_private)

      case derive_key(ephemeral_private, ephemeral_public, device_public) do
        {:ok, key} ->
          {ciphertext, tag} =
            :crypto.crypto_one_time_aead(
              :chacha20_poly1305,
              key,
              nonce,
              plaintext,
              aad(host),
              true
            )

          bytes =
            <<@version, ephemeral_public::binary, nonce::binary, ciphertext::binary, tag::binary>>

          {:ok, Base.url_encode64(bytes, padding: false)}

        :error ->
          {:error, :invalid_key}
      end
    end
  end

  def seal(_payload, _device_public, _host, _options), do: {:error, :invalid_payload}

  # @cc [owner:ghuntley,label:security;protocol] push-poke-open-authenticated
  # Opening MUST authenticate the ciphertext, ephemeral key, nonce and bound
  # deployment host before any plaintext is interpreted, MUST refuse unknown
  # versions and lengths outside the v1 bounds, and MUST NOT raise on input.
  @doc "Opens an encoded poke with the device private key, for the expected host."
  @spec open(term(), term(), term()) :: {:ok, payload()} | {:error, open_error()}
  def open(poke, <<_::binary-size(32)>> = device_private, host)
      when is_binary(poke) and is_binary(host) do
    with :ok <- valid_host(host) |> map_error(:authentication),
         {:ok, bytes} <- decode(poke),
         {:ok, ephemeral_public, nonce, ciphertext, tag} <- split(bytes),
         device_public = public_key(device_private),
         {:ok, key} <-
           derive_key(device_private, ephemeral_public, ephemeral_public, device_public)
           |> map_error(:authentication),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :chacha20_poly1305,
             key,
             nonce,
             ciphertext,
             aad(host),
             tag,
             false
           ) do
      decode_plaintext(plaintext, host)
    else
      :error -> {:error, :authentication}
      {:error, reason} -> {:error, reason}
    end
  end

  def open(_poke, _device_private, _host), do: {:error, :encoding}

  @doc "The exact v1 plaintext bytes for a payload, or an error when it is not allowed."
  @spec encode_plaintext(term(), term(), term()) :: {:ok, binary()} | {:error, :invalid_payload}
  def encode_plaintext(kind, route, host) do
    with {:ok, name} <- kind_name(kind),
         :ok <- valid_route(route, host) do
      plaintext =
        ~s({"kind":) <> JSON.encode!(name) <> ~s(,"route":) <> JSON.encode!(route) <> ~s(,"v":1})

      if byte_size(plaintext) <= @maximum_plaintext,
        do: {:ok, plaintext},
        else: {:error, :invalid_payload}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp kind_name(kind) when is_atom(kind) do
    case Enum.find(@kinds, fn {_name, value} -> value == kind end) do
      {name, _} -> {:ok, name}
      nil -> :error
    end
  end

  defp kind_name(_), do: :error

  defp decode_plaintext(plaintext, host) do
    with true <- byte_size(plaintext) <= @maximum_plaintext and String.valid?(plaintext),
         {:ok, %{"v" => 1, "kind" => name, "route" => route} = object} <- decode_json(plaintext),
         true <- map_size(object) == 3,
         {:ok, kind} <- Map.fetch(@kinds, name),
         :ok <- valid_route(route, host) do
      {:ok, %{kind: kind, route: route}}
    else
      _ -> {:error, :plaintext}
    end
  end

  defp decode_json(text) do
    JSON.decode(text)
  rescue
    _ -> :error
  end

  defp valid_route(route, host) when is_binary(route) and is_binary(host) do
    link = "overalls://" <> host <> route

    with "/" <> _ <- route,
         {:ok, parsed} <- AppRoute.parse(link),
         ^link <- AppRoute.format(parsed) do
      :ok
    else
      _ -> :error
    end
  end

  defp valid_route(_, _), do: :error

  defp valid_host(host) when is_binary(host) do
    if OverallsProtocol.SSHHostCertificate.hostname?(host), do: :ok, else: {:error, :invalid_host}
  end

  defp valid_host(_), do: {:error, :invalid_host}

  defp valid_device_key(<<_::binary-size(32)>>), do: :ok
  defp valid_device_key(_), do: {:error, :invalid_key}

  defp seal_material(options) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- [:ephemeral_private, :nonce],
         <<_::binary-size(32)>> = ephemeral <-
           Keyword.get_lazy(options, :ephemeral_private, fn -> :crypto.strong_rand_bytes(32) end),
         <<_::binary-size(12)>> = nonce <-
           Keyword.get_lazy(options, :nonce, fn -> :crypto.strong_rand_bytes(12) end) do
      {:ok, ephemeral, nonce}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp decode(poke) do
    if byte_size(poke) <= maximum_encoded_length() + 4 do
      case Base.url_decode64(poke, padding: false) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :encoding}
      end
    else
      {:error, :length}
    end
  end

  defp split(<<version, _::binary>>) when version != @version, do: {:error, :version}

  defp split(bytes) when byte_size(bytes) < @overhead or byte_size(bytes) > @maximum_bytes,
    do: {:error, :length}

  defp split(<<@version, ephemeral::binary-size(32), nonce::binary-size(12), rest::binary>>) do
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    {:ok, ephemeral, nonce, ciphertext, tag}
  end

  # Sender side: ephemeral private with the device public key.
  defp derive_key(ephemeral_private, ephemeral_public, device_public),
    do: derive_key(ephemeral_private, device_public, ephemeral_public, device_public)

  # `private` with `peer` gives the X25519 shared secret; the salt is always
  # ephemeral_public || device_public whichever side derives it.
  defp derive_key(private, peer, salt_ephemeral, salt_device) do
    shared = :crypto.compute_key(:ecdh, peer, private, :x25519)

    if shared == <<0::256>>,
      do: :error,
      else: {:ok, hkdf(shared, salt_ephemeral <> salt_device, @label, 32)}
  rescue
    _ -> :error
  end

  defp aad(host), do: @label <> <<0>> <> host

  defp map_error(:ok, _), do: :ok
  defp map_error({:ok, value}, _), do: {:ok, value}
  defp map_error(_, reason), do: {:error, reason}

  @doc false
  @spec hkdf(binary(), binary(), binary(), pos_integer()) :: binary()
  def hkdf(ikm, salt, info, length) when length <= 255 * 32 do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    {okm, _} =
      Enum.reduce_while(1..255, {<<>>, <<>>}, fn counter, {acc, previous} ->
        if byte_size(acc) >= length do
          {:halt, {acc, previous}}
        else
          block = :crypto.mac(:hmac, :sha256, prk, previous <> info <> <<counter>>)
          {:cont, {acc <> block, block}}
        end
      end)

    binary_part(okm, 0, length)
  end
end
