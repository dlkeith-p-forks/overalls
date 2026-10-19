defmodule MarshallWeb.Admin.ScimLive do
  use MarshallWeb, :live_view

  alias Marshall.Scim.Configuration
  alias Marshall.Authorization.SystemActor

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket), do: {:ok, refresh(socket)}

  @impl true
  def handle_event("configure", %{"enabled" => enabled, "rotate_token" => rotate}, socket) do
    params = %{enabled: enabled == "true", rotate_token: rotate == "true"}

    result =
      Configuration
      |> Ash.ActionInput.for_action(:configure, params, actor: socket.assigns.current_user)
      |> Ash.run_action()

    case result do
      {:ok, %{token: token}} ->
        socket = refresh(socket)
        socket = if is_binary(token), do: assign(socket, generated_token: token), else: socket

        {:noreply,
         put_flash(socket, :info, dgettext("admin_access", "SCIM configuration updated."))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_access", "SCIM configuration could not be updated.")
         )}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("admin_access", "Invalid request."))}

  defp refresh(socket) do
    config =
      Configuration
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read_one(actor: SystemActor.compute())

    assign(socket, configuration: config, generated_token: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="admin"
      admin_active="scim"
    >
      <section id="admin-scim" class="stack">
        <UI.heading
          title={dgettext("admin_access", "SCIM provisioning")}
          subtitle={
            dgettext(
              "admin_access",
              "Configure directory provisioning, identity lifecycle and managed teams."
            )
          }
        />
        <UI.panel id="scim-configuration" title={dgettext("admin_access", "SCIM configuration")}>
          <p class="muted">
            {if @configuration && @configuration.state == :enabled,
              do: dgettext("admin_access", "SCIM is enabled."),
              else: dgettext("admin_access", "SCIM is disabled.")}
          </p>
          <.form for={to_form(%{})} id="scim-config-form" phx-submit="configure" class="stack">
            <input
              type="hidden"
              name="enabled"
              value={
                if(@configuration && @configuration.state == :enabled, do: "false", else: "true")
              }
            />
            <input type="hidden" name="rotate_token" value="true" />
            <button class="console-button primary" type="submit">
              {if @configuration && @configuration.state == :enabled,
                do: dgettext("admin_access", "Disable SCIM"),
                else: dgettext("admin_access", "Enable SCIM and generate token")}
            </button>
          </.form>
          <div :if={@generated_token} id="scim-generated-token" class="panel inverse">
            <p>
              {dgettext("admin_access", "Copy this bearer token now. It will not be shown again.")}
            </p>
            <code>{@generated_token}</code>
          </div>
        </UI.panel>
      </section>
    </Layouts.app>
    """
  end
end
