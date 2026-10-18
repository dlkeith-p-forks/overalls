defmodule Marshall.Ingress.Open do
  @moduledoc "Fresh access before durable wake demand, followed by local or one-hop admission."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine, Wake}
  alias Marshall.Ingress.{Endpoint, Error, Execution, Relays, Services}

  @impl true
  def run(input, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> open!(input.arguments) end) |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;recovery] ingress-wake-before-stream
  # Each pending poll MUST repeat current credential and policy checks before
  # committing durable wake demand. Pending responses MUST grant no execution.
  # Only fresh completed running authority may create a local or one-hop stream;
  # an internal relocation pause MUST wait rather than resume the source copy.
  @spec open!(map()) :: map()
  defp open!(request) do
    source = Services.authenticate!(request.service_token)
    unless source.role == :gateway, do: deny!()
    {id, endpoint} = target!(request.purpose, request.label)
    candidate = List.first(Ledger.read!(VirtualMachine, id: id)) || deny!()
    destination = Relays.destination!(source, candidate.host_id)
    Relays.serialize_origin!(source.id)
    Services.serialize_open!(destination.id)
    Relays.authorize_origin!(source, destination)
    {vm, _, _} = Execution.target!(id, destination.host_id)
    unless vm.host_id == destination.host_id, do: deny!()
    actor = authorize!(request.purpose, source, request, vm, endpoint)

    unless vm.desired_state in [:running, :paused] and
             (vm.observed_state in [:running, :paused] or vm.desired_state == :running),
           do: deny!()

    Wake.request_locked!(vm, :network, actor)

    if Wake.ready?(vm) do
      grant = grant!(request.purpose, destination, request)
      response = %{version: 1, grant: grant}

      if source.id == destination.id,
        do: response,
        else:
          Map.put(response, :relay, Relays.issue!(source, destination, request.purpose, grant))
    else
      %{version: 1, pending: %{vm_id: vm.id, ttl: 30_000, retry_after_ms: 1000}}
    end
  end

  @spec target!(:ssh | :web | :editor, String.t()) :: {String.t(), Endpoint.t() | nil}
  defp target!(:editor, label) do
    case OverallsProtocol.EditorName.parse(label) do
      {:ok, %{vm_id: id}} -> {id, nil}
      _ -> deny!()
    end
  end

  defp target!(_, label) do
    unless OverallsProtocol.IngressName.valid_label?(label), do: deny!()
    endpoint = List.first(Ledger.read!(Endpoint, label: label)) || deny!()
    {endpoint.vm_id, endpoint}
  end

  @spec authorize!(:ssh | :web | :editor, struct(), map(), VirtualMachine.t(), Endpoint.t() | nil) ::
          Marshall.Accounts.User.t() | nil
  defp authorize!(:ssh, _, request, vm, _),
    do: Marshall.Ingress.Sessions.authorize_wake!(request, vm)

  defp authorize!(:web, source, request, vm, endpoint),
    do: Marshall.Ingress.WebStreams.authorize_wake!(source, request, vm, endpoint)

  defp authorize!(:editor, source, request, vm, _),
    do: Marshall.Editor.Authority.authorize_wake!(source, request, vm)

  @spec grant!(:ssh | :web | :editor, struct(), map()) :: map()
  defp grant!(:ssh, service, request) do
    {grant, _event} = Marshall.Ingress.Sessions.open_for!(service, request)

    Ledger.after_commit(fn ->
      require Marshall.Events

      Marshall.Events.emit("ingress.ssh_session_opened",
        vm_id: grant.binding.vm_id,
        host_id: grant.binding.host_id,
        session_id: grant.binding.session_id
      )
    end)

    grant
  end

  defp grant!(:web, service, request), do: Marshall.Ingress.WebStreams.open_for!(service, request)

  defp grant!(:editor, service, request),
    do: Marshall.Editor.Authority.open_for!(service, request)

  @spec deny!() :: no_return()
  defp deny!, do: Ledger.rollback(:unauthorized)
end
