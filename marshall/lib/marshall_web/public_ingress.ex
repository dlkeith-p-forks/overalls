defmodule MarshallWeb.PublicIngress do
  @moduledoc "Public SSH key discovery and refusal of machine control API paths."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] public-listener-machine-refusal
  # The public listener MUST expose only current known-host discovery and the
  # agent CLI routes under /api. Every other /api path, including unknown
  # services, versions and methods, MUST halt with an uncached 404 before body
  # parsing or machine dispatch. Headers and credentials MUST NOT bypass refusal.
  @impl true
  def call(
        %{path_info: ["api", "audi", "v1", "inception-known-hosts", label, service, layer]} = conn,
        _
      ),
      do: MarshallWeb.IngressKnownHosts.nested(conn, label, service, layer)

  def call(%{path_info: ["api", "audi", "v1", "known-hosts", label]} = conn, _),
    do: MarshallWeb.IngressKnownHosts.call(conn, label)

  def call(%{path_info: ["api", service | _]} = conn, _) when service != "agents" do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(404, "unavailable\n")
    |> halt()
  end

  def call(conn, _), do: conn
end
