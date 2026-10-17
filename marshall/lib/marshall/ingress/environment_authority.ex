defmodule Marshall.Ingress.EnvironmentAuthority do
  @moduledoc "Locked current publication and namespace checks for nested stream coordinators."
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Environment, EnvironmentPublication, Execution}

  # @cc [owner:ghuntley,label:security;concurrency] inception-current-stream-authority
  # Callers MUST hold the authenticated gateway service lock through commit.
  # Checks MUST lock host then VM and require completed current Inception execution,
  # exact environment policy and publication host/session/execution bindings.
  # Stream authority MUST NOT outlive the publication or five seconds. HTTPS
  # requires a ready child record; SSH requires the selected published host key.
  # This listener permission MUST NOT imply membership in the child deployment.
  @spec current!(struct(), map(), OverallsProtocol.InceptionName.service()) :: map()
  def current!(service, binding, kind)
      when kind in [:control_https, :audi_https, :porsche_ssh, :audi_ssh] do
    {vm, host, _} = Execution.current!(service, binding, :exclusive)
    unless vm.profile == :inception, do: deny!()
    environment = one!(Environment, vm.id)
    publication = one!(EnvironmentPublication, vm.id)

    unless environment.enabled and environment.label == binding.label and
             environment.generation == binding.environment_generation and
             publication.host_id == host.id and
             publication.placement_id == vm.current_placement_id and
             publication.execution_epoch == vm.execution_epoch and
             publication.vm_generation == vm.generation and
             publication.environment_generation == environment.generation and
             publication.session_id == host.connection_session_id and
             publication.host_epoch == host.connection_epoch,
           do: deny!()

    now = Ledger.now()
    unless publication.expires_at, do: deny!()
    ttl = min(5000, DateTime.diff(publication.expires_at, now, :millisecond))
    unless ttl > 0, do: deny!()
    payload = publication.payload
    unless is_map(payload), do: deny!()
    key = listener!(payload, kind)

    %{
      ttl: ttl,
      expires_at: DateTime.add(now, ttl, :millisecond),
      host_session_id: host.connection_session_id,
      host_epoch: host.connection_epoch,
      host_key: key
    }
  end

  def current!(_, _, _), do: deny!()

  defp listener!(payload, kind) when kind in [:porsche_ssh, :audi_ssh] do
    field = if kind == :porsche_ssh, do: "porsche_host_key", else: "audi_host_key"

    case OverallsProtocol.SSHKey.parse(payload[field]) do
      {:ok, key} -> key.public_key
      _ -> deny!()
    end
  end

  defp listener!(payload, kind) do
    ready =
      Enum.any?(Map.get(payload, "records", []), fn record ->
        record["ready"] == true and
          if(kind == :control_https,
            do: record["label"] == "control",
            else: OverallsProtocol.IngressName.valid_label?(record["label"])
          )
      end)

    unless ready, do: deny!()
    nil
  end

  defp one!(resource, vm) do
    case Ledger.read!(resource, vm_id: vm) do
      [row] -> row
      _ -> deny!()
    end
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
