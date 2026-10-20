defmodule Marshall.Redaction.ScannerTest do
  use ExUnit.Case, async: true
  alias Marshall.Redaction.Scanner

  test "redacts supported text and is idempotent" do
    secret = "ghp_" <> String.duplicate("A", 24)
    first = Scanner.redact("before #{secret} after")
    second = Scanner.redact(first.value)

    assert first.value == "before [REDACTED:github-token] after"
    assert first.findings == [%{rule: "github-token", count: 1}]
    assert second.value == first.value
    assert second.findings == []
  end

  test "recursively redacts JSON text while preserving structure" do
    {value, findings} = Scanner.redact_json(%{"prompt" => "sk-" <> String.duplicate("b", 24), "n" => 3})

    assert value["prompt"] == "[REDACTED:openai-key]"
    assert value["n"] == 3
    assert findings == [%{rule: "openai-key", count: 1}]
  end

  test "attachments represented as non-text values are untouched" do
    value = %{"attachment" => %{"bytes" => <<0, 1, 2>>, "mime" => "image/png"}}
    assert {^value, []} = Scanner.redact_json(value)
  end
end
