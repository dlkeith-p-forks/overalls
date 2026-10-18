defmodule Audi.DNS.AdmissionPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.DNS.{Authority, Wire}

  property "every countable public outcome had pre-resolution admission eligibility" do
    label = draw("label", string(:alphanumeric, min_length: 1, max_length: 40))
    type = draw("type", integer(0..65535))
    class = draw("class", member_of([1, 3]))
    opcode = draw("opcode", integer(0..15))
    in_zone = draw("in_zone", boolean())
    transport = draw("transport", member_of([:udp, :tcp]))
    directory = Audi.Test.DNSDirectory.start!([])

    config = %Authority{
      zone: ["apps", "example"],
      nameservers: [["ns", "example"]],
      mailbox: ["hostmaster", "example"],
      directory: directory
    }

    name = [label, if(in_zone, do: "apps", else: "other"), "example"]
    flags = Bitwise.bsl(opcode, 11)

    packet =
      <<1::16, flags::16, 1::16, 0::16, 0::16, 0::16>> <>
        Wire.encode_name(name) <> <<type::16, class::16>>

    {_reply, outcome} = Authority.answer_with_outcome(packet, config, transport)
    eligible = Authority.eligible?(packet, config)
    assert eligible == (in_zone and class == 1 and opcode == 0 and type not in [251, 252])
    if outcome != :exclude, do: assert(eligible)
  end

  property "arbitrary malformed or reply packets cannot become admitted public work" do
    packet = draw("packet", binary(max_length: 512))

    config = %Authority{
      zone: ["apps", "example"],
      nameservers: [["ns", "example"]],
      mailbox: ["hostmaster", "example"],
      directory: :unused_directory
    }

    if not match?({:ok, _}, Wire.decode(packet)),
      do: refute(Authority.eligible?(packet, config))
  end
end
