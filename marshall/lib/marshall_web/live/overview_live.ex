defmodule MarshallWeb.OverviewLive do
  @moduledoc "A bounded, actor-authorized starting point for the Overalls workspace."
  use MarshallWeb, :live_view
  alias Marshall.Compute
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

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
    {:ok, socket |> assign(page_title: gettext("Overview"), visible: true) |> refresh()}
  end

  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}

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

  @spec refresh(socket()) :: socket()
  defp refresh(socket) do
    actor = socket.assigns.current_user
    machines = read(fn -> preview(actor) end)
    catalog = read(fn -> Compute.catalog(%{}, actor: actor) end)

    assign(socket,
      machines: machines,
      catalog: catalog,
      updated_at: DateTime.utc_now()
    )
  end

  # Pinned machines take the first slots; the keyset page fills the rest. When
  # every slot is pinned, one excluded row only tells whether more exist.
  @spec preview(Marshall.Accounts.User.t()) :: {:ok, preview()} | {:error, term()}
  defp preview(actor) do
    with {:ok, %{items: pinned}} <- Compute.pinned_vms(%{}, actor: actor),
         shown = Enum.take(pinned, @preview),
         {:ok, page} <-
           Compute.list_vms(
             %{limit: max(@preview - length(shown), 1), exclude: Enum.map(pinned, & &1.id)},
             actor: actor
           ) do
      full? = length(shown) == @preview

      {:ok,
       %{
         items: shown ++ if(full?, do: [], else: page.items),
         more:
           length(pinned) > @preview or page.next_cursor != nil or (full? and page.items != [])
       }}
    end
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
          title={gettext("A good day to make something.")}
          subtitle={gettext("Your workspace, with a little room to breathe.")}
        >
          <:actions>
            <.link id="overview-create" navigate={~p"/machines/new"} class="console-button primary">
              {gettext("+ Create machine")}
            </.link>
          </:actions>
        </UI.heading>
        <div class="overview-grid">
          <UI.panel id="overview-machines" title={gettext("Your machines")}>
            <:actions><.link navigate={~p"/machines"}>{gettext("View all →")}</.link></:actions>
            <%= case @machines do %>
              <% {:ok, page} -> %>
                <UI.empty
                  :if={page.items == []}
                  id="overview-machines-empty"
                  title={gettext("Room for your next idea")}
                >
                  {gettext(
                    "No machines in this preview yet. Create one or ask an owner to share access."
                  )}
                  <:action>
                    <.link navigate={~p"/machines/new"} class="console-button ghost">{gettext(
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
                        {vm.vcpu} vCPU · {gib(vm.memory_bytes)} GiB memory · {gib(vm.disk_bytes)} GiB disk · {if vm.owner,
                          do: gettext("Personal"),
                          else: gettext("Shared")}
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
                      >{gettext("Open terminal ↗")}</.link>
                      <UI.machine_editor_action vm={vm} id_prefix="overview-machine" variant={:link} />
                      <UI.pin_toggle vm={vm} id={"pin-#{vm.id}"} />
                    </div>
                  </article>
                </div>
                <p :if={page.more} class="muted">
                  {gettext("A small preview. All your accessible machines are in")} <.link navigate={
                    ~p"/machines"
                  }>{gettext("Machines")}</.link>.
                </p>
              <% :unavailable -> %>
                <p id="overview-machines-unavailable" role="status">
                  {gettext("Machines couldn’t be loaded. Refresh to try again.")}
                </p>
            <% end %>
          </UI.panel>
          <div class="overview-side">
            <UI.panel
              id="overview-marvin-extension"
              title={gettext("Open repositories from your browser")}
              data-overalls-extension-setup="true"
            >
              <p class="muted">
                {gettext(
                  "Bring a GitHub, GitLab, Codeberg or Bitbucket repository into Overalls with the Chrome or Firefox extension."
                )}
              </p>
              <.link
                id="overview-marvin-extension-link"
                href={~p"/docs/browser-extension"}
                class="console-button ghost"
              >{gettext("Set up the browser extension ↗")}</.link>
            </UI.panel>
            <UI.panel id="overview-capacity" title={gettext("Room to grow")}>
              <p class="muted">{gettext("Current provisioning headroom")}</p>
              <%= case @catalog do %>
                <% {:ok, %{capacity_known: true} = catalog} -> %>
                  <.kv>
                    <:item title={gettext("CPU")}>
                      {gettext("%{value1} vCPU", value1: catalog.available.vcpu)}
                    </:item>
                    <:item title={gettext("Memory")}>
                      {gettext("%{value1} GiB", value1: gib(catalog.available.memory_bytes))}
                    </:item>
                    <:item title={gettext("Disk")}>
                      {gettext("%{value1} GiB", value1: gib(catalog.available.disk_bytes))}
                    </:item>
                  </.kv>
                  <p class="muted">
                    {gettext("Capacity is checked again when you create a machine.")}
                  </p>
                <% _ -> %>
                  <p id="overview-capacity-unavailable" class="muted">
                    {gettext("Headroom is temporarily unavailable.")}
                  </p>
              <% end %>
            </UI.panel>
            <UI.panel title={gettext("Make yourself at home")}>
              <ul class="tree note-list">
                <li>
                  <strong>{gettext("Next steps")}</strong>
                  <ul>
                    <li>
                      <.link navigate={~p"/integrations"}>{gettext("Connect an integration ↗")}</.link>
                    </li>
                    <li><.link navigate={~p"/teams"}>{gettext("Find your people ↗")}</.link></li>
                    <li><.link navigate={~p"/usage"}>{gettext("Explore your usage ↗")}</.link></li>
                    <li><.link href={~p"/docs"}>{gettext("Read the field notes ↗")}</.link></li>
                  </ul>
                </li>
              </ul>
            </UI.panel>
          </div>
        </div>
        <div class="overview-refresh">
          <span>{gettext("Updated")} <.timestamp at={@updated_at} zone={@time_zone} format={:time} /></span><Layouts.action
            id="overview-refresh"
            tone="ghost"
            phx-click="refresh"
            phx-disable-with={gettext("Refreshing…")}
          >
            <.glyph name="refresh" /> {gettext("Refresh")}
          </Layouts.action>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
