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

  @tag obligation: "enrico.mirror.I4"
  test "manager rejects malformed refresh requests before admission" do
    config = %Enrico.Config{
      bind: {127, 0, 0, 1},
      port: 1,
      state_dir: System.tmp_dir!(),
      token: String.duplicate("t", 32),
      certificate: "/tmp/cert",
      key: "/tmp/key",
      status_socket: "/tmp/status.sock"
    }

    {:ok, state} = Enrico.Manager.init(config)

    assert {:reply, {:error, :invalid_request}, ^state} =
             Enrico.Manager.handle_call({:refresh, "bad", "bad", "owner", "repo"}, self(), state)

    assert {:reply, {:error, :invalid_request}, ^state} =
             Enrico.Manager.handle_call(
               {:refresh, "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222", "../owner", "repo"},
               self(),
               state
             )
  end

  @tag obligation: "enrico.mirror.I5"
  test "configuration rejects non-string bind without raising" do
    path =
      Path.join(System.tmp_dir!(), "enrico-invalid-#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(%{"bind" => 123}))
    on_exit(fn -> File.rm(path) end)
    assert {:error, :invalid_configuration} = Enrico.Config.load(path)
  end
end
