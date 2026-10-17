defmodule MarshallWeb.PublicEndpointTest do
  use MarshallWeb.ConnCase, async: true

  test "browser endpoint refuses machine APIs before JSON parsing or credentials" do
    for service <- ["provisioners", "ssh", "ziggy", "audi", "fleet"] do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer synthetic-fixture")
        |> put_req_header("x-forwarded-for", "127.0.0.1")
        |> post("https://localhost/api/#{service}/v1/identity", "invalid-json")

      assert response.status == 404
      assert response.resp_body == "unavailable\n"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "set-cookie") == []
    end
  end
end
