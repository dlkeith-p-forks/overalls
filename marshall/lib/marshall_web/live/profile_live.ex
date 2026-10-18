defmodule MarshallWeb.ProfileLive do
  @moduledoc "Self-service profile: the account's email and its display time zone (ADR-0195)."
  use MarshallWeb, :live_view
  alias Marshall.Accounts.{TimeZones, User}
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @type socket :: Phoenix.LiveView.Socket.t()

  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Profile") |> assign_picker()}
  end

  # @cc [owner:ghuntley,label:security] profile-time-zone-through-domain-action
  # Saving or clearing MUST go through the User set_time_zone action with the
  # freshly authenticated socket user as the actor; the page MUST NOT write
  # the users table itself or accept a user id from the form. A refused zone
  # MUST leave the saved zone and the viewer assigns unchanged.
  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("save", %{"profile" => %{"time_zone" => zone}}, socket) when is_binary(zone) do
    case set_time_zone(socket, zone) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Time zone saved.")}

      :error ->
        {:noreply, put_flash(socket, :error, "Choose a time zone from the list.")}
    end
  end

  def handle_event("clear", _params, socket) do
    case set_time_zone(socket, nil) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Time zone cleared. Your browser's zone is used.")}

      :error ->
        {:noreply, put_flash(socket, :error, "Could not clear your time zone.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

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
      form: to_form(%{"time_zone" => zone}, as: :profile)
    )
  end

  @spec status(TimeZones.source(), TimeZones.iana()) :: String.t()
  defp status(:saved, zone),
    do: "Saved: #{zone}. Others who share a team, machine or thread with you see your local time."

  defp status(:browser, zone),
    do: "Detected from your browser: #{zone}. Save it so others can see your local time."

  defp status(:utc, _zone),
    do: "No zone saved and none detected; times are shown in UTC until you choose one."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      active="profile"
    >
      <section id="profile-settings" class="stack">
        <UI.heading
          title="Profile"
          subtitle="Your account identity and how times are shown to you."
        />
        <UI.panel id="profile-account" title="Account">
          <.kv>
            <:item title="Email">{@current_user.email}</:item>
          </.kv>
          <p class="muted">Your email is your sign-in identity and cannot be edited here.</p>
        </UI.panel>
        <UI.panel id="profile-time-zone" title="Time zone">
          <p class="muted">
            Every time on Overalls is shown in this zone. People who share a team, machine or thread
            with you, and administrators, see your current local time next to your email.
          </p>
          <.form for={@form} id="time-zone-form" phx-submit="save" class="stack">
            <.input
              field={@form[:time_zone]}
              type="select"
              label="Time zone"
              options={@options}
            />
            <p id="time-zone-status" class="muted" data-source={@time_zone_source}>
              {status(@time_zone_source, @time_zone)}
            </p>
            <div class="row actions">
              <button id="save-time-zone" type="submit" class="console-button primary">
                Save time zone
              </button>
              <button
                :if={@saved}
                id="clear-time-zone"
                type="button"
                phx-click="clear"
                class="console-button"
              >
                Clear saved zone
              </button>
            </div>
          </.form>
        </UI.panel>
        <UI.panel id="profile-local-time" title="Your local time">
          <p class="profile-clock">
            <.local_clock
              id="profile-local-clock"
              zone={@time_zone}
              now={@now}
              source={@time_zone_source}
            />
            <span class="muted">{@time_zone} · {TimeZones.gmt_label(
              TimeZones.offset(@time_zone, @now)
            )}</span>
          </p>
          <p class="muted">Updates every minute while this page is open.</p>
        </UI.panel>
      </section>
    </Layouts.app>
    """
  end
end
