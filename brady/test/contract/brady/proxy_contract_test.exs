defmodule BradyProxyContractTest do
  use Covenant.Case, component: "brady.proxy"

  @tag obligation: "brady.proxy.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Brady.Connection,
      Brady.HTTP.Head,
      Brady.HTTP.Stream,
      Brady.Log,
      Brady.Proxy,
      Brady.TLS,
      Brady.TLS.Certificates,
      Brady.TLS.Hello,
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
end
