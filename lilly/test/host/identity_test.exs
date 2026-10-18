defmodule Lilly.Host.IdentityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Identity, UIDReservation}

  property "host identity is stable with either allowed line termination and hides the raw ID" do
    check all(raw <- binary(length: 16)) do
      Hegel.assume(raw != <<0::128>>)
      machine = Base.encode16(raw, case: :lower)
      assert {:ok, id} = Identity.derive(machine)
      assert {:ok, ^id} = Identity.derive(machine <> "\n")
      assert OverallsProtocol.Execution.machine_id?(id)
      refute String.contains?(id, machine)
    end
  end

  test "uninitialized, zero, uppercase and malformed machine IDs are rejected" do
    for input <- [
          "",
          "uninitialized\n",
          String.duplicate("0", 32),
          String.duplicate("A", 32),
          "../machine",
          nil
        ] do
      assert {:error, :invalid_machine_identity} = Identity.derive(input)
    end
  end

  test "local accounts and subordinate ranges cannot claim VM identities" do
    assert UIDReservation.available?("root:x:0:0:root:/root:/bin/sh\n", :account)
    assert UIDReservation.available?("users:x:1000:\n", :account)

    for id <- [1_000_002, 1_262_142] do
      refute UIDReservation.available?("other:x:#{id}:\n", :account)
      refute UIDReservation.available?("other:#{id}:1\n", :subordinate)
      refute UIDReservation.available?("other:x:1000:#{id}:name:/home:/bin/sh\n", :account)
    end

    assert UIDReservation.available?("other:100000:65536\n", :subordinate)
    refute UIDReservation.available?("other:999999:4\n", :subordinate)
    refute UIDReservation.available?("other:1262142:10\n", :subordinate)
    refute UIDReservation.available?("other:1196607:0\n", :subordinate)
    refute UIDReservation.available?("other:1196607:1\n", :subordinate)
    assert UIDReservation.available?("other:1262143:1\n", :subordinate)
    refute UIDReservation.available?("corrupt", :account)
  end
end
