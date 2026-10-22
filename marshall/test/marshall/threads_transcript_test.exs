defmodule Marshall.ThreadsTranscriptTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Hegel
  import Hegel.Gen

  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread

  test "thread tools discover shared user links and read retained content only with current access" do
    host_fixture()
    creator = user()
    reader = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: creator)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    thread = user_thread(creator, vm, root, agent_thread)

    Ledger.create!(Marshall.Agents.Event, :append, %{
      thread_id: agent_thread.id,
      sequence: agent_thread.next_event_sequence,
      kind: :assistant,
      body: %{"text" => "content-only needle"}
    })

    tool = Marshall.Agents.ThreadTool
    assert {:ok, []} = tool.search(reader.id)
    assert {:error, :forbidden} = tool.read(reader.id, thread.id)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(reader.email),
                 role: :viewer,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: creator
             )

    assert {:ok, [found]} = tool.search(reader.id, "VISIBLE")
    assert found.id == thread.id
    assert found.url == "/threads/" <> thread.id
    refute found.id == agent_thread.id
    assert {:ok, []} = tool.search(reader.id, "content-only needle")
    assert {:error, :not_subscribed} = tool.replay(reader.id, thread.id, 0)
    assert {:ok, %{active: true}} = tool.subscribe(reader.id, thread.id)
    assert {:ok, %{active: true}} = tool.subscribe(reader.id, thread.id)

    Ledger.create!(Marshall.Agents.ThreadNotification, :append, %{
      thread_id: agent_thread.id,
      user_thread_id: thread.id,
      owner_id: creator.id,
      sequence: 1,
      kind: :machine_purged,
      metadata: %{"state" => "stopped"}
    })

    assert {:ok, [%{sequence: 1, kind: :machine_purged}]} = tool.replay(reader.id, thread.id, 0)
    assert {:ok, []} = tool.replay(reader.id, thread.id, 1)
    assert {:ok, %{active: false}} = tool.subscribe(reader.id, thread.id, false)
    assert {:error, :not_subscribed} = tool.replay(reader.id, thread.id, 0)
    assert {:ok, %{active: true}} = tool.subscribe(reader.id, thread.id)

    assert {:ok, %{events: [%{body: %{"text" => "content-only needle"}}]}} =
             tool.read(reader.id, thread.id)

    assert {:error, :forbidden} = tool.read(reader.id, agent_thread.id)

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(reader.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: creator
             )

    assert {:ok, []} = tool.search(reader.id)
    assert {:error, :forbidden} = tool.read(reader.id, thread.id)
    assert {:error, :forbidden} = tool.read(reader.id, "invalid")
    assert {:error, :forbidden} = tool.subscribe(reader.id, thread.id)
    assert {:error, :forbidden} = tool.replay(reader.id, thread.id, 0)
  end

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
      Marshall.ThreadStateFixture.ready!(thread, %{
        machine_id: first_vm.id,
        agent_root_id: first_root.id,
        agent_thread_id: first_agent.id
      })

    Marshall.Threads.Generation.open!(thread, 1)

    assert {:ok, %{active: true}} = Marshall.Agents.ThreadTool.subscribe(creator.id, thread.id)

    [subscription] =
      Ledger.read!(Marshall.Agents.ThreadSubscription,
        owner_id: creator.id,
        user_thread_id: thread.id
      )

    Ledger.create!(Marshall.Agents.ThreadNotification, :append, %{
      thread_id: first_agent.id,
      user_thread_id: thread.id,
      owner_id: creator.id,
      sequence: 1,
      kind: :machine_purged,
      metadata: %{"state" => "stopped"}
    })

    old_event =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: first_agent.id,
        sequence: first_agent.next_event_sequence,
        kind: :assistant,
        body: %{"text" => "first machine response"}
      })

    :ok = Ledger.archive!(first_vm, :archive)

    reopened =
      Marshall.ThreadStateFixture.reopened!(
        thread,
        "thread-reopen:" <> thread.id <> ":" <> Ash.UUID.generate()
      )

    Marshall.Threads.Generation.open!(reopened, 2)

    assert {:ok, [%{sequence: 1}]} = Marshall.Agents.ThreadTool.replay(creator.id, thread.id, 0)

    assert {:ok, %{active: false}} =
             Marshall.Agents.ThreadTool.subscribe(creator.id, thread.id, false)

    assert {:error, :not_subscribed} = Marshall.Agents.ThreadTool.replay(creator.id, thread.id, 0)
    assert {:ok, %{active: true}} = Marshall.Agents.ThreadTool.subscribe(creator.id, thread.id)

    {:ok, second_vm} =
      Marshall.Compute.provision(
        request(%{idempotency_key: reopened.machine_key}),
        actor: creator
      )

    [second_root] = Ledger.read!(Marshall.Agents.Root, vm_id: second_vm.id)
    [second_agent] = Ledger.read!(Marshall.Agents.Thread, root_id: second_root.id)

    current =
      Marshall.ThreadStateFixture.ready!(reopened, %{
        machine_id: second_vm.id,
        agent_root_id: second_root.id,
        agent_thread_id: second_agent.id
      })

    Marshall.Threads.Generation.sync!(current)

    Ledger.create!(Marshall.Agents.ThreadNotification, :append, %{
      thread_id: second_agent.id,
      user_thread_id: thread.id,
      owner_id: creator.id,
      sequence: 2,
      kind: :machine_purged,
      metadata: %{"state" => "paused"}
    })

    assert {:ok, [%{sequence: 2}]} = Marshall.Agents.ThreadTool.replay(creator.id, thread.id, 1)

    assert [%{id: retained_id, thread_id: origin_id}] =
             Ledger.read!(Marshall.Agents.ThreadSubscription,
               owner_id: creator.id,
               user_thread_id: thread.id
             )

    assert retained_id == subscription.id
    assert origin_id == first_agent.id

    # A previous release supplies only its agent binding and generation-local
    # cursor. The additive migration must retain global ordering during rollout.
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      INSERT INTO agent_thread_tool_events
        (id, thread_id, owner_id, sequence, kind, metadata, inserted_at, updated_at)
      VALUES ($1, $2, $3, 1, 'machine_purged', '{}', now(), now())
      """,
      [
        Ecto.UUID.dump!(Ash.UUID.generate()),
        Ecto.UUID.dump!(second_agent.id),
        Ecto.UUID.dump!(creator.id)
      ],
      log: false
    )

    assert {:ok, [%{sequence: 3}]} = Marshall.Agents.ThreadTool.replay(creator.id, thread.id, 2)

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

  @tag hegel_case_sandbox: true, timeout: 120_000
  property "thread read bounds encoded bytes including Unicode and JSON escaping" do
    size = draw("body length", integer(10_000..70_000))
    character = draw("encoding", member_of(["x", "\"", "é", "\n"]))
    isolate_property_case()
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
        body: %{"text" => String.duplicate(character, size)}
      })

    expected = %{
      id: thread.id,
      title: thread.title,
      url: "/threads/" <> thread.id,
      events: [Map.take(event, [:sequence, :kind, :body])]
    }

    if byte_size(Jason.encode!(expected)) <= 65_536 do
      assert {:ok, ^expected} = Marshall.Agents.ThreadTool.read(creator.id, thread.id)
    else
      assert {:error, :result_too_large} = Marshall.Agents.ThreadTool.read(creator.id, thread.id)
    end
  end

  # @cc [owner:ghuntley,label:verification] thread-subscription-history
  # Generated activation histories MUST retain one subscription identity and
  # permit replay exactly while the independently modeled state is active.
  @tag hegel_case_sandbox: true, timeout: 120_000
  property "subscription histories preserve identity and active replay authority" do
    commands = draw("subscription transitions", list_of(boolean(), min_length: 1, max_length: 12))
    isolate_property_case()
    host_fixture()
    creator = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: creator)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    thread = user_thread(creator, vm, root, agent_thread)

    Enum.reduce(commands, nil, fn active, previous_id ->
      assert {:ok, %{active: ^active}} =
               Marshall.Agents.ThreadTool.subscribe(creator.id, thread.id, active)

      [subscription] =
        Ledger.read!(Marshall.Agents.ThreadSubscription,
          owner_id: creator.id,
          thread_id: agent_thread.id
        )

      if previous_id, do: assert(subscription.id == previous_id)
      assert subscription.state == if(active, do: :active, else: :inactive)
      expected = if(active, do: {:ok, []}, else: {:error, :not_subscribed})
      assert Marshall.Agents.ThreadTool.replay(creator.id, thread.id, 0) == expected
      subscription.id
    end)
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
      Marshall.ThreadStateFixture.ready!(thread, %{
        machine_id: vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent_thread.id
      })

    thread = Ledger.update!(thread, :set_title, %{title: "Visible title"})

    :ok = Ledger.archive!(vm, :archive)
    assert Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id) == []

    assert [%{archived_at: %DateTime{}}] =
             Ledger.history!(Marshall.Compute.VirtualMachine, id: vm.id)

    Marshall.ThreadStateFixture.archived!(thread)
  end
end
