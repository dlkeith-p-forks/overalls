defmodule MarshallWeb.SettingsLive do
  use MarshallWeb, :live_view
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_, _, socket), do: {:ok, refresh(socket)}

  # @cc [owner:ghuntley,label:security] self-git-settings
  # Settings updates MUST use the authenticated account and only accepted Git
  # preference fields; submitted owner identifiers MUST NOT select an account.
  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("save", %{"settings" => params}, socket) when is_map(params) do
    actor = socket.assigns.current_user
    params = Map.take(params, ["git_username", "git_email", "commit_trailers_enabled"])

    case actor |> Ash.Changeset.for_update(:git_settings, params) |> Ash.update(actor: actor) do
      {:ok, _} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Git settings saved.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Enter a valid Git name and email address.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh(socket) do
    user = Marshall.Accounts.Security.current(socket.assigns.current_user.id)

    assign(socket,
      form:
        to_form(
          %{
            "git_username" => user.git_username,
            "git_email" => to_string(user.git_email),
            "commit_trailers_enabled" => user.commit_trailers_enabled
          },
          as: :settings
        )
    )
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      compute={true}
      active="settings"
    >
      <section id="git-settings" class="stack">
        <UI.heading title="Settings" subtitle="Configure your Git identity and commit attribution." />
        <.form for={@form} id="git-settings-form" phx-submit="save" class="panel">
          <.input field={@form[:git_username]} label="Git username" maxlength="128" required />
          <.input field={@form[:git_email]} type="email" label="Git email" maxlength="254" required />
          <.input
            field={@form[:commit_trailers_enabled]}
            type="checkbox"
            label="Add Overalls commit attribution"
          />
          <p>
            When enabled, new agent commits include Co-authored-by: Overalls &lt;noreply@overalls.dev&gt;.
          </p>
          <p>
            Git identity changes apply to new machines. Commit attribution changes apply to future agent requests.
          </p>
          <Layouts.action id="save-git-settings" type="submit" tone="primary">
            Save Git settings
          </Layouts.action>
        </.form>
        <p>
          <.link navigate={~p"/settings/security"}>Security</.link>
          · <.link navigate={~p"/settings/ssh-keys"}>SSH keys</.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
