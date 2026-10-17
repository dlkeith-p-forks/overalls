defmodule OverallsAntithesis.Lilly.ControlledExecutor do
  @moduledoc "Durable controlled operation publication; no guest or native execution proof."
  @behaviour Lilly.VM.Executor
  alias Lilly.Control.Config
  alias Lilly.Host.PrivateFiles

  @type effect :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  # @cc [owner:ghuntley,label:recovery;verification] controlled-effect-before-receipt
  # Publication records requested work before returning. It does not prove
  # physical absence, cleanup, a VM, native disk, boot or readiness. Every
  # lifecycle outcome remains unavailable until independently observed.
  @impl true
  @spec reconcile(Config.t(), OverallsProtocol.Execution.command(), map()) ::
          Lilly.VM.Executor.result()
  def reconcile(config, command, _history) do
    _ = publish(config, command)
    {:retry, :execution_unavailable}
  end

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

  @spec effect(OverallsProtocol.Execution.command()) :: effect()
  defp effect(command) do
    %{
      "scope" => "controlled_operation_publication_only",
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
