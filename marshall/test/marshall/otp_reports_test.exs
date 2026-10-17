defmodule Marshall.OTPReportsTest do
  use ExUnit.Case, async: true

  test "runtime reports cannot render process secrets or terminal contents" do
    sentinel = "private-terminal-and-credential-sentinel"

    for label <- [
          {:gen_server, :terminate},
          {:proc_lib, :crash},
          {:supervisor, :progress},
          :unknown
        ] do
      {:ok, message, metadata} =
        Marshall.OTPReports.translate(
          :debug,
          :error,
          :report,
          {:logger,
           %{label: label, state: sentinel, reason: sentinel, message: sentinel, args: [sentinel]}}
        )

      refute inspect({message, metadata}) =~ sentinel
      assert Keyword.fetch!(metadata, :event) =~ "otp."
    end

    {:ok, message, _} =
      Marshall.OTPReports.translate(:debug, :error, :format, {~c"~p", [sentinel]})

    refute to_string(message) =~ sentinel
  end

  test "an actual untagged OTP crash never formats process state" do
    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        pid =
          start_supervised!(
            Supervisor.child_spec(
              {Agent, fn -> "OTP_PRIVATE_STATE_SENTINEL" end},
              restart: :temporary
            )
          )

        ref = Process.monitor(pid)
        Agent.cast(pid, fn state -> exit({:private_reason, state}) end)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:private_reason, _}}, 5_000
        Logger.flush()
      end)

    assert logs =~ "process_crash"
    refute logs =~ "OTP_PRIVATE_STATE_SENTINEL"
    refute logs =~ "private_reason"
  end
end
