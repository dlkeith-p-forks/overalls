defmodule MarshallWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  alias Marshall.Accounts.Login
  use MarshallWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {MarshallWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    socket = Marshall.Localization.assign_socket(socket, session)

    if socket.assigns[:current_user] do
      socket |> assign_time_zone() |> fresh_login(:mount)
    else
      {:cont, socket |> assign(:current_user, nil) |> assign_time_zone()}
    end
  end

  # @cc [owner:ghuntley,label:security] required-login-hooks
  # on_mount(:live_user_required, ...) MUST validate the login token against the
  # assigned user before continuing and install fresh-login checks for events,
  # messages (including clock ticks) and parameter changes. Only the token
  # identifier may be retained.
  def on_mount(mode, _params, session, socket) when mode in [:live_user_required, :security] do
    socket = Marshall.Localization.assign_socket(socket, session)

    if socket.view == MarshallWeb.TerminalLive and Phoenix.LiveView.connected?(socket),
      do: Logger.metadata(marshall_terminal: true)

    with %Marshall.Accounts.User{} = user <- socket.assigns[:current_user],
         {:ok, jti, _} <- Login.verify(session["user_token"], user) do
      socket =
        socket
        |> assign(:current_user, Marshall.Accounts.Security.bind(user, jti))
        |> Phoenix.LiveView.put_private(:login_jti, jti)
        |> Phoenix.LiveView.attach_hook(:fresh_login, :handle_event, fn _, _, socket ->
          fresh_login(socket, :drop)
        end)
        |> Phoenix.LiveView.attach_hook(:fresh_login, :handle_info, fn message, socket ->
          fresh_login(socket, {:redeliver, message})
        end)
        |> Phoenix.LiveView.attach_hook(:fresh_login, :handle_params, fn _, _, socket ->
          fresh_login(socket, :drop)
        end)
        |> assign_time_zone()

      fresh_login(socket, :mount)
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket = Marshall.Localization.assign_socket(socket, session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  @tick {__MODULE__, :clock_tick}
  @tick_ms 60_000

  # @cc [owner:ghuntley,label:product] viewer-time-zone-resolution
  # The viewer zone MUST resolve as the saved user zone, then a valid browser
  # zone from the connect params, then UTC, with :time_zone_source naming
  # which applied. The dead render MUST use only the saved zone or UTC. A
  # browser zone MUST be validated before use and MUST never be persisted here.
  @doc """
  Assigns `:time_zone`, `:time_zone_source` and `:now` for the viewer and, on
  a connected socket, refreshes `:now` every minute so local clocks and
  differences stay current.
  """
  @spec assign_time_zone(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_time_zone(socket) do
    socket = remember_browser_zone(socket)
    {zone, source} = resolve_zone(socket)

    socket
    |> assign(:time_zone, zone)
    |> assign(:time_zone_source, source)
    |> assign(:now, DateTime.utc_now())
    |> schedule_tick()
  end

  @spec resolve_zone(Phoenix.LiveView.Socket.t()) ::
          {Marshall.Accounts.TimeZones.iana(), Marshall.Accounts.TimeZones.source()}
  defp resolve_zone(socket) do
    saved =
      case socket.assigns[:current_user] do
        %Marshall.Accounts.User{time_zone: zone} when is_binary(zone) -> zone
        _ -> nil
      end

    browser = socket.private[:browser_time_zone]

    cond do
      Marshall.Accounts.TimeZones.valid?(saved) -> {saved, :saved}
      Marshall.Accounts.TimeZones.valid?(browser) -> {browser, :browser}
      true -> {Marshall.Accounts.TimeZones.utc(), :utc}
    end
  end

  # Connect params exist only during mount, so the browser zone is read once
  # on a connected mount and kept in the socket's private state for later
  # re-resolution (for example after the profile page saves or clears a zone).
  @spec remember_browser_zone(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp remember_browser_zone(socket) do
    cond do
      Map.has_key?(socket.private, :browser_time_zone) ->
        socket

      Phoenix.LiveView.connected?(socket) ->
        zone = (Phoenix.LiveView.get_connect_params(socket) || %{})["timezone"]
        Phoenix.LiveView.put_private(socket, :browser_time_zone, zone)

      true ->
        socket
    end
  end

  # Required/security mounts attach fresh_login before this hook, so clock ticks
  # retain the same persisted-login check as other refreshes. Optional mounts
  # retain their existing behavior without required-login hooks.
  @spec schedule_tick(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp schedule_tick(socket) do
    if Phoenix.LiveView.connected?(socket) and
         not Map.has_key?(socket.private, :time_zone_tick) do
      Process.send_after(self(), @tick, @tick_ms)

      socket
      |> Phoenix.LiveView.put_private(:time_zone_tick, true)
      |> Phoenix.LiveView.attach_hook(:time_zone_tick, :handle_info, fn
        @tick, socket ->
          Process.send_after(self(), @tick, @tick_ms)
          {:halt, assign(socket, :now, DateTime.utc_now())}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] revoked-login-halts-operation
  # fresh_login/2 MUST check persisted identifier/user authority on each call;
  # a missing or expired login MUST halt the current operation and redirect.
  # Only when the database does not answer is the check inconclusive
  # (ADR-0140): the operation is halted without redirecting (events dropped,
  # messages redelivered after a second) and a mount crashes instead, so a
  # blocked database never signs the user out or leaves the page.
  @spec fresh_login(Phoenix.LiveView.Socket.t(), :mount | :drop | {:redeliver, term()}) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  defp fresh_login(socket, on_inconclusive) do
    case login_verdict(socket) do
      {:cont, _socket} = accepted ->
        accepted

      :inconclusive ->
        inconclusive(socket, on_inconclusive)

      {:halt, _socket} = refused ->
        if Marshall.Repo.answers?(), do: refused, else: inconclusive(socket, on_inconclusive)
    end
  rescue
    error ->
      if Marshall.Repo.answers?(),
        do: reraise(error, __STACKTRACE__),
        else: inconclusive(socket, on_inconclusive)
  end

  defp inconclusive(_socket, :mount),
    do: raise(DBConnection.ConnectionError, "database unavailable")

  defp inconclusive(socket, :drop), do: {:halt, socket}

  defp inconclusive(socket, {:redeliver, message}) do
    Process.send_after(self(), message, 1_000)
    {:halt, socket}
  end

  defp login_verdict(socket) do
    case Login.token_check(socket.private.login_jti, socket.assigns.current_user.id) do
      :unavailable ->
        :inconclusive

      {:ok, _} ->
        user = Marshall.Accounts.Security.current(socket.assigns.current_user.id)

        if is_nil(user) or not is_nil(user.deleted_at),
          do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")},
          else: {:cont, socket}

      :refused ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end
end
