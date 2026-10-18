defmodule Audi.HTTP.WebSocketFrameTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.HTTP.WebSocketFrame, as: Frame

  property "client encoding masks every payload and canonical length boundary" do
    payload = draw("payload", binary(max_length: 8192))
    kind = draw("kind", member_of([:text, :binary]))
    assert {:ok, frame} = Frame.encode(kind, payload)
    <<1::1, 0::3, opcode::4, 1::1, length::7, rest::binary>> = frame
    assert opcode == if(kind == :text, do: 1, else: 2)

    {size, rest} =
      case length do
        126 ->
          <<size::16, rest::binary>> = rest
          {size, rest}

        127 ->
          <<size::64, rest::binary>> = rest
          {size, rest}

        size ->
          {size, rest}
      end

    assert size == byte_size(payload)
    <<mask::binary-size(4), encoded::binary>> = rest
    repeated = binary_part(:binary.copy(mask, div(size + 3, 4)), 0, size)
    assert :crypto.exor(encoded, repeated) == payload
    assert :error = Frame.decode(frame)
  end

  property "server decoding handles every split without losing trailing frames" do
    payload = draw("payload", binary(max_length: 125))
    split = draw("split", integer(0..127))
    frame = <<1::1, 0::3, 2::4, 0::1, byte_size(payload)::7, payload::binary>>
    size = min(split, byte_size(frame) - 1)
    assert :more = Frame.decode(binary_part(frame, 0, size))

    assert {:ok, %{final: true, opcode: 2, payload: ^payload}, ^frame} =
             Frame.decode(frame <> frame)
  end

  property "untrusted frame headers fail closed or remain bounded" do
    bytes = draw("bytes", binary(max_length: 512))

    case Frame.decode(bytes) do
      {:ok, frame, _} -> assert byte_size(frame.payload) <= Frame.maximum()
      value -> assert value in [:more, :error]
    end

    assert :error = Frame.decode(<<0x82, 127, 1_048_577::64>>)
    assert :error = Frame.decode(<<0x89, 126, 126::16>>)
    assert :error = Frame.decode(<<0x82, 126, 1::16>>)
    assert :error = Frame.decode(<<0x09, 0>>)
  end
end
