defmodule Marshall.Control.Hints.Hosts do
  @moduledoc """
  Resolves the host a record's VM is placed on, for host-keyed hints such as
  `gateway_catalog` (ADR-0142). Runs inside the emitting action's transaction.
  """

  alias Marshall.Compute.{Ledger, VirtualMachine, WorkloadPlacement}

  @doc "The host of a VM record's current placement, or nil."
  @spec of_vm(map()) :: String.t() | nil
  def of_vm(%{current_placement_id: id}) when is_binary(id), do: placement_host(id)
  def of_vm(_record), do: nil

  @doc "The host of the current placement of the VM a record names by `vm_id`."
  @spec of_vm_id(map()) :: String.t() | nil
  def of_vm_id(%{vm_id: vm_id}) when is_binary(vm_id) do
    case Ledger.read!(VirtualMachine, id: vm_id) do
      [vm] -> of_vm(vm)
      _ -> nil
    end
  end

  def of_vm_id(_record), do: nil

  @spec placement_host(String.t()) :: String.t() | nil
  defp placement_host(id) do
    case Ledger.read!(WorkloadPlacement, id: id) do
      [%{host_id: host}] -> host
      _ -> nil
    end
  end
end
