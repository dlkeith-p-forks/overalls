defmodule Peach.Privacy do
  @moduledoc "Conservative source-level diagnostic redaction for the reflection service."

  @spec install() :: :ok | {:error, :privacy_filter_conflict | :privacy_filter_unavailable}
  def install do
    Overalls.Diagnostics.Privacy.install(Peach.Events, :peach, filter_id: :peach_privacy)
  end

  # @cc [owner:ghuntley,label:security] peach-logger-content-exclusion
  # Raw diagnostics, process state, metadata and formatter callbacks MUST NOT
  # reach handlers. Only catalogued messages and validated metadata survive;
  # projection contents and credentials never do.
  @spec filter(map(), term()) :: map() | :ignore | :stop
  def filter(event, _) do
    Overalls.Diagnostics.Privacy.filter(
      event,
      Overalls.Diagnostics.Privacy.install_state(Peach.Events, :peach)
    )
  end
end
