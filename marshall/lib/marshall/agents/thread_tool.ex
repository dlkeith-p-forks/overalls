defmodule Marshall.Agents.ThreadTool do
  @moduledoc "Bounded, metadata-only thread discovery for agent tools."
  import Ecto.Query
  alias Marshall.Repo

  @type result :: %{id: String.t(), title: String.t(), url: String.t()}

  @spec search!(String.t(), String.t() | nil, pos_integer()) :: [result()]
  def search!(owner_id, query \\ nil, limit \\ 50)
      when is_binary(owner_id) and (is_nil(query) or is_binary(query)) and
             is_integer(limit) and limit in 1..100 do
    pattern = if query, do: "%" <> query <> "%", else: nil

    from(t in "agent_threads",
      join: r in "agent_roots",
      on: r.id == t.root_id,
      where: r.owner_id == ^owner_id,
      where: is_nil(^pattern) or ilike(t.title, ^pattern),
      order_by: [desc: t.inserted_at],
      limit: ^limit,
      select: %{id: t.id, title: t.title}
    )
    |> Repo.all()
    |> Enum.map(fn row -> Map.put(row, :url, "/threads/" <> row.id) end)
  end

  @spec read!(String.t(), String.t()) :: result() | nil
  def read!(owner_id, thread_id) when is_binary(owner_id) and is_binary(thread_id) do
    from(t in "agent_threads",
      join: r in "agent_roots",
      on: r.id == t.root_id,
      where: r.owner_id == ^owner_id and t.id == ^thread_id,
      select: %{id: t.id, title: t.title}
    )
    |> Repo.one()
    |> case do
      nil -> nil
      row -> Map.put(row, :url, "/threads/" <> row.id)
    end
  end

  @spec subscribe!(String.t(), String.t(), boolean()) :: :ok
  def subscribe!(owner_id, thread_id, active \\ true)
      when is_binary(owner_id) and is_binary(thread_id) and is_boolean(active) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      "agent_thread_tool_subscriptions",
      [
        %{
          id: Ecto.UUID.generate(),
          owner_id: owner_id,
          thread_id: thread_id,
          active: active,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:active, :updated_at]},
      conflict_target: [:owner_id, :thread_id]
    )

    :ok
  end

  @spec replay!(String.t(), String.t(), non_neg_integer(), pos_integer()) :: [map()]
  def replay!(owner_id, thread_id, after_sequence, limit \\ 100)
      when is_binary(owner_id) and is_binary(thread_id) and is_integer(after_sequence) and
             after_sequence >= 0 and limit in 1..100 do
    from(e in "agent_thread_tool_events",
      where:
        e.owner_id == ^owner_id and e.thread_id == ^thread_id and e.sequence > ^after_sequence,
      order_by: [asc: e.sequence],
      limit: ^limit,
      select: e
    )
    |> Repo.all()
    |> Enum.map(&Map.new/1)
  end
end
