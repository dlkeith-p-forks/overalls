defmodule Overalls.Diagnostics.SharedObservabilityTest do
  use ExUnit.Case, async: false

  alias Overalls.Diagnostics.Events.Catalog
  alias Overalls.Diagnostics.Metrics
  alias Overalls.Diagnostics.Privacy

  defmodule ProjectionCatalog do
    use Catalog, service: :lilly

    defevent("lilly.log_only",
      message: "Log only",
      trace: false,
      metadata: [outcome: {{:enum, [:ok, :error]}, :optional}]
    )

    defevent("lilly.trace_only", message: "Trace only", log: false, metadata: [])
  end

  setup do
    assert :ok = Metrics.reset()
    :ok
  end

  test "catalog projection exposes independent log and trace decisions" do
    assert %{log?: true, trace?: false, message: "Log only"} =
             Catalog.projection(ProjectionCatalog, "lilly.log_only")

    assert Catalog.log_event?(ProjectionCatalog, "lilly.log_only")
    refute Catalog.trace_event?(ProjectionCatalog, "lilly.log_only")
    refute Catalog.log_event?(ProjectionCatalog, "lilly.trace_only")
    assert Catalog.trace_event?(ProjectionCatalog, "lilly.trace_only")
    refute Catalog.projection(ProjectionCatalog, "lilly.missing")
  end

  test "metrics reject unregistered paths and unreviewed labels" do
    assert :ok = Metrics.record([:marshall, :terminal, :input], %{duration: 3}, %{})
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => 3}}} = Metrics.snapshot()
    assert {:error, :invalid} = Metrics.record([:marshall, :secret, :payload], %{count: 1}, %{})

    assert {:error, :invalid} =
             Metrics.record([:marshall, :terminal, :input], %{count: 1}, %{payload: "secret"})
  end

  test "metrics keep cardinality bounded and count overflow" do
    # The fixed registry accepts known paths only; repeated updates never grow
    # the table beyond one entry per event and measurement.
    assert Enum.all?(1..100, fn _ ->
             :ok == Metrics.record([:marshall, :terminal, :input], %{duration: 1}, %{})
           end)

    assert %{size: size, capacity: capacity, dropped: 0} = Metrics.health()
    assert size <= capacity
  end

  test "metric snapshots read without consuming and interval snapshots consume values" do
    event = [:marshall, :terminal, :input]
    assert :ok = Metrics.record(event, %{duration: 3})
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => 3}}} = Metrics.snapshot()
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => 3}}} = Metrics.snapshot()
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => 3}}} = Metrics.take_snapshot()
    assert {:ok, %{}} = Metrics.snapshot()
    assert {:ok, %{}} = Metrics.take_snapshot()

    assert :ok = Metrics.record(event, %{duration: 2})
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => 2}}} = Metrics.take_snapshot()
    assert {:ok, %{}} = Metrics.take_snapshot()
  end

  test "metric snapshots distinguish an empty registry from an unavailable owner" do
    assert {:ok, %{}} = Metrics.snapshot()
    assert {:ok, %{}} = Metrics.take_snapshot()

    supervisor = Overalls.Diagnostics.Application.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, Metrics)

    on_exit(fn ->
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Metrics)
    end)

    assert {:error, :unavailable} = Metrics.snapshot()
    assert {:error, :unavailable} = Metrics.take_snapshot()
    assert {:error, :unavailable} = Metrics.record([:marshall, :terminal, :input], %{duration: 1})
  end

  test "concurrent interval consumers account for every accepted increment exactly once" do
    consumers = Enum.map(1..2, fn _ -> Task.async(fn -> consume_intervals(0) end) end)

    producers =
      Enum.map(1..8, fn _ ->
        Task.async(fn ->
          Enum.each(1..500, fn _ ->
            assert :ok = Metrics.record([:marshall, :terminal, :input], %{duration: 1})
          end)
        end)
      end)

    Enum.each(producers, &Task.await(&1, 10_000))
    Enum.each(consumers, &send(&1.pid, :finish))
    assert consumers |> Enum.map(&Task.await(&1, 10_000)) |> Enum.sum() == 4_000
    assert {:ok, %{}} = Metrics.snapshot()
  end

  test "metric overflow is explicit and remains unknown until reset" do
    event = [:marshall, :terminal, :input]
    assert :ok = Metrics.record(event, %{duration: 9_223_372_036_854_775_807}, %{})
    assert {:error, :overflow} = Metrics.record(event, %{duration: 1}, %{})
    assert {:ok, %{"marshall.terminal.input" => %{"duration" => :unknown}}} = Metrics.snapshot()

    assert {:ok, %{"marshall.terminal.input" => %{"duration" => :unknown}}} =
             Metrics.take_snapshot()

    assert {:error, :overflow} = Metrics.record(event, %{duration: 1})

    assert {:ok, %{"marshall.terminal.input" => %{"duration" => :unknown}}} =
             Metrics.take_snapshot()

    assert %{dropped: 1} = Metrics.health()
    assert :ok = Metrics.reset()
    assert {:ok, %{}} = Metrics.take_snapshot()
    assert :ok = Metrics.record(event, %{duration: 1}, %{})
  end

  test "privacy translates OTP reports and drops source text" do
    event = %{
      msg: {:report, %{label: {:gen_server, :terminate}, reason: "private"}},
      meta: %{pid: self()}
    }

    filtered = Privacy.filter(event, Privacy.install_state(ProjectionCatalog, :lilly))
    assert %{msg: {:string, message}, meta: %{event: "lilly.process_crash"}} = filtered
    assert message =~ "payload redacted"
    refute inspect(filtered) =~ "private"
  end

  test "privacy drops trace-only catalog events before handlers" do
    event = %{msg: {:string, "trace-only"}, meta: %{event: "lilly.trace_only"}}
    assert :stop = Privacy.filter(event, Privacy.install_state(ProjectionCatalog, :lilly))
  end

  test "privacy redacts an ordinary uncatalogued logger message" do
    event = %{msg: {:string, "credential=secret"}, meta: %{token: "secret"}}
    filtered = Privacy.filter(event, Privacy.install_state(ProjectionCatalog, :lilly))
    assert filtered.msg == {:string, "Lilly runtime_report (payload redacted)"}
    refute inspect(filtered) =~ "secret"
  end

  test "privacy installation only accepts the exact installed filter" do
    id = :diagnostics_installation_test
    on_exit(fn -> :logger.remove_primary_filter(id) end)

    assert :ok = Privacy.install(ProjectionCatalog, :lilly, filter_id: id)
    assert :ok = Privacy.install(ProjectionCatalog, :lilly, filter_id: id)

    assert {:error, :privacy_filter_conflict} =
             Privacy.install(ProjectionCatalog, :marshall, filter_id: id)

    assert :ok = :logger.remove_primary_filter(id)
    assert :ok = :logger.add_primary_filter(id, {fn _event, _state -> :ignore end, nil})

    assert {:error, :privacy_filter_conflict} =
             Privacy.install(ProjectionCatalog, :lilly, filter_id: id)

    assert {:error, :privacy_filter_unavailable} =
             Privacy.install(ProjectionCatalog, :lilly, filter_id: "invalid")
  end

  @spec consume_intervals(non_neg_integer()) :: non_neg_integer()
  defp consume_intervals(total) do
    receive do
      :finish -> total + take_count()
    after
      0 -> consume_intervals(total + take_count())
    end
  end

  @spec take_count() :: non_neg_integer()
  defp take_count do
    assert {:ok, snapshot} = Metrics.take_snapshot()
    snapshot |> Map.get("marshall.terminal.input", %{}) |> Map.get("duration", 0)
  end
end
