Code.require_file("observation.ex", __DIR__)
ExUnit.start()

defmodule Lilly.CloneObservationFixtureTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Lilly.CloneObservationFixture, as: Fixture
  @moduletag :tmp_dir
  @placement "11111111-1111-4111-8111-111111111111"

  test "exact and empty bindings reach one unchanged callback and are removed", %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    File.write!(Path.join(root, "armed"), "")
    name = "zroot/lilly/vm-#{@placement}@lilly-b"
    parent = self()

    for snapshots <- [%{}, %{name => %{dataset_guid: "123", snapshot_guid: "456"}}] do
      assert {:error, :storage_busy} ==
               Fixture.capture(root, 123, @placement, snapshots, fn ->
                 path = Path.join(root, "context-123.json")
                 assert band(File.stat!(path).mode, 0o777) == 0o600
                 assert File.stat!(path).size <= 4096

                 assert JSON.decode!(File.read!(path)) ==
                          JSON.decode!(
                            JSON.encode!(%{placement_id: @placement, snapshots: snapshots})
                          )

                 send(parent, :once)
                 {:error, :storage_busy}
               end)

      assert_received :once
      refute_received :once
      refute File.exists?(Path.join(root, "context-123.json"))
      refute File.exists?(Path.join(root, "context-123.json.tmp"))
    end
  end

  test "callback exceptions survive context cleanup", %{tmp_dir: root} do
    File.write!(Path.join(root, "armed"), "")

    assert catch_throw(Fixture.capture(root, 123, @placement, %{}, fn -> throw(:original) end)) ==
             :original

    refute File.exists?(Path.join(root, "context-123.json"))
  end

  test "invalid projection and unavailable storage cannot change callback result", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "armed"), "")

    for {directory, placement, snapshots} <- [
          {root, nil, %{}},
          {root, @placement, %{"foreign" => %{dataset_guid: "123", snapshot_guid: "456"}}},
          {root, @placement,
           %{
             "zroot/lilly/vm-#{@placement}@lilly-b" => %{
               dataset_guid: "bad",
               snapshot_guid: "456"
             }
           }},
          {Path.join(root, "absent"), @placement, %{}}
        ] do
      assert :unchanged ==
               Fixture.capture(directory, 123, placement, snapshots, fn ->
                 refute File.exists?(Path.join(directory, "context-123.json"))
                 :unchanged
               end)
    end
  end
end
