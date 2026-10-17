defmodule OverallsProtocol.SSHBootstrapTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.PrivateServices

  @id "11111111-1111-4111-8111-111111111111"
  @binding %{
    "host_id" => @id,
    "vm_id" => @id,
    "placement_id" => @id,
    "execution_epoch" => 1,
    "generation" => 2,
    "operation_id" => @id
  }

  test "roster proof is never an ordinary service identity" do
    assert {:ok, %{generation: 2, operation_id: @id}} = PrivateServices.roster_binding(@binding)
    assert {:error, :invalid_binding} = PrivateServices.binding(@binding)

    for key <- Map.keys(@binding) do
      assert {:error, :invalid_binding} =
               PrivateServices.roster_binding(Map.delete(@binding, key))
    end

    assert {:error, :invalid_binding} =
             PrivateServices.roster_binding(Map.put(@binding, "scope", "all"))
  end

  property "invalid generations and operation identifiers fail closed" do
    check all(generation <- one_of([integer(-100..0), string(:alphanumeric)])) do
      assert {:error, :invalid_binding} =
               PrivateServices.roster_binding(Map.put(@binding, "generation", generation))
    end

    assert {:error, :invalid_binding} =
             PrivateServices.roster_binding(Map.put(@binding, "operation_id", "unknown"))
  end
end
