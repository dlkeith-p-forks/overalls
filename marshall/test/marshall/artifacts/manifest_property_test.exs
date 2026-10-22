defmodule Marshall.Artifacts.ManifestPropertyTest do
  # @cc [owner:ghuntley,label:verification;correctness] artifact-manifest-model
  # Manifest application MUST equal the Map model (put, delete on nil, keep
  # omitted) over normalized paths; path normalization MUST be idempotent and
  # reject traversal; limits MUST be inclusive at their exact boundaries.
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Artifacts.{Limits, Manifest, Paths}

  @segments ~w(a b css js img data.json style.css app.js logo.svg)

  defp path,
    do: map(list_of(member_of(@segments), min_length: 1, max_length: 3), &Enum.join(&1, "/"))

  defp entry,
    do:
      map(integer(0, 1_000), fn bytes ->
        %{sha256: String.duplicate("a", 64), bytes: bytes, content_type: "text/plain"}
      end)

  property "applying changes equals the map model" do
    previous = draw("previous", map_of(path(), entry(), max_length: 6))
    changes = draw("changes", map_of(path(), one_of([constant(nil), entry()]), max_length: 6))

    expected =
      Enum.reduce(changes, previous, fn
        {path, nil}, acc -> Map.delete(acc, path)
        {path, change}, acc -> Map.put(acc, path, change)
      end)

    assert Manifest.apply(previous, changes) == {:ok, expected}
  end

  property "normalization is idempotent and never yields traversal" do
    raw =
      draw(
        "raw",
        map(
          list_of(member_of(@segments ++ ["", ".", "..", "./", "__x", "a\\b"]),
            min_length: 1,
            max_length: 4
          ),
          &Enum.join(&1, "/")
        )
      )

    case Paths.normalize(raw) do
      {:ok, normalized} ->
        assert Paths.normalize(normalized) == {:ok, normalized}
        refute Enum.any?(String.split(normalized, "/"), &(&1 in ["", ".", ".."]))
        refute String.starts_with?(normalized, "__")

      {:error, :invalid_path} ->
        :ok
    end
  end

  test "the page path cannot be changed through files" do
    assert {:error, :manifest_conflict} = Manifest.apply(%{}, %{"index.html" => nil})
  end

  test "keys that normalize to one path conflict" do
    one = %{sha256: String.duplicate("b", 64), bytes: 1, content_type: "text/plain"}
    assert {:error, :manifest_conflict} = Manifest.apply(%{}, %{"a.txt" => one, "./a.txt" => one})
  end

  property "limits are inclusive at each boundary" do
    field =
      draw(
        "field",
        member_of([:page_bytes, :publish_files, :publish_bytes, :version_files, :version_bytes])
      )

    limit =
      case field do
        :page_bytes -> Limits.page_bytes()
        :publish_files -> Limits.publish_files()
        :publish_bytes -> Limits.publish_bytes()
        :version_files -> Limits.version_files()
        :version_bytes -> Limits.version_bytes()
      end

    base = %{
      page_bytes: 0,
      publish_files: 0,
      publish_bytes: 0,
      version_files: 1,
      version_bytes: 0
    }

    assert Limits.check(Map.put(base, field, limit)) == :ok
    assert {:error, _} = Limits.check(Map.put(base, field, limit + 1))
  end
end
