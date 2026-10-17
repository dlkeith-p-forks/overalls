defmodule OverallsProtocol.WebSocketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @limit 70_000

  @spec frame() :: StreamData.t(Frame.frame())
  defp frame do
    one_of([
      map(string(:printable, max_length: 300), &{:text, &1}),
      map(binary(max_length: 70_000), &{:binary, &1}),
      map(binary(max_length: 125), &{:ping, &1}),
      map(binary(max_length: 125), &{:pong, &1}),
      map({integer(1000..4999), string(:alphanumeric, max_length: 100)}, fn {code, reason} ->
        {:close, code, reason}
      end)
    ])
  end

  property "every frame round-trips in both directions, also when split" do
    check all(frame <- frame(), cut <- integer(0..200), max_runs: 200) do
      for {sender, receiver} <- [client: :server, server: :client] do
        {:ok, data} = Frame.encode(frame, sender, @limit)
        data = IO.iodata_to_binary(data)
        assert {:ok, ^frame, "tail"} = Frame.decode(data <> "tail", receiver, @limit)
        prefix = binary_part(data, 0, min(cut, byte_size(data) - 1))
        assert Frame.decode(prefix, receiver, @limit) == :more
      end
    end
  end

  property "arbitrary input never raises and never yields a frame from the wrong role" do
    check all(input <- binary(max_length: 300), max_runs: 500) do
      for role <- [:client, :server] do
        assert match?({:ok, _, _}, Frame.decode(input, role, @limit)) or
                 Frame.decode(input, role, @limit) in [
                   :more,
                   {:error, :protocol_error},
                   {:error, :frame_too_large}
                 ]
      end
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
