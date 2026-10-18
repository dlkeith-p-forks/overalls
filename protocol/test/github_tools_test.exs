defmodule OverallsProtocol.GitHubToolsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.GitHubTools

  @type manifest :: %{String.t() => GitHubTools.json()}

  @spec manifest() :: manifest()
  defp manifest do
    files =
      Enum.map(~w(gh git-lfs github.gitconfig), fn name ->
        %{
          "name" => name,
          "path" => "linux-amd64/" <> name,
          "sha256" => String.duplicate("a", 64),
          "bytes" => 10
        }
      end)

    body = %{
      "version" => 1,
      "configuration_sha256" => String.duplicate("a", 64),
      "platforms" => %{"linux-amd64" => %{"files" => files}}
    }

    Map.put(body, "generation", GitHubTools.generation(body))
  end

  test "canonical hashing has an independently fixed sorted-key JSON vector" do
    assert GitHubTools.generation(%{"z" => [1, "a"], "a" => %{"b" => 2}}) ==
             "9bce931c1891aeb81f58e1ba0a8f8eda41f284909e15510fa941aa8dba3dccb7"
  end

  test "closed release decodes metadata but carries no activation authority" do
    assert {:ok, release} = GitHubTools.decode(manifest())
    assert length(release.platforms["linux-amd64"]) == 3
    refute Map.has_key?(release, :vm_id)
    refute Map.has_key?(release, :executor_id)

    for version <- [-1, 0, 2, "1", nil] do
      assert {:error, :invalid_github_tools} =
               GitHubTools.decode(Map.put(manifest(), "version", version))
    end
  end

  @tag :hegel
  test "unknown fields fail even with a recomputed valid content hash" do
    Hegel.check(fn ->
      key = "extra_" <> draw("field", string(:alphanumeric, min_length: 1, max_length: 32))
      body = manifest() |> Map.delete("generation") |> Map.put(key, "bounded")
      wire = Map.put(body, "generation", GitHubTools.generation(body))
      assert {:error, :invalid_github_tools} = GitHubTools.decode(wire)
    end)
  end

  @tag :hegel
  test "guest-selected paths and duplicate tool names never enter the release inventory" do
    Hegel.check(fn ->
      bad_path =
        draw(
          "path",
          one_of([
            constant("../gh"),
            constant("/etc/passwd"),
            constant("linux-amd64/../gh"),
            constant("https://example.test/gh"),
            constant("windows-amd64/gh.exe")
          ])
        )

      file_index = draw("file", integer(0..2))
      body = Map.delete(manifest(), "generation")
      files = get_in(body, ["platforms", "linux-amd64", "files"])
      files = List.update_at(files, file_index, &Map.put(&1, "path", bad_path))
      body = put_in(body, ["platforms", "linux-amd64", "files"], files)
      wire = Map.put(body, "generation", GitHubTools.generation(body))
      assert {:error, :invalid_github_tools} = GitHubTools.decode(wire)

      duplicate = List.duplicate(hd(files), 3)
      body = put_in(body, ["platforms", "linux-amd64", "files"], duplicate)
      wire = Map.put(body, "generation", GitHubTools.generation(body))
      assert {:error, :invalid_github_tools} = GitHubTools.decode(wire)
    end)
  end
end
