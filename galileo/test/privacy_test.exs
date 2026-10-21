defmodule Galileo.PrivacyTest do
  use ExUnit.Case, async: true

  test "logger handlers cannot inspect content, secrets, state or report callbacks" do
    for message <- [
          {:report, %{state: "synthetic-secret"}},
          {~c"~p", ["synthetic-secret"]},
          {:string, "synthetic-secret"}
        ] do
      event = %{
        level: :error,
        msg: message,
        meta: %{
          bearer: "synthetic-secret",
          request_id: "invalid",
          report_cb: fn _ -> "synthetic-secret" end
        }
      }

      clean = Galileo.Privacy.filter(event, nil)
      refute inspect(clean) =~ "synthetic-secret"
      refute Map.has_key?(clean.meta, :report_cb)
      refute Map.has_key?(clean.meta, :request_id)
    end
  end

  test "only validated identifiers survive" do
    id = "01234567-89ab-4def-8123-456789abcdef"

    clean =
      Galileo.Privacy.filter(
        %{
          level: :info,
          msg: {:string, "x"},
          meta: %{event: "galileo.request_authorized", vm_id: id, other: "value"}
        },
        nil
      )

    assert clean.meta.vm_id == id
    refute Map.has_key?(clean.meta, :other)

    unreviewed =
      Galileo.Privacy.filter(
        %{level: :info, msg: {:string, "x"}, meta: %{vm_id: id}},
        nil
      )

    refute Map.has_key?(unreviewed.meta, :vm_id)
  end

  test "only catalogued fixed categories survive" do
    clean =
      Galileo.Privacy.filter(
        %{
          level: :warning,
          msg: {:string, "x"},
          meta: %{event: "galileo.request_denied", reason: :unauthorized}
        },
        nil
      )

    assert clean.meta.event == "galileo.request_denied"
    assert clean.meta.reason == :unauthorized

    rejected =
      Galileo.Privacy.filter(
        %{level: :warning, msg: {:string, "x"}, meta: %{event: "unknown", reason: "raw"}},
        nil
      )

    assert rejected.meta.event == "galileo.runtime_report"
    refute Map.has_key?(rejected.meta, :reason)
  end

  test "OTP crash categories survive without process state" do
    clean =
      Galileo.Privacy.filter(
        %{
          level: :error,
          msg: {:report, %{label: {:gen_server, :terminate}, state: "synthetic-secret"}},
          meta: %{}
        },
        nil
      )

    assert clean.meta.event == "galileo.process_crash"
    assert clean.meta.report_category == :process_crash
    refute inspect(clean) =~ "synthetic-secret"
  end
end
