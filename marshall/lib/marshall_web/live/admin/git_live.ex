defmodule MarshallWeb.Admin.GitLive do
  use MarshallWeb, :live_view
  alias Marshall.Enrico.Catalog
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket),
    do: {:ok, refresh(assign(socket, form: to_form(%{"owner" => "", "repo" => ""}, as: :git)))}

  @impl true
  def handle_event("register", %{"git" => %{"owner" => owner, "repo" => repo}}, socket) do
    case Catalog.register(socket.assigns.current_user, owner, repo) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Repository registered.")) |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not register repository. Verify your passkey and labels.")
         )}
    end
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    case Catalog.refresh(socket.assigns.current_user, id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Refresh queued.")) |> refresh()}

      {:error, :already_refreshing} ->
        {:noreply, put_flash(socket, :info, gettext("Refresh already in progress."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Refresh could not be queued."))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Catalog.remove(socket.assigns.current_user, id) do
      :ok -> {:noreply, socket |> put_flash(:info, gettext("Removal queued.")) |> refresh()}
      _ -> {:noreply, put_flash(socket, :error, gettext("Repository could not be removed."))}
    end
  end

  defp refresh(socket),
    do:
      assign(socket,
        repos: Catalog.list(socket.assigns.current_user),
        events: Catalog.audit(socket.assigns.current_user)
      )

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
      admin_active="git"
    >
      <section id="admin-git" class="stack">
        <UI.heading
          title={gettext("Git mirrors")}
          subtitle={
            gettext(
              "Public GitHub repositories mirrored for machines. Mirrors refresh hourly; changes require recent passkey verification."
            )
          }
        />
        <.form :if={@admin_authorized} for={@form} phx-submit="register" class="panel stack">
          <h2>{gettext("Add a mirror")}</h2>
          <div class="grid">
            <div class="field">
              <label>
                <span class="field-label">{gettext("GitHub organization")}</span>
                <input name="git[owner]" placeholder={gettext("nixos")} />
              </label>
            </div>
            <div class="field">
              <label>
                <span class="field-label">{gettext("Repository")}</span>
                <input name="git[repo]" placeholder={gettext("nixpkgs")} />
              </label>
            </div>
          </div>
          <div class="row actions">
            <button class="console-button primary">{gettext("Add mirror")}</button>
          </div>
        </.form>
        <UI.panel id="git-mirrors" title={gettext("Mirrors")}>
          <p :if={@repos == []} class="muted">{gettext("No repositories are mirrored yet.")}</p>
          <div :if={@repos != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{gettext("Repository")}</th>
                  <th class="width-min">{gettext("Phase")}</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">{gettext("Actions")}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={repo <- @repos}>
                  <td class="break">
                    <.link navigate={"/git/github/#{repo.owner}/#{repo.name}"}>
                      <code>github/{repo.owner}/{repo.name}</code>
                    </.link>
                  </td>
                  <td><span class="status-label">{phase_label(repo.phase)}</span></td>
                  <td :if={@admin_authorized} class="nowrap">
                    <button phx-click="refresh" phx-value-id={repo.id} class="console-button">
                      {gettext("Refresh")}
                    </button>
                    <button
                      phx-click="remove"
                      phx-value-id={repo.id}
                      data-confirm={gettext("Remove mirror?")}
                      class="console-button danger"
                    >{gettext("Remove")}</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="git-audit" title={gettext("Recent mirror audit")}>
          <p :if={@events == []} class="muted">{gettext("No mirror events recorded.")}</p>
          <div :if={@events != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">{gettext("When")}</th>
                  <th class="width-min">{gettext("Action")}</th>
                  <th class="width-auto">{gettext("Reason")}</th>
                  <th class="width-auto">{gettext("Identifiers")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @events}>
                  <td class="nowrap">
                    <.timestamp at={event.inserted_at} zone={@time_zone} format={:datetime} />
                  </td>
                  <td>{action_label(event.kind)}</td>
                  <td class="break">{reason_label(event.failure_reason)}</td>
                  <td class="break muted">
                    {gettext("actor")}
                    <code>{event.actor_id || "system"}</code><br /> {gettext("repository")}
                    <code>{event.repository_id}</code><br /> {gettext("attempt")}
                    <code>{event.attempt_id || "—"}</code>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
      </section>
    </Layouts.app>
    """
  end

  # @cc [owner:ghuntley,label:product] localized-repository-phase-labels
  # Repository phase labels MUST be translated without modifying domain phases.
  @spec phase_label(atom()) :: String.t()
  defp phase_label(:pending), do: gettext("Pending")
  defp phase_label(:refreshing), do: gettext("Refreshing")
  defp phase_label(:ready), do: gettext("Ready")
  defp phase_label(:failed), do: gettext("Failed")
  defp phase_label(:removing), do: gettext("Removing")
  defp phase_label(_), do: gettext("Unknown")

  # @cc [owner:ghuntley,label:product] localized-mirror-audit-labels
  # Audit action and refusal labels MUST be translated without changing stored
  # event kinds, failure reasons or identifiers.
  @spec action_label(atom()) :: String.t()
  defp action_label(:registered), do: gettext("Registered")
  defp action_label(:refresh_requested), do: gettext("Refresh requested")
  defp action_label(:refresh_succeeded), do: gettext("Refresh succeeded")
  defp action_label(:refresh_failed), do: gettext("Refresh failed")
  defp action_label(:remove_requested), do: gettext("Removal requested")
  defp action_label(:removed), do: gettext("Removed")
  defp action_label(_), do: gettext("Unknown")

  @spec reason_label(atom() | nil) :: String.t()
  defp reason_label(nil), do: "—"
  defp reason_label(:tls_untrusted), do: gettext("TLS verification failed")
  defp reason_label(:timeout), do: gettext("Timed out")
  defp reason_label(:unauthorized), do: gettext("Unauthorized")
  defp reason_label(:service_unavailable), do: gettext("Service unavailable")
  defp reason_label(:git_failed), do: gettext("Git operation failed")
  defp reason_label(:unknown), do: gettext("Unknown")
  defp reason_label(_), do: gettext("Unknown")
end
