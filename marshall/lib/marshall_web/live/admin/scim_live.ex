defmodule MarshallWeb.Admin.ScimLive do
  @moduledoc """
  Control room SCIM administration: enable, disable, bearer-token rotation and
  OIDC single sign-on settings, plus retirement status counts.

  Every mutation submits the administrator-gated `configure` event with one
  explicit `operation`, so saving OIDC settings never rotates the bearer token.
  A generated token is held only in this socket until the next refresh and is
  never rendered again. The stored client secret is never sent to the browser.
  """
  use MarshallWeb, :live_view

  require Ash.Query
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Scim.{Configuration, Oidc}
  alias Marshall.Teams.Team

  @type socket :: Phoenix.LiveView.Socket.t()
  @operations %{
    "enable" => :enable,
    "disable" => :disable,
    "rotate_token" => :rotate_token,
    "save_oidc" => :save_oidc
  }

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_, _, socket), do: {:ok, socket |> assign(generated_token: nil) |> refresh()}

  # @cc [owner:ghuntley,label:security] scim-admin-single-operation
  # Each submission MUST perform exactly the named operation. Only enable and
  # rotate may display a token, once; OIDC saves MUST NOT rotate the token and a
  # blank secret MUST keep the stored secret unless clearing is requested.
  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("scim-configure", %{"operation" => operation} = raw, socket)
      when is_map_key(@operations, operation) do
    operation = Map.fetch!(@operations, operation)
    oidc = oidc_params(raw)

    if operation == :save_oidc and not issuer_valid?(oidc["oidc_issuer"]) do
      {:noreply,
       assign(socket,
         generated_token: nil,
         oidc_form: oidc_form(socket.assigns.configuration, oidc, invalid_issuer: true)
       )}
    else
      configure(socket, operation, oidc)
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("admin_access", "Invalid request."))}

  @spec configure(socket(), atom(), map()) :: {:noreply, socket()}
  defp configure(socket, operation, oidc) do
    params = %{
      operation: operation,
      oidc_issuer: oidc["oidc_issuer"],
      oidc_client_id: oidc["oidc_client_id"],
      oidc_client_secret: oidc["oidc_client_secret"],
      clear_oidc_client_secret: oidc["clear_oidc_client_secret"] == "true"
    }

    result =
      Configuration
      |> Ash.ActionInput.for_action(:configure, params, actor: socket.assigns.current_user)
      |> Ash.run_action()

    case result do
      {:ok, %{token: token}} ->
        socket = socket |> assign(generated_token: token) |> refresh()
        {:noreply, put_flash(socket, :info, success_message(operation))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(generated_token: nil)
         |> refresh()
         |> put_flash(
           :error,
           dgettext("admin_access", "SCIM configuration could not be updated.")
         )}
    end
  end

  @spec success_message(atom()) :: String.t()
  defp success_message(:enable), do: dgettext("admin_access", "SCIM provisioning enabled.")
  defp success_message(:disable), do: dgettext("admin_access", "SCIM provisioning disabled.")
  defp success_message(:rotate_token), do: dgettext("admin_access", "SCIM bearer token rotated.")
  defp success_message(:save_oidc), do: dgettext("admin_access", "Single sign-on settings saved.")

  @spec oidc_params(map()) :: %{optional(String.t()) => String.t()}
  defp oidc_params(%{"oidc" => %{} = oidc}) do
    for key <- ~w(oidc_issuer oidc_client_id oidc_client_secret clear_oidc_client_secret),
        is_binary(oidc[key]),
        into: %{},
        do: {key, oidc[key]}
  end

  defp oidc_params(_), do: %{}

  @spec issuer_valid?(term()) :: boolean()
  defp issuer_valid?(issuer) when is_binary(issuer),
    do: String.trim(issuer) == "" or Oidc.valid_issuer?(String.trim(issuer))

  defp issuer_valid?(_), do: true

  @spec refresh(socket()) :: socket()
  defp refresh(socket) do
    config =
      case Configuration
           |> Ash.Query.filter(key == "installation")
           |> Ash.Query.sort(inserted_at: :asc)
           |> Ash.read_one(actor: SystemActor.compute()) do
        {:ok, config} -> config
        _ -> nil
      end

    assign(socket,
      configuration: config,
      enabled: match?(%Configuration{state: :enabled}, config),
      secret_set: match?(%Configuration{oidc_client_secret: s} when is_binary(s), config),
      oidc_form: oidc_form(config, nil, []),
      retiring_users: count_retiring_users(),
      retiring_teams: count_retiring_teams()
    )
  end

  @spec oidc_form(Configuration.t() | nil, map() | nil, keyword()) :: Phoenix.HTML.Form.t()
  defp oidc_form(config, submitted, opts) do
    params =
      case submitted do
        nil ->
          %{
            "oidc_issuer" => (config && config.oidc_issuer) || "",
            "oidc_client_id" => (config && config.oidc_client_id) || ""
          }

        submitted ->
          Map.take(submitted, ["oidc_issuer", "oidc_client_id"])
      end

    errors =
      if opts[:invalid_issuer],
        do: [
          oidc_issuer: {dgettext("admin_access", "Enter an absolute https:// issuer URL."), []}
        ],
        else: []

    to_form(params, as: :oidc, id: "scim-oidc", errors: errors)
  end

  @spec count_retiring_users() :: non_neg_integer() | nil
  defp count_retiring_users do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(not is_nil(scim_retirement_deadline))
    |> Ash.Query.select([:id])
    |> Ash.read(actor: SystemActor.compute())
    |> case do
      {:ok, users} -> length(users)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec count_retiring_teams() :: non_neg_integer() | nil
  defp count_retiring_teams do
    Team
    |> Ash.Query.filter(management_mode == :retiring)
    |> Ash.Query.select([:id])
    |> Ash.read(actor: SystemActor.compute())
    |> case do
      {:ok, teams} -> length(teams)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec count_label(non_neg_integer() | nil) :: String.t()
  defp count_label(nil), do: dgettext("admin_access", "unavailable")
  defp count_label(count), do: Integer.to_string(count)

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
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
        <UI.panel id="scim-status" title={dgettext("admin_access", "Status")}>
          <.kv id="scim-status-values">
            <:item title={dgettext("admin_access", "Provisioning")}>
              <span
                id="scim-state"
                class="status-label"
                data-state={if @enabled, do: "enabled", else: "disabled"}
              >
                {if @enabled,
                  do: dgettext("admin_access", "[enabled]"),
                  else: dgettext("admin_access", "[disabled]")}
              </span>
            </:item>
            <:item title={dgettext("admin_access", "Accounts pending retirement")}>
              <span id="scim-retiring-users">{count_label(@retiring_users)}</span>
            </:item>
            <:item title={dgettext("admin_access", "Teams retiring")}>
              <span id="scim-retiring-teams">{count_label(@retiring_teams)}</span>
            </:item>
            <:item title={dgettext("admin_access", "Single sign-on")}>
              <span id="scim-oidc-state">
                {if @configuration && is_binary(@configuration.oidc_issuer) && @secret_set,
                  do: dgettext("admin_access", "[configured]"),
                  else: dgettext("admin_access", "[not configured]")}
              </span>
            </:item>
          </.kv>
        </UI.panel>

        <UI.panel id="scim-configuration" title={dgettext("admin_access", "Provisioning")}>
          <div :if={not @enabled} class="stack">
            <p class="muted">
              {dgettext(
                "admin_access",
                "Enabling SCIM disables magic-link sign-in, archives native teams after a seven-day grace period and generates a bearer token."
              )}
            </p>
            <.form for={%{}} as={:scim} id="scim-enable-form" phx-submit="scim-configure">
              <input type="hidden" name="operation" value="enable" />
              <Layouts.action tone="primary" type="submit" id="scim-enable">
                {dgettext("admin_access", "Enable SCIM and generate token")}
              </Layouts.action>
            </.form>
          </div>
          <div :if={@enabled} class="stack">
            <p class="muted">
              {dgettext(
                "admin_access",
                "Rotating the bearer token immediately invalidates the previous token."
              )}
            </p>
            <div class="row">
              <.form for={%{}} as={:scim} id="scim-rotate-form" phx-submit="scim-configure">
                <input type="hidden" name="operation" value="rotate_token" />
                <Layouts.action
                  type="submit"
                  id="scim-rotate"
                  data-confirm={
                    dgettext(
                      "admin_access",
                      "Rotate the SCIM bearer token? The directory must be updated with the new token."
                    )
                  }
                >
                  {dgettext("admin_access", "Rotate bearer token")}
                </Layouts.action>
              </.form>
              <.form for={%{}} as={:scim} id="scim-disable-form" phx-submit="scim-configure">
                <input type="hidden" name="operation" value="disable" />
                <Layouts.action
                  tone="danger"
                  type="submit"
                  id="scim-disable"
                  data-confirm={
                    dgettext(
                      "admin_access",
                      "Disable SCIM provisioning? Managed teams stay locked until an administrator hands them off."
                    )
                  }
                >
                  {dgettext("admin_access", "Disable SCIM")}
                </Layouts.action>
              </.form>
            </div>
          </div>
          <div :if={@generated_token} id="scim-generated-token" class="panel inverse">
            <p>
              {dgettext("admin_access", "Copy this bearer token now. It will not be shown again.")}
            </p>
            <code>{@generated_token}</code>
          </div>
        </UI.panel>

        <UI.panel id="scim-oidc" title={dgettext("admin_access", "Single sign-on (OIDC)")}>
          <.form for={@oidc_form} id="scim-oidc-form" phx-submit="scim-configure" class="stack">
            <input type="hidden" name="operation" value="save_oidc" />
            <.input
              field={@oidc_form[:oidc_issuer]}
              type="url"
              label={dgettext("admin_access", "OIDC issuer")}
              hint={
                dgettext("admin_access", "The exact https:// issuer URL from provider discovery.")
              }
              autocomplete="off"
            />
            <.input
              field={@oidc_form[:oidc_client_id]}
              label={dgettext("admin_access", "OIDC client ID")}
              autocomplete="off"
            />
            <.input
              field={@oidc_form[:oidc_client_secret]}
              type="password"
              value=""
              label={dgettext("admin_access", "OIDC client secret")}
              hint={
                if @secret_set,
                  do:
                    dgettext(
                      "admin_access",
                      "A client secret is set. Leave blank to keep it."
                    ),
                  else: dgettext("admin_access", "No client secret is set.")
              }
              autocomplete="new-password"
            />
            <.input
              :if={@secret_set}
              field={@oidc_form[:clear_oidc_client_secret]}
              type="checkbox"
              value="false"
              label={dgettext("admin_access", "Clear the stored client secret")}
            />
            <div class="row">
              <Layouts.action tone="primary" type="submit" id="scim-oidc-save">
                {dgettext("admin_access", "Save single sign-on settings")}
              </Layouts.action>
            </div>
          </.form>
        </UI.panel>
      </section>
    </Layouts.app>
    """
  end
end
