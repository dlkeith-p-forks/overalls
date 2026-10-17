defmodule Audi.HTTP.HeadersTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.HTTP.Headers

  @context %{
    host: "vm-0123456789ab4def8123456789abcdef.apps.example",
    port: 443,
    remote_ip: {192, 0, 2, 1},
    user_id: nil
  }

  property "untrusted forwarding and platform cookies cannot replace trusted context" do
    check all(value <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      headers = [
        {"X-Forwarded-For", value},
        {"Forwarded", value},
        {"X-Audi-User-Id", value},
        {"Cookie", "__Host-audi_session=" <> value <> "; guest=" <> value},
        {"Host", "attacker.example"},
        {"Authorization", "Basic " <> value},
        {"X-Overalls-Source-VM", "forged"}
      ]

      assert {:ok, clean} = Headers.request(headers, @context)
      assert List.keyfind(clean, "host", 0) == {"host", @context.host}
      assert List.keyfind(clean, "x-forwarded-for", 0) == {"x-forwarded-for", "192.0.2.1"}
      assert List.keyfind(clean, "cookie", 0) == {"cookie", "guest=" <> value}
      assert List.keyfind(clean, "authorization", 0) == {"authorization", "Basic " <> value}
      refute List.keymember?(clean, "x-overalls-source-vm", 0)
      refute List.keymember?(clean, "forwarded", 0)
      refute List.keymember?(clean, "x-audi-user-id", 0)
    end
  end

  test "verified peer context replaces authorization and source identity exactly once" do
    source = "01234567-89ab-4def-8123-456789abcdef"

    assert {:ok, clean} =
             Headers.request(
               [
                 {"authorization", "galileo-peer opaque"},
                 {"x-overalls-source-vm", "forged"},
                 {"X-Overalls-Source-VM", "also-forged"}
               ],
               Map.put(@context, :source_vm_id, source)
             )

    refute List.keymember?(clean, "authorization", 0)

    assert Enum.filter(clean, fn {name, _} -> name == "x-overalls-source-vm" end) == [
             {"x-overalls-source-vm", source}
           ]
  end

  property "response cookies remain separate and cannot set a sibling-domain or platform cookie" do
    check all(value <- string(:alphanumeric, min_length: 1, max_length: 80)) do
      assert {:ok, clean} =
               Headers.response([
                 {"Set-Cookie", "guest=" <> value <> "; Domain=.apps.example; Path=/; HttpOnly"},
                 {"Set-Cookie", "other=" <> value <> "; DOMAIN=apps.example"},
                 {"Set-Cookie", "__Host-audi_session=" <> value <> "; Path=/; Secure"}
               ])

      assert [{"set-cookie", first}, {"set-cookie", second}] = clean
      assert first == "guest=" <> value <> "; Path=/; HttpOnly"
      assert second == "other=" <> value
    end
  end

  test "connection-nominated fields and framing cannot survive either direction" do
    fields = [
      {"Connection", "x-hop, cookie"},
      {"X-Hop", "secret"},
      {"Cookie", "guest=secret"},
      {"Content-Length", "999"},
      {"Transfer-Encoding", "chunked"}
    ]

    assert {:ok, clean} = Headers.request(fields, @context)

    refute Enum.any?(clean, fn {key, _} ->
             key in ~w(connection x-hop cookie content-length transfer-encoding)
           end)

    assert {:ok, []} = Headers.response(fields)
  end

  test "control bytes and bounds reject the whole header list" do
    for headers <- [
          [{"x", "a\r\nb"}],
          [{"x", <<0>>}],
          [{"x", String.duplicate("a", 8193)}],
          List.duplicate({"x", "a"}, 65)
        ] do
      assert {:error, :invalid_headers} = Headers.request(headers, @context)
      assert {:error, :invalid_headers} = Headers.response(headers)
    end
  end
end
