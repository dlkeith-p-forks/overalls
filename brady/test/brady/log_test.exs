defmodule Brady.LogTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "arbitrary request and crash payloads cannot enter serialized events" do
    payload = draw("payload", binary())

    event = %{
      msg: {:report, %{reason: payload, state: payload}},
      meta: %{
        url: payload,
        body: payload,
        password: payload,
        brady_event: %{
          event: :request,
          url: payload,
          request_body: payload,
          response_body: payload,
          headers: payload,
          reason: payload
        }
      }
    }

    assert event |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "runtime_event"}
  end

  test "preserves validated identifiers and bounded request measurements" do
    id = "12345678-1234-1234-1234-123456789abc"

    fields = %{
      host_id: id,
      vm_id: id,
      owner_id: id,
      placement_id: id,
      attribution: :resolved,
      method: "GET",
      status: 200,
      duration_us: 12,
      cache: :hit,
      protocol: :https
    }

    assert Brady.Log.sanitize(fields) == fields
    assert Brady.Log.sanitize(%{owner_id: "secret", method: "SECRET", bytes_sent: -1}) == %{}
  end

  test "runtime messages are replaced, not formatted" do
    assert Brady.Log.format(%{msg: "secret", meta: %{reason: "secret"}}, %{}) ==
             [~s({"event":"runtime_event"}), "\n"]
  end

  defmodule Sink do
    # @cc [owner:ghuntley,label:verification;concurrency] fixture-log-owner-only
    # Capture MUST select the fixture's emitter, so concurrent application logs
    # cannot become evidence for its catalog serialization assertion.
    @spec log(:logger.log_event(), %{config: pid()}) :: :ok
    def log(%{meta: %{pid: emitter}} = event, %{config: owner}) when emitter == owner do
      send(owner, {:log_event, event})
      :ok
    end

    def log(_event, _config), do: :ok
  end

  test "catalogued events emitted through the catalog serialize with validated metadata" do
    :ok = :logger.add_handler(:brady_log_test_sink, Sink, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:brady_log_test_sink) end)

    require Brady.Events
    Brady.Events.emit("brady.cache_store_lost", reason: :crashed)

    assert_receive {:log_event, event}, 1_000

    assert event |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "brady.cache_store_lost", "reason" => "crashed"}
  end

  test "catalogued event names serialize with their declared metadata" do
    event = %{
      msg: {:string, "Listener failed"},
      meta: %{event: "brady.listener_failed", reason: :acceptor_stopped}
    }

    assert event |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "brady.listener_failed", "reason" => "acceptor_stopped"}

    identity_free = %{
      msg: {:string, "Runtime CA leaf certificate signed"},
      meta: %{event: "brady.certificate_signed"}
    }

    assert identity_free |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "brady.certificate_signed"}
  end

  test "catalogued names with mismatched message or undeclared keys stay redacted" do
    for event <- [
          %{msg: {:string, "secret message"}, meta: %{event: "brady.listener_failed"}},
          %{
            msg: {:string, "Listener failed"},
            meta: %{event: "brady.listener_failed", reason: "secret"}
          },
          %{
            msg: {:string, "Listener failed"},
            meta: %{event: "brady.not_catalogued", reason: :ok}
          },
          %{
            msg: {:report, secret: "secret"},
            meta: %{event: "brady.listener_failed", reason: :ok}
          }
        ] do
      assert event |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
               %{"event" => "runtime_event"}
    end
  end

  property "smuggled secrets cannot ride catalogued event names" do
    suffix = draw("suffix", string(:printable, min_length: 1, max_length: 128))
    secret = "smuggled-secret-" <> suffix

    undeclared = %{
      msg: {:string, "Listener failed"},
      meta: %{
        event: "brady.listener_failed",
        reason: :acceptor_stopped,
        host: secret,
        secret: secret
      }
    }

    assert undeclared |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "brady.listener_failed", "reason" => "acceptor_stopped"}

    wrong_shape = %{
      msg: {:string, "Listener failed" <> secret},
      meta: %{event: "brady.listener_failed", reason: secret}
    }

    output = wrong_shape |> Brady.Log.format(%{}) |> IO.iodata_to_binary()

    refute output =~ secret
    assert JSON.decode!(output) == %{"event" => "runtime_event"}
  end

  property "arbitrary payload on catalogued names is redacted when shapes mismatch" do
    payload = draw("payload", binary())
    event = %{msg: payload, meta: %{event: "brady.cache_store_lost", reason: payload}}

    assert event |> Brady.Log.format(%{}) |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{"event" => "runtime_event"}
  end

  property "cache publication outcomes cannot carry arbitrary diagnostic payload" do
    secret = draw("secret", binary())
    assert Brady.Log.sanitize(%{cache_write: secret}) == %{}

    for outcome <- [:published, :abandoned, :not_attempted] do
      assert Brady.Log.sanitize(%{cache_write: outcome, url: secret, payload: secret}) == %{
               cache_write: outcome
             }
    end
  end

  test "mid-stream transport failure reasons survive sanitization" do
    assert Brady.Log.sanitize(%{reason: :transport, cache: :failed}) == %{
             reason: :transport,
             cache: :failed
           }

    assert Brady.Log.sanitize(%{reason: :closed}) == %{reason: :closed}
  end
end
