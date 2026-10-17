defmodule Marshall.ThreadsTranscriptTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread

  test "creator can read an archived transcript after thread archival" do
    host_fixture()
    creator = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: creator)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)

    thread = user_thread(creator, vm, root, agent_thread)

    event =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent_thread.id,
        sequence: agent_thread.next_event_sequence,
        kind: :assistant,
        body: %{"text" => "retained response"}
      })

    assert {:ok, [transcript_event]} = Marshall.Threads.events(thread.id, creator)
    assert transcript_event.id == event.id
    assert transcript_event.kind == :assistant
    assert transcript_event.body == %{"text" => "retained response"}
  end

  test "team member can read an archived transcript but a stranger cannot" do
    host_fixture()
    creator = user()
    member = user()
    stranger = user()

    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "thread-team-#{Ash.UUID.generate()}", idempotency_key: Ash.UUID.generate()},
        actor: creator
      )

    assert {:ok, _membership} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: creator
             )

    {:ok, vm} = Marshall.Compute.provision(Map.put(request(), :team_id, team.id), actor: creator)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    thread = user_thread(creator, vm, root, agent_thread, team.id)

    Ledger.create!(Marshall.Agents.Event, :append, %{
      thread_id: agent_thread.id,
      sequence: agent_thread.next_event_sequence,
      kind: :prompt,
      body: %{"prompt" => "team-visible"}
    })

    assert {:ok, [%{kind: :prompt, body: %{"prompt" => "team-visible"}}]} =
             Marshall.Threads.events(thread.id, member)

    assert {:error, :forbidden} = Marshall.Threads.events(thread.id, stranger)
  end

  test "retained transcript rejects an agent thread paired with a different root" do
    host_fixture()
    creator = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: creator)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    {:ok, other_vm} = Marshall.Compute.provision(request(), actor: creator)
    [other_root] = Ledger.read!(Marshall.Agents.Root, vm_id: other_vm.id)
    [other_agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: other_root.id)

    thread = user_thread(creator, vm, root, other_agent_thread)

    assert {:error, :machine_unavailable} = Marshall.Threads.events(thread.id, creator)
  end

  @spec user_thread(
          Marshall.Accounts.User.t(),
          Marshall.Compute.VirtualMachine.t(),
          Marshall.Agents.Root.t(),
          Marshall.Agents.Thread.t(),
          String.t() | nil
        ) :: Thread.t()
  defp user_thread(creator, vm, root, agent_thread, team_id \\ nil) do
    key = Ash.UUID.generate()

    thread =
      Ledger.create!(Thread, :open, %{
        creator_id: creator.id,
        team_id: team_id,
        objective: "Retained transcript",
        mode: :medium,
        machine_spec: Map.put(request(), :team_id, team_id),
        idempotency_key: key,
        machine_key: key
      })

    thread =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent_thread.id,
        status: :ready
      })

    :ok = Ledger.archive!(vm, :archive)
    assert Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id) == []

    assert [%{archived_at: %DateTime{}}] =
             Ledger.history!(Marshall.Compute.VirtualMachine, id: vm.id)

    Ledger.update!(thread, :mark_archived, %{
      status: :archived,
      archived_at: DateTime.utc_now()
    })
  end
end
