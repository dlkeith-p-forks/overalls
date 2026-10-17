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
end
