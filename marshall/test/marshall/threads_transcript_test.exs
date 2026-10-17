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

  # @cc [owner:ghuntley,label:verification;durability] previous-generation-transcript-selection
  # An authorized reader MUST be able to select a retained transcript by its
  # generation after reopen. Selecting an unknown generation or a binding whose
  # root/VM owner does not match MUST refuse without exposing events.
  test "authorized readers can browse a previous machine generation" do
    host_fixture()
    creator = user()
    {:ok, first_vm} = Marshall.Compute.provision(request(), actor: creator)
    [first_root] = Ledger.read!(Marshall.Agents.Root, vm_id: first_vm.id)
    [first_agent] = Ledger.read!(Marshall.Agents.Thread, root_id: first_root.id)

    key = Ash.UUID.generate()

    thread =
      Ledger.create!(Thread, :open, %{
        creator_id: creator.id,
        objective: "Browse retained work",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: key,
        machine_key: first_vm.idempotency_key
      })

    thread =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: first_vm.id,
        agent_root_id: first_root.id,
        agent_thread_id: first_agent.id,
        status: :ready
      })

    Marshall.Threads.Generation.open!(thread, 1)

    old_event =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: first_agent.id,
        sequence: first_agent.next_event_sequence,
        kind: :assistant,
        body: %{"text" => "first machine response"}
      })

    :ok = Ledger.archive!(first_vm, :archive)

    reopened =
      Ledger.update!(thread, :reopen, %{
        status: :pending,
        archived_at: nil,
        machine_id: nil,
        agent_root_id: nil,
        agent_thread_id: nil,
        machine_key: "thread-reopen:" <> thread.id <> ":" <> Ash.UUID.generate(),
        failure_reason: nil
      })

    Marshall.Threads.Generation.open!(reopened, 2)

    {:ok, second_vm} =
      Marshall.Compute.provision(
        request(%{idempotency_key: reopened.machine_key}),
        actor: creator
      )

    [second_root] = Ledger.read!(Marshall.Agents.Root, vm_id: second_vm.id)
    [second_agent] = Ledger.read!(Marshall.Agents.Thread, root_id: second_root.id)

    current =
      Ledger.update!(reopened, :bind_machine, %{
        machine_id: second_vm.id,
        agent_root_id: second_root.id,
        agent_thread_id: second_agent.id,
        status: :ready
      })

    Marshall.Threads.Generation.sync!(current)

    assert {:ok, generations} = Marshall.Threads.generations(thread.id, creator)
    assert Enum.map(generations, & &1.ordinal) == [2, 1]

    assert {:ok, [event]} = Marshall.Threads.events(thread.id, creator, 1, 100)
    assert event.id == old_event.id
    assert event.body == %{"text" => "first machine response"}

    [first_generation] =
      Ledger.read!(Marshall.Threads.Generation, thread_id: thread.id, ordinal: 1)

    tampered =
      Ledger.update!(first_generation, :bind, %{
        machine_id: second_vm.id,
        agent_root_id: second_root.id,
        agent_thread_id: second_agent.id
      })

    assert {:error, :machine_unavailable} = Marshall.Threads.events(thread.id, creator, 1, 100)

    Ledger.update!(tampered, :bind, %{
      machine_id: first_vm.id,
      agent_root_id: first_root.id,
      agent_thread_id: first_agent.id
    })

    member = user()

    assert {:ok, _grant} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(member.email),
                 role: :viewer,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: creator
             )

    assert {:ok, [%{id: member_event_id}]} = Marshall.Threads.events(thread.id, member, 1, 100)
    assert member_event_id == old_event.id

    assert {:error, :not_found} = Marshall.Threads.events(thread.id, creator, 3, 100)

    [current_generation] =
      Ledger.read!(Marshall.Threads.Generation, thread_id: thread.id, ordinal: 2)

    Ledger.update!(current_generation, :bind, %{
      machine_id: first_vm.id,
      agent_root_id: first_root.id,
      agent_thread_id: first_agent.id
    })

    assert {:error, :machine_unavailable} = Marshall.Threads.events(thread.id, creator)

    Ledger.update!(current_generation, :bind, %{
      machine_id: nil,
      agent_root_id: nil,
      agent_thread_id: nil
    })

    assert {:error, :machine_unavailable} = Marshall.Threads.events(thread.id, creator)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(member.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: creator
             )

    assert {:error, :forbidden} = Marshall.Threads.events(thread.id, member, 1, 100)
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
        machine_key: vm.idempotency_key
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
