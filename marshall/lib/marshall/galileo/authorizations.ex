defmodule Marshall.Galileo.Authorizations do
  @moduledoc "Per-request integration authorization with full execution fencing."
  alias Marshall.Accounts.Security
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Operation, VirtualMachine}
  alias Marshall.Galileo.{Credentials, Integration, IntegrationHeader, Ownership, PeerTokens}
  alias Marshall.Ingress.Endpoint
  alias Marshall.Teams
  require Ash.Query
  require Marshall.Events
  @lease_ttl 2000

  # @cc [owner:ghuntley,label:security] galileo-authorize-fences-execution
  # Authorization MUST authenticate the dedicated host credential, require the
  # binding host match and the same live execution fences as inference
  # admission (live owner, egress profile, enabled fresh host, exact
  # placement/epoch, running states, completed provision/start/resume) before resolving any
  # configuration. No response is ever cached or replayed.
  require Marshall.Events

  @spec authorize(binary(), term()) :: {:ok, map()} | {:error, term()}
  def authorize(token, wire) when is_map(wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire["binding"]),
         true <- OverallsProtocol.Integration.name?(wire["name"]) do
      Ledger.transaction(fn ->
        {vm, integration} = admit!(token, binding, wire["name"])

        headers =
          integration.id
          |> then(&Ledger.read!(IntegrationHeader, integration_id: &1))
          |> Ash.load!(:value, actor: SystemActor.compute())
          |> Enum.map(&injected/1)

        response = %{
          "target" => integration.target,
          "strip_prefix" => integration.strip_prefix,
          "headers" => Enum.map(headers, fn {name, value} -> [name, value] end),
          "ttl" => @lease_ttl
        }

        if integration.peer do
          endpoint = peer_endpoint!(integration)
          token = PeerTokens.mint(vm.id, integration.id, integration.name)

          response
          |> Map.put("target", endpoint)
          |> Map.put("peer", %{"endpoint" => endpoint, "token" => token})
          |> closed!()
        else
          closed!(response)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
    |> refused()
  end

  def authorize(_, _), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security] galileo-renewal-rechecks-execution
  # Renewal MUST repeat source execution, ownership and attachment admission
  # under the host credential. It returns only a bounded relative TTL and MUST
  # NOT decrypt headers, return routing data or mint another peer token.
  @spec renew(binary(), term()) :: {:ok, map()} | {:error, term()}
  def renew(token, wire) when is_map(wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire["binding"]),
         true <- OverallsProtocol.Integration.name?(wire["name"]) do
      Ledger.transaction(fn ->
        _admission = admit!(token, binding, wire["name"])
        %{"version" => 1, "ttl" => @lease_ttl}
      end)
    else
      _ -> {:error, :invalid_request}
    end
    |> refused()
  end

  def renew(_, _), do: {:error, :invalid_request}

  @spec identity(binary()) :: {:ok, map()} | {:error, term()}
  def identity(token) do
    Ledger.transaction(fn ->
      authority = Credentials.authenticate_locked!(token)
      %{host_id: authority.host_id}
    end)
    |> refused()
  end

  # @cc [owner:ghuntley,label:security;observability] galileo-authorization-refusals
  # Every refused edge authorization MUST emit its closed refusal reason after
  # the transaction settles; admitted requests stay silent because the
  # authorization handshake runs per upstream request. Reasons never carry
  # binding details, tokens or header values.
  defp refused({:ok, _} = ok), do: ok

  defp refused({:error, reason}) when is_atom(reason) do
    unless Marshall.Repo.in_transaction?(),
      do: Marshall.Events.emit("galileo.authorization_denied", reason: reason)

    {:error, reason}
  end

  defp refused(other), do: other

  # @cc [owner:ghuntley,label:security] galileo-vm-eligibility
  # A machine reaches a personal integration only through a current explicit
  # attachment, including its owner's machines. Live team-member machines retain
  # automatic team integration access. Peer integrations MUST target a machine owned by
  # the integration owner or a member of the owning team.
  defp vm_authorized!(integration, vm) do
    unless Ownership.live?(integration), do: deny!()

    attached =
      integration.id |> attachment_query(vm.id) |> Ash.exists?(actor: SystemActor.compute())

    member = is_binary(integration.team_id) and Teams.member?(integration.team_id, vm.owner_id)

    unless member or attached, do: deny!()
  end

  defp peer_endpoint!(integration) do
    target =
      integration.peer_vm_id &&
        VirtualMachine
        |> Ash.Query.filter(id == ^integration.peer_vm_id)
        |> Ash.Query.lock("FOR SHARE")
        |> Ash.read_one!(actor: SystemActor.compute())

    unless match?(%VirtualMachine{desired_state: :running}, target || %{}), do: deny!()

    owned =
      (is_binary(integration.team_id) and Teams.member?(integration.team_id, target.owner_id)) or
        (is_binary(integration.owner_id) and integration.owner_id == target.owner_id)

    unless owned, do: deny!()

    case Ledger.read!(Endpoint, vm_id: target.id) do
      [%Endpoint{label: label}] ->
        zone = Application.fetch_env!(:marshall, :ingress_zone)
        "https://" <> label <> "." <> zone

      _ ->
        Ledger.rollback(:peer_unreachable)
    end
  end

  defp attachment_query(integration_id, vm_id) do
    require Ash.Query

    Marshall.Galileo.Attachment
    |> Ash.Query.filter(integration_id == ^integration_id and vm_id == ^vm_id)
  end

  defp active_integration!(name) do
    case Ledger.read!(Integration, name: name) do
      [integration] -> integration
      _ -> deny!()
    end
  end

  defp admit!(token, binding, name) do
    authority = Credentials.authenticate_locked!(token)
    if authority.host_id != binding.host_id, do: deny!()
    vm = current_vm!(authority.host, binding)
    integration = active_integration!(name)
    vm_authorized!(integration, vm)
    {vm, integration}
  end

  defp injected(%IntegrationHeader{kind: :static, name: name, value: value}), do: {name, value}

  defp injected(%IntegrationHeader{kind: :bearer, value: value}),
    do: {"authorization", "Bearer " <> value}

  defp injected(%IntegrationHeader{kind: :basic, value: value}),
    do: {"authorization", "Basic " <> Base.encode64(value)}

  defp current_vm!(host, binding) do
    vm =
      VirtualMachine
      |> Ash.Query.filter(id == ^binding.vm_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

    now = Ledger.now()

    unless match?(%Marshall.Accounts.User{deleted_at: nil}, Security.current(vm.owner_id)) and
             OverallsProtocol.ProfilePolicy.allows?(vm.profile, :egress) and
             host.enabled and host.maintenance_mode != :retired and
             is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               now
             ) and
             vm.host_id == host.id and vm.current_placement_id == binding.placement_id and
             vm.execution_epoch == binding.execution_epoch and vm.desired_state == :running and
             vm.observed_state == :running and
             Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm),
           do: deny!()

    started =
      Operation
      |> Ash.Query.filter(
        vm_id == ^vm.id and placement_id == ^vm.current_placement_id and
          execution_epoch == ^vm.execution_epoch and generation == ^vm.generation and
          status == :completed and kind in [:start, :provision, :resume]
      )
      |> Ash.exists?(actor: SystemActor.compute())

    unless started, do: deny!()
    vm
  end

  defp closed!(response) do
    case OverallsProtocol.Integration.authorization(response) do
      {:ok, _authorization} -> response
      _ -> Ledger.rollback(:authorization_invalid)
    end
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
