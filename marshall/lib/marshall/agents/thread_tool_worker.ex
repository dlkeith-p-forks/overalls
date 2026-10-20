defmodule Marshall.Agents.ThreadToolWorker do
  @moduledoc "Executes server-owned typed thread tool commands."
  use GenServer
  alias Marshall.Agents.{AttachmentTool, Command, ThreadTool, Turn}
  alias Marshall.Compute.Ledger

  @poll_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    send(self(), :poll)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    claim_one()
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  defp claim_one do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
          SELECT c.id FROM agent_commands c
          JOIN agent_turns t ON t.id = c.turn_id AND t.thread_id = c.thread_id
          WHERE c.tool = 'thread' AND c.status = 'queued' AND t.status = 'running'
          ORDER BY c.inserted_at LIMIT 1
        """,
        [],
        log: false
      )

    case rows do
      [[raw_id]] -> execute(Ledger.lock!(Command, Ecto.UUID.load!(raw_id)))
      [] -> :ok
    end
  rescue
    _ -> :ok
  end

  defp execute(command) do
    result =
      case Ledger.read!(Turn, id: command.turn_id) do
        [%Turn{actor_id: owner_id}] -> dispatch(owner_id, command.arguments)
        _ -> {:error, :thread_unavailable}
      end

    {status, payload} =
      case result do
        {:ok, value} -> {:completed, %{items: List.wrap(value)}}
        {:error, reason} -> {:failed, %{reason: Atom.to_string(reason)}}
      end

    Ledger.update!(command, :transition, %{status: status, result: payload})
  end

  defp dispatch(owner_id, %{"operation" => "search"} = args),
    do: {:ok, ThreadTool.search!(owner_id, Map.get(args, "query"), Map.get(args, "limit", 50))}

  defp dispatch(owner_id, %{"operation" => "read", "thread_id" => thread_id}),
    do: {:ok, ThreadTool.read!(owner_id, thread_id)}

  defp dispatch(owner_id, %{"operation" => "subscribe", "thread_id" => thread_id} = args),
    do: {:ok, ThreadTool.subscribe!(owner_id, thread_id, Map.get(args, "active", true))}

  defp dispatch(owner_id, %{"operation" => "replay", "thread_id" => thread_id} = args),
    do:
      {:ok,
       ThreadTool.replay!(
         owner_id,
         thread_id,
         Map.get(args, "cursor", 0),
         Map.get(args, "limit", 100)
       )}

  defp dispatch(owner_id, %{"operation" => "upload", "thread_id" => thread_id} = args),
    do: AttachmentTool.upload(owner_id, thread_id, args)

  defp dispatch(owner_id, %{"operation" => "download", "attachment_id" => attachment_id}),
    do: AttachmentTool.download(owner_id, attachment_id)


  defp dispatch(_, _), do: {:error, :invalid_operation}
end
