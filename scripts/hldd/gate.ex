defmodule Overalls.HLDDGate do
  @moduledoc "Deterministic review receipts and structural checks for the handbook."
  @type group :: %{String.t() => term()}
  @manifest "docs/hldd-maintenance.json"
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
      path == @manifest or
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
    data = root |> Path.join(@manifest) |> File.read!() |> JSON.decode!()

    unless is_map(data) and data["version"] == 1 and is_list(data["groups"]),
      do: raise("invalid HLDD manifest")

    groups = data["groups"]
    unless Enum.all?(groups, &is_map/1), do: raise("invalid HLDD group")
    ids = Enum.map(groups, & &1["id"])
    unless length(ids) == length(Enum.uniq(ids)), do: raise("duplicate HLDD group")

    Enum.each(groups, fn g ->
      unless is_map(g) and is_binary(g["id"]) and Regex.match?(~r/^[a-z][a-z0-9-]*$/, g["id"]) and
               is_list(g["prefixes"]) and Enum.all?(g["prefixes"], &safe_path?/1) and
               is_list(g["chapters"]) and g["chapters"] != [] and
               Enum.all?(g["chapters"], &safe_path?/1),
             do: raise("invalid HLDD group")
    end)

    unless Enum.count(groups, &(&1["prefixes"] == [])) == 1,
      do: raise("one catch-all HLDD group is required")

    data
  end

  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path),
    do:
      path != "" and Path.type(path) == :relative and
        not Enum.any?(Path.split(path), &(&1 in ["..", "."])) and
        not String.contains?(path, ["\\", "\n", "\r"])

  def safe_path?(_), do: false

  @spec assigned([String.t()], [group()], group()) :: [String.t()]
  def assigned(paths, groups, group) do
    Enum.filter(paths, fn path ->
      matches =
        Enum.filter(groups, fn g -> Enum.any?(g["prefixes"], &String.starts_with?(path, &1)) end)

      if matches == [], do: group["prefixes"] == [], else: group in matches
    end)
  end

  @spec fingerprints(String.t(), [String.t()], [group()], group()) :: map()
  def fingerprints(root, paths, groups, group) do
    %{
      "source_digest" => digest(root, assigned(paths, groups, group)),
      "chapter_digest" => digest(root, Enum.map(group["chapters"], &Path.join(@chapters, &1)))
    }
  end

  # @cc [owner:ghuntley,label:verification] hldd-check-read-only
  # Checking MUST NOT refresh receipts. Every source or chapter mismatch MUST
  # fail until an explicit reviewed update or reasoned no-impact record is made.
  @spec check(String.t()) :: [String.t()]
  def check(root) do
    data = manifest(root)
    paths = files(root)

    errors =
      Enum.flat_map(data["groups"], fn group ->
        expected = fingerprints(root, paths, data["groups"], group)

        valid =
          group["disposition"] in ["updated", "no-impact"] and is_binary(group["rationale"]) and
            String.length(String.trim(group["rationale"])) >= 20

        cond do
          not valid ->
            ["#{group["id"]}: missing disposition or concrete review rationale"]

          Enum.any?(expected, fn {key, value} -> group[key] != value end) ->
            [
              "#{group["id"]}: HLDD review is stale; inspect the diff and update chapters or record why no update is needed"
            ]

          true ->
            []
        end
      end)

    errors ++
      links(root, data["groups"]) ++
      Overalls.HLDDCoverage.check(root) ++
      Overalls.HLDDViews.check(root, paths)
  rescue
    e in [ArgumentError, KeyError, RuntimeError, File.Error] -> [Exception.message(e)]
  end

  @spec links(String.t(), [group()]) :: [String.t()]
  defp links(root, groups) do
    paths = Path.wildcard(Path.join([root, @chapters, "[0-9]*.md"])) |> Enum.sort()
    names = Enum.map(paths, &Path.basename/1)
    mapped = groups |> Enum.flat_map(& &1["chapters"]) |> Enum.uniq()
    anchors = Enum.map(names, &Regex.replace(~r/^\d+-|\.md$/, &1, ""))
    coverage = Enum.map(names -- mapped, &"unmapped chapter: #{&1}")

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

  @spec record(String.t(), String.t(), String.t(), String.t()) :: :ok
  def record(root, id, disposition, rationale) do
    unless disposition in ["updated", "no-impact"] and String.length(String.trim(rationale)) >= 20,
      do: raise("supply updated|no-impact and a concrete rationale (at least 20 characters)")

    data = manifest(root)
    unless Enum.any?(data["groups"], &(&1["id"] == id)), do: raise("unknown review group #{id}")
    paths = files(root)

    groups =
      Enum.map(data["groups"], fn g ->
        if g["id"] == id do
          current = fingerprints(root, paths, data["groups"], g)

          if disposition == "updated" and g["source_digest"] != current["source_digest"] and
               g["chapter_digest"] == current["chapter_digest"],
             do:
               raise(
                 "updated requires a chapter change; otherwise record no-impact with its rationale"
               )

          Map.merge(g, current)
          |> Map.merge(%{"disposition" => disposition, "rationale" => rationale})
        else
          g
        end
      end)

    File.write!(Path.join(root, @manifest), JSON.encode!(%{data | "groups" => groups}) <> "\n")
  end
end
