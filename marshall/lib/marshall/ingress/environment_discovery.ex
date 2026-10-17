defmodule Marshall.Ingress.EnvironmentDiscovery do
  @moduledoc "Current public SSH identities for one parent-owned nested listener."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Ingress.{Environment, EnvironmentAuthority, Error, Service}
  require Ash.Query

  @impl true
  def run(input, _, %{actor: %SystemActor{purpose: :compute}}),
    do: Ledger.transaction(fn -> current!(input.arguments) end) |> Error.result()

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;concurrency] inception-public-current-ssh-keys
  # Discovery MUST revalidate enabled namespace, current execution, host session,
  # publication expiry and selected listener key. All gateway locks MUST precede
  # host/VM locks. At most sixteen current local gateways may supply outer keys;
  # overflow MUST deny rather than truncate. No stored publication alone grants
  # discovery, and discovery MUST NOT create a stream or grant child membership.
  defp current!(request) do
    unless OverallsProtocol.IngressName.valid_label?(request.label), do: deny!()
    environment = List.first(Ledger.read!(Environment, label: request.label)) || deny!()
    vm = List.first(Ledger.read!(VirtualMachine, id: environment.vm_id)) || deny!()

    services =
      Service
      |> Ash.Query.filter(
        host_id == ^vm.host_id and enabled == true and role == :gateway and
          not is_nil(ssh_host_key) and addresses != []
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(17)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read!(actor: SystemActor.compute())

    unless length(services) in 1..16, do: deny!()

    authorities =
      Enum.map(services, fn service ->
        binding = %{
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          generation: vm.generation,
          service_generation: service.generation,
          environment_generation: environment.generation,
          label: environment.label
        }

        EnvironmentAuthority.current!(service, binding, request.nested_service)
      end)

    keys = authorities |> Enum.map(& &1.host_key) |> Enum.uniq()
    unless length(keys) == 1, do: deny!()

    %{
      label: environment.label,
      host_key: hd(keys),
      gateway_keys: services |> Enum.map(& &1.ssh_host_key) |> Enum.uniq(),
      ttl: authorities |> Enum.map(& &1.ttl) |> Enum.min()
    }
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
