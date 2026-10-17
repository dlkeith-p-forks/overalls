defmodule OverallsProtocol.SSHOnboardingTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.SSHOnboarding, as: Help

  property "terminal conversion is idempotent and preserves non-PTY bytes" do
    check all(bytes <- binary(max_length: 5000)) do
      assert Help.terminal_lines(bytes, false) == bytes
      pty = Help.terminal_lines(bytes, true)
      assert Help.terminal_lines(pty, true) == pty
      refute Regex.match?(~r/(?<!\r)\n/, pty)
      assert byte_size(pty) <= byte_size(bytes) * 2
    end
  end

  test "status schema is closed and versioned" do
    for status <- [:recognized, :unknown] do
      wire = %{"version" => 1, "result" => %{"status" => Atom.to_string(status)}}
      assert Help.decode_status(wire) == {:ok, status}
      assert {:error, _} = Help.decode_status(Map.put(wire, "account", "private"))
      assert {:error, _} = Help.decode_status(%{wire | "version" => 2})
    end
  end

  property "unrecognized status values cannot become valid statuses or atoms" do
    check all(value <- string(:utf8), value not in ["recognized", "unknown"]) do
      assert {:error, :invalid_message} =
               Help.decode_status(%{"version" => 1, "result" => %{"status" => value}})
    end
  end

  property "untrusted text is bounded and never emits terminal controls" do
    check all(value <- one_of([binary(max_length: 4096), string(:utf8, max_length: 1000)])) do
      rendered = Help.approval(value, value)
      assert byte_size(rendered) < 25_000
      assert String.valid?(rendered)

      refute Regex.match?(
               ~r/[\x{0000}-\x{0009}\x{000b}-\x{001f}\x{007f}-\x{009f}\x{2028}\x{2029}]/u,
               rendered
             )
    end
  end

  test "Unicode C1 and line separator controls are escaped explicitly" do
    for point <- Enum.to_list(0..31) ++ Enum.to_list(127..159) ++ [0x2028, 0x2029] do
      text = <<point::utf8>>
      refute Help.safe(text) =~ text
      assert Help.safe(text) =~ "\\u"
    end
  end

  test "public origins cannot inject commands or leak credentials" do
    assert Help.public_origin?("https://control.example.test")
    assert Help.public_origin?("https://control.example.test:8443")

    for origin <- [
          nil,
          "http://control.test",
          "https://user:secret@control.test",
          "https://control.test/path",
          "https://control.test?secret",
          "https://control.test#fragment",
          "https://-oProxyCommand=whoami",
          "https://control.test;id",
          "https://control.test\n",
          "https://control.test:99999"
        ] do
      refute Help.public_origin?(origin)
    end
  end

  test "wording distinguishes unknown, recognized, denied and unavailable" do
    for mode <- [:direct, :proxy] do
      unknown = Help.guidance(:unknown, "SHA256:fixture", "https://control.test", mode)
      assert unknown =~ "We don't recognize this SSH key"
      assert unknown =~ "ssh control.test"
      assert unknown =~ "without root@"
      refute unknown =~ "profile has no keys"

      for status <- [:recognized, :unavailable, :denied] do
        refute Help.guidance(status, "SHA256:fixture", nil, mode) =~ "don't recognize"
      end
    end
  end

  test "one-shot management guidance never turns an unsafe origin into a command" do
    for origin <- [nil, "https://user:secret@control.test", "https://control.test;id"] do
      text = Help.retry_interactively("SHA256:fixture", origin)
      assert text =~ "without a remote command"
      refute text =~ "secret"
      refute text =~ ";id"
    end
  end
end
