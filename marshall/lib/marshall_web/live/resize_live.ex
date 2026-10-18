defmodule MarshallWeb.ResizeLive do
  use MarshallWeb, :live_view
  alias Marshall.Compute
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount MarshallWeb.MachineWorkspace
  alias MarshallWeb.MachineWorkspace
  @draft ~w(vcpu memory_mib disk_gib expected_generation request_key)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 1000)
    {:ok, assign(socket, vm: nil, form: nil, page_title: "Resize machine")}
  end

  # @cc [owner:ghuntley,label:product;security] resize-draft-is-not-authority
  # Allowed URL draft fields MUST survive validation, polling and reload without
  # updating the expected generation. Every submission MUST use current domain
  # authorization; revoked management permission removes the form and progress.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = socket |> assign(:vm_id, params["id"]) |> refresh()

    if socket.assigns.vm do
      vm = socket.assigns.vm

      defaults = %{
        "vcpu" => to_string(vm.vcpu),
        "memory_mib" => to_string(div(vm.memory_bytes, 1_048_576)),
        "disk_gib" => disk_gib(vm.disk_bytes),
        "expected_generation" => to_string(vm.generation),
        "request_key" => Ash.UUID.generate()
      }

      values = Map.merge(defaults, draft(params["resize"]))

      form =
        if vm.resize != nil and params["resize"] == nil,
          do: nil,
          else: to_form(values, as: :resize)

      socket = assign(socket, form: form)

      if connected?(socket) and params["resize"] == nil and vm.resize == nil,
        do:
          {:noreply,
           push_patch(socket,
             to: ~p"/machines/#{vm.id}/resize?#{%{resize: values}}",
             replace: true
           )},
        else: {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 1000)
    socket = refresh(socket)

    if socket.assigns.vm != nil and socket.assigns.vm.resize == nil and socket.assigns.form == nil do
      {:noreply,
       push_patch(socket, to: ~p"/machines/#{socket.assigns.vm_id}/resize", replace: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"resize" => params}, socket) do
    previous = if socket.assigns.form, do: socket.assigns.form.params, else: %{}
    values = Map.merge(previous, draft(params))

    {:noreply,
     push_patch(socket,
       to: ~p"/machines/#{socket.assigns.vm_id}/resize?#{%{resize: values}}",
       replace: true
     )}
  end

  # @cc [owner:ghuntley,label:product;security] resize-stale-draft-explicit-refresh
  # Only an explicit review action may renew a retained draft's generation/key.
  # It MUST keep size inputs and cannot itself request physical work. After an
  # accepted resize, completion MUST prefill a new form from confirmed resources.
  def handle_event("refresh_request", _, socket) do
    socket = refresh(socket)

    if socket.assigns.vm != nil and socket.assigns.vm.resize == nil and socket.assigns.form != nil do
      values =
        socket.assigns.form.params
        |> Map.put("expected_generation", to_string(socket.assigns.vm.generation))
        |> Map.put("request_key", Ash.UUID.generate())

      {:noreply,
       push_patch(socket,
         to: ~p"/machines/#{socket.assigns.vm_id}/resize?#{%{resize: values}}",
         replace: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resize", %{"resize" => params}, socket) do
    socket = assign(socket, form: to_form(draft(params), as: :resize))

    with {cpu, ""} <- integer(params["vcpu"]),
         {memory, ""} <- integer(params["memory_mib"]),
         {:ok, disk} <- disk_bytes(params["disk_gib"]),
         {generation, ""} <- integer(params["expected_generation"]),
         {:ok, _} <-
           Compute.resize(
             %{
               vm_id: socket.assigns.vm_id,
               vcpu: cpu,
               memory_bytes: memory * 1_048_576,
               disk_bytes: disk,
               expected_generation: generation,
               idempotency_key: params["request_key"]
             },
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Resize requested.")
       |> push_patch(to: ~p"/machines/#{socket.assigns.vm_id}/resize", replace: true)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Resize could not be accepted. Check the sizes and current machine state."
         )
         |> refresh()}
    end
  end

  def handle_event("cancel", _, socket) do
    socket = refresh(socket)

    case socket.assigns.vm do
      %{resize: %{id: id}} = vm ->
        case Compute.cancel_resize(%{vm_id: vm.id, request_id: id},
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Resize cancelled.") |> refresh()}

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cancel could not be accepted. Sizes are already being applied or the machine state is unconfirmed."
             )}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("retry", _, socket) do
    socket = refresh(socket)

    case socket.assigns.vm do
      %{resize: %{id: id}} = vm ->
        case Compute.retry_resize(
               %{vm_id: vm.id, request_id: id, expected_generation: vm.generation},
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            {:noreply, refresh(socket)}

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Retry could not be accepted. Capacity or machine state may have changed."
             )}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp refresh(socket) do
    case Compute.get_vm(%{vm_id: socket.assigns.vm_id}, actor: socket.assigns.current_user) do
      {:ok, %{permissions: %{manage: true}, desired_state: state} = vm} when state != :deleted ->
        MachineWorkspace.put_vm(socket, vm)

      _ ->
        assign(socket,
          admin_access_expired: MachineWorkspace.administrative_access_expired?(socket, :manage),
          vm: nil,
          machine_connection: nil
        )
    end
  end

  defp draft(params) when is_map(params) do
    params
    |> Map.take(@draft)
    |> Map.filter(fn {_, v} -> is_binary(v) and byte_size(v) <= 128 end)
  end

  defp draft(_), do: %{}
  defp integer(value) when is_binary(value), do: Integer.parse(value)
  defp integer(_), do: :error

  # @cc [owner:ghuntley,label:product] resize-draft-exact-disk-units
  # Confirmed, pending and draft GiB values MUST round-trip every 4096-byte-aligned
  # disk without floating point rounding or truncation. Fractional bytes must be rejected.
  defp disk_gib(bytes) do
    whole = to_string(div(bytes, 1_073_741_824))
    fraction = div(rem(bytes, 1_073_741_824) * 1_000_000_000_000_000_000, 1_073_741_824)

    if fraction == 0 do
      whole
    else
      whole <>
        "." <>
        (fraction |> to_string() |> String.pad_leading(18, "0") |> String.trim_trailing("0"))
    end
  end

  defp disk_bytes(value) when is_binary(value) and byte_size(value) <= 24 do
    if Regex.match?(~r/\A[0-9]{1,5}(?:\.[0-9]{1,18})?\z/, value) do
      [whole | fractional] = String.split(value, ".")
      fraction = List.first(fractional) || ""
      denominator = Integer.pow(10, byte_size(fraction))
      numerator = String.to_integer(whole <> fraction) * 1_073_741_824
      if rem(numerator, denominator) == 0, do: {:ok, div(numerator, denominator)}, else: :error
    else
      :error
    end
  end

  defp disk_bytes(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      compute={true}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
    >
      <div class="stack">
        <UI.machine_header
          :if={@vm}
          vm={@vm}
          connection={@machine_connection}
          power_key={@machine_power_key}
          active="settings"
        />
        <p><.link navigate={~p"/machines/#{@vm_id}/settings"}>← Settings</.link></p>
        <div :if={@vm == nil} id="resize-unavailable" class="panel">
          <%= if @admin_access_expired do %>
            <p>
              Administrative verification expired. Your resize draft is kept in this page's address.
            </p>
            <p>
              <.link id="admin-access-recovery" navigate={~p"/admin/workloads"}>
                Return to Fleet workloads and verify your passkey to reopen the machine →
              </.link>
            </p>
          <% else %>
            This machine is unavailable or you no longer have management access.
          <% end %>
        </div>
        <div :if={@vm} class="stack">
          <UI.heading
            title="Resize machine"
            subtitle="CPU and memory can increase or decrease. Disk size can only grow."
          />
          <UI.panel id="confirmed-resources" title="Confirmed resources">
            <.kv>
              <:item title="CPU">{@vm.vcpu} CPU</:item>
              <:item title="Memory">{div(@vm.memory_bytes, 1_048_576)} MiB</:item>
              <:item title="Disk">{disk_gib(@vm.disk_bytes)} GiB</:item>
              <:item title="Power">
                {if @vm.desired_state == :running, do: "Running", else: "Stopped"}
              </:item>
            </.kv>
          </UI.panel>
          <section
            :if={@vm.resize}
            id="resize-progress"
            class="panel"
            data-tone={if @vm.resize.failure, do: "warning", else: "working"}
            aria-labelledby="resize-progress-heading"
          >
            <header>
              <h2 id="resize-progress-heading">Resize in progress</h2>
              <span class="status-label" data-tone={if @vm.resize.failure, do: "warning", else: nil}>
                {if @vm.resize.failure, do: "Needs attention", else: phase_label(@vm.resize.phase)}
              </span>
            </header>
            <div class="panel-body">
              <p>{phase_detail(@vm.resize)}</p>
              <ol class="steps" aria-label="Resize stages">
                <li
                  :for={{label, state} <- resize_steps(@vm.resize)}
                  data-state={state}
                  aria-current={state == :current && "step"}
                >
                  <span class="step-marker" aria-hidden="true"></span>
                  <span>{label}<span class="sr-only"> — {state}</span></span>
                </li>
              </ol>
              <.kv id="pending-resources">
                <:item title="CPU">
                  {@vm.resize.original_sizes["vcpu"]} → {@vm.resize.target_sizes["vcpu"]} CPU
                </:item>
                <:item title="Memory">
                  {div(@vm.resize.original_sizes["memory_bytes"], 1_048_576)} → {div(
                    @vm.resize.target_sizes["memory_bytes"],
                    1_048_576
                  )} MiB
                </:item>
                <:item title="Disk">
                  {disk_gib(@vm.resize.original_sizes["disk_bytes"])} → {disk_gib(
                    @vm.resize.target_sizes["disk_bytes"]
                  )} GiB
                </:item>
                <:item title="Power afterwards">
                  {if @vm.resize.original_power_state == :running,
                    do: "Restarted",
                    else: "Remains stopped; the filesystem grows on the next boot"}
                </:item>
              </.kv>
              <p :if={@vm.resize.failure} id="resize-failure" class="error">
                Resize needs attention. Confirmed disk growth is retained. Retry resumes the recorded phase.
              </p>
              <div :if={@vm.resize.failure || cancellable?(@vm.resize)} class="row actions">
                <button
                  :if={@vm.resize.failure}
                  id="retry-resize"
                  phx-click="retry"
                  class="console-button primary"
                >
                  Retry resize
                </button>
                <button
                  :if={cancellable?(@vm.resize)}
                  id="cancel-resize"
                  phx-click="cancel"
                  class="console-button"
                >
                  Cancel resize
                </button>
              </div>
            </div>
          </section>
          <.form
            :if={@vm.resize == nil && @form}
            for={@form}
            id="resize-form"
            phx-change="validate"
            phx-submit="resize"
            class="panel stack"
          >
            <h2>New sizes</h2>
            <div
              :if={@form.params["expected_generation"] != to_string(@vm.generation)}
              id="resize-stale-draft"
              class="panel dashed"
            >
              <p>
                The machine has changed since this draft was created. Review the confirmed resources above.
              </p>
              <button
                id="refresh-resize-request"
                type="button"
                phx-click="refresh_request"
                class="console-button compact"
              >Use current machine state, keeping these sizes</button>
            </div>
            <.input field={@form[:request_key]} type="hidden" />
            <.input field={@form[:expected_generation]} type="hidden" />
            <div class="grid">
              <.input field={@form[:vcpu]} type="number" label="CPU" min="1" max="32" required />
              <.input
                field={@form[:memory_mib]}
                type="number"
                label="Memory (MiB)"
                min="512"
                max="262144"
                step="1"
                required
              />
              <.input
                field={@form[:disk_gib]}
                type="number"
                label="Disk (GiB) — Maximum 500 GiB"
                min={disk_gib(@vm.disk_bytes)}
                max={OverallsProtocol.VMShape.maximum_disk_gib()}
                step="any"
                required
              />
            </div>
            <.kv id="resize-preview">
              <:item title="CPU">{@vm.vcpu} → {@form.params["vcpu"]} CPU</:item>
              <:item title="Memory">
                {div(@vm.memory_bytes, 1_048_576)} → {@form.params["memory_mib"]} MiB
              </:item>
              <:item title="Disk">{disk_gib(@vm.disk_bytes)} → {@form.params["disk_gib"]} GiB</:item>
            </.kv>
            <ol class="steps" aria-label="What happens">
              <li :for={label <- planned_steps(@vm)} data-state="pending">
                <span class="step-marker" aria-hidden="true"></span>
                <span>{label}</span>
              </li>
            </ol>
            <p class="muted">
              {if @vm.desired_state == :running,
                do: "Your machine will stop while resources change, then restart. Expect downtime.",
                else:
                  "Your machine will remain stopped. Disk filesystem growth completes on its next boot."}
            </p>
            <button
              id="submit-resize"
              type="submit"
              phx-disable-with="Requesting resize…"
              class="console-button primary"
            >
              {if @vm.desired_state == :running, do: "Resize and restart", else: "Resize machine"}
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @phases [:stopping, :resizing, :restarting, :complete]

  # Cancel is offered only before any size is applied: while stopping, unless
  # the stop's physical state is unconfirmed (retry is then the only path).
  @spec cancellable?(map()) :: boolean()
  defp cancellable?(%{phase: :stopping, failure: nil}), do: true
  defp cancellable?(_), do: false

  @spec phase_label(atom()) :: String.t()
  defp phase_label(:stopping), do: "Stopping"
  defp phase_label(:resizing), do: "Resizing"
  defp phase_label(:restarting), do: "Restarting"
  defp phase_label(:fencing), do: "Restarting"
  defp phase_label(:complete), do: "Complete"
  defp phase_label(:cancelling), do: "Cancelling"
  defp phase_label(:cancelled), do: "Cancelled"
  defp phase_label(other), do: other |> to_string() |> String.capitalize()

  @spec phase_detail(map()) :: String.t()
  defp phase_detail(%{failure: failure}) when is_binary(failure),
    do:
      "The last step did not finish. Retry resumes from the recorded phase without repeating completed work."

  defp phase_detail(%{phase: :stopping}),
    do: "Stopping the machine so its resources can change safely."

  defp phase_detail(%{phase: :cancelling, original_power_state: :running}),
    do: "Cancelling: waiting for the stop to confirm, then restarting with the current sizes."

  defp phase_detail(%{phase: :cancelling}),
    do: "Cancelling: waiting for the stop to confirm; the sizes stay unchanged."

  defp phase_detail(%{phase: :resizing}),
    do: "Applying the new CPU, memory and disk sizes on the host."

  defp phase_detail(%{phase: phase}) when phase in [:restarting, :fencing],
    do: "Starting the machine with its new resources."

  defp phase_detail(_),
    do: "The resize has completed; this page refreshes with the confirmed sizes."

  # Stage ladder from the persisted phase; failure never fabricates completed stages.
  @spec resize_steps(map()) :: [{String.t(), :done | :current | :pending}]
  defp resize_steps(%{phase: :cancelling, original_power_state: power}) do
    restart = if power == :running, do: "Restart unchanged", else: "Leave stopped"
    [{"Stop", :current}, {restart, :pending}, {"Cancelled", :pending}]
  end

  defp resize_steps(%{phase: :restarting, cancelled_at: at, original_power_state: power})
       when not is_nil(at) do
    restart = if power == :running, do: "Restart unchanged", else: "Leave stopped"
    [{"Stop", :done}, {restart, :current}, {"Cancelled", :pending}]
  end

  defp resize_steps(%{phase: phase, original_power_state: power}) do
    current =
      Enum.find_index(@phases, &(&1 == if(phase == :fencing, do: :restarting, else: phase))) || 0

    restart = if power == :running, do: "Restart", else: "Leave stopped"

    ["Stop", "Resize", restart, "Confirm"]
    |> Enum.with_index()
    |> Enum.map(fn {label, index} ->
      {label,
       cond do
         index < current -> :done
         index == current -> :current
         true -> :pending
       end}
    end)
  end

  @spec planned_steps(map()) :: [String.t()]
  defp planned_steps(%{desired_state: :running}),
    do: ["Stop the machine", "Apply the new sizes", "Restart with the new resources", "Confirm"]

  defp planned_steps(_),
    do: ["Apply the new sizes while stopped", "Grow the filesystem on next boot", "Confirm"]
end
