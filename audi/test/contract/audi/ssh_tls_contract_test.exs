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
end
