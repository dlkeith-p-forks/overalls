# Privileged, isolated network fixture; the separate browser check owns UI authorization evidence.
defmodule FleetNetwork do
  alias FleetTerminal, as: Terminal
  alias Lilly.Host.Command
  alias Lilly.Network.{Config, Guest}

  @spec run(String.t(), map()) :: :ok
  def run(action, input) when action in ["prepare", "probe", "listeners"] do
    {:ok, network} =
      Config.new(input["host_id"], "eth2", ["11.0.0.2/32"], "/var/lib/lilly/network")

    profiles = %{"customer" => :customer, "standard" => :standard, "oss" => :oss}

    guests =
      Enum.map(input["guests"], fn row ->
        {:ok, guest} =
          Guest.new(row["placement_id"], Map.fetch!(profiles, row["profile"]), row["slot"])

        true = OverallsProtocol.uuid?(row["host_id"])
        {row["host_id"], guest}
      end)

    local = for {host, guest} <- guests, host == input["host_id"], do: guest
    3 = length(local)

    for guest <- local do
      {:ok, socket} = Terminal.connect(guest.vm_id)

      try do
        :ok = Terminal.ready(socket, 120_000)

        case action do
          "listeners" ->
            echo_listener(socket)

            command(
              socket,
              "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080 || exit 31; echo probe >&3 || exit 32; read -r reply <&3 || exit 33; test \"$reply\" = probe || exit 34'"
            )

          "prepare" ->
            command(socket, "printf '%s' '#{guest.vm_id}' > /root/update-retained && sync")
            echo_listener(socket)

            command(
              socket,
              "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080 || exit 31; echo probe >&3 || exit 32; read -r reply <&3 || exit 33; test \"$reply\" = probe || exit 34'"
            )

            internet(socket, guest)

          "probe" ->
            command(socket, "test \"$(cat /root/update-retained)\" = '#{guest.vm_id}'")

            for {_host, peer} <- guests, peer.vm_id != guest.vm_id do
              denied(socket, peer.address, 18080)
            end

            for address <-
                  input["host_addresses"] ++
                    [guest.gateway, "169.254.255.1", "169.254.169.254", "11.0.0.2"] do
              denied(socket, ipv4!(address), 8080)
            end

            spoof_denials(network, socket, guest)
            internet(socket, guest)
        end
      after
        Terminal.close(socket)
      end
    end

    :ok
  end

  defp echo_listener(socket) do
    # cat needs the accepted connection, not the listening socket. Keep these
    # fixture-only units in /run and prove an actual response before any denial.
    command(
      socket,
      Enum.join(
        [
          "printf '%s\\n' '[Socket]' 'ListenStream=18080' 'Accept=yes' > /run/systemd/system/fleet-echo.socket",
          "printf '%s\\n' '[Service]' 'ExecStart=/run/current-system/sw/bin/cat' 'StandardInput=socket' 'StandardOutput=socket' 'StandardError=null' > /run/systemd/system/fleet-echo@.service",
          "systemctl daemon-reload",
          "systemctl start fleet-echo.socket"
        ],
        " && "
      )
    )
  end

  # @cc [owner:ghuntley,label:verification] fleet-network-positive-control-and-drops
  # Denial probes MUST come from actual guest consoles, require timeouts to live
  # peer listeners and require Customer egress denial, with successful controlled
  # DNS/HTTP egress for other profiles. Spoofing,
  # VLAN and IPv6 probes MUST increase the actual TAP guard's drop counters.
  # No terminal bytes or exception terms may leave this fixture.
  defp spoof_denials(network, socket, guest) do
    checks = [
      {"ip addr add 11.0.0.99/32 dev eth0", "--interface 11.0.0.99",
       "ip addr del 11.0.0.99/32 dev eth0"},
      {"ip link set eth0 address 02:00:00:00:00:99", "", "ip link set eth0 address #{guest.mac}"},
      {"ip link add link eth0 name probe7 type vlan id 7; ip link set probe7 up; ip addr add #{guest.address}/32 dev probe7; ip route add 11.0.0.1/32 via #{guest.gateway} dev probe7 onlink",
       "--interface probe7", "ip route del 11.0.0.1/32; ip link del probe7"}
    ]

    for {setup, options, cleanup} <- checks do
      before = drops(network, guest)

      command(
        socket,
        "#{setup}; curl --silent --connect-timeout 2 --max-time 3 #{options} http://11.0.0.1:8080/ -o /dev/null; result=$?; #{cleanup}; test \"$result\" = 28"
      )

      true = drops(network, guest) > before
    end

    before = drops(network, guest)

    command(
      socket,
      "sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.eth0.disable_ipv6=0"
    )

    await(fn -> drops(network, guest) > before end, deadline(5000))

    command(
      socket,
      "sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.eth0.disable_ipv6=1"
    )
  end

  defp drops(network, guest) do
    {:ok, body} =
      Command.in_namespace(network.namespace, :nft, [
        "--json",
        "list",
        "table",
        "netdev",
        guest.guard
      ])

    for %{"rule" => %{"expr" => expressions}} <- JSON.decode!(body)["nftables"],
        Enum.any?(expressions, &Map.has_key?(&1, "drop")),
        %{"counter" => %{"packets" => packets}} <- expressions,
        reduce: 0 do
      total -> total + packets
    end
  end

  defp ipv4!(address) do
    {:ok, tuple} = :inet.parse_ipv4_address(String.to_charlist(address))
    ^address = tuple |> Tuple.to_list() |> Enum.join(".")
    address
  end

  defp denied(socket, address, port),
    do:
      command(
        socket,
        "timeout 2 bash -c 'echo probe >/dev/tcp/#{address}/#{port}' >/dev/null 2>&1; test \"$?\" = 124"
      )

  defp internet(socket, %{profile: :customer}) do
    denied(socket, "11.0.0.1", 8080)

    command(
      socket,
      "curl --silent --connect-timeout 2 --max-time 3 http://fleet.example.test:8080/ -o /dev/null; test \"$?\" = 28"
    )
  end

  defp internet(socket, _guest),
    do:
      command(
        socket,
        "test \"$(curl --silent --fail --max-time 10 http://fleet.example.test:8080/)\" = fixture-egress-ok"
      )

  defp command(socket, command) do
    marker = "NET_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(socket, command <> "; result=$?; printf '\\n#{marker}:%s\\n' \"$result\"\n")

    command_result(socket, marker, deadline(30_000), "")
  end

  @spec command_result(FleetTerminal.t(), String.t(), integer(), binary()) :: :ok
  defp command_result(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(~r/\n#{marker}:([0-9]{1,3})\n/, body) do
          [_, "0"] ->
            :ok

          [_, status] ->
            IO.puts(:stderr, "Guest command failed with exit status #{String.to_integer(status)}")
            raise "Fixture command failed"

          _ ->
            count = min(byte_size(body), 256)

            command_result(
              socket,
              marker,
              until,
              binary_part(body, byte_size(body) - count, count)
            )
        end

      {:error, :timeout} ->
        command_result(socket, marker, until, tail)

      _ ->
        raise "Fixture terminal closed"
    end
  end

  defp wait(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(socket, marker, until, tail)

      _ ->
        raise "Guest console closed"
    end
  end

  defp await(probe, until) do
    unless probe.() do
      true = System.monotonic_time(:millisecond) < until

      receive do
      after
        100 -> await(probe, until)
      end
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

try do
  [action, path] = System.argv()
  :ok = FleetNetwork.run(action, path |> File.read!() |> JSON.decode!())
  IO.puts("Network guest assertions passed")
rescue
  error ->
    locations =
      for {module, function, _, location} <- __STACKTRACE__,
          module == FleetNetwork,
          do: "#{function}:#{Keyword.get(location, :line, 0)}"

    IO.puts(
      :stderr,
      "Network fixture failed (#{inspect(error.__struct__)}, #{Enum.join(locations, ",")}); terminal bytes withheld"
    )

    System.halt(1)
end
