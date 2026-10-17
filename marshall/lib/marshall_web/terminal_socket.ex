defmodule MarshallWeb.TerminalSocket do
  @moduledoc "Browser terminal viewer WebSocket endpoint authenticated by single-use tickets."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] viewer-socket-ticket-authority
  # The upgrade MUST require an authenticated browser session and a ticket
  # query parameter; the ticket alone carries terminal authority and MUST be
  # consumed by the viewer handler before any bytes flow.
  @impl true
  def call(%Plug.Conn{method: "GET", path_info: path} = conn, _options)
      when length(path) == 5 do
    with ticket when is_binary(ticket) and ticket != "" <- conn.query_params["ticket"],
         %{current_user: %{} = actor} <- conn.assigns,
         {:ok, login_jti, _expiry} <-
           Marshall.Accounts.Login.verify(get_session(conn, "user_token"), actor),
         {:ok, cursor} <-
           bounded_integer(conn.query_params["cursor"], 0, 9_223_372_036_854_775_807),
         {:ok, cols} <- bounded_integer(conn.query_params["cols"], 0, 4096),
         {:ok, rows} <- bounded_integer(conn.query_params["rows"], 0, 512),
         true <- cols == 0 == (rows == 0) do
      WebSockAdapter.upgrade(
        conn,
        Marshall.Terminal.Viewer,
        %{
          ticket: ticket,
          actor: actor,
          cursor: cursor,
          login_jti: login_jti,
          cols: cols,
          rows: rows
        },
        timeout: :infinity,
        max_frame_size: 65_550,
        compress: false
      )
      |> halt()
    else
      _ -> conn |> put_status(404) |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _), do: conn

  @spec bounded_integer(term(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :error
  defp bounded_integer(nil, default, _), do: {:ok, default}

  defp bounded_integer(value, _default, maximum)
       when is_binary(value) and byte_size(value) <= 20 do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= maximum -> {:ok, number}
      _ -> :error
    end
  end

  defp bounded_integer(_, _, _), do: :error
end
