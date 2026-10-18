defmodule Peach.HTTP do
  import Plug.Conn
  @behaviour Plug
  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, config) do
    with "GET" <- conn.method,
         "" <- conn.query_string,
         [encoded] <- get_req_header(conn, "x-overalls-binding"),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, binding} <- Jason.decode(json),
         {:ok, binding} <- OverallsProtocol.PrivateServices.binding(binding),
         true <- binding.host_id == config.host_id,
         {:ok, snapshot} <-
           Peach.Control.snapshot(Map.new(binding, fn {k, v} -> {Atom.to_string(k), v} end)),
         {:ok, snapshot} <- OverallsProtocol.Reflection.snapshot(snapshot) do
      body = response(conn.request_path, snapshot)
      if body, do: send_json(conn, 200, body), else: send_resp(conn, 404, "Not found\n")
    else
      {:error, :unavailable} -> send_resp(conn, 503, "Unavailable\n")
      _ -> send_resp(conn, 403, "Forbidden\n")
    end
  rescue
    _ -> send_resp(conn, 503, "Unavailable\n")
  end

  defp response("/", snapshot), do: OverallsProtocol.Reflection.root(snapshot)
  defp response("/guest", %{guest: guest}), do: guest
  defp response("/integrations", %{integrations: integrations}), do: integrations
  defp response(_, _), do: nil

  defp send_json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
