defmodule OverallsProtocol.AndroidDisplayStreamTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.AndroidDisplayStream

  test "data frames round trip only for the current generation" do
    assert {:ok, frame} = AndroidDisplayStream.encode_data(4, 1, <<1, 2, 3>>)

    assert {:ok, %{generation: 4, sequence: 1, bytes: <<1, 2, 3>>}} =
             AndroidDisplayStream.decode_data(frame, 4)

    assert {:error, :invalid_frame} = AndroidDisplayStream.decode_data(frame, 5)
  end

  test "input frames are bounded and typed" do
    assert {:ok, <<2, _::binary>>} = AndroidDisplayStream.encode_input(4, :pointer, <<0, 1>>)
    assert {:error, :invalid_frame} = AndroidDisplayStream.encode_input(0, :key, <<1>>)
    assert {:error, :invalid_frame} = AndroidDisplayStream.encode_input(4, :touch, <<1>>)
  end
end
