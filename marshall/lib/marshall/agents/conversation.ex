defmodule Marshall.Agents.Conversation do
  @moduledoc "Authorized conversation reads and child-thread creation."
  alias Marshall.Agents.{AuditEvent, Event, Root, Thread, Turn}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @type user :: Marshall.Accounts.User.t()

  @spec machine(String.t(), user()) :: {:ok, map()} | {:error, term()}
  def machine(vm_id, %Marshall.Accounts.User{} = actor) when is_binary(vm_id) do
    case Marshall.Compute.get_vm(%{vm_id: vm_id}, actor: actor) do
      {:ok, vm} ->
        if vm.desired_state == :deleted,
          do: {:ok, Map.put(vm, :permissions, %{write: false})},
          else: {:ok, vm}

      _ ->
        case Ledger.history!(VirtualMachine, id: vm_id) do
          [%VirtualMachine{owner_id: owner_id, desired_state: :deleted} = vm]
          when owner_id == actor.id ->
            if match?(
                 %Marshall.Accounts.User{deleted_at: nil, active: true},
                 Marshall.Accounts.Security.current(actor.id)
               ),
               do: {:ok, Map.put(vm, :permissions, %{write: false})},
               else: {:error, :machine_unavailable}

          _ ->
            {:error, :machine_unavailable}
        end
    end
  end

  def machine(_, _), do: {:error, :forbidden}

  # @cc [owner:ghuntley,label:security] agent-conversation-fresh-read
  # Every conversation read MUST recheck the current VM permission. Thread IDs
  # alone never grant access to prompts, assistant text or tool output.
  @spec list(String.t(), user()) :: {:ok, [Thread.t()]} | {:error, term()}
  def list(vm_id, %Marshall.Accounts.User{} = actor) when is_binary(vm_id) do
    with {:ok, _vm} <- machine(vm_id, actor),
         [%Root{} = root] <- Ledger.read!(Root, vm_id: vm_id) do
      root_thread =
        Thread
        |> Ash.Query.filter(root_id == ^root.id and is_nil(parent_thread_id))
        |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

      children =
        Thread
        |> Ash.Query.filter(root_id == ^root.id and not is_nil(parent_thread_id))
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(99)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

      if root_thread, do: {:ok, [root_thread | children]}, else: {:error, :machine_unavailable}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  def list(_, _), do: {:error, :forbidden}

  @spec get_thread(String.t(), user()) :: {:ok, Thread.t()} | {:error, term()}
  def get_thread(thread_id, %Marshall.Accounts.User{} = actor) when is_binary(thread_id) do
    with [%Thread{} = thread] <- Ledger.read!(Thread, id: thread_id),
         [%Root{} = root] <- Ledger.read!(Root, id: thread.root_id),
         {:ok, _vm} <- machine(root.vm_id, actor) do
      {:ok, thread}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  def get_thread(_, _), do: {:error, :forbidden}

  @spec events(String.t(), user(), pos_integer()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def events(thread_id, actor, limit \\ 100)

  def events(thread_id, %Marshall.Accounts.User{} = actor, limit)
      when is_binary(thread_id) and is_integer(limit) and limit in 1..200 do
    with {:ok, _thread} <- get_thread(thread_id, actor) do
      events =
        Event
        |> Ash.Query.filter(thread_id == ^thread_id and kind != :model_output)
        |> Ash.Query.sort(sequence: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

      {:ok, Enum.reverse(events)}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  def events(_, _, _), do: {:error, :forbidden}

  @spec turn(String.t(), user()) :: {:ok, map()} | {:error, term()}
  def turn(turn_id, %Marshall.Accounts.User{} = actor) when is_binary(turn_id) do
    with [%Turn{} = turn] <- Ledger.read!(Turn, id: turn_id),
         {:ok, _thread} <- get_thread(turn.thread_id, actor) do
      terminal =
        case turn.status do
          :completed ->
            case Ledger.read!(Event, turn_id: turn.id, kind: :assistant) do
              [%Event{body: %{"text" => text}}] -> %{text: text}
              _ -> %{}
            end

          :failed ->
            %{reason: turn.failure_reason}

          _ ->
            %{}
        end

      {:ok, Map.merge(%{id: turn.id, status: turn.status}, terminal)}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  def turn(_, _), do: {:error, :forbidden}

  # @cc [owner:ghuntley,label:security;concurrency] child-current-vm-write
  # Child creation MUST recheck current VM write access and persist its parent
  # event and content-free audit receipt in the same transaction.
  @spec spawn_child(String.t(), String.t(), user()) ::
          {:ok, Thread.t()} | {:error, term()}
  def spawn_child(parent_id, title, %Marshall.Accounts.User{} = actor)
      when is_binary(parent_id) and is_binary(title) and byte_size(title) in 1..256 do
    Ledger.transaction(
      fn ->
        parent = Ledger.lock!(Thread, parent_id) || Ledger.rollback(:not_found)
        [root] = Ledger.read!(Root, id: parent.root_id)

        vm =
          case Ledger.read!(VirtualMachine, id: root.vm_id) do
            [current] -> current
            _ -> Ledger.rollback(:machine_unavailable)
          end

        Marshall.Access.Authorization.require!(vm, actor, "write")
        if vm.desired_state == :deleted, do: Ledger.rollback(:machine_unavailable)

        child =
          Ledger.create!(Thread, :open, %{
            root_id: root.id,
            parent_thread_id: parent.id,
            created_by_id: actor.id,
            title: title
          })

        Ledger.create!(Event, :append, %{
          thread_id: parent.id,
          sequence: parent.next_event_sequence,
          kind: :child_spawned,
          body: %{"child_thread_id" => child.id}
        })

        Ledger.update!(parent, :advance, %{next_event_sequence: parent.next_event_sequence + 1})

        Ledger.create!(AuditEvent, :record, %{
          vm_id: vm.id,
          thread_id: child.id,
          actor_id: actor.id,
          kind: :child_created,
          target_id: child.id,
          outcome: :accepted
        })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("agent.child_created",
            vm_id: vm.id,
            thread_id: child.id,
            parent_thread_id: parent.id
          )
        end)

        child
      end,
      actor
    )
  end

  def spawn_child(_, _, _), do: {:error, :invalid_request}
end
