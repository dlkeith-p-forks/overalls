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

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      fresh_login(socket, :mount)
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  # @cc [owner:ghuntley,label:security] required-login-hooks
  # on_mount(:live_user_required, ...) MUST validate the login token against the
  # assigned user before continuing and install fresh-login checks for events,
  # messages and parameter changes. Only the token identifier may be retained.
  def on_mount(mode, _params, session, socket) when mode in [:live_user_required, :security] do
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

      fresh_login(socket, :mount)
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
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
