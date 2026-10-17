defmodule OverallsProtocol.CapacityTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.Capacity
  @id "11111111-1111-4111-8111-111111111111"

  test "unknown is distinct from known zero; coverage is bounded and strictly versioned" do
    capacity = %{
      "version" => 1,
      "cpu_headroom_millicores" => 0,
      "memory_headroom_bytes" => 0,
      "interval_us" => 1_000_000,
      "covered" => %{}
    }

    assert Capacity.valid?(nil)
    assert Capacity.valid?(capacity)
    refute Capacity.valid?(Map.put(capacity, "version", 2))
    refute Capacity.valid?(Map.put(capacity, "interval_us", 5_000_001))
    refute Capacity.valid?(Map.put(capacity, "memory_headroom_bytes", -1))
    refute Capacity.valid?(Map.put(capacity, "extra", 0))

    proof = %{
      "generation" => 1,
      "execution_epoch" => 1,
      "outcome_id" => @id,
      "compute" => true,
      "disk" => true
    }

    assert Capacity.valid?(%{capacity | "covered" => %{@id => proof}})
    refute Capacity.valid?(%{capacity | "covered" => %{@id => Map.put(proof, "generation", 0)}})
    refute Capacity.valid?(%{capacity | "covered" => %{"invalid" => proof}})
  end
end
