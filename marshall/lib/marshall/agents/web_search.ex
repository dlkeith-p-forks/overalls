defmodule Marshall.Agents.WebSearch do
  @moduledoc "Durable Marshall-owned public search tool and Serper client."
  use GenServer

  alias Marshall.Agents.{AuditEvent, Capabilities, Command, Root, SearchUsage, Thread, Turn}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Marshall.Events

  @poll_ms 1_000
  @maximum_active 8
  @claim_timeout_seconds 60
  @max_result_bytes 200_000
  @max_provider_bytes 1_048_576
  @provider_origin "https://google.serper.dev"

  @type organic_result :: %{String.t() => String.t() | nil}
  @type answer_box :: %{String.t() => String.t() | nil}
  @type projection :: %{String.t() => [organic_result()] | answer_box() | nil}
  @type work :: %{id: String.t(), claim_id: String.t(), query: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    Process.send_after(self(), :poll, @poll_ms)
    {:ok, %{active: %{}, ticks: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    reap()
    if rem(state.ticks, 60) == 0, do: prune_cache()

    state =
      if map_size(state.active) < @maximum_active do
        case claim() do
          {:ok, %{} = work} ->
            task = Task.Supervisor.async_nolink(Marshall.Agents.SearchTasks, fn -> run(work) end)
            %{state | active: Map.put(state.active, task.ref, task.pid)}

          _ ->
            state
        end
      else
        state
      end

    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, %{state | ticks: state.ticks + 1}}
  rescue
    _ ->
      Marshall.Events.emit("agent.loop_failed", reason: :search_worker)
      Process.send_after(self(), :poll, @poll_ms)
      {:noreply, state}
  end

  def handle_info({ref, _result}, %{active: active} = state) when is_map_key(active, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | active: Map.delete(active, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: active} = state)
      when is_map_key(active, ref),
      do: {:noreply, %{state | active: Map.delete(active, ref)}}

  def handle_info(_, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:security;recovery] search-claim-before-provider
  # The current authorized turn and profile MUST be checked under the database
  # lock before a search is claimed. A claimed command MUST NOT be queued again.
  @spec claim() :: {:ok, work() | nil} | {:error, term()}
  def claim do
    Ledger.transaction(fn ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          """
          SELECT c.id FROM agent_commands AS c
          JOIN agent_turns AS t ON t.id = c.turn_id AND t.thread_id = c.thread_id
          JOIN agent_threads AS th ON th.id = c.thread_id AND th.root_id = c.root_id
          WHERE c.tool = 'web_search' AND c.status = 'queued' AND t.status = 'running'
            AND th.active_turn_id = t.id
          ORDER BY c.inserted_at, c.id LIMIT 1 FOR UPDATE OF c SKIP LOCKED
          """,
          [],
          log: false
        )

      case rows do
        [] ->
          nil

        [[raw_id]] ->
          command = Ledger.lock!(Command, Ecto.UUID.load!(raw_id))
          [turn] = Ledger.read!(Turn, id: command.turn_id)
          [thread] = Ledger.read!(Thread, id: command.thread_id)
          [root] = Ledger.read!(Root, id: command.root_id)
          vm = Ledger.lock!(VirtualMachine, root.vm_id) || Ledger.rollback(:machine_unavailable)
          actor = Marshall.Accounts.Security.current(turn.actor_id)

          cond do
            not Capabilities.allowed?(vm.profile, :web_search) ->
              finish_locked!(
                command,
                vm,
                turn,
                :cancelled,
                %{"reason" => "capability_denied"},
                nil,
                false
              )

              nil

            vm.archived_at != nil or vm.desired_state != :running or
              vm.observed_state != :running or
              not Marshall.Compute.Images.guest_capabilities(vm.image_id).agents or
              not match?(%Marshall.Accounts.User{deleted_at: nil}, actor) or
                not Marshall.Access.Authorization.allowed?(vm, actor, "write") ->
              finish_locked!(
                command,
                vm,
                turn,
                :cancelled,
                %{"reason" => "access_revoked"},
                nil,
                false
              )

              nil

            true ->
              Marshall.Compute.Idle.touch_locked!(vm)
              query = String.trim(command.arguments["query"])
              key = cache_key(query)

              case cached(key) do
                {:hit, result} ->
                  Ledger.create!(AuditEvent, :record, %{
                    vm_id: vm.id,
                    thread_id: thread.id,
                    turn_id: turn.id,
                    actor_id: turn.actor_id,
                    kind: :tool_dispatched,
                    target_id: command.id,
                    outcome: :accepted
                  })

                  finish_locked!(command, vm, turn, :completed, result, 0, true)

                  Ledger.after_commit(fn ->
                    Marshall.Events.emit("agent.search_cache_hit",
                      vm_id: vm.id,
                      command_id: command.id
                    )
                  end)

                  nil

                :miss ->
                  claim_id = Ash.UUID.generate()

                  Ledger.update!(command, :transition, %{
                    status: :claimed,
                    claim_id: claim_id,
                    claimed_at: Ledger.now()
                  })

                  Ledger.create!(AuditEvent, :record, %{
                    vm_id: vm.id,
                    thread_id: thread.id,
                    turn_id: turn.id,
                    actor_id: turn.actor_id,
                    kind: :tool_dispatched,
                    target_id: command.id,
                    outcome: :accepted
                  })

                  Ledger.after_commit(fn ->
                    Marshall.Events.emit("agent.search_claimed",
                      vm_id: vm.id,
                      command_id: command.id
                    )
                  end)

                  %{id: command.id, claim_id: claim_id, query: query}
              end
          end
      end
    end)
  end

  @spec run(work()) :: :ok
  def run(work) do
    {outcome, result, credits} = search(work.query)
    complete(work.id, work.claim_id, outcome, result, credits)
    :ok
  rescue
    _ -> :ok
  end

  @spec cache_key(String.t()) :: String.t()
  def cache_key(query) when is_binary(query) do
    :crypto.hash(:sha256, "serper-search-v1\0" <> String.trim(query))
    |> Base.encode16(case: :lower)
  end

  @spec project(map()) :: {:ok, projection(), non_neg_integer() | nil} | {:error, atom()}
  def project(body) when is_map(body) do
    with organic when is_list(organic) <- Map.get(body, "organic", []),
         {:ok, results} <- project_organic(organic),
         {:ok, answer_box} <- project_answer(Map.get(body, "answerBox")),
         {:ok, credits} <- credits(Map.get(body, "credits")) do
      result = %{"answer_box" => answer_box, "results" => results}

      if byte_size(Jason.encode!(result)) <= @max_result_bytes,
        do: {:ok, result, credits},
        else: {:error, :search_result_too_large}
    end
  end

  def project(_), do: {:error, :invalid_provider_response}

  defp project_organic(organic) do
    Enum.reduce_while(organic, {:ok, []}, fn item, {:ok, items} ->
      case item do
        %{"title" => title, "link" => url} when is_binary(title) and is_binary(url) ->
          snippet = Map.get(item, "snippet")

          if is_nil(snippet) or is_binary(snippet) do
            {:cont, {:ok, [%{"title" => title, "url" => url, "snippet" => snippet} | items]}}
          else
            {:halt, {:error, :invalid_provider_response}}
          end

        _ ->
          {:halt, {:error, :invalid_provider_response}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp project_answer(nil), do: {:ok, nil}

  defp project_answer(%{} = box) do
    title = Map.get(box, "title")
    answer = Map.get(box, "answer", Map.get(box, "snippet"))
    url = Map.get(box, "link")

    if Enum.all?([title, answer, url], &(is_nil(&1) or is_binary(&1))),
      do: {:ok, %{"title" => title, "answer" => answer, "url" => url}},
      else: {:error, :invalid_provider_response}
  end

  defp project_answer(_), do: {:error, :invalid_provider_response}

  defp credits(nil), do: {:ok, nil}
  defp credits(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp credits(_), do: {:error, :invalid_provider_response}

  defp cached(key) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT result FROM agent_search_cache WHERE key = $1 AND fetched_at > now() - interval '24 hours'",
        [key],
        log: false
      )

    case rows do
      [[result]] when is_map(result) -> {:hit, result}
      _ -> :miss
    end
  end

  defp search(query) do
    key_file = Application.get_env(:marshall, :serper_key_file)

    case key_file && File.read(key_file) do
      {:ok, key} ->
        key = String.trim(key)

        if String.starts_with?(key, "overalls-serper-placeholder-v1-") do
          {:failed, %{"reason" => "search_unavailable"}, nil}
        else
          request_serper(query, key)
        end

      _ ->
        {:failed, %{"reason" => "search_unavailable"}, nil}
    end
  end

  defp request_serper(query, key) do
    origin = Application.get_env(:marshall, :serper_origin, @provider_origin)

    case Req.post(origin <> "/search",
           headers: [{"x-api-key", key}],
           json: %{q: query},
           retry: false,
           redirect: false,
           receive_timeout: 15_000,
           compressed: false,
           raw: true,
           into: fn {:data, chunk}, {request, response} ->
             body = response.body

             if is_binary(body) and byte_size(body) + byte_size(chunk) <= @max_provider_bytes do
               {:cont, {request, %{response | body: body <> chunk}}}
             else
               {:halt, {request, %{response | body: :oversize}}}
             end
           end
         ) do
      {:ok, %Req.Response{status: 200, body: :oversize}} ->
        {:failed, %{"reason" => "search_result_too_large"}, nil}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            case project(decoded) do
              {:ok, result, credits} -> {:completed, result, credits}
              {:error, reason} -> {:failed, %{"reason" => Atom.to_string(reason)}, nil}
            end

          _ ->
            {:failed, %{"reason" => "search_failed"}, nil}
        end

      _ ->
        {:failed, %{"reason" => "search_failed"}, nil}
    end
  rescue
    _ -> {:failed, %{"reason" => "search_failed"}, nil}
  end

  # @cc [owner:ghuntley,label:recovery;security] search-terminal-single-receipt
  # Only the matching claim may complete a search. Result, credit receipt and
  # content-free audit MUST commit atomically; duplicate completion is inert.
  @spec complete(String.t(), String.t(), atom(), map(), non_neg_integer() | nil) ::
          {:ok, term()} | {:error, term()}
  def complete(id, claim_id, outcome, result, credits)
      when outcome in [:completed, :failed] and is_map(result) do
    Ledger.transaction(fn ->
      command = Ledger.lock!(Command, id) || Ledger.rollback(:not_found)

      if command.status == :claimed and command.claim_id == claim_id do
        [root] = Ledger.read!(Root, id: command.root_id)
        vm = Ledger.lock!(VirtualMachine, root.vm_id) || Ledger.rollback(:machine_unavailable)
        [turn] = Ledger.read!(Turn, id: command.turn_id)
        finish_locked!(command, vm, turn, outcome, result, credits, false)

        if outcome == :completed do
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            """
            INSERT INTO agent_search_cache (key, result, fetched_at)
            VALUES ($1, $2, now())
            ON CONFLICT (key) DO UPDATE SET result = EXCLUDED.result, fetched_at = EXCLUDED.fetched_at
            """,
            [cache_key(command.arguments["query"]), result],
            log: false
          )
        end

        :ok
      else
        :stale
      end
    end)
  end

  defp finish_locked!(command, vm, turn, status, result, credits, cache_hit) do
    if status != :cancelled, do: Marshall.Compute.Idle.touch_locked!(vm)
    Ledger.update!(command, :transition, %{status: status, result: result})

    Ledger.create!(SearchUsage, :record, %{
      command_id: command.id,
      vm_id: vm.id,
      thread_id: command.thread_id,
      actor_id: turn.actor_id,
      credits: credits,
      cache_hit: cache_hit,
      outcome: if(status == :cancelled, do: :failed, else: status)
    })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: command.thread_id,
      turn_id: command.turn_id,
      actor_id: turn.actor_id,
      kind: :tool_finished,
      target_id: command.id,
      outcome: if(status == :cancelled, do: :failed, else: status)
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.search_finished",
        vm_id: vm.id,
        command_id: command.id,
        outcome: status,
        credits: credits
      )
    end)
  end

  @spec reap() :: :ok
  def reap do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT id FROM agent_commands WHERE tool = 'web_search' AND status = 'claimed'
          AND claimed_at < now() - interval '60 seconds'
        ORDER BY claimed_at, id LIMIT 128
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [raw_id] ->
      Ledger.transaction(fn ->
        command = Ledger.lock!(Command, Ecto.UUID.load!(raw_id))

        if (command && command.status == :claimed) and
             DateTime.compare(
               command.claimed_at,
               DateTime.add(Ledger.now(), -@claim_timeout_seconds, :second)
             ) == :lt do
          [root] = Ledger.read!(Root, id: command.root_id)
          [turn] = Ledger.read!(Turn, id: command.turn_id)
          [vm] = Ledger.read!(VirtualMachine, id: root.vm_id)
          finish_locked!(command, vm, turn, :uncertain, %{"reason" => "result_lost"}, nil, false)
        end
      end)
    end)

    :ok
  end

  @spec prune_cache() :: :ok
  def prune_cache do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      DELETE FROM agent_search_cache WHERE ctid IN
        (SELECT ctid FROM agent_search_cache WHERE fetched_at <= now() - interval '24 hours'
         ORDER BY fetched_at LIMIT 128)
      """,
      [],
      log: false
    )

    :ok
  end
end
