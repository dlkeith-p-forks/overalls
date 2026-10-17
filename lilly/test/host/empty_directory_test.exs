defmodule Lilly.Host.EmptyDirectoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.EmptyDirectory

  setup do
    parent = Path.join(System.tmp_dir!(), "empty-directory-#{System.unique_integer([:positive])}")
    File.mkdir!(parent)
    on_exit(fn -> File.rm_rf!(parent) end)
    %{parent: parent, path: Path.join(parent, "vm")}
  end

  # Exercise real filesystem operations without requiring root; only ownership
  # observations are mapped to root for successful unprivileged fixtures.
  defp root_stat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, %{stat | uid: 0}}
      error -> error
    end
  end

  test "empty, absent and repeated removal sync their parent", %{parent: parent, path: path} do
    File.mkdir!(path)

    sync = fn actual ->
      assert actual == parent
      send(self(), :synced)
      :ok
    end

    for _ <- 1..3 do
      assert :ok = EmptyDirectory.remove(path, stat: &root_stat/1, sync: sync)
      assert {:error, :enoent} = File.lstat(path)
      assert_received :synced
    end
  end

  test "sync failure withholds success after removal and can be retried", %{path: path} do
    File.mkdir!(path)

    assert {:error, :sync_failed} =
             EmptyDirectory.remove(path,
               stat: &root_stat/1,
               sync: fn _ -> {:error, :sync_failed} end
             )

    assert {:error, :enoent} = File.lstat(path)
    assert :ok = EmptyDirectory.remove(path)
  end

  property "unexpected names and bytes survive refused cleanup", %{path: path} do
    check all(
            name <- string(:alphanumeric, min_length: 1, max_length: 80),
            contents <- binary(max_length: 2048)
          ) do
      File.mkdir!(path)
      file = Path.join(path, ".unexpected-" <> name)
      File.write!(file, contents)
      assert {:error, reason} = EmptyDirectory.remove(path, stat: &root_stat/1)
      assert reason in [:enotempty, :eexist]
      assert File.read!(file) == contents
      assert File.ls!(path) == [Path.basename(file)]
      File.rm!(file)
      File.rmdir!(path)
    end
  end

  test "symlinks, files and nested directories survive", %{parent: parent, path: path} do
    target = Path.join(parent, "target")
    File.mkdir!(target)
    File.ln_s!(target, path)
    assert {:error, :unsafe_cleanup_directory} = EmptyDirectory.remove(path, stat: &root_stat/1)
    assert {:ok, ^target} = File.read_link(path)
    File.rm!(path)
    File.write!(path, "preserved")
    assert {:error, :unsafe_cleanup_directory} = EmptyDirectory.remove(path, stat: &root_stat/1)
    assert File.read!(path) == "preserved"
    File.rm!(path)
    File.mkdir!(path)
    File.mkdir!(Path.join(path, "nested"))
    assert {:error, reason} = EmptyDirectory.remove(path, stat: &root_stat/1)
    assert reason in [:enotempty, :eexist]
    assert File.dir?(Path.join(path, "nested"))
  end

  test "foreign ownership and stat errors fail without syncing", %{path: path} do
    File.mkdir!(path)
    sync = fn _ -> flunk("must not sync after failed removal") end

    foreign = fn p ->
      {:ok, stat} = File.lstat(p)
      {:ok, %{stat | uid: 1234}}
    end

    assert {:error, :unsafe_cleanup_directory} =
             EmptyDirectory.remove(path, stat: foreign, sync: sync)

    assert {:error, :eacces} =
             EmptyDirectory.remove(path, stat: fn _ -> {:error, :eacces} end, sync: sync)

    assert File.dir?(path)
  end

  test "FIFO is rejected without unlinking", %{path: path} do
    {_, 0} = System.cmd("mkfifo", [path])
    assert {:error, :unsafe_cleanup_directory} = EmptyDirectory.remove(path, stat: &root_stat/1)
    assert {:ok, %File.Stat{type: :other}} = File.lstat(path)
  end

  test "rmdir errors remain errors", %{path: path} do
    File.write!(path, "preserved")
    stat = fn _ -> {:ok, %File.Stat{type: :directory, uid: 0}} end
    assert {:error, :enotdir} = EmptyDirectory.remove(path, stat: stat)
    assert File.read!(path) == "preserved"
  end
end
