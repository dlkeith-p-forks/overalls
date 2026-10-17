defmodule BradyProxyContractTest do
  use Covenant.Case, component: "brady.proxy"

  @tag obligation: "brady.proxy.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Brady.Connection,
      Brady.Destination,
      Brady.HTTP.Head,
      Brady.HTTP.Stream,
      Brady.Log,
      Brady.Proxy,
      Brady.TLS,
      Brady.TLS.Certificates,
      Brady.TLS.Hello,
      Brady.Listener,
      Brady.Transport,
      Brady.Tunnel,
      Brady.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "brady.proxy.I2"
  test "HTTP framing rejects ambiguous requests and preserves remainder" do
    valid = "GET /health HTTP/1.1\r\nhost: example.test\r\ncontent-length: 0\r\n\r\nnext"

    assert {:ok, %{method: "GET", target: "/health", body: {:length, 0}}, "next"} =
             Brady.HTTP.Head.parse(valid, :request)

    duplicate_host = "GET / HTTP/1.1\r\nhost: a\r\nhost: b\r\n\r\n"
    assert {:error, :invalid_http} = Brady.HTTP.Head.parse(duplicate_host, :request)

    ambiguous =
      "POST / HTTP/1.1\r\nhost: example.test\r\ncontent-length: 1\r\ntransfer-encoding: chunked\r\n\r\n"

    assert {:error, :invalid_http} = Brady.HTTP.Head.parse(ambiguous, :request)
  end

  @tag obligation: "brady.proxy.I3"
  test "response serialization strips hop-by-hop and stale framing headers" do
    head = %{
      status: 200,
      headers: [{"connection", "upgrade"}, {"content-length", "999"}, {"x-ok", "yes"}],
      body: {:length, 2}
    }

    output = IO.iodata_to_binary(Brady.HTTP.Head.response_bytes(head))
    assert output =~ "x-ok: yes"
    refute output =~ "upgrade"
    refute output =~ "content-length: 999"
    assert output =~ "content-length: 2"
    assert output =~ "connection: close"
  end

  @tag obligation: "brady.proxy.I4"
  test "destination admission and authority matching fail closed" do
    {:ok, policy} = Brady.Destination.policy([])
    refute Brady.Destination.allowed?({127, 0, 0, 1}, 443, policy)
    refute Brady.Destination.allowed?({1, 2, 3, 4}, 0, policy)
    refute Brady.Destination.allowed?({1, 2, 3, 4, 443}, 443, policy)
    assert Brady.Destination.allowed?({1, 2, 3, 4}, 443, policy)

    resolver = fn
      "origin.test" -> {:ok, [{1, 2, 3, 4}]}
      _ -> {:error, :nxdomain}
    end

    assert Brady.Destination.matches?("origin.test", 443, {{1, 2, 3, 4}, 443}, resolver)
    refute Brady.Destination.matches?("origin.test", 80, {{1, 2, 3, 4}, 443}, resolver)
    refute Brady.Destination.matches?("bad host", 443, {{1, 2, 3, 4}, 443}, resolver)
  end

  @tag obligation: "brady.proxy.I5"
  test "transport reports closed sockets and close remains safe after peer closure" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(parent, {:accepted, socket})

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    assert_receive {:accepted, peer}, 1_000
    :gen_tcp.close(client)
    assert Brady.Transport.recv({:tcp, peer}, 0, 100) == {:error, :closed}
    assert Brady.Transport.close({:tcp, peer}) == :ok
    send(server, :close)
    :gen_tcp.close(listener)
  end
end
