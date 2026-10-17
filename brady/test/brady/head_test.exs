defmodule Brady.HTTP.HeadTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.HTTP.Head

  test "body bytes are preserved and hop-by-hop fields cannot escape" do
    raw =
      "GET /package HTTP/1.1\r\nHost: example.com\r\nConnection: x-secret\r\nX-Secret: remove\r\nContent-Length: 4\r\n\r\ndata"

    assert {:ok, head, "data"} = Head.parse(raw, :request)
    assert head.body == {:length, 4}
    output = head |> Head.request_bytes() |> IO.iodata_to_binary()
    refute output =~ "x-secret"
    assert output =~ "content-length: 4"
  end

  test "ambiguous lengths, request smuggling and header folding are refused" do
    for fields <- [
          "Content-Length: 1\r\nContent-Length: 1",
          "Content-Length: 1\r\nTransfer-Encoding: chunked",
          "Transfer-Encoding: gzip, chunked",
          "Content-Length: -1",
          " Host: attacker",
          "Host: duplicate",
          "Bad : value",
          "X: a\rb"
        ] do
      assert {:error, :invalid_http} =
               Head.parse(
                 "POST / HTTP/1.1\r\nHost: example.com\r\n" <> fields <> "\r\n\r\n",
                 :request
               )
    end

    assert {:error, :invalid_http} = Head.parse(String.duplicate("x", 32_769), :request)
  end

  property "every prefix remains incomplete until the header terminator arrives" do
    check all(target <- string(:alphanumeric, min_length: 1, max_length: 50)) do
      raw = "GET /#{target} HTTP/1.1\r\nHost: example.com\r\n\r\n"

      for size <- 0..(byte_size(raw) - 1) do
        assert :more = Head.parse(binary_part(raw, 0, size), :request)
      end

      assert {:ok, _, ""} = Head.parse(raw, :request)
    end
  end

  test "HTTP3 advertisements are stripped on responses" do
    {:ok, head, _} =
      Head.parse(
        "HTTP/1.1 200 OK\r\nAlt-Svc: h3=\":443\"\r\nContent-Length: 0\r\n\r\n",
        :response
      )

    refute head |> Head.response_bytes() |> IO.iodata_to_binary() |> String.contains?("h3")
  end
end
