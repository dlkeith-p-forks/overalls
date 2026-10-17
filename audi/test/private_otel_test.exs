defmodule Audi.PrivateOtelTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Audi.Private.Front

  @paths ["/v1/metrics", "/v1/traces"]

  property "only exact protobuf metric and trace POSTs enter the guest OTLP route" do
    check all(
            path <- member_of(@paths ++ ["/v1/logs", "/v1/metrics/", "/metrics", "/"]),
            method <- member_of([:post, :get, :put, :delete]),
            content_type <-
              member_of(["application/x-protobuf", "application/json", "text/plain"]),
            query <- member_of(["", "extra=1"])
          ) do
      url =
        "https://otel.integration.internal" <> path <> if(query == "", do: "", else: "?" <> query)

      conn =
        Plug.Test.conn(method, url)
        |> Plug.Conn.put_req_header("content-type", content_type)

      accepted =
        method == :post and path in @paths and content_type == "application/x-protobuf" and
          query == ""

      assert Front.allowed_request?(:otel, conn) == accepted
    end
  end

  property "bounded declared body lengths and no content encoding" do
    check all(length <- integer(0..2_000_000), encoded <- boolean()) do
      conn =
        Plug.Test.conn(:post, "https://otel.integration.internal/v1/traces")
        |> Plug.Conn.put_req_header("content-type", "application/x-protobuf")
        |> Plug.Conn.put_req_header("content-length", Integer.to_string(length))

      conn =
        if encoded,
          do: Plug.Conn.put_req_header(conn, "content-encoding", "gzip"),
          else: conn

      assert Front.allowed_request?(:otel, conn) == (length <= 1_048_576 and not encoded)
    end
  end

  test "invalid and duplicate length headers refuse" do
    base =
      Plug.Test.conn(:post, "https://otel.integration.internal/v1/metrics")
      |> Plug.Conn.put_req_header("content-type", "application/x-protobuf")

    for invalid <- ["-1", "1x", "999999999999999999999", "+1"] do
      conn = Plug.Conn.put_req_header(base, "content-length", invalid)
      refute Front.allowed_request?(:otel, conn)
    end

    conn = %{
      base
      | req_headers: [{"content-length", "1"}, {"content-length", "2"} | base.req_headers]
    }

    refute Front.allowed_request?(:otel, conn)
  end
end
