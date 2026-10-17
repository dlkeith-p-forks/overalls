defmodule MarshallWeb.ExecutionAPITest do
  use MarshallWeb.ConnCase, async: false
  import Marshall.ComputeFixtures
  import Marshall.LillySocket, only: [reply: 2]
  alias Marshall.LillySocket
  alias OverallsProtocol.Execution
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Host,
    Ledger,
    Operation,
    PhysicalOutcome,
    Reservation,
    VirtualMachine
  }

  setup do
    machine = "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    fixture = host_fixture(%{machine_id: machine})
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    {:ok, credential} = Credentials.rotate(fixture.host.id, 3600)
    Map.merge(fixture, %{machine: machine, user: actor, vm: vm, token: credential.token})
  end

  test "the retired owner refresh route is refused without reading or writing", context do
    session = open(context) |> reply(200)
    before_vm = Ledger.read!(VirtualMachine, id: context.vm.id)

    message =
      Map.take(session, ["version", "session_id", "epoch"]) |> Map.put("bindings", [])

    refute "egress_owners" in Marshall.Compute.ProvisionerRequests.routes()
    assert post_api(context.token, 4, "egress_owners", message) |> reply(426)
    assert Ledger.read!(VirtualMachine, id: context.vm.id) == before_vm
  end

  test "execution sessions require enrolled physical identity",
       context do
    wrong = Map.put(context, :machine, "sha256:" <> String.duplicate("0", 64))
    assert %{"error" => "machine_identity_mismatch"} = open(wrong) |> reply(403)
    session = open(context) |> reply(200)
    assert session["version"] == 4
    assert open(context, session["session_id"]) |> reply(200) == session

    unbound = host_fixture()
    {:ok, token} = Credentials.rotate(unbound.host.id, 3600)

    assert %{"error" => "machine_identity_mismatch"} =
             open(%{context | token: token.token}) |> reply(403)
  end

  test "commands include image and address; durable receipts are separate from physical outcomes",
       context do
    session = open(context) |> reply(200)
    body = exchange(context, session) |> reply(200)
    assert {:ok, [command]} = Execution.commands(body["commands"])
    assert command.vm_id == context.vm.id
    assert command.image_id == context.vm.image_id
    assert command.slot == 2

    assert {:error, :invalid_message} =
             OverallsProtocol.Execution.commands(
               Enum.map(body["commands"], &Map.drop(&1, ["image_id", "slot"]))
             )

    exchange(context, session, %{"acknowledgements" => [command.id]}) |> reply(200)
    assert [%{observed_state: :pending}] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert [%{status: :acknowledged}] = Ledger.read!(Operation, id: command.id)

    event = outcome(command, 1, :running)
    body = exchange(context, session, %{"outcomes" => [event]}) |> reply(200)
    assert body["outcome_acknowledgements"] == [event["id"]]
    assert body["commands"] == []
    assert [%{observed_state: :running}] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert [%{status: :completed}] = Ledger.read!(Operation, id: command.id)
    assert [%{compute_held: true}] = Ledger.read!(Reservation, vm_id: command.vm_id)
  end

  test "delete outcome and its command receipt commit together even after VM archival", context do
    session = open(context) |> reply(200)

    {:ok, delete} =
      Compute.lifecycle(%{vm_id: context.vm.id, kind: :delete, idempotency_key: "delete"},
        actor: context.user
      )

    body = exchange(context, session) |> reply(200)
    {:ok, [command]} = Execution.commands(body["commands"])
    assert command.id == delete.id
    event = outcome(command, 1, :deleted)
    message = %{"acknowledgements" => [delete.id], "outcomes" => [event]}
    body = exchange(context, session, message) |> reply(200)
    assert body["outcome_acknowledgements"] == [event["id"]]
    assert body["commands"] == []
    assert [] == Ledger.read!(VirtualMachine, id: context.vm.id)

    assert [%{compute_held: false, disk_held: false}] =
             Ledger.read!(Reservation, vm_id: context.vm.id)

    assert exchange(context, session, message) |> reply(200) == body
  end

  test "an invalid receipt rolls back outcome, capacity and a fresh report", context do
    session = open(context) |> reply(200)
    body = exchange(context, session) |> reply(200)
    {:ok, [command]} = Execution.commands(body["commands"])
    event = outcome(command, 1, :running)

    assert %{"error" => "invalid_acknowledgement"} =
             exchange(context, session, %{
               "report" => OverallsProtocol.encode_report(context.report),
               "acknowledgements" => [Ash.UUID.generate()],
               "outcomes" => [event]
             })
             |> reply(400)

    assert [%{report_sequence: 0, reported_at: nil}] = Ledger.read!(Host, id: context.host.id)
    assert [%{observed_state: :pending}] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert [] = Ledger.read!(PhysicalOutcome, vm_id: context.vm.id)
    assert [%{compute_held: true}] = Ledger.read!(Reservation, vm_id: context.vm.id)
  end

  test "a successor session fences older observations before they change any state", context do
    old = open(context) |> reply(200)
    body = exchange(context, old) |> reply(200)
    {:ok, [command]} = Execution.commands(body["commands"])
    successor = open(context) |> reply(200)
    assert successor["epoch"] > old["epoch"]
    event = outcome(command, 1, :running)

    assert %{"error" => "stale_connection"} =
             exchange(context, old, %{"outcomes" => [event]}) |> reply(409)

    assert [] = Ledger.read!(PhysicalOutcome, vm_id: context.vm.id)

    assert %{"outcome_acknowledgements" => [_]} =
             exchange(context, successor, %{"outcomes" => [event]}) |> reply(200)
  end

  test "an outcome cannot claim another placement or execution epoch", context do
    session = open(context) |> reply(200)
    %{"commands" => [wire]} = exchange(context, session, %{}) |> reply(200)
    {:ok, command} = Execution.command(wire)
    event = outcome(command, 1, :running)

    for {field, value} <- [
          {"placement_id", Ash.UUID.generate()},
          {"execution_epoch", command.execution_epoch + 1}
        ] do
      assert %{"error" => "invalid_outcome"} =
               exchange(context, session, %{"outcomes" => [Map.put(event, field, value)]})
               |> reply(400)
    end

    assert [] = Ledger.read!(PhysicalOutcome, vm_id: context.vm.id)
  end

  defp open(context, id \\ Ash.UUID.generate()),
    do:
      post_api(context.token, 4, "sessions", %{
        "version" => 4,
        "session_id" => id,
        "machine_id" => context.machine
      })

  defp exchange(context, session, overrides \\ %{}) do
    post_api(
      context.token,
      4,
      "exchange",
      Map.merge(
        %{
          "version" => 4,
          "session_id" => session["session_id"],
          "epoch" => session["epoch"],
          "report" => nil,
          "acknowledgements" => [],
          "outcomes" => []
        },
        overrides
      )
    )
  end

  defp outcome(command, sequence, state) do
    Execution.encode_outcome(%{
      id: Ash.UUID.generate(),
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      execution_epoch: command.execution_epoch,
      operation_id: command.id,
      generation: command.generation,
      sequence: sequence,
      state: state,
      compute_empty: state == :deleted,
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: :none
    })
  end

  # Control requests run over the control socket (ADR-0142).
  defp post_api(token, 4, action, body), do: LillySocket.request(token, action, body)
end
