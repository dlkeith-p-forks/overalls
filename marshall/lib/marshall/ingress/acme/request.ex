defmodule Marshall.Ingress.ACME.Request do
  @moduledoc "Fresh fleet wildcard P-256 key and narrowly scoped PKCS#10 request."
  require Record

  for {local, name} <- [
        ec: :ECPrivateKey,
        info: :CertificationRequestInfo,
        spki: :CertificationRequestInfo_subjectPKInfo,
        algorithm: :CertificationRequestInfo_subjectPKInfo_algorithm,
        attribute: :CertificationRequestInfo_attributes_SETOF,
        signature_algorithm: :CertificationRequest_signatureAlgorithm,
        request: :CertificationRequest,
        extension: :Extension
      ] do
    Record.defrecordp(
      local,
      name,
      Record.extract(name, from_lib: "public_key/include/public_key.hrl")
    )
  end

  @derive {Inspect, only: [:hostname]}
  @enforce_keys [:hostname, :der, :private_key_pem]
  defstruct [:hostname, :der, :private_key_pem]
  @type t :: %__MODULE__{hostname: binary(), der: binary(), private_key_pem: binary()}
  @curve {1, 2, 840, 10045, 3, 1, 7}

  # @cc [owner:ghuntley,label:security;protocol] fleet-csr-wildcard-scope
  # Each request MUST generate a fresh P-256 key and prove possession in PKCS#10.
  # Its only requested extension MUST be SAN with exactly the canonical
  # fleet wildcard. Arbitrary names and
  # caller-supplied extensions MUST NOT be accepted. Inspection/errors MUST omit
  # private key material. Generation is not certificate issuance or installation.
  @spec generate(term()) :: {:ok, t()} | {:error, :invalid_certificate_request}
  def generate(hostname) do
    if hostname?(hostname) do
      key = :public_key.generate_key({:namedCurve, @curve})

      info = request_info(hostname, key)

      signed =
        :public_key.sign(:public_key.der_encode(:CertificationRequestInfo, info), :sha256, key)

      der =
        :public_key.der_encode(
          :CertificationRequest,
          request(
            certificationRequestInfo: info,
            signatureAlgorithm: signature_algorithm(algorithm: {1, 2, 840, 10045, 4, 3, 2}),
            signature: signed
          )
        )

      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
      {:ok, %__MODULE__{hostname: hostname, der: der, private_key_pem: pem}}
    else
      {:error, :invalid_certificate_request}
    end
  rescue
    _ -> {:error, :invalid_certificate_request}
  catch
    _, _ -> {:error, :invalid_certificate_request}
  end

  # @cc [owner:ghuntley,label:security;recovery] fleet-csr-recovery-binding
  # Restoring a saved request MUST preserve its exact DER and key, validate its
  # signature and require the same canonical subject, algorithm, SANs and key
  # identity as a newly generated request. Mismatched or malformed material MUST
  # fail without generating a replacement key or exposing saved bytes in errors.
  @spec restore(term(), term(), term()) :: {:ok, t()} | {:error, :invalid_certificate_request}
  def restore(hostname, der, pem) do
    with true <- hostname?(hostname),
         true <- is_binary(der) and byte_size(der) in 1..16_384,
         true <- is_binary(pem) and byte_size(pem) in 1..16_384,
         [entry = {:ECPrivateKey, _, :not_encrypted}] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         {:namedCurve, @curve} <- ec(key, :parameters),
         private when is_binary(private) and byte_size(private) == 32 <- ec(key, :privateKey),
         {public, _} <- :crypto.generate_key(:ecdh, :secp256r1, private),
         true <- public == ec(key, :publicKey),
         decoded <- :public_key.der_decode(:CertificationRequest, der),
         true <- :public_key.der_encode(:CertificationRequest, decoded) == der,
         info <- request(decoded, :certificationRequestInfo),
         true <-
           :public_key.der_encode(:CertificationRequestInfo, info) ==
             :public_key.der_encode(:CertificationRequestInfo, request_info(hostname, key)),
         true <-
           request(decoded, :signatureAlgorithm) ==
             signature_algorithm(algorithm: {1, 2, 840, 10045, 4, 3, 2}),
         true <-
           :public_key.verify(
             :public_key.der_encode(:CertificationRequestInfo, info),
             :sha256,
             request(decoded, :signature),
             {{:ECPoint, public}, {:namedCurve, @curve}}
           ) do
      {:ok, %__MODULE__{hostname: hostname, der: der, private_key_pem: pem}}
    else
      _ -> {:error, :invalid_certificate_request}
    end
  rescue
    _ -> {:error, :invalid_certificate_request}
  catch
    _, _ -> {:error, :invalid_certificate_request}
  end

  defp request_info(hostname, key) do
    sans = [{:dNSName, String.to_charlist("*." <> hostname)}]

    extensions =
      :public_key.der_encode(:Extensions, [
        extension(
          extnID: {2, 5, 29, 17},
          critical: true,
          extnValue: :public_key.der_encode(:SubjectAltName, sans)
        )
      ])

    info(
      version: :v1,
      subject: {:rdnSequence, []},
      subjectPKInfo:
        spki(
          algorithm:
            algorithm(
              algorithm: {1, 2, 840, 10045, 2, 1},
              parameters:
                {:asn1_OPENTYPE, :public_key.der_encode(:EcpkParameters, {:namedCurve, @curve})}
            ),
          subjectPublicKey: ec(key, :publicKey)
        ),
      attributes: [
        attribute(
          type: {1, 2, 840, 113_549, 1, 9, 14},
          values: [{:asn1_OPENTYPE, extensions}]
        )
      ]
    )
  end

  defp hostname?(value) when is_binary(value) and byte_size(value) <= 251 do
    if String.valid?(value) do
      labels = String.split(value, ".")

      length(labels) >= 2 and
        Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))
    else
      false
    end
  end

  defp hostname?(_), do: false
end
