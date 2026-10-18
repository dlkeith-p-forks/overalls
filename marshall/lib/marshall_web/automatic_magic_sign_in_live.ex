defmodule MarshallWeb.AutomaticMagicSignInLive do
  @moduledoc "Automatically submits a magic link through the normal browser sign-in route."
  use MarshallWeb, :live_view

  @type socket :: Phoenix.LiveView.Socket.t()

  # @cc [owner:ghuntley,label:security;product] automatic-magic-link-post
  # A browser visit MUST submit the link token through the CSRF-protected
  # authentication POST with remember_me enabled. Rendering the GET alone MUST
  # NOT consume the token or establish a login.
  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  @spec handle_params(map(), String.t(), socket()) :: {:noreply, socket()}
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :token, params["token"] || params["magic_link"])}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main class="auth-shell">
      <section class="auth-panel" aria-live="polite">
        <h1 class="ident">{gettext("Signing you in")}</h1>
        <p>{gettext("Your email link is being verified.")}</p>
        <form action={~p"/auth/user/magic_link"} method="post" phx-trigger-action={true}>
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="user[token]" value={@token} />
          <input type="hidden" name="user[remember_me]" value="true" />
          <button type="submit" class="console-button primary">{gettext("Continue to Overalls")}</button>
        </form>
      </section>
    </main>
    """
  end
end
