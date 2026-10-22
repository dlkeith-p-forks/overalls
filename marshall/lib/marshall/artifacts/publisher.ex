defmodule Marshall.Artifacts.Publisher do
  @moduledoc """
  Publishes one artifact version under optimistic concurrency.

  The page and files are resolved against the immutable base version before the
  transaction, so edit and limit refusals never hold a lock. Inside the
  transaction the artifact is locked, Cedar and the base are rechecked, blobs
  are stored and the version, head and audit row commit together.
  """
  require Marshall.Events
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Audit, Authorization, Blobs, Edits, Limits, Manifest}
  alias Marshall.Artifacts.{Paths, Version, VersionFile}
  alias Marshall.Compute.Ledger

  @type page :: {:content, binary()} | {:edits, [Edits.edit()]} | :keep
  @type file_change ::
          {:bytes, binary(), String.t() | nil}
          | {:blob, Blobs.sha256(), non_neg_integer(), String.t() | nil}
          | nil
  @type request :: %{
          required(:artifact_id) => String.t() | nil,
          required(:base_version) => non_neg_integer(),
          required(:page) => page(),
          required(:via) => :agent | :web,
          optional(:files) => %{String.t() => file_change()},
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:format) => :html | :markdown | nil,
          optional(:command_id) => String.t() | nil,
          optional(:source_thread_id) => String.t() | nil
        }
  @type published :: %{artifact: Artifact.t(), version: Version.t(), replayed: boolean()}
  @type refusal :: {:error, atom()} | {:error, atom(), map()}

  # @cc [owner:ghuntley,label:correctness;security] artifact-optimistic-base
  # A publish MUST name the version it was built from. It commits only when
  # that base equals the locked artifact's current version (0 creates a new
  # artifact), the actor currently holds Cedar publish (or create) authority and
  # the artifact is active. A stale base MUST be refused with the current
  # version and change nothing. A retried command returns its committed version.
  @spec publish(User.t(), request()) :: {:ok, published()} | refusal()
  def publish(%User{} = actor, %{} = request) do
    result =
      Overalls.Diagnostics.Tracing.with_span(
        "marshall.artifact.publish",
        [via: request.via],
        fn -> do_publish(actor, request) end
      )

    report(actor, request, result)
    result
  end

  @spec do_publish(User.t(), request()) :: {:ok, published()} | refusal()
  defp do_publish(actor, request) do
    case replay(request) do
      {:ok, published} ->
        {:ok, published}

      :none ->
        with {:ok, head} <- authorized_head(actor, request),
             {:ok, base} <- base_contents(head, request.base_version),
             {:ok, page} <- resolve_page(base, request.page),
             {:ok, files, sent} <- resolve_files(base, Map.get(request, :files, %{})),
             :ok <- check_limits(page, files, sent) do
          commit(actor, request, page, files)
        end
    end
  end

  @spec replay(request()) :: {:ok, published()} | :none
  defp replay(%{command_id: command_id}) when is_binary(command_id) do
    case Ledger.read!(Version, command_id: command_id) do
      [%Version{} = version] ->
        [artifact] = Ledger.read!(Artifact, id: version.artifact_id)
        {:ok, %{artifact: artifact, version: version, replayed: true}}

      [] ->
        :none
    end
  end

  defp replay(_), do: :none

  @spec authorized_head(User.t(), request()) :: {:ok, Artifact.t() | nil} | refusal()
  defp authorized_head(actor, %{artifact_id: nil, base_version: 0}) do
    if Authorization.create_allowed?(actor), do: {:ok, nil}, else: {:error, :forbidden}
  end

  defp authorized_head(_actor, %{artifact_id: nil}),
    do: {:error, :stale_base_version, %{current_version: 0}}

  defp authorized_head(actor, %{artifact_id: id}) do
    case Ledger.read!(Artifact, id: id) do
      [%Artifact{} = artifact] ->
        cond do
          not Authorization.allowed?(artifact, actor, :read) -> {:error, :not_found}
          artifact.state != :active -> {:error, :inactive}
          not Authorization.allowed?(artifact, actor, :publish) -> {:error, :forbidden}
          true -> {:ok, artifact}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @type contents :: %{
          page: {:blob, Blobs.sha256()} | nil,
          files: Manifest.files(),
          format: atom() | nil
        }

  @spec base_contents(Artifact.t() | nil, non_neg_integer()) :: {:ok, contents()} | refusal()
  defp base_contents(nil, 0), do: {:ok, %{page: nil, files: %{}, format: nil}}

  defp base_contents(%Artifact{current_version: current}, base) when base != current,
    do: {:error, :stale_base_version, %{current_version: current}}

  defp base_contents(%Artifact{current_version: 0}, 0),
    do: {:ok, %{page: nil, files: %{}, format: nil}}

  defp base_contents(%Artifact{} = artifact, base) do
    [version] = Ledger.read!(Version, artifact_id: artifact.id, number: base)

    files =
      for file <- Ledger.read!(VersionFile, version_id: version.id), into: %{} do
        {file.path, %{sha256: file.sha256, bytes: file.bytes, content_type: file.content_type}}
      end

    {:ok, %{page: {:blob, version.page_sha256}, files: files, format: version.format}}
  end

  @spec resolve_page(contents(), page()) :: {:ok, binary()} | refusal()
  defp resolve_page(_base, {:content, content}) when is_binary(content), do: {:ok, content}
  defp resolve_page(%{page: nil}, _), do: {:error, :edit_not_found, %{index: 0}}
  defp resolve_page(%{page: {:blob, sha}}, :keep), do: {:ok, Blobs.read!(sha)}

  defp resolve_page(%{page: {:blob, sha}}, {:edits, edits}),
    do: Edits.apply(Blobs.read!(sha), edits)

  @spec resolve_files(contents(), %{String.t() => file_change()}) ::
          {:ok, Manifest.files(), {non_neg_integer(), non_neg_integer()}} | refusal()
  defp resolve_files(base, changes) do
    prepared =
      Enum.reduce_while(changes, {:ok, %{}, {0, 0}}, fn {path, change},
                                                        {:ok, acc, {count, bytes}} ->
        case prepare(path, change) do
          {:ok, entry, sent} ->
            {:cont, {:ok, Map.put(acc, path, entry), {count + 1, bytes + sent}}}

          error ->
            {:halt, error}
        end
      end)

    with {:ok, normalized, sent} <- prepared,
         {:ok, files} <- Manifest.apply(base.files, normalized) do
      {:ok, files, sent}
    end
  end

  @spec prepare(String.t(), file_change()) ::
          {:ok, Manifest.change() | {:pending, binary(), Manifest.entry()}, non_neg_integer()}
          | refusal()
  defp prepare(_path, nil), do: {:ok, nil, 0}

  defp prepare(path, {:bytes, bytes, declared}) do
    with {:ok, normalized} <- Paths.normalize(path),
         true <- Paths.declared_type_ok?(normalized, declared) || {:error, :invalid_path} do
      {type, _} = Paths.media_type(normalized)
      sha = Blobs.sha256(bytes)

      {:ok, %{sha256: sha, bytes: byte_size(bytes), content_type: type, data: bytes},
       byte_size(bytes)}
    end
  end

  defp prepare(path, {:blob, sha, bytes, declared}) do
    with {:ok, normalized} <- Paths.normalize(path),
         true <- Paths.declared_type_ok?(normalized, declared) || {:error, :invalid_path} do
      {type, _} = Paths.media_type(normalized)
      {:ok, %{sha256: sha, bytes: bytes, content_type: type}, bytes}
    end
  end

  @spec check_limits(binary(), Manifest.files(), {non_neg_integer(), non_neg_integer()}) ::
          :ok | refusal()
  defp check_limits(page, files, {sent_files, sent_bytes}) do
    {version_bytes, version_files} = Manifest.totals(files, byte_size(page))

    Limits.check(%{
      page_bytes: byte_size(page),
      publish_files: sent_files,
      publish_bytes: sent_bytes + byte_size(page),
      version_files: version_files,
      version_bytes: version_bytes
    })
  end

  @spec commit(User.t(), request(), binary(), Manifest.files()) ::
          {:ok, published()} | refusal()
  defp commit(actor, request, page, files) do
    Ledger.transaction(
      fn ->
        artifact = lock_or_create!(actor, request)
        Authorization.require!(artifact, actor, :publish)
        if artifact.state != :active, do: Ledger.rollback(:inactive)

        if artifact.current_version != request.base_version,
          do: Ledger.rollback(:stale_base_version)

        {page_sha, page_bytes} = Blobs.put!(page)

        Enum.each(files, fn
          {_path, %{data: data}} -> Blobs.put!(data)
          _ -> :ok
        end)

        {total_bytes, file_count} = Manifest.totals(files, page_bytes)
        number = artifact.current_version + 1
        title = request[:title] || artifact.title
        format = request[:format] || artifact.format

        version =
          Ledger.create!(Version, :record, %{
            artifact_id: artifact.id,
            number: number,
            base_number: request.base_version,
            command_id: request[:command_id],
            author_id: actor.id,
            page_sha256: page_sha,
            page_bytes: page_bytes,
            total_bytes: total_bytes,
            file_count: file_count,
            title: title,
            format: format
          })

        Enum.each(files, fn {path, entry} ->
          Ledger.create!(VersionFile, :record, %{
            version_id: version.id,
            artifact_id: artifact.id,
            path: path,
            sha256: entry.sha256,
            bytes: entry.bytes,
            content_type: entry.content_type
          })
        end)

        artifact =
          Ledger.update!(artifact, :advance, %{
            current_version: number,
            title: title,
            description: Map.get(request, :description) || artifact.description,
            format: format,
            total_bytes: total_bytes,
            file_count: file_count
          })

        Audit.record!(%{
          artifact_id: artifact.id,
          actor_id: actor.id,
          kind: :published,
          via: request.via,
          version: number,
          bytes: total_bytes
        })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("artifact.published",
            artifact_id: artifact.id,
            version: number,
            via: request.via
          )
        end)

        %{artifact: artifact, version: version, replayed: false}
      end,
      {:user, actor.id}
    )
    |> case do
      {:ok, published} ->
        {:ok, published}

      {:error, :stale_base_version} ->
        current =
          case request.artifact_id && Ledger.read!(Artifact, id: request.artifact_id) do
            [%Artifact{current_version: current}] -> current
            _ -> 0
          end

        {:error, :stale_base_version, %{current_version: current}}

      {:error, reason} when reason in [:forbidden, :inactive, :not_found] ->
        {:error, reason}

      {:error, _} ->
        # A concurrent duplicate of the same command may have won the race.
        case replay(request) do
          {:ok, published} -> {:ok, published}
          :none -> {:error, :tool_failed}
        end
    end
  end

  @spec lock_or_create!(User.t(), request()) :: Artifact.t()
  defp lock_or_create!(actor, %{artifact_id: nil} = request) do
    unless Authorization.create_allowed?(actor), do: Ledger.rollback(:forbidden)

    artifact =
      Ledger.create!(Artifact, :create, %{
        owner_id: actor.id,
        title: request[:title] || "Untitled",
        description: request[:description],
        format: request[:format] || :html,
        source_thread_id: request[:source_thread_id],
        created_via: request.via
      })

    Audit.record!(%{
      artifact_id: artifact.id,
      actor_id: actor.id,
      kind: :created,
      via: request.via
    })

    artifact
  end

  defp lock_or_create!(_actor, %{artifact_id: id}),
    do: Ledger.lock!(Artifact, id) || Ledger.rollback(:not_found)

  @spec report(User.t(), request(), {:ok, published()} | refusal()) :: :ok
  defp report(actor, request, result) do
    case result do
      {:ok, %{replayed: false, version: version}} ->
        Overalls.Diagnostics.Metrics.record(
          [:marshall, :artifacts, :publish],
          %{bytes: version.total_bytes, file_count: version.file_count},
          %{}
        )

      {:ok, _} ->
        :ok

      refusal ->
        reason = elem(refusal, 1)

        Audit.refusal(%{
          artifact_id: request.artifact_id,
          actor_id: actor.id,
          kind: :publish_refused,
          via: request.via,
          reason: reason
        })

        Marshall.Events.emit("artifact.publish_refused",
          artifact_id: request.artifact_id,
          reason: event_reason(reason),
          via: request.via
        )

        Overalls.Diagnostics.Metrics.record(
          [:marshall, :artifacts, :refusal],
          %{count: 1},
          %{reason: event_reason(reason)}
        )
    end

    :ok
  end

  @spec event_reason(atom()) :: atom()
  defp event_reason(reason) do
    if reason in Marshall.Artifacts.AuditEvent.reasons(), do: reason, else: :other
  end
end
