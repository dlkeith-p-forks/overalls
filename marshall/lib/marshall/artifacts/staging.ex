defmodule Marshall.Artifacts.Staging do
  @moduledoc """
  Large publishes staged from the guest: Marshall queues an internal
  `artifact_stage` command, Lyra streams bounded, hashed chunks back over the
  fenced executor RPC, and the parent `artifact` command resumes once staging
  finishes.
  """
  import Ecto.Query
  alias Marshall.Agents.{Command, ServerToolJob}
  alias Marshall.Artifacts.{Blobs, Limits, Paths, Publisher, PublishRequest, Tool}
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @chunk_bytes 196_608
  @ttl_seconds 1_800

  @spec chunk_bytes() :: pos_integer()
  def chunk_bytes, do: @chunk_bytes

  @spec staged?(Tool.Request.t()) :: boolean()
  def staged?(%Tool.Request{page: page, files: files}) do
    match?({:stage, _}, page) or
      Enum.any?(files, fn {_, file} -> match?({:stage, _, _}, file) end)
  end

  @doc """
  Advances a staged publish for its parent command. Returns `:pending` while
  the guest is still uploading; otherwise the publish outcome.
  """
  @spec advance(
          Tool.Request.t(),
          Marshall.Agents.ServerTool.context(),
          Marshall.Accounts.User.t()
        ) ::
          {:ready, Publisher.request()} | :pending | {:error, atom()}
  def advance(request, context, actor) do
    case Ledger.read!(PublishRequest, command_id: context.command.id) do
      [] -> open(request, context, actor)
      [%PublishRequest{} = staged] -> resume(staged, request, context)
    end
  end

  @spec open(Tool.Request.t(), Marshall.Agents.ServerTool.context(), Marshall.Accounts.User.t()) ::
          :pending | {:error, atom()}
  defp open(request, context, actor) do
    sources = sources(request)

    {:ok, _} =
      Ledger.transaction(
        fn ->
          command = context.command

          staged =
            Ledger.create!(PublishRequest, :open, %{
              command_id: command.id,
              user_id: actor.id,
              vm_id: context.vm.id,
              files:
                Enum.map(sources, fn {index, path, _source, type} ->
                  %{"file_index" => index, "path" => path, "content_type" => type}
                end),
              expires_at: DateTime.add(Ledger.now(), @ttl_seconds, :second)
            })

          stage =
            Ledger.create!(Command, :queue, %{
              root_id: command.root_id,
              thread_id: command.thread_id,
              turn_id: command.turn_id,
              call_id: "artifact_stage:" <> command.id,
              tool: :artifact_stage,
              arguments: %{
                "publish_request_id" => staged.id,
                "max_file_bytes" => Limits.publish_bytes(),
                "max_total_bytes" => Limits.publish_bytes(),
                "files" =>
                  Enum.map(sources, fn {index, _path, source, _type} ->
                    %{"file_index" => index, "source_path" => source}
                  end)
              }
            })

          Ledger.update!(staged, :attach_stage, %{stage_command_id: stage.id})
        end,
        {:user, actor.id}
      )

    :pending
  end

  # The page is file index 0 when staged; supporting files follow in path order.
  @spec sources(Tool.Request.t()) ::
          [{non_neg_integer(), String.t(), String.t(), String.t() | nil}]
  defp sources(%Tool.Request{page: page, files: files}) do
    page_source =
      with {:stage, source} <- page, do: [{Paths.page(), source, nil}], else: (_ -> [])

    file_sources =
      for {path, {:stage, source, type}} <- Enum.sort(files), do: {path, source, type}

    (page_source ++ file_sources)
    |> Enum.with_index()
    |> Enum.map(fn {{path, source, type}, index} -> {index, path, source, type} end)
  end

  @spec resume(PublishRequest.t(), Tool.Request.t(), Marshall.Agents.ServerTool.context()) ::
          {:ready, Publisher.request()} | :pending | {:error, atom()}
  defp resume(%PublishRequest{state: :staging} = staged, request, context) do
    case Ledger.read!(Command, id: staged.stage_command_id) do
      [%Command{status: status}] when status in [:queued, :claimed, :started] ->
        :pending

      [%Command{status: :completed, result: %{"files" => reported}}] ->
        promote(staged, request, context, reported)

      _ ->
        refuse(staged, :upload_refused)
    end
  end

  defp resume(%PublishRequest{state: :committed}, request, context),
    do: {:ready, Tool.publisher_request(request, context)}

  defp resume(%PublishRequest{state: :refused, reason: reason}, _, _),
    do: {:error, reason || :upload_refused}

  defp resume(%PublishRequest{}, _, _), do: {:error, :staging_unavailable}

  # @cc [owner:ghuntley,label:security;durability] artifact-staged-promotion
  # A staged file becomes a blob only when every declared file was reported,
  # its chunks are dense from zero and the whole-file SHA-256 recomputed from
  # the stored chunks equals the guest's report. Any mismatch refuses the
  # publish and releases the staged chunks.
  @spec promote(PublishRequest.t(), Tool.Request.t(), map(), term()) ::
          {:ready, Publisher.request()} | {:error, atom()}
  defp promote(staged, request, context, reported) when is_list(reported) do
    by_index = Map.new(reported, fn entry -> {entry["file_index"], entry} end)

    promoted =
      Enum.reduce_while(staged.files, {:ok, %{}}, fn %{"file_index" => index} = file,
                                                     {:ok, acc} ->
        with %{"sha256" => sha, "bytes" => bytes} when is_binary(sha) and is_integer(bytes) <-
               Map.get(by_index, index),
             {:ok, true} <- store(staged.id, index, sha, bytes),
             ^bytes <- Blobs.size(sha) do
          {:cont, {:ok, Map.put(acc, file["path"], {sha, bytes, file["content_type"]})}}
        else
          _ -> {:halt, :error}
        end
      end)

    case promoted do
      {:ok, blobs} ->
        base = Tool.publisher_request(request, context)

        page =
          case Map.fetch(blobs, Paths.page()) do
            {:ok, {sha, _bytes, _}} -> {:content, Blobs.read!(sha)}
            :error -> base.page
          end

        files =
          Map.new(base.files, fn
            {path, {:stage, _source, type}} ->
              {sha, bytes, _} = Map.fetch!(blobs, path)
              {path, {:blob, sha, bytes, type}}

            other ->
              other
          end)

        {:ready, %{base | page: page, files: files}}

      :error ->
        refuse(staged, :upload_refused)
    end
  end

  defp promote(staged, _, _, _), do: refuse(staged, :upload_refused)

  @doc "Records the publish outcome for a staged request and releases its chunks."
  @spec settle(String.t(), {:ok, term()} | {:error, atom()} | {:error, atom(), map()}) :: :ok
  def settle(command_id, outcome) do
    {:ok, _} =
      Ledger.transaction(
        fn ->
          case Ledger.read!(PublishRequest, command_id: command_id) do
            [%PublishRequest{state: :staging} = staged] ->
              locked = Ledger.lock!(PublishRequest, staged.id)

              case outcome do
                {:ok, %{artifact: artifact, version: version}} ->
                  Ledger.update!(locked, :commit, %{
                    artifact_id: artifact.id,
                    version_number: version.number
                  })

                refusal ->
                  Ledger.update!(locked, :refuse, %{reason: elem(refusal, 1)})
              end

              release!(staged.id)

            _ ->
              :ok
          end
        end,
        {:system, nil}
      )

    :ok
  end

  @spec refuse(PublishRequest.t(), atom()) :: {:error, atom()}
  defp refuse(staged, reason) do
    {:ok, _} =
      Ledger.transaction(
        fn ->
          case Ledger.lock!(PublishRequest, staged.id) do
            %PublishRequest{state: :staging} = locked ->
              Ledger.update!(locked, :refuse, %{reason: reason})
              release!(staged.id)

            _ ->
              :ok
          end
        end,
        {:system, nil}
      )

    {:error, reason}
  end

  # An empty file arrives as zero chunks; it is stored only if the guest
  # reported the empty-content digest, otherwise chunks must be dense from zero.
  @spec store(String.t(), non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, term()}
  defp store(request_id, index, sha, 0) do
    if sha == Blobs.sha256("") and not dense?(request_id, index) do
      Ledger.transaction(fn ->
        Blobs.put!("")
        true
      end)
    else
      {:ok, false}
    end
  end

  defp store(request_id, index, sha, _bytes) do
    if dense?(request_id, index),
      do: Ledger.transaction(fn -> Blobs.put_staged!(request_id, index, sha) end),
      else: {:ok, false}
  end

  @spec dense?(String.t(), non_neg_integer()) :: boolean()
  defp dense?(request_id, file_index) do
    id = Ecto.UUID.dump!(request_id)

    {count, max} =
      Repo.one(
        from(c in "artifact_staged_chunks",
          where: c.publish_request_id == ^id and c.file_index == ^file_index,
          select: {count(c.chunk_index), max(c.chunk_index)}
        )
      )

    count > 0 and max == count - 1
  end

  @spec release!(String.t()) :: :ok
  def release!(request_id) do
    id = Ecto.UUID.dump!(request_id)
    Repo.delete_all(from(c in "artifact_staged_chunks", where: c.publish_request_id == ^id))
    :ok
  end

  # @cc [owner:ghuntley,label:security;capacity] artifact-chunk-receipt
  # A chunk MUST belong to the staging request named by the started stage
  # command, a declared file index, the next or an identical repeated chunk
  # index, and keep the file within the per-file and the request within the
  # per-publish byte limits. Anything else is refused without storing bytes.
  @spec receive_chunk_locked!(Command.t(), %{
          publish_request_id: String.t(),
          file_index: non_neg_integer(),
          chunk_index: non_neg_integer(),
          sha256: String.t(),
          data: binary()
        }) :: :ok
  def receive_chunk_locked!(%Command{} = command, chunk) do
    unless command.arguments["publish_request_id"] == chunk.publish_request_id,
      do: Ledger.rollback(:upload_refused)

    staged = Ledger.lock!(PublishRequest, chunk.publish_request_id) || Ledger.rollback(:not_found)

    unless staged.state == :staging and staged.stage_command_id == command.id and
             DateTime.compare(staged.expires_at, Ledger.now()) == :gt and
             Enum.any?(staged.files, &(&1["file_index"] == chunk.file_index)),
           do: Ledger.rollback(:upload_refused)

    id = Ecto.UUID.dump!(staged.id)

    existing =
      Repo.one(
        from(c in "artifact_staged_chunks",
          where:
            c.publish_request_id == ^id and c.file_index == ^chunk.file_index and
              c.chunk_index == ^chunk.chunk_index,
          select: c.sha256
        )
      )

    {file_bytes, next_index} =
      Repo.one(
        from(c in "artifact_staged_chunks",
          where: c.publish_request_id == ^id and c.file_index == ^chunk.file_index,
          select: {coalesce(sum(fragment("octet_length(?)", c.data)), 0), count(c.chunk_index)}
        )
      )

    total_bytes =
      Repo.one(
        from(c in "artifact_staged_chunks",
          where: c.publish_request_id == ^id,
          select: coalesce(sum(fragment("octet_length(?)", c.data)), 0)
        )
      )

    size = byte_size(chunk.data)

    cond do
      existing == chunk.sha256 ->
        :ok

      existing != nil ->
        Ledger.rollback(:upload_refused)

      chunk.chunk_index != next_index ->
        Ledger.rollback(:upload_refused)

      to_int(file_bytes) + size > max_file_bytes(staged, chunk.file_index) ->
        Ledger.rollback(:upload_refused)

      to_int(total_bytes) + size > Limits.publish_bytes() ->
        Ledger.rollback(:upload_refused)

      true ->
        Repo.insert_all("artifact_staged_chunks", [
          %{
            publish_request_id: id,
            file_index: chunk.file_index,
            chunk_index: chunk.chunk_index,
            sha256: chunk.sha256,
            data: chunk.data,
            inserted_at: DateTime.utc_now()
          }
        ])

        :ok
    end
  end

  # The page is bounded by the page limit; supporting files by the publish limit.
  defp max_file_bytes(staged, index) do
    case Enum.find(staged.files, &(&1["file_index"] == index)) do
      %{"path" => "index.html"} -> Limits.page_bytes()
      _ -> Limits.publish_bytes()
    end
  end

  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_int(value) when is_integer(value), do: value

  @doc "Called in the transaction that finishes a stage command: resumes the parent."
  @spec stage_finished_locked!(Command.t()) :: :ok
  def stage_finished_locked!(%Command{id: id}) do
    case Ledger.read!(PublishRequest, stage_command_id: id) do
      [%PublishRequest{command_id: parent}] ->
        %{"command_id" => parent} |> ServerToolJob.new() |> Oban.insert!()
        :ok

      [] ->
        :ok
    end
  end
end
