defmodule Lilly.SupervisedStopTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.SupervisedStop

  test "expected shutdowns do not produce failure diagnostics" do
    assert :ok = SupervisedStop.emit(:runtime, :normal)
    assert :ok = SupervisedStop.emit(:runtime, {:shutdown, :replacement})
    assert SupervisedStop.category(:vm_supervision_lost) == :vm_supervision_lost
    assert SupervisedStop.category(:journal_lock_lost) == :journal_lock_lost
    assert SupervisedStop.category(:command_store_failed) == :command_store_failed
    assert SupervisedStop.category({:badarg, "private"}) == :badarg
    assert SupervisedStop.category({RuntimeError.exception("private"), []}) == :exception
  end

  property "arbitrary crash payloads collapse to a closed reason without disclosure" do
    check all(secret <- binary(max_length: 256)) do
      assert SupervisedStop.category({:unknown, secret}) == :unknown_tuple

      for reason <- [%{payload: secret}, [secret], secret],
          do: assert(SupervisedStop.category(reason) == :unexpected)

      assert SupervisedStop.category({:shutdown, secret}) == :shutdown

      assert SupervisedStop.location({:badarg, [{Lilly.VM.Actor, :schedule, [secret], []}]}) ==
               {Lilly.VM.Actor, :schedule, 1}
    end
  end
end
