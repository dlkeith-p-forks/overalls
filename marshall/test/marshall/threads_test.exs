defmodule Marshall.ThreadsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Threads.{MachineSpec, Mode, Title}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.ProvisionWorker

  test "modes are closed and medium is the default" do
    assert Mode.default() == :medium
    assert Mode.values() == [:low, :medium, :high, :ultra]
    assert Mode.parse("high") == {:ok, :high}
    assert Mode.parse("unknown") == {:error, :invalid_mode}
    assert Mode.model(:medium) == "gpt-6-sol"
    assert Mode.reasoning_effort(:high) == :high
  end

  test "machine specifications normalize browser values into typed admission input" do
    assert {:ok, spec} =
             MachineSpec.from_map(%{
               "profile" => "standard",
               "image_id" => "sha256:" <> String.duplicate("a", 64),
               "vcpu" => "2",
               "memory_bytes" => 4_294_967_296,
               "disk_bytes" => 42_949_672_960,
               "team_id" => nil
             })

    assert spec.profile == :standard
    assert spec.vcpu == 2
    assert MachineSpec.from_map(%{"profile" => "standard"}) == {:error, :invalid_machine_spec}
  end

  test "machine specifications reject customer agents and out of range shapes" do
    base = %{
      "architecture" => "x86_64",
      "profile" => "standard",
      "image_id" => "sha256:" <> String.duplicate("a", 64),
      "vcpu" => 2,
      "memory_bytes" => 4_294_967_296,
      "disk_bytes" => 42_949_672_960
    }

    assert MachineSpec.from_map(%{base | "profile" => "customer"}) == {:error, :invalid_profile}

    assert MachineSpec.from_map(%{base | "architecture" => "aarch64"}) ==
             {:error, :invalid_machine_spec}

    assert MachineSpec.from_map(%{base | "memory_bytes" => 1}) == {:error, :invalid_machine_spec}
    assert MachineSpec.from_map(%{base | "vcpu" => 64}) == {:error, :invalid_machine_spec}
  end

  test "invalid machine specification creates neither a thread nor a provisioning job" do
    actor = user()
    arguments = thread_arguments()
    arguments = %{arguments | machine_spec: Map.put(arguments.machine_spec, :vcpu, 64)}

    assert_thread_error(
      Marshall.Threads.create_thread(arguments, actor: actor),
      :invalid_machine_spec
    )

    assert Ledger.read!(Marshall.Threads.Thread, idempotency_key: arguments.idempotency_key) == []
    assert Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: ProvisionWorker) == []
  end

  test "title generation is bounded and has a prompt-derived fallback" do
    assert Title.fallback("Fix the terminal. Ignore this second sentence") == "Fix the terminal"
    assert byte_size(Title.generate(String.duplicate("x", 300))) <= 120
  end

  test "thread creation commits a pending record and reuses its idempotency key" do
    actor = Marshall.ComputeFixtures.user()

    arguments = %{
      objective: "Inspect the failing deployment",
      mode: :high,
      machine_spec: %{
        architecture: :x86_64,
        profile: :standard,
        image_id: "sha256:" <> String.duplicate("a", 64),
        vcpu: 2,
        memory_bytes: 4_294_967_296,
        disk_bytes: 42_949_672_960,
        team_id: nil
      },
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, first} = Marshall.Threads.create_thread(arguments, actor: actor)
    assert first.status == :pending
    assert first.mode == :high

    assert {:ok, second} = Marshall.Threads.create_thread(arguments, actor: actor)
    assert second.id == first.id

    assert {:error, _} =
             Marshall.Threads.create_thread(
               %{arguments | objective: "A different objective"},
               actor: actor
             )
  end

  test "team membership is required to create a team-scoped thread" do
    owner = user()
    outsider = user()

    assert {:ok, team} =
             Marshall.Teams.create_team(
               %{name: "threads-#{Ash.UUID.generate()}", idempotency_key: Ash.UUID.generate()},
               actor: owner
             )

    assert_thread_error(
      Marshall.Threads.create_thread(thread_arguments(team_id: team.id), actor: outsider),
      :forbidden
    )
  end

  test "visible thread history is not hidden by newer threads owned by other users" do
    actor = user()
    outsider = user()
    assert {:ok, owned} = Marshall.Threads.create_thread(thread_arguments(), actor: actor)

    for _ <- 1..101 do
      assert {:ok, _foreign} =
               Marshall.Threads.create_thread(thread_arguments(), actor: outsider)
    end

    assert {:ok, [%{id: thread_id}]} = Marshall.Threads.list_threads(%{limit: 100}, actor: actor)
    assert thread_id == owned.id
  end

  # @cc [owner:ghuntley,label:verification;durability] thread-page-cursor-scope
  # Keyset pages MUST continue after an authorized cursor in stable newest-first
  # order, while a foreign cursor returns an empty page without widening scope.
  test "authorized thread pages use a stable keyset cursor" do
    actor = user()
    outsider = user()

    assert {:ok, first} = Marshall.Threads.create_thread(thread_arguments(), actor: actor)
    assert {:ok, second} = Marshall.Threads.create_thread(thread_arguments(), actor: actor)
    assert {:ok, third} = Marshall.Threads.create_thread(thread_arguments(), actor: actor)

    assert {:ok, %{items: first_page, next_cursor: cursor}} =
             Marshall.Threads.list_thread_page(%{limit: 2}, actor: actor)

    assert length(first_page) == 2
    assert is_binary(cursor)
    assert Enum.map(first_page, & &1.id) == [third.id, second.id]

    assert {:ok, %{items: second_page, next_cursor: nil}} =
             Marshall.Threads.list_thread_page(%{limit: 2, after: cursor}, actor: actor)

    assert Enum.map(second_page, & &1.id) == [first.id]

    assert {:ok, %{items: [], next_cursor: nil}} =
             Marshall.Threads.list_thread_page(%{limit: 2, after: first.id}, actor: outsider)
  end

  test "idempotency replay rejects a changed machine specification" do
    actor = user()
    key = Ash.UUID.generate()
    arguments = thread_arguments(idempotency_key: key)

    assert {:ok, first} = Marshall.Threads.create_thread(arguments, actor: actor)

    assert_thread_error(
      Marshall.Threads.create_thread(
        %{arguments | machine_spec: Map.put(arguments.machine_spec, :vcpu, 4)},
        actor: actor
      ),
      :idempotency_conflict
    )

    assert first.id == hd(Ledger.read!(Marshall.Threads.Thread, idempotency_key: key)).id
  end

  test "a ready thread routes prompts to its bound agent thread" do
    host_fixture()
    actor = user()
    arguments = thread_arguments()
    assert {:ok, thread} = Marshall.Threads.create_thread(arguments, actor: actor)

    assert {:snooze, 5} =
             Oban.Testing.perform_job(
               ProvisionWorker,
               %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
               repo: Marshall.Repo
             )

    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    assert Ledger.read!(Marshall.Agents.Turn, actor_id: actor.id) == []
    Ledger.update!(vm, :observe, %{observed_state: :running})

    assert :ok =
             Oban.Testing.perform_job(
               ProvisionWorker,
               %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
               repo: Marshall.Repo
             )

    [ready] = Ledger.read!(Marshall.Threads.Thread, id: thread.id)
    request_key = Ash.UUID.generate()

    assert {:ok, %{turn_id: turn_id}} =
             Marshall.Threads.submit_prompt(
               %{thread_id: ready.id, prompt: "Check the deployment", request_key: request_key},
               actor: actor
             )

    assert [%{thread_id: agent_thread_id, actor_id: actor_id, prompt: "Check the deployment"}] =
             Ledger.read!(Marshall.Agents.Turn, id: turn_id)

    assert agent_thread_id == ready.agent_thread_id
    assert actor_id == actor.id

    assert {:ok, %{turn_id: ^turn_id}} =
             Marshall.Threads.submit_prompt(
               %{thread_id: ready.id, prompt: "Check the deployment", request_key: request_key},
               actor: actor
             )
  end

  test "retry resets a failed thread and archive requires current creator" do
    actor = user()
    stranger = user()
    assert {:ok, thread} = Marshall.Threads.create_thread(thread_arguments(), actor: actor)

    failed =
      Ledger.update!(thread, :mark_failed, %{status: :failed, failure_reason: :capacity})

    assert_thread_error(
      Marshall.Threads.archive_thread(%{thread_id: failed.id}, actor: stranger),
      :forbidden
    )

    assert {:ok, %{status: :pending}} =
             Marshall.Threads.retry_provisioning(%{thread_id: failed.id}, actor: actor)

    assert Enum.any?(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: ProvisionWorker),
             &(&1.args == %{"thread_id" => failed.id, "machine_key" => failed.machine_key})
           )

    assert {:ok, %{status: :archived, archived_at: %DateTime{}}} =
             Marshall.Threads.archive_thread(%{thread_id: failed.id}, actor: actor)
  end

  defp thread_arguments(overrides \\ []) do
    request = request()
    team_id = Keyword.get(overrides, :team_id)

    Map.merge(
      %{
        objective: "Inspect the failing deployment",
        mode: :medium,
        machine_spec: Map.put(request, :team_id, team_id),
        idempotency_key: request.idempotency_key
      },
      overrides |> Keyword.delete(:team_id) |> Map.new()
    )
  end

  defp assert_thread_error({:error, error}, reason) when is_atom(error),
    do: assert(error == reason)

  defp assert_thread_error({:error, error}, reason) do
    assert Exception.message(error) =~ Atom.to_string(reason)
  end

  test "reopening an archived thread clears the old binding and queues a fresh admission" do
    host_fixture()
    actor = Marshall.ComputeFixtures.user()

    assert {:ok, thread} =
             Marshall.Threads.create_thread(
               %{
                 objective: "Reopen this task",
                 mode: :medium,
                 machine_spec: Marshall.ComputeFixtures.request(),
                 idempotency_key: Ash.UUID.generate()
               },
               actor: actor
             )

    {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)

    bound =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent_thread.id,
        status: :ready
      })

    :ok = Ledger.archive!(vm, :archive)

    assert {:ok, archived} =
             Marshall.Threads.archive_thread(%{thread_id: bound.id}, actor: actor)

    assert archived.status == :archived
    assert archived.machine_id == vm.id
    original_machine_key = archived.machine_key

    assert {:ok, reopened} =
             Marshall.Threads.reopen_thread(%{thread_id: archived.id}, actor: actor)

    assert reopened.status == :pending
    assert is_nil(reopened.archived_at)
    assert is_nil(reopened.machine_id)
    assert is_nil(reopened.agent_root_id)
    assert is_nil(reopened.agent_thread_id)
    assert reopened.idempotency_key == archived.idempotency_key
    assert reopened.machine_key != original_machine_key

    assert Enum.any?(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: ProvisionWorker),
             &(&1.args == %{"thread_id" => archived.id, "machine_key" => reopened.machine_key})
           )
  end

  test "provision worker binds the creator and root agent thread" do
    host_fixture()
    actor = user()
    request = request()

    arguments = %{
      objective: "Inspect the failing deployment",
      mode: :medium,
      machine_spec: Map.put(request, :team_id, nil),
      idempotency_key: request.idempotency_key
    }

    assert {:ok, thread} = Marshall.Threads.create_thread(arguments, actor: actor)

    assert {:snooze, 5} =
             Oban.Testing.perform_job(
               ProvisionWorker,
               %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
               repo: Marshall.Repo
             )

    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    assert Ledger.read!(Marshall.Agents.Turn, actor_id: actor.id) == []
    Ledger.update!(vm, :observe, %{observed_state: :running})

    assert :ok =
             Oban.Testing.perform_job(
               ProvisionWorker,
               %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
               repo: Marshall.Repo
             )

    [ready] = Ledger.read!(Marshall.Threads.Thread, id: thread.id)
    assert ready.status == :ready
    assert is_binary(ready.machine_id)
    assert is_binary(ready.agent_root_id)
    assert is_binary(ready.agent_thread_id)
    machine_id = ready.machine_id

    assert :ok =
             Oban.Testing.perform_job(
               ProvisionWorker,
               %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
               repo: Marshall.Repo
             )

    assert [%{id: ^machine_id}] =
             Ledger.history!(VirtualMachine, idempotency_key: request.idempotency_key)

    assert [%{prompt: "Inspect the failing deployment", thread_id: agent_thread_id}] =
             Ledger.read!(Marshall.Agents.Turn,
               request_key: "thread-initial:" <> thread.id,
               actor_id: actor.id
             )

    assert agent_thread_id == ready.agent_thread_id
  end
end
