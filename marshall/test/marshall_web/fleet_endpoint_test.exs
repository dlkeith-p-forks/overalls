defmodule MarshallWeb.FleetEndpointTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Plug.Conn
  import Plug.Test

  test "machine listener has no browser sessions, login redirects or websocket routes" do
    for path <- ["/", "/sign-in", "/machines", "/live/websocket", "/api/unknown"] do
      response = MarshallWeb.FleetEndpoint.call(conn(:get, path), [])
      assert response.status == 404
      assert response.halted
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "set-cookie") == []
      assert get_resp_header(response, "location") == []
    end
  end

  test "public boundary refuses every machine API prefix without reading its body" do
    for service <- ["provisioners", "ssh", "audi", "control", "terminal-peer", "unknown"],
        suffix <- ["", "/v1/identity", "/v999/unknown"],
        method <- [:get, :post, :put, :delete] do
      request =
        conn(method, "https://example.test/api/#{service}#{suffix}", "not-json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer synthetic-fixture")
        |> put_req_header("x-forwarded-for", "127.0.0.1")

      response = MarshallWeb.PublicIngress.call(request, [])
      assert response.status == 404
      assert response.halted
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert {:ok, "not-json", _} = read_body(response)
    end
  end

  test "public discovery preserves the actual HTTPS requirement" do
    for path <- [
          "/api/audi/v1/known-hosts/example",
          "/api/audi/v1/inception-known-hosts/example/audi/inner"
        ] do
      response =
        conn(:get, path)
        |> put_req_header("x-forwarded-proto", "https")
        |> MarshallWeb.PublicIngress.call([])

      assert response.status == 404
      assert response.halted
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "ordinary browser paths and agent CLI routes pass through the public boundary unchanged" do
    for path <- ["/machines", "/api/agents/v1/session"] do
      request = conn(:get, path)
      assert MarshallWeb.PublicIngress.call(request, []) == request
    end
  end

  property "listener routing ignores method, host header and supplied machine credential" do
    check all(
            service <-
              one_of([
                member_of(~w(provisioners ssh audi control terminal-peer)),
                filter(string(:alphanumeric, min_length: 1, max_length: 12), &(&1 != "agents"))
              ]),
            suffix <- member_of(["v1/identity", "v3/clone", "v999/unknown"]),
            method <- member_of([:get, :post, :put, :delete]),
            host <- member_of(["example.test", "fleet.example.test", "localhost"]),
            slug <- string(:alphanumeric, min_length: 1, max_length: 24),
            max_runs: 60
          ) do
      machine_path = "/api/#{service}/#{suffix}"

      public =
        conn(method, "https://#{host}#{machine_path}", "not-json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer synthetic-fixture")
        |> MarshallWeb.PublicIngress.call([])

      assert public.status == 404
      assert public.halted
      assert get_resp_header(public, "cache-control") == ["no-store"]
      assert get_resp_header(public, "set-cookie") == []
      assert {:ok, "not-json", _} = read_body(public)

      fleet =
        conn(method, "https://#{host}/machines/#{slug}", "not-json")
        |> put_req_header("authorization", "Lilly synthetic-fixture")
        |> MarshallWeb.FleetEndpoint.call([])

      assert fleet.status == 404
      assert fleet.halted
      assert get_resp_header(fleet, "cache-control") == ["no-store"]
      assert get_resp_header(fleet, "set-cookie") == []
      assert get_resp_header(fleet, "location") == []
    end
  end
end
