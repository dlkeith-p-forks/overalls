defmodule Marshall.Artifacts.Blobs do
  @moduledoc "Content-addressed chunk storage in PostgreSQL, written once and streamed."
  import Ecto.Query
  alias Marshall.Repo

  @chunk_bytes 1_048_576

  @type sha256 :: String.t()

  @spec sha256(iodata()) :: sha256()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # @cc [owner:ghuntley,label:durability;security] artifact-blob-content-address
  # A blob row and its chunks MUST be written in the caller's transaction and
  # MUST hash to their key; an existing key is reused, never rewritten.
  @spec put!(binary()) :: {sha256(), non_neg_integer()}
  def put!(bytes) when is_binary(bytes) do
    sha = sha256(bytes)

    unless exists?(sha) do
      chunks = chunk(bytes)
      now = DateTime.utc_now()

      Repo.insert_all(
        "artifact_blobs",
        [%{sha256: sha, bytes: byte_size(bytes), chunk_count: length(chunks), inserted_at: now}],
        on_conflict: :nothing
      )

      chunks
      |> Enum.with_index()
      |> Enum.chunk_every(16)
      |> Enum.each(fn batch ->
        Repo.insert_all(
          "artifact_blob_chunks",
          Enum.map(batch, fn {data, index} -> %{sha256: sha, index: index, data: data} end),
          on_conflict: :nothing
        )
      end)
    end

    {sha, byte_size(bytes)}
  end

  @doc "Promotes verified staged chunks into a blob; returns false when the hash disagrees."
  @spec put_staged!(String.t(), non_neg_integer(), sha256()) :: boolean()
  def put_staged!(request_id, file_index, expected) do
    hash =
      request_id
      |> staged_stream(file_index)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    cond do
      hash != expected ->
        false

      exists?(hash) ->
        true

      true ->
        %{rows: [[bytes, count]]} =
          Repo.query!(
            """
            SELECT coalesce(sum(octet_length(data)), 0)::bigint, count(*)::int
            FROM artifact_staged_chunks WHERE publish_request_id = $1 AND file_index = $2
            """,
            [Ecto.UUID.dump!(request_id), file_index]
          )

        Repo.insert_all(
          "artifact_blobs",
          [%{sha256: hash, bytes: bytes, chunk_count: count, inserted_at: DateTime.utc_now()}],
          on_conflict: :nothing
        )

        Repo.query!(
          """
          INSERT INTO artifact_blob_chunks (sha256, index, data)
          SELECT $3, chunk_index, data FROM artifact_staged_chunks
          WHERE publish_request_id = $1 AND file_index = $2
          ON CONFLICT DO NOTHING
          """,
          [Ecto.UUID.dump!(request_id), file_index, hash]
        )

        true
    end
  end

  @spec exists?(sha256()) :: boolean()
  def exists?(sha), do: Repo.exists?(from(b in "artifact_blobs", where: b.sha256 == ^sha))

  @spec size(sha256()) :: non_neg_integer() | nil
  def size(sha),
    do: Repo.one(from(b in "artifact_blobs", where: b.sha256 == ^sha, select: b.bytes))

  @doc "Reads a whole blob. Only for bounded blobs such as the page (16 MiB)."
  @spec read!(sha256()) :: binary()
  def read!(sha), do: sha |> stream() |> Enum.join()

  @doc "Lazily streams a blob chunk by chunk, one query per chunk."
  @spec stream(sha256()) :: Enumerable.t()
  def stream(sha) do
    Stream.resource(
      fn -> 0 end,
      fn index ->
        case Repo.one(
               from(c in "artifact_blob_chunks",
                 where: c.sha256 == ^sha and c.index == ^index,
                 select: c.data
               )
             ) do
          nil -> {:halt, index}
          data -> {[data], index + 1}
        end
      end,
      fn _ -> :ok end
    )
  end

  @spec staged_stream(String.t(), non_neg_integer()) :: Enumerable.t()
  defp staged_stream(request_id, file_index) do
    id = Ecto.UUID.dump!(request_id)

    Stream.resource(
      fn -> 0 end,
      fn index ->
        case Repo.one(
               from(c in "artifact_staged_chunks",
                 where:
                   c.publish_request_id == ^id and c.file_index == ^file_index and
                     c.chunk_index == ^index,
                 select: c.data
               )
             ) do
          nil -> {:halt, index}
          data -> {[data], index + 1}
        end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Deletes at most `limit` blobs no version references, older than the grace
  period. Chunks follow by `ON DELETE CASCADE`.
  """
  @spec sweep!(pos_integer(), non_neg_integer()) :: non_neg_integer()
  def sweep!(limit, grace_seconds) do
    %{num_rows: count} =
      Repo.query!(
        """
        WITH doomed AS (
          SELECT b.sha256 FROM artifact_blobs AS b
          WHERE b.inserted_at < now() - make_interval(secs => $2)
            AND NOT EXISTS (SELECT 1 FROM artifact_versions v WHERE v.page_sha256 = b.sha256)
            AND NOT EXISTS (SELECT 1 FROM artifact_version_files f WHERE f.sha256 = b.sha256)
          LIMIT $1 FOR UPDATE SKIP LOCKED
        )
        DELETE FROM artifact_blobs b USING doomed d WHERE b.sha256 = d.sha256
        """,
        [limit, grace_seconds]
      )

    count
  end

  @spec chunk(binary()) :: [binary()]
  defp chunk(<<>>), do: [<<>>]

  defp chunk(bytes), do: do_chunk(bytes, [])

  defp do_chunk(<<chunk::binary-size(@chunk_bytes), rest::binary>>, acc) when rest != <<>>,
    do: do_chunk(rest, [chunk | acc])

  defp do_chunk(rest, acc), do: Enum.reverse([rest | acc])
end
