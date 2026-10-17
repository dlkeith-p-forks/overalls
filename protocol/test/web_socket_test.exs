defmodule OverallsProtocol.WebSocketTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen

  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @limit 70_000

  @spec frame() :: :hegel_gen.t(Frame.frame())
  defp frame do
    one_of([
      map(utf8(0, 300), &{:text, &1}),
      map(binary(max_length: 70_000), &{:binary, &1}),
      map(binary(max_length: 125), &{:ping, &1}),
      map(binary(max_length: 125), &{:pong, &1}),
      map(tuple([integer(1000, 4999), utf8(0, 100)]), fn {code, reason} ->
        {:close, code, reason}
      end)
    ])
  end

  property "every frame round-trips in both directions, also when split",
    database: :disabled,
    print_blob: false,
    test_cases: 200,
    seed: 20_261_106 do
    frame = draw("frame", frame())
    cut = draw("cut", integer(0, 200))

    for {sender, receiver} <- [client: :server, server: :client] do
      {:ok, data} = Frame.encode(frame, sender, @limit)
      data = IO.iodata_to_binary(data)
      assert {:ok, ^frame, "tail"} = Frame.decode(data <> "tail", receiver, @limit)
      prefix = binary_part(data, 0, min(cut, byte_size(data) - 1))
      assert Frame.decode(prefix, receiver, @limit) == :more
    end
  end

  property "arbitrary input never raises and never yields a frame from the wrong role",
    database: :disabled,
    print_blob: false,
    test_cases: 500,
    seed: 20_261_107 do
    input = draw("input", binary(0, 300))

    for role <- [:client, :server] do
      assert match?({:ok, _, _}, Frame.decode(input, role, @limit)) or
               Frame.decode(input, role, @limit) in [
                 :more,
                 {:error, :protocol_error},
                 {:error, :frame_too_large}
               ]
    end
  end

  test "masking, fragmentation, reserved bits and limits are enforced" do
    {:ok, client} = Frame.encode({:text, "hi"}, :client, @limit)
    client = IO.iodata_to_binary(client)
    # A client frame is masked, so a client decoding it refuses it.
    assert Frame.decode(client, :client, @limit) == {:error, :protocol_error}

    assert Frame.decode(<<0::1, 0::3, 1::4, 0::1, 1::7, "x">>, :client, @limit) ==
             {:error, :protocol_error}

    assert Frame.decode(<<1::1, 1::3, 2::4, 0::1, 1::7, "x">>, :client, @limit) ==
             {:error, :protocol_error}

    assert Frame.decode(<<1::1, 0::3, 3::4, 0::1, 0::7>>, :client, @limit) ==
             {:error, :protocol_error}

    assert Frame.encode({:binary, :binary.copy("a", 11)}, :server, 10) ==
             {:error, :frame_too_large}

    assert Frame.encode({:ping, :binary.copy("a", 126)}, :server, @limit) ==
             {:error, :frame_too_large}

    big = <<1::1, 0::3, 2::4, 0::1, 127::7, 0::1, 1_000_000::63>>
    assert Frame.decode(big, :client, @limit) == {:error, :frame_too_large}
    # Non-minimal length encodings are refused.
    assert Frame.decode(<<1::1, 0::3, 2::4, 0::1, 126::7, 5::16, "hello">>, :client, @limit) ==
             {:error, :protocol_error}

    # Text must be valid UTF-8.
    assert Frame.decode(<<1::1, 0::3, 1::4, 0::1, 1::7, 255>>, :client, @limit) ==
             {:error, :protocol_error}
  end

  test "the handshake accepts only a matching 101 and bounds the head" do
    key = Handshake.key()

    ok =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{Handshake.accept(key)}\r\n\r\nrest"

    assert Handshake.response(ok, key) == {:ok, "rest"}
    assert Handshake.response(binary_part(ok, 0, 20), key) == :more

    assert Handshake.response("HTTP/1.1 426 Upgrade Required\r\n\r\n", key) ==
             {:error, {:status, 426}}

    wrong = String.replace(ok, Handshake.accept(key), Handshake.accept(Handshake.key()))
    assert Handshake.response(wrong, key) == {:error, :handshake_failed}
    assert Handshake.response(:binary.copy("a", 9000), key) == {:error, :handshake_failed}

    request =
      IO.iodata_to_binary(Handshake.request("h.example", "/api/x", key, [{"authorization", "t"}]))

    assert request =~ "GET /api/x HTTP/1.1\r\nHost: h.example\r\n"
    assert String.ends_with?(request, "authorization: t\r\n\r\n")
  end
end
