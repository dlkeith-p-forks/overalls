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
    assert {:error, :malformed} = Audi.DNS.Wire.decode(String.duplicate("x", 65_536))
  end

  @tag obligation: "audi.dns_authority.I3"
  test "oversized UDP replies truncate and keep unsafe flags clear" do
    question = %{
      id: 7,
      flags: 0,
      wire_labels: ["example", "com"],
      type: 1,
      class: 1,
      udp_size: 512,
      edns: true
    }

    answer = {["example", "com"], 1, 60, String.duplicate("x", 600)}
    packet = Audi.DNS.Wire.reply(question, 0, [answer], [], false, :udp)
    <<_id::16, flags::16, _rest::binary>> = packet

    assert byte_size(packet) <= 512
    assert Bitwise.band(flags, 0x0200) == 0x0200
    assert Bitwise.band(flags, 0x0100) == 0
    assert Bitwise.band(flags, 0x0020) == 0
  end
end
