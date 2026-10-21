defmodule Audi.TLS.FleetWorker do
  @moduledoc "Fetch the Cloak-backed fleet wildcard and refresh route readiness."
  use GenServer
  alias Audi.TLS.Readiness
  alias Audi.Control.Client
  alias Audi.TLS.{FleetCertificate, Installation, Probe, Store}
  require Audi.Events

  @probe_label OverallsProtocol.IngressName.label("probe", "00000000-0000-4000-8000-000000000000")

  @type state :: %{
          options: keyword(),
          scheduler: pid(),
          next_fetch: integer(),
          certificate: FleetCertificate.t(),
          last_error: atom() | nil,
          halted?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec automatic_work_enabled?(GenServer.server()) :: boolean()
  def automatic_work_enabled?(server) do
    GenServer.call(server, :automatic_work_enabled?, 1000)
  catch
    :exit, _ -> false
  end

  @impl true
  def handle_call(:automatic_work_enabled?, _, state), do: {:reply, not state.halted?, state}

  @impl true
  def init(options) do
    :logger.update_process_metadata(%{audi_private: true})

    {:ok, scheduler} =
      Readiness.start_link(
        owner: self(),
        tasks: Keyword.fetch!(options, :tasks),
        work: fn entry, _revision ->
          Installation.publish_fleet(
            Keyword.fetch!(options, :client),
            Keyword.fetch!(options, :store),
            entry,
            options
          )
        end
      )

    send(self(), :tick)

    # Catalog hints refresh at once; the one-second tick stays the backstop.
    # An activated certificate generation is fetched at once on its hint.
    if Process.whereis(Audi.Control.Hints) do
      {:ok, _} = Registry.register(Audi.Control.Hints, "gateway_catalog", nil)
      {:ok, _} = Registry.register(Audi.Control.Hints, "fleet_certificate", nil)
    end

    {:ok,
     %{
       options: options,
       scheduler: scheduler,
       next_fetch: System.monotonic_time(:millisecond),
       certificate: FleetCertificate.new(),
       last_error: nil,
       halted?: false
     }}
  end

  @impl true
  def handle_info(:tick, %{halted?: false} = state) do
    state = fetch_if_due(state)

    state =
      if state.halted?, do: state, else: state |> check_installed() |> refresh_catalog()

    unless state.halted?, do: Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end

  def handle_info({:control_hint, "gateway_catalog", _host}, %{halted?: false} = state),
    do: {:noreply, refresh_catalog(state)}

  def handle_info({:control_hint, "fleet_certificate", _id}, %{halted?: false} = state) do
    state = fetch_if_due(%{state | next_fetch: System.monotonic_time(:millisecond)})
    {:noreply, if(state.halted?, do: state, else: check_installed(state))}
  end

  def handle_info({:control_version_refused, scheduler}, %{scheduler: scheduler} = state),
    do: {:noreply, halt(state)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  # @cc [owner:ghuntley,label:privacy] fleet-worker-status-redaction
  # Preserve OTP status keys so the runtime accepts redaction; remove payloads
  # from state, messages, reasons and debug logs before status/crash formatting.
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] audi-fleet-delivery-before-readiness
  # A gateway MUST validate the fetched certificate and key, install them in
  # memory, complete a verified local SNI handshake, and acknowledge that exact
  # generation before refreshing any workload route. Failed fetches or probes
  # MUST leave the previous valid generation intact and grant no new readiness;
  # the last proven generation keeps serving existing routes (FleetCertificate
  # :degraded) until it expires or is no longer installed.
  defp fetch_if_due(state) do
    now = System.monotonic_time(:millisecond)

    if now < state.next_fetch do
      state
    else
      options = state.options
      client = Keyword.fetch!(options, :client)
      store = Keyword.fetch!(options, :store)
      zone = Keyword.fetch!(options, :zone)
      roots = Keyword.fetch!(options, :trust_pem)
      peer = Keyword.fetch!(options, :probe_peer)

      result =
        with {:ok, bundle} <- staged(Client.fleet_certificate(client, zone), :fetch),
             {:ok, checked} <-
               staged(
                 Audi.TLS.FleetMaterial.validate(
                   bundle.chain_pem,
                   bundle.private_key_pem,
                   roots,
                   zone
                 ),
                 :validate
               ),
             :ok <-
               ensure(
                 checked.fingerprint == bundle.fingerprint and
                   checked.expires_at == DateTime.to_unix(bundle.expires_at),
                 :binding
               ),
             {:ok, installed} <-
               staged(
                 Store.install_fleet(
                   store,
                   zone,
                   bundle.generation,
                   bundle.chain_pem,
                   bundle.private_key_pem
                 ),
                 :install
               ),
             :ok <-
               ensure(
                 installed.fingerprint == bundle.fingerprint and
                   installed.expires_at == DateTime.to_unix(bundle.expires_at),
                 :binding
               ),
             {:ok, metadata} <-
               staged(Store.fleet_metadata(store, @probe_label <> "." <> zone), :select),
             :ok <- staged(Probe.check(peer, metadata, roots), :probe),
             :ok <- staged(Store.prove(store, bundle.generation), :probe),
             {:ok, _} <-
               staged(
                 Client.acknowledge_fleet_certificate(
                   client,
                   zone,
                   bundle.generation,
                   bundle.fingerprint
                 ),
                 :ack
               ) do
          {:ok, bundle.generation}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_material}
        end

      case result do
        {:ok, generation} ->
          if FleetCertificate.serving(state.certificate) != generation,
            do:
              Audi.Events.emit("audi.fleet_certificate_ready",
                host_id: client.host_id,
                generation: generation
              )

          {:ok, certificate} = FleetCertificate.step(state.certificate, {:installed, generation})
          %{state | certificate: certificate, next_fetch: now + 30_000, last_error: nil}

        {:error, reason} ->
          if reason == :unsupported_version, do: halt(state), else: failed(state, reason)
      end
    end
  rescue
    _ -> failed(state, :unexpected)
  catch
    :exit, _ -> failed(state, :unavailable)
  end

  defp staged({:ok, _} = result, _), do: result
  defp staged(:ok, _), do: :ok
  defp staged({:error, :unsupported_version} = result, _), do: result
  defp staged(_, reason), do: {:error, reason}

  defp ensure(true, _), do: :ok
  defp ensure(_, reason), do: {:error, reason}

  # A failed refresh keeps the proven generation serving (:degraded); it is
  # reported once per distinct reason and retried after five seconds.
  defp failed(state, reason) do
    client = Keyword.fetch!(state.options, :client)

    if state.last_error != reason,
      do:
        Audi.Events.emit("audi.fleet_certificate_sync_failed",
          host_id: client.host_id,
          reason: reason
        )

    {:ok, certificate} = FleetCertificate.step(state.certificate, {:failed, reason})

    %{
      state
      | certificate: certificate,
        last_error: reason,
        next_fetch: System.monotonic_time(:millisecond) + 5000
    }
  end

  # The serving generation MUST still be installed, unexpired and proven in the
  # store (a restarted store or an expired certificate ends readiness).
  defp check_installed(state) do
    case FleetCertificate.serving(state.certificate) do
      nil ->
        state

      generation ->
        store = Keyword.fetch!(state.options, :store)
        zone = Keyword.fetch!(state.options, :zone)

        if Store.proven?(store, generation) and
             match?(
               {:ok, %{generation: ^generation}},
               Store.fleet_metadata(store, @probe_label <> "." <> zone)
             ) do
          state
        else
          client = Keyword.fetch!(state.options, :client)
          Audi.Events.emit("audi.fleet_certificate_unavailable", host_id: client.host_id)
          {:ok, certificate} = FleetCertificate.step(state.certificate, :expired)
          %{state | certificate: certificate, next_fetch: System.monotonic_time(:millisecond)}
        end
    end
  end

  defp refresh_catalog(state) do
    options = state.options

    result =
      if FleetCertificate.serving(state.certificate) do
        case Client.gateway_catalog(Keyword.fetch!(options, :client)) do
          {:ok, catalog} ->
            Enum.map(catalog.entries, fn entry ->
              {Map.put(entry, :service_generation, catalog.service_generation),
               System.unique_integer([:positive, :monotonic])}
            end)
            |> then(&{&1, catalog.expires_at})

          {:error, :unsupported_version} ->
            :unsupported_version

          _ ->
            {[], 0}
        end
      else
        {[], 0}
      end

    case result do
      :unsupported_version ->
        halt(state)

      {work, expiry} ->
        Readiness.refresh(state.scheduler, work, expiry)
        state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  # @cc [owner:ghuntley,label:protocol;recovery] audi-fleet-terminal-version
  # Fetch, acknowledgement, catalog or readiness version refusal MUST halt fleet
  # polling and retire readiness ownership without waiting for scheduler replies.
  # Its independent job guards observe owner death even when it is suspended.
  # Installed certificate expiry remains intact.
  @spec halt(state()) :: state()
  defp halt(%{halted?: true} = state), do: state

  defp halt(state) do
    Process.unlink(state.scheduler)
    Process.exit(state.scheduler, :kill)
    Audi.Events.emit("audi.control_version_refused", owner: :fleet_worker)

    %{
      state
      | halted?: true,
        certificate: FleetCertificate.new(),
        last_error: :unsupported_version
    }
  end
end
