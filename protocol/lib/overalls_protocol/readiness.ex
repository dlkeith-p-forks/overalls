defmodule OverallsProtocol.Readiness do
  @moduledoc "Guest boot evidence only; never execution, transfer or cleanup authorization."
  @maximum 9_223_372_036_854_775_807
  @type expectation :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          boot_challenge: String.t()
        }
  @type observation :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          boot_challenge: String.t(),
          boot_id: OverallsProtocol.uuid()
        }
  @type failure :: {:error, :invalid_message | :unsupported_version | :stale_readiness}

  # @cc [owner:ghuntley,label:protocol;security] readiness-closed-boot-evidence
  # response/1 MUST accept only the closed v1 ready response with canonical placement,
  # positive bounded epoch, 32-byte lowercase hex boot challenge and kernel boot UUID.
  # Callers MUST correlate this evidence with their persisted current boot expectation
  # and observed VMM identity; a syntactically valid response is not cleanup authority.
  @spec response(term()) :: {:ok, observation()} | failure()
  def response(
        %{
          "version" => 1,
          "state" => "ready",
          "placement_id" => placement,
          "execution_epoch" => epoch,
          "boot_challenge" => challenge,
          "boot_id" => boot
        } = value
      )
      when map_size(value) == 6 do
    if OverallsProtocol.uuid?(placement) and OverallsProtocol.uuid?(boot) and
         is_integer(epoch) and epoch in 1..@maximum and challenge?(challenge) do
      {:ok,
       %{
         placement_id: placement,
         execution_epoch: epoch,
         boot_challenge: challenge,
         boot_id: boot
       }}
    else
      {:error, :invalid_message}
    end
  end

  def response(%{"version" => version}) when version != 1,
    do: {:error, :unsupported_version}

  def response(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:recovery] readiness-correlates-entire-boot
  # verify/2 MUST reject evidence for any other placement, epoch or boot challenge,
  # including a prior boot of the same placement and epoch. The trusted expectation
  # MUST be persisted before launch, and a new physical boot MUST get a fresh challenge.
  @spec verify(term(), expectation()) :: {:ok, OverallsProtocol.uuid()} | failure()
  def verify(value, expectation) do
    with {:ok, observed} <- response(value) do
      if Map.take(observed, [:placement_id, :execution_epoch, :boot_challenge]) == expectation,
        do: {:ok, observed.boot_id},
        else: {:error, :stale_readiness}
    end
  end

  defp challenge?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp challenge?(_), do: false
end
