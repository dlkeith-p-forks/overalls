defmodule MarshallWeb.AuthenticationPrivacy do
  @moduledoc "Tag token-bearing HTTP and LiveView processes before request diagnostics."
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  # @cc [owner:ghuntley,label:security] token-path-process-tag
  # call/2 MUST tag authentication request processes before downstream logging;
  # every /api path is token-bearing and tagged, and adding another
  # token-bearing route requires including its prefix in this boundary.
  @impl true
  def call(%{path_info: [prefix | _]} = conn, _)
      when prefix in [
             "magic_link",
             "auth",
             "sign-in",
             "register",
             "reset",
             "confirm_new_user",
             "launch"
           ] do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  # The account page at /settings carries passkey ceremonies and pasted SSH
  # key material in one LiveView, so the whole settings tree is tagged.
  def call(%{path_info: ["settings" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(%{path_info: ["ssh", "approve" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(%{path_info: ["agents", "cli", "approve" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(%{path_info: ["audi", "authorize" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(%{path_info: ["editor", "authorize" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(%{path_info: ["api", _service | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn
  end

  def call(conn, _), do: conn

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    Logger.metadata(marshall_authentication: true)
    {:cont, Marshall.Localization.assign_socket(socket, session)}
  end
end
