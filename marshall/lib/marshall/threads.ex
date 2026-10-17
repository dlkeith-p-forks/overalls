defmodule Marshall.Threads do
  @moduledoc "User-facing conversations that own an automatically provisioned machine."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]
  require Ash.Query

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Threads.Thread do
      define :create_thread, action: :create_thread
      define :list_threads, action: :list_for_user
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
  end

  @type user :: Marshall.Accounts.User.t()

  @doc "Reads the retained transcript for an authorized user thread."
  # @cc [owner:ghuntley,label:security;durability] retained-transcript-binding
  # Transcript reads MUST resolve the retained high-level thread through the
  # paired agent root/thread binding; a stale or cross-bound agent ID MUST fail.
  @spec events(String.t(), user(), pos_integer()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  def events(thread_id, actor, limit \\ 100)

  def events(thread_id, %Marshall.Accounts.User{} = actor, limit)
      when is_binary(thread_id) and is_integer(limit) and limit in 1..200 do
    with {:ok, thread} <- get_thread(%{thread_id: thread_id}, actor: actor),
         agent_thread_id when is_binary(agent_thread_id) <- thread.agent_thread_id,
         [%Marshall.Agents.Thread{root_id: root_id}] <-
           Marshall.Compute.Ledger.read!(Marshall.Agents.Thread, id: agent_thread_id),
         true <- root_id == thread.agent_root_id do
      events =
        Marshall.Agents.Event
        |> Ash.Query.filter(thread_id == ^agent_thread_id and kind != :model_output)
        |> Ash.Query.sort(sequence: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

      {:ok, Enum.reverse(events)}
    else
      nil -> {:error, :machine_unavailable}
      {:error, reason} -> {:error, error_reason(reason)}
      _ -> {:error, :machine_unavailable}
    end
  end

  def events(_, _, _), do: {:error, :forbidden}

  @doc "Returns a bounded reason suitable for thread UI and API error handling."
  @spec error_reason(term()) :: atom()
  def error_reason(%Marshall.Compute.Error{reason: reason}) when is_atom(reason), do: reason
  def error_reason(%Ash.Error.Unknown{errors: [reason]}), do: error_reason(reason)
  def error_reason(%Ash.Error.Invalid{errors: [reason]}), do: error_reason(reason)
  def error_reason(%Ash.Error.Forbidden{}), do: :forbidden
  def error_reason(reason) when is_atom(reason), do: reason
  def error_reason(_), do: :unavailable
end
