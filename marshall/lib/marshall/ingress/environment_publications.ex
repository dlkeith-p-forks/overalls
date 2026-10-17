defmodule Marshall.Ingress.EnvironmentPublications do
  @moduledoc "Host-then-VM serialized, short-lived child publication authority."
  alias Marshall.Compute.{Credentials, Ledger, VirtualMachine}
  alias Marshall.Ingress.{Environment, EnvironmentPublication}

  @binding [
    :host_id,
    :placement_id,
    :execution_epoch,
    :vm_generation,
    :environment_generation,
    :session_id,
    :host_epoch
  ]

  # @cc [owner:ghuntley,label:security;concurrency] inception-publication-current-authority
  # Callers MUST supply a validated InceptionControl request. Each exchange MUST
  # authenticate the current host session, then lock the VM and require its exact
  # current Inception execution and enabled environment. Proof bootstrap MUST NOT
  # require completed public readiness. Offers MUST be single-use, expire within
  # five seconds and bind all execution/session/environment revisions. Accepting
  # a result MUST cap the original offer deadline by the child remaining TTL
  # measured from offer creation, never extend authority from receipt.
  # Parent SSH discovery MUST use this operator-configured public endpoint and
  # the current environment namespace, never host-provided or request headers.
  @spec exchange(binary(), map()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    Credentials.with_host(token, fn host ->
      now = Ledger.now()

      unless host.enabled and host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch and
               Marshall.Compute.HostLiveness.authority?(
                 host.connection_session_id,
                 host.reported_at,
                 now
               ),
             do: Ledger.rollback(:stale_connection)

      vm = Ledger.lock!(VirtualMachine, message.vm_id) || Ledger.rollback(:unauthorized)

      unless vm.profile == :inception and vm.host_id == host.id and vm.desired_state == :running and
               vm.current_placement_id == message.placement_id and
               vm.execution_epoch == message.execution_epoch and
               vm.generation == message.generation,
             do: Ledger.rollback(:unauthorized)

      environment =
        case Ledger.read!(Environment, vm_id: vm.id) do
          [%{enabled: true} = row] -> row
          _ -> Ledger.rollback(:unauthorized)
        end

      zone = Application.get_env(:marshall, :ingress_zone)

      unless match?({:ok, _}, OverallsProtocol.InceptionName.origins(environment.label, zone)),
        do: Ledger.rollback(:temporarily_unavailable)

      binding = %{
        host_id: host.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        vm_generation: vm.generation,
        environment_generation: environment.generation,
        session_id: host.connection_session_id,
        host_epoch: host.connection_epoch
      }

      existing =
        case Ledger.read!(EnvironmentPublication, vm_id: vm.id) do
          [row] -> row
          [] -> nil
        end

      # Re-read database time after potentially waiting for the VM lock.
      now = Ledger.now()
      {payload, expires} = accept!(existing, binding, message.result, now)

      offer =
        Map.merge(binding, %{
          offer_id: Ash.UUID.generate(),
          offer_expires_at: DateTime.add(now, 5, :second)
        })

      if existing do
        Ledger.update!(
          existing,
          :advance,
          Map.merge(offer, %{payload: payload, expires_at: expires})
        )
      else
        Ledger.create!(EnvironmentPublication, :record, Map.put(offer, :vm_id, vm.id))
      end

      %{
        "version" => 4,
        "host_id" => host.id,
        "session_id" => host.connection_session_id,
        "epoch" => host.connection_epoch,
        "offer_id" => offer.offer_id,
        "vm_id" => vm.id,
        "placement_id" => vm.current_placement_id,
        "execution_epoch" => vm.execution_epoch,
        "generation" => vm.generation,
        "environment_generation" => environment.generation,
        "label" => environment.label,
        "zone" => zone,
        "public" => Application.get_env(:marshall, :inception_public),
        "parent" => %{
          "origin" => MarshallWeb.Endpoint.url(),
          "label" => environment.label,
          "zone" => zone
        },
        "ttl_ms" => 5000
      }
    end)
  end

  defp accept!(nil, _, nil, _), do: {nil, nil}

  defp accept!(row, binding, nil, now) do
    if row && Map.take(row, @binding) == binding && row.expires_at &&
         DateTime.compare(row.expires_at, now) == :gt,
       do: {row.payload, row.expires_at},
       else: {nil, nil}
  end

  defp accept!(row, binding, result, now) do
    unless row && Map.take(row, @binding) == binding && row.offer_id == result.offer_id &&
             DateTime.compare(row.offer_expires_at, now) == :gt &&
             result.publication["generation"] == binding.environment_generation &&
             result.publication["binding"]["placement_id"] == binding.placement_id &&
             result.publication["binding"]["execution_epoch"] == binding.execution_epoch,
           do: Ledger.rollback(:invalid_outcome)

    expires =
      DateTime.add(row.offer_expires_at, result.publication["ttl_ms"] - 5000, :millisecond)

    unless DateTime.compare(expires, now) == :gt, do: Ledger.rollback(:invalid_outcome)
    {result.publication, expires}
  end
end
