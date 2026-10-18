defmodule MarshallWeb.Admin.LillyNodesLive do
  use MarshallWeb, :live_view
  alias Marshall.Compute
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 15_000)

    {:ok,
     assign(socket,
       host_id: nil,
       cursor: nil,
       next_cursor: nil,
       node: nil,
       proxy: %{},
       campaign: nil,
       unavailable?: false,
       preview?: false,
       capacity: nil,
       timeline: [],
       campaign_history: [],
       loaded_at: nil,
       request_id: Ash.UUID.generate()
     )
     |> stream(:nodes, [])
     |> stream(:workloads, [])}
  end

  @impl true
  def handle_params(params, _, socket) do
    if Enum.all?([params["id"], params["after"]], &(is_nil(&1) or OverallsProtocol.uuid?(&1))) do
      {:noreply,
       socket
       |> assign(host_id: params["id"], cursor: params["after"], loaded_at: nil)
       |> refresh(false)}
    else
      {:noreply, push_navigate(socket, to: ~p"/admin/nodes")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 15_000)

    if socket.assigns.host_id || is_nil(socket.assigns.loaded_at) ||
         System.monotonic_time(:second) - socket.assigns.loaded_at >= 60,
       do: {:noreply, refresh(socket, false)},
       else: {:noreply, socket}
  end

  @impl true
  def handle_event("preview", _, socket), do: {:noreply, refresh(socket, true)}

  def handle_event("capacity", _, socket) do
    case Compute.admin_node_capacity(%{host_id: socket.assigns.host_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, capacity} ->
        {:noreply, assign(socket, :capacity, capacity)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Capacity information is temporarily unavailable."))}
    end
  end

  def handle_event("configure", params, socket) do
    with {:ok, cores} <- nonnegative(params["overhead_cores"]),
         {:ok, memory} <- nonnegative(params["overhead_memory_bytes"]),
         enabled when enabled in [true, false] <- parse_boolean(params["enabled"]),
         {:ok, _} <-
           Compute.admin_configure_host(
             %{
               host_id: socket.assigns.host_id,
               enabled: enabled,
               overhead_cores: cores,
               overhead_memory_bytes: memory
             },
             actor: socket.assigns.current_user
           ) do
      {:noreply, put_flash(socket, :info, gettext("Admission settings updated.")) |> refresh(false)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Admission settings were invalid or the node is not ready."))}
    end
  end

  def handle_event("evacuate", _, socket) do
    result =
      Compute.request_evacuation(
        %{host_id: socket.assigns.host_id, request_id: socket.assigns.request_id},
        actor: socket.assigns.current_user
      )

    respond(socket, result)
  end

  def handle_event("control", %{"command" => command}, socket)
      when command in ~w(pause continue resume retire) do
    commands = %{
      "pause" => :pause,
      "continue" => :continue,
      "resume" => :resume,
      "retire" => :retire
    }

    if socket.assigns.campaign do
      respond(
        socket,
        Compute.control_evacuation(%{id: socket.assigns.campaign.id, command: commands[command]},
          actor: socket.assigns.current_user
        )
      )
    else
      {:noreply, put_flash(socket, :error, gettext("No active campaign."))}
    end
  end

  def handle_event(action, %{"id" => id, "key" => key}, socket)
      when action in ~w(approve replan) do
    if socket.assigns.campaign do
      args = %{id: socket.assigns.campaign.id, item_id: id, expected_key: key}

      result =
        if action == "approve",
          do: Compute.approve_evacuation_downtime(args, actor: socket.assigns.current_user),
          else: Compute.replan_evacuation_workload(args, actor: socket.assigns.current_user)

      respond(socket, result)
    else
      {:noreply, put_flash(socket, :error, gettext("No active campaign."))}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, gettext("Invalid request."))}

  defp respond(socket, {:ok, _}) do
    {:noreply,
     socket
     |> assign(cursor: nil, request_id: Ash.UUID.generate())
     |> put_flash(:info, gettext("Maintenance updated."))
     |> refresh(false)}
  end

  defp respond(socket, _),
    do:
      {:noreply,
       socket
       |> put_flash(:error, gettext("Could not accept this change. Refresh and check the workload state."))
       |> refresh(false)}

  # @cc [owner:ghuntley,label:capacity;product] maintenance-view-read-cadence
  # Node inventory MUST refresh at most once per minute without navigation;
  # campaign pages at most every fifteen seconds. Preview MUST require an explicit
  # event and clear on ordinary refresh. Never display bytes as a completion percent.
  defp refresh(%{assigns: %{host_id: nil}} = socket, _) do
    case Compute.admin_nodes(%{after: socket.assigns.cursor}, actor: socket.assigns.current_user) do
      {:ok, page} ->
        socket
        |> assign(
          next_cursor: page.next_cursor,
          loaded_at: System.monotonic_time(:second),
          unavailable?: false
        )
        |> stream(:nodes, page.items, reset: true)

      _ ->
        socket |> assign(unavailable?: true, next_cursor: nil) |> stream(:nodes, [], reset: true)
    end
  end

  defp refresh(socket, preview) do
    case Compute.admin_node(
           %{host_id: socket.assigns.host_id, after: socket.assigns.cursor, preview: preview},
           actor: socket.assigns.current_user
         ) do
      {:ok, page} ->
        socket
        |> assign(
          node: page.host,
          campaign: page.campaign,
          timeline: page.timeline || [],
          campaign_history: page.campaign_history || [],
          next_cursor: page.next_cursor,
          preview?: preview,
          capacity: nil,
          unavailable?: false
        )
        |> stream(:workloads, page.items, reset: true)

      _ ->
        socket
        |> assign(
          node: nil,
          campaign: nil,
          capacity: nil,
          campaign_history: [],
          unavailable?: true,
          next_cursor: nil,
          preview?: false
        )
        |> stream(:workloads, [], reset: true)
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
      admin_active="nodes"
    >
      <section id="admin-lilly-nodes" class="stack">
        <UI.heading
          :if={is_nil(@host_id)}
          title={gettext("Node maintenance")}
          subtitle={gettext("Lilly nodes and their admission state. Move a node's workloads before taking its machine out of service.")}
        />
        <p :if={@unavailable?} role="alert" class="error">{gettext("Node information is unavailable.")}</p>
        <div :if={is_nil(@host_id)} class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-auto">{gettext("Node")}</th>
                <th class="width-min">{gettext("Maintenance")}</th>
                <th class="width-min">{gettext("Admission")}</th>
                <th class="width-min">{gettext("Report")}</th>
              </tr>
            </thead>
            <tbody id="lilly-node-rows" phx-update="stream">
              <tr :for={{dom_id, node} <- @streams.nodes} id={dom_id}>
                <td class="break">
                  <.link navigate={~p"/admin/nodes/#{node.id}"}>{node.name}</.link>
                </td>
                <td><span class="status-label">{label(node.maintenance_mode)}</span></td>
                <td>{if node.enabled, do: gettext("Enabled"), else: gettext("Excluded")}</td>
                <td class="nowrap">
                  <span class="status-label" data-tone={if node.fresh, do: "success", else: "muted"}>
                    {if node.fresh, do: gettext("Fresh"), else: gettext("Stale or unknown")}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@node && @host_id} class="stack">
          <p><.link navigate={~p"/admin/nodes"}>{gettext("← Nodes")}</.link></p>
          <header class="page-heading ident">
            <div>
              <h1>{@node.name}</h1>
              <p>{gettext("Lilly node · %{mode} maintenance", mode: label(@node.maintenance_mode))}</p>
            </div>
          </header>
          <UI.panel id="node-summary" title={gettext("Node")}>
            <.kv>
              <:item title={gettext("Maintenance")}>
                <span class="status-label">{label(@node.maintenance_mode)}</span>
              </:item>
              <:item title={gettext("Admission")}>{if @node.enabled, do: gettext("Enabled"), else: gettext("Excluded")}</:item>
              <:item title={gettext("Report")}>
                {if @node.fresh, do: gettext("Fresh report"), else: gettext("Stale or unknown report")}
              </:item>
            </.kv>
            <p id="terminal-stream-health" class="muted">
              {gettext("Terminal protocol: %{protocol} · Local stream: %{state}", protocol: Map.get(@node, :terminal_protocol, gettext("Unknown")), state: if(@node.terminal_stream_ready, do: gettext("ready"), else: gettext("unavailable")))}
            </p>
            <p class="muted">
              {gettext("Evacuation blocks new placements while existing guests remain served. Moving a running guest briefly interrupts it. A full stopped copy can take substantially longer and needs approval for each workload.")}
            </p>
            <div class="row actions">
              <button id="preview-evacuation" phx-click="preview" class="console-button">
                {gettext("Preview evacuation")}
              </button>
              <button id="capacity-details" phx-click="capacity" class="console-button">
                {gettext("Explain capacity")}
              </button>
              <button
                :if={
                  @admin_authorized and
                    (is_nil(@campaign) and @node.enabled and @node.maintenance_mode == :normal)
                }
                id="start-evacuation"
                phx-click="evacuate"
                data-confirm={gettext("Evacuate all workloads on this node? Running guests will be interrupted during their moves. Full stopped copies require separate per-workload approval.")}
                class="console-button primary"
              >{gettext("Start evacuation")}</button>
            </div>
          </UI.panel>
          <UI.panel :if={@capacity} id="capacity-details-panel" title={gettext("Capacity explanation")}>
            <p class="muted">
              {gettext("Read-only admission arithmetic. It does not reserve capacity; unknown measurements withhold admission.")}
            </p>
            <.kv>
              <:item title={gettext("Admission")}>
                {if @capacity.admission_enabled, do: "enabled", else: "excluded"}
              </:item>
              <:item title={gettext("Execution ready")}>
                {if @capacity.execution_ready, do: gettext("yes"), else: gettext("unknown")}
              </:item>
            </.kv>
            <p id="admission-overhead" class="muted">
              Configured host overhead: {@capacity.host.overhead_cores} cores · {bytes(
                @capacity.host.overhead_memory_bytes
              )} memory. These margins are included in admission arithmetic and remain deployment-controlled.
            </p>
            <form
              :if={@admin_authorized}
              id="admission-settings"
              phx-submit="configure"
              class="stack"
            >
              <div class="grid">
                <div class="field">
                  <label>
                    <span class="field-label">{gettext("Admission")}</span>
                    <span class="select">
                      <select name="enabled">
                        <option value="true" selected={@capacity.admission_enabled}>{gettext("enabled")}</option>
                        <option value="false" selected={not @capacity.admission_enabled}>
                          {gettext("excluded")}
                        </option>
                      </select>
                    </span>
                  </label>
                </div>
                <div class="field">
                  <label>
                    <span class="field-label">{gettext("CPU overhead (cores)")}</span>
                    <input
                      name="overhead_cores"
                      type="number"
                      min="0"
                      value={@capacity.host.overhead_cores}
                    />
                  </label>
                </div>
                <div class="field">
                  <label>
                    <span class="field-label">{gettext("RAM overhead (bytes)")}</span>
                    <input
                      name="overhead_memory_bytes"
                      type="number"
                      min="0"
                      value={@capacity.host.overhead_memory_bytes}
                    />
                  </label>
                </div>
              </div>
              <div class="row actions">
                <button class="console-button primary" type="submit">{gettext("Apply admission settings")}</button>
              </div>
            </form>
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">{gettext("Pool")}</th>
                    <th class="width-min">{gettext("Report")}</th>
                    <th class="width-min num">{gettext("CPU headroom")}</th>
                    <th class="width-min num">{gettext("Memory headroom")}</th>
                    <th class="width-min num">{gettext("CPU after holds")}</th>
                    <th class="width-min num">{gettext("Memory after holds")}</th>
                    <th class="width-min num">{gettext("Disk after holds")}</th>
                    <th class="width-min num">{gettext("Startup holds")}</th>
                    <th class="width-min num">{gettext("Copy/resize holds")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={pool <- @capacity.pools}>
                    <td><code>{pool.name}</code></td>
                    <td class="muted">{if pool.fresh, do: gettext("Fresh"), else: gettext("Stale or unknown")}</td>
                    <td class="num">
                      {quantity(pool.budget.measured_cpu_headroom_millicores, "mCPU")}
                    </td>
                    <td class="num">{bytes(pool.budget.measured_memory_headroom_bytes)}</td>
                    <td class="num">{quantity(pool.budget.available.vcpu, "cores")}</td>
                    <td class="num">{bytes(pool.budget.available.memory_bytes)}</td>
                    <td class="num">{bytes(pool.budget.available.disk_bytes)}</td>
                    <td class="num">
                      {quantity(pool.budget.startup_compute.vcpu, "cores")} / {bytes(
                        pool.budget.startup_compute.memory_bytes
                      )}
                    </td>
                    <td class="num">{bytes(pool.budget.disk.pending_bytes)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </UI.panel>
          <UI.panel :if={@campaign} id="evacuation-campaign" title={gettext("Evacuation campaign")}>
            <:actions>
              <span class="status-label">{label(@campaign.status)}</span>
            </:actions>
            <p class="break muted">{gettext("Campaign")} <code>{@campaign.id}</code></p>
            <p class="muted">
              {gettext("Pause stops new moves from being scheduled. Accepted moves continue. Maintenance-ready requires confirmed source cleanup; completed jobs alone are insufficient.")}
            </p>
            <div class="row actions">
              <button
                :if={@admin_authorized and @campaign.status == :active}
                id="pause-evacuation"
                phx-click="control"
                phx-value-command="pause"
                class="console-button"
              >{gettext("Pause scheduling")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :paused}
                id="continue-evacuation"
                phx-click="control"
                phx-value-command="continue"
                class="console-button"
              >{gettext("Continue scheduling")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :ready}
                id="resume-node"
                phx-click="control"
                phx-value-command="resume"
                class="console-button"
              >{gettext("Restore admission")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :ready}
                id="retire-node"
                phx-click="control"
                phx-value-command="retire"
                data-confirm={gettext("Permanently retire this empty node and revoke its credentials?")}
                class="console-button danger"
              >{gettext("Retire node")}</button>
            </div>
          </UI.panel>
          <UI.panel :if={@timeline != []} id="evacuation-timeline" title={gettext("Evacuation timeline")}>
            <p class="muted">
              {gettext("Campaign, workload and relocation milestones from durable control-plane records.")}
            </p>
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-min">{gettext("Time")}</th>
                    <th class="width-min">{gettext("Event")}</th>
                    <th class="width-auto">{gettext("Details")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @timeline}>
                    <td><.timestamp at={event.at} zone={@time_zone} format={:datetime_seconds} /></td>
                    <td>{label(event.kind)}</td>
                    <td class="muted break">
                      <span :if={event.vm_id}>{gettext("VM")} <code>{event.vm_id}</code></span>
                      <span :if={event.relocation_id}>{gettext("move")} <code>{event.relocation_id}</code></span>
                      <span :if={event[:campaign_id]}>{gettext("campaign")} <code>{event[:campaign_id]}</code></span>
                      <span :if={event.kind == :job_state}>
                        {gettext("job")} <code>{event.job_id}</code> · {event.state} · {gettext("attempt %{attempt}", attempt: event.attempt)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </UI.panel>
          <UI.panel
            :if={@campaign_history != []}
            id="evacuation-campaign-history"
            title={gettext("Campaign history")}
          >
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">{gettext("Campaign")}</th>
                    <th class="width-min">{gettext("Status")}</th>
                    <th class="width-min">{gettext("Opened")}</th>
                    <th class="width-min">{gettext("Closed")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={campaign <- @campaign_history}>
                    <td class="break"><code>{campaign.id}</code></td>
                    <td>{label(campaign.status)}</td>
                    <td class="muted">
                      <.timestamp
                        at={campaign.inserted_at}
                        zone={@time_zone}
                        format={:datetime_seconds}
                      />
                    </td>
                    <td class="muted">
                      <.timestamp
                        at={campaign.closed_at}
                        zone={@time_zone}
                        format={:datetime_seconds}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </UI.panel>
          <p :if={@preview?} id="evacuation-preview-note" class="panel dashed">
            {gettext("Advisory preview for this page. Each workload is evaluated independently; destinations and available capacity can change. Admission rechecks and reserves resources when each move begins.")}
          </p>
          <div id="evacuation-workloads" phx-update="stream" class="stack">
            <article :for={{dom_id, row} <- @streams.workloads} id={dom_id} class="panel">
              <header>
                <h3>{row.name}</h3>
                <span class="status-label" data-state={row.observed_state}>
                  {label(row.observed_state)}
                </span>
              </header>
              <p class="muted">
                Desired: {label(row.desired_state)} · Observed: {label(row.observed_state)}
              </p>
              <p :if={row.item && row.item.blocker} class="error">
                Blocked: {label(row.item.blocker)}
              </p>
              <p :if={row.item && row.item.resolved_at}>
                {gettext("Removed from this source; awaiting campaign cleanup verification.")}
              </p>
              <div :if={row.progress}>
                <p>{gettext("Phase: %{phase}", phase: label(row.progress.phase))}</p>
                <p :if={row.progress.downtime}>
                  Observed interruption: {row.progress.downtime.seconds}s {if row.progress.downtime.ongoing,
                    do: "(ongoing)",
                    else: ""}
                </p>
              </div>
              <div :if={row.preview}>
                <p :if={row.preview[:blocker]}>{gettext("Preview: %{blocker}", blocker: label(row.preview.blocker))}</p>
                <p :if={row.preview[:destination_name]}>
                  Candidate: {row.preview.destination_name}<span :if={
                    row.preview.downtime_approval_required
                  }> {gettext("· Downtime approval required")}</span>
                </p>
              </div>
              <div :if={row.item && is_nil(row.item.resolved_at)} class="row actions">
                <button
                  :if={
                    @admin_authorized and
                      (is_nil(row.progress) and row.item.original_state == :running and
                         is_nil(row.item.approved_at))
                  }
                  id={"approve-#{row.item.id}"}
                  phx-click="approve"
                  phx-value-id={row.item.id}
                  phx-value-key={row.item.request_key}
                  data-confirm={gettext("Stop this running workload for the entire move? Copying its disks and restarting it on the destination can cause prolonged downtime.")}
                  class="console-button"
                >{gettext("Approve move downtime")}</button>
                <span :if={row.item.approved_at} class="muted">{gettext("Downtime approved for this workload revision")}</span>
                <button
                  :if={@admin_authorized and (is_nil(row.progress) or not row.progress.active)}
                  id={"replan-#{row.item.id}"}
                  phx-click="replan"
                  phx-value-id={row.item.id}
                  phx-value-key={row.item.request_key}
                  data-confirm={gettext("Re-plan this workload using its current placement and desired state? Any previous downtime approval will be cleared.")}
                  class="console-button"
                >{gettext("Re-plan workload")}</button>
              </div>
            </article>
          </div>
        </div>
        <nav aria-label={gettext("Maintenance pages")} class="row">
          <.link :if={@cursor} patch={page_path(@host_id, nil)}>{gettext("← First page")}</.link>
          <.link :if={@next_cursor} patch={page_path(@host_id, @next_cursor)}>{gettext("Next page →")}</.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  defp page_path(nil, nil), do: ~p"/admin/nodes"
  defp page_path(nil, cursor), do: ~p"/admin/nodes?#{%{after: cursor}}"
  defp page_path(host, nil), do: ~p"/admin/nodes/#{host}"
  defp page_path(host, cursor), do: ~p"/admin/nodes/#{host}?#{%{after: cursor}}"
  defp label(nil), do: gettext("Unknown")
  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp quantity(nil, _), do: gettext("Unknown")
  defp quantity(value, unit), do: "#{value} #{unit}"
  defp bytes(nil), do: gettext("Unknown")
  defp bytes(value), do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  defp nonnegative(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp nonnegative(_), do: :error
  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean(_), do: :invalid
end
