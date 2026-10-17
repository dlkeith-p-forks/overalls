defmodule Lilly.Transfer.KeyRuntime do
  @moduledoc "Bounded authenticated key preparation and retirement independent of VM execution."
  use GenServer
  require Lilly.Events
  alias Lilly.Control.Client
  alias Lilly.Transfer.Key

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)

    state = %{
      mode: Keyword.get(options, :mode, :prepare),
      client: Keyword.fetch!(options, :client),
      session: Keyword.fetch!(options, :session),
      root: Keyword.fetch!(options, :root),
      owner: Keyword.fetch!(options, :owner),
      pending: %{},
      effect_failures: %{},
      task: nil
    }

    send(self(), :tick)
    {:ok, state}
  end

  # @cc [owner:ghuntley,label:security;recovery] key-runtime-local-custody
  # The runtime MUST perform at most one key exchange/effect task at a time,
  # retain unacknowledged public results, and reuse the durable local key on
  # restart/lost replies. Retirement MUST replay the durable tombstone without
  # regenerating credentials. Peer commands MUST NOT select local paths. Publication
  # follows permanent binding of the enrolled source pin. Fenced sessions stop
  # further work; key preparation never authorizes disk effects or guest launch.
  # Revocation mode fences the key after cancellation or committed handoff, before
  # waiting for activity/stream quiescence;
  # busy retries MUST NOT republish credentials or claim disk reclamation.
  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    task =
      Task.async(fn ->
        Process.flag(:sensitive, true)

        try do
          exchange(state)
        rescue
          _ -> {:error, :key_preparation_failed}
        catch
          _, _ -> {:error, :key_preparation_failed}
        end
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, pending, failures} ->
        Process.send_after(self(), :tick, 1000)
        {:noreply, report_effect_failures(%{state | pending: pending, task: nil}, failures)}

      {:error, reason} when reason in [:unauthorized, :stale_connection, :unsupported_version] ->
        event =
          case state.mode do
            :retire -> :transfer_key_retirement_fenced
            :cancel -> :transfer_destination_revocation_fenced
            :prepare -> :transfer_keys_fenced
          end

        send(state.owner, {event, self(), reason})
        {:noreply, %{state | task: nil}}

      _ ->
        Process.send_after(self(), :tick, 5000)
        {:noreply, %{state | task: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    Process.send_after(self(), :tick, 5000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  @impl true
  def format_status(status),
    do: Map.put(status, :state, %{pending_keys: map_size(status.state.pending)})

  defp exchange(state) do
    with {:ok, response} <-
           control(state.mode, state.client, state.session, Map.values(state.pending)) do
      pending = Map.drop(state.pending, response.acknowledgements)

      Enum.reduce_while(response.commands, {:ok, pending, %{}}, fn command,
                                                                   {:ok, pending, failures} ->
        cond do
          Map.has_key?(pending, command.id) ->
            {:cont, {:ok, pending, failures}}

          map_size(pending) == 16 ->
            {:halt, {:ok, pending, failures}}

          true ->
            case effect(state.mode, state.root, state.client.host_id, command) do
              {:ok, result} ->
                {:cont, {:ok, Map.put(pending, command.id, result), failures}}

              {:error, reason} ->
                {:cont, {:ok, pending, Map.put(failures, command.id, reason)}}
            end
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] key-effect-failure-diagnostics-deduped
  # Key effect failures MUST report only the closed per-mode reason atom and,
  # for retirement, the relocation identifier; commands, endpoints, journals and
  # key material MUST NOT be logged. Identical per-command failures MUST be
  # suppressed until that command succeeds, disappears or the reason changes;
  # ticking retries MUST NOT spam events.
  defp report_effect_failures(state, failures) do
    :ok =
      Enum.each(failures, fn {id, reason} ->
        if state.effect_failures[id] != reason do
          case state.mode do
            :retire ->
              Lilly.Events.emit("lilly.key_retirement_failed", relocation_id: id, reason: reason)

            _ ->
              Lilly.Events.emit("lilly.transfer_effect_failed", reason: reason)
          end
        end
      end)

    %{state | effect_failures: failures}
  end

  defp control(:prepare, client, session, results),
    do: Client.exchange_relocation_keys(client, session, results)

  defp control(:retire, client, session, results),
    do: Client.exchange_relocation_key_retirement(client, session, results)

  defp control(:cancel, client, session, results),
    do: Client.exchange_relocation_destination_revocation(client, session, results)

  defp effect(:cancel, root, host, command),
    do: Lilly.Transfer.DestinationRevocation.execute(root, host, command)

  defp effect(:prepare, root, host, command), do: prepare(root, host, command)
  defp effect(:retire, root, host, command), do: retire(root, host, command)

  # @cc [owner:ghuntley,label:security;recovery] retirement-excludes-transfer-effects
  # retire/3 requires authenticated post-source-cleanup authority. It MUST validate
  # destination identity and lease, exclude receive/adoption and native streams,
  # and permanently erase the key before returning a receipt. It MUST NOT touch
  # guest disks, regenerate missing keys, or accept peer-selected paths.
  @spec retire(Path.t(), String.t(), OverallsProtocol.RelocationKeyRetirement.command()) ::
          {:ok, OverallsProtocol.RelocationKeyRetirement.result()} | {:error, atom()}
  def retire(root, host, command) do
    codec = OverallsProtocol.RelocationKeyRetirement

    with {:ok, ^command} <- codec.command(codec.encode(command)),
         true <-
           command.host_id == host and
             (command.expires_at - System.system_time(:second)) in 1..300,
         directory = Path.join([root, "transfers", command.id]),
         :ok <-
           owned(Path.join(directory, "receive"), fn ->
             owned(Path.join(directory, "stream"), fn ->
               if (command.expires_at - System.system_time(:second)) in 1..300,
                 do: Key.retire(root, host, command.id, command.placement_id),
                 else: {:error, :key_retirement_expired}
             end)
           end),
         do: {:ok, Map.take(command, [:id, :placement_id, :execution_epoch])},
         else: (_ -> {:error, :key_retirement_unconfirmed})
  end

  defp owned(directory, fun) do
    with {:ok, lock} <- Lilly.Host.Lock.acquire(directory) do
      try do
        fun.()
      after
        Lilly.Host.Lock.release(lock)
      end
    end
  end

  @spec prepare(Path.t(), String.t(), OverallsProtocol.RelocationKeys.command()) ::
          {:ok, OverallsProtocol.RelocationKeys.result()} | {:error, atom()}
  # @cc [owner:ghuntley,label:security] key-preparation-bound-publication
  # prepare/3 requires authenticated control and an operator-selected root. It
  # MUST reject a different destination host before creating state and return
  # only the public key after durable key and enrolled source-pin binding.
  # Retired/lost published keys and changed pins MUST NOT be silently replaced.
  def prepare(root, host, command) do
    with {:ok, ^command} <-
           OverallsProtocol.RelocationKeys.command(
             OverallsProtocol.RelocationKeys.encode(command)
           ),
         true <- command.host_id == host,
         {:ok, public} <- Key.ensure(root, host, command.id, command.placement_id),
         {:ok, _private_paths} <-
           Key.connection(
             root,
             host,
             command.id,
             command.placement_id,
             command.source_host_id,
             command.source_endpoint
           ) do
      {:ok,
       %{
         id: command.id,
         placement_id: command.placement_id,
         execution_epoch: command.execution_epoch,
         public_key: public
       }}
    else
      _ -> {:error, :key_preparation_failed}
    end
  end
end
