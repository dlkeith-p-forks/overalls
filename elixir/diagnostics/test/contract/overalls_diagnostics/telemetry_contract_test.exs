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
end
