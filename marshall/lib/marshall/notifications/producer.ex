defmodule Marshall.Notifications.Producer do
  @moduledoc """
  Turns committed "agent needs input" facts into deliveries (ADR-0225).

  `needs_input!/2` is called inside the agent question or plan proposal
  transaction and only registers a `Ledger.after_commit/1` callback. After the
  outer commit, one new transaction creates every recipient device's Delivery
  together with its Oban job. Recipients are the thread's current writers
  other than the acting user; devices must be active and enabled.
  """
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Notifications
  alias Marshall.Notifications.{Delivery, DeliveryWorker, Device}
  alias OverallsProtocol.AppRoute
  require Ash.Query
  require Marshall.Events

  @expiry_seconds 3600
  @candidate_limit 513

  @type source :: %{thread_id: Ash.UUID.t(), root_id: Ash.UUID.t()}

  @doc "Expiry of a poke after it was produced, in seconds."
  @spec expiry_seconds() :: pos_integer()
  def expiry_seconds, do: @expiry_seconds

  # @cc [owner:ghuntley,label:observability;recovery] notification-producer-after-commit
  # Deliveries MUST be produced only after the outer agent transaction commits
  # and MUST NOT run when notifications are disabled. A producer failure MUST
  # NOT affect the committed agent work; it is reported as a closed refusal.
  @doc "Registers a needs-input notification for the enclosing Ledger transaction."
  @spec needs_input!(map(), keyword()) :: :ok
  def needs_input!(%{id: thread_id, root_id: root_id}, options \\ []) do
    actor_id = Keyword.get(options, :actor_id)

    Ledger.after_commit(fn ->
      produce(%{thread_id: thread_id, root_id: root_id}, actor_id)
    end)
  end

  @doc "Creates deliveries for a committed needs-input fact. Returns the delivery count."
  @spec produce(source(), Ash.UUID.t() | nil) :: non_neg_integer()
  def produce(source, actor_id) do
    if Notifications.enabled?() do
      case Ledger.transaction(fn -> produce_locked!(source, actor_id) end) do
        {:ok, deliveries} ->
          Enum.each(deliveries, fn delivery ->
            Marshall.Events.emit("notifications.delivery_transition",
              delivery_id: delivery.id,
              device_id: delivery.device_id,
              state: delivery.state,
              reason: delivery.drop_reason || :produced
            )
          end)

          length(deliveries)

        {:error, _} ->
          Marshall.Events.emit("notifications.poke_refused", reason: :producer_failed)
          0
      end
    else
      0
    end
  rescue
    _ ->
      Marshall.Events.emit("notifications.poke_refused", reason: :producer_failed)
      0
  end

  @spec produce_locked!(source(), Ash.UUID.t() | nil) :: [Delivery.t()]
  defp produce_locked!(%{thread_id: thread_id, root_id: root_id}, actor_id) do
    with [root] <- Ledger.read!(Marshall.Agents.Root, id: root_id),
         [%VirtualMachine{archived_at: nil} = vm] <- Ledger.read!(VirtualMachine, id: root.vm_id),
         true <- vm.desired_state != :deleted,
         {:ok, task} <- task(root.id),
         {:ok, route} <- route(vm, task, thread_id) do
      collapse_key = "needs_input:" <> thread_id
      expires_at = DateTime.add(Ledger.now(), @expiry_seconds, :second)

      vm
      |> recipients(task, actor_id)
      |> devices()
      |> Enum.map(&deliver!(&1, collapse_key, route, expires_at))
    else
      _ -> []
    end
  end

  @spec deliver!(Device.t(), String.t(), String.t(), DateTime.t()) :: Delivery.t()
  defp deliver!(device, collapse_key, route, expires_at) do
    attributes = %{
      device_id: device.id,
      user_id: device.user_id,
      kind: :needs_input,
      collapse_key: collapse_key,
      route: route,
      expires_at: expires_at
    }

    open =
      Delivery
      |> Ash.Query.filter(
        device_id == ^device.id and collapse_key == ^collapse_key and
          state in [:queued, :sending, :retry_wait]
      )
      |> Ash.Query.lock(:for_update)
      |> Ash.read!(actor: SystemActor.compute())

    case open do
      [_existing | _] ->
        # @cc [owner:ghuntley,label:concurrency] notification-delivery-coalesce
        # A device MUST hold at most one open delivery per collapse key; a newer
        # fact for the same key is recorded as dropped(coalesced).
        Ledger.create!(
          Delivery,
          :record_coalesced,
          Map.put(attributes, :finished_at, Ledger.now())
        )

      [] ->
        delivery = Ledger.create!(Delivery, :enqueue, attributes)
        %{delivery_id: delivery.id} |> DeliveryWorker.new() |> Oban.insert!()
        delivery
    end
  end

  @doc "Thread writers who may be notified, excluding the actor."
  @spec recipients(VirtualMachine.t(), Marshall.Threads.Thread.t() | nil, Ash.UUID.t() | nil) ::
          [Ash.UUID.t()]
  def recipients(vm, task, actor_id) do
    machine =
      Marshall.Access.Grant
      |> Ash.Query.filter(vm_id == ^vm.id)
      |> Ash.Query.limit(@candidate_limit)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.user_id)

    thread =
      if task,
        do:
          Marshall.Threads.Grant
          |> Ash.Query.filter(thread_id == ^task.id)
          |> Ash.Query.limit(@candidate_limit)
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.map(& &1.user_id),
        else: Marshall.Threads.Authorization.machine_user_ids(vm)

    team =
      [vm.team_id, task && task.team_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn team_id ->
        Marshall.Teams.TeamMember
        |> Ash.Query.filter(team_id == ^team_id)
        |> Ash.Query.limit(@candidate_limit)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(& &1.user_id)
      end)

    owner = [vm.owner_id] ++ if(task, do: [task.creator_id], else: [])

    (owner ++ machine ++ thread ++ team)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == actor_id))
    |> Enum.filter(&writer?(&1, vm, task))
  end

  # @cc [owner:ghuntley,label:security] notification-recipients-current-writers
  # Recipients MUST hold current write authority on the machine and, for a
  # task thread, on that thread, evaluated through the same Cedar checks the
  # answer path uses. Viewers, retired accounts and the acting user receive none.
  @spec writer?(Ash.UUID.t(), VirtualMachine.t(), Marshall.Threads.Thread.t() | nil) :: boolean()
  defp writer?(user_id, vm, task) do
    case Security.current(user_id) do
      %User{deleted_at: nil} = user ->
        Marshall.Access.Authorization.allowed?(vm, user, "write") and
          (is_nil(task) or Marshall.Threads.Authorization.allowed?(task, user, "write"))

      _ ->
        false
    end
  end

  @spec devices([Ash.UUID.t()]) :: [Device.t()]
  defp devices([]), do: []

  defp devices(user_ids) do
    Device
    |> Ash.Query.filter(user_id in ^user_ids and state == :active and enabled == true)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: SystemActor.compute())
  end

  @spec task(Ash.UUID.t()) :: {:ok, Marshall.Threads.Thread.t() | nil} | :error
  defp task(root_id) do
    case Ledger.history!(Marshall.Threads.Thread, agent_root_id: root_id) do
      [] -> {:ok, nil}
      [%{status: :ready, archived_at: nil} = task] -> {:ok, task}
      _ -> :error
    end
  end

  @spec route(VirtualMachine.t(), Marshall.Threads.Thread.t() | nil, Ash.UUID.t()) ::
          {:ok, String.t()} | :error
  defp route(_vm, %{id: task_id}, _thread_id), do: path({:thread, task_id})
  defp route(vm, nil, thread_id), do: path({:machine_thread, vm.id, thread_id})

  @doc "The canonical route path (without scheme and host) for an application page."
  @spec path(AppRoute.page()) :: {:ok, String.t()} | :error
  def path(page) do
    route = %{host: "route.invalid", port: nil, page: page}
    formatted = AppRoute.format(route)

    with {:ok, ^route} <- AppRoute.parse(formatted),
         "overalls://route.invalid" <> path <- formatted do
      {:ok, path}
    else
      _ -> :error
    end
  end
end
