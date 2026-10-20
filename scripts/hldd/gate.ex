Code.require_file("documents.ex", __DIR__)

defmodule Overalls.HLDDGate do
  @moduledoc "Deterministic review receipts and structural checks for the handbook."
  @type group :: %{String.t() => term()}
  alias Overalls.HLDDDocuments, as: Documents
  @manifest "docs/hldd-maintenance.json"
  @reviews "docs/hldd/reviews"
  @groups "docs/hldd/groups"
  @type review :: %{
          path: String.t(),
          kind: String.t(),
          groups: [String.t()],
          chapters: [String.t()],
          expected: map(),
          receipt: map() | nil,
          status: String.t()
        }
  @chapters "marshall/priv/hldd"
  @ignored ~w(.git .devenv .direnv .ruff_cache .nixos-test-history _build deps node_modules target result)

  @spec files(String.t()) :: [String.t()]
  def files(root) do
    paths =
      if File.exists?(Path.join(root, ".git")) do
        case System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
               cd: root
             ) do
          {output, 0} -> String.split(output, <<0>>, trim: true)
          _ -> raise("cannot enumerate HLDD source inventory")
        end
      else
        walk(root, "")
      end

    paths
    |> Enum.uniq()
    |> Enum.reject(&excluded?/1)
    |> Enum.filter(&File.regular?(Path.join(root, &1)))
    |> Enum.sort()
  end

  @spec walk(String.t(), String.t()) :: [String.t()]
  defp walk(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(relative, name)
      full = Path.join(root, path)

      cond do
        name in @ignored -> []
        File.lstat!(full).type == :symlink -> []
        File.dir?(full) -> walk(root, path)
        excluded?(path) -> []
        true -> [path]
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] hldd-ci-workflows-exempt
  # .github/ (CI workflows, actions and their scripts) MUST NOT be a reviewed
  # source: it drives repository automation, not documented product behavior,
  # configuration or deployment, so it needs no handbook receipt.
  @ci_prefix ".github/"

  # @cc [owner:ghuntley,label:verification] hldd-devenv-pin-exempt
  # devenv.lock and flake.lock MUST NOT be reviewed sources: the scheduled
  # automatic nix upgrades workflow rewrites their pins unattended; a pin bump
  # alone changes no documented behavior. devenv.yaml, devenv.nix and
  # flake.nix remain covered.
  @spec excluded?(String.t()) :: boolean()
  defp excluded?(path) do
    Enum.any?(Path.split(path), &(&1 in @ignored)) or
      path == @manifest or String.starts_with?(path, @reviews <> "/") or
      path in ["devenv.lock", "flake.lock"] or
      (String.starts_with?(path, @chapters <> "/") and String.ends_with?(path, ".md")) or
      String.starts_with?(path, ["secrets/", "marshall/priv/static/assets/", @ci_prefix]) or
      String.ends_with?(path, [".beam", ".pyc", ".gz"]) or
      path == "marshall/priv/static/cache_manifest.json" or
      Regex.match?(~r/-[0-9a-f]{32}\.[^.]+$/, path)
  end

  # @cc [owner:ghuntley,label:verification] hldd-digest-identity
  # Review digests MUST bind sorted relative paths and file bytes. Adding,
  # deleting, renaming or editing a covered file MUST invalidate its receipt.
  @spec digest(String.t(), [String.t()]) :: String.t()
  def digest(root, paths) do
    paths
    |> Enum.sort()
    |> Enum.map(fn path ->
      bytes = File.read!(Path.join(root, path))
      [Integer.to_string(byte_size(path)), ":", path, ":", :crypto.hash(:sha256, bytes)]
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec manifest(String.t()) :: map()
  def manifest(root) do
    if File.exists?(Path.join(root, @manifest)),
      do: raise("legacy HLDD manifest exists; run migrate LEGACY_ROOT before checking")

    groups = Documents.collection(Path.join(root, @groups), "id")
    validate_groups!(groups)
    %{"version" => 2, "groups" => groups}
  end

  @spec validate_groups!([map()]) :: :ok
  def validate_groups!(groups) do
    Enum.each(groups, fn g ->
      unless Map.keys(g) |> Enum.sort() == ~w(chapters id prefixes) and
               is_binary(g["id"]) and Regex.match?(~r/^[a-z][a-z0-9-]*$/, g["id"]) and
               is_list(g["prefixes"]) and Enum.all?(g["prefixes"], &safe_path?/1) and
               is_list(g["chapters"]) and g["chapters"] != [] and
               Enum.all?(
                 g["chapters"],
                 &(safe_path?(&1) and Path.basename(&1) == &1 and String.ends_with?(&1, ".md"))
               ),
             do: raise("invalid HLDD group")
    end)

    ids = Enum.map(groups, & &1["id"])
    unless length(ids) == length(Enum.uniq(ids)), do: raise("duplicate HLDD group")

    unless Enum.count(groups, &(&1["prefixes"] == [])) == 1,
      do: raise("one catch-all HLDD group is required")

    :ok
  end

  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path),
    do:
      path != "" and Path.type(path) == :relative and
        not Enum.any?(Path.split(path), &(&1 in ["..", "."])) and
        not String.contains?(path, ["\\", "\n", "\r", <<0>>])

  def safe_path?(_), do: false

  @spec assigned([String.t()], [group()], group()) :: [String.t()]
  def assigned(paths, groups, group) do
    Enum.filter(paths, fn path ->
      matches =
        Enum.filter(groups, fn g -> Enum.any?(g["prefixes"], &String.starts_with?(path, &1)) end)

      if matches == [], do: group["prefixes"] == [], else: group in matches
    end)
  end

  @spec receipt_path(String.t(), String.t()) :: String.t()
  def receipt_path(kind, path) when kind in ["source", "chapter"] do
    unless safe_path?(path), do: raise("invalid receipt target")
    suffix = if kind == "chapter", do: Path.basename(path, ".md"), else: path
    Path.join([@reviews, kind <> "s", suffix <> ".md"])
  end

  @spec mapping([group()], String.t()) :: [group()]
  defp mapping(groups, path), do: Enum.filter(groups, &(assigned([path], groups, &1) != []))

  @spec mapping_digest([group()]) :: String.t()
  defp mapping_digest(groups) do
    groups
    |> Enum.sort_by(& &1["id"])
    |> Enum.map(&{&1["id"], Enum.sort(&1["prefixes"]), Enum.sort(&1["chapters"])})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec expected(String.t(), String.t(), String.t(), [group()]) :: map()
  defp expected(root, kind, path, groups) do
    exists = File.regular?(Path.join(root, path))

    %{
      "version" => 2,
      "kind" => kind,
      "path" => path,
      "state" => if(exists, do: "present", else: "deleted"),
      "digest" => if(exists, do: digest(root, [path]), else: nil),
      "mapping_digest" =>
        if(kind == "source", do: mapping_digest(mapping(groups, path)), else: nil)
    }
  end

  @spec hash?(term()) :: boolean()
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  @spec chapter_path?(term()) :: boolean()
  defp chapter_path?(path),
    do:
      safe_path?(path) and Path.dirname(path) == @chapters and
        Regex.match?(~r/^[0-9]+-[a-z0-9-]+\.md$/, Path.basename(path))

  @spec migration?(term()) :: boolean()
  defp migration?(nil), do: true

  defp migration?(data) when is_map(data) do
    map_size(data) > 0 and
      Enum.all?(data, fn {id, hashes} ->
        is_binary(id) and Regex.match?(~r/^[a-z][a-z0-9-]*$/, id) and is_map(hashes) and
          Enum.sort(Map.keys(hashes)) == ~w(chapter_digest source_digest) and
          Enum.all?(Map.values(hashes), &hash?/1)
      end)
  end

  defp migration?(_), do: false

  @spec receipts(String.t()) :: %{String.t() => map()}
  defp receipts(root) do
    paths = Documents.paths(Path.join(root, @reviews), ".md")

    Enum.zip(paths, Documents.read(paths))
    |> Map.new(fn {file, %{"data" => data, "body" => body} = document} ->
      required = ~w(version kind path state digest mapping_digest reviewed_chapters disposition)

      unless is_map(data) and Enum.sort(Map.keys(data) -- ["migration"]) == Enum.sort(required) and
               data["version"] == 2 and data["kind"] in ["source", "chapter"] and
               safe_path?(data["path"]) and data["state"] in ["present", "deleted"] and
               (data["kind"] == "source" or chapter_path?(data["path"])) and
               migration?(data["migration"]) and
               ((data["state"] == "present" and hash?(data["digest"])) or
                  (data["state"] == "deleted" and data["digest"] == nil)) and
               ((data["kind"] == "source" and hash?(data["mapping_digest"])) or
                  (data["kind"] == "chapter" and data["mapping_digest"] == nil)) and
               is_map(data["reviewed_chapters"]) and
               Enum.all?(data["reviewed_chapters"], fn {path, hash} ->
                 chapter_path?(path) and hash?(hash)
               end) and
               (data["kind"] == "source" or data["reviewed_chapters"] == %{}) and
               data["disposition"] in ["updated", "no-impact"] and
               is_binary(body) and String.length(String.trim(body)) >= 20 and
               Path.relative_to(file, root) == receipt_path(data["kind"], data["path"]),
             do: raise("invalid review receipt: #{Path.relative_to(file, root)}")

      {data["kind"] <> ":" <> data["path"], document}
    end)
  end

  # @cc [owner:ghuntley,label:verification] hldd-independent-reviews
  # Source currency MUST bind its path, bytes and applicable mappings. Chapter
  # currency MUST be checked independently; a later chapter review MUST NOT
  # invalidate unrelated source reviews. Deleted targets require tombstones.

  # @cc [owner:ghuntley,label:verification] hldd-chapter-removal-review
  # A chapter removed from every current mapping MUST remain selectable for
  # explicit deletion review through the catch-all group.
  @spec status(String.t()) :: [review()]
  def status(root), do: status(root, manifest(root)["groups"])

  @spec status(String.t(), [group()]) :: [review()]
  defp status(root, groups) do
    receipts = receipts(root)
    sources = files(root)

    chapters =
      Path.wildcard(Path.join([root, @chapters, "[0-9]*.md"]))
      |> Enum.map(&Path.relative_to(&1, root))

    current = Enum.map(sources, &{"source", &1}) ++ Enum.map(chapters, &{"chapter", &1})
    previous = Enum.map(receipts, fn {_, r} -> {r["data"]["kind"], r["data"]["path"]} end)

    (current ++ previous)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {kind, path} ->
      receipt = receipts[kind <> ":" <> path]
      expected = expected(root, kind, path, groups)

      mapped =
        if kind == "source",
          do: mapping(groups, path),
          else: Enum.filter(groups, &(Path.basename(path) in &1["chapters"]))

      # A removed chapter has no current association. Keep its deletion
      # review reachable through the catch-all rather than orphan its receipt.
      mapped = if mapped == [], do: Enum.filter(groups, &(&1["prefixes"] == [])), else: mapped

      state =
        cond do
          receipt == nil -> "added"
          Enum.all?(expected, fn {key, value} -> receipt["data"][key] == value end) -> "current"
          expected["state"] == "deleted" -> "deleted"
          receipt["data"]["state"] == "deleted" -> "restored"
          receipt["data"]["mapping_digest"] != expected["mapping_digest"] -> "mapping-changed"
          true -> "changed"
        end

      %{
        kind: kind,
        path: path,
        expected: expected,
        receipt: receipt,
        status: state,
        groups: Enum.map(mapped, & &1["id"]),
        chapters: mapped |> Enum.flat_map(& &1["chapters"]) |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  # @cc [owner:ghuntley,label:verification] hldd-check-read-only
  # Checking MUST NOT refresh receipts. Every source or chapter mismatch MUST
  # fail until an explicit reviewed update or reasoned no-impact record is made.
  @spec check(String.t()) :: [String.t()]
  def check(root) do
    data = manifest(root)

    errors =
      for row <- status(root, data["groups"]),
          row.status != "current",
          do: "#{row.path}: HLDD review is stale (#{row.status}); review and record this path"

    errors ++
      links(root, data["groups"]) ++
      Overalls.HLDDCoverage.check(root) ++
      Overalls.HLDDViews.check(root, files(root))
  rescue
    e in [ArgumentError, KeyError, RuntimeError, File.Error] -> [Exception.message(e)]
  end

  @spec links(String.t(), [group()]) :: [String.t()]
  defp links(root, groups) do
    paths = Path.wildcard(Path.join([root, @chapters, "[0-9]*.md"])) |> Enum.sort()
    names = Enum.map(paths, &Path.basename/1)
    mapped = groups |> Enum.flat_map(& &1["chapters"]) |> Enum.uniq()
    anchors = Enum.map(names, &Regex.replace(~r/^\d+-|\.md$/, &1, ""))

    coverage =
      Enum.map(names -- mapped, &"unmapped chapter: #{&1}") ++
        Enum.map(mapped -- names, &"missing mapped chapter: #{&1}")

    duplicates =
      if length(anchors) == length(Enum.uniq(anchors)),
        do: [],
        else: ["duplicate chapter anchors"]

    coverage ++
      duplicates ++
      Enum.flat_map(paths, fn path ->
        markdown = File.read!(path)

        headings =
          if Regex.match?(~r/^# .+$/m, markdown), do: [], else: ["#{path}: missing title"]

        headings ++
          (Regex.scan(~r/\]\(([^\s)]+)\)/, markdown)
           |> Enum.flat_map(fn [_, target] ->
             valid =
               cond do
                 String.starts_with?(target, "repo:") ->
                   relative = target |> String.trim_leading("repo:") |> String.split("#") |> hd()
                   safe_path?(relative) and File.regular?(Path.join(root, relative))

                 String.starts_with?(target, "#") ->
                   String.trim_leading(target, "#") in anchors

                 String.starts_with?(target, ["https://", "http://"]) ->
                   true

                 true ->
                   false
               end

             if valid, do: [], else: ["#{Path.basename(path)}: invalid reference #{target}"]
           end))
      end)
  end

  # @cc [owner:ghuntley,label:verification] hldd-record-scoped
  # Explicit recording MUST write only selected stale targets, never refresh
  # unrelated or already-current receipts, and MUST preserve a concrete rationale.
  @spec record(String.t(), String.t(), String.t(), String.t(), [String.t()]) :: :ok
  def record(root, id, disposition, rationale, selected \\ []) do
    unless disposition in ["updated", "no-impact"] and String.length(String.trim(rationale)) >= 20,
      do: raise("supply updated|no-impact and a concrete rationale (at least 20 characters)")

    groups = manifest(root)["groups"]
    unless Enum.any?(groups, &(&1["id"] == id)), do: raise("unknown review group #{id}")
    rows = status(root, groups) |> Enum.filter(&(id in &1.groups))

    Enum.each(selected, fn path ->
      unless Enum.any?(rows, &(&1.path == path)),
        do: raise("path is outside group #{id}: #{path}")
    end)

    selected_rows = Enum.filter(rows, &(selected == [] or &1.path in selected))
    rows = Enum.reject(selected_rows, &(&1.status == "current"))

    changed_chapter =
      Enum.any?(selected_rows, fn chapter ->
        chapter.kind == "chapter" and
          (chapter.status != "current" or
             Enum.any?(rows, fn source ->
               source.kind == "source" and source.receipt != nil and
                 Map.has_key?(source.receipt["data"]["reviewed_chapters"], chapter.path) and
                 source.receipt["data"]["reviewed_chapters"][chapter.path] !=
                   chapter.expected["digest"]
             end))
      end)

    if disposition == "updated" and Enum.any?(rows, &(&1.kind == "source")) and
         not changed_chapter,
       do:
         raise(
           "updated requires a chapter change in the selected review; otherwise record no-impact"
         )

    entries = Enum.map(rows, &review_entry(root, &1, disposition, rationale))
    Documents.write(entries)
  end

  @spec review_entry(String.t(), review(), String.t(), String.t()) :: map()
  defp review_entry(root, row, disposition, rationale) do
    snapshots =
      if row.kind == "source" do
        row.chapters
        |> Enum.map(&Path.join(@chapters, &1))
        |> Enum.filter(&File.regular?(Path.join(root, &1)))
        |> Map.new(&{&1, digest(root, [&1])})
      else
        %{}
      end

    %{
      "path" => Path.join(root, receipt_path(row.kind, row.path)),
      "body" => rationale,
      "data" =>
        Map.merge(row.expected, %{"disposition" => disposition, "reviewed_chapters" => snapshots})
    }
  end

  @doc "Transfer validated legacy evidence; current target bytes are never substituted."
  @spec migration_entries(String.t(), String.t(), [group()]) :: [map()]
  def migration_entries(baseline, target, legacy_groups) do
    groups = Enum.map(legacy_groups, &Map.take(&1, ~w(id prefixes chapters)))
    sources = Enum.map(files(baseline), &{"source", &1})

    chapters =
      groups
      |> Enum.flat_map(& &1["chapters"])
      |> Enum.uniq()
      |> Enum.map(&{"chapter", Path.join(@chapters, &1)})

    Enum.map(sources ++ chapters, fn {kind, path} ->
      mapped =
        if kind == "source",
          do: mapping(groups, path),
          else: Enum.filter(groups, &(Path.basename(path) in &1["chapters"]))

      old =
        Enum.filter(legacy_groups, fn group -> Enum.any?(mapped, &(&1["id"] == group["id"])) end)

      rationale = Enum.map_join(old, "\n\n", &"#{&1["id"]}: #{&1["rationale"]}")

      row = %{
        kind: kind,
        path: path,
        expected: expected(baseline, kind, path, groups),
        chapters: mapped |> Enum.flat_map(& &1["chapters"]) |> Enum.uniq(),
        groups: Enum.map(mapped, & &1["id"]),
        receipt: nil,
        status: "added"
      }

      entry = review_entry(baseline, row, hd(old)["disposition"], rationale)
      provenance = Map.new(old, &{&1["id"], Map.take(&1, ~w(source_digest chapter_digest))})

      %{
        entry
        | "path" => Path.join(target, receipt_path(kind, path)),
          "data" => Map.put(entry["data"], "migration", provenance)
      }
    end)
  end
end
