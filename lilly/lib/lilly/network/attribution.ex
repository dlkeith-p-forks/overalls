defmodule Lilly.Network.Attribution do
  @moduledoc "Join kernel flow labels with the current execution view and its command owner."
  alias Lilly.Network.{Config, FlowLookup}

  # @cc [owner:ghuntley,label:security] attribution-complete-evidence-join
  # Resolution MUST join the exact kernel flow with the current execution for
  # that label and source (Lilly.Execution.by_flow/2: connected runtime,
  # identical durable intent, unexpired running observation) and the owner
  # carried by that validated durable command (`command.owner_id`). It MUST
  # recheck the kernel label and the execution row
  # version after obtaining the owner. Changed identity, a missing owner or a
  # lookup taking at least one second MUST remain unresolved. Resolution reads
  # the view and kernel only; it never calls the Runtime or an actor.
  @spec resolve(Config.t(), FlowLookup.flow(), atom()) :: {:ok, map()} | {:error, :unresolved}
  def resolve(config, flow, view \\ Lilly.Execution.view())

  def resolve(config, %{source: {source, _}} = flow, view) do
    started = System.monotonic_time(:millisecond)

    with {:ok, label} <- FlowLookup.label(config, flow),
         {:ok, version, identity} <- identity(view, label, source),
         {:ok, ^label} <- FlowLookup.label(config, flow),
         {:ok, ^version, ^identity} <- identity(view, label, source),
         true <- System.monotonic_time(:millisecond) - started < 1000 do
      {:ok, identity}
    else
      _ -> {:error, :unresolved}
    end
  rescue
    _ -> {:error, :unresolved}
  catch
    :exit, _ -> {:error, :unresolved}
  end

  def resolve(_, _, _), do: {:error, :unresolved}

  @doc """
  The attributable identity of the current execution for a kernel label and
  source, with the execution row version. The owner is the command's validated
  `owner_id`.
  """
  @spec identity(atom(), String.t(), :inet.ip4_address()) ::
          {:ok, OverallsProtocol.View.version(), map()} | {:error, :unresolved}
  def identity(view, label, source) do
    with {:ok, version, %{command: command}} <- Lilly.Execution.by_flow(view, label, source),
         %{owner_id: owner} <- command,
         true <- OverallsProtocol.uuid?(owner) do
      {:ok, version,
       command
       |> Map.take([:vm_id, :placement_id, :execution_epoch, :generation])
       |> Map.merge(%{host_id: command.host_id, owner_id: owner, attribution: :resolved})}
    else
      _ -> {:error, :unresolved}
    end
  end
end
