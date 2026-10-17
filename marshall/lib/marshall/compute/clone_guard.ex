defmodule Marshall.Compute.CloneGuard do
  @moduledoc "Clone exclusions under the caller's host/VM transaction locks."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.CloneRequest
  require Ash.Query

  # @cc [owner:ghuntley,label:concurrency;security] clone-unpublished-destination-fenced
  # Unpublished destinations MUST reject ordinary lifecycle and recovery. Source
  # start/stop may resume only after restoration; source destructive operations
  # and another copy MUST remain excluded until snapshot cleanup is confirmed.
  @spec lifecycle_busy?(String.t(), atom()) :: boolean()
  def lifecycle_busy?(id, kind) do
    requests(id)
    |> Enum.any?(fn request ->
      if request.source_vm_id == id,
        do: kind not in [:start, :stop] or is_nil(request.source_restored_at),
        else: is_nil(request.published_at)
    end)
  end

  @spec vm_busy?(String.t()) :: boolean()
  def vm_busy?(id), do: lifecycle_busy?(id, :delete)

  # @cc [owner:ghuntley,label:concurrency] clone-host-busy-until-publication
  # A host is clone-busy only while an active request has not published its
  # destination: until then a stream may still start or resume. After
  # publication the copy is an ordinary machine and the remaining prune work
  # never needs the host's transfer slot, so drains, evacuations and other
  # transfers proceed; the source itself stays excluded at VM level.
  @spec host_busy?(String.t()) :: boolean()
  def host_busy?(id) do
    CloneRequest
    |> Ash.Query.filter(
      active == true and is_nil(published_at) and
        (source_host_id == ^id or destination_host_id == ^id)
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.compute()) != []
  end

  # A completed request whose source snapshot prune has not confirmed keeps
  # excluding the source from destructive work and from another copy.
  defp requests(id) do
    CloneRequest
    |> Ash.Query.filter(
      (active == true and (source_vm_id == ^id or destination_vm_id == ^id)) or
        (source_vm_id == ^id and phase == :complete and is_nil(cleanup_completed_at))
    )
    |> Ash.read!(actor: SystemActor.compute())
  end
end
