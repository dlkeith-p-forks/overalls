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
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_git", "Repository registered.")) |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_git", "Could not register repository. Verify your passkey and labels.")
         )}
    end
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    case Catalog.refresh(socket.assigns.current_user, id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_git", "Refresh queued.")) |> refresh()}

      {:error, :already_refreshing} ->
        {:noreply,
         put_flash(socket, :info, dgettext("admin_git", "Refresh already in progress."))}

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_git", "Refresh could not be queued."))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Catalog.remove(socket.assigns.current_user, id) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_git", "Removal queued.")) |> refresh()}

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_git", "Repository could not be removed."))}
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
          title={dgettext("admin_git", "Git mirrors")}
          subtitle={
            dgettext(
              "admin_git",
              "Public GitHub repositories mirrored for machines. Mirrors refresh hourly; changes require recent passkey verification."
            )
          }
        />
        <.form :if={@admin_authorized} for={@form} phx-submit="register" class="panel stack">
          <h2>{dgettext("admin_git", "Add a mirror")}</h2>
          <div class="grid">
            <div class="field">
              <label>
                <span class="field-label">{dgettext("admin_git", "GitHub organization")}</span>
                <input name="git[owner]" placeholder={dgettext("admin_git", "nixos")} />
              </label>
            </div>
            <div class="field">
              <label>
                <span class="field-label">{dgettext("admin_git", "Repository")}</span>
                <input name="git[repo]" placeholder={dgettext("admin_git", "nixpkgs")} />
              </label>
            </div>
          </div>
          <div class="row actions">
            <button class="console-button primary">{dgettext("admin_git", "Add mirror")}</button>
          </div>
        </.form>
        <UI.panel id="git-mirrors" title={dgettext("admin_git", "Mirrors")}>
          <p :if={@repos == []} class="muted">
            {dgettext("admin_git", "No repositories are mirrored yet.")}
          </p>
          <div :if={@repos != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_git", "Repository")}</th>
                  <th class="width-min">{dgettext("admin_git", "Phase")}</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">{dgettext("admin_git", "Actions")}</span>
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
                      {dgettext("admin_git", "Refresh")}
                    </button>
                    <button
                      phx-click="remove"
                      phx-value-id={repo.id}
                      data-confirm={dgettext("admin_git", "Remove mirror?")}
                      class="console-button danger"
                    >{dgettext("admin_git", "Remove")}</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="git-audit" title={dgettext("admin_git", "Recent mirror audit")}>
          <p :if={@events == []} class="muted">
            {dgettext("admin_git", "No mirror events recorded.")}
          </p>
          <div :if={@events != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">{dgettext("admin_git", "When")}</th>
                  <th class="width-min">{dgettext("admin_git", "Action")}</th>
                  <th class="width-auto">{dgettext("admin_git", "Reason")}</th>
                  <th class="width-auto">{dgettext("admin_git", "Identifiers")}</th>
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
                    {dgettext("admin_git", "actor")}
                    <code>{event.actor_id || "system"}</code><br /> {dgettext(
                      "admin_git",
                      "repository"
                    )}
                    <code>{event.repository_id}</code><br /> {dgettext("admin_git", "attempt")}
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
  defp phase_label(:pending), do: dgettext("admin_git", "Pending")
  defp phase_label(:refreshing), do: dgettext("admin_git", "Refreshing")
  defp phase_label(:ready), do: dgettext("admin_git", "Ready")
  defp phase_label(:failed), do: dgettext("admin_git", "Failed")
  defp phase_label(:removing), do: dgettext("admin_git", "Removing")
  defp phase_label(_), do: dgettext("admin_git", "Unknown")

  # @cc [owner:ghuntley,label:product] localized-mirror-audit-labels
  # Audit action and refusal labels MUST be translated without changing stored
  # event kinds, failure reasons or identifiers.
  @spec action_label(atom()) :: String.t()
  defp action_label(:registered), do: dgettext("admin_git", "Registered")
  defp action_label(:refresh_requested), do: dgettext("admin_git", "Refresh requested")
  defp action_label(:refresh_succeeded), do: dgettext("admin_git", "Refresh succeeded")
  defp action_label(:refresh_failed), do: dgettext("admin_git", "Refresh failed")
  defp action_label(:remove_requested), do: dgettext("admin_git", "Removal requested")
  defp action_label(:removed), do: dgettext("admin_git", "Removed")
  defp action_label(_), do: dgettext("admin_git", "Unknown")

  @spec reason_label(atom() | nil) :: String.t()
  defp reason_label(nil), do: "—"
  defp reason_label(:tls_untrusted), do: dgettext("admin_git", "TLS verification failed")
  defp reason_label(:timeout), do: dgettext("admin_git", "Timed out")
  defp reason_label(:unauthorized), do: dgettext("admin_git", "Unauthorized")
  defp reason_label(:service_unavailable), do: dgettext("admin_git", "Service unavailable")
  defp reason_label(:git_failed), do: dgettext("admin_git", "Git operation failed")
  defp reason_label(:unknown), do: dgettext("admin_git", "Unknown")
  defp reason_label(_), do: dgettext("admin_git", "Unknown")
end
