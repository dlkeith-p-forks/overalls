defmodule Audi.TLS.FleetCertificateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.TLS.FleetCertificate

  # @cc [owner:ghuntley,label:verification;recovery] audi-fleet-certificate-model
  # For any event sequence: a failed refresh never clears the serving
  # generation, expiry always does, and only an installation sets it.
  property "serving generation follows installs and expiry, never failures" do
    event =
      one_of([
        tuple({constant(:installed), integer(1..5)}),
        tuple({constant(:failed), member_of([:fetch, :probe, :ack, :unavailable])}),
        constant(:expired)
      ])

    events = draw("events", list_of(event, max_length: 50))

    Enum.reduce(events, {FleetCertificate.new(), nil}, fn event, {machine, model} ->
      assert {:ok, next} = FleetCertificate.step(machine, event)

      model =
        case event do
          {:installed, generation} -> generation
          {:failed, _} -> model
          :expired -> nil
        end

      assert FleetCertificate.serving(next) == model
      assert next.state == if(model, do: next.state, else: :unavailable)

      if match?({:failed, _}, event) and model,
        do: assert(next.state == :degraded)

      {next, model}
    end)
  end
end
