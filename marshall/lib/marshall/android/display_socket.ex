defmodule Marshall.Android.DisplaySocket do
  @moduledoc "WebSocket adapter for the generation-fenced Android display relay."
  @behaviour WebSock

  @impl true
  def init(%{claim: claim, actor: actor, login_jti: login_jti, generation: generation, mode: mode}) do
    with {:ok, _expiry} <- Marshall.Accounts.Login.present(login_jti, actor.id),
         true <- claim.actor_id == actor.id,
         {:ok, relay} <- Marshall.Android.DisplayRelay.start_link(generation),
         :ok <- Marshall.Android.DisplayRelay.attach(relay, self(), mode) do
      {:push, {:text, Jason.encode!(%{op: "ready", generation: generation, mode: mode})},
       %{relay: relay, generation: generation, mode: mode}}
    else
      _ -> {:stop, :unauthorized, %{}}
    end
  end

  def init(_), do: {:stop, :unauthorized, %{}}

  @impl true
  def handle_in({bytes, [opcode: :binary]}, %{mode: :controller, relay: relay, generation: generation} = state) do
    case Marshall.Android.DisplayRelay.input(relay, self(), generation, bytes) do
      :ok -> {:ok, state}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_in({_bytes, _opcode}, state), do: {:ok, state}

  @impl true
  def handle_info({:android_display_frame, generation, sequence, bytes}, state) do
    case OverallsProtocol.AndroidDisplayStream.encode_data(generation, sequence, bytes) do
      {:ok, frame} -> {:reply, :ok, {:binary, frame}, state}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_info(_, state), do: {:ok, state}
end
