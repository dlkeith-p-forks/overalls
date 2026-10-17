defmodule OverallsDiagnosticsTelemetryContractTest do
  use Covenant.Case, component: "overalls_diagnostics.telemetry"

  @tag obligation: "overalls_diagnostics.telemetry.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Overalls.Diagnostics,
      Overalls.Diagnostics.Application,
      Overalls.Diagnostics.Configuration,
      Overalls.Diagnostics.Context,
      Overalls.Diagnostics.Custody,
      Overalls.Diagnostics.Events.Catalog,
      Overalls.Diagnostics.Exporter,
      Overalls.Diagnostics.Formatter,
      Overalls.Diagnostics.IdGenerator,
      Overalls.Diagnostics.Metrics,
      Overalls.Diagnostics.Privacy,
      Overalls.Diagnostics.Processor,
      Overalls.Diagnostics.Sampler,
      Overalls.Diagnostics.Schema,
      Overalls.Diagnostics.Tracing
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_diagnostics.telemetry.I2"
  test "privacy filter emits fixed messages and removes unreviewed payload" do
    state =
      Overalls.Diagnostics.Privacy.install_state(Overalls.Diagnostics.Events.Catalog, :marshall)

    event = %{msg: {:string, "secret source text"}, meta: %{password: "secret", token: "secret"}}
    filtered = Overalls.Diagnostics.Privacy.filter(event, state)
    assert %{msg: {:string, _}, meta: metadata} = filtered
    refute Map.has_key?(metadata, :password)
    refute Map.has_key?(metadata, :token)
  end

  @tag obligation: "overalls_diagnostics.telemetry.I3"
  test "runtime categories are finite" do
    filtered =
      Overalls.Diagnostics.Privacy.filter(
        %{msg: {:string, "secret"}, meta: %{}},
        Overalls.Diagnostics.Privacy.install_state(Overalls.Diagnostics.Events.Catalog, :marshall)
      )

    assert %{meta: %{event: "marshall.runtime_report"}} = filtered

    assert :process_crash =
             Overalls.Diagnostics.Privacy.otp_category(
               {:report, %{label: {:gen_server, :terminate}}}
             )

    assert "marshall.runtime_report" =
             Overalls.Diagnostics.Privacy.category_event(:marshall, :runtime_report)
  end

  @tag obligation: "overalls_diagnostics.telemetry.I4"
  test "catalog validation is closed over events and metadata" do
    catalog = Overalls.Diagnostics.Events.Catalog

    assert {:error, :invalid} =
             Overalls.Diagnostics.Events.Catalog.validate(catalog, "unknown.event", %{})

    assert {:error, :invalid} =
             Overalls.Diagnostics.Events.Catalog.validate(catalog, "marshall.runtime_report", %{
               password: "x"
             })

    assert {:error, :invalid} =
             Overalls.Diagnostics.Events.Catalog.validate(catalog, "marshall.runtime_report",
               event: "x",
               event: "y"
             )
  end

  @tag obligation: "overalls_diagnostics.telemetry.I5"
  test "untyped filter input is ignored" do
    state =
      Overalls.Diagnostics.Privacy.install_state(Overalls.Diagnostics.Events.Catalog, :marshall)

    assert :ignore = Overalls.Diagnostics.Privacy.filter(:not_an_event, state)
  end

  @tag obligation: "overalls_diagnostics.telemetry.I6"
  test "schema predicates reject malformed and unknown values" do
    assert Overalls.Diagnostics.Schema.uuid?("123e4567-e89b-12d3-a456-426614174000")
    assert Overalls.Diagnostics.Schema.uuid?("123E4567-e89b-12d3-a456-426614174000")
    refute Overalls.Diagnostics.Schema.uuid?("123e4567-e89b-12d3-a456-42661417400")
    refute Overalls.Diagnostics.Schema.uuid?(:not_a_uuid)
    refute Overalls.Diagnostics.Schema.enum?(:not_in_trace_schema)
  end

  @tag obligation: "overalls_diagnostics.telemetry.I7"
  test "metric interval snapshots consume accepted measurements once" do
    assert :ok = Overalls.Diagnostics.Metrics.reset()
    assert :ok = Overalls.Diagnostics.Metrics.record([:audi, :ssh, :candidate], %{count: 2})
    assert {:ok, first} = Overalls.Diagnostics.Metrics.take_snapshot()
    assert get_in(first, ["audi.ssh.candidate", "count"]) == 2
    assert {:ok, second} = Overalls.Diagnostics.Metrics.take_snapshot()
    refute Map.has_key?(second, "audi.ssh.candidate")
    assert :ok = Overalls.Diagnostics.Metrics.reset()
    assert {:ok, empty} = Overalls.Diagnostics.Metrics.take_snapshot()
    assert empty == %{}
  end

  @tag obligation: "overalls_diagnostics.telemetry.I8"
  test "processor health has bounded typed counters" do
    health = Overalls.Diagnostics.Processor.health()
    assert is_boolean(health.available)
    assert is_integer(health.pending) and health.pending >= 0
    assert is_integer(health.queue_dropped) and health.queue_dropped >= 0
    assert is_integer(health.export_failed) and health.export_failed >= 0
  end
end
