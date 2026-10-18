defmodule Marshall.Agents.MaintenanceTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Agents.{Executor, ExecutorRPC, ExecutorSession, ToolMaintenance}
  alias Marshall.Compute.Ledger
  @moduletag capture_log: true

  @type context :: %{
          binding: %{String.t() => String.t() | pos_integer()},
          token: String.t(),
          generation: String.t(),
          vm_id: String.t()
        }
  @type command :: :claim | :start | :complete | :replace | :stale
  @type model :: %{
          phase: nil | :claimed | :started | :completed,
          attempt: String.t() | nil,
          executor: Executor.t(),
          old: {Executor.t(), String.t() | nil} | nil
        }

  # @cc [owner:ghuntley,label:verification] maintenance-durable-history-scope
  # Generated histories MUST compare current-attempt and executor replacement
  # outcomes against a separate model. Each case MUST own its SQL sandbox and
  # temporary release. This verifies BEAM/database authority, not native guest
  # installation, activation, transport or physical VM isolation.
  @tag :hegel_case_sandbox
  @tag timeout: 300_000
  property "maintenance needs no conversation and stale executors cannot finish replacement attempts" do
    Marshall.DataCase.isolate_property_case()
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["github-tools-v1"])

    commands =
      draw(
        "commands",
        list_of(one_of(Enum.map([:claim, :start, :complete, :replace, :stale], &constant/1)),
          min_length: 5,
          max_length: 20
        )
      )

    initial = %{phase: nil, attempt: nil, executor: executor, old: nil}
    Enum.reduce(commands, initial, &step(&1, &2, c))
  end

  test "missing capability never claims a tool install" do
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding)
    assert {:error, :executor_upgrade_required} = claim(c, executor)
    assert Ledger.read!(ToolMaintenance, vm_id: c.vm_id) == []
  end

  test "release replacement fences a staged old generation before activation" do
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["github-tools-v1"])
    {:ok, %{maintenance: operation}} = claim(c, executor)
    assert {:ok, %{status: :started}} = transition(c, executor, operation.id, "started", %{})
    {_path, new_generation} = release_fixture("new-generation")
    assert new_generation != c.generation
    assert {:error, :stale_fence} = transition(c, executor, operation.id, "started", %{})
    assert {:ok, %{maintenance: replacement}} = claim(c, executor)
    assert replacement.generation == new_generation
    assert replacement.id != operation.id
    assert {:error, :stale_fence} = transition(c, executor, operation.id, "completed", receipt(c))
  end

  test "artifact selectors require the current VM and installation attempt" do
    c = fixture()
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["github-tools-v1"])
    {:ok, %{maintenance: operation}} = claim(c, executor)
    file = hd(operation.files)

    input =
      lease(c, executor)
      |> Map.merge(%{"maintenance_id" => operation.id, "digest" => file.sha256})

    assert {:ok, %{sha256: digest, generation: generation}} =
             ExecutorRPC.request(c.token, "maintenance_artifact", input)

    assert digest == file.sha256 and generation == c.generation

    assert {:error, :stale_fence} =
             ExecutorRPC.request(
               c.token,
               "maintenance_artifact",
               Map.put(input, "maintenance_id", Ash.UUID.generate())
             )

    assert {:error, :unauthorized} =
             ExecutorRPC.request(
               c.token,
               "maintenance_artifact",
               Map.put(input, "digest", String.duplicate("0", 64))
             )
  end

  @spec step(command(), model(), context()) :: model()
  defp step(:claim, model, c) do
    result = claim(c, model.executor)

    case model.phase do
      phase when phase in [:started, :completed] ->
        assert result == {:ok, %{maintenance: nil}}
        model

      _ ->
        assert {:ok, %{maintenance: operation}} = result
        assert operation.generation == c.generation
        assert Enum.sort(Enum.map(operation.files, & &1.name)) == ~w(gh git-lfs github.gitconfig)
        if model.attempt, do: assert(operation.id == model.attempt)
        %{model | phase: :claimed, attempt: operation.id}
    end
  end

  defp step(:start, %{attempt: nil} = model, _c), do: model

  defp step(:start, model, c) do
    result = transition(c, model.executor, model.attempt, "started", %{})

    if model.phase in [:claimed, :started] do
      assert {:ok, %{status: :started}} = result
      %{model | phase: :started}
    else
      assert {:error, :invalid_transition} = result
      model
    end
  end

  defp step(:complete, %{attempt: nil} = model, _c), do: model

  defp step(:complete, model, c) do
    result = transition(c, model.executor, model.attempt, "completed", receipt(c))

    if model.phase in [:started, :completed] do
      assert {:ok, %{status: :completed}} = result
      %{model | phase: :completed}
    else
      assert {:error, :invalid_transition} = result
      model
    end
  end

  defp step(:replace, model, c) do
    assert {:ok, replacement} = ExecutorSession.register(c.binding, nil, ["github-tools-v1"])
    assert replacement.fence_epoch > model.executor.fence_epoch

    %{
      model
      | executor: replacement,
        old: {model.executor, model.attempt},
        phase: nil,
        attempt: nil
    }
  end

  defp step(:stale, %{old: nil} = model, _c), do: model

  defp step(:stale, %{old: {old, attempt}} = model, c) do
    before = Ledger.read!(ToolMaintenance, vm_id: c.vm_id)

    assert {:error, :stale_fence} =
             transition(c, old, attempt || Ash.UUID.generate(), "completed", receipt(c))

    assert Ledger.read!(ToolMaintenance, vm_id: c.vm_id) == before
    model
  end

  @spec fixture() :: context()
  defp fixture do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {_path, generation} = release_fixture("initial")
    {:ok, issued} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)

    %{
      vm_id: fixture.vm.id,
      generation: generation,
      token: issued.id <> "." <> issued.secret,
      binding: %{
        "host_id" => fixture.vm.host_id,
        "vm_id" => fixture.vm.id,
        "placement_id" => fixture.vm.current_placement_id,
        "execution_epoch" => fixture.vm.execution_epoch
      }
    }
  end

  @spec release_fixture(String.t()) :: {String.t(), String.t()}
  defp release_fixture(suffix) do
    root = Path.join(System.tmp_dir!(), "overalls-github-tools-" <> Ash.UUID.generate())
    File.mkdir_p!(Path.join(root, "linux-amd64"))
    originals = Application.fetch_env(:marshall, :github_tools_manifest_file)

    cleanup = fn ->
      case originals do
        {:ok, value} -> Application.put_env(:marshall, :github_tools_manifest_file, value)
        :error -> Application.delete_env(:marshall, :github_tools_manifest_file)
      end

      File.rm_rf!(root)
    end

    if Hegel.in_property_case?(), do: Hegel.on_cleanup(cleanup), else: on_exit(cleanup)

    files =
      Enum.map(~w(gh git-lfs github.gitconfig), fn name ->
        contents = name <> suffix
        File.write!(Path.join([root, "linux-amd64", name]), contents)

        %{
          "name" => name,
          "path" => "linux-amd64/" <> name,
          "sha256" => hash(contents),
          "bytes" => byte_size(contents)
        }
      end)

    body = %{
      "version" => 1,
      "configuration_sha256" => hash("github.gitconfig" <> suffix),
      "platforms" => %{"linux-amd64" => %{"files" => files}}
    }

    generation = OverallsProtocol.GitHubTools.generation(body)
    path = Path.join(root, "manifest.json")
    File.write!(path, JSON.encode!(Map.put(body, "generation", generation)))
    Application.put_env(:marshall, :github_tools_manifest_file, path)
    {path, generation}
  end

  @spec hash(String.t()) :: String.t()
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @spec lease(context(), Executor.t()) :: map()
  defp lease(c, executor),
    do: %{
      "binding" => c.binding,
      "executor_id" => executor.id,
      "fence_epoch" => executor.fence_epoch
    }

  @spec claim(context(), Executor.t()) :: {:ok, map()} | {:error, term()}
  defp claim(c, executor),
    do: ExecutorRPC.request(c.token, "maintenance_claim", lease(c, executor))

  @spec receipt(context()) :: %{String.t() => String.t()}
  defp receipt(c), do: %{"generation" => c.generation, "outcome" => "installed"}

  @spec transition(context(), Executor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defp transition(c, executor, id, status, result) do
    ExecutorRPC.request(
      c.token,
      "maintenance_transition",
      lease(c, executor)
      |> Map.merge(%{"maintenance_id" => id, "status" => status, "result" => result})
    )
  end
end
