defmodule Ziggy.SpoolTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  @id "01234567-89ab-4def-8123-456789abcdef"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ziggy-spool-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "startup creates the checkpoint and restart preserves acknowledged totals",
       %{dir: dir} do
    spool = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 2})
    assert File.exists?(Path.join(dir, ".slo-checkpoint"))
    :ok = Ziggy.Spool.admit(spool, admission())
    :ok = Ziggy.Spool.complete(spool, @id, completion())
    assert %{requests: 1} = Ziggy.Spool.slo_snapshot(spool)
    :ok = Ziggy.Spool.acknowledge(spool, @id)
    expected = stable_slo(spool)
    stop_supervised!(Ziggy.Spool)
    restarted = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 2})
    assert stable_slo(restarted) == expected
    assert Ziggy.Spool.pending(restarted) == []
    :ok = Ziggy.Spool.admit(restarted, admission())
    :ok = Ziggy.Spool.complete(restarted, @id, completion())
    assert %{requests: 2} = Ziggy.Spool.slo_snapshot(restarted)
  end

  test "empty durable source lifetime survives restart before any provider work",
       %{dir: dir} do
    producer = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    assert File.exists?(Path.join(dir, ".slo-checkpoint"))
    assert %{requests: 0} = Ziggy.Spool.slo_snapshot(producer)
    expected = stable_slo(producer)
    stop_supervised!(Ziggy.Spool)
    restarted = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    assert stable_slo(restarted) == expected
    assert Ziggy.Spool.pending(restarted) == []
  end

  # @cc [owner:ghuntley,label:verification;recovery] spool-ack-gated-generated-capacity
  # Generated saturation and partial-ack histories MUST retain every unacked
  # completed receipt through restart and reclaim exactly the acknowledged slots.
  property "completed receipts consume slots until their exact acknowledgements", %{dir: root} do
    capacity = draw("capacity", integer(1..6))
    acknowledged = draw("acknowledged", list_of(boolean(), length: capacity))

    directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    Hegel.on_cleanup(fn -> File.rm_rf!(directory) end)
    {:ok, spool} = Ziggy.Spool.start_link(directory: directory, max_requests: capacity)
    Hegel.on_cleanup(fn -> if Process.alive?(spool), do: GenServer.stop(spool) end)
    originals = Enum.map(1..capacity, &request_id/1)
    assert Enum.all?(originals, &OverallsProtocol.uuid?/1)

    for id <- originals do
      assert :ok = Ziggy.Spool.admit(spool, Map.put(admission(), "request_id", id))
      assert :ok = Ziggy.Spool.complete(spool, id, completion())
      assert File.exists?(Path.join(directory, id <> ".json"))
    end

    assert {:error, :spool_full} =
             Ziggy.Spool.admit(spool, Map.put(admission(), "request_id", request_id(99)))

    retained =
      originals
      |> Enum.zip(acknowledged)
      |> Enum.flat_map(fn {id, ack?} ->
        if ack? do
          assert :ok = Ziggy.Spool.acknowledge(spool, id)
          refute File.exists?(Path.join(directory, id <> ".json"))
          []
        else
          [id]
        end
      end)

    expected_pending =
      Ziggy.Spool.pending(spool)
      |> Enum.sort_by(&get_in(&1, ["admission", "request_id"]))

    retained_bytes = Map.new(retained, &{&1, File.read!(Path.join(directory, &1 <> ".json"))})
    before_slo = stable_slo(spool)

    GenServer.stop(spool)
    {:ok, recovered} = Ziggy.Spool.start_link(directory: directory, max_requests: capacity)
    Hegel.on_cleanup(fn -> if Process.alive?(recovered), do: GenServer.stop(recovered) end)

    recovered_pending =
      Ziggy.Spool.pending(recovered)
      |> Enum.sort_by(&get_in(&1, ["admission", "request_id"]))

    pending_ids = Enum.map(recovered_pending, &get_in(&1, ["admission", "request_id"]))

    assert pending_ids == Enum.sort(retained)
    assert recovered_pending == expected_pending
    assert stable_slo(recovered) == before_slo

    assert Map.new(retained, &{&1, File.read!(Path.join(directory, &1 <> ".json"))}) ==
             retained_bytes

    assert Ziggy.Spool.ready?(recovered) == Enum.any?(acknowledged)

    replacements = Enum.count(acknowledged, & &1)

    if replacements > 0 do
      for offset <- 1..replacements do
        id = request_id(100 + offset)
        assert OverallsProtocol.uuid?(id)
        assert :ok = Ziggy.Spool.admit(recovered, Map.put(admission(), "request_id", id))
        assert :ok = Ziggy.Spool.complete(recovered, id, completion())
      end
    end

    assert length(Ziggy.Spool.pending(recovered)) == capacity
    assert Ziggy.Spool.ready?(recovered) == false

    for %{"admission" => %{"request_id" => id}} <- Ziggy.Spool.pending(recovered) do
      assert :ok = Ziggy.Spool.acknowledge(recovered, id)
    end

    assert Ziggy.Spool.pending(recovered) == []
    assert Ziggy.Spool.ready?(recovered)
    totals = stable_slo(recovered)
    assert totals.requests == capacity + replacements
    GenServer.stop(recovered)

    final =
      Overalls.HegelFixtures.start_supervised!(
        {Ziggy.Spool, directory: directory, max_requests: capacity}
      )

    assert Ziggy.Spool.pending(final) == []
    assert stable_slo(final) == totals
    stop_supervised!(Ziggy.Spool)
  end

  # @cc [owner:ghuntley,label:verification] spool-generated-id-canonical
  # Request IDs for the generated history's 1..106 menu MUST be canonical
  # lowercase UUIDs so valid capacity transitions cannot fail on fixture syntax.
  @spec request_id(1..106) :: String.t()
  defp request_id(number) when number in 1..106 do
    suffix =
      number
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(12, "0")

    "00000000-0000-4000-8000-" <> suffix
  end

  @spec stable_slo(GenServer.server()) :: map()
  defp stable_slo(server), do: Map.delete(Ziggy.Spool.slo_snapshot(server), :sampled_at_unix_nano)

  test "terminal slot ahead of checkpoint is counted once on recovery", %{dir: dir} do
    spool = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    :ok = Ziggy.Spool.admit(spool, admission())
    checkpoint = Path.join(dir, ".slo-checkpoint")
    before = File.read!(checkpoint)
    :ok = Ziggy.Spool.complete(spool, @id, completion())
    expected = stable_slo(spool)
    stop_supervised!(Ziggy.Spool)
    File.write!(checkpoint, before)
    recovered = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    assert stable_slo(recovered) == expected
    assert :ok = Ziggy.Spool.complete(recovered, @id, completion())
    assert stable_slo(recovered) == expected
  end

  test "durable unlink ahead of replay-set cleanup preserves acknowledged totals", %{dir: dir} do
    spool = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    :ok = Ziggy.Spool.admit(spool, admission())
    :ok = Ziggy.Spool.complete(spool, @id, completion())
    checkpoint = Path.join(dir, ".slo-checkpoint")
    before = File.read!(checkpoint)
    expected = stable_slo(spool)
    :ok = Ziggy.Spool.acknowledge(spool, @id)
    stop_supervised!(Ziggy.Spool)
    File.write!(checkpoint, before)
    recovered = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    assert Ziggy.Spool.pending(recovered) == []
    assert stable_slo(recovered) == expected
    other = Map.put(admission(), "request_id", request_id(2))
    :ok = Ziggy.Spool.admit(recovered, other)
    :ok = Ziggy.Spool.complete(recovered, other["request_id"], completion())
    assert %{requests: 2, failures: 2} = Ziggy.Spool.slo_snapshot(recovered)
  end

  test "uncertain checkpoint fences admission and acknowledgement until recovery", %{dir: dir} do
    spool = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 2})
    :ok = Ziggy.Spool.admit(spool, admission())
    stage = Path.join(dir, ".slo-checkpoint.pending")
    File.mkdir!(stage)
    assert {:error, :spool_unavailable} = Ziggy.Spool.complete(spool, @id, completion())
    refute Ziggy.Spool.ready?(spool)
    assert {:error, :spool_unavailable} = Ziggy.Spool.acknowledge(spool, @id)

    assert {:error, :spool_unavailable} =
             Ziggy.Spool.admit(spool, Map.put(admission(), "request_id", request_id(2)))

    assert File.exists?(Path.join(dir, @id <> ".json"))
    stop_supervised!(Ziggy.Spool)
    File.rmdir!(stage)
    recovered = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 2})
    assert %{requests: 1, failures: 1} = Ziggy.Spool.slo_snapshot(recovered)
    assert :ok = Ziggy.Spool.acknowledge(recovered, @id)
  end

  test "durable recovery does not turn admission into completion", %{dir: dir} do
    pid = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    assert :ok = Ziggy.Spool.admit(pid, admission())
    assert {:error, :duplicate_request} = Ziggy.Spool.admit(pid, admission())
    assert {:error, :invalid_transition} = Ziggy.Spool.acknowledge(pid, @id)
    stop_supervised!(Ziggy.Spool)
    recovered = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})

    assert [%{"admission" => event, "completion" => recovered_completion}] =
             Ziggy.Spool.pending(recovered)

    assert event == admission()
    assert recovered_completion["outcome"] == "interrupted"
    assert recovered_completion["completeness"] == "unknown"

    assert %{requests: 1, failures: 1, duration: %{count: 0}} =
             Ziggy.Spool.slo_snapshot(recovered)

    assert {:error, :spool_full} =
             Ziggy.Spool.admit(
               recovered,
               Map.put(event, "request_id", "11234567-89ab-4def-8123-456789abcdef")
             )

    assert :ok = Ziggy.Spool.complete(recovered, @id, recovered_completion)
    assert :ok = Ziggy.Spool.complete(recovered, @id, recovered_completion)
    assert %{requests: 1, failures: 1} = Ziggy.Spool.slo_snapshot(recovered)

    assert {:error, :invalid_transition} =
             Ziggy.Spool.complete(recovered, @id, Map.put(completion(), "response_bytes", 1))

    assert :ok = Ziggy.Spool.acknowledge(recovered, @id)
    assert [] = Ziggy.Spool.pending(recovered)
  end

  test "untrusted content fields cannot enter disk", %{dir: dir} do
    pid = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    checkpoint = File.read!(Path.join(dir, ".slo-checkpoint"))

    for key <- ~w(prompt response api_key tool_calls authorization) do
      assert {:error, :invalid_event} =
               Ziggy.Spool.admit(pid, Map.put(admission(), key, "synthetic"))
    end

    assert [".slo-checkpoint"] = File.ls!(dir)
    assert File.read!(Path.join(dir, ".slo-checkpoint")) == checkpoint
    assert %{requests: 0} = Ziggy.Spool.slo_snapshot(pid)
    assert :ok = Ziggy.Spool.admit(pid, admission())

    assert {:error, :invalid_event} =
             Ziggy.Spool.complete(pid, @id, Map.put(completion(), "body", "synthetic"))
  end

  test "interrupted completion staging recovers the admitted unknown outcome", %{dir: dir} do
    pid = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    :ok = Ziggy.Spool.admit(pid, admission())
    stop_supervised!(Ziggy.Spool)
    File.write!(Path.join(dir, @id <> ".json.pending"), "interrupted synthetic stage")
    recovered = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})

    assert [
             %{
               "completion" => %{
                 "outcome" => "interrupted",
                 "tokens" => %{},
                 "duration_ms" => nil
               }
             }
           ] = Ziggy.Spool.pending(recovered)

    refute File.exists?(Path.join(dir, @id <> ".json.pending"))
  end

  test "completed batching excludes active requests", %{dir: dir} do
    pid = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 4})
    :ok = Ziggy.Spool.admit(pid, admission())
    other = "11234567-89ab-4def-8123-456789abcdef"
    :ok = Ziggy.Spool.admit(pid, Map.put(admission(), "request_id", other))

    assert %{"ziggy_active_requests" => 2, "ziggy_pending_receipts" => 0} =
             Ziggy.Spool.metrics(pid)

    assert [] = Ziggy.Spool.completed(pid, 1)
    :ok = Ziggy.Spool.complete(pid, other, completion())

    assert %{"ziggy_active_requests" => 1, "ziggy_pending_receipts" => 1} =
             Ziggy.Spool.metrics(pid)

    assert [%{"admission" => %{"request_id" => ^other}}] = Ziggy.Spool.completed(pid, 1)
  end

  test "one durable successful completion adds one source-owned outcome", %{dir: dir} do
    pid = start_supervised!({Ziggy.Spool, directory: dir, max_requests: 1})
    :ok = Ziggy.Spool.admit(pid, admission())

    result =
      completion()
      |> Map.put("outcome", "completed")
      |> Map.put("http_status", 200)
      |> Map.put("duration_ms", 50)

    assert :ok = Ziggy.Spool.complete(pid, @id, result)
    assert :ok = Ziggy.Spool.complete(pid, @id, result)

    assert %{requests: 1, successes: 1, failures: 0, duration: %{count: 1}} =
             Ziggy.Spool.slo_snapshot(pid)
  end

  defp admission,
    do: %{
      "request_id" => @id,
      "host_id" => @id,
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => 1,
      "owner_id" => @id,
      "provider" => "openai",
      "model" => "gpt-test",
      "operation" => "responses",
      "admitted_at" => 1
    }

  defp completion,
    do: %{
      "outcome" => "interrupted",
      "tokens" => %{},
      "completeness" => "unknown",
      "duration_ms" => 0,
      "request_bytes" => 0,
      "response_bytes" => 0
    }
end
