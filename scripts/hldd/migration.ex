defmodule Overalls.HLDDMigration do
  @moduledoc "Explicit one-time transfer of validated v1 review evidence."
  alias Overalls.{HLDDDocuments, HLDDGate}
  @legacy "docs/hldd-maintenance.json"

  # @cc [owner:ghuntley,label:verification] hldd-migration-preserves-evidence
  # Migration MUST validate every old group against its baseline before writing.
  # It MUST transfer baseline hashes and rationales, never bless changed target
  # bytes, and MUST refuse an existing v2 review store.
  @spec run(String.t(), String.t()) :: :ok
  def run(root, baseline) do
    if File.exists?(Path.join(root, "docs/hldd/reviews")), do: raise("v2 receipts already exist")
    legacy = baseline |> Path.join(@legacy) |> File.read!() |> JSON.decode!()

    unless is_map(legacy) and legacy["version"] == 1 and is_list(legacy["groups"]),
      do: raise("invalid legacy manifest")

    groups = legacy["groups"]
    definitions = Enum.map(groups, &Map.take(&1, ~w(id prefixes chapters)))
    HLDDGate.validate_groups!(definitions)
    paths = HLDDGate.files(baseline)

    Enum.each(groups, fn group ->
      source = HLDDGate.digest(baseline, HLDDGate.assigned(paths, groups, group))

      chapter =
        HLDDGate.digest(
          baseline,
          Enum.map(group["chapters"], &Path.join("marshall/priv/hldd", &1))
        )

      unless source == group["source_digest"] and chapter == group["chapter_digest"] and
               group["disposition"] in ["updated", "no-impact"] and
               is_binary(group["rationale"]) and
               String.length(String.trim(group["rationale"])) >= 20,
             do: raise("stale legacy group #{group["id"]}; review it before migration")
    end)

    entries = HLDDGate.migration_entries(baseline, root, groups)

    definitions =
      Enum.map(
        definitions,
        &%{"path" => Path.join([root, "docs/hldd/groups", &1["id"] <> ".yaml"]), "data" => &1}
      )

    HLDDDocuments.write(definitions ++ entries)
    if File.exists?(Path.join(root, @legacy)), do: File.rm!(Path.join(root, @legacy))
    :ok
  end
end
