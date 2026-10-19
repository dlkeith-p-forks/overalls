defmodule Marshall.Notifications.ProducerTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.{Compute, Notifications, SSH}
  alias Marshall.Agents.{Planning, Root, Thread, Turn}
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, Producer}
  alias OverallsProtocol.PushPoke
  require Ecto.Query
  @moduletag capture_log: true

  setup do
    host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)

    {:ok, {thread, turn}} =
      Ledger.transaction(fn ->
        turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: thread.id,
            actor_id: owner.id,
            request_key: Ash.UUID.generate(),
            ordinal: 1,
            prompt: "Plan the change.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        thread = Ledger.update!(thread, :advance, %{active_turn_id: turn.id})
        thread = Ledger.update!(thread, :set_context, %{collaboration_mode: :plan})
        {thread, turn}
      end)

    on_exit(fn -> Application.delete_env(:marshall, :notifications_enabled) end)
    %{owner: owner, vm: vm, root: root, thread: thread, turn: turn}
  end

  test "an agent question notifies current writers' devices after commit, not viewers", c do
    operator = user()
    viewer = user()
    stranger = user()
    share!(c, operator, :operator)
    share!(c, viewer, :viewer)
    owner_device = device!(c.owner)
    operator_device = device!(operator)
    _viewer_device = device!(viewer)
    _stranger_device = device!(stranger)
    disabled = device!(operator)

    {:ok, _} =
      Notifications.set_device_preference(%{id: disabled.id, enabled: false}, actor: operator)

    assert {:ok, _} = request_questions(c)
    deliveries = Ledger.read!(Delivery)

    assert deliveries |> Enum.map(& &1.device_id) |> Enum.sort() ==
             Enum.sort([owner_device.id, operator_device.id])

    for delivery <- deliveries do
      assert delivery.state == :queued
      assert delivery.kind == :needs_input
      assert delivery.collapse_key == "needs_input:" <> c.thread.id
      assert delivery.route == "/machines/#{c.vm.id}/threads/#{c.thread.id}"
      assert DateTime.diff(delivery.expires_at, delivery.inserted_at) in 3590..3610
    end

    assert jobs() |> Enum.map(& &1.args["delivery_id"]) |> Enum.sort() ==
             deliveries |> Enum.map(& &1.id) |> Enum.sort()

    # Replaying the same call creates neither a question nor a delivery.
    assert {:ok, _} = request_questions(c)
    assert length(Ledger.read!(Delivery)) == 2
  end

  test "a rolled-back question produces nothing", c do
    _device = device!(c.owner)

    assert {:error, :rolled_back} =
             Ledger.transaction(fn ->
               turn = Ledger.lock!(Turn, c.turn.id)
               thread = Ledger.lock!(Thread, c.thread.id)
               Planning.request_questions_locked!(thread, turn, call())
               Ledger.rollback(:rolled_back)
             end)

    assert [] == Ledger.read!(Delivery)
    assert [] == jobs()
  end

  test "the producer is a no-op when notifications are disabled", c do
    _device = device!(c.owner)
    Application.put_env(:marshall, :notifications_enabled, false)
    assert {:ok, _} = request_questions(c)
    assert [] == Ledger.read!(Delivery)
  end

  test "the acting user is excluded and an open delivery coalesces a newer fact", c do
    device = device!(c.owner)
    source = %{thread_id: c.thread.id, root_id: c.root.id}
    assert 0 == Producer.produce(source, c.owner.id)
    assert 1 == Producer.produce(source, nil)
    assert 1 == Producer.produce(source, nil)

    assert [%{state: :queued}, %{state: :dropped, drop_reason: :coalesced}] =
             Ledger.read!(Delivery, device_id: device.id) |> Enum.sort_by(&(&1.state != :queued))

    assert length(jobs()) == 1
  end

  test "a completed plan proposal notifies writers", c do
    device = device!(c.owner)

    {:ok, _} =
      Ledger.transaction(fn ->
        turn = Ledger.lock!(Turn, c.turn.id)
        thread = Ledger.lock!(Thread, c.thread.id)
        turn = Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

        Planning.record_proposal_locked!(
          thread,
          turn,
          "<proposed_plan>\nDo the work.\n</proposed_plan>"
        )
      end)

    assert [%{device_id: id, state: :queued}] = Ledger.read!(Delivery)
    assert id == device.id
  end

  test "route paths are canonical app routes without scheme or host" do
    machine = Ash.UUID.generate()
    thread = Ash.UUID.generate()
    assert {:ok, "/threads/" <> ^thread} = Producer.path({:thread, thread})

    assert {:ok, path} = Producer.path({:machine_thread, machine, thread})
    assert path == "/machines/#{machine}/threads/#{thread}"
  end

  defp request_questions(c) do
    Ledger.transaction(fn ->
      turn = Ledger.lock!(Turn, c.turn.id)
      thread = Ledger.lock!(Thread, c.thread.id)
      Planning.request_questions_locked!(thread, turn, call())
    end)
  end

  defp share!(c, member, role) do
    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )
  end

  defp device!(actor) do
    raw = :crypto.strong_rand_bytes(32)
    blob = <<11::32, "ssh-ed25519", 32::32, raw::binary>>
    {:ok, key} = SSH.add_key(%{public_key: "ssh-ed25519 " <> Base.encode64(blob)}, actor: actor)
    {public, _private} = PushPoke.generate_key_pair()

    {:ok, device} =
      Notifications.register_device(
        %{
          platform: :android,
          push_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          enc_public_key: Base.url_encode64(public, padding: false),
          key_id: key.id
        },
        actor: actor
      )

    device
  end

  defp jobs do
    Oban.Job
    |> Ecto.Query.where(worker: "Marshall.Notifications.DeliveryWorker")
    |> Marshall.Repo.all()
  end

  defp call do
    %{
      id: "question-call",
      arguments: %{
        "questions" => [
          %{
            "id" => "approach",
            "header" => "Approach",
            "question" => "Which approach should the plan use?",
            "options" => [
              %{"label" => "First", "description" => "Keep the existing interface."},
              %{"label" => "Second", "description" => "Add a new interface."}
            ]
          }
        ]
      }
    }
  end
end
