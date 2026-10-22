defmodule Marshall.Agents.CapabilitiesTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Agents.{Capabilities, Event, Executor, ExecutorSession, ModelProtocol}

  @profiles [:oss, :standard, :inception, :customer, :unknown]
  @tools [
    :exec_command,
    :read_file,
    :spawn_child_agent,
    :web_search,
    :web_fetch,
    :thread,
    :attachment,
    :message_board,
    :artifact
  ]

  # Marshall-owned tools follow the guest tools; Inception has no message board.
  @shared_server [:thread, :attachment, :artifact]
  @server [:thread, :attachment, :message_board, :artifact]

  @spec expected(term()) :: [Capabilities.tool()]

  defp expected(:oss),
    do: [:exec_command, :read_file, :spawn_child_agent, :web_search, :web_fetch] ++ @server

  defp expected(:inception),
    do: [:exec_command, :read_file, :spawn_child_agent, :web_search, :web_fetch] ++ @shared_server

  defp expected(:standard), do: [:exec_command, :read_file, :web_search, :web_fetch] ++ @server

  defp expected(_), do: []

  property "advertised tools and dispatch permission follow the independent profile matrix" do
    profile =
      draw(
        "profile",
        one_of([member_of(@profiles), integer(), string(:printable, max_length: 8)])
      )

    tool = draw("tool", one_of([member_of(@tools), integer(), string(:printable, max_length: 8)]))
    assert Capabilities.tools(profile) == expected(profile)
    assert Capabilities.allowed?(profile, tool) == tool in expected(profile)

    events = [struct(Event, %{kind: :prompt, sequence: 1, body: %{"prompt" => "hello"}})]

    case ModelProtocol.request(events, "gpt-6-sol", profile) do
      {:ok, %{"tools" => schemas} = request} ->
        assert Enum.map(schemas, & &1["name"]) == Enum.map(expected(profile), &Atom.to_string/1)
        assert ModelProtocol.request_tools_allowed?(request, profile)

      {:error, :capability_denied} ->
        assert expected(profile) == []

        assert {:error, :capability_denied} =
                 ModelProtocol.parse_response(
                   %{"choices" => [%{"message" => %{"content" => "hello"}}]},
                   profile
                 )
    end
  end

  test "persisted model tools follow profile policy while internal tools require guest capabilities" do
    tools = Ash.Resource.Info.attribute(Marshall.Agents.Command, :tool).constraints[:one_of]
    internal = [:context_inventory, :context_read, :skill_install, :skill_status, :artifact_stage]
    assert tools != []

    for profile <- [:oss, :standard, :inception], tool <- tools -- internal do
      assert Capabilities.allowed?(profile, tool) == tool in expected(profile)
    end

    for profile <- [:oss, :standard, :inception], tool <- internal do
      refute Capabilities.allowed?(profile, tool)
      refute ExecutorSession.supported?(%Executor{capabilities: []}, tool)

      assert ExecutorSession.supported?(
               %Executor{capabilities: ["context-v1", "skills-v1", "artifacts-v1"]},
               tool
             )
    end

    refute ExecutorSession.supported?(%Executor{capabilities: ["context-v1"]}, :skill_install)
    refute ExecutorSession.supported?(%Executor{capabilities: ["skills-v1"]}, :context_read)
    refute ExecutorSession.supported?(%Executor{capabilities: ["context-v1"]}, :artifact_stage)
  end

  property "any forbidden call rejects a whole generated model response" do
    profile = draw("profile", member_of(@profiles))

    tools =
      draw(
        "tools",
        list_of(
          member_of([:exec_command, :read_file, :spawn_child_agent, :web_search, :web_fetch]),
          min_length: 1,
          max_length: 8
        )
      )

    output =
      tools
      |> Enum.with_index()
      |> Enum.map(fn {tool, index} ->
        arguments =
          case tool do
            :exec_command -> ~s({"cmd":"pwd"})
            :read_file -> ~s({"path":"/etc/hostname"})
            :spawn_child_agent -> ~s({"title":"child","prompt":"work"})
            :web_search -> ~s({"query":"example"})
            :web_fetch -> ~s({"url":"http://127.0.0.1:8080/"})
          end

        %{
          "type" => "function_call",
          "call_id" => "call-#{index}",
          "name" => Atom.to_string(tool),
          "arguments" => arguments
        }
      end)

    result =
      ModelProtocol.parse_response(%{"status" => "completed", "output" => output}, profile)

    if Enum.all?(tools, &(&1 in expected(profile))) do
      assert {:ok, {:tools, calls}} = result
      assert Enum.map(calls, & &1.tool) == tools
    else
      assert {:error, :capability_denied} = result
    end
  end
end
