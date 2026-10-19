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
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_access", "SSH key revoked.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_access", "Could not revoke that key."))}
    end
  end

  def handle_event("revoke-session", %{"id" => id}, socket) do
    case SSH.revoke_session_for_admin(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_access", "SSH session closed.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_access", "Could not close that session."))}
    end
  end

  def handle_event("revoke-grant", %{"id" => id}, socket) do
    case Marshall.Access.revoke_grant_for_admin(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("admin_access", "VM access revoked.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("admin_access", "Could not revoke that VM access."))}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("admin_access", "Invalid request."))}

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
      _ ->
        put_flash(
          socket,
          :error,
          dgettext("admin_access", "Access inventory is temporarily unavailable.")
        )
    end
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
      admin_active="access"
    >
      <section id="admin-access" class="stack">
        <UI.heading
          title={dgettext("admin_access", "Access authority")}
          subtitle={
            dgettext(
              "admin_access",
              "Who can reach which machine, and by which key or session. Private keys, session tokens and gateway credentials are never shown."
            )
          }
        >
          <:actions>
            <span class="muted">{dgettext("admin_access", "Updated every 15 seconds")}</span>
          </:actions>
        </UI.heading>
        <.kv id="access-summary">
          <:item title={dgettext("admin_access", "Shared machine grants")}>{length(@grants)}</:item>
          <:item title={dgettext("admin_access", "Registered SSH keys")}>{length(@keys)}</:item>
          <:item title={dgettext("admin_access", "Active SSH sessions")}>{length(@sessions)}</:item>
        </.kv>
        <UI.panel id="admin-grants" title={dgettext("admin_access", "Shared machine access")}>
          <p :if={@grants == []} class="muted">
            {dgettext("admin_access", "No machine is shared with another account.")}
          </p>
          <div :if={@grants != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_access", "Machine")}</th>
                  <th class="width-auto">{dgettext("admin_access", "Account")}</th>
                  <th class="width-min">{dgettext("admin_access", "Role")}</th>
                  <th class="width-min">{dgettext("admin_access", "Granted")}</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">{dgettext("admin_access", "Actions")}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={grant <- @grants} id={"admin-grant-#{grant.id}"}>
                  <td class="break">{grant.vm_name}</td>
                  <td class="break">
                    <.person
                      id={"admin-grant-#{grant.id}-person"}
                      email={grant.email}
                      time_zone={grant.time_zone}
                      viewer_zone={@time_zone}
                      now={@now}
                    />
                  </td>
                  <td><span class="status-label">{role_label(grant.role)}</span></td>
                  <td class="muted nowrap">
                    <.timestamp at={grant.inserted_at} zone={@time_zone} format={:date} />
                  </td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-grant-#{grant.id}"}
                      phx-click="revoke-grant"
                      phx-value-id={grant.id}
                      data-confirm={dgettext("admin_access", "Revoke this user's VM access?")}
                    >
                      {dgettext("admin_access", "Revoke access")}
                    </Layouts.action>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="admin-keys" title={dgettext("admin_access", "Registered SSH keys")}>
          <p :if={@keys == []} class="muted">{dgettext("admin_access", "No active keys.")}</p>
          <div :if={@keys != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_access", "Account")}</th>
                  <th class="width-auto">{dgettext("admin_access", "Key")}</th>
                  <th class="width-min">{dgettext("admin_access", "Added")}</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">{dgettext("admin_access", "Actions")}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={key <- @keys} id={"admin-key-#{key.id}"}>
                  <td class="break">
                    <.person
                      id={"admin-key-#{key.id}-person"}
                      email={key.email}
                      time_zone={key.time_zone}
                      viewer_zone={@time_zone}
                      now={@now}
                    />
                  </td>
                  <td class="break">
                    {if key.label == "", do: dgettext("admin_access", "SSH key"), else: key.label}<br />
                    <code>{key.fingerprint}</code><br />
                    <span class="muted">{key.algorithm}</span>
                  </td>
                  <td class="muted nowrap">
                    <.timestamp at={key.inserted_at} zone={@time_zone} format={:date} />
                  </td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-key-#{key.id}"}
                      phx-click="revoke-key"
                      phx-value-id={key.id}
                      data-confirm={
                        dgettext("admin_access", "Revoke this SSH key and close sessions using it?")
                      }
                    >
                      {dgettext("admin_access", "Revoke key")}
                    </Layouts.action>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="admin-sessions" title={dgettext("admin_access", "Active SSH sessions")}>
          <p :if={@sessions == []} class="muted">{dgettext("admin_access", "No active sessions.")}</p>
          <div :if={@sessions != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">{dgettext("admin_access", "Gateway")}</th>
                  <th class="width-auto">{dgettext("admin_access", "Key")}</th>
                  <th class="width-min">{dgettext("admin_access", "Expires")}</th>
                  <th :if={@admin_authorized} class="width-min">
                    <span class="sr-only">{dgettext("admin_access", "Actions")}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={session <- @sessions} id={"admin-session-#{session.id}"}>
                  <td class="break">{session.gateway_name}</td>
                  <td class="break">
                    <code>{session.fingerprint || dgettext("admin_access", "Pending key approval")}</code>
                  </td>
                  <td class="muted nowrap">
                    <.timestamp at={session.expires_at} zone={@time_zone} format={:datetime} />
                  </td>
                  <td :if={@admin_authorized}>
                    <Layouts.action
                      tone="danger"
                      id={"revoke-session-#{session.id}"}
                      phx-click="revoke-session"
                      phx-value-id={session.id}
                      data-confirm={dgettext("admin_access", "Close this SSH session?")}
                    >
                      {dgettext("admin_access", "Close session")}
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

  # @cc [owner:ghuntley,label:product] localized-access-role-labels
  # Visible access roles MUST use translated labels while role attributes and
  # action values retain the authoritative domain atoms.
  @spec role_label(atom()) :: String.t()
  defp role_label(:web), do: dgettext("admin_access", "Web apps")
  defp role_label(:viewer), do: dgettext("admin_access", "Viewer")
  defp role_label(:operator), do: dgettext("admin_access", "Operator")
  defp role_label(:manager), do: dgettext("admin_access", "Manager")
  defp role_label(:revoked), do: dgettext("admin_access", "Revoked")
  defp role_label(_), do: dgettext("admin_access", "Unknown")
end
