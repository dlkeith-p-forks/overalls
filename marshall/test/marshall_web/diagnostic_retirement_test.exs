defmodule MarshallWeb.DiagnosticRetirementTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Plug.Conn
  import Plug.Test

  property "retired fleet ingestion refuses every credential and preserves unread bodies" do
    method = draw("method", member_of([:get, :post, :put, :delete]))
    credential = draw("credential", string(:alphanumeric, max_length: 120))
    suffix = draw("suffix", member_of(["v1/samples", "v999/samples", ""]))

    response =
      conn(method, "https://fleet.example.test/api/fleet/" <> suffix, "private-fixture")
      |> put_req_header("authorization", "Bearer " <> credential)
      |> put_req_header("content-type", "application/json")
      |> MarshallWeb.FleetEndpoint.call([])

    assert response.status == 404
    assert response.halted
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert {:ok, "private-fixture", _} = read_body(response)
  end
end
