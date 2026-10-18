defmodule Marshall.Threads.ProvisionWorker do
  @moduledoc "Retries durable thread machine admission and binds the agent identity."
  use Oban.Worker,
    queue: :provisioning,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:thread_id, :machine_key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Ash.Query
  require Marshall.Events
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{Generation, MachineSpec, Thread}

  @impl true
  @spec perform(Oban.Job.t()) ::
          :ok | {:error, term()} | {:snooze, pos_integer()} | {:cancel, :invalid_job}
  def perform(%Oban.Job{args: %{"thread_id" => thread_id, "machine_key" => machine_key}})
      when is_binary(thread_id) and is_binary(machine_key) and byte_size(machine_key) > 0 do
    case claim(thread_id, machine_key) do
      :done -> :ok
      {:ok, thread} -> provision(thread)
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_job}

  @spec claim(String.t(), String.t()) :: :done | {:ok, Thread.t()} | {:error, term()}
  defp claim(thread_id, expected_key) do
    transact(fn ->
      case Ledger.lock_history!(Thread, thread_id) do
        nil ->
          :done

        %Thread{status: status} when status in [:ready, :archived, :deleting] ->
          :done

        %Thread{} = thread ->
          if thread.machine_key == expected_key do
            Generation.ensure_current!(thread)
            updated = Ledger.update!(thread, :bind_machine, %{status: :provisioning})
            Generation.sync!(updated)
            {:ok, updated}
          else
            :done
          end
      end
    end)
  end

  # @cc [owner:ghuntley,label:concurrency;durability] thread-admission-binding-atomic
  # Compute admission and recording its VM identity MUST retain the thread lock
  # until both commit. Archive MUST see the admitted machine, and an obsolete
  # machine generation MUST NOT admit or bind a replacement machine.
  @spec provision(Thread.t()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  defp provision(thread) do
    result =
      transact(fn ->
        case active_generation(thread) do
          :done ->
            :done

          {:ok, current} ->
            with {:ok, spec} <- MachineSpec.from_map(current.machine_spec),
                 {:ok, actor} <- actor(current.creator_id),
                 {:ok, vm} <-
                   Marshall.Compute.provision(
                     Map.put(spec, :idempotency_key, current.machine_key),
                     actor: actor
                   ) do
              if current.machine_id == nil do
                machine = Ledger.lock!(Marshall.Compute.VirtualMachine, vm.id)
                Marshall.Compute.Idle.enable_locked!(machine)
              end

              bound = Ledger.update!(current, :bind_machine, %{machine_id: vm.id})
              Generation.sync!(bound)
              {:ok, bound, actor, vm}
            else
              {:error, reason} -> Ledger.rollback(error_reason(reason))
            end
        end
      end)

    case result do
      :done -> :ok
      {:ok, bound, actor, vm} -> continue_after_admission(bound, actor, vm)
      {:error, reason} -> fail(thread, reason)
    end
  end

  @spec continue_after_admission(
          Thread.t(),
          Marshall.Accounts.User.t(),
          Marshall.Compute.VirtualMachine.t()
        ) ::
          :ok | {:error, term()} | {:snooze, pos_integer()}
  defp continue_after_admission(thread, actor, vm) do
    case wait_for_running(vm) do
      {:error, :machine_not_ready} ->
        {:snooze, 5}

      {:error, reason} ->
        fail(thread, reason)

      {:ok, running_vm} ->
        case activate(thread, actor, running_vm) do
          :done -> :ok
          {:ok, _ready} -> :ok
          {:error, :machine_not_ready} -> {:snooze, 5}
          {:error, reason} -> fail(thread, reason)
        end
    end
  end

  @spec wait_for_running(Marshall.Compute.VirtualMachine.t()) ::
          {:ok, Marshall.Compute.VirtualMachine.t()} | {:error, atom()}
  defp wait_for_running(vm) do
    case Ledger.history!(Marshall.Compute.VirtualMachine, id: vm.id) do
      [
        %Marshall.Compute.VirtualMachine{
          archived_at: nil,
          desired_state: :running,
          observed_state: :running
        } = current
      ] ->
        {:ok, current}

      [
        %Marshall.Compute.VirtualMachine{
          archived_at: nil,
          desired_state: :running,
          observed_state: state
        }
      ]
      when state in [:pending, :unknown] ->
        {:error, :machine_not_ready}

      _ ->
        {:error, :machine_unavailable}
    end
  end

  @spec actor(String.t()) :: {:ok, Marshall.Accounts.User.t()} | {:error, :machine_unavailable}
  defp actor(id) do
    case Marshall.Accounts.User
         |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
         |> Ash.Query.filter(id == ^id)
         |> Ash.read(actor: SystemActor.compute()) do
      {:ok, [%Marshall.Accounts.User{} = user]} -> {:ok, user}
      _ -> {:error, :machine_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:concurrency;recovery] thread-generation-fences-effects
  # Agent binding, initial prompt admission, readiness and failure cleanup MUST
  # recheck the current machine generation under the thread lock. An old job MUST
  # NOT modify a reopened generation or delete a machine already made ready.
  @spec activate(Thread.t(), Marshall.Accounts.User.t(), Marshall.Compute.VirtualMachine.t()) ::
          :done | {:ok, Thread.t()} | {:error, term()}
  defp activate(thread, actor, vm) do
    transact(fn ->
      case active_generation(thread) do
        :done ->
          :done

        {:ok, current} ->
          unless current.machine_id == vm.id, do: Ledger.rollback(:machine_unavailable)
          lock_running_vm!(vm)
          root = agent_root!(vm.id)
          agent_thread = agent_thread!(root.id)
          Ledger.update!(agent_thread, :set_mode, %{mode: current.mode})

          bound =
            Ledger.update!(current, :bind_machine, %{
              agent_root_id: root.id,
              agent_thread_id: agent_thread.id,
              status: :provisioning,
              failure_reason: nil
            })

          Generation.sync!(bound)

          case Marshall.Agents.submit_prompt(
                 %{
                   thread_id: agent_thread.id,
                   prompt: bound.objective,
                   request_key: "thread-initial:" <> bound.id,
                   collaboration_mode: bound.collaboration_mode,
                   selected_skill_ids: bound.initial_skill_ids
                 },
                 actor: actor
               ) do
            {:ok, _turn} ->
              ready = Ledger.update!(bound, :bind_machine, %{status: :ready, failure_reason: nil})
              Generation.sync!(ready)
              Marshall.Threads.TitleWorker.new(%{"thread_id" => ready.id}) |> Oban.insert!()
              {:ok, ready}

            {:error, reason} ->
              Ledger.rollback(error_reason(reason))
          end
      end
    end)
  end

  @spec lock_running_vm!(Marshall.Compute.VirtualMachine.t()) :: :ok
  defp lock_running_vm!(vm) do
    host = Ledger.lock!(Marshall.Compute.Host, vm.host_id)
    current = Ledger.lock_history!(Marshall.Compute.VirtualMachine, vm.id)

    unless host && current && current.host_id == host.id &&
             current.archived_at == nil && current.desired_state == :running &&
             current.observed_state == :running do
      Ledger.rollback(:machine_not_ready)
    end

    :ok
  end

  @spec agent_root!(String.t()) :: Marshall.Agents.Root.t()
  defp agent_root!(vm_id) do
    case Ledger.read!(Marshall.Agents.Root, vm_id: vm_id) do
      [%Marshall.Agents.Root{} = root] -> root
      _ -> Ledger.rollback(:agent_unavailable)
    end
  end

  @spec agent_thread!(String.t()) :: Marshall.Agents.Thread.t()
  defp agent_thread!(root_id) do
    case Marshall.Agents.Thread
         |> Ash.Query.filter(root_id == ^root_id and is_nil(parent_thread_id))
         |> Ash.read!(actor: SystemActor.compute()) do
      [%Marshall.Agents.Thread{} = thread] -> thread
      _ -> Ledger.rollback(:agent_unavailable)
    end
  end

  @spec active_generation(Thread.t()) :: :done | {:ok, Thread.t()}
  defp active_generation(expected) do
    case Ledger.lock_history!(Thread, expected.id) do
      %Thread{status: status} = current when status in [:pending, :provisioning, :failed] ->
        if current.machine_key == expected.machine_key,
          do: {:ok, current},
          else: :done

      _ ->
        :done
    end
  end

  @spec fail(Thread.t(), term()) :: :ok | {:error, term()}
  defp fail(thread, reason) do
    normalized = normalize_reason(error_reason(reason))

    case transact(fn ->
           case active_generation(thread) do
             :done ->
               :done

             {:ok, current} ->
               cleanup_vm(current)

               failed =
                 Ledger.update!(current, :mark_failed, %{
                   status: :failed,
                   failure_reason: normalized
                 })

               Generation.sync!(failed)

               Ledger.after_commit(fn ->
                 Marshall.Events.emit("thread.provision_failed",
                   thread_id: thread.id,
                   reason: normalized
                 )
               end)

               :failed
           end
         end) do
      :done -> :ok
      _ -> {:error, reason}
    end
  end

  @spec cleanup_vm(Thread.t()) :: :ok
  defp cleanup_vm(%Thread{machine_id: nil}), do: :ok

  defp cleanup_vm(thread) do
    with {:ok, actor} <- actor(thread.creator_id),
         [%{archived_at: nil, desired_state: desired_state}] when desired_state != :deleted <-
           Ledger.history!(Marshall.Compute.VirtualMachine, id: thread.machine_id) do
      case Marshall.Compute.lifecycle(
             %{
               vm_id: thread.machine_id,
               kind: :delete,
               idempotency_key: "thread-cleanup:" <> thread.machine_id
             },
             actor: actor
           ) do
        {:ok, _operation} -> :ok
        {:error, reason} -> Ledger.rollback(error_reason(reason))
      end
    else
      _ -> :ok
    end
  end

  @spec transact((-> result)) :: result | {:error, term()} when result: term()
  defp transact(fun) do
    case Ledger.transaction(fun, {:system, nil}) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec error_reason(term()) :: atom()
  defp error_reason(%Marshall.Compute.Error{reason: reason}), do: reason
  defp error_reason(%{errors: [error | _]}), do: error_reason(error)
  defp error_reason(reason) when is_atom(reason), do: reason
  defp error_reason(_), do: :provision_failed

  @spec normalize_reason(atom()) :: atom()
  defp normalize_reason(reason)
       when reason in [
              :invalid_machine_spec,
              :invalid_profile,
              :machine_unavailable,
              :agent_unavailable
            ],
       do: reason

  defp normalize_reason(_), do: :provision_failed
end
