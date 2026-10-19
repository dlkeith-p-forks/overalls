defmodule Porsche.SSH.OutputTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Porsche.SSH.Output

  test "exec context preserves pending JSON but gives human users a usable next step" do
    response = %{
      "version" => 1,
      "status" => "approval_required",
      "fingerprint" => "SHA256:fixture",
      "approval_url" => "https://control.test/ssh/approve/fixture"
    }

    context = {:exec, "https://control.test"}
    assert Output.render(response, true, context) == Output.render(response, true)
    assert Output.render(response, false, context) =~ "ssh control.test"
    refute Output.render(response, false, context) =~ "/ssh/approve/"
    assert Output.render(response, false, :interactive) =~ response["approval_url"]
  end

  test "human errors translate prose while JSON retains the exact error contract" do
    response = %{"version" => 1, "status" => "error", "error" => "invalid_command"}
    assert Output.render(response, false) =~ "Invalid command."
    assert JSON.decode!(Output.render(response, true)) == response
  end

  # @cc [owner:ghuntley,label:verification;protocol] porsche-human-locale-wire-separation
  # Japanese and Arabic human labels and pin guidance MUST be translated while
  # JSON bytes, unknown outer values and nested user/protocol data stay unchanged.
  test "Japanese and Arabic translate pin guidance and human receipt labels without changing JSON" do
    response = %{
      "version" => 1,
      "status" => "succeeded",
      "request_id" => "request-fixture",
      "operation_id" => "operation-fixture",
      "result" => %{"status" => "failed", "name" => "Accepted", "role" => "manager"},
      "unknown" => "succeeded"
    }

    Gettext.put_locale(Porsche.Gettext, "en")
    json = Output.render(response, true)

    for {locale, status_label, success_label, pin_text} <- [
          {"ja", "状態", "成功", "ピン"},
          {"ar", "الحالة", "نجح", "تثبيت"}
        ] do
      Gettext.put_locale(Porsche.Gettext, locale)
      human = Output.render(response, false)
      assert human =~ status_label <> ": " <> success_label
      assert human =~ "request-fixture"
      assert human =~ "operation-fixture"
      assert human =~ "unknown: succeeded"
      assert human =~ JSON.encode!(response["result"])
      assert Output.render(response, true) == json

      for reason <- ["machine_pinned", "machine_failed", "pin_limit"] do
        error = %{"version" => 1, "status" => "error", "error" => reason}
        text = Output.render(error, false)
        assert text =~ pin_text
        refute text =~ reason
        assert JSON.decode!(Output.render(error, true)) == error
      end
    end
  end

  test "unknown reason remains escaped as an identifier in localized fallback" do
    Gettext.put_locale(Porsche.Gettext, "ja")
    reason = "future_reason" <> "\e[2J"
    response = %{"version" => 1, "status" => "error", "error" => reason}
    human = Output.render(response, false)
    assert human =~ "future_reason"
    refute human =~ "\e"
    assert JSON.decode!(Output.render(response, true)) == response
  end

  property "JSON results round-trip arbitrary Unicode without raw terminal control sequences" do
    text = draw("text", string(:utf8, max_length: 200))
    response = %{"version" => 1, "status" => "succeeded", "result" => %{"value" => [text]}}
    encoded = Output.render(response, true)
    assert JSON.decode!(encoded) == response
    assert String.ends_with?(encoded, "\n")

    refute Regex.match?(
             ~r/[\x{0000}-\x{0009}\x{000b}-\x{001f}\x{007f}-\x{009f}\x{2028}\x{2029}]/u,
             encoded
           )

    assert length(String.split(encoded, "\n")) == 2
  end

  test "human results escape controls in top-level and nested fields" do
    malicious = "value\e[2J\r\n" <> <<0x9B::utf8, 0x2028::utf8>>

    response = %{
      "status" => "succeeded",
      "value" => malicious,
      "result" => %{"label" => malicious}
    }

    output = Output.render(response, false)
    refute output =~ "\e"
    refute output =~ "\r"
    refute output =~ <<0x9B::utf8>>
    refute output =~ <<0x2028::utf8>>
    assert output =~ "\\u009B"
    assert output =~ "\\n"
  end
end
