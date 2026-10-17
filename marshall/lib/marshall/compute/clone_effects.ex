defmodule Marshall.Compute.CloneEffects do
  @moduledoc "Authenticated, host-bound clone work and immutable physical receipts."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{CloneEffect, CloneFailure, CloneRequest, Credentials, Host, Ledger}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] clone-effect-receipts-immutable
  # Receipts MUST match an offered effect on the authenticated current host
  # session. Conflicting replays MUST fail. A capture receipt MUST preserve the
  # exact admitted clone intent. Host receipts enqueue reconciliation atomically;
  # they do not independently publish machines or release reservations.
  @spec exchange(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    with {:ok, {response, events}} <- exchange_locked(token, message) do
      unless Marshall.Repo.in_transaction?(), do: Enum.each(events, &emit/1)
      {:ok, response}
    end
  end

  defp exchange_locked(token, message) do
    Credentials.with_host(token, fn host ->
      unless host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch,
             do: Ledger.rollback(:stale_connection)

      receipts = Enum.map(message.results, &accept!(host.id, &1))
      accepted = Enum.map(receipts, &elem(&1, 0))
      events = receipts |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

      effects =
        CloneEffect
        |> Ash.Query.filter(host_id == ^host.id)
        |> Ash.Query.filter(
          clone_request.active == true or
            (kind == :prune and is_nil(clone_request.cleanup_completed_at))
        )
        |> Ash.Query.filter(is_nil(completed_at) or kind in [:capture, :probe])
        |> Ash.Query.sort(inserted_at: :asc)
        |> Ash.Query.limit(16)
        |> Ash.read!(actor: SystemActor.compute())

      commands =
        Enum.flat_map(effects, fn effect ->
          case Ledger.read!(CloneRequest, id: effect.clone_request_id) do
            [request] -> if offered?(effect, request), do: [command(effect, request)], else: []
            [] -> []
          end
        end)

      {%{
         "version" => 5,
         "host_id" => host.id,
         "session_id" => message.session_id,
         "epoch" => host.connection_epoch,
         "commands" => commands,
         "acknowledgements" => accepted
       }, events}
    end)
  end

  # @cc [owner:ghuntley,label:observability] clone-effect-diagnostics-after-commit
  # Effect diagnostics MUST be emitted only after the exchange transaction
  # commits and only on a change: the first unconfirmed receipt, each change of
  # the closed host reason, and the confirmation that ends a run of unconfirmed
  # attempts. Repeated identical receipts MUST NOT log again.
  defp emit({:unconfirmed, clone_id, host_id, kind, reason, attempt}),
    do:
      Marshall.Events.emit("clone.effect_unconfirmed",
        clone_id: clone_id,
        host_id: host_id,
        effect: kind,
        reason: reason,
        attempt: attempt
      )

  defp emit({:confirmed, clone_id, host_id, kind, attempt}),
    do:
      Marshall.Events.emit("clone.effect_confirmed",
        clone_id: clone_id,
        host_id: host_id,
        effect: kind,
        attempt: attempt
      )

  defp accept!(host, wire) do
    effect = Ledger.lock!(CloneEffect, wire["id"]) || Ledger.rollback(:invalid_outcome)

    unless effect.offered_at != nil and effect.host_id == host and
             Atom.to_string(effect.kind) == wire["kind"],
           do: Ledger.rollback(:invalid_outcome)

    request = Ledger.lock!(CloneRequest, effect.clone_request_id)
    result = wire["result"]

    if effect.kind == :capture and not Map.has_key?(result, "error") do
      {:ok, descriptor} = OverallsProtocol.DiskTransfer.descriptor(result["descriptor"])

      unless OverallsProtocol.DiskTransfer.encode_intent(descriptor) == intent(request),
        do: Ledger.rollback(:invalid_outcome)
    end

    case result do
      # A late unconfirmed replay after the receipt landed changes nothing:
      # the receipt is immutable and the attempt history already closed.
      %{"error" => "unconfirmed"} when effect.result != nil ->
        {effect.id, nil}

      %{"error" => "unconfirmed", "reason" => reason} ->
        {:ok, failure} =
          with :error <- CloneFailure.unconfirmed(effect.kind, reason),
               do: Ledger.rollback(:invalid_outcome)

        if request.finished_at == nil and
             request.failure not in ["source_restart_failed", "retry_source_restart"] do
          Ledger.update!(request, :record_progress, %{failure: failure})
        end

        changed = effect.unconfirmed_reason != reason
        attempt = effect.unconfirmed_count + 1

        Ledger.update!(effect, :record_unconfirmed, %{
          unconfirmed_reason: reason,
          unconfirmed_count: attempt,
          unconfirmed_at: Ledger.now()
        })

        event =
          if changed,
            do:
              {:unconfirmed, request.id, host, effect.kind, CloneFailure.reason_atom(failure),
               attempt}

        {effect.id, event}

      ^result when effect.result == result ->
        {effect.id, nil}

      _ when effect.result != nil ->
        Ledger.rollback(:outcome_conflict)

      _ ->
        # An already offered effect may finish after cancellation. Retain that
        # evidence without reviving the phase; cancellation still owns cleanup.
        Ledger.update!(effect, :complete, %{result: result, completed_at: Ledger.now()})

        if CloneFailure.effect_atom(request.failure) == effect.kind,
          do: Ledger.update!(request, :record_progress, %{failure: nil})

        Ledger.update!(request, :schedule, %{})

        event =
          if effect.unconfirmed_count > 0,
            do: {:confirmed, request.id, host, effect.kind, effect.unconfirmed_count}

        {effect.id, event}
    end
  end

  defp offered?(effect, request) do
    cond do
      # A completed request keeps offering its source prune until confirmed.
      not request.active -> effect.kind == :prune and is_nil(request.cleanup_completed_at)
      effect.kind in [:revoke, :discard, :prune] -> true
      request.cancel_requested_at != nil -> false
      effect.kind == :probe -> request.phase == :preparing
      effect.kind == :capture -> request.phase in [:capturing, :copying, :publishing]
      true -> effect.completed_at == nil
    end
  end

  defp command(effect, request) do
    if effect.offered_at == nil, do: Ledger.update!(effect, :offer, %{offered_at: Ledger.now()})
    [source] = Ledger.read!(Host, id: request.source_host_id)
    [prepare] = Ledger.read!(CloneEffect, clone_request_id: request.id, kind: :prepare)
    now = DateTime.to_unix(Ledger.now())

    command = %{
      "id" => effect.id,
      "clone_id" => request.id,
      "host_id" => effect.host_id,
      "kind" => Atom.to_string(effect.kind),
      "endpoint" => Atom.to_string(effect.endpoint),
      "intent" => intent(request),
      "descriptor" => request.snapshot && request.snapshot["descriptor"],
      "public_key" => prepare.result && prepare.result["public_key"],
      "source_endpoint" => source.transfer_endpoint,
      "source_generation" => effect.payload["source_generation"],
      "revision" => now,
      "expires_at" => now + 180
    }

    case OverallsProtocol.CloneControl.command(command) do
      {:ok, command} -> command
      _ -> Ledger.rollback(:invalid_clone_command)
    end
  end

  @doc false
  @spec intent(CloneRequest.t()) :: map()
  def intent(request) do
    s = request.specification["source"]
    d = request.specification["destination"]

    %{
      "version" => 3,
      "purpose" => "clone",
      "relocation_id" => request.id,
      "vm_id" => s["vm_id"],
      "destination_vm_id" => d["vm_id"],
      "source_slot" => s["slot"],
      "source" => Map.take(s, ["placement_id", "host_id", "pool_id"]),
      "destination" => Map.take(d, ["placement_id", "host_id", "pool_id"]),
      "source_epoch" => s["execution_epoch"],
      "destination_epoch" => d["execution_epoch"],
      "workload" => Map.put(request.specification["workload"], "slot", d["slot"])
    }
  end
end
