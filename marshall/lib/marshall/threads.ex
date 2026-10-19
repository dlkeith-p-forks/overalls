defmodule Marshall.Threads do
  @moduledoc "User-facing conversations that own an automatically provisioned machine."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]
  require Ash.Query

  alias Marshall.Threads.Thread

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Threads.Thread do
      define :create_thread, action: :create_thread
      define :list_threads, action: :list_for_user
      define :list_thread_page, action: :list_page_for_user
      define :get_thread, action: :get_for_user
      define :submit_prompt, action: :submit_prompt
      define :retry_provisioning, action: :retry_provisioning
      define :archive_thread, action: :archive_thread
      define :delete_thread, action: :delete_thread
      define :reopen_thread, action: :reopen_thread
      define :thread_controls, action: :thread_controls
      define :set_collaboration_mode, action: :set_collaboration_mode
      define :answer_questions, action: :answer_questions
      define :implement_plan, action: :implement_plan
      define :compact_context, action: :compact_context
      define :reload_context, action: :reload_context
      define :context_info, action: :context_info
      define :list_skills, action: :list_skills
      define :install_skill, action: :install_skill
      define :update_skill, action: :update_skill
      define :set_skill_enabled, action: :set_skill_enabled
      define :remove_skill, action: :remove_skill
    end

    resource Marshall.Threads.Grant do
      define :set_access, action: :set_access
      define :list_grants, action: :list_grants
    end

    resource Marshall.Threads.AccessChange

    resource Marshall.Threads.Generation

    resource Marshall.Threads.ReadMarker do
      define :mark_read, action: :mark_read
    end
  end

  @type user :: Marshall.Accounts.User.t()

  @doc "Lists retained machine generations for an authorized user thread."
  # @cc [owner:ghuntley,label:security;durability] retained-generation-list
  # Generation listings MUST recheck current thread read authority. They MAY
  # expose retired binding metadata needed for selection, but MUST NOT grant
  # prompt, terminal or machine authority for a retired generation.
  @spec generations(String.t(), user()) ::
          {:ok, [Marshall.Threads.Generation.t()]} | {:error, term()}
  def generations(thread_id, %Marshall.Accounts.User{} = actor) when is_binary(thread_id) do
    with {:ok, thread} <- get_thread(%{thread_id: thread_id}, actor: actor) do
      generations = read_generations(thread.id)
      {:ok, fallback_generation(thread, generations)}
    else
      {:error, reason} -> {:error, error_reason(reason)}
      _ -> {:error, :forbidden}
    end
  end

  def generations(_, _), do: {:error, :forbidden}

  @doc "Reads the retained transcript for an authorized user thread."
  # @cc [owner:ghuntley,label:security;durability] retained-transcript-binding
  # Transcript reads MUST resolve the retained high-level thread through the
  # paired agent root/thread binding; a stale or cross-bound agent ID MUST fail.
  @spec events(String.t(), user(), pos_integer()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  def events(thread_id, actor, limit \\ 100)

  def events(thread_id, %Marshall.Accounts.User{} = actor, limit)
      when is_binary(thread_id) and is_integer(limit) and limit in 1..200 do
    transcript_events(thread_id, actor, nil, limit)
  end

  def events(_, _, _), do: {:error, :forbidden}

  @doc "Reads a retained transcript for an explicit machine generation ordinal."
  # @cc [owner:ghuntley,label:security;durability] retained-generation-events
  # A selected generation MUST belong to the authorized high-level thread and
  # its retained agent thread MUST still match the generation's root and VM
  # owner. Retired generations are read-only and never authorize mutations.
  @spec events(String.t(), user(), pos_integer(), pos_integer()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  def events(thread_id, %Marshall.Accounts.User{} = actor, generation, limit)
      when is_binary(thread_id) and is_integer(generation) and generation >= 1 and
             is_integer(limit) and limit in 1..200 do
    transcript_events(thread_id, actor, generation, limit)
  end

  def events(_, _, _, _), do: {:error, :forbidden}

  @spec transcript_events(String.t(), user(), pos_integer() | nil, pos_integer()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  defp transcript_events(thread_id, actor, ordinal, limit) do
    with {:ok, thread} <- get_thread(%{thread_id: thread_id}, actor: actor),
         {:ok, generation} <- generation_for(thread, ordinal),
         {:ok, agent_thread_id} <- valid_binding(thread, generation) do
      events =
        Marshall.Agents.Event
        |> Ash.Query.filter(thread_id == ^agent_thread_id and kind != :model_output)
        |> Ash.Query.sort(sequence: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

      {:ok, Enum.reverse(events)}
    else
      {:error, reason} -> {:error, error_reason(reason)}
      _ -> {:error, :machine_unavailable}
    end
  end

  @doc "Reads retained transcript events after a sequence, oldest first."
  # @cc [owner:ghuntley,label:security;durability] retained-transcript-after
  # Incremental transcript reads MUST apply the same current read authority and
  # paired agent binding as `events/4`, return events strictly after the given
  # sequence in ascending order, and exclude streamed model output.
  @spec events_after(String.t(), user(), pos_integer() | nil, non_neg_integer(), pos_integer()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  def events_after(
        thread_id,
        %Marshall.Accounts.User{} = actor,
        generation,
        after_sequence,
        limit
      )
      when is_binary(thread_id) and
             (is_nil(generation) or (is_integer(generation) and generation >= 1)) and
             is_integer(after_sequence) and after_sequence >= 0 and is_integer(limit) and
             limit in 1..200 do
    with {:ok, thread} <- get_thread(%{thread_id: thread_id}, actor: actor),
         {:ok, generation} <- generation_for(thread, generation),
         {:ok, agent_thread_id} <- valid_binding(thread, generation) do
      {:ok,
       Marshall.Agents.Event
       |> Ash.Query.filter(
         thread_id == ^agent_thread_id and kind != :model_output and sequence > ^after_sequence
       )
       |> Ash.Query.sort(sequence: :asc)
       |> Ash.Query.limit(limit)
       |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())}
    else
      {:error, reason} -> {:error, error_reason(reason)}
      _ -> {:error, :machine_unavailable}
    end
  end

  def events_after(_, _, _, _, _), do: {:error, :forbidden}

  @spec generation_for(Thread.t(), pos_integer() | nil) ::
          {:ok, Marshall.Threads.Generation.t()} | {:error, atom()}
  defp generation_for(thread, nil) do
    generations = fallback_generation(thread, read_generations(thread.id))

    case Enum.find(generations, &(&1.machine_key == thread.machine_key)) do
      %Marshall.Threads.Generation{} = generation ->
        if current_binding?(thread, generation) do
          {:ok, hydrate_current_generation(thread, generation)}
        else
          {:error, :machine_unavailable}
        end

      nil ->
        {:error, :machine_unavailable}
    end
  end

  defp generation_for(thread, ordinal) do
    case Marshall.Threads.Generation
         |> Ash.Query.filter(thread_id == ^thread.id and ordinal == ^ordinal)
         |> Ash.read_one(actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, %Marshall.Threads.Generation{} = generation} ->
        if generation.machine_key == thread.machine_key do
          if current_binding?(thread, generation) do
            {:ok, hydrate_current_generation(thread, generation)}
          else
            {:error, :machine_unavailable}
          end
        else
          {:ok, generation}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @spec current_binding?(Thread.t(), Marshall.Threads.Generation.t()) :: boolean()
  defp current_binding?(thread, generation) do
    if is_nil(generation.machine_id) and is_nil(generation.agent_root_id) and
         is_nil(generation.agent_thread_id) and is_nil(thread.machine_id) and
         is_nil(thread.agent_root_id) and is_nil(thread.agent_thread_id) do
      true
    else
      generation.machine_id == thread.machine_id and
        generation.agent_root_id == thread.agent_root_id and
        generation.agent_thread_id == thread.agent_thread_id
    end
  end

  @spec valid_binding(Thread.t(), Marshall.Threads.Generation.t()) ::
          {:ok, String.t()} | {:error, atom()}
  defp valid_binding(thread, generation) do
    with agent_thread_id when is_binary(agent_thread_id) <- generation.agent_thread_id,
         root_id when is_binary(root_id) <- generation.agent_root_id,
         machine_id when is_binary(machine_id) <- generation.machine_id,
         [%Marshall.Compute.VirtualMachine{idempotency_key: machine_key, owner_id: owner_id}] <-
           Marshall.Compute.Ledger.history!(Marshall.Compute.VirtualMachine, id: machine_id),
         true <- machine_key == generation.machine_key,
         true <- owner_id == thread.creator_id,
         [%Marshall.Agents.Thread{root_id: ^root_id}] <-
           Marshall.Compute.Ledger.read!(Marshall.Agents.Thread, id: agent_thread_id),
         [%Marshall.Agents.Root{vm_id: ^machine_id, owner_id: ^owner_id}] <-
           Marshall.Compute.Ledger.read!(Marshall.Agents.Root, id: root_id),
         true <- owner_id == thread.creator_id do
      {:ok, agent_thread_id}
    else
      _ -> {:error, :machine_unavailable}
    end
  end

  @spec read_generations(String.t()) :: [Marshall.Threads.Generation.t()]
  defp read_generations(thread_id) do
    Marshall.Threads.Generation
    |> Ash.Query.filter(thread_id == ^thread_id)
    |> Ash.Query.sort(ordinal: :desc)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
  end

  @spec fallback_generation(Thread.t(), [Marshall.Threads.Generation.t()]) ::
          [Marshall.Threads.Generation.t()]
  defp fallback_generation(%Marshall.Threads.Thread{} = thread, []),
    do: [struct(Marshall.Threads.Generation, fallback_generation_attributes(thread))]

  defp fallback_generation(_thread, generations), do: generations

  @spec hydrate_current_generation(Thread.t(), Marshall.Threads.Generation.t()) ::
          Marshall.Threads.Generation.t()
  defp hydrate_current_generation(thread, %Marshall.Threads.Generation{} = generation) do
    %Marshall.Threads.Generation{
      generation
      | machine_id: thread.machine_id,
        agent_root_id: thread.agent_root_id,
        agent_thread_id: thread.agent_thread_id,
        status: thread.status,
        failure_reason: thread.failure_reason,
        archived_at: thread.archived_at
    }
  end

  @spec fallback_generation_attributes(Marshall.Threads.Thread.t()) :: map()
  defp fallback_generation_attributes(thread) do
    %{
      id: "00000000-0000-0000-0000-000000000001",
      thread_id: thread.id,
      ordinal: 1,
      machine_key: thread.machine_key,
      machine_id: thread.machine_id,
      agent_root_id: thread.agent_root_id,
      agent_thread_id: thread.agent_thread_id,
      status: thread.status,
      failure_reason: thread.failure_reason,
      archived_at: thread.archived_at,
      inserted_at: thread.inserted_at,
      updated_at: thread.updated_at
    }
  end

  @doc "Returns a bounded reason suitable for thread UI and API error handling."
  @spec error_reason(term()) :: atom()
  def error_reason(%Marshall.Compute.Error{reason: reason}) when is_atom(reason), do: reason
  def error_reason(%Ash.Error.Unknown{errors: [reason]}), do: error_reason(reason)
  def error_reason(%Ash.Error.Invalid{errors: [reason]}), do: error_reason(reason)
  def error_reason(%Ash.Error.Forbidden{}), do: :forbidden
  def error_reason(reason) when is_atom(reason), do: reason
  def error_reason(_), do: :unavailable
end
