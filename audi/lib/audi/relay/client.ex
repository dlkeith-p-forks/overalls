defmodule Audi.Relay.Client do
  @moduledoc "Passive one-hop connector over explicitly keyed fleet WireGuard peers."
  alias OverallsProtocol.IngressRelay

  # @cc [owner:ghuntley,label:security] audi-relay-configured-fleet-peer
  # A relay MUST dial only an operator-configured fleet peer and bind the local
  # fleet address. It MUST complete one bounded capability handshake before raw
  # stream bytes. Failed setup MUST close its socket and MUST NOT redeliver.
  @spec open(IngressRelay.route(), map(), map()) ::
          {:ok, :gen_tcp.socket()} | {:error, :connector_unavailable}
  def open(route, grant, %{address: local, peers: peers}) do
    with true <- route.address in peers and IngressRelay.fleet_address?(local),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(route.address)),
         {:ok, source} <- :inet.parse_ipv4strict_address(String.to_charlist(local)),
         {:ok, preface} <-
           IngressRelay.encode(route.capability, grant.ticket, grant.binding.service),
         {:ok, socket} <-
           :gen_tcp.connect(
             address,
             route.port,
             [
               :binary,
               active: false,
               packet: 4,
               packet_size: IngressRelay.maximum(),
               ip: source,
               buffer: 65_536,
               send_timeout: 1000,
               send_timeout_close: true
             ],
             1000
           ) do
      result =
        with :ok <- :gen_tcp.send(socket, preface),
             {:ok, response} <-
               :gen_tcp.recv(
                 socket,
                 0,
                 if(grant.binding.service == :editor, do: 25_000, else: 5000)
               ),
             true <- response == IngressRelay.ready(),
             :ok <- :inet.setopts(socket, packet: 0, packet_size: 0),
             do: {:ok, socket},
             else: (_ -> {:error, :connector_unavailable})

      if match?({:error, _}, result), do: :gen_tcp.close(socket)
      result
    else
      _ -> {:error, :connector_unavailable}
    end
  end

  def open(_, _, _), do: {:error, :connector_unavailable}
end
