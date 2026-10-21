defmodule Overalls.Diagnostics.SDKTest.Catalog do
  use Overalls.Diagnostics.Events.Catalog, service: :lilly

  defevent("lilly.lifecycle_effect_attempted",
    message: "Reviewed effect",
    metadata: [action: :atom]
  )

  defevent("lilly.lifecycle_transition_committed",
    message: "Committed transition",
    delivery: :custody,
    metadata: [
      event_id: :uuid,
      occurred_at: :int64,
      revision: :int64,
      resource_id: :uuid,
      action: :atom,
      next_state: :atom,
      resource_type: :atom
    ]
  )
end

defmodule Overalls.Diagnostics.SDKTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :tmp_dir

  defmodule FailsAfterCallback do
    @spec with_span(:otel_ctx.t(), :opentelemetry.tracer(), binary(), map(), (term() -> term())) ::
            no_return()
    def with_span(_context, _tracer, _name, _options, callback) do
      callback.(:undefined)
      raise "synthetic SDK completion failure"
    end
  end

  defmodule FailsStatus do
    require Record

    Record.defrecord(
      :span_ctx,
      Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    )

    @spec with_span(:otel_ctx.t(), :opentelemetry.tracer(), binary(), map(), (term() -> result)) ::
            result
          when result: term()
    def with_span(_context, _tracer, _name, _options, callback),
      do: callback.(span_ctx(is_recording: true, span_sdk: {__MODULE__, []}))

    @spec set_status(:opentelemetry.span_ctx(), :opentelemetry.status()) :: no_return()
    def set_status(_span, _status), do: raise("synthetic SDK status failure")
  end

  alias Overalls.Diagnostics.SDKTest.Catalog
  require Catalog

  setup do
    socket = "/tmp/overalls-sdk-#{System.unique_integer([:positive])}.sock"
    previous = System.get_env("OVERALLS_TRACE_SOCKET")
    System.put_env("OVERALLS_TRACE_SOCKET", socket)

    on_exit(fn ->
      File.rm(socket)

      if previous,
        do: System.put_env("OVERALLS_TRACE_SOCKET", previous),
        else: System.delete_env("OVERALLS_TRACE_SOCKET")
    end)

    {:ok, socket: socket}
  end

  test "custody admission validates the catalog and only empty successful spool replies export",
       %{socket: socket} do
    _ = Overalls.Diagnostics.Processor.force_flush(%{})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    task = Task.async(fn -> for status <- [503, 204], do: serve(listener, status, "") end)

    metadata = %{
      event_id: "f9ae3c38-91bf-44b9-9565-1a0b7e3e8f38",
      occurred_at: 1_800_000_000_000_000,
      revision: 3_000_000_000,
      resource_id: "096046e4-f2e1-41af-a5fc-46f0e970b328",
      action: :initialize_creating,
      next_state: :creating,
      resource_type: :dataset
    }

    before = Overalls.Diagnostics.Processor.health().export_failed

    for _ <- 1..2 do
      assert :ok =
               Overalls.Diagnostics.Custody.enqueue(
                 Catalog,
                 "lilly.lifecycle_transition_committed",
                 metadata
               )

      _ = Overalls.Diagnostics.Processor.force_flush(%{})
    end

    assert [first, second] = Task.await(task, 5000)
    assert byte_size(first) > 100 and byte_size(second) > 100
    assert Overalls.Diagnostics.Processor.health().export_failed >= before + 1
    assert {:error, :invalid} = Overalls.Diagnostics.Custody.enqueue(Catalog, "unknown", metadata)
  end

  test "routine queue admission is bounded and does not change work when spool is absent" do
    processor = Process.whereis(Overalls.Diagnostics.Processor)
    :ok = :sys.suspend(processor)

    try do
      for _ <- 1..400,
          do:
            assert(
              :ok ==
                Catalog.emit("lilly.lifecycle_effect_attempted", action: :zfs_create)
            )

      assert %{available: true, pending: 256, queue_dropped: dropped} =
               Overalls.Diagnostics.Processor.health()

      assert dropped >= 144

      assert :returned =
               Overalls.Diagnostics.Tracing.with_span(
                 "lilly.host.utility",
                 [utility: :zfs_create],
                 fn ->
                   :returned
                 end
               )

      assert_raise RuntimeError, "application failure", fn ->
        Overalls.Diagnostics.Tracing.with_span("lilly.host.utility", [], fn ->
          raise "application failure"
        end)
      end
    after
      :sys.resume(processor)
    end

    assert {:error, :unavailable} = Overalls.Diagnostics.Processor.force_flush(%{})

    assert %{available: true, pending: 0, export_failed: failed} =
             Overalls.Diagnostics.Processor.health()

    assert failed >= 256
  end

  test "official encoder batches routine spans and exporter rejects partial success", %{
    socket: socket
  } do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    task = Task.async(fn -> serve(listener, 200, "partial refusal") end)

    assert :ok =
             Catalog.emit("lilly.lifecycle_effect_attempted", action: :zfs_create)

    assert {:error, :unavailable} = Overalls.Diagnostics.Processor.force_flush(%{})
    assert byte_size(Task.await(task, 5000)) > 100
  end

  test "standalone catalog Logger identifiers match the actual official OTLP span", %{
    socket: socket
  } do
    _ = Overalls.Diagnostics.Processor.force_flush(%{})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    task = Task.async(fn -> serve(listener, 200, "") end)

    log =
      capture_log([metadata: [:trace_id, :span_id]], fn ->
        Catalog.emit("lilly.lifecycle_effect_attempted", action: :zfs_create)
      end)

    assert :ok = Overalls.Diagnostics.Processor.force_flush(%{})

    request =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        Task.await(task, 5000),
        :export_trace_service_request
      )

    assert %{resource_spans: [%{scope_spans: [%{spans: [span]}]}]} = request
    assert log =~ Base.encode16(span.trace_id, case: :lower)
    assert log =~ Base.encode16(span.span_id, case: :lower)
    assert log =~ "Reviewed effect"
  end

  test "SDK failure before or after work preserves single callback execution and original exception" do
    key = {Overalls.Diagnostics.Tracing, :tracer}
    saved = :persistent_term.get(key)

    try do
      for tracer <- [
            {Overalls.Diagnostics.UnavailableTracer, []},
            {FailsAfterCallback, []},
            {FailsStatus, []}
          ] do
        :persistent_term.put(key, tracer)
        Process.put(:work_invocations, 0)
        exact = make_ref()

        assert exact ==
                 Overalls.Diagnostics.Tracing.with_span("lilly.host.utility", [], fn ->
                   Process.put(:work_invocations, Process.get(:work_invocations) + 1)
                   exact
                 end)

        assert Process.get(:work_invocations) == 1
        Process.put(:work_invocations, 0)

        assert catch_throw(
                 Overalls.Diagnostics.Tracing.with_span("lilly.host.utility", [], fn ->
                   Process.put(:work_invocations, Process.get(:work_invocations) + 1)
                   throw({:application_outcome, exact})
                 end)
               ) == {:application_outcome, exact}

        assert Process.get(:work_invocations) == 1
      end
    after
      :persistent_term.put(key, saved)
      Process.delete(:work_invocations)
    end
  end

  test "operation errors have closed status without reason or exception content", %{
    socket: socket
  } do
    _ = Overalls.Diagnostics.Processor.force_flush(%{})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    task = Task.async(fn -> serve(listener, 200, "") end)

    assert {:error, "synthetic-private-reason"} =
             Overalls.Diagnostics.Tracing.with_span("lilly.host.utility", [], fn ->
               {:error, "synthetic-private-reason"}
             end)

    assert %{status: 503} =
             Overalls.Diagnostics.Tracing.with_span("galileo.http", [], fn -> %{status: 503} end)

    assert :ok = Overalls.Diagnostics.Processor.force_flush(%{})
    body = Task.await(task, 5000)
    refute body =~ "synthetic-private-reason"

    request =
      :opentelemetry_exporter_trace_service_pb.decode_msg(body, :export_trace_service_request)

    assert %{resource_spans: [%{scope_spans: [%{spans: spans}]}]} = request
    assert length(spans) == 2
    for span <- spans, do: assert(span.status.code == :STATUS_CODE_ERROR)
  end

  test "deferred events retain their parent span without copying baggage", %{socket: socket} do
    _ = Overalls.Diagnostics.Processor.force_flush(%{})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    exporter = Task.async(fn -> serve(listener, 200, "") end)

    assert :ok =
             Overalls.Diagnostics.Tracing.with_span("enrico.http", [], fn ->
               callback =
                 Overalls.Diagnostics.Context.wrap(fn ->
                   Catalog.emit("lilly.lifecycle_effect_attempted", action: :zfs_create)
                 end)

               callback |> Task.async() |> Task.await()
             end)

    assert :ok = Overalls.Diagnostics.Processor.force_flush(%{})

    request =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        Task.await(exporter, 5000),
        :export_trace_service_request
      )

    assert %{resource_spans: [%{scope_spans: [%{spans: spans}]}]} = request
    assert length(spans) == 2
    parent = Enum.find(spans, &(&1.name == "enrico.http"))
    child = Enum.find(spans, &(&1.name == "lilly.lifecycle_effect_attempted"))
    assert child.trace_id == parent.trace_id
    assert child.parent_span_id == parent.span_id
  end

  @spec serve(port(), non_neg_integer(), binary()) :: binary()
  defp serve(listener, status, response) do
    {:ok, socket} = :gen_tcp.accept(listener, 5000)
    body = request(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} Test\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
      )

    :gen_tcp.close(socket)
    body
  end

  @spec request(port(), binary()) :: binary()
  defp request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: ([0-9]+)/i, headers)
        if byte_size(body) == String.to_integer(length), do: body, else: more(socket, bytes)

      [_] ->
        more(socket, bytes)
    end
  end

  @spec more(port(), binary()) :: binary()
  defp more(socket, bytes) do
    {:ok, next} = :gen_tcp.recv(socket, 0, 5000)
    request(socket, bytes <> next)
  end
end
