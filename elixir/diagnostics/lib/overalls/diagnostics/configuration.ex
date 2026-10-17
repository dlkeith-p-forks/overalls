defmodule Overalls.Diagnostics.Configuration do
  @moduledoc "Configuration queries for the diagnostics runtime."

  @doc "Returns whether the configured local trace socket can be attempted."
  @spec configured?() :: boolean()
  def configured?, do: System.get_env("OVERALLS_TRACE_SOCKET") != nil
end
