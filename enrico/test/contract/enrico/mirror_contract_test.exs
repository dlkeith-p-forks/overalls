defmodule EnricoMirrorContractTest do
  use Covenant.Case, component: "enrico.mirror"

  @tag obligation: "enrico.mirror.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Enrico.Application,
      Enrico.Config,
      Enrico.Events,
      Enrico.Git,
      Enrico.HTTP,
      Enrico.Health,
      Enrico.Manager,
      Enrico.Privacy,
      Enrico.RefreshSupervisor,
      Enrico.SLO
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "enrico.mirror.I2"
  test "git validators reject traversal and unsafe sources" do
    assert Enrico.Git.valid_source?("owner", "repo")
    refute Enrico.Git.valid_source?("../owner", "repo.git")
    refute Enrico.Git.valid_ref?("main..evil")
    refute Enrico.Git.valid_path?("/etc/passwd")
    refute Enrico.Git.valid_path?("a/../b")
  end

  @tag obligation: "enrico.mirror.I3"
  test "validations reject shell and git metacharacters" do
    refute Enrico.Git.valid_source?("owner;touch", "repo")
    refute Enrico.Git.valid_ref?("refs/heads/main~1")
    refute Enrico.Git.valid_path?("docs/secret\n")
    refute Enrico.Git.valid_ref?("refs/heads/main/")
    refute Enrico.Git.valid_path?(String.duplicate("a", 1025))
    refute Enrico.Git.valid_source?("", "repo")
  end
end
