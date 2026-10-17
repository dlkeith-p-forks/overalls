defmodule Audi.Inception.FrontTest do
  use ExUnit.Case, async: true
  alias Audi.Control.Client
  alias OverallsProtocol.IngressConnect
  @id "11111111-1111-4111-8111-111111111111"
  @label OverallsProtocol.IngressName.label("lab", @id)
  @name "control." <> @label <> ".inception.apps.example"
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)
  @moduletag :tmp_dir

  test "HTTP initialization preserves the peer read before TLS" do
    peer = {{203, 0, 113, 9}, 12_345}

    state = %{
      tls_upgraded: true,
      handler_module: Bandit.InitialHandler,
      plug: {Audi.HTTP.Front, verified_client_peer: peer}
    }

    assert {:continue, initialized} = Audi.Inception.Front.handle_connection(:closed, state)
    assert initialized.handler_module == Bandit.HTTP1.Handler
    assert initialized.conn_data == {true, elem(peer, 0)}
  end

  test "nested TLS stays opaque and parent revocation closes both ends", %{tmp_dir: directory} do
    cert = Path.join(directory, "inner.pem")
    key = Path.join(directory, "inner.key")

    root_pem = Path.join(directory, "root.pem")
    root_key = Path.join(directory, "root.key")
    csr = Path.join(directory, "inner.csr")
    ext = Path.join(directory, "ext")

    File.write!(
      ext,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:#{@name}\n"
    )

    for args <- [
          [
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-keyout",
            root_key,
            "-out",
            root_pem,
            "-subj",
            "/CN=root",
            "-days",
            "2",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign"
          ],
          [
            "req",
            "-new",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-keyout",
            key,
            "-out",
            csr,
            "-subj",
            "/CN=fixture"
          ],
          [
            "x509",
            "-req",
            "-in",
            csr,
            "-CA",
            root_pem,
            "-CAkey",
            root_key,
            "-CAcreateserial",
            "-days",
            "1",
            "-extfile",
            ext,
            "-out",
            cert
          ]
        ] do
      {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)
      assert status == 0, output
    end

    server =
      start_supervised!(
        {Bandit,
         plug: {Audi.Test.DNSControl, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, control_port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Client.new(
        "https://127.0.0.1:#{control_port}",
        "audi_service_" <> String.duplicate("A", 43),
        :gateway,
        host_id: @id,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    client = Audi.Test.DNSControl.connected(client)

    path = Path.join(System.tmp_dir!(), "nested-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: 4])

    {:ok, %{uid: uid}} = File.stat(path)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    parent = self()

    guest =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3000)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 3000)
        {:ok, binding} = IngressConnect.decode(bytes)
        send(parent, {:binding, binding})
        :ok = :gen_tcp.send(socket, IngressConnect.ready())
        :ok = :inet.setopts(socket, packet: 0)

        {:ok, tls} =
          :ssl.handshake(
            socket,
            [certfile: String.to_charlist(cert), keyfile: String.to_charlist(key)],
            3000
          )

        {:ok, request} = :ssl.recv(tls, 0, 3000)
        send(parent, {:inner_request, request})
        :ok = :ssl.send(tls, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\ninner")
        assert {:error, :closed} = :ssl.recv(tls, 0, 3000)
      end)

    # No nested certificate is installed in the outer store.
    store = Audi.Test.TLSStore.start!(trust_pem: File.read!(Path.join(@fixtures, "ca.pem")))

    outer =
      start_supervised!(
        {Audi.HTTP.Listener,
         scheme: :https,
         store: store,
         port: 0,
         client: client,
         connector: %{path: path, uid: uid},
         zone: "apps.example"}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(outer)

    browser =
      Task.async(fn ->
        [{:Certificate, root, :not_encrypted}] =
          root_pem |> File.read!() |> :public_key.pem_decode()

        {:ok, socket} =
          :ssl.connect(
            {127, 0, 0, 1},
            port,
            [
              :binary,
              active: false,
              verify: :verify_peer,
              cacerts: [root],
              server_name_indication: String.to_charlist(@name)
            ],
            3000
          )

        [{:Certificate, leaf, :not_encrypted}] = cert |> File.read!() |> :public_key.pem_decode()
        assert {:ok, ^leaf} = :ssl.peercert(socket)

        :ok =
          :ssl.send(
            socket,
            "GET /private HTTP/1.1\r\nHost: #{@name}\r\nCookie: inner-session=fixture\r\n\r\n"
          )

        assert {:ok, response} = :ssl.recv(socket, 0, 3000)
        send(parent, {:response, response})
        assert {:error, :closed} = :ssl.recv(socket, 0, 3000)
      end)

    assert_receive {:control_request, request_pid, ref, "/api/audi/v1/nested-open", _, request},
                   2000

    assert request["label"] == @label and request["nested_service"] == "control_https"

    binding = %{
      vm_id: @id,
      host_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      environment_generation: 1,
      label: @label,
      service: :control_https,
      port: 443
    }

    ticket = "audi_nested_stream_" <> Base.url_encode64(<<0::256>>, padding: false)

    send(
      request_pid,
      {ref, 200,
       JSON.encode!(%{
         version: 1,
         grant: %{binding: binding, ticket: ticket, ttl: 5000, host_key: nil}
       })}
    )

    assert_receive {:binding, connector_binding}, 2000
    assert Map.delete(connector_binding, :client_peer) == binding
    assert %{address: "127.0.0.1", port: port} = connector_binding.client_peer
    assert port in 1..65535
    assert_receive {:inner_request, inner}, 2000
    assert inner =~ "inner-session=fixture"
    assert_receive {:response, response}, 2000
    assert response =~ "200 OK" and response =~ "inner"

    assert_receive {:control_request, renew_pid, renew_ref, "/api/audi/v1/nested-renew", _, _},
                   2000

    send(renew_pid, {renew_ref, 401, ~s({"error":"unauthorized"})})
    Task.await(browser, 1000)
    Task.await(guest, 1000)
  end
end
