defmodule MarshallWeb.AccountLive do
  @moduledoc """
  The signed-in account page at `/settings` (ADR-0196): one LiveView with four
  anchored sections. Profile (`#profile`) holds the email and the display time
  zone of ADR-0195, language, and Git preferences of ADR-0199; Sign-in and passkeys (`#security`) holds passkey
  enrollment, verification, the elevation return path of ADR-0160 and passkey
  management; SSH keys (`#ssh-keys`) holds the owner-scoped keys of ADR-0046.
  Git preferences (`#git-settings`) retain ADR-0198 account-owned identity defaults.
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
       page_title: dgettext("account", "Account"),
       return_to: safe_return(params["return_to"], pending_launch),
       pending_launch: pending_launch,
       security: nil,
       remaining: 0,
       enrollment_started?: false,
       keys: []
     )
     |> assign_picker()
     |> assign_git_settings()
     |> reset_key_form()
     |> refresh_security()
     |> refresh_keys()
     |> refresh_git_settings()}
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
           dgettext(
             "account",
             "Verification required. Use an existing passkey, or sign out and request a fresh email link before first enrollment."
           )
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
             do:
               dgettext(
                 "account",
                 "Passkey added. Verify it when you need to approve an administrative change."
               ),
             else: dgettext("account", "Passkey verified for 15 minutes.")
           )
         )
         |> refresh_security()}

      _ ->
        {:reply, %{ok: false},
         put_flash(
           socket,
           :error,
           dgettext("account", "Verification could not be completed. Please try again.")
         )}
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
           dgettext(
             "account",
             "Credential change refused. Names must be 1–80 characters, changes need a passkey verified in the last 15 minutes, and administrators must keep at least one passkey."
           )
         )}
    end
  end

  def handle_event("cancelled", _, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :info,
         dgettext("account", "Passkey request cancelled or unavailable. You can try again.")
       )}

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
        {:noreply,
         socket |> put_flash(:info, dgettext("account", "SSH key added.")) |> refresh_keys()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext(
             "account",
             "Could not add this key. Paste one supported public key; it must not belong to another account."
           )
         )}
    end
  end

  def handle_event("rename_ssh_key", %{"key_id" => id, "label" => label}, socket)
      when is_binary(id) and is_binary(label) do
    case SSH.rename_key(%{id: id, label: label}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("account", "SSH key renamed.")) |> refresh_keys()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           dgettext("account", "Could not rename this key. Use at most 128 characters.")
         )
         |> refresh_keys()}
    end
  end

  def handle_event("remove_ssh_key", %{"id" => id}, socket) do
    case SSH.remove_key(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("account", "SSH key removed.")) |> refresh_keys()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("account", "Could not remove this key."))
         |> refresh_keys()}
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
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, dgettext("account", "Time zone saved."))}

      :error ->
        {:noreply,
         put_flash(socket, :error, dgettext("account", "Choose a time zone from the list."))}
    end
  end

  def handle_event("clear_time_zone", _params, socket) do
    case set_time_zone(socket, nil) do
      {:ok, socket} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           dgettext("account", "Time zone cleared. Your browser's zone is used.")
         )}

      :error ->
        {:noreply,
         put_flash(socket, :error, dgettext("account", "Could not clear your time zone."))}
    end
  end

  # @cc [owner:ghuntley,label:security] profile-language-through-domain-action
  # Browser input MUST only select a locale, never a target account. Reloading
  # after a successful update applies language and direction to the whole page.
  def handle_event("save_locale", %{"language" => %{"locale" => locale}}, socket)
      when is_binary(locale) do
    save_locale(socket, locale)
  end

  def handle_event("clear_locale", _, socket), do: save_locale(socket, nil)

  # @cc [owner:ghuntley,label:security] self-git-settings
  # Git updates MUST use the freshly authenticated socket account and only the
  # three accepted preference fields. Submitted owner identifiers MUST NOT
  # select an account or weaken the page's security mount.
  def handle_event("save_git_settings", %{"settings" => params}, socket) when is_map(params) do
    actor = socket.assigns.current_user
    params = Map.take(params, ["git_username", "git_email", "commit_trailers_enabled"])

    case actor |> Ash.Changeset.for_update(:git_settings, params) |> Ash.update(actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_git_settings()
         |> put_flash(:info, dgettext("account", "Git settings saved."))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("account", "Enter a valid Git name and email address.")
         )}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("account", "Invalid request."))}

  @spec refresh_git_settings(socket()) :: socket()
  defp refresh_git_settings(socket) do
    user = Marshall.Accounts.Security.current(socket.assigns.current_user.id)

    assign(socket,
      git_form:
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
        socket
        |> assign(keys: [])
        |> put_flash(:error, dgettext("account", "SSH keys are temporarily unavailable."))
    end
  end

  @spec reset_key_form(socket()) :: socket()
  defp reset_key_form(socket),
    do: assign(socket, key_form: to_form(%{"label" => "", "public_key" => ""}, as: :key))

  @spec save_locale(socket(), String.t() | nil) :: {:noreply, socket()}
  defp save_locale(socket, locale) do
    User
    |> Ash.ActionInput.for_action(:set_locale, %{locale: locale},
      actor: socket.assigns.current_user
    )
    |> Ash.run_action()
    |> case do
      {:ok, _} ->
        {:noreply, push_event(socket, "locale-updated", %{})}

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("account", "Choose a language from the list."))}
    end
  end

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
      zone_form: to_form(%{"time_zone" => zone}, as: :profile),
      locale_form:
        to_form(%{"locale" => user.locale || socket.assigns[:locale] || "en"}, as: :language),
      locale_options: Marshall.Localization.options()
    )
  end

  @spec assign_git_settings(socket()) :: socket()
  defp assign_git_settings(socket) do
    user = Marshall.Accounts.Security.current(socket.assigns.current_user.id)

    assign(socket,
      git_form:
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

  @spec zone_status(TimeZones.source(), TimeZones.iana()) :: String.t()
  defp zone_status(:saved, zone),
    do:
      dgettext(
        "account",
        "Saved: %{value1}. Others who share a team, machine or thread with you see your local time.",
        value1: zone
      )

  defp zone_status(:browser, zone),
    do:
      dgettext(
        "account",
        "Detected from your browser: %{value1}. Save it so others can see your local time.",
        value1: zone
      )

  defp zone_status(:utc, _zone),
    do:
      dgettext(
        "account",
        "No zone saved and none detected; times are shown in UTC until you choose one."
      )

  @spec key_title(String.t() | nil) :: String.t()
  defp key_title(label) when label in [nil, ""], do: dgettext("account", "SSH key")
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
          title={dgettext("account", "Account")}
          subtitle={
            dgettext(
              "account",
              "Who you are, how you prove it, and the keys that reach your machines."
            )
          }
        />
        <nav id="account-index" class="account-index" aria-label={dgettext("account", "On this page")}>
          <ol>
            <li>
              <a href="#profile">{dgettext("account", "Profile")}</a>
              <span class="muted">{dgettext("account", "email, time zone and your local clock")}</span>
            </li>
            <li>
              <a href="#security">{dgettext("account", "Sign-in and passkeys")}</a>
              <span class="muted">{dgettext("account", "verification for administrative changes")}</span>
            </li>
            <li>
              <a href="#ssh-keys">{dgettext("account", "SSH keys")}</a>
              <span class="muted">{dngettext(
                "account",
                "%{count} registered key",
                "%{count} registered keys",
                length(@keys)
              )}</span>
            </li>
            <li>
              <a href="#git-settings">{dgettext("account", "Git identity")}</a>
              <span class="muted">{dgettext("account", "new machines and commit attribution")}</span>
            </li>
          </ol>
        </nav>

        <section id="profile" class="account-section stack" aria-labelledby="profile-title">
          <h2 id="profile-title">{dgettext("account", "1. Profile")}</h2>
          <.form for={@locale_form} id="language-form" phx-submit="save_locale" class="stack">
            <.input
              field={@locale_form[:locale]}
              type="select"
              label={dgettext("account", "Language")}
              options={@locale_options}
            />
            <p id="language-status" class="muted">
              {if @current_user.locale,
                do: dgettext("account", "Your saved language overrides browser preferences."),
                else: dgettext("account", "Language is detected from your browser.")}
            </p>
            <div class="row actions">
              <button id="save-language" type="submit" class="console-button primary">
                {dgettext("account", "Save language")}
              </button>
              <button
                :if={@current_user.locale}
                id="clear-language"
                type="button"
                phx-click="clear_locale"
                class="console-button"
              >
                {dgettext("account", "Use browser language")}
              </button>
            </div>
          </.form>
          <.kv id="profile-account">
            <:item title={dgettext("account", "Email")}>{@current_user.email}</:item>
            <:item title={dgettext("account", "Local time")}>
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
            {dgettext(
              "account",
              "Your email is your sign-in identity and cannot be edited here. Every time on Overalls is shown in your zone; people who share a team, machine or thread with you, and administrators, see your current local time next to your email once a zone is saved."
            )}
          </p>
          <.form for={@zone_form} id="time-zone-form" phx-submit="save_time_zone" class="stack">
            <.input
              field={@zone_form[:time_zone]}
              type="select"
              label={dgettext("account", "Time zone")}
              options={@options}
            />
            <p id="time-zone-status" class="muted" data-source={@time_zone_source}>
              {zone_status(@time_zone_source, @time_zone)}
            </p>
            <div class="row actions">
              <button id="save-time-zone" type="submit" class="console-button primary">
                {dgettext("account", "Save time zone")}
              </button>
              <button
                :if={@saved}
                id="clear-time-zone"
                type="button"
                phx-click="clear_time_zone"
                class="console-button"
              >
                {dgettext("account", "Clear saved zone")}
              </button>
            </div>
          </.form>
        </section>

        <hr />

        <section id="security" class="account-section stack" aria-labelledby="security-title">
          <h2 id="security-title">{dgettext("account", "2. Sign-in and passkeys")}</h2>
          <p class="muted">
            {dgettext(
              "account",
              "You sign in with an email link. A passkey proves it is you before administrative changes and before passkey changes; everyday use of your workspace never asks for one."
            )}
          </p>
          <div :if={@security} class="stack">
            <p id="verification-status" aria-live="polite" data-verified={@remaining > 0}>
              <%= if @remaining > 0 do %>
                <strong class="inverse">{dgettext("account", "[verified]")}</strong>
                {dngettext(
                  "account",
                  "Passkey verified · %{count} second remaining.",
                  "Passkey verified · %{count} seconds remaining.",
                  @remaining
                )}
              <% else %>
                <strong>{dgettext("account", "[not verified]")}</strong>
                {dgettext(
                  "account",
                  "Verify a passkey before making administrative changes or changing passkeys."
                )}
              <% end %>
            </p>
            <p :if={@security.reset_required} class="error">
              {dgettext(
                "account",
                "Your passkeys were reset. Register a replacement before approving administrative changes."
              )}
            </p>
            <div
              id="passkey-ceremony"
              phx-hook="PasskeyCeremony"
              phx-update="ignore"
              class="row actions"
            >
              <button id="add-passkey" type="button" data-kind="register" class="console-button">
                {dgettext("account", "Add passkey")}
              </button>
              <button
                id="verify-passkey"
                type="button"
                data-kind="verify"
                class="console-button primary"
              >
                {dgettext("account", "Verify with passkey")}
              </button>
            </div>
            <p :if={@remaining > 0}>
              <button
                id="lock-elevation"
                phx-click="credential"
                phx-value-operation="lock"
                class="console-button compact"
              >{dgettext("account", "Lock now")}</button>
              <span class="muted">{dgettext(
                "account",
                "End this verification before the fifteen minutes are up."
              )}</span>
            </p>
            <p :if={@security.verified or @enrollment_started?}>
              <.link id="security-continue" href={@return_to}>
                {dgettext("account", "Return to the requested page and retry the action →")}
              </.link>
            </p>
            <p :if={@security.credentials == []} id="passkeys-empty" class="empty-state">
              {dgettext(
                "account",
                "No passkeys yet. First enrollment requires a fresh email sign-in completed within the last five minutes. After setup, return to the page you came from and retry the action."
              )}
            </p>
            <h3 :if={@security.credentials != []}>{dgettext("account", "Your passkeys")}</h3>
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
                  <.input
                    name="label"
                    value={key.label}
                    label={dgettext("account", "Passkey name")}
                    maxlength="80"
                  />
                  <button class="console-button">{dgettext("account", "Rename")}</button>
                  <button
                    id={"remove-#{key.id}"}
                    type="button"
                    phx-click="credential"
                    phx-value-id={key.id}
                    phx-value-operation="remove"
                    data-confirm={
                      dgettext(
                        "account",
                        "Remove this passkey? Removing your last passkey signs you out everywhere."
                      )
                    }
                    class="console-button danger"
                  >{dgettext("account", "Remove")}</button>
                </.form>
                <p class="muted">
                  {dgettext("account", "Added")}
                  <.timestamp at={key.inserted_at} zone={@time_zone} format={:date} />
                </p>
              </div>
            </div>
            <p class="muted">
              {dgettext(
                "account",
                "Keep a backup passkey. If you lose access, another administrator can reset your passkeys."
              )}
            </p>
          </div>
        </section>

        <hr />

        <section id="ssh-keys" class="account-section stack" aria-labelledby="ssh-keys-title">
          <h2 id="ssh-keys-title">{dgettext("account", "3. SSH keys")}</h2>
          <p class="muted">
            {dgettext(
              "account",
              "Keys registered here open your machines over SSH with the same account and permissions as this site. Remove a key to revoke its access; email sign-in keeps working without any key."
            )}
          </p>
          <p :if={@keys == []} id="ssh-keys-empty" class="empty-state">
            {dgettext("account", "No SSH keys yet. You can always sign in here using email.")}
          </p>
          <article :for={key <- @keys} id={"ssh-key-#{key.id}"} class="panel">
            <header>
              <h3>{key_title(key.label)}</h3>
              <Layouts.action
                tone="danger"
                id={"remove-ssh-key-#{key.id}"}
                phx-click="remove_ssh_key"
                phx-value-id={key.id}
                data-confirm={
                  dgettext(
                    "account",
                    "Remove this key's SSH access? Already accepted machine operations will continue."
                  )
                }
              >
                {dgettext("account", "Remove")}
              </Layouts.action>
            </header>
            <.form
              for={to_form(%{"label" => key.label})}
              id={"rename-ssh-key-#{key.id}"}
              phx-submit="rename_ssh_key"
              class="field-row"
            >
              <input type="hidden" name="key_id" value={key.id} />
              <.input
                name="label"
                id={"ssh-key-label-#{key.id}"}
                value={key.label}
                label={dgettext("account", "Description")}
                maxlength="128"
              />
              <button class="console-button">{dgettext("account", "Rename")}</button>
            </.form>
            <.kv>
              <:item title={dgettext("account", "Fingerprint")}>
                <code class="break">{key.fingerprint}</code>
              </:item>
              <:item title={dgettext("account", "Type")}>{key.algorithm}</:item>
              <:item title={dgettext("account", "Added")}>
                <.timestamp at={key.inserted_at} zone={@time_zone} format={:date} />
              </:item>
            </.kv>
          </article>
          <.form for={@key_form} id="ssh-key-form" phx-submit="add_ssh_key" class="panel dashed">
            <h3>{dgettext("account", "Add a key")}</h3>
            <.input
              field={@key_form[:label]}
              label={dgettext("account", "Label (optional)")}
              maxlength="128"
              placeholder={dgettext("account", "My laptop")}
            />
            <.input
              field={@key_form[:public_key]}
              type="textarea"
              label={dgettext("account", "Public key")}
              required
              maxlength="4096"
              rows="4"
              placeholder="ssh-ed25519 …"
              hint={
                dgettext(
                  "account",
                  "Paste a public key from your .pub file. Never paste a private key."
                )
              }
            />
            <Layouts.action
              tone="primary"
              id="add-ssh-key"
              type="submit"
              phx-disable-with={dgettext("account", "Adding…")}
            >
              {dgettext("account", "Add SSH key")}
            </Layouts.action>
          </.form>
        </section>

        <hr />

        <section id="git-settings" class="account-section stack" aria-labelledby="git-settings-title">
          <h2 id="git-settings-title">{dgettext("account", "4. Git identity")}</h2>
          <.form for={@git_form} id="git-settings-form" phx-submit="save_git_settings" class="panel">
            <.input
              field={@git_form[:git_username]}
              label={dgettext("account", "Git username")}
              maxlength="128"
              required
            />
            <.input
              field={@git_form[:git_email]}
              type="email"
              label={dgettext("account", "Git email")}
              maxlength="254"
              required
            />
            <.input
              field={@git_form[:commit_trailers_enabled]}
              type="checkbox"
              label={dgettext("account", "Add Overalls commit attribution")}
            />
            <p>
              {dgettext(
                "account",
                "When enabled, new agent commits include Co-authored-by: Overalls <noreply@overalls.dev>."
              )}
            </p>
            <p>
              {dgettext(
                "account",
                "Git identity changes apply to new machines. Commit attribution changes apply to future agent requests."
              )}
            </p>
            <Layouts.action id="save-git-settings" type="submit" tone="primary">
              {dgettext("account", "Save Git settings")}
            </Layouts.action>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
