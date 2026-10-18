defmodule Galileo.GitHub.CapabilitiesTest do
  use ExUnit.Case, async: true
  import Kernel, except: [binding: 0]
  import Hegel
  import Hegel.Gen
  alias Galileo.GitHub.Capabilities

  @host "01234567-89ab-4def-8123-456789abcdef"
  @vm "11234567-89ab-4def-8123-456789abcdef"
  @placement "21234567-89ab-4def-8123-456789abcdef"
  @connection "31234567-89ab-4def-8123-456789abcdef"
  @lease "41234567-89ab-4def-8123-456789abcdef"
  @url "https://release-assets.githubusercontent.com/object?sig=synthetic"

  property "transfer histories preserve exact execution and generation custody" do
    commands =
      draw(
        "commands",
        list(
          member_of([
            :read,
            :new_request,
            :wrong_vm,
            :wrong_host,
            :wrong_placement,
            :wrong_epoch,
            :wrong_generation,
            :wrong_connection,
            :wrong_method,
            :anonymous,
            :expire
          ]),
          min: 1,
          max: 30
        )
      )

    {server, child} = server()
    Hegel.on_cleanup(fn -> stop_supervised!(child) end)
    assert {:ok, path} = Capabilities.mint(@url, binding(), lease(), server)
    selector = String.replace_prefix(path, "/capabilities/", "")

    Enum.reduce(commands, true, fn command, active ->
      {binding, lease, method} =
        case command do
          :wrong_vm -> {Map.put(binding(), "vm_id", @host), lease(), "GET"}
          :wrong_host -> {Map.put(binding(), "host_id", @vm), lease(), "GET"}
          :wrong_placement -> {Map.put(binding(), "placement_id", @vm), lease(), "GET"}
          :wrong_epoch -> {Map.put(binding(), "execution_epoch", 2), lease(), "GET"}
          :wrong_generation -> {binding(), %{lease() | generation: 3}, "GET"}
          :wrong_connection -> {binding(), %{lease() | connection_id: @vm}, "GET"}
          :wrong_method -> {binding(), lease(), "PUT"}
          :anonymous -> {binding(), :anonymous, "GET"}
          :new_request -> {binding(), %{lease() | id: @vm}, "HEAD"}
          _ -> {binding(), lease(), "GET"}
        end

      if command == :expire, do: send(server, {:expire, selector})
      result = Capabilities.resolve(selector, binding, lease, method, server)
      granted = active and command in [:read, :new_request]
      assert match?({:ok, _}, result) == granted
      active and command != :expire
    end)
  end

  test "mutation selectors have one winner across concurrent resolves" do
    {server, _} = server()

    transfer = %{
      url: @url,
      headers: [{"authorization", "RemoteAuth synthetic"}],
      method: "PUT",
      object: nil,
      ttl: 60_000
    }

    assert {:ok, path} = Capabilities.mint_transfer(transfer, binding(), lease(), server)
    selector = String.replace_prefix(path, "/capabilities/", "")

    results =
      Task.async_stream(1..16, fn _ ->
        Capabilities.resolve(selector, binding(), lease(), "PUT", server)
      end)
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:error, :unavailable}}, &1)) == 15
  end

  test "idle expiry is scheduled and status excludes held transfer credentials" do
    {server, _} = server()
    :erlang.trace(server, true, [:receive, {:tracer, self()}])

    transfer = %{
      url: @url,
      headers: [{"authorization", "RemoteAuth synthetic"}],
      method: "GET",
      object: nil,
      ttl: 25
    }

    assert {:ok, path} = Capabilities.mint_transfer(transfer, binding(), lease(), server)
    selector = String.replace_prefix(path, "/capabilities/", "")
    status = :sys.get_status(server) |> inspect()
    refute status =~ "synthetic"
    refute status =~ "release-assets"
    assert_receive {:trace, ^server, :receive, {:expire, ^selector}}, 1000
    assert :sys.get_state(server) == %{}

    assert {:error, :unavailable} =
             Capabilities.resolve(selector, binding(), lease(), "GET", server)
  end

  test "invalid binding and credential recipient cannot mint authority" do
    {server, _} = server()

    assert {:error, :unavailable} =
             Capabilities.mint(@url, Map.put(binding(), "owner_id", @host), lease(), server)

    assert {:error, :unavailable} =
             Capabilities.mint("https://attacker.invalid/file?sig=x", binding(), lease(), server)
  end

  @spec server() :: {pid(), reference()}
  defp server do
    id = make_ref()
    {start_supervised!({Capabilities, name: nil}, id: id), id}
  end

  @spec binding() :: map()
  defp binding,
    do: %{
      "host_id" => @host,
      "vm_id" => @vm,
      "placement_id" => @placement,
      "execution_epoch" => 1
    }

  @spec lease() :: OverallsProtocol.GitHub.lease()
  defp lease, do: %{id: @lease, connection_id: @connection, generation: 2}
end
