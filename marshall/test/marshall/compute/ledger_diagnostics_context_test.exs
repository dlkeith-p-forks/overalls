defmodule Marshall.Compute.LedgerDiagnosticsContextTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.Ledger
  require Record

  Record.defrecordp(
    :span_ctx,
    Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  test "after-commit work retains the registering span while excluding baggage" do
    saved = :otel_ctx.get_current()
    registered = span_ctx(trace_id: 123, span_id: 456, trace_flags: 1)
    committing = span_ctx(trace_id: 789, span_id: 987, trace_flags: 1)
    receiver = self()

    try do
      assert {:ok, :committed} =
               Ledger.transaction(fn ->
                 :otel_tracer.set_current_span(registered)
                 :otel_ctx.set_value(:private_baggage, "registered-private-value")

                 Ledger.after_commit(fn ->
                   send(
                     receiver,
                     {:callback_context, :otel_tracer.current_span_ctx(),
                      :otel_ctx.get_value(:private_baggage)}
                   )
                 end)

                 :otel_tracer.set_current_span(committing)
                 :otel_ctx.set_value(:private_baggage, "committing-private-value")
                 :committed
               end)

      assert_received {:callback_context, ^registered, :undefined}
      refute_received {:callback_context, _, _}
      assert :otel_tracer.current_span_ctx() == committing
      assert :otel_ctx.get_value(:private_baggage) == "committing-private-value"
    after
      :otel_ctx.attach(saved)
    end
  end
end
