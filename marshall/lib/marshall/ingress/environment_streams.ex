defmodule Marshall.Ingress.EnvironmentStreams do
  @moduledoc "Parent listener admission and renewal; child services authenticate users independently."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}

  alias Marshall.Ingress.{
    Environment,
    EnvironmentAuthority,
    EnvironmentStream,
    Error,
    Services,
    Token
  }

  require Ash.Query

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}),
    do:
      Ledger.transaction(fn -> perform(options[:operation], input.arguments) end)
      |> Error.result()

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;concurrency] inception-stream-parent-permission
  # Admission MUST serialize gateway capacity, then lock host and VM through the
  # current namespace/publication check. At most 1024 live leases per gateway are
  # allowed. SSH admission requires the authenticated gateway's attestation of a
  # completed signature proof for the supplied key; parent membership is not
  # child membership. HTTPS carries no parent user credential into the child.
  defp perform(:open, request) do
    service = Services.authenticate!(request.service_token, :exclusive)
    unless OverallsProtocol.IngressName.valid_label?(request.label), do: deny!()
    environment = List.first(Ledger.read!(Environment, label: request.label)) || deny!()
    vm = List.first(Ledger.read!(VirtualMachine, id: environment.vm_id)) || deny!()

    binding = %{
      vm_id: vm.id,
      host_id: service.host_id,
      service_generation: service.generation,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation,
      environment_generation: environment.generation,
      label: environment.label
    }

    authority = EnvironmentAuthority.current!(service, binding, request.nested_service)
    fingerprint = peer!(request.nested_service, request[:public_key])
    now = Ledger.now()

    active =
      EnvironmentStream
      |> Ash.Query.filter(service_id == ^service.id and is_nil(closed_at) and expires_at > ^now)

    if Ash.count!(active, actor: SystemActor.compute()) >= 1024, do: Ledger.rollback(:capacity)
    {ticket, digest} = Token.issue(:nested_stream)

    stream =
      Ledger.create!(
        EnvironmentStream,
        :record,
        Map.merge(binding, %{
          service_id: service.id,
          token_hash: digest,
          nested_service: request.nested_service,
          peer_fingerprint: fingerprint,
          host_key: authority.host_key,
          host_session_id: authority.host_session_id,
          host_epoch: authority.host_epoch,
          expires_at: authority.expires_at
        })
      )

    Map.put(view(stream), :ticket, ticket)
  end

  # @cc [owner:ghuntley,label:security] inception-stream-renewal-no-resurrection
  # Renewal MUST recheck current authority and preserve host session/epoch and
  # selected SSH host key. It MUST NOT revive closed/expired leases or extend
  # them beyond the current publication deadline. Revoked policy MUST fail even
  # while the VM remains physically running.
  defp perform(:renew_nested, request) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(request.stream_token)
    bind!(candidate, service)
    authority = EnvironmentAuthority.current!(service, candidate, candidate.nested_service)

    unless authority.host_session_id == candidate.host_session_id and
             authority.host_epoch == candidate.host_epoch and
             authority.host_key == candidate.host_key,
           do: deny!()

    stream = Ledger.lock!(EnvironmentStream, candidate.id) || deny!()

    unless is_nil(stream.closed_at) and DateTime.compare(stream.expires_at, Ledger.now()) == :gt,
      do: deny!()

    stream |> Ledger.update!(:renew, %{expires_at: authority.expires_at}) |> view()
  end

  defp perform(:close_nested, request) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(request.stream_token)
    bind!(candidate, service)
    stream = Ledger.lock!(EnvironmentStream, candidate.id) || deny!()
    if is_nil(stream.closed_at), do: Ledger.update!(stream, :close, %{closed_at: Ledger.now()})
    %{closed: true}
  end

  defp peer!(kind, key) when kind in [:porsche_ssh, :audi_ssh] do
    case OverallsProtocol.SSHKey.parse(key) do
      {:ok, parsed} -> parsed.fingerprint
      _ -> deny!()
    end
  end

  defp peer!(kind, nil) when kind in [:control_https, :audi_https], do: nil
  defp peer!(_, _), do: deny!()

  defp candidate!(token) do
    case Token.digest(token, :nested_stream) do
      {:ok, hash} -> List.first(Ledger.read!(EnvironmentStream, token_hash: hash)) || deny!()
      _ -> deny!()
    end
  end

  defp bind!(stream, service) do
    unless stream.service_id == service.id and stream.service_generation == service.generation and
             stream.host_id == service.host_id,
           do: deny!()
  end

  defp view(stream) do
    {_, port} = OverallsProtocol.InceptionName.destination(stream.nested_service)

    binding =
      Map.take(stream, [
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :environment_generation,
        :label
      ])
      |> Map.merge(%{session_id: stream.id, service: stream.nested_service, port: port})

    ttl = min(5000, DateTime.diff(stream.expires_at, Ledger.now(), :millisecond))
    unless ttl > 0, do: deny!()
    %{binding: binding, ttl: ttl, host_key: stream.host_key}
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
