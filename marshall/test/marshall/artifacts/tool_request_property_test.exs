defmodule Marshall.Artifacts.ToolRequestPropertyTest do
  # @cc [owner:ghuntley,label:verification;protocol] artifact-tool-request-closed
  # The artifact tool parser MUST accept exactly the closed per-operation
  # argument sets and refuse unknown keys, mixed page sources, oversized
  # inline content, relative staged paths and creation without a full page.
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Artifacts.Tool

  property "unknown keys are always refused" do
    operation = draw("operation", member_of(~w(publish read list delete)))
    key = draw("key", member_of(~w(owner_id actor path_to sql binding status)))

    arguments =
      %{"operation" => operation, "artifact_id" => Ash.UUID.generate(), "base_version" => 1}
      |> Map.take(Map.fetch!(allowed(), operation))
      |> Map.put(key, "x")

    assert Tool.parse(arguments) == {:error, :invalid_arguments}
  end

  property "publish accepts at most one page source" do
    content = draw("content", boolean())
    edits = draw("edits", boolean())
    staged = draw("staged", boolean())

    arguments =
      %{"operation" => "publish", "artifact_id" => Ash.UUID.generate(), "base_version" => 2}
      |> then(&if(content, do: Map.put(&1, "content", "<p>x</p>"), else: &1))
      |> then(
        &if(edits, do: Map.put(&1, "edits", [%{"old_str" => "x", "new_str" => "y"}]), else: &1)
      )
      |> then(&if(staged, do: Map.put(&1, "content_path", "/workspace/index.html"), else: &1))

    sources = Enum.count([content, edits, staged], & &1)

    if sources <= 1,
      do: assert({:ok, %Tool.Request{operation: :publish}} = Tool.parse(arguments)),
      else: assert(Tool.parse(arguments) == {:error, :invalid_arguments})
  end

  test "creation needs base 0 and a full page" do
    assert {:ok, _} =
             Tool.parse(%{"operation" => "publish", "base_version" => 0, "content" => "x"})

    assert {:error, :invalid_arguments} =
             Tool.parse(%{"operation" => "publish", "base_version" => 1, "content" => "x"})

    assert {:error, :invalid_arguments} =
             Tool.parse(%{
               "operation" => "publish",
               "base_version" => 0,
               "edits" => [%{"old_str" => "a", "new_str" => "b"}]
             })
  end

  test "inline content is bounded and staged paths must be absolute" do
    big = String.duplicate("a", 128 * 1024 + 1)

    assert {:error, :invalid_arguments} =
             Tool.parse(%{"operation" => "publish", "base_version" => 0, "content" => big})

    assert {:error, :invalid_arguments} =
             Tool.parse(%{
               "operation" => "publish",
               "base_version" => 0,
               "content_path" => "rel/x.html"
             })

    assert {:ok, %Tool.Request{page: {:stage, "C:\\work\\x.html"}}} =
             Tool.parse(%{
               "operation" => "publish",
               "base_version" => 0,
               "content_path" => "C:\\work\\x.html"
             })
  end

  defp allowed do
    %{
      "publish" => ~w(operation artifact_id base_version),
      "read" => ~w(operation artifact_id),
      "list" => ~w(operation),
      "delete" => ~w(operation artifact_id)
    }
  end
end
