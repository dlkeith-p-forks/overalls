defmodule Marshall.Compute.Views do
  @moduledoc "Bounded user-facing VM views. Resource mutation remains in the trusted coordinators."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.{Authorization, Pins}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Budget, Host, Image, Ledger, Reservation, StoragePool, VirtualMachine}
  require Ash.Query

  # @cc [owner:ghuntley,label:product;security] views-reflection-metadata
  # Every authorized machine view MUST project the persisted labels and comment
  # consumed by settings. Projection MUST retain the existing read authorization;
  # metadata visibility MUST NOT grant permission to change it.
  @fields [
    :id,
    :name,
    :labels,
    :comment,
    :profile,
    :architecture,
    :image_id,
    :vcpu,
    :memory_bytes,
    :disk_bytes,
    :desired_state,
    :observed_state,
    :failure_reason,
    :generation,
    :inserted_at
  ]

  @impl true
  def run(input, options, context) do
    result =
      Ledger.transaction(fn ->
        case options[:operation] do
          :get ->
            input.arguments.vm_id
            |> Authorization.live_vm!(context.actor, "read", false, true)
            |> view(context.actor)

          :list ->
            list(input.arguments, context.actor)

          :pinned ->
            pinned(context.actor)

          :resolve ->
            resolve(input.arguments.reference, context.actor)

          :catalog ->
            catalog()
        end
      end)

    case result do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:security] views-reference-current-access
  # Name/UUID resolution MUST return only a currently readable, unarchived VM.
  # Resolving a name MUST NOT itself grant authority for a later mutation.
  defp resolve(reference, actor) do
    filter =
      cond do
        OverallsProtocol.uuid?(reference) -> [id: reference]
        OverallsProtocol.MachineName.valid?(reference) -> [name: reference]
        true -> Ledger.rollback(:forbidden)
      end

    case Ledger.read!(VirtualMachine, filter) do
      [vm] ->
        vm.id |> Authorization.live_vm!(actor, "read", false, true) |> view(actor)

      [] ->
        Ledger.rollback(:forbidden)
    end
  end

  # @cc [owner:ghuntley,label:security] views-bounded-current-access
  # User VM pages MUST be bounded by the validated limit and cursor, include only
  # current Cedar-readable VMs, and expose only the view field allowlist, the
  # current physical host name, the registered image display name, opaque
  # execution reference, finite editor image status, current permissions, the
  # caller's own pin flag and bounded authorized operation summaries. The
  # bounded SQL candidates MUST include current thread grants; every row still
  # requires a fresh Cedar decision. The validated `exclude` list (at most the
  # pin limit) MUST remove those ids from the keyset page without changing its
  # order or cursor semantics. Internal host IDs, placements, reservations,
  # image manifests and other users' pins stay private.
  defp list(request, actor) do
    exclude = Map.get(request, :exclude, [])

    query =
      VirtualMachine
      |> Ash.Query.filter(
        owner_id == ^actor.id or
          (profile in [:standard, :oss, :inception] and
             (exists(team.members, user_id == ^actor.id and is_nil(archived_at)) or
                exists(
                  access_grants,
                  user_id == ^actor.id and is_nil(archived_at) and
                    role in [:viewer, :operator, :manager]
                ) or
                exists(
                  current_threads.grants,
                  user_id == ^actor.id and is_nil(archived_at) and
                    role in [:viewer, :operator, :manager]
                )))
      )
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(request.limit + 1)

    query =
      if Map.get(request, :after), do: Ash.Query.filter(query, id > ^request.after), else: query

    query = if exclude == [], do: query, else: Ash.Query.filter(query, id not in ^exclude)

    rows = Ash.read!(query, actor: SystemActor.compute())

    items =
      rows
      |> Enum.take(request.limit)
      |> Enum.filter(&Authorization.allowed?(&1, actor, "read"))
      |> Enum.map(&view(&1, actor))

    %{
      items: items,
      next_cursor: if(length(rows) > request.limit, do: Enum.at(rows, request.limit - 1).id)
    }
  end

  # @cc [owner:ghuntley,label:security;product] views-pinned-section-bounded
  # The pinned section MUST contain only the caller's live `pinned` rows (at
  # most the pin limit), ordered newest pin first, restricted to unarchived VMs
  # that pass the same fresh per-row Cedar read decision and projected through
  # the same view as the keyset page. A pin on a VM the caller can no longer
  # read MUST be omitted, not fail the whole section.
  defp pinned(actor) do
    ids = Pins.pinned_vm_ids(actor)

    rows =
      if ids == [] do
        %{}
      else
        VirtualMachine
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(actor: SystemActor.compute())
        |> Map.new(&{&1.id, &1})
      end

    items =
      ids
      |> Enum.flat_map(&List.wrap(rows[&1]))
      |> Enum.filter(&Authorization.allowed?(&1, actor, "read"))
      |> Enum.map(&view(&1, actor))

    %{items: items}
  end

  @spec view(VirtualMachine.t(), map()) :: map()
  defp view(vm, actor) do
    image = List.first(Ledger.read!(Image, id: vm.image_id))

    Map.merge(Map.take(vm, @fields), %{
      image_name: image_name(image),
      execution_ref: execution_ref(vm),
      host: host_name(vm),
      ssh_host: ssh_host_name(vm),
      editor_image_status: editor_image_status(image),
      guest_capabilities: Image.guest_capabilities(image),
      pinned: Pins.pinned?(vm, actor),
      resize: resize_view(vm, actor),
      relocation:
        if(Authorization.allowed?(vm, actor, "manage"),
          do: Marshall.Compute.RelocationStatus.latest(vm.id)
        ),
      owner: vm.owner_id == actor.id,
      permissions:
        Map.new(
          [:read, :write, :manage],
          &{&1, Authorization.allowed?(vm, actor, Atom.to_string(&1))}
        )
    })
    |> Map.merge(owner_view(vm, actor))
  end

  # @cc [owner:ghuntley,label:security;product] views-shared-owner-identity
  # A view MUST name the owner (email and saved display zone, ADR-0195) only
  # when the caller is not the owner and already holds read access to the
  # machine; the owner's own view carries nil for both so no page shows a
  # person their own local time as another user. SSH wire views drop both.
  @spec owner_view(VirtualMachine.t(), map()) :: %{
          owner_email: String.t() | nil,
          owner_time_zone: String.t() | nil
        }
  defp owner_view(%VirtualMachine{owner_id: owner_id}, %{id: owner_id}),
    do: %{owner_email: nil, owner_time_zone: nil}

  defp owner_view(vm, _actor) do
    owner =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^vm.owner_id)
      |> Ash.read_one!()

    %{
      owner_email: owner && to_string(owner.email),
      owner_time_zone: owner && owner.time_zone
    }
  end

  # @cc [owner:ghuntley,label:product;security] views-image-display-name
  # The view MUST expose the registered image's display name (`image_name`) as
  # the machine's operating-system label, and nothing else from the image row;
  # a missing image row MUST project nil rather than failing or a placeholder.
  @spec image_name(Image.t() | nil) :: String.t() | nil
  defp image_name(%Image{name: name}) when is_binary(name), do: name
  defp image_name(_), do: nil

  # @cc [owner:ghuntley,label:security;product] views-editor-image-status
  # An authorized VM view MUST expose only a finite status derived from its
  # immutable image and current configured editor release, never the descriptor.
  # Missing image data MUST fail closed. Projection MUST NOT allocate accounts,
  # mutate images or replace fresh editor launch authorization.

  # @cc [owner:ghuntley,label:security;product] views-guest-capabilities
  # The same view MUST expose finite per-capability booleans (guest_capabilities)
  # from the immutable image's agent set so presentation can hide terminal, agent,
  # editor and SSH controls the guest cannot serve; the booleans never authorize.
  @spec editor_image_status(Image.t() | nil) :: Image.editor_image_status()
  defp editor_image_status(image) do
    case Image.editor_capability(image, Application.get_env(:marshall, :ingress_editor_releases)) do
      {:ok, _} -> :available
      {:error, status} -> status
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] views-opaque-execution
  # The public execution reference MUST change on placement, epoch or generation
  # changes without exposing internal placement IDs. It grants no authority.
  @spec execution_ref(VirtualMachine.t()) :: String.t()
  defp execution_ref(vm) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({vm.id, vm.current_placement_id, vm.execution_epoch, vm.generation})
    )
    |> Base.url_encode64(padding: false)
  end

  defp host_name(vm) do
    case Ledger.read!(Host, id: vm.host_id) do
      [%{name: name}] when is_binary(name) -> name
      _ -> nil
    end
  end

  # @cc [owner:ghuntley,label:security;product] views-authorized-ssh-name
  # A readable VM view MUST expose its stable Audi SSH name separately from
  # the physical host. The name comes from the persisted endpoint label and
  # configured zone; it MUST NOT reveal another VM or a mutable placement.
  @doc "The stable guest SSH host name `show` exposes, or nil without an ingress zone/endpoint."
  @spec ssh_host_name(Marshall.Compute.VirtualMachine.t()) :: String.t() | nil
  def ssh_host_name(vm) do
    case {Application.get_env(:marshall, :ingress_zone),
          Ledger.read!(Marshall.Ingress.Endpoint, vm_id: vm.id)} do
      {zone, [%{label: label}]}
      when is_binary(zone) and is_binary(label) and byte_size(label) + byte_size(zone) < 253 ->
        label <> "." <> zone

      _ ->
        nil
    end
  end

  defp resize_view(vm, actor) do
    if Authorization.allowed?(vm, actor, "manage") do
      case Marshall.Compute.Resize.active(vm.id) do
        nil ->
          nil

        request ->
          Map.take(request, [
            :id,
            :phase,
            :failure,
            :original_sizes,
            :target_sizes,
            :original_power_state,
            :cancelled_at
          ])
      end
    end
  end

  # @cc [owner:ghuntley,label:capacity] catalog-observations-are-not-reservations
  # Catalog totals MUST include only eligible fresh hosts/pools and advertise only
  # enabled locally available images. Count host CPU/RAM once across its pools;
  # these unlocked totals MUST NOT substitute for transactional admission checks.
  defp catalog do
    now = Ledger.now()

    hosts =
      Ledger.read!(Host, enabled: true)
      |> Enum.filter(
        &(&1.maintenance_mode == :normal and &1.inventory["execution_ready"] == true and
            Marshall.Compute.HostLiveness.capacity_fresh?(&1.reported_at, now) and
            &1.capacity != nil)
      )

    {available, ids, known} =
      Enum.reduce(hosts, {%{vcpu: 0, memory_bytes: 0, disk_bytes: 0}, [], false}, fn host,
                                                                                     {sum, ids,
                                                                                      known} ->
        reservations = Ledger.read!(Reservation, host_id: host.id)

        pools =
          Ledger.read!(StoragePool, host_id: host.id)
          |> Enum.filter(&Marshall.Compute.HostLiveness.capacity_fresh?(&1.reported_at, now))

        budgets = Enum.map(pools, &Budget.available(host, &1, reservations))

        case budgets do
          [] ->
            {sum, ids, known}

          [first | _] ->
            {%{
               vcpu: sum.vcpu + first.vcpu,
               memory_bytes: sum.memory_bytes + first.memory_bytes,
               disk_bytes: sum.disk_bytes + Enum.sum(Enum.map(budgets, & &1.disk_bytes))
             }, host.inventory["images"] ++ ids, true}
        end
      end)

    images =
      Ledger.read!(Image, enabled: true)
      |> Enum.filter(&(&1.id in ids))
      |> Enum.sort_by(&{&1.name, &1.id})
      |> Enum.map(
        &Map.take(&1, [:id, :name, :architecture, :minimum_memory_bytes, :minimum_disk_bytes])
      )

    %{images: images, available: available, sampled_at: now, capacity_known: known}
  end
end
