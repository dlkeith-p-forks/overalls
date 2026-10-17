defmodule Overalls.Diagnostics.FormatterTest do
  use ExUnit.Case, async: true

  defmodule Catalog do
    use Overalls.Diagnostics.Events.Catalog, service: :lilly

    defevent("lilly.formatter_test",
      message: "Formatter test event",
      metadata: [count: :int64, outcome: {{:enum, [:ok, :error]}, :optional}],
      trace: false
    )
  end

  test "emits one stable envelope and keeps only reviewed metadata" do
    trace_id = String.duplicate("a", 32)
    span_id = String.duplicate("b", 16)

    output =
      Overalls.Diagnostics.Formatter.format(
        %{
          level: :info,
          msg: {:string, "untrusted replacement"},
          meta: %{
            event: "lilly.formatter_test",
            count: 4,
            outcome: :ok,
            payload: "secret",
            trace_id: trace_id,
            span_id: span_id
          }
        },
        catalog: Catalog
      )

    assert %{
             "schema_version" => 1,
             "event" => "lilly.formatter_test",
             "message" => "Formatter test event",
             "metadata" => %{
               "count" => 4,
               "outcome" => "ok",
               "trace_id" => ^trace_id,
               "span_id" => ^span_id
             }
           } = Jason.decode!(IO.iodata_to_binary(output))

    refute IO.iodata_to_binary(output) =~ "secret"
    refute IO.iodata_to_binary(output) =~ "untrusted replacement"
  end

  test "uncatalogued reports use a fixed redacted message" do
    output =
      Overalls.Diagnostics.Formatter.format(
        %{level: :error, msg: {:string, "secret exception"}, meta: %{token: "secret"}},
        service: :lilly
      )

    assert %{
             "event" => "runtime.diagnostic",
             "message" => "lilly runtime diagnostic (payload redacted)"
           } =
             Jason.decode!(IO.iodata_to_binary(output))

    refute IO.iodata_to_binary(output) =~ "secret"
  end

  test "accepts OTP map formatter configuration and preserves finite runtime categories" do
    output =
      Overalls.Diagnostics.Formatter.format(
        %{
          level: :warning,
          msg: {:report, %{label: {:gen_server, :terminate}, reason: "secret"}},
          meta: %{
            event: "otp.process_crash",
            report_category: "process_crash",
            request_id: "00000000-0000-0000-0000-000000000001",
            token: "secret"
          }
        },
        %{catalog: Catalog, service: :lilly}
      )

    assert %{
             "event" => "otp.process_crash",
             "message" => "lilly process_crash (payload redacted)",
             "metadata" => %{
               "report_category" => "process_crash",
               "request_id" => "00000000-0000-0000-0000-000000000001"
             }
           } = Jason.decode!(IO.iodata_to_binary(output))

    refute IO.iodata_to_binary(output) =~ "secret"
  end
end
