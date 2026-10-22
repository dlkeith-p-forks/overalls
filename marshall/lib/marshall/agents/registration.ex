defmodule Marshall.Agents.Registration do
  @moduledoc "Register eligible VM agents in the VM admission transaction."
  alias Marshall.Agents.{AuditEvent, Root, Thread}
  alias Marshall.Compute.{Ledger, VirtualMachine}

  # @cc [owner:ghuntley,label:architecture;durability] agent-registration-atomic
  # An eligible VM and its root thread MUST commit together. Customer VMs MUST
  # never acquire an agent root, even when their owner is otherwise authorized.
  @spec register!(VirtualMachine.t()) :: Root.t() | nil
  def register!(%VirtualMachine{profile: profile} = vm)
      when profile in [:oss, :standard, :inception] do
    root = Ledger.create!(Root, :register, %{vm_id: vm.id, owner_id: vm.owner_id})

    thread_attrs = %{
      root_id: root.id,
      title: "Agent",
      created_by_id: vm.owner_id,
      mode: :medium
    }

    thread = Ledger.create!(Thread, :open, thread_attrs)

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: thread.id,
      actor_id: vm.owner_id,
      kind: :agent_registered,
      target_id: root.id,
      outcome: :accepted
    })

    root
  end

  def register!(%VirtualMachine{}), do: nil
end
