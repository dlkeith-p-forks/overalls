defmodule MarshallWeb.ScimSignInLive do
  @moduledoc """
  The `/sign-in` page. Without SCIM it renders AshAuthentication's sign-in
  LiveView unchanged. While SCIM is enabled the magic-link request form is not
  rendered; the page offers OIDC single sign-on when it is configured, and
  otherwise explains that sign-in is unavailable. The server-side magic-link
  fence (`Marshall.Accounts.ScimMagicLinkDisabled`) still refuses requests.
  """
  use MarshallWeb, :live_view

  alias AshAuthentication.Phoenix.SignInLive

  @type socket :: Phoenix.LiveView.Socket.t()

  # Sign-in components deliver their flash messages to the parent LiveView.
  on_mount AshAuthentication.Phoenix.Utils.Flash

  # @cc [owner:ghuntley,label:security;product] scim-sign-in-page
  # While SCIM is enabled the page MUST NOT render the magic-link request form
  # and MUST offer only /auth/oidc/start when OIDC is configured. With SCIM
  # disabled it MUST render the ordinary sign-in page unchanged.
  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket(), keyword()}
  def mount(params, session, socket) do
    {:ok, socket} = SignInLive.mount(params, session, socket)
    scim? = Marshall.Scim.enabled?()

    socket =
      assign(socket,
        scim_enabled: scim?,
        oidc_available: scim? and Marshall.Scim.Oidc.available?()
      )

    # The library layout renders the flash; keep it so the page is unchanged.
    {:ok, socket, layout: {AshAuthentication.Phoenix.LayoutView, :live}}
  end

  @impl true
  @spec handle_params(map(), String.t(), socket()) :: {:noreply, socket()}
  def handle_params(params, uri, socket), do: SignInLive.handle_params(params, uri, socket)

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{scim_enabled: false} = assigns), do: SignInLive.render(assigns)

  def render(assigns) do
    ~H"""
    <div class="auth-shell">
      <section id="scim-sign-in" class="auth-panel stack">
        <h2 class="ident">{dgettext("auth", "Sign in")}</h2>
        <%= if @oidc_available do %>
          <p class="muted">
            {dgettext("auth", "Your organization manages Overalls accounts through its directory.")}
          </p>
          <a id="scim-sso-sign-in" class="console-button primary" href={~p"/auth/oidc/start"}>
            {dgettext("auth", "Sign in with single sign-on")}
          </a>
        <% else %>
          <p id="scim-sso-unavailable">
            {dgettext(
              "auth",
              "Email sign-in is disabled because your organization manages accounts through its directory, and single sign-on is not configured yet. Contact your administrator."
            )}
          </p>
        <% end %>
      </section>
    </div>
    """
  end
end
