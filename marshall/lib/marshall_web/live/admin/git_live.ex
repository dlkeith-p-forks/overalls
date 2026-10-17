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
        {:noreply, socket |> put_flash(:info, "Repository registered.") |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not register repository. Verify your passkey and labels."
         )}
    end
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    case Catalog.refresh(socket.assigns.current_user, id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Refresh queued.") |> refresh()}

      {:error, :already_refreshing} ->
        {:noreply, put_flash(socket, :info, "Refresh already in progress.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Refresh could not be queued.")}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Catalog.remove(socket.assigns.current_user, id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Removal queued.") |> refresh()}
      _ -> {:noreply, put_flash(socket, :error, "Repository could not be removed.")}
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
      compute={true}
      active="admin"
      admin_active="git"
    >
      <section id="admin-git" class="stack">
        <UI.heading
          title="Git mirrors"
          subtitle="Public GitHub repositories mirrored for machines. Mirrors refresh hourly; changes require recent passkey verification."
        />
        <.form :if={@admin_authorized} for={@form} phx-submit="register" class="panel stack">
          <h2>Add a mirror</h2>
          <div class="grid">
            <div class="field">
              <label>
                <span class="field-label">GitHub organization</span>
                <input name="git[owner]" placeholder="nixos" />
              </label>
            </div>
            <div class="field">
              <label>
                <span class="field-label">Repository</span>
                <input name="git[repo]" placeholder="nixpkgs" />
              </label>
            </div>
          </div>
          <div class="row actions">
            <button class="console-button primary">Add mirror</button>
          </div>
        </.form>
        <UI.panel id="git-mirrors" title="Mirrors">
          <p :if={@repos == []} class="muted">No repositories are mirrored yet.</p>
          <div :if={@repos != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">Repository</th>
                  <th class="width-min">Phase</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">Actions</span>
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
                  <td><span class="status-label">{repo.phase}</span></td>
                  <td :if={@admin_authorized} class="nowrap">
                    <button phx-click="refresh" phx-value-id={repo.id} class="console-button">
                      Refresh
                    </button>
                    <button
                      phx-click="remove"
                      phx-value-id={repo.id}
                      data-confirm="Remove mirror?"
                      class="console-button danger"
                    >Remove</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="git-audit" title="Recent mirror audit">
          <p :if={@events == []} class="muted">No mirror events recorded.</p>
          <div :if={@events != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">When</th>
                  <th class="width-min">Action</th>
                  <th class="width-auto">Reason</th>
                  <th class="width-auto">Identifiers</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @events}>
                  <td class="nowrap">{Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M UTC")}</td>
                  <td>{event.kind}</td>
                  <td class="break">{event.failure_reason || "—"}</td>
                  <td class="break muted">
                    actor <code>{event.actor_id || "system"}</code><br /> repository
                    <code>{event.repository_id}</code><br /> attempt
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
end
