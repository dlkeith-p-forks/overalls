defmodule Marshall.Accounts.GuestAccounts do
  @moduledoc "Serialized lifetime guest identity allocation with permanent UID reservation."
  alias Marshall.Accounts.{GuestAccount, GuestUsername, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query

  @typep allocation :: {User.t(), GuestAccount.t() | nil}

  # @cc [owner:ghuntley,label:security;concurrency] guest-account-never-reassign
  # Allocation MUST use the locked active User UUID and reuse its current
  # GuestAccount UUID, UID and canonical name regardless of email changes.
  # Every historical UUID and UID MUST remain reserved; another User UUID MUST
  # receive a fresh identity and MUST NOT inherit an old UID or guest home.
  @spec ensure!(String.t()) :: GuestAccount.t()
  def ensure!(user_id) do
    [account] = ensure_all!([user_id])
    account
  end

  # @cc [owner:ghuntley,label:concurrency;security] guest-account-batch-lock-order
  # Callers MUST supply their entire allocation batch once per transaction,
  # never loop ensure!/1 inside one enclosing transaction. Every unique User row
  # MUST be locked in sorted ID order before any GuestAccount lock; no later user
  # lock may be acquired by allocation. Deleted or invalid identities refuse the
  # whole batch. Results follow sorted IDs, not caller order.
  @spec ensure_all!([String.t()]) :: [GuestAccount.t()]
  def ensure_all!(user_ids) do
    unless Marshall.Repo.in_transaction?(),
      do: raise(ArgumentError, "guest allocation requires a transaction")

    ids = user_ids |> Enum.uniq() |> Enum.sort()
    if length(ids) > 512, do: Ledger.rollback(:guest_identity_unavailable)

    ids
    |> Enum.map(&lock_user!/1)
    |> Enum.map(&current_account!/1)
    |> Enum.map(&allocate!/1)
  end

  @spec lock_user!(String.t()) :: User.t()
  defp lock_user!(user_id) do
    user =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^user_id)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read_one!() || Ledger.rollback(:unauthorized)

    if user.deleted_at, do: Ledger.rollback(:unauthorized)
    user
  end

  @spec current_account!(User.t()) :: allocation()
  defp current_account!(user) do
    current =
      GuestAccount
      |> Ash.Query.filter(user_id == ^user.id and is_nil(retired_at))
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: SystemActor.compute())

    {user, current}
  end

  # @cc [owner:ghuntley,label:security;recovery] guest-identity-sequence-exhaustion
  # New allocations MUST refuse on UID exhaustion. Refusal MUST roll back every
  # allocation in the batch; existing accounts MUST resolve without a new UID.
  # Sequence values may be consumed by refusal but MUST never be reset or reused.
  @spec allocate!(allocation()) :: GuestAccount.t()
  defp allocate!({_user, %GuestAccount{} = current}), do: current

  defp allocate!({user, nil}) do
    uid = next_uid!()
    {:ok, name} = GuestUsername.from_uid(uid)

    Ledger.create!(GuestAccount, :allocate, %{user_id: user.id, username: name, uid: uid})
  end

  @spec next_uid!() :: 200_000..999_999
  defp next_uid! do
    case Ecto.Adapters.SQL.query(
           Marshall.Repo,
           "SELECT nextval('account_guest_uid_seq')",
           [],
           log: false
         ) do
      {:ok, %{rows: [[uid]]}} when uid in 200_000..999_999 ->
        uid

      {:error, %Postgrex.Error{postgres: %{code: :sequence_generator_limit_exceeded}}} ->
        Ledger.rollback(:guest_identity_unavailable)

      {:ok, _} ->
        Ledger.rollback(:guest_identity_unavailable)

      {:error, error} ->
        raise error
    end
  end
end
