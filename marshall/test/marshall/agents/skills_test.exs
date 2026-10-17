defmodule Marshall.Agents.SkillsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.User
  alias Marshall.Agents.{SkillInstallation, SkillOperation, SkillRevision, Skills}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}

  @type context :: %{
          owner: User.t(),
          member: User.t(),
          thread: Thread.t(),
          vm: VirtualMachine.t()
        }

  setup do
    %{owner: owner, vm: vm} = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})

    thread =
      Ledger.create!(Thread, :open, %{
        creator_id: owner.id,
        objective: "Review the project",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: Ash.UUID.generate(),
        machine_key: Ash.UUID.generate()
      })

    thread = Ledger.update!(thread, :bind_machine, %{machine_id: vm.id, status: :ready})
    %{owner: owner, member: user(), thread: thread, vm: vm}
  end

  test "manager-only mutation and current read grants remain separate", c do
    for role <- [:viewer, :operator] do
      grant = share(c, role)
      assert {:ok, %{items: []}} = Skills.list(c.thread.id, actor: c.member)
      assert {:error, :forbidden} = Skills.install(arguments(c), actor: c.member)
      Ledger.archive!(grant, :revoke)
    end

    share(c, :manager)
    assert {:ok, %SkillOperation{status: :queued}} = Skills.install(arguments(c), actor: c.member)
    assert {:error, :forbidden} = Skills.list(c.thread.id, actor: user())
  end

  test "immutable idempotency does not reenable a removed installation", c do
    args = arguments(c)
    assert {:ok, operation} = Skills.install(args, actor: c.owner)
    assert {:ok, same} = Skills.install(args, actor: c.owner)
    assert operation.id == same.id

    assert {:error, :idempotency_conflict} =
             Skills.install(%{args | subdirectory: "another"}, actor: c.owner)

    assert {:ok, _} = Skills.remove(change_operation(c, operation), actor: c.owner)
    assert {:ok, replay} = Skills.install(args, actor: c.owner)
    assert replay.id == operation.id
    assert {:ok, %{items: []}} = Skills.list(c.thread.id, actor: c.owner)
    assert [%{status: :removed}] = Ledger.read!(SkillInstallation, id: operation.installation_id)
  end

  test "failed updates preserve the pinned active revision and dispatch cannot repeat", c do
    operation = installed(c)
    [revision] = Ledger.read!(SkillRevision, id: operation.revision_id)
    assert revision.commit == String.duplicate("a", 40)
    assert {:ok, update} = Skills.update(change_operation(c, operation), actor: c.owner)

    assert {:ok, dispatched} =
             Skills.dispatch(update.id, fn _thread, _operation, wire ->
               assert wire["previous_path"] == revision.path
               assert wire["previous_digest"] == revision.digest
               Ash.UUID.generate()
             end)

    assert {:ok, replay} =
             Skills.dispatch(update.id, fn _, _, _ -> flunk("duplicate dispatch") end)

    assert replay.command_id == dispatched.command_id
    assert {:ok, %{status: :failed}} = Skills.fail(update.id, :fetch_failed)
    assert [installation] = Ledger.read!(SkillInstallation, id: operation.installation_id)
    assert installation.active_revision_id == revision.id
    assert length(Ledger.read!(SkillRevision, installation_id: installation.id)) == 1
  end

  test "manager revocation before publication refuses a successful guest result", c do
    grant = share(c, :manager)
    assert {:ok, operation} = Skills.install(arguments(c), actor: c.member)
    assert {:ok, _} = Skills.dispatch(operation.id, fn _, _, _ -> Ash.UUID.generate() end)
    assert Skills.command_allowed?(operation.id, c.member.id, c.vm.id)
    Ledger.archive!(grant, :revoke)
    refute Skills.command_allowed?(operation.id, c.member.id, c.vm.id)

    assert {:ok, %{status: :failed, failure_reason: :access_revoked}} =
             Skills.complete(operation.id, result(operation))

    assert Ledger.read!(SkillRevision, installation_id: operation.installation_id) == []
  end

  test "remove and rebind fence late results without altering old revisions", c do
    assert {:ok, operation} = Skills.install(arguments(c), actor: c.owner)
    assert {:ok, _} = Skills.dispatch(operation.id, fn _, _, _ -> Ash.UUID.generate() end)
    assert {:ok, _} = Skills.remove(change_operation(c, operation), actor: c.owner)

    assert {:ok, %{status: :failed, failure_reason: :stale_operation}} =
             Skills.complete(operation.id, result(operation))

    assert {:ok, operation} = Skills.install(arguments(c), actor: c.owner)
    assert {:ok, _} = Skills.dispatch(operation.id, fn _, _, _ -> Ash.UUID.generate() end)
    Ledger.update!(c.thread, :reopen, %{machine_key: Ash.UUID.generate()})

    assert {:ok, %{status: :failed, failure_reason: :machine_changed}} =
             Skills.complete(operation.id, result(operation))
  end

  test "ambiguous results reconcile from status without repeating installation", c do
    assert {:ok, operation} = Skills.install(arguments(c), actor: c.owner)
    assert {:ok, _} = Skills.dispatch(operation.id, fn _, _, _ -> Ash.UUID.generate() end)
    assert {:ok, %{status: :uncertain}} = Skills.fail(operation.id, :uncertain)

    assert {:ok, %{status: :uncertain}} =
             Skills.dispatch(operation.id, fn _, _, _ -> flunk("unsafe replay") end)

    assert {:ok, completed} = Skills.complete(operation.id, result(operation))
    assert completed.status == :completed
    assert {:ok, duplicate} = Skills.complete(operation.id, %{})
    assert duplicate.revision_id == completed.revision_id
  end

  test "replacement machine restoration pins the prior commit and digest", c do
    operation = installed(c)
    [old_revision] = Ledger.read!(SkillRevision, id: operation.revision_id)
    Ledger.update!(c.thread, :reopen, %{machine_key: Ash.UUID.generate()})
    thread_id = c.thread.id
    assert [^thread_id] = Skills.restoration_threads()
    assert [^thread_id] = Skills.restoration_threads(thread_id)
    assert {:ok, [restore]} = Skills.restore(c.thread.id)

    # A queued or terminal failed receipt owns this machine generation. The
    # coordinator must skip it so another replacement can make progress.
    assert Skills.restoration_threads() == []
    assert {:ok, %{status: :failed}} = Skills.fail(restore.id, :fetch_failed)
    assert Skills.restoration_threads() == []

    assert restore.request["source"]["revision"] == %{
             "kind" => "commit",
             "value" => old_revision.commit
           }

    assert restore.request["expected_digest"] == old_revision.digest
    assert {:ok, [same]} = Skills.restore(c.thread.id)
    assert same.id == restore.id
  end

  test "invalid repository and traversal inputs have no durable effects", c do
    for url <- [
          "https://unknown.test/x/y",
          "https://user:secret@github.com/x/y",
          "file:///tmp/skill"
        ] do
      assert {:error, _} = Skills.install(%{arguments(c) | url: url}, actor: c.owner)
    end

    for path <- ["../escape", "/absolute", "safe/../../escape", "C:\\Users\\other"] do
      assert {:error, :invalid_subdirectory} =
               Skills.install(%{arguments(c) | subdirectory: path}, actor: c.owner)
    end

    assert Ledger.read!(SkillOperation, thread_id: c.thread.id) == []
  end

  @spec installed(context()) :: SkillOperation.t()
  defp installed(c) do
    {:ok, operation} = Skills.install(arguments(c), actor: c.owner)
    {:ok, _} = Skills.dispatch(operation.id, fn _, _, _ -> Ash.UUID.generate() end)
    {:ok, complete} = Skills.complete(operation.id, result(operation))
    assert complete.status == :completed
    complete
  end

  @spec arguments(context()) :: map()
  defp arguments(c),
    do: %{
      thread_id: c.thread.id,
      url: "https://github.com/example/skills",
      subdirectory: "review",
      idempotency_key: Ash.UUID.generate()
    }

  @spec change_operation(context(), SkillOperation.t()) :: map()
  defp change_operation(c, operation),
    do: %{
      thread_id: c.thread.id,
      installation_id: operation.installation_id,
      idempotency_key: Ash.UUID.generate()
    }

  @spec result(SkillOperation.t()) :: map()
  defp result(operation) do
    path = "/var/lib/overalls/skills/" <> operation.installation_id <> "/revision"

    %{
      "version" => 1,
      "operation_id" => operation.id,
      "status" => "installed",
      "full_commit" => String.duplicate("a", 40),
      "content_digest" => String.duplicate("b", 64),
      "path" => path,
      "skill_file" => %{
        "path" => path <> "/SKILL.md",
        "digest" => String.duplicate("c", 64),
        "bytes" => 100,
        "header" => "---\nname: review\ndescription: Review project changes\n---\n"
      }
    }
  end

  @spec share(context(), atom()) :: Grant.t()
  defp share(c, role),
    do:
      Ledger.create!(Grant, :grant, %{
        thread_id: c.thread.id,
        user_id: c.member.id,
        role: role,
        granted_by_id: c.owner.id
      })
end
