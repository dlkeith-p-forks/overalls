defmodule MarshallWeb.SecurityLive do
  use MarshallWeb, :live_view
  alias Marshall.Accounts.User
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :security}

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)
    pending_launch = session[MarshallWeb.PendingLaunch.key()]
    return_to = safe_return(params["return_to"], pending_launch)

    {:ok,
     socket
     |> assign(
       return_to: return_to,
       pending_launch: pending_launch,
       security: nil,
       remaining: 0,
       enrollment_started?: false
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("begin", %{"kind" => kind}, socket) when kind in ["register", "verify"] do
    operation = if kind == "register", do: :begin_register, else: :begin_verify

    case action(socket, operation, %{}) do
      {:ok, challenge} ->
        {:reply, %{ok: true, challenge: challenge}, socket}

      _ ->
        {:reply, %{ok: false},
         put_flash(
           socket,
           :error,
           "Verification required. Use an existing passkey, or sign out and request a fresh email link before first enrollment."
         )}
    end
  end

  def handle_event("finish", %{"kind" => kind, "payload" => payload}, socket)
      when kind in ["register", "verify"] do
    operation = if kind == "register", do: :finish_register, else: :finish_verify

    case action(socket, operation, payload) do
      {:ok, %{error: message}} ->
        {:reply, %{ok: false}, put_flash(socket, :error, message)}

      {:ok, _} ->
        {:reply, %{ok: true},
         socket
         |> assign(enrollment_started?: kind == "register")
         |> put_flash(
           :info,
           if(kind == "register",
             do: "Passkey added. Verify it when you need to approve an administrative change.",
             else: "Passkey verified for 15 minutes."
           )
         )
         |> refresh()}

      _ ->
        {:reply, %{ok: false},
         put_flash(socket, :error, "Verification could not be completed. Please try again.")}
    end
  end

  def handle_event("credential", %{"operation" => operation} = params, socket)
      when operation in ["rename", "remove", "lock"] do
    operation = %{"rename" => :rename, "remove" => :remove, "lock" => :lock}[operation]

    case action(socket, operation, %{
           "id" => params["id"] || params["credential_id"],
           "label" => params["label"]
         }) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Credential change refused. Names must be 1–80 characters, changes need a passkey verified in the last 15 minutes, and administrators must keep at least one passkey."
         )}
    end
  end

  def handle_event("cancelled", _, socket),
    do:
      {:noreply,
       put_flash(socket, :info, "Passkey request cancelled or unavailable. You can try again.")}

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp refresh(socket) do
    case action(socket, :status, %{}) do
      {:ok, status} ->
        remaining =
          if status.recent,
            do: max(0, DateTime.diff(status.expires_at, Marshall.Compute.Ledger.now())),
            else: 0

        assign(socket, security: status, remaining: remaining)

      _ ->
        redirect(socket, to: ~p"/sign-in")
    end
  end

  defp action(socket, operation, payload) do
    User
    |> Ash.ActionInput.for_action(:security, %{operation: operation, payload: payload},
      actor: socket.assigns.current_user
    )
    |> Ash.run_action()
  end

  # @cc [owner:ghuntley,label:security] security-return-path
  # Verification MUST only return to an allowlisted same-origin application path.
  # Exact /launch MAY return to valid staged public input; this
  # return MUST NOT authorize admission or retain a credential-bearing URL.
  @spec safe_return(term(), term()) :: String.t()
  defp safe_return("/launch", pending) do
    if MarshallWeb.PendingLaunch.validate(pending), do: "/launch", else: "/overview"
  end

  defp safe_return(path, _) when is_binary(path) do
    if (path == "/overview" or String.starts_with?(path, ["/admin/", "/machines"])) and
         not String.contains?(path, ["\\", "\r", "\n"]), do: path, else: "/overview"
  end

  defp safe_return(_, _), do: "/overview"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{user: @current_user}} active="security">
      <section id="security-settings" class="stack">
        <UI.heading
          title="Security"
          subtitle="Passkeys protect sensitive account and administrative changes. Signing in and using your workspace does not require a passkey."
        />
        <div :if={@security} class="stack">
          <p id="verification-status" aria-live="polite">
            <%= if @remaining > 0 do %>
              Passkey verified · {@remaining} seconds remaining.
            <% else %>
              Verify a passkey before making administrative changes or changing passkeys.
            <% end %>
          </p>
          <p :if={@security.reset_required} class="error">
            Your passkeys were reset. Register a replacement before approving administrative changes.
          </p>
          <div
            id="passkey-ceremony"
            phx-hook="PasskeyCeremony"
            phx-update="ignore"
            class="row actions"
          >
            <button id="add-passkey" type="button" data-kind="register" class="console-button">
              Add passkey
            </button>
            <button
              id="verify-passkey"
              type="button"
              data-kind="verify"
              class="console-button primary"
            >
              Verify with passkey
            </button>
          </div>
          <button
            :if={@remaining > 0}
            id="lock-elevation"
            phx-click="credential"
            phx-value-operation="lock"
            class="console-button compact"
          >Lock now</button>
          <p :if={@security.verified or @enrollment_started?}>
            <.link id="security-continue" href={@return_to}>
              Return to the requested page and retry the action →
            </.link>
          </p>
          <p :if={@security.credentials == []} class="muted">
            First passkey enrollment requires a fresh email sign-in completed within the last five minutes. After setup, return to the page you came from and retry the action.
          </p>
          <div id="passkey-list" class="stack">
            <div :for={key <- @security.credentials} id={"passkey-#{key.id}"} class="panel">
              <.form
                for={to_form(%{"credential_id" => key.id, "label" => key.label})}
                id={"label-#{key.id}"}
                phx-submit="credential"
                class="field-row"
              >
                <input type="hidden" name="credential_id" value={key.id} />
                <input type="hidden" name="operation" value="rename" />
                <.input name="label" value={key.label} label="Passkey name" maxlength="80" />
                <button class="console-button">Rename</button>
              </.form>
              <p>
                <button
                  id={"remove-#{key.id}"}
                  phx-click="credential"
                  phx-value-id={key.id}
                  phx-value-operation="remove"
                  data-confirm="Remove this passkey? Removing your last passkey signs you out everywhere."
                  class="console-button compact"
                >Remove</button>
              </p>
            </div>
          </div>
          <p class="muted">
            Keep a backup passkey. If you lose access, another administrator can reset your passkeys.
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
