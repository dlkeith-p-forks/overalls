defmodule Peach.HTTP do
  @moduledoc "Private reflection Plug behind Audi's private frontend."
  import Plug.Conn
  require Peach.Events
  @behaviour Plug

  @paths ["/", "/guest", "/integrations"]

  @impl true
  def init(config), do: config

  # @cc [owner:ghuntley,label:security] peach-request-admission
  # Only bodiless GET requests for a fixed path, without a query, carrying
  # exactly one protocol-valid binding for this host may ask Marshall for a
  # projection. Unknown paths answer 404 before any control request; a
  # projection is served only after the shared protocol validates it.
  @impl true
  def call(conn, config) do
    case admit(conn, config) do
      {:ok, binding} -> project(conn, config, binding)
      {:error, status, reason} -> refuse(conn, status, reason, config.host_id, nil)
    end
  rescue
    _ -> refuse(conn, 503, :internal, config.host_id, nil)
  end

  @spec admit(Plug.Conn.t(), map()) :: {:ok, map()} | {:error, 403 | 404 | 405, atom()}
  defp admit(conn, config) do
    with {:method, "GET"} <- {:method, conn.method},
         {:path, path} when path in @paths <- {:path, conn.request_path},
         {:query, ""} <- {:query, conn.query_string},
         [encoded] <- get_req_header(conn, "x-overalls-binding"),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, wire} <- Jason.decode(json),
         {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
         true <- binding.host_id == config.host_id do
      {:ok, binding}
    else
      {:method, _} -> {:error, 405, :method}
      {:path, _} -> {:error, 404, :path}
      {:query, _} -> {:error, 403, :query}
      _ -> {:error, 403, :binding}
    end
  end

  @spec project(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  defp project(conn, config, binding) do
    wire = Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end)

    with {:control, {:ok, object}} <- {:control, Peach.Control.snapshot(config.control, wire)},
         {:ok, snapshot} <- OverallsProtocol.Reflection.snapshot(object),
         true <- snapshot.guest["id"] == binding.vm_id do
      Peach.Events.emit("peach.request_served", host_id: binding.host_id, vm_id: binding.vm_id)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(response(conn.request_path, snapshot)))
    else
      {:control, {:error, :refused}} ->
        refuse(conn, 403, :refused, binding.host_id, binding.vm_id)

      {:control, {:error, :unavailable}} ->
        refuse(conn, 503, :unavailable, binding.host_id, binding.vm_id)

      _ ->
        refuse(conn, 503, :invalid_snapshot, binding.host_id, binding.vm_id)
    end
  end

  @spec response(binary(), OverallsProtocol.Reflection.snapshot()) :: map() | list()
  defp response("/", snapshot), do: OverallsProtocol.Reflection.root(snapshot)
  defp response("/guest", snapshot), do: snapshot.guest
  defp response("/integrations", snapshot), do: snapshot.integrations

  @spec refuse(Plug.Conn.t(), 403 | 404 | 405 | 503, atom(), binary() | nil, binary() | nil) ::
          Plug.Conn.t()
  defp refuse(conn, status, reason, host_id, vm_id) do
    Peach.Events.emit("peach.request_refused", host_id: host_id, vm_id: vm_id, reason: reason)

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body(status))
  end

  defp body(403), do: "Forbidden\n"
  defp body(404), do: "Not found\n"
  defp body(405), do: "Method not allowed\n"
  defp body(503), do: "Unavailable\n"
end
