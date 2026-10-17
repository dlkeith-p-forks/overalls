defmodule Lilly.Network.Ingress do
  @moduledoc "Privileged local SSH/web sockets, scoped to a validated namespace and placement TAP."
  alias Lilly.Network.{Config, Guest, Policy}

  # @cc [owner:ghuntley,label:security] ingress-socket-derived-local-target
  # Ingress connect MUST require explicit operator enablement, revalidate derived
  # namespace/TAP/address identities, bind the socket to that TAP, and set the
  # service-specific ingress mark. SSH MUST use port 22; web uses the admitted
  # app port. Editor MUST use port4444, a complete closed binding and the derived
  # gateway source IPv4; its bounded ready frame MUST precede opaque bytes. Nested services MUST derive their paired address and fixed port
  # from an Inception guest. No service may supply a peer address.
  # Customer MUST reject web service sockets, including port 22, regardless of peer authority.
  # Missing privilege, namespace or interface MUST fail without a host-network fallback.
  @spec connect(Config.t(), Guest.t()) ::
          {:ok, :gen_tcp.socket()} | {:error, :ingress_unavailable}
  def connect(network, guest), do: connect(network, guest, %{service: :ssh, port: 22})

  @spec connect(Config.t(), Guest.t(), map()) ::
          {:ok, :gen_tcp.socket()} | {:error, :ingress_unavailable}
  def connect(%Config{ingress: true} = network, %Guest{} = guest, binding) do
    with {:ok, ^network} <-
           Config.new(
             network.host_id,
             network.egress,
             network.protected,
             network.state_dir,
             true,
             network.private_services,
             network.brady
           ),
         {:ok, ^guest} <- Guest.new(guest.vm_id, guest.profile, guest.slot),
         {:ok, {destination, port, mark}} <- target(guest, binding),
         {:ok, preface} <- preface(binding, destination, port),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(destination)),
         {:ok, source} <- :inet.parse_ipv4strict_address(String.to_charlist(guest.gateway)),
         {:ok, socket} <-
           Lilly.Host.Sockets.connect_netns(
             %{
               namespace: network.namespace,
               device: guest.tap,
               mark: mark,
               destination: address,
               port: port,
               source: if(binding.service == :editor, do: source, else: nil),
               timeout: 750
             },
             [
               {:inet_backend, :inet},
               {:netns, String.to_charlist("/run/netns/" <> network.namespace)},
               {:bind_to_device, guest.tap},
               # Linux SOL_SOCKET/SO_MARK, native-endian uint32.
               {:raw, 1, 36, <<mark::native-unsigned-32>>}
             ] ++ if(binding.service == :editor, do: [ip: source], else: []),
             [
               :binary,
               {:active, false},
               {:packet, 0},
               {:send_timeout, 1000},
               {:send_timeout_close, true},
               {:buffer, 65_536}
             ],
             750
           ) do
      case :gen_tcp.send(socket, preface) do
        :ok ->
          ready(socket, binding)

        _ ->
          :gen_tcp.close(socket)
          {:error, :ingress_unavailable}
      end
    else
      _ -> {:error, :ingress_unavailable}
    end
  rescue
    _ -> {:error, :ingress_unavailable}
  end

  def connect(_, _, _), do: {:error, :ingress_unavailable}

  # @cc [owner:ghuntley,label:security] connector-owned-proxy-preface
  # Nested HTTPS MUST require validated client metadata before opening a socket
  # and prepend exactly one IPv4 PROXY header using the derived guest destination.
  # Editor MUST receive the length-framed typed editor binding instead.
  # Ordinary web and SSH streams MUST NOT receive either preface.
  defp preface(%{service: service} = binding, address, port)
       when service in [:control_https, :audi_https],
       do: OverallsProtocol.ProxyHeader.encode(binding[:client_peer], address, port)

  defp preface(%{service: :editor} = binding, _, _) do
    with {:ok, bytes} <- OverallsProtocol.EditorConnect.encode(binding),
         do: {:ok, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>}
  end

  defp preface(_, _, _), do: {:ok, <<>>}

  defp ready(socket, %{service: :editor}) do
    with :ok <- :inet.setopts(socket, packet: 4, packet_size: 2048),
         {:ok, bytes} <- :gen_tcp.recv(socket, 0, 20_000),
         true <- OverallsProtocol.IngressConnect.ready?(bytes),
         :ok <- :inet.setopts(socket, packet: 0, packet_size: 0),
         do: {:ok, socket},
         else: (_ ->
                  :gen_tcp.close(socket)
                  {:error, :ingress_unavailable})
  end

  defp ready(socket, _), do: {:ok, socket}

  # @cc [owner:ghuntley,label:security] ingress-fixed-nested-target
  # Targets MUST derive from a revalidated guest identity. Nested services MUST
  # select only control 22/443 or Audi 22/443 on that Inception slot's paired
  # addresses. Wrong ports, ordinary profiles and altered identities MUST fail.
  @spec target(Guest.t(), map()) ::
          {:ok, {binary(), pos_integer(), pos_integer()}} | {:error, :ingress_unavailable}
  def target(%Guest{} = guest, binding) do
    with {:ok, ^guest} <- Guest.new(guest.vm_id, guest.profile, guest.slot) do
      target_validated(guest, binding)
    else
      _ -> {:error, :ingress_unavailable}
    end
  end

  defp target_validated(guest, %{service: service, port: port})
       when (service == :ssh and port == 22) or
              (service == :web and is_integer(port) and port in 1..65535 and port != 4444) or
              (service == :editor and port == 4444) do
    if OverallsProtocol.ProfilePolicy.allows?(guest.profile, service),
      do: {:ok, {guest.address, port, Policy.ingress_mark(service)}},
      else: {:error, :ingress_unavailable}
  end

  defp target_validated(
         %Guest{profile: :inception, addresses: [control, audi]},
         %{service: service, port: port}
       )
       when service in [:control_https, :porsche_ssh, :audi_https, :audi_ssh] do
    {kind, expected_port} = OverallsProtocol.InceptionName.destination(service)

    if port == expected_port do
      address = if kind == :control, do: control, else: audi
      mark = Policy.ingress_mark(if port == 22, do: :ssh, else: :web)
      {:ok, {address, port, mark}}
    else
      {:error, :ingress_unavailable}
    end
  end

  defp target_validated(_, _), do: {:error, :ingress_unavailable}
end
