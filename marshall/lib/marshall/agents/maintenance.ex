defmodule Marshall.Agents.Maintenance do
  @moduledoc "Conversation-independent, current-execution-fenced managed tool installation authority."
  alias Marshall.Agents.{Executor, ExecutorSession, ToolMaintenance}
  alias Marshall.Compute.{Image, Ledger, VirtualMachine}
  alias OverallsProtocol.GitHubTools
  require Marshall.Events

  @type binding :: OverallsProtocol.PrivateServices.binding()
  @type descriptor :: %{name: String.t(), sha256: String.t(), bytes: pos_integer()}
  @type offer :: %{
          id: String.t(),
          kind: String.t(),
          generation: String.t(),
          platform: GitHubTools.platform(),
          files: [descriptor()]
        }
  @type claim_result :: %{maintenance: offer() | nil}
  @type transition_result :: %{maintenance_id: String.t(), status: atom()}
  @type artifact_result :: %{sha256: String.t(), bytes: pos_integer(), generation: String.t()}

  @outcomes ~w(installed already_current rolled_back invalid_artifact activation_failed unsupported interrupted stale_fence)

  # @cc [owner:ghuntley,label:security;recovery] maintenance-current-execution
  # Claim and transition MUST hold the VM and executor lease locks, require the
  # managed-tool capability, and use the catalog image's validated platform.
  # No running conversation is required. A new generation or executor MAY
  # reconcile the idempotent installer; stale receipts MUST NOT complete the
  # replacement attempt or authorize artifacts for another VM or generation.
  @spec claim_locked!(binding(), String.t(), pos_integer(), GitHubTools.release()) ::
          claim_result()
  def claim_locked!(binding, executor_id, fence, release) do
    {executor, vm} = lease!(binding, executor_id, fence)
    platform = platform!(vm)
    files = Map.get(release.platforms, platform) || Ledger.rollback(:unavailable)
    row = row!(vm, release.generation, platform)

    row =
      if row.phase in [:completed, :failed] and
           (row.executor_id != executor.id or row.fence_epoch != fence) do
        reset!(row, release.generation, platform)
      else
        row
      end

    cond do
      row.phase in [:completed, :failed] and row.generation == release.generation ->
        %{maintenance: nil}

      row.phase == :claimed and row.executor_id == executor.id and row.fence_epoch == fence ->
        view(row, files)

      row.phase == :started and row.executor_id == executor.id and
          row.fence_epoch == fence ->
        %{maintenance: nil}

      true ->
        row =
          if row.phase in [:claimed, :started] do
            uncertain = Ledger.update!(row, :uncertain, %{outcome: :interrupted})
            log_transition(uncertain)
            uncertain
          else
            row
          end

        row =
          Ledger.update!(row, :claim, %{
            attempt_id: Ash.UUID.generate(),
            executor_id: executor.id,
            fence_epoch: fence,
            placement_id: vm.current_placement_id,
            execution_epoch: vm.execution_epoch
          })

        log_transition(row)
        view(row, files)
    end
  end

  @spec transition_locked!(
          binding(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          map(),
          GitHubTools.release()
        ) :: transition_result()
  def transition_locked!(binding, executor_id, fence, attempt_id, status, result, release) do
    {executor, vm} = lease!(binding, executor_id, fence)
    row = find_locked!(vm.id)
    previous_phase = row && row.phase

    unless row && row.generation == release.generation && row.attempt_id == attempt_id &&
             row.executor_id == executor.id &&
             row.fence_epoch == fence && row.placement_id == vm.current_placement_id &&
             row.execution_epoch == vm.execution_epoch,
           do: Ledger.rollback(:stale_fence)

    row =
      case {status, row.phase} do
        {"started", :claimed} ->
          unless result == %{}, do: Ledger.rollback(:invalid_request)
          Ledger.update!(row, :start, %{})

        {"started", :started} ->
          unless result == %{}, do: Ledger.rollback(:invalid_request)
          row

        {"completed", :started} ->
          {outcome, previous} = receipt!(row, result)
          unless outcome in [:installed, :already_current], do: Ledger.rollback(:invalid_request)
          Ledger.update!(row, :complete, %{outcome: outcome, previous_generation: previous})

        {"completed", :completed} ->
          {outcome, previous} = receipt!(row, result)

          unless row.outcome == outcome and row.previous_generation == previous,
            do: Ledger.rollback(:invalid_request)

          row

        {"failed", phase} when phase in [:claimed, :started] ->
          {outcome, _previous} = receipt!(row, result)

          unless outcome not in [:installed, :already_current],
            do: Ledger.rollback(:invalid_request)

          Ledger.update!(row, :fail, %{outcome: outcome})

        {"failed", :failed} ->
          {outcome, _previous} = receipt!(row, result)
          unless row.outcome == outcome, do: Ledger.rollback(:invalid_request)
          row

        _ ->
          Ledger.rollback(:invalid_transition)
      end

    if row.phase != previous_phase, do: log_transition(row)
    %{maintenance_id: row.attempt_id, status: row.phase}
  end

  @spec artifact_locked!(
          binding(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          GitHubTools.release()
        ) :: artifact_result()
  def artifact_locked!(binding, executor_id, fence, attempt_id, digest, release) do
    {executor, vm} = lease!(binding, executor_id, fence)
    row = find_locked!(vm.id)

    unless row && row.phase in [:claimed, :started] && row.attempt_id == attempt_id &&
             row.executor_id == executor.id && row.fence_epoch == fence &&
             row.generation == release.generation && row.placement_id == vm.current_placement_id &&
             row.execution_epoch == vm.execution_epoch,
           do: Ledger.rollback(:stale_fence)

    file =
      Enum.find(Map.fetch!(release.platforms, row.platform), &(&1.sha256 == digest)) ||
        Ledger.rollback(:unauthorized)

    %{sha256: file.sha256, bytes: file.bytes, generation: row.generation}
  end

  # @cc [owner:ghuntley,label:observability] maintenance-committed-transition
  # Installation diagnostics MUST contain only safe identifiers and closed
  # phases, emit after the outer commit, and omit unchanged repeated receipts.
  @spec log_transition(ToolMaintenance.t()) :: :ok
  defp log_transition(row) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.installation_transition",
        vm_id: row.vm_id,
        attempt_id: row.attempt_id,
        executor_id: row.executor_id,
        kind: :maintenance,
        phase: row.phase
      )
    end)
  end

  @spec lease!(binding(), String.t(), pos_integer()) :: {Executor.t(), VirtualMachine.t()}
  defp lease!(binding, id, fence) do
    {executor, vm} = ExecutorSession.maintenance_lease!(binding, id, fence)

    unless "github-tools-v1" in executor.capabilities or
             Marshall.Agents.Bootstrap.authorized_locked?(vm.id, id, fence),
           do: Ledger.rollback(:executor_upgrade_required)

    {executor, vm}
  end

  @spec platform!(VirtualMachine.t()) :: GitHubTools.platform()
  defp platform!(vm) do
    capability =
      case Ledger.read!(Image, id: vm.image_id) do
        [image] -> Image.guest_agents_capability(image)
        _ -> {:error, :unavailable}
      end

    case capability do
      {:ok, :linux} -> "linux-amd64"
      {:ok, :windows_v1} -> "windows-amd64"
      {:ok, :freebsd_v1} -> "freebsd-amd64"
      {:ok, :illumos_v1} -> "illumos-amd64"
      _ -> Ledger.rollback(:unavailable)
    end
  end

  @spec row!(VirtualMachine.t(), String.t(), String.t()) :: ToolMaintenance.t()
  defp row!(vm, generation, platform) do
    case find_locked!(vm.id) do
      nil ->
        Ledger.create!(ToolMaintenance, :queue, %{
          vm_id: vm.id,
          generation: generation,
          platform: platform
        })

      %{generation: ^generation, platform: ^platform} = row ->
        row

      row ->
        reset!(row, generation, platform)
    end
  end

  @spec reset!(ToolMaintenance.t(), String.t(), String.t()) :: ToolMaintenance.t()
  defp reset!(row, generation, platform) do
    Ledger.update!(row, :reset, %{
      generation: generation,
      platform: platform,
      attempt_id: nil,
      executor_id: nil,
      fence_epoch: nil,
      placement_id: nil,
      execution_epoch: nil,
      previous_generation: nil,
      outcome: nil
    })
  end

  @spec view(ToolMaintenance.t(), [GitHubTools.file()]) :: claim_result()
  defp view(row, files) do
    %{
      maintenance: %{
        id: row.attempt_id,
        kind: "github-tools",
        generation: row.generation,
        platform: row.platform,
        files: Enum.map(files, &Map.take(&1, [:name, :sha256, :bytes]))
      }
    }
  end

  @spec find_locked!(String.t()) :: ToolMaintenance.t() | nil
  defp find_locked!(vm_id) do
    case Ledger.read!(ToolMaintenance, vm_id: vm_id) do
      [row] -> Ledger.lock!(ToolMaintenance, row.id)
      [] -> nil
    end
  end

  @spec receipt!(ToolMaintenance.t(), map()) :: {atom(), String.t() | nil}
  defp receipt!(row, result) do
    unless Map.keys(result) -- ~w(generation outcome previous_generation) == [] &&
             result["generation"] == row.generation && result["outcome"] in @outcomes &&
             (is_nil(result["previous_generation"]) or
                GitHubTools.digest?(result["previous_generation"])),
           do: Ledger.rollback(:invalid_request)

    outcome =
      Enum.find(
        [
          :installed,
          :already_current,
          :rolled_back,
          :invalid_artifact,
          :activation_failed,
          :unsupported,
          :interrupted,
          :stale_fence
        ],
        &(Atom.to_string(&1) == result["outcome"])
      )

    {outcome, result["previous_generation"]}
  end
end
