defmodule Marshall.ThreadsMachineKeyTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{ArchiveWorker, ProvisionWorker, Thread}

  test "provisioning refuses missing or malformed keys without admitting a machine" do
    thread = thread()

    for args <- [
          %{"thread_id" => thread.id},
          %{"thread_id" => thread.id, "machine_key" => nil},
          %{"thread_id" => thread.id, "machine_key" => ""},
          %{"thread_id" => thread.id, "machine_key" => 1}
        ] do
      assert {:cancel, :invalid_job} = ProvisionWorker.perform(%Oban.Job{args: args})
    end

    assert [%Thread{status: :pending, machine_id: nil}] = Ledger.history!(Thread, id: thread.id)

    assert [] =
             Ledger.history!(Marshall.Compute.VirtualMachine,
               idempotency_key: thread.machine_key
             )
  end

  test "archival refuses missing or malformed keys without archiving the thread" do
    thread = Ledger.update!(thread(), :mark_deleting, %{status: :deleting})

    for args <- [
          %{"thread_id" => thread.id},
          %{"thread_id" => thread.id, "machine_key" => nil},
          %{"thread_id" => thread.id, "machine_key" => ""},
          %{"thread_id" => thread.id, "machine_key" => 1}
        ] do
      assert {:cancel, :invalid_job} = ArchiveWorker.perform(%Oban.Job{args: args})
    end

    assert [%Thread{status: :deleting, archived_at: nil}] = Ledger.history!(Thread, id: thread.id)
  end

  test "an archive job from an older generation cannot archive the current thread" do
    thread = Ledger.update!(thread(), :mark_deleting, %{status: :deleting})

    assert :ok =
             ArchiveWorker.perform(%Oban.Job{
               args: %{"thread_id" => thread.id, "machine_key" => Ash.UUID.generate()}
             })

    assert [%Thread{status: :deleting, archived_at: nil}] = Ledger.history!(Thread, id: thread.id)

    assert :ok =
             ArchiveWorker.perform(%Oban.Job{
               args: %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
             })

    assert [%Thread{status: :archived, archived_at: %DateTime{}}] =
             Ledger.history!(Thread, id: thread.id)
  end

  test "thread creation requires an explicit machine admission key" do
    actor = user()

    changeset =
      Ash.Changeset.for_create(
        Thread,
        :open,
        %{
          creator_id: actor.id,
          objective: "Inspect the deployment",
          mode: :medium,
          machine_spec: request(),
          idempotency_key: Ash.UUID.generate()
        },
        actor: SystemActor.compute()
      )

    assert {:error,
            %Ash.Error.Invalid{
              errors: [%Ash.Error.Changes.Required{field: :machine_key}]
            }} = Ash.create(changeset)
  end

  test "the database refuses a missing machine admission key" do
    actor = user()

    assert {:ok, thread} =
             Marshall.Threads.create_thread(
               %{
                 objective: "Inspect the deployment",
                 mode: :medium,
                 machine_spec: request(),
                 idempotency_key: Ash.UUID.generate()
               },
               actor: actor
             )

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :not_null_violation, column: "machine_key"}
            }} =
             Ecto.Adapters.SQL.query(
               Marshall.Repo,
               "UPDATE threads SET machine_key = NULL WHERE id = $1",
               [Ecto.UUID.dump!(thread.id)],
               log: false
             )
  end

  @spec thread() :: Thread.t()
  defp thread do
    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Inspect the deployment",
          mode: :medium,
          machine_spec: request(),
          idempotency_key: Ash.UUID.generate()
        },
        actor: user()
      )

    thread
  end
end
