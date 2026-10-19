defmodule MarshallWeb.TerminalLogFilterTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog

  property "only the closed viewer refusal reasons survive tagged process redaction" do
    secret = draw("secret", string(:alphanumeric, min_length: 24))

    reason =
      draw(
        "reason",
        member_of([
          :authority,
          :authority_unconfirmed,
          :authority_login,
          :authority_session,
          :authority_host,
          :authority_writer,
          :input_window,
          :output_window,
          :input_ack,
          :output_ack,
          :slow_viewer,
          :gateway_session,
          :gateway_unavailable,
          :gateway_ticket,
          :stream_unavailable,
          :attach_timeout,
          :attach_refused
        ])
      )

    event = %{
      msg: {:string, secret},
      meta: %{
        marshall_terminal: true,
        event: "terminal.viewer_refused",
        reason: reason,
        bytes: secret
      }
    }

    filtered = MarshallWeb.TerminalLogFilter.filter(event, nil)
    assert filtered.meta == %{event: "terminal.viewer_refused", reason: reason}
    assert filtered.msg == {:string, "Terminal process diagnostic (payload redacted)"}

    for unsafe <- [secret, {:error, secret}, :unexpected] do
      redacted =
        MarshallWeb.TerminalLogFilter.filter(put_in(event, [:meta, :reason], unsafe), nil)

      assert redacted.meta == %{event: "terminal.viewer_refused"}
    end

    other =
      MarshallWeb.TerminalLogFilter.filter(
        put_in(event, [:meta, :event], "terminal.attached"),
        nil
      )

    refute Map.has_key?(other.meta, :reason)
  end

  test "OTP crash reports from terminal processes exclude reason, queued data and state" do
    logs =
      capture_log(fn ->
        pid =
          start_supervised!(
            Supervisor.child_spec(
              {Agent,
               fn ->
                 Logger.metadata(marshall_terminal: true)
                 "PRIVATE_TERMINAL_BYTES"
               end},
              restart: :temporary
            )
          )

        ref = Process.monitor(pid)
        Agent.cast(pid, fn state -> exit({:synthetic_secret, state}) end)
        # Crash-report processing may be scheduled alongside distributed tests;
        # the privacy invariant does not require completion within 100 ms.
        assert_receive {:DOWN, ^ref, :process, ^pid, {:synthetic_secret, _}}, 1_000
      end)

    assert logs =~ "Terminal process diagnostic (payload redacted)"
    refute logs =~ "PRIVATE_TERMINAL_BYTES"
  end

  test "ordinary events keep their diagnostics and browser parameters filter byte fields" do
    assert :ignore =
             MarshallWeb.TerminalLogFilter.filter(%{meta: %{}, msg: {:string, "ordinary"}}, nil)

    assert Phoenix.Logger.filter_values(%{"bytes" => "private", "token" => "secret"}) == %{
             "bytes" => "[FILTERED]",
             "token" => "[FILTERED]"
           }
  end

  test "ticket refusals keep only their closed reason" do
    for reason <- [
          :unknown_session,
          :forbidden,
          :terminal_unavailable,
          :vm_deleted,
          :unavailable,
          :other
        ] do
      event = %{
        msg: {:string, "secret"},
        meta: %{marshall_terminal: true, event: "terminal.ticket_refused", reason: reason}
      }

      assert MarshallWeb.TerminalLogFilter.filter(event, nil).meta ==
               %{event: "terminal.ticket_refused", reason: reason}
    end

    unsafe = %{
      msg: {:string, "secret"},
      meta: %{marshall_terminal: true, event: "terminal.ticket_refused", reason: "secret"}
    }

    assert MarshallWeb.TerminalLogFilter.filter(unsafe, nil).meta ==
             %{event: "terminal.ticket_refused"}
  end
end
