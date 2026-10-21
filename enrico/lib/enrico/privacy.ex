defmodule Enrico.Privacy do
  @moduledoc "Discard all uncatalogued runtime diagnostic content."
  @spec install() :: :ok | {:error, :privacy_filter_conflict | :privacy_filter_unavailable}
  def install do
    Overalls.Diagnostics.Privacy.install(Enrico.Events, :enrico, filter_id: :enrico_privacy)
  end

  @spec filter(map(), term()) :: map() | :ignore | :stop
  def filter(event, _) do
    Overalls.Diagnostics.Privacy.filter(
      event,
      Overalls.Diagnostics.Privacy.install_state(Enrico.Events, :enrico)
    )
  end
end
