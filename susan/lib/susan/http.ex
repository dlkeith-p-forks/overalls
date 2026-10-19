defmodule Susan.HTTP do
  @moduledoc """
  Susan's public HTTP surface behind the TLS-terminating proxy:

    * `POST /api/push/v1/keys` (Mila) -> 201 `{push_key, key_id, expires_at}`
    * `POST /api/push/v1/poke` (Marshall) -> 204 / 400 / 404 / 410 / 429 / 503
    * `GET /healthz` -> 200 `{"status":"ok"}` or 503

  Bodies are capped at 1 KiB. 400 and 404 share one body. There is no admin
  surface; operators use `bin/susan rpc` (`Susan.Operator`).
  """
  @behaviour Plug
  import Plug.Conn

  alias Susan.SourceAddress

  @max_body 1024
  @bodies %{
    rejected: ~s({"error":"rejected"}),
    unregistered: ~s({"error":"unregistered"}),
    rate_limited: ~s({"error":"rate_limited"}),
    unavailable: ~s({"error":"unavailable"})
  }

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security;privacy] susan-http-surface
  # Only the three documented routes exist. Bodies MUST be bounded to 1 KiB
  # before parsing, 400 and 404 MUST be byte-identical, and no response may
  # echo request data, internal reasons or source addresses.
  @impl true
  @spec call(Plug.Conn.t(), Susan.Config.t() | (-> Susan.Config.t())) :: Plug.Conn.t()
  def call(conn, config) when is_function(config, 0), do: call(conn, config.())

  def call(%{method: "GET", request_path: "/healthz", query_string: ""} = conn, _config) do
    healthy = Susan.Repo.answers?()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(healthy, do: 200, else: 503),
      if(healthy, do: ~s({"status":"ok"}), else: ~s({"status":"unavailable"}))
    )
  end

  def call(%{method: "POST", request_path: "/api/push/v1/poke", query_string: ""} = conn, config) do
    with_body(conn, fn conn, body ->
      input = %{
        body: body,
        install_key: header(conn, "overalls-install-key"),
        signature: header(conn, "overalls-install-signature"),
        source: source(conn, config),
        now: System.os_time(:second)
      }

      {:respond, status, body_tag, retry} = Susan.Poke.handle(input, config)
      respond(conn, status, body_tag, retry)
    end)
  end

  def call(%{method: "POST", request_path: "/api/push/v1/keys", query_string: ""} = conn, config) do
    with_body(conn, fn conn, body ->
      case Susan.Keys.issue(body, source(conn, config), config, System.os_time(:second)) do
        {201, response} ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(201, JSON.encode!(response))

        {status, tag, retry} ->
          respond(conn, status, tag, retry)
      end
    end)
  end

  def call(conn, _config), do: respond(conn, 404, :rejected, nil)

  defp with_body(conn, fun) do
    declared = header(conn, "content-length")
    type = header(conn, "content-type")

    with true <- json?(type),
         true <- declared == nil or bounded_length?(declared),
         {:ok, body, conn} <- read_body(conn, length: @max_body, read_length: @max_body) do
      fun.(conn, body)
    else
      _ -> respond(conn, 400, :rejected, nil)
    end
  rescue
    _ -> respond(conn, 503, :unavailable, 30)
  end

  defp respond(conn, 204, _tag, _retry), do: send_resp(conn, 204, "")

  defp respond(conn, status, tag, retry) do
    conn
    |> put_resp_content_type("application/json")
    |> then(fn conn ->
      if retry, do: put_resp_header(conn, "retry-after", Integer.to_string(retry)), else: conn
    end)
    |> send_resp(status, Map.fetch!(@bodies, tag))
  end

  defp source(conn, config) do
    conn.remote_ip
    |> SourceAddress.client(get_req_header(conn, "x-forwarded-for"), config.trusted_proxies)
    |> SourceAddress.digest()
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  defp json?(type) when is_binary(type),
    do:
      type |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
        "application/json"

  defp json?(_), do: false

  defp bounded_length?(value) do
    case Integer.parse(value) do
      {length, ""} -> length in 0..@max_body
      _ -> false
    end
  end
end
