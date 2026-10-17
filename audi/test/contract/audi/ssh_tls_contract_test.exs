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
end
