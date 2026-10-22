defmodule MarshallWeb.ArtifactContentEndpoint do
  @moduledoc """
  The isolated artifact content origin. No session, socket, body parser or
  browser route: only `GET`/`HEAD /v/<ticket>/[path]`, authorized by a short
  view ticket and a fresh Cedar read on every request.
  """
  use Plug.Builder
  require Marshall.Events
  alias Marshall.Artifacts.{Blobs, Library, Paths, Tickets}
  alias MarshallWeb.ArtifactContentHeaders

  plug :lockdown
  plug :dispatch

  # @cc [owner:ghuntley,label:security] artifact-content-closed-routing
  # The content listener MUST serve only GET and HEAD on /v/<ticket>/ and
  # /v/<ticket>/<path>; everything else (including health paths) is an uncached
  # 404 with the lockdown headers. It MUST NOT read a request body, fetch a
  # session, set a cookie, or log tickets, paths or headers.
  @spec lockdown(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def lockdown(conn, _opts) do
    config = config()

    conn
    |> assign(:artifact_content, config)
    |> ArtifactContentHeaders.put(config.host || "invalid", marshall_host())
    |> register_before_send(fn conn ->
      ArtifactContentHeaders.put(conn, config.host || "invalid", marshall_host())
    end)
  end

  @spec dispatch(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def dispatch(%Plug.Conn{method: method, path_info: ["v", ticket | path]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    started = System.monotonic_time()

    conn =
      Overalls.Diagnostics.Tracing.with_span("marshall.artifact.content", [], fn ->
        serve(conn, ticket, path)
      end)

    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    Overalls.Diagnostics.Metrics.record(
      [:marshall, :artifacts, :content],
      %{duration: elapsed, refused: conn.status not in [200, 304]},
      %{}
    )

    halt(conn)
  end

  def dispatch(conn, _opts), do: not_found(conn)

  @spec serve(Plug.Conn.t(), String.t(), [String.t()]) :: Plug.Conn.t()
  defp serve(conn, ticket, path) do
    host = conn.assigns.artifact_content.host

    with true <- is_binary(host) and conn.host == host,
         {:ok, %{artifact: artifact, version: version}} <- Tickets.redeem(ticket, host) do
      case path do
        [] -> page(conn, version)
        [""] -> page(conn, version)
        ["__echo"] -> echo(conn)
        segments -> file(conn, version, Enum.join(segments, "/"), artifact)
      end
    else
      _ -> refuse(conn, :invalid_ticket)
    end
  end

  @spec page(Plug.Conn.t(), Marshall.Artifacts.Version.t()) :: Plug.Conn.t()
  defp page(conn, version) do
    body =
      case version.format do
        :markdown -> Marshall.Artifacts.Markdown.render(Library.page(version), version.title)
        :html -> Library.page(version)
      end

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, Marshall.Artifacts.PageHelper.inject(body))
  end

  @spec file(Plug.Conn.t(), Marshall.Artifacts.Version.t(), String.t(), term()) :: Plug.Conn.t()
  defp file(conn, version, raw, _artifact) do
    with {:ok, path} <- Paths.normalize(raw),
         %{} = entry <- Enum.find(Library.files(version), &(&1.path == path)) do
      {type, disposition} = Paths.media_type(path)

      conn =
        conn
        |> put_resp_header("content-type", type)
        |> put_resp_header("content-length", Integer.to_string(entry.bytes))

      conn =
        if disposition == :attachment,
          do: put_resp_header(conn, "content-disposition", "attachment"),
          else: conn

      if conn.method == "HEAD" do
        send_resp(conn, 200, "")
      else
        conn = send_chunked(conn, 200)

        Enum.reduce_while(Blobs.stream(entry.sha256), conn, fn data, acc ->
          case chunk(acc, data) do
            {:ok, acc} -> {:cont, acc}
            {:error, _} -> {:halt, acc}
          end
        end)
      end
    else
      _ -> refuse(conn, :not_found)
    end
  end

  # Test-only observation of what the proxy forwarded; never in production.
  @spec echo(Plug.Conn.t()) :: Plug.Conn.t()
  defp echo(conn) do
    if conn.assigns.artifact_content.debug_echo do
      body =
        Jason.encode!(%{
          cookie: get_req_header(conn, "cookie") != [],
          authorization: get_req_header(conn, "authorization") != []
        })

      conn
      |> put_resp_header("content-type", "application/json")
      |> put_private(:artifact_echo_probe, true)
      |> put_resp_header("set-cookie", "probe=1")
      |> send_resp(200, body)
    else
      refuse(conn, :not_found)
    end
  end

  @spec refuse(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  defp refuse(conn, reason) do
    Marshall.Events.emit("artifact.content_refused", reason: reason)
    not_found(conn)
  end

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  defp not_found(conn) do
    conn
    |> put_resp_header("content-type", "text/plain; charset=utf-8")
    |> send_resp(404, "unavailable\n")
    |> halt()
  end

  @spec config() :: %{host: String.t() | nil, debug_echo: boolean()}
  def config do
    content = Application.get_env(:marshall, :artifact_content) || %{}
    %{host: Map.get(content, :host), debug_echo: Map.get(content, :debug_echo, false)}
  end

  @spec marshall_host() :: String.t()
  defp marshall_host do
    MarshallWeb.Endpoint.config(:url)[:host] || "localhost"
  end
end
