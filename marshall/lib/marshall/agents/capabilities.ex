defmodule Marshall.Agents.Capabilities do
  @moduledoc "Closed agent tool policy derived from the VM's persisted profile."

  @type profile :: :oss | :standard | :inception | :customer
  @type tool ::
          :exec_command | :read_file | :spawn_child_agent | :web_search | :web_fetch | :thread

  @all_tools [:exec_command, :read_file, :spawn_child_agent, :web_search, :web_fetch, :thread]
  @standard_tools [:exec_command, :read_file, :web_search, :web_fetch, :thread]

  # @cc [owner:ghuntley,label:security] agent-profile-tool-policy
  # The persisted VM profile alone selects model tools. Unknown profiles and
  # tools MUST fail closed; model output and guest claims never grant authority.
  @spec tools(term()) :: [tool()]
  def tools(profile) when profile in [:oss, :inception], do: @all_tools
  def tools(:standard), do: @standard_tools
  def tools(_), do: []

  @spec allowed?(term(), term()) :: boolean()
  def allowed?(profile, tool), do: tool in tools(profile)
end
