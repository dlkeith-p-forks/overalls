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
      when kind in ["start", "stop", "delete"] do
    case Compute.lifecycle(
           %{
             vm_id: id,
             kind: String.to_existing_atom(kind),
             idempotency_key: Ash.UUID.generate()
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Lifecycle request queued.") |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, lifecycle_refusal(error))}
    end
  end

  def handle_event("relocate", %{"id" => id}, socket) do
    case Compute.relocate(%{vm_id: id, idempotency_key: Ash.UUID.generate()},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Relocation request queued.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Relocation request was rejected.")}
    end
  end

  def handle_event("admin-override", %{"id" => id, "destination" => destination}, socket)
      when destination in ["details", "terminals", "resize"] do
    suffix = %{"details" => "", "terminals" => "/terminals", "resize" => "/resize"}[destination]
    {:noreply, push_navigate(socket, to: "/machines/" <> id <> suffix)}
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  # The owner's pin fences administrator deletes too (ADR-0193); every other
  # refusal keeps the generic text so no coordinator detail leaks.
  @spec lifecycle_refusal(Exception.t()) :: String.t()
  defp lifecycle_refusal(error) do
    if Exception.message(error) =~ "machine_pinned",
      do: "The owner has pinned this machine; it cannot be deleted until they unpin it.",
      else: "Lifecycle request was rejected."
  end

  defp refresh(socket) do
    case Compute.list_vms_for_admin(%{}, actor: socket.assigns.current_user) do
      {:ok, %{items: workloads}} ->
        assign(socket, workloads: workloads, refreshed_at: DateTime.utc_now())

      _ ->
        put_flash(socket, :error, "Workload inventory is temporarily unavailable.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      compute={true}
      active="admin"
      admin_active="workloads"
    >
      <section id="admin-workloads" class="stack">
        <UI.heading
          title="Fleet workloads"
          subtitle="Every machine in the fleet, with the same lifecycle, resize and relocation safety checks as the owner's console. No terminal data or credentials are included."
        >
          <:actions>
            <span class="muted">Updated {stamp(@refreshed_at)} · every 15 seconds</span>
          </:actions>
        </UI.heading>
        <p :if={@workloads == []} class="empty-state">No active workloads.</p>
        <div :if={@workloads != []} class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-auto">Workload</th>
                <th class="width-min">Host</th>
                <th class="width-min">Shape</th>
                <th class="width-min">State</th>
                <th :if={@admin_authorized} class="width-min">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={vm <- @workloads} id={"admin-workload-#{vm.id}"}>
                <td class="break">
                  <strong>{vm.name}</strong><br />
                  <span class="muted">{vm.owner_email}</span><br />
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
                      Details
                    </Layouts.action>
                    <Layouts.action
                      id={"terminals-#{vm.id}"}
                      phx-click="admin-override"
                      phx-value-id={vm.id}
                      phx-value-destination="terminals"
                    >
                      Terminal
                    </Layouts.action>
                    <Layouts.action
                      id={"resize-#{vm.id}"}
                      phx-click="admin-override"
                      phx-value-id={vm.id}
                      phx-value-destination="resize"
                    >
                      Resize
                    </Layouts.action>
                  </div>
                  <div class="row">
                    <Layouts.action
                      :if={vm.desired_state == :stopped}
                      id={"start-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="start"
                    >
                      Start
                    </Layouts.action>
                    <Layouts.action
                      :if={vm.desired_state == :running}
                      id={"stop-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="stop"
                    >
                      Stop
                    </Layouts.action>
                    <Layouts.action id={"relocate-#{vm.id}"} phx-click="relocate" phx-value-id={vm.id}>
                      Move
                    </Layouts.action>
                    <Layouts.action
                      tone="danger"
                      id={"delete-#{vm.id}"}
                      phx-click="lifecycle"
                      phx-value-id={vm.id}
                      phx-value-kind="delete"
                      data-confirm="Archive this VM?"
                    >
                      Delete
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

  @spec stamp(DateTime.t() | nil) :: String.t()
  defp stamp(nil), do: "—"
  defp stamp(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
end
