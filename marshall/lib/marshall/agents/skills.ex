defmodule Marshall.Agents.Skills do
  @moduledoc "Thread-authorized skill manifests and fenced, immutable installation receipts."
  alias OverallsProtocol.WorkspaceSource
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Agents.{SkillInstallation, SkillOperation, SkillRevision}
  alias Marshall.Agents.Skills.{Catalog, Failures}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Authorization, Thread}
  require Marshall.Events
  require Ash.Query

  @type result :: {:ok, SkillOperation.t()} | {:error, term()}
  @type options :: [actor: User.t()]
  @max_installations 100
  @terminal [:completed, :failed]

  @spec list(String.t(), options()) :: {:ok, map()} | {:error, term()}
  def list(thread_id, options) do
    authorized(thread_id, options, "read", fn thread, _actor ->
      rows = installations(thread.id)
      %{items: Enum.map(rows, &projection/1), next_cursor: nil}
    end)
  end

  @spec install(map(), options()) :: result()
  def install(arguments, options) do
    with {:ok, source} <- source(arguments),
         {:ok, subdirectory} <- subdirectory(Map.get(arguments, :subdirectory, ".")) do
      request = %{"source" => WorkspaceSource.encode(source), "subdirectory" => subdirectory}

      mutate(:install, arguments, request, options, fn thread, actor ->
        ready!(thread)

        if length(installations(thread.id)) >= @max_installations,
          do: Ledger.rollback(:skill_limit)

        Ledger.create!(SkillInstallation, :register, %{
          thread_id: thread.id,
          created_by_id: actor.id,
          source: request["source"],
          subdirectory: subdirectory
        })
      end)
    end
  end

  @spec update(map(), options()) :: result()
  def update(arguments, options) do
    with :ok <- identifiers(arguments, :installation_id) do
      authorized(Map.get(arguments, :thread_id), options, "manage", fn thread, actor ->
        installation = installation!(thread.id, arguments.installation_id)
        {:ok, existing_source} = WorkspaceSource.decode(installation.source)

        source =
          case revision(existing_source, Map.get(arguments, :revision)) do
            {:ok, value} -> value
            {:error, reason} -> Ledger.rollback(reason)
          end

        request = %{
          "installation_id" => installation.id,
          "source" => WorkspaceSource.encode(source),
          "subdirectory" => installation.subdirectory
        }

        mutation!(:update, arguments, request, thread, actor, fn ->
          ready!(thread)
          active!(installation)
          idle!(installation.id)
          installation
        end)
      end)
    end
  end

  @spec set_enabled(map(), options()) :: result()
  def set_enabled(%{enabled: enabled} = arguments, options) when is_boolean(enabled) do
    configure(if(enabled, do: :enable, else: :disable), arguments, options)
  end

  def set_enabled(_, _), do: {:error, :invalid_request}

  @spec remove(map(), options()) :: result()
  def remove(arguments, options), do: configure(:remove, arguments, options)

  # @cc [owner:ghuntley,label:security;recovery] managed-skill-admission-authority
  # Every manager mutation MUST recheck current thread manage authority under its
  # thread lock before receipt replay or writes. Matching idempotency keys MUST
  # return the existing receipt without restoring removed or disabled settings.
  @spec mutate(atom(), map(), map(), options(), (Thread.t(), User.t() -> SkillInstallation.t())) ::
          result()
  defp mutate(kind, arguments, request, options, create) do
    authorized(Map.get(arguments, :thread_id), options, "manage", fn thread, actor ->
      mutation!(kind, arguments, request, thread, actor, fn -> create.(thread, actor) end)
    end)
  end

  @spec mutation!(atom(), map(), map(), Thread.t(), User.t(), (-> SkillInstallation.t())) ::
          SkillOperation.t()
  defp mutation!(kind, arguments, request, thread, actor, create) do
    key = Map.get(arguments, :idempotency_key)
    unless is_binary(key) and byte_size(key) in 1..128, do: Ledger.rollback(:invalid_request)
    digest = fingerprint(%{kind: kind, request: request})

    case Ledger.read!(SkillOperation,
           thread_id: thread.id,
           requested_by_id: actor.id,
           request_key: key
         ) do
      [operation] ->
        if operation.request_digest == digest,
          do: operation,
          else: Ledger.rollback(:idempotency_conflict)

      [] ->
        installation = create.()

        operation =
          Ledger.create!(SkillOperation, :record, %{
            thread_id: thread.id,
            installation_id: installation.id,
            requested_by_id: actor.id,
            request_key: key,
            request_digest: digest,
            kind: kind,
            request: request,
            machine_id: thread.machine_id,
            machine_key: thread.machine_key,
            base_revision_id: installation.active_revision_id
          })

        if kind in [:enable, :disable, :remove] do
          Ledger.update!(installation, :configure, %{
            enabled: kind == :enable,
            status: if(kind == :remove, do: :removed, else: installation.status)
          })

          Ledger.update!(operation, :finish, %{status: :completed})
        else
          operation
        end
    end
  end

  @spec configure(atom(), map(), options()) :: result()
  defp configure(kind, arguments, options) do
    with :ok <- identifiers(arguments, :installation_id) do
      request = %{"installation_id" => arguments.installation_id}

      mutate(kind, arguments, request, options, fn thread, _actor ->
        installation = installation!(thread.id, arguments.installation_id)
        if kind == :enable, do: active!(installation)
        installation
      end)
    end
  end

  @doc "Bounded internal coordinator scan; returned requests confer no authority."
  @spec pending() :: [SkillOperation.t()]
  def pending do
    SkillOperation
    |> Ash.Query.filter(status == :queued)
    |> Ash.Query.sort([:inserted_at, :id])
    |> Ash.Query.limit(50)
    |> Ash.read!(actor: SystemActor.compute())
  end

  # @cc [owner:ghuntley,label:security;concurrency] managed-skill-dispatch-fenced
  # Dispatch MUST lock thread before VM, recheck the requesting manager and the
  # captured machine generation, and persist its command ID in the same
  # transaction as command creation. A previously dispatched request MUST NOT
  # invoke the enqueue callback again.
  @spec dispatch(String.t(), (Thread.t(), SkillOperation.t(), map() -> String.t())) :: result()
  def dispatch(operation_id, enqueue) when is_function(enqueue, 3) do
    operation_transaction(operation_id, fn thread, operation, installation ->
      if operation.status == :queued do
        case current_error(thread, operation, installation) do
          nil ->
            command_id = enqueue.(thread, operation, install_request(operation, installation))
            unless OverallsProtocol.uuid?(command_id), do: Ledger.rollback(:invalid_command)
            Ledger.update!(operation, :dispatch, %{status: :dispatched, command_id: command_id})

          reason ->
            fail!(operation, installation, reason)
        end
      else
        operation
      end
    end)
  end

  @doc "Runs one read-only status command admission under current installation authority."
  @spec reconcile(String.t(), (Thread.t(), SkillOperation.t(), map() -> value)) ::
          {:ok, value | SkillOperation.t()} | {:error, term()}
        when value: term()
  def reconcile(operation_id, enqueue) when is_function(enqueue, 3) do
    operation_transaction(operation_id, fn thread, operation, installation ->
      cond do
        operation.status in @terminal ->
          operation

        operation.status not in [:dispatched, :uncertain] ->
          Ledger.rollback(:operation_not_dispatched)

        reason = current_error(thread, operation, installation) ->
          fail!(operation, installation, reason)

        true ->
          enqueue.(thread, operation, status_request(operation))
      end
    end)
  end

  @doc "Read-only status request; never redispatches the installation side effect."
  @spec status_request(SkillOperation.t()) :: map()
  def status_request(operation) do
    %{
      "version" => 1,
      "operation_id" => operation.id,
      "thread_id" => operation.thread_id,
      "installation_id" => operation.installation_id
    }
  end

  @doc "Fresh read-only executor check, safe while the caller already holds the VM lock."
  @spec command_allowed?(String.t(), String.t(), String.t()) :: boolean()
  def command_allowed?(operation_id, actor_id, vm_id) do
    with [%SkillOperation{requested_by_id: ^actor_id, machine_id: ^vm_id} = operation] <-
           Ledger.read!(SkillOperation, id: operation_id),
         true <- operation.status in [:dispatched, :uncertain],
         [thread] <- Ledger.read!(Thread, id: operation.thread_id),
         [installation] <- Ledger.read!(SkillInstallation, id: operation.installation_id) do
      is_nil(current_error(thread, operation, installation))
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] managed-skill-publish-current-authority
  # A verified installation result MUST publish only while its manager, current
  # machine binding and base revision still match admission. Invalid, failed,
  # stale or ambiguous results MUST preserve the previous published revision.
  # Terminal receipts MUST not be overwritten, and removed skills MUST not be
  # resurrected by late completion.
  @spec complete(String.t(), map()) :: result()
  def complete(operation_id, result) do
    previous = List.first(Ledger.read!(SkillOperation, id: operation_id))

    outcome =
      operation_transaction(operation_id, fn thread, operation, installation ->
        cond do
          operation.status in @terminal ->
            operation

          operation.status == :queued ->
            Ledger.rollback(:operation_not_dispatched)

          reason = current_error(thread, operation, installation) ->
            fail!(operation, installation, reason)

          true ->
            accept_result(thread, operation, installation, result)
        end
      end)

    case outcome do
      {:ok, %SkillOperation{} = operation} ->
        if (previous && previous.status not in @terminal) and operation.status in @terminal do
          Marshall.Events.emit("agent.skill_operation_finished",
            operation_id: operation.id,
            installation_id: operation.installation_id,
            outcome: operation.status
          )
        end

        :ok

      _ ->
        :ok
    end

    outcome
  end

  @spec fail(String.t(), term()) :: result()
  def fail(operation_id, reason) do
    previous = List.first(Ledger.read!(SkillOperation, id: operation_id))

    result =
      operation_transaction(operation_id, fn _thread, operation, installation ->
        if operation.status in @terminal,
          do: operation,
          else: fail!(operation, installation, Failures.normalize(reason))
      end)

    case result do
      {:ok, %SkillOperation{} = operation} ->
        if (previous && previous.status not in @terminal) and operation.status in @terminal do
          Marshall.Events.emit("agent.skill_operation_finished",
            operation_id: operation.id,
            installation_id: operation.installation_id,
            outcome: operation.status
          )
        end

        :ok

      _ ->
        :ok
    end

    result
  end

  @doc "Only enabled revisions verified for the currently bound machine enter context."
  @spec managed_paths(String.t()) :: [String.t()]
  def managed_paths(agent_thread_id) do
    case Ledger.read!(Marshall.Agents.Thread, id: agent_thread_id) do
      [%{root_id: root_id}] ->
        case Ledger.read!(Thread, agent_root_id: root_id) do
          [thread] ->
            for installation <- installations(thread.id),
                installation.enabled and installation.status == :ready,
                revision = active_revision(installation),
                revision && revision.machine_id == thread.machine_id &&
                  revision.machine_key == thread.machine_key,
                do: revision.path

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @doc "Whether a current enabled manifest needs verification on this replacement machine."
  @spec restoration_required?(String.t()) :: boolean()
  def restoration_required?(agent_thread_id) do
    with [%{root_id: root_id}] <- Ledger.read!(Marshall.Agents.Thread, id: agent_thread_id),
         [thread] <- Ledger.read!(Thread, agent_root_id: root_id) do
      Enum.any?(installations(thread.id), fn installation ->
        revision = active_revision(installation)

        installation.enabled and installation.status == :ready and revision != nil and
          (revision.machine_id != thread.machine_id or revision.machine_key != thread.machine_key)
      end)
    else
      _ -> false
    end
  end

  @doc "Bounded current-generation scan for enabled pinned manifests needing restoration."
  # @cc [owner:ghuntley,label:concurrency;recovery] skill-restoration-round-robin
  # Restoration scans MUST advance past the caller's cursor and wrap when the
  # end is reached. A blocked thread therefore cannot monopolize the first
  # batch forever. Current-generation active receipts already own the next
  # attempt, while terminal failed receipts are not replayed automatically.
  @spec restoration_threads(String.t() | nil) :: [String.t()]
  def restoration_threads(cursor \\ nil) do
    rows = restoration_query(cursor)

    if rows == [] and not is_nil(cursor), do: restoration_query(nil), else: rows
  end

  @spec restoration_query(String.t() | nil) :: [String.t()]
  defp restoration_query(cursor) do
    cursor = if is_nil(cursor), do: nil, else: Ecto.UUID.dump!(cursor)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT DISTINCT t.id FROM threads t
        JOIN agent_skill_installations i ON i.thread_id = t.id
        JOIN agent_skill_revisions r ON r.id = i.active_revision_id
        WHERE t.status = 'ready' AND t.archived_at IS NULL
          AND i.enabled AND i.status = 'ready'
          AND (r.machine_id != t.machine_id OR r.machine_key != t.machine_key)
          AND ($1::uuid IS NULL OR t.id > $1::uuid)
          AND NOT EXISTS (
            SELECT 1 FROM agent_skill_operations o
            WHERE o.thread_id = t.id
              AND o.installation_id = i.id
              AND o.kind = 'restore'
              AND o.machine_key = t.machine_key
              AND o.status IN ('queued', 'dispatched', 'uncertain', 'failed')
          )
        ORDER BY t.id LIMIT 25
        """,
        [cursor],
        log: false
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  @doc "Schedules enabled revisions on a replacement machine at their recorded commit and digest."
  @spec restore(String.t()) :: {:ok, [SkillOperation.t()]} | {:error, term()}
  def restore(thread_id) do
    Ledger.transaction(fn ->
      thread = lock_thread!(thread_id)
      ready!(thread)
      actor = Security.current(thread.creator_id)
      Authorization.require!(thread, actor, "manage")

      for installation <- installations(thread.id),
          installation.status == :ready and installation.enabled,
          revision = active_revision(installation),
          revision &&
            (revision.machine_id != thread.machine_id ||
               revision.machine_key != thread.machine_key) do
        {:ok, source} = WorkspaceSource.decode(revision.source)
        source = %{source | revision: %{kind: :commit, value: revision.commit}}

        request = %{
          "installation_id" => installation.id,
          "source" => WorkspaceSource.encode(source),
          "subdirectory" => installation.subdirectory,
          "expected_digest" => revision.digest
        }

        mutation!(
          :restore,
          %{idempotency_key: "restore:" <> fingerprint({installation.id, thread.machine_key})},
          request,
          thread,
          actor,
          fn -> installation end
        )
      end
    end)
  end

  @spec install_request(SkillOperation.t(), SkillInstallation.t()) :: map()
  defp install_request(operation, installation) do
    request = Map.merge(operation.request, status_request(operation))

    request =
      Map.delete(request, "installation_id") |> Map.put("installation_id", installation.id)

    case active_revision(installation) do
      %SkillRevision{} = revision
      when operation.kind == :update and revision.machine_id == operation.machine_id and
             revision.machine_key == operation.machine_key ->
        Map.merge(request, %{
          "previous_path" => revision.path,
          "previous_digest" => revision.digest
        })

      _ ->
        request
    end
  end

  @spec accept_result(Thread.t(), SkillOperation.t(), SkillInstallation.t(), term()) ::
          SkillOperation.t()
  defp accept_result(
         thread,
         operation,
         installation,
         %{"version" => 1, "status" => "installed", "operation_id" => id} = result
       )
       when id == operation.id do
    case verify_result(result, operation) do
      {:ok, metadata} ->
        revision =
          Ledger.create!(
            SkillRevision,
            :record,
            Map.merge(metadata, %{
              installation_id: installation.id,
              operation_id: operation.id,
              machine_id: thread.machine_id,
              machine_key: thread.machine_key,
              source: operation.request["source"]
            })
          )

        Ledger.update!(installation, :publish, %{
          active_revision_id: revision.id,
          status: :ready,
          failure_reason: nil
        })

        Ledger.update!(operation, :finish, %{status: :completed, revision_id: revision.id})

      {:error, reason} ->
        fail!(operation, installation, reason)
    end
  end

  defp accept_result(_thread, operation, installation, %{
         "version" => 1,
         "status" => "failed",
         "operation_id" => id,
         "code" => code
       })
       when id == operation.id,
       do: fail!(operation, installation, Failures.normalize(code))

  defp accept_result(_thread, operation, _installation, %{
         "version" => 1,
         "status" => status,
         "operation_id" => id
       })
       when id == operation.id and status in ["missing", "running"], do: operation

  defp accept_result(_thread, operation, installation, %{
         "version" => 1,
         "status" => "uncertain",
         "operation_id" => id
       })
       when id == operation.id, do: fail!(operation, installation, :uncertain)

  defp accept_result(_thread, operation, installation, _),
    do: fail!(operation, installation, :invalid_result)

  @spec verify_result(map(), SkillOperation.t()) :: {:ok, map()} | {:error, atom()}
  defp verify_result(result, operation) do
    with %{
           "full_commit" => commit,
           "content_digest" => digest,
           "path" => path,
           "skill_file" => %{
             "path" => skill_path,
             "digest" => skill_digest,
             "bytes" => bytes,
             "header" => header
           }
         } <- result,
         true <- is_binary(commit) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit),
         true <- sha256?(digest),
         true <- is_binary(path) and byte_size(path) in 1..4096,
         true <- is_binary(skill_path) and String.starts_with?(skill_path, path <> "/"),
         true <- is_integer(bytes) and bytes in 1..1_048_576,
         true <- is_binary(header) and byte_size(header) <= 32_768,
         {:ok, entry} <-
           Catalog.parse(
             %{path: skill_path, digest: skill_digest, bytes: bytes, scope: :managed},
             header
           ),
         expected = operation.request["expected_digest"],
         true <- is_nil(expected) or expected == digest do
      {:ok,
       %{
         commit: commit,
         digest: digest,
         path: path,
         skill_path: skill_path,
         skill_digest: skill_digest,
         skill_bytes: bytes,
         name: entry.name,
         description: entry.description
       }}
    else
      _ -> {:error, :invalid_result}
    end
  end

  @spec current_error(Thread.t(), SkillOperation.t(), SkillInstallation.t()) :: atom() | nil
  defp current_error(thread, operation, installation) do
    actor = Security.current(operation.requested_by_id)

    cond do
      not Authorization.allowed?(thread, actor, "manage") ->
        :access_revoked

      thread.status != :ready or thread.machine_id != operation.machine_id or
          thread.machine_key != operation.machine_key ->
        :machine_changed

      installation.status == :removed or
          installation.active_revision_id != operation.base_revision_id ->
        :stale_operation

      true ->
        nil
    end
  end

  @spec fail!(SkillOperation.t(), SkillInstallation.t(), atom()) :: SkillOperation.t()
  defp fail!(operation, installation, reason) do
    Ledger.update!(installation, :fail, %{failure_reason: reason})

    Ledger.update!(operation, :finish, %{
      status: if(reason == :uncertain, do: :uncertain, else: :failed),
      failure_reason: reason
    })
  end

  @spec operation_transaction(String.t(), (Thread.t(),
                                           SkillOperation.t(),
                                           SkillInstallation.t() ->
                                             result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  defp operation_transaction(id, callback) do
    Ledger.transaction(fn ->
      case Ledger.read!(SkillOperation, id: id) do
        [found] ->
          thread = lock_thread!(found.thread_id)
          lock_machine!(thread)
          operation = Ledger.lock!(SkillOperation, id) || Ledger.rollback(:not_found)
          installation = installation!(thread.id, operation.installation_id)
          callback.(thread, operation, installation)

        [] ->
          Ledger.rollback(:not_found)
      end
    end)
  end

  @spec authorized(term(), options(), String.t(), (Thread.t(), User.t() -> value)) ::
          {:ok, value} | {:error, term()}
        when value: term()
  defp authorized(id, options, action, callback) do
    case Keyword.get(options, :actor) do
      %User{} = actor ->
        if OverallsProtocol.uuid?(id) do
          Ledger.transaction(
            fn ->
              thread = lock_thread!(id)
              Authorization.require!(thread, actor, action)
              callback.(thread, actor)
            end,
            actor
          )
        else
          {:error, :invalid_request}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  @spec lock_thread!(String.t()) :: Thread.t()
  defp lock_thread!(id) do
    Thread
    |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!() || Ledger.rollback(:not_found)
  end

  @spec lock_machine!(Thread.t()) :: VirtualMachine.t() | nil
  defp lock_machine!(%Thread{machine_id: nil}), do: nil

  defp lock_machine!(thread) do
    VirtualMachine
    |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^thread.machine_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  @spec installation!(String.t(), String.t()) :: SkillInstallation.t()
  defp installation!(thread_id, id) do
    case Ledger.lock!(SkillInstallation, id) do
      %SkillInstallation{thread_id: ^thread_id} = installation -> installation
      _ -> Ledger.rollback(:not_found)
    end
  end

  @spec installations(String.t()) :: [SkillInstallation.t()]
  defp installations(thread_id) do
    SkillInstallation
    |> Ash.Query.filter(thread_id == ^thread_id and status != :removed)
    |> Ash.Query.sort(:id)
    |> Ash.Query.limit(@max_installations + 1)
    |> Ash.read!(actor: SystemActor.compute())
  end

  @spec active_revision(SkillInstallation.t()) :: SkillRevision.t() | nil
  defp active_revision(%SkillInstallation{active_revision_id: nil}), do: nil

  defp active_revision(installation),
    do: List.first(Ledger.read!(SkillRevision, id: installation.active_revision_id))

  @spec projection(SkillInstallation.t()) :: map()
  defp projection(installation) do
    revision = active_revision(installation)
    {:ok, source} = WorkspaceSource.decode(installation.source)

    %{
      id: installation.id,
      name: if(revision, do: revision.name, else: WorkspaceSource.display_name(source)),
      description: if(revision, do: revision.description, else: "Waiting for installation"),
      enabled: installation.enabled,
      status: installation.status,
      failure_reason: installation.failure_reason,
      revision_id: installation.active_revision_id,
      commit: if(revision, do: revision.commit),
      digest: if(revision, do: revision.digest),
      source_url: WorkspaceSource.to_url(source),
      subdirectory: installation.subdirectory
    }
  end

  @spec ready!(Thread.t()) :: :ok
  defp ready!(thread) do
    unless thread.status == :ready and is_binary(thread.machine_id),
      do: Ledger.rollback(:machine_unavailable)

    :ok
  end

  @spec active!(SkillInstallation.t()) :: :ok
  defp active!(installation) do
    if installation.status == :removed, do: Ledger.rollback(:skill_removed)
    :ok
  end

  @spec idle!(String.t()) :: :ok
  defp idle!(id) do
    pending =
      SkillOperation
      |> Ash.Query.filter(installation_id == ^id and status in [:queued, :dispatched, :uncertain])
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute())

    if pending != [], do: Ledger.rollback(:skill_busy)
    :ok
  end

  @spec identifiers(term(), atom()) :: :ok | {:error, :invalid_request}
  defp identifiers(arguments, key) when is_map(arguments) do
    if OverallsProtocol.uuid?(Map.get(arguments, key)), do: :ok, else: {:error, :invalid_request}
  end

  defp identifiers(_, _), do: {:error, :invalid_request}

  @spec source(map()) :: {:ok, WorkspaceSource.t()} | {:error, atom()}
  defp source(arguments) when is_map(arguments) do
    with {:ok, source} <- WorkspaceSource.parse_url(Map.get(arguments, :url)),
         do: revision(source, Map.get(arguments, :revision))
  end

  defp source(_), do: {:error, :invalid_request}

  @spec revision(WorkspaceSource.t(), term()) :: {:ok, WorkspaceSource.t()} | {:error, atom()}
  defp revision(source, value) when value in [nil, ""], do: {:ok, source}

  defp revision(source, value) when is_binary(value) do
    revision =
      if Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, value),
        do: %{kind: :commit, value: String.downcase(value)},
        else: %{kind: :ref, value: value}

    source = %{source | revision: revision}
    if WorkspaceSource.valid?(source), do: {:ok, source}, else: {:error, :invalid_reference}
  end

  defp revision(_, _), do: {:error, :invalid_reference}

  @spec subdirectory(term()) :: {:ok, String.t()} | {:error, :invalid_subdirectory}
  defp subdirectory(value) when value in [nil, "", "."], do: {:ok, "."}

  defp subdirectory(value) when is_binary(value) and byte_size(value) <= 1024 do
    if Enum.all?(String.split(value, "/"), fn part ->
         part not in ["", ".", ".."] and Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9._ -]*\z/, part)
       end), do: {:ok, value}, else: {:error, :invalid_subdirectory}
  end

  defp subdirectory(_), do: {:error, :invalid_subdirectory}

  @spec sha256?(term()) :: boolean()
  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  @spec fingerprint(term()) :: String.t()
  defp fingerprint(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
