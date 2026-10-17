defmodule OverallsProtocol.ProxyHeader do
  @moduledoc "Fixed IPv4 TCP PROXY v2 metadata emitted only by the trusted connector."
  @signature <<13, 10, 13, 10, 0, 13, 10, "QUIT", 10>>

  # @cc [owner:ghuntley,label:security] proxy-header-ipv4-only
  # Metadata MUST be exactly a 28-byte PROXY v2 IPv4/TCP header with source and
  # destination ports. IPv6, LOCAL commands, TLVs and alternate lengths MUST fail.
  # Callers MUST authenticate the transport peer before trusting decoded metadata.
  @spec encode(map(), binary(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_proxy_header}
  def encode(%{address: source, port: source_port} = peer, destination, port)
      when map_size(peer) == 2 do
    with {:ok, {a, b, c, d}} <- ipv4(source),
         {:ok, {e, f, g, h}} <- ipv4(destination),
         true <- port?(source_port) and port?(port) do
      {:ok, <<@signature, 0x21, 0x11, 12::16, a, b, c, d, e, f, g, h, source_port::16, port::16>>}
    else
      _ -> invalid()
    end
  end

  def encode(_, _, _), do: invalid()

  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_proxy_header}
  def decode(
        <<@signature, 0x21, 0x11, 12::16, a, b, c, d, e, f, g, h, source_port::16, port::16>>
      )
      when source_port > 0 and port > 0 do
    {:ok, %{source: {{a, b, c, d}, source_port}, destination: {{e, f, g, h}, port}}}
  end

  def decode(_), do: invalid()

  @spec peer?(term()) :: boolean()
  def peer?(%{address: address, port: port} = peer) when map_size(peer) == 2,
    do: match?({:ok, _}, ipv4(address)) and port?(port)

  def peer?(_), do: false

  defp ipv4(value) when is_binary(value) and byte_size(value) in 7..15 do
    with true <- String.valid?(value),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(value)),
         true <- List.to_string(:inet.ntoa(address)) == value,
         do: {:ok, address},
         else: (_ -> :error)
  end

  defp ipv4(_), do: :error
  defp port?(port), do: is_integer(port) and port in 1..65535
  defp invalid, do: {:error, :invalid_proxy_header}
end
