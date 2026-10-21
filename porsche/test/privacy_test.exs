defmodule Porsche.PrivacyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  defmodule Handler do
    def log(event, %{config: owner}) do
      send(owner, {:source_event, event})
      :ok
    end
  end

  defmodule CrashingServer do
    use GenServer
    @impl true
    def init(secret), do: {:ok, secret}
    @impl true
    def handle_call(:crash, _from, secret), do: raise(secret)
  end

  property "report redaction is independent of arbitrary secret payloads and metadata" do
    secret = draw("secret", binary(min_length: 1, max_length: 4096))

    event = %{
      level: :error,
      msg: {:report, %{label: {:gen_server, :terminate}, state: secret, messages: [secret]}},
      meta: %{porsche_private: true, token: secret, report_cb: fn _ -> secret end}
    }

    filtered = Porsche.Privacy.filter(event, nil)

    assert filtered == %{
             level: :error,
             msg: {:string, "Porsche process_crash (payload redacted)"},
             meta: %{
               domain: [:porsche],
               event: "porsche.process_crash",
               report_category: "process_crash"
             }
           }
  end

  test "raw handlers receive only redacted source events, even without the default formatter" do
    assert :ok = Porsche.Privacy.install()
    assert :ok = :logger.add_handler(:porsche_test_sink, Handler, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:porsche_test_sink) end)
    secret = "synthetic-session-token-and-command"

    :logger.error(
      %{label: {:gen_server, :terminate}, state: secret, messages: [secret]},
      %{domain: [:otp], private_data: secret}
    )

    assert_receive {:source_event, event}
    refute inspect(event) =~ secret
    assert event.meta.report_category == "process_crash"

    :logger.error(secret, %{domain: [:otp, :ssh], command: secret})
    assert_receive {:source_event, ssh_event}
    refute inspect(ssh_event) =~ secret
    assert ssh_event.meta.report_category == "ssh_runtime"

    :logger.error(~c"~p", [secret], %{domain: [:otp]})
    assert_receive {:source_event, formatted}
    refute inspect(formatted) =~ secret
    assert formatted.meta.report_category == "runtime_report"
  end

  test "uncatalogued application and dependency strings are redacted before handlers" do
    event = %{level: :info, msg: {:string, "private-canary"}, meta: %{event: "porsche.started"}}

    assert %{meta: %{event: "porsche.runtime_report"}} =
             clean = Porsche.Privacy.filter(event, nil)

    refute inspect(clean) =~ "private-canary"
  end

  test "producer health remains private and visible while trace ingress is absent without queue recursion" do
    assert :ok = Porsche.Privacy.install()

    assert :ok =
             :logger.add_handler(:porsche_health_sink, Handler, %{level: :all, config: self()})

    on_exit(fn -> :logger.remove_handler(:porsche_health_sink) end)
    previous = System.get_env("OVERALLS_TRACE_SOCKET")
    saved_metadata = :logger.get_process_metadata()
    processor = Process.whereis(Overalls.Diagnostics.Processor)
    :ok = :sys.suspend(processor)
    System.put_env("OVERALLS_TRACE_SOCKET", "/tmp/overalls-absent-health-fixture.sock")
    :logger.set_process_metadata(%{porsche_private: true, command: "synthetic-health-secret"})

    try do
      before = Overalls.Diagnostics.Processor.health()
      assert :ok = Overalls.Diagnostics.Processor.publish_health(Porsche.Events)
      assert_receive {:source_event, %{meta: %{event: "porsche.observability_health"}} = event}
      assert event.msg == {:string, "Observability producer health observed"}
      assert event.meta.trace_available == 1
      assert event.meta.trace_pending == before.pending
      assert event.meta.trace_queue_dropped == before.queue_dropped
      assert event.meta.trace_export_failed == before.export_failed
      refute inspect(event) =~ "synthetic-health-secret"
      assert Overalls.Diagnostics.Processor.health() == before
    after
      :ok = :sys.resume(processor)
      :logger.set_process_metadata(if(is_map(saved_metadata), do: saved_metadata, else: %{}))

      if previous,
        do: System.put_env("OVERALLS_TRACE_SOCKET", previous),
        else: System.delete_env("OVERALLS_TRACE_SOCKET")
    end
  end

  test "reviewed catalog events survive redaction with fixed text and only validated atoms" do
    event = %{
      level: :warning,
      msg: {:string, "original text is discarded"},
      meta: %{
        porsche_private: true,
        event: "porsche.auth_denied",
        reason: :unknown_key,
        fingerprint: "SHA256:secret-fingerprint",
        peer: "10.0.0.1",
        command: "secret-command"
      }
    }

    assert Porsche.Privacy.filter(event, nil) == %{
             level: :warning,
             msg: {:string, "SSH authentication denied"},
             meta: %{domain: [:porsche], event: "porsche.auth_denied", reason: :unknown_key}
           }

    outcome = %{
      level: :info,
      msg: {:string, "Marshall session open outcome"},
      meta: %{
        porsche_private: true,
        event: "porsche.session_outcome",
        outcome_state: :pending_approval
      }
    }

    assert Porsche.Privacy.filter(outcome, nil) == %{
             level: :info,
             msg: {:string, "Marshall session open outcome"},
             meta: %{
               domain: [:porsche],
               event: "porsche.session_outcome",
               outcome_state: :pending_approval
             }
           }
  end

  test "catalogued names with wrong-shaped metadata keep the fixed text without the value" do
    event = %{
      level: :info,
      msg: {:string, "whatever"},
      meta: %{
        porsche_private: true,
        event: "porsche.exchange_failed",
        reason: "secret-reason-text"
      }
    }

    assert Porsche.Privacy.filter(event, nil) == %{
             level: :info,
             msg: {:string, "Marshall HTTPS exchange failed"},
             meta: %{domain: [:porsche], event: "porsche.exchange_failed"}
           }
  end

  property "fingerprints, command markers and credentials never appear in any filter output" do
    payload = draw("payload", string(:printable, min_length: 1, max_length: 128))
    secret = "synthetic-secret-" <> payload

    events = [
      %{
        level: :warning,
        msg: {:string, secret},
        meta: %{
          porsche_private: true,
          event: "porsche.auth_denied",
          reason: :unknown_key,
          fingerprint: secret,
          command: secret
        }
      },
      %{
        level: :info,
        msg: {:string, secret},
        meta: %{porsche_private: true, event: "porsche.session_outcome", outcome_state: secret}
      },
      %{
        level: :warning,
        msg: {:string, secret},
        meta: %{porsche_private: true, event: "porsche.exchange_failed", reason: secret}
      },
      %{
        level: :error,
        msg: {:report, %{label: {:gen_server, :terminate}, state: secret, command: secret}},
        meta: %{porsche_private: true, token: secret}
      },
      %{level: :error, msg: {:string, secret}, meta: %{domain: [:otp, :ssh], command: secret}},
      %{level: :error, msg: {~c"~s~s", [secret, secret]}, meta: %{porsche_private: true}}
    ]

    for event <- events do
      filtered = Porsche.Privacy.filter(event, nil)

      refute inspect(filtered) =~ secret
    end
  end

  test "a real crashing process cannot expose its state or exception to a raw handler" do
    assert :ok = :logger.add_handler(:porsche_test_sink, Handler, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:porsche_test_sink) end)
    secret = "synthetic-crash-state-session-and-command"
    {:ok, pid} = GenServer.start(CrashingServer, secret)
    assert catch_exit(GenServer.call(pid, :crash))
    assert_receive {:source_event, %{meta: %{report_category: "process_crash"}} = event}
    refute inspect(event) =~ secret
    assert event.msg == {:string, "Porsche process_crash (payload redacted)"}
  end

  test "events emitted through the catalog reach raw handlers with fixed text only" do
    assert :ok = Porsche.Privacy.install()
    assert :ok = :logger.add_handler(:porsche_test_sink, Handler, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:porsche_test_sink) end)
    :logger.update_process_metadata(%{porsche_private: true})

    require Porsche.Events
    Porsche.Events.emit("porsche.exchange_failed", reason: :unauthorized)

    assert_receive {:source_event, event}
    assert event.msg == {:string, "Marshall HTTPS exchange failed"}
    assert event.meta.event == "porsche.exchange_failed"
    assert event.meta.reason == :unauthorized
    assert Map.keys(event.meta) -- [:event, :reason, :time, :pid, :gl, :domain] == []
  end
end
