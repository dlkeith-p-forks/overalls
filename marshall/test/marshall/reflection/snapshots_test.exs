defmodule Marshall.Reflection.SnapshotsTest do
  use Marshall.DataCase, async: false

  alias Marshall.Control.Services.Peach
  alias OverallsProtocol.Control.Envelope

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    Map.put(fixture, :binding, binding)
  end

  test "the Peach control service returns a protocol-valid, wire-encodable projection", c do
    assert {:ok, snapshot} =
             Peach.handle_request(
               "peach.snapshot",
               %{"version" => 1, "binding" => c.binding},
               %{host_id: c.vm.host_id}
             )

    encoded = Envelope.encode({:res, %{id: 1, result: {:ok, snapshot}}})
    assert {:ok, {:res, %{result: {:ok, wire}}}} = Envelope.decode(encoded)
    assert {:ok, checked} = OverallsProtocol.Reflection.snapshot(wire)
    assert checked.guest["id"] == c.vm.id
    assert Enum.map(checked.integrations, & &1["name"]) |> Enum.take(2) == ["reflection", "llm"]
  end

  test "attached integrations appear with header names and kinds but no values", c do
    {:ok, _} =
      Marshall.Galileo.configure_integration(
        %{
          name: "esample",
          target: "https://api.example.test",
          headers: [
            %{kind: :bearer, name: "authorization", value: "sk-live"},
            %{kind: :static, name: "x-team", value: "platform"}
          ],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    {:ok, _} =
      Marshall.Galileo.attach_integration(%{name: "esample", vm_id: c.vm.id}, actor: c.owner)

    assert {:ok, snapshot} = Marshall.Reflection.Snapshots.fetch(c.binding)

    assert %{"url" => "https://esample.integration.internal", "headers" => headers} =
             Enum.find(snapshot["integrations"], &(&1["name"] == "esample"))

    assert headers == [
             %{"name" => "authorization", "kind" => "authorization"},
             %{"name" => "x-team", "kind" => "custom"}
           ]

    assert {:ok, _} = OverallsProtocol.Reflection.snapshot(snapshot)
    refute inspect(snapshot) =~ "sk-live"
    refute inspect(snapshot) =~ "platform"
    refute inspect(snapshot) =~ "api.example.test"
  end

  test "a binding for another host or a stale epoch is refused", c do
    assert {:error, "invalid_request"} =
             Peach.handle_request(
               "peach.snapshot",
               %{
                 "version" => 1,
                 "binding" => %{c.binding | "execution_epoch" => c.vm.execution_epoch + 1}
               },
               %{host_id: c.vm.host_id}
             )

    assert {:error, "invalid_request"} =
             Peach.handle_request(
               "peach.snapshot",
               %{"version" => 1, "binding" => c.binding},
               %{host_id: Ecto.UUID.generate()}
             )
  end
end
