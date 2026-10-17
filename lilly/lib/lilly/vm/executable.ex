defmodule Lilly.VM.Executable do
  @moduledoc "Reject dynamic ELF executables before using the Firecracker jailer."
  import Bitwise
  # @cc [owner:ghuntley,label:security] jailer-elf-has-no-interpreter
  # static_x86_64?/1 MUST reject ELF files containing PT_INTERP, malformed or truncated program
  # headers, or unsupported architecture; successful validation requires an executable x86-64 ELF
  # with a load segment.
  @spec static_x86_64?(Path.t()) :: boolean()
  def static_x86_64?(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- band(mode, 0o111) != 0 and band(mode, 0o022) == 0,
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok,
              <<0x7F, "ELF", 2, 1, 1, _::binary-size(9), type::little-16, 62::little-16,
                1::little-32, _entry::little-64, offset::little-64, _sections::little-64,
                _flags::little-32, 64::little-16, 56::little-16, count::little-16, _::binary>>} <-
               :file.pread(file, 0, 64),
             true <- type in [2, 3] and count in 1..128,
             {:ok, headers} <- :file.pread(file, offset, count * 56),
             true <- byte_size(headers) == count * 56 do
          types = for <<kind::little-32, _::binary-size(52) <- headers>>, do: kind
          1 in types and 3 not in types
        else
          _ -> false
        end
      after
        File.close(file)
      end
    else
      _ -> false
    end
  end
end
