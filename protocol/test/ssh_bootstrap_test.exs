defmodule OverallsProtocol.SSHBootstrapTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
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

  property "invalid generations and operation identifiers fail closed",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_828_801_506 do
    (
      generation =
        draw(
          "generation",
          one_of([integer(-100..0), OverallsProtocol.TestGenerators.string(:alphanumeric)])
        )

      assert {:error, :invalid_binding} =
               PrivateServices.roster_binding(Map.put(@binding, "generation", generation))
    )

    assert {:error, :invalid_binding} =
             PrivateServices.roster_binding(Map.put(@binding, "operation_id", "unknown"))
  end
end
