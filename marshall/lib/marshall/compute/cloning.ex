defmodule Marshall.Compute.Cloning do
  @moduledoc "Authorized clone queue admission, inspection and user recovery intent."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.Authorization
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{CloneRequest, Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] clone-queue-durable-admission
  # Every distinct actor/key MUST enqueue a separate destination. Exact retries
  # MUST return the pinned request and changed source/name inputs MUST conflict.
  # Authorization under the source VM lock and job insertion MUST share the
  # admission transaction. Queuing MUST NOT stop a VM or reserve host capacity.
  @impl true
  def run(input, options, context) do
    operation = options[:operation]

    result =
      Ledger.transaction(
        fn -> execute(operation, input.arguments, context.actor) end,
        context.actor
      )

    case result do
      {:ok, {view, %CloneRequest{} = accepted}} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("clone.accepted",
            vm_id: accepted.source_vm_id,
            clone_id: accepted.id,
            destination_vm_id: accepted.destination_vm_id
          )
        end

        {:ok, view}

      {:ok, view} ->
        {:ok, view}

      {:error, reason} when is_atom(reason) ->
        if operation == :submit and not Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("clone.submission_refused",
            vm_id: vm_id(input.arguments),
            reason: reason
          )
        end

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  defp vm_id(%{vm_id: id}), do: if(OverallsProtocol.uuid?(id), do: id, else: nil)

  defp execute(:submit, args, actor) do
    Marshall.Accounts.AccountLifecycle.admit!(actor.id)
    lock!("clone-request:#{actor.id}:#{args.idempotency_key}")

    case Ledger.read!(CloneRequest, requested_by_id: actor.id, request_key: args.idempotency_key) do
      [existing] ->
        authorize_history!(existing.source_vm_id, actor)

        unless existing.source_vm_id == args.vm_id and existing.requested_name == args[:name],
          do: Ledger.rollback(:idempotency_conflict)

        view(existing)

      [] ->
        id = Ash.UUID.generate()
        name = args[:name] || OverallsProtocol.MachineName.generated(id)
        lock!("vm-name:" <> name)
        reserve_name!(name)
        lock_source!(args.vm_id)
        Authorization.live_vm!(args.vm_id, actor, "manage")

        request =
          Ledger.create!(CloneRequest, :enqueue, %{
            source_vm_id: args.vm_id,
            requested_by_id: actor.id,
            request_key: args.idempotency_key,
            requested_name: args[:name],
            destination_vm_id: id,
            name: name,
            sequence: next_sequence(args.vm_id)
          })

        {view(request), request}
    end
  end

  defp execute(:list, args, actor) do
    authorize_history!(args.vm_id, actor)

    query =
      CloneRequest
      |> Ash.Query.filter(source_vm_id == ^args.vm_id and requested_by_id == ^actor.id)
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(args.limit)

    query = if args[:before], do: Ash.Query.filter(query, sequence < ^args.before), else: query
    %{requests: query |> Ash.read!(actor: SystemActor.compute()) |> Enum.map(&view/1)}
  end

  defp execute(operation, args, actor) do
    request =
      case Ledger.read!(CloneRequest, id: args.request_id) do
        [request] -> request
        [] -> Ledger.rollback(:forbidden)
      end

    lock_source!(request.source_vm_id)
    authorize_history!(request.source_vm_id, actor)
    request = Ledger.lock!(CloneRequest, request.id)
    unless request.requested_by_id == actor.id, do: Ledger.rollback(:forbidden)

    case operation do
      :get -> view(request)
      :cancel -> cancel!(request) |> view()
      :retry -> retry!(request) |> view()
    end
  end

  defp authorize_history!(id, actor) do
    # Admission/status acquire no host lock after this VM authorization lock.
    vm =
      VirtualMachine
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!()

    unless vm, do: Ledger.rollback(:forbidden)
    Authorization.require!(vm, actor, "manage")
  end

  defp cancel!(%{phase: phase} = request) when phase in [:cancelled, :cancelling], do: request

  defp cancel!(%{published_at: published}) when not is_nil(published),
    do: Ledger.rollback(:clone_already_published)

  defp cancel!(%{active: false} = request) do
    now = Ledger.now()

    Ledger.update!(request, :cancel, %{
      finished_at: now,
      name_released_at: now
    })
  end

  defp cancel!(request) do
    request
    |> Ledger.update!(:request_cancel, %{cancel_requested_at: Ledger.now()})
    |> Ledger.update!(:schedule, %{})
  end

  defp retry!(%{phase: :failed, active: false, snapshot: nil} = request) do
    request
    |> Ledger.update!(:retry, %{
      finished_at: nil,
      failure: nil,
      sequence: next_sequence(request.source_vm_id)
    })
    |> Ledger.update!(:schedule, %{})
  end

  defp retry!(%{active: true, failure: failure} = request) when not is_nil(failure),
    do:
      request
      |> Ledger.update!(:record_progress, %{
        failure:
          case failure do
            "source_restart_failed" -> "retry_source_restart"
            "source_stop_failed" -> "retry_source_stop"
            _ -> nil
          end
      })
      |> Ledger.update!(:schedule, %{})

  defp retry!(_), do: Ledger.rollback(:clone_not_retryable)

  @doc false
  @spec lock_source!(String.t()) :: :ok
  def lock_source!(id), do: lock!("clone-source:" <> id)

  @doc false
  @spec reserve_name!(String.t(), String.t() | nil) :: :ok
  def reserve_name!(name, destination_id \\ nil) do
    if Ledger.read!(VirtualMachine, name: name) != [] or
         Enum.any?(
           Ledger.read!(CloneRequest, name: name, name_released_at: [is_nil: true]),
           &(&1.destination_vm_id != destination_id)
         ),
       do: Ledger.rollback(:name_unavailable)

    :ok
  end

  defp next_sequence(id) do
    query =
      CloneRequest
      |> Ash.Query.filter(source_vm_id == ^id)
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(1)

    case Ash.read!(query, actor: SystemActor.compute()) do
      [] -> 1
      [request] -> request.sequence + 1
    end
  end

  defp lock!(key) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [key],
      log: false
    )

    :ok
  end

  @doc false
  @spec view(CloneRequest.t()) :: map()
  def view(request) do
    position =
      if request.phase == :queued do
        CloneRequest
        |> Ash.Query.filter(
          source_vm_id == ^request.source_vm_id and is_nil(finished_at) and
            sequence <= ^request.sequence
        )
        |> Ash.count!(actor: SystemActor.compute())
      end

    request
    |> Map.take([
      :id,
      :source_vm_id,
      :destination_vm_id,
      :name,
      :phase,
      :active,
      :failure,
      :original_power_state,
      :source_restored_at,
      :published_at,
      :finished_at,
      :cleanup_deadline_at,
      :cleanup_completed_at,
      :deferred_reason,
      :inserted_at
    ])
    |> Map.put(:queue_position, position)
  end
end
