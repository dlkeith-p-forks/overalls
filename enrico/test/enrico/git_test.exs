defmodule Enrico.GitTest do
  use ExUnit.Case, async: true
  alias Enrico.Git

  test "Git labels and paths reject command and tree escapes" do
    assert Git.valid_source?("NixOS", "nixpkgs")
    refute Git.valid_source?("-evil", "repo")
    refute Git.valid_source?("owner", "repo.git")
    refute Git.valid_ref?("--upload-pack=evil")
    refute Git.valid_ref?("main..other")
    refute Git.valid_path?("../etc/passwd")
    refute Git.valid_path?("/etc/passwd")
    assert Git.valid_path?("src/main.ex")
  end

  test "read-only tree, blob and history operations use a bare mirror" do
    directory = Path.join(System.tmp_dir!(), "enrico-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    source = Path.join(directory, "source")
    mirror = Path.join(directory, "mirror.git")
    File.mkdir_p!(source)
    assert {_, 0} = System.cmd("git", ["init", "-q", source])
    File.write!(Path.join(source, "hello.txt"), "hello\n")
    assert {_, 0} = System.cmd("git", ["-C", source, "add", "hello.txt"])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               source,
               "-c",
               "user.email=test@example.test",
               "-c",
               "user.name=Test",
               "commit",
               "-qm",
               "initial"
             ])

    assert {_, 0} = System.cmd("git", ["clone", "-q", "--mirror", source, mirror])

    assert {:ok, tree} = Git.inspect(mirror, "tree", "HEAD", "")
    assert tree =~ "hello.txt"
    assert {:ok, "hello\n"} = Git.inspect(mirror, "blob", "HEAD", "hello.txt")
    assert {:ok, history} = Git.inspect(mirror, "history", "HEAD", "")
    assert history =~ "initial"
    assert {:ok, ""} = Git.search(mirror, "HEAD", "content", "absent-term")
    assert {:ok, "hello.txt"} = Git.search(mirror, "HEAD", "paths", "hello")
    assert {:error, :invalid_path} = Git.inspect(mirror, "blob", "HEAD", "../hello.txt")
  end
end
