defmodule Marshall.PaperTrailPolicyTest do
  use ExUnit.Case, async: true

  alias AshPaperTrail.Resource.Info, as: PaperTrailInfo

  test "every PaperTrail resource has private actor metadata and bounded retention" do
    retained = MapSet.new(Marshall.Compute.ExpireLifecycleEvents.version_tables())

    Enum.each(resources(), fn resource ->
      metadata = Map.new(PaperTrailInfo.metadata(resource), &{&1.name, &1})

      assert %{
               actor_kind: %{type: Ash.Type.Atom, allow_nil?: true},
               actor_id: %{type: Ash.Type.UUID, allow_nil?: true}
             } =
               metadata,
             "#{inspect(resource)} must retain nullable actor metadata"

      assert PaperTrailInfo.sensitive_attributes(resource) == :ignore,
             "#{inspect(resource)} must ignore sensitive attributes"

      version = PaperTrailInfo.version_resource(resource)
      table = AshPostgres.DataLayer.Info.table(version)

      assert MapSet.member?(retained, table),
             "#{inspect(resource)} version table #{inspect(table)} is missing from retention"
    end)
  end

  defp resources do
    :marshall
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&(AshPaperTrail.Resource in Ash.Resource.Info.extensions(&1)))
  end
end
