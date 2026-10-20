Code.require_file("documents.ex", __DIR__)

defmodule Overalls.HLDDViews do
  @moduledoc "Source-derived Ash ownership and allowlisted NixOS placement views."
  @type domain :: %{name: String.t(), source: String.t(), resources: [String.t()]}
  @type host :: %{
          name: String.t(),
          enrolled: boolean(),
          services: [String.t()],
          marshall_instances: [String.t()],
          fleet_address: String.t() | nil,
          fleet_peers: [String.t()],
          admin_ssh_ports: [1..65_535]
        }
  @directory "marshall/priv/hldd"
  @snapshot "topology"
  @domain_chapter "21-domains.md"
  @topology_chapter "22-topology.md"

  # @cc [owner:ghuntley,label:verification] hldd-ash-source-inventory
  # Every literal Ash.Domain and its declared resource set MUST enter the view.
  # Parse repository source without evaluating application code. Unsupported
  # dynamic declarations MUST fail rather than silently omit ownership.
  @spec domains(String.t(), [String.t()]) :: [domain()]
  def domains(root, paths) do
    paths
    |> Enum.filter(&Regex.match?(~r{^[^/]+/lib/.*\.ex$}, &1))
    |> Enum.flat_map(fn path ->
      ast = root |> Path.join(path) |> File.read!() |> Code.string_to_quoted!(file: path)

      {_ast, found} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [name, [do: body]]} = node, found ->
            if Enum.any?(expressions(body), &domain_use?/1) do
              resources =
                expressions(body)
                |> Enum.flat_map(fn
                  {:resources, _, [[do: declarations]]} ->
                    Enum.map(expressions(declarations), fn
                      {:resource, _, [module | _]} -> module_name!(module)
                      _ -> raise("#{path}: unsupported dynamic Ash resource declaration")
                    end)

                  _ ->
                    []
                end)
                |> Enum.uniq()
                |> Enum.sort()

              if resources == [], do: raise("#{path}: Ash domain has no literal resources")
              domain = %{name: module_name!(name), source: path, resources: resources}
              {node, [domain | found]}
            else
              {node, found}
            end

          node, found ->
            {node, found}
        end)

      found
    end)
    |> Enum.sort_by(& &1.name)
  end

  @spec expressions(Macro.t()) :: [Macro.t()]
  defp expressions({:__block__, _, items}), do: items
  defp expressions(item), do: [item]

  @spec domain_use?(Macro.t()) :: boolean()
  defp domain_use?({:use, _, [{:__aliases__, _, [:Ash, :Domain]} | _]}), do: true
  defp domain_use?(_), do: false

  @spec module_name!(Macro.t()) :: String.t()
  defp module_name!({:__aliases__, _, parts}) do
    unless Enum.all?(
             parts,
             &(is_atom(&1) and Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, Atom.to_string(&1)))
           ),
           do: raise("expected a literal module name")

    Enum.join(parts, ".")
  end

  defp module_name!(_), do: raise("expected a literal module name")

  @spec hosts(String.t()) :: [host()]
  def hosts(json) do
    rows = JSON.decode!(json)
    unless is_list(rows) and rows != [], do: raise("expected a nonempty topology inventory")

    hosts =
      Enum.map(rows, fn row ->
        keys = ~w(name enrolled services marshallInstances fleetAddress fleetPeers adminSshPorts)

        unless is_map(row) and Enum.sort(Map.keys(row)) == Enum.sort(keys),
          do: raise("invalid topology fields; only the public projection is allowed")

        unless identifier?(row["name"]) and is_boolean(row["enrolled"]) and
                 identifiers?(row["services"]) and identifiers?(row["marshallInstances"]) and
                 identifiers?(row["fleetPeers"]) and
                 (is_nil(row["fleetAddress"]) or
                    (is_binary(row["fleetAddress"]) and
                       Regex.match?(~r/^[0-9a-fA-F.:]+$/, row["fleetAddress"]))) and
                 is_list(row["adminSshPorts"]) and
                 Enum.all?(row["adminSshPorts"], &(is_integer(&1) and &1 in 1..65_535)),
               do: raise("invalid public topology values")

        %{
          name: row["name"],
          enrolled: row["enrolled"],
          services: Enum.sort(row["services"]),
          marshall_instances: Enum.sort(row["marshallInstances"]),
          fleet_address: row["fleetAddress"],
          fleet_peers: Enum.sort(row["fleetPeers"]),
          admin_ssh_ports: Enum.sort(row["adminSshPorts"])
        }
      end)

    unless length(hosts) == length(Enum.uniq_by(hosts, & &1.name)),
      do: raise("duplicate topology host")

    Enum.sort_by(hosts, & &1.name)
  end

  @spec identifier?(term()) :: boolean()
  defp identifier?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9-]*$/, value)

  @spec identifiers?(term()) :: boolean()
  defp identifiers?(values),
    do: is_list(values) and Enum.all?(values, &identifier?/1) and Enum.uniq(values) == values

  @spec domain_view([domain()]) :: String.t()
  def domain_view(domains) do
    diagrams =
      domains
      |> Enum.group_by(&(String.split(&1.name, ".") |> hd()))
      |> Enum.sort()
      |> Enum.map_join("\n", fn {application, owned} ->
        nodes =
          Enum.with_index(owned, fn domain, index -> "  app --> d#{index}[\"#{domain.name}\"]" end)

        "```mermaid\nflowchart LR\n  app[\"#{application} application\"]\n#{Enum.join(nodes, "\n")}\n```\n"
      end)

    rows =
      Enum.map_join(domains, "\n", fn domain ->
        resources = Enum.map_join(domain.resources, ", ", &"`#{&1}`")
        "| [`#{domain.name}`](repo:#{domain.source}) | #{resources} |"
      end)

    "## Declared ownership\n\nArrows mean application ownership, not calls or deployment units. " <>
      "Resources below are literal declarations, deduplicated; extension-generated versions are excluded.\n\n" <>
      diagrams <> "\n| Ash domain | Declared resources |\n| --- | --- |\n" <> rows <> "\n"
  end

  @spec topology_view([host()]) :: String.t()
  def topology_view(hosts) do
    Enum.map_join(hosts, "\n", fn host ->
      nodes =
        Enum.with_index(host.services, fn service, index ->
          "  host --> s#{index}[\"#{service}\"]"
        end)

      "### #{host.name}\n\n" <>
        "```mermaid\nflowchart LR\n  host[\"#{host.name}\"]\n#{Enum.join(nodes, "\n")}\n```\n\n" <>
        "Arrows mean configured service placement. Configuration: `#{host.name}#{if host.enrolled, do: "", else: "-base"}`. " <>
        "Marshall instances: #{items(host.marshall_instances)}. Fleet address: `#{host.fleet_address || "disabled"}`. " <>
        "Fleet peers: #{items(host.fleet_peers)}. Administrative SSH ports: #{Enum.join(host.admin_ssh_ports, ", ")}.\n"
    end)
  end

  @spec items([String.t()]) :: String.t()
  defp items([]), do: "none"
  defp items(items), do: Enum.map_join(items, ", ", &"`#{&1}`")

  @spec block(String.t()) :: String.t()
  defp block(body), do: "<!-- hldd:view:start -->\n" <> body <> "<!-- hldd:view:end -->"

  @spec replace(String.t(), String.t()) :: String.t()
  defp replace(markdown, body) do
    pattern = ~r/<!-- hldd:view:start -->.*?<!-- hldd:view:end -->/s

    unless length(Regex.scan(pattern, markdown)) == 1,
      do: raise("expected exactly one generated view block")

    Regex.replace(pattern, markdown, fn _ -> block(body) end)
  end

  # @cc [owner:ghuntley,label:verification] hldd-required-visual-views
  # Refreshed review receipts MUST NOT bypass missing or stale views, omitted
  # domain/host explanations, or missing authority and verification prose.
  # A supplied evaluated topology MUST equal the recorded public projection.
  @spec check(String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def check(root, paths, evaluated \\ nil) do
    if File.exists?(chapter_path(root, "deployment-topology.json")),
      do: raise("legacy deployment-topology.json exists; regenerate topology YAML instead")

    domains = domains(root, paths)
    if domains == [], do: raise("missing Ash domain declarations")

    hosts =
      root
      |> chapter_path(@snapshot)
      |> Overalls.HLDDDocuments.collection("name")
      |> JSON.encode!()
      |> hosts()

    expected_hosts =
      paths
      |> Enum.filter(&Regex.match?(~r{^fleet/hosts/[^/]+/host\.json$}, &1))
      |> Enum.map(&(Path.dirname(&1) |> Path.basename()))
      |> Enum.sort()

    if Enum.map(hosts, & &1.name) != expected_hosts, do: raise("topology host inventory is stale")

    if evaluated != nil and hosts(evaluated) != hosts,
      do: raise("evaluated deployment topology is stale")

    check_chapter(root, @domain_chapter, domain_view(domains), Enum.map(domains, & &1.name)) ++
      check_chapter(root, @topology_chapter, topology_view(hosts), Enum.map(hosts, & &1.name))
  rescue
    e in [ArgumentError, RuntimeError, File.Error, SyntaxError, TokenMissingError] ->
      [Exception.message(e)]
  end

  @spec check_chapter(String.t(), String.t(), String.t(), [String.t()]) :: [String.t()]
  defp check_chapter(root, chapter, body, names) do
    markdown = File.read!(chapter_path(root, chapter))

    generated_errors =
      if replace(markdown, body) == markdown,
        do: [],
        else: ["#{chapter}: generated visual inventory is stale"]

    prose = Regex.replace(~r/<!-- hldd:view:start -->.*?<!-- hldd:view:end -->/s, markdown, "")

    explanations =
      Enum.flat_map(names, fn name ->
        row = ~r/^\| `#{Regex.escape(name)}` \| ([^\n]+) \|$/m

        case Regex.run(row, prose) do
          [_, text] when byte_size(text) >= 60 -> []
          _ -> ["#{chapter}: missing responsibility/boundary explanation for #{name}"]
        end
      end)

    sections =
      Enum.flat_map(["Authority and interactions", "Verification and gaps"], fn title ->
        pattern = ~r/^## #{title}\n(.*?)(?=^## |\z)/ms

        case Regex.run(pattern, prose) do
          [_, text] ->
            plain = Regex.replace(~r/```.*?```/s, text, "") |> String.trim()

            if String.length(plain) >= 100 and String.contains?(plain, "](repo:"),
              do: [],
              else: ["#{chapter}: explain #{title} with source evidence"]

          _ ->
            ["#{chapter}: missing #{title}"]
        end
      end)

    diagrams =
      if Regex.match?(~r/```mermaid\n.+?\n```/s, prose),
        do: [],
        else: ["#{chapter}: missing interaction diagram"]

    generated_errors ++ explanations ++ sections ++ diagrams
  end

  @spec write(String.t(), [String.t()], String.t()) :: :ok
  def write(root, paths, json) do
    hosts = hosts(json)
    domains = domains(root, paths)

    for {chapter, body} <- [
          {@domain_chapter, domain_view(domains)},
          {@topology_chapter, topology_view(hosts)}
        ] do
      path = chapter_path(root, chapter)
      File.write!(path, replace(File.read!(path), body))
    end

    directory = chapter_path(root, @snapshot)

    entries =
      Enum.map(JSON.decode!(json), fn host ->
        unless is_binary(host["name"]) and Regex.match?(~r/^[a-z][a-z0-9-]*$/, host["name"]),
          do: raise("invalid topology host name")

        %{"path" => Path.join(directory, host["name"] <> ".yaml"), "data" => host}
      end)

    Overalls.HLDDDocuments.write(entries)
    retained = Enum.map(entries, & &1["path"])

    for path <- Overalls.HLDDDocuments.paths(directory, ".yaml"),
        path not in retained,
        do: File.rm!(path)

    :ok
  end

  @spec chapter_path(String.t(), String.t()) :: String.t()
  defp chapter_path(root, chapter), do: Path.join([root, @directory, chapter])
end
