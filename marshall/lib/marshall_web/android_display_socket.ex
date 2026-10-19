defmodule MarshallWeb.AndroidDisplaySocket do
  @moduledoc "Authenticated WebSocket entry point for Android display streams."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] android-display-socket-auth
  # Upgrade MUST verify the current browser login and signed machine-bound
  # display ticket before creating a relay process. Invalid requests terminate
  # without revealing whether a machine or ticket exists.
  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["android-display"]} = conn, _options) do
    with ticket when is_binary(ticket) and byte_size(ticket) <= 4096 <-
           conn.query_params["ticket"],
         %{current_user: %{id: actor_id} = actor} <- conn.assigns,
         {:ok, login_jti, _expiry} <-
           Marshall.Accounts.Login.verify(get_session(conn, "user_token"), actor),
         {:ok, claim} <- Marshall.Android.DisplayTickets.verify(ticket),
         true <- claim.actor_id == actor_id,
         {:ok, generation} <-
           bounded_integer(conn.query_params["generation"], 1, 9_223_372_036_854_775_807),
         {:ok, mode} <- mode(conn.query_params["mode"]),
         true <- claim.generation == generation,
         true <- claim.mode == mode,
         true <- claim.machine_id == conn.query_params["machine_id"],
         true <- Marshall.Android.DisplayTickets.current?(claim, actor) do
      WebSockAdapter.upgrade(
        conn,
        Marshall.Android.DisplaySocket,
        %{claim: claim, actor: actor, login_jti: login_jti, generation: generation, mode: mode},
        timeout: :infinity,
        max_frame_size: 262_144,
        compress: false
      )
      |> halt()
    else
      _ -> conn |> put_status(404) |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _options), do: conn

  defp mode("viewer"), do: {:ok, :viewer}
  defp mode("controller"), do: {:ok, :controller}
  defp mode(_), do: :error

  defp bounded_integer(value, minimum, maximum)
       when is_binary(value) and byte_size(value) <= 20 do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= maximum -> {:ok, number}
      _ -> :error
    end
  end

  defp bounded_integer(_, _, _), do: :error
end
