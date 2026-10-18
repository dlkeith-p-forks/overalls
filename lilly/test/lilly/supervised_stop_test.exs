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

  property "arbitrary crash payloads collapse to a closed reason without disclosure",
    print_blob: false do
    test_case = :hegel.current_test_case()
    :hegel.note(test_case, "secret = <redacted>")
    secret = :hegel.draw_silent(test_case, binary(max_length: 256))
    assert SupervisedStop.category({:unknown, secret}) == :unknown_tuple

    for reason <- [%{payload: secret}, [secret], secret],
        do: assert(SupervisedStop.category(reason) == :unexpected)

    assert SupervisedStop.category({:shutdown, secret}) == :shutdown

    assert SupervisedStop.location({:badarg, [{Lilly.VM.Actor, :schedule, [secret], []}]}) ==
             {:unknown, :unknown, 0}

    assert SupervisedStop.location({:badarg, [{:gen_server, :init, [secret], []}]}) ==
             {:gen_server, :init, 1}
  end
end
