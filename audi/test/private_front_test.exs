defmodule Audi.PrivateFrontTest do
  use ExUnit.Case, async: true
  alias Audi.Private.Front

  @private_hosts [
    "llm.internal",
    "reflection.internal",
    "com-github.integration.internal",
    "example.integration.internal",
    "otel.integration.internal"
  ]

  # @cc [owner:ghuntley,label:verification;security] private-customer-before-binding
  # Every non-SSH private service MUST refuse Customer before connector access,
  # including the configured reflection and integration backends.
  test "Customer refuses every non-SSH private service before binding" do
    for host <- @private_hosts,
        peer <- [{10, 10, 0, 2}, {10, 10, 255, 254}] do
      path = if host == "otel.integration.internal", do: "/v1/traces", else: "/v1/snapshot"

      conn =
        https(host, path, peer, :post)
        |> Plug.Conn.put_req_header("content-type", "application/x-protobuf")

      options = options(:unconfigured, 0)

      # A connector lookup with this invalid path raises instead of returning a
      # refusal, so a successful 403 establishes that binding was never requested.
      result = Front.call(conn, options)
      assert result.status == 403
      assert result.resp_body == "Unavailable\n"
    end
  end

  test "Customer retains SSH account pulls and exact bootstrap purposes", c do
    for {method, path, purpose} <- [
          {:get, "/ssh/v1/authorized-keys", :services},
          {:get, "/ssh/v1/roster", :ssh_roster},
          {:post, "/ssh/v1/host-certificate", :ssh_host_certificate}
        ] do
      conn = https("ssh.integration.internal", path, {10, 10, 0, 2}, method)
      assert lookup(conn, c) == {:ok, "10.10.0.2", purpose}
    end
  end

  test "non-Customer sources retain each configured private service", c do
    for host <- @private_hosts,
        peer <- [{10, 20, 0, 2}, {10, 30, 0, 2}] do
      path = if host == "otel.integration.internal", do: "/v1/traces", else: "/v1/snapshot"
      conn = https(host, path, peer, :post)
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/x-protobuf")
      assert lookup(conn, c) == {:ok, to_string(:inet.ntoa(peer)), :services}
    end
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audi-private-front-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: 4, ifaddr: {:local, path}])

    {:ok, %{uid: uid}} = File.stat(path)

    on_exit(fn ->
      :ok = :gen_tcp.close(listener)
      File.rm!(path)
    end)

    %{listener: listener, options: options(path, uid)}
  end

  @spec options(Path.t() | :unconfigured, non_neg_integer()) :: keyword()
  defp options(path, uid) do
    [
      connector: path,
      connector_uid: uid,
      peach_socket: "/fixture/peach.sock",
      galileo_socket: "/fixture/galileo.sock",
      otel_socket: "/fixture/otel.sock"
    ]
  end

  @spec https(String.t(), String.t(), :inet.ip4_address(), :get | :post) :: Plug.Conn.t()
  defp https(host, path, peer, method) do
    conn = Plug.Test.conn(method, "https://" <> host <> path)
    {adapter, payload} = conn.adapter

    %{
      conn
      | remote_ip: peer,
        req_headers: [{"host", host} | conn.req_headers],
        adapter: {adapter, Map.put(payload, :ssl_data, sni_hostname: String.to_charlist(host))}
    }
  end

  @spec lookup(Plug.Conn.t(), %{listener: :gen_tcp.socket(), options: keyword()}) ::
          {:ok, String.t(), OverallsProtocol.PrivateServices.purpose()}
          | {:error, :invalid_request}
  defp lookup(conn, %{listener: listener, options: options}) do
    request =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)

        try do
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
          {:ok, document} = JSON.decode(bytes)
          :ok = :gen_tcp.send(socket, "{}")
          OverallsProtocol.PrivateServices.decode_watch_request(document)
        after
          :gen_tcp.close(socket)
        end
      end)

    # The fixture deliberately refuses the grant after observing its purpose.
    assert Front.call(conn, options).status == 403
    Task.await(request, 2000)
  end
end
