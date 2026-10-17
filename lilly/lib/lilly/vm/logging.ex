defmodule Lilly.VM.Logging do
  @moduledoc "Generation-bound native VMM diagnostics, independent of the guest console."
  require Lilly.Events
  alias Lilly.Host.{Command, Pool, PrivateFiles}
  alias Lilly.VM.{Config, Intent, Jail, Spec}
  @directory "/var/lib/overalls-firecracker"

  # @cc [owner:ghuntley,label:isolation;recovery] native-logs-never-console
  # Native logging MUST use generation-specific nonblocking Firecracker FIFOs,
  # never console bytes. Collector failure MUST NOT become VM stop authority.
  @spec prepare(Config.t(), Pool.t(), Spec.t(), Intent.t()) :: :ok | {:error, atom()}
  def prepare(%Config{firecracker_logging: false}, _, _, _), do: :ok

  # @cc [owner:ghuntley,label:recovery;observability] logging-prep-failure-closed
  # FIFO preparation failures MUST report only the placement identifier and a
  # closed local reason atom; FIFO paths, VMM configuration and native output
  # MUST NOT enter diagnostics and the original error result MUST be preserved.
  def prepare(config, pool, spec, intent) do
    result =
      with :ok <- PrivateFiles.directory(@directory),
           :ok <- fifo(pool, spec, intent, "log"),
           :ok <- fifo(pool, spec, intent, "metrics") do
        PrivateFiles.write(
          @directory,
          key(intent) <> ".json",
          Jason.encode!(%{
            placement_id: intent.placement_id,
            execution_epoch: intent.execution_epoch,
            generation: intent.generation,
            uid: spec.network.uid,
            log: Path.join(Jail.root(pool, spec), filename(intent, "log")),
            metrics: Path.join(Jail.root(pool, spec), filename(intent, "metrics")),
            state_directory: config.state_dir
          })
        )
      end

    case result do
      :ok ->
        :ok

      failure ->
        {:error, reason} = failure

        Lilly.Events.emit("lilly.logging_preparation_failed",
          placement_id: intent.placement_id,
          reason: reason
        )

        failure
    end
  end

  defp fifo(pool, spec, intent, kind) do
    path = Path.join(Jail.root(pool, spec), filename(intent, kind))

    with {:ok, _} <- Command.run(:mkfifo, ["--mode=0600", "--", path]),
         {:ok, _} <- Command.run(:chown, ["#{spec.network.uid}:#{spec.network.uid}", "--", path]),
         do: :ok
  end

  @spec arguments(Config.t(), Intent.t()) :: [String.t()]
  def arguments(%Config{firecracker_logging: false}, _), do: ["--level", "Off"]

  def arguments(_, intent),
    do: [
      "--level",
      "Info",
      "--log-path",
      "/" <> filename(intent, "log"),
      "--metrics-path",
      "/" <> filename(intent, "metrics")
    ]

  defp filename(intent, kind), do: "#{kind}-#{intent.execution_epoch}-#{intent.generation}.fifo"
  defp key(intent), do: "#{intent.placement_id}-#{intent.execution_epoch}-#{intent.generation}"
end
