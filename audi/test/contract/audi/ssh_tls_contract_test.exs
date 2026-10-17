defmodule AudiSshTlsContractTest do
  use Covenant.Case, component: "audi.ssh_tls"

  @tag obligation: "audi.ssh_tls.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Audi.SSH.Backend,
      Audi.SSH.Channel,
      Audi.SSH.ControlBackend,
      Audi.SSH.HostKey,
      Audi.SSH.KeyPublisher,
      Audi.SSH.Listener,
      Audi.SSH.Proof,
      Audi.SSH.Request,
      Audi.SSH.State,
      Audi.TLS.FleetCertificate,
      Audi.TLS.FleetMaterial,
      Audi.TLS.FleetWorker,
      Audi.TLS.Installation,
      Audi.TLS.Probe,
      Audi.TLS.Readiness,
      Audi.TLS.Store
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "audi.ssh_tls.I2"
  test "SSH request grammar is closed and bounded" do
    assert Audi.SSH.Request.parse("connect a-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ==
             {:ok, "a-" <> String.duplicate("a", 32)}

    assert Audi.SSH.Request.parse("connect bad host") == :error
    assert Audi.SSH.Request.parse("connect " <> String.duplicate("a", 64)) == :error
    assert Audi.SSH.Request.parse(:unexpected) == :error
  end

  @tag obligation: "audi.ssh_tls.I3"
  test "TLS material validation fails closed for malformed input" do
    assert Audi.TLS.FleetMaterial.validate("", "", "", "example.com") ==
             {:error, :invalid_tls_material}

    assert Audi.TLS.FleetMaterial.validate("bad", "bad", "bad", "*.example.com") ==
             {:error, :invalid_tls_material}
  end

  @tag obligation: "audi.ssh_tls.I4"
  test "stream guard fences the owner on revocation and rejects stale renewal" do
    owner = spawn(fn -> Process.sleep(:infinity) end)

    binding = %{
      host_id: "11111111-1111-4111-8111-111111111111",
      vm_id: "22222222-2222-4222-8222-222222222222",
      placement_id: "33333333-3333-4333-8333-333333333333",
      session_id: "44444444-4444-4444-8444-444444444444",
      execution_epoch: 1
    }

    requested_at = System.monotonic_time(:millisecond)
    {:ok, guard} =
      Audi.Authority.StreamGuard.start_link(
        owner: owner,
        binding: binding,
        requested_at: requested_at,
        ttl: 5_000
      )

    assert {:error, :stale} =
             Audi.Authority.StreamGuard.renew(
               guard,
               binding,
               requested_at,
               5_000
             )

    owner_ref = Process.monitor(owner)
    assert :ok = Audi.Authority.StreamGuard.revoke(guard)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
  end
end
