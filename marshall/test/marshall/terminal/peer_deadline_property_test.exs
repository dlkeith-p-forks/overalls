defmodule Marshall.Terminal.PeerDeadlinePropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Terminal.PeerSocket
  alias Marshall.Terminal.Remote

  # @cc [owner:ghuntley,label:verification;recovery] peer-silence-expired-budget
  # Both peer callbacks MUST stop at an exhausted silence budget, including
  # exact equality; the outgoing heartbeat MUST NOT send another ping.
  property "exhausted silence stops both peers without another heartbeat" do
    check all(overdue <- integer(0..5_000)) do
      state = %{last_seen: System.monotonic_time(:millisecond) - 15_000 - overdue}
      assert {:stop, :normal, ^state} = PeerSocket.handle_info(:liveness, state)
      assert {:stop, :normal, ^state} = Remote.handle_info(:silence_deadline, state)
      assert {:stop, :normal, ^state} = Remote.handle_info(:heartbeat, state)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] peer-silence-next-wakeup
  # An attached peer's next liveness wake MUST NOT exceed its remaining
  # fifteen-second silence budget. This observes the actual timer BIF from
  # a callback worker; constructed timestamps do not prove native/TLS timing.
  property "the next peer-silence wake remains inside the unexpired deadline", test_cases: 20 do
    :erlang.trace_pattern({:erlang, :send_after, 4}, true, [])

    try do
      check all(remaining <- integer(500..4_500), test_cases: 20) do
        for {module, message, expected} <- [
              {PeerSocket, :liveness, :ok},
              {Remote, :silence_deadline, :noreply}
            ] do
          observer = self()
          reference = make_ref()

          worker =
            start_supervised!(%{
              id: reference,
              start:
                {Task, :start_link,
                 [
                   fn ->
                     receive do
                       :inspect_deadline ->
                         started = System.monotonic_time(:millisecond)
                         state = %{last_seen: started - (15_000 - remaining), phase: :attached}
                         result = module.handle_info(message, state)

                         send(
                           observer,
                           {:deadline_result, reference, result,
                            System.monotonic_time(:millisecond) - started}
                         )
                     end
                   end
                 ]},
              restart: :temporary
            })

          monitor = Process.monitor(worker)
          :erlang.trace(worker, true, [:call])
          send(worker, :inspect_deadline)
          assert_receive {:deadline_result, ^reference, result, elapsed}, 1_000

          case result do
            {^expected, _state} ->
              assert_receive {:trace, ^worker, :call,
                              {:erlang, :send_after, [delay, ^worker, ^message, _options]}},
                             1_000

              assert delay > 0
              assert delay <= remaining

            {:stop, :normal, _state} ->
              assert elapsed >= remaining
          end

          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
        end
      end
    after
      :erlang.trace_pattern({:erlang, :send_after, 4}, false, [])
    end
  end
end
