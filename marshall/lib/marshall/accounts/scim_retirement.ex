defmodule Marshall.Accounts.ScimRetirement do
  @moduledoc """
  The SCIM user retirement lifecycle (ADR-0229).

  Deactivation (`active=false` or SCIM `DELETE`) revokes every stored login,
  records a `:scim_retirement` `UserDeletion` in `:scheduled` and suspends the
  user's running machines. Reactivation inside the grace period cancels that
  deletion and resumes only the machines SCIM suspended. Once the deadline
  passes the deletion physically reclaims every owned machine and then
  finalizes the identity: the UUID and history remain, the email becomes
  `deleted-<uuid>@deleted.invalid`, credentials are revoked and the identity
  can never become active again.

  PostgreSQL holds every decision; `Marshall.Scim.RetirementWorker` retries
  each step through Oban.
  """
  alias Marshall.Accounts.{AccountLifecycle, ScimMachineSuspension, User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Lifecycle, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @default_grace_seconds 7 * 24 * 60 * 60
  @service_owner_external_id "scim-service-owner"

  @typedoc "What one reconciliation pass did for a user."
  @type outcome :: :finalized | :resumed | :suspended | :pending | :absent

  @typep plan ::
           :absent
           | :finalized
           | {:resume, User.t(), [ScimMachineSuspension.t()]}
           | {:suspend, User.t()}
           | {:retire, UserDeletion.t()}

  # @cc [owner:ghuntley,label:product;recovery] scim-retirement-single-grace
  # Every SCIM user retirement deadline MUST derive from grace_seconds/0, a
  # positive integer configured once (default seven days). Callers MUST NOT
  # embed their own grace duration.
  @doc "The configured SCIM retirement grace period in seconds (default seven days)."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds do
    case Keyword.get(Application.get_env(:marshall, __MODULE__, []), :grace_seconds) do
      nil ->
        @default_grace_seconds

      seconds when is_integer(seconds) and seconds > 0 ->
        seconds

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :grace_seconds must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc "The retirement deadline for a deactivation observed at `now`."
  @spec deadline_from(DateTime.t()) :: DateTime.t()
  def deadline_from(%DateTime{} = now), do: DateTime.add(now, grace_seconds(), :second)

  @doc "Whether this user is the internal SCIM service owner, which SCIM never manages."
  @spec service_owner?(User.t()) :: boolean()
  def service_owner?(%User{scim_external_id: id}), do: id == @service_owner_external_id

  @doc "Whether an inactive identity's grace period has ended at `now`."
  @spec due?(User.t(), DateTime.t()) :: boolean()
  def due?(%User{active: false, scim_retirement_deadline: %DateTime{} = deadline}, now),
    do: DateTime.compare(deadline, now) != :gt

  def due?(%User{}, _now), do: false

  @doc "Row-locks a user for a lifecycle decision; the caller holds the transaction."
  @spec lock_user!(Ash.UUID.t()) :: User.t() | nil
  def lock_user!(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  # @cc [owner:ghuntley,label:security;recovery] scim-deactivation-immediate-effect
  # In the transaction that commits active=false, every stored login MUST be
  # revoked, the scheduled :scim_retirement deletion MUST exist and suspension
  # work MUST be enqueued, both immediately and at the deadline.
  @doc "Commits the durable side effects of a SCIM deactivation; requires a transaction."
  @spec deactivated!(User.t()) :: :ok
  def deactivated!(%User{active: false, scim_retirement_deadline: %DateTime{} = deadline} = user) do
    AccountLifecycle.revoke_tokens!(user.id)

    case Ledger.read!(UserDeletion, user_id: user.id) do
      [] ->
        Ledger.create!(UserDeletion, :schedule_scim, %{
          user_id: user.id,
          requested_by_id: user.id,
          email: user.email
        })

      [%UserDeletion{state: :cancelled} = deletion] ->
        Ledger.update!(deletion, :reschedule, %{email: user.email})

      [%UserDeletion{}] ->
        :ok
    end

    enqueue!(user.id)
    enqueue!(user.id, deadline)
    :ok
  end

  # @cc [owner:ghuntley,label:product;recovery] scim-reactivation-cancels-deletion
  # Reactivation inside the grace period MUST transition the scheduled deletion
  # to :cancelled in the committing transaction and enqueue resumption of only
  # the machines recorded as SCIM suspensions.
  @doc "Commits the durable side effects of a SCIM reactivation; requires a transaction."
  @spec reactivated!(User.t()) :: :ok
  def reactivated!(%User{active: true} = user) do
    case Ledger.read!(UserDeletion, user_id: user.id) do
      [%UserDeletion{kind: :scim_retirement, state: :scheduled} = deletion] ->
        Ledger.update!(deletion, :cancel, %{})

      _ ->
        :ok
    end

    enqueue!(user.id)
    :ok
  end

  @doc "Enqueues one reconciliation for a user, optionally scheduled at `at`."
  @spec enqueue!(Ash.UUID.t(), DateTime.t() | nil) :: :ok
  def enqueue!(user_id, at \\ nil) do
    args = %{"user_id" => user_id}

    changeset =
      if at do
        Marshall.Scim.RetirementWorker.new(Map.put(args, "at", DateTime.to_iso8601(at)),
          scheduled_at: at,
          unique: [period: :infinity, states: [:available, :scheduled, :retryable]]
        )
      else
        Marshall.Scim.RetirementWorker.new(args,
          unique: [period: 60, states: [:available, :scheduled, :retryable]]
        )
      end

    Oban.insert!(changeset)
    :ok
  end

  @doc "Users that still need SCIM retirement work: inactive live users and open suspensions."
  @spec pending_user_ids() :: [Ash.UUID.t()]
  def pending_user_ids do
    inactive =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(active == false and is_nil(deleted_at))
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> Enum.map(& &1.id)

    suspended =
      ScimMachineSuspension
      |> Ash.Query.filter(state == :suspended)
      |> Ash.Query.select([:user_id])
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.user_id)

    Enum.uniq(inactive ++ suspended)
  end

  # @cc [owner:ghuntley,label:security;recovery] scim-reconcile-locked-decision
  # Each pass MUST decide from the row-locked user and database clock: a live
  # user resumes its SCIM suspensions, an inactive user inside grace suspends
  # running machines and is never deleted, an expired inactive user advances
  # its deletion, and a finalized identity is never changed again.
  @doc "One idempotent retirement pass for a user."
  @spec reconcile(Ash.UUID.t()) :: {:ok, outcome()} | {:error, term()}
  def reconcile(user_id) do
    case Ledger.transaction(fn -> plan_locked!(user_id) end, {:system, nil}) do
      {:ok, plan} -> execute(plan)
      {:error, _} = error -> error
    end
  end

  @spec plan_locked!(Ash.UUID.t()) :: plan()
  defp plan_locked!(user_id) do
    user = lock_user!(user_id)
    now = Ledger.now()

    cond do
      is_nil(user) ->
        :absent

      not is_nil(user.deleted_at) ->
        release_open!(user.id)
        :finalized

      user.active ->
        {:resume, user, Ledger.read!(ScimMachineSuspension, user_id: user.id, state: :suspended)}

      is_nil(user.scim_retirement_deadline) ->
        # An identity created or migrated as inactive without a deadline
        # starts its grace period now rather than staying fenced forever.
        user =
          Ledger.update!(user, :scim_retirement_state, %{
            scim_retirement_deadline: deadline_from(now)
          })

        deactivated!(user)
        {:suspend, user}

      due?(user, now) ->
        {:retire, ensure_deletion!(user)}

      true ->
        {:suspend, user}
    end
  end

  @spec ensure_deletion!(User.t()) :: UserDeletion.t()
  defp ensure_deletion!(user) do
    case Ledger.read!(UserDeletion, user_id: user.id) do
      [] ->
        Ledger.create!(UserDeletion, :schedule_scim, %{
          user_id: user.id,
          requested_by_id: user.id,
          email: user.email
        })

      [%UserDeletion{state: :cancelled} = deletion] ->
        Ledger.update!(deletion, :reschedule, %{email: user.email})

      [deletion] ->
        deletion
    end
  end

  @spec execute(plan()) :: {:ok, outcome()} | {:error, term()}
  defp execute(:absent), do: {:ok, :absent}
  defp execute(:finalized), do: {:ok, :finalized}

  defp execute({:resume, user, suspensions}) do
    results = Enum.map(suspensions, &Lifecycle.resume_for_scim/1)
    resumed = Enum.count(results, &match?({:ok, :resumed}, &1))

    if resumed > 0,
      do:
        Marshall.Events.emit("scim.user_machines_resumed",
          user_id: user.id,
          resumed_count: resumed
        )

    first_error(results, :resumed)
  end

  defp execute({:suspend, user}) do
    VirtualMachine
    |> Ash.Query.filter(owner_id == ^user.id and desired_state == :running)
    |> Ash.Query.sort(:id)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.map(fn vm ->
      case Lifecycle.pause_for_scim(user.id, vm.id, user.scim_retirement_deadline) do
        {:ok, _} = ok ->
          Marshall.Events.emit("scim.machine_suspended", user_id: user.id, vm_id: vm.id)
          ok

        {:error, error} = failed ->
          Marshall.Events.emit("scim.machine_suspension_failed",
            user_id: user.id,
            vm_id: vm.id,
            reason: reason(error)
          )

          failed
      end
    end)
    |> first_error(:suspended)
  end

  defp execute({:retire, deletion}) do
    UserDeletion
    |> Ash.ActionInput.for_action(:advance, %{primary_key: %{"id" => deletion.id}},
      actor: SystemActor.compute()
    )
    |> Ash.run_action()
    |> case do
      {:ok, %{complete: true}} -> {:ok, :finalized}
      {:ok, _} -> {:ok, :pending}
      {:error, _} = error -> error
    end
  end

  @spec first_error([{:ok, term()} | {:error, term()}], outcome()) ::
          {:ok, outcome()} | {:error, term()}
  defp first_error(results, outcome) do
    Enum.find(results, {:ok, outcome}, &match?({:error, _}, &1))
  end

  @spec reason(term()) :: atom()
  defp reason(%Marshall.Compute.Error{reason: reason}) when is_atom(reason), do: reason

  defp reason(%Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: reason} | _]})
       when is_atom(reason),
       do: reason

  defp reason(reason) when is_atom(reason), do: reason
  defp reason(_), do: :unknown

  @doc "Closes every open SCIM suspension for a retired identity; requires a transaction."
  @spec release_open!(Ash.UUID.t()) :: :ok
  def release_open!(user_id) do
    ScimMachineSuspension
    |> Ash.Query.filter(user_id == ^user_id and state == :suspended)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&Ledger.update!(&1, :release, %{}))
  end
end
