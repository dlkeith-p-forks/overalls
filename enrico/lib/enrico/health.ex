defmodule Enrico.Health do
  @moduledoc "Local deployment readiness endpoint, separate from the fleet API."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(config), do: config

  @impl true
  def call(%{method: "GET", request_path: "/health/ready"} = conn, config) do
    ready = File.dir?(config.state_dir) and Process.whereis(Enrico.Manager) != nil

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(ready, do: 200, else: 503),
      JSON.encode!(%{version: 1, ready: ready, role: "enrico"})
    )
  end

  # @cc [owner:ghuntley,label:security] enrico-slo-private-projection
  # Only the local Unix health frontend may expose fixed numeric outcomes;
  # repository identity, source details and credentials MUST remain absent.
  def call(
        %{method: "GET", host: "localhost", request_path: "/slo", query_string: ""} = conn,
        _config
      ) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(Enrico.Manager.slo_snapshot()))
  end

  def call(conn, _), do: send_resp(conn, 404, "not_found")
end
