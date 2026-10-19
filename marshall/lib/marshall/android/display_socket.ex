defmodule Marshall.Android.DisplaySocket do
  @moduledoc "WebSocket adapter for the generation-fenced Android display relay."
  @behaviour WebSock

  @impl true
  def init(%{
        claim: claim,
        actor: actor,
        login_jti: login_jti,
        generation: generation,
        mode: mode
      }) do
    with {:ok, _expiry} <- Marshall.Accounts.Login.present(login_jti, actor.id),
         true <- claim.actor_id == actor.id,
         {:ok, relay} <- Marshall.Android.DisplayRelay.start_link(generation),
         :ok <- Marshall.Android.DisplayRelay.attach(relay, self(), mode) do
      {:ok, %{relay: relay, generation: generation, mode: mode}}
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
end
