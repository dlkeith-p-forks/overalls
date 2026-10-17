defmodule Audi.Inception.PeerTest do
  use ExUnit.Case, async: true

  defp listener(expected) do
    server =
      start_supervised!(
        {ThousandIsland,
         handler_module: Audi.Test.ProxyPeer,
         handler_options: {self(), expected},
         port: 0,
         transport_options: [ip: {127, 0, 0, 2}]},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  test "parent IPv4 and exact socket destination are required" do
    for valid <- [true, false] do
      port = listener({127, 0, 0, 1})

      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 2}, port, [:binary, active: false, ip: {127, 0, 0, 1}], 1000)

      destination = if valid, do: "127.0.0.2", else: "127.0.0.3"

      {:ok, bytes} =
        OverallsProtocol.ProxyHeader.encode(
          %{address: "203.0.113.9", port: 12345},
          destination,
          port
        )

      :ok = :gen_tcp.send(socket, bytes)

      expected =
        if valid, do: {:ok, {{203, 0, 113, 9}, 12345}}, else: {:error, :invalid_proxy_header}

      assert_receive {:proxy_peer, ^expected}, 1000
      :gen_tcp.close(socket)
    end

    port = listener({127, 0, 0, 9})

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 2}, port, [:binary, active: false, ip: {127, 0, 0, 1}], 1000)

    assert_receive {:proxy_peer, {:error, :invalid_proxy_header}}, 1000
    :gen_tcp.close(socket)
  end

  test "public mode and same-address local probes never adopt claimed metadata" do
    for {expected, source} <- [{nil, {127, 0, 0, 1}}, {{127, 0, 0, 1}, {127, 0, 0, 2}}] do
      port = listener(expected)

      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 2}, port, [:binary, active: false, ip: source], 1000)

      assert_receive {:proxy_peer, {:ok, nil}}, 1000
      :gen_tcp.close(socket)
    end
  end
end
