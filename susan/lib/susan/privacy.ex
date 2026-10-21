defmodule Susan.Privacy do
  @moduledoc "Source-level redaction through the shared reviewed diagnostics filter."

  @spec install() :: :ok
  def install,
    do: Overalls.Diagnostics.Privacy.install(Susan.Events, :susan, filter_id: :susan_privacy)

  # @cc [owner:ghuntley,label:security] susan-logger-content-exclusion
  # Raw diagnostics, process state and arbitrary metadata MUST NOT reach handlers.
  # Only reviewed event fields and fixed runtime categories may survive.
  @spec filter(map(), term()) :: map() | :stop | :ignore
  def filter(event, _),
    do:
      Overalls.Diagnostics.Privacy.filter(
        event,
        Overalls.Diagnostics.Privacy.install_state(Susan.Events, :susan)
      )
end
