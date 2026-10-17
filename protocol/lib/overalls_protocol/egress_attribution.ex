defmodule OverallsProtocol.EgressAttribution do
  @moduledoc "Versioned fixed-size local attribution messages; no execution authority."
  @maximum 9_223_372_036_854_775_807
  @type endpoint :: {{byte(), byte(), byte(), byte()}, 1..65_535}
  @type flow :: %{source: endpoint(), destination: endpoint()}

  @spec maximum() :: 256
  def maximum, do: 256

  # @cc [owner:ghuntley,label:protocol;security] egress-wire-closed-tuple
  # Requests MUST contain only version 1 and both IPv4 TCP endpoints, including
  # nonzero ports. Unknown versions, missing bytes and trailing bytes MUST fail.
  @spec request(flow()) :: binary()
  def request(%{source: {{a, b, c, d}, left}, destination: {{e, f, g, h}, right}}),
    do: <<1, a, b, c, d, left::16, e, f, g, h, right::16>>

  @spec decode_request(term()) :: {:ok, flow()} | {:error, :invalid_message}
  def decode_request(<<1, a, b, c, d, left::16, e, f, g, h, right::16>>)
      when left > 0 and right > 0,
      do: {:ok, %{source: {{a, b, c, d}, left}, destination: {{e, f, g, h}, right}}}

  def decode_request(_), do: {:error, :invalid_message}

  @spec response({:ok, map()} | {:error, :unresolved}) :: binary()
  def response({:error, :unresolved}), do: <<1, 0>>

  def response({:ok, identity}) do
    <<1, 1, identity.host_id::binary-size(36), identity.vm_id::binary-size(36),
      identity.placement_id::binary-size(36), identity.execution_epoch::64,
      identity.generation::64, identity.owner_id::binary-size(36)>>
  end

  # @cc [owner:ghuntley,label:security] egress-wire-closed-identity
  # Successful responses MUST carry canonical host/VM/placement/owner UUIDs and
  # positive bounded epoch/generation. Failure MUST disclose no partial identity.
  # This codec does not establish peer credentials or fresh execution evidence.
  @spec decode_response(term()) :: {:ok, map()} | {:error, :unresolved}
  def decode_response(
        <<1, 1, host::binary-size(36), vm::binary-size(36), placement::binary-size(36), epoch::64,
          generation::64, owner::binary-size(36)>>
      )
      when epoch in 1..@maximum and generation in 1..@maximum do
    if Enum.all?([host, vm, placement, owner], &OverallsProtocol.uuid?/1) do
      {:ok,
       %{
         host_id: host,
         vm_id: vm,
         placement_id: placement,
         execution_epoch: epoch,
         generation: generation,
         owner_id: owner,
         attribution: :resolved
       }}
    else
      {:error, :unresolved}
    end
  end

  def decode_response(_), do: {:error, :unresolved}
end
