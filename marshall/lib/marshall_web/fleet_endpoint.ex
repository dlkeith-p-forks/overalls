defmodule MarshallWeb.FleetEndpoint do
  @moduledoc "Machine transport without browser routes, sessions or generic body parsing."
  use Plug.Builder

  # @cc [owner:ghuntley,label:security] fleet-listener-closed-routing
  # The fleet transport MUST dispatch only health and purpose-authenticated machine
  # APIs. Unmatched requests MUST terminate with an uncached 404, never enter the
  # browser router, establish a session or redirect to a browser login. Each API
  # MUST retain its own bounded body reader and transport/credential checks.
  plug MarshallWeb.AuthenticationPrivacy
  plug MarshallWeb.Health
  plug MarshallWeb.ControlAPI
  plug MarshallWeb.ProvisionerAPI
  plug MarshallWeb.TerminalPeerAPI
  plug MarshallWeb.TerminalGatewayAPI
  plug MarshallWeb.SSHAPI
  plug MarshallWeb.IngressAPI
  plug :not_found

  defp not_found(conn, _) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(404, "unavailable\n")
    |> halt()
  end
end
