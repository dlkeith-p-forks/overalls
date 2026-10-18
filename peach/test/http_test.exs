defmodule Peach.HTTPTest do
  use ExUnit.Case, async: true
  import Plug.Test

  test "serves a validated reflection snapshot through the public paths" do
    snapshot = %{
      version: 1,
      guest: %{
        "id" => "11111111-1111-4111-8111-111111111111",
        "name" => "guest",
        "profile" => "customer",
        "architecture" => "x86_64",
        "operating_system" => "linux",
        "vcpu" => 2,
        "memory_bytes" => 1,
        "disk_bytes" => 1,
        "image_id" => "image",
        "generation" => 1,
        "state" => "running",
        "owner_email" => "owner@example.invalid",
        "team_name" => nil,
        "node" => %{"id" => "22222222-2222-4222-8222-222222222222", "name" => "node"},
        "labels" => [],
        "comment" => ""
      },
      integrations: []
    }

    assert {:ok, checked} = OverallsProtocol.Reflection.snapshot(Map.put(snapshot, :version, 1) |> stringify_keys())
    assert checked.version == 1
  end

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
