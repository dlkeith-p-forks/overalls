defmodule Marshall.Android.DisplaySocket do
  @moduledoc "WebSocket adapter for the generation-fenced Android display relay."
  @behaviour WebSock

  @impl true
  def init(%{
        claim: claim,
        actor: actor,
        login_jti: login_jti,
        generation: generation,
        mode: mode,
        ticket: ticket
      }) do
    with {:ok, _expiry} <- Marshall.Accounts.Login.present(login_jti, actor.id),
         true <- claim.actor_id == actor.id,
         {:ok, relay} <- Marshall.Android.DisplayRegistry.relay({claim.machine_id, generation}),
         :ok <- Marshall.Android.DisplayRelay.attach(relay, self(), mode),
         {:ok, vm} <- Marshall.Compute.get_vm(%{vm_id: claim.machine_id}, actor: actor),
         {:ok, host_stream} <- Marshall.Terminal.Relay.stream_for(vm.host_id),
         {:ok, bridge} <-
           Marshall.Android.DisplayRegistry.bridge(
             {claim.machine_id, generation},
             host_stream,
             %{
               type: :android_display_open,
               vm_id: vm.id,
               placement_id: vm.current_placement_id,
               execution_epoch: vm.execution_epoch,
               generation: generation,
               mode: mode,
               ticket: ticket,
               channel: 1
             }
           ) do
      {:ok, %{relay: relay, bridge: bridge, generation: generation, mode: mode}}
    else
      _ -> {:stop, :unauthorized, %{}}
    end
  end

  def init(_), do: {:stop, :unauthorized, %{}}

  @impl true
  def handle_in(
        {bytes, [opcode: :binary]},
        %{mode: :controller, relay: relay, generation: generation} = state
      ) do
    case Marshall.Android.DisplayRelay.input(relay, self(), generation, bytes) do
      :ok -> {:ok, state}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_in({_bytes, _opcode}, state), do: {:ok, state}

  @impl true
  def handle_info({:android_display_frame, generation, sequence, bytes}, state) do
    if generation == state.generation and is_integer(sequence) and sequence > 0 and
         is_binary(bytes) and byte_size(bytes) in 1..262_144 do
      # RFB is a byte stream. Generation and sequencing are enforced by the
      # relay; no application frame header may be inserted before noVNC bytes.
      {:reply, :ok, {:binary, bytes}, state}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{relay: relay}) do
    _ = Marshall.Android.DisplayRelay.detach(relay, self())
    :ok
  end

  def terminate(_, _), do: :ok
end
