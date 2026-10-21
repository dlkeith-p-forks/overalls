# @cc [owner:ghuntley,label:verification] logging-structural-gate
# Every application precommit MUST run this structural logging gate. It fails
# closed on direct Logger diagnostics outside reviewed infrastructure, on
# emit calls that bypass the catalog, on mutating modules that emit no
# catalogued events, and on allowlist/catalog key drift. It cannot prove an
# event is semantically sufficient; it only preserves the reviewed surface.
#
# Reminder for agents: emit diagnostic events only through the application's
# Events catalog (add a defevent entry first). Never log credentials,
# authentication tokens, terminal bytes, command arguments or payloads, and
# never pass them as event metadata — the catalog has no string type on
# purpose.

apps = %{
  "marshall" => %{
    catalog: Marshall.Events,
    infra: [
      Marshall.OTPReports,
      Marshall.Observability,
      Marshall.Mailer.LogFilter,
      Marshall.Operations.Privacy,
      MarshallWeb.TerminalLogFilter,
      Marshall.Events
    ],
    # Reviewed exemptions (each with reason; MUST be re-reviewed if the module
    # gains security-significant outcomes not covered elsewhere):
    # - ingress/token.ex + ssh/token.ex + editor/token.ex: stateless token minters;
    #   Editor.Authority emits its security-significant outcomes after outer commit;
    #   logging from the nested generator would announce uncommitted authority.
    #   For all three minters, logging there would be
    #   secret-adjacent spam. Denials are emitted by the API/domain layers.
    # - operations/ssh_gateway.ex: operator CLI wrapper; outcomes are emitted
    #   domain-side by SSH.Authority (no double logging).
    exempt_from_logging_rule: [
      "lib/marshall/ingress/token.ex",
      "lib/marshall/ssh/token.ex",
      "lib/marshall/editor/token.ex",
      "lib/marshall/operations/ssh_gateway.ex"
    ],
    # Reviewed: workflow measurement admission has no execution/authorization
    # outcome. SSH.Commands emits admission outcomes after outer commit;
    # ServiceLevelPublisher emits catalogued publication failures. Emitting in
    # this nested accounting transaction would report rolled-back admissions.
    exempt_from_mutation_rule: [
      "lib/marshall/compute/workflow_service_levels.ex",
      # Editor.Releases.approved?/2 is a pure registry membership predicate;
      # it has no security-significant side effect to announce.
      "lib/marshall/editor/releases.ex"
    ]
  },
  "lilly" => %{
    catalog: Lilly.Events,
    infra: [Lilly.OTPReports, Lilly.Observability, Lilly.Events],
    exempt_from_logging_rule: [],
    # Reviewed: checkpoint completion/revocation use Lifecycle.Journal's
    # post-durable-write transition events; Command emits native-effect events,
    # and the execution journal publishes the confirmed outer VM outcome.
    # Local emits would duplicate those events inside an unfinished operation.
    exempt_from_mutation_rule: [
      "lib/lilly/vm/checkpoint.ex",
      "lib/lilly/vm/checkpoint_storage.ex"
    ]
  },
  "audi" => %{
    catalog: Audi.Events,
    infra: [Audi.OTPReports, Audi.Privacy, Audi.Events],
    exempt_from_mutation_rule: []
  },
  "brady" => %{
    catalog: Brady.Events,
    infra: [Brady.Log, Brady.Events],
    allowlist_check: false,
    exempt_from_mutation_rule: ["lib/brady/cache/policy.ex"]
  },
  "ziggy" => %{
    catalog: Ziggy.Events,
    infra: [Ziggy.Privacy, Ziggy.Events],
    exempt_from_mutation_rule: []
  },
  "galileo" => %{
    catalog: Galileo.Events,
    infra: [Galileo.Privacy, Galileo.Events],
    exempt_from_mutation_rule: []
  },
  "enrico" => %{
    catalog: Enrico.Events,
    infra: [Enrico.Privacy, Enrico.Events],
    exempt_from_mutation_rule: []
  },
  "peach" => %{
    catalog: Peach.Events,
    infra: [Peach.Privacy, Peach.Events],
    exempt_from_mutation_rule: []
  },
  "susan" => %{
    catalog: Susan.Events,
    infra: [Susan.Privacy, Susan.Events],
    exempt_from_mutation_rule: []
  },
  "porsche" => %{
    catalog: Porsche.Events,
    infra: [
      Porsche.OTPReports,
      Porsche.Privacy,
      Porsche.Observability,
      Porsche.Events
    ],
    exempt_from_mutation_rule: []
  }
}

