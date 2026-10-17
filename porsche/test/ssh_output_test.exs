defmodule Porsche.SSH.OutputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
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

  property "JSON results round-trip arbitrary Unicode without raw terminal control sequences" do
    check all(text <- string(:utf8, max_length: 200)) do
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
