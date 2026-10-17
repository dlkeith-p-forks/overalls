defmodule Enrico.HTTP do
  @moduledoc "Authenticated, versioned fleet API for mirror work and bounded Git reads."
  @behaviour Plug
  import Plug.Conn
  require Enrico.Events
  alias Enrico.{Git, Manager}

  @impl true
  def init(config), do: config

  # @cc [owner:ghuntley,label:security] enrico-closed-fleet-api
  # Every API request MUST present the dedicated service token before reading
  # Git objects or starting work. Inputs and outputs MUST remain bounded.
  @impl true
  def call(conn, config) do
    if authenticated?(conn, config.token) do
      dispatch(conn, config)
    else
      Enrico.Events.emit("enrico.request_denied", reason: :unauthorized)
      reply(conn, 401, %{error: "unauthorized"})
    end
  rescue
    _ -> reply(conn, 503, %{error: "unavailable"})
  end

  defp dispatch(%{method: "POST", path_info: ["v1", "repos", id, "refresh"]} = conn, _) do
    with {:ok, bytes, conn} <- read_body(conn, length: 4096, read_length: 4096),
         {:ok, %{"attempt_id" => attempt, "owner" => owner, "repo" => repo}} <- JSON.decode(bytes) do
      case Manager.refresh(id, attempt, owner, repo) do
        {:ok, status} -> reply(conn, 202, %{status: status})
        {:error, :busy} -> reply(conn, 409, %{error: "busy"})
        {:error, :unavailable} -> reply(conn, 503, %{error: "unavailable"})
        _ -> reply(conn, 400, %{error: "invalid_request"})
      end
    else
      _ -> reply(conn, 400, %{error: "invalid_request"})
    end
  end

  defp dispatch(%{method: "GET", path_info: ["v1", "repos", id, "attempts", attempt]} = conn, _) do
    reply(conn, 200, %{status: Manager.status(id, attempt)})
  end

  defp dispatch(%{method: "DELETE", path_info: ["v1", "repos", id]} = conn, _) do
    case Manager.remove(id) do
      :ok -> reply(conn, 200, %{status: "removed"})
      {:error, :busy} -> reply(conn, 409, %{error: "busy"})
      _ -> reply(conn, 400, %{error: "invalid_request"})
    end
  end

  defp dispatch(%{method: "GET", path_info: ["v1", "repos", id, "git", operation]} = conn, config)
       when operation in ["tree", "blob", "history", "diff", "blame", "refs"] do
    conn = fetch_query_params(conn)
    ref = Map.get(conn.params, "ref", "HEAD")
    path = Map.get(conn.params, "path", "")

    root = Path.join(config.state_dir, id <> ".git")

    if uuid?(id) and File.dir?(root) do
      case Git.inspect(root, operation, ref, path) do
        {:ok, value} when operation == "blob" ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("content-disposition", "attachment")
          |> send_resp(200, value)

        {:ok, value} ->
          reply(conn, 200, %{data_base64: Base.encode64(value)})

        _ ->
          reply(conn, 404, %{error: "not_found"})
      end
    else
      reply(conn, 404, %{error: "not_found"})
    end
  end

  defp dispatch(%{method: "GET", path_info: ["v1", "repos", id, "search"]} = conn, config) do
    conn = fetch_query_params(conn)
    root = Path.join(config.state_dir, id <> ".git")

    if uuid?(id) and File.dir?(root) do
      case Git.search(
             root,
             Map.get(conn.params, "ref", "HEAD"),
             Map.get(conn.params, "kind", "content"),
             Map.get(conn.params, "q", "")
           ) do
        {:ok, value} -> reply(conn, 200, %{data_base64: Base.encode64(value)})
        _ -> reply(conn, 400, %{error: "search_failed"})
      end
    else
      reply(conn, 400, %{error: "search_failed"})
    end
  end

  defp dispatch(conn, _), do: reply(conn, 404, %{error: "not_found"})

  defp authenticated?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] ->
        Plug.Crypto.secure_compare(:crypto.hash(:sha256, supplied), :crypto.hash(:sha256, token))

      _ ->
        false
    end
  end

  @spec uuid?(binary()) :: boolean()
  defp uuid?(value),
    do:
      Regex.match?(
        ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        value
      )

  defp reply(conn, code, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(code, JSON.encode!(body))
  end
end
