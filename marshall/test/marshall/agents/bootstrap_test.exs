defmodule Marshall.Agents.BootstrapTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Agents.{Executor, ExecutorRPC, ExecutorSession, ToolBootstrap}
  alias Marshall.Compute.Ledger
  alias OverallsProtocol.GitHubTools
  @moduletag capture_log: true
  @type context :: %{binding: map(), token: String.t(), vm_id: String.t()}
  @type model :: %{
          executor: Executor.t(),
          phase: nil | :claimed | :started,
          attempt: String.t() | nil,
          old: Executor.t() | nil
        }
  @type operation :: :claim | :start | :replace | :stale

  # @cc [owner:ghuntley,label:verification] bootstrap-no-conversation-history
  # Generated lease histories MUST exercise the actual host-authenticated wire
  # boundary without creating any user turn. Replacement executors and stale
  # receipts MUST be compared against an independent current-attempt model.
  # This is BEAM/database authority evidence, not guest or native execution.
  @tag :hegel_case_sandbox
  @tag timeout: 300_000
  property "retained executor bootstrap survives replacement and refuses stale receipts without turns" do
    Marshall.DataCase.isolate_property_case()
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding)

    operations =
      draw(
        "operations",
        list_of(one_of(Enum.map([:claim, :start, :replace, :stale], &constant/1)),
          min_length: 5,
          max_length: 20
        )
      )

    Enum.reduce(
      operations,
      %{executor: executor, phase: nil, attempt: nil, old: nil},
      &step(&1, &2, c)
    )

    assert Ledger.read!(Marshall.Agents.Turn, []) == []
  end

  test "fixed script and artifacts are bound to the current started attempt" do
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding)
    assert {:ok, %{command: command}} = rpc(c, executor, "claim")
    assert command.tool == :exec_command
    assert command.call_id == "executor-bootstrap"
    assert command.arguments["cmd"] =~ "__github-tools-bootstrap"
    assert command.arguments["cmd"] =~ "--proxy" or command.arguments["cmd"] =~ "ProxyHandler({})"
    assert {:ok, %{command: ^command}} = rpc(c, executor, "claim")
    [row] = Ledger.read!(ToolBootstrap, vm_id: c.vm_id)
    selector = %{"bootstrap_id" => row.attempt_id, "digest" => row.artifact_sha256}
    assert {:error, :unauthorized} = rpc(c, executor, "bootstrap_artifact", selector)

    assert {:ok, %{status: :started}} =
             rpc(c, executor, "transition", %{
               "command_id" => row.attempt_id,
               "status" => "started",
               "result" => %{}
             })

    assert {:ok, %{sha256: digest, bytes: size}} =
             rpc(c, executor, "bootstrap_artifact", selector)

    assert digest == row.artifact_sha256 and size == row.artifact_bytes

    assert {:error, :unauthorized} =
             rpc(
               c,
               executor,
               "bootstrap_artifact",
               Map.put(selector, "digest", String.duplicate("0", 64))
             )

    assert {:ok, %{status: :failed}} =
             rpc(c, executor, "transition", %{
               "command_id" => row.attempt_id,
               "status" => "completed",
               "result" => %{}
             })

    assert Ledger.read!(Marshall.Agents.Turn, []) == []
  end

  @spec step(operation(), model(), context()) :: model()
  defp step(:claim, model, c) do
    assert {:ok, %{command: command}} = rpc(c, model.executor, "claim")

    if model.phase == :started do
      assert command == nil
      model
    else
      assert command.call_id == "executor-bootstrap"
      if model.attempt, do: assert(command.id == model.attempt)
      %{model | phase: :claimed, attempt: command.id}
    end
  end

  defp step(:start, %{attempt: nil} = model, _c), do: model

  defp step(:start, model, c) do
    assert {:ok, %{status: :started}} =
             rpc(c, model.executor, "transition", %{
               "command_id" => model.attempt,
               "status" => "started",
               "result" => %{}
             })

    %{model | phase: :started}
  end

  defp step(:replace, model, c) do
    assert {:ok, executor} = ExecutorSession.register(c.binding)
    %{model | executor: executor, old: model.executor, phase: nil, attempt: nil}
  end

  defp step(:stale, %{old: nil} = model, _c), do: model

  defp step(:stale, model, c) do
    before = Ledger.read!(ToolBootstrap, vm_id: c.vm_id)

    assert {:error, :stale_fence} =
             rpc(c, model.old, "transition", %{
               "command_id" => model.attempt || Ash.UUID.generate(),
               "status" => "started",
               "result" => %{}
             })

    assert Ledger.read!(ToolBootstrap, vm_id: c.vm_id) == before
    model
  end

  @spec rpc(context(), Executor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp rpc(c, executor, route, extra \\ %{}) do
    ExecutorRPC.request(
      c.token,
      route,
      Map.merge(
        %{
          "binding" => c.binding,
          "executor_id" => executor.id,
          "fence_epoch" => executor.fence_epoch
        },
        extra
      )
    )
  end

  @spec fixture() :: context()
  defp fixture do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    root = Path.join(System.tmp_dir!(), "overalls-bootstrap-" <> Ash.UUID.generate())
    File.mkdir_p!(root)
    keys = [:executor_bootstrap_manifest_file, :github_tools_manifest_file]
    originals = Map.new(keys, &{&1, Application.fetch_env(:marshall, &1)})

    cleanup = fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)

      File.rm_rf!(root)
    end

    if Hegel.in_property_case?(), do: Hegel.on_cleanup(cleanup), else: on_exit(cleanup)

    platforms =
      Map.new(~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64), fn platform ->
        relative =
          platform <> if(platform == "windows-amd64", do: "/executor.exe", else: "/executor")

        File.mkdir_p!(Path.dirname(Path.join(root, relative)))
        File.write!(Path.join(root, relative), platform)

        {platform,
         %{"path" => relative, "sha256" => hash(platform), "bytes" => byte_size(platform)}}
      end)

    manifest = Path.join(root, "manifest.json")
    File.write!(manifest, JSON.encode!(%{"version" => 1, "platforms" => platforms}))
    Application.put_env(:marshall, :executor_bootstrap_manifest_file, manifest)

    files =
      Enum.map(~w(gh git-lfs github.gitconfig), fn name ->
        File.write!(Path.join([root, "linux-amd64", name]), name)

        %{
          "name" => name,
          "path" => "linux-amd64/" <> name,
          "sha256" => hash(name),
          "bytes" => byte_size(name)
        }
      end)

    body = %{
      "version" => 1,
      "configuration_sha256" => hash("github.gitconfig"),
      "platforms" => %{"linux-amd64" => %{"files" => files}}
    }

    tools_manifest = Path.join(root, "tools.json")

    File.write!(
      tools_manifest,
      JSON.encode!(Map.put(body, "generation", GitHubTools.generation(body)))
    )

    Application.put_env(:marshall, :github_tools_manifest_file, tools_manifest)
    {:ok, issued} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)

    %{
      vm_id: fixture.vm.id,
      token: issued.id <> "." <> issued.secret,
      binding: %{
        "host_id" => fixture.vm.host_id,
        "vm_id" => fixture.vm.id,
        "placement_id" => fixture.vm.current_placement_id,
        "execution_epoch" => fixture.vm.execution_epoch
      }
    }
  end

  @spec hash(String.t()) :: String.t()
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
