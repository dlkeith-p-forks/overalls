defmodule Overalls.Diagnostics.ContextTest do
  use ExUnit.Case, async: true
  alias Overalls.Diagnostics.Context

  test "deferred work excludes baggage and restores the worker context" do
    saved = :otel_ctx.get_current()

    try do
      :otel_ctx.set_value(:private_baggage, "parent-private-canary")
      wrapped = Context.wrap(fn -> :otel_ctx.get_value(:private_baggage) end)

      task =
        Task.async(fn ->
          :otel_ctx.set_value(:private_baggage, "worker-private-canary")
          assert wrapped.() == :undefined
          assert :otel_ctx.get_value(:private_baggage) == "worker-private-canary"
        end)

      Task.await(task)
      assert :otel_ctx.get_value(:private_baggage) == "parent-private-canary"
    after
      :otel_ctx.attach(saved)
    end
  end

  test "callback raises and throws exactly once while restoring context" do
    saved = :otel_ctx.get_current()

    try do
      for mode <- [:raise, :throw, :exit] do
        wrapped =
          Context.wrap(fn ->
            Process.put(:context_callback_count, Process.get(:context_callback_count, 0) + 1)

            case mode do
              :raise -> raise "callback failure"
              :throw -> throw(:callback_failure)
              :exit -> exit(:callback_failure)
            end
          end)

        Process.put(:context_callback_count, 0)
        :otel_ctx.set_value(:worker_context, mode)

        case mode do
          :raise -> assert_raise RuntimeError, "callback failure", wrapped
          :throw -> assert catch_throw(wrapped.()) == :callback_failure
          :exit -> assert catch_exit(wrapped.()) == :callback_failure
        end

        assert Process.get(:context_callback_count) == 1
        assert :otel_ctx.get_value(:worker_context) == mode
      end
    after
      Process.delete(:context_callback_count)
      :otel_ctx.attach(saved)
    end
  end
end
