defmodule MarshallWeb.Health do
  @moduledoc "Load-balancer probes without sessions, account data or database diagnostics."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(%{method: method, request_path: "/health/live"} = conn, _)
      when method in ["GET", "HEAD"],
      do: respond(conn, 200)

  def call(%{method: method, request_path: "/health/ready"} = conn, _)
      when method in ["GET", "HEAD"],
      do: respond(conn, if(Marshall.Operations.Health.ready?(), do: 200, else: 503))

  def call(conn, _), do: conn

  # @cc [owner:ghuntley,label:security] health-minimal-uncached-response
  # Health responses MUST be uncached fixed status messages without sessions,
  # database details or account data; HEAD responses MUST have an empty body.
  defp respond(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(
      status,
      if(conn.method == "HEAD",
        do: "",
        else: if(status == 200, do: "ok\n", else: "unavailable\n")
      )
    )
    |> halt()
  end
end
