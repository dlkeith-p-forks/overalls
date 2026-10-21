defmodule Lilly.SupervisedStopTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.SupervisedStop

  test "expected shutdowns do not produce failure diagnostics" do
    assert :ok = SupervisedStop.emit(:runtime, :normal)
    assert :ok = SupervisedStop.emit(:runtime, {:shutdown, :replacement})
    assert SupervisedStop.category(:vm_supervision_lost) == :vm_supervision_lost
    assert SupervisedStop.category(:hostd_session_lost) == :hostd_session_lost
    assert SupervisedStop.category(:journal_lock_lost) == :journal_lock_lost
    assert SupervisedStop.category(:command_store_failed) == :command_store_failed
    assert SupervisedStop.category({:badarg, "private"}) == :badarg
    assert SupervisedStop.category({RuntimeError.exception("private"), []}) == :exception
  end

  test "host daemon status removes native chunks and pending request payloads" do
    private = "private native output and command arguments"

    assert Lilly.Host.Hostd.format_status(%{
             state: %{chunks: %{1 => [private]}, pending: %{2 => private}},
             message: {:run, private},
             reason: {:badmatch, private},
             log: [private]
           }) == %{state: :redacted, message: :redacted, reason: :redacted, log: []}
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
  end
end
