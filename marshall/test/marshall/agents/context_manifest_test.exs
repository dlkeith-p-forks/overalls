defmodule Marshall.Agents.ContextManifestTest do
  use ExUnit.Case, async: true
  alias Marshall.Agents.ContextManifest

  test "inventory pages retain source order and reject changed or discontinuous inventories" do
    first = source(0, "/workspace/AGENTS.md", "root")
    second = source(1, "/workspace/app/AGENTS.md", "child")
    cursor = %{"digest" => digest("inventory"), "offset" => 1}
    page_one = page([first], cursor)
    page_two = page([second])
    assert {:ok, manifest} = ContextManifest.inventory([page_one, page_two])
    assert Enum.map(manifest.entries, & &1.path) == [first["path"], second["path"]]
    assert manifest.next_cursor == nil

    assert {:error, :invalid_context_result} =
             ContextManifest.inventory([
               page_one,
               Map.put(page_two, "inventory_digest", digest("changed"))
             ])

    assert {:error, :invalid_context_result} =
             ContextManifest.inventory([page_one, page([Map.put(second, "position", 2)])])
  end

  test "complete files require contiguous reads, final EOF, exact byte size and whole-file digest" do
    bytes = String.duplicate("q", 4096) <> "last page"
    entry = parsed_source(source(0, "/workspace/AGENTS.md", bytes))
    first = chunk(entry, binary_part(bytes, 0, 4096), 0, false)
    last = chunk(entry, "last page", 4096, true)
    assert {:more, 0} = ContextManifest.file(entry, [])
    assert {:more, 4096} = ContextManifest.file(entry, [first])
    assert {:ok, ^bytes} = ContextManifest.file(entry, [first, last])

    assert {:error, :invalid_context_result} = ContextManifest.file(entry, [last])
    assert {:error, :invalid_context_result} = ContextManifest.file(entry, [first, first])

    assert {:error, :context_changed} =
             ContextManifest.file(entry, [
               first,
               Map.put(last, "data_base64", Base.encode64("wrong end"))
             ])

    assert {:error, :invalid_context_result} = ContextManifest.file(entry, [first, last, last])
  end

  test "empty overrides are retained and consume no project budget" do
    empty = parsed_source(source(0, "/workspace/AGENTS.override.md", ""))
    assert {:ok, ""} = ContextManifest.file(empty, [chunk(empty, "", 0, true)])
    applied = ContextManifest.instructions([%{entry: empty, content: ""}])
    assert applied.instructions == []
    assert [%{"applied_bytes" => 0, "truncated" => false}] = applied.sources
  end

  test "project budget is shared root first while creator instructions remain outside it" do
    root = String.duplicate("r", 32_760)
    child = "abcdefghijk"
    creator = "creator guidance"

    files = [
      file(2, "/workspace/app/AGENTS.md", child),
      file(0, "/home/u200000/.overalls/AGENTS.md", creator, "creator"),
      file(1, "/workspace/AGENTS.md", root)
    ]

    applied = ContextManifest.instructions(files)
    assert Enum.map(applied.sources, & &1["applied_bytes"]) == [16, 32_760, 8]
    assert List.last(applied.instructions) =~ "abcdefgh"
    refute List.last(applied.instructions) =~ "abcdefghi"
    assert applied.warnings == ["project_instructions_truncated"]
  end

  test "UTF-8 truncation is visible and produces valid model text" do
    bytes = String.duplicate("a", 32_767) <> "é"
    applied = ContextManifest.instructions([file(0, "/workspace/AGENTS.md", bytes)])
    assert String.valid?(hd(applied.instructions))
    assert String.ends_with?(hd(applied.instructions), "�")
    assert applied.warnings == ["project_instructions_truncated"]
  end

  test "platform paths and metadata linkage are validated without host filesystem reads" do
    windows = source(0, "C:\\workspace\\AGENTS.md", "guide")
    assert {:ok, _} = ContextManifest.inventory([page([windows])])
    relative = Map.put(windows, "path", "workspace/AGENTS.md")
    assert {:error, :invalid_context_result} = ContextManifest.inventory([page([relative])])

    metadata =
      windows
      |> Map.put("kind", "skill_metadata")
      |> Map.put("skill_path", "C:\\workspace\\skills\\SKILL.md")

    assert {:ok, _} = ContextManifest.inventory([page([metadata])])

    assert {:error, :invalid_context_result} =
             ContextManifest.inventory([page([Map.delete(metadata, "skill_path")])])
  end

  test "forged bytes, oversized chunks and unsafe warning values are rejected" do
    entry = parsed_source(source(0, "/workspace/AGENTS.md", "guide"))

    assert {:error, :context_changed} =
             ContextManifest.file(entry, [
               chunk(entry, "guide", 0, true) |> Map.put("digest", digest("forged"))
             ])

    assert {:error, :invalid_context_result} =
             ContextManifest.file(entry, [
               %{"version" => 1, "data_base64" => String.duplicate("a", 6000)}
             ])

    assert {:error, :invalid_context_result} =
             ContextManifest.inventory([
               page([]) |> Map.put("warnings", ["untrusted file payload"])
             ])
  end

  @spec source(non_neg_integer(), String.t(), binary(), String.t()) :: map()
  defp source(position, path, content, scope \\ "project"),
    do: %{
      "position" => position,
      "kind" => "instruction",
      "path" => path,
      "digest" => digest(content),
      "bytes" => byte_size(content),
      "scope" => scope
    }

  @spec page([map()], map() | nil) :: map()
  defp page(entries, cursor \\ nil),
    do: %{
      "version" => 1,
      "working_directory" => "/workspace/app",
      "creator_home" => "/home/u200000",
      "project_root" => "/workspace",
      "inventory_digest" => digest("inventory"),
      "entries" => entries,
      "next_cursor" => cursor,
      "warnings" => []
    }

  @spec parsed_source(map()) :: ContextManifest.entry()
  defp parsed_source(source) do
    {:ok, %{entries: [entry]}} =
      ContextManifest.inventory([page([Map.put(source, "position", 0)])])

    %{entry | position: source["position"]}
  end

  @spec file(non_neg_integer(), String.t(), binary(), String.t()) :: ContextManifest.file()
  defp file(position, path, content, scope \\ "project"),
    do: %{entry: parsed_source(source(position, path, content, scope)), content: content}

  @spec chunk(ContextManifest.entry(), binary(), non_neg_integer(), boolean()) :: map()
  defp chunk(entry, bytes, offset, eof?),
    do: %{
      "version" => 1,
      "path" => entry.path,
      "digest" => entry.digest,
      "offset" => offset,
      "data_base64" => Base.encode64(bytes),
      "eof" => eof?,
      "next_offset" => if(eof?, do: nil, else: offset + byte_size(bytes))
    }

  @spec digest(binary()) :: String.t()
  defp digest(value), do: ContextManifest.digest(value)
end
