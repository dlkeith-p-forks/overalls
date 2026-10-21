defmodule Galileo.Privacy do
  @moduledoc "Conservative source-level diagnostic redaction for content-bearing processes."
  @spec install() :: :ok | {:error, :privacy_filter_conflict | :privacy_filter_unavailable}
  def install do
    Overalls.Diagnostics.Privacy.install(Galileo.Events, :galileo, filter_id: :galileo_privacy)
  end

  # @cc [owner:ghuntley,label:security] galileo-logger-content-exclusion
  # Raw diagnostics, process state, metadata and formatter callbacks MUST NOT
  # reach handlers. Only fixed categories and validated request identifiers may
  # survive; caller-provided message text and injected values never survive.
  @spec filter(map(), term()) :: map() | :ignore | :stop
  def filter(event, _) do
    Overalls.Diagnostics.Privacy.filter(
      event,
      Overalls.Diagnostics.Privacy.install_state(Galileo.Events, :galileo)
    )
  end
end
