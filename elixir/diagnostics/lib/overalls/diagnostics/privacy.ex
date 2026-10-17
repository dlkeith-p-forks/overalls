defmodule Overalls.Diagnostics.Privacy do
  @moduledoc "Shared Logger primary filter for catalogued events and OTP diagnostics."

  @typedoc "Configuration captured by a logger filter callback."
  @type state :: %{catalog: module(), service: atom(), filter_id: atom()}

  @safe_metadata [:time, :pid, :gl]
  @filter_ids %{
    marshall: :marshall_observability_privacy,
    lilly: :lilly_observability_privacy,
    audi: :audi_observability_privacy,
    brady: :brady_observability_privacy,
    ziggy: :ziggy_observability_privacy,
    porsche: :porsche_observability_privacy,
    enrico: :enrico_observability_privacy,
    galileo: :galileo_observability_privacy
  }

  @doc "Install a source privacy filter for an application's reviewed catalog."
  @spec install(module(), atom(), keyword()) :: :ok
  def install(catalog, service, opts \\ []) when is_atom(catalog) and is_atom(service) do
    filter_id =
      Keyword.get(opts, :filter_id, Map.get(@filter_ids, service, :overalls_diagnostics_privacy))

    state = %{catalog: catalog, service: service, filter_id: filter_id}

    case :logger.add_primary_filter(filter_id, {&__MODULE__.filter/2, state}) do
      :ok -> :ok
      {:error, {:already_exist, ^filter_id}} -> :ok
      _ -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] shared-privacy-source-redaction
  # Logger events MUST be reduced to fixed catalog messages, reviewed metadata,
  # and finite OTP categories before handlers inspect them. Source text,
  # reports, process state and unreviewed values MUST be discarded.
  @doc "Reduce an OTP Logger event to a fixed category and reviewed metadata."
  @spec filter(map(), state() | term()) :: map() | :ignore | :stop
  def filter(event, %{catalog: catalog, service: service}) when is_map(event) do
    metadata = Map.get(event, :meta, %{})

    cond do
      trace_only?(metadata, catalog) ->
        :stop

      catalogued?(metadata, catalog) ->
        catalogued_event(event, metadata, catalog)

      supervisor_progress?(event) ->
        :stop

      otp_report?(event) ->
        runtime_event(event, metadata, service, otp_category(Map.get(event, :msg)), catalog)

      formatted?(event) ->
        runtime_event(event, metadata, service, :runtime_report, catalog)

      Map.get(metadata, :observability_private, false) ->
        runtime_event(event, metadata, service, :private_diagnostic, catalog)

      private_tag?(metadata, service) ->
        runtime_event(event, metadata, service, :private_diagnostic, catalog)

      ssh_domain?(metadata) ->
        runtime_event(event, metadata, service, :ssh_runtime, catalog)

      true ->
        runtime_event(event, metadata, service, :runtime_report, catalog)
    end
  end

  def filter(_, _), do: :ignore

  @doc "Translate an OTP report label to the finite runtime category vocabulary."
  @spec otp_category(term()) :: atom()
  def otp_category({:report, %{label: label}}), do: category_label(label)
  def otp_category(%{label: label}), do: category_label(label)
  def otp_category(_), do: :runtime_report

  @spec category_event(atom(), atom()) :: binary()
  def category_event(service, category),
    do: Atom.to_string(service) <> "." <> Atom.to_string(category)

  @spec sanitize_metadata(keyword() | map(), map()) :: map()
  def sanitize_metadata(declared, metadata) when is_list(declared) and is_map(metadata),
    do: Overalls.Diagnostics.Events.Catalog.safe_metadata(declared, metadata)

  @spec install_state(module(), atom()) :: state()
  def install_state(catalog, service),
    do: %{catalog: catalog, service: service, filter_id: :overalls_diagnostics_privacy}

  defp catalogued?(metadata, catalog) do
    name = Map.get(metadata, :event)
    is_binary(name) and Overalls.Diagnostics.Events.Catalog.projection(catalog, name) != nil
  end

  defp trace_only?(metadata, catalog) do
    case Map.get(metadata, :event) do
      name when is_binary(name) ->
        match?(%{log?: false}, Overalls.Diagnostics.Events.Catalog.projection(catalog, name))

      _ ->
        false
    end
  end

  defp catalogued_event(event, metadata, catalog) do
    name = Map.fetch!(metadata, :event)
    spec = Overalls.Diagnostics.Events.Catalog.projection(catalog, name)
    selected = sanitize_metadata(spec.metadata, metadata)

    Map.merge(event, %{
      msg: {:string, spec.message},
      meta: safe_metadata(metadata, selected, name, nil)
    })
  end

  defp runtime_event(event, metadata, service, category, catalog) do
    name = category_event(service, category)

    message =
      case Overalls.Diagnostics.Events.Catalog.projection(catalog, name) do
        %{message: fixed} when is_binary(fixed) ->
          fixed

        _ ->
          String.capitalize(Atom.to_string(service)) <>
            " " <> Atom.to_string(category) <> " (payload redacted)"
      end

    Map.merge(event, %{
      msg: {:string, message},
      meta: safe_metadata(metadata, %{}, name, category)
    })
  end

  defp safe_metadata(metadata, selected, name, category) do
    metadata
    |> Map.take(@safe_metadata)
    |> Map.merge(Overalls.Diagnostics.Context.log_context(metadata))
    |> Map.merge(selected)
    |> Map.put(:event, name)
    |> maybe_put(:report_category, category)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp supervisor_progress?(%{msg: {:report, %{label: {:supervisor, :progress}}}}), do: true
  defp supervisor_progress?(_), do: false

  defp otp_report?(%{msg: {:report, _}}), do: true
  defp otp_report?(_), do: false

  defp formatted?(%{msg: {format, _}}) when is_list(format) or is_binary(format), do: true
  defp formatted?(_), do: false

  defp ssh_domain?(metadata),
    do: Map.get(metadata, :domain) in [[:otp, :ssh], [:otp, :ssh, :connection]]

  defp private_tag?(metadata, :audi), do: Map.get(metadata, :audi_private, false)
  defp private_tag?(metadata, :brady), do: Map.get(metadata, :brady_private, false)
  defp private_tag?(metadata, :galileo), do: Map.get(metadata, :galileo_private, false)
  defp private_tag?(metadata, :enrico), do: Map.get(metadata, :enrico_private, false)
  defp private_tag?(metadata, :lilly), do: Map.get(metadata, :lilly_private, false)
  defp private_tag?(metadata, :marshall), do: Map.get(metadata, :marshall_private, false)
  defp private_tag?(metadata, :porsche), do: Map.get(metadata, :porsche_private, false)
  defp private_tag?(metadata, :ziggy), do: Map.get(metadata, :ziggy_private, false)
  defp private_tag?(_, _), do: false

  defp category_label({:gen_server, :terminate}), do: :process_crash
  defp category_label({:gen_statem, :terminate}), do: :process_crash
  defp category_label({:proc_lib, :crash}), do: :process_crash
  defp category_label({Task.Supervisor, :terminating}), do: :process_crash
  defp category_label({:supervisor, :progress}), do: :supervisor_started
  defp category_label({:supervisor, _}), do: :supervisor_report
  defp category_label(_), do: :runtime_report
end
