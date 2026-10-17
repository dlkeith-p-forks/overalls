defmodule Ziggy.PrivacyTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  require Ziggy.Events

  @catalog Ziggy.Events.__catalog__()
  @request "11111111-1111-4111-8111-111111111111"
  @host "22222222-2222-4222-8222-222222222222"
  @credential "sk-ziggy-marker-secret-0123456789abcdef"

  test "catalog events survive with fixed text and validated identifiers" do
    for {name, spec} <- @catalog do
      event = %{
        level: :info,
        msg: {:string, @credential},
        meta: %{
          event: name,
          request_id: @request,
          host_id: @host,
          vm_id: "not-a-uuid",
          reason: :closed,
          model: "marker-model-name",
          credential: @credential
        }
      }

      clean = Ziggy.Privacy.filter(event, nil)
      assert clean.msg == {:string, Map.fetch!(@catalog, name).message}
      assert clean.meta.event == name

      for {key, value} <- [request_id: @request, host_id: @host, reason: :closed] do
        if Keyword.has_key?(spec.metadata, key),
          do: assert(Map.get(clean.meta, key) == value),
          else: refute(Map.has_key?(clean.meta, key))
      end

      refute Map.has_key?(clean.meta, :vm_id)
      refute Map.has_key?(clean.meta, :model)
      refute Map.has_key?(clean.meta, :credential)
      refute inspect(clean) =~ @credential
      refute inspect(clean) =~ "marker-model-name"
    end
  end

  test "catalog events drop non-uuid identifiers and non-atom reasons" do
    event = %{
      level: :warning,
      msg: {:string, "marker"},
      meta: %{
        event: "ziggy.lease_revoked",
        request_id: "invalid",
        host_id: [:not, :a, :uuid],
        vm_id: 4,
        reason: "provider string reason marker"
      }
    }

    clean = Ziggy.Privacy.filter(event, nil)
    assert clean.msg == {:string, "Admission lease revoked"}
    assert clean.meta.event == "ziggy.lease_revoked"
    refute Map.has_key?(clean.meta, :request_id)
    refute Map.has_key?(clean.meta, :host_id)
    refute Map.has_key?(clean.meta, :vm_id)
    refute Map.has_key?(clean.meta, :reason)
    refute inspect(clean) =~ "marker"
  end

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
          event: "ziggy.uncatalogued",
          api_key: "synthetic-secret",
          request_id: "invalid",
          report_cb: fn _ -> "synthetic-secret" end
        }
      }

      clean = Ziggy.Privacy.filter(event, nil)
      assert clean.msg == {:string, "Ziggy runtime diagnostic (payload redacted)"}
      assert clean.meta.event == "ziggy.runtime"
      refute inspect(clean) =~ "synthetic-secret"
      refute Map.has_key?(clean.meta, :report_cb)
      refute Map.has_key?(clean.meta, :request_id)
    end
  end

  test "provider credential markers never survive any filtered output" do
    for name <- ["ziggy.runtime", "ziggy.inference_admitted"] do
      event = %{
        level: :info,
        msg: {:report, %{body: "Bearer " <> @credential, key: @credential}},
        meta: %{
          event: name,
          api_key: @credential,
          authorization: "Bearer " <> @credential,
          prompt: "marker-prompt-content",
          response: "marker-completion-content"
        }
      }

      clean = Ziggy.Privacy.filter(event, nil)
      refute inspect(clean) =~ @credential
      refute inspect(clean) =~ "marker-prompt-content"
      refute inspect(clean) =~ "marker-completion-content"
    end
  end

  test "emitted catalog events carry fixed text through the installed filter" do
    log =
      capture_log([metadata: [:request_id, :host_id, :api_key, :model]], fn ->
        :ok = Ziggy.Privacy.install()
        Logger.metadata(api_key: @credential, model: "marker-model-name")
        Ziggy.Events.emit("ziggy.inference_admitted", request_id: @request, host_id: @host)
      end)

    assert log =~ "Inference admitted"
    assert log =~ @request
    refute log =~ @credential
    refute log =~ "marker-model-name"
  end
end
