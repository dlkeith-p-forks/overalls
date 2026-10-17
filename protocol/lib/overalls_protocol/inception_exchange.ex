defmodule OverallsProtocol.InceptionExchange do
  @moduledoc "Bounded boot-bound child publication; contains no parent credentials or destinations."
  alias OverallsProtocol.{IngressName, Readiness, SSHKey}
  @maximum 262_144
  @maximum_records 256
  @integer_max 9_223_372_036_854_775_807

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum
  @spec maximum_records() :: pos_integer()
  def maximum_records, do: @maximum_records
  @spec port() :: pos_integer()
  def port, do: 1028

  # @cc [owner:ghuntley,label:security] inception-publication-scope
  # Decode MUST bound bytes before JSON parsing and accept only a closed v1
  # publication. Child records may name control or canonical workload labels;
  # the empty label is reserved for a proof-only apps-zone wildcard challenge,
  # never arbitrary DNS names, addresses, ports, credentials or NS delegations.
  # TXT proofs and SSH keys MUST be bounded and validated; duplicate labels fail.
  # The remaining TTL MUST be 1..5000 milliseconds and may only shorten the
  # parent offer deadline. It MUST NOT establish a fresh receipt-time lifetime.
  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_inception_publication}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum do
    with {:ok, value} <- JSON.decode(bytes), true <- valid?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_inception_publication}
    end
  end

  def decode(_), do: {:error, :invalid_inception_publication}

  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid_inception_publication}
  def encode(value) do
    if valid?(value) do
      bytes = JSON.encode!(value)

      if byte_size(bytes) <= @maximum,
        do: {:ok, bytes},
        else: {:error, :invalid_inception_publication}
    else
      {:error, :invalid_inception_publication}
    end
  end

  # @cc [owner:ghuntley,label:security] inception-publication-request-correlation
  # Verification MUST bind the exact placement, epoch, boot challenge, request
  # UUID and environment generation. Valid syntax alone MUST NOT accept an old
  # poll or another environment's reply. Callers must independently verify live
  # placement ownership and impose authority expiry from the poll's start time.
  @spec verify(term(), Readiness.expectation(), binary(), pos_integer()) ::
          {:ok, map()} | {:error, :invalid_inception_publication | :stale_inception_publication}
  def verify(bytes, boot, request_id, generation) do
    with {:ok, value} <- decode(bytes) do
      expected = Map.new(boot, fn {key, value} -> {Atom.to_string(key), value} end)

      if value["binding"] == expected and value["request_id"] == request_id and
           value["generation"] == generation do
        {:ok, value}
      else
        {:error, :stale_inception_publication}
      end
    end
  end

  defp valid?(
         %{
           "version" => 1,
           "binding" => binding,
           "request_id" => request,
           "generation" => generation,
           "ttl_ms" => ttl,
           "porsche_host_key" => porsche,
           "audi_host_key" => audi,
           "records" => records
         } = value
       )
       when map_size(value) == 8 do
    binding?(binding) and OverallsProtocol.uuid?(request) and
      is_integer(generation) and generation in 1..@integer_max and
      is_integer(ttl) and ttl in 1..5000 and
      key?(porsche) and key?(audi) and is_list(records) and
      length(records) <= @maximum_records and Enum.all?(records, &record?/1) and
      length(Enum.uniq_by(records, & &1["label"])) == length(records)
  end

  defp valid?(_), do: false

  defp binding?(
         %{"placement_id" => placement, "execution_epoch" => epoch, "boot_challenge" => challenge} =
           value
       )
       when map_size(value) == 3 do
    match?(
      {:ok, _},
      Readiness.response(%{
        "version" => 1,
        "state" => "ready",
        "placement_id" => placement,
        "execution_epoch" => epoch,
        "boot_challenge" => challenge,
        "boot_id" => placement
      })
    )
  end

  defp binding?(_), do: false

  defp key?(nil), do: true

  defp key?(key) when is_binary(key) and byte_size(key) <= 8192,
    do: match?({:ok, _}, SSHKey.parse(key))

  defp key?(_), do: false

  defp record?(%{"label" => label, "ready" => ready, "proofs" => proofs} = value)
       when map_size(value) == 3 do
    (label == "control" or IngressName.valid_label?(label) or
       (label == "" and ready == false and proofs != [])) and is_boolean(ready) and
      is_list(proofs) and length(proofs) <= 2 and Enum.all?(proofs, &proof?/1) and
      Enum.uniq(proofs) == proofs
  end

  defp record?(_), do: false

  defp proof?(proof) when is_binary(proof) and byte_size(proof) == 43 do
    case Base.url_decode64(proof, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == proof

      _ ->
        false
    end
  end

  defp proof?(_), do: false
end
