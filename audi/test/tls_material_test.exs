defmodule Audi.TLS.FleetMaterialTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.TLS.FleetMaterial
  @host "demo-0123456789abcdef0123456789abcdef.apps.example"

  setup_all do
    directory = Path.join(System.tmp_dir!(), "audi-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    openssl = fn args ->
      {output, status} = System.cmd("openssl", args, cd: directory, stderr_to_stdout: true)
      assert status == 0, output
    end

    for root <- ["root", "other"] do
      openssl.([
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:P-256",
        "-nodes",
        "-keyout",
        "#{root}.key",
        "-out",
        "#{root}.pem",
        "-subj",
        "/CN=#{root}",
        "-days",
        "2",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign"
      ])
    end

    openssl.([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      "leaf.key",
      "-out",
      "leaf.csr",
      "-subj",
      "/CN=ignored.example"
    ])

    for {name, san, eku} <- [
          {"leaf", "DNS:#{@host},DNS:*.#{@host}", "serverAuth"},
          {"fleet", "DNS:#{@host},DNS:*.apps.example", "serverAuth"},
          {"missing", "DNS:#{@host}", "serverAuth"},
          {"client", "DNS:#{@host},DNS:*.#{@host}", "clientAuth"}
        ] do
      File.write!(
        Path.join(directory, "ext"),
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=#{eku}\nsubjectAltName=#{san}\n"
      )

      openssl.([
        "x509",
        "-req",
        "-in",
        "leaf.csr",
        "-CA",
        "root.pem",
        "-CAkey",
        "root.key",
        "-CAcreateserial",
        "-days",
        "1",
        "-extfile",
        "ext",
        "-out",
        "#{name}.pem"
      ])
    end

    File.write!(
      Path.join(directory, "fleet-exact-ext"),
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:*.apps.example\n"
    )

    openssl.([
      "x509",
      "-req",
      "-in",
      "leaf.csr",
      "-CA",
      "root.pem",
      "-CAkey",
      "root.key",
      "-CAcreateserial",
      "-days",
      "1",
      "-extfile",
      "fleet-exact-ext",
      "-out",
      "fleet-exact.pem"
    ])

    openssl.([
      "req",
      "-new",
      "-key",
      "other.key",
      "-out",
      "intermediate.csr",
      "-subj",
      "/CN=intermediate"
    ])

    File.write!(
      Path.join(directory, "ca-ext"),
      "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
    )

    openssl.([
      "x509",
      "-req",
      "-in",
      "intermediate.csr",
      "-CA",
      "root.pem",
      "-CAkey",
      "root.key",
      "-CAcreateserial",
      "-days",
      "1",
      "-extfile",
      "ca-ext",
      "-out",
      "intermediate.pem"
    ])

    File.write!(
      Path.join(directory, "server-ext"),
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:#{@host},DNS:*.#{@host}\n"
    )

    openssl.([
      "x509",
      "-req",
      "-in",
      "leaf.csr",
      "-CA",
      "intermediate.pem",
      "-CAkey",
      "other.key",
      "-CAcreateserial",
      "-days",
      "2",
      "-extfile",
      "server-ext",
      "-out",
      "intermediate-leaf.pem"
    ])

    %{
      directory: directory,
      chain: File.read!(Path.join(directory, "leaf.pem")),
      fleet_chain: File.read!(Path.join(directory, "fleet-exact.pem")),
      key: File.read!(Path.join(directory, "leaf.key")),
      roots: File.read!(Path.join(directory, "root.pem"))
    }
  end

  test "exact wildcard serves distinct flat VM and alternate-port names", c do
    assert {:ok, fleet} = FleetMaterial.validate(c.fleet_chain, c.key, c.roots, "apps.example")
    assert fleet.hostname == "apps.example"
    refute inspect(fleet) =~ "PRIVATE"

    store = Audi.Test.TLSStore.start!(trust_pem: c.roots)
    assert :unrecognized = Audi.TLS.Store.sni(store, @host)

    assert {:ok, metadata} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 1, c.fleet_chain, c.key)

    assert metadata.fingerprint == fleet.fingerprint

    for name <- [
          @host,
          alternate(@host, 3000),
          OverallsProtocol.EditorName.label(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002"
          ) <> ".apps.example",
          "1" <> String.duplicate("v", 51) <> ".apps.example",
          "other-0123456789abcdef0123456789abcdef.apps.example"
        ] do
      assert {:ok, "ok"} = sni_connection(store, name, c.roots)

      assert {:ok, %{generation: 1, fingerprint: fingerprint}} =
               Audi.TLS.Store.fleet_metadata(store, name)

      assert fingerprint == fleet.fingerprint
    end

    for name <- [
          "deeper." <> @host,
          "outside.example",
          "apps.example",
          "e-invalid-" <> String.duplicate("a", 32) <> ".apps.example",
          "webview.apps.example"
        ] do
      assert :unrecognized = Audi.TLS.Store.sni(store, name)
      assert {:error, :unavailable} = Audi.TLS.Store.fleet_metadata(store, name)
    end
  end

  test "wrong name, trust, usage and private key never install", c do
    other_key = File.read!(Path.join(c.directory, "other.key"))
    client_only = File.read!(Path.join(c.directory, "client.pem"))
    store = Audi.Test.TLSStore.start!(trust_pem: c.roots)

    for {chain, key} <- [
          {c.chain, c.key},
          {client_only, c.key},
          {c.fleet_chain, other_key}
        ] do
      assert {:error, :invalid_tls_material} =
               FleetMaterial.validate(chain, key, c.roots, "apps.example")

      assert {:error, :invalid_tls_material} =
               Audi.TLS.Store.install_fleet(store, "apps.example", 1, chain, key)
    end

    other_roots = File.read!(Path.join(c.directory, "other.pem"))
    other_store = Audi.Test.TLSStore.start!(trust_pem: other_roots)

    assert {:error, :invalid_tls_material} =
             FleetMaterial.validate(c.fleet_chain, c.key, other_roots, "apps.example")

    assert {:error, :invalid_tls_material} =
             Audi.TLS.Store.install_fleet(other_store, "apps.example", 1, c.fleet_chain, c.key)

    assert :unrecognized = Audi.TLS.Store.sni(store, @host)
  end

  # @cc [owner:ghuntley,label:verification;security] audi-readiness-proof-generation
  # A proof applies only to the exact installed generation: a newer install is
  # unproven until proven itself, and an uninstalled generation is refused.
  test "a readiness proof covers exactly the installed generation", c do
    store = Audi.Test.TLSStore.start!(trust_pem: c.roots)
    assert {:error, :not_installed} = Audi.TLS.Store.prove(store, 1)
    refute Audi.TLS.Store.proven?(store, 1)

    assert {:ok, _} = Audi.TLS.Store.install_fleet(store, "apps.example", 1, c.fleet_chain, c.key)
    refute Audi.TLS.Store.proven?(store, 1)
    assert :ok = Audi.TLS.Store.prove(store, 1)
    assert Audi.TLS.Store.proven?(store, 1)

    assert {:ok, _} = Audi.TLS.Store.install_fleet(store, "apps.example", 2, c.fleet_chain, c.key)
    refute Audi.TLS.Store.proven?(store, 2)
    refute Audi.TLS.Store.proven?(store, 1)
    assert {:error, :not_installed} = Audi.TLS.Store.prove(store, 1)
    assert :ok = Audi.TLS.Store.prove(store, 2)
    assert Audi.TLS.Store.proven?(store, 2)
  end

  test "generation, capacity and restart preserve only valid memory state", c do
    store = Audi.Test.TLSStore.start!(trust_pem: c.roots)

    assert {:ok, metadata} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 2, c.fleet_chain, c.key)

    assert {:ok, ^metadata} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 2, c.fleet_chain, c.key)

    assert {:error, :stale} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 1, c.fleet_chain, c.key)

    assert {:error, :invalid_tls_material} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 3, c.fleet_chain, "bad")

    assert {:error, :invalid_generation} =
             Audi.TLS.Store.install_fleet(store, "apps.example", 0, c.fleet_chain, c.key)

    assert {:ok, %{generation: 2}} = Audi.TLS.Store.fleet_metadata(store, @host)

    tiny = Audi.Test.TLSStore.start!(trust_pem: c.roots, max_bytes: 1)

    assert {:error, :capacity} =
             Audi.TLS.Store.install_fleet(tiny, "apps.example", 1, c.fleet_chain, c.key)

    assert :unrecognized = Audi.TLS.Store.sni(tiny, @host)

    # Expire the installed generation inside the store, its view's only writer.
    :sys.replace_state(store, fn state ->
      material = %{state.fleet.material | expires_at: System.system_time(:second) - 1}
      fleet = %{state.fleet | material: material}
      {:ok, _} = OverallsProtocol.View.put(state.view, :fleet, fleet)
      %{state | fleet: fleet}
    end)

    assert :unrecognized = Audi.TLS.Store.sni(store, @host)
    # A store restart publishes nothing until reinstalled: SNI fails closed.
    Process.exit(Process.whereis(store), :kill)

    eventually(fn ->
      OverallsProtocol.View.fetch(Audi.TLS.Store.view(store), :fleet) == :error
    end)

    assert :unrecognized = Audi.TLS.Store.sni(store, @host)
  end

  property "arbitrary bytes fail validation without exposing decoder exceptions", c do
    check all(bytes <- binary(max_length: 2048)) do
      assert {:error, :invalid_tls_material} =
               FleetMaterial.validate(bytes, c.key, c.roots, "apps.example")

      assert {:error, :invalid_tls_material} =
               FleetMaterial.validate(c.fleet_chain, bytes, c.roots, "apps.example")

      assert {:error, :invalid_tls_material} =
               FleetMaterial.validate(c.fleet_chain, c.key, bytes, "apps.example")
    end
  end

  defp sni_connection(store, name, roots) do
    {:ok, listener} =
      :ssl.listen(0,
        sni_fun: &Audi.TLS.Store.sni(store, &1),
        active: false,
        versions: [:"tlsv1.3"]
      )

    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :ssl.transport_accept(listener, 3000)

           case :ssl.handshake(socket, 3000) do
             {:ok, socket} ->
               :ssl.send(socket, "ok")
               :ssl.close(socket)

             {:error, _} ->
               :ssl.close(socket)
           end

           send(owner, {:handshake_done, self()})
         end},
        id: make_ref()
      )

    [{:Certificate, root, :not_encrypted}] = :public_key.pem_decode(roots)

    result =
      case :ssl.connect(
             {127, 0, 0, 1},
             port,
             [
               verify: :verify_peer,
               cacerts: [root],
               server_name_indication: String.to_charlist(name),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ],
               active: false,
               mode: :binary,
               versions: [:"tlsv1.3"]
             ],
             3000
           ) do
        {:ok, socket} ->
          reply = :ssl.recv(socket, 2, 3000)
          :ssl.close(socket)
          reply

        error ->
          error
      end

    assert_receive {:handshake_done, ^task}, 3000
    :ssl.close(listener)
    result
  end

  @spec alternate(binary(), integer()) :: binary()
  defp alternate(host, port) do
    [label | zone] = String.split(host, ".")
    OverallsProtocol.IngressName.alternate_label(label, port) <> "." <> Enum.join(zone, ".")
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