app_dir =
  case System.argv() do
    [maybe_dir | _] when is_binary(maybe_dir) ->
      if File.dir?(maybe_dir), do: maybe_dir, else: "."

    _ ->
      "."
  end

app_dir = String.trim_trailing(app_dir, "/")
app = app_dir |> Path.expand() |> Path.basename()
config = Map.fetch!(apps, app)
app_prefix = if app_dir == ".", do: "", else: app_dir <> "/"

defmodule LogCheck do
  @moduledoc false

  @mutation_verbs ~r/^(rotate|revoke|issue|retire|disable|approve|admit|complete|materialize|destroy|delete|cancel|publish|reset|purge|rescind)/

  @infra_keys [:event, :request_id, :report_category, :application, :domain, :trace_id, :span_id]

  def infra_keys, do: @infra_keys

  def files(dir) do
    Path.wildcard(Path.join(dir, "**/*.{ex,exs}"))
  end

  def parse(path) do
    case Code.string_to_quoted(File.read!(path), file: path) do
      {:ok, ast} -> ast
      {:error, _} -> raise "could not parse #{path}"
    end
  end

  def modules(ast) do
    {_, mods} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(mods)
  end

  def catalog_files(dir, catalog_module) do
    files(dir)
    |> Enum.filter(fn path ->
      try do
        parse(path) |> modules() |> Enum.any?(&(&1 == catalog_module))
      rescue
        _ -> false
      end
    end)
  end

  def read_catalog(dir, catalog_module) do
    path = catalog_files(dir, catalog_module) |> List.first()
    path = path || raise "catalog module #{inspect(catalog_module)} not found under lib/"

    ast = parse(path)

    {_, entries} =
      Macro.prewalk(ast, [], fn
        {:defevent, _, [event, opts]} = node, acc when is_binary(event) ->
          keys =
            opts
            |> Keyword.get(:metadata, [])
            |> Enum.map(fn
              {key, {{:enum, values}, :optional}} when is_list(values) ->
                {key, {:enum, values}, true}

              {key, {:enum, values}} when is_list(values) ->
                {key, {:enum, values}, false}

              {key, {type, :optional}} when is_atom(type) ->
                {key, type, true}

              {key, type} when is_atom(type) ->
                {key, type, false}
            end)

          {node, [%{event: event, keys: keys} | acc]}

        node, acc ->
          {node, acc}
      end)

    {path, entries}
  end

  def logger_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Logger]}, fun]}, _, _args} = node, acc
        when fun in [:debug, :info, :notice, :warning, :error, :critical, :emergency, :log] ->
          {node, [fun | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  def emit_calls(ast, catalog_module) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, :emit]}, _, [event, meta]} = node, acc
        when is_binary(event) and is_list(meta) ->
          if Module.concat(parts) == catalog_module do
            {node, [event_meta(event, meta) | acc]}
          else
            {node, acc}
          end

        {:emit, _, [event, meta]} = node, acc when is_binary(event) and is_list(meta) ->
          {node, [event_meta(event, meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp event_meta(event, meta), do: {event, meta}

  def mutating_defs(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{name, _, _} | _]} = node, acc when is_atom(name) ->
          if Regex.match?(@mutation_verbs, Atom.to_string(name)) do
            {node, [name | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  def find_metadata_list(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:config, _, [:logger, :default_handler, value]} = node, _acc
        when is_list(value) ->
          metadata =
            case Keyword.get(value, :formatter) do
              {{:__aliases__, _, [:LoggerJSON, :Formatters, :Basic]}, opts} when is_list(opts) ->
                Keyword.get(opts, :metadata)

              {{:__aliases__, _, [:Overalls, :Diagnostics, :Formatter]}, _opts} ->
                :shared_catalog_formatter

              _ ->
                nil
            end

          {node, metadata}

        node, acc ->
          {node, acc}
      end)

    found
  end
end

alias LogCheck, as: C

{catalog_path, entries} = C.read_catalog(Path.join(app_dir, "lib"), config.catalog)
catalog = Map.new(entries, &{&1.event, &1})

catalog_keys =
  catalog
  |> Map.values()
  |> Enum.flat_map(& &1.keys)
  |> Enum.map(fn {k, _t, _o} -> k end)
  |> Enum.uniq()

violations =
  (C.files(Path.join(app_dir, "lib")) ++ C.files(Path.join(app_dir, "config")))
  |> Enum.flat_map(fn path ->
    relative = String.replace_prefix(path, app_prefix, "")
    ast = C.parse(path)
    mods = C.modules(ast)
    infra? = Enum.any?(mods, &(&1 in config.infra))
    exempt? = relative in Map.get(config, :exempt_from_logging_rule, [])
    emits = C.emit_calls(ast, config.catalog)
    logger = C.logger_calls(ast)

    v1 =
      if infra? or exempt? do
        []
      else
        Enum.map(logger, fn fun ->
          "#{path}: direct Logger.#{fun} outside reviewed infrastructure — " <>
            "emit through #{inspect(config.catalog)} instead " <>
            "(add a defevent to #{Path.relative_to(catalog_path, File.cwd!())})"
        end)
      end

    v2 =
      Enum.flat_map(emits, fn {event, meta} ->
        case Map.fetch(catalog, event) do
          :error ->
            ["#{path}: emit of unknown event #{inspect(event)}"]

          {:ok, entry} ->
            declared = MapSet.new(entry.keys, &elem(&1, 0))
            unknown = meta |> Keyword.keys() |> Enum.reject(&(&1 in declared))

            if unknown == [] do
              []
            else
              ["#{path}: event #{inspect(event)} received undeclared keys #{inspect(unknown)}"]
            end
        end
      end)

    v3 =
      if infra? or exempt? or relative in config.exempt_from_mutation_rule or emits != [] or
           logger != [] do
        []
      else
        mutations = C.mutating_defs(ast)

        if mutations == [] do
          []
        else
          [
            "#{path}: defines mutating functions (#{Enum.map_join(mutations, ", ", &"#{&1}")}) " <>
              "but emits no catalogued event — add #{inspect(config.catalog)}.emit/2 for the " <>
              "security-significant outcome, or add a reviewed exemption in scripts/check_logging.exs"
          ]
        end
      end

    v1 ++ v2 ++ v3
  end)

allowlist_violations =
  if config[:allowlist_check] == false do
    []
  else
    config_path = Path.join(app_dir, "config/config.exs")

    case C.find_metadata_list(C.parse(config_path)) do
      :shared_catalog_formatter ->
        []

      allowlist when is_list(allowlist) ->
        missing = catalog_keys |> Enum.reject(&(&1 in allowlist or &1 in C.infra_keys()))
        stale = allowlist |> Enum.reject(&(&1 in catalog_keys or &1 in C.infra_keys()))

        Enum.map(missing, fn key ->
          "#{config_path}: catalogued metadata key #{inspect(key)} is missing from the logger " <>
            "allowlist and would be dropped by the formatter"
        end) ++
          Enum.map(stale, fn key ->
            "#{config_path}: allowlist key #{inspect(key)} is not used by any catalogued event — " <>
              "remove it or add an event that uses it"
          end)

      _ ->
        ["#{config_path}: could not find reviewed Logger formatter configuration"]
    end
  end

violations = violations ++ allowlist_violations

if violations != [] do
  raise """

  logging.check failed for #{app} (#{length(violations)} violations):

  #{Enum.join(Enum.sort(violations), "\n")}

  Reminders:
  - Diagnostic events MUST go through the application Events catalog
    (defevent first, then emit with catalogued metadata keys).
  - Credentials, authentication tokens, terminal bytes, command arguments
    and payloads MUST NEVER appear in events or messages.
  """
else
  IO.puts("logging.check: #{app} OK (#{map_size(catalog)} catalogued events)")
end
