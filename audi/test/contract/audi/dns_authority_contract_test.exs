defmodule AudiDnsAuthorityContractTest do
  use Covenant.Case, component: "audi.dns_authority"

  @tag obligation: "audi.dns_authority.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Audi.Authority.HintRenewal,
      Audi.Authority.Lease,
      Audi.Authority.Renewal,
      Audi.Authority.StreamGuard,
      Audi.DNS.Authority,
      Audi.DNS.Challenge,
      Audi.DNS.Directory,
      Audi.DNS.Replica,
      Audi.DNS.Server,
      Audi.DNS.Snapshot,
      Audi.DNS.Wire,
      Audi.Private.DNS,
      Audi.Private.Guard
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
