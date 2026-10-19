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
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_nodes", "Capacity information is temporarily unavailable.")
         )}
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
      {:noreply,
       put_flash(socket, :info, dgettext("admin_nodes", "Admission settings updated."))
       |> refresh(false)}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_nodes", "Admission settings were invalid or the node is not ready.")
         )}
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
      {:noreply, put_flash(socket, :error, dgettext("admin_nodes", "No active campaign."))}
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
      {:noreply, put_flash(socket, :error, dgettext("admin_nodes", "No active campaign."))}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("admin_nodes", "Invalid request."))}

  defp respond(socket, {:ok, _}) do
    {:noreply,
     socket
     |> assign(cursor: nil, request_id: Ash.UUID.generate())
     |> put_flash(:info, dgettext("admin_nodes", "Maintenance updated."))
     |> refresh(false)}
  end

  defp respond(socket, _),
    do:
      {:noreply,
       socket
       |> put_flash(
         :error,
         dgettext(
           "admin_nodes",
           "Could not accept this change. Refresh and check the workload state."
         )
       )
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
          title={dgettext("admin_nodes", "Node maintenance")}
          subtitle={
            dgettext(
              "admin_nodes",
              "Lilly nodes and their admission state. Move a node's workloads before taking its machine out of service."
            )
          }
        />
        <p :if={@unavailable?} role="alert" class="error">
          {dgettext("admin_nodes", "Node information is unavailable.")}
        </p>
        <div :if={is_nil(@host_id)} class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-auto">{dgettext("admin_nodes", "Node")}</th>
                <th class="width-min">{dgettext("admin_nodes", "Maintenance")}</th>
                <th class="width-min">{dgettext("admin_nodes", "Admission")}</th>
                <th class="width-min">{dgettext("admin_nodes", "Report")}</th>
              </tr>
            </thead>
            <tbody id="lilly-node-rows" phx-update="stream">
              <tr :for={{dom_id, node} <- @streams.nodes} id={dom_id}>
                <td class="break">
                  <.link navigate={~p"/admin/nodes/#{node.id}"}>{node.name}</.link>
                </td>
                <td><span class="status-label">{label(node.maintenance_mode)}</span></td>
                <td>
                  {if node.enabled,
                    do: dgettext("admin_nodes", "Enabled"),
                    else: dgettext("admin_nodes", "Excluded")}
                </td>
                <td class="nowrap">
                  <span class="status-label" data-tone={if node.fresh, do: "success", else: "muted"}>
                    {if node.fresh,
                      do: dgettext("admin_nodes", "Fresh"),
                      else: dgettext("admin_nodes", "Stale or unknown")}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@node && @host_id} class="stack">
          <p><.link navigate={~p"/admin/nodes"}>{dgettext("admin_nodes", "← Nodes")}</.link></p>
          <header class="page-heading ident">
            <div>
              <h1>{@node.name}</h1>
              <p>
                {dgettext("admin_nodes", "Lilly node · %{mode} maintenance",
                  mode: label(@node.maintenance_mode)
                )}
              </p>
            </div>
          </header>
          <UI.panel id="node-summary" title={dgettext("admin_nodes", "Node")}>
            <.kv>
              <:item title={dgettext("admin_nodes", "Maintenance")}>
                <span class="status-label">{label(@node.maintenance_mode)}</span>
              </:item>
              <:item title={dgettext("admin_nodes", "Admission")}>
                {if @node.enabled,
                  do: dgettext("admin_nodes", "Enabled"),
                  else: dgettext("admin_nodes", "Excluded")}
              </:item>
              <:item title={dgettext("admin_nodes", "Report")}>
                {if @node.fresh,
                  do: dgettext("admin_nodes", "Fresh report"),
                  else: dgettext("admin_nodes", "Stale or unknown report")}
              </:item>
            </.kv>
            <p id="terminal-stream-health" class="muted">
              {dgettext("admin_nodes", "Terminal protocol: %{protocol} · Local stream: %{state}",
                protocol: Map.get(@node, :terminal_protocol, dgettext("admin_nodes", "Unknown")),
                state:
                  if(@node.terminal_stream_ready,
                    do: dgettext("admin_nodes", "ready"),
                    else: dgettext("admin_nodes", "unavailable")
                  )
              )}
            </p>
            <p class="muted">
              {dgettext(
                "admin_nodes",
                "Evacuation blocks new placements while existing guests remain served. Moving a running guest briefly interrupts it. A full stopped copy can take substantially longer and needs approval for each workload."
              )}
            </p>
            <div class="row actions">
              <button id="preview-evacuation" phx-click="preview" class="console-button">
                {dgettext("admin_nodes", "Preview evacuation")}
              </button>
              <button id="capacity-details" phx-click="capacity" class="console-button">
                {dgettext("admin_nodes", "Explain capacity")}
              </button>
              <button
                :if={
                  @admin_authorized and
                    (is_nil(@campaign) and @node.enabled and @node.maintenance_mode == :normal)
                }
                id="start-evacuation"
                phx-click="evacuate"
                data-confirm={
                  dgettext(
                    "admin_nodes",
                    "Evacuate all workloads on this node? Running guests will be interrupted during their moves. Full stopped copies require separate per-workload approval."
                  )
                }
                class="console-button primary"
              >{dgettext("admin_nodes", "Start evacuation")}</button>
            </div>
          </UI.panel>
          <UI.panel
            :if={@capacity}
            id="capacity-details-panel"
            title={dgettext("admin_nodes", "Capacity explanation")}
          >
            <p class="muted">
              {dgettext(
                "admin_nodes",
                "Read-only admission arithmetic. It does not reserve capacity; unknown measurements withhold admission."
              )}
            </p>
            <.kv>
              <:item title={dgettext("admin_nodes", "Admission")}>
                {if @capacity.admission_enabled,
                  do: dgettext("admin_nodes", "enabled"),
                  else: dgettext("admin_nodes", "excluded")}
              </:item>
              <:item title={dgettext("admin_nodes", "Execution ready")}>
                {if @capacity.execution_ready,
                  do: dgettext("admin_nodes", "yes"),
                  else: dgettext("admin_nodes", "unknown")}
              </:item>
            </.kv>
            <p id="admission-overhead" class="muted">
              {dgettext(
                "admin_nodes",
                "Configured host overhead: %{cores} cores · %{memory} memory. These margins are included in admission arithmetic and remain deployment-controlled.",
                cores: @capacity.host.overhead_cores,
                memory: bytes(@capacity.host.overhead_memory_bytes)
              )}
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
                    <span class="field-label">{dgettext("admin_nodes", "Admission")}</span>
                    <span class="select">
                      <select name="enabled">
                        <option value="true" selected={@capacity.admission_enabled}>
                          {dgettext("admin_nodes", "enabled")}
                        </option>
                        <option value="false" selected={not @capacity.admission_enabled}>
                          {dgettext("admin_nodes", "excluded")}
                        </option>
                      </select>
                    </span>
                  </label>
                </div>
                <div class="field">
                  <label>
                    <span class="field-label">{dgettext("admin_nodes", "CPU overhead (cores)")}</span>
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
                    <span class="field-label">{dgettext("admin_nodes", "RAM overhead (bytes)")}</span>
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
                <button class="console-button primary" type="submit">{dgettext(
                  "admin_nodes",
                  "Apply admission settings"
                )}</button>
              </div>
            </form>
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">{dgettext("admin_nodes", "Pool")}</th>
                    <th class="width-min">{dgettext("admin_nodes", "Report")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "CPU headroom")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "Memory headroom")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "CPU after holds")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "Memory after holds")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "Disk after holds")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "Startup holds")}</th>
                    <th class="width-min num">{dgettext("admin_nodes", "Copy/resize holds")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={pool <- @capacity.pools}>
                    <td><code>{pool.name}</code></td>
                    <td class="muted">
                      {if pool.fresh,
                        do: dgettext("admin_nodes", "Fresh"),
                        else: dgettext("admin_nodes", "Stale or unknown")}
                    </td>
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
          <UI.panel
            :if={@campaign}
            id="evacuation-campaign"
            title={dgettext("admin_nodes", "Evacuation campaign")}
          >
            <:actions>
              <span class="status-label">{label(@campaign.status)}</span>
            </:actions>
            <p class="break muted">
              {dgettext("admin_nodes", "Campaign")} <code>{@campaign.id}</code>
            </p>
            <p class="muted">
              {dgettext(
                "admin_nodes",
                "Pause stops new moves from being scheduled. Accepted moves continue. Maintenance-ready requires confirmed source cleanup; completed jobs alone are insufficient."
              )}
            </p>
            <div class="row actions">
              <button
                :if={@admin_authorized and @campaign.status == :active}
                id="pause-evacuation"
                phx-click="control"
                phx-value-command="pause"
                class="console-button"
              >{dgettext("admin_nodes", "Pause scheduling")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :paused}
                id="continue-evacuation"
                phx-click="control"
                phx-value-command="continue"
                class="console-button"
              >{dgettext("admin_nodes", "Continue scheduling")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :ready}
                id="resume-node"
                phx-click="control"
                phx-value-command="resume"
                class="console-button"
              >{dgettext("admin_nodes", "Restore admission")}</button>
              <button
                :if={@admin_authorized and @campaign.status == :ready}
                id="retire-node"
                phx-click="control"
                phx-value-command="retire"
                data-confirm={
                  dgettext(
                    "admin_nodes",
                    "Permanently retire this empty node and revoke its credentials?"
                  )
                }
                class="console-button danger"
              >{dgettext("admin_nodes", "Retire node")}</button>
            </div>
          </UI.panel>
          <UI.panel
            :if={@timeline != []}
            id="evacuation-timeline"
            title={dgettext("admin_nodes", "Evacuation timeline")}
          >
            <p class="muted">
              {dgettext(
                "admin_nodes",
                "Campaign, workload and relocation milestones from durable control-plane records."
              )}
            </p>
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-min">{dgettext("admin_nodes", "Time")}</th>
                    <th class="width-min">{dgettext("admin_nodes", "Event")}</th>
                    <th class="width-auto">{dgettext("admin_nodes", "Details")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @timeline}>
                    <td><.timestamp at={event.at} zone={@time_zone} format={:datetime_seconds} /></td>
                    <td>{label(event.kind)}</td>
                    <td class="muted break">
                      <span :if={event.vm_id}>{dgettext("admin_nodes", "VM")}
                      <code>{event.vm_id}</code></span>
                      <span :if={event.relocation_id}>{dgettext("admin_nodes", "move")}
                      <code>{event.relocation_id}</code></span>
                      <span :if={event[:campaign_id]}>{dgettext("admin_nodes", "campaign")}
                      <code>{event[:campaign_id]}</code></span>
                      <span :if={event.kind == :job_state}>
                        {dgettext("admin_nodes", "job")} <code>{event.job_id}</code>
                        · {job_state_label(event.state)} · {dgettext(
                          "admin_nodes",
                          "attempt %{attempt}",
                          attempt: event.attempt
                        )}
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
            title={dgettext("admin_nodes", "Campaign history")}
          >
            <div class="table-flow">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">{dgettext("admin_nodes", "Campaign")}</th>
                    <th class="width-min">{dgettext("admin_nodes", "Status")}</th>
                    <th class="width-min">{dgettext("admin_nodes", "Opened")}</th>
                    <th class="width-min">{dgettext("admin_nodes", "Closed")}</th>
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
            {dgettext(
              "admin_nodes",
              "Advisory preview for this page. Each workload is evaluated independently; destinations and available capacity can change. Admission rechecks and reserves resources when each move begins."
            )}
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
                {dgettext("admin_nodes", "Desired: %{desired} · Observed: %{observed}",
                  desired: label(row.desired_state),
                  observed: label(row.observed_state)
                )}
              </p>
              <p :if={row.item && row.item.blocker} class="error">
                {dgettext("admin_nodes", "Blocked: %{reason}", reason: label(row.item.blocker))}
              </p>
              <p :if={row.item && row.item.resolved_at}>
                {dgettext(
                  "admin_nodes",
                  "Removed from this source; awaiting campaign cleanup verification."
                )}
              </p>
              <div :if={row.progress}>
                <p>{dgettext("admin_nodes", "Phase: %{phase}", phase: label(row.progress.phase))}</p>
                <p :if={row.progress.downtime}>
                  {if row.progress.downtime.ongoing,
                    do:
                      dgettext("admin_nodes", "Observed interruption: %{seconds}s (ongoing)",
                        seconds: row.progress.downtime.seconds
                      ),
                    else:
                      dgettext("admin_nodes", "Observed interruption: %{seconds}s",
                        seconds: row.progress.downtime.seconds
                      )}
                </p>
              </div>
              <div :if={row.preview}>
                <p :if={row.preview[:blocker]}>
                  {dgettext("admin_nodes", "Preview: %{blocker}", blocker: label(row.preview.blocker))}
                </p>
                <p :if={row.preview[:destination_name]}>
                  {dgettext("admin_nodes", "Candidate: %{name}", name: row.preview.destination_name)}<span :if={
                    row.preview.downtime_approval_required
                  }>{dgettext("admin_nodes", "· Downtime approval required")}</span>
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
                  data-confirm={
                    dgettext(
                      "admin_nodes",
                      "Stop this running workload for the entire move? Copying its disks and restarting it on the destination can cause prolonged downtime."
                    )
                  }
                  class="console-button"
                >{dgettext("admin_nodes", "Approve move downtime")}</button>
                <span :if={row.item.approved_at} class="muted">{dgettext(
                  "admin_nodes",
                  "Downtime approved for this workload revision"
                )}</span>
                <button
                  :if={@admin_authorized and (is_nil(row.progress) or not row.progress.active)}
                  id={"replan-#{row.item.id}"}
                  phx-click="replan"
                  phx-value-id={row.item.id}
                  phx-value-key={row.item.request_key}
                  data-confirm={
                    dgettext(
                      "admin_nodes",
                      "Re-plan this workload using its current placement and desired state? Any previous downtime approval will be cleared."
                    )
                  }
                  class="console-button"
                >{dgettext("admin_nodes", "Re-plan workload")}</button>
              </div>
            </article>
          </div>
        </div>
        <nav aria-label={dgettext("admin_nodes", "Maintenance pages")} class="row">
          <.link :if={@cursor} patch={page_path(@host_id, nil)}>{dgettext(
            "admin_nodes",
            "← First page"
          )}</.link>
          <.link :if={@next_cursor} patch={page_path(@host_id, @next_cursor)}>{dgettext(
            "admin_nodes",
            "Next page →"
          )}</.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  defp page_path(nil, nil), do: ~p"/admin/nodes"
  defp page_path(nil, cursor), do: ~p"/admin/nodes?#{%{after: cursor}}"
  defp page_path(host, nil), do: ~p"/admin/nodes/#{host}"
  defp page_path(host, cursor), do: ~p"/admin/nodes/#{host}?#{%{after: cursor}}"
  @spec label(term()) :: String.t()
  defp label(value) when value in [:normal, "normal"], do: dgettext("admin_nodes", "Normal")
  defp label(value) when value in [:draining, "draining"], do: dgettext("admin_nodes", "Draining")
  defp label(value) when value in [:drained, "drained"], do: dgettext("admin_nodes", "Drained")

  defp label(value) when value in [:evacuating, "evacuating"],
    do: dgettext("admin_nodes", "Evacuating")

  defp label(value) when value in [:retired, "retired"], do: dgettext("admin_nodes", "Retired")
  defp label(value) when value in [:active, "active"], do: dgettext("admin_nodes", "Active")
  defp label(value) when value in [:paused, "paused"], do: dgettext("admin_nodes", "Paused")
  defp label(value) when value in [:ready, "ready"], do: dgettext("admin_nodes", "Ready")
  defp label(value) when value in [:resumed, "resumed"], do: dgettext("admin_nodes", "Resumed")
  defp label(value) when value in [:running, "running"], do: dgettext("admin_nodes", "Running")
  defp label(value) when value in [:stopped, "stopped"], do: dgettext("admin_nodes", "Stopped")
  defp label(value) when value in [:pending, "pending"], do: dgettext("admin_nodes", "Pending")
  defp label(value) when value in [:failed, "failed"], do: dgettext("admin_nodes", "Failed")
  defp label(value) when value in [:deleted, "deleted"], do: dgettext("admin_nodes", "Deleted")

  defp label(value) when value in [:unavailable, "unavailable"],
    do: dgettext("admin_nodes", "Unavailable")

  defp label(value) when value in [:unknown, "unknown"], do: dgettext("admin_nodes", "Unknown")

  defp label(value) when value in [:preparing, "preparing"],
    do: dgettext("admin_nodes", "Preparing")

  defp label(value) when value in [:checking_transfer, "checking_transfer"],
    do: dgettext("admin_nodes", "Checking transfer connectivity")

  defp label(value) when value in [:stopping_source, "stopping_source"],
    do: dgettext("admin_nodes", "Stopping the source")

  defp label(value) when value in [:copying, "copying"], do: dgettext("admin_nodes", "Copying")

  defp label(value) when value in [:importing, "importing"],
    do: dgettext("admin_nodes", "Importing")

  defp label(value) when value in [:handoff, "handoff"],
    do: dgettext("admin_nodes", "Switching placement")

  defp label(value) when value in [:checking_destination, "checking_destination"],
    do: dgettext("admin_nodes", "Checking destination readiness")

  defp label(value) when value in [:readiness_failed, "readiness_failed"],
    do: dgettext("admin_nodes", "Destination readiness failed; source copy retained")

  defp label(value) when value in [:activation_failed, "activation_failed"],
    do: dgettext("admin_nodes", "Destination boot failed; source copy retained")

  defp label(value) when value in [:retrying_destination, "retrying_destination"],
    do: dgettext("admin_nodes", "Retrying destination boot")

  defp label(value) when value in [:source_cleanup, "source_cleanup"],
    do: dgettext("admin_nodes", "Cleaning up the source")

  defp label(value) when value in [:restoring_source, "restoring_source"],
    do: dgettext("admin_nodes", "Restoring the source")

  defp label(value) when value in [:cancelled_cleanup, "cancelled_cleanup"],
    do: dgettext("admin_nodes", "Cleaning up after cancellation")

  defp label(value) when value in [:deleting_copies, "deleting_copies"],
    do: dgettext("admin_nodes", "Deleting retained copies")

  defp label(value) when value in [:complete, "complete"], do: dgettext("admin_nodes", "Complete")

  defp label(value) when value in [:cancelled, "cancelled"],
    do: dgettext("admin_nodes", "Cancelled")

  defp label(value) when value in [:campaign_requested, "campaign_requested"],
    do: dgettext("admin_nodes", "Campaign requested")

  defp label(value) when value in [:source_ready, "source_ready"],
    do: dgettext("admin_nodes", "Source ready")

  defp label(value) when value in [:campaign_closed, "campaign_closed"],
    do: dgettext("admin_nodes", "Campaign closed")

  defp label(value) when value in [:relocation_committed, "relocation_committed"],
    do: dgettext("admin_nodes", "Relocation committed")

  defp label(value) when value in [:source_restored, "source_restored"],
    do: dgettext("admin_nodes", "Source restored")

  defp label(value) when value in [:source_cleanup_requested, "source_cleanup_requested"],
    do: dgettext("admin_nodes", "Source cleanup requested")

  defp label(value) when value in [:source_cleanup_confirmed, "source_cleanup_confirmed"],
    do: dgettext("admin_nodes", "Source cleanup confirmed")

  defp label(value)
       when value in [:destination_cleanup_requested, "destination_cleanup_requested"],
       do: dgettext("admin_nodes", "Destination cleanup requested")

  defp label(value)
       when value in [:destination_cleanup_confirmed, "destination_cleanup_confirmed"],
       do: dgettext("admin_nodes", "Destination cleanup confirmed")

  defp label(value) when value in [:cancellation_requested, "cancellation_requested"],
    do: dgettext("admin_nodes", "Cancellation requested")

  defp label(value) when value in [:job_state, "job_state"],
    do: dgettext("admin_nodes", "Job state")

  defp label(value) when value in [:workload_observed, "workload_observed"],
    do: dgettext("admin_nodes", "Workload observed")

  defp label(value) when value in [:downtime_approved, "downtime_approved"],
    do: dgettext("admin_nodes", "Downtime approved")

  defp label(value) when value in [:relocation_started, "relocation_started"],
    do: dgettext("admin_nodes", "Relocation started")

  defp label(value) when value in [:workload_resolved, "workload_resolved"],
    do: dgettext("admin_nodes", "Workload resolved")

  defp label(value) when value in [:workload_changed, "workload_changed"],
    do: dgettext("admin_nodes", "Workload changed")

  defp label(value) when value in [:workload_not_stable, "workload_not_stable"],
    do: dgettext("admin_nodes", "Workload is not stable")

  defp label(value) when value in [:source_unavailable, "source_unavailable"],
    do: dgettext("admin_nodes", "Source unavailable")

  defp label(value) when value in [:transfer_busy, "transfer_busy"],
    do: dgettext("admin_nodes", "Transfer busy")

  defp label(value) when value in [:insufficient_capacity, "insufficient_capacity"],
    do: dgettext("admin_nodes", "Insufficient capacity")

  defp label(value) when value in [:downtime_approval_required, "downtime_approval_required"],
    do: dgettext("admin_nodes", "Downtime approval required")

  defp label(value) when value in [:resize_in_progress, "resize_in_progress"],
    do: dgettext("admin_nodes", "Resize in progress")

  defp label(value) when value in [:relocation_in_progress, "relocation_in_progress"],
    do: dgettext("admin_nodes", "Relocation in progress")

  defp label(value) when value in [:clone_in_progress, "clone_in_progress"],
    do: dgettext("admin_nodes", "Clone in progress")

  defp label(_), do: dgettext("admin_nodes", "Unknown")
  defp quantity(nil, _), do: dgettext("admin_nodes", "Unknown")
  defp quantity(value, unit), do: "#{value} #{unit}"
  defp bytes(nil), do: dgettext("admin_nodes", "Unknown")
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

  # @cc [owner:ghuntley,label:product] localized-node-job-states
  # Timeline job state labels MUST match reviewed Oban display meanings without
  # changing the retained job state identifiers or terminal outcome semantics.
  @spec job_state_label(atom() | String.t()) :: String.t()
  defp job_state_label(state) when state in [:available, "available"],
    do: dgettext("admin_nodes", "Queued")

  defp job_state_label(state) when state in [:suspended, "suspended"],
    do: dgettext("admin_nodes", "Suspended")

  defp job_state_label(state) when state in [:scheduled, "scheduled"],
    do: dgettext("admin_nodes", "Scheduled")

  defp job_state_label(state) when state in [:executing, "executing"],
    do: dgettext("admin_nodes", "Running")

  defp job_state_label(state) when state in [:retryable, "retryable"],
    do: dgettext("admin_nodes", "Retrying")

  defp job_state_label(state) when state in [:completed, "completed"],
    do: dgettext("admin_nodes", "Succeeded")

  defp job_state_label(state) when state in [:discarded, "discarded"],
    do: dgettext("admin_nodes", "Failed")

  defp job_state_label(state) when state in [:cancelled, "cancelled"],
    do: dgettext("admin_nodes", "Cancelled")

  defp job_state_label(_), do: dgettext("admin_nodes", "Unknown")
end
