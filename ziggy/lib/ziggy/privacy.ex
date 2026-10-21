defmodule Ziggy.Privacy do
  @moduledoc "Conservative source-level diagnostic redaction for content-bearing processes."
  @catalog Ziggy.Events.__catalog__()

  @spec install() :: :ok | {:error, :privacy_filter_conflict | :privacy_filter_unavailable}
  def install do
    callback = &__MODULE__.filter/2

    case :logger.add_primary_filter(:ziggy_privacy, {callback, nil}) do
      :ok ->
        :ok

      {:error, {:already_exist, :ziggy_privacy}} ->
        case List.keyfind(:logger.get_primary_config().filters, :ziggy_privacy, 0) do
          {:ziggy_privacy, {^callback, nil}} -> :ok
          _ -> {:error, :privacy_filter_conflict}
        end

      _ ->
        {:error, :privacy_filter_unavailable}
    end
  catch
    _, _ -> {:error, :privacy_filter_unavailable}
  end

  # @cc [owner:ghuntley,label:security] ziggy-logger-content-exclusion
  # Raw diagnostics, process state, metadata and formatter callbacks MUST NOT
  # reach handlers. Events catalogued in Ziggy.Events MUST be reconstructed
  # from the catalog with its fixed message and only validated request
  # identifiers plus closed-atom reasons; every other event reduces to a fixed
  # category and caller-provided message text never survives.
  @spec filter(map(), term()) :: map()
  def filter(%{msg: {:string, _}, meta: %{event: name}} = event, _)
      when is_map_key(@catalog, name) do
    spec = Map.fetch!(@catalog, name)
    selected = Overalls.Diagnostics.Events.Catalog.safe_metadata(spec.metadata, event.meta)

    safe =
      Map.take(event.meta, [:time, :pid, :gl])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(event.meta))

    %{
      event
      | msg: {:string, spec.message},
        meta: safe |> Map.merge(selected) |> Map.put(:event, name) |> Map.put(:domain, [:ziggy])
    }
  end

  def filter(event, _) do
    metadata = Map.get(event, :meta, %{})

    safe =
      metadata
      |> Map.take([:time, :pid, :gl])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(Map.get(event, :meta, %{})))

    identifiers =
      metadata
      |> Map.take([:request_id, :host_id, :vm_id])
      |> Enum.filter(fn {_, id} -> OverallsProtocol.uuid?(id) end)
      |> Map.new()

    category = Overalls.Diagnostics.Privacy.otp_category(Map.get(event, :msg))

    %{
      event
      | msg: {:string, "Ziggy " <> Atom.to_string(category) <> " (payload redacted)"},
        meta:
          Map.merge(safe, identifiers)
          |> Map.put(:event, Overalls.Diagnostics.Privacy.category_event(:ziggy, category))
          |> Map.put(:report_category, category)
    }
  end
end
