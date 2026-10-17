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

  @tag obligation: "audi.dns_authority.I2"
  test "wire decoder rejects responses and clamps EDNS" do
    assert Audi.DNS.Wire.decode(<<0::16, 0x8000::16, 1::16, 0::48>>) == {:error, :response}

    packet =
      <<1::16, 0::16, 1::16, 0::16, 0::16, 1::16>> <>
        Audi.DNS.Wire.encode_name(["com"]) <>
        <<1::16, 1::16>> <>
        <<0, 41::16, 65_535::16, 0, 0, 0::16, 0::16>>

    assert {:ok, q} = Audi.DNS.Wire.decode(packet)
    assert q.udp_size == 1232
  end
end
