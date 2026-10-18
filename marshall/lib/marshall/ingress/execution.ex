defmodule Marshall.Ingress.Execution do
  @moduledoc "Locked current gateway execution checks shared by ingress coordinators."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, VirtualMachine}
  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] ingress-current-execution
  # Callers MUST hold the service row lock before checking execution. Checks MUST
  # lock host then VM, require exact gateway/placement/epoch/generation binding,
  # fresh running evidence and completed start/provision/resume with relocation ready.
  # Neither a certificate receipt nor wake discovery may bypass these checks.
  # Ingress.Publications MAY retain sleeping or prior-gateway discovery; its
  # weaker predicate MUST NOT substitute for this execution check.
  @spec current!(struct(), map(), :shared | :exclusive) :: {struct(), struct(), DateTime.t()}
  def current!(service, request, mode), do: current!(service, request, mode, :admit)

  # @cc [owner:ghuntley,label:security;recovery] ingress-renewal-host-reconnecting
  # For :renew, a host that is enabled, not retired and carries an otherwise
  # current execution, but whose provisioner is reconnecting (no connection
  # session, or a new session without its first report), MUST pass this check
  # so the caller still applies every conclusive authority check; the caller
  # MUST then call renewable!/2 before extending the lease, which refuses with
  # :temporarily_unavailable that Audi retries within the unchanged lease
  # (ADR-0192). Every other failure, and every :admit failure, stays
  # :unauthorized: a changed host, VM binding, desired or observed state,
  # relocation readiness or start operation, and an aged-out report remain
  # conclusive.
  @spec current!(struct(), map(), :shared | :exclusive, :admit | :renew) ::
          {struct(), struct(), DateTime.t()}
  def current!(service, request, mode, purpose) when purpose in [:admit, :renew] do
    unless service.enabled and service.role == :gateway and
             service.generation == request.service_generation and
             service.addresses != [] and is_binary(service.ssh_host_key), do: deny!()

    host = shared!(Host, id: service.host_id)

    vm =
      if mode == :shared,
        do: shared!(VirtualMachine, id: request.vm_id),
        else: Ledger.lock!(VirtualMachine, request.vm_id) || deny!()

    now = Ledger.now()

    unless host.enabled and host.maintenance_mode != :retired and
             vm.host_id == host.id and vm.current_placement_id == request.placement_id and
             vm.execution_epoch == request.execution_epoch and vm.generation == request.generation and
             vm.desired_state == :running and vm.observed_state == :running and
             Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm),
           do: deny!()

    unless is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               now
             ) do
      unless purpose == :renew and reconnecting?(host), do: deny!()
    end

    started? =
      Operation
      |> Ash.Query.filter(
        vm_id == ^vm.id and placement_id == ^vm.current_placement_id and
          execution_epoch == ^vm.execution_epoch and generation == ^vm.generation and
          status == :completed and kind in [:provision, :start, :resume]
      )
      |> Ash.exists?(actor: SystemActor.compute())

    unless started?, do: deny!()

    {vm, host, now}
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-nonexecuting-target
  # Discovery and wake policy MAY inspect suspended current placements under
  # host-before-VM locks. This MUST NOT prove running execution or permit a socket.
  # A changed placement during locking or an expected-host mismatch MUST refuse
  # rather than lock its new host.
  @doc false
  @spec target!(String.t(), String.t() | nil) :: {VirtualMachine.t(), Host.t(), DateTime.t()}
  def target!(id, expected_host_id \\ nil) do
    candidate = List.first(Ledger.read!(VirtualMachine, id: id)) || deny!()
    unless is_nil(expected_host_id) or candidate.host_id == expected_host_id, do: deny!()
    host = shared!(Host, id: candidate.host_id)
    vm = Ledger.lock!(VirtualMachine, id) || deny!()
    now = Ledger.now()

    unless vm.host_id == host.id and vm.current_placement_id == candidate.current_placement_id and
             vm.execution_epoch == candidate.execution_epoch and is_nil(vm.archived_at) and
             vm.desired_state != :deleted and host.enabled and host.maintenance_mode != :retired and
             is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               now
             ),
           do: deny!()

    {vm, host, now}
  end

  # @cc [owner:ghuntley,label:security;recovery] ingress-discovery-wake-only
  # Discovery MAY retain the authenticated previous gateway across a move when
  # both gateways have fleet relay enrollment. It MUST require live gateway and
  # current-host authority and a nondeleted running or suspended intent. Reports
  # MUST carry the current VM tuple; reads MAY retain an older discovery tuple.
  # This projection MUST never substitute for current!/3 at stream admission.
  @doc false
  @spec discover!(struct(), map(), :shared | :exclusive) ::
          {VirtualMachine.t(), Host.t(), DateTime.t()}
  def discover!(service, binding, mode) do
    gateway_host = shared!(Host, id: service.host_id)
    {vm, host, now} = target!(binding.vm_id)
    remote? = host.id != service.host_id

    unless service.enabled and service.role == :gateway and
             service.generation == binding.service_generation and service.addresses != [] and
             is_binary(service.ssh_host_key) and gateway_host.enabled and
             gateway_host.maintenance_mode != :retired and
             Marshall.Compute.HostLiveness.authority?(
               gateway_host.connection_session_id,
               gateway_host.reported_at,
               now
             ) and
             vm.desired_state in [:running, :paused] and
             vm.observed_state not in [:deleted, :failed] and
             (not remote? or relay_origin?(service, vm)) and
             (mode == :shared or
                (vm.current_placement_id == binding.placement_id and
                   vm.execution_epoch == binding.execution_epoch and
                   vm.generation == binding.generation)),
           do: deny!()

    {vm, gateway_host, now}
  end

  @spec relay_origin?(struct(), VirtualMachine.t()) :: boolean()
  defp relay_origin?(service, vm) do
    OverallsProtocol.IngressRelay.fleet_address?(service.relay_address) and
      Enum.any?(
        Ledger.read!(Marshall.Ingress.Service,
          host_id: vm.host_id,
          role: :gateway,
          enabled: true
        ),
        &OverallsProtocol.IngressRelay.fleet_address?(&1.relay_address)
      ) and
      Enum.any?(
        Ledger.read!(Marshall.Ingress.Route, vm_id: vm.id),
        &(&1.service_id == service.id)
      )
  end

  # @cc [owner:ghuntley,label:security] ingress-login-without-execution
  # Browser identity exchange MAY precede wake. It MUST bind the current VM and
  # gateway generation and refuse deleted/failed machines; it MUST NOT create
  # a stream or treat sleeping discovery as running evidence.
  @doc false
  @spec login!(struct(), map()) :: {VirtualMachine.t(), Host.t(), DateTime.t()}
  def login!(service, binding) do
    {vm, host, _} = result = target!(binding.vm_id)

    unless service.enabled and service.role == :gateway and
             service.generation == binding.service_generation and
             vm.current_placement_id == binding.placement_id and
             vm.execution_epoch == binding.execution_epoch and
             vm.generation == binding.generation and vm.desired_state in [:running, :paused] and
             vm.observed_state in [:running, :paused] and
             Map.get(binding, :host_id, host.id) == host.id and
             (service.host_id == host.id or
                OverallsProtocol.IngressRelay.fleet_address?(service.relay_address)),
           do: deny!()

    result
  end

  # @cc [owner:ghuntley,label:security] web-profile-admission
  # Web admission and renewal MUST reject profiles without web capability under the
  # current VM lock, before any public-access or credential exception.
  @spec web!(struct(), map(), :shared | :exclusive, :admit | :renew) ::
          {struct(), struct(), DateTime.t()}
  def web!(service, request, mode, purpose \\ :admit) do
    {vm, _, _} = result = current!(service, request, mode, purpose)
    unless OverallsProtocol.ProfilePolicy.allows?(vm.profile, :web), do: deny!()
    result
  end

  @doc """
  Refuses a renewal, after its conclusive checks, while the provisioner is
  reconnecting. The refusal is inconclusive: the lease is left unchanged.
  """
  @spec renewable!(struct(), DateTime.t()) :: :ok
  def renewable!(host, now) do
    unless is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               now
             ),
           do: Ledger.rollback(:temporarily_unavailable)

    :ok
  end

  defp shared!(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!(actor: SystemActor.compute()) || deny!()
  end

  # Disconnected (the session was cleared) or a new session that has not yet
  # reported: the provisioner is restarting or reconnecting.
  defp reconnecting?(host),
    do: not is_binary(host.connection_session_id) or is_nil(host.reported_at)

  defp deny!, do: Ledger.rollback(:unauthorized)
end
