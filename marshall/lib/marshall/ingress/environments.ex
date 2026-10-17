defmodule Marshall.Ingress.Environments do
  @moduledoc "VM-serialized parent environment identity and fixed namespace construction."
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Endpoint, Environment}

  # @cc [owner:ghuntley,label:concurrency;security] inception-environment-identity
  # Callers MUST hold the VM row lock or its uncommitted insertion through commit.
  # Only the Inception profile may acquire an environment. Repeated initialization
  # MUST retain the original label and generation; it MUST NOT re-enable revocation.
  # A namespace record alone MUST NOT authorize publication or a guest connection.
  @spec ensure!(Marshall.Compute.VirtualMachine.t(), Endpoint.t()) :: Environment.t() | nil
  def ensure!(%{profile: :inception} = vm, %Endpoint{vm_id: id} = endpoint) when id == vm.id do
    case Ledger.read!(Environment, vm_id: vm.id) do
      [environment] -> environment
      [] -> Ledger.create!(Environment, :record, %{vm_id: vm.id, label: endpoint.label})
    end
  end

  def ensure!(%{profile: profile}, %Endpoint{}) when profile != :inception, do: nil

  @spec origins(Environment.t(), binary()) :: {:ok, map()} | {:error, :invalid_inception_name}
  def origins(%Environment{label: label}, zone),
    do: OverallsProtocol.InceptionName.origins(label, zone)
end
