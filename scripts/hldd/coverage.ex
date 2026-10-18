defmodule Overalls.HLDDCoverage do
  @moduledoc "Validated scenario and security-boundary evidence, rendered without upgrading claims."
  @layers ~w(identity authorization transport execution isolation storage recovery)
  @path "marshall/priv/hldd/scenarios.json"
  @output "marshall/priv/hldd/19-coverage.md"

  @spec read(String.t()) :: map()
  def read(root), do: root |> Path.join(@path) |> File.read!() |> JSON.decode!()

  # @cc [owner:ghuntley,label:verification] hldd-security-evidence
  # Each scenario MUST name its boundary, expected denial, evidence scope and gaps.
  # Every security layer MUST have an entry. Missing native/property evidence MUST
  # be explicit; file presence MUST NOT become a recorded passing execution claim.
  @spec validate(String.t(), term()) :: [String.t()]
  def validate(root, %{"version" => 1, "scenarios" => rows}) when is_list(rows) and rows != [] do
    errors = Enum.flat_map(rows, &row_errors(root, &1))

    if errors == [] do
      ids = Enum.map(rows, & &1["id"])
      layers = Enum.flat_map(rows, & &1["layers"])

      errors ++
        if(length(ids) != length(Enum.uniq(ids)), do: ["duplicate scenario ID"], else: []) ++
        Enum.map(@layers -- layers, &"missing security layer: #{&1}")
    else
      errors
    end
  end

  def validate(_, _), do: ["invalid scenario ledger"]

  @spec row_errors(String.t(), term()) :: [String.t()]
  defp row_errors(root, row) when is_map(row) do
    fields = ~w(id journey boundary denial scope gaps preferred_gap)

    valid =
      Enum.all?(fields, &(is_binary(row[&1]) and String.trim(row[&1]) != "")) and
        is_list(row["layers"]) and row["layers"] != [] and
        Enum.all?(row["layers"], &(&1 in @layers)) and
        row["status"] in ["partial", "gap", "covered"] and is_list(row["evidence"])

    if valid do
      kinds = for %{"kind" => kind} <- row["evidence"], do: kind

      missing =
        if "machine" in kinds and "property" in kinds,
          do: [],
          else:
            if(String.length(row["preferred_gap"]) < 20,
              do: ["#{row["id"]}: explain missing NixOS machine or property coverage"],
              else: []
            )

      covered =
        if row["status"] == "covered" and
             (not ("machine" in kinds and "property" in kinds) or
                not Enum.all?(row["evidence"], &(is_map(&1) and &1["execution"] == "recorded"))),
           do: ["#{row["id"]}: covered requires recorded native and property evidence"],
           else: []

      gap =
        if row["status"] == "gap" and row["evidence"] != [],
          do: ["#{row["id"]}: gap must have no evidence; use partial"],
          else: []

      missing ++ covered ++ gap ++ Enum.flat_map(row["evidence"], &evidence_errors(root, &1))
    else
      ["invalid scenario fields"]
    end
  end

  defp row_errors(_, _), do: ["invalid scenario record"]

  @spec evidence_errors(String.t(), term()) :: [String.t()]
  defp evidence_errors(root, e) when is_map(e) do
    valid =
      e["kind"] in ~w(machine property unit manual) and e["execution"] in ~w(present recorded) and
        Enum.all?(~w(path assertion scope), &(is_binary(e[&1]) and String.trim(e[&1]) != ""))

    if valid and local_file?(root, e["path"]) do
      source = File.read!(Path.join(root, e["path"]))

      assertion =
        if String.contains?(source, e["assertion"]),
          do: [],
          else: ["missing test assertion: #{e["path"]}"]

      kind =
        cond do
          e["kind"] == "machine" and
              not String.starts_with?(e["path"], "nix/verification/tests/machines/") ->
            ["machine evidence must reference a NixOS machine test"]

          e["kind"] == "property" and not property_source?(source) ->
            ["property evidence has no property test: #{e["path"]}"]

          true ->
            []
        end

      run =
        if e["execution"] == "recorded" and
             not (local_file?(root, e["record"]) and is_binary(e["record_assertion"]) and
                    String.contains?(
                      File.read!(Path.join(root, e["record"])),
                      e["record_assertion"]
                    )), do: ["recorded execution needs an existing scoped result"], else: []

      assertion ++ kind ++ run
    else
      ["invalid or missing test evidence"]
    end
  end

  defp evidence_errors(_, _), do: ["invalid evidence record"]

  # @cc [owner:ghuntley,label:verification] hldd-hegel-runner-boundary
  # Hegel evidence MUST recognize the exact hegel::test attribute with either no
  # arguments or balanced parenthesized options, including whitespace and nested
  # calls. Macro-name prefixes and incomplete outer delimiters MUST NOT qualify.
  # Explicit Elixir Hegel.check/run callbacks and unqualified property macros,
  # including parenthesized calls, MUST qualify; qualified lookalikes and name
  # prefixes MUST NOT. Lexical recognition MUST NOT imply
  # source validity or recorded/native execution.
  @spec property_source?(String.t()) :: boolean()
  defp property_source?(source) do
    String.contains?(source, ["check all", "proptest!", "@given"]) or
      unqualified_call?(source, ~r/\bproperty(?:\s+|\s*\()/) or
      unqualified_call?(source, ~r/\bHegel\s*\.\s*(?:check|run)\s*\(\s*fn\b/) or
      Regex.match?(
        ~r/#\s*\[\s*hegel\s*::\s*test\s*(?<args>\((?:[^()]|(?&args))*\))?\s*\]/,
        source
      )
  end

  @spec unqualified_call?(String.t(), Regex.t()) :: boolean()
  defp unqualified_call?(source, pattern) do
    pattern
    |> Regex.scan(source, return: :index)
    |> Enum.any?(fn [{offset, _length}] ->
      prefix =
        source
        |> binary_part(0, offset)
        |> then(&Regex.replace(~r/^\s*#[^\n]*$/m, &1, ""))
        |> String.trim_trailing()

      not String.ends_with?(prefix, ".")
    end)
  end

  @spec local_file?(String.t(), term()) :: boolean()
  defp local_file?(root, path) when is_binary(path),
    do:
      Path.type(path) == :relative and
        not Enum.any?(Path.split(path), &(&1 in ["..", "."])) and
        File.regular?(Path.join(root, path))

  defp local_file?(_, _), do: false

  @spec render(map()) :: String.t()
  def render(%{"scenarios" => rows}) do
    "# User scenarios and test gaps\n\n" <>
      "NixOS machine integration tests and property-based tests are the preferred evidence. " <>
      "Unit tests establish narrower behavior. **Present** means a test exists and its assertion was inspected; " <>
      "**recorded** links a historical execution record, not a rerun of the current tree. " <>
      "Partial coverage does not mean the feature is broken. Gaps identify what the evidence cannot establish.\n\n" <>
      Enum.map_join(rows, "\n", fn row ->
        evidence =
          Enum.map_join(row["evidence"], "\n", fn e ->
            record =
              if e["execution"] == "recorded",
                do: "; [execution record](repo:#{e["record"]})",
                else: ""

            "- **#{e["kind"]}, #{e["execution"]}**: [#{e["assertion"]}](repo:#{e["path"]}) — #{e["scope"]}#{record}."
          end)

        "## #{row["journey"]}\n\n" <>
          "Coverage: **#{row["status"]}**. Layers: #{Enum.join(row["layers"], ", ")}.\n\n" <>
          "Boundary: #{row["boundary"]}\n\nRequired refusal: #{row["denial"]}\n\n" <>
          "Tested scope: #{row["scope"]}\n\n#{evidence}\n\n" <>
          "**Gaps:** #{row["gaps"]}\n\n**Preferred test work:** #{row["preferred_gap"]}\n"
      end)
  end

  @spec check(String.t()) :: [String.t()]
  def check(root) do
    data = read(root)

    case validate(root, data) do
      [] ->
        if File.read!(Path.join(root, @output)) == render(data),
          do: [],
          else: ["scenario chapter is stale; regenerate after review"]

      errors ->
        errors
    end
  end
end
