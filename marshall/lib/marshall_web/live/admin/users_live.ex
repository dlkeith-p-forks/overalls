defmodule MarshallWeb.Admin.UsersLive do
  use MarshallWeb, :live_view
  alias Marshall.Accounts.User
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5_000)
    {:ok, assign(socket, cursor: nil, next_cursor: nil, empty?: true) |> stream(:users, [])}
  end

  @impl true
  def handle_params(params, _, socket) do
    cursor = params["after"]

    if is_nil(cursor) or OverallsProtocol.uuid?(cursor),
      do: {:noreply, socket |> assign(:cursor, cursor) |> refresh()},
      else: {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("set-role", %{"id" => id, "enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    result =
      User
      |> Ash.ActionInput.for_action(
        :set_administrator,
        %{user_id: id, administrator: enabled == "true"},
        actor: socket.assigns.current_user
      )
      |> Ash.run_action()

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Administrator access updated.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not change administrator access.")}
    end
  end

  def handle_event("revoke-sessions", %{"id" => id}, socket) do
    result =
      User
      |> Ash.ActionInput.for_action(
        :revoke_sessions_for_admin,
        %{user_id: id},
        actor: socket.assigns.current_user
      )
      |> Ash.run_action()

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Browser sessions revoked.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not revoke browser sessions.")}
    end
  end

  def handle_event("invite", %{"email" => email}, socket),
    do: change_account(socket, :invite_user, %{email: email})

  def handle_event("delete-user", %{"user_id" => id, "confirmation" => email}, socket),
    do: change_account(socket, :delete_user, %{user_id: id, confirmation: email})

  def handle_event("reset-mfa", %{"id" => id}, socket),
    do: change_account(socket, :reset_mfa, %{user_id: id})

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp change_account(socket, action, params) do
    case User
         |> Ash.ActionInput.for_action(action, params, actor: socket.assigns.current_user)
         |> Ash.run_action() do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Account request accepted.") |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not accept this account change. Check confirmation and verify your passkey."
         )}
    end
  end

  defp refresh(socket) do
    result =
      User
      |> Ash.ActionInput.for_action(:list_admin_users, %{after: socket.assigns.cursor},
        actor: socket.assigns.current_user
      )
      |> Ash.run_action()

    case result do
      {:ok, page} ->
        socket
        |> assign(next_cursor: page.next_cursor, empty?: page.items == [])
        |> stream(:users, page.items, reset: true)

      {:error, _} ->
        socket
        |> stream(:users, [], reset: true)
        |> assign(empty?: true, next_cursor: nil)
        |> put_flash(:error, "Accounts are temporarily unavailable.")
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
      admin_active="users"
    >
      <section id="admin-users" class="stack">
        <UI.heading
          title="Users"
          subtitle="Every account on this deployment. Signed-in users can read this page; changes need an administrator with a recent passkey verification."
        />
        <UI.panel :if={@admin_authorized} id="invite-panel" title="Invite a user">
          <.form for={to_form(%{})} id="invite-user" phx-submit="invite" class="field-row">
            <.input name="email" value="" type="email" label="Email address" required />
            <button class="console-button primary">Send invitation</button>
          </.form>
          <p class="muted">
            <.link href={~p"/settings/security?#{%{return_to: "/admin/users"}}"}>
              Verify with passkey · administrative access lasts 15 minutes →
            </.link>
          </p>
        </UI.panel>
        <div id="admin-user-rows" phx-update="stream" class="stack">
          <article :for={{dom_id, user} <- @streams.users} id={dom_id} class="panel account">
            <header>
              <h2 class="ident break">{user.email}</h2>
              <span class="status-label" data-tone={if user.administrator, do: "success", else: nil}>
                {if user.administrator, do: "Administrator", else: "User"}
              </span>
            </header>
            <div class="panel-body">
              <p class="muted">
                {user.owned_count} owned machines · {if user.mfa_enabled,
                  do: "MFA enabled",
                  else: "MFA not enrolled"}<span :if={user.id == @current_user.id}> · Your account</span>
              </p>
              <p :if={user.deletion_status} class="muted">{user.deletion_status}</p>
              <p :if={user.time_zone}>
                <.local_time
                  id={"admin-user-local-time-#{user.id}"}
                  zone={user.time_zone}
                  viewer_zone={@time_zone}
                  now={@now}
                />
              </p>
              <div
                :if={@admin_authorized and (user.id != @current_user.id and is_nil(user.deleted_at))}
                class="stack"
              >
                <div class="row actions">
                  <button
                    id={"role-#{user.id}"}
                    phx-click="set-role"
                    phx-value-id={user.id}
                    phx-value-enabled={to_string(not user.administrator)}
                    data-confirm={
                      if user.administrator,
                        do: "Remove administrator access for this account?",
                        else:
                          "Grant this account access to administer the entire fleet and all machines?"
                    }
                    class="console-button"
                  >
                    {if user.administrator, do: "Remove administrator", else: "Make administrator"}
                  </button>
                  <button
                    id={"sessions-#{user.id}"}
                    phx-click="revoke-sessions"
                    phx-value-id={user.id}
                    data-confirm="Sign this account out of every browser session?"
                    class="console-button"
                  >Sign out everywhere</button>
                  <button
                    id={"reset-mfa-#{user.id}"}
                    phx-click="reset-mfa"
                    phx-value-id={user.id}
                    data-confirm="Reset this user's MFA and revoke all browser sessions? They must enroll a replacement passkey."
                    class="console-button"
                  >Reset MFA</button>
                </div>
                <.form
                  for={to_form(%{})}
                  id={"delete-user-#{user.id}"}
                  phx-submit="delete-user"
                  class="field-row"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <.input
                    name="confirmation"
                    value=""
                    label={"Type the email to delete this account and its #{user.owned_count} machines"}
                    required
                  />
                  <button
                    data-confirm="Permanently delete this account and ALL machines they own, including machines shared with others?"
                    class="console-button danger"
                  >Delete user and machines</button>
                </.form>
              </div>
            </div>
          </article>
        </div>
        <p :if={@empty?} id="admin-users-empty" class="empty-state">
          No accounts on this page.
        </p>
        <nav class="row" aria-label="Account pages">
          <.link :if={@cursor} patch={~p"/admin/users"}>← First page</.link>
          <.link
            :if={@next_cursor}
            id="admin-users-next"
            patch={~p"/admin/users?#{%{after: @next_cursor}}"}
          >Next page →</.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end
end
