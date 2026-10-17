defmodule Audi.SLOTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Audi.SLO

  # @cc [owner:ghuntley,label:verification] audi-private-slo-outcome-partition
  # Generated bound completions MUST produce closed cumulative outcomes and
  # exactly one fixed latency bucket each, without leaking request identity.
  property "bound private completions have closed outcomes and buckets" do
    check all(
            outcomes <-
              list_of(
                tuple({one_of([constant(nil), integer(200..599)]), integer(0..20_000_000)}),
                max_length: 100
              )
          ) do
      snapshot =
        Enum.reduce(outcomes, SLO.new(), fn {status, duration}, state ->
          SLO.observe(state, status, duration)
        end)
        |> SLO.snapshot()

      successes =
        Enum.count(outcomes, fn {status, _} -> is_integer(status) and status in 200..499 end)

      bounds = snapshot.duration.explicit_bounds_us

      assert snapshot.service == "audi_private"
      assert snapshot.requests == length(outcomes)
      assert snapshot.successes == successes
      assert snapshot.failures == length(outcomes) - successes
      assert snapshot.duration.count == length(outcomes)
      assert snapshot.duration.sum_us == Enum.sum(Enum.map(outcomes, &elem(&1, 1)))

      assert snapshot.duration.bucket_counts ==
               Enum.map(0..length(bounds), fn index ->
                 Enum.count(outcomes, fn {_, duration} ->
                   Enum.find_index(bounds, &(duration <= &1)) == index or
                     (index == length(bounds) and duration > List.last(bounds))
                 end)
               end)

      refute inspect(snapshot) =~ "request_id"
    end
  end

  test "private publisher atomically replaces an owner-only numeric snapshot" do
    path = Path.join(System.tmp_dir!(), "audi-slo-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    pid = start_supervised!({SLO, path: path})
    send(pid, :publish)
    :sys.get_state(pid)
    assert {:ok, %{"requests" => 0}} = path |> File.read!() |> JSON.decode()

    SLO.record(204, 20_000)
    assert {:ok, %{"requests" => 0}} = path |> File.read!() |> JSON.decode()
    send(pid, :publish)
    :sys.get_state(pid)

    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, body} = File.read(path)
    assert {:ok, %{"requests" => 1, "successes" => 1}} = JSON.decode(body)
  end

  property "public DNS outcomes retain closed counts and one duration bucket per answer" do
    check all(outcomes <- list_of(tuple({boolean(), integer(0..20_000_000)}), max_length: 100)) do
      snapshot =
        Enum.reduce(outcomes, SLO.new("audi_dns"), fn {success?, duration}, state ->
          SLO.observe_outcome(state, success?, duration)
        end)
        |> SLO.snapshot()

      assert snapshot.service == "audi_dns"
      assert snapshot.requests == length(outcomes)
      assert snapshot.successes == Enum.count(outcomes, &elem(&1, 0))
      assert snapshot.failures == snapshot.requests - snapshot.successes
      assert snapshot.duration.count == snapshot.requests
      assert Enum.sum(snapshot.duration.bucket_counts) == snapshot.requests
    end
  end

  # @cc [owner:ghuntley,label:verification] audi-ssh-fixed-outcome-arithmetic
  # Admitted SSH establishment outcomes MUST retain closed counts and one
  # duration bucket without adding caller or guest identity to the snapshot.
  property "SSH establishment outcomes retain fixed cumulative buckets" do
    check all(outcomes <- list_of(tuple({boolean(), integer(0..20_000_000)}), max_length: 100)) do
      snapshot =
        Enum.reduce(outcomes, SLO.new("audi_ssh"), fn {success?, duration}, state ->
          SLO.observe_outcome(state, success?, duration)
        end)
        |> SLO.snapshot()

      assert snapshot.service == "audi_ssh"
      assert snapshot.requests == length(outcomes)
      assert snapshot.successes == Enum.count(outcomes, &elem(&1, 0))
      assert snapshot.failures == snapshot.requests - snapshot.successes
      assert snapshot.duration.count == snapshot.requests
      assert Enum.sum(snapshot.duration.bucket_counts) == snapshot.requests
      refute inspect(snapshot) =~ "vm_id"
    end
  end

  test "concurrent DNS replies keep one atomic outcome and bucket per request" do
    path = Path.join(System.tmp_dir!(), "audi-dns-slo-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    pid = start_supervised!({SLO, path: path, service: "audi_dns"})

    results =
      1..1000
      |> Task.async_stream(fn index -> SLO.record_outcome(rem(index, 2) == 0, index * 100) end,
        max_concurrency: 32,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    send(pid, :publish)
    :sys.get_state(pid)
    assert {:ok, snapshot} = path |> File.read!() |> JSON.decode()
    assert snapshot["service"] == "audi_dns"
    assert snapshot["requests"] == 1000
    assert snapshot["successes"] == 500
    assert snapshot["failures"] == 500
    assert snapshot["duration"]["count"] == 1000
    assert Enum.sum(snapshot["duration"]["bucket_counts"]) == 1000
  end
end
