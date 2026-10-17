defmodule MarshallWeb.OverviewLive do
  @moduledoc "A bounded, actor-authorized starting point for the Overalls workspace."
  use MarshallWeb, :live_view
  alias Marshall.Compute
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @type socket :: Phoenix.LiveView.Socket.t()
  # @cc [owner:ghuntley,label:security;product] overview-bounded-authorized-panels
  # Overview MUST request a machine page with limit six through the current actor's
  # domain action. Failed panels MUST remain unavailable, not become zero-valued
  # measurements. Refresh replaces all displayed data.
  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 60_000)
    {:ok, socket |> assign(page_title: "Overview", visible: true) |> refresh()}
  end

  @impl true
  @spec handle_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}

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
    machines = read(fn -> Compute.list_vms(%{limit: 6}, actor: actor) end)
    catalog = read(fn -> Compute.catalog(%{}, actor: actor) end)

    assign(socket,
      machines: machines,
      catalog: catalog,
      updated_at: Calendar.strftime(DateTime.utc_now(), "%H:%M UTC")
    )
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

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      compute={true}
      active="overview"
    >
      <section id="overview" phx-hook="DashboardVisibility">
        <UI.heading
          title="A good day to make something."
          subtitle="Your workspace, with a little room to breathe."
        >
          <:actions>
            <.link id="overview-create" navigate={~p"/machines/new"} class="console-button primary">
              + Create machine
            </.link>
          </:actions>
        </UI.heading>
        <div class="overview-grid">
          <UI.panel id="overview-machines" title="Your machines">
            <:actions><.link navigate={~p"/machines"}>View all →</.link></:actions>
            <%= case @machines do %>
              <% {:ok, page} -> %>
                <UI.empty
                  :if={page.items == []}
                  id="overview-machines-empty"
                  title="Room for your next idea"
                >
                  No machines in this preview yet. Create one or ask an owner to share access.
                  <:action>
                    <.link navigate={~p"/machines/new"} class="console-button ghost">Create your first machine</.link>
                  </:action>
                </UI.empty>
                <div id="overview-machine-preview">
                  <article
                    :for={vm <- page.items}
                    id={"overview-machine-#{vm.id}"}
                    class="preview-machine"
                  >
                    <div>
                      <.link navigate={~p"/machines/#{vm.id}"} class="machine-name">{vm.name}</.link><p>
                        {vm.vcpu} vCPU · {gib(vm.memory_bytes)} GiB memory · {if vm.owner,
                          do: "Personal",
                          else: "Shared"}
                      </p>
                    </div>
                    <span class="status-label" data-state={vm.observed_state}>{UI.machine_state(vm)}</span>
                    <div class="preview-links">
                      <.link
                        :if={vm.desired_state == :running && vm.observed_state == :running}
                        navigate={~p"/machines/#{vm.id}/terminals"}
                        id={"overview-terminal-#{vm.id}"}
                      >Open terminal ↗</.link>
                      <UI.machine_editor_action vm={vm} id_prefix="overview-machine" variant={:link} />
                    </div>
                  </article>
                </div>
                <p :if={page.next_cursor} class="muted">
                  A small preview. All your accessible machines are in <.link navigate={~p"/machines"}>Machines</.link>.
                </p>
              <% :unavailable -> %>
                <p id="overview-machines-unavailable" role="status">
                  Machines couldn’t be loaded. Refresh to try again.
                </p>
            <% end %>
          </UI.panel>
          <div class="overview-side">
            <UI.panel id="overview-browser-extension" title="Open repositories from your browser">
              <p class="muted">
                Bring a GitHub, GitLab, Codeberg or Bitbucket repository into Overalls
                with the Chrome or Firefox extension.
              </p>
              <.link
                id="overview-browser-extension-link"
                href={~p"/docs/browser-extension"}
                class="console-button ghost"
              >Set up the browser extension ↗</.link>
            </UI.panel>
            <UI.panel id="overview-capacity" title="Room to grow">
              <p class="muted">Current provisioning headroom</p>
              <%= case @catalog do %>
                <% {:ok, %{capacity_known: true} = catalog} -> %>
                  <.kv>
                    <:item title="CPU">{catalog.available.vcpu} vCPU</:item>
                    <:item title="Memory">{gib(catalog.available.memory_bytes)} GiB</:item>
                    <:item title="Disk">{gib(catalog.available.disk_bytes)} GiB</:item>
                  </.kv>
                  <p class="muted">Capacity is checked again when you create a machine.</p>
                <% _ -> %>
                  <p id="overview-capacity-unavailable" class="muted">
                    Headroom is temporarily unavailable.
                  </p>
              <% end %>
            </UI.panel>
            <UI.panel title="Make yourself at home">
              <ul class="tree note-list">
                <li>
                  <strong>Next steps</strong>
                  <ul>
                    <li><.link navigate={~p"/integrations"}>Connect an integration ↗</.link></li>
                    <li><.link navigate={~p"/teams"}>Find your people ↗</.link></li>
                    <li><.link navigate={~p"/usage"}>Explore your usage ↗</.link></li>
                    <li><.link href={~p"/docs"}>Read the field notes ↗</.link></li>
                  </ul>
                </li>
              </ul>
            </UI.panel>
          </div>
        </div>
        <div class="overview-refresh">
          <span>Updated {@updated_at}</span><Layouts.action
            id="overview-refresh"
            tone="ghost"
            phx-click="refresh"
            phx-disable-with="Refreshing…"
          >
            <.glyph name="refresh" /> Refresh
          </Layouts.action>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
