defmodule Marshall.Agents.Skills.CatalogTest do
  use ExUnit.Case, async: true
  alias Marshall.Agents.Skills.Catalog

  test "metadata is bounded and bodies are not included in the initial catalog" do
    body = String.duplicate("Read the schema.\n", 1024)

    assert {:ok, skill} =
             Catalog.parse(
               source(),
               "---\nname: schema\ndescription: Read schemas\n---\n" <> body
             )

    assert skill.body == body
    assert skill.allow_implicit
    assert {:ok, [entry]} = Catalog.catalog([skill])
    refute Map.has_key?(entry, :body)
    assert entry.name == "schema"
    assert entry.digest == source().digest
  end

  test "duplicate names retain identities and require exact selection" do
    assert {:ok, first} = Catalog.parse(source(), document())
    assert {:ok, second} = Catalog.parse(source("/workspace/other/SKILL.md"), document())
    refute first.id == second.id
    assert {:error, :ambiguous_skill} = Catalog.select([first, second], ["review"])
    assert {:ok, [^second]} = Catalog.select([first, second], [second.id])
    assert {:error, :duplicate_selection} = Catalog.select([first], [first.id, "$review"])
  end

  test "implicit invocation policy is typed and explicit selection still works" do
    metadata =
      "policy:\n  allow_implicit_invocation: false\ndependencies:\n  - external-service\n"

    assert {:ok, entry} = Catalog.parse(source(), document(), metadata)
    refute entry.allow_implicit
    assert entry.dependencies == ["external-service"]
    assert {:ok, [^entry]} = Catalog.select([entry], ["$review"])

    assert {:error, :invalid_metadata} =
             Catalog.parse(
               source(),
               document(),
               "policy:\n  allow_implicit_invocation: yesplease\n"
             )
  end

  test "aliases and application tags are refused before YAML expansion" do
    for header <- [
          "name: &anchor review\ndescription: *anchor",
          "name: !!str review\ndescription: harmless",
          "name: review\ndescription: [*anchor]",
          "name: review\ndescription: harmless\npolicy: !custom {}"
        ] do
      assert {:error, :invalid_metadata} =
               Catalog.parse(source(), "---\n" <> header <> "\n---\nBody")
    end
  end

  test "missing fields, invalid UTF8 and oversized bodies fail explicitly" do
    assert {:error, :invalid_skill} = Catalog.parse(source(), "not a skill file")
    assert {:error, :invalid_metadata} = Catalog.parse(source(), "---\nname: review\n---\nbody")
    assert {:error, :invalid_skill} = Catalog.parse(source(), <<255>>)
    assert {:error, :skill_too_large} = Catalog.parse(source(), String.duplicate("x", 1_048_577))
    assert {:error, :invalid_skill} = Catalog.parse(%{source() | scope: :unknown}, document())
  end

  test "catalog overflow is explicit and skill mentions are distinct standalone tokens" do
    assert {:ok, skill} = Catalog.parse(source(), document())
    assert {:error, :catalog_too_large} = Catalog.catalog(List.duplicate(skill, 101))

    assert Catalog.mentions(
             "Use $review, then $schema. Again $review! Price $10 and cost$invalid"
           ) ==
             ["review", "schema"]
  end

  @spec document() :: String.t()
  defp document,
    do: "---\nname: review\ndescription: Review the current changes\n---\nInspect contracts.\n"

  @spec source(String.t()) :: Catalog.source()
  defp source(path \\ "/workspace/.agents/skills/review/SKILL.md"),
    do: %{path: path, digest: String.duplicate("a", 64), bytes: 128, scope: :project}
end
