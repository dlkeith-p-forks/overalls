defmodule MarshallWeb.OverviewLive do
  @moduledoc "A bounded, actor-authorized starting point for the Overalls workspace."
  use MarshallWeb, :live_view
  alias Marshall.Compute
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})

  @type socket :: Phoenix.LiveView.Socket.t()
  @type preview :: %{items: [map()], more: boolean()}
  @preview 6
  # @cc [owner:ghuntley,label:security;product] overview-bounded-authorized-panels
  # Overview MUST request the caller's pinned section and then a machine page
  # through the current actor's domain actions, show at most six machines with
  # pinned machines first, and exclude pinned ids from the page so no machine
  # repeats. Failed panels MUST remain unavailable, not become zero-valued
  # measurements. Refresh replaces all displayed data.
  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 60_000)

    {:ok,
     socket
     |> assign(
       page_title: dgettext("machines", "Overview"),
       visible: true,
       newsletter_status: nil
     )
     |> assign(newsletter_form: to_form(%{"email" => ""}, as: :newsletter))
     |> initial()}
  end

  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}

  def handle_event("dismiss_newsletter", _, socket) do
    case Ash.update(socket.assigns.current_user, %{},
           action: :dismiss_newsletter,
           actor: socket.assigns.current_user
         ) do
      {:ok, _user} -> {:noreply, assign(socket, :newsletter_dismissed, true)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("subscribe_newsletter", %{"newsletter" => %{"email" => email}}, socket)
      when is_binary(email) do
    result = Marshall.Newsletter.subscribe(email)
    {:noreply, assign(socket, :newsletter_status, result)}
  end

  def handle_event("pin", %{"id" => id, "pinned" => pinned}, socket)
      when is_binary(id) and is_binary(pinned) do
    {:noreply,
     socket |> MarshallWeb.MachineWorkspace.toggle_pin(id, pinned == "true") |> refresh()}
  end

  def handle_event("visibility", %{"visible" => visible}, socket) when is_boolean(visible),
    do: {:noreply, assign(socket, :visible, visible)}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  @spec handle_info(:refresh, socket()) :: {:noreply, socket()}
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 60_000)
    {:noreply, if(socket.assigns.visible, do: refresh(socket), else: socket)}
  end

  # @cc [owner:ghuntley,label:product;observability] overview-connected-load
  # The disconnected render MUST NOT read machine or catalog data; it shows the
  # panels as loading, and the connected mount performs the single initial read.
  @spec initial(socket()) :: socket()
  defp initial(socket) do
    if connected?(socket) do
      refresh(socket)
    else
      assign(socket,
        machines: :loading,
        catalog: :loading,
        newsletter_dismissed: true,
        updated_at: nil
      )
    end
  end

  @spec refresh(socket()) :: socket()
  defp refresh(socket),
    do: Marshall.Observability.measure_refresh(:overview, fn -> load(socket) end)

  @spec load(socket()) :: socket()
  defp load(socket) do
    actor = socket.assigns.current_user
    machines = read(fn -> preview(actor) end)
    catalog = read(fn -> Compute.catalog(%{}, actor: actor) end)

    assign(socket,
      machines: machines,
      catalog: catalog,
      newsletter_dismissed: newsletter_dismissed(actor),
      updated_at: DateTime.utc_now()
    )
  end

  @spec newsletter_dismissed(Marshall.Accounts.User.t()) :: boolean()
  defp newsletter_dismissed(%Marshall.Accounts.User{id: id} = actor) do
    current = Marshall.Accounts.Security.current(id)
    Map.get(current || actor, :newsletter_dismissed, false)
  end

  # Pinned machines take the first slots; the keyset page fills the rest.
  @spec preview(Marshall.Accounts.User.t()) :: {:ok, preview()} | {:error, term()}
  defp preview(actor) do
    with {:ok, %{items: shown, ids: pinned_ids}} <-
           Compute.pinned_vms(%{limit: @preview}, actor: actor),
         full? = length(shown) == @preview,
         {:ok, page} <- page(actor, full?, length(shown), pinned_ids) do
      {:ok,
       %{
         items: shown ++ page.items,
         more: length(pinned_ids) > @preview or page.more
       }}
    end
  end

  # When every slot is pinned, one excluded row only tells whether more exist.
  @spec page(Marshall.Accounts.User.t(), boolean(), non_neg_integer(), [String.t()]) ::
          {:ok, %{items: [map()], more: boolean()}} | {:error, term()}
  defp page(actor, true, _shown, pinned_ids) do
    with {:ok, page} <- Compute.list_vms(%{limit: 1, exclude: pinned_ids}, actor: actor),
         do: {:ok, %{items: [], more: page.next_cursor != nil or page.items != []}}
  end

  defp page(actor, false, shown, pinned_ids) do
    with {:ok, page} <-
           Compute.list_vms(%{limit: @preview - shown, exclude: pinned_ids}, actor: actor),
         do: {:ok, %{items: page.items, more: page.next_cursor != nil}}
  end

  @spec read((-> {:ok, map()} | {:error, term()})) :: {:ok, map()} | :unavailable
  defp read(fetch) do
    case fetch.() do
      {:ok, result} -> {:ok, result}
      {:error, _} -> :unavailable
    end
  rescue
    _ in [
      Ash.Error.Forbidden,
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      :unavailable
  end

  @spec gib(non_neg_integer()) :: String.t()
  defp gib(value), do: :erlang.float_to_binary(value / 1_073_741_824, decimals: 1)

  # @cc [owner:ghuntley,label:product] overview-machine-agentless-navigation
  # The overview's per-machine preview MUST expose terminal, editor and access
  # destinations without a machine-scoped agent entry; global Threads is the
  # user-facing entry point for agent work.
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:newsletter_dismissed, false)
      |> Map.put_new(:newsletter_status, nil)
      |> Map.put_new(:newsletter_form, to_form(%{"email" => ""}, as: :newsletter))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="overview"
    >
      <section id="overview" phx-hook="DashboardVisibility">
        <UI.heading
          title={dgettext("machines", "A good day to make something.")}
          subtitle={dgettext("machines", "Your workspace, with a little room to breathe.")}
        >
          <:actions>
            <.link id="overview-create" navigate={~p"/machines/new"} class="console-button primary">
              {dgettext("machines", "+ Create machine")}
            </.link>
          </:actions>
        </UI.heading>
        <div class="overview-grid">
          <UI.panel id="overview-machines" title={dgettext("machines", "Your machines")}>
            <:actions>
              <.link navigate={~p"/machines"}>{dgettext("machines", "View all →")}</.link>
            </:actions>
            <%= case @machines do %>
              <% {:ok, page} -> %>
                <UI.empty
                  :if={page.items == []}
                  id="overview-machines-empty"
                  title={dgettext("machines", "Room for your next idea")}
                >
                  {dgettext(
                    "machines",
                    "No machines in this preview yet. Create one or ask an owner to share access."
                  )}
                  <:action>
                    <.link navigate={~p"/machines/new"} class="console-button ghost">{dgettext(
                      "machines",
                      "Create your first machine"
                    )}</.link>
                  </:action>
                </UI.empty>
                <div id="overview-machine-preview">
                  <article
                    :for={vm <- page.items}
                    id={"overview-machine-#{vm.id}"}
                    class="preview-machine"
                    data-pinned={to_string(UI.pinned?(vm))}
                  >
                    <div>
                      <.link navigate={~p"/machines/#{vm.id}"} class="machine-name">{vm.name}</.link><p>
                        {dgettext(
                          "machines",
                          "%{value1} vCPU · %{value2} GiB RAM · %{value3} GiB disk",
                          value1: vm.vcpu,
                          value2: gib(vm.memory_bytes),
                          value3: gib(vm.disk_bytes)
                        )} · {if vm.owner,
                          do: dgettext("machines", "Personal"),
                          else: dgettext("machines", "Shared")}
                      </p>
                    </div>
                    <div class="preview-labels">
                      <UI.pinned_label vm={vm} id={"overview-machine-pinned-#{vm.id}"} />
                      <UI.os_label vm={vm} id={"overview-machine-os-#{vm.id}"} />
                      <span
                        class="status-label"
                        data-state={vm.observed_state}
                        data-tone={UI.machine_tone(vm)}
                      >{UI.machine_state(vm)}</span>
                    </div>
                    <div class="preview-links">
                      <.link
                        :if={vm.desired_state == :running && vm.observed_state == :running}
                        navigate={~p"/machines/#{vm.id}/terminals"}
                        id={"overview-terminal-#{vm.id}"}
                      >{dgettext("machines", "Open terminal ↗")}</.link>
                      <UI.machine_editor_action vm={vm} id_prefix="overview-machine" variant={:link} />
                      <UI.pin_toggle vm={vm} id={"pin-#{vm.id}"} />
                    </div>
                  </article>
                </div>
                <p :if={page.more} class="muted">
                  {dgettext("machines", "A small preview. All your accessible machines are in")} <.link navigate={
                    ~p"/machines"
                  }>{dgettext("machines", "Machines")}</.link>.
                </p>
              <% :loading -> %>
                <div id="overview-machines-loading" aria-busy="true"></div>
              <% :unavailable -> %>
                <p id="overview-machines-unavailable" role="status">
                  {dgettext("machines", "Machines couldn’t be loaded. Refresh to try again.")}
                </p>
            <% end %>
          </UI.panel>
          <div class="overview-side">
            <UI.panel
              :if={!@newsletter_dismissed}
              id="overview-newsletter"
              title={dgettext("machines", "Stay in the loop")}
            >
              <:actions>
                <button
                  id="overview-newsletter-dismiss"
                  type="button"
                  class="console-button ghost"
                  phx-click="dismiss_newsletter"
                >{dgettext("machines", "Dismiss")}</button>
              </:actions>
              <p class="muted">
                {dgettext("machines", "Get tips, tricks and updates about Overalls and AI by email.")}
              </p>
              <.form
                for={@newsletter_form}
                id="overview-newsletter-form"
                phx-submit="subscribe_newsletter"
                action="https://ghuntley.com/newsletter/"
                method="get"
              >
                <.input
                  field={@newsletter_form[:email]}
                  type="email"
                  autocomplete="email"
                  placeholder="you@example.com"
                  required
                  label={dgettext("machines", "Email address")}
                />
                <button id="overview-newsletter-submit" type="submit" class="console-button primary">{dgettext(
                  "machines",
                  "Subscribe"
                )}</button>
              </.form>
              <p id="overview-newsletter-status" class="muted" role="status" aria-live="polite">
                <%= case @newsletter_status do %>
                  <% :ok -> %>
                    {dgettext(
                      "machines",
                      "Check your inbox and click the link to confirm your subscription."
                    )}
                  <% {:error, :invalid_email} -> %>
                    {dgettext("machines", "Enter a valid email address.")}
                  <% {:error, :unavailable} -> %>
                    {dgettext(
                      "machines",
                      "We could not reach the newsletter service. Try again later."
                    )}
                  <% _ -> %>
                    {dgettext("machines", "Unsubscribe any time.")}
                <% end %>
              </p>
            </UI.panel>
            <UI.panel
              id="overview-marvin-extension"
              title={dgettext("machines", "Open repositories from your browser")}
              data-overalls-extension-setup="true"
            >
              <p class="muted">
                {dgettext(
                  "machines",
                  "Bring a GitHub, GitLab, Codeberg or Bitbucket repository into Overalls with the Chrome or Firefox extension."
                )}
              </p>
              <.link
                id="overview-marvin-extension-link"
                href={~p"/docs/browser-extension"}
                class="console-button ghost"
              >{dgettext("machines", "Set up the browser extension ↗")}</.link>
            </UI.panel>
            <UI.panel id="overview-capacity" title={dgettext("machines", "Room to grow")}>
              <p class="muted">{dgettext("machines", "Current provisioning headroom")}</p>
              <%= case @catalog do %>
                <% {:ok, %{capacity_known: true} = catalog} -> %>
                  <.kv>
                    <:item title={dgettext("machines", "CPU")}>
                      {dgettext("machines", "%{value1} vCPU", value1: catalog.available.vcpu)}
                    </:item>
                    <:item title={dgettext("machines", "Memory")}>
                      {dgettext("machines", "%{value1} GiB",
                        value1: gib(catalog.available.memory_bytes)
                      )}
                    </:item>
                    <:item title={dgettext("machines", "Disk")}>
                      {dgettext("machines", "%{value1} GiB",
                        value1: gib(catalog.available.disk_bytes)
                      )}
                    </:item>
                  </.kv>
                  <p class="muted">
                    {dgettext("machines", "Capacity is checked again when you create a machine.")}
                  </p>
                <% :loading -> %>
                  <div id="overview-capacity-loading" aria-busy="true"></div>
                <% _ -> %>
                  <p id="overview-capacity-unavailable" class="muted">
                    {dgettext("machines", "Headroom is temporarily unavailable.")}
                  </p>
              <% end %>
            </UI.panel>
            <UI.panel title={dgettext("machines", "Make yourself at home")}>
              <ul class="tree note-list">
                <li>
                  <strong>{dgettext("machines", "Next steps")}</strong>
                  <ul>
                    <li>
                      <.link navigate={~p"/integrations"}>{dgettext(
                        "machines",
                        "Connect an integration ↗"
                      )}</.link>
                    </li>
                    <li>
                      <.link navigate={~p"/teams"}>{dgettext("machines", "Find your people ↗")}</.link>
                    </li>
                    <li>
                      <.link navigate={~p"/usage"}>{dgettext("machines", "Explore your usage ↗")}</.link>
                    </li>
                    <li>
                      <.link href={~p"/docs"}>{dgettext("machines", "Read the field notes ↗")}</.link>
                    </li>
                  </ul>
                </li>
              </ul>
            </UI.panel>
          </div>
        </div>
        <div class="overview-refresh">
          <span>{dgettext("machines", "Updated")}
          <.timestamp at={@updated_at} zone={@time_zone} format={:time} /></span><Layouts.action
            id="overview-refresh"
            tone="ghost"
            phx-click="refresh"
            phx-disable-with={dgettext("machines", "Refreshing…")}
          >
            <.glyph name="refresh" /> {dgettext("machines", "Refresh")}
          </Layouts.action>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
