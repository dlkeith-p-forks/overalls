defmodule Marshall.Operations.ObanQueuesTest do
  # @cc [owner:ghuntley,label:operations] release-oban-queues-complete
  # The release replaces the compile-time Oban queue list in config/runtime.exs.
  # Every compile-time queue MUST also be served there, or jobs inserted into it
  # (server tools, artifact purges) are durable but never run in production.
  use ExUnit.Case, async: true

  @spec queues(String.t()) :: [atom()]
  defp queues(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:config, _, [:marshall, {:__aliases__, _, [:Oban]}, options]} = node, acc
        when is_list(options) ->
          queues = Keyword.get(options, :queues, [])
          {node, if(is_list(queues), do: acc ++ Keyword.keys(queues), else: acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  test "the release serves every compile-time Oban queue" do
    compile_time = queues("config/config.exs")
    release = queues("config/runtime.exs")

    assert :agent_tools in compile_time and release != []
    assert compile_time -- release == []
  end
end
