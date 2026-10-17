defmodule Audi.TLS.Store do
  @moduledoc """
  In-memory selection of one validated public wildcard certificate.

  The store is the single writer (ADR-0140): it validates and installs fleet
  generations and publishes the installed one to its `OverallsProtocol.View`.
  Every TLS handshake (SNI) and metadata read is a lock-free view read; no
  reader ever waits behind the store.
  """
  use GenServer
  alias Audi.TLS.FleetMaterial
  alias OverallsProtocol.View

  @maximum_generation 9_223_372_036_854_775_807

  @doc "The read view published by the store registered as `store`."
  @spec view(atom()) :: atom()
  def view(store) when is_atom(store), do: Module.concat(store, View)

  @doc "Children for a named store: its read view, then the store."
  @spec children(keyword()) :: [{module(), keyword()}]
  def children(options) do
    store = Keyword.fetch!(options, :name)
    [{View, name: view(store)}, {__MODULE__, options}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.fetch!(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec install_fleet(GenServer.server(), binary(), pos_integer(), binary(), binary()) ::
          {:ok, map()} | {:error, atom()}
  def install_fleet(server, zone, generation, chain, key),
    do: GenServer.call(server, {:install_fleet, zone, generation, chain, key}, 5000)

  @doc """
  Records that the local listener was proven, by a verified SNI handshake, to
  serve the installed fleet `generation`.
  """
  @spec prove(atom(), pos_integer()) :: :ok | {:error, :not_installed}
  def prove(store, generation), do: GenServer.call(store, {:prove, generation}, 5000)

  # @cc [owner:ghuntley,label:security;capacity] audi-readiness-proof-per-generation
  # proven?/2 MUST be true only for the exact installed generation last proven
  # by the fleet worker's verified local handshake; a newer installation is
  # unproven until its own probe succeeds. Per-VM readiness may then skip the
  # repeated handshake: the wildcard and listener are the same for every VM.
  @spec proven?(atom(), pos_integer()) :: boolean()
  def proven?(store, generation) do
    match?({:ok, {_, ^generation}}, View.fetch(view(store), :proven)) and
      match?({:ok, %{generation: ^generation}}, installed(store))
  rescue
    ArgumentError -> false
  end

  @spec fleet_metadata(atom(), binary()) :: {:ok, map()} | {:error, atom()}
  def fleet_metadata(store, hostname) do
    case installed(store) do
      {:ok, %{material: %FleetMaterial{} = material, generation: generation}} ->
        if fleet_name?(hostname, material.hostname) and
             material.expires_at > System.system_time(:second),
           do:
             {:ok,
              %{
                hostname: hostname,
                generation: generation,
                fingerprint: material.fingerprint,
                expires_at: material.expires_at
              }},
           else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] audi-sni-no-fallback
  # Unknown, unavailable and expired certificate selections MUST return
  # unrecognized. Only the installed fleet wildcard may satisfy SNI; no per-VM
  # certificate or disk custody fallback may establish a TLS identity.
  # Selection establishes no application authority.
  @spec sni(atom(), term()) :: keyword() | :unrecognized
  def sni(store, name) do
    with {:ok, hostname} <- name_value(name),
         {:ok, %{material: %FleetMaterial{} = material}} <- installed(store),
         true <- fleet_name?(hostname, material.hostname),
         true <- material.expires_at > System.system_time(:second) do
      [certs_keys: [%{cert: material.certificates, key: material.key}]]
    else
      _ -> :unrecognized
    end
  rescue
    _ -> :unrecognized
  end

  # Lock-free read of the generation the store last published.
  defp installed(store) do
    case View.fetch(view(store), :fleet) do
      {:ok, {_version, fleet}} -> {:ok, fleet}
      :error -> :error
    end
  end

  # @cc [owner:ghuntley,label:security;architecture] audi-tls-store-single-writer
  # The store MUST be the only writer of its view's :fleet row and MUST publish
  # a generation only after it is validated and accepted; a store restart
  # starts with no published certificate (the view drops an exited writer's
  # rows), so SNI fails closed until the fleet worker reinstalls.
  @impl true
  def init(options) do
    roots = Keyword.fetch!(options, :trust_pem)
    limit = Keyword.get(options, :max_bytes, 268_435_456)
    view = view(Keyword.fetch!(options, :name))

    with true <-
           is_binary(roots) and byte_size(roots) in 1..1_048_576 and
             is_integer(limit) and limit in 1..268_435_456,
         :ok <- View.claim(view, :fleet),
         :ok <- View.claim(view, :proven) do
      {:ok, %{roots: roots, limit: limit, fleet: nil, view: view}}
    else
      _ -> {:stop, :invalid_tls_store_configuration}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] audi-fleet-wildcard-memory-install
  # A complete validated wildcard may replace the in-memory generation only
  # monotonically. A stale or conflicting generation MUST preserve the installed
  # certificate. Capacity rejection MUST also preserve the old generation.
  # No certificate or private key may be written to local storage.
  @impl true
  def handle_call({:install_fleet, zone, generation, chain, key}, _, state) do
    reply =
      cond do
        not is_integer(generation) or generation not in 1..@maximum_generation ->
          {:error, :invalid_generation}

        state.fleet != nil and generation < state.fleet.generation ->
          {:error, :stale}

        true ->
          with {:ok, material} <- FleetMaterial.validate(chain, key, state.roots, zone),
               true <- material_size(material) <= state.limit || {:error, :capacity},
               :ok <- matching_generation(state.fleet, generation, material) do
            metadata = %{
              hostname: zone,
              fingerprint: material.fingerprint,
              expires_at: material.expires_at
            }

            {:ok, metadata, %{state | fleet: %{generation: generation, material: material}}}
          else
            {:error, _} = error -> error
          end
      end

    case reply do
      {:ok, metadata, next} ->
        {:ok, _version} = View.put(state.view, :fleet, next.fleet)
        {:reply, {:ok, metadata}, next}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:prove, generation}, _, %{fleet: %{generation: generation}} = state) do
    {:ok, _} = View.put(state.view, :proven, generation)
    {:reply, :ok, state}
  end

  def handle_call({:prove, _generation}, _, state), do: {:reply, {:error, :not_installed}, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} when key in [:state, :message, :reason] -> {key, :redacted_tls_store}
      other -> other
    end)
  end

  defp matching_generation(nil, _, _), do: :ok
  defp matching_generation(%{generation: old}, generation, _) when generation > old, do: :ok

  defp matching_generation(%{generation: generation, material: material}, generation, material),
    do: :ok

  defp matching_generation(_, _, _), do: {:error, :conflict}

  defp material_size(material),
    do: byte_size(elem(material.key, 1)) + Enum.sum(Enum.map(material.certificates, &byte_size/1))

  defp name_value(name) when is_list(name) and length(name) <= 253,
    do: name |> List.to_string() |> name_value()

  defp name_value(name) when is_binary(name) and byte_size(name) in 1..253,
    do: {:ok, name}

  defp name_value(_), do: :error

  defp fleet_name?(name, zone) when is_binary(name) and is_binary(zone) do
    suffix = "." <> zone

    if String.ends_with?(name, suffix) do
      label = binary_part(name, 0, byte_size(name) - byte_size(suffix))

      not String.contains?(label, ".") and
        (OverallsProtocol.EditorName.valid_label?(label) or
           OverallsProtocol.EditorName.webview_label?(label) or
           (not String.starts_with?(label, "e-") and
              match?({:ok, _, _}, OverallsProtocol.IngressName.application_label(label))))
    else
      false
    end
  end

  defp fleet_name?(_, _), do: false
end
