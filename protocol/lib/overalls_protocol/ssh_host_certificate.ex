defmodule OverallsProtocol.SSHHostCertificate do
  @moduledoc "Bounded Ed25519 OpenSSH host certificates; never user authentication keys."
  alias OverallsProtocol.SSHKey
  @algorithm "ssh-ed25519-cert-v01@openssh.com"
  @maximum 16_384
  @type t :: %{
          public_key: binary(),
          ca: binary(),
          principals: [binary()],
          serial: non_neg_integer(),
          valid_after: non_neg_integer(),
          valid_before: non_neg_integer(),
          key_id: binary(),
          signed: binary(),
          signature: binary(),
          blob: binary()
        }

  @spec algorithm() :: binary()
  def algorithm, do: @algorithm

  # @cc [owner:ghuntley,label:security] ssh-host-certificate-closed-format
  # Certificates MUST be bounded Ed25519 host certificates with nonempty exact
  # DNS principals, an Ed25519 CA, and no options, extensions or trailing bytes.
  # Parsing MUST NOT imply signature verification or user-key authorization.
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_certificate}
  def parse(line) when is_binary(line) and byte_size(line) <= @maximum do
    with [@algorithm, encoded | _comment] <- String.split(String.trim(line), ~r/[ \t]+/, parts: 3),
         {:ok, blob} <- Base.decode64(encoded),
         true <- Base.encode64(blob) == encoded,
         {:ok, @algorithm, rest} <- field(blob),
         {:ok, nonce, rest} <- field(rest),
         true <- byte_size(nonce) in 16..64,
         {:ok, key, <<serial::64, 2::32, rest::binary>>} <- field(rest),
         true <- byte_size(key) == 32,
         {:ok, id, rest} <- field(rest),
         true <- byte_size(id) in 1..128 and String.valid?(id),
         {:ok, names, <<after_time::64, before_time::64, rest::binary>>} <- field(rest),
         {:ok, principals} <- principals(names, []),
         true <- after_time < before_time,
         {:ok, "", rest} <- field(rest),
         {:ok, "", rest} <- field(rest),
         {:ok, "", rest} <- field(rest),
         {:ok, ca, signature_field} <- field(rest),
         {:ok, %{algorithm: "ssh-ed25519", public_key: ca_line}} <- SSHKey.from_blob(ca),
         {:ok, signature_blob, ""} <- field(signature_field),
         {:ok, "ssh-ed25519", signature_blob} <- field(signature_blob),
         {:ok, signature, ""} <- field(signature_blob),
         true <- byte_size(signature) == 64,
         {:ok, public} <- SSHKey.from_blob(string("ssh-ed25519") <> string(key)) do
      {:ok,
       %{
         public_key: public.public_key,
         ca: ca_line,
         principals: principals,
         serial: serial,
         valid_after: after_time,
         valid_before: before_time,
         key_id: id,
         signed: binary_part(blob, 0, byte_size(blob) - byte_size(signature_field)),
         signature: signature,
         blob: blob
       }}
    else
      _ -> {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  def parse(_), do: {:error, :invalid_certificate}

  # @cc [owner:ghuntley,label:security] ssh-host-certificate-exact-authority
  # Verification MUST bind the expected CA, leaf key, exact principal and current
  # validity interval, and cryptographically verify the complete certificate.
  @spec verify(term(), binary(), binary(), binary(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_certificate}
  def verify(line, ca, key, principal, now) do
    with {:ok, cert} <- parse(line),
         true <- cert.ca == ca and cert.public_key == key and principal in cert.principals,
         true <- now >= cert.valid_after and now < cert.valid_before,
         {:ok, raw_ca} <- ed25519(ca),
         true <- :crypto.verify(:eddsa, :none, cert.signed, cert.signature, [raw_ca, :ed25519]) do
      {:ok, cert}
    else
      _ -> {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  @spec issue(
          binary(),
          binary(),
          binary(),
          [binary()],
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, binary()} | {:error, :invalid_certificate}
  def issue(key, ca, seed, principals, serial, id, after_time, before_time)
      when byte_size(seed) == 32 and serial >= 0 and serial < 18_446_744_073_709_551_616 do
    with {:ok, leaf} <- ed25519(key),
         {:ok, issuer} <- ed25519(ca),
         {^issuer, _} <- :crypto.generate_key(:eddsa, :ed25519, seed),
         true <-
           principals != [] and length(principals) <= 8 and Enum.all?(principals, &hostname?/1),
         true <- byte_size(id) in 1..128 and after_time >= 0 and before_time > after_time do
      ca_blob = string("ssh-ed25519") <> string(issuer)

      signed =
        string(@algorithm) <>
          string(:crypto.strong_rand_bytes(32)) <>
          string(leaf) <>
          <<serial::64, 2::32>> <>
          string(id) <>
          string(Enum.map_join(principals, &string/1)) <>
          <<after_time::64, before_time::64>> <>
          string("") <> string("") <> string("") <> string(ca_blob)

      signature = :crypto.sign(:eddsa, :none, signed, [seed, :ed25519])

      {:ok,
       @algorithm <>
         " " <>
         Base.encode64(signed <> string(string("ssh-ed25519") <> string(signature))) <> "\n"}
    else
      _ -> {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  def issue(_, _, _, _, _, _, _, _), do: {:error, :invalid_certificate}

  @spec valid_blob?(binary(), binary(), non_neg_integer()) :: boolean()
  def valid_blob?(blob, key, now) do
    line = @algorithm <> " " <> Base.encode64(blob)

    with {:ok, cert} <- parse(line),
         [principal] <- cert.principals,
         {:ok, _} <- verify(line, cert.ca, key, principal, now),
         do: true,
         else: (_ -> false)
  end

  @spec ed25519(term()) :: {:ok, binary()} | {:error, :invalid_public_key}
  def ed25519(line) do
    with {:ok, %{algorithm: "ssh-ed25519", public_key: canonical}} <- SSHKey.parse(line),
         [_, encoded] <- String.split(canonical, " "),
         {:ok, <<11::32, "ssh-ed25519", 32::32, key::binary-size(32)>>} <- Base.decode64(encoded),
         do: {:ok, key},
         else: (_ -> {:error, :invalid_public_key})
  end

  @spec hostname?(term()) :: boolean()
  def hostname?(name) when is_binary(name) and byte_size(name) in 1..253 do
    String.split(name, ".")
    |> Enum.all?(&Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))
  end

  def hostname?(_), do: false

  @spec gateway_principal(binary(), binary()) :: {:ok, binary()} | {:error, :invalid_public_key}
  def gateway_principal(key, origin_host) do
    with {:ok, raw} <- ed25519(key), true <- hostname?(origin_host) do
      digest =
        :crypto.hash(:sha256, string("ssh-ed25519") <> string(raw))
        |> Base.encode32(case: :lower, padding: false)

      name = "audi-" <> digest <> ".ssh." <> origin_host
      if hostname?(name), do: {:ok, name}, else: {:error, :invalid_public_key}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  defp principals("", names) when names != [], do: {:ok, Enum.reverse(names)}

  defp principals(bytes, names) when length(names) < 8 do
    with {:ok, name, rest} <- field(bytes),
         true <- hostname?(name) and name not in names,
         do: principals(rest, [name | names]),
         else: (_ -> {:error, :invalid_certificate})
  end

  defp principals(_, _), do: {:error, :invalid_certificate}
  defp field(<<length::32, value::binary-size(length), rest::binary>>), do: {:ok, value, rest}
  defp field(_), do: :error
  defp string(value), do: <<byte_size(value)::32, value::binary>>
end
