defmodule Marshall.Ingress.ACME.Material do
  @moduledoc "Validated fleet wildcard TLS material; not an installation acknowledgement."
  require Record

  Record.defrecordp(
    :cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  @derive {Inspect, only: [:hostname, :fingerprint, :expires_at]}
  @enforce_keys [:hostname, :fingerprint, :expires_at, :certificates, :key]
  defstruct [:hostname, :fingerprint, :expires_at, :certificates, :key]

  @type t :: %__MODULE__{
          hostname: binary(),
          fingerprint: binary(),
          expires_at: integer(),
          certificates: [binary()],
          key: tuple()
        }

  # @cc [owner:ghuntley,label:security] fleet-wildcard-tls-material
  # Acceptance MUST validate a bounded certificate path to operator trust, exact
  # wildcard SAN, server authentication usage and private-key possession.
  # Mismatched keys and invalid time bounds MUST fail.
  # Errors and inspection MUST NOT expose private material. Validation alone MUST
  # NOT acknowledge listener installation or authorize route publication.
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, :invalid_tls_material}
  def validate(chain_pem, key_pem, roots_pem, hostname) do
    with true <- hostname?(hostname),
         {:ok, chain} <- certificates(chain_pem, 524_288, 8),
         {:ok, roots} <- certificates(roots_pem, 1_048_576, 256),
         [leaf | _] <- chain,
         decoded = :public_key.pkix_decode_cert(leaf, :otp),
         true <- leaf_usage?(decoded, hostname),
         {:ok, root, public} <- trusted_path(chain, roots),
         true <- is_binary(key_pem) and byte_size(key_pem) in 1..16_384,
         [entry = {kind, _, :not_encrypted}] <- :public_key.pem_decode(key_pem),
         true <- kind in [:ECPrivateKey, :PrivateKeyInfo],
         private = :public_key.pem_entry_decode(entry),
         signature = :public_key.sign("audi-tls-key-possession-v1", :sha256, private),
         true <- :public_key.verify("audi-tls-key-possession-v1", :sha256, signature, public),
         expires = Enum.min(Enum.map([root | chain], &expires_at/1)),
         true <- expires > System.system_time(:second) do
      {:ok,
       %__MODULE__{
         hostname: hostname,
         fingerprint: :crypto.hash(:sha256, leaf) |> Base.encode16(case: :lower),
         expires_at: expires,
         certificates: chain,
         key: {kind, elem(entry, 1)}
       }}
    else
      _ -> {:error, :invalid_tls_material}
    end
  rescue
    _ -> {:error, :invalid_tls_material}
  catch
    _, _ -> {:error, :invalid_tls_material}
  end

  defp hostname?(value) when is_binary(value) and byte_size(value) <= 253 do
    case String.split(value, ".") do
      [label | zone] when zone != [] ->
        Enum.all?([label | zone], fn part ->
          byte_size(part) in 1..63 and
            Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, part)
        end)

      _ ->
        false
    end
  end

  defp hostname?(_), do: false

  defp certificates(pem, maximum, count)
       when is_binary(pem) and byte_size(pem) in 1..maximum//1 do
    entries = :public_key.pem_decode(pem)

    if length(entries) in 1..count and
         Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1)),
       do: {:ok, Enum.map(entries, &elem(&1, 1))},
       else: :error
  end

  defp certificates(_, _, _), do: :error

  defp leaf_usage?(decoded, hostname) do
    extensions = decoded |> cert(:tbsCertificate) |> tbs(:extensions)
    san = get_extension(extensions, {2, 5, 29, 17})
    eku = get_extension(extensions, {2, 5, 29, 37})
    usage = get_extension(extensions, {2, 5, 29, 15})
    constraints = get_extension(extensions, {2, 5, 29, 19})

    expected = [{:dNSName, String.to_charlist("*." <> hostname)}]

    is_list(san) and san == expected and
      is_list(eku) and {1, 3, 6, 1, 5, 5, 7, 3, 1} in eku and
      is_list(usage) and :digitalSignature in usage and :keyCertSign not in usage and
      (constraints == nil or constraints == {:BasicConstraints, false, :asn1_NOVALUE})
  end

  defp get_extension(extensions, id) do
    case Enum.filter(extensions, &(extension(&1, :extnID) == id)) do
      [value] -> extension(value, :extnValue)
      [] -> nil
      _ -> :duplicate
    end
  end

  defp trusted_path(chain, roots) do
    Enum.find_value(roots, :error, fn root ->
      path = if List.last(chain) == root, do: Enum.drop(chain, -1), else: chain

      if path != [] do
        case :public_key.pkix_path_validation(root, Enum.reverse(path), max_path_length: 6) do
          {:ok,
           {{{1, 2, 840, 10045, 2, 1}, key, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}} = params},
            _}} ->
            {:ok, root, {key, params}}

          _ ->
            nil
        end
      end
    end)
  end

  defp expires_at(der) do
    time =
      der
      |> :public_key.pkix_decode_cert(:otp)
      |> cert(:tbsCertificate)
      |> tbs(:validity)
      |> validity(:notAfter)

    text =
      case time do
        {:utcTime, [a, b | rest]} ->
          prefix = if [a, b] < ~c"50", do: ~c"20", else: ~c"19"
          List.to_string(prefix ++ [a, b | rest])

        {:generalTime, chars} ->
          List.to_string(chars)
      end

    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2), "Z">> = text

    {:ok, date, 0} = DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")
    DateTime.to_unix(date)
  end
end
