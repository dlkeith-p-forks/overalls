defmodule OverallsProtocol.HegelTerminalTest do
  use ExUnit.Case, async: true
  use Hegel

  alias OverallsProtocol.Terminal

  property "data frames preserve channel, sequence and payload", database: :disabled, test_cases: 64, seed: 20261017 do
    channel = draw("channel", Hegel.Gen.integer(1, 100))
    sequence = draw("sequence", Hegel.Gen.integer(1, 1_000_000))
    payload = draw("payload", Hegel.Gen.binary(0, 256))
    wire = Terminal.encode_data_frame(channel, sequence, payload)
    assert {:ok, %{channel: ^channel, sequence: ^sequence, bytes: ^payload}} = Terminal.decode_frame(wire)
    assert Terminal.frame_consumed(wire) == byte_size(wire)
  end

  property "truncating a valid frame is reported as partial", database: :disabled, test_cases: 48, seed: 20261018 do
    channel = draw(Hegel.Gen.integer(1, 100))
    sequence = draw(Hegel.Gen.integer(1, 1_000_000))
    payload = draw(Hegel.Gen.binary(1, 128))
    wire = Terminal.encode_data_frame(channel, sequence, payload)
    cut = draw(Hegel.Gen.integer(0, byte_size(wire) - 1))
    assert :partial = Terminal.decode_frame(binary_part(wire, 0, cut))
  end
end
