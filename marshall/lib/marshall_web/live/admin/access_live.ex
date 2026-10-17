defmodule MarshallWeb.Admin.AccessLive do
  use MarshallWeb, :live_view

  alias Marshall.SSH

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 15_000)
    {:ok, socket |> assign(keys: [], sessions: [], grants: [], refreshed_at: nil) |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 15_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("revoke-key", %{"id" => id}, socket) do
    case SSH.revoke_key_for_admin(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "SSH key revoked.") |> refresh()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not revoke that key.")}
    end
  end

  def handle_event("revoke-session", %{"id" => id}, socket) do
    case SSH.revoke_session_for_admin(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "SSH session closed.") |> refresh()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not close that session.")}
    end
  end

  def handle_event("revoke-grant", %{"id" => id}, socket) do
    case Marshall.Access.revoke_grant_for_admin(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "VM access revoked.") |> refresh()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not revoke that VM access.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp refresh(socket) do
    with {:ok, keys} <- SSH.list_keys_for_admin(%{}, actor: socket.assigns.current_user),
         {:ok, sessions} <- SSH.list_sessions_for_admin(%{}, actor: socket.assigns.current_user),
         {:ok, grants} <-
           Marshall.Access.list_grants_for_admin(%{}, actor: socket.assigns.current_user) do
      assign(socket,
        keys: keys,
        sessions: sessions,
        grants: grants,
        refreshed_at: DateTime.utc_now()
      )
    else
      _ -> put_flash(socket, :error, "Access inventory is temporarily unavailable.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      compute={true}
      active="admin"
      admin_active="access"
    >
      <section id="admin-access" class="stack">
        <UI.heading
          title="Access authority"
          subtitle="Who can reach which machine, and by which key or session. Private keys, session tokens and gateway credentials are never shown."
        >
          <:actions><span class="muted">Updated every 15 seconds</span></:actions>
        </UI.heading>
        <.kv id="access-summary">
          <:item title="Shared machine grants">{length(@grants)}</:item>
          <:item title="Registered SSH keys">{length(@keys)}</:item>
          <:item title="Active SSH sessions">{length(@sessions)}</:item>
        </.kv>
        <UI.panel id="admin-grants" title="Shared machine access">
          <p :if={@grants == []} class="muted">No machine is shared with another account.</p>
          <div :if={@grants != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">Machine</th>
                  <th class="width-auto">Account</th>
                  <th class="width-min">Role</th>
                  <th class="width-min">Granted</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={grant <- @grants} id={"admin-grant-#{grant.id}"}>
                  <td class="break">{grant.vm_name}</td>
                  <td class="break">{grant.email}</td>
                  <td><span class="status-label">{grant.role}</span></td>
                  <td class="muted nowrap">{Calendar.strftime(grant.inserted_at, "%Y-%m-%d")}</td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-grant-#{grant.id}"}
                      phx-click="revoke-grant"
                      phx-value-id={grant.id}
                      data-confirm="Revoke this user's VM access?"
                    >
                      Revoke access
                    </Layouts.action>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="admin-keys" title="Registered SSH keys">
          <p :if={@keys == []} class="muted">No active keys.</p>
          <div :if={@keys != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">Account</th>
                  <th class="width-auto">Key</th>
                  <th class="width-min">Added</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={key <- @keys} id={"admin-key-#{key.id}"}>
                  <td class="break">{key.email}</td>
                  <td class="break">
                    {if key.label == "", do: "SSH key", else: key.label}<br />
                    <code>{key.fingerprint}</code><br />
                    <span class="muted">{key.algorithm}</span>
                  </td>
                  <td class="muted nowrap">{Calendar.strftime(key.inserted_at, "%Y-%m-%d")}</td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-key-#{key.id}"}
                      phx-click="revoke-key"
                      phx-value-id={key.id}
                      data-confirm="Revoke this SSH key and close sessions using it?"
                    >
                      Revoke key
                    </Layouts.action>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="admin-sessions" title="Active SSH sessions">
          <p :if={@sessions == []} class="muted">No active sessions.</p>
          <div :if={@sessions != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">Gateway</th>
                  <th class="width-auto">Key</th>
                  <th class="width-min">Expires</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={session <- @sessions} id={"admin-session-#{session.id}"}>
                  <td class="break">{session.gateway_name}</td>
                  <td class="break"><code>{session.fingerprint || "pending key approval"}</code></td>
                  <td class="muted nowrap">
                    {Calendar.strftime(session.expires_at, "%Y-%m-%d %H:%M UTC")}
                  </td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-session-#{session.id}"}
                      phx-click="revoke-session"
                      phx-value-id={session.id}
                      data-confirm="Close this SSH session?"
                    >
                      Close session
                    </Layouts.action>
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
