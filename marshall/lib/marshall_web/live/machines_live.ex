defmodule MarshallWeb.MachinesLive do
  use MarshallWeb, :live_view
  alias Marshall.{Access, Compute, Teams}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount MarshallWeb.MachineWorkspace
  alias MarshallWeb.{MachineDefaults, MachineWorkspace}
  alias MarshallWeb.CloneComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 1000)

    {:ok,
     socket
     |> assign(
       vm: nil,
       clone_form: to_form(%{"name" => "", "request_key" => Ash.UUID.generate()}, as: :clone),
       clones_empty: true,
       clones_available: true,
       clone_announcement: "",
       catalog_available: false,
       provisioning_teams: [],
       cursor: nil,
       next_cursor: nil,
       grant_cursor: nil,
       grant_next: nil,
       grant_owner: nil,
       grants_empty: false,
       empty: true,
       catalog: %{
         images: [],
         capacity_known: false,
         available: %{vcpu: 0, memory_bytes: 0, disk_bytes: 0}
       },
       relocation_key: Ash.UUID.generate(),
       relocation_retry_key: Ash.UUID.generate(),
       lifecycle_key: Ash.UUID.generate()
     )
     |> new_form()
     |> share_form()
     |> stream(:machines, [])
     |> stream(:grants, [])
     |> stream(:clones, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :resources}} = socket) do
    # Resources now live on the Settings page; keep old links working.
    {:noreply, push_navigate(socket, to: ~p"/machines/#{id}/settings")}
  end

  def handle_params(params, _uri, socket) do
    cursor = valid_cursor(params["after"])
    socket = socket |> assign(vm_id: params["id"], cursor: cursor) |> refresh()

    socket =
      if socket.assigns.live_action == :settings do
        values =
          Map.merge(
            socket.assigns.clone_form.params,
            Map.take(params["clone"] || %{}, ["name", "request_key"])
          )

        socket = assign(socket, clone_form: to_form(values, as: :clone))

        if connected?(socket) and
             get_in(params, ["clone", "request_key"]) != values["request_key"] do
          push_patch(socket,
            to: ~p"/machines/#{params["id"]}/settings?#{%{clone: values}}",
            replace: true
          )
        else
          socket
        end
      else
        socket
      end

    if socket.assigns.live_action == :new do
      profile =
        creation_params(params["machine"])["profile"] || socket.assigns.form.params["profile"]

      values =
        socket.assigns.form.params
        |> Map.put_new(
          "image_id",
          MachineDefaults.default_image(profile, socket.assigns.catalog.images)
        )
        |> Map.merge(creation_params(params["machine"]))
        |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

      socket = assign(socket, form: to_form(values, as: :machine), page_title: "Create machine")

      if connected?(socket) and
           creation_params(params["machine"])["request_key"] != values["request_key"] do
        {:noreply, push_patch(socket, to: ~p"/machines/new?#{%{machine: values}}", replace: true)}
      else
        {:noreply, socket}
      end
    else
      {:noreply,
       assign(socket,
         page_title: if(socket.assigns.vm, do: socket.assigns.vm.name, else: "Machines")
       )}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 1000)
    {:noreply, refresh(socket)}
  end

  # @cc [owner:ghuntley,label:security] provision-through-admission
  # provision MUST parse complete integer resource inputs and pass the request
  # key plus current actor to Compute.provision. Displayed capacity and HTML
  # input limits MUST NOT replace transactional domain admission.
  @impl true
  def handle_event("provision", %{"machine" => %{} = params}, socket) do
    params = MachineDefaults.creation_defaults(params, socket.assigns.catalog.images)
    socket = assign(socket, form: to_form(params, as: :machine))

    with {memory, ""} <- integer(params["memory_mib"]),
         {disk, ""} <- integer(params["disk_gib"]),
         {vcpu, ""} <- integer(params["vcpu"]),
         {:ok, vm} <-
           Compute.provision(
             %{
               idempotency_key: params["request_key"],
               architecture: :x86_64,
               image_id: params["image_id"],
               profile: params["profile"],
               team_id: blank_to_nil(params["team_id"]),
               vcpu: vcpu,
               memory_bytes: memory * 1_048_576,
               disk_bytes: disk * 1_073_741_824
             },
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Machine requested.")
       |> push_navigate(to: ~p"/machines/#{vm.id}")}
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Enter whole numbers for CPU, memory and disk size.")}
    end
  end

  # @cc [owner:ghuntley,label:product] creation-draft-retention
  # Draft changes MUST preserve the request identity and all allowed resource
  # fields through validation, periodic refresh and browser reload. URL values
  # MUST NOT bypass authenticated transactional admission. An explicit profile
  # selection into or out of Inception resets its image and size defaults, and an
  # explicit image change resets the size defaults to that image's minima;
  # subsequent size edits MUST remain intact.
  def handle_event("validate", %{"machine" => params}, socket) do
    previous = socket.assigns.form.params
    values = Map.merge(previous, creation_params(params))

    values =
      cond do
        values["profile"] != previous["profile"] and
            "inception" in [values["profile"], previous["profile"]] ->
          values
          |> Map.drop(~w(image_id vcpu memory_mib disk_gib))
          |> Map.put(
            "image_id",
            MachineDefaults.default_image(values["profile"], socket.assigns.catalog.images)
          )
          |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

        values["image_id"] != previous["image_id"] ->
          values
          |> Map.drop(~w(vcpu memory_mib disk_gib))
          |> MachineDefaults.creation_defaults(socket.assigns.catalog.images)

        true ->
          values
      end

    {:noreply, push_patch(socket, to: ~p"/machines/new?#{%{machine: values}}", replace: true)}
  end

  # @cc [owner:ghuntley,label:security] lifecycle-current-actor
  # lifecycle MUST send the server-selected VM, request key and current actor to
  # Compute.lifecycle even when the UI showed management permission previously.
  def handle_event("lifecycle", %{"kind" => kind, "key" => key}, socket) do
    case Compute.lifecycle(%{vm_id: socket.assigns.vm_id, kind: kind, idempotency_key: key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(lifecycle_key: Ash.UUID.generate())
         |> put_flash(:info, "Machine update requested.")
         |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] clone-form-durable-request-identity
  # Clone submission MUST use the current actor and the form's retained key.
  # Duplicate events MUST reuse that key; a new intentional submission receives
  # a new key. Refresh and validation MUST NOT change a pending submission's key.
  def handle_event("clone-validate", %{"clone" => params}, socket) do
    values =
      Map.merge(socket.assigns.clone_form.params, Map.take(params, ["name", "request_key"]))

    {:noreply,
     push_patch(socket,
       to: ~p"/machines/#{socket.assigns.vm_id}/settings?#{%{clone: values}}",
       replace: true
     )}
  end

  def handle_event("clone", %{"clone" => params}, socket) do
    name = if params["name"] in [nil, ""], do: nil, else: params["name"]

    case Compute.clone(
           %{vm_id: socket.assigns.vm_id, name: name, idempotency_key: params["request_key"]},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        values = %{"name" => "", "request_key" => Ash.UUID.generate()}

        {:noreply,
         socket
         |> put_flash(:info, "Clone queued. You can queue another copy.")
         |> refresh()
         |> push_patch(
           to: ~p"/machines/#{socket.assigns.vm_id}/settings?#{%{clone: values}}",
           replace: true
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["clone-retry", "clone-cancel"] do
    action = if event == "clone-retry", do: :retry_clone, else: :cancel_clone

    case apply(Compute, action, [%{request_id: id}, [actor: socket.assigns.current_user]]) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # @cc [owner:ghuntley,label:security] relocation-controls-current-domain-authority
  # Relocate, Cancel and Retry MUST invoke authorized Compute actions with the current
  # actor. The server selects the VM and displayed relocation; client flags MUST
  # NOT grant permission or select a destination. Retain admission keys on errors.
  def handle_event("relocate", _, socket) do
    case Compute.relocate(
           %{vm_id: socket.assigns.vm_id, idempotency_key: socket.assigns.relocation_key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(relocation_key: Ash.UUID.generate())
         |> put_flash(:info, "Relocation requested. A destination is selected automatically.")
         |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("cancel-relocation", _, socket) do
    relocation = socket.assigns.vm && socket.assigns.vm.relocation

    if relocation do
      case Compute.cancel_relocation(%{relocation_id: relocation.id},
             actor: socket.assigns.current_user
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Cancellation requested. Cleanup may continue after recovery.")
           |> refresh()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, "No relocation is available.")}
    end
  end

  def handle_event("retry-relocation", _, socket) do
    relocation = socket.assigns.vm && socket.assigns.vm.relocation

    if relocation do
      case Compute.retry_relocation(
             %{
               relocation_id: relocation.id,
               idempotency_key: socket.assigns.relocation_retry_key
             },
             actor: socket.assigns.current_user
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(relocation_retry_key: Ash.UUID.generate())
           |> put_flash(
             :info,
             "Destination restart requested. The source copy remains retained until readiness succeeds."
           )
           |> refresh()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, "No relocation is available.")}
    end
  end

  # @cc [owner:ghuntley,label:security] sharing-through-authorized-domain
  # share MUST delegate recipient resolution, role validation and current VM
  # management permission to Access.set_access with the current actor and key.
  # Browser form fields MUST NOT be treated as trusted account or grant records.
  def handle_event("share", %{"access" => %{} = params}, socket) do
    case Access.set_access(
           %{
             vm_id: socket.assigns.vm_id,
             email: params["email"],
             role: params["role"],
             idempotency_key: params["request_key"]
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> share_form() |> put_flash(:info, "Access updated.") |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # The shared MachineWorkspace hook takes this event on detail pages, where the
  # header shows the toggle; the list page reaches here and re-reads its rows so
  # the pinned section and the keyset page stay disjoint (ADR-0193).
  def handle_event("pin", %{"id" => id, "pinned" => pinned}, socket)
      when is_binary(id) and is_binary(pinned) do
    {:noreply, socket |> MachineWorkspace.toggle_pin(id, pinned == "true") |> refresh()}
  end

  def handle_event("grants_next", _, socket),
    do: {:noreply, socket |> assign(grant_cursor: socket.assigns.grant_next) |> refresh()}

  def handle_event("grants_first", _, socket),
    do: {:noreply, socket |> assign(grant_cursor: nil) |> refresh()}

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp integer(value) when is_binary(value) and byte_size(value) <= 12, do: Integer.parse(value)
  defp integer(_), do: :error

  defp creation_params(params) when is_map(params) do
    params
    |> Map.take(~w(image_id profile vcpu memory_mib disk_gib request_key team_id))
    |> Enum.filter(fn {key, value} ->
      is_binary(value) and byte_size(value) <= 128 and
        (key != "request_key" or OverallsProtocol.uuid?(value)) and
        (key != "team_id" or value == "" or OverallsProtocol.uuid?(value))
    end)
    |> Map.new()
  end

  defp creation_params(_), do: %{}

  defp refresh(%{assigns: %{live_action: :new}} = socket) do
    actor = socket.assigns.current_user

    case {Compute.catalog(%{}, actor: actor), Teams.list_teams(%{limit: 100}, actor: actor)} do
      {{:ok, catalog}, {:ok, teams}} ->
        teams = Enum.filter(teams, &(&1.role in [:owner, :admin]))
        assign(socket, catalog: catalog, catalog_available: true, provisioning_teams: teams)

      _ ->
        assign(socket, catalog_available: false)
    end
  end

  # @cc [owner:ghuntley,label:product] machines-pinned-first
  # The list page MUST read the caller's pinned section first and exclude those
  # ids from every keyset page, so a pinned machine appears once, before the
  # unpinned rows, and only on the first page. Later pages MUST keep the same
  # exclusion so paging neither repeats nor skips a machine.
  defp refresh(%{assigns: %{live_action: :index}} = socket) do
    actor = socket.assigns.current_user

    with {:ok, %{items: pinned}} <- Compute.pinned_vms(%{}, actor: actor),
         {:ok, page} <-
           Compute.list_vms(
             %{after: socket.assigns.cursor, exclude: Enum.map(pinned, & &1.id)},
             actor: actor
           ),
         {:ok, catalog} <- Compute.catalog(%{}, actor: actor) do
      items = if(socket.assigns.cursor, do: [], else: pinned) ++ page.items

      socket
      |> assign(
        catalog: catalog,
        catalog_available: true,
        next_cursor: page.next_cursor,
        empty: items == []
      )
      |> stream(:machines, items, reset: true)
    else
      _ ->
        socket
        |> assign(catalog_available: false)
        |> put_flash(:error, "Machines are temporarily unavailable.")
    end
  end

  # @cc [owner:ghuntley,label:security] refresh-removes-revoked-views
  # Detail refresh MUST refetch current VM access and redirect when it fails.
  # Grant details MUST be cleared when management permission disappears, the VM
  # is deleted, or the authorized grant query fails.
  defp refresh(socket) do
    case Compute.get_vm(%{vm_id: socket.assigns.vm_id}, actor: socket.assigns.current_user) do
      {:ok, vm} ->
        socket = MachineWorkspace.put_vm(socket, vm)

        socket =
          case socket.assigns.live_action == :settings && vm.permissions.manage &&
                 Compute.list_clones(%{vm_id: vm.id}, actor: socket.assigns.current_user) do
            {:ok, %{requests: requests}} ->
              socket
              |> assign(
                clones_empty: requests == [],
                clones_available: true,
                clone_announcement: CloneComponents.announcement(requests)
              )
              |> stream(:clones, requests, reset: true)

            _ ->
              socket
              |> assign(clones_empty: true, clones_available: false, clone_announcement: "")
              |> stream(:clones, [], reset: true)
          end

        if socket.assigns.live_action == :access and vm.permissions.manage and
             vm.desired_state != :deleted do
          case Access.list_grants(%{vm_id: vm.id, after: socket.assigns.grant_cursor},
                 actor: socket.assigns.current_user
               ) do
            {:ok, page} ->
              socket
              |> assign(
                grant_owner: page.owner,
                grant_next: page.next_cursor,
                grants_empty: page.items == []
              )
              |> stream(:grants, page.items, reset: true)

            _ ->
              socket
              |> assign(grant_owner: nil, grant_next: nil, grants_empty: false)
              |> stream(:grants, [], reset: true)
          end
        else
          socket
          |> assign(grant_owner: nil, grant_next: nil, grants_empty: false)
          |> stream(:grants, [], reset: true)
        end

      _ ->
        MachineWorkspace.return_after_access_loss(socket, :read)
    end
  end

  # @cc [owner:ghuntley,label:product;security] browser-new-default-profile
  # A fresh machine form MUST select OSS. Explicit Customer and other supported
  # selections MUST survive draft changes, reloads and submission.
  defp new_form(socket),
    do:
      assign(socket,
        form:
          to_form(
            %{
              "profile" => "oss",
              "team_id" => "",
              "request_key" => Ash.UUID.generate()
            },
            as: :machine
          )
      )

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp profile_options(images) do
    ordinary = [{"Customer", "customer"}, {"Standard", "standard"}, {"OSS", "oss"}]

    if Enum.any?(images, &(&1.id == Marshall.Compute.Profiles.inception_image_id())),
      do: ordinary ++ [{"Inception", "inception"}],
      else: ordinary
  end

  @spec profile_description(String.t()) :: String.t()
  defp profile_description("customer"),
    do:
      "Private and owner-only. SSH and terminal access; no outbound connections, sharing, web apps, or AI agent."

  defp profile_description("standard"),
    do:
      "Outbound connections, sharing, web apps, SSH, terminal, and AI agent tools. The agent cannot start child agents."

  defp profile_description("oss"),
    do:
      "The same network and access options as Standard, with AI agents that can start child agents."

  defp profile_description("inception"),
    do:
      "A Overalls development environment for nested machines. It uses a dedicated image, an extra 256 GiB data disk, and higher resource minimums. Its AI agent can start child agents."

  defp share_form(socket),
    do:
      assign(socket,
        access_form:
          to_form(%{"email" => "", "role" => "viewer", "request_key" => Ash.UUID.generate()},
            as: :access
          )
      )

  defp valid_cursor(value), do: if(OverallsProtocol.uuid?(value), do: value)

  defp image_options(images, selected) do
    options = Enum.map(images, &{&1.name, &1.id})

    if is_binary(selected) and selected != "" and not Enum.any?(images, &(&1.id == selected)),
      do: [{"Selected image unavailable", selected} | options],
      else: options
  end

  defp gib(bytes), do: Float.round(bytes / 1_073_741_824, 1)

  @spec role_label(atom()) :: String.t()
  defp role_label(:web), do: "Web apps"
  defp role_label(role), do: role |> to_string() |> String.capitalize()

  @spec role_summary(atom()) :: String.t()
  defp role_summary(:web), do: "Open this machine's web apps. No terminal."
  defp role_summary(:viewer), do: "Read the terminal."
  defp role_summary(:operator), do: "Read and write in the terminal."
  defp role_summary(:manager), do: "Terminal, lifecycle, resize, clone and sharing."
  defp role_summary(:revoked), do: "Ends that person's access to this machine."
  defp role_summary(_), do: ""
  defp label(:customer), do: "Customer"
  defp label(:inception), do: "Inception"
  defp label(:standard), do: "Standard"
  defp label(:oss), do: "OSS"
  defp state(%{desired_state: :deleted}), do: "Deleting"
  defp state(%{desired_state: :stopped, observed_state: :running}), do: "Stopping"

  defp state(%{desired_state: :running, observed_state: state})
       when state in [:pending, :stopped], do: "Starting"

  defp state(%{observed_state: state}), do: state |> Atom.to_string() |> String.capitalize()

  # @cc [owner:ghuntley,label:security] fixed-machine-error-messages
  # error_message/1 MUST return only predefined public messages; raw exceptions,
  # SQL details, credential data and arbitrary error payloads MUST NOT be shown.
  defp error_message(error) do
    text = Exception.message(error)

    messages = [
      insufficient_capacity: "There is not enough available capacity for this machine.",
      image_unavailable: "This image is no longer available. Refresh and choose another image.",
      image_requirements_not_met: "The selected image needs more memory or disk space.",
      host_unavailable: "This machine's host is currently unavailable.",
      recipient_not_registered: "No registered account matches that email address.",
      owner_protected: "The owner's access cannot be changed.",
      forbidden: "You no longer have permission for this action.",
      vm_deleted: "This machine is being deleted.",
      machine_pinned: "Unpin this machine before deleting it.",
      idempotency_conflict: "This request has already been used. Refresh before trying again."
    ]

    Enum.find_value(
      messages,
      "The request could not be completed. Check the values and try again.",
      fn {reason, message} ->
        if String.contains?(text, Atom.to_string(reason)), do: message
      end
    )
  end

  defp relocation_phase(phase) do
    %{
      preparing: "Preparing transfer",
      checking_transfer: "Checking transfer connectivity",
      stopping_source: "Stopping the source",
      copying: "Copying the stopped disks",
      importing: "Verifying the destination disks",
      handoff: "Switching placement",
      checking_destination: "Checking destination readiness",
      activation_failed: "Destination boot failed; source copy retained",
      readiness_failed: "Destination readiness failed; source copy retained",
      retrying_destination: "Restarting the destination; source copy retained",
      source_cleanup: "Destination ready; cleaning up the source",
      restoring_source: "Cancelling and restoring the source",
      cancelled_cleanup: "Source restored; destination cleanup pending",
      deleting_copies: "Deleting retained copies",
      cancelled: "Move cancelled; cleanup complete",
      complete: "Move complete",
      deleted: "All retained copies deleted"
    }[phase]
  end

  # @cc [owner:ghuntley,label:product] creation-profile-explanations
  # The creation form MUST explain every offered profile using its enforced access,
  # network, and agent capabilities. It MUST omit Inception help when Inception is
  # unavailable and MUST keep the comparison accessible from the profile selector.
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} compute={true} current_scope={%{user: @current_user}}>
      <section :if={@live_action == :index} class="stack">
        <UI.heading title="Machines" subtitle="Your development environments, personal and shared.">
          <:actions>
            <.link id="create-machine" navigate={~p"/machines/new"} class="console-button primary">
              + Create machine
            </.link>
          </:actions>
        </UI.heading>
        <p id="available-capacity" class="capacity-summary muted">
          <span :if={@catalog_available && @catalog.capacity_known}>
            Current headroom: {@catalog.available.vcpu} vCPU · {gib(@catalog.available.memory_bytes)} GiB memory · {gib(
              @catalog.available.disk_bytes
            )} GiB disk
          </span>
          <span :if={!@catalog_available || !@catalog.capacity_known}>Current headroom is temporarily unavailable.</span>
        </p>
        <p :if={@empty} id="machines-empty" class="empty-state">
          No machines on this page. Create a machine or ask an owner to share access.
        </p>
        <div class="machine-table">
          <table>
            <thead>
              <tr>
                <th class="width-auto">Machine</th>
                <th class="width-min">Status</th>
                <th class="width-min">Resources</th>
                <th class="width-min">Profile</th>
                <th class="width-min">Host</th>
                <th class="width-min">Access</th>
                <th class="width-min">Connect</th>
              </tr>
            </thead>
            <tbody id="machines" phx-update="stream">
              <tr
                :for={{id, vm} <- @streams.machines}
                id={id}
                class="machine-row"
                data-pinned={to_string(UI.pinned?(vm))}
              >
                <td>
                  <.link navigate={~p"/machines/#{vm.id}"} class="machine-name">{vm.name}</.link>
                  <UI.os_label vm={vm} id={"machine-os-#{vm.id}"} />
                </td>
                <td data-label="Status">
                  <UI.pinned_label vm={vm} id={"machine-pinned-#{vm.id}"} />
                  <span class="status-label" data-state={vm.observed_state}>{state(vm)}</span>
                </td>
                <td class="resource-values" data-label="Resources">
                  {vm.vcpu} vCPU · {gib(vm.memory_bytes)} GiB RAM · {gib(vm.disk_bytes)} GiB disk
                </td>
                <td data-label="Profile">{label(vm.profile)}</td>
                <td id={"machine-host-#{vm.id}"} class="nowrap" data-label="Host">
                  <code>{vm.host || "Unavailable"}</code>
                </td>
                <td class="muted" data-label="Access">{if vm.owner, do: "Owner", else: "Shared"}</td>
                <td data-label="Connect">
                  <div class="machine-open-actions">
                    <.link
                      :if={vm.desired_state == :running && vm.observed_state == :running}
                      navigate={~p"/machines/#{vm.id}/terminals"}
                      id={"machine-terminal-#{vm.id}"}
                      class="console-button"
                      aria-label={"Open terminal for #{vm.name}"}
                    >Open terminal</.link>
                    <span
                      :if={vm.desired_state != :running || vm.observed_state != :running}
                      class="muted"
                    >Terminal unavailable</span>
                    <UI.machine_editor_action vm={vm} id_prefix="machine" />
                    <UI.pin_toggle vm={vm} id={"pin-#{vm.id}"} />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <nav class="row" aria-label="Machine pages">
          <.link :if={@cursor} patch={~p"/machines"} id="machines-first">← First page</.link>
          <.link :if={@next_cursor} patch={~p"/machines?#{%{after: @next_cursor}}"} id="machines-next">Next page →</.link>
        </nav>
      </section>
      <section :if={@live_action == :new} class="creation-page stack">
        <p><.link navigate={~p"/machines"}>← Machines</.link></p>
        <UI.heading
          title="Create machine"
          subtitle="Choose an image and the resources for your environment."
        />
        <div class="panel">
          <p :if={!@catalog_available} role="status" class="console-notice">
            Images and capacity are temporarily unavailable. Your choices are retained.
          </p>
          <p
            :if={@catalog_available && @catalog.images == []}
            id="no-ready-images"
            role="status"
            class="console-notice"
          >
            No images are available on ready hosts right now.
          </p>
          <p :if={@catalog_available && @catalog.capacity_known} class="capacity-summary muted">
            Current headroom: {@catalog.available.vcpu} vCPU · {gib(@catalog.available.memory_bytes)} GiB memory · {gib(
              @catalog.available.disk_bytes
            )} GiB disk
          </p>
          <.form
            for={@form}
            id="provision-form"
            phx-submit="provision"
            phx-change="validate"
            class="stack"
          >
            <.input field={@form[:request_key]} type="hidden" />
            <h2 class="form-chapter"><span>1.</span> Choose your environment</h2>
            <.input
              :if={@form[:profile].value != "inception"}
              field={@form[:image_id]}
              type="select"
              label="Image"
              prompt="Choose an image"
              options={
                image_options(
                  Enum.reject(
                    @catalog.images,
                    &(&1.id == Marshall.Compute.Profiles.inception_image_id())
                  ),
                  @form[:image_id].value
                )
              }
              required
            />
            <.input
              field={@form[:profile]}
              type="select"
              label="Profile"
              options={profile_options(@catalog.images)}
              aria-describedby="profile-guide"
            />
            <div id="profile-guide" class="profile-guide">
              <p class="muted">
                Profiles choose access and agent features. Machines remain isolated from one another.
              </p>
              <dl class="kv">
                <div
                  :for={{name, profile} <- profile_options(@catalog.images)}
                  id={"profile-help-#{profile}"}
                >
                  <dt>{name}</dt>
                  <dd>{profile_description(profile)}</dd>
                </div>
              </dl>
            </div>
            <h2 class="form-chapter"><span>2.</span> Make it yours</h2>
            <.input
              field={@form[:team_id]}
              type="select"
              label="Owner"
              options={[{"Personal", ""} | Enum.map(@provisioning_teams, &{&1.name, &1.id})]}
            />
            <.input
              :if={@form[:profile].value == "inception"}
              field={@form[:image_id]}
              type="hidden"
              id="inception-image-id"
            />
            <h2 class="form-chapter"><span>3.</span> Give it room to grow</h2>
            <div class="grid">
              <.input
                field={@form[:vcpu]}
                type="number"
                label="CPU (vCPU)"
                min={if @form[:profile].value == "inception", do: 16, else: 1}
                max="32"
                required
              />
              <.input
                field={@form[:memory_mib]}
                type="number"
                label="Memory (MiB)"
                min={if @form[:profile].value == "inception", do: 32768, else: 512}
                step="1"
                required
              />
              <.input
                field={@form[:disk_gib]}
                type="number"
                label={
                  if @form[:profile].value == "inception", do: "Root disk (GiB)", else: "Disk (GiB)"
                }
                min={if @form[:profile].value == "inception", do: 64, else: 2}
                max={OverallsProtocol.VMShape.maximum_disk_gib()}
                step="1"
                required
              />
            </div>
            <div id="creation-summary" class="creation-summary panel dashed">
              <h3>Ready when you are</h3>
              <p>
                {@form[:vcpu].value} vCPU · {@form[:memory_mib].value} MiB memory · {@form[:disk_gib].value} GiB disk
              </p>
              <p class="muted">Your disk stays with you when the machine is stopped.</p>
            </div>
            <div class="row actions">
              <Layouts.action
                tone="primary"
                id="provision-submit"
                disabled={!@catalog_available || @catalog.images == []}
                phx-disable-with="Creating…"
              >
                Create machine
              </Layouts.action>
              <.link navigate={~p"/machines"} class="console-button">Cancel</.link>
            </div>
          </.form>
        </div>
      </section>
      <section :if={@live_action in [:access, :settings] && @vm} id="machine-detail" class="stack">
        <UI.machine_header
          vm={@vm}
          connection={@machine_connection}
          power_key={@machine_power_key}
          active={to_string(@live_action)}
        />
        <UI.panel :if={@live_action == :settings} id="machine-resources" title="Resources">
          <:actions>
            <.link
              :if={@vm.permissions.manage && @vm.desired_state != :deleted}
              id="resize-machine"
              navigate={~p"/machines/#{@vm.id}/resize"}
              class="console-button"
            >
              Resize
            </.link>
          </:actions>
          <.kv>
            <:item title="Operating system">
              <span id="machine-operating-system">{UI.operating_system(@vm) || "Unavailable"}</span>
            </:item>
            <:item title="CPU">{@vm.vcpu} vCPU</:item>
            <:item title="Memory">{gib(@vm.memory_bytes)} GiB</:item>
            <:item title="Disk">{gib(@vm.disk_bytes)} GiB</:item>
            <:item title="Host">
              <code id="machine-host">{@vm.host || "Unavailable"}</code>
            </:item>
            <:item title="Profile">{label(@vm.profile)}</:item>
          </.kv>
          <p class="muted">Your disk is retained when the machine is stopped.</p>
        </UI.panel>
        <p
          :if={@live_action in [:access, :settings] && !@vm.permissions.manage}
          class="empty-state"
          role="status"
        >
          Management access is required to change the remaining settings.
        </p>
        <p :if={@vm.profile == :customer} id="customer-isolation" class="muted">
          Customer machines allow only owner SSH and terminal access. Outbound networking,
          workspace sharing, and web service exposure are disabled.
        </p>
        <section
          :if={
            @live_action == :access && @vm.permissions.manage && @vm.desired_state != :deleted &&
              OverallsProtocol.ProfilePolicy.allows?(@vm.profile, :sharing)
          }
          id="sharing"
          class="stack"
        >
          <UI.heading
            title="Access"
            subtitle="Who can reach this machine, and what each role allows."
          />
          <UI.panel id="access-people" title="Direct machine grants">
            <p class="muted">
              Team membership and thread sharing can also grant machine access.
            </p>
            <div class="machine-table access-table">
              <table>
                <thead>
                  <tr>
                    <th class="width-auto">Account</th>
                    <th class="width-min">Role</th>
                    <th class="width-min">Allows</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@grant_owner} id="machine-owner">
                    <td class="break" data-label="Account">{@grant_owner.email}</td>
                    <td data-label="Role"><span class="status-label">Owner</span></td>
                    <td data-label="Allows" class="muted">
                      Everything; cannot be changed here.
                    </td>
                  </tr>
                </tbody>
                <tbody id="grants" phx-update="stream">
                  <tr :for={{id, grant} <- @streams.grants} id={id}>
                    <td class="break" data-label="Account">{grant.email}</td>
                    <td data-label="Role">
                      <span class="status-label">{role_label(grant.role)}</span>
                    </td>
                    <td data-label="Allows" class="muted">{role_summary(grant.role)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@grants_empty} id="grants-empty" class="muted">
              No direct machine grants.
            </p>
            <div :if={@grant_cursor || @grant_next} class="row actions">
              <Layouts.action :if={@grant_cursor} tone="default" phx-click="grants_first">
                ← First page
              </Layouts.action>
              <Layouts.action :if={@grant_next} tone="default" phx-click="grants_next">
                Next page →
              </Layouts.action>
            </div>
          </UI.panel>
          <.form for={@access_form} id="sharing-form" phx-submit="share" class="panel stack">
            <h2>Grant, change or remove access</h2>
            <p class="muted">
              The account must already be registered. Saving a role replaces that person's
              direct machine role; choose Remove access to remove that direct grant.
            </p>
            <.input field={@access_form[:request_key]} type="hidden" />
            <div class="grid">
              <.input
                field={@access_form[:email]}
                type="email"
                label="Registered email"
                required
              />
              <.input
                field={@access_form[:role]}
                type="select"
                label="Role"
                options={[
                  {"Web apps only", "web"},
                  {"Viewer", "viewer"},
                  {"Operator", "operator"},
                  {"Manager", "manager"},
                  {"Remove access", "revoked"}
                ]}
              />
            </div>
            <.kv>
              <:item title="Web apps only">{role_summary(:web)}</:item>
              <:item title="Viewer">{role_summary(:viewer)}</:item>
              <:item title="Operator">{role_summary(:operator)}</:item>
              <:item title="Manager">{role_summary(:manager)}</:item>
              <:item title="Remove access">{role_summary(:revoked)}</:item>
            </.kv>
            <div class="row actions">
              <Layouts.action tone="primary" id="share-submit" phx-disable-with="Saving…">
                Save access
              </Layouts.action>
            </div>
          </.form>
        </section>
        <section
          :if={@live_action == :settings && @vm.permissions.manage}
          id="machine-advanced"
          class="stack"
        >
          <UI.panel id="relocation-controls" title="Relocate machine">
            <:actions>
              <Layouts.action
                :if={
                  @vm.desired_state != :deleted &&
                    (!@vm.relocation || !@vm.relocation.active)
                }
                id="relocate-machine"
                phx-click="relocate"
                phx-disable-with="Requesting…"
                data-confirm="Move this machine to an automatically selected host? The machine may be briefly unavailable."
              >
                Move to another host
              </Layouts.action>
            </:actions>
            <p id="relocation-network-note" class="muted">
              The machine is stopped, copied once and started on an automatically selected host.
              Our development fleet uses a 1 Gbit/s connection between hosts, so a move can take a
              little longer; moves are expected to be much faster when Overalls runs on AWS in production.
            </p>
            <div :if={@vm.relocation} id="relocation-status" class="stack" aria-live="polite">
              <.kv>
                <:item title="Phase">
                  <span id="relocation-phase">{relocation_phase(@vm.relocation.phase)}</span>
                </:item>
                <:item title="Mode">
                  <span id="relocation-mode">
                    The machine is stopped, copied once and started on the destination.
                  </span>
                </:item>
                <:item :if={@vm.relocation.downtime} title="Observed downtime">
                  <span
                    id="relocation-downtime"
                    title="Measured between control-plane stop and readiness observations; guest availability may differ."
                  >
                    {@vm.relocation.downtime.seconds} seconds{if @vm.relocation.downtime.ongoing,
                      do: " and counting",
                      else: ""}
                  </span>
                </:item>
              </.kv>
              <div :if={@vm.relocation.cancellable || @vm.relocation.retryable} class="row actions">
                <Layouts.action
                  :if={@vm.relocation.cancellable}
                  id="cancel-relocation"
                  phx-click="cancel-relocation"
                  phx-disable-with="Cancelling…"
                >
                  Cancel move
                </Layouts.action>
                <Layouts.action
                  :if={@vm.relocation.retryable}
                  id="retry-relocation"
                  phx-click="retry-relocation"
                  phx-disable-with="Requesting restart…"
                >
                  Retry destination boot
                </Layouts.action>
              </div>
            </div>
          </UI.panel>
          <section
            :if={@vm.desired_state != :deleted}
            id="clone-machine"
            class="panel clone-section"
            aria-labelledby="clone-heading"
          >
            <header>
              <h2 id="clone-heading">Clone machine</h2>
              <span class="muted">Files and stored credentials are included in the copy</span>
            </header>
            <div class="panel-body">
              <p>
                Create a private, independent copy of this machine. Running machines stop briefly
                for each snapshot, then restart while copying continues. Copies are processed in
                order and match the source's power state when their turn begins.
              </p>
              <.form
                for={@clone_form}
                id="clone-form"
                phx-change="clone-validate"
                phx-submit="clone"
                class="field-row clone-form"
              >
                <.input field={@clone_form[:request_key]} type="hidden" />
                <.input
                  field={@clone_form[:name]}
                  label="New machine name (optional)"
                  placeholder="Leave blank to generate a name"
                  maxlength="63"
                  aria-describedby="clone-name-help clone-privacy"
                />
                <button
                  id="submit-clone"
                  type="submit"
                  class="console-button primary"
                  phx-disable-with="Queuing…"
                >
                  + Queue clone
                </button>
              </.form>
              <p id="clone-name-help" class="sr-only">Leave blank to generate a name.</p>
              <p id="clone-privacy" class="sr-only">
                Files and stored credentials are included in the copy.
              </p>
            </div>
          </section>
          <section
            :if={@vm.desired_state != :deleted}
            class="panel"
            aria-labelledby="clone-requests-heading"
          >
            <header>
              <h2 id="clone-requests-heading">Clone requests</h2>
              <span class="muted">Updates automatically</span>
            </header>
            <div class="panel-body">
              <p :if={@clones_available && @clones_empty} id="clone-empty" class="empty-state">
                No clone requests yet. Queue a copy and follow its progress here.
              </p>
              <p :if={!@clones_available} id="clone-unavailable" class="empty-state">
                Clone requests are temporarily unavailable. Retrying automatically.
              </p>
              <%!-- Outside the reset stream: unchanged polls must not reannounce every card. --%>
              <p
                id="clone-announcement"
                class="sr-only"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                {@clone_announcement}
              </p>
              <div id="clone-requests" phx-update="stream" class="clone-requests">
                <CloneComponents.card
                  :for={{dom_id, clone} <- @streams.clones}
                  id={dom_id}
                  clone={clone}
                />
              </div>
            </div>
          </section>
          <UI.panel
            :if={@vm.desired_state != :deleted}
            class="danger danger-zone"
            title="Delete machine"
          >
            <:actions>
              <%!-- The owner's pin fences deletion server-side (ADR-0193); the
                   disabled control only explains that refusal ahead of time. --%>
              <Layouts.action
                tone="danger"
                id="delete-machine"
                phx-click="lifecycle"
                phx-value-kind="delete"
                phx-value-key={@lifecycle_key}
                disabled={@vm.owner && UI.pinned?(@vm)}
                aria-describedby={@vm.owner && UI.pinned?(@vm) && "delete-pinned"}
                data-confirm="Delete this machine and its disk? This cannot be undone."
              >
                Delete
              </Layouts.action>
            </:actions>
            <p :if={@vm.owner && UI.pinned?(@vm)} id="delete-pinned">
              Unpin to delete. While you have this machine pinned, nothing can delete it.
            </p>
            <p class="muted">
              Permanently remove this machine and its disk. This cannot be undone.
            </p>
          </UI.panel>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
