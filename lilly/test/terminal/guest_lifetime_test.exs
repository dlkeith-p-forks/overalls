defmodule Lilly.Terminal.GuestLifetimeTest do
  use ExUnit.Case, async: true

  test "guest control manager retires when its authorizing VM actor exits" do
    actor = start_supervised!({Task, fn -> receive do: (:retire -> :ok) end})

    identity = %{
      uds_path: "/unused-terminal-test",
      placement_id: "11111111-1111-4111-8111-111111111111",
      execution_epoch: 1,
      boot_challenge: String.duplicate("ab", 32),
      actor_pid: actor
    }

    manager =
      start_supervised!(%{
        id: Lilly.Terminal.Guest,
        restart: :temporary,
        start: {Lilly.Terminal.Guest, :start_link, [self(), identity]}
      })

    reference = Process.monitor(manager)
    send(actor, :retire)
    assert_receive {:guest_actor_gone, ^manager}, 1000
    assert_receive {:DOWN, ^reference, :process, ^manager, :normal}, 1000
  end
end
