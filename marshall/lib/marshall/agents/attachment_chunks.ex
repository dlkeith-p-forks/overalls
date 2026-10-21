defmodule Marshall.Agents.AttachmentChunks do
  @moduledoc "Trusted chunk persistence inside an authorized attachment transaction."
  alias Marshall.Agents.{Attachment, AttachmentChunk}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query
  require Marshall.Events

  @chunk_bytes 262_144

  # @cc [owner:ghuntley,label:security;durability] attachment-chunk-write
  # Callers MUST retain the authorized thread and attachment locks through commit.
  # Chunks MUST fit their declared aligned slot; identical retries reuse identity
  # and changed content MUST refuse. Plaintext MUST be encrypted with the Vault.
  @spec put_locked(Attachment.t(), non_neg_integer(), binary()) ::
          {:ok, String.t()} | {:error, atom()}
  def put_locked(%Attachment{state: :uploading, size_bytes: size} = row, offset, bytes)
      when is_integer(size) and size in 1..10_485_760 and is_integer(offset) and
             offset >= 0 and is_binary(bytes) do
    unless Marshall.Repo.in_transaction?(), do: raise(ArgumentError, "chunk transaction required")

    if rem(offset, @chunk_bytes) == 0 and offset < size and
         byte_size(bytes) == min(@chunk_bytes, size - offset) do
      digest = hash(bytes)

      case Ledger.read!(AttachmentChunk, attachment_id: row.id, offset: offset) do
        [] ->
          chunk =
            Ledger.create!(AttachmentChunk, :store, %{
              attachment_id: row.id,
              offset: offset,
              size_bytes: byte_size(bytes),
              sha256: digest,
              bytes: bytes
            })

          {:ok, chunk.id}

        [%{sha256: ^digest, size_bytes: count} = chunk] when count == byte_size(bytes) ->
          {:ok, chunk.id}

        _ ->
          {:error, :chunk_conflict}
      end
    else
      {:error, :invalid_chunk}
    end
  end

  def put_locked(_, _, _), do: {:error, :invalid_chunk}

  # @cc [owner:ghuntley,label:security;durability] attachment-chunk-assembly
  # Assembly MUST refuse missing, overlapping or corrupt chunks and require the
  # complete plaintext digest and size to match attachment metadata before publish.
  @spec assemble_locked(Attachment.t()) :: {:ok, binary()} | {:error, atom()}
  def assemble_locked(%Attachment{state: state, size_bytes: size} = row)
      when state in [:uploading, :available] and is_integer(size) and size in 0..10_485_760 do
    unless Marshall.Repo.in_transaction?(), do: raise(ArgumentError, "chunk transaction required")
    chunks = Ledger.read!(AttachmentChunk, attachment_id: row.id) |> Enum.sort_by(& &1.offset)

    result =
      Enum.reduce_while(chunks, {0, []}, fn chunk, {offset, parts} ->
        loaded = Ash.load!(chunk, [:bytes], actor: SystemActor.compute())

        if chunk.offset == offset and byte_size(loaded.bytes) == chunk.size_bytes and
             hash(loaded.bytes) == chunk.sha256 do
          {:cont, {offset + chunk.size_bytes, [loaded.bytes | parts]}}
        else
          {:halt, :invalid}
        end
      end)

    case result do
      {^size, parts} ->
        bytes = parts |> Enum.reverse() |> IO.iodata_to_binary()
        if hash(bytes) == row.sha256, do: {:ok, bytes}, else: {:error, :content_mismatch}

      _ ->
        {:error, :incomplete_upload}
    end
  end

  def assemble_locked(_), do: {:error, :invalid_upload}

  @spec delete_locked(Attachment.t()) :: :ok | {:error, atom()}
  def delete_locked(%Attachment{id: id, thread_id: thread_id}) do
    chunks =
      AttachmentChunk
      |> Ash.Query.filter(attachment_id == ^id)
      |> Ash.read!(actor: SystemActor.compute())

    Enum.each(chunks, &Ledger.archive!(&1, :destroy))

    if chunks != [] do
      Ledger.after_commit(fn ->
        Marshall.Events.emit("attachment.chunks_deleted",
          attachment_id: id,
          thread_id: thread_id,
          deleted_count: length(chunks)
        )
      end)
    end

    :ok
  end

  @spec hash(binary()) :: String.t()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
