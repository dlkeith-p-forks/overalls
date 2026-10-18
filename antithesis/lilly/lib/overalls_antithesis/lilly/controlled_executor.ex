defmodule OverallsAntithesis.Lilly.ControlledExecutor do
  @moduledoc """
  Durable controlled operation publication; no guest or native execution proof.

  Under the `admission-stub` profile only, a labelled **STUB** lets a delete
  settle for a placement this executor observably never created anything for,
  so Marshall's real delete, release and archive path can run. It is never
  cleanup, KVM, ZFS or physical-absence evidence for anything that existed.
  """
  @behaviour Lilly.VM.Executor
  alias Lilly.Control.Config
  alias Lilly.Host.PrivateFiles
  alias OverallsAntithesis.Lilly.StubStorage

  @delete_env "OVERALLS_ANTITHESIS_STUB_DELETE"
  @publication_scope "controlled_operation_publication_only"
  @absence_scope "controlled_absence_attestation_stub_not_physical"
  @deleted %{
    state: :deleted,
    compute_empty: true,
    disk_present: false,
    cleanup_complete: true,
    reason: :none
  }

  @type effect :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  # @cc [owner:ghuntley,label:recovery;verification] controlled-effect-before-receipt
  # Publication records requested work before returning. It does not prove
  # physical absence, cleanup, a VM, native disk, boot or readiness. Every
  # lifecycle outcome remains unavailable until independently observed, except
  # the attested stub delete below.
  @impl true
  @spec reconcile(Config.t(), OverallsProtocol.Execution.command(), map()) ::
          Lilly.VM.Executor.result()
  def reconcile(config, command, history) do
    case publish(config, command) do
      :ok -> settle(config, command, history, StubStorage.read(), System.get_env(@delete_env))
      _ -> {:retry, :execution_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery;verification] stub-delete-attests-only-observed-absence
  # Only a :delete under the admission-stub profile (a valid stub substrate AND
  # the explicit OVERALLS_ANTITHESIS_STUB_DELETE=1 opt-in) MAY settle, and only
  # with the deleted facts, after observing a controlled pool, a journal that
  # never recorded running for the placement, publication-only controlled
  # records for the placement and no native per-placement execution state. Any
  # other kind, profile or unknown fact MUST stay retry; this executor never
  # reports running or failed.
  @doc false
  @spec settle(
          Config.t(),
          OverallsProtocol.Execution.command(),
          map(),
          {:ok, StubStorage.t()} | :disabled | {:error, atom()},
          String.t() | nil
        ) :: Lilly.VM.Executor.result()
  def settle(config, %{kind: :delete} = command, history, {:ok, _stub}, "1") do
    with true <- controlled_pool?(config, command.pool_id),
         %{running_epoch: 0, running_generation: 0} <- history,
         :ok <- publications_only(config, command.placement_id),
         :ok <- native_state_absent(config, command.placement_id),
         :ok <- attest(config, command) do
      {:ok, @deleted}
    else
      _ -> {:retry, :execution_unavailable}
    end
  end

  def settle(_config, _command, _history, _substrate, _opt_in),
    do: {:retry, :execution_unavailable}

  @impl true
  @spec boot_proof(Config.t(), OverallsProtocol.Execution.command()) :: {:error, :not_launched}
  def boot_proof(_config, _command), do: {:error, :not_launched}

  @impl true
  @spec watch_target(Config.t(), OverallsProtocol.Execution.command()) :: :error
  def watch_target(_config, _command), do: :error

  @impl true
  @spec terminal_options(Config.t(), OverallsProtocol.Execution.command()) ::
          {:error, :terminal_unavailable}
  def terminal_options(_config, _command), do: {:error, :terminal_unavailable}

  @impl true
  @spec open_ingress(Config.t(), OverallsProtocol.Execution.command(), map()) ::
          {:error, :ingress_unavailable}
  def open_ingress(_config, _command, _binding), do: {:error, :ingress_unavailable}

  @doc "Path to the independently inspectable controlled publication for one operation."
  @spec proof_path(Config.t(), OverallsProtocol.uuid()) :: Path.t()
  def proof_path(config, operation_id),
    do: Path.join([config.state_dir, "controlled-effects", operation_id <> ".json"])

  defp publish(config, command) do
    with true <- OverallsProtocol.uuid?(command.id),
         true <- OverallsProtocol.uuid?(command.placement_id),
         true <- command.kind in [:provision, :start, :resize, :stop, :delete],
         path = proof_path(config, command.id),
         directory = Path.dirname(path),
         :ok <- PrivateFiles.directory(directory),
         proof = effect(command),
         encoded = JSON.encode!(proof),
         :ok <- publish_once(directory, path, encoded) do
      :ok
    else
      _ -> {:error, :effect_unconfirmed}
    end
  end

  @doc "Independently inspectable record that a stub delete settled on observed absence only."
  @spec absence_path(Config.t(), OverallsProtocol.uuid()) :: Path.t()
  def absence_path(config, operation_id),
    do: Path.join([config.state_dir, "controlled-absence", operation_id <> ".json"])

  @spec controlled_pool?(Config.t(), OverallsProtocol.uuid()) :: boolean()
  defp controlled_pool?(%Config{pools: pools}, pool_id) when is_list(pools),
    do: Enum.any?(pools, &(&1.id == pool_id and &1.backend == :controlled))

  defp controlled_pool?(_config, _pool_id), do: false

  @spec publications_only(Config.t(), OverallsProtocol.uuid()) :: :ok | {:error, atom()}
  defp publications_only(config, placement_id) do
    directory = Path.join(config.state_dir, "controlled-effects")

    case File.ls(directory) do
      {:ok, names} ->
        if Enum.all?(names, &publication_only?(Path.join(directory, &1), placement_id)),
          do: :ok,
          else: {:error, :effect_unconfirmed}

      _ ->
        {:error, :effect_unconfirmed}
    end
  end

  @spec publication_only?(Path.t(), OverallsProtocol.uuid()) :: boolean()
  defp publication_only?(path, placement_id) do
    with {:ok, bytes} <- PrivateFiles.read_secret(path),
         {:ok, %{"placement_id" => placement, "scope" => scope}} <- JSON.decode(bytes) do
      placement != placement_id or scope == @publication_scope
    else
      _ -> false
    end
  end

  @spec native_state_absent(Config.t(), OverallsProtocol.uuid()) :: :ok | {:error, atom()}
  defp native_state_absent(%Config{execution: %{state_dir: directory}}, placement_id)
       when is_binary(directory) do
    case File.lstat(Path.join(directory, placement_id)) do
      {:error, :enoent} -> :ok
      _ -> {:error, :effect_unconfirmed}
    end
  end

  defp native_state_absent(_config, _placement_id), do: {:error, :effect_unconfirmed}

  @spec attest(Config.t(), OverallsProtocol.Execution.command()) :: :ok | {:error, atom()}
  defp attest(config, command) do
    path = absence_path(config, command.id)
    directory = Path.dirname(path)

    encoded =
      command
      |> effect()
      |> Map.merge(%{
        "scope" => @absence_scope,
        "checked" => "controlled_pool,journal_never_running,publications_only,native_state_absent"
      })
      |> JSON.encode!()

    with :ok <- PrivateFiles.directory(directory), do: publish_once(directory, path, encoded)
  end

  @spec effect(OverallsProtocol.Execution.command()) :: effect()
  defp effect(command) do
    %{
      "scope" => @publication_scope,
      "operation_id" => command.id,
      "placement_id" => command.placement_id,
      "vm_id" => command.vm_id,
      "execution_epoch" => command.execution_epoch,
      "generation" => command.generation,
      "kind" => Atom.to_string(command.kind)
    }
  end

  defp publish_once(directory, path, encoded) do
    case File.lstat(path) do
      {:error, :enoent} ->
        PrivateFiles.write(directory, Path.basename(path), encoded)

      {:ok, _} ->
        case PrivateFiles.read_secret(path) do
          {:ok, ^encoded} -> :ok
          _ -> {:error, :effect_conflict}
        end

      _ ->
        {:error, :effect_unconfirmed}
    end
  end
end
