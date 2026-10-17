defmodule OverallsProtocol.KernelAttestation do
  @moduledoc "Closed, boot-bound evidence for a native guest kernel."

  @maximum_epoch 9_223_372_036_854_775_807
  @type os :: :freebsd | :illumos
  @type expectation :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          boot_challenge: String.t(),
          os: os(),
          kernel_sha256: String.t()
        }
  @type observation :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          boot_challenge: String.t(),
          boot_id: OverallsProtocol.uuid(),
          os: os(),
          kernel_sha256: String.t()
        }
  @type failure :: {:error, :invalid_message | :unsupported_version | :stale_attestation}

  # @cc [owner:ghuntley,label:protocol;security] native-kernel-attestation-closed
  # response/1 MUST accept only the bounded v1 native-kernel response with a
  # finite OS, canonical boot identity and lowercase SHA-256 kernel digest.
  # Peer fields MUST never become atoms, and a syntactically valid response is
  # evidence only after verify/2 correlates every expected boot and kernel field.
  @spec response(term()) :: {:ok, observation()} | failure()
  def response(
        %{
          "version" => 1,
          "state" => "attested",
          "os" => os,
          "placement_id" => placement,
          "execution_epoch" => epoch,
          "boot_challenge" => challenge,
          "boot_id" => boot,
          "kernel_sha256" => digest
        } = value
      )
      when map_size(value) == 8 do
    with {:ok, os} <- parse_os(os),
         true <- OverallsProtocol.uuid?(placement),
         true <- OverallsProtocol.uuid?(boot),
         true <- is_integer(epoch) and epoch in 1..@maximum_epoch,
         true <- challenge?(challenge),
         true <- digest?(digest) do
      {:ok,
       %{
         placement_id: placement,
         execution_epoch: epoch,
         boot_challenge: challenge,
         boot_id: boot,
         os: os,
         kernel_sha256: digest
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def response(%{"version" => version}) when version != 1,
    do: {:error, :unsupported_version}

  def response(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:security;recovery] native-kernel-attestation-binds-identity
  # verify/2 MUST reject any placement, epoch, challenge, OS or kernel digest
  # other than the current locally validated native image and boot expectation.
  @spec verify(term(), expectation()) :: {:ok, OverallsProtocol.uuid()} | failure()
  def verify(value, expectation) do
    with {:ok, observed} <- response(value),
         true <-
           Map.take(observed, [
             :placement_id,
             :execution_epoch,
             :boot_challenge,
             :os,
             :kernel_sha256
           ]) ==
             Map.take(expectation, [
               :placement_id,
               :execution_epoch,
               :boot_challenge,
               :os,
               :kernel_sha256
             ]) do
      {:ok, observed.boot_id}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_attestation}
    end
  end

  @spec parse_os(term()) :: {:ok, os()} | {:error, :invalid_message}
  def parse_os("freebsd"), do: {:ok, :freebsd}
  def parse_os("illumos"), do: {:ok, :illumos}
  def parse_os(_), do: {:error, :invalid_message}

  defp challenge?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp challenge?(_), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false
end
