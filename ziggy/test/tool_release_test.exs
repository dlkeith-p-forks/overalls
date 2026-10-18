defmodule Ziggy.ToolReleaseTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.GitHubTools

  @spec digest(binary()) :: String.t()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec fixture() :: String.t()
  defp fixture do
    root = Path.join(System.tmp_dir!(), "ziggy-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "linux-amd64"))
    on_exit(fn -> File.rm_rf!(root) end)

    files =
      Enum.map(~w(gh git-lfs github.gitconfig), fn name ->
        bytes = "synthetic-" <> name
        path = "linux-amd64/" <> name
        File.write!(Path.join(root, path), bytes)
        %{"name" => name, "path" => path, "bytes" => byte_size(bytes), "sha256" => digest(bytes)}
      end)

    body = %{
      "version" => 1,
      "configuration_sha256" => digest("synthetic-github.gitconfig"),
      "platforms" => %{"linux-amd64" => %{"files" => files}}
    }

    manifest = Map.put(body, "generation", GitHubTools.generation(body))
    File.write!(Path.join(root, "manifest.json"), Jason.encode!(manifest))
    root
  end

  test "verified inventory contains only manifest-selected exact bytes" do
    root = fixture()
    assert {:ok, %{artifacts: artifacts}} = Ziggy.ToolRelease.load(root)
    assert map_size(artifacts) == 3

    Enum.each(artifacts, fn {sha, artifact} ->
      bytes = File.read!(artifact.path)
      assert digest(bytes) == sha
      assert byte_size(bytes) == artifact.size
    end)
  end

  test "same-sized corruption, missing files and manifest extensions fail closed" do
    for mutation <- [:corrupt, :missing, :extension] do
      root = fixture()

      case mutation do
        :corrupt ->
          File.write!(
            Path.join(root, "linux-amd64/gh"),
            "x" <> String.slice("synthetic-gh", 1..-1//1)
          )

        :missing ->
          File.rm!(Path.join(root, "linux-amd64/git-lfs"))

        :extension ->
          path = Path.join(root, "manifest.json")
          manifest = path |> File.read!() |> Jason.decode!() |> Map.put("extra", true)
          File.write!(path, Jason.encode!(manifest))
      end

      assert {:error, :invalid_configuration} = Ziggy.ToolRelease.load(root)
    end
  end

  test "absent release is optional; relative paths and nonpaths are denied" do
    assert {:ok, nil} = Ziggy.ToolRelease.load(nil)

    for root <- ["relative", "/tmp/../tmp", 1, %{}] do
      assert {:error, :invalid_configuration} = Ziggy.ToolRelease.load(root)
    end
  end
end
