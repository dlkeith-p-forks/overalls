defmodule Marshall.Agents.ThreadAuditPrivacyTest do
  use Marshall.DataCase, async: false
  alias Marshall.Agents.{Root, Thread}
  alias Marshall.Compute.Ledger
  require Ash.Query

  test "agent thread versions preserve attribution without private titles or context" do
    %{owner: owner, vm: vm} = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [parent] = Ledger.read!(Thread, root_id: root.id)

    assert {:ok, thread} =
             Ledger.transaction(
               fn ->
                 thread =
                   Ledger.create!(Thread, :open, %{
                     root_id: root.id,
                     parent_thread_id: parent.id,
                     created_by_id: owner.id,
                     title: "private-title-fixture",
                     working_directory: "/private-path-fixture",
                     selected_skills: ["private-skill-fixture"]
                   })

                 Ledger.update!(thread, :set_context, %{
                   working_directory: "/replacement-private-path-fixture",
                   selected_skills: ["replacement-private-skill-fixture"]
                 })
               end,
               owner
             )

    versions = Ledger.read!(Thread.Version, version_source_id: thread.id)
    assert versions != []
    assert Enum.all?(versions, &(&1.actor_id == owner.id and &1.actor_kind == :user))

    Enum.each(versions, fn version ->
      refute Map.has_key?(version.changes, "title")
      refute Map.has_key?(version.changes, "working_directory")
      refute Map.has_key?(version.changes, "selected_skills")
      refute inspect(version.changes) =~ "private-"
    end)

    assert thread.title == "private-title-fixture"
    assert thread.working_directory == "/replacement-private-path-fixture"
  end

  test "user thread title updates do not copy content into PaperTrail history" do
    owner = Marshall.ComputeFixtures.user()

    assert {:ok, thread} =
             Ledger.transaction(
               fn ->
                 thread =
                   Ledger.create!(Marshall.Threads.Thread, :open, %{
                     creator_id: owner.id,
                     objective: "private-objective-fixture",
                     mode: :medium,
                     machine_spec: Marshall.ComputeFixtures.request(),
                     idempotency_key: Ash.UUID.generate(),
                     machine_key: Ash.UUID.generate()
                   })

                 Ledger.update!(thread, :set_title, %{title: "private-generated-title-fixture"})
               end,
               owner
             )

    # User-thread version reads have no application entry point; inspect only
    # the persisted test fixture without widening production audit authority.
    versions =
      Marshall.Threads.Thread.Version
      |> Ash.Query.filter(version_source_id == ^thread.id)
      |> Ash.read!(authorize?: false)

    assert versions != []

    Enum.each(versions, fn version ->
      refute Map.has_key?(version.changes, "title")
      refute inspect(version.changes) =~ "private-"
    end)

    assert thread.title == "private-generated-title-fixture"
  end
end
