defmodule Audi.HTTP.EditorAssetsPublisher do
  @moduledoc "Recurring authenticated readiness for the locally installed editor asset release."
  use GenServer
  require Audi.Events

  @type state :: %{
          client: Audi.Control.Client.t(),
          assets: Audi.HTTP.EditorAssets.t(),
          probe_peer: {:inet.ip_address(), :inet.port_number()},
          zone: binary(),
          roots: binary(),
          ready?: boolean(),
          halted?: boolean()
        }
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    :logger.update_process_metadata(%{audi_private: true})
    send(self(), :refresh)

    {:ok,
     %{
       client: Keyword.fetch!(options, :client),
       assets: Keyword.fetch!(options, :assets),
       probe_peer: Keyword.fetch!(options, :probe_peer),
       zone: Keyword.fetch!(options, :zone),
       roots: Keyword.fetch!(options, :trust_pem),
       ready?: false,
       halted?: false
     }}
  end

  # @cc [owner:ghuntley,label:security;recovery] audi-assets-current-announcement
  # Each announcement MUST revalidate local immutable files, prove their current
  # HTTPS service through the actual listener, and travel through the current
  # authenticated gateway session. Version refusal MUST halt this
  # publisher. Failure MUST let Marshall's five-second receipt expire; a local
  # readiness flag MUST NOT authorize editor admission.
  @impl true
  def handle_info(:refresh, %{halted?: true} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, assets} <- Audi.HTTP.EditorAssets.load(state.assets.root),
           true <- assets == state.assets,
           :ok <-
             Audi.HTTP.EditorAssetsProbe.check(
               state.probe_peer,
               state.zone,
               state.roots,
               assets.descriptor
             ),
           do: Audi.Control.Client.editor_assets_ready(state.client, assets.descriptor)

    ready? = match?({:ok, _}, result)
    if ready? and not state.ready?, do: Audi.Events.emit("audi.editor_assets_ready", [])

    if not ready? and state.ready?,
      do: Audi.Events.emit("audi.editor_assets_unavailable", reason: :unavailable)

    halted? = result == {:error, :unsupported_version}
    delay = max(2000 - (System.monotonic_time(:millisecond) - started), 0)
    if not halted?, do: Process.send_after(self(), :refresh, delay)
    {:noreply, %{state | ready?: ready?, halted?: halted?}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(_), do: %{state: :redacted}
end
