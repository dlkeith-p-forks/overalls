defmodule Marshall.Compute.CommandSnapshot do
  @moduledoc "Pin executable payload at operation creation, before its durable dispatch job."
  use Ash.Resource.Change

  alias Marshall.Compute.{
    Image,
    Ledger,
    NetworkAddress,
    VirtualMachine,
    WorkloadPlacement,
    WorkspaceSource
  }

  # @cc [owner:ghuntley,label:recovery] operation-command-snapshot-immutable
  # Enqueue MUST retain a validated complete command matching operation authority.
  # Later VM size changes MUST NOT rewrite a previously accepted operation payload.
  # Owning-user metadata MUST match the authoritative VM owner, never the
  # requesting administrator or caller-supplied snapshot identity. The executable
  # image MUST match the VM's retained immutable image, including supplied starts.
  @impl true
  def change(changeset, _, _) do
    changeset =
      Ash.Changeset.force_change_attribute(
        changeset,
        :id,
        Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()
      )

    fields =
      Map.new(
        [:id, :vm_id, :placement_id, :execution_epoch, :generation, :kind],
        &{&1, Ash.Changeset.get_attribute(changeset, &1)}
      )

    [placement] = Ledger.read!(WorkloadPlacement, id: fields.placement_id, vm_id: fields.vm_id)
    [vm] = Ledger.history!(VirtualMachine, id: fields.vm_id)

    fields =
      Map.merge(fields, %{
        host_id: placement.host_id,
        pool_id: placement.pool_id,
        owner_id: vm.owner_id,
        image_id: vm.image_id
      })

    snapshot =
      (Ash.Changeset.get_attribute(changeset, :command_snapshot) || build(fields))
      |> Map.put_new("owner_id", vm.owner_id)

    clone = Ash.Changeset.get_attribute(changeset, :clone_request_id)

    snapshot =
      if clone && fields.kind == :start, do: Map.put(snapshot, "clone_id", clone), else: snapshot

    with {:ok, command} <- OverallsProtocol.Execution.command(snapshot),
         true <- Map.take(command, Map.keys(fields)) == fields do
      snapshot =
        command
        |> Map.delete(:git_identity)
        |> put_git_identity(vm)
        |> Map.delete(:workspace_source)
        |> put_workspace_source(vm)
        |> OverallsProtocol.Execution.encode_command()

      Ash.Changeset.force_change_attribute(changeset, :command_snapshot, snapshot)
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :command_snapshot,
          message: "invalid command authority"
        )
    end
  end

  @doc "Builds the encoded executable command for operation authority fields."
  @spec build(map()) :: map()
  def build(fields) do
    [vm] = Ledger.history!(VirtualMachine, id: fields.vm_id)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

    fields
    |> Map.merge(
      Map.take(vm, [:architecture, :profile, :vcpu, :memory_bytes, :disk_bytes, :image_id])
    )
    |> Map.put(:slot, address.slot)
    |> put_git_identity(vm)
    |> put_workspace_source(vm)
    |> OverallsProtocol.Execution.encode_command()
  end

  # @cc [owner:ghuntley,label:security;protocol] command-snapshot-git-identity
  # Provision and start commands MUST use only the authoritative immutable VM Git
  # identity and require its content-bound image capability. Caller identity MUST
  # be removed before rebuilding the command; VMs without a snapshot and other
  # command kinds MUST omit it. The identity remains inert guest configuration.
  @spec put_git_identity(map(), VirtualMachine.t()) :: map()
  defp put_git_identity(%{kind: kind} = fields, %{git_identity: identity} = vm)
       when kind in [:provision, :start] and not is_nil(identity) do
    Marshall.Compute.GitIdentity.require_image!(vm.image_id)

    case OverallsProtocol.GitIdentity.decode(identity) do
      {:ok, validated} -> Map.put(fields, :git_identity, validated)
      _ -> Ledger.rollback(:invalid_git_identity)
    end
  end

  defp put_git_identity(fields, _vm), do: fields

  # @cc [owner:ghuntley,label:security] command-snapshot-workspace-source
  # Provision and start commands for a VM with a recorded workspace source MUST
  # carry that stored reference; other operation kinds and VMs without a source,
  # including clones, MUST NOT. A new source-bearing snapshot MUST require the
  # matching durable manifest4/catalog identity and source2 capability, even for
  # retained starts; no staging lookup or immutable-snapshot rewrite is allowed.
  # Explicitly supplied snapshots MUST use the authoritative stored source too;
  # caller-provided source data MUST NOT replace it or source an unsourced VM.
  # The reference remains inert guest data (ADR-0157).
  @spec put_workspace_source(map(), VirtualMachine.t()) :: map()
  defp put_workspace_source(%{kind: kind} = fields, vm) when kind in [:provision, :start] do
    case Ledger.read!(WorkspaceSource, vm_id: vm.id) do
      [source] ->
        require_source_image!(vm.image_id)
        Map.put(fields, :workspace_source, WorkspaceSource.protocol(source))

      [] ->
        fields
    end
  end

  defp put_workspace_source(fields, _vm), do: fields

  @spec require_source_image!(String.t()) :: :ok
  defp require_source_image!(image_id) do
    if source_image_available?(image_id),
      do: :ok,
      else: Ledger.rollback(:workspace_source_unavailable)
  end

  @doc "Checks source-image eligibility without changing restart or physical-outcome authority."
  # @cc [owner:ghuntley,label:recovery;security] source-restart-preflight-no-effects
  # Coordinators MUST distinguish unavailable source capability before creating
  # restart intent, preserving accepted physical outcomes and host reports. This
  # read-only check MUST NOT consult staging or require an enabled catalog flag;
  # final source-bearing snapshot validation MUST still enforce the same identity.
  @spec workspace_source_available?(VirtualMachine.t()) :: boolean()
  def workspace_source_available?(vm) do
    case Ledger.read!(WorkspaceSource, vm_id: vm.id) do
      [] -> true
      [_source] -> source_image_available?(vm.image_id)
    end
  end

  @spec source_image_available?(String.t()) :: boolean()
  defp source_image_available?(image_id) do
    with [image] <- Ledger.read!(Image, id: image_id),
         {:ok, %{id: ^image_id, workspace_source_version: 2}} <-
           OverallsProtocol.ImageManifest.validate(image.manifest) do
      true
    else
      _ -> false
    end
  end
end
