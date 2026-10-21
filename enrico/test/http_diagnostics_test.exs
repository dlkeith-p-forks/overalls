defmodule Enrico.HTTPDiagnosticsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "request exceptions retain a closed failure event without request data" do
    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {Overalls.Diagnostics.Formatter, [catalog: Enrico.Events]}],
        fn ->
          response =
            conn(:get, "/private-canary")
            |> Plug.Conn.put_req_header("authorization", "Bearer private-canary")
            |> Enrico.HTTP.call(%{token: nil})

          assert response.status == 503
        end
      )

    assert %{
             "event" => "enrico.request_failed",
             "metadata" => %{"reason" => "exception"}
           } = Jason.decode!(output)

    refute output =~ "private-canary"
  end

  test "manager unavailability produces a safe unavailable response and diagnostic" do
    refute Process.whereis(Enrico.Manager)

    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {Overalls.Diagnostics.Formatter, [catalog: Enrico.Events]}],
        fn ->
          response =
            conn(:get, "/v1/repos/private-canary/attempts/private-canary")
            |> Plug.Conn.put_req_header("authorization", "Bearer private-canary")
            |> Enrico.HTTP.call(%{token: "private-canary"})

          assert response.status == 503
        end
      )

    assert %{"event" => "enrico.request_failed", "metadata" => %{"reason" => "exit"}} =
             Jason.decode!(output)

    refute output =~ "private-canary"
  end
end
