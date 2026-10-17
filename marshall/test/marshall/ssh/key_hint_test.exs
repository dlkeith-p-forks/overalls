defmodule Marshall.SSH.KeyHintTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures, only: [user: 0]

  test "removing an SSH key hints its owner" do
    owner = user()
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 13::256>>)
    {:ok, added} = Marshall.SSH.add_key(%{public_key: key}, actor: owner)
    parent = self()
    handler = "key-hint-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _, _, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, _} = Marshall.SSH.remove_key(%{id: added.id}, actor: owner)
    owner_id = owner.id
    assert_receive {:hint, :user, ^owner_id}, 1_000
  end
end
