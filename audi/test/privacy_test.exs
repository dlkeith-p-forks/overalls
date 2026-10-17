defmodule Audi.PrivacyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  @catalog Audi.Events.__catalog__()
  @uuid "11111111-1111-4111-8111-111111111111"
  @maximum 9_223_372_036_854_775_807

  test "editor events retain reviewed account and execution fields through the actual log handler" do
    require Audi.Events

    output =
      ExUnit.CaptureLog.capture_log(fn ->
        :logger.update_process_metadata(%{private_payload: "private-canary"})

        Audi.Events.emit("audi.editor_admitted",
          host_id: @uuid,
          vm_id: @uuid,
          placement_id: @uuid,
          session_id: @uuid,
          guest_account_id: @uuid,
          user_id: @uuid,
          execution_epoch: @maximum,
          generation: @maximum
        )
      end)

    refute output =~ "private-canary"
    assert output =~ "Editor stream admitted"

    event = %{
      level: :info,
      msg: {:string, "private-canary"},
      meta: %{
        event: "audi.editor_admitted",
        guest_account_id: @uuid,
        user_id: @uuid,
        execution_epoch: @maximum,
        generation: @maximum,
        origin: "private-canary"
      }
    }

    assert %{
             guest_account_id: @uuid,
             user_id: @uuid,
             execution_epoch: @maximum,
             generation: @maximum
           } =
             Audi.Privacy.filter(event, nil).meta

    refute inspect(Audi.Privacy.filter(event, nil)) =~ "private-canary"

    for invalid <- [-1, @maximum + 1, "private-canary"] do
      rejected =
        event
        |> put_in([:meta, :execution_epoch], invalid)
        |> put_in([:meta, :generation], invalid)
        |> Audi.Privacy.filter(nil)

      refute Map.has_key?(rejected.meta, :execution_epoch)
      refute Map.has_key?(rejected.meta, :generation)
      refute inspect(rejected) =~ "private-canary"
    end

    denied = %{
      event
      | meta: %{
          event: "audi.editor_denied",
          reason: :origin_mismatch,
          guest_account_id: @uuid,
          user_id: @uuid
        }
    }

    assert Audi.Privacy.filter(denied, nil).meta == %{
             event: "audi.editor_denied",
             domain: [:audi],
             reason: :origin_mismatch
           }
  end

  test "reviewed events keep validated identifiers but discard arbitrary text and metadata" do
    event = %{
      level: :info,
      msg: {:string, "private-canary"},
      meta: %{
        event: "audi.ssh_open",
        host_id: @uuid,
        vm_id: "private-canary",
        token: "private-canary"
      }
    }

    sanitized = Audi.Privacy.filter(event, nil)
    assert sanitized.msg == {:string, "SSH stream opened"}
    assert sanitized.meta.host_id == @uuid
    assert sanitized.meta.event == "audi.ssh_open"
    refute inspect(sanitized) =~ "private-canary"
  end

  property "every catalog event reconstructs its fixed message and rejects arbitrary metadata" do
    check all(
            name <- member_of(Map.keys(@catalog)),
            payload <- binary(min_length: 1, max_length: 1024)
          ) do
      canary = "private-canary-" <> payload

      event = %{
        level: :info,
        msg: {:string, payload},
        meta: %{
          event: name,
          token: canary,
          path: canary,
          user_id: canary,
          hostname: "canary." <> payload,
          reason: payload,
          vm_id: "not-a-uuid",
          audi_private: true,
          state: %{secret: canary}
        }
      }

      sanitized = Audi.Privacy.filter(event, nil)
      canary = "private-canary-" <> payload
      assert sanitized.msg == {:string, Map.fetch!(@catalog, name).message}
      assert sanitized.meta == %{event: name, domain: [:audi]}
      refute inspect(sanitized) =~ canary
    end
  end

  test "catalog events keep only uuid-validated identifiers" do
    for {name, spec} <- @catalog do
      event = %{
        level: :info,
        msg: {:string, "private-canary"},
        meta: %{
          event: name,
          host_id: @uuid,
          vm_id: "vm.example.internal",
          placement_id: 4,
          session_id: "not-a-uuid",
          execution_epoch: 7,
          generation: 2,
          reason: :closed_atom
        }
      }

      sanitized = Audi.Privacy.filter(event, nil)

      expected =
        %{host_id: @uuid, execution_epoch: 7, generation: 2}
        |> Map.take(Keyword.keys(spec.metadata))
        |> Map.merge(%{event: name, domain: [:audi]})

      assert sanitized.meta == expected
      refute inspect(sanitized) =~ "vm.example.internal"
    end
  end

  test "fleet and control failures retain only closed diagnostic reasons" do
    for {name, approved} <- [
          {"audi.fleet_certificate_sync_failed", :fetch},
          {"audi.control_exchange_failed", :unauthorized}
        ] do
      event = %{
        level: :warning,
        msg: {:string, "private-canary"},
        meta: %{event: name, host_id: @uuid, reason: approved, token: "private-canary"}
      }

      sanitized = Audi.Privacy.filter(event, nil)
      assert sanitized.meta.reason == approved
      assert sanitized.meta.host_id == @uuid
      refute inspect(sanitized) =~ "private-canary"

      rejected = Audi.Privacy.filter(put_in(event, [:meta, :reason], :private_canary), nil)
      refute Map.has_key?(rejected.meta, :reason)
    end
  end

  test "fleet readiness retains only a bounded generation" do
    event = %{
      level: :info,
      msg: {:string, "private-canary"},
      meta: %{event: "audi.fleet_certificate_ready", host_id: @uuid, generation: 7}
    }

    assert Audi.Privacy.filter(event, nil).meta.generation == 7

    assert Audi.Privacy.filter(put_in(event, [:meta, :generation], 0), nil).meta.generation == 0

    for invalid <- [-1, "private-canary", 2_147_483_648] do
      rejected = Audi.Privacy.filter(put_in(event, [:meta, :generation], invalid), nil)
      refute Map.has_key?(rejected.meta, :generation)
      refute inspect(rejected) =~ "private-canary"
    end
  end

  test "non-catalog events stay redacted" do
    messages = [
      {{:report, %{label: {:gen_server, :terminate}, state: "private-canary"}},
       "Audi process failed"},
      {{~c"~p", ["private-canary"]}, "Audi runtime_report (payload redacted)"},
      {{:string, "private-canary"}, "Audi private_diagnostic (payload redacted)"}
    ]

    for {message, expected_text} <- messages do
      event = %{
        level: :error,
        msg: message,
        meta: %{
          event: "audi.uncatalogued",
          audi_private: true,
          formatter: "private-canary",
          token: "private-canary",
          host_id: @uuid
        }
      }

      sanitized = Audi.Privacy.filter(event, nil)
      assert {:string, text} = sanitized.msg
      assert text == expected_text
      assert sanitized.meta.event == "audi." <> sanitized.meta.report_category
      refute inspect(sanitized) =~ "private-canary"
      refute Map.has_key?(sanitized.meta, :host_id)
    end
  end

  test "runtime reports retain only a closed component atom" do
    event = %{
      level: :error,
      msg: {:report, %{label: {:gen_server, :terminate}, state: "private-canary"}},
      meta: %{
        audi_private: true,
        audi_component: :https,
        audi_phase: :http_data,
        dependency_component: :private_canary,
        token: "private-canary"
      }
    }

    sanitized = Audi.Privacy.filter(event, nil)
    assert sanitized.msg == {:string, "Audi process failed"}
    assert sanitized.meta.component == :https
    assert sanitized.meta.phase == :http_data
    assert sanitized.meta.event == "audi.process_crash"
    refute inspect(sanitized) =~ "private-canary"

    assert %{meta: metadata} =
             Audi.Privacy.filter(
               event
               |> put_in([:meta, :audi_component], :private_canary)
               |> put_in([:meta, :audi_phase], :private_canary),
               nil
             )

    refute Map.has_key?(metadata, :component)
    refute Map.has_key?(metadata, :phase)
  end

  test "supervisor progress reports are dropped; failures are still reported" do
    progress = %{
      level: :info,
      msg: {:report, %{label: {:supervisor, :progress}, report: [started: [pid: self()]]}},
      meta: %{}
    }

    assert Audi.Privacy.filter(progress, nil) == :stop

    failure = %{progress | msg: {:report, %{label: {:supervisor, :child_terminated}, report: []}}}
    assert %{meta: %{event: "audi.supervisor_report"}} = Audi.Privacy.filter(failure, nil)
  end

  test "OTP reports and private diagnostics never retain payloads or formatter callbacks" do
    for message <- [
          {:report, %{label: {:gen_server, :terminate}, state: "private-canary"}},
          {~c"~p", ["private-canary"]},
          {:string, "private-canary"}
        ] do
      event = %{
        level: :error,
        msg: message,
        meta: %{audi_private: true, formatter: "private-canary", token: "private-canary"}
      }

      refute inspect(Audi.Privacy.filter(event, nil)) =~ "private-canary"
    end
  end

  test "secrets and hostnames never survive reviewed reconstruction" do
    event = %{
      level: :warning,
      msg: {:string, "Bearer audi_service_secret-canary"},
      meta: %{
        event: "audi.web_denied",
        reason: :unauthorized,
        authorization: "Bearer audi_service_secret-canary",
        host: "evil.example.internal",
        cookie: "__Host-audi_session=secret-canary"
      }
    }

    sanitized = Audi.Privacy.filter(event, nil)
    assert sanitized.msg == {:string, "Web request denied"}
    assert sanitized.meta == %{event: "audi.web_denied", domain: [:audi], reason: :unauthorized}
    refute inspect(sanitized) =~ "secret-canary"
    refute inspect(sanitized) =~ "evil.example.internal"
    rejected = Audi.Privacy.filter(put_in(event, [:meta, :reason], :private_canary), nil)
    refute Map.has_key?(rejected.meta, :reason)
  end
end
