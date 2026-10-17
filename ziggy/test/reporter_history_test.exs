defmodule Ziggy.ReporterHistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag timeout: 300_000

  @identity "01234567-89ab-4def-8123-456789abcdef"
  @type mode :: :transient | :wrong_ack | :conflict | :healthy
  @type controller :: %{
          mode: mode(),
          conflict_id: String.t(),
          expected: %{String.t() => map()},
          attempts: %{String.t() => non_neg_integer()},
          bodies: %{String.t() => map()},
          ids: [String.t()]
        }

  # @cc [owner:ghuntley,label:verification;recovery] reporter-immutable-mixed-drain
  # Refusal histories MUST preserve exact durable completions and retry bodies.
  # Each controlled initial batch MUST attempt precisely min(128, pending) rows.
  # A single conflicted receipt MUST NOT prevent healthy neighbors from draining.
  # Reporting and spool recovery MUST preserve lifetime totals.
  property "mixed reporter histories retain exact receipts and drain healthy neighbors" do
    check all(
            repeats <- member_of([1, 2, 4]),
            order <-
              member_of([
                [:transient, :wrong_ack, :conflict],
                [:conflict, :transient, :wrong_ack]
              ]),
            max_runs: 2
          ) do
      for count <- [2, 127, 128, 129],
          position <- Enum.uniq([0, div(min(count, 128), 2), min(count, 128) - 1]) do
        run_history(count, position, repeats, order)
      end
    end
  end

  @spec run_history(pos_integer(), non_neg_integer(), pos_integer(), [mode()]) :: :ok
  defp run_history(count, position, repeats, order) do
    directory =
      Path.join(System.tmp_dir!(), "ziggy-reporter-history-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    spool_id = {:spool, make_ref()}
    controller_id = {:controller, make_ref()}

    spool =
      start_supervised!(
        Supervisor.child_spec({Ziggy.Spool, directory: directory, max_requests: count},
          id: spool_id
        )
      )

    ids = Enum.map(1..count, &request_id/1)
    assert Enum.all?(ids, &OverallsProtocol.uuid?/1)

    expected =
      Map.new(Enum.with_index(ids, 1), fn {id, number} ->
        {id, %{"request_id" => id, "completion" => completion(number)}}
      end)

    for id <- ids do
      assert {:ok, _} = Ziggy.Completion.validate(expected[id]["completion"])
      assert :ok = Ziggy.Spool.admit(spool, admission(id))
      assert :ok = Ziggy.Spool.complete(spool, id, expected[id]["completion"])
    end

    initial_batch = Ziggy.Spool.completed(spool, 128)
    assert length(initial_batch) == min(count, 128)
    conflict_id = get_in(Enum.at(initial_batch, position), ["admission", "request_id"])
    pending = pending_entries(spool)
    bytes = receipt_bytes(directory, ids)
    totals = stable_slo(spool)
    known = div(count, 2)
    assert totals.requests == count
    assert totals.successes == known
    assert totals.failures == count - known
    assert totals.duration.count == known
    assert totals.duration.sum_us == known * (known + 1) * 1000

    assert totals.duration.explicit_bounds_us == [
             10_000,
             50_000,
             100_000,
             500_000,
             1_000_000,
             5_000_000,
             10_000_000
           ]

    assert totals.duration.bucket_counts == [
             div(min(count, 10), 2),
             div(min(count, 50), 2) - div(min(count, 10), 2),
             div(min(count, 100), 2) - div(min(count, 50), 2),
             known - div(min(count, 100), 2),
             0,
             0,
             0,
             0
           ]

    controller =
      start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               mode: :transient,
               conflict_id: conflict_id,
               expected: expected,
               bodies: %{},
               attempts: %{},
               ids: ids
             }
           end},
          id: controller_id,
          restart: :temporary
        )
      )

    for mode <- order do
      Agent.update(controller, &%{&1 | mode: mode})
      for _ <- 1..repeats, do: one_batch(spool, controller)
      assert pending_entries(spool) == pending
      assert receipt_bytes(directory, ids) == bytes
      assert stable_slo(spool) == totals
      refute Ziggy.Spool.ready?(spool)
    end

    Agent.update(controller, &%{&1 | mode: :healthy})

    for _ <- 1..2 do
      before = pending_entries(spool)
      batch = Ziggy.Spool.completed(spool, 128)
      one_batch(spool, controller)

      acknowledged =
        batch
        |> Enum.map(&get_in(&1, ["admission", "request_id"]))
        |> Enum.reject(&(&1 == conflict_id))

      expected_remaining =
        Enum.reject(before, &(get_in(&1, ["admission", "request_id"]) in acknowledged))

      assert pending_entries(spool) == expected_remaining
      assert stable_slo(spool) == totals
    end

    assert Enum.map(pending_entries(spool), &get_in(&1, ["admission", "request_id"])) == [
             conflict_id
           ]

    assert receipt_bytes(directory, [conflict_id]) == Map.take(bytes, [conflict_id])
    assert Ziggy.Spool.ready?(spool)

    expected_wire =
      Map.new(expected, fn {id, body} ->
        {id, Map.update!(body, "completion", &Ziggy.Completion.wire/1)}
      end)

    assert Agent.get(controller, & &1.bodies) == expected_wire
    :ok = stop_supervised(spool_id)

    recovered =
      start_supervised!(
        Supervisor.child_spec({Ziggy.Spool, directory: directory, max_requests: count},
          id: spool_id
        )
      )

    assert pending_entries(recovered) ==
             Enum.filter(pending, &(get_in(&1, ["admission", "request_id"]) == conflict_id))

    assert receipt_bytes(directory, [conflict_id]) == Map.take(bytes, [conflict_id])
    assert stable_slo(recovered) == totals
    assert :ok = Ziggy.Spool.acknowledge(recovered, conflict_id)
    assert pending_entries(recovered) == []
    assert stable_slo(recovered) == totals
    :ok = stop_supervised(spool_id)
    :ok = stop_supervised(controller_id)
    File.rm_rf!(directory)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] reporter-one-initial-batch
  # The first callback MUST block outside the controller until a suspend system
  # message is confirmed in the Reporter mailbox. Its initial handle_info batch
  # MUST finish before suspension; no queued timer may supply extra attempts.
  @spec one_batch(GenServer.server(), pid()) :: :ok
  defp one_batch(spool, controller) do
    batch = Ziggy.Spool.completed(spool, 128)
    pending_count = length(pending_entries(spool))
    assert length(batch) == min(pending_count, 128)
    assert pending_count > 0
    selected = Enum.map(batch, &get_in(&1, ["admission", "request_id"]))
    before = Agent.get(controller, & &1.attempts)
    owner = self()
    pass_ref = make_ref()
    reporter_id = {:reporter, pass_ref}

    request = fn _control, "complete", body ->
      unless Process.get(:initial_callback_released, false) do
        send(owner, {:initial_callback, pass_ref, self()})

        receive do
          {:release_callback, ^pass_ref} -> Process.put(:initial_callback_released, true)
        after
          60_000 -> raise "controlled reporter callback was not released"
        end
      end

      record_response(controller, body)
    end

    reporter =
      start_supervised!(
        Supervisor.child_spec({Ziggy.Reporter, spool: spool, control: %{}, request: request},
          id: reporter_id,
          restart: :temporary,
          shutdown: 1000
        )
      )

    try do
      assert_receive {:initial_callback, ^pass_ref, ^reporter}, 10_000

      task =
        Task.async(fn ->
          receive do
            {:suspend_now, ^pass_ref} -> :sys.suspend(reporter, 60_000)
          after
            10_000 -> raise "controlled suspension was not started"
          end
        end)

      try do
        task_pid = task.pid
        :erlang.trace(task_pid, true, [:send, {:tracer, self()}])
        send(task_pid, {:suspend_now, pass_ref})

        assert_receive {:trace, ^task_pid, :send, {:system, {^task_pid, _tag}, :suspend},
                        ^reporter},
                       10_000

        {:messages, messages} = Process.info(reporter, :messages)

        assert Enum.any?(messages, fn
                 {:system, {^task_pid, _tag}, :suspend} -> true
                 _ -> false
               end)

        send(reporter, {:release_callback, pass_ref})
        assert Task.await(task, 60_000) == :ok
        after_attempts = Agent.get(controller, & &1.attempts)

        expected_attempts =
          Enum.reduce(selected, before, fn id, acc -> Map.update(acc, id, 1, &(&1 + 1)) end)

        assert after_attempts == expected_attempts
        :ok
      after
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end
    after
      stop_supervised(reporter_id)
    end
  end

  @spec record_response(pid(), map()) :: {:ok, map()} | {:error, atom()}
  defp record_response(controller, %{"request_id" => id} = body) do
    Agent.get_and_update(controller, fn state ->
      expected = Map.fetch!(state.expected, id)

      assert %{
               expected
               | "completion" => Ziggy.Completion.wire(expected["completion"])
             } == body

      next = %{
        state
        | bodies: Map.put(state.bodies, id, body),
          attempts: Map.update(state.attempts, id, 1, &(&1 + 1))
      }

      response =
        case state.mode do
          :transient -> {:error, :authority_unavailable}
          :wrong_ack -> {:ok, %{"acknowledged" => Enum.find(state.ids, &(&1 != id))}}
          :conflict -> conflict_response()
          :healthy when id == state.conflict_id -> conflict_response()
          :healthy -> {:ok, %{"acknowledged" => id}}
        end

      {response, next}
    end)
  end

  @spec conflict_response() :: {:error, :completion_conflict}
  defp conflict_response do
    response =
      Ziggy.Control.socket_result({:error, "completion_conflict"}, "complete", 16_384, nil)

    assert response == {:error, :completion_conflict}
    response
  end

  @spec pending_entries(GenServer.server()) :: [map()]
  defp pending_entries(spool),
    do: spool |> Ziggy.Spool.pending() |> Enum.sort_by(&get_in(&1, ["admission", "request_id"]))

  @spec receipt_bytes(String.t(), [String.t()]) :: %{String.t() => binary()}
  defp receipt_bytes(directory, ids),
    do: Map.new(ids, &{&1, File.read!(Path.join(directory, &1 <> ".json"))})

  @spec stable_slo(GenServer.server()) :: map()
  defp stable_slo(spool), do: Map.delete(Ziggy.Spool.slo_snapshot(spool), :sampled_at_unix_nano)

  @spec request_id(pos_integer()) :: String.t()
  defp request_id(number),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(String.downcase(Integer.to_string(number, 16)), 12, "0")

  @spec admission(String.t()) :: map()
  defp admission(id),
    do: %{
      "request_id" => id,
      "host_id" => @identity,
      "vm_id" => @identity,
      "placement_id" => @identity,
      "execution_epoch" => 1,
      "owner_id" => @identity,
      "provider" => "openai",
      "model" => "gpt-test",
      "operation" => "responses",
      "admitted_at" => 1
    }

  @spec completion(pos_integer()) :: map()
  defp completion(number),
    do: %{
      "outcome" => if(rem(number, 2) == 0, do: "completed", else: "interrupted"),
      "tokens" =>
        if(rem(number, 2) == 0,
          do: %{"input_tokens" => number, "output_tokens" => number + 1},
          else: %{}
        ),
      "completeness" => if(rem(number, 2) == 0, do: "complete", else: "unknown"),
      "duration_ms" => if(rem(number, 2) == 0, do: number, else: nil),
      "request_bytes" => number * 10,
      "response_bytes" => number * 11,
      "http_status" => if(rem(number, 2) == 0, do: 200, else: nil)
    }
end
