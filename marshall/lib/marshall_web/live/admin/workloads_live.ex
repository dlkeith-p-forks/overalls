defmodule MarshallWeb.Admin.WorkloadsLive do
  use MarshallWeb, :live_view

  alias Marshall.Compute

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 15_000)
    {:ok, socket |> assign(workloads: [], refreshed_at: nil) |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 15_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("lifecycle", %{"id" => id, "kind" => kind}, socket)
      when kind in ["start", "stop", "pause", "resume", "delete"] do
    case Compute.lifecycle(
           %{
             vm_id: id,
             kind: String.to_existing_atom(kind),
             idempotency_key: Ash.UUID.generate()
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Lifecycle request queued.")) |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, lifecycle_refusal(error))}
    end
  end

  def handle_event("relocate", %{"id" => id}, socket) do
    case Compute.relocate(%{vm_id: id, idempotency_key: Ash.UUID.generate()},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Relocation request queued.")) |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Relocation request was rejected."))}
    end
  end

  def handle_event("admin-override", %{"id" => id, "destination" => destination}, socket)
      when destination in ["details", "terminals", "resize"] do
    suffix = %{"details" => "", "terminals" => "/terminals", "resize" => "/resize"}[destination]
    {:noreply, push_navigate(socket, to: "/machines/" <> id <> suffix)}
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Invalid request."))}

  # The owner's pin fences administrator deletes too (ADR-0193); every other
  # refusal keeps the generic text so no coordinator detail leaks.
  @spec lifecycle_refusal(Exception.t()) :: String.t()
  defp lifecycle_refusal(error) do
    if Exception.message(error) =~ "machine_pinned",
      do: gettext("The owner has pinned this machine; it cannot be deleted until they unpin it."),
      else: gettext("Lifecycle request was rejected.")
  end

  defp refresh(socket) do
    case Compute.list_vms_for_admin(%{}, actor: socket.assigns.current_user) do
      {:ok, %{items: workloads}} ->
        assign(socket, workloads: workloads, refreshed_at: DateTime.utc_now())

      _ ->
        put_flash(socket, :error, gettext("Workload inventory is temporarily unavailable."))
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
      admin_active="workloads"
    >
      <section id="admin-workloads" class="stack">
        <UI.heading
          title={gettext("Fleet workloads")}
          subtitle={
            gettext(
              "Every machine in the fleet, with the same lifecycle, resize and relocation safety checks as the owner's console. No terminal data or credentials are included."
            )
          }
        >
          <:actions>
            <span class="muted">{gettext("Updated")}
            <.timestamp at={@refreshed_at} zone={@time_zone} format={:datetime_seconds} />
            {gettext("· every 15 seconds")}</span>
          </:actions>
        </UI.heading>
        <p :if={@workloads == []} class="empty-state">{gettext("No active workloads.")}</p>
        <div :if={@workloads != []} class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-auto">{gettext("Workload")}</th>
                <th class="width-min">{gettext("Host")}</th>
                <th class="width-min">{gettext("Shape")}</th>
                <th class="width-min">{gettext("State")}</th>
                <th :if={@admin_authorized} class="width-min">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={vm <- @workloads} id={"admin-workload-#{vm.id}"}>
                <td class="break">
                  <strong>{vm.name}</strong><br />
                  <.person
                    id={"admin-workload-#{vm.id}-owner"}
                    email={vm.owner_email}
                    time_zone={vm.owner_time_zone}
                    viewer_zone={@time_zone}
                    now={@now}
                    class="muted"
                  /><br />
                  <code class="muted">{vm.id}</code>
                </td>
                <td><code title={vm.host_id}>{short(vm.host_id)}</code></td>
                <td class="nowrap">{vm.vcpu} vCPU · {gib(vm.memory_bytes)} GiB</td>
                <td class="nowrap">
                  <span class="status-label" data-state={vm.observed_state}>{vm.observed_state}</span>
                  <span :if={vm.desired_state != vm.observed_state} class="muted">
                    → {vm.desired_state}
                  </span>
                </td>
                <td :if={@admin_authorized} class="actions-cell">
                  <div class="row">
                    <Layouts.action
                      id={"details-#{vm.id}"}
                      phx-click="admin-override"
                      phx-value-id={vm.id}
                      phx-value-destination="details"
                    >
                      {gettext("Details")}
                    </Layouts.action>
                    <Layouts.action
                      id={"terminals-#{vm.id}"}
                      phx-click="admin-override"
                      phx-value-id={vm.id}
                      phx-value-destination="terminals"
                    >
                      {gettext("Terminal")}
                    </Layouts.action>
                    <Layouts.action
                      id={"resize-#{vm.id}"}
                      phx-click="admin-override"
                      phx-value-id={vm.id}
                      phx-value-destination="resize"
                    >
                      {gettext("Resize")}
                    </Layouts.action>
                  </div>
                  <div class="row">
                    <Layouts.action
                      :if={vm.desired_state == :paused || vm.observed_state == :paused}
                      id={"resume-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="resume"
                    >
                      Resume
                    </Layouts.action>
                    <Layouts.action
                      :if={vm.desired_state == :running && vm.observed_state == :running}
                      id={"pause-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="pause"
                    >
                      Pause
                    </Layouts.action>
                    <Layouts.action
                      :if={vm.desired_state == :stopped}
                      id={"start-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="start"
                    >
                      {gettext("Start")}
                    </Layouts.action>
                    <Layouts.action
                      :if={vm.desired_state == :running}
                      id={"stop-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="stop"
                    >
                      {gettext("Stop")}
                    </Layouts.action>
                    <Layouts.action id={"relocate-#{vm.id}"} phx-click="relocate" phx-value-id={vm.id}>
                      {gettext("Move")}
                    </Layouts.action>
                    <Layouts.action
                      tone="danger"
                      id={"delete-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="delete"
                      data-confirm={gettext("Archive this VM?")}
                    >
                      {gettext("Delete")}
                    </Layouts.action>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp gib(value), do: Float.round(value / 1_073_741_824, 1)
  @spec short(String.t() | nil) :: String.t()
  defp short(nil), do: "unplaced"
  defp short(id), do: String.slice(to_string(id), 0, 8)
end
