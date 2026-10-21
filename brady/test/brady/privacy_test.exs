defmodule Brady.PrivacyTest do
  use ExUnit.Case, async: false

  test "additional handlers never see raw runtime content" do
    output =
      ExUnit.CaptureLog.capture_log([format: "$message $metadata", metadata: :all], fn ->
        :logger.log(
          :error,
          %{label: {:gen_server, :terminate}, state: "brady-private-canary"},
          %{credential: "brady-private-canary"}
        )
      end)

    assert output =~ "process_crash"
    refute output =~ "brady-private-canary"
  end

  test "status redaction preserves OTP status keys without payloads" do
    status = %{
      state: %{secret: "private-canary"},
      message: "private-canary",
      reason: :boom,
      log: [:secret]
    }

    clean = Brady.Metrics.format_status(status)
    assert Map.keys(clean) |> Enum.sort() == Map.keys(status) |> Enum.sort()
    assert clean == %{state: :redacted, message: :redacted, reason: :redacted, log: []}
  end
end
