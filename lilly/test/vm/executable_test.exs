defmodule Lilly.VM.ExecutableTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Executable
  @moduletag :tmp_dir

  defp elf(headers, type \\ 3) do
    count = length(headers)

    <<0x7F, "ELF", 2, 1, 1, 0::72, type::little-16, 62::little-16, 1::little-32, 0::little-64,
      64::little-64, 0::little-64, 0::little-32, 64::little-16, 56::little-16, count::little-16,
      0::48>> <>
      IO.iodata_to_binary(for kind <- headers, do: <<kind::little-32, 0::416>>)
  end

  test "static ELF and PIE are accepted; dynamic interpreter and malformed headers fail", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "vmm")

    for type <- [2, 3] do
      File.write!(path, elf([1, 2], type))
      File.chmod!(path, 0o555)
      assert Executable.static_x86_64?(path)
      File.chmod!(path, 0o755)
    end

    for bytes <- [elf([1, 3]), elf([2]), elf([1], 1), "#!/bin/sh\n", binary_part(elf([1]), 0, 70)] do
      File.write!(path, bytes)
      refute Executable.static_x86_64?(path)
    end

    File.write!(path, elf([1]))
    File.chmod!(path, 0o777)
    refute Executable.static_x86_64?(path)
  end

  @tag :hegel

  test "an ELF interpreter is always rejected regardless of header order", %{tmp_dir: dir} do
    path = Path.join(dir, "vmm")

    Hegel.check(
      fn ->
        headers = draw("headers", list_of(integer(0..16), max_length: 16))
        File.write!(path, elf([1 | headers] ++ [3]))
        File.chmod!(path, 0o755)
        refute Executable.static_x86_64?(path)
      end,
      []
    )
  end
end
