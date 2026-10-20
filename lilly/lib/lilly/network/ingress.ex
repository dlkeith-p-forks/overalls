defmodule Lilly.Network.Ingress do
  @moduledoc "Privileged local SSH/web sockets, scoped to a validated namespace and placement TAP."
  alias Lilly.Network.{AndroidDisplay, Config, Guest, Policy}

  # @cc [owner:ghuntley,label:security] ingress-socket-derived-local-target
  # Ingress connect MUST require explicit operator enablement, revalidate derived
  # namespace/TAP/address identities, bind the socket to that TAP, and set the
  # service-specific ingress mark. SSH MUST use port 22; web uses the admitted
  # app port and MUST NOT select the editor port 4444 or Android display relay port 5900. Editor MUST use port4444, a complete closed binding and the derived
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

  # @cc [owner:ghuntley,label:security;isolation;recovery] android-display-namespace-connect
  # Android display sockets MUST use the AndroidDisplay target and relay preface;
  # no generic web/editor binding or host-network fallback may be substituted.
  @spec connect_android_display(Config.t(), Guest.t(), map(), pos_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, :display_unavailable}
  def connect_android_display(
        %Config{ingress: true} = network,
        %Guest{} = guest,
        binding,
        generation
      )
      when is_map(binding) and is_integer(generation) and generation > 0 do
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
         {:ok, target} <- AndroidDisplay.target(guest, binding, generation),
         {:ok, preface} <-
           OverallsProtocol.AndroidDisplayRelay.encode(
             binding[:ticket],
             generation,
             binding[:mode]
           ),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(target.address)),
         {:ok, socket} <-
           Lilly.Host.Sockets.connect_netns(
             %{
               namespace: network.namespace,
               device: guest.tap,
               mark: target.mark,
               destination: address,
               port: target.port,
               source: nil,
               timeout: 750
             },
             [
               :binary,
               {:active, false},
               {:packet, 0},
               {:send_timeout, 1000},
               {:send_timeout_close, true},
               {:buffer, 65_536}
             ],
             750
           ),
         :ok <- :gen_tcp.send(socket, preface) do
      {:ok, socket}
    else
      _ -> {:error, :display_unavailable}
    end
  rescue
    _ -> {:error, :display_unavailable}
  end

  def connect_android_display(_, _, _, _), do: {:error, :display_unavailable}

  @doc """
  Services hostd may bridge detached: every service connect/3 serves. SSH
  and web need no stage; the editor and nested HTTPS have hostd write the
  preface Lilly derived, and the editor has hostd require Lilly's exact ready
  frame, before the bridge starts (ADR-0187, ADR-0192).
  """
  @spec detachable?(map()) :: boolean()
  def detachable?(%{service: service}),
    do: service in [:ssh, :web, :editor, :porsche_ssh, :audi_ssh, :control_https, :audi_https]

  def detachable?(_), do: false

  # The editor's guest ready frame, as the trusted connector requires it: the
  # broker writes exactly this length-framed document after accepting the
  # editor binding, and hostd compares it byte for byte.
  @editor_ready OverallsProtocol.IngressConnect.ready()
  @editor_ready_ms 20_000

  # @cc [owner:ghuntley,label:security;protocol] ingress-detached-stage
  # stage/3 MUST derive what hostd exchanges with the guest before a detached
  # bridge starts only from the validated binding and derived target: nested
  # HTTPS gets exactly connect/3's PROXY v2 preface and no expected frame; the
  # editor gets connect/3's length-framed editor binding, the exact
  # length-framed ready document and connect/3's 20 s ready bound; every other
  # service gets nothing. Lilly alone decides both byte strings; hostd only
  # writes one and compares the other.
  @spec stage(map(), binary(), pos_integer()) ::
          {:ok, Lilly.Host.Hostd.bridge_stage()} | {:error, :ingress_unavailable}
  def stage(binding, destination, port) do
    with {:ok, preface} <- preface(binding, destination, port) do
      {:ok, Map.put(expected(binding), :preface, preface)}
    else
      _ -> {:error, :ingress_unavailable}
    end
  end

  defp expected(%{service: :editor}),
    do: %{
      expect: <<byte_size(@editor_ready)::unsigned-big-32, @editor_ready::binary>>,
      ready: @editor_ready_ms
    }

  defp expected(_), do: %{expect: <<>>, ready: 0}

  # @cc [owner:ghuntley,label:security;recovery] ingress-detached-bridge-derived-target
  # bridge/6 MUST apply exactly connect/3's enablement, identity revalidation,
  # target derivation and editor source address, accept only a detachable
  # binding, derive its stage through ingress-detached-stage, and have hostd
  # bridge Audi's connection `client` to that target in a detached bridge
  # named by `key`, writing `greeting` first (ADR-0187, ADR-0192). No service
  # may supply a peer address, a preface or a greeting.
  @spec bridge(Config.t(), Guest.t(), map(), :gen_tcp.socket(), <<_::128>>, binary()) ::
          :ok | {:error, :ingress_unavailable}
  def bridge(%Config{ingress: true} = network, %Guest{} = guest, binding, client, key, greeting) do
    with true <- detachable?(binding),
         {:ok, ^network} <-
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
         {:ok, stage} <- stage(binding, destination, port),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(destination)),
         {:ok, source} <- :inet.parse_ipv4strict_address(String.to_charlist(guest.gateway)),
         :ok <-
           Lilly.Host.Hostd.bridge_ingress(client, key, greeting, stage, %{
             namespace: network.namespace,
             device: guest.tap,
             mark: mark,
             destination: address,
             port: port,
             source: if(binding.service == :editor, do: source, else: nil),
             timeout: 750
           }) do
      :ok
    else
      _ -> {:error, :ingress_unavailable}
    end
  rescue
    _ -> {:error, :ingress_unavailable}
  end

  def bridge(_, _, _, _, _, _), do: {:error, :ingress_unavailable}

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
              (service == :web and is_integer(port) and port in 1..65535 and
                 port not in [4444, 5900]) or
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
