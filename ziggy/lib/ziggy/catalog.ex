defmodule Ziggy.Catalog do
  @moduledoc "Provider discovery with atomic snapshots; LLMDB enriches, never gates, model IDs."
  use GenServer
  require Ziggy.Events
  @interval 900_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @spec models(GenServer.server(), :all | :openai | :anthropic) :: [map()]
  def models(server, provider \\ :all), do: GenServer.call(server, {:models, provider})

  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server), do: GenServer.call(server, :ready)

  @impl true
  def init(opts) do
    send(self(), :refresh)

    {:ok,
     %{
       credentials: Keyword.fetch!(opts, :credentials),
       openai_origin: Keyword.get(opts, :openai_origin, Ziggy.Route.origin(:openai)),
       models: %{},
       task: nil,
       failures: 0,
       tasks: Keyword.fetch!(opts, :tasks)
     }}
  end

  @impl true
  def handle_call(:ready, _, state),
    do: {:reply, Enum.all?(Map.keys(state.credentials), &Map.has_key?(state.models, &1)), state}

  def handle_call({:models, provider}, _, state) do
    models =
      if provider == :all,
        do: state.models |> Map.values() |> List.flatten(),
        else: Map.get(state.models, provider, [])

    {:reply, models, state}
  end

  @impl true
  def handle_info(:refresh, %{task: nil} = state) do
    credentials = state.credentials
    openai_origin = state.openai_origin

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        Map.new(credentials, fn {provider, key} ->
          {provider, discover(provider, key, openai_origin)}
        end)
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    models =
      Enum.reduce(result, state.models, fn
        {provider, {:ok, models}}, acc -> Map.put(acc, provider, models)
        _, acc -> acc
      end)

    failures =
      if Enum.all?(Map.values(result), &match?({:ok, _}, &1)) do
        Ziggy.Events.emit("ziggy.catalog_refreshed", [])
        0
      else
        Ziggy.Events.emit("ziggy.catalog_failed", reason: :discovery_failed)
        state.failures + 1
      end

    schedule(failures)
    {:noreply, %{state | models: models, task: nil, failures: failures}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    Ziggy.Events.emit("ziggy.catalog_failed", reason: :discovery_task_lost)
    failures = state.failures + 1
    schedule(failures)
    {:noreply, %{state | task: nil, failures: failures}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:security] discovery-fixed-origin-bounded-pagination
  # Pagination MUST preserve the configured fixed origin and bound pages and
  # model IDs. Only complete snapshots may replace the previous snapshot.
  # Absence from LLMDB MUST NOT omit an available provider model.
  @spec discover(:openai | :anthropic, binary()) :: {:ok, [map()]} | {:error, :discovery_failed}
  def discover(provider, key), do: discover(provider, key, Ziggy.Route.origin(:openai))

  @spec discover(:openai | :anthropic, binary(), binary()) ::
          {:ok, [map()]} | {:error, :discovery_failed}
  def discover(provider, key, openai_origin),
    do: pages(provider, key, openai_origin, nil, [], %{}, 100)

  @spec pages(
          :openai | :anthropic,
          binary(),
          binary(),
          nil | binary(),
          [map()],
          %{optional(binary()) => true},
          non_neg_integer()
        ) :: {:ok, [map()]} | {:error, :discovery_failed}
  defp pages(_, _, _, _, _, _, 0), do: {:error, :discovery_failed}

  defp pages(provider, key, openai_origin, cursor, acc, seen, remaining) do
    params = if is_nil(cursor), do: [], else: [after_id: cursor, limit: 1000]
    headers = Ziggy.Upstream.headers(provider, key, [])

    result =
      Req.get(origin(provider, openai_origin) <> "/v1/models",
        headers: headers,
        params: params,
        retry: false,
        redirect: false,
        receive_timeout: 10_000,
        decode_body: false,
        into: &collect/2
      )

    with {:ok, %{status: 200, body: raw}} <- result,
         {:ok, %{"data" => data} = body} <- Jason.decode(raw),
         true <- is_list(data) and length(data) <= 10_000,
         true <- Enum.all?(data, &(is_map(&1) and Ziggy.Route.valid_model?(&1["id"]))) do
      entries = Enum.map(data, &enrich(provider, &1["id"]))

      if body["has_more"] == true do
        next = body["last_id"]

        if Ziggy.Route.valid_model?(next) and not Map.has_key?(seen, next),
          do:
            pages(
              provider,
              key,
              openai_origin,
              next,
              entries ++ acc,
              Map.put(seen, next, true),
              remaining - 1
            ),
          else: {:error, :discovery_failed}
      else
        {:ok, Enum.uniq_by(entries ++ acc, & &1["id"]) |> Enum.sort_by(& &1["id"])}
      end
    else
      _ -> {:error, :discovery_failed}
    end
  end

  defp origin(:openai, openai_origin), do: openai_origin
  defp origin(provider, _), do: Ziggy.Route.origin(provider)

  defp collect({:data, chunk}, {req, resp}) do
    body = resp.body || ""

    if is_binary(body) and byte_size(body) + byte_size(chunk) <= 4_194_304,
      do: {:cont, {req, %{resp | body: body <> chunk}}},
      else: {:halt, {req, %{resp | status: 502, body: ""}}}
  end

  defp enrich(provider, id) do
    base = %{"id" => id, "object" => "model", "owned_by" => Atom.to_string(provider)}

    case LLMDB.model({provider, id}) do
      {:ok, model} -> Map.put(base, "display_name", model.name)
      _ -> base
    end
  end

  # @cc [owner:ghuntley,label:recovery] catalog-failure-retries-promptly
  # A complete refresh repeats at the jittered interval. A failed or partial
  # discovery MUST retry after five seconds, doubling to at most the interval,
  # so one outage at startup cannot leave readiness false for the whole
  # interval; retained models stay until a complete snapshot replaces them.
  @spec schedule(non_neg_integer()) :: reference()
  defp schedule(0),
    do: Process.send_after(self(), :refresh, @interval + :rand.uniform(60_001) - 30_001)

  defp schedule(failures),
    do: Process.send_after(self(), :refresh, min(5_000 * 2 ** min(failures - 1, 10), @interval))
end
