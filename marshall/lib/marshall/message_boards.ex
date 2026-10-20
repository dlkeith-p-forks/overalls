defmodule Marshall.MessageBoards do
  @moduledoc "User/profile message boards with machine-scoped cleanup."
  import Ecto.Query
  alias Marshall.Repo

  @profiles [:standard, :oss]
  @max_body 65_536

  @type profile :: :standard | :oss
  @type post :: %{
          id: String.t(),
          board_id: String.t(),
          author_id: String.t(),
          body: String.t(),
          vm_id: String.t() | nil,
          thread_id: String.t() | nil,
          root_id: String.t()
        }

  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @spec list!(String.t(), profile()) :: [post()]
  def list!(user_id, profile) when is_binary(user_id) and profile in @profiles do
    board_id = ensure_board!(user_id, profile)

    Repo.all(
      from p in "message_board_posts",
        where: p.board_id == ^board_id,
        order_by: [desc: p.inserted_at],
        limit: 100,
        select: p
    )
    |> Enum.map(&Map.new/1)
  end

  @spec ensure_board!(String.t(), profile()) :: String.t()
  def ensure_board!(user_id, profile) when is_binary(user_id) and profile in @profiles do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      "message_boards",
      [
        %{
          id: id,
          user_id: user_id,
          profile: Atom.to_string(profile),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_id, :profile]
    )

    Repo.one!(
      from(b in "message_boards",
        where: b.user_id == ^user_id and b.profile == ^Atom.to_string(profile),
        select: b.id
      )
    )
  end

  @spec post!(String.t(), profile(), String.t(), String.t(), keyword()) ::
          {:ok, post()} | {:error, atom()}
  def post!(author_id, profile, request_key, body, opts \\ [])
      when is_binary(author_id) and profile in @profiles and is_binary(request_key) and
             is_binary(body) do
    if body == "" or byte_size(body) > @max_body,
      do: {:error, :invalid_body},
      else: do_post(author_id, profile, request_key, body, opts)
  end

  @spec purge_machine!(String.t()) :: non_neg_integer()
  def purge_machine!(vm_id) when is_binary(vm_id) do
    {count, _} = Repo.delete_all(from(p in "message_board_posts", where: p.vm_id == ^vm_id))
    count
  end

  @doc "Purges board entries when the VM state machine reaches an unavailable state."
  @spec purge_for_state!(String.t(), atom()) :: non_neg_integer()
  def purge_for_state!(vm_id, state) when state in [:paused, :stopped, :deleted],
    do: purge_machine_with_events!(vm_id, state)

  def purge_for_state!(_vm_id, _state), do: 0

  defp purge_machine_with_events!(vm_id, state) do
    threads =
      Repo.all(
        from p in "message_board_posts",
          where: p.vm_id == ^vm_id,
          distinct: true,
          select: p.thread_id
      )

    count = purge_machine!(vm_id)

    Marshall.Events.emit("agent.message_board_machine_purged",
      vm_id: vm_id,
      state: state,
      purged_count: count
    )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(Enum.reject(threads, &is_nil/1), fn thread_id ->
      %{max: sequence} =
        Repo.one(
          from e in "agent_thread_tool_events",
            where: e.thread_id == ^thread_id,
            select: %{max: max(e.sequence)}
        )

      Repo.insert_all(
        "agent_thread_tool_events",
        [
          %{
            id: Ecto.UUID.generate(),
            thread_id: thread_id,
            owner_id: owner_for_thread(thread_id),
            sequence: (sequence || 0) + 1,
            kind: "machine_purged",
            metadata: %{state: Atom.to_string(state), vm_id: vm_id, count: count},
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )
    end)

    count
  end

  defp owner_for_thread(thread_id) do
    Repo.one(
      from t in "agent_threads",
        join: r in "agent_roots",
        on: r.id == t.root_id,
        where: t.id == ^thread_id,
        select: r.owner_id
    )
  end

  @spec purge_thread!(String.t()) :: non_neg_integer()
  def purge_thread!(thread_id) when is_binary(thread_id) do
    {count, _} =
      Repo.delete_all(from(p in "message_board_posts", where: p.thread_id == ^thread_id))

    count
  end

  defp do_post(author_id, profile, request_key, body, opts) do
    board_id = ensure_board!(author_id, profile)

    attrs = %{
      id: Ecto.UUID.generate(),
      board_id: board_id,
      author_id: author_id,
      vm_id: opts[:vm_id],
      thread_id: opts[:thread_id],
      root_id: opts[:root_id] || Ecto.UUID.generate(),
      request_key: request_key,
      body: body,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case Repo.insert_all("message_board_posts", [attrs],
           on_conflict: :nothing,
           conflict_target: [:board_id, :author_id, :request_key],
           returning: true
         ) do
      {1, [row]} ->
        {:ok, Map.new(row)}

      {0, _} ->
        existing =
          Repo.one(
            from(p in "message_board_posts",
              where:
                p.board_id == ^board_id and p.author_id == ^author_id and
                  p.request_key == ^request_key,
              select: p
            )
          )

        case existing do
          %{} = post when post.body == body -> {:ok, Map.new(post)}
          %{} -> {:error, :request_key_conflict}
          nil -> {:error, :post_failed}
        end
    end
  end
end
