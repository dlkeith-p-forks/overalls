defmodule Lilly.Host.ImageCopyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Command, Lock}
  @moduletag :tmp_dir
  @moduletag capture_log: true

  @tag :hegel
  test "native materialization preserves sparse bytes and independent destination writes", c do
    check all(
            prefix <- binary(min_length: 1, max_length: 1024),
            suffix <- binary(min_length: 1, max_length: 1024),
            hole <- integer(0..2_097_152),
            method <- member_of(["copy", "auto"]),
            test_cases: 16
          ) do
      directory = Path.join(c.tmp_dir, Lilly.UUID.generate())
      {:ok, lock} = Lock.acquire(directory)
      source = Path.join(directory, "source")
      destination = Path.join(directory, "destination")
      bytes = prefix <> :binary.copy(<<0>>, hole) <> suffix
      File.write!(source, bytes)
      File.chmod!(source, 0o444)

      try do
        assert {:ok, result} =
                 Command.run(
                   :image_copy,
                   [method, source, destination, to_string(byte_size(bytes))],
                   10_000
                 )

        assert result in ["copy\n", "offload\n", "reflink\n"]
        if method == "copy", do: assert(result == "copy\n")
        assert File.read!(destination) == bytes
        assert File.stat!(destination).links == 1
        File.write!(destination, "changed")
        assert File.read!(source) == bytes

        assert {:error, _} =
                 Command.run(:image_copy, [
                   method,
                   source,
                   destination,
                   to_string(byte_size(bytes))
                 ])

        assert File.read!(destination) == "changed"
      after
        Lock.release(lock)
      end
    end
  end

  test "size mismatch, mutable sources and symlink destinations are refused", c do
    File.chmod!(c.tmp_dir, 0o700)
    {:ok, lock} = Lock.acquire(c.tmp_dir)
    source = Path.join(c.tmp_dir, "source")
    target = Path.join(c.tmp_dir, "target")
    destination = Path.join(c.tmp_dir, "destination")
    File.write!(source, "hello")
    File.write!(target, "untouched")
    File.ln_s!(target, destination)

    try do
      assert {:error, _} = Command.run(:image_copy, ["auto", source, destination, "5"])
      File.chmod!(source, 0o444)
      assert {:error, _} = Command.run(:image_copy, ["copy", source, destination, "5"])
      File.rm!(destination)
      assert {:error, _} = Command.run(:image_copy, ["copy", source, destination, "6"])
      refute File.exists?(destination)
      assert File.read!(target) == "untouched"
    after
      Lock.release(lock)
    end
  end
end
