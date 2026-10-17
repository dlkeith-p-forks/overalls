defmodule Marshall.Terminal.CreationTest do
  use Marshall.DataCase, async: false

  import ExUnit.CaptureLog

  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Terminal.{Authority, Creation, Event, Opening, Reconciler, Relay}
  require Ecto.Query

  test "scheduled reconciliation enqueues VM work through its system-authorized action" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)

    assert {:ok, _} =
             Creation.reserve(vm, fixture.owner, "root", "xterm-256color", Ash.UUID.generate())

    input =
      Ash.ActionInput.for_action(Opening, :reconcile, %{},
        actor: Marshall.Authorization.SystemActor.compute()
      )

    assert {:ok, 1} = Ash.run_action(input)

    jobs =
      Oban.Job
      |> Ecto.Query.where([job], job.worker == "Marshall.Terminal.Workers.Reconcile")
      |> Marshall.Repo.all()

    assert Enum.any?(jobs, &(&1.args["action_arguments"]["vm_id"] == vm.id))
  end

  test "a lost guest-create reply is recovered into exactly one registry and audit receipt" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)
    request_id = Ash.UUID.generate()

    assert {:ok, opening} =
             Creation.reserve(vm, fixture.owner, "root", "xterm-256color", request_id)

    assert {:ok, %{guest_session_id: guest_id}} = Relay.control(stream, create_message(opening))
    assert {:ok, []} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)

    assert :ok = Reconciler.reconcile_vm(vm.id)
    assert :ok = Reconciler.reconcile_vm(vm.id)
    assert {:ok, [session]} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)
    assert session.guest_session_id == guest_id

    assert {:ok, retried} =
             Authority.open_session(vm, fixture.owner, "root", "xterm-256color", request_id)

    assert retried.id == session.id
    events = Ash.read!(Event, authorize?: false)
    assert Enum.count(events, &(&1.request_id == request_id and &1.kind == :opened)) == 1
  end

  test "cancellation of an unknown guest request fences a delayed create" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)

    assert {:ok, opening} =
             Creation.reserve(vm, fixture.owner, "root", "xterm-256color", Ash.UUID.generate())

    assert {:ok, _} = Creation.begin_cancel(opening.id)
    assert :ok = Reconciler.reconcile_vm(vm.id)
    assert {:ok, %{ok: false}} = Relay.control(stream, create_message(opening))
    assert {:error, :opening_expired} = Creation.complete(opening.id, 123)
    assert {:ok, %Opening{status: :failed}} = Ash.get(Opening, opening.id, authorize?: false)
    assert {:ok, []} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)
  end

  test "request identity cannot be reused by another actor or with different parameters" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)
    other = Marshall.ComputeFixtures.user()
    request_id = Ash.UUID.generate()
    assert {:ok, _} = Creation.reserve(vm, fixture.owner, "root", "xterm-256color", request_id)

    assert {:error, :idempotency_conflict} =
             Creation.reserve(vm, other, "root", "xterm-256color", request_id)

    assert {:error, :idempotency_conflict} =
             Creation.reserve(vm, fixture.owner, "nobody", "xterm-256color", request_id)

    assert {:error, :idempotency_conflict} =
             Creation.reserve(vm, fixture.owner, "root", "vt100", request_id)
  end

  test "stream loss retains pending intent and active registry authority" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)

    assert {:ok, session} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)

    assert {:ok, opening} =
             Creation.reserve(vm, fixture.owner, "root", "xterm-256color", Ash.UUID.generate())

    monitor = Process.monitor(stream)
    Process.exit(stream, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^stream, :shutdown}
    assert {:error, :terminal_unavailable} = Reconciler.reconcile_vm(vm.id)
    assert {:ok, %Opening{status: :pending}} = Ash.get(Opening, opening.id, authorize?: false)
    assert {:ok, [remaining]} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)
    assert remaining.id == session.id
  end

  test "recovery advances a durable cursor instead of processing every pending create in one job" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)

    for _ <- 1..2 do
      assert {:ok, opening} =
               Creation.reserve(vm, fixture.owner, "root", "xterm-256color", Ash.UUID.generate())

      assert {:ok, %{ok: true}} = Relay.control(stream, create_message(opening))
    end

    assert :ok = Reconciler.reconcile_vm(vm.id)
    assert {:ok, [_]} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)

    jobs =
      Oban.Job
      |> Ecto.Query.where([job], job.worker == "Marshall.Terminal.Workers.Reconcile")
      |> Marshall.Repo.all()

    continuation = Enum.find(jobs, &(&1.args["action_arguments"]["vm_id"] == vm.id))
    assert continuation
    args = continuation.args["action_arguments"]
    assert OverallsProtocol.uuid?(args["after_opening"])
    assert :ok = Reconciler.reconcile_vm(vm.id, args["after_opening"], args["after_session"])
    assert {:ok, sessions} = Marshall.Terminal.list_for_vm(vm.id, authorize?: false)
    assert length(sessions) == 2
  end

  test "an unexpected creation probe reply is refused before reserving or creating a terminal" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    parent = self()

    start_supervised!(%{
      id: :legacy_terminal_stream,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             :ok = Relay.register(Relay, fixture.host.id, self())
             send(parent, :legacy_stream_ready)

             receive do
               {:relay_control, request} ->
                 assert request.message.type == :creation_query

                 Relay.reply(
                   request,
                   {:ok,
                    %{
                      type: :creation_cancelled,
                      request_id: request.message.request_id,
                      ok: false
                    }}
                 )
             end

             receive do
               {:relay_control, request} ->
                 send(parent, {:unexpected_legacy_operation, request.message.type})
             end
           end
         ]}
    })

    assert_receive :legacy_stream_ready

    assert {:error, :terminal_unavailable} =
             Authority.open_session(fixture.vm, fixture.owner, "root", "xterm-256color")

    assert Ash.count!(Opening, authorize?: false) == 0
    assert {:ok, []} = Marshall.Terminal.list_for_vm(fixture.vm.id, authorize?: false)
    refute_receive {:unexpected_legacy_operation, _}
  end

  @spec create_message(Opening.t()) :: map()
  defp create_message(opening) do
    %{
      type: :create,
      request_id: opening.id,
      vm_id: opening.vm_id,
      placement_id: opening.placement_id,
      execution_epoch: opening.execution_epoch,
      mode: :rw,
      user: "root",
      term: "xterm-256color",
      cols: 80,
      rows: 24
    }
  end

  test "refused terminal creations emit closed denial reasons" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    [vm] = Ledger.read!(VirtualMachine, id: fixture.vm.id)

    old_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log([metadata: [:event, :reason, :vm_id]], fn ->
        assert {:error, :invalid_terminal_request} =
                 Creation.reserve(vm, fixture.owner, "root", String.duplicate("x", 64), "bad-id")
      end)

    assert logs =~ "event=terminal.creation_refused"
    assert logs =~ "reason=invalid_terminal_request"
    assert logs =~ vm.id

    fill_logs =
      capture_log([metadata: [:event, :reason]], fn ->
        for _ <- 1..64,
            do: Creation.reserve(vm, fixture.owner, "root", "xterm", Ash.UUID.generate())

        assert {:error, :too_many_terminal_sessions} =
                 Creation.reserve(vm, fixture.owner, "root", "xterm", Ash.UUID.generate())
      end)

    assert fill_logs =~ "event=terminal.creation_refused"
    assert fill_logs =~ "reason=too_many_terminal_sessions"
  end
end
