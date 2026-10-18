defmodule MarshallWeb.AccountLive do
  @moduledoc """
  The signed-in account page at `/settings` (ADR-0196): one LiveView with three
  anchored sections. Profile (`#profile`) holds the email and the display time
  zone of ADR-0195; Sign-in and passkeys (`#security`) holds passkey
  enrollment, verification, the elevation return path of ADR-0160 and passkey
  management; SSH keys (`#ssh-keys`) holds the owner-scoped keys of ADR-0046.
  The security mount of `MarshallWeb.LiveUserAuth` guards every section.
  """
  use MarshallWeb, :live_view
  alias Marshall.Accounts.{TimeZones, User}
  alias Marshall.SSH
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :security}

  @type socket :: Phoenix.LiveView.Socket.t()
  @type reply :: {:noreply, socket()} | {:reply, map(), socket()}

  # @cc [owner:ghuntley,label:security] account-page-security-mount
  # The merged page MUST mount through LiveUserAuth's :security mode (the
  # strictest required-login mount) so every section, including profile and
  # SSH keys, rechecks the persisted login on mount, each event, each message
  # and each parameter change. Merging sections MUST NOT weaken the gate the
  # standalone Security page had.
  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(params, session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)
    pending_launch = session[MarshallWeb.PendingLaunch.key()]

    {:ok,
     socket
     |> assign(
       page_title: "Account",
       return_to: safe_return(params["return_to"], pending_launch),
       pending_launch: pending_launch,
       security: nil,
       remaining: 0,
       enrollment_started?: false,
       keys: []
     )
     |> assign_picker()
     |> reset_key_form()
     |> refresh_security()
     |> refresh_keys()}
  end

  @impl true
  @spec handle_info(:tick, socket()) :: {:noreply, socket()}
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, refresh_security(socket)}
  end

  # Sign-in and passkeys: the ceremony hook pushes begin/finish/cancelled; the
  # rename form and the remove/lock buttons push credential. The generic
  # :security action on User decides every outcome with the socket actor.
  @impl true
  @spec handle_event(String.t(), map(), socket()) :: reply()
  def handle_event("begin", %{"kind" => kind}, socket) when kind in ["register", "verify"] do
    operation = if kind == "register", do: :begin_register, else: :begin_verify

    case security_action(socket, operation, %{}) do
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

    case security_action(socket, operation, payload) do
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
         |> refresh_security()}

      _ ->
        {:reply, %{ok: false},
         put_flash(socket, :error, "Verification could not be completed. Please try again.")}
    end
  end

  def handle_event("credential", %{"operation" => operation} = params, socket)
      when operation in ["rename", "remove", "lock"] do
    operation = %{"rename" => :rename, "remove" => :remove, "lock" => :lock}[operation]

    case security_action(socket, operation, %{
           "id" => params["id"] || params["credential_id"],
           "label" => params["label"]
         }) do
      {:ok, _} ->
        {:noreply, refresh_security(socket)}

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

  # @cc [owner:ghuntley,label:security] browser-key-account-authority
  # SSH key actions MUST use the freshly authenticated socket user, never an
  # owner supplied by the form. Submitted key material MUST be cleared after
  # attempts and MUST NOT be reflected in diagnostics or error messages.
  def handle_event("add_ssh_key", %{"key" => params}, socket) when is_map(params) do
    result =
      SSH.add_key(Map.take(params, ["public_key", "label"]), actor: socket.assigns.current_user)

    socket = reset_key_form(socket)

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "SSH key added.") |> refresh_keys()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not add this key. Paste one supported public key; it must not belong to another account."
         )}
    end
  end

  def handle_event("remove_ssh_key", %{"id" => id}, socket) do
    case SSH.remove_key(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "SSH key removed.") |> refresh_keys()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not remove this key.") |> refresh_keys()}
    end
  end

  # @cc [owner:ghuntley,label:security] profile-time-zone-through-domain-action
  # Saving or clearing MUST go through the User set_time_zone action with the
  # freshly authenticated socket user as the actor; the page MUST NOT write
  # the users table itself or accept a user id from the form. A refused zone
  # MUST leave the saved zone and the viewer assigns unchanged.
  def handle_event("save_time_zone", %{"profile" => %{"time_zone" => zone}}, socket)
      when is_binary(zone) do
    case set_time_zone(socket, zone) do
      {:ok, socket} -> {:noreply, put_flash(socket, :info, "Time zone saved.")}
      :error -> {:noreply, put_flash(socket, :error, "Choose a time zone from the list.")}
    end
  end

  def handle_event("clear_time_zone", _params, socket) do
    case set_time_zone(socket, nil) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Time zone cleared. Your browser's zone is used.")}

      :error ->
        {:noreply, put_flash(socket, :error, "Could not clear your time zone.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  @spec refresh_security(socket()) :: socket()
  defp refresh_security(socket) do
    case security_action(socket, :status, %{}) do
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

  @spec security_action(socket(), atom(), map()) :: {:ok, term()} | {:error, term()}
  defp security_action(socket, operation, payload) do
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

  @spec refresh_keys(socket()) :: socket()
  defp refresh_keys(socket) do
    case SSH.list_keys(%{}, actor: socket.assigns.current_user) do
      {:ok, keys} ->
        assign(socket, keys: keys)

      {:error, _} ->
        socket |> assign(keys: []) |> put_flash(:error, "SSH keys are temporarily unavailable.")
    end
  end

  @spec reset_key_form(socket()) :: socket()
  defp reset_key_form(socket),
    do: assign(socket, key_form: to_form(%{"label" => "", "public_key" => ""}, as: :key))

  @spec set_time_zone(socket(), String.t() | nil) :: {:ok, socket()} | :error
  defp set_time_zone(socket, zone) do
    User
    |> Ash.ActionInput.for_action(:set_time_zone, %{time_zone: zone},
      actor: socket.assigns.current_user
    )
    |> Ash.run_action()
    |> case do
      {:ok, %{time_zone: saved}} ->
        user = %{socket.assigns.current_user | time_zone: saved}

        {:ok,
         socket
         |> assign(:current_user, user)
         |> MarshallWeb.LiveUserAuth.assign_time_zone()
         |> assign_picker()}

      _ ->
        :error
    end
  end

  # The picker preselects the saved zone, else the browser's zone (added to the
  # list when it is not curated), else UTC.
  @spec assign_picker(socket()) :: socket()
  defp assign_picker(socket) do
    %{time_zone: zone, now: now, current_user: user} = socket.assigns
    options = TimeZones.options(now)

    options =
      if Enum.any?(options, &(&1.zone == zone)) do
        options
      else
        case TimeZones.option(zone, now) do
          nil -> options
          extra -> [extra | options]
        end
      end

    assign(socket,
      saved: user.time_zone,
      options: Enum.map(options, &{&1.label, &1.zone}),
      zone_form: to_form(%{"time_zone" => zone}, as: :profile)
    )
  end

  @spec zone_status(TimeZones.source(), TimeZones.iana()) :: String.t()
  defp zone_status(:saved, zone),
    do: "Saved: #{zone}. Others who share a team, machine or thread with you see your local time."

  defp zone_status(:browser, zone),
    do: "Detected from your browser: #{zone}. Save it so others can see your local time."

  defp zone_status(:utc, _zone),
    do: "No zone saved and none detected; times are shown in UTC until you choose one."

  @spec key_title(String.t() | nil) :: String.t()
  defp key_title(label) when label in [nil, ""], do: "SSH key"
  defp key_title(label), do: label

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      active="account"
    >
      <div id="account-settings" class="stack">
        <UI.heading
          title="Account"
          subtitle="Who you are, how you prove it, and the keys that reach your machines."
        />
        <nav id="account-index" class="account-index" aria-label="On this page">
          <ol>
            <li>
              <a href="#profile">Profile</a>
              <span class="muted">email, time zone and your local clock</span>
            </li>
            <li>
              <a href="#security">Sign-in and passkeys</a>
              <span class="muted">verification for administrative changes</span>
            </li>
            <li>
              <a href="#ssh-keys">SSH keys</a>
              <span class="muted">{length(@keys)} registered</span>
            </li>
          </ol>
        </nav>

        <section id="profile" class="account-section stack" aria-labelledby="profile-title">
          <h2 id="profile-title">1. Profile</h2>
          <.kv id="profile-account">
            <:item title="Email">{@current_user.email}</:item>
            <:item title="Local time">
              <span class="profile-clock">
                <.local_clock
                  id="profile-local-clock"
                  zone={@time_zone}
                  now={@now}
                  source={@time_zone_source}
                />
                <span class="muted">
                  {@time_zone} · {TimeZones.gmt_label(TimeZones.offset(@time_zone, @now))}
                </span>
              </span>
            </:item>
          </.kv>
          <p class="muted">
            Your email is your sign-in identity and cannot be edited here. Every time on Overalls
            is shown in your zone; people who share a team, machine or thread with you, and
            administrators, see your current local time next to your email once a zone is saved.
          </p>
          <.form for={@zone_form} id="time-zone-form" phx-submit="save_time_zone" class="stack">
            <.input
              field={@zone_form[:time_zone]}
              type="select"
              label="Time zone"
              options={@options}
            />
            <p id="time-zone-status" class="muted" data-source={@time_zone_source}>
              {zone_status(@time_zone_source, @time_zone)}
            </p>
            <div class="row actions">
              <button id="save-time-zone" type="submit" class="console-button primary">
                Save time zone
              </button>
              <button
                :if={@saved}
                id="clear-time-zone"
                type="button"
                phx-click="clear_time_zone"
                class="console-button"
              >
                Clear saved zone
              </button>
            </div>
          </.form>
        </section>

        <hr />

        <section id="security" class="account-section stack" aria-labelledby="security-title">
          <h2 id="security-title">2. Sign-in and passkeys</h2>
          <p class="muted">
            You sign in with an email link. A passkey proves it is you before administrative
            changes and before passkey changes; everyday use of your workspace never asks for one.
          </p>
          <div :if={@security} class="stack">
            <p id="verification-status" aria-live="polite" data-verified={@remaining > 0}>
              <%= if @remaining > 0 do %>
                <strong class="inverse">[verified]</strong>
                Passkey verified · {@remaining} seconds remaining.
              <% else %>
                <strong>[not verified]</strong>
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
            <p :if={@remaining > 0}>
              <button
                id="lock-elevation"
                phx-click="credential"
                phx-value-operation="lock"
                class="console-button compact"
              >Lock now</button>
              <span class="muted">End this verification before the fifteen minutes are up.</span>
            </p>
            <p :if={@security.verified or @enrollment_started?}>
              <.link id="security-continue" href={@return_to}>
                Return to the requested page and retry the action →
              </.link>
            </p>
            <p :if={@security.credentials == []} id="passkeys-empty" class="empty-state">
              No passkeys yet. First enrollment requires a fresh email sign-in completed within
              the last five minutes. After setup, return to the page you came from and retry the action.
            </p>
            <h3 :if={@security.credentials != []}>Your passkeys</h3>
            <div id="passkey-list" class="stack">
              <div :for={key <- @security.credentials} id={"passkey-#{key.id}"} class="passkey">
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
                  <button
                    id={"remove-#{key.id}"}
                    type="button"
                    phx-click="credential"
                    phx-value-id={key.id}
                    phx-value-operation="remove"
                    data-confirm="Remove this passkey? Removing your last passkey signs you out everywhere."
                    class="console-button danger"
                  >Remove</button>
                </.form>
                <p class="muted">
                  Added <.timestamp at={key.inserted_at} zone={@time_zone} format={:date} />
                </p>
              </div>
            </div>
            <p class="muted">
              Keep a backup passkey. If you lose access, another administrator can reset your passkeys.
            </p>
          </div>
        </section>

        <hr />

        <section id="ssh-keys" class="account-section stack" aria-labelledby="ssh-keys-title">
          <h2 id="ssh-keys-title">3. SSH keys</h2>
          <p class="muted">
            Keys registered here open your machines over SSH with the same account and
            permissions as this site. Remove a key to revoke its access; email sign-in keeps
            working without any key.
          </p>
          <p :if={@keys == []} id="ssh-keys-empty" class="empty-state">
            No SSH keys yet. You can always sign in here using email.
          </p>
          <article :for={key <- @keys} id={"ssh-key-#{key.id}"} class="panel">
            <header>
              <h3>{key_title(key.label)}</h3>
              <Layouts.action
                tone="danger"
                id={"remove-ssh-key-#{key.id}"}
                phx-click="remove_ssh_key"
                phx-value-id={key.id}
                data-confirm="Remove this key's SSH access? Already accepted machine operations will continue."
              >
                Remove
              </Layouts.action>
            </header>
            <.kv>
              <:item title="Fingerprint"><code class="break">{key.fingerprint}</code></:item>
              <:item title="Type">{key.algorithm}</:item>
              <:item title="Added">
                <.timestamp at={key.inserted_at} zone={@time_zone} format={:date} />
              </:item>
            </.kv>
          </article>
          <.form for={@key_form} id="ssh-key-form" phx-submit="add_ssh_key" class="panel dashed">
            <h3>Add a key</h3>
            <.input
              field={@key_form[:label]}
              label="Label (optional)"
              maxlength="128"
              placeholder="My laptop"
            />
            <.input
              field={@key_form[:public_key]}
              type="textarea"
              label="Public key"
              required
              maxlength="4096"
              rows="4"
              placeholder="ssh-ed25519 …"
              hint="Paste a public key from your .pub file. Never paste a private key."
            />
            <Layouts.action
              tone="primary"
              id="add-ssh-key"
              type="submit"
              phx-disable-with="Adding…"
            >
              Add SSH key
            </Layouts.action>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
