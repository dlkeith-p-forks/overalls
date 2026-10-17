defmodule Lilly.VM.BootLogTest do
  use ExUnit.Case, async: true

  @prefix ~r/\[\+\d+\.\d{3}\] /

  test "writer bounds the line-stamped bytes and otherwise keeps their binary representation" do
    path = Path.join(System.tmp_dir!(), "lilly-boot-log-#{System.unique_integer([:positive])}")
    input = path <> ".input"
    payload = :binary.list_to_bin(Enum.to_list(0..255))
    source = :binary.copy(payload, 5000)
    File.write!(input, source)

    {"", 0} =
      System.cmd("lilly-boot-log", [
        path,
        System.find_executable("cat"),
        input
      ])

    assert {:ok, bytes} = File.read(path)
    assert byte_size(bytes) == 1_048_576
    # Every line holding a non-CR/LF byte starts with one host offset prefix
    # (boot-log-line-timestamps); removing them yields an exact source prefix.
    assert String.starts_with?(bytes, "[+")
    stripped = Regex.replace(~r/(\A|[\r\n])\[\+\d+\.\d{3}\] /, bytes, "\\1")
    assert stripped == binary_part(source, 0, byte_size(stripped))
    starts = length(Regex.scan(~r/(?:\A|[\r\n])[^\r\n]/, stripped))
    assert length(Regex.scan(@prefix, bytes)) == starts
    File.rm!(path)
    File.rm!(input)
  end
end
