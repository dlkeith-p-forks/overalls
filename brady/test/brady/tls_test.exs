defmodule Brady.TLSTest do
  use ExUnit.Case, async: true
  alias Brady.TLS.Certificates

  setup do
    root = Path.join(System.tmp_dir!(), "brady-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    key = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(key, "/CN=Brady Test Issuer", template: :root_ca)
    certfile = Path.join(root, "issuer.pem")
    keyfile = Path.join(root, "issuer.key")
    File.write!(certfile, X509.Certificate.to_pem(cert))
    File.write!(keyfile, X509.PrivateKey.to_pem(key))
    File.chmod!(certfile, 0o600)
    File.chmod!(keyfile, 0o600)
    signer = start_supervised!({Certificates, certfile: certfile, keyfile: keyfile})
    %{signer: signer, certfile: certfile, keyfile: keyfile}
  end

  test "native TLS client trusts minted hostname with HTTP1 ALPN", context do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        result = Brady.TLS.accept(socket, context.signer, "127.0.0.1")

        case result do
          {:ok, {:tls, tls}, "packages.example"} ->
            :ssl.send(tls, "test")
            :ssl.close(tls)

          _ ->
            :gen_tcp.close(socket)
        end

        result |> elem(0)
      end)

    assert {:ok, client} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               [
                 :binary,
                 active: false,
                 verify: :verify_peer,
                 cacertfile: String.to_charlist(context.certfile),
                 server_name_indication: ~c"packages.example",
                 alpn_advertised_protocols: ["h2", "http/1.1"],
                 customize_hostname_check: [
                   match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                 ]
               ],
               10_000
             )

    assert {:ok, "http/1.1"} = :ssl.negotiated_protocol(client)
    assert {:ok, "test"} = :ssl.recv(client, 4, 5_000)
    :ssl.close(client)
    assert :ok = Task.await(server, 10_000)
    :gen_tcp.close(listener)
  end

  test "rejects unsafe signing names and private-file permission drift", context do
    assert {:error, :certificate_unavailable} =
             Certificates.fetch(context.signer, "example.com/secret")

    stop_supervised!(Certificates)
    File.chmod!(context.keyfile, 0o644)

    assert {:error, {:invalid_signing_credentials, _}} =
             start_supervised(
               {Certificates, certfile: context.certfile, keyfile: context.keyfile}
             )
  end

  test "upstream verifies both independent trust and the requested hostname", context do
    {:ok, options} = Certificates.fetch(context.signer, "origin.example")
    config = %{destination_policy: [], socket_options: [], upstream_ca_file: context.certfile}
    assert {:ok, transport} = upstream(options, "origin.example", config)
    Brady.Transport.close(transport)
    assert {:error, :tls} = upstream(options, "wrong.example", config)
    wrong_key = X509.PrivateKey.new_ec(:secp256r1)

    wrong_ca =
      X509.Certificate.self_signed(wrong_key, "/CN=Unrelated Test CA", template: :root_ca)

    other = context.certfile <> ".other"
    File.write!(other, X509.Certificate.to_pem(wrong_ca))

    assert {:error, :tls} =
             upstream(options, "origin.example", %{config | upstream_ca_file: other})
  end

  defp upstream(options, host, config) do
    {:ok, listener} =
      :ssl.listen(0, options ++ [:binary, active: false, reuseaddr: true, log_level: :none])

    {:ok, {_, port}} = :ssl.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} ->
            :ssl.send(socket, "test")
            :ssl.close(socket)

          _ ->
            :ok
        end
      end)

    result = Brady.Upstream.connect({{127, 0, 0, 1}, port}, :https, host, config)
    Task.await(server, 10_000)
    :ssl.close(listener)
    result
  end
end
