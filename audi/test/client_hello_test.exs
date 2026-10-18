defmodule Audi.Inception.ClientHelloTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.Inception.ClientHello

  defp body(extensions) do
    <<3, 3, 0::256, 0, 2::16, 0x1301::16, 1, 0, byte_size(extensions)::16, extensions::binary>>
  end

  defp sni(host) do
    value = <<byte_size(host) + 3::16, 0, byte_size(host)::16, host::binary>>
    <<0::16, byte_size(value)::16, value::binary>>
  end

  test "only one canonical SNI and exact extension lengths are accepted" do
    assert {:ok, "apps.example"} = ClientHello.parse(body(sni("apps.example")))

    for extensions <- [
          <<>>,
          sni("apps.example") <> sni("apps.example"),
          sni("*.example"),
          sni("Apps.example"),
          sni("a..example"),
          sni("apps.example") <> <<1, 2, 3>>
        ] do
      assert {:error, :invalid_client_hello} = ClientHello.parse(body(extensions))
    end
  end

  property "malformed hello bodies fail without raising" do
    bytes = draw("bytes", binary(max_length: 65536))
    assert {:error, :invalid_client_hello} = ClientHello.parse(bytes)
  end

  test "fragmented records preserve all original bytes" do
    hello = body(sni("apps.example"))
    handshake = <<1, byte_size(hello)::24, hello::binary>>
    <<first::binary-size(2), rest::binary>> = handshake
    wire = <<22, 3, 1, 2::16, first::binary, 22, 3, 3, byte_size(rest)::16, rest::binary>>
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)
        result = ClientHello.read(socket)
        :gen_tcp.close(socket)
        result
      end)

    {:ok, peer} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    :ok = :gen_tcp.send(peer, wire)
    assert {:ok, "apps.example", ^wire} = Task.await(task, 2000)
    :gen_tcp.close(peer)
  end
end
