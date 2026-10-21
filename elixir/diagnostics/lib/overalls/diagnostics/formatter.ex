defmodule Overalls.Diagnostics.Formatter do
  @moduledoc "Canonical, privacy-preserving JSON formatter for reviewed Logger events."
  @catalog_services %{
    Marshall.Events => :marshall,
    Lilly.Events => :lilly,
    Audi.Events => :audi,
    Brady.Events => :brady,
    Ziggy.Events => :ziggy,
    Porsche.Events => :porsche,
    Enrico.Events => :enrico,
    Galileo.Events => :galileo,
    Susan.Events => :susan,
    Peach.Events => :peach
  }
  @runtime_categories ~w(
    application_exit
    application_started
    metrics
    private_diagnostic
    process_crash
    runtime
    runtime_report
    ssh_runtime
    supervisor_report
    supervisor_started
    task_crash
  )

  @typedoc "The formatter configuration supplied by a Logger handler."
  @type config :: keyword() | %{optional(atom()) => term()}

  @doc "Encode one Logger event in the stable observability envelope."
  @spec format(map(), config()) :: iodata()
  def format(event, config) when is_map(event) and (is_list(config) or is_map(config)) do
    catalog =
      option(config, :catalog) || Application.get_env(:overalls_diagnostics, :events_catalog)

    service = option(config, :service) || service_from_catalog(catalog)
    metadata = Map.get(event, :meta, %{})
    candidate = event_name(metadata, service)
    projection = projection(catalog, candidate)
    runtime? = is_nil(projection) and runtime_event?(candidate, service)
    event_name = if projection || runtime?, do: candidate, else: "runtime.diagnostic"

    envelope = %{
      "schema_version" => 1,
      "timestamp" => timestamp(Map.get(metadata, :time)),
      "level" => level(Map.get(event, :level)),
      "event" => event_name,
      "message" => message(projection, service, event_name),
      "metadata" => metadata(projection, metadata, runtime?)
    }

    [Jason.encode!(envelope), "\n"]
  rescue
    _ -> [Jason.encode!(fallback(event)), "\n"]
  end

  @spec projection(module() | nil, binary()) ::
          Overalls.Diagnostics.Events.Catalog.projection() | nil
  defp projection(catalog, name) when is_atom(catalog) and is_binary(name),
    do: Overalls.Diagnostics.Events.Catalog.projection(catalog, name)

  defp projection(_, _), do: nil

  @spec event_name(map(), atom() | nil) :: binary()
  defp event_name(metadata, _service) do
    case Map.get(metadata, :event) do
      value when is_binary(value) and byte_size(value) <= 128 -> value
      _ -> "runtime.diagnostic"
    end
  end

  @spec message(map() | nil, atom() | nil, binary()) :: binary()
  defp message(%{message: message}, _service, _event_name) when is_binary(message), do: message

  defp message(_, nil, _event_name), do: "runtime diagnostic (payload redacted)"

  defp message(_, service, event_name) when is_atom(service) do
    if event_name == "runtime.diagnostic" do
      Atom.to_string(service) <> " runtime diagnostic (payload redacted)"
    else
      category = event_name |> String.split(".", parts: 2) |> List.last()
      Atom.to_string(service) <> " " <> category <> " (payload redacted)"
    end
  end

  @spec metadata(map() | nil, map(), boolean()) :: map()
  defp metadata(%{metadata: declared}, source, _runtime?) do
    declared
    |> Overalls.Diagnostics.Events.Catalog.safe_metadata(source)
    |> Map.merge(Overalls.Diagnostics.Context.log_context(source))
    |> stringify_keys()
  end

  defp metadata(_, source, _runtime?), do: runtime_metadata(source) |> stringify_keys()

  @spec runtime_event?(binary(), atom() | nil) :: boolean()
  defp runtime_event?(name, service) when is_binary(name) and is_atom(service) do
    service_prefix = Atom.to_string(service)

    case String.split(name, ".", parts: 2) do
      [prefix, category] ->
        (prefix in [service_prefix, "otp"] and category in @runtime_categories) or
          (service == :marshall and prefix == "metrics" and category == "summary")

      _ ->
        false
    end
  end

  defp runtime_event?(_, _), do: false

  @spec runtime_metadata(map()) :: map()
  defp runtime_metadata(source) do
    metadata =
      source
      |> Overalls.Diagnostics.Context.attributes()
      |> Map.merge(Overalls.Diagnostics.Context.log_context(source))

    case Map.get(source, :report_category) do
      category when is_atom(category) ->
        name = Atom.to_string(category)

        if name in @runtime_categories,
          do: Map.put(metadata, :report_category, name),
          else: metadata

      category when is_binary(category) and category in @runtime_categories ->
        Map.put(metadata, :report_category, category)

      _ ->
        metadata
    end
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(values),
    do:
      Map.new(values, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

  @spec timestamp(term()) :: binary() | nil
  defp timestamp(microseconds) when is_integer(microseconds) do
    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, value} -> DateTime.to_iso8601(value)
      _ -> nil
    end
  end

  defp timestamp({mega, seconds, micros})
       when is_integer(mega) and is_integer(seconds) and is_integer(micros) and micros >= 0 and
              micros < 1_000_000 do
    unix_microseconds = (mega * 1_000_000 + seconds) * 1_000_000 + micros

    case DateTime.from_unix(unix_microseconds, :microsecond) do
      {:ok, value} -> DateTime.to_iso8601(value)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  @spec level(term()) :: binary()
  defp level(value)
       when value in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency],
       do: Atom.to_string(value)

  defp level(_), do: "info"

  @spec service_from_catalog(module() | nil) :: atom() | nil
  defp service_from_catalog(catalog) when is_atom(catalog),
    do: Map.get(@catalog_services, catalog)

  defp service_from_catalog(_), do: nil

  @spec option(config(), atom()) :: term()
  defp option(config, key) when is_map(config), do: Map.get(config, key)
  defp option(config, key) when is_list(config), do: Keyword.get(config, key)

  @spec fallback(map()) :: map()
  defp fallback(event) do
    metadata = Map.get(event, :meta, %{})

    %{
      "schema_version" => 1,
      "timestamp" => timestamp(Map.get(metadata, :time)),
      "level" => level(Map.get(event, :level)),
      "event" => "runtime.diagnostic",
      "message" => "runtime diagnostic (payload redacted)",
      "metadata" => metadata |> runtime_metadata() |> stringify_keys()
    }
  end
end
